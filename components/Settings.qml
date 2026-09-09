pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io

// The one setting a panel-only plugin has any business persisting.
//
// Flagged since before 2026-08: the checksum default reset
// every session because nothing said where a panel-only plugin's settings
// should live. Here: `$XDG_CONFIG_HOME/omafile/settings.json` (falling back to
// `~/.config`), written by the plugin directly — this is a fact about how the
// window starts up, not about a transfer in progress, so it belongs beside
// the window rather than in the daemon, which has no session to remember
// across (ADR 0009: nothing about finished work outlives the session, and a
// *preference* is not finished work).
//
// Never under `~/.config/omarchy/plugins/`: a write there tears down every
// plugin — the split is not stylistic — which is exactly why
// this lives in its own directory instead.
Item {
  id: settings

  readonly property string dir:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omafile"
  readonly property string path: settings.dir + "/settings.json"

  property bool checksum: false
  property bool showHidden: false
  property bool showIcons: true
  /// Pinned folder paths, newest first.
  property var pinned: []
  /// Named, not numbered. This defaulted to 0 -- which is FolderListModel's
  /// *Unsorted*, not Name -- so a fresh install listed files in filesystem
  /// order with no column marked, and the header looked broken rather than
  /// unsorted.
  property int sortField: FolderListModel.Name
  property bool sortReversed: false

  /// Guards the initial read from writing straight back out. The file's own
  /// load (or its absence, on a first run) is not a user decision to persist —
  /// only a later, actual change to `checksum` is.
  property bool _loaded: false

  function _apply(json) {
    var obj = {}
    try { obj = JSON.parse(json) } catch (e) { obj = {} }
    settings.checksum = obj.checksum === true
    settings.showHidden = obj.showHidden === true
    settings.showIcons = obj.showIcons !== false
    settings.pinned = Array.isArray(obj.pinned) ? obj.pinned : []
    if (typeof obj.sortField === "number") settings.sortField = obj.sortField
    settings.sortReversed = obj.sortReversed === true
    settings._loaded = true
  }

  /// One writer for every setting. Two `onXChanged` handlers each writing
  /// their own object would have the second erase the first's key.
  function _save() {
    if (!settings._loaded) return
    file.setText(JSON.stringify({
      checksum: settings.checksum,
      showHidden: settings.showHidden,
      showIcons: settings.showIcons,
      pinned: settings.pinned,
      sortField: settings.sortField,
      sortReversed: settings.sortReversed
    }) + "\n")
  }

  onChecksumChanged: settings._save()
  onShowHiddenChanged: settings._save()
  onShowIconsChanged: settings._save()
  onPinnedChanged: settings._save()
  onSortFieldChanged: settings._save()
  onSortReversedChanged: settings._save()

  // FileView cannot create a missing parent directory on write, and this
  // plugin's directory does not otherwise exist until something asks for it.
  // Made ahead of the first write rather than on demand: a write that raced
  // the mkdir would fail exactly once, silently, on whichever machine first
  // toggled the chip.
  Process {
    id: ensureDir
    command: ["mkdir", "-p", settings.dir]
    // The handler takes no arguments on purpose, as DaemonClient.qml does for
    // Socket's onError: `exitStatus` carries a QProcess enum qmllint cannot
    // resolve through this import, and every exit code wants the same
    // response — try the read now that the directory should exist.
    // qmllint disable signal-handler-parameters
    onExited: { file.reload() }
    // qmllint enable signal-handler-parameters
  }

  FileView {
    id: file
    path: settings.path
    printErrors: false
    // A load failure here is almost always "no settings file yet" (first run,
    // or the directory the Process above just created is still empty) — not a
    // fault to surface. It is treated exactly like an empty file: default to
    // checksum off, the product's own default (ADR: checksum is opt-in).
    onLoaded: settings._apply(text())
    onLoadFailed: settings._apply("{}")
  }

  Component.onCompleted: ensureDir.running = true
}
