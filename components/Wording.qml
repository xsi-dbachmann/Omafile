pragma ComponentBehavior: Bound

import QtQuick

// The product's sentences, or the parts of them that are arithmetic.
//
// This project's mistakes cluster here. `Copied 4 files` was said for a Job that
// copied three and left one alone; `Nothing copied` was said for a move; a
// Keep-both landing was named by the file that was asked for rather than the one
// that arrived. Every one of them was a phrase built from the wrong number, and
// every one was found by a person reading a screen.
//
// So the phrases live in a `QtObject` that imports **QtQuick and nothing else**,
// which is the whole point: `qmltestrunner` can hold this, and cannot hold
// anything that imports `qs.Commons`, because Quickshell's modules are compiled
// into the `quickshell` binary's own resources and no other process can load
// them. Keeping a computation free of the theme is what makes it checkable
// without a display — see `tests/qml/tst_wording.qml`.
QtObject {
  id: wording

  /// The folder a path or a directory path is in, as the panes name it.
  function folderName(dirPath) {
    var d = String(dirPath).replace(/\/+$/, "")
    var n = d.substring(d.lastIndexOf("/") + 1)
    return n !== "" ? n : (d !== "" ? d : "/")
  }

  /// What a Job actually landed, phrased the way its label is.
  ///
  /// `label` is what was *asked for* — "4 files" — and using it to report what
  /// happened is how a Job that copied three of four came to say "Copied 4
  /// files". The daemon already draws this distinction (`Tally::files_done`
  /// counts what arrived, "not the loop index"); the sentence in the bar did
  /// not, which is this project's signature defect in its usual shape: one place
  /// taught, its reader left alone.
  ///
  /// The label is kept when nothing was left behind, because it names the file
  /// rather than counting it, and a name is the more useful sentence.
  function landedPhrase(info) {
    var done = Number(info.files_done)
    var left = Number(info.files_skipped_existing) || 0
    if (!(done >= 0) || left === 0) return String(info.label)
    return done + (done === 1 ? " file" : " files")
  }

  /// The files a policy of "skip" left where they were, said out loud. The panel
  /// row carries it too; the bar is where the reader is looking.
  function leftAlonePhrase(info) {
    var left = Number(info.files_skipped_existing) || 0
    return left > 0 ? " — " + left + " left alone" : ""
  }

  /// What "Keep both" actually produces, in the engine's own shape:
  /// `free_name_beside()` numbers from -2 upward and treats a leading dot as
  /// part of the name rather than an extension. The conflict dialog's button has
  /// no room for a sentence, so its body says it, and this keeps the example
  /// true — an example that drifts from the engine is worse than none.
  function keepBothAs(name) {
    var n = String(name)
    var dot = n.lastIndexOf(".")
    return dot > 0 ? n.substring(0, dot) + "-2" + n.substring(dot) : n + "-2"
  }

  // The sentence half of every mutation `App.qml::noteMutation()` handles.
  //
  // Issue 26: `qmltestrunner` can hold exactly what does not import `qs.*`, and
  // `noteMutation()` used to decide both the sentence AND the undo recording in
  // one function, which put the phrasing behind an import no headless runner
  // can load. These six take the same plain data `noteMutation()` already has
  // — a Job, a path list, a name — and return the `{ text, role }` it hands to
  // `setNotice()`, with nothing else threaded through. `noteMutation()` keeps
  // the recording calls (`undoStack.record...`), because deciding whether a
  // mutation is undoable is a decision *about the undo stack*, not a sentence.

  function trashPhrase(items) {
    var trashed = items.length === 1
      ? String(items[0].path).split("/").pop()
      : items.length + " items"
    return { text: trashed + " moved to trash — Ctrl+Z to put "
                   + (items.length === 1 ? "it" : "them") + " back",
             role: "ok" }
  }

  // Deliberately not undoable (ADR 0009): it is gone, and saying otherwise
  // would be the lie the confirmation exists to prevent.
  function permanentPhrase(paths) {
    var goneCount = paths.length
    var gone = goneCount === 1 ? String(paths[0]).split("/").pop() : goneCount + " items"
    return { text: gone + " deleted permanently from "
                   + folderName(String(paths[0]).replace(/\/[^/]*$/, ""))
                   + " — " + (goneCount === 1 ? "it is" : "they are") + " gone for good",
             role: "bad" }
  }

  function renamePhrase(to, undone) {
    var newName = String(to).split("/").pop()
    return { text: undone
                   ? ("Name put back to " + newName)
                   : ("Renamed to " + newName + " — Ctrl+Z to change it back"),
             role: "ok" }
  }

  function movePhrase(info, undone) {
    var movedTo = folderName(info.destination)
    return { text: (undone ? ("Put " + landedPhrase(info) + " back in " + movedTo)
                           : ("Moved " + landedPhrase(info) + " to " + movedTo))
                   + leftAlonePhrase(info)
                   + (info.files_replaced > 0 ? " — " + info.files_replaced + " replaced" : ""),
             role: "ok" }
  }

  // A Job where nothing was transferred is not a silent no-op.
  function skippedPhrase(info, undone) {
    if (undone)
      return { text: "Nothing put back — " + info.label + " is already in "
                     + folderName(info.destination) + ", and you left it alone",
               role: "warn" }
    // The daemon's word, not one chosen here (server.rs, Tally::is_move):
    // hard-coding "Nothing copied" told a user who had asked for a move that a
    // copy had not happened, watched on screen 2026-09-08.
    return { text: (info.tier || "Nothing transferred") + " — "
                   + (info.files_total === 1 ? "it was" : "all " + info.files_total + " were")
                   + " already in " + folderName(info.destination),
             role: "warn" }
  }

  // Deliberately not undoable: reversing a copy is a delete (ADR 0009). Counted
  // from what landed, not from what was asked for — a Job that copied three of
  // four once said "Copied 4 files", the fourth mentioned nowhere.
  function copyPhrase(info) {
    return { text: "Copied " + landedPhrase(info) + " to " + folderName(info.destination)
                   + leftAlonePhrase(info)
                   + (info.files_replaced > 0 ? " — " + info.files_replaced + " replaced" : "")
                   + (info.tier ? " · " + info.tier : ""),
             role: "ok" }
  }

  /// The label that follows the cursor during a drag (issue 19 item 2).
  ///
  /// ADR 0012 makes a drag *always* a copy, and until this existed that rule was
  /// stated only in the notice that appears **after** the drop — by which time
  /// the Job has been asked for and the mind that might have been changed has
  /// nothing left to change. The label is the rule's only chance to be read in
  /// time.
  ///
  /// `paths` is what would actually land: `DirPane::selectedPaths()` drops
  /// directories, so a selection of two files and a folder copies two. Counting
  /// the selection instead would promise three, which is this project's
  /// signature defect wearing a new hat — so `hadFolder` says what is being left
  /// behind rather than letting the number quietly disagree with the screen.
  ///
  /// `blocked` is for a drag that can do nothing *wherever* it is dropped, which
  /// is a different thing from one that is merely not aimed at a pane yet.
  function dragPhrase(paths, hadFolder, destName) {
    var n = paths.length
    if (n === 0)
      return { text: hadFolder ? "Folders are not transferred in this version"
                               : "Nothing to copy",
               blocked: true }
    var what = n === 1 ? String(paths[0]).split("/").pop() : n + " files"
    return { text: "Copy " + what
                   + (destName !== "" ? " to " + destName : "")
                   + (hadFolder ? " — folders are left behind" : ""),
             blocked: false }
  }

  /// What to say, and what to put on the clipboard, when there is no daemon
  /// to talk to (issue 38).
  ///
  /// The complaint was *"it is strange for user that he needs to run a daemon
  /// by hand, bad ux"*, and the useful part of it is narrower than it sounds:
  /// in normal operation nobody runs a daemon by hand, because the socket unit
  /// starts it (ADR 0005). What the session actually hit was **first run**, and
  /// first run is two commands with completely different privilege profiles —
  /// one needs root to put a binary in a system path, the other touches only
  /// the user's own systemd instance.
  ///
  /// The plugin used to know none of that. It knew "cannot connect", and said
  /// one sentence naming both commands for all three situations.
  ///
  /// `state` is `systemctl --user is-enabled omafiled.socket`, trimmed, and it
  /// separates all three by itself. `not-found` means the unit file is absent,
  /// which IS "the package is not installed" because the unit ships inside it —
  /// so there is deliberately no second `test -x /usr/bin/omafiled`. Two ways
  /// to ask one question is two gates to keep in agreement, and this project
  /// has found nine instances of one place taught and its reader left alone.
  ///
  /// **Nothing here runs anything.** The command is copied, not executed: the
  /// friction worth removing is typing a long line correctly, not the decision
  /// to run it, and a copied command that fails teaches the user something
  /// where a button that silently fails does not. ADR 0006's "the plugin
  /// instructs, never installs" therefore stands unamended — this is the
  /// instruction, made pasteable.
  function firstRunHelp(state, pluginDir) {
    var s = String(state)
    var enableNow = "systemctl --user enable --now omafiled.socket"
    var bothHalves = "cd " + pluginDir + "/packaging && makepkg -si && " + enableNow

    if (s === "not-found")
      return { note: "omafiled is not installed — browsing only", command: bothHalves }

    // systemd's affirmative answers, plural. Treating `static` or
    // `enabled-runtime` as "not enabled" would offer a button that does
    // nothing, which is the rank 7 rule this product keeps rediscovering.
    if (s === "enabled" || s === "enabled-runtime" || s === "static" || s === "indirect"
        || s === "alias" || s === "generated")
      return { note: "omafiled's socket is enabled but nothing is answering",
               // Diagnosis, not a fix. What is wrong is not known from here, and
               // `restart` would be a guess wearing the clothes of advice.
               command: "systemctl --user status omafiled.socket" }

    // `enable` on a masked unit fails. Offering it anyway would make the
    // product look broken instead of the unit.
    if (s === "masked" || s === "masked-runtime")
      return { note: "omafiled's socket is masked", command:
               "systemctl --user unmask omafiled.socket && " + enableNow }

    if (s !== "")
      return { note: "omafiled is installed, but its socket is not enabled",
               command: enableNow }

    // Not asked yet, or `systemctl` said nothing at all. The sentence that was
    // here before any of this existed: vague in every state, because it is
    // correct in every state.
    return { note: "omafiled not running — browsing only", command: bothHalves }
  }

  /// A byte count, in the units the panes label it with (issue 19 item 4b).
  ///
  /// **Decimal, deliberately.** The form this replaces divided by 1024 and
  /// labelled the result `KB`/`MB`, so a 3,000,000-byte file rendered `2.9 MB`
  /// in the pane while the transfer panel beside it read `3000000 bytes,
  /// exactly as expected` — two numbers describing one file, disagreeing on
  /// screen, in a product whose whole argument is that it tells you the truth
  /// about bytes. Either half could have been fixed: `MiB` would have been just
  /// as true. The maths moved instead, because the exact byte count is what a
  /// reader reconciles this against, and `3.0 MB` reconciles by eye where
  /// `2.9 MiB` needs a lesson in powers of two first — and a third character in
  /// a 52px column (ADR 0014).
  ///
  /// Here rather than in `DirPane` because a division that decides what the
  /// user believes about a file's size is arithmetic, and arithmetic is what
  /// `qmltestrunner` can hold. The pane keeps `humanSize()`, the name its call
  /// sites already use; this decides what it answers.
  function sizePhrase(bytes) {
    var b = Number(bytes)
    if (!isFinite(b) || b < 0) return ""
    if (b < 1000) return b + " B"
    var units = ["KB", "MB", "GB", "TB"]
    var i = -1
    do { b = b / 1000; i++ } while (b >= 1000 && i < units.length - 1)
    var digits = b < 10 ? 1 : 0
    // 999,950 bytes is 999.95 KB, which rounds *for display* to `1000 KB` — a
    // number the next unit up exists to say. The rounding is what the user
    // reads, so the unit is chosen after it rather than before.
    if (Number(b.toFixed(digits)) >= 1000 && i < units.length - 1) {
      b = b / 1000
      i++
      digits = 1
    }
    return b.toFixed(digits) + " " + units[i]
  }

  /// How long a notice stays on screen, in milliseconds (issue 19 item 3).
  ///
  /// It was a flat 6000 for every string the bar writes. That constant was
  /// tuned for *dismissal* — the defect it fixed was a present-tense sentence
  /// that never cleared — and nothing ever tuned it for *reading*. The
  /// completion notice is the longest sentence the product writes, and on
  /// 2026-09-08 the first person to drive the UI could not finish it: *"message
  /// disappeared shortly after, could not manage to get exact message read."*
  ///
  /// So the string's own length decides. ~80ms a character is about 150 words a
  /// minute, which is reading-off-a-screen speed rather than prose speed. The
  /// floor keeps a two-word refusal from flickering; the ceiling keeps the bar
  /// from becoming the status line the timer exists to prevent. 50 characters
  /// lands on exactly 6000, so the short notices the old constant was chosen
  /// around are unchanged and only the long ones stay longer.
  ///
  /// The alternative was pausing on hover, which asks the reader to reach for
  /// the mouse to finish a sentence — no help at all to the keyboard user this
  /// product is for.
  function noticeLifeMs(text) {
    return Math.max(4000, Math.min(14000, 2000 + 80 * String(text || "").length))
  }
}
