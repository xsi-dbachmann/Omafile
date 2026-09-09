import QtQuick
import qs.Commons

// One row in the listing. Draws what it is given and decides nothing --
// following the convention omamail's AGENTS.md sets out for view components.
//
// Colours come from the active Omarchy theme via Color. There are no literal
// colours here: muted and selected variants are derived from the inherited
// foreground with alpha, so a theme change propagates without edits.
Rectangle {
  id: row

  property string fileName: ""
  property real fileSize: 0
  property bool isDir: false
  property bool selected: false
  /// The keyboard cursor, which is not the same thing as being selected: you
  /// can move over a row without picking it.
  property bool cursor: false
  property string sizeText: ""
  /// When the file last changed, already worded by the pane. A row drew
  /// exactly three things -- glyph, name, size -- so replacing a file with a
  /// same-named, same-sized one redrew to identical pixels and the destination
  /// pane could not show that anything had arrived (rank 6).
  property string timeText: ""
  /// True while the pane is pointing this row out because it just landed here.
  property bool flash: false

  signal activated
  signal clicked(bool ctrl)
  signal contextRequested(real gx, real gy)
  /// Emitted when this row is dragged far enough to mean it. A drag is always
  /// a copy (ADR 0012): dragging is easy to do by accident, and an unwanted
  /// copy costs disk space where an unwanted move relocates your files.
  signal dragStarted
  /// Where the drag was released, in scene coordinates. The window hit-tests
  /// this against its panes.
  ///
  /// Qt's Drag/DropArea machinery is deliberately not used: a DragHandler with
  /// no target never starts a Qt drag, so a DropArea can never receive one —
  /// which is exactly the bug this replaced. Reporting a release point and
  /// letting the window decide is fewer moving parts and does not depend on
  /// mime negotiation for a gesture that never leaves the window.
  signal dragReleased(real sx, real sy)
  signal dragMoved(real sx, real sy)

  height: 30
  color: selected
    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
    : (cursor
       ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)
       : (hover.hovered
          ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
          : "transparent"))

  HoverHandler { id: hover }

  // Columns are a ladder, widest pane first: the name always, then the
  // modified time, then the size. A narrow pane spends its pixels on the name,
  // because the name is the only thing in the row that identifies the file --
  // and in a 264px pane (the 720px minimum window) there is not room for all
  // three. The time outranks the size because it is what says a file just
  // arrived; the size is the least identifying thing here.
  //
  // Both are decided by width alone, never by whether this row has a value:
  // a column that collapses on the rows with nothing to say leaves the names
  // ending at a different x on every line.
  readonly property bool showTime: row.width > 320
  readonly property bool showSize: row.width > 420

  // Lit for a couple of seconds after a transfer landed this file here, so the
  // pane can point at an arrival instead of leaving the user to hunt for it in
  // name order. Drawn before the text so the name stays legible through it.
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.28)
    border.width: 1
    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.60)
    opacity: row.flash ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }
  }

  Text {
    id: glyph
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.leftMargin: 8
    width: 12
    // Kept to plain characters so the row needs no icon font to be legible.
    text: row.isDir ? "▸" : "·"
    color: row.isDir ? Color.accent : Color.muted
    font.pixelSize: 13
  }

  Text {
    id: nameLabel
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: glyph.right
    anchors.leftMargin: 6
    anchors.right: timeLabel.left
    anchors.rightMargin: row.showTime ? 12 : 4
    // ElideMiddle, not ElideRight: the tail of a filename is what identifies
    // it -- the extension, the episode, the camera's sequence number. Same
    // pixels either way, but "Severance.S02E07…FLUX.mkv" can be recognised in
    // the destination pane where "Severance.S02E07.2160p.WEB-DL…" cannot.
    elide: Text.ElideMiddle
    text: row.fileName
    color: Color.foreground
    font.pixelSize: 13
  }

  Text {
    id: timeLabel
    anchors.verticalCenter: parent.verticalCenter
    anchors.right: sizeLabel.left
    anchors.rightMargin: row.showSize ? 12 : 0
    visible: row.showTime
    // Anchors resolve against invisible items too, so a hidden column has to
    // hand its width back explicitly or the name gains nothing by dropping it.
    // The floor keeps the column straight down the pane instead of ragged.
    width: visible ? Math.max(implicitWidth, 52) : 0
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    text: row.timeText
    color: Color.muted
    font.pixelSize: 11
  }

  Text {
    id: sizeLabel
    anchors.verticalCenter: parent.verticalCenter
    anchors.right: parent.right
    anchors.rightMargin: 16
    visible: row.showSize
    width: visible ? Math.max(implicitWidth, 44) : 0
    horizontalAlignment: Text.AlignRight
    text: row.sizeText
    color: Color.muted
    font.pixelSize: 12
  }

  TapHandler {
    acceptedModifiers: Qt.NoModifier
    onSingleTapped: row.clicked(false)
    onDoubleTapped: row.activated()
  }
  TapHandler {
    acceptedModifiers: Qt.ControlModifier
    onSingleTapped: row.clicked(true)
  }

  TapHandler {
    acceptedButtons: Qt.RightButton
    onSingleTapped: function (event) {
      var g = row.mapToItem(null, event.position.x, event.position.y)
      row.contextRequested(g.x, g.y)
    }
  }

  DragHandler {
    id: drag
    target: null
    property real lastX: 0
    property real lastY: 0
    onCentroidChanged: {
      lastX = centroid.scenePosition.x
      lastY = centroid.scenePosition.y
      if (active) row.dragMoved(lastX, lastY)
    }
    onActiveChanged: {
      if (active) row.dragStarted()
      else row.dragReleased(lastX, lastY)
    }
  }
}
