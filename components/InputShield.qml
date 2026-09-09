pragma ComponentBehavior: Bound

import QtQuick

// The surface of a stacked layer, and the thing that actually stops input
// reaching what is underneath it.
//
// Issue 39. Every overlay in this product used to swallow input like this:
//
//     TapHandler { onSingleTapped: {} }
//
// and `Shortcuts.qml` said so in a comment — "swallows every click, so a stray
// press while the sheet is up cannot land on a file row underneath it". That
// was not true, and had never been true.
//
// **A TapHandler's default `gesturePolicy` takes a passive grab on press.** It
// watches the gesture to see whether it becomes a tap; it does not claim the
// press, so delivery carries on to items below, and a `DragHandler` down there
// takes it quite happily.
//
// A `MouseArea` does not fix this, which was the first thing tried here and it
// was watched failing on screen. Qt 6 delivers a press to **every item's
// pointer handlers first**, front to back, and only afterwards to the items
// themselves. A MouseArea is an item, so a `DragHandler` behind it is served
// first however the z-order reads. Shielding against handlers takes a handler.
//
// Watched on 2026-09-09: with the conflict dialog open, a drag begun on a file
// row behind it ran to completion. `beginTransfer` refused the second transfer
// ("Still asking about the last transfer — one at a time"), so no data was at
// risk — but the guard doing the work was the last line of defence rather than
// the first. And on the way through, `DirPane`'s `onDragStarted` emitted
// `pane.activated()`, which `App.qml` answers with `browser.forceActiveFocus()`
// — so the dialog lost the keyboard and **stopped answering `Escape` while
// still printing "Escape cancels"**. Trap 3, reached by a route nobody had
// walked.
//
// `ContextMenu` and `GoMenu` use a full-surface MouseArea scrim, and by the
// reasoning above it cannot stop a drag either. **Watched, not assumed**: with
// the context menu open, a drag on a row behind it copied a file. Both are now
// covered — `contextMenu` through `App.qml`'s `modalOpen`, and `GoMenu` by
// `DirPane` disabling its own list, because that menu is a child of the pane
// and disabling the pane would disable the menu asking the question.
//
// **This component is not the whole fix, and must not be read as one.** It stops
// a press reaching any *item* below — every MouseArea in this window — plus
// hover and the wheel. Stopping a pointer *handler* takes `enabled`, and that
// is `modalOpen`'s job.
//
// `scripts/lint-qml.sh` refuses a root-level `TapHandler` in any component that
// declares a `z:`, so a sixth overlay cannot be written with the hole already
// in it.
Item {
  id: shield

  /// A click on the shield — that is, anywhere on the layer that is not one of
  /// its own controls. Overlays that close on a click outside connect this; the
  /// ones that must be answered deliberately simply do not, and the click is
  /// swallowed.
  signal tapped()

  anchors.fill: parent

  // `gesturePolicy` is the whole fix, and it is the trap from STATE.md wearing
  // the other hat.
  //
  // The DEFAULT policy, `DragThreshold`, takes a **passive** grab: the handler
  // watches to see whether the press becomes a tap, and delivery carries on to
  // everything behind it. That is what the old `TapHandler { onSingleTapped: {} }`
  // was doing, and why it stopped nothing.
  //
  // `WithinBounds` takes an **exclusive** grab on press. This project already
  // learned what that does — on a ListView it killed double-click, and on a
  // pane's root it ate every control inside the pane, and the scrollbar was
  // rewritten three times chasing it. Here that is precisely what is wanted: a
  // modal layer SHOULD kill every control underneath it. Same mechanism, and
  // the difference between a bug and a feature is only where it is attached.
  //
  // A sibling, never an ancestor, of the layer's own controls. The buttons are
  // declared after this and are therefore in front of it, so their handlers are
  // offered the press first and this never reaches them — which is exactly the
  // distinction that made the pane-root version a bug.
  TapHandler {
    // Every button, so a right-press cannot reach a file row behind the dialog
    // and open its context menu.
    acceptedButtons: Qt.AllButtons
    gesturePolicy: TapHandler.WithinBounds
    onTapped: function (point, button) {
      // Only the left button dismisses. A right-click is still swallowed by the
      // grab above, but "I right-clicked" is not "I asked to close this".
      if (button === Qt.LeftButton) shield.tapped()
    }
  }

  // Hover too. Rows lighting up under a modal is the same fault in a quieter
  // register: the layer has claimed the pointer, so it should claim all of it.
  HoverHandler { blocking: true; cursorShape: Qt.ArrowCursor }

  // The wheel is a separate delivery path from press and release, and an
  // unguarded one scrolls the pane behind the sheet.
  WheelHandler {
    // qmllint disable signal-handler-parameters
    onWheel: {}
  }
}
