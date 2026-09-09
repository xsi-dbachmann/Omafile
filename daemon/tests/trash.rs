//! Tests for trash and restore.
//!
//! The one that matters most is that a filesystem which cannot host a trash
//! reports Permanent rather than quietly doing something else — ADR 0009 turns
//! on that distinction being told truthfully.

use omafiled::trash::{self, Disposal};
use std::path::PathBuf;
use std::fs;

#[test]
fn trashing_moves_the_file_and_writes_a_restorable_record() {
    let home = tempfile::tempdir().unwrap();
    let root: PathBuf = home.path().join("Trash");

    let f = home.path().join("victim.txt");
    fs::write(&f, b"still wanted").unwrap();

    let d = trash::trash_in(&root, &f).unwrap();
    let (trashed_as, info) = match d {
        Disposal::Trashed { trashed_as, info } => (trashed_as, info),
        other => panic!("expected Trashed, got {other:?}"),
    };

    assert!(!f.exists(), "the original must be gone from its place");
    assert!(trashed_as.exists(), "the file must be in the trash");
    assert!(info.exists(), "a .trashinfo record must exist");

    let rec = fs::read_to_string(&info).unwrap();
    assert!(rec.starts_with("[Trash Info]"), "spec header missing: {rec}");
    assert!(rec.contains("Path="), "no Path in {rec}");
    assert!(rec.contains("DeletionDate="), "no DeletionDate in {rec}");

    let back = trash::restore(&trashed_as, &info).unwrap();
    assert_eq!(back, f.canonicalize().unwrap_or(f.clone()));
    assert_eq!(fs::read(&f).unwrap(), b"still wanted");
    assert!(!info.exists(), "the record must be cleared after restore");
}

#[test]
fn a_second_file_of_the_same_name_gets_its_own_slot() {
    let home = tempfile::tempdir().unwrap();
    let root: PathBuf = home.path().join("Trash");
    let dir = home.path().join("work");
    fs::create_dir_all(&dir).unwrap();

    let mut seen = Vec::new();
    for i in 0..3 {
        let f = dir.join("same.txt");
        fs::write(&f, format!("copy {i}")).unwrap();
        match trash::trash_in(&root, &f).unwrap() {
            Disposal::Trashed { trashed_as, .. } => seen.push(trashed_as),
            other => panic!("expected Trashed, got {other:?}"),
        }
    }
    seen.sort();
    seen.dedup();
    assert_eq!(seen.len(), 3, "each deletion needs its own name in the trash");
}

/// The case ADR 0009 turns on: a filesystem that cannot host a trash must be
/// reported as permanent, never quietly copied somewhere to look reversible.
#[test]
fn a_filesystem_without_a_trash_reports_permanent() {
    let home = tempfile::tempdir().unwrap();
    let root: PathBuf = home.path().join("Trash");

    // /dev/shm is a different device from any tempdir under $HOME, which is
    // exactly the shape of an SMB share or a USB stick.
    let other = std::path::Path::new("/dev/shm");
    if !other.exists() {
        eprintln!("skipping: /dev/shm unavailable");
        return;
    }
    let f = other.join("omafile-trash-test.txt");
    fs::write(&f, b"on another device").unwrap();

    assert!(!trash::can_trash_in(&root, &f), "a cross-device file must not be trashable");
    let d = trash::trash_in(&root, &f).unwrap();
    assert_eq!(d, Disposal::Permanent, "must report Permanent, not pretend");
    assert!(f.exists(), "reporting Permanent must not itself delete anything");

    let d2 = trash::delete_permanently(&f).unwrap();
    assert_eq!(d2, Disposal::Permanent);
    assert!(!f.exists());
}

#[test]
fn paths_with_awkward_characters_survive_a_round_trip() {
    let home = tempfile::tempdir().unwrap();
    let root: PathBuf = home.path().join("Trash");
    let dir = home.path().join("holiday photos & clips");
    fs::create_dir_all(&dir).unwrap();
    let f = dir.join("100% done #1.txt");
    fs::write(&f, b"awkward").unwrap();

    let (t, i) = match trash::trash_in(&root, &f).unwrap() {
        Disposal::Trashed { trashed_as, info } => (trashed_as, info),
        other => panic!("{other:?}"),
    };
    let back = trash::restore(&t, &i).unwrap();
    assert_eq!(fs::read(&back).unwrap(), b"awkward");
    assert!(back.to_string_lossy().contains("100% done #1.txt"));
}

/// A `.trashinfo` this daemon did not write.
///
/// `Restore` is a socket request and names its own info file, and the
/// FreeDesktop trash is a directory shared with every other tool on the
/// machine. Our `uri_escape` escapes every byte that is not unreserved, so a
/// record *we* wrote can never carry a bare `%`; a tool that escapes less can,
/// and a name like `50%日本.txt` puts a multi-byte character directly after
/// one. `%` followed by something that is not two hex digits is not an escape,
/// so it must come back through unchanged rather than take the daemon with it.
#[test]
fn a_trashinfo_from_another_tool_does_not_bring_the_daemon_down() {
    let home = tempfile::tempdir().unwrap();
    let files = home.path().join("Trash/files");
    let info_dir = home.path().join("Trash/info");
    fs::create_dir_all(&files).unwrap();
    fs::create_dir_all(&info_dir).unwrap();

    let trashed_as = files.join("odd.txt");
    fs::write(&trashed_as, b"came from somewhere else").unwrap();

    let dest = home.path().join("50%日本.txt");
    let info = info_dir.join("odd.txt.trashinfo");
    fs::write(
        &info,
        format!(
            "[Trash Info]\nPath={}\nDeletionDate=2026-09-09T12:00:00\n",
            dest.display()
        ),
    )
    .unwrap();

    let back = trash::restore(&trashed_as, &info).unwrap();
    assert_eq!(back, dest, "the name must survive a % that is not an escape");
    assert_eq!(fs::read(&dest).unwrap(), b"came from somewhere else");
}

/// Two hex digits, and nothing else, is an escape.
///
/// `%+1` used to come back as the byte 0x01, because `u8::from_str_radix`
/// accepts a leading sign — measured: `from_str_radix("+1", 16)` is `Ok(1)`.
/// The spec has no such escape, so those three characters are part of the name.
/// `%41` is a real one and still decodes.
#[test]
fn only_two_hex_digits_are_an_escape() {
    let home = tempfile::tempdir().unwrap();
    let files = home.path().join("Trash/files");
    let info_dir = home.path().join("Trash/info");
    fs::create_dir_all(&files).unwrap();
    fs::create_dir_all(&info_dir).unwrap();

    let trashed_as = files.join("odd.txt");
    fs::write(&trashed_as, b"back where it belongs").unwrap();

    let info = info_dir.join("odd.txt.trashinfo");
    fs::write(
        &info,
        format!(
            "[Trash Info]\nPath={}/keep %+1 %zz %41.txt\nDeletionDate=2026-09-09T12:00:00\n",
            home.path().display()
        ),
    )
    .unwrap();

    let back = trash::restore(&trashed_as, &info).unwrap();
    assert_eq!(back, home.path().join("keep %+1 %zz A.txt"));
    assert_eq!(fs::read(&back).unwrap(), b"back where it belongs");
}
