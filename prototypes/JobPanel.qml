pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Prototype for ticket 07: where a Job lives, and how a completion reads as a
// proof rather than a claim.
//
// The design problem this exists to answer: after ADR 0003 and ticket 05 a
// finished Job has FOUR possible assurance levels, so a single green tick would
// be a claim the product cannot always support. Nautilus showed a bar that
// reached the end and vanished, and it was wrong -- Omafile must not simply
// draw a nicer version of that.
//
// The approach here: every completed row states its tier in words, and the
// words are ranked. Nothing is ever just "done".
Rectangle {
  id: root
  color: Color.background

  // tier: 0 shared extents, 1 checksummed, 2 size-checked, 3 running,
  //       4 verifying, 5 failed, 6 interrupted
  property var jobs: [
    { name: "GH010474.MP4", from: "//nas/home/Drive", to: "~/Documents", tier: 3, pct: 0.62, detail: "987 MB · 41 MB/s · 8s left" },
    { name: "GH010475.MP4", from: "//nas/home/Drive", to: "~/Documents", tier: 4, pct: 0.31, detail: "547 MB · verifying 31%" },
    { name: "GOPR0477.JPG", from: "//nas/home/Drive", to: "~/Documents", tier: 1, pct: 1, detail: "bytes read back and matched the source" },
    { name: "GH010460.MP4", from: "//nas/home/Drive", to: "~/Documents", tier: 2, pct: 1, detail: "404,625,057 bytes, exactly as expected" },
    { name: "project-archive/", from: "~/Work", to: "~/Backup", tier: 0, pct: 1, detail: "same data as the source — cannot diverge" },
    { name: "GH010489.MP4", from: "//nas/home/Drive", to: "~/Documents", tier: 5, pct: 0.88, detail: "checksum mismatch on retry — nothing was written" },
    { name: "GH010491.MP4", from: "//nas/home/Drive", to: "~/Documents", tier: 6, pct: 0.44, detail: "resumable from 44%" }
  ]

  function tierLabel(t) {
    return ["Shared extents", "Checksummed", "Size checked", "Copying",
            "Verifying", "Failed", "Interrupted"][t]
  }
  function tierColor(t) {
    if (t === 5) return Color.urgent
    if (t === 6) return Color.muted
    if (t <= 2) return Color.accent
    return Color.foreground
  }

  Item {
    id: head
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 42
    Text {
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16 }
      text: "Transfers"
      color: Color.foreground
      font.pixelSize: 14
      font.bold: true
    }
    Text {
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
      text: "2 running · 5 finished this session"
      color: Color.muted
      font.pixelSize: 11
    }
  }

  Rectangle {
    id: headRule
    anchors { top: head.bottom; left: parent.left; right: parent.right }
    height: 1
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
  }

  ListView {
    anchors { top: headRule.bottom; bottom: foot.top; left: parent.left; right: parent.right }
    clip: true
    model: root.jobs
    spacing: 0

    delegate: Item {
      required property var modelData
      width: ListView.view.width
      height: 56

      // Progress is drawn as a filled region behind the row rather than as a
      // separate bar. A bar that fills and vanishes is the thing that lied;
      // this keeps the row itself the object, and the fill is an attribute of
      // it rather than a widget that can complete independently.
      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)
      }
      Rectangle {
        visible: modelData.tier >= 3 && modelData.tier <= 4
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: parent.width * modelData.pct
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
      }

      Text {
        id: nameText
        anchors { left: parent.left; leftMargin: 16; top: parent.top; topMargin: 9 }
        text: modelData.name
        color: Color.foreground
        font.pixelSize: 13
      }
      Text {
        anchors { left: parent.left; leftMargin: 16; top: nameText.bottom; topMargin: 3 }
        text: modelData.from + "  →  " + modelData.to
        color: Color.muted
        font.pixelSize: 11
      }

      // The tier, stated in words, on every row. This is the whole point: a
      // finished Job never says only "done", it says what was actually
      // established about it.
      Text {
        id: tierText
        anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 9 }
        text: root.tierLabel(modelData.tier)
        color: root.tierColor(modelData.tier)
        font.pixelSize: 12
        font.bold: modelData.tier <= 2
      }
      Text {
        anchors { right: parent.right; rightMargin: 16; top: tierText.bottom; topMargin: 3 }
        text: modelData.detail
        color: Color.muted
        font.pixelSize: 11
      }

      Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 1
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
      }
    }
  }

  // The session note is not decoration. It tells the user, before they go
  // looking, that this list is the only record and it ends with the window --
  // the direct consequence of the no-durable-history decision.
  Rectangle {
    id: foot
    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
    height: 32
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
    Text {
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16 }
      text: "This list is kept for this session only. Interrupted transfers resume; nothing else is stored."
      color: Color.muted
      font.pixelSize: 11
    }
  }
}
