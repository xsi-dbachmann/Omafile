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

  // Issue 19 item 2. The drag label is the ONE place ADR 0012's rule — a drag is
  // always a copy — can still change somebody's mind; the notice that carried it
  // arrived after the drop, when the copy had already been asked for.
  function test_drag_phrase_names_one_file_and_says_copy() {
    var d = w.dragPhrase(["/tmp/a/photo.jpg"], false, "")
    compare(d.text, "Copy photo.jpg")
    compare(d.blocked, false)
  }

  // Aimed at a pane, the label names where it would land. The destination is the
  // half the pane wash cannot say in words.
  function test_drag_phrase_names_the_destination_once_it_has_one() {
    compare(w.dragPhrase(["/tmp/a/photo.jpg"], false, "Downloads").text,
            "Copy photo.jpg to Downloads")
  }

  function test_drag_phrase_counts_several() {
    compare(w.dragPhrase(["/a/1", "/a/2", "/a/3"], false, "Downloads").text,
            "Copy 3 files to Downloads")
  }

  // Rank 7, before the drop rather than after it: dragging a folder does nothing
  // at all in this version, and the label is where that gets said while the
  // button is still down.
  function test_drag_phrase_refuses_a_folder_before_the_drop() {
    var d = w.dragPhrase([], true, "Downloads")
    compare(d.text, "Folders are not transferred in this version")
    compare(d.blocked, true)
  }

  function test_drag_phrase_refuses_an_empty_drag() {
    var d = w.dragPhrase([], false, "Downloads")
    compare(d.text, "Nothing to copy")
    compare(d.blocked, true)
  }

  // The project's signature defect, in the shape it takes here: `selectedPaths()`
  // drops directories, so a selection of two files and a folder copies TWO, and
  // a label counting the selection would promise three. It counts what would
  // land, and says what would not.
  function test_drag_phrase_counts_what_would_land_not_what_is_selected() {
    var d = w.dragPhrase(["/a/1", "/a/2"], true, "Downloads")
    compare(d.text, "Copy 2 files to Downloads — folders are left behind")
    compare(d.blocked, false)
  }

  // Issue 38. First run sends the user to a terminal twice, and the plugin knew
  // only "cannot connect" -- one sentence for three situations, two of which
  // have a specific thing to do about them.
  //
  // `systemctl --user is-enabled omafiled.socket` separates all three on its
  // own: `not-found` when the unit file is absent, which is exactly "the
  // package is not installed" because the unit ships in it. Checked, not
  // assumed: rc 4 / `not-found` on this machine 2026-09-09. So there is no
  // second `test -x /usr/bin/omafiled` -- that would be a second way to ask one
  // question, and two gates to keep in agreement is this project's signature
  // defect.
  function test_first_run_not_installed_joins_both_commands() {
    var h = w.firstRunHelp("not-found", "/home/x/.config/omarchy/plugins/omafile")
    compare(h.note, "omafiled is not installed — browsing only")
    compare(h.command,
            "cd /home/x/.config/omarchy/plugins/omafile/packaging && makepkg -si"
            + " && systemctl --user enable --now omafiled.socket")
  }

  // The half that needs nothing: no sudo, no polkit, no tty.
  function test_first_run_installed_but_not_enabled_offers_only_the_second_half() {
    var h = w.firstRunHelp("disabled", "/plug")
    compare(h.note, "omafiled is installed, but its socket is not enabled")
    compare(h.command, "systemctl --user enable --now omafiled.socket")
  }

  // `enable` on a masked unit fails, and a copied command that fails is worse
  // than no button: it looks like the product is broken rather than the unit.
  function test_first_run_masked_unmasks_first() {
    compare(w.firstRunHelp("masked", "/plug").command,
            "systemctl --user unmask omafiled.socket"
            + " && systemctl --user enable --now omafiled.socket")
  }

  // Enabled and still not answering is not a first-run problem at all, so it
  // must not offer a first-run command. Diagnosis, not a fix: what is wrong is
  // not known from here, and `restart` would be a guess dressed as advice.
  function test_first_run_enabled_but_silent_offers_diagnosis_not_a_fix() {
    var h = w.firstRunHelp("enabled", "/plug")
    compare(h.note, "omafiled's socket is enabled but nothing is answering")
    compare(h.command, "systemctl --user status omafiled.socket")
  }

  // Before the check has answered, and if it never answers. Vague in every
  // state because it is correct in every state -- the sentence that was there
  // before any of this existed.
  function test_first_run_unknown_falls_back_to_naming_both_halves() {
    var h = w.firstRunHelp("", "/plug")
    compare(h.note, "omafiled not running — browsing only")
    compare(h.command,
            "cd /plug/packaging && makepkg -si"
            + " && systemctl --user enable --now omafiled.socket")
  }

  // `static` and `enabled-runtime` are systemd's other affirmative answers.
  // Treating them as "not enabled" would offer a button that does nothing.
  function test_first_run_treats_systemd_other_affirmatives_as_enabled() {
    compare(w.firstRunHelp("static", "/plug").note,
            "omafiled's socket is enabled but nothing is answering")
    compare(w.firstRunHelp("enabled-runtime", "/plug").note,
            "omafiled's socket is enabled but nothing is answering")
  }

  // Issue 19 item 4b, watched on screen 2026-09-09: the pane column read
  // `2.9 MB` for the file whose transfer-panel row, in the same window, read
  // `3000000 bytes, exactly as expected`. Binary maths under a decimal label.
  // The two numbers describe one file and now agree.
  function test_a_size_is_decimal_so_it_agrees_with_the_exact_byte_count() {
    compare(w.sizePhrase(3000000), "3.0 MB")
    compare(w.sizePhrase(50000), "50 KB")     // was `49 KB`
    compare(w.sizePhrase(2500000000), "2.5 GB")
    compare(w.sizePhrase(1500000000000), "1.5 TB")
  }

  // Under a thousand there is no arithmetic to get wrong, so the exact count
  // is what is shown -- and 1000 is where the first unit starts, not 1024.
  function test_small_sizes_are_the_bytes_themselves() {
    compare(w.sizePhrase(0), "0 B")
    compare(w.sizePhrase(999), "999 B")
    compare(w.sizePhrase(1000), "1.0 KB")
  }

  // 999,950 bytes is 999.95 KB, which ROUNDS to a number its own unit cannot
  // hold. The rounding is what the user reads, so it picks the unit.
  function test_a_size_that_rounds_up_takes_the_next_unit() {
    compare(w.sizePhrase(999950), "1.0 MB")
  }

  // TB is the last unit, so a number too big for it stays in it rather than
  // running off the end of the array as `undefined`.
  function test_a_size_past_the_last_unit_stays_in_it() {
    compare(w.sizePhrase(5000000000000000), "5000 TB")
  }

  // A directory row and a stat that failed both arrive here. Neither is a
  // size, and "NaN B" in the column would be a claim about a file.
  function test_what_is_not_a_size_says_nothing() {
    compare(w.sizePhrase(-1), "")
    compare(w.sizePhrase("nonsense"), "")
    compare(w.sizePhrase(undefined), "")
  }

  // Issue 19 item 3. The notice had a flat 6s: tuned for dismissal, never for
  // reading. 50 characters still gets exactly that, so the short notices the
  // constant was chosen around are unchanged.
  function test_a_fifty_character_notice_keeps_the_old_six_seconds() {
    var s = "12345678901234567890123456789012345678901234567890"
    compare(s.length, 50)
    compare(w.noticeLifeMs(s), 6000)
  }

  // A floor, so a two-word refusal does not flicker, and a ceiling, so the bar
  // never becomes the status line the timer exists to prevent.
  function test_a_notice_life_has_a_floor_and_a_ceiling() {
    compare(w.noticeLifeMs("Cancelled"), 4000)
    compare(w.noticeLifeMs(""), 4000)
    compare(w.noticeLifeMs(new Array(400).join("x")), 14000)
  }

  // The sentence the complaint was actually about -- built here rather than
  // written out, so it cannot drift from what `copyPhrase()` produces. It is
  // longer than the old constant was tuned for, and now outlives it.
  function test_the_completion_sentence_outlives_the_old_six_seconds() {
    var j = t.job("4 files", 3, 4, 1)
    j.destination = "/home/me/Documents"
    j.tier = "Size checked"
    j.files_replaced = 0
    var text = w.copyPhrase(j).text
    verify(text.length > 50)
    verify(w.noticeLifeMs(text) > 6000)
  }

  // Issue 04 -- the filter strip counted rows the filter never applied to.
  // FolderListModel.nameFilters does not filter directories, so the count has
  // to be of files. It is deliberately short: the longer version that also
  // named the folders squeezed the TextInput beside it to nothing at the 720
  // minimum, which is ADR 0014's collision in a second control.

  function test_filter_counts_files_not_rows() {
    // The reproduction: "zzz" in a directory of four files and one folder.
    // The old strip said "1 shown", counting the folder it had not filtered.
    compare(w.filterPhrase(0), "0 files match")
  }

  function test_filter_one_file_is_singular_and_agrees_with_its_verb() {
    compare(w.filterPhrase(1), "1 file matches")
  }

  function test_filter_counts_several() {
    compare(w.filterPhrase(4), "4 files match")
  }

  function test_filter_what_is_not_a_count_says_nothing() {
    // Same rule as sizePhrase beside it: a value that is not a number says
    // nothing. Deliberately not `""`, which Number() makes 0 -- sizePhrase
    // reads it as zero too, and one guard behaving two ways in one file is
    // worse than either behaviour.
    compare(w.filterPhrase("nonsense"), "")
    compare(w.filterPhrase(undefined), "")
    compare(w.filterPhrase(-1), "")
  }
}
