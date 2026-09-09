pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The one setting a panel-only plugin has any business persisting.
//
// STATE.md flagged this since before 2026-09-08: the checksum default reset
// every session because nothing said where a panel-only plugin's settings
// should live. Here: `$XDG_CONFIG_HOME/omafile/settings.json` (falling back to
// `~/.config`), written by the plugin directly — this is a fact about how the
// window starts up, not about a transfer in progress, so it belongs beside
// the window rather than in the daemon, which has no session to remember
// across (ADR 0009: nothing about finished work outlives the session, and a
// *preference* is not finished work).
//
// Never under `~/.config/omarchy/plugins/`: a write there tears down every
// plugin (see STATE.md's "The split is not stylistic"), which is exactly why
// this lives in its own directory instead.
Item {
  id: settings

  readonly property string dir:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omafile"
  readonly property string path: settings.dir + "/settings.json"

  property bool checksum: false

  /// Guards the initial read from writing straight back out. The file's own
  /// load (or its absence, on a first run) is not a user decision to persist —
  /// only a later, actual change to `checksum` is.
  property bool _loaded: false

  function _apply(json) {
    var obj = {}
    try { obj = JSON.parse(json) } catch (e) { obj = {} }
    settings.checksum = obj.checksum === true
    settings._loaded = true
  }

  onChecksumChanged: {
    if (!settings._loaded) return
    file.setText(JSON.stringify({ checksum: settings.checksum }) + "\n")
  }

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
