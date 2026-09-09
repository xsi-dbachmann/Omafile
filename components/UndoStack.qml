pragma ComponentBehavior: Bound

import QtQuick

// What can be taken back, and how.
//
// ADR 0009: a session stack, held in memory, gone when Omafile closes. A
// durable undo history would be a record of what you copied and deleted, which
// is exactly what the no-history decision ruled out.
//
// What is undoable, and what is deliberately not:
//   move       reversible — move it back
//   rename     reversible — rename it back
//   delete     reversible only when it went to the trash, not when permanent
//   copy       NOT offered. Reversing a copy means deleting what was written,
//              which is destructive rather than restorative, so it is presented
//              as a delete instead of hidden behind the word "undo".
//
// Every mutation must pass through App.qml's noteMutation(), which has a case
// per kind and warns on an unknown one. Rename shipped without an undo entry
// because nothing forced that decision to be made; this is that force.
//
// An entry is not removed when the undo is *asked for* — only when the daemon
// says it happened. pop() used to run before anything had been attempted, so
// Ctrl+Z with the daemon down ate the top of the stack and said nothing.
//
// Every entry carries three strings:
//   payload    what it is about — "report.pdf" or "5 items"
//   label      what pressing the button does — "Put report.pdf back"
//   busyLabel  the same, while it is on its way — "Putting report.pdf back…"
QtObject {
  id: undo

  property var entries: []
  /// True while the top entry is being carried out. Nothing else may be undone
  /// until the daemon has answered for it.
  property bool busy: false

  /// There is something on the stack — the button is drawn.
  readonly property bool hasEntries: entries.length > 0
  /// …and it can be pressed. These are separate because an undo in flight must
  /// keep its place in the bar and report itself, not vanish and come back.
  readonly property bool canUndo: entries.length > 0 && !busy
  readonly property string nextLabel: entries.length === 0
    ? ""
    : (busy ? entries[entries.length - 1].busyLabel : entries[entries.length - 1].label)

  function push(entry) {
    var next = entries.slice()
    next.push(entry)
    // A session stack, not an archive. Deep enough for real mistakes, bounded
    // so a long session cannot grow it without limit.
    if (next.length > 50) next.shift()
    entries = next
  }

  /// `destinationDir` is where it went; `sourceDir` is where it came from, so
  /// undo can ask for the reverse transfer in the same terms the engine takes.
  /// `landedName` is the bare name the file actually committed under, which is
  /// NOT the name that was asked for when the conflict policy was Keep both —
  /// a move of `report.txt` onto an occupied name lands as `report-2.txt`.
  /// Recording the asked-for name would make Ctrl+Z move `report.txt`: a
  /// different file, the one the user just chose to keep.
  function recordMove(source, destinationDir, landedName) {
    var name = String(landedName || "").length > 0
      ? String(landedName)
      : String(source).split("/").pop()
    push({
      kind: "move",
      payload: name,
      label: "Move " + name + " back",
      busyLabel: "Moving " + name + " back…",
      source: source,
      sourceDir: String(source).replace(/\/[^/]*$/, ""),
      destination: String(destinationDir) + "/" + name
    })
  }

  /// One confirmation is one entry.
  ///
  /// Deleting five files pushed five entries, so the "You can put this back
  /// with Ctrl+Z" the dialog had just promised put *one* file back and left
  /// four in the trash — and four more presses were needed to find that out.
  /// `items` are `{ path, trashedAs, info }`, one per file that actually
  /// reached the trash.
  function recordTrashBatch(items) {
    if (!items || items.length === 0) return
    var payload = items.length === 1
      ? String(items[0].path).split("/").pop()
      : items.length + " items"
    push({
      kind: "trash",
      payload: payload,
      label: "Put " + payload + " back",
      busyLabel: "Putting " + payload + " back…",
      items: items
    })
  }

  /// `to` is where the file is now; `originalName` is the bare name to put
  /// back. Undo asks the daemon to rename it back, and the daemon's collision
  /// check applies — if something has taken the old name in the meantime, the
  /// refusal surfaces rather than one file quietly replacing another.
  function recordRename(to, originalName) {
    push({
      kind: "rename",
      payload: originalName,
      label: "Rename back to " + originalName,
      busyLabel: "Renaming back to " + originalName + "…",
      path: to,
      originalName: originalName
    })
  }

  /// What the next Ctrl+Z would act on, without committing to acting on it.
  function peek() { return entries.length === 0 ? null : entries[entries.length - 1] }

  /// The entry currently being carried out, held by identity rather than by
  /// position. Nothing stops a new mutation being recorded while an undo is in
  /// flight, and a positional `pop()` would then spend the wrong entry.
  property var inFlight: null

  /// Mark the top entry as being carried out. It stays on the stack: until the
  /// daemon has actually done it, removing it would be a claim.
  function begin() {
    if (entries.length === 0) return
    inFlight = entries[entries.length - 1]
    busy = true
  }

  /// Spend one named entry, wherever it sits, without disturbing the top.
  ///
  /// The stack's other operations all act on "the top" or on "the one in
  /// flight". Neither is any use to a reply that arrives after the window has
  /// given up waiting: `release()` has already cleared `inFlight`, so a
  /// `commit()` then would fall through to `pop()` and spend whatever happens
  /// to be on top — a different entry, describing a different file. That is
  /// the shape of historical bug #6, and it is why issue 22 was left open
  /// rather than fixed with the operations that existed.
  ///
  /// Returns the entry if it was still on the stack, or null if it had already
  /// gone — the caller must treat "already spent" as an ordinary outcome, not
  /// an error.
  function retire(entry) {
    if (!entry) return null
    var next = []
    var removed = null
    for (var i = 0; i < entries.length; i++) {
      if (!removed && entries[i] === entry) { removed = entries[i]; continue }
      next.push(entries[i])
    }
    if (!removed) return null
    entries = next
    return removed
  }

  /// It happened — that exact entry is spent, wherever it now sits.
  function commit() {
    busy = false
    var target = inFlight
    inFlight = null
    if (!target) return pop()
    return retire(target)
  }

  /// It did not happen. Put the entry back within reach rather than losing it
  /// to a refusal, a failure, or a conflict answer of "leave it alone".
  function release() { busy = false; inFlight = null }

  function pop() {
    if (entries.length === 0) return null
    var next = entries.slice()
    var top = next.pop()
    entries = next
    return top
  }

  function clear() { entries = []; busy = false }
}
