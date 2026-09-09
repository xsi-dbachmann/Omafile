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
  /// Whether the pane holding this row is the focused one. Focus is expressed
  /// as brightness (issue 39), and a pane whose background dims while its text
  /// stays at full strength looks like a rendering fault rather than a state:
  /// the text has to recede with it. `dim` is the single factor every colour
  /// here is multiplied through, so the two can never drift apart.
  property bool paneActive: true
  /// Icons on or off, from the window's persisted setting. Off falls back to
  /// the original two characters, so turning them off is not a downgrade to
  /// nothing -- it is the older, plainer row.
  property bool showIcons: true
  readonly property real dim: paneActive ? 1.0 : 0.55

  /// The colour actually behind this row's text, which is what legibility is
  /// measured against. Passed in because a row cannot see its pane's
  /// background, and guessing it is how a size column ends up invisible.
  property color surface: Color.background

  /// Issue 05. `dim` used to be an ALPHA -- `Qt.rgba(Color.muted.r, .g, .b,
  /// 0.55)` -- which composites toward whatever is behind. On a dark ground
  /// that moves a light grey toward black and the gap survives; on a light one
  /// it moves a mid grey toward near-white and the gap closes. Measured under
  /// Flexoki Light: the Modified and Size columns came out at **1.0:1**, text
  /// the same luminance as its row. One operation, opposite outcomes, decided
  /// by a theme this component never sees.
  ///
  /// Receding is now expressed as less contrast against `surface`, which means
  /// the same thing on both grounds, with a floor it will not go below. The
  /// floors differ because the columns do: a file's name is what you read, its
  /// time and size are what you check.
  ///
  /// `Contrast` is imported for the arithmetic and tested without a display,
  /// for the same reason `Wording` is.
  readonly property color nameColor: fileContrast.recede(Color.foreground, row.surface, 1 - row.dim, 3.5)
  readonly property color metaColor: fileContrast.recede(Color.muted, row.surface, 1 - row.dim, 2.5)
  readonly property color kindColor: fileContrast.recede(Color.accent, row.surface, 1 - row.dim, 2.5)

  Contrast { id: fileContrast }

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
    anchors.leftMargin: 18
    width: 14
    // What the row IS. Whether it is *picked* is the mark to the left of this,
    // and they were the same character until issue 36: three facts in one 8px
    // glyph is why nobody could read any of them.
    text: row.showIcons ? kinds.iconFor(row.fileName, row.isDir)
                        : (row.isDir ? "▸" : "·")
    // The Nerd Font by name, not by hoping the default family has the glyph: a
    // missing codepoint renders as a tofu box, which is worse than the plain
    // character this replaces. Omarchy's own bar already loads this family.
    font.family: row.showIcons ? "JetBrainsMono Nerd Font" : nameLabel.font.family
    color: row.isDir ? row.kindColor : row.metaColor
    font.pixelSize: 13
  }

  FileKind { id: kinds }

  /// Picked, as a fact of its own.
  ///
  /// The row's background already tints when selected, but a tint is a weak
  /// signal against a theme that may be light or dark, and it was carrying the
  /// whole meaning. A mark says it outright, in a column the kind glyph does
  /// not share.
  Text {
    id: pick
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.leftMargin: 6
    width: 10
    visible: row.selected
    text: "✓"
    color: row.kindColor
    font.pixelSize: 11
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
    color: row.nameColor
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
    color: row.metaColor
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
    color: row.metaColor
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
