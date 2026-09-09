//! What a finished Job says on the wire.
//!
//! The plugin never sees `Outcome`; it sees one JSON object per Job, and every
//! surface in the product is derived from it. These tests drive a real daemon
//! over a real socket, because the falsehoods they guard against were assembled
//! in `start_job` — between an engine that knew the truth and a row that
//! reported something else.
//!
//! The daemon runs on its own socket in a temp directory, with `XDG_STATE_HOME`
//! pointed there too, so it shares neither a socket nor a journal with anything
//! already running.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Reaps its daemon on the way out, **including** when the test panics.
///
/// Killing it on the last line of each test is not enough: a failing assertion
/// unwinds past that line, the daemon outlives the test binary, and `cargo
/// test` then waits on the orphan instead of reporting the failure — measured
/// at 160 seconds for a run whose tests had all already failed. A test that
/// hangs when it fails is a test nobody will run.
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

/// Start one Job and return the terminal JobView it produces.
///
/// A fresh connection per Job, which is also the interesting case: the opening
/// snapshot marks Jobs that finished earlier as already delivered, so the only
/// terminal event on this connection belongs to the Job just asked for.
fn run_job(sock: &Path, req: &str) -> serde_json::Value {
    let s = UnixStream::connect(sock).expect("connect");
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut w = s.try_clone().unwrap();
    let mut r = BufReader::new(s);
    let mut line = String::new();
    // Drain the hello and the state snapshot that open every connection.
    for _ in 0..2 {
        line.clear();
        r.read_line(&mut line).unwrap();
    }
    writeln!(w, "{req}").unwrap();
    w.flush().unwrap();
    // A deadline for the whole exchange, because the per-read timeout above
    // cannot bound this loop: the daemon heartbeats every two seconds, so a Job
    // that never reaches a terminal event keeps the socket readable forever and
    // `read_line` never times out. Found 2026-09-08 by looking at a hung run —
    // `cargo test` sat here for **two hours and twenty-two minutes**, its daemon
    // still ticking, and the suite reported 26 tests instead of 35 with an exit
    // code of 0. A test that can hang forever is a test nobody will run.
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        assert!(
            Instant::now() < deadline,
            "no terminal event for this Job within 60s; last line: {line}"
        );
        line.clear();
        assert!(r.read_line(&mut line).unwrap() > 0, "daemon closed before finishing");
        let v: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => panic!("unparseable event {line}: {e}"),
        };
        match v["t"].as_str() {
            Some("finished") | Some("failed") => return v["job"].clone(),
            _ => continue,
        }
    }
}

fn quoted(p: &Path) -> String {
    p.to_str().unwrap().to_string()
}

/// A "Keep both" transfer lands as `report-2.txt`, and the row has to be able
/// to say so: the engine computed that name and used to throw it away, leaving
/// the panel naming `report.txt` in a directory that holds a different
/// `report.txt`.
#[test]
fn a_keep_both_job_reports_the_name_it_landed_under() {
    let td = tempfile::tempdir().unwrap();
    let sock = td.path().join("s.sock");
    let _daemon = daemon(&sock, td.path());

    let from = td.path().join("from");
    let to = td.path().join("to");
    fs::create_dir_all(&from).unwrap();
    fs::create_dir_all(&to).unwrap();
    fs::write(from.join("report.txt"), vec![b'n'; 400]).unwrap();
    fs::write(to.join("report.txt"), b"the one already here").unwrap();

    let job = run_job(
        &sock,
        &format!(
            r#"{{"op":"copy","id":1,"sources":["{}"],"destination_dir":"{}","on_conflict":"keep_both"}}"#,
            quoted(&from.join("report.txt")),
            quoted(&to)
        ),
    );

    assert_eq!(job["error"], serde_json::Value::Null, "job: {job}");
    assert_eq!(job["outcome"], serde_json::json!("copied"));
    assert_eq!(job["landed_as"][0]["asked"], serde_json::json!("report.txt"));
    assert_eq!(
        job["landed_as"][0]["name"],
        serde_json::json!("report-2.txt"),
        "the row must name the file that is actually there: {job}"
    );
    assert_eq!(job["bytes"], serde_json::json!(400));
    assert_eq!(
        fs::read(to.join("report.txt")).unwrap(),
        b"the one already here",
        "keep-both leaves the original alone"
    );

    // The rank ships beside the label, so the UI can order the completion words
    // without parsing them. Which tier this is depends on whether the temp
    // directory's filesystem can reflink; both are honest, and both are ranked.
    let strength = job["strength"].as_u64().unwrap_or_else(|| panic!("no rank: {job}"));
    assert!((1..=3).contains(&strength), "rank out of range: {job}");
}

/// The pre-flight total is summed before anything is skipped, and it used to be
/// what the finished row reported — both as its byte count and inside
/// "exactly as expected". A Job that left most of the selection alone still
/// claimed the whole of it.
#[test]
fn a_job_reports_the_bytes_that_landed_not_the_ones_it_set_out_to_move() {
    let td = tempfile::tempdir().unwrap();
    let sock = td.path().join("s.sock");
    let _daemon = daemon(&sock, td.path());

    let from = td.path().join("from");
    let to = td.path().join("to");
    fs::create_dir_all(&from).unwrap();
    fs::create_dir_all(&to).unwrap();
    // 1000 bytes are already at the destination and will be left alone; 37 are
    // the only bytes this Job will actually write.
    fs::write(from.join("already.bin"), vec![b'a'; 1000]).unwrap();
    fs::write(to.join("already.bin"), vec![b'a'; 1000]).unwrap();
    fs::write(from.join("new.bin"), vec![b'n'; 37]).unwrap();

    let job = run_job(
        &sock,
        &format!(
            r#"{{"op":"copy","id":1,"sources":["{}","{}"],"destination_dir":"{}"}}"#,
            quoted(&from.join("already.bin")),
            quoted(&from.join("new.bin")),
            quoted(&to)
        ),
    );

    assert_eq!(job["error"], serde_json::Value::Null, "job: {job}");
    assert_eq!(job["expected"], serde_json::json!(1037), "the Job asked for both files");
    assert_eq!(
        job["bytes"],
        serde_json::json!(37),
        "only 37 bytes were written: {job}"
    );
    assert_eq!(job["files_done"], serde_json::json!(1), "one file landed: {job}");
    assert_eq!(job["files_skipped_existing"], serde_json::json!(1));
    assert_eq!(job["landed_as"].as_array().unwrap().len(), 1, "one file landed");
    assert_eq!(job["landed_as"][0]["name"], serde_json::json!("new.bin"));

    let detail = job["detail"].as_str().unwrap();
    assert!(
        !detail.contains("1037"),
        "the detail must not claim the total it set out to move: {detail}"
    );
}

/// Every file was already there: nothing was moved, nothing was copied, and
/// there is no tier to rank. A rank here would put the absence of work on the
/// same ladder as a verified transfer.
#[test]
fn a_job_that_transferred_nothing_carries_no_rank() {
    let td = tempfile::tempdir().unwrap();
    let sock = td.path().join("s.sock");
    let _daemon = daemon(&sock, td.path());

    let from = td.path().join("from");
    let to = td.path().join("to");
    fs::create_dir_all(&from).unwrap();
    fs::create_dir_all(&to).unwrap();
    fs::write(from.join("same.txt"), b"here already").unwrap();
    fs::write(to.join("same.txt"), b"here already").unwrap();

    let job = run_job(
        &sock,
        &format!(
            r#"{{"op":"copy","id":1,"sources":["{}"],"destination_dir":"{}"}}"#,
            quoted(&from.join("same.txt")),
            quoted(&to)
        ),
    );

    assert_eq!(job["outcome"], serde_json::json!("skipped"));
    assert_eq!(job["strength"], serde_json::Value::Null, "not a rung on the ladder: {job}");
    assert_eq!(job["bytes"], serde_json::json!(0));
    assert_eq!(job["files_done"], serde_json::json!(0), "nothing landed: {job}");
    assert!(job["landed_as"].as_array().unwrap().is_empty());
}

/// A move is a verb, not a grade, and it still has to say where the file went.
#[test]
fn a_move_carries_its_landing_place_and_no_rank() {
    let td = tempfile::tempdir().unwrap();
    let sock = td.path().join("s.sock");
    let _daemon = daemon(&sock, td.path());

    let from = td.path().join("from");
    let to = td.path().join("to");
    fs::create_dir_all(&from).unwrap();
    fs::create_dir_all(&to).unwrap();
    fs::write(from.join("going.txt"), vec![b'g'; 64]).unwrap();

    let job = run_job(
        &sock,
        &format!(
            r#"{{"op":"move","id":1,"sources":["{}"],"destination_dir":"{}"}}"#,
            quoted(&from.join("going.txt")),
            quoted(&to)
        ),
    );

    assert_eq!(job["outcome"], serde_json::json!("moved"), "job: {job}");
    assert_eq!(job["strength"], serde_json::Value::Null, "a move is not a grade: {job}");
    assert_eq!(job["landed_as"][0]["name"], serde_json::json!("going.txt"));
    assert_eq!(job["bytes"], serde_json::json!(64), "a move still moved 64 bytes: {job}");
    assert!(!from.join("going.txt").exists(), "the source is gone");
    assert!(to.join("going.txt").exists());
}
