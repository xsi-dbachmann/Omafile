//! A daemon must never unlink a socket it did not create (issue 16).
//!
//! `serve` used to `remove_file` the path and bind over it, so a second
//! `omafiled serve` silently took the first one's clients: the running daemon
//! kept its descriptor while its socket file was replaced underneath it, and
//! the next client to connect reached the newcomer. Every case below is a
//! sentence from that decision, and the third one is why the unlink could not
//! simply be deleted.

use omafiled::server::bind_fresh;
use std::io::ErrorKind;
use std::os::unix::net::{UnixListener, UnixStream};

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("omafiled-socket-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn binds_a_path_with_nothing_on_it() {
    let dir = temp_dir("fresh");
    let path = dir.join("omafiled.sock");

    let listener = bind_fresh(&path).expect("a free path should bind");

    assert!(path.exists(), "binding should have created the socket file");
    UnixStream::connect(&path).expect("the bound socket should answer");
    drop(listener);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn refuses_to_evict_a_live_daemon() {
    let dir = temp_dir("live");
    let path = dir.join("omafiled.sock");

    let incumbent = bind_fresh(&path).expect("the first bind should succeed");

    let err = bind_fresh(&path).expect_err("the second bind must not succeed");
    assert_eq!(err.kind(), ErrorKind::AddrInUse);
    assert!(
        err.to_string().contains("already served by a running omafiled"),
        "the refusal must say why, got: {err}"
    );

    // The point of the refusal: the incumbent still has its clients. Under the
    // old code the file at this path belonged to the newcomer by now.
    let client = UnixStream::connect(&path).expect("the incumbent should still be reachable");
    incumbent.accept().expect("and it should be the one accepting");
    drop(client);
    drop(incumbent);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn clears_a_socket_an_unclean_exit_left_behind() {
    let dir = temp_dir("stale");
    let path = dir.join("omafiled.sock");

    // Dropping a UnixListener does not unlink its path — this is exactly what a
    // killed daemon leaves, and why "refuse whenever the path exists" would
    // make one crash permanent.
    drop(UnixListener::bind(&path).unwrap());
    assert!(path.exists(), "the socket file should outlive its listener");
    assert_eq!(
        UnixStream::connect(&path).unwrap_err().kind(),
        ErrorKind::ConnectionRefused,
        "a stale socket is one that refuses, and that is the whole test"
    );

    let listener = bind_fresh(&path).expect("a stale socket should be cleared and rebound");
    UnixStream::connect(&path).expect("the new listener should answer");
    listener.accept().expect("and it should be this one accepting");

    drop(listener);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn never_removes_something_that_is_not_a_socket() {
    let dir = temp_dir("regular");
    let path = dir.join("not-a-socket");
    std::fs::write(&path, b"someone's file").unwrap();

    let err = bind_fresh(&path).expect_err("a regular file must not be bound over");
    assert_eq!(err.kind(), ErrorKind::AlreadyExists);
    assert!(
        err.to_string().contains("refusing to remove it"),
        "the refusal must say why, got: {err}"
    );
    assert_eq!(
        std::fs::read(&path).unwrap(),
        b"someone's file",
        "the file must still be there, byte for byte"
    );

    std::fs::remove_dir_all(&dir).unwrap();
}
