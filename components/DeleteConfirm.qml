pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Asks before deleting, and asks *differently* depending on whether the file
// can come back.
//
// ADR 0009 required this and it was missed on the first pass: Delete went
// straight through to the daemon, so a permanent deletion on a network share
// happened on one keypress with no warning. The after-the-fact notice in the
// action bar is not a substitute for asking first.
//
// The two cases are deliberately not the same dialog with a different noun.
// A recoverable delete is routine and the wording is calm; a permanent one
// names the place the files are leaving and colours the confirm button with
// the urgent role, because it is the one action in Omafile that destroys data.
Rectangle {
  id: dialog

  property var paths: []
  property bool recoverable: true
  property string location: ""

  signal confirmed()
  signal cancelled()

  visible: false
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.82)

  function ask(pathList, canTrash, where) {
    paths = pathList
    recoverable = canTrash
    location = where
    visible = true
    focusCatcher.forceActiveFocus()
  }

  function accept() { visible = false; confirmed() }
  function reject() { visible = false; cancelled() }

  // Swallow clicks so nothing behind the scrim can be touched while a
  // destructive question is on screen.
  // Declared here rather than at the use site, like every other stacked layer
  // in this repo. It had been set only in App.qml, which is one fact in two
  // places -- and it was also the reason the issue 39 lint rule could not see
  // this file, since that rule keys on a component declaring its own z.
  z: 100

  // Swallows the click: the one action here that destroys data must not be
  // dismissable by a stray press, in either direction.
  InputShield {}

  Item {
    id: focusCatcher
    anchors.fill: parent
    focus: dialog.visible
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Escape) { dialog.reject(); event.accepted = true }
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        // Enter confirms only when the action is reversible. A permanent
        // delete must be clicked or tabbed to deliberately -- muscle memory
        // should not be able to destroy data.
        if (dialog.recoverable) { dialog.accept(); event.accepted = true }
      }
    }
  }

  Rectangle {
    anchors.centerIn: parent
    width: 460
    // The where-line only exists in the permanent case, so the box has to grow
    // for it rather than assume a fixed body.
    height: title.implicitHeight + body.implicitHeight
            + (whereLine.visible ? whereLine.implicitHeight + 10 : 0) + 110
    radius: 6
    color: Color.background
    border.width: 1
    border.color: dialog.recoverable
      ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.20)
      : Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.55)

    Text {
      id: title
      anchors { top: parent.top; topMargin: 20; left: parent.left; leftMargin: 22; right: parent.right; rightMargin: 22 }
      wrapMode: Text.WordWrap
      text: dialog.recoverable
        ? (dialog.paths.length === 1
            ? "Move to trash?"
            : "Move " + dialog.paths.length + " items to trash?")
        : (dialog.paths.length === 1
            ? "Delete permanently?"
            : "Delete " + dialog.paths.length + " items permanently?")
      color: dialog.recoverable ? Color.foreground : Color.urgent
      font.pixelSize: 15
      font.bold: true
    }

    Text {
      id: body
      anchors { top: title.bottom; topMargin: 10; left: parent.left; leftMargin: 22; right: parent.right; rightMargin: 22 }
      wrapMode: Text.WordWrap
      // Consequence first. This body used to open with the raw mount path and
      // leave "this cannot be undone" as a trailing clause — which is how a
      // permanent delete on a share got read as the routine kind. What happens
      // to the data leads, the reason follows it, and the place it happens is
      // the dim line under the names, where it cannot displace either.
      //
      // The plural was wrong too: "You can put this back" appeared under
      // "Move 5 items to trash?".
      text: (dialog.recoverable
             ? (dialog.paths.length === 1
                ? "You can put this back with Ctrl+Z, or from the trash later."
                : "You can put these back with Ctrl+Z, or from the trash later.")
             : (dialog.paths.length === 1
                ? "This file is gone for good — there is no trash here to put it back from."
                : "These files are gone for good — there is no trash here to put them back from."))
            + "\n\n"
            + dialog.paths.slice(0, 3).map(function (p) { return String(p).split("/").pop() }).join("\n")
            + (dialog.paths.length > 3 ? "\n… and " + (dialog.paths.length - 3) + " more" : "")
      color: Color.muted
      font.pixelSize: 12
      lineHeight: 1.25
    }

    // Where it happens: context for the sentence above, not the first thing to
    // read, so it is dim, small and last. Only the permanent case shows it —
    // a trash delete does not need to name the place, because nothing is
    // leaving for good. Elided in the middle because the part that identifies
    // a share is the mount root and the leaf, not the run of folders between.
    Text {
      id: whereLine
      visible: !dialog.recoverable && dialog.location !== ""
      anchors { top: body.bottom; topMargin: 10; left: parent.left; leftMargin: 22; right: parent.right; rightMargin: 22 }
      elide: Text.ElideMiddle
      text: dialog.location
      color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.70)
      font.pixelSize: 11
    }

    Row {
      anchors { bottom: parent.bottom; bottomMargin: 18; right: parent.right; rightMargin: 22 }
      spacing: 10

      Rectangle {
        width: cancelText.width + 30; height: 32; radius: 4
        color: cancelHover.hovered
          ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
          : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
        Text { id: cancelText; anchors.centerIn: parent; text: "Cancel"; color: Color.foreground; font.pixelSize: 12 }
        HoverHandler { id: cancelHover }
        TapHandler { onSingleTapped: dialog.reject() }
      }

      Rectangle {
        width: okText.width + 30; height: 32; radius: 4
        color: dialog.recoverable
          ? (okHover.hovered ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.32)
                             : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.20))
          : (okHover.hovered ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.42)
                             : Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.26))
        Text {
          id: okText
          anchors.centerIn: parent
          // The button names the outcome, not "OK". You should be able to read
          // only the button and know what happens.
          text: dialog.recoverable ? "Move to trash" : "Delete permanently"
          color: Color.foreground
          font.pixelSize: 12
          font.bold: !dialog.recoverable
        }
        HoverHandler { id: okHover }
        TapHandler { onSingleTapped: dialog.accept() }
      }
    }
  }
}
