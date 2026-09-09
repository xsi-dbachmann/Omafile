pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The sign that a list is drawing less than it holds (issue 17), and — since
// the second hands-on session — something you can actually grab.
//
// It began as an indicator and nothing else: a pane read "40 files" in its
// header and drew nineteen, with nothing on screen saying so. That is the same
// failure as incident 1, where the destination pane would not corroborate what
// the action bar claimed.
//
// It stayed 3px wide because it is an **overlay**: it sits in the 16px gutter
// FileRow already leaves to the right of the size column, so it costs no layout
// width at all. That is what let issue 17 be fixed without spending any of
// ADR 0014's pixel budget, which is why the issue was blocked on that decision.
//
// "scrollbar is too tight, can not be clicked nicely with mouse" — correct, and
// the fix costs nothing either: **the hit area is 14px and still fits inside
// that same 16px gutter**, so it is grabbable while the drawn thumb stays thin.
// The thumb thickens while hovered or dragged, so the target announces itself
// rather than being a 3px line you are expected to guess at.
//
// Drawn here rather than pulled from QtQuick.Controls so it takes its colour
// from the theme like everything else in this window.
//
// One component, two lists, because these were nearly two: TransferPanel drew
// this by hand while DirPane a few pixels above it drew nothing, which made the
// omission look deliberate on screen when it was not.
Item {
  id: hint

  /// The list this describes. Must be a sibling: the position is computed in
  /// the shared parent's coordinates.
  required property ListView list

  readonly property bool overflowing: hint.list.contentHeight > hint.list.height
                                      && hint.list.height > 0
  readonly property real trackHeight: hint.list.height
  readonly property real thumbHeight: hint.list.contentHeight > 0
    ? Math.max(18, hint.trackHeight * (hint.trackHeight / hint.list.contentHeight))
    : 0
  /// How far the content can travel, and how far the thumb can, in the same
  /// order. Both are needed in three places; computing them twice is how a
  /// scrollbar ends up disagreeing with the list it describes.
  readonly property real maxContentY: Math.max(0, hint.list.contentHeight - hint.list.height)
  readonly property real maxThumbY: Math.max(0, hint.trackHeight - hint.thumbHeight)

  visible: hint.overflowing
  // The hit area spans the whole track and the full width of the gutter. The
  // gutter is 16px, so 14 leaves the rows untouched.
  anchors { right: hint.list.right }
  y: hint.list.y
  width: 14
  height: hint.trackHeight

  Rectangle {
    id: thumb
    anchors.right: parent.right
    anchors.rightMargin: 3
    // Thin at rest, thicker under the pointer: the target says it is one.
    width: (mouse.containsMouse || mouse.pressed) ? 6 : 3
    radius: width / 2
    height: hint.thumbHeight
    y: hint.maxContentY > 0
      ? (hint.list.contentY / hint.maxContentY) * hint.maxThumbY
      : 0
    color: (mouse.containsMouse || mouse.pressed)
      ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.55)
      : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.28)

    Behavior on width { NumberAnimation { duration: 90 } }
  }

  /// A MouseArea, not a DragHandler.
  ///
  /// The DragHandler version never scrolled: watched failing twice, once via
  /// `centroid` and once via `activeTranslation`, with a 300px drag starting on
  /// the thumb leaving the list on exactly the same rows. The divider grip in
  /// App.qml has been dragged successfully since 2026-09-08 and it is a
  /// MouseArea with onPressed/onPositionChanged, so this is the idiom known to
  /// work here rather than the one that ought to.
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    /// Without this the grab is lost the moment the pointer leaves the 14px
    /// strip sideways -- "scrolling is impossible because the user needs to
    /// follow the scroll direction exactly, if not it looses scrollbar".
    ///
    /// Nobody drags a scrollbar in a perfectly straight line, and nobody
    /// should have to: once the thumb is held, every vertical movement belongs
    /// to it until the button comes up, wherever the pointer wanders. This is
    /// the switch that says an ancestor may not take the grab away mid-drag.
    preventStealing: true

    property real grabY: 0
    property real grabContentY: 0
    property bool onThumb: false

    onPressed: function (m) {
      mouse.onThumb = m.y >= thumb.y && m.y <= thumb.y + thumb.height
      mouse.grabY = m.y
      mouse.grabContentY = hint.list.contentY
    }

    onPositionChanged: function (m) {
      if (!mouse.pressed || !mouse.onThumb || hint.maxThumbY <= 0) return
      // A delta from where the grab began, never the pointer's absolute
      // position: anchoring to the pointer makes the thumb jump under the
      // cursor on the first pixel of movement.
      var moved = ((m.y - mouse.grabY) / hint.maxThumbY) * hint.maxContentY
      hint.list.contentY = Math.max(0, Math.min(hint.maxContentY,
                                                mouse.grabContentY + moved))
    }

    /// Clicking the track pages toward the click, the way a scrollbar does.
    /// Never jumps to the position: a page is undoable by clicking the other
    /// side of the thumb, and a jump loses your place with no way back.
    onClicked: function (m) {
      if (mouse.onThumb) return
      if (m.y < thumb.y)
        hint.list.contentY = Math.max(0, hint.list.contentY - hint.list.height)
      else
        hint.list.contentY = Math.min(hint.maxContentY,
                                      hint.list.contentY + hint.list.height)
    }
  }
}
