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
}
