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
