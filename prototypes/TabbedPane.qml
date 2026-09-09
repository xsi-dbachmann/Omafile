pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Prototype B for ticket 08: one location at a time, tabs to switch.
//
// The argument for it: this is what people expect from a file browser, so the
// learning curve is nil. The argument against: Omafile's whole purpose is the
// two-location case, and here the second location is behind a tab switch --
// the destination is out of sight at the moment you commit to sending files
// to it, and the clipboard has to carry the intent across.
Rectangle {
  id: root
  property string leftDir: ""
  property string rightDir: ""
  property int current: 0
  color: Color.background

  Row {
    id: tabs
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 34
    spacing: 0

    Repeater {
      model: [root.leftDir, root.rightDir]
      Rectangle {
        required property string modelData
        required property int index
        width: 260
        height: tabs.height
        color: index === root.current
          ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
          : "transparent"
        Text {
          anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 14 }
          elide: Text.ElideMiddle
          text: modelData.split("/").pop() || modelData
          color: index === root.current ? Color.foreground : Color.muted
          font.pixelSize: 12
        }
        Rectangle {
          anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
          height: 2
          color: index === root.current ? Color.accent : "transparent"
        }
      }
    }
  }

  PaneListing {
    anchors { top: tabs.bottom; bottom: bar.top; left: parent.left; right: parent.right }
    dir: root.current === 0 ? root.leftDir : root.rightDir
    label: root.current === 0 ? root.leftDir : root.rightDir
    active: true
  }

  // With only one location visible, the action cannot name a destination --
  // it can only put things on a clipboard and hope the user remembers what is
  // on it when they arrive somewhere else.
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
        width: cLabel.width + 28; height: 28; radius: 4
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        Text { id: cLabel; anchors.centerIn: parent; text: "Copy"; color: Color.foreground; font.pixelSize: 12 }
      }
      Rectangle {
        width: xLabel.width + 28; height: 28; radius: 4
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
        Text { id: xLabel; anchors.centerIn: parent; text: "Cut"; color: Color.foreground; font.pixelSize: 12 }
      }
      Rectangle {
        width: pLabel.width + 28; height: 28; radius: 4
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
        Text { id: pLabel; anchors.centerIn: parent; text: "Paste (3 waiting)"; color: Color.muted; font.pixelSize: 12 }
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
