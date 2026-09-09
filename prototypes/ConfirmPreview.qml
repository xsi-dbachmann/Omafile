pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

import "../components"

// Renders both delete confirmations side by side so the wording can be
// compared without deleting anything. Throwaway.
Rectangle {
  id: root
  color: Color.background

  Text {
    id: cap
    anchors { top: parent.top; topMargin: 10; horizontalCenter: parent.horizontalCenter }
    text: "left: trashable (recoverable)          right: network share (permanent)"
    color: Color.muted
    font.pixelSize: 11
  }

  DeleteConfirm {
    id: a
    anchors { top: cap.bottom; bottom: parent.bottom; left: parent.left }
    width: parent.width / 2
    Component.onCompleted: ask(["holiday-01.mp4", "holiday-02.mp4"], true, "/home/you/Videos")
  }

  DeleteConfirm {
    id: b
    anchors { top: cap.bottom; bottom: parent.bottom; right: parent.right }
    width: parent.width / 2
    Component.onCompleted: ask(
      ["GOPR0477.JPG", "GH010483.MP4", "sample.bin", "extra.raw"],
      false, "//127.0.0.1/omafiletest")
  }
}
