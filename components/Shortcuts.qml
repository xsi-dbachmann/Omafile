pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// What the keyboard does, on demand.
//
// The product is keyboard-first and nothing on screen said so (issue 35). The
// decision this needed was where the pixels come from: ADR 0014 is an explicit
// budget and the bottom of the window is its most contested strip -- the action
// bar's notice already had to be given a row of its own.
//
// So: an overlay, not a permanent bar. It costs nothing until asked for, and
// the discoverability problem that argues against on-demand help is answered by
// a hint in the action bar rather than by a row of keys nobody reads twice.
Rectangle {
  id: sheet

  /// The running plugin version, passed in from App.qml. See the note beside
  /// the line that draws it.
  required property string version

  property bool open: false

  anchors.fill: parent
  visible: open
  // Dim rather than hide: the window stays recognisable behind it, so this
  // reads as a layer over the app and not as a different screen.
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.93)
  z: 200

  // Swallows every click, so a stray press while the sheet is up cannot land
  // on a file row underneath it. That claim was false for two months -- a
  // TapHandler does not stop a drag below it -- and InputShield is what
  // finally makes it true (issue 39).
  InputShield { onTapped: sheet.open = false }

  Column {
    anchors.centerIn: parent
    width: Math.min(560, parent.width - 80)
    spacing: 14

    Text {
      text: "Keyboard"
      color: Color.foreground
      font.pixelSize: 15
      font.bold: true
    }

    /// Which Omafile you are actually looking at.
    ///
    /// It is here rather than in the panel's status line because that line is
    /// shared with the daemon's sentence, and ADR 0014's rule is that a
    /// sentence in a shared line is charged to whatever shares it -- the
    /// first-run instruction is long and must not be elided to make room for a
    /// version. This sheet costs no width and is where you look a thing up.
    ///
    /// `version` is a literal in App.qml, not a runtime read of manifest.json,
    /// so it names the code that is RUNNING. The two differ whenever the plugin
    /// is a symlink into a working tree and the shell has not been restarted --
    /// seven hours and three releases apart, on the day this was added.
    Text {
      text: "Omafile " + sheet.version
      color: Color.muted
      font.pixelSize: 11
    }

    Grid {
      columns: 1
      rowSpacing: 5

      Repeater {
        // Kept as one list so a new binding is added in one place. The order
        // is the order someone learns them in: move, pick, act, undo.
        model: [
          ["Tab", "switch which pane is the source"],
          ["↑ ↓", "move the cursor"],
          ["Home / End", "first / last row"],
          ["PageUp / PageDown", "a screenful"],
          ["Enter", "open a folder, or a file"],
          ["Backspace", "up one folder"],
          ["Alt+← / Alt+→", "back / forward"],
          ["double-click path", "type a path"],
          ["Space", "pick or unpick"],
          ["F3  or  Alt+Space", "preview without opening"],
          ["Ctrl+A", "pick everything here"],
          ["Ctrl+C / Ctrl+M", "copy / move to the other pane"],
          ["Ctrl+K", "checksum for the next transfer"],
          ["Ctrl+D", "pin this folder to the sidebar"],
          // "the files here", not "this folder": FolderListModel's nameFilters
          // never applied to directories, so folders stay listed whatever is
          // typed (issue 04). The strip counts files for the same reason, and
          // is too narrow to say why -- so this is where the rule is stated.
          ["Ctrl+F", "filter the files here"],
          ["Ctrl+H", "show hidden files"],
          ["Ctrl+I", "file-type icons on or off"],
          ["Ctrl+B", "show or hide the sidebar"],
          ["F2", "rename"],
          ["Delete", "delete (trash where possible)"],
          ["Ctrl+Z", "undo the last move or delete"],
          ["Menu / Shift+F10", "context menu"],
          ["?  or  F1", "this list"],
          ["Escape", "close"]
        ]
        // Each cell is the pair, so the key and what it does cannot drift into
        // different rows of the grid.
        Row {
          id: cell
          required property var modelData
          spacing: 10
          Text {
            width: 128
            horizontalAlignment: Text.AlignRight
            text: cell.modelData[0]
            color: Color.accent
            font.pixelSize: 12
            font.family: "monospace"
          }
          Text {
            width: 240
            elide: Text.ElideRight
            text: cell.modelData[1]
            color: Color.foreground
            font.pixelSize: 12
          }
        }
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      text: "In the conflict dialog: K keeps both, S skips. Enter is deliberately "
            + "unbound there — Replace destroys data and must not be reachable by habit."
      color: Color.muted
      font.pixelSize: 11
    }
  }
}
