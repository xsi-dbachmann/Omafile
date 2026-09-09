import QtQuick
import QtTest
import "../../components"

// The sentences, checked against the numbers they claim to report.
//
// Two of the three cases below are bugs this product shipped and one is a bug it
// nearly shipped, and all three were caught by a person reading a screen. They
// are arithmetic; a screen should not be what catches them.
TestCase {
  id: t
  name: "Wording"

  Wording { id: w }

  function job(label, done, total, left) {
    return { label: label, files_done: done, files_total: total,
             files_skipped_existing: left }
  }

  // Watched on screen 2026-09-08: a four-file copy with one file already at the
  // destination said "Copied 4 files", and said nothing at all about the one it
  // had left alone.
  function test_a_partly_skipped_job_counts_what_landed() {
    var j = t.job("4 files", 3, 4, 1)
    compare(w.landedPhrase(j), "3 files")
    compare(w.leftAlonePhrase(j), " — 1 left alone")
  }

  function test_one_file_landed_is_singular() {
    compare(w.landedPhrase(t.job("3 files", 1, 3, 2)), "1 file")
    compare(w.leftAlonePhrase(t.job("3 files", 1, 3, 2)), " — 2 left alone")
  }

  // Nothing was left behind, so the label is kept: it NAMES the file instead of
  // counting it, and a name is the better sentence.
  function test_a_clean_job_keeps_its_label() {
    var j = t.job("report.pdf", 1, 1, 0)
    compare(w.landedPhrase(j), "report.pdf")
    compare(w.leftAlonePhrase(j), "")
  }

  // An older daemon, or a Job shape that does not carry the counts. Falling back
  // to the label is the safe direction: it may be vaguer, never wrong.
  function test_missing_counts_fall_back_to_the_label() {
    compare(w.landedPhrase({ label: "5 files" }), "5 files")
    compare(w.leftAlonePhrase({ label: "5 files" }), "")
  }

  function test_folder_name() {
    compare(w.folderName("/tmp/omafile-auto/dst"), "dst")
    compare(w.folderName("/tmp/omafile-auto/dst/"), "dst")
    compare(w.folderName("/tmp/omafile-auto/dst///"), "dst")
    compare(w.folderName("/"), "/")
    compare(w.folderName(""), "/")
    compare(w.folderName("dst"), "dst")
  }

  // The engine's rule, repeated where the dialog can show it: free_name_beside()
  // numbers from -2 and treats a leading dot as part of the name. An example
  // that drifts from the engine is worse than no example.
  function test_keep_both_names() {
    compare(w.keepBothAs("report.txt"), "report-2.txt")
    compare(w.keepBothAs("archive.tar.gz"), "archive.tar-2.gz")
    compare(w.keepBothAs("README"), "README-2")
    compare(w.keepBothAs(".bashrc"), ".bashrc-2")
  }

  // Issue 26: noteMutation() used to build these sentences itself, behind an
  // import qmltestrunner cannot load. These are the same functions it now
  // calls, given the same plain data it has at each call site.

  function test_trash_phrase_names_one_file() {
    var r = w.trashPhrase([{ path: "/tmp/a/one.txt" }])
    compare(r.text, "one.txt moved to trash — Ctrl+Z to put it back")
    compare(r.role, "ok")
  }

  function test_trash_phrase_counts_several() {
    var r = w.trashPhrase([{ path: "/a" }, { path: "/b" }])
    compare(r.text, "2 items moved to trash — Ctrl+Z to put them back")
  }

  function test_permanent_phrase_names_the_folder_it_left() {
    var r = w.permanentPhrase(["/mnt/share/one.txt"])
    compare(r.text, "one.txt deleted permanently from share — it is gone for good")
    compare(r.role, "bad")
  }

  function test_rename_phrase_undo_reads_differently_from_the_original() {
    compare(w.renamePhrase("/a/renamed.txt", false).text,
            "Renamed to renamed.txt — Ctrl+Z to change it back")
    compare(w.renamePhrase("/a/original.txt", true).text,
            "Name put back to original.txt")
  }

  // Watched failing on screen 2026-09-08: a skipped MOVE once said "Nothing
  // copied", because the label was hard-coded rather than taken from the
  // request. `tier` here stands in for what the daemon actually sends.
  function test_skipped_phrase_repeats_the_daemons_own_verb() {
    var moved = t.job("x.txt", 0, 1, 1)
    moved.tier = "Nothing moved"
    moved.destination = "/tmp/dst"
    compare(w.skippedPhrase(moved, false).text,
            "Nothing moved — it was already in dst")
  }

  function test_skipped_phrase_undone_says_nothing_was_put_back() {
    var j = { label: "x.txt", destination: "/tmp/dst" }
    compare(w.skippedPhrase(j, true).text,
            "Nothing put back — x.txt is already in dst, and you left it alone")
  }

  function test_move_phrase_names_replacements() {
    var j = t.job("2 files", 2, 2, 0)
    j.destination = "/tmp/dst"
    j.files_replaced = 1
    compare(w.movePhrase(j, false).text, "Moved 2 files to dst — 1 replaced")
  }

  // The bug this was written to catch: counted from what landed, not from
  // what was asked for.
  function test_copy_phrase_counts_what_landed_not_the_label() {
    var j = t.job("4 files", 3, 4, 1)
    j.destination = "/tmp/dst"
    j.files_replaced = 0
    j.tier = "Size checked"
    compare(w.copyPhrase(j).text,
            "Copied 3 files to dst — 1 left alone · Size checked")
  }
}
