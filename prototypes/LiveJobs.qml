pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons

import "../components"

// The transfer panel from ticket 07, driven by the real omafiled over the real
// socket. Fake data is gone: every row here came off the wire.
Rectangle {
  id: root
  color: Color.background

  DaemonClient { id: daemon }

  Item {
    id: head
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 46
    Text {
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16 }
      text: "Transfers"
      color: Color.foreground; font.pixelSize: 14; font.bold: true
    }
    // Browse-only is stated plainly, with the command, and never as a silent
    // absence (ADR 0006).
    Text {
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
      text: daemon.incompatible !== "" ? daemon.incompatible
          : daemon.canTransfer ? ("omafiled " + daemon.daemonVersion + " · protocol ok")
          : "omafiled not running — transfers unavailable. Build: makepkg -si in packaging/"
      color: daemon.canTransfer ? Color.muted : Color.urgent
      font.pixelSize: 11
    }
  }

  Rectangle {
    id: rule
    anchors { top: head.bottom; left: parent.left; right: parent.right }
    height: 1
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
  }

  Text {
    anchors.centerIn: parent
    visible: daemon.jobs.length === 0
    text: daemon.canTransfer ? "No transfers yet." : "Waiting for omafiled…"
    color: Color.muted
    font.pixelSize: 13
  }

  ListView {
    anchors { top: rule.bottom; bottom: foot.top; left: parent.left; right: parent.right }
    clip: true
    model: daemon.jobs

    delegate: Item {
      required property var modelData
      width: ListView.view.width
      height: 56

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)
      }
      // Progress fills the row; there is no separate bar that could reach the
      // end independently of the thing it describes (ADR 0009).
      Rectangle {
        visible: modelData.phase !== null && modelData.phase !== undefined
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: parent.width * (modelData.done || 0)
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
      }

      Text {
        id: nm
        anchors { left: parent.left; leftMargin: 16; top: parent.top; topMargin: 9 }
        text: modelData.file
        color: Color.foreground; font.pixelSize: 13
      }
      Text {
        anchors { left: parent.left; leftMargin: 16; top: nm.bottom; topMargin: 3 }
        text: modelData.source + "  →  " + modelData.destination
        color: Color.muted; font.pixelSize: 11
        elide: Text.ElideMiddle
        width: parent.width - 320
      }

      Text {
        id: st
        anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 9 }
        text: modelData.error ? "Failed"
            : modelData.tier ? modelData.tier
            : modelData.phase === "verifying" ? "Verifying"
            : "Copying"
        color: modelData.error ? Color.urgent
             : modelData.tier ? Color.accent
             : Color.foreground
        font.pixelSize: 12
        font.bold: !!modelData.tier
      }
      Text {
        anchors { right: parent.right; rightMargin: 16; top: st.bottom; topMargin: 3 }
        text: modelData.error ? modelData.error
            : modelData.detail ? modelData.detail
            : Math.round((modelData.done || 0) * 100) + "%"
        color: Color.muted; font.pixelSize: 11
      }

      Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 1
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
      }
    }
  }

  Rectangle {
    id: foot
    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
    height: 32
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
    Text {
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16 }
      text: "This list is kept for this session only. Interrupted transfers resume; nothing else is stored."
      color: Color.muted; font.pixelSize: 11
    }
    Text {
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
      text: "reconnects: " + daemon.reconnects
      color: Color.muted; font.pixelSize: 11
    }
  }
}
