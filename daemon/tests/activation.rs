//! The systemd socket-activation protocol, read by hand (ADR 0005).
//!
//! One test function on purpose. Every case here manipulates process-wide
//! environment variables and descriptor 3, and `cargo test` runs the tests in a
//! binary on threads — so these cannot be separate `#[test]`s without racing
//! each other for the two pieces of global state they are about.

use omafiled::server::activated_listener;
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};

fn set(pid: &str, fds: &str) {
    std::env::set_var("LISTEN_PID", pid);
    std::env::set_var("LISTEN_FDS", fds);
    std::env::set_var("LISTEN_FDNAMES", "omafiled.socket");
}

fn clear() {
    std::env::remove_var("LISTEN_PID");
    std::env::remove_var("LISTEN_FDS");
    std::env::remove_var("LISTEN_FDNAMES");
}

/// Descriptor 3 is not ours to clobber — the test harness may be holding
/// something there — so it is put back exactly as it was found.
fn take_fd3() -> Option<RawFd> {
    let saved = unsafe { libc::dup(3) };
    if saved < 0 { None } else { Some(saved) }
}

fn give_back_fd3(saved: Option<RawFd>) {
    unsafe {
        libc::close(3);
        if let Some(s) = saved {
            libc::dup2(s, 3);
            libc::close(s);
        }
    }
}

/// Puts `fd` on descriptor 3 and gives up ownership of it, since
/// `activated_listener` takes ownership of 3 on success. Returns the original
/// descriptor if it still needs closing afterwards.
fn install_as_fd3<T: AsRawFd>(owner: T) -> Option<RawFd> {
    let raw = owner.as_raw_fd();
    let spare = if raw == 3 {
        None
    } else {
        unsafe { libc::dup2(raw, 3) };
        Some(raw)
    };
    std::mem::forget(owner);
    spare
}

#[test]
fn the_activation_protocol() {
    let dir = std::env::temp_dir().join(format!("omafiled-activation-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    // Nobody activated us: the ordinary case, every time the daemon is run by
    // hand.
    clear();
    assert!(activated_listener().unwrap().is_none(), "no LISTEN_PID means no inherited socket");

    // Addressed to another process. This is the case the whole check exists
    // for: an inherited LISTEN_FDS would otherwise have the daemon adopt
    // whatever descriptor 3 happens to be and serve it.
    set("1", "1");
    assert!(activated_listener().unwrap().is_none(), "a LISTEN_PID for pid 1 is not for us");
    assert!(std::env::var("LISTEN_PID").is_err(), "the variables must be consumed when read");
    assert!(std::env::var("LISTEN_FDS").is_err());
    assert!(std::env::var("LISTEN_FDNAMES").is_err());

    let me = std::process::id().to_string();

    // Addressed to us with nothing usable behind it. Not silently ignorable:
    // systemd is holding the socket clients will connect to, so binding our own
    // path instead would leave them talking to a listener nobody accepts on.
    set(&me, "not a number");
    let err = activated_listener().expect_err("a garbled LISTEN_FDS must not be shrugged off");
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);

    set(&me, "0");
    let err = activated_listener().expect_err("being activated with no sockets is a broken unit");
    assert!(err.to_string().contains("passed no sockets"), "got: {err}");

    // A real listening socket, adopted and served.
    {
        let saved = take_fd3();
        let path = dir.join("passed.sock");
        let spare = install_as_fd3(UnixListener::bind(&path).unwrap());

        set(&me, "1");
        let adopted = activated_listener()
            .expect("a listening AF_UNIX stream socket is exactly what systemd passes")
            .expect("and it is addressed to us");

        let flags = unsafe { libc::fcntl(3, libc::F_GETFD) };
        assert!(
            flags & libc::FD_CLOEXEC != 0,
            "systemd does not set close-on-exec on what it passes; the daemon must"
        );

        let client = UnixStream::connect(&path).expect("a client should reach the passed socket");
        adopted.accept().expect("and the adopted listener should be the one accepting");
        drop(client);
        drop(adopted);
        if let Some(s) = spare {
            unsafe { libc::close(s) };
        }
        give_back_fd3(saved);
    }

    // Descriptor 3 is not something we can accept() on. Without the check this
    // surfaces as accept() returning "Invalid argument" forever, which names
    // the symptom and not the cause.
    {
        let saved = take_fd3();
        let spare = install_as_fd3(std::fs::File::create(dir.join("plain")).unwrap());

        set(&me, "1");
        let err = activated_listener().expect_err("a regular file is not a listening socket");
        assert!(
            err.to_string().contains("not a listening AF_UNIX stream socket"),
            "the refusal must name the cause, got: {err}"
        );

        if let Some(s) = spare {
            unsafe { libc::close(s) };
        }
        give_back_fd3(saved);
    }

    clear();
    std::fs::remove_dir_all(&dir).unwrap();
}
