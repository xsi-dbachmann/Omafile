pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Rename, asked for in a dialog rather than edited in place.
//
// In-place editing in a list is nicer, but it makes "am I typing a filename or
// a keyboard shortcut" ambiguous in a browser where Space, Delete and Ctrl+C
// all do things. A dialog is unambiguous about where keystrokes go.
Rectangle {
  id: dialog

  property string path: ""
  property string original: ""
  property string errorText: ""

  signal accepted(string newName)
  signal cancelled()

  visible: false
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.82)
  z: 90

  function ask(p) {
    path = p
    original = String(p).split("/").pop()
    errorText = ""
    field.text = original
    visible = true
    field.forceActiveFocus()
    // Select the stem, not the extension: renaming usually means changing the
    // name and keeping the type.
    var dot = original.lastIndexOf(".")
    if (dot > 0) field.select(0, dot)
    else field.selectAll()
  }

  function fail(message) { errorText = message; visible = true; field.forceActiveFocus() }
  function done() { visible = false; errorText = "" }

  InputShield {}

  Rectangle {
    anchors.centerIn: parent
    width: 420
    height: 168
    radius: 6
    color: Color.background
    border.width: 1
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.20)

    Text {
      id: heading
      anchors { top: parent.top; topMargin: 18; left: parent.left; leftMargin: 20 }
      text: "Rename"
      color: Color.foreground
      font.pixelSize: 15
      font.bold: true
    }

    Rectangle {
      id: fieldBox
      anchors { top: heading.bottom; topMargin: 14; left: parent.left; leftMargin: 20; right: parent.right; rightMargin: 20 }
      height: 34
      radius: 4
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.07)
      border.width: 1
      border.color: dialog.errorText !== ""
        ? Color.urgent
        : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)

      TextInput {
        id: field
        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
        verticalAlignment: TextInput.AlignVCenter
        color: Color.foreground
        selectionColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.40)
        selectByMouse: true
        font.pixelSize: 13
        onTextChanged: dialog.errorText = ""
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) { dialog.done(); dialog.cancelled(); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (text.length > 0 && text !== dialog.original) dialog.accepted(text)
            else { dialog.done(); dialog.cancelled() }
            event.accepted = true
          }
        }
      }
    }

    Text {
      anchors { top: fieldBox.bottom; topMargin: 8; left: parent.left; leftMargin: 20; right: parent.right; rightMargin: 20 }
      wrapMode: Text.WordWrap
      // The daemon's refusal is shown verbatim rather than reworded: it already
      // says exactly what was wrong, and paraphrasing it here would be a second
      // place for the two to disagree.
      text: dialog.errorText !== "" ? dialog.errorText : "Enter to rename, Escape to cancel."
      color: dialog.errorText !== "" ? Color.urgent : Color.muted
      font.pixelSize: 11
    }
  }
}
