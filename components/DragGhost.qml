pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// What is under the cursor during a drag, and what releasing it would do.
//
// Issue 19 item 2, from the first driven run: *"would be nice to see the file
// under mouse during drag, maybe with a copy label."* Until this existed a drag
// moved nothing on screen at all — `FileRow`'s `DragHandler` has `target: null`
// by design, so the row stays put — and the only feedback was the destination
// pane's wash, which says *where* but never *what* or *what to*.
//
// The label matters more than the picture. ADR 0012 makes a drag **always a
// copy**, and that rule was stated only in the notice that appears *after* the
// drop, when the Job has already been asked for. A rule you read after the fact
// is not a rule you can act on: this is its one chance to be read while the
// button is still down.
//
// It is drawn, not dragged. Qt's Drag/DropArea machinery is not used here for
// the same reason `FileRow` does not use it (see that file): a targetless
// DragHandler starts no Qt drag, so there is nothing for Qt to render. The
// window feeds this a scene point and a sentence, and it follows.
Rectangle {
  id: ghost

  /// Scene coordinates of the pointer, as `FileRow` reports them.
  property real pointerX: 0
  property real pointerY: 0
  /// The sentence, from `Wording::dragPhrase()`, which is where its arithmetic
  /// is tested. Nothing here decides what it says.
  property string label: ""
  /// A drag that can do nothing wherever it lands — a folder, or an empty
  /// selection. Different from one merely not aimed at a pane yet, which is a
  /// normal state on the way to a destination.
  property bool blocked: false
  /// The kind glyph, for a single-file drag. Empty for several files, because
  /// one file's icon standing for four would name the wrong thing.
  property string icon: ""

  // Below the pointer and to its right, because the cursor hotspot is its
  // top-left corner and a label centred on it would be the thing the cursor
  // covers. Clamped so a drag towards an edge does not push the sentence off
  // the window — the same reason ContextMenu::popupAt clamps.
  readonly property point local: ghost.parent
    ? ghost.parent.mapFromItem(null, ghost.pointerX, ghost.pointerY)
    : Qt.point(0, 0)
  x: Math.max(2, Math.min(ghost.local.x + 15, (ghost.parent ? ghost.parent.width : 0) - ghost.width - 2))
  y: Math.max(2, Math.min(ghost.local.y + 13, (ghost.parent ? ghost.parent.height : 0) - ghost.height - 2))

  width: body.implicitWidth + 20
  height: 26
  radius: 5

  // Lighter than the *active* pane (1.45), so it reads as floating above either
  // pane rather than merging into whichever one it happens to be over. The
  // neutral surface is deliberate: the accent is for outcomes, and nothing has
  // happened yet.
  color: Qt.lighter(Color.background, 1.6)
  border.width: 1
  border.color: ghost.blocked
    ? Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.45)
    : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.28)

  Row {
    id: body
    anchors.centerIn: parent
    spacing: 7

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: ghost.icon !== "" && !ghost.blocked
      text: ghost.icon
      color: Color.muted
      font.family: "JetBrainsMono Nerd Font"
      font.pixelSize: 13
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: ghost.label
      // Muted while blocked: a refusal should recede, not shout. `Color.urgent`
      // is this product's word for destroying data (DeleteConfirm) and a drag
      // that will politely do nothing has not earned it.
      color: ghost.blocked ? Color.muted : Color.foreground
      font.pixelSize: 12
    }
  }
}
