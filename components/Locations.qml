pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Where you can go: home, the usual folders that actually exist, and every
// mounted network share.
//
// A mounted share really is just a path (ADR 0001), but leaving it at that
// would make the product's main use case the least discoverable thing in it.
// So mounts are detected and listed rather than typed.
Rectangle {
  id: locations

  property string currentDir: ""
  signal chosen(string path)

  readonly property string homeDir: Quickshell.env("HOME") || "/"
  readonly property var usualFolders: ["Documents", "Downloads", "Pictures", "Videos", "Music", "Projects"]
  property var places: []
  property var mounts: []

  // Where the panes have actually been this session. Nothing about a session
  // outlives it here (STATE.md), so this is a list in memory, not a setting.
  property var recent: []

  // Below this the sidebar cannot show seven places *and* the shares, and the
  // shares are the reason the product exists — so Places collapses to a
  // shortlist and the Network section keeps the leftover height, rather than
  // getting whatever Places has not already taken (ticket 13).
  readonly property bool compact: height < 300
  property bool placesExpanded: false
  readonly property var shownPlaces: locations.compact && !locations.placesExpanded
    ? locations.shortlist(locations.places, locations.recent)
    : locations.places

  // The rows do not merely overflow without this: ActionBar's fill is 4% alpha,
  // so an unclipped row paints *over* the notice and stays hit-testable. The
  // Flickable below fills this rectangle exactly, so this one clip covers it.
  clip: true

  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)

  Component.onCompleted: seedPlaces()

  onCurrentDirChanged: locations.noteVisit(locations.currentDir)

  // Home is the anchor: offered before the scan has answered, and kept whatever
  // the scan says. The rest wait to be proven to exist.
  function seedPlaces() {
    locations.places = [{ name: "Home", path: locations.homeDir }]
  }

  // Recency is recorded for whatever directory the pane shows. The shortlist
  // intersects it with the places list, so a stray subdirectory never matches
  // and simply falls out.
  function noteVisit(path) {
    if (!path) return
    var r = locations.recent.slice()
    var at = r.indexOf(path)
    if (at !== -1) r.splice(at, 1)
    r.unshift(path)
    if (r.length > 6) r.length = 6
    locations.recent = r
  }

  // Home, then the places most recently opened, topped up in declared order so
  // a fresh session still offers three. Everything else is one tap away behind
  // the disclosure row instead of pushing the shares off the bottom.
  function shortlist(all, seen) {
    var out = []
    for (var i = 0; i < all.length; i++)
      if (all[i].path === locations.homeDir) out.push(all[i])
    for (var j = 0; j < seen.length && out.length < 3; j++)
      for (var k = 0; k < all.length; k++)
        if (all[k].path === seen[j] && out.indexOf(all[k]) === -1) out.push(all[k])
    for (var m = 0; m < all.length && out.length < 3; m++)
      if (out.indexOf(all[m]) === -1) out.push(all[m])
    return out
  }

  // Mounts come and go, so this is polled rather than read once. `findmnt`
  // rather than parsing /proc/mounts by hand: it already resolves the source
  // into the //host/share form a person recognises.
  Timer {
    interval: 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!mountScan.running) mountScan.running = true
  }

  Process {
    id: mountScan
    command: ["findmnt", "-rno", "TARGET,SOURCE,FSTYPE"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: locations.parseMounts(text)
    }
  }

  function parseMounts(raw) {
    var out = []
    var lines = String(raw).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split(" ")
      if (f.length < 3) continue
      var target = f[0], source = f[1], fstype = f[2]
      // Network filesystems only. Local mounts are reachable through the
      // ordinary folders and would just make this list noise.
      if (["cifs", "smb3", "nfs", "nfs4", "sshfs"].indexOf(fstype) === -1) continue
      out.push({
        name: source.replace(/\\040/g, " "),
        path: target.replace(/\\040/g, " "),
        fstype: fstype
      })
    }
    mounts = out
  }

  // The usual folders are a guess about a machine, not a fact about it: a
  // system with no ~/Videos should not offer a row that opens on nothing.
  // Checked the same way mounts are, and polled for the same reason — a folder
  // can be created while the window is open — just far less often, because a
  // folder appearing is rarer than a share appearing.
  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!placeScan.running) placeScan.running = true
  }

  Process {
    id: placeScan
    // -L so a Downloads symlinked onto another disk still counts as a
    // directory; -maxdepth 0 so this only ever tests the arguments themselves.
    command: ["find", "-L"].concat(locations.usualFolders.map(function (n) {
      return locations.homeDir + "/" + n
    })).concat(["-maxdepth", "0", "-type", "d"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: locations.parsePlaces(text)
    }
    // find names the missing paths on stderr. Their absence is the answer we
    // asked for, not a fault, so it is collected here rather than left to
    // print into the shell's log every half minute.
    stderr: StdioCollector { }
  }

  function parsePlaces(raw) {
    var present = {}
    var lines = String(raw).split("\n")
    // Not trimmed: a path is whatever bytes name it, trailing spaces included.
    for (var i = 0; i < lines.length; i++)
      if (lines[i] !== "") present[lines[i]] = true

    var p = [{ name: "Home", path: locations.homeDir }]
    for (var j = 0; j < locations.usualFolders.length; j++) {
      var path = locations.homeDir + "/" + locations.usualFolders[j]
      if (present[path]) p.push({ name: locations.usualFolders[j], path: path })
    }
    locations.places = p
  }

  // Scrollable, because the height this lives at is the window's height minus
  // the action bar and the transfer panel: at the 480px minimum one cifs mount
  // already overflows, and an unreachable share is the same as no share.
  Flickable {
    id: scroll
    anchors.fill: parent
    contentWidth: width
    contentHeight: content.height
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: scroll.width
      topPadding: 8
      bottomPadding: 8
      spacing: 0

      Text {
        x: 14
        text: "Places"
        color: Color.muted
        font.pixelSize: 10
        font.bold: true
        bottomPadding: 4
      }

      Repeater {
        model: locations.shownPlaces
        Rectangle {
          id: place
          required property var modelData
          width: content.width
          height: 26
          color: locations.currentDir === modelData.path
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
            : (hov.hovered ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                           : "transparent")
          Text {
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 10 }
            elide: Text.ElideRight
            text: place.modelData.name
            color: locations.currentDir === place.modelData.path ? Color.accent : Color.foreground
            font.pixelSize: 12
          }
          HoverHandler { id: hov }
          TapHandler { onSingleTapped: locations.chosen(place.modelData.path) }
        }
      }

      // Only drawn where it buys something: at a full-height sidebar, or with
      // three places or fewer, nothing is being hidden and this row would be
      // claiming otherwise.
      Rectangle {
        visible: locations.compact && locations.places.length > 3
        width: content.width
        height: 24
        color: disclosureHov.hovered
          ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
          : "transparent"
        Text {
          anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 10 }
          elide: Text.ElideRight
          text: locations.placesExpanded
            ? "▾  Show fewer"
            : "▸  " + (locations.places.length - locations.shownPlaces.length) + " more places"
          color: Color.muted
          font.pixelSize: 11
        }
        HoverHandler { id: disclosureHov }
        TapHandler { onSingleTapped: locations.placesExpanded = !locations.placesExpanded }
      }

      Item { width: 1; height: 12 }

      Text {
        x: 14
        text: "Network"
        color: Color.muted
        font.pixelSize: 10
        font.bold: true
        bottomPadding: 4
      }

      // Said plainly rather than left as an empty space, so "there are no shares
      // mounted" is distinguishable from "this feature is broken".
      Text {
        visible: locations.mounts.length === 0
        x: 14
        width: content.width - 24
        wrapMode: Text.WordWrap
        text: "No shares mounted.\nMount one and it appears here."
        color: Color.muted
        font.pixelSize: 10
      }

      Repeater {
        model: locations.mounts
        Rectangle {
          id: share
          required property var modelData
          width: content.width
          height: 34
          color: locations.currentDir === modelData.path
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
            : (mh.hovered ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                          : "transparent")
          Text {
            id: shareName
            anchors { left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 10; top: parent.top; topMargin: 4 }
            elide: Text.ElideMiddle
            text: share.modelData.name
            color: locations.currentDir === share.modelData.path ? Color.accent : Color.foreground
            font.pixelSize: 11
          }
          Text {
            anchors { left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 10; top: shareName.bottom }
            elide: Text.ElideMiddle
            text: share.modelData.fstype + " · " + share.modelData.path
            color: Color.muted
            font.pixelSize: 9
          }
          HoverHandler { id: mh }
          TapHandler { onSingleTapped: locations.chosen(share.modelData.path) }
        }
      }
    }
  }

  // A scrollbar rather than a Controls one: nothing else in this plugin imports
  // QtQuick.Controls, and its only job is to say that there is more below.
  Rectangle {
    visible: scroll.contentHeight > scroll.height
    anchors { right: parent.right; rightMargin: 1 }
    width: 2
    radius: 1
    y: scroll.contentHeight > 0
      ? Math.max(0, Math.min(scroll.height - height, scroll.height * scroll.contentY / scroll.contentHeight))
      : 0
    height: scroll.contentHeight > 0
      ? Math.max(24, scroll.height * scroll.height / scroll.contentHeight)
      : 0
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
  }
}
