//! What the daemon is allowed to claim about free space.
//!
//! Free space is a number the plugin will refuse a transfer on, so the two ways
//! it can be wrong are both expensive and neither is loud: reporting the root
//! reserve promises space the user cannot write into, and reporting zero for a
//! query that failed refuses transfers that would have fitted. Both produce a
//! plausible-looking integer, which is why these are tested against an outside
//! oracle rather than against the arithmetic that produced them.

use omafiled::space;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// `df`'s own answer for a path, in bytes: (size, available).
///
/// An independent oracle on purpose. Recomputing `f_blocks * f_frsize` inside
/// the test would assert only that the test and the implementation multiply the
/// same way — and the bug being guarded against is picking the wrong *field*,
/// which that arithmetic would reproduce faithfully.
fn df(path: &Path) -> (u64, u64) {
    let out = std::process::Command::new("df")
        .args(["-B1", "--output=size,avail"])
        .arg(path)
        .output()
        .expect("df");
    assert!(out.status.success(), "df failed: {}", String::from_utf8_lossy(&out.stderr));
    let text = String::from_utf8(out.stdout).unwrap();
    let row = text.lines().nth(1).unwrap_or_else(|| panic!("no df row: {text}"));
    let mut n = row.split_whitespace();
    (
        n.next().unwrap().parse().unwrap(),
        n.next().unwrap().parse().unwrap(),
    )
}

/// The block reserve on this path's filesystem, and what `f_bfree` would have
/// reported — the wrong answer, in bytes.
///
/// This is the one place the test calls `statvfs` itself, and it is not
/// recomputing the answer: it is establishing whether the filesystem under the
/// test even *has* a reserve, so the assertion below can say what it is
/// distinguishing rather than pass vacuously.
fn reserve_and_bfree(path: &Path) -> (u64, u64) {
    let c = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    assert_eq!(unsafe { libc::statvfs(c.as_ptr(), &mut st) }, 0, "statvfs {}", path.display());
    let unit = st.f_frsize as u64;
    (
        (st.f_bfree as u64 - st.f_bavail as u64) * unit,
        (st.f_bfree as u64) * unit,
    )
}

/// `f_bavail`, not `f_bfree`. The difference is the reserve only root may
/// spend, and a transfer sized against it would be told it fits and then run
/// out of space partway — a partial result reported as a plan that worked.
///
/// Run against this crate's own directory rather than a temp one: `/tmp` is a
/// tmpfs with no reserve at all, where the two fields are equal and the
/// assertion would prove nothing.
#[test]
fn available_is_what_a_user_can_write_not_the_root_reserve() {
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let s = space::query(&here).expect("this crate's own directory is on a filesystem");

    let (df_size, df_avail) = df(&here);
    assert_eq!(s.total, df_size, "the filesystem's size is not a moving number");

    // Available *is* a moving number — anything on this machine can write
    // between the two calls — so it is checked for agreement, not equality.
    let drift = s.available.abs_diff(df_avail);
    assert!(
        drift < 64 * 1024 * 1024,
        "available {} disagrees with df's {} by {drift} bytes",
        s.available, df_avail
    );

    let (reserve, bfree) = reserve_and_bfree(&here);
    if reserve > 64 * 1024 * 1024 {
        assert!(
            bfree - s.available > reserve / 2,
            "reported {} where f_bfree is {bfree}: that is the {reserve}-byte root \
             reserve being promised to a user who cannot spend it",
            s.available
        );
    }

    assert!(s.available <= s.total, "cannot have more free than there is: {s:?}");
}

/// A path that cannot be queried must say so. Answering zero would be
/// indistinguishable from a full disk, and a caller refusing transfers on it
/// would refuse every valid one — the query making things worse than not
/// asking.
#[test]
fn a_path_that_does_not_exist_is_an_error_and_not_zero() {
    let td = tempfile::tempdir().unwrap();
    let missing = td.path().join("no-such-directory").join("nor-this-one");

    let e = space::query(&missing).expect_err("a missing path has no filesystem to report");
    assert!(e.contains("nor-this-one"), "the error must name what was asked about: {e}");
    assert!(
        e.to_lowercase().contains("no such file"),
        "and why the kernel refused it: {e}"
    );
}

/// Reaps its daemon on the way out, including when the test panics — a failing
/// assertion otherwise unwinds past the kill and `cargo test` waits on the
/// orphan instead of reporting the failure (see `tests/finished.rs`).
struct DaemonUnderTest(std::process::Child);

impl Drop for DaemonUnderTest {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn daemon(sock: &Path, state: &Path) -> DaemonUnderTest {
    let bin = PathBuf::from(env!("CARGO_BIN_EXE_omafiled"));
    let c = std::process::Command::new(bin)
        .args(["serve", "--socket", sock.to_str().unwrap()])
        .env("XDG_STATE_HOME", state)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("daemon");
    for _ in 0..50 {
        if sock.exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    DaemonUnderTest(c)
}

/// The plugin binds these field names directly, so the wire shape is the part
/// worth proving over a real socket: a field that quietly serialised under
/// another name would leave a QML binding reading `undefined` with nothing
/// failing.
#[test]
fn the_daemon_answers_a_space_request_over_the_socket() {
    let td = tempfile::tempdir().unwrap();
    let sock = td.path().join("s.sock");
    let _daemon = daemon(&sock, td.path());

    let s = UnixStream::connect(&sock).expect("connect");
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut w = s.try_clone().unwrap();
    let mut r = BufReader::new(s);
    let mut line = String::new();
    // Drain the hello and the state snapshot that open every connection.
    for _ in 0..2 {
        line.clear();
        r.read_line(&mut line).unwrap();
    }

    // Reads past the heartbeat, which is the only other thing an idle daemon
    // says — and the deadline is there *because* of it. The socket's read
    // timeout cannot bound this loop: a daemon that never answers still speaks
    // every two seconds, so `read_line` keeps returning and the loop spins
    // forever. Watched happening here, not reasoned about: sabotaging the
    // request's `op` tag so the daemon could not parse it left this test
    // running past sixty seconds instead of failing, which is exactly the hang
    // `tests/finished.rs` documents at two hours and twenty-two minutes.
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut await_space = |req: String| -> serde_json::Value {
        writeln!(w, "{req}").unwrap();
        w.flush().unwrap();
        loop {
            assert!(Instant::now() < deadline, "no space reply within 20s; last line: {line}");
            line.clear();
            assert!(r.read_line(&mut line).unwrap() > 0, "daemon closed without answering");
            let v: serde_json::Value = serde_json::from_str(&line).expect(&line);
            if v["t"] == serde_json::json!("space") {
                return v;
            }
        }
    };

    let here = td.path().to_str().unwrap().to_string();
    let v = await_space(format!(r#"{{"op":"space","id":7,"path":"{here}"}}"#));
    assert_eq!(v["id"], serde_json::json!(7), "the reply belongs to the request: {v}");
    assert_eq!(v["path"], serde_json::json!(here), "and names what it is about");
    assert_eq!(v["error"], serde_json::Value::Null, "{v}");
    let total = v["total"].as_u64().unwrap_or_else(|| panic!("no total: {v}"));
    let available = v["available"].as_u64().unwrap_or_else(|| panic!("no available: {v}"));
    assert!(total > 0, "a mounted filesystem has a size: {v}");
    assert!(available <= total, "{v}");

    // The failure path over the same socket. The connection must survive it —
    // a question the daemon cannot answer is not a reason to drop the client.
    let missing = td.path().join("gone").to_str().unwrap().to_string();
    let v = await_space(format!(r#"{{"op":"space","id":8,"path":"{missing}"}}"#));
    assert_eq!(v["id"], serde_json::json!(8));
    assert!(v["error"].is_string(), "an unanswerable query must say so: {v}");
    assert!(v["total"].is_null(), "not zero — zero is a full disk: {v}");
    assert!(v["available"].is_null(), "not zero — zero is a full disk: {v}");
}
