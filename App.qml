pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

import "components"
import "prototypes"

// Omafile's window.
//
// Dual-pane, because Omafile's purpose is moving things between two places:
// the destination is a fact of the layout, so the action bar can name both
// ends rather than sending intent through a clipboard (ticket 08). The Job
// list lives in this same window, because the Job is the product's central
// noun (ticket 07).
//
// The window `title` below is part of Omafile's public contract. Every
// Quickshell toplevel shares the Hyprland class `org.quickshell`, so Omarchy's
// window rules discriminate by title and users' rules will match on this
// string. It must not change (ticket 02).
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool closingFromHost: false

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omafile"
  readonly property string homeDir: Quickshell.env("HOME") || "/"

  /// 0 = left, 1 = right. The inactive pane is the destination.
  property int activePane: 0
  /// Persisted — the checksum default used to reset every session; see
  /// `components/Settings.qml`. An alias, not a copy: every write here is a
  /// write there, so nothing has to remember to save it.
  property alias checksum: settings.checksum
  property alias showHidden: settings.showHidden
  property alias showIcons: settings.showIcons
  property alias pinned: settings.pinned

  /// Pin or unpin the pane you are looking at. One key does both, because a
  /// folder is either in the list or it is not and there is nothing to choose.
  function togglePin(path) {
    var i = root.pinned.indexOf(path)
    var next = root.pinned.slice()
    if (i === -1) {
      next.unshift(path)
      // Reassigned whole, never mutated in place: a JS array mutated behind a
      // property's back does not notify, so the sidebar would not redraw and
      // the setting would not save.
      root.pinned = next
      root.setNotice("Pinned " + root.wording.folderName(path), "ok")
    } else {
      next.splice(i, 1)
      root.pinned = next
      root.setNotice("Unpinned " + root.wording.folderName(path), "warn")
    }
  }
  property alias sortField: settings.sortField
  property alias sortReversed: settings.sortReversed

  /// Clicking the sorted column reverses it; clicking another switches to it,
  /// ascending. Reversing on a *switch* would make the same click mean two
  /// things depending on where you last clicked.
  /// `test -d`, not a guess. A typed path that does not exist must not blank
  /// the pane: an empty pane pointed at nothing looks exactly like an empty
  /// directory, and the user would have no way to tell which had happened.
  function checkPath(pane, path) {
    pathCheck.forPane = pane
    pathCheck.candidate = path
    pathCheck.command = ["test", "-d", path]
    pathCheck.running = true
  }

  function sortBy(field) {
    if (root.sortField === field) root.sortReversed = !root.sortReversed
    else { root.sortField = field; root.sortReversed = false }
  }
  property string proto: ""
  /// The sidebar costs pane width, and dual-pane already made it scarce
  /// (ticket 08). Ctrl+B takes it back.
  property bool showLocations: true
  /// One line of feedback for things that are not Jobs — a delete, an undo, a
  /// refusal. Jobs speak for themselves in the transfer panel.
  ///
  /// Written only through setNotice(). Assigning it directly was how every
  /// line in this bar came to be drawn in the success colour, in the present
  /// tense, and to stay there until the window closed: the string was written
  /// before the daemon was asked anything, nothing ever cleared it, and a
  /// failure looked exactly like a success.
  property string notice: ""
  /// "ok" — it happened and it went well · "warn" — nothing happened, or a
  /// plain fact · "bad" — it failed, or it destroyed something.
  property string noticeRole: "ok"
  /// Bumped on every write, including a write of the same words, so the bar can
  /// show a repeat as a second event.
  property int noticeSeq: 0
  /// The two boundaries the user may now move (ADR 0014). Nothing in the layout
  /// was resizable: the sidebar was 190, the panes an exact 50/50 split and the
  /// divider a 1px rule with no handler on it, so the obvious answer to a
  /// clipped filename — widen that pane — was impossible.
  ///
  /// Deliberately not persisted. A panel-only plugin has no home for settings
  /// yet, and inventing one here would smuggle a second decision in
  /// behind this one.
  property real sidebarWidth: 190
  property real splitFraction: 0.5
  /// The narrowest a pane may be dragged. Below this the columns the panes drop
  /// in a narrow window (size, modified) have already gone and the name itself
  /// starts to elide away to nothing.
  readonly property int minPaneWidth: 220
  readonly property int minSidebarWidth: 120
  readonly property int maxSidebarWidth: 360

  /// `splitFraction` clamped so neither pane can be dragged below the minimum.
  /// When there is not room for two minimums the split is even, because half of
  /// too little is the least bad of the available answers.
  function clampedSplit(available) {
    if (available <= 0) return 0.5
    var m = root.minPaneWidth / available
    if (m >= 0.5) return 0.5
    return Math.max(m, Math.min(1 - m, root.splitFraction))
  }

  /// Which pane a drag started from, so a drop knows the direction. Dropping
  /// onto the pane you dragged from does nothing.
  property int dragFrom: -1
  /// What the drag is carrying, captured **once** when it starts.
  ///
  /// Not recomputed per pointer move: `DirPane::selectedPaths()` walks the whole
  /// `FolderListModel`, and doing that on every frame of a drag over a large
  /// directory is precisely the UI-thread cost ticket 12 measured and forbade.
  /// Capturing also makes the label and the Job the *same* list rather than two
  /// walks that agree by luck — `dropOnto` reads these, not the pane.
  property var dragPaths: []
  property bool dragHadFolder: false
  /// The folder a release would land in, or "" when the pointer is not over a
  /// pane that would accept it. Empty is a normal state on the way somewhere,
  /// not a refusal.
  property string dragDest: ""
  property real dragPointerX: 0
  property real dragPointerY: 0
  /// The drag ghost stays hidden until the pointer has actually reported a
  /// position. `dragStarted` and the first `dragMoved` are separate events, and
  /// drawing between them puts the label in the window's top-left corner for a
  /// frame.
  property bool dragPointerSeen: false
  readonly property var dragLabel: root.wording.dragPhrase(root.dragPaths, root.dragHadFolder,
                                                           root.dragDest)
  /// A transfer waiting on a conflict answer: what to send once we have one.
  /// One slot, and now one at a time — see beginTransfer.
  property var pendingTransfer: null
  /// The request id of the undo currently on its way to the daemon, and, once
  /// the daemon has taken it, the Job it became. Both -1 / "" when no undo is
  /// in flight.
  ///
  /// Undo used to be invisible to the reply handlers, so the reverse move and
  /// the reverse rename were recorded as fresh mutations: Ctrl+Z twice was a
  /// toggle and the stack could never be walked back. A flag alone would be
  /// wrong — an ordinary transfer finishing while an undo is running would be
  /// swallowed by it — so the reply is matched by id.
  property int undoRequestId: -1
  property string undoJobId: ""

  /// Undos we have stopped waiting for, but which the daemon may still answer.
  ///
  /// A liveness drop means *silence*, not death: the daemon can be paused, or
  /// merely slow, and its reply can land afterwards — by which time it has
  /// already done the work. The release path used to clear the two id fields
  /// above and nothing else, so that late reply arrived unrecognised and was
  /// recorded as a **fresh mutation**: a second entry pointing the other way,
  /// on top of the released original, and Ctrl+Z was a toggle again — the exact
  /// bug rank 4a exists to kill.
  ///
  /// Watched on screen 2026-09-08 with a proxy holding the daemon's replies for
  /// eight seconds: probe.txt → renamed.txt → probe.txt → renamed.txt, forever.
  /// Keeping the ids is what lets a late answer be recognised as the answer to
  /// an undo rather than as something the user just did.
  /// Each record is `{ id, entry }` or `{ job, entry }`: the handle the reply
  /// will arrive under, and **the stack entry it belongs to**. The entry is
  /// carried because the id alone only ever answered "was this an undo?", and
  /// the answer that matters is "which offer does this retire?" — see issue 22
  /// and `UndoStack.retire()`. `release()` has already cleared `inFlight` by
  /// the time the late reply lands, so there is nothing else left holding it.
  property var abandonedUndos: []
  property var abandonedUndoJobs: []

  /// Restore batches given up on, `{ batch, entry }`. A trash undo is several
  /// requests answered one at a time, so its late replies have to be tallied
  /// rather than matched one-for-one.
  property var abandonedRestores: []

  /// The record for an undo we gave up on — and forgets it, so a Job id can
  /// take its place and a repeat cannot match twice. Null when `id` was not one.
  function takeAbandonedRequest(id) {
    for (var i = 0; i < root.abandonedUndos.length; i++) {
      if (root.abandonedUndos[i].id !== id) continue
      var rec = root.abandonedUndos[i]
      var next = root.abandonedUndos.slice()
      next.splice(i, 1)
      root.abandonedUndos = next
      return rec
    }
    return null
  }
  function takeAbandonedJob(jobId) {
    for (var i = 0; i < root.abandonedUndoJobs.length; i++) {
      if (root.abandonedUndoJobs[i].job !== jobId) continue
      var rec = root.abandonedUndoJobs[i]
      var next = root.abandonedUndoJobs.slice()
      next.splice(i, 1)
      root.abandonedUndoJobs = next
      return rec
    }
    return null
  }

  /// Issue 28: which finished Jobs are safe for the daemon to forget.
  ///
  /// A Job qualifies only once nothing could still need to learn its outcome
  /// through a reconnect's `state` snapshot — the mechanism issues 22/24 built.
  /// That rules out an in-flight Job (no outcome to learn yet) and one this
  /// window is still waiting to hear back from after a liveness drop
  /// (`undoJobId`, `abandonedUndoJobs`): releasing either would mean a late
  /// `finished`/`failed` for it can never reach this window at all, because the
  /// daemon's own registry — not the live event stream — is what a reconnect's
  /// snapshot is built from.
  readonly property var dismissableJobIds: {
    var ids = []
    for (var i = 0; i < daemon.jobs.length; i++) {
      var j = daemon.jobs[i]
      if (!j || (!j.error && !j.tier)) continue
      if (j.job === root.undoJobId) continue
      var awaited = false
      for (var k = 0; k < root.abandonedUndoJobs.length; k++) {
        if (root.abandonedUndoJobs[k].job === j.job) { awaited = true; break }
      }
      if (!awaited) ids.push(j.job)
    }
    return ids
  }

  /// Drop one Job's TransferPanel row and tell the daemon it can forget the
  /// Job too. A row not in `dismissableJobIds` is refused rather than trusted
  /// blindly — `TransferPanel` only draws the control this calls from when a
  /// row is in that list, but a stale click (the list changed underneath it)
  /// must not race an in-flight undo out of the registry.
  function dismissJob(jobId) {
    if (root.dismissableJobIds.indexOf(jobId) === -1) return
    daemon.jobs = daemon.jobs.filter(function (j) { return j.job !== jobId })
    daemon.release(jobId)
  }

  /// Withdraw the offer a late answer has just made untrue, and say so.
  ///
  /// `retire()` returns null when the entry had already gone, which is not an
  /// error and must not be reported as one: the sentence then simply says what
  /// the daemon did, with nothing about the button.
  function retireLate(entry, said) {
    var gone = undoStack.retire(entry)
    root.setNotice(gone ? (said + ", and that undo is no longer offered") : said, "warn")
  }

  /// The only writer of `notice`. `role` is one of "ok", "warn", "bad".
  function setNotice(text, role) {
    root.notice = String(text || "")
    root.noticeRole = role || "ok"
    root.noticeSeq++
    // A notice is the answer to something you just did, not a status line: it
    // has to go away, or the last thing you did is still on screen an hour
    // later, asserted in the present tense.
    if (root.notice === "") noticeLife.stop()
    else {
      // How long it has depends on how much there is to read (issue 19 item 3).
      // Set before the restart, because a Timer reads `interval` when it starts.
      noticeLife.interval = root.wording.noticeLifeMs(root.notice)
      noticeLife.restart()
    }
  }

  Timer {
    id: noticeLife
    // Overwritten on every write by setNotice(), which scales it to the length
    // of the sentence (`Wording::noticeLifeMs()`). This literal is only what a
    // Timer needs to be constructible, and is the value a 50-character notice
    // still gets.
    interval: 6000
    // Through setNotice() like every other write. Clearing the two properties
    // by hand here made this the one exception to the rule the property's own
    // doc comment states, and an exception is how the rule stops being
    // checkable. setNotice("") is exactly this, plus the sequence bump the bar
    // ignores for an empty notice.
    onTriggered: root.setNotice("")
  }

  readonly property var srcPane: activePane === 0 ? leftPane : rightPane
  readonly property var dstPane: activePane === 0 ? rightPane : leftPane

  function open(payloadJson) {
    closingFromHost = false
    proto = ""
    if (payloadJson) {
      try {
        var p = JSON.parse(String(payloadJson))
        if (p && typeof p.proto === "string") proto = p.proto
        if (p && typeof p.left === "string") leftPane.dir = p.left
        if (p && typeof p.right === "string") rightPane.dir = p.right
      } catch (e) { /* ignore */ }
    }
    window.visible = true
    Qt.callLater(function () { browser.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  /// Picked for deletion, waiting on the confirmation dialog. Nothing here has
  /// been sent anywhere yet.
  property var pendingDelete: []

  /// The deletes from one confirmation, and what came back from each.
  ///
  /// The daemon answers per file. Speaking per file meant five identical
  /// notices — an identical string is not a visible change, so five deletes
  /// drew as one — and five undo entries under a dialog that had just promised
  /// one Ctrl+Z. The batch is spoken for once, when the last reply lands.
  property var deleteBatch: null

  /// Ask before deleting, and ask the right question.
  ///
  /// The daemon is asked whether this location can hold a trash *before*
  /// anything is destroyed, so the confirmation can be worded honestly
  /// (ADR 0009). Nothing is deleted until the dialog is accepted.
  function deleteSelection() {
    var paths = srcPane.selectedPaths()
    if (paths.length === 0) {
      // Reachable from the Delete key, which nothing disarms. The menu and
      // the action bar are armed from selectedFileCount(), so from them this
      // line is unreachable -- and a refusal that says nothing is the bug.
      root.setNotice(srcPane.containsDir ? "Folders are not deleted in this version"
                                         : "Pick a file to delete", "warn")
      return
    }
    if (!daemon.canTransfer) { root.setNotice("omafiled is not answering — nothing was deleted", "bad"); return }
    // Checked, like every other _send. This was the one that was not, and the
    // guard above does not cover it: `canTransfer` is inferred from traffic in
    // the last five seconds, so for those five seconds the socket can already
    // be shut while the daemon still reads as live. Delete then set
    // `pendingDelete`, sent nothing, and said nothing — no dialog, no notice,
    // no refusal. Watched on screen 2026-09-08, with a second Delete twenty
    // seconds later proving the keypress was reaching the window at all.
    if (daemon.canTrash(paths[0]) === -1) {
      root.setNotice("omafiled is not answering — nothing was deleted", "bad")
      return
    }
    pendingDelete = paths
  }

  function performPendingDelete() {
    var paths = root.pendingDelete
    root.pendingDelete = []
    if (paths.length === 0) return
    // `total` counts what actually went out, not what was asked for: the batch
    // is only complete when every *sent* delete has answered, and a request the
    // socket refused will never answer at all.
    var b = { asked: paths.length, total: 0, replies: 0, trashed: [], gone: [], errors: [] }
    root.deleteBatch = b
    for (var i = 0; i < paths.length; i++) {
      if (daemon.del(paths[i]) !== -1) b.total++
    }
    if (b.total === 0) {
      root.deleteBatch = null
      root.setNotice("omafiled is not answering — nothing was deleted", "bad")
      return
    }
    srcPane.clearSelection()
  }

  /// Collect one file's answer, and speak for the batch once they are all in.
  function noteDeleted(info) {
    var b = root.deleteBatch
    // A reply nobody asked for: nothing to add it to, and inventing a batch
    // here would put an undo entry behind a delete this window did not start.
    if (!b) return
    b.replies++
    if (info.error !== "") b.errors.push(info.error)
    else if (info.recoverable)
      b.trashed.push({ path: info.path, trashedAs: info.trashedAs, info: info.info })
    else b.gone.push(info.path)
    if (b.replies < b.total) return

    root.deleteBatch = null
    // A batch can in principle produce both kinds. The irreversible one is the
    // sentence that gets said, and a failure outranks them both.
    var said = null
    if (b.trashed.length > 0) said = root.noteMutation("trash", { items: b.trashed })
    if (b.gone.length > 0) said = root.noteMutation("permanent", { paths: b.gone })
    var lost = b.errors.length + (b.asked - b.total)
    if (lost > 0)
      said = { text: lost + " of " + b.asked + " could not be deleted — "
                     + (b.errors.length > 0 ? b.errors[0] : "omafiled stopped answering"),
               role: "bad" }
    if (said) root.setNotice(said.text, said.role)
  }

  /// The phrases that are arithmetic rather than judgement, in a component with
  /// no theme import so `qmltestrunner` can hold it (tests/qml/tst_wording.qml).
  /// `noteMutation()` below is the reason it grew past single phrases: it used
  /// to decide the sentence AND the undo recording for every mutation kind in
  /// one function, which put the sentence half behind an import a headless
  /// runner cannot load (issue 26). `folderName` keeps a thin forwarder because
  /// enough call sites read better as `root.folderName(...)` than as a reach
  /// through an id to justify the one exception.
  property Wording wording: Wording {}

  /// The other QtQuick-only helper, here for the drag ghost's one glyph. The
  /// rows get theirs from `FileRow`'s own instance; a second one costs nothing
  /// and keeps the lookup table in the single place `tests/qml/tst_filekind.qml`
  /// checks it.
  property FileKind fileKinds: FileKind {}

  function folderName(dirPath) { return root.wording.folderName(dirPath) }

  /// Every filesystem mutation passes through here, and every kind must have a
  /// case. Rename shipped without an undo entry because nothing forced the
  /// decision to be made — three separate gaps in this project have had that
  /// shape. An unknown kind now warns instead of silently doing nothing.
  ///
  /// Returns `{ text, role }` for setNotice, or null for mutations that speak
  /// for themselves in the transfer panel. Every sentence is in the past tense
  /// and names the destination: the bar used to end a transfer on a present
  /// participle written before the daemon was asked anything.
  ///
  /// `isUndo` is the second half of the record decision. An undo goes back
  /// through the same daemon calls as the thing it reverses, so without this
  /// the reversal recorded itself and Ctrl+Z became a toggle.
  function noteMutation(kind, info, isUndo) {
    var undone = isUndo === true
    switch (kind) {
    case "trash":
      // One entry for the whole confirmation, so one Ctrl+Z puts back exactly
      // what the dialog said it would.
      if (!undone) undoStack.recordTrashBatch(info.items)
      return root.wording.trashPhrase(info.items)
    case "permanent":
      return root.wording.permanentPhrase(info.paths)
    case "rename":
      if (!undone) undoStack.recordRename(info.to, String(info.from).split("/").pop())
      return root.wording.renamePhrase(info.to, undone)
    case "move":
      // Only a single-file move is recorded: reversing a multi-file move is
      // several transfers and does not belong behind one Ctrl+Z. And a Job that
      // left anything alone is not a clean reversal.
      if (!undone && info.files_total === 1 && info.files_skipped_existing === 0) {
        // Record the name it LANDED under. A Keep-both move lands beside the
        // occupant, so recording the asked-for name would arm a Ctrl+Z that
        // moves the occupant — a file the user never touched and explicitly
        // chose to keep. Without that fact, offer no undo at all: a refusal is
        // recoverable, a wrong put-back is not.
        var landed = root.landedName(info)
        if (landed !== "") undoStack.recordMove(info.source, info.destination, landed)
      }
      return root.wording.movePhrase(info, undone)
    case "skipped":
      return root.wording.skippedPhrase(info, undone)
    case "copy":
      return root.wording.copyPhrase(info)
    default:
      console.warn("omafile: mutation '" + kind + "' has no undo disposition")
      return null
    }
  }

  /// The restores from one trash entry, counted so the entry is only spent
  /// once every file in it has come back.
  property var restoreBatch: null

  /// The bare name a single-file Job committed under, from the daemon's
  /// `landed_as`. Empty when the daemon did not say — an older daemon, or a Job
  /// shape that carries no landing. Callers must treat empty as "do not guess".
  function landedName(job) {
    var l = job && job.landed_as
    if (!l || l.length !== 1) return ""
    return String(l[0].name || "")
  }

  /// Take back the last move, rename or delete.
  ///
  /// A move across a boundary is a full verified transfer back, so it appears
  /// in the transfer panel as its own Job rather than pretending to be
  /// instant (ADR 0009).
  ///
  /// Nothing is taken off the stack here. This used to pop first and then ask,
  /// so Ctrl+Z with the daemon down ate the top entry and said nothing at all —
  /// which is indistinguishable from the undo bug it was hiding.
  function undoLast() {
    // Already on its way. Saying so is better than a second Ctrl+Z doing
    // nothing and looking like the undo bug this is fixing.
    if (undoStack.busy) { root.setNotice(undoStack.nextLabel, "warn"); return }
    var e = undoStack.peek()
    if (!e) { root.setNotice("Nothing to undo", "warn"); return }
    if (!daemon.canTransfer) {
      root.setNotice("omafiled is not answering — " + e.payload + " is still where it is", "bad")
      return
    }

    if (e.kind === "trash") {
      // As with a delete, `total` is what actually went out: a request the
      // socket refused will never answer, and the batch would wait for it.
      // `ids` is what makes a reply belong to a batch. Without it the tally was
      // positional — any `restored` reply counted, so a late answer to a batch
      // this window had given up on was counted into whatever batch was running
      // by then (issue 22).
      var b = { asked: e.items.length, total: 0, replies: 0, back: 0, errors: [],
                payload: e.payload, ids: [] }
      root.restoreBatch = b
      for (var i = 0; i < e.items.length; i++) {
        var rid = daemon.restore(e.items[i].trashedAs, e.items[i].info)
        if (rid !== -1) { b.total++; b.ids.push(rid) }
      }
      if (b.total === 0) {
        root.restoreBatch = null
        root.setNotice("omafiled is not answering — nothing was put back", "bad")
        return
      }
      undoStack.begin()
    } else if (e.kind === "rename") {
      var id = daemon.rename(e.path, e.originalName)
      if (id === -1) { root.setNotice("omafiled is not answering — the name was not changed back", "bad"); return }
      root.undoRequestId = id
      undoStack.begin()
    } else if (e.kind === "move") {
      // The same conflict pre-check as every other transfer. This was the one
      // mutation that bypassed it, and the engine made that catastrophic:
      // putting a file back over a newer file of the same name destroyed the
      // newer file without asking. The engine now honours the policy
      // (commit 6292cfd); this is the half that puts the question.
      if (!root.beginTransfer([e.destination], e.sourceDir, true, true)) return
      undoStack.begin()
      root.setNotice("Moving " + e.payload + " back — this is a real transfer", "warn")
    }
  }

  /// One restored file's answer. The entry is spent only when they are all in.
  function noteRestored(info) {
    var b = root.restoreBatch
    if (!b || b.ids.indexOf(info.id) === -1) { root.noteLateRestored(info); return }
    b.replies++
    if (info.error !== "") b.errors.push(info.error)
    else b.back++
    if (b.replies < b.total) return

    root.restoreBatch = null
    if (b.back === b.asked) {
      undoStack.commit()
      root.setNotice(b.payload + " back where "
                     + (b.asked === 1 ? "it" : "they") + " came from", "ok")
    } else if (b.back === 0) {
      // Nothing moved, so the entry is still the thing to undo.
      undoStack.release()
      root.setNotice("Could not put " + b.payload + " back — "
                     + (b.errors.length > 0 ? b.errors[0] : "omafiled stopped answering"), "bad")
    } else {
      // Partly back. The entry can no longer be replayed as a whole, so it is
      // spent either way; what is still in the trash is said out loud.
      undoStack.commit()
      root.setNotice(b.back + " of " + b.asked + " put back — "
                     + (b.errors.length > 0 ? b.errors[0] : "omafiled stopped answering"), "bad")
    }
  }

  /// A file coming back out of the trash for a batch this window stopped
  /// waiting for. Tallied, not ignored: the offer to put those files back is
  /// still on the bar, and if they have in fact come back it is describing a
  /// state that no longer exists (issue 22).
  function noteLateRestored(info) {
    for (var i = 0; i < root.abandonedRestores.length; i++) {
      var rec = root.abandonedRestores[i]
      if (rec.batch.ids.indexOf(info.id) === -1) continue
      rec.batch.replies++
      if (info.error !== "") rec.batch.errors.push(info.error)
      else rec.batch.back++
      if (rec.batch.replies < rec.batch.total) return
      var next = root.abandonedRestores.slice()
      next.splice(i, 1)
      root.abandonedRestores = next
      if (rec.batch.back === rec.batch.asked)
        root.retireLate(rec.entry, "omafiled answered late — " + rec.batch.payload
                                   + " came back after all")
      else if (rec.batch.back > 0)
        root.retireLate(rec.entry, "omafiled answered late — " + rec.batch.back + " of "
                                   + rec.batch.asked + " came back; the rest is still in the trash")
      else
        root.setNotice("omafiled answered late — nothing came back out of the trash", "bad")
      return
    }
  }

  /// A Job that stopped. The longest sentence in the product, and the one that
  /// has to be led by the state of the data.
  ///
  /// `jobFailed` reached a handler that opened "Nothing was written" and then
  /// drew it in the success colour — and said it even when three of five files
  /// were already at the destination, which is the one number a reader would
  /// act on.
  function noteJobFailed(job) {
    if (root.undoJobId !== "" && job.job === root.undoJobId) {
      root.undoJobId = ""
      root.undoRequestId = -1
      // The put-back did not happen, so it is still the thing to undo.
      undoStack.release()
    } else {
      // An undo already released by the liveness path, failing late. Nothing
      // to do to the stack — it has been back within reach since then, and the
      // put-back did NOT happen, so the entry is still exactly the truth. This
      // is the one late answer that must not retire anything; the record is
      // taken only so its id cannot match twice.
      root.takeAbandonedJob(job.job)
    }
    var why = String(job.error || "the transfer failed")
    // The daemon's message opens with the failing file's whole path and closes
    // with the same clause this notice opens with. The path is in the transfer
    // panel, at full width; here there is room for the name and the numbers.
    var cut = why.indexOf(": ")
    if (cut > 0 && why.substring(0, cut).indexOf("/") !== -1) why = why.substring(cut + 2)
    why = why.replace(/\s*—\s*nothing was written\s*$/, "")

    var landed = Number(job.files_done) || 0
    var head = landed > 0
      ? (landed + (landed === 1 ? " file is" : " files are") + " there; the rest is not")
      : "Nothing was written"
    var name = String(job.file || job.label || "")
    var untried = Number(job.files_skipped) || 0
    var tail = untried > 0
      ? " " + untried + (untried === 1 ? " file" : " files") + " not attempted."
      : ""
    root.setNotice(head + " — " + (name !== "" ? name + ": " : "") + why + "." + tail, "bad")
  }

  /// Open with the system handler. Unprivileged, and deliberately not routed
  /// through the daemon: the daemon owns filesystem *mutation*, and opening a
  /// file mutates nothing.
  function openSelection() {
    // selectedSingleFile(), not selectedPaths().length === 1: it is the same
    // expression the menu row is armed from (ContextMenu.qml `armed`).
    var one = srcPane.selectedSingleFile()
    if (one === "") {
      root.setNotice(srcPane.containsDir ? "Folders are not opened in this version"
                   : srcPane.selectedFileCount() === 0 ? "Pick one file to open"
                   : "Pick one file to open, not " + srcPane.selectedFileCount(), "warn")
      return
    }
    // Say so. Opening had no feedback of any kind: on a file type with no
    // handler, or when the launched app took a moment to appear, "double-click
    // did nothing" was indistinguishable from the gesture not being wired --
    // and for a while it genuinely was not, which is exactly why silence here
    // cost a bug report to find.
    root.openedName = one.substring(one.lastIndexOf("/") + 1)
    opener.command = ["xdg-open", one]
    opener.running = true
    root.setNotice("Opening " + root.openedName, "warn")
  }

  function renameSelection() {
    var one = srcPane.selectedSingleFile()
    if (one === "") {
      root.setNotice(srcPane.containsDir ? "Folders are not renamed in this version"
                   : srcPane.selectedFileCount() === 0 ? "Pick one file to rename"
                   : "Rename works on one file at a time", "warn")
      return
    }
    renameDialog.ask(one)
  }

  /// Open the context menu from the keyboard (Menu, Shift+F10).
  ///
  /// It opens against the top of the active pane's list rather than at the
  /// cursor row: a pane does not expose where that row sits on screen, and
  /// working it out from a row height and a scroll offset would be the kind of
  /// hard-coded layout arithmetic this window has already been bitten by. The
  /// menu acts on the selection either way, exactly as the mouse path does.
  function popupMenuForKeyboard() {
    var pane = root.srcPane
    if (!pane) return
    var p = pane.mapToItem(null, 16, 44)
    contextMenu.popupAt(p.x, p.y, pane.selectedFileCount(), pane.containsDir)
  }

  function showProperties() {
    var one = srcPane.selectedSingleFile()
    if (one === "") {
      root.setNotice(srcPane.containsDir ? "Folders have no properties in this version"
                   : srcPane.selectedFileCount() === 0 ? "Pick one file to see its path"
                   : "Pick one file to see its path, not " + srcPane.selectedFileCount(), "warn")
      return
    }
    root.setNotice(String(one), "warn")
  }

  /// Which pane contains a scene point, or -1. Used instead of Qt's drop
  /// machinery, which never engaged because a targetless DragHandler starts no
  /// Qt drag.
  function paneAt(sx, sy) {
    var l = leftPane.mapFromItem(null, sx, sy)
    if (l.x >= 0 && l.y >= 0 && l.x < leftPane.width && l.y < leftPane.height) return 0
    var r = rightPane.mapFromItem(null, sx, sy)
    if (r.x >= 0 && r.y >= 0 && r.x < rightPane.width && r.y < rightPane.height) return 1
    return -1
  }

  /// Read the pane's selection the once, at the moment the drag becomes a drag.
  function beginDrag(paneIndex) {
    var from = paneIndex === 0 ? leftPane : rightPane
    root.dragFrom = paneIndex
    root.dragPaths = from.selectedPaths()
    root.dragHadFolder = from.containsDir
    root.dragDest = ""
    root.dragPointerSeen = false
  }

  function updateDropTarget(sx, sy) {
    var over = paneAt(sx, sy)
    root.dragPointerX = sx
    root.dragPointerY = sy
    root.dragPointerSeen = true
    // Over a pane, from a drag, and not the pane it came from.
    var accepts = over !== -1 && root.dragFrom !== -1 && over !== root.dragFrom
    root.dragDest = accepts ? root.folderName((over === 0 ? leftPane : rightPane).dir) : ""
    // The wash and the label answer to the same sentence, read from the label
    // rather than re-derived here. Watched on screen 2026-09-09: dragging a
    // folder lit the destination pane while the label under the cursor was
    // saying folders are not transferred — a target armed for something that
    // will do nothing, which is rank 7 in its plainest form, and two places
    // deciding one fact, which is how the other nine got in.
    var lit = accepts && !root.dragLabel.blocked
    leftPane.dropTarget = lit && over === 0
    rightPane.dropTarget = lit && over === 1
  }

  function releaseDrag(sx, sy) {
    leftPane.dropTarget = false
    rightPane.dropTarget = false
    root.dragPointerSeen = false
    dropOnto(paneAt(sx, sy))
  }

  /// Ask the daemon what would collide, then ask the user, then start. The
  /// engine is never left waiting on a person (ADR 0013).
  ///
  /// Returns true if the question actually went out, so a caller that has
  /// something to unwind — undo, in particular — can tell.
  ///
  /// `pendingTransfer` is one slot and used to be overwritten without a guard.
  /// The conflicts round-trip is async and the window is widest exactly where
  /// this product lives, on a stalled share: a second drag during a slow reply
  /// showed transfer A's colliding names against transfer B's destination and
  /// applied the answer to B's sources, while A was dropped in silence.
  function beginTransfer(sources, destDir, isMove, isUndo) {
    if (sources.length === 0) return false
    if (!daemon.canTransfer) {
      root.setNotice("omafiled is not answering — nothing was started", "bad")
      return false
    }
    if (root.pendingTransfer) {
      root.setNotice("Still asking about the last transfer — one at a time", "warn")
      return false
    }
    var id = daemon.conflicts(sources, destDir)
    if (id === -1) {
      root.setNotice("omafiled is not answering — nothing was started", "bad")
      return false
    }
    root.pendingTransfer = { requestId: id, sources: sources, dest: destDir,
                             isMove: isMove === true, isUndo: isUndo === true }
    conflictWait.restart()
    return true
  }

  /// Give up on a conflicts question that never came back.
  ///
  /// Without this the one-at-a-time guard above would be a permanent lockout
  /// the first time a share stalls. Clearing the slot also makes the late reply
  /// harmless: its id no longer matches anything, so it is dropped.
  Timer {
    id: conflictWait
    interval: 20000
    onTriggered: {
      var p = root.pendingTransfer
      if (!p) return
      root.pendingTransfer = null
      if (p.isUndo) undoStack.release()
      root.setNotice("omafiled did not answer in time — nothing was started", "bad")
    }
  }

  function sendPendingTransfer(policy) {
    var p = root.pendingTransfer
    root.pendingTransfer = null
    conflictWait.stop()
    if (!p) return
    var id = p.isMove ? daemon.move(p.sources, p.dest, root.checksum, policy)
                      : daemon.copy(p.sources, p.dest, root.checksum, policy)
    if (id === -1) {
      if (p.isUndo) undoStack.release()
      root.setNotice("omafiled is not answering — nothing was started", "bad")
      return
    }
    // The Job id arrives on the reply; until then this request id is the only
    // handle on it.
    if (p.isUndo) { root.undoRequestId = id; root.undoJobId = "" }
  }

  /// A drop copies. Never moves — see ADR 0012.
  function dropOnto(paneIndex) {
    if (paneIndex === -1 || root.dragFrom === -1 || root.dragFrom === paneIndex) {
      root.dragFrom = -1
      return
    }
    var from = root.dragFrom === 0 ? leftPane : rightPane
    var to = paneIndex === 0 ? leftPane : rightPane
    // What the ghost promised, not a second walk of the model. Two computations
    // of "the files this drag carries" is one place taught and its reader left
    // alone — this project's signature defect, and there is no reason to invite
    // it when the answer was already worked out at `beginDrag`.
    var paths = root.dragPaths
    var hadFolder = root.dragHadFolder
    root.dragFrom = -1
    if (paths.length === 0) {
      // A drag selects the row it started on, so an empty list here means
      // the drag began on a folder. The ghost has been saying so since the
      // gesture began; this is the same sentence, kept for the release.
      root.setNotice(hadFolder ? "Folders are not transferred in this version"
                               : "Nothing to copy", "warn")
      return
    }
    // States the rule, in the neutral role: the accent is for outcomes, and
    // this is written before the daemon has been asked anything. The Job's own
    // completion notice is what says it finished.
    if (!root.beginTransfer(paths, to.dir, false)) return
    root.setNotice("Copying " + paths.length + (paths.length === 1 ? " item" : " items")
      + " to " + root.folderName(to.dir) + " — a drag always copies", "warn")
    from.clearSelection()
  }

  function startTransfer(isMove) {
    var paths = srcPane.selectedPaths()
    if (paths.length === 0) {
      // Reachable from Ctrl+C and Ctrl+M, which nothing disarms; see
      // deleteSelection() for why this must say something.
      root.setNotice(srcPane.containsDir ? "Folders are not transferred in this version"
                                         : "Pick a file to " + (isMove ? "move" : "copy"), "warn")
      return
    }
    // Refuse a copy that cannot fit, before the first byte rather than after
    // some of them. This is the whole argument of the product applied to the
    // one failure it can see coming: the engine already knows what the sources
    // weigh, and the daemon now knows what the destination can take.
    //
    // Copies only, on purpose. A same-filesystem move writes nothing at all --
    // it is a rename (ADR 0002) -- so refusing one for want of space would be a
    // false refusal, and a false refusal blocks work that would have succeeded.
    // We cannot tell from here whether a move crosses a filesystem, so a move
    // is left to the engine, which finds out for certain.
    //
    // Known limitation, stated rather than hidden: a copy that replaces
    // existing files reclaims their bytes, and this does not count that. Such a
    // copy can be refused when it would in fact have fitted. Conflicts are not
    // resolved until after this point (ADR 0013), so the number needed to be
    // exact is not available yet.
    if (!isMove && dstPane.freeBytes >= 0) {
      var need = srcPane.selectedBytes()
      if (need > dstPane.freeBytes) {
        root.setNotice("Not enough room — " + srcPane.humanSize(need) + " to copy, "
                       + dstPane.humanSize(dstPane.freeBytes) + " free", "bad")
        return
      }
    }
    // One request, one Job. Sending a request per file would put the selection
    // beyond the reach of the stop rule.
    if (!beginTransfer(paths, dstPane.dir, isMove)) return
    srcPane.clearSelection()
  }

  Process {
    id: pathCheck
    running: false
    // The pane that asked, so the answer goes back to the right one.
    property var forPane: null
    property string candidate: ""
    // (A comment line beginning with the linter's name is read as a directive.)
    // qmllint disable signal-handler-parameters
    onExited: function (code) {
      if (code === 0) {
        pathCheck.forPane.dir = pathCheck.candidate
        pathCheck.forPane.editingPath = false
      } else {
        root.setNotice("No folder at " + pathCheck.candidate, "bad")
      }
    }
  }

  /// What `systemctl --user is-enabled omafiled.socket` last answered, trimmed,
  /// or "" before it has been asked. Issue 38.
  ///
  /// One command separates all three first-run situations, which is why there
  /// is no second check for the binary: the socket unit ships in the same
  /// package, so `not-found` **is** "not installed". Verified on this machine
  /// rather than assumed — a missing unit answers `not-found` with status 4.
  /// A `test -x /usr/bin/omafiled` beside this would be a second way to ask one
  /// question, and two gates that must agree is the defect this project has now
  /// found nine times.
  property string socketState: ""

  /// Where the plugin is installed, which is where its `packaging/` is. Omarchy
  /// puts a plugin at `~/.config/omarchy/plugins/<id>`, and `link-plugin.sh`
  /// makes the same path a symlink for development — so `cd` through it works
  /// either way and the copied command is true on a user's machine and on this
  /// one.
  readonly property string pluginDir:
    root.homeDir + "/.config/omarchy/plugins/" + root.pluginId

  readonly property var firstRun: root.wording.firstRunHelp(root.socketState, root.pluginDir)

  /// The transfer panel's daemon line, and the command its chip copies, decided
  /// **once**.
  ///
  /// These were briefly two parallel ternaries — one for the sentence, one for
  /// the command — and they disagreed on the first screen they were watched on:
  /// the note said the daemon was connected and merely quiet, while the chip
  /// beside it offered `makepkg -si` to install the daemon that was plainly
  /// already there. One armed control, nothing useful behind it, which is the
  /// rank 7 rule; and one fact decided in two places, which is how the other
  /// nine got in. So there is one expression and the panel reads both halves
  /// off it.
  ///
  /// Only the last branch has anything to paste. A version mismatch and a quiet
  /// daemon are both explained by their sentence, and neither is fixed by a
  /// command this window could name.
  /// Whether a layer that must be answered is on screen.
  ///
  /// Issue 39, and the reason this exists rather than the shield doing it all:
  /// `InputShield` stops a *press* reaching what is behind it, which covers
  /// every MouseArea in this window — the scrollbar, the divider grip, the
  /// sidebar. It cannot stop `FileRow`'s `DragHandler`, and two attempts to
  /// make it were watched failing on screen with both handlers instrumented:
  ///
  ///   * A full-surface `MouseArea` shields nothing from a handler. Qt 6 offers
  ///     a press to **every item's pointer handlers first**, front to back, and
  ///     only then to the items themselves. A MouseArea is an item.
  ///   * A `TapHandler` with `gesturePolicy: WithinBounds` takes the exclusive
  ///     grab on press — the log shows it taking one — and then **gives it up
  ///     the instant the point moves**, which is precisely when a drag begins.
  ///     A tap handler cannot hold a drag; that is its job description. The
  ///     `DragHandler` below, holding a passive grab all along, takes over.
  ///   * A `DragHandler` on the shield does not win either: both it and the
  ///     row's went active in the same gesture.
  ///
  /// `enabled` is not a grab race. A disabled item and everything under it
  /// receive no input at all, handlers included, which is what Qt's own modal
  /// popups rely on. So the panes — the only place beneath an overlay where a
  /// pointer *handler* lives — are disabled while one is up.
  /// `contextMenu` is in the list because it was watched doing it: with the menu
  /// open, a drag on a row behind it copied a file. Its scrim is a MouseArea and
  /// by the reasoning above a MouseArea cannot stop a handler. A menu is not a
  /// modal, but a drag running behind one is not "click away to dismiss" either
  /// — the scrim eats the click, so the gesture is invisible where it lands and
  /// effective where it does not.
  ///
  /// `GoMenu` is the same fault and is NOT here, because it lives inside the
  /// pane: disabling the pane would disable the menu with it. `DirPane` disables
  /// its own list instead.
  readonly property bool modalOpen: conflictDialog.visible || renameDialog.visible
                                    || confirmDelete.visible
                                    || previewSheet.open || shortcutSheet.open
                                    || contextMenu.visible

  /// The overlays that answer their keys through `browser`'s `Keys.onPressed`
  /// instead of through a focus item of their own. The three dialogs are not
  /// here on purpose: each takes focus when it asks and gives it back in
  /// `onVisibleChanged`, and that difference is the whole of this bug.
  ///
  /// `modalOpen` disables both panes, and **disabling an item destroys the
  /// active focus it holds**. Focus is usually on `browser`, but not always:
  /// after `DirPane::endFilter()` it sits on a `FileRow`, where keys still work
  /// because they propagate up to the handler. Open an overlay from *that*
  /// state and the focus is thrown away with the pane, `Keys.onPressed` is
  /// never reached again, and `Preview` goes on printing "Escape closes" while
  /// Escape does nothing at all. Only a mouse click recovered it. Watched
  /// 2026-09-09; the reproduction is four keystrokes, Ctrl+F Escape F1 Escape.
  ///
  /// So the overlay claims the focus the pane is about to lose. Keying this off
  /// `modalOpen` instead would fire for the dialogs too and take the keyboard
  /// away from the item currently asking the question -- the same defect from
  /// the other end.
  ///
  /// `Qt.callLater` because this handler and `enabled: !root.modalOpen` are two
  /// readers of one property change with no ordering between them: claiming the
  /// focus first and disabling the pane second loses it again. The same reason
  /// `activated()` is answered late further up.
  readonly property bool overlayOpen: previewSheet.open || shortcutSheet.open
                                      || contextMenu.visible
  onOverlayOpenChanged: if (root.overlayOpen)
                          Qt.callLater(function () { browser.forceActiveFocus() })

  readonly property var daemonBanner: {
    if (daemon.canTransfer)
      return { note: "omafiled " + daemon.daemonVersion + " · protocol ok", command: "" }
    if (daemon.incompatible !== "")
      return { note: daemon.incompatible, command: "" }
    if (daemon.attached)
      return { note: "omafiled is connected but has gone quiet — nothing was lost;"
                     + " it is still being asked",
               command: "" }
    // Issue 38. This used to be one sentence naming both first-run commands for
    // all three of the situations it can mean, and the two halves of first run
    // have completely different privilege profiles, so saying them together
    // said neither well. `systemctl --user is-enabled` tells them apart, and
    // the sentence and command come from `Wording::firstRunHelp()`, where they
    // are tested rather than eyeballed.
    //
    // `makepkg -si` rather than `yay -S omafiled`: the AUR closed new account
    // registration on 2026-09-09 with no stated date, so that package cannot
    // exist yet and naming it would be telling the user to run a command that
    // fails. The PKGBUILD lives in this repo (ADR 0006), which is what makes
    // the AUR a convenience rather than a requirement.
    return root.firstRun
  }

  Process {
    id: socketCheck
    running: false
    command: ["systemctl", "--user", "is-enabled", "omafiled.socket"]
    // Decided from the word, not the exit status: systemd distinguishes
    // `not-found`, `disabled` and `masked` in the text while giving them
    // exit codes that would have to be memorised to be read.
    stdout: StdioCollector {
      onStreamFinished: root.socketState = String(this.text).trim()
    }
  }

  Component.onCompleted: socketCheck.running = true

  Connections {
    target: daemon
    // Ask again whenever the daemon stops being usable, so a diagnosis from
    // startup does not outlive the thing it described — the socket can be
    // enabled, or masked, while the window is open.
    function onCanTransferChanged() {
      if (!daemon.canTransfer) socketCheck.running = true
    }
  }

  Process {
    id: opener
    running: false
    // The exit code comes from the signal, not from a property: Process
    // exposes no `exitCode` to read afterwards. Its second argument is a
    // QProcess enum the linter cannot resolve through this import, so the
    // handler declares only the argument it uses and the parameter check is
    // switched off -- the accommodation Settings.qml's Process already needed.
    // (Careful: a comment line *beginning* with the linter's name is read as a
    // directive, which is how this block first produced six bogus warnings.)
    // qmllint disable signal-handler-parameters
    onExited: function (code) {
      // xdg-open returns 3 for "no handler" and 4 for "action failed"; both
      // look identical to the user without this, because the window it was
      // waiting for simply never appears.
      if (code !== 0)
        root.setNotice("Nothing here opens " + root.openedName, "bad")
    }
  }

  /// The file the opener was last asked for, so its exit can name it.
  property string openedName: ""

  // Declared before the client, because the client's handlers reach into it
  // and a property-change handler can fire while the rest of the tree is still
  // being built.
  Settings { id: settings }

  UndoStack { id: undoStack }

  DaemonClient {
    id: daemon
    // A daemon that has stopped answering will never answer the undo it was
    // already given. Leaving the entry marked in-flight would take Ctrl+Z out
    // of the session for good, over a put-back that did not happen.
    onCanTransferChanged: {
      if (daemon.canTransfer || !undoStack.busy) return
      // Remembered, not forgotten. `release()` puts the entry back within
      // reach, which is right, and the id fields must not stay armed — but
      // clearing them outright was worse than leaving them: the reply the
      // daemon may still send then looked like a fresh rename or a fresh move
      // and got recorded as one. See `abandonedUndos`.
      //
      // The entry itself is what goes into the record. Taken before
      // `release()`, which clears `inFlight` and is the last thing holding it.
      var entry = undoStack.inFlight
      if (root.undoRequestId !== -1)
        root.abandonedUndos = root.abandonedUndos.concat([{ id: root.undoRequestId, entry: entry }])
      if (root.undoJobId !== "")
        root.abandonedUndoJobs = root.abandonedUndoJobs.concat([{ job: root.undoJobId, entry: entry }])
      if (root.restoreBatch)
        root.abandonedRestores = root.abandonedRestores.concat([{ batch: root.restoreBatch, entry: entry }])
      root.undoRequestId = -1
      root.undoJobId = ""
      root.restoreBatch = null
      undoStack.release()
      root.setNotice("omafiled stopped answering — the undo did not finish", "bad")
    }
    onDeleted: function (info) { root.noteDeleted(info) }
    onAcknowledged: function (requestId, jobId, error) {
      // The only place a request id and a Job id are ever seen together. An
      // undo that became a Job is followed by its Job id from here on.
      if (requestId !== root.undoRequestId || requestId === -1) {
        // An undo we gave up on, taken by the daemon after all. Follow it to
        // its Job id, or the Job's completion will arrive unrecognised too.
        var rec = root.takeAbandonedRequest(requestId)
        if (rec && jobId !== "")
          root.abandonedUndoJobs = root.abandonedUndoJobs.concat([{ job: jobId, entry: rec.entry }])
        return
      }
      if (error !== "") {
        root.undoRequestId = -1
        undoStack.release()
        root.setNotice("omafiled refused the undo — " + error, "bad")
        return
      }
      if (jobId !== "") root.undoJobId = jobId
    }
    onConflictsFound: function (requestId, names) {
      var p = root.pendingTransfer
      // An answer to a question we are no longer asking is not an answer. It
      // used to be applied to whatever was in the slot by then.
      if (!p || requestId !== p.requestId) return
      conflictWait.stop()
      if (names.length === 0) {
        // Skip, not replace. The pre-check found nothing, so a file that
        // appears between the check and the copy was never asked about — and
        // under-doing is recoverable where overwriting is not (ADR 0013).
        // Sending "replace" here made Replace the policy in force for every
        // ordinary transfer in the product.
        root.sendPendingTransfer("skip")
        return
      }
      // The Job's own size, not the number of collisions: the dialog offers
      // Skip only when skipping would still transfer something (issue 18).
      conflictDialog.ask(names, p.dest, p.sources.length)
    }
    onJobFailed: function (job) { root.noteJobFailed(job) }
    onRenamed: function (info) {
      var wasUndo = (root.undoRequestId !== -1 && info.id === root.undoRequestId)
      if (wasUndo) root.undoRequestId = -1
      else {
        var lateRename = root.takeAbandonedRequest(info.id)
        if (lateRename) {
          // The undo this window stopped waiting for, answered late. Recording
          // it as a rename would arm a Ctrl+Z pointing the other way, so
          // nothing is recorded either way — but the offer still on the bar is
          // now describing a file that no longer has that name, and pressing it
          // failed with `Could not p…` (issue 22). It is withdrawn, by
          // identity: the top of the stack may be something else by now.
          if (info.error !== "") {
            // The name did not change back, so the entry is still the truth.
            root.setNotice("omafiled answered late — the name was not put back: "
                           + info.error, "bad")
          } else {
            root.retireLate(lateRename.entry,
                            "omafiled answered late — the name is "
                            + String(info.to).split("/").pop() + " after all")
          }
          return
        }
      }
      if (info.error !== "") {
        if (wasUndo) {
          // The name did not change back, so the entry is still the thing to
          // undo. A failed undo has no dialog open to fail into.
          undoStack.release()
          root.setNotice("Could not put the name back — " + info.error, "bad")
        } else if (renameDialog.visible) {
          renameDialog.fail(info.error)
        } else {
          root.setNotice("Could not rename — " + info.error, "bad")
        }
        return
      }
      if (wasUndo) undoStack.commit()
      else renameDialog.done()
      var said = root.noteMutation("rename", info, wasUndo)
      if (said) root.setNotice(said.text, said.role)
    }
    onRestored: function (info) { root.noteRestored(info) }
    /// The answer names the path it was asked about, so it can be handed to
    /// whichever pane is looking at it -- both, when they are in the same
    /// place, which is a normal thing to do.
    onSpaceReported: function (path, total, available, error) {
      if (error !== "") return
      if (leftPane.dir === path) { leftPane.freeBytes = available; leftPane.totalBytes = total }
      if (rightPane.dir === path) { rightPane.freeBytes = available; rightPane.totalBytes = total }
    }
    onTrashAvailability: function (path, available) {
      if (root.pendingDelete.length === 0) return
      confirmDelete.ask(root.pendingDelete, available, root.srcPane.dir)
    }
    onJobFinished: function (job) {
      // The daemon says what happened; this used to infer it by string-matching
      // the display label, which was wrong in both directions — a
      // cross-filesystem move reports a copy tier, and an all-skipped Job
      // reported "Moved" and pushed an undo that would have moved the very file
      // the user chose to keep.
      var wasUndo = (root.undoJobId !== "" && job.job === root.undoJobId)
      if (wasUndo) {
        root.undoJobId = ""
        root.undoRequestId = -1
        // "Leave them alone" means the file did not come back. Spending the
        // entry on a no-op would put Ctrl+Z one step further from the file.
        if (job.outcome === "skipped") undoStack.release()
        else undoStack.commit()
      } else {
        var lateJob = root.takeAbandonedJob(job.job)
        if (lateJob) {
          // As in onRenamed: an undo this window gave up on, finished late.
          // Recording this as a fresh move would push an entry pointing the
          // other way, so nothing is recorded — and the offer it belongs to is
          // withdrawn, because the file it describes is back where it started.
          var lateSaid = "omafiled answered late — " + job.label + " is back in "
                         + root.folderName(job.destination) + " after all"
          // "Leave them alone" means it did not come back, so the entry is
          // still the truth — the same distinction onJobFinished draws above.
          if (job.outcome === "skipped")
            root.setNotice("omafiled answered late — " + job.label
                           + " was left where it was", "warn")
          else
            root.retireLate(lateJob.entry, lateSaid)
          return
        }
      }
      // Only a move is recorded, and only ever the user's own: reversing a copy
      // is a delete and calling that undo would mislead (ADR 0009), and an undo
      // that recorded itself made Ctrl+Z a toggle.
      var kind = job.outcome === "moved" ? "move"
               : job.outcome === "skipped" ? "skipped"
               : "copy"
      var said = root.noteMutation(kind, job, wasUndo)
      if (said) root.setNotice(said.text, said.role)
    }
  }

  FloatingWindow {
    id: window
    title: "omafile"
    color: Color.background
    implicitWidth: 1100
    implicitHeight: 720
    minimumSize: Qt.size(720, 480)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell
          && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    // The prototypes stay reachable for comparison; they are not the product.
    Loader {
      width: window.width
      height: window.height
      active: root.proto !== ""
      sourceComponent: root.proto === "confirm" ? confirmProto
                     : root.proto === "jobs" ? jobsProto
                     : root.proto === "ipc" ? ipcProto
                     : root.proto === "tabs" ? tabsProto : null
    }
    Component { id: confirmProto; ConfirmPreview {} }
    Component { id: jobsProto; JobPanel {} }
    Component { id: ipcProto; IpcProbe {} }
    Component {
      id: tabsProto
      TabbedPane {
        leftDir: root.homeDir
        rightDir: root.homeDir + "/Downloads"
      }
    }

    // Sized from the window: FloatingWindow's content item sizes itself to its
    // children, so `anchors.fill: parent` is circular and silently collapses
    // the whole UI into a narrow column (found in ticket 04).
    Rectangle {
      id: browser
      visible: root.proto === ""
      width: window.width
      height: window.height
      color: Color.background
      // Keys only arrive at something that actually holds active focus, and
      // adding the sidebar was enough to leave this without it. Claim it
      // explicitly rather than relying on the focus chain.
      activeFocusOnTab: true

      Locations {
        id: sidebar
        pinned: root.pinned
        showHidden: root.showHidden
        onUnpinned: function (path) { root.togglePin(path) }
        anchors { top: parent.top; bottom: actions.top; left: parent.left }
        width: root.showLocations ? root.sidebarWidth : 0
        visible: root.showLocations
        currentDir: root.srcPane ? root.srcPane.dir : ""
        // A place opens in the pane you were last working in, so choosing a
        // share does not silently change which way a transfer would go.
        onChosen: function (path) {
          if (root.activePane === 0) leftPane.dir = path
          else rightPane.dir = path
          browser.forceActiveFocus()
        }
      }

      Rectangle {
        id: sidebarRule
        anchors { top: parent.top; bottom: actions.top; left: sidebar.right }
        width: root.showLocations ? 1 : 0
        color: sidebarGrip.pressed || sidebarGrip.containsMouse
               ? Color.accent
               : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
      }

      // A 1px rule is not a target. The grip is nine pixels wide and centred on
      // the rule, which lights up under it so the boundary says it can be moved
      // before anyone tries.
      MouseArea {
        id: sidebarGrip
        anchors { top: parent.top; bottom: actions.top; horizontalCenter: sidebarRule.horizontalCenter }
        width: 11
        // Above the panes. A pane declared after a grip paints over it, so the
        // grip was only catching the half that no pane covered — about four
        // pixels, off-centre, which is why the drag worked "but not every
        // time" when it was first tried. Below the context menu's scrim (55).
        z: 20
        visible: root.showLocations
        hoverEnabled: true
        cursorShape: Qt.SplitHCursor
        property real grabX: 0
        property real grabWidth: 0
        onPressed: function (m) {
          grabX = mapToItem(browser, m.x, 0).x
          grabWidth = root.sidebarWidth
        }
        onPositionChanged: function (m) {
          if (!pressed) return
          var dx = mapToItem(browser, m.x, 0).x - grabX
          root.sidebarWidth = Math.max(root.minSidebarWidth,
                                       Math.min(root.maxSidebarWidth, grabWidth + dx))
        }
      }

      DirPane {
        id: leftPane
        // Issue 39. The one place beneath an overlay where a pointer HANDLER
        // lives, and therefore the one place a shield cannot cover.
        enabled: !root.modalOpen
        homePath: root.homeDir
        showIcons: root.showIcons
        onSpaceWanted: function (path) { daemon.askSpace(path) }
        onPathChecked: function (path) { root.checkPath(leftPane, path) }
        showHidden: root.showHidden
        sortField: root.sortField
        sortReversed: root.sortReversed
        onSortRequested: function (field) { root.sortBy(field) }
        onOpenRequested: root.openSelection()
        anchors { top: parent.top; bottom: actions.top; left: sidebarRule.right }
        width: {
          var avail = parent.width - sidebar.width - sidebarRule.width - divider.width
          return avail * root.clampedSplit(avail)
        }
        dir: root.homeDir
        active: root.activePane === 0
        places: sidebar.places
        mounts: sidebar.mounts
        onActivated: { root.activePane = 0; browser.forceActiveFocus() }
        onContextRequested: function (gx, gy) { contextMenu.popupAt(gx, gy, leftPane.selectedFileCount(), leftPane.containsDir) }
        onDragBegan: root.beginDrag(0)
        onDragReleased: function (sx, sy) { root.releaseDrag(sx, sy) }
        onDragMoved: function (sx, sy) { root.updateDropTarget(sx, sy) }
      }

      Rectangle {
        id: divider
        anchors { top: parent.top; bottom: actions.top; left: leftPane.right }
        width: 1
        color: dividerGrip.pressed || dividerGrip.containsMouse
               ? Color.accent
               : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
      }

      // The split is a fraction, not a width, so a resized window keeps the
      // proportion the user chose rather than giving every new pixel to one
      // pane. Clamped in clampedSplit() so neither side can be dragged shut.
      MouseArea {
        id: dividerGrip
        anchors { top: parent.top; bottom: actions.top; horizontalCenter: divider.horizontalCenter }
        width: 11
        z: 20
        hoverEnabled: true
        cursorShape: Qt.SplitHCursor
        property real grabX: 0
        property real grabFraction: 0.5
        onPressed: function (m) {
          grabX = mapToItem(browser, m.x, 0).x
          grabFraction = root.clampedSplit(browser.width - sidebar.width
                                           - sidebarRule.width - divider.width)
        }
        onPositionChanged: function (m) {
          if (!pressed) return
          var avail = browser.width - sidebar.width - sidebarRule.width - divider.width
          if (avail <= 0) return
          var dx = mapToItem(browser, m.x, 0).x - grabX
          root.splitFraction = grabFraction + dx / avail
        }
        // A double-click puts it back. Undoing a drag by dragging is fiddly,
        // and 50/50 is the only split with a name.
        onDoubleClicked: root.splitFraction = 0.5
      }

      DirPane {
        id: rightPane
        enabled: !root.modalOpen
        homePath: root.homeDir
        showIcons: root.showIcons
        onSpaceWanted: function (path) { daemon.askSpace(path) }
        onPathChecked: function (path) { root.checkPath(rightPane, path) }
        showHidden: root.showHidden
        sortField: root.sortField
        sortReversed: root.sortReversed
        onSortRequested: function (field) { root.sortBy(field) }
        onOpenRequested: root.openSelection()
        anchors { top: parent.top; bottom: actions.top; left: divider.right; right: parent.right }
        dir: root.homeDir + "/Downloads"
        active: root.activePane === 1
        places: sidebar.places
        mounts: sidebar.mounts
        onActivated: { root.activePane = 1; browser.forceActiveFocus() }
        onContextRequested: function (gx, gy) { contextMenu.popupAt(gx, gy, rightPane.selectedFileCount(), rightPane.containsDir) }
        onDragBegan: root.beginDrag(1)
        onDragReleased: function (sx, sy) { root.releaseDrag(sx, sy) }
        onDragMoved: function (sx, sy) { root.updateDropTarget(sx, sy) }
      }

      // Above both panes (the drop wash is z: 40 inside a pane) and below the
      // dialogs, which cannot be open while a drag is in flight anyway.
      DragGhost {
        id: dragGhost
        z: 90
        visible: root.dragPointerSeen && root.dragFrom !== -1
        pointerX: root.dragPointerX
        pointerY: root.dragPointerY
        label: root.dragLabel.text
        blocked: root.dragLabel.blocked
        // Follows Ctrl+I: a window with icons turned off should not grow one
        // under the cursor. One file only — a single file's icon standing in
        // for four would name the wrong one.
        icon: root.showIcons && root.dragPaths.length === 1
              ? root.fileKinds.iconFor(String(root.dragPaths[0]).split("/").pop(), false)
              : ""
      }

      Shortcuts { id: shortcutSheet }

      Preview { id: previewSheet }

      ActionBar {
        id: actions
        anchors { bottom: transfers.top; left: parent.left; right: parent.right }
        // The controls sit under the pane they act on, so the source pane is
        // stated by position as well as by the button's own words.
        sourceX: root.activePane === 0 ? leftPane.x : rightPane.x
        sourceIsLeft: root.activePane === 0
        // Armed from the count the actions run on. A pane's selection holds
        // folders too and selectedPaths() drops them; armed from the raw
        // length, Copy lit for a folder and then did nothing (instance #8,
        // watched 2026-09-08). scripts/lint-qml.sh refuses the old expression.
        selectedCount: root.srcPane ? root.srcPane.selectedFileCount() : 0
        containsDir: root.srcPane ? root.srcPane.containsDir : false
        directionLabel: root.activePane === 0 ? "right" : "left"
        checksum: root.checksum
        canTransfer: daemon.canTransfer
        // The diagnosis only. This Text is capped at 24% of the bar (see
        // ActionBar.qml) so the buttons keep their room, and the cap used to
        // fall exactly on the install command — the one half of the sentence a
        // reader would act on, elided to "install ...". Watched on screen
        // 2026-09-08. The command now lives in the panel header below, which
        // has the width for it and, until this change, did not carry it either
        // despite a comment here saying it did.
        // "Not running" is only one of the two ways the daemon can be
        // unusable, and until issue 24 they were indistinguishable from here.
        // A socket that shook hands and then went quiet is a daemon that is
        // very much installed, and telling its owner to install it is a
        // sentence they could act on.
        reason: daemon.incompatible !== ""
          ? daemon.incompatible
          : (daemon.attached ? "omafiled is not answering" : "omafiled not running")
        notice: root.notice
        noticeRole: root.noticeRole
        noticeSeq: root.noticeSeq
        // Drawn from hasEntries, armed from canUndo: an undo already on its way
        // keeps its place in the bar and says what it is doing.
        undoLabel: undoStack.hasEntries ? undoStack.nextLabel : ""
        undoArmed: undoStack.canUndo
        onCopyRequested: root.startTransfer(false)
        onMoveRequested: root.startTransfer(true)
        onChecksumToggled: root.checksum = !root.checksum
        onUndoRequested: root.undoLast()
        onDeleteRequested: root.deleteSelection()
      }

      TransferPanel {
        id: transfers
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        // No explicit height: the panel sizes itself to the Jobs it holds
        // (TransferPanel.implicitHeight, bounded by maxHeight). Pinning it to
        // 172 here overrode that binding entirely, so the panel it describes —
        // 52px when empty, giving 120px back to the panes — was never the
        // panel on screen. Found by looking at it, not by a test.
        jobs: daemon.jobs
        dismissableJobIds: root.dismissableJobIds
        onHelpRequested: shortcutSheet.open = true
        onDismissRequested: function (jobId) { root.dismissJob(jobId) }
        daemonLive: daemon.canTransfer
        daemonNote: root.daemonBanner.note
        daemonCommand: root.daemonBanner.command
        onCopyCommandRequested: {
          Quickshell.clipboardText = root.daemonBanner.command
          // Names what was copied. A clipboard write is invisible, and "Copied"
          // alone is also what a finished file copy says in this same window.
          root.setNotice("Command copied — paste it in a terminal", "ok")
        }
      }

      // Keyboard-first, and handled at the window rather than in the panes:
      // the active pane is a property of the browser, so the browser routes
      // keys to it instead of depending on where Qt put focus.
      //
      //   Tab           switch which pane is the source
      //   Up/Down       move the cursor
      //   Home/End      jump to the first/last row (issue 23)
      //   PageUp/Down   jump by a screenful
      //   Space         pick or unpick the row at the cursor
      //   Enter         open a directory
      //   Backspace     go up
      //   Ctrl+A        pick every file here
      //   Ctrl+C/Ctrl+M copy or move to the other pane
      //   Ctrl+K        toggle checksum for the next transfer
      //   Ctrl+B        show or hide the places sidebar
      //   Delete        delete the selection (trash where possible)
      //   Ctrl+Z        take back the last move or delete
      //   F2            rename
      //   Menu/Shift+F10  the context menu
      //   Escape        dismiss the menu, or close
      Keys.onPressed: function (event) {
        // A dialog owns the keyboard while it is up. Each dialog's focus Item
        // accepts only Escape (and Enter for a recoverable delete), so every
        // other key propagated to here and Ctrl+C, Ctrl+M and Delete fired
        // behind the scrim — which is what made the one-transfer-at-a-time
        // race easy to hit rather than exotic.
        if (conflictDialog.visible || renameDialog.visible || confirmDelete.visible) return

        // The menu owns the keyboard on the same terms. It was left out of the
        // guard above, so Delete pressed with the menu open put the permanent-
        // delete confirmation up *through* it — two modals on screen at once,
        // with the menu stranded behind the dialog's scrim. Watched on screen
        // 2026-09-08. Escape still reaches the menu, because dismissing it is
        // the one thing the keyboard should be able to do while it is up.
        if (contextMenu.visible) {
          if (event.key === Qt.Key_Escape) {
            contextMenu.dismiss()
            event.accepted = true
          }
          return
        }

        // Layers close before the window does, innermost first. Preview sits
        // above the shortcut sheet because it is what you opened most recently.
        if (previewSheet.open) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_F3
              || (event.key === Qt.Key_Space && (event.modifiers & Qt.AltModifier) !== 0)) {
            previewSheet.open = false
            event.accepted = true
          }
          return
        }

        // The shortcut sheet is a layer over the window, so Escape must close
        // the layer before it closes the window -- the same rule the context
        // menu guard above established, for the same reason.
        if (shortcutSheet.open) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Question
              || event.key === Qt.Key_F1) {
            shortcutSheet.open = false
            event.accepted = true
          }
          return
        }

        var pane = root.srcPane
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (event.key === Qt.Key_Escape) {
          // The menu case is handled by the guard above: Escape with the menu
          // open used to close the whole window, because the menu takes no
          // focus and this binding fired instead of it.
          root.requestClose()
        }
        else if (event.key === Qt.Key_Tab) { root.activePane = 1 - root.activePane }
        else if (ctrl && event.key === Qt.Key_A) { pane.selectAllFiles() }
        else if (ctrl && event.key === Qt.Key_C) { root.startTransfer(false) }
        else if (ctrl && event.key === Qt.Key_M) { root.startTransfer(true) }
        else if (ctrl && event.key === Qt.Key_K) { root.checksum = !root.checksum }
        else if (ctrl && event.key === Qt.Key_B) { root.showLocations = !root.showLocations }
        else if (ctrl && event.key === Qt.Key_H) {
          root.showHidden = !root.showHidden
          root.setNotice(root.showHidden ? "Showing hidden files" : "Hiding hidden files", "warn")
        }
        else if (ctrl && event.key === Qt.Key_F) { pane.beginFilter() }
        else if (ctrl && event.key === Qt.Key_D) { root.togglePin(pane.dir) }
        // F3 is the primary. This is a dual-pane commander and it already
        // binds F2 to rename, which is the Norton/Midnight Commander map; in
        // that map F3 is View, so preview was already named before it existed.
        // Alt+Space is kept as the alias the request asked for -- it costs one
        // clause, and somebody who reaches for it should not be told no.
        else if (event.key === Qt.Key_F3
                 || ((event.modifiers & Qt.AltModifier) !== 0 && event.key === Qt.Key_Space)) {
          var f = pane.fileAtCursor()
          if (f === "") root.setNotice("Nothing to preview here", "warn")
          else { previewSheet.path = f; previewSheet.open = true }
        }
        else if (ctrl && event.key === Qt.Key_I) {
          root.showIcons = !root.showIcons
          root.setNotice(root.showIcons ? "Icons on" : "Icons off", "warn")
        }
        else if (event.key === Qt.Key_Question || event.key === Qt.Key_F1) {
          shortcutSheet.open = !shortcutSheet.open
        }
        else if (ctrl && event.key === Qt.Key_Z) { root.undoLast() }
        else if (event.key === Qt.Key_Delete) { root.deleteSelection() }
        else if (event.key === Qt.Key_F2) { root.renameSelection() }
        else if (event.key === Qt.Key_Menu
                 || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier) !== 0)) {
          root.popupMenuForKeyboard()
        }
        else if (event.key === Qt.Key_Space) { pane.toggleAtCursor() }
        else if (event.key === Qt.Key_Down) { pane.moveCursor(1) }
        else if (event.key === Qt.Key_Up) { pane.moveCursor(-1) }
        else if (event.key === Qt.Key_Home) { pane.moveCursorHome() }
        else if (event.key === Qt.Key_End) { pane.moveCursorEnd() }
        else if (event.key === Qt.Key_PageUp) { pane.moveCursorPage(-1) }
        else if (event.key === Qt.Key_PageDown) { pane.moveCursorPage(1) }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          // Enter does one obvious thing per row type. enterAtCursor() is a
          // no-op on a file, so Enter on a file used to do nothing at all and
          // say nothing about it; if the directory did not change, the row was
          // a file and opening it is what was meant.
          var before = pane.dir
          pane.enterAtCursor()
          if (pane.dir === before) root.openSelection()
        }
        else if (event.key === Qt.Key_Backspace) { pane.goUp() }
        else if ((event.modifiers & Qt.AltModifier) !== 0
                 && event.key === Qt.Key_Left) { pane.goBack() }
        else if ((event.modifiers & Qt.AltModifier) !== 0
                 && event.key === Qt.Key_Right) { pane.goForward() }
        else return
        event.accepted = true
      }
      focus: true

      ContextMenu {
        id: contextMenu
        directionLabel: root.activePane === 0 ? "right" : "left"
        canTransfer: daemon.canTransfer
        onCopyRequested: root.startTransfer(false)
        onMoveRequested: root.startTransfer(true)
        onOpenRequested: root.openSelection()
        onRenameRequested: root.renameSelection()
        // The same confirmation as the Delete key. One path to a destructive
        // action, not two.
        onDeleteRequested: root.deleteSelection()
        onPropertiesRequested: root.showProperties()
      }

      // Dismissing the menu by clicking away, without swallowing that click
      // from the thing underneath being aimed at.
      MouseArea {
        anchors.fill: parent
        visible: contextMenu.visible
        z: 55
        acceptedButtons: Qt.AllButtons
        onPressed: contextMenu.dismiss()
      }

      // Each dialog grabs active focus and none of them gave it back, so after
      // confirming a delete with Enter nothing held focus and Ctrl+Z did
      // nothing at all — indistinguishable from the undo bug it was sitting on
      // top of, and only recoverable by clicking a file row. A fourth dialog
      // inherits the handler by copy.
      ConflictDialog {
        id: conflictDialog
        anchors.fill: parent
        onVisibleChanged: if (!visible) browser.forceActiveFocus()
        onChose: function (policy) { root.sendPendingTransfer(policy) }
        onCancelled: {
          var p = root.pendingTransfer
          root.pendingTransfer = null
          conflictWait.stop()
          // Cancelling an undo's conflict question means the file did not come
          // back: the entry stays on the stack.
          if (p && p.isUndo) undoStack.release()
          root.setNotice("Transfer cancelled — nothing was written", "warn")
        }
      }

      RenameDialog {
        id: renameDialog
        anchors.fill: parent
        onVisibleChanged: if (!visible) browser.forceActiveFocus()
        onAccepted: function (newName) {
          if (daemon.rename(renameDialog.path, newName) === -1)
            renameDialog.fail("omafiled is not answering")
        }
        onCancelled: renameDialog.done()
      }

      DeleteConfirm {
        id: confirmDelete
        anchors.fill: parent
        onVisibleChanged: if (!visible) browser.forceActiveFocus()
        onConfirmed: root.performPendingDelete()
        onCancelled: {
          root.pendingDelete = []
          root.setNotice("Delete cancelled — nothing was deleted", "warn")
        }
      }
    }
  }
}
