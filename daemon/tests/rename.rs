//! Rename is a filesystem mutation the daemon owns, and it validates the shape
//! of a name rather than sanitising a string. These tests are about refusal.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

fn daemon(sock: &PathBuf) -> std::process::Child {
    let bin = PathBuf::from(env!("CARGO_BIN_EXE_omafiled"));
    let c = std::process::Command::new(bin)
        .args(["serve", "--socket", sock.to_str().unwrap()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("daemon");
    for _ in 0..50 {
        if sock.exists() { break }
        std::thread::sleep(std::time::Duration::from_millis(40));
    }
    c
}

fn ask(sock: &PathBuf, req: &str) -> String {
    let s = UnixStream::connect(sock).expect("connect");
    let mut w = s.try_clone().unwrap();
    let mut r = BufReader::new(s);
    // Drain the hello and the state snapshot that open every connection.
    let mut line = String::new();
    for _ in 0..2 { line.clear(); r.read_line(&mut line).unwrap(); }
    writeln!(w, "{req}").unwrap();
    w.flush().unwrap();
    loop {
        line.clear();
        if r.read_line(&mut line).unwrap() == 0 { return String::new() }
        if line.contains("\"renamed\"") { return line }
    }
}

#[test]
fn rename_works_and_refuses_paths_collisions_and_dots() {
    let td = tempfile::tempdir().unwrap();
    let sock = td.path().join("s.sock");
    let mut child = daemon(&sock);

    let f = td.path().join("original.txt");
    fs::write(&f, b"contents").unwrap();
    let other = td.path().join("taken.txt");
    fs::write(&other, b"someone else").unwrap();
    let p = f.to_str().unwrap();

    // A plain rename works.
    let out = ask(&sock, &format!(r#"{{"op":"rename","id":1,"path":"{p}","new_name":"renamed.txt"}}"#));
    assert!(out.contains("\"error\":null"), "plain rename should succeed: {out}");
    assert!(td.path().join("renamed.txt").exists());
    let p2 = td.path().join("renamed.txt");
    let p2s = p2.to_str().unwrap();

    // A name containing a separator would be a move to somewhere the user
    // never chose. It must be refused, not sanitised.
    let out = ask(&sock, &format!(r#"{{"op":"rename","id":2,"path":"{p2s}","new_name":"../escaped.txt"}}"#));
    assert!(out.contains("path separator"), "must refuse a path: {out}");
    assert!(p2.exists(), "a refused rename must change nothing");

    // Renaming onto an existing file is a delete wearing a rename's clothes.
    let out = ask(&sock, &format!(r#"{{"op":"rename","id":3,"path":"{p2s}","new_name":"taken.txt"}}"#));
    assert!(out.contains("already exists"), "must refuse a collision: {out}");
    assert_eq!(fs::read(&other).unwrap(), b"someone else", "the other file must be untouched");

    // Dot names are not usable names.
    let out = ask(&sock, &format!(r#"{{"op":"rename","id":4,"path":"{p2s}","new_name":".."}}"#));
    assert!(out.contains("not a usable name"), "must refuse '..': {out}");

    // Empty is not a name.
    let out = ask(&sock, &format!(r#"{{"op":"rename","id":5,"path":"{p2s}","new_name":""}}"#));
    assert!(out.contains("cannot be empty"), "must refuse empty: {out}");

    assert_eq!(fs::read(&p2).unwrap(), b"contents", "contents survive every refusal");
    let _ = child.kill();
}
