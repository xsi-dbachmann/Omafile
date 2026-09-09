pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import qs.Commons

// One half of the browser: a directory, its selection, and nothing else.
//
// Dual-pane exists so the destination is a fact of the layout rather than
// something held in the head (ticket 08). This component therefore knows what
// it is showing and what is picked in it, and knows nothing about transfers.
Rectangle {
  id: pane

  property string dir: ""
  property bool active: false
  property var selection: []          // file names, not paths
  /// The shared sidebar's data, handed down so the per-pane Go▾ door (ADR
  /// 0014) can offer the same places and mounts without scanning for them a
  /// second time -- there is one `findmnt` poll for both panes, not two.
  property var places: []
  property var mounts: []
  property alias count: folderModel.count
  /// The keyboard cursor. Exposed so the window can drive a pane without
  /// depending on where Qt happens to have put focus.
  property alias cursorIndex: list.currentIndex

  signal activated()                  // this pane was interacted with
  signal contextRequested(real gx, real gy)
  signal dragBegan()
  signal dragReleased(real sx, real sy)
  signal dragMoved(real sx, real sy)
  /// True while this pane is the one a drag would land on.
  property bool dropTarget: false

  /// Bare filenames currently being flashed by reveal(). Reassigned whole so
  /// the rows' bindings re-evaluate; never mutated in place.
  property var revealed: []
  /// Names reveal() was asked for but could not find in the model yet, and how
  /// many times we have looked. FolderListModel refreshes off
  /// QFileSystemWatcher, which need not have caught the committing rename by
  /// the time the daemon reports the Job done.
  property var pendingReveal: []
  property int revealAttempts: 0

  color: "transparent"

  function humanSize(bytes) {
    var b = Number(bytes)
    if (!isFinite(b) || b < 0) return ""
    if (b < 1024) return b + " B"
    var units = ["KB", "MB", "GB", "TB"]
    var i = -1
    do { b = b / 1024; i++ } while (b >= 1024 && i < units.length - 1)
    return b.toFixed(b < 10 ? 1 : 0) + " " + units[i]
  }

  /// When the file last changed, worded for a column 52px wide.
  ///
  /// Precision where it earns its place: a file that arrived in this session
  /// is identified by its clock time, one from this year by its date, and an
  /// older one by month and year -- nobody reads a 2019 timestamp to the
  /// minute, and the pixels go to the name instead.
  function humanTime(when) {
    var d = (when instanceof Date) ? when : new Date(when)
    if (!d || isNaN(d.getTime())) return ""
    // An unset mtime comes back as the epoch; a date column reading
    // "Jan 1970" for every row of a share is noise, not information.
    if (d.getFullYear() < 1971) return ""
    var now = new Date()
    if (d.getFullYear() === now.getFullYear()) {
      if (d.getMonth() === now.getMonth() && d.getDate() === now.getDate())
        return Qt.formatDateTime(d, "HH:mm")
      return Qt.formatDateTime(d, "d MMM")
    }
    return Qt.formatDateTime(d, "MMM yyyy")
  }

  function isSelected(name) { return selection.indexOf(name) !== -1 }

  function isRevealed(name) { return revealed.indexOf(name) !== -1 }

  function toggle(name) {
    var next = selection.slice()
    var i = next.indexOf(name)
    if (i === -1) next.push(name); else next.splice(i, 1)
    selection = next
  }

  function selectOnly(name) {
    selection = [name]
  }

  function clearSelection() {
    selection = []
  }

  function selectAllFiles() {
    var next = []
    for (var i = 0; i < folderModel.count; i++) {
      if (!folderModel.get(i, "fileIsDir"))
        next.push(String(folderModel.get(i, "fileName")))
    }
    selection = next
  }

  function toggleAtCursor() {
    var n = String(folderModel.get(list.currentIndex, "fileName"))
    if (n) toggle(n)
  }

  function moveCursor(delta) {
    var n = list.currentIndex + delta
    if (n < 0) n = 0
    if (n >= folderModel.count) n = folderModel.count - 1
    list.currentIndex = n
  }

  function moveCursorHome() { list.currentIndex = 0 }
  function moveCursorEnd() { list.currentIndex = folderModel.count - 1 }

  /// A page is however many rows the list actually shows, not a constant --
  /// the pane's height is not fixed (ADR 0014 made the divider draggable), and
  /// a PageDown that jumps a fixed 10 rows would over- or under-shoot a pane
  /// that has been resized. Issue 23.
  function moveCursorPage(sign) {
    moveCursor(sign * Math.max(1, Math.floor(list.height / 30)))
  }

  /// The path as clickable segments (ADR 0014's breadcrumb): `label` is what
  /// is drawn, `path` is what a click sets `dir` to. The root segment's path
  /// is "/", never "" -- FolderListModel resolves an empty folder to whatever
  /// the process's working directory happens to be, which is not this pane.
  function crumbs() {
    var p = String(pane.dir).replace(/\/+$/, "")
    if (p === "") p = "/"
    var parts = p.split("/").filter(function (s) { return s !== "" })
    var out = [{ label: "/", path: "/" }]
    var acc = ""
    for (var i = 0; i < parts.length; i++) {
      acc += "/" + parts[i]
      out.push({ label: parts[i], path: acc })
    }
    return out
  }

  function enterAtCursor() { enter(list.currentIndex) }

  /// Absolute paths for what is picked. Directories are excluded: v1 transfers
  /// files, and silently walking a tree would be a promise the engine does not
  /// yet make.
  function selectedPaths() {
    var out = []
    for (var i = 0; i < folderModel.count; i++) {
      var n = String(folderModel.get(i, "fileName"))
      if (isSelected(n) && !folderModel.get(i, "fileIsDir"))
        out.push(String(folderModel.get(i, "filePath")))
    }
    return out
  }

  /// The selection counted the way the actions count it.
  ///
  /// Controls were armed from `selection.length` while every action ran on
  /// `selectedPaths()`, which drops directories -- so right-clicking a folder,
  /// the most natural thing to right-click in a file manager, lit Copy, Move
  /// and Delete and then returned without doing or saying anything. Arming and
  /// acting have to be the same expression, so this is that expression.
  ///
  /// Safe to call from a binding: it reads `selection` and `folderModel.count`,
  /// so the binding re-evaluates when either changes.
  function selectedFileCount() { return selectedPaths().length }

  /// True when the selection includes at least one directory. The control that
  /// is refusing needs to be able to say *why* it is refusing, and "you picked
  /// a folder" is a different sentence from "you picked nothing".
  readonly property bool containsDir: {
    for (var i = 0; i < folderModel.count; i++) {
      var n = String(folderModel.get(i, "fileName"))
      if (isSelected(n) && folderModel.get(i, "fileIsDir")) return true
    }
    return false
  }

  /// How many of the rows on screen are directories. The header names files and
  /// folders separately (ADR 0014): `5 items` beside the action bar's `1 file
  /// selected` described two different things in the same breath and read as a
  /// contradiction, and the folder restriction is worth stating before someone
  /// asks for something that will be refused.
  readonly property int dirCount: {
    var n = 0
    for (var i = 0; i < folderModel.count; i++)
      if (folderModel.get(i, "fileIsDir")) n++
    return n
  }

  /// The single file an act-on-one action would act on, or "".
  ///
  /// "Exactly one thing is picked" is not `selectedFileCount() === 1`: a file
  /// and a folder picked together are two things, and one of them is a file.
  /// Rename, Open and Properties arm on this and act on this, so the menu row
  /// and the F2 key cannot disagree about what a mixed selection means.
  function selectedSingleFile() {
    var p = selectedPaths()
    return (p.length === 1 && !containsDir) ? p[0] : ""
  }

  function indexOfName(name) {
    for (var i = 0; i < folderModel.count; i++) {
      if (String(folderModel.get(i, "fileName")) === name) return i
    }
    return -1
  }

  /// Point at files that just arrived: scroll the first of them into view and
  /// flash them all for about two seconds.
  ///
  /// This is the one thing a pane could not do. A row draws no arrival, so a
  /// Replace onto a same-named, same-sized file redrew to identical pixels,
  /// and a newly created file appeared wherever name order put it -- usually
  /// off screen, which is exactly the report the user could not find.
  ///
  /// `names` are bare filenames **as they landed**: pass the Keep-both name
  /// (`landed_as`), not the name that was asked for, or the flash lands on
  /// nothing. `dir` is optional; when given, the reveal is dropped unless this
  /// pane is still showing that directory, so a transfer that finishes after
  /// the user has navigated away does not flash whatever now sits at that name.
  ///
  /// The selection is deliberately left alone: selecting the arrivals would
  /// arm Delete and Move on files the user never picked.
  function reveal(names, dir) {
    if (!names || names.length === 0) return
    if (typeof dir === "string" && dir !== "" && !sameDir(dir, pane.dir)) return
    pendingReveal = names.slice()
    revealAttempts = 0
    // Any flash already running is left to clear on its own timer: stopping it
    // here would strand it lit if this reveal never finds its files.
    if (!showPending(false)) revealRetry.restart()
  }

  function sameDir(a, b) {
    return String(a).replace(/\/+$/, "") === String(b).replace(/\/+$/, "")
  }

  /// Flash pendingReveal once the model can see it. Returns false while the
  /// model is still behind, which is the retry's cue to look again.
  ///
  /// A Job commits its files one rename at a time, so an early attempt can see
  /// two of five. Unless this is the last look (`lastTry`), hold out for the
  /// whole set rather than flashing two files and calling that the report.
  function showPending(lastTry) {
    var found = []
    var first = -1
    for (var i = 0; i < pendingReveal.length; i++) {
      var idx = indexOfName(String(pendingReveal[i]))
      if (idx === -1) continue
      found.push(String(pendingReveal[i]))
      if (first === -1 || idx < first) first = idx
    }
    if (first === -1) return false
    if (found.length < pendingReveal.length && !lastTry) return false
    // Contain, not Beginning: a file already on screen should not make the
    // pane jump under the user.
    list.positionViewAtIndex(first, ListView.Contain)
    revealed = found
    pendingReveal = []
    revealHold.restart()
    return true
  }

  Timer {
    id: revealRetry
    interval: 120
    repeat: true
    onTriggered: {
      pane.revealAttempts++
      // ~1.4s of looking. Past that the files are not coming: the pane is
      // showing somewhere else, or the watcher never saw the write -- inotify
      // does not see what another machine writes to a share.
      var lastTry = pane.revealAttempts >= 12
      if (pane.showPending(lastTry) || lastTry) {
        stop()
        pane.pendingReveal = []
      }
    }
  }

  Timer {
    id: revealHold
    interval: 2000
    onTriggered: pane.revealed = []
  }

  function enter(index) {
    if (index < 0 || index >= folderModel.count) return
    if (!folderModel.get(index, "fileIsDir")) return
    pane.dir = String(folderModel.get(index, "filePath"))
    clearSelection()
  }

  function goUp() {
    var p = String(pane.dir)
    if (p === "/" || p === "") return
    var cut = p.lastIndexOf("/")
    pane.dir = cut > 0 ? p.substring(0, cut) : "/"
    clearSelection()
  }

  FolderListModel {
    id: folderModel
    folder: "file://" + pane.dir
    showDirsFirst: true
    showDotAndDotDot: false
    showHidden: false
    onFolderChanged: {
      pane.clearSelection()
      // A reveal is about one directory. Leaving it armed across a navigation
      // would flash a same-named file somewhere else.
      revealRetry.stop()
      pane.pendingReveal = []
      pane.revealed = []
    }
  }

  // The active pane is marked with an accent edge rather than a border: a box
  // around one of two adjacent panes fights the "two halves of one thing"
  // reading (ticket 08).
  Rectangle {
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
    width: 2
    color: pane.active ? Color.accent : "transparent"
  }

  Item {
    id: header
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 36
    clip: true

    // The path, as segments you can click straight to (ADR 0014). Backspace
    // was the only way up before this, and it has no on-screen affordance --
    // "source and destination selection is not usable" was the user's oldest
    // open complaint about this project.
    Item {
      id: breadcrumbArea
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 14; right: goButton.left; rightMargin: 8 }
      height: 18
      clip: true

      Row {
        id: crumbRow
        // Right-anchored: when the path is wider than the area, the directory
        // actually open matters more than the root, so the tail is what stays
        // on screen rather than eliding it away.
        x: Math.min(0, breadcrumbArea.width - width)
        height: parent.height
        spacing: 2

        Repeater {
          model: pane.crumbs()
          Row {
            id: crumb
            required property var modelData
            required property int index
            spacing: 2
            height: parent.height
            Text {
              visible: crumb.index > 0
              anchors.verticalCenter: parent.verticalCenter
              text: "›"
              color: Color.muted
              font.pixelSize: 11
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: crumb.index > 0 ? 2 : 0
              text: crumb.modelData.label
              color: pane.active ? Color.foreground : Color.muted
              font.pixelSize: 12
              font.bold: pane.active && crumb.index === pane.crumbs().length - 1
              TapHandler { onSingleTapped: pane.dir = crumb.modelData.path }
            }
          }
        }
      }
    }

    // The door itself: a list of places and mounts a pane can jump straight
    // to, independent of the shared sidebar and of which pane is the transfer
    // source. Named "Go" rather than the sidebar's own vocabulary because this
    // is the one word a keyboard-first tool can bind a mnemonic to later.
    Text {
      id: goButton
      anchors { verticalCenter: parent.verticalCenter; right: cnt.left; rightMargin: 10 }
      text: "Go ▾"
      color: goMenu.open ? Color.accent : Color.muted
      font.pixelSize: 11
      TapHandler { onSingleTapped: goMenu.open = !goMenu.open }
    }

    Text {
      id: cnt
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 14 }
      // Files and folders counted separately, and the selection counted the way
      // the actions count it (ADR 0014). This is the one place `selection` may
      // still be read directly -- the header describes what the pane *shows*,
      // not what a control would act on -- which is why scripts/lint-qml.sh
      // exempts this file and only this file.
      text: {
        var files = folderModel.count - pane.dirCount
        var picked = pane.selectedFileCount()
        if (pane.selection.length > 0)
          return picked + " file" + (picked === 1 ? "" : "s") + " of " + files
                 + (pane.containsDir ? " · folder picked" : "")
        return files + " file" + (files === 1 ? "" : "s")
               + (pane.dirCount > 0
                  ? ", " + pane.dirCount + " folder" + (pane.dirCount === 1 ? "" : "s")
                  : "")
      }
      color: pane.selection.length > 0 ? Color.accent : Color.muted
      font.pixelSize: 11
    }
  }

  Rectangle {
    id: rule
    anchors { top: header.bottom; left: parent.left; right: parent.right }
    height: 1
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
  }

  // Lit while a drag would land here, so the destination is visible before
  // the button is released rather than announced afterwards.
  Rectangle {
    anchors.fill: parent
    visible: pane.dropTarget
    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.07)
    border.width: 1
    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
    z: 40
  }

  ListView {
    id: list
    anchors { top: rule.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }
    clip: true
    model: folderModel
    focus: pane.active
    highlightMoveDuration: 0

    delegate: FileRow {
      required property var model
      required property int index

      width: list.width
      fileName: model.fileName
      isDir: model.fileIsDir
      selected: pane.isSelected(model.fileName)
      cursor: pane.active && index === list.currentIndex
      sizeText: model.fileIsDir ? "" : pane.humanSize(model.fileSize)
      timeText: pane.humanTime(model.fileModified)
      flash: pane.isRevealed(model.fileName)

      onClicked: function (ctrl) {
        pane.activated()
        list.currentIndex = index
        if (ctrl) pane.toggle(model.fileName)
        else pane.selectOnly(model.fileName)
      }
      onActivated: {
        pane.activated()
        if (model.fileIsDir) pane.enter(index)
      }
      onContextRequested: function (gx, gy) {
        pane.activated()
        // Right-clicking something unselected acts on it, not on a selection
        // you had forgotten about somewhere off screen.
        if (!pane.isSelected(model.fileName)) pane.selectOnly(model.fileName)
        list.currentIndex = index
        pane.contextRequested(gx, gy)
      }
      onDragStarted: {
        pane.activated()
        if (!pane.isSelected(model.fileName)) pane.selectOnly(model.fileName)
        pane.dragBegan()
      }
      onDragReleased: function (sx, sy) { pane.dragReleased(sx, sy) }
      onDragMoved: function (sx, sy) { pane.dragMoved(sx, sy) }
    }

    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Space) {
        var n = String(folderModel.get(list.currentIndex, "fileName"))
        if (n) pane.toggle(n)
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        pane.enter(list.currentIndex); event.accepted = true
      } else if (event.key === Qt.Key_Backspace) {
        pane.goUp(); event.accepted = true
      } else if (event.key === Qt.Key_Home) {
        pane.moveCursorHome(); event.accepted = true
      } else if (event.key === Qt.Key_End) {
        pane.moveCursorEnd(); event.accepted = true
      } else if (event.key === Qt.Key_PageUp) {
        pane.moveCursorPage(-1); event.accepted = true
      } else if (event.key === Qt.Key_PageDown) {
        pane.moveCursorPage(1); event.accepted = true
      }
    }
  }

  // Declared after the list so it paints over the rows, and last so nothing
  // paints over it except the drop-target wash (z: 40), which covers the pane
  // deliberately. Issue 17: before this, a pane whose header said "40 files"
  // drew nineteen and said nothing about the rest.
  ScrollHint { list: list }

  GoMenu {
    id: goMenu
    places: pane.places
    mounts: pane.mounts
    onChosen: function (path) { pane.dir = path }
  }
}
