pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The sign that a list is drawing less than it holds (issue 17).
//
// An indicator, not a control: the lists already scroll by wheel and flick, and
// what was missing was any evidence that there was more of them. A pane read
// "40 files" in its header and drew nineteen, with nothing on screen saying so
// -- the same failure as incident 1, where the destination pane would not
// corroborate what the action bar claimed.
//
// Drawn here rather than pulled from QtQuick.Controls so it takes its colour
// from the theme like everything else in this window, and it is an **overlay**:
// it sits in the 16px gutter FileRow already leaves to the right of the size
// column, so it costs no layout width at all. That is what let issue 17 be
// fixed without spending any of ADR 0014's pixel budget, which is the reason
// the issue was blocked on that decision in the first place.
//
// One component, two lists, because these were nearly two: TransferPanel drew
// this by hand while DirPane a few pixels above it drew nothing, which made the
// omission look deliberate on screen when it was not.
Rectangle {
  id: hint

  /// The list this describes. Must be a sibling: the position is computed in
  /// the shared parent's coordinates, as `y`, not by anchoring vertically.
  required property ListView list

  visible: hint.list.contentHeight > hint.list.height && hint.list.height > 0
  anchors { right: hint.list.right; rightMargin: 3 }
  width: 3
  radius: 1.5
  height: hint.list.contentHeight > 0
    ? Math.max(18, hint.list.height * (hint.list.height / hint.list.contentHeight))
    : 0
  y: hint.list.contentHeight > 0
    ? hint.list.y + Math.max(0, Math.min(hint.list.height - hint.height,
                                         (hint.list.contentY / hint.list.contentHeight) * hint.list.height))
    : hint.list.y
  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.28)
}
