pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The Job list, inside the browser window.
//
// The Job is the product's central noun, so it lives in the product's window
// rather than in a bar popup, which would make the thing Omafile is *for* into
// a peripheral notification (ticket 07).
Rectangle {
  id: panel

  property var jobs: []
  property bool daemonLive: false
  property string daemonNote: ""

  /// Issue 28: Job ids the daemon is safe to forget right now, computed by
  /// `App.qml` (which alone knows whether an undo is still waiting on one).
  /// The footer's clear control only ever acts on this list, not on every
  /// finished row — arming and acting are the same expression here for the
  /// same reason `scripts/lint-qml.sh` requires it of `DirPane`'s controls.
  property var dismissableJobIds: []
  signal dismissRequested(string jobId)

  // One row, one Job. Named because three separate things measure against it:
  // the delegate, the fold count in the header, and the panel's own height.
  readonly property int rowHeight: 44
  readonly property int headHeight: 30
  readonly property int footHeight: 22

  /// The tallest this panel may grow. 40% of the window by default, taken from
  /// the parent because that is what the panel is laid out against — override
  /// it if this is ever put inside something whose height depends on its
  /// children, which would make the binding circular.
  property real maxHeight: panel.parent ? panel.parent.height * 0.4 : 288

  // Height follows content, bounded at both ends. The panel used to be a fixed
  // 172px: 52px of chrome against a 44px row left a 120px viewport, so it
  // showed 2.7 rows at every window size — simultaneously too small to hold a
  // session's transfers and too big to sit under two panes at the 480px
  // minimum window, where its fixed chrome was 45% of the height. Empty, it now
  // costs 52px and gives the other 120 back to the panes (7 file rows → 11).
  implicitHeight: Math.min(panel.headHeight + panel.footHeight + panel.jobs.length * panel.rowHeight,
                           Math.max(panel.headHeight + panel.footHeight, panel.maxHeight))

  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.02)

  // Rows the viewport cannot show, counted rather than left to be discovered.
  // A panel that silently hides the row you came to read is the failure this
  // header exists to prevent; the list auto-follows the newest Job, so what is
  // out of view is usually *above*, which is why the side is named.
  readonly property int hiddenAbove:
    Math.max(0, Math.floor(Math.max(0, list.contentY) / panel.rowHeight))
  readonly property int hiddenBelow:
    Math.max(0, panel.jobs.length
                - Math.ceil((Math.max(0, list.contentY) + list.height) / panel.rowHeight))
  readonly property string foldNote: {
    if (panel.hiddenAbove > 0 && panel.hiddenBelow > 0)
      return " (" + (panel.hiddenAbove + panel.hiddenBelow) + " hidden)"
    if (panel.hiddenAbove > 0) return " (" + panel.hiddenAbove + " above)"
    if (panel.hiddenBelow > 0) return " (" + panel.hiddenBelow + " below)"
    return ""
  }

  // Jobs are appended newest-last and nothing scrolled, so from the third Job
  // of a session onward the one that just finished — or just failed — was below
  // the fold. Follow the tail when the list grows and when a Job settles.
  property int _seenCount: 0
  property int _settledCount: 0

  function showNewest() { list.positionViewAtEnd() }

  onJobsChanged: {
    var settled = 0
    for (var i = 0; i < panel.jobs.length; i++) {
      var j = panel.jobs[i]
      if (j && (j.error || j.tier)) settled++
    }
    if (panel.jobs.length !== panel._seenCount || settled !== panel._settledCount) {
      panel._seenCount = panel.jobs.length
      panel._settledCount = settled
      // The view has not re-laid-out yet: contentHeight is still the old one,
      // so positioning now would scroll to where the end used to be.
      Qt.callLater(panel.showNewest)
    }
  }

  Item {
    id: head
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: panel.headHeight
    Text {
      id: title
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16 }
      text: panel.jobs.length === 0
        ? "Transfers · none yet"
        : "Transfers · " + panel.jobs.length + panel.foldNote
      color: Color.foreground; font.pixelSize: 12; font.bold: true
    }
    Text {
      // Bounded against the title rather than left to overlap it: a protocol
      // mismatch puts a long sentence here, and this panel's whole complaint
      // was text painting over other text.
      anchors { verticalCenter: parent.verticalCenter
                left: title.right; leftMargin: 16
                right: parent.right; rightMargin: 16 }
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      text: panel.daemonNote
      color: panel.daemonLive ? Color.muted : Color.urgent
      font.pixelSize: 11
    }
  }

  ListView {
    id: list
    anchors { top: head.bottom; bottom: foot.top; left: parent.left; right: parent.right }
    clip: true
    model: panel.jobs

    delegate: Item {
      id: jobRow
      required property var modelData
      width: ListView.view.width
      height: panel.rowHeight

      // The rung this Job's completion word sits on, 3 strongest, 0 for a word
      // that is not on the ladder at all. "Moved" is a verb and "Nothing
      // copied" is the absence of work, so the daemon sends no strength for
      // either (ADR 0003, rank 12). A daemon too old to send the field lands
      // here as 0 as well, which draws every word unranked rather than wrongly
      // ranked.
      readonly property int strength:
        (typeof modelData.strength === "number"
         && modelData.strength >= 1 && modelData.strength <= 3)
          ? modelData.strength : 0
      readonly property bool graded: jobRow.strength > 0 && !modelData.error

      // Progress fills the row. There is no separate bar that could reach the
      // end independently of the thing it describes (ADR 0009).
      Rectangle {
        visible: jobRow.modelData.phase !== null && jobRow.modelData.phase !== undefined
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: parent.width * (jobRow.modelData.done || 0)
        color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
      }

      Text {
        id: nm
        anchors { left: parent.left; leftMargin: 16
                  right: mark.left; rightMargin: 16
                  top: parent.top; topMargin: 6 }
        // The middle goes, never the tail: the extension is the part that
        // identifies the file.
        elide: Text.ElideMiddle
        text: jobRow.modelData.files_total > 1
          ? (jobRow.modelData.label + "  ·  " + jobRow.modelData.file)
          : jobRow.modelData.file
        color: Color.foreground; font.pixelSize: 12
      }
      Text {
        anchors { left: parent.left; leftMargin: 16
                  right: detail.left; rightMargin: 16
                  top: nm.bottom; topMargin: 2 }
        // Was `width: parent.width - 340`, a guess at how much room the
        // right-hand column wanted; the failure sentence needs 348px, so at the
        // 720px minimum window it painted over the destination path. Both
        // columns are now anchored to each other and neither can reach the
        // other's pixels.
        elide: Text.ElideMiddle
        text: jobRow.modelData.destination
        color: Color.muted; font.pixelSize: 10
      }

      // The rank, drawn as three fixed slots: the mark's width never changes,
      // only how much of it is filled, so the ladder is comparable between two
      // rows without reading either word. Three filled is the strongest claim
      // in the product. Words alone could not carry this — all four completion
      // words drew identically, and the strongest one reads as the most
      // obscure (ADR 0009's own consequence).
      Row {
        id: mark
        visible: jobRow.graded
        width: jobRow.graded ? implicitWidth : 0
        anchors { right: st.left; rightMargin: jobRow.graded ? 8 : 0
                  verticalCenter: st.verticalCenter }
        spacing: 3
        Repeater {
          model: 3
          Rectangle {
            required property int index
            width: 5; height: 5; radius: 2.5
            // Filled from the weakest rung up.
            color: index < jobRow.strength
              ? Color.accent
              : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
          }
        }
      }

      // No row ever says only "done": a tier is a statement of what was
      // established (ADR 0009).
      Text {
        id: st
        anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 6 }
        text: jobRow.modelData.error ? "Failed"
            : jobRow.modelData.tier ? jobRow.modelData.tier
            : jobRow.modelData.phase === "verifying" ? "Verifying"
            : "Copying"
        // The accent marks a grade. "Moved" wearing it is what made four
        // unrelated words read as one ladder; it is a verb, so it draws in the
        // ordinary foreground and carries no mark.
        color: jobRow.modelData.error ? Color.urgent
             : jobRow.graded ? Color.accent
             : Color.foreground
        font.pixelSize: 11
        font.bold: !!jobRow.modelData.tier
      }
      Text {
        id: detail
        anchors { right: parent.right; rightMargin: 16; top: st.bottom; topMargin: 2 }
        // Capped at a share of the row and elided. This is the longest string
        // the panel ever draws — a failure sentence names the files that were
        // never attempted — and it used to have no width at all.
        width: Math.min(implicitWidth, jobRow.width * 0.45)
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        // Files never attempted are named, because silently doing less than
        // was asked is its own kind of lie (ADR 0008).
        text: jobRow.modelData.error
              ? (jobRow.modelData.error
                 + (jobRow.modelData.files_skipped > 0
                    ? "  ·  stopped, " + jobRow.modelData.files_skipped + " not attempted"
                    : ""))
            : jobRow.modelData.detail
              ? (jobRow.modelData.detail
                 + (jobRow.modelData.files_total > 1
                    ? "  ·  " + jobRow.modelData.files_total + " files" : "")
                 // A transfer that changed things is not the same as one that
                 // only added things, and the panel says which (ADR 0013).
                 + (jobRow.modelData.files_replaced > 0
                    ? "  ·  " + jobRow.modelData.files_replaced + " replaced" : "")
                 + (jobRow.modelData.files_skipped_existing > 0
                    ? "  ·  " + jobRow.modelData.files_skipped_existing + " left alone" : ""))
            : (jobRow.modelData.files_total > 1
               ? (jobRow.modelData.files_done + " of " + jobRow.modelData.files_total + "  ·  "
                  + Math.round((jobRow.modelData.done || 0) * 100) + "%")
               : Math.round((jobRow.modelData.done || 0) * 100) + "%")
        color: Color.muted; font.pixelSize: 10
      }

      Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 1
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
      }
    }
  }

  // The same indicator the panes use, and the same component, so the two
  // cannot drift apart again (issue 17).
  ScrollHint { list: list }

  // States the rule before anyone goes looking for last week's transfer.
  Item {
    id: foot
    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
    height: panel.footHeight
    Text {
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16
                right: clearFinished.visible ? clearFinished.left : parent.right
                rightMargin: clearFinished.visible ? 16 : 16 }
      elide: Text.ElideRight
      text: "Kept for this session only. Interrupted transfers resume; nothing else is stored."
      color: Color.muted; font.pixelSize: 10
    }
    // One button for every dismissable row rather than one per row: a
    // per-row control would have to fit inside a 44px row already carrying
    // two columns of text (ADR 0014's pixel budget), and "forget everything
    // safe to forget" is the whole of what issue 28 needed a UI trigger for.
    Text {
      id: clearFinished
      visible: panel.dismissableJobIds.length > 0
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
      text: "Clear finished"
      color: clearArea.containsMouse ? Color.foreground : Color.accent
      font.pixelSize: 10; font.underline: clearArea.containsMouse
      MouseArea {
        id: clearArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          // A snapshot, not a live binding: dismissing the first id can change
          // `dismissableJobIds` (a job it was blocking) before the loop reaches
          // the rest, and iterating the property directly would then skip or
          // reread a shifting array mid-loop.
          var ids = panel.dismissableJobIds.slice()
          for (var i = 0; i < ids.length; i++) panel.dismissRequested(ids[i])
        }
      }
    }
  }
}
