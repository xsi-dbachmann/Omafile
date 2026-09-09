pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Ticket 12: measure the QML side of the socket before the protocol is locked.
//
// No Omarchy plugin has used Quickshell's Socket, so the event rate at which
// the UI starts to stutter is unknown. That number decides the protocol: the
// daemon must coalesce below it, on the daemon side, not the client side.
//
// Throwaway. Drive it with prototypes/ipc/emit.py.
Rectangle {
  id: root
  color: Color.background

  property string sockPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omafile-probe.sock"

  property int received: 0
  property int lastSeq: -1
  property int gaps: 0
  property real startedAt: 0
  property real eventsPerSec: 0

  // Frame timing is the actual measurement. Counting events only says the
  // socket kept up; it says nothing about whether the desktop stayed smooth,
  // which is the entire reason the daemon is a separate process.
  property int frames: 0
  property real worstFrameMs: 0
  property int jankFrames: 0     // over 33ms, i.e. a dropped frame at 30fps
  property int badFrames: 0      // over 100ms, visible stutter

  FrameAnimation {
    running: true
    onTriggered: {
      var ms = frameTime * 1000
      root.frames++
      // Ignore the first frames while the scene warms up.
      if (root.frames > 30) {
        if (ms > root.worstFrameMs) root.worstFrameMs = ms
        if (ms > 33) root.jankFrames++
        if (ms > 100) root.badFrames++
      }
    }
  }

  Timer {
    interval: 1000; running: true; repeat: true
    onTriggered: {
      if (root.startedAt > 0) {
        var secs = (Date.now() - root.startedAt) / 1000
        root.eventsPerSec = secs > 0 ? root.received / secs : 0
      }
    }
  }

  Socket {
    id: sock
    path: root.sockPath
    connected: true

    parser: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (root.startedAt === 0) root.startedAt = Date.now()
        root.received++
        // Parsing every event is the realistic case: a client that only counts
        // bytes would flatter the protocol.
        try {
          var m = JSON.parse(line)
          if (root.lastSeq >= 0 && m.seq !== root.lastSeq + 1) root.gaps++
          root.lastSeq = m.seq
          // Touch the UI the way a real progress row would.
          bar.width = root.width * m.done
          fileLabel.text = m.file
        } catch (e) {
          root.gaps++
        }
      }
    }
  }

  Column {
    anchors { fill: parent; margins: 24 }
    spacing: 10

    Text {
      text: sock.connected ? "connected — " + root.sockPath : "waiting for " + root.sockPath
      color: sock.connected ? Color.accent : Color.muted
      font.pixelSize: 13
    }
    Text { id: fileLabel; text: "—"; color: Color.foreground; font.pixelSize: 16 }

    Rectangle {
      width: parent.width; height: 6
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
      Rectangle { id: bar; height: parent.height; width: 0; color: Color.accent }
    }

    Text {
      text: "events received: " + root.received + "   (" + root.eventsPerSec.toFixed(0) + "/s)   sequence gaps: " + root.gaps
      color: Color.foreground; font.pixelSize: 13
    }
    Text {
      text: "frames: " + root.frames
            + "   worst frame: " + root.worstFrameMs.toFixed(1) + " ms"
            + "   >33ms: " + root.jankFrames
            + "   >100ms: " + root.badFrames
      color: root.badFrames > 0 ? Color.urgent : Color.foreground
      font.pixelSize: 13
    }
    Text {
      text: root.badFrames > 0 ? "STUTTERING at this rate"
          : root.jankFrames > 5 ? "dropping frames at this rate"
          : "smooth at this rate"
      color: root.badFrames > 0 ? Color.urgent : Color.muted
      font.pixelSize: 13
      font.bold: true
    }
  }
}
