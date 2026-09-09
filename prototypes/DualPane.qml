pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Prototype A for ticket 08: two locations visible at once.
//
// The argument for it: Omafile's purpose is moving things between two places,
// so both places are on screen and the transfer direction is a fact of the
// layout rather than something you hold in your head. Drag-and-drop becomes
// meaningful. The argument against: unfamiliar to anyone expecting Nautilus.
Rectangle {
  id: root
  property string leftDir: ""
  property string rightDir: ""
  color: Color.background

  PaneListing {
    id: left
    anchors { top: parent.top; bottom: bar.top; left: parent.left }
    width: (parent.width - divider.width) / 2
    dir: root.leftDir
    label: root.leftDir
    active: true
  }

  Rectangle {
    id: divider
    anchors { top: parent.top; bottom: bar.top; left: left.right }
    width: 1
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
  }

  PaneListing {
    anchors { top: parent.top; bottom: bar.top; left: divider.right; right: parent.right }
    dir: root.rightDir
    label: root.rightDir
    active: false
  }

  // The action bar states the direction explicitly. In a dual-pane layout the
  // direction is implied by which pane is active, and "implied" is how you get
  // a file copied the wrong way.
  Rectangle {
    id: bar
    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
    height: 46
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)

    Text {
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16 }
      text: "3 items selected"
      color: Color.muted
      font.pixelSize: 12
    }

    Row {
      anchors.centerIn: parent
      spacing: 10
      Rectangle {
        width: copyLabel.width + 28; height: 28; radius: 4
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        Text {
          id: copyLabel
          anchors.centerIn: parent
          text: "Copy  →  right"
          color: Color.foreground
          font.pixelSize: 12
        }
      }
      Rectangle {
        width: moveLabel.width + 28; height: 28; radius: 4
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
        Text {
          id: moveLabel
          anchors.centerIn: parent
          text: "Move  →  right"
          color: Color.foreground
          font.pixelSize: 12
        }
      }
    }

    Text {
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
      text: "✓ checksum off"
      color: Color.muted
      font.pixelSize: 11
    }
  }
}
