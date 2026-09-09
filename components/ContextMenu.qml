pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The right-click menu.
//
// Delete here routes through exactly the same confirmation as the Delete key.
// Two paths to a destructive action is how the first delete gap happened: the
// mechanism existed, one caller used it, and the other did not.
Rectangle {
  id: menu

  /// How many *files* are picked -- the count the actions run on, not the
  /// raw selection. A folder among them is reported through isDir instead,
  /// because a control that refuses has to be able to say why.
  property int count: 0
  /// True when the selection holds a folder. v1 transfers files only.
  property bool isDir: false
  property string directionLabel: "right"
  property bool canTransfer: true

  signal copyRequested()
  signal moveRequested()
  signal openRequested()
  signal renameRequested()
  signal deleteRequested()
  signal propertiesRequested()

  visible: false
  width: 210
  height: col.implicitHeight + 10
  radius: 5
  color: Color.background
  border.width: 1
  border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.20)
  z: 60

  function popupAt(x, y, selCount, dir) {
    count = selCount
    isDir = dir
    // Keep the whole menu on screen rather than letting it run off an edge.
    menu.x = Math.max(0, Math.min(x, parent.width - width - 4))
    menu.y = Math.max(0, Math.min(y, parent.height - height - 4))
    visible = true
  }

  function dismiss() { visible = false }

  Column {
    id: col
    anchors { fill: parent; margins: 5 }
    spacing: 0

    Component.onCompleted: {}

    Repeater {
      model: [
        { key: "copy",   label: "Copy  →  " + menu.directionLabel, danger: false, needsTransfer: true },
        { key: "move",   label: "Move  →  " + menu.directionLabel, danger: false, needsTransfer: true },
        { key: "sep1",   label: "",       danger: false, needsTransfer: false },
        { key: "open",   label: "Open",   danger: false, needsTransfer: false },
        { key: "rename", label: "Rename", danger: false, needsTransfer: false },
        { key: "sep2",   label: "",       danger: false, needsTransfer: false },
        { key: "delete", label: "Delete", danger: true,  needsTransfer: true },
        { key: "sep3",   label: "",       danger: false, needsTransfer: false },
        { key: "props",  label: "Properties", danger: false, needsTransfer: false }
      ]

      Item {
        id: row
        required property var modelData
        width: col.width
        height: modelData.key.indexOf("sep") === 0 ? 7 : 26

        // Rename and Properties act on exactly one thing; the rest act on a
        // selection. An item that cannot do anything is drawn disabled rather
        // than hidden, so the menu does not change shape under the cursor.
        //
        // `count` is files only, so "exactly one thing" is one file with no
        // folder beside it: a file and a folder picked together are two
        // things, whatever the file count says.
        property bool armed: {
          if (modelData.key === "rename" || modelData.key === "props") return menu.count === 1 && !menu.isDir
          if (modelData.key === "open") return menu.count === 1 && !menu.isDir
          if (modelData.needsTransfer) return menu.count > 0 && menu.canTransfer
          return true
        }

        Rectangle {
          visible: row.modelData.key.indexOf("sep") === 0
          anchors.centerIn: parent
          width: parent.width - 12
          height: 1
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
        }

        Rectangle {
          visible: row.modelData.key.indexOf("sep") !== 0
          anchors.fill: parent
          radius: 3
          color: (hov.hovered && row.armed)
            ? (row.modelData.danger
               ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.22)
               : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10))
            : "transparent"
          Text {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 10 }
            text: row.modelData.label
            color: !row.armed ? Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.55)
                 : row.modelData.danger ? Color.urgent
                 : Color.foreground
            font.pixelSize: 12
          }
          HoverHandler { id: hov }
          TapHandler {
            enabled: row.armed
            onSingleTapped: {
              menu.dismiss()
              switch (row.modelData.key) {
              case "copy":   menu.copyRequested(); break
              case "move":   menu.moveRequested(); break
              case "open":   menu.openRequested(); break
              case "rename": menu.renameRequested(); break
              case "delete": menu.deleteRequested(); break
              case "props":  menu.propertiesRequested(); break
              }
            }
          }
        }
      }
    }

    // Why the rows above are dim, or why a folder in a mixed selection is
    // about to be left behind. Decided when the menu opens, so its shape
    // still does not change under the cursor.
    Text {
      visible: menu.isDir
      width: col.width
      leftPadding: 10; rightPadding: 8; topPadding: 4; bottomPadding: 6
      wrapMode: Text.Wrap
      text: "Folders are not transferred in this version"
      color: Color.muted
      font.pixelSize: 11
    }
  }
}
