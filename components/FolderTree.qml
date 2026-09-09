pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import qs.Commons

// The sidebar's tree, held flat.
//
// "feels strange not to see tree". It lives in the sidebar and not in a pane,
// and that is a decision: ADR 0008 and the dual-pane choice rest on the
// destination being a fact of the layout, which is what lets a button read
// "Copy → right" with no confirmation dialog. A pane showing three directories
// at once would stop "the other pane" naming a location and make that sentence
// false. The sidebar has no such duty -- choosing in it sets a pane's directory,
// exactly as Places already did.
//
// **Flat, not recursive.** The obvious shape is a component that instantiates
// itself once per child; QML refuses it outright ("TreeNode is instantiated
// recursively"), and the Loader-by-URL trick that gets around the refusal
// turns every live binding into a one-shot value. So the tree is a ListModel of
// visible rows carrying their own depth, and expanding a row splices its
// children in beneath it. One ListView, which also means the tree scrolls and
// is virtualised rather than building every open branch as real items.
//
// A collapsed row costs one ListElement and no directory listing at all.
Item {
  id: tree

  /// Roots to show. `[{ name, path }]`.
  property var roots: []
  property string currentDir: ""
  property bool showHidden: false

  signal chosen(string path)

  ListModel { id: rows }

  /// One lister, reused. Expanding is click-driven, so at most one listing is
  /// ever in flight, and a model per open folder would keep a file watcher per
  /// open folder for the life of the session.
  FolderListModel {
    id: lister
    showFiles: false
    showDotAndDotDot: false
    showHidden: tree.showHidden
    sortField: FolderListModel.Name
    onStatusChanged: if (lister.status === FolderListModel.Ready) tree._insertChildren()
  }

  property int _pendingRow: -1

  function _rebuildRoots() {
    rows.clear()
    for (var i = 0; i < tree.roots.length; i++)
      rows.append({ path: String(tree.roots[i].path), label: String(tree.roots[i].name),
                    depth: 0, expanded: false })
  }
  onRootsChanged: tree._rebuildRoots()
  Component.onCompleted: tree._rebuildRoots()

  function toggle(row) {
    if (row < 0 || row >= rows.count) return
    if (rows.get(row).expanded) { tree._collapse(row); return }
    // Point the lister at it; the children arrive in _insertChildren().
    tree._pendingRow = row
    lister.folder = "file://" + rows.get(row).path
  }

  function _insertChildren() {
    var row = tree._pendingRow
    tree._pendingRow = -1
    if (row < 0 || row >= rows.count) return
    var depth = rows.get(row).depth
    for (var i = 0; i < lister.count; i++) {
      rows.insert(row + 1 + i, {
        path: String(lister.get(i, "filePath")),
        label: String(lister.get(i, "fileName")),
        depth: depth + 1,
        expanded: false
      })
    }
    rows.setProperty(row, "expanded", true)
  }

  /// Removes everything deeper than this row, not just its direct children:
  /// collapsing a branch has to take the grandchildren an earlier expansion
  /// put there, or they are left orphaned at a depth with no parent above them.
  function _collapse(row) {
    var depth = rows.get(row).depth
    while (row + 1 < rows.count && rows.get(row + 1).depth > depth)
      rows.remove(row + 1)
    rows.setProperty(row, "expanded", false)
  }

  /// A Column of Repeater rows, not a ListView.
  ///
  /// The sidebar already scrolls, and a ListView inside a scrolling Column has
  /// to be given a height it cannot know. Sizing to content and letting the
  /// sidebar scroll is the arrangement that has one scrollbar in it rather than
  /// two. Virtualisation is given up, and it costs nothing worth having: only
  /// rows the user has opened exist at all.
  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: tree.width

    Repeater {
      model: rows
      Rectangle {
        id: node
        required property int index
        required property string path
        required property string label
        required property int depth
        required property bool expanded

        width: tree.width
        height: 24
        color: tree.currentDir === node.path
          ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
          : (hov.hovered ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                         : "transparent")

        /// The twisty is a separate target from the name, because they are
        /// different intentions: opening a folder to see what is in it is not
        /// the same as going there, and a tree that conflates them navigates
        /// away from where you are every time you explore.
        Text {
          id: twisty
          anchors { verticalCenter: parent.verticalCenter; left: parent.left }
          anchors.leftMargin: 8 + node.depth * 11
          width: 12
          text: node.expanded ? "▾" : "▸"
          color: Color.muted
          font.pixelSize: 10
          TapHandler { onSingleTapped: tree.toggle(node.index) }
        }

        Text {
          anchors { verticalCenter: parent.verticalCenter; left: twisty.right
                    leftMargin: 2; right: parent.right; rightMargin: 8 }
          elide: Text.ElideRight
          text: node.label
          color: tree.currentDir === node.path ? Color.accent : Color.foreground
          font.pixelSize: 12
          TapHandler { onSingleTapped: tree.chosen(node.path) }
        }

        HoverHandler { id: hov }
      }
    }
  }
}
