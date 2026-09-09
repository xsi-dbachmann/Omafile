pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import qs.Commons

import "../components"

// A single directory listing with its own path bar. Shared by both pane-model
// prototypes so the comparison is about layout, not about two different list
// implementations. Throwaway: ticket 08.
Rectangle {
  id: pane

  property string dir: ""
  property bool active: false
  property string label: ""

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

  FolderListModel {
    id: folderModel
    folder: "file://" + pane.dir
    showDirsFirst: true
    showDotAndDotDot: false
    showHidden: false
  }

  // The active pane is marked by a left accent edge rather than a full border:
  // a border on one of two adjacent panes reads as a box around it, which
  // fights the "these are two halves of one thing" reading.
  Rectangle {
    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
    width: 2
    color: pane.active ? Color.accent : "transparent"
  }

  Item {
    id: header
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 38

    Text {
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 14 }
      text: pane.label
      color: pane.active ? Color.foreground : Color.muted
      font.pixelSize: 12
      font.bold: pane.active
    }
    Text {
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 14 }
      text: folderModel.count + " items"
      color: Color.muted
      font.pixelSize: 11
    }
  }

  Rectangle {
    id: rule
    anchors { top: header.bottom; left: parent.left; right: parent.right }
    height: 1
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
  }

  ListView {
    anchors { top: rule.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }
    clip: true
    model: folderModel
    delegate: FileRow {
      required property var model
      required property int index
      width: ListView.view.width
      fileName: model.fileName
      isDir: model.fileIsDir
      selected: pane.active && index < 3
      sizeText: model.fileIsDir ? "" : pane.humanSize(model.fileSize)
    }
  }
}
