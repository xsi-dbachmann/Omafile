pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Where a transfer begins.
//
// The whole argument for dual-pane was that the destination is a fact of the
// layout, so the buttons can name both ends: "Copy → right". That is why there
// is no confirmation dialog — the button already states the direction and the
// destination, and a second "are you sure" adds nothing (ticket 08).
Rectangle {
  id: bar

  /// Files picked -- what Copy, Move and Delete will actually act on.
  property int selectedCount: 0
  /// A folder is among what is picked. Says why the count is short.
  property bool containsDir: false
  property string directionLabel: "right"
  /// The x of the pane the actions would act on, in this bar's coordinates.
  /// The buttons align to it so they sit under the pane they affect rather
  /// than in a fixed corner: which pane is the source is the single most
  /// important fact in a dual-pane transfer, and the controls now state it by
  /// where they are as well as by what they say.
  property real sourceX: 0
  /// True when the source is the left pane. The summary moves to the opposite
  /// side of the buttons, which is the only place always guaranteed to have
  /// room at the 720px minimum (ADR 0014).
  property bool sourceIsLeft: true
  property bool checksum: false
  property bool canTransfer: true
  property string reason: ""
  property string notice: ""
  /// How the notice should read: "ok" — it happened and it went well;
  /// "warn" — nothing happened, or a plain fact; "bad" — it failed, or it
  /// destroyed something. The colour comes from this and not from
  /// `notice !== ""`, which drew every refusal and every failure in the
  /// success colour.
  property string noticeRole: "ok"
  /// Bumped by the writer on every notice, including one that repeats the
  /// previous words.
  property int noticeSeq: 0
  /// Empty when there is nothing to take back.
  property string undoLabel: ""
  /// False while the put-back is on its way to the daemon: the button keeps
  /// its place and reports what it is doing rather than disappearing.
  property bool undoArmed: true

  signal copyRequested()
  signal moveRequested()
  signal checksumToggled()
  signal undoRequested()
  signal deleteRequested()

  // 46 for the controls, 20 for the notice's own row (ADR 0014). Constant, not
  // grown when a notice arrives: a bar that changes height every time something
  // is said would reflow the panes under the reader's eyes six seconds later,
  // when the notice expires.
  height: 66
  readonly property int controlsHeight: 46
  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)

  // A repeat is still a second event. Five trash deletes wrote the same string
  // five times and nothing on screen changed, which is how one delete and five
  // deletes came to look identical.
  onNoticeSeqChanged: if (bar.notice !== "") noticeFlash.restart()

  SequentialAnimation {
    id: noticeFlash
    NumberAnimation { target: noticeText; property: "opacity"; to: 0.0; duration: 80 }
    NumberAnimation { target: noticeText; property: "opacity"; to: 1.0; duration: 200 }
  }

  // The controls row resolves right-to-left: the checksum chip is a fixed fact,
  // the buttons take what they need beside it, and the selection summary gets
  // the rest.
  //
  // It used to centre the buttons over a notice box of a fixed 320px. At the
  // shipped 1100 the two overlapped from x 273, and the buttons are declared
  // later, so they painted on top of the sentence explaining what had just
  // happened; at the 720 minimum the Move button also overlapped the checksum
  // chip. Anchoring removed all three collisions by construction.
  //
  // What anchoring could not fix is that the notice shared this line. Measured
  // at the 720 minimum on 2026-09-08: **265px** for the notice with no undo
  // entry, **83px** — about eleven characters — with one, because the undo
  // button's width is a *filename*. Every refusal watched that day was cut
  // there: `Could not p...`, `omafiled an...`. The product's only channel for
  // saying no was narrowest exactly when it had something to say, so it has its
  // own row now (ADR 0014).
  Item {
    id: controls
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: bar.controlsHeight

  Text {
    id: summaryText
    // Opposite the buttons: left of them when the source is the right pane,
    // right of them when it is the left. Anchored both sides so it elides
    // instead of colliding, which is the failure ADR 0014 exists to prevent.
    anchors {
      verticalCenter: parent.verticalCenter
      left: bar.sourceIsLeft ? btnRow.right : parent.left
      leftMargin: bar.sourceIsLeft ? 14 : 16
      right: bar.sourceIsLeft ? rightGroup.left : btnRow.left
      rightMargin: 12
    }
    horizontalAlignment: bar.sourceIsLeft ? Text.AlignLeft : Text.AlignRight
    elide: Text.ElideRight
    text: bar.selectedCount === 0
          ? (bar.containsDir ? "Folders are not transferred in this version" : "Nothing selected")
        : bar.selectedCount + (bar.selectedCount === 1 ? " file selected" : " files selected")
          + (bar.containsDir ? " — folders are not transferred" : "")
    color: bar.selectedCount === 0 ? Color.muted : Color.foreground
    font.pixelSize: 12
  }

  Row {
    id: btnRow
    anchors {
      verticalCenter: parent.verticalCenter
      // Pinned to the source pane, but never past the right group.
      left: parent.left
      leftMargin: Math.max(16, Math.min(bar.sourceX, rightGroup.x - width - 12))
    }
    spacing: 10

    Rectangle {
      id: copyBtn
      width: copyText.width + 30; height: 30; radius: 4
      property bool armed: bar.selectedCount > 0 && bar.canTransfer
      color: armed
        ? (copyHover.hovered ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.30)
                             : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18))
        : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
      Text {
        id: copyText
        anchors.centerIn: parent
        text: "Copy  →  " + bar.directionLabel
        color: copyBtn.armed ? Color.foreground : Color.muted
        font.pixelSize: 12
      }
      HoverHandler { id: copyHover; enabled: copyBtn.armed }
      TapHandler { enabled: copyBtn.armed; onSingleTapped: bar.copyRequested() }
    }

    Rectangle {
      id: delBtn
      width: delText.width + 26; height: 30; radius: 4
      property bool armed: bar.selectedCount > 0 && bar.canTransfer
      color: armed
        ? (delHover.hovered ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.26)
                            : Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.14))
        : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
      Text {
        id: delText
        anchors.centerIn: parent
        text: "Delete"
        color: delBtn.armed ? Color.foreground : Color.muted
        font.pixelSize: 12
      }
      HoverHandler { id: delHover; enabled: delBtn.armed }
      TapHandler { enabled: delBtn.armed; onSingleTapped: bar.deleteRequested() }
    }

    // The label already names the outcome — "Put report.pdf back", "Move
    // report.pdf back" — so there is no "Undo " prefix in front of it. Log
    // grammar ("Undo Delete of report.pdf") names the thing being reversed;
    // this names what pressing it does, which is the same rule the delete
    // dialog's own confirm button follows. Ctrl+Z is taught by the notices.
    Rectangle {
      id: undoBtn
      visible: bar.undoLabel !== ""
      width: undoText.width + 26; height: 30; radius: 4
      color: !bar.undoArmed
        ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
        : (undoHover.hovered
           ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
           : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08))
      Text {
        id: undoText
        anchors.centerIn: parent
        text: bar.undoLabel
        color: bar.undoArmed ? Color.foreground : Color.muted
        font.pixelSize: 12
      }
      HoverHandler { id: undoHover; enabled: bar.undoArmed }
      TapHandler { enabled: bar.undoArmed; onSingleTapped: bar.undoRequested() }
    }

    Rectangle {
      id: moveBtn
      width: moveText.width + 30; height: 30; radius: 4
      property bool armed: bar.selectedCount > 0 && bar.canTransfer
      color: armed
        ? (moveHover.hovered ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
                             : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08))
        : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
      Text {
        id: moveText
        anchors.centerIn: parent
        text: "Move  →  " + bar.directionLabel
        color: moveBtn.armed ? Color.foreground : Color.muted
        font.pixelSize: 12
      }
      HoverHandler { id: moveHover; enabled: moveBtn.armed }
      TapHandler { enabled: moveBtn.armed; onSingleTapped: bar.moveRequested() }
    }
  }

  // The per-job checksum override lives here, beside the button that starts
  // the Job — visible at the moment of commitment (ADR 0008). This group is
  // the bar's fixed right edge; everything else is placed against it.
  Row {
    id: rightGroup
    anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
    spacing: 8

    // Capped, because everything else in the bar is now placed against this
    // group's left edge: an un-elided daemon-down sentence is wide enough to
    // push the buttons off the left of a 720px window and leave the notice no
    // room at all. The full sentence has a home in the transfer panel header,
    // which has the width for it.
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !bar.canTransfer
      width: Math.min(implicitWidth, bar.width * 0.24)
      elide: Text.ElideRight
      text: bar.reason
      color: Color.urgent
      font.pixelSize: 11
    }

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      visible: bar.canTransfer
      width: ckText.width + 22; height: 24; radius: 3
      color: bar.checksum
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
      Text {
        id: ckText
        anchors.centerIn: parent
        text: bar.checksum ? "checksum on" : "checksum off"
        color: bar.checksum ? Color.accent : Color.muted
        font.pixelSize: 11
      }
      TapHandler { onSingleTapped: bar.checksumToggled() }
    }
  }

  }  // controls

  // The notice's own row: the whole width of the window, whatever the buttons
  // are doing above it. This is where a refusal gets to be a sentence.
  Text {
    id: noticeText
    anchors {
      top: controls.bottom
      left: parent.left; leftMargin: 16
      right: parent.right; rightMargin: 16
    }
    height: bar.height - bar.controlsHeight
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
    text: bar.notice
    color: bar.noticeRole === "bad" ? Color.urgent
         : bar.noticeRole === "warn" ? Color.foreground
         : Color.accent
    font.pixelSize: 12
  }
}
