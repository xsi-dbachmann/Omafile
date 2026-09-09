//! Tests for the commit discipline.
//!
//! The important ones are the failure tests. A verification that cannot be made
//! to fail on demand proves nothing — that was the lesson of the founding
//! incident, where every layer reported success.

use omafiled::engine::Conflict;
use omafiled::{Engine, Journal, Options, Outcome, TransferError, VerificationTier};
use std::fs;
use std::path::Path;

fn engine(dir: &Path) -> Engine {
    Engine::new(Journal::open_at(dir.join("journal")).unwrap())
}

fn write(p: &Path, bytes: &[u8]) {
    fs::write(p, bytes).unwrap();
}

#[test]
fn copy_without_checksum_is_size_checked() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("src");
    let dst = td.path().join("dst");
    write(&src, b"hello omafile");

    let out = e.copy_file(&src, &dst, Options::default()).unwrap();
    match out {
        Outcome::Copied { tier, bytes, .. } => {
            assert!(matches!(tier, VerificationTier::SizeChecked | VerificationTier::SharedExtents));
            assert_eq!(bytes, 13);
        }
        other => panic!("unexpected {other:?}"),
    }
    assert_eq!(fs::read(&dst).unwrap(), b"hello omafile");
}

#[test]
fn copy_with_checksum_reports_checksummed() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("src");
    let dst = td.path().join("sub/dst");
    fs::create_dir_all(dst.parent().unwrap()).unwrap();
    write(&src, &vec![7u8; 5 << 20]);

    // Across directories on the same fs a reflink may still succeed; force the
    // copy path by asserting on whichever tier is reported being an honest one.
    let out = e.copy_file(&src, &dst, Options { checksum: true, ..Options::default() }).unwrap();
    match out {
        Outcome::Copied { tier, bytes, .. } => {
            assert_eq!(bytes, 5 << 20);
            assert!(matches!(
                tier,
                VerificationTier::Checksummed | VerificationTier::SharedExtents
            ));
        }
        other => panic!("unexpected {other:?}"),
    }
    assert_eq!(fs::metadata(&dst).unwrap().len(), 5 << 20);
}

#[test]
fn same_filesystem_move_copies_nothing() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("src");
    let dst = td.path().join("dst");
    write(&src, b"moved");

    assert_eq!(
        e.move_file(&src, &dst, Options::default()).unwrap(),
        Outcome::Moved { committed_as: dst.clone() }
    );
    assert!(!src.exists());
    assert_eq!(fs::read(&dst).unwrap(), b"moved");
}

/// The decisive failure test: verification must be able to fail.
#[test]
fn checksum_mismatch_is_detected_and_leaves_nothing_behind() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("src");
    let temp = td.path().join(".omafile-dst.part");
    let dst = td.path().join("dst");

    write(&src, b"the real bytes");
    write(&temp, b"the WRONG bytes"); // as if the medium corrupted the write

    let err = e.verify_with_retry(&src, &temp, &dst).unwrap_err();
    assert!(matches!(err, TransferError::ChecksumMismatch { .. }));

    // A failed verification must leave the destination untouched and the temp
    // file gone — never a partial file at a final path.
    assert!(!dst.exists(), "destination must not exist after a failed verification");
    assert!(!temp.exists(), "the temp file must be discarded");
}

#[test]
fn identical_bytes_verify_clean() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("src");
    let temp = td.path().join(".omafile-dst.part");
    let dst = td.path().join("dst");
    write(&src, &vec![3u8; 1 << 20]);
    write(&temp, &vec![3u8; 1 << 20]);

    assert!(e.verify_with_retry(&src, &temp, &dst).is_ok());
    assert!(temp.exists(), "a passing verification must not delete the temp file");
}

/// A stray `.part` file is not evidence of trustworthy progress. Without a
/// journal entry that agrees with it, the copy starts over.
#[test]
fn stray_part_file_is_not_resumed() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("src");
    let dst = td.path().join("dst");
    let temp = td.path().join(".omafile-dst.part");

    write(&src, b"0123456789");
    write(&temp, b"XXXX"); // junk left by something else

    e.copy_file(&src, &dst, Options::default()).unwrap();
    assert_eq!(fs::read(&dst).unwrap(), b"0123456789");
}

/// The journal holds unfinished work only. After a commit there must be
/// nothing left recording it — that is the no-history rule (ADR 0008).
#[test]
fn journal_is_empty_after_a_successful_commit() {
    let td = tempfile::tempdir().unwrap();
    let jdir = td.path().join("journal");
    let e = Engine::new(Journal::open_at(jdir.clone()).unwrap());
    let src = td.path().join("src");
    let dst = td.path().join("dst");
    write(&src, b"committed");

    e.copy_file(&src, &dst, Options::default()).unwrap();

    let j = Journal::open_at(jdir).unwrap();
    assert!(j.unfinished().unwrap().is_empty(), "journal must not record finished work");
}

#[test]
fn tier_labels_never_say_done() {
    for t in [
        VerificationTier::SharedExtents,
        VerificationTier::Checksummed,
        VerificationTier::SizeChecked,
    ] {
        let l = t.label().to_lowercase();
        assert!(!l.contains("done"), "{l} must state what was established");
        assert!(!l.contains("ok"), "{l} must state what was established");
    }
}

/// The reflink fast path must obey the same commit discipline as everything
/// else. An earlier version cloned straight into the destination with
/// truncate, and removed it when the clone failed — so copying onto an
/// existing file destroyed that file before anything was known to have worked.
#[test]
fn copying_onto_an_existing_file_never_leaves_it_damaged() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("new.bin");
    let dst = td.path().join("existing.bin");

    let old = vec![0xAAu8; 3 << 20];
    let new = vec![0xBBu8; 5 << 20];
    write(&src, &new);
    write(&dst, &old);

    let opts = Options { on_conflict: Conflict::Replace, ..Options::default() };
    let out = e.copy_file(&src, &dst, opts).unwrap();
    match out {
        Outcome::Copied { bytes, replaced, .. } => {
            assert_eq!(bytes, new.len() as u64);
            assert!(replaced, "an existing destination was committed over");
        }
        other => panic!("unexpected {other:?}"),
    }

    // The destination is now the new content in full — never a truncated or
    // half-written version of either.
    let landed = fs::read(&dst).unwrap();
    assert_eq!(landed.len(), new.len(), "destination must be the full new file");
    assert_eq!(landed, new, "destination content must match the source exactly");

    // And no temp file was left lying around.
    let strays: Vec<_> = fs::read_dir(td.path())
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with(".omafile-"))
        .collect();
    assert!(strays.is_empty(), "temp files left behind: {strays:?}");
}

/// A copy that cannot complete must leave the existing destination exactly as
/// it was — the property the old reflink path violated.
#[test]
fn a_failed_copy_leaves_an_existing_destination_untouched() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("unreadable.bin");
    let dst = td.path().join("precious.bin");

    write(&src, &vec![1u8; 1 << 20]);
    let precious = b"do not lose me".to_vec();
    write(&dst, &precious);

    // Make the source unreadable so the copy cannot succeed by any path.
    let mut perms = fs::metadata(&src).unwrap().permissions();
    use std::os::unix::fs::PermissionsExt;
    perms.set_mode(0o000);
    fs::set_permissions(&src, perms).unwrap();

    let opts = Options { on_conflict: Conflict::Replace, ..Options::default() };
    let result = e.copy_file(&src, &dst, opts);
    assert!(result.is_err(), "an unreadable source must fail the copy");

    assert!(dst.exists(), "the existing destination must still exist");
    assert_eq!(
        fs::read(&dst).unwrap(),
        precious,
        "the existing destination must be byte-for-byte unchanged"
    );

    let mut perms = fs::metadata(&src).unwrap().permissions();
    perms.set_mode(0o644);
    let _ = fs::set_permissions(&src, perms);
}


/// The default must never destroy anything. A caller that forgets to say what
/// to do about a conflict gets Skip, not Replace.
#[test]
fn the_default_conflict_policy_leaves_an_existing_file_alone() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("incoming.txt");
    let dst = td.path().join("already-here.txt");
    write(&src, b"new content");
    write(&dst, b"original content");

    let out = e.copy_file(&src, &dst, Options::default()).unwrap();
    assert_eq!(out, Outcome::SkippedExisting);
    assert_eq!(fs::read(&dst).unwrap(), b"original content");
}

#[test]
fn keep_both_lands_beside_without_touching_the_original() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("photo.jpg");
    let dst = td.path().join("holiday.jpg");
    write(&src, b"the new one");
    write(&dst, b"the old one");

    let opts = Options { on_conflict: Conflict::KeepBoth, ..Options::default() };
    let out = e.copy_file(&src, &dst, opts).unwrap();
    match out {
        Outcome::Copied { replaced, .. } => assert!(!replaced, "keep-both replaces nothing"),
        other => panic!("unexpected {other:?}"),
    }
    assert_eq!(fs::read(&dst).unwrap(), b"the old one", "the original is untouched");
    // The extension is preserved, so the copy is still the same kind of file.
    assert_eq!(fs::read(td.path().join("holiday-2.jpg")).unwrap(), b"the new one");
}

/// A move that is skipped must not delete the source. The cross-filesystem path
/// copied, got SkippedExisting, and then removed the source unconditionally —
/// so moving a file onto an existing name destroyed it without ever copying it.
#[test]
fn a_skipped_move_never_deletes_the_source() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    // /dev/shm is a different device, forcing the copy-then-delete path.
    let src = std::path::PathBuf::from("/dev/shm/omafile-move-skip-src.txt");
    let dst = td.path().join("already.txt");
    write(&src, b"the only copy");
    write(&dst, b"the existing one");

    let out = e.move_file(&src, &dst, Options::default()).unwrap();
    assert_eq!(out, Outcome::SkippedExisting, "a skipped move reports skipped");
    assert!(src.exists(), "THE SOURCE MUST SURVIVE A SKIPPED MOVE");
    assert_eq!(fs::read(&src).unwrap(), b"the only copy");
    assert_eq!(fs::read(&dst).unwrap(), b"the existing one", "destination untouched");
    let _ = fs::remove_file(&src);
}

/// A same-filesystem move must honour the conflict policy too. It renamed
/// straight over the destination without consulting it.
#[test]
fn a_same_filesystem_move_honours_the_conflict_policy() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("incoming.txt");
    let dst = td.path().join("keep-me.txt");
    write(&src, b"new");
    write(&dst, b"precious");

    let out = e.move_file(&src, &dst, Options::default()).unwrap();
    assert_eq!(out, Outcome::SkippedExisting);
    assert_eq!(fs::read(&dst).unwrap(), b"precious", "must not overwrite on Skip");
    assert!(src.exists(), "and must not delete the source");

    // With Replace it may proceed, and the source goes.
    let opts = Options { on_conflict: Conflict::Replace, ..Options::default() };
    assert_eq!(
        e.move_file(&src, &dst, opts).unwrap(),
        Outcome::Moved { committed_as: dst.clone() }
    );
    assert_eq!(fs::read(&dst).unwrap(), b"new");
    assert!(!src.exists());
}

/// "Keep both" is one of four buttons on the conflict dialog, and the engine
/// already computes `holiday-2.jpg` — it just threw the name away, because the
/// outcome carried no path. The finished row then named `holiday.jpg`, in a
/// directory that still holds a different `holiday.jpg`, and the user went
/// hunting. The outcome states where the bytes actually went.
#[test]
fn keep_both_reports_the_name_it_landed_under() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("photo.jpg");
    let dst = td.path().join("holiday.jpg");
    write(&src, b"the new one");
    write(&dst, b"the old one");

    let opts = Options { on_conflict: Conflict::KeepBoth, ..Options::default() };
    match e.copy_file(&src, &dst, opts).unwrap() {
        Outcome::Copied { committed_as, .. } => {
            assert_eq!(
                committed_as,
                td.path().join("holiday-2.jpg"),
                "the outcome must name the file the copy actually committed to"
            );
        }
        other => panic!("unexpected {other:?}"),
    }
}

/// The ordinary case still has to be right, or the caller cannot tell a
/// keep-both landing from a plain one without re-deriving the name itself.
/// Same directory, same filesystem: this covers the reflink fast path too,
/// which returns from a different place.
#[test]
fn a_plain_copy_reports_the_path_it_committed_to() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("src");
    let dst = td.path().join("dst");
    write(&src, b"nothing in the way");

    match e.copy_file(&src, &dst, Options::default()).unwrap() {
        Outcome::Copied { committed_as, .. } => assert_eq!(committed_as, dst),
        other => panic!("unexpected {other:?}"),
    }
}

/// A move can land beside an existing file too, and then the source name is
/// gone from the source pane and absent from the destination pane — the worst
/// case for a row that cannot say where the file went.
#[test]
fn a_keep_both_move_reports_the_name_it_landed_under() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    let src = td.path().join("incoming.txt");
    let dst = td.path().join("keep-me.txt");
    write(&src, b"new");
    write(&dst, b"precious");

    let opts = Options { on_conflict: Conflict::KeepBoth, ..Options::default() };
    let out = e.move_file(&src, &dst, opts).unwrap();
    assert_eq!(out, Outcome::Moved { committed_as: td.path().join("keep-me-2.txt") });
    assert!(!src.exists(), "the move must still remove the source");
    assert_eq!(fs::read(&dst).unwrap(), b"precious", "the original is untouched");
    assert_eq!(fs::read(td.path().join("keep-me-2.txt")).unwrap(), b"new");
}

/// The cross-filesystem path arrives at the same fact by copying and removing,
/// and returns `Moved` from a different place, so it needs its own proof.
#[test]
fn a_cross_filesystem_keep_both_move_reports_the_name_it_landed_under() {
    let td = tempfile::tempdir().unwrap();
    let e = engine(td.path());
    // /dev/shm is a different device, forcing the copy-then-remove path.
    let src = std::path::PathBuf::from("/dev/shm/omafile-move-keepboth-src.txt");
    let dst = td.path().join("already.txt");
    write(&src, b"the incoming one");
    write(&dst, b"the existing one");

    let opts = Options { on_conflict: Conflict::KeepBoth, ..Options::default() };
    let out = e.move_file(&src, &dst, opts).unwrap();
    assert_eq!(out, Outcome::Moved { committed_as: td.path().join("already-2.txt") });
    assert!(!src.exists(), "a completed cross-filesystem move removes the source");
    assert_eq!(fs::read(&dst).unwrap(), b"the existing one", "destination untouched");
    assert_eq!(fs::read(td.path().join("already-2.txt")).unwrap(), b"the incoming one");
    let _ = fs::remove_file(&src);
}
