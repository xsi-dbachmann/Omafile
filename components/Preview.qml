pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons

// Look at a file without opening it (issue 37).
//
// Four questions had to be answered before this could exist, and the answers
// are the reason it is this small.
//
// **The key.** `Space` is picking and cannot move -- it is the oldest binding
// here and every multi-file transfer depends on it. `Alt+Space`, as the person
// who asked for this suggested.
//
// **Which types.** Images and text. Not PDF: rendering one needs a library, and
// taking a dependency is an ADR-sized decision for a plugin whose pitch is that
// you can review what it installs (ADR 0006). Anything else says what it is and
// points at Enter, which opens it in whatever the system uses -- a preview that
// admits it cannot preview something is better than a blank rectangle.
//
// **The stalled-mount hazard, which is the one that matters.** Reading a file to
// show it is exactly the operation that hangs on a dead SMB share, and hanging
// the UI thread is the one thing ticket 12's measurements said must never
// happen. So: images load through `Image` with `asynchronous: true`, and text is
// read by a **Process** rather than by any synchronous file API. `head -c` also
// gives the size cap for free -- a preview must never read a 2 GB file to show
// the first screenful of it.
//
// **Cursor row, not selection.** Preview is a "look at this one" gesture, which
// is what the cursor means; the selection is what the transfer buttons act on,
// and this product has been careful to keep those apart.
Rectangle {
  id: sheet

  property bool open: false
  /// Absolute path of the file to show. Setting it does not open the sheet.
  property string path: ""
  readonly property string fileName: sheet.path.substring(sheet.path.lastIndexOf("/") + 1)

  /// How much text is ever read. One screenful is the point; the rest is what
  /// opening the file is for.
  readonly property int textCap: 65536

  FileKind { id: kinds }
  readonly property string ext: kinds.extensionOf(sheet.fileName)
  readonly property bool isImage: ["jpg","jpeg","png","gif","webp","bmp","svg"].indexOf(sheet.ext) !== -1
  readonly property bool isText: ["txt","md","log","csv","json","toml","yaml","yml",
                                  "js","ts","py","rs","sh","c","h","cpp","qml",
                                  "html","css","conf","ini"].indexOf(sheet.ext) !== -1

  anchors.fill: parent
  visible: sheet.open
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.95)
  z: 190

  onOpenChanged: {
    textView.text = ""
    if (sheet.open && sheet.isText && sheet.path !== "") {
      reader.command = ["head", "-c", String(sheet.textCap), sheet.path]
      reader.running = true
    }
  }

  Process {
    id: reader
    running: false
    stdout: StdioCollector {
      onStreamFinished: textView.text = this.text
    }
  }

  InputShield { onTapped: sheet.open = false }

  Text {
    id: title
    anchors { top: parent.top; topMargin: 18; horizontalCenter: parent.horizontalCenter }
    width: parent.width - 60
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideMiddle
    text: sheet.fileName
    color: Color.foreground
    font.pixelSize: 13
    font.bold: true
  }

  Item {
    id: body
    anchors { top: title.bottom; topMargin: 14; bottom: hint.top; bottomMargin: 14
              left: parent.left; leftMargin: 30; right: parent.right; rightMargin: 30 }

    Image {
      anchors.fill: parent
      visible: sheet.isImage
      // Asynchronous, always: a large image off a slow mount would otherwise
      // freeze the window while it decoded.
      asynchronous: true
      fillMode: Image.PreserveAspectFit
      // Decode to the size actually shown. Without this a 60-megapixel photo is
      // decoded at full resolution to be drawn 600px wide.
      sourceSize.width: Math.max(1, body.width)
      sourceSize.height: Math.max(1, body.height)
      source: sheet.open && sheet.isImage ? "file://" + sheet.path : ""
    }

    Flickable {
      anchors.fill: parent
      visible: sheet.isText
      contentWidth: width
      contentHeight: textView.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      Text {
        id: textView
        width: parent.width
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        color: Color.foreground
        font.pixelSize: 11
        font.family: "monospace"
      }
    }

    Text {
      anchors.centerIn: parent
      visible: !sheet.isImage && !sheet.isText
      horizontalAlignment: Text.AlignHCenter
      text: sheet.ext === ""
        ? "No preview for this file"
        : "No preview for ." + sheet.ext + " files"
      color: Color.muted
      font.pixelSize: 12
    }
  }

  Text {
    id: hint
    anchors { bottom: parent.bottom; bottomMargin: 16; horizontalCenter: parent.horizontalCenter }
    text: (sheet.isText ? "First 64 KB · " : "") + "Enter opens it · Escape closes"
    color: Color.muted
    font.pixelSize: 10
  }
}
