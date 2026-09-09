pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import qs.Commons

// The column labels, and the only way to sort.
//
// There were no column headers at all: three columns of data with nothing
// naming them, which is half of why "with the dot it is not clear if it is a
// selection, folder or file" (issue 36) was hard to answer by looking. And
// FolderListModel was left at its default sort — name, ascending, forever —
// so "which of these is biggest" and "what changed today" were unanswerable in
// a file manager.
//
// One row answers both: the labels say what the columns are, and clicking one
// sorts by it. Sort is a window-level setting rather than per-pane, because
// comparing two directories is the entire point of dual-pane and two panes
// sorted differently cannot be compared.
//
// The widths here mirror FileRow's exactly. They are the same layout drawn
// twice, which is a standing hazard: a change to one that misses the other
// makes the header point at the wrong column. FileRow is the source of truth
// and these constants exist only because a header is not a row.
Item {
  id: head

  /// FolderListModel.Name / Time / Size. Mirrors the pane's model.
  required property int sortField
  required property bool sortReversed
  /// Kept in step with FileRow's own thresholds so a hidden column has no label.
  property real rowWidth: head.width
  property bool paneActive: true

  signal sortRequested(int field)

  readonly property bool showTime: head.rowWidth > 320
  readonly property bool showSize: head.rowWidth > 420
  readonly property real dim: head.paneActive ? 1.0 : 0.55

  /// Which way the list is actually ordered right now.
  ///
  /// Not simply `!sortReversed`. FolderListModel's unreversed order is not the
  /// same direction for every field, measured rather than assumed: with
  /// sortReversed false, Name lists A→Z but Size lists largest-first and Time
  /// lists newest-first. Deriving the arrow from sortReversed alone drew "Size
  /// ↑" above a list running 84 MB → 10 B, which is a label stating the
  /// opposite of what is on screen — the exact class of falsehood this project
  /// exists to refuse.
  readonly property bool ascending: {
    var baseAscending = (head.sortField === FolderListModel.Name)
    return head.sortReversed ? !baseAscending : baseAscending
  }

  implicitHeight: 22

  component Label: Text {
    id: lbl
    required property int field
    required property string caption
    font.pixelSize: 10
    // The arrow marks the sorted column and states the direction. Without it a
    // sorted list is indistinguishable from an unsorted one that happens to
    // look ordered.
    text: lbl.caption + (head.sortField === lbl.field
                         ? (head.ascending ? "  ↑" : "  ↓") : "")
    color: head.sortField === lbl.field
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, head.dim)
      : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, head.dim * (hov.hovered ? 1.0 : 0.75))
    HoverHandler { id: hov }
    TapHandler { onSingleTapped: head.sortRequested(lbl.field) }
  }

  Label {
    id: nameLabel
    anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 26 }
    field: FolderListModel.Name
    caption: "Name"
  }

  Label {
    id: timeLabel
    anchors { verticalCenter: parent.verticalCenter
              right: sizeLabel.left; rightMargin: head.showSize ? 12 : 0 }
    visible: head.showTime
    // A fixed width, not Math.max(implicitWidth, ...). That form loops here:
    // the label elides, so its implicitWidth answers a question that depends on
    // its width. FileRow gets away with it; a header carrying a sort arrow that
    // appears and disappears does not. Right-aligned, so the columns still line
    // up with the rows whatever the caption measures.
    width: visible ? 66 : 0
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    field: FolderListModel.Time
    caption: "Modified"
  }

  Label {
    id: sizeLabel
    anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 16 }
    visible: head.showSize
    width: visible ? 52 : 0
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    field: FolderListModel.Size
    caption: "Size"
  }

  Rectangle {
    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
    height: 1
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.07)
  }
}
