pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// A pane's own door to the places and shares Locations.qml already knows
// about (ADR 0014). It exists apart from the shared sidebar for two reasons:
// a pane should be reachable without the sidebar being open, and jumping a
// pane here must not change which pane is the transfer source the way
// choosing a place in the sidebar does.
Item {
  id: menu

  property bool open: false
  property var places: []
  property var mounts: []
  signal chosen(string path)

  // Fills the pane so a click anywhere outside the panel closes it, the same
  // way ContextMenu's scrim does.
  anchors.fill: parent
  visible: open
  z: 60

  MouseArea {
    anchors.fill: parent
    onClicked: menu.open = false
  }

  Rectangle {
    id: panel
    anchors { top: parent.top; left: parent.left; topMargin: 36; leftMargin: 6 }
    width: 220
    height: Math.max(40, Math.min(list.contentHeight + 8, 260))
    radius: 4
    color: Color.background
    border.width: 1
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.20)

    ListView {
      id: list
      anchors.fill: parent
      anchors.margins: 4
      clip: true
      model: menu.places.concat(menu.mounts)

      delegate: Rectangle {
        id: row
        required property var modelData
        width: list.width
        height: 26
        color: hov.hovered
          ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
          : "transparent"
        Text {
          anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 8; right: parent.right; rightMargin: 8 }
          elide: Text.ElideMiddle
          text: row.modelData.name
          color: Color.foreground
          font.pixelSize: 12
        }
        HoverHandler { id: hov }
        TapHandler {
          onSingleTapped: {
            menu.chosen(row.modelData.path)
            menu.open = false
          }
        }
      }

      // Said plainly rather than left empty: an unmounted share reads
      // differently from "this door is broken".
      Text {
        visible: list.count === 0
        anchors { top: parent.top; topMargin: 6; left: parent.left; leftMargin: 8; right: parent.right; rightMargin: 8 }
        wrapMode: Text.WordWrap
        text: "Nothing to jump to yet."
        color: Color.muted
        font.pixelSize: 11
      }
    }

    ScrollHint { list: list }
  }
}
