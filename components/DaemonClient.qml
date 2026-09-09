pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// The plugin's half of the omafiled protocol.
//
// Shaped by ticket 12's measurements, which found two things the obvious
// implementation gets wrong:
//
//  * There is **no automatic reconnect**. After the daemon closes, the socket
//    stays dead and a daemon restarted on the same path is never noticed. The
//    client must retry, so it does, with backoff.
//  * **`Socket.connected` does not report live state.** It is a write property
//    — a request to connect. During the measurement it read "waiting" while
//    thousands of events per second were arriving. Liveness is therefore
//    inferred from *recent traffic*, never from that property.
Item {
  id: client

  readonly property string socketPath:
    (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omafiled.sock"

  /// The protocol this plugin speaks. The daemon ships through the AUR and the
  /// plugin through git (ADR 0006), so they drift independently and a silent
  /// mismatch is exactly the failure class Omafile exists to prevent.
  readonly property int expectedProtocol: 1

  property var jobs: []              // JobView objects, newest activity last
  property string daemonVersion: ""
  property string incompatible: ""   // non-empty when the handshake failed
  property real lastMessageAt: 0
  property int reconnects: 0

  /// True only if something actually arrived recently. See the note above.
  readonly property bool live:
    lastMessageAt > 0 && (nowTick.now - lastMessageAt) < 5000

  /// Browse-only, stated plainly (ADR 0006): the window still works, it just
  /// cannot transfer.
  readonly property bool canTransfer: live && incompatible === ""

  /// Whether a socket exists that reached "connected" and has not since
  /// dropped. **Not** `Socket.connected`, which is a write property and reports
  /// what was asked for, not what is (see the note at the top of this file);
  /// this is driven by the state signal, which does fire when the peer goes.
  ///
  /// The distinction matters because "quiet" and "gone" are different failures
  /// and only one of them is fixed by throwing the connection away — see the
  /// two timers at the bottom.
  property bool attached: false

  property int _nextId: 1
  property int _backoffMs: 250

  signal jobFinished(var job)
  signal jobFailed(var job)
  signal deleted(var info)      // { id, path, recoverable, trashedAs, info, error }
  signal restored(var info)     // { id, path, error }
  signal trashAvailability(string path, bool available)
  signal renamed(var info)      // { id, from, to, error }
  /// Which names would collide, and *which question* this answers. Every reply
  /// carries the id of the request it answers; dropping it meant a slow answer
  /// arriving after a second transfer had started got applied to that second
  /// transfer's sources — the caller could not tell the two apart.
  signal conflictsFound(int requestId, var names)
  /// The daemon has taken a request. `jobId` is non-empty only for a request
  /// that started a Job, and it is the only place the two identifier spaces
  /// meet: everything afterwards is reported against the Job id, so a caller
  /// that needs to recognise its own Job has to catch it here.
  signal acknowledged(int requestId, string jobId, string error)

  Timer {
    id: nowTick
    property real now: Date.now()
    interval: 1000; running: true; repeat: true
    onTriggered: now = Date.now()
  }

  /// Try again, later each time. Called from both failure paths, because they
  /// are different signals: a *dropped* connection is a state change, a
  /// *refused* one is an error, and only handling the first is how a client
  /// with a working retry never retried.
  ///
  /// The cap is deliberate: the daemon is socket-activated, so a connection
  /// attempt is also what starts it (ADR 0005). Retrying is not merely waiting
  /// for something else to happen.
  function armRetry() { retry.restart() }

  /// Returns the request id the daemon will echo on its reply, or **-1 if
  /// nothing was sent**. Every caller must check: a caller that assumed the
  /// request went out is a caller that has already told the user it did.
  /// Real ids start at 1, so -1 and 0 can never match one.
  function _send(obj) {
    if (!client.sock || !client.sock.connected) return -1
    var id = client._nextId++
    obj.id = id
    client.sock.write(JSON.stringify(obj) + "\n")
    return id
  }

  /// A whole selection is one Job, not one Job per file — so a verification
  /// failure can stop it (ADR 0008, protocol.rs).
  function copy(sources, destinationDir, checksum, onConflict) {
    return _send({ op: "copy", sources: sources, destination_dir: destinationDir,
                   checksum: checksum === true, on_conflict: onConflict || "skip" })
  }
  function move(sources, destinationDir, checksum, onConflict) {
    return _send({ op: "move", sources: sources, destination_dir: destinationDir,
                   checksum: checksum === true, on_conflict: onConflict || "skip" })
  }
  /// Which of these would land on something that already exists. Asked before
  /// starting, so the question reaches the user rather than the engine.
  function conflicts(sources, destinationDir) {
    return _send({ op: "conflicts", sources: sources, destination_dir: destinationDir })
  }
  function del(path) { return _send({ op: "delete", path: path }) }
  function canTrash(path) { return _send({ op: "cantrash", path: path }) }
  function rename(path, newName) {
    return _send({ op: "rename", path: path, new_name: newName })
  }
  function restore(trashedAs, info) {
    return _send({ op: "restore", trashed_as: trashedAs, info: info })
  }
  /// Issue 28: forget a finished Job. Fire-and-forget — the caller has already
  /// removed its own copy from `jobs` before calling this, and the daemon's
  /// reply carries nothing worth waiting for.
  function release(jobId) { return _send({ op: "release", job: jobId }) }

  /// Ask for the current picture. Never a replay — there is no history to
  /// replay by design (ADR 0008).
  function resync() { return _send({ op: "state" }) }

  function _upsert(job) {
    var next = []
    var replaced = false
    for (var i = 0; i < jobs.length; i++) {
      if (jobs[i].job === job.job) { next.push(job); replaced = true }
      else next.push(jobs[i])
    }
    if (!replaced) next.push(job)
    jobs = next
  }

  /// The socket is *rebuilt*, never revived.
  ///
  /// Measured 2026-09-08, in a ghost session, after a connect was refused:
  /// `connected = false; connected = true` does nothing (88 retries, not one
  /// further error and not one connection), and clearing and re-setting `path`
  /// does nothing either. A `Socket` whose first connect failed stays inert for
  /// good. So a retry throws it away and loads a new one, which is the only
  /// thing that has been observed to work.
  Loader {
    id: sockLoader
    active: true
    sourceComponent: Component {
    Socket {
      id: sock
      path: client.socketPath
      connected: true

      onConnectionStateChanged: {
        client.attached = connected
        if (connected) {
          client._backoffMs = 250
          client._send({ op: "hello", client_version: "omafile-plugin/0.0.1" })
          if (client.resync() === -1) client.armRetry()
        } else {
          client.armRetry()
        }
      }

      // A connect that is *refused* never becomes a state change, so this is the
      // only signal that fires when the daemon is not running -- which is the one
      // case the retry was written for.
      //
      // Measured 2026-09-08 in a ghost session: start the plugin with no daemon
      // and the log shows exactly one `QLocalSocket::ConnectionRefusedError` and
      // **zero** connectionStateChanged events. The retry was armed only in the
      // handler above, so it was never armed at all: a daemon started afterwards
      // was never noticed, for the life of the shell, and the window stayed
      // browse-only saying "omafiled not running" and naming the install
      // command while omafiled was running the whole time. Issue 21.
      //
      // The handler takes no arguments on purpose. `error` carries a
      // `QLocalSocket::LocalSocketError`, a C++ enum qmllint cannot resolve
      // through the Quickshell import, and every reason it can carry wants the
      // same response: try again, later. Suppressed narrowly rather than by
      // loosening the linter, which is the gate that caught rank 7.
      // qmllint disable signal-handler-parameters
      onError: { client.attached = false; client.armRetry() }
      // qmllint enable signal-handler-parameters

      parser: SplitParser {
        splitMarker: "\n"
        onRead: function (line) {
          client.lastMessageAt = Date.now()
          var m
          try { m = JSON.parse(line) } catch (e) { return }

          // Any message counts as liveness, including the idle heartbeat. That
          // is what makes silence diagnostic rather than ambiguous.
          switch (m.t) {
          case "tick":
            break
          case "hello":
            client.daemonVersion = m.daemon_version || ""
            client.incompatible = (m.protocol === client.expectedProtocol)
              ? ""
              : "omafiled speaks protocol " + m.protocol + "; this plugin speaks "
                + client.expectedProtocol
            break
          case "state":
            // A snapshot replaces what we hold. A reattaching client is
            // indistinguishable from a new one, and both want the same thing.
            client.jobs = m.jobs || []
            break
          case "progress":
            client._upsert(m.job)
            break
          case "finished":
            client._upsert(m.job); client.jobFinished(m.job)
            break
          case "failed":
            client._upsert(m.job); client.jobFailed(m.job)
            break
          case "reply":
            client.acknowledged(m.id || 0, m.job || "", m.error || "")
            break
          case "deleted":
            client.deleted({
              id: m.id || 0, path: m.path, recoverable: m.recoverable === true,
              trashedAs: m.trashed_as || "", info: m.info || "", error: m.error || ""
            })
            break
          case "restored":
            client.restored({ id: m.id || 0, path: m.path || "", error: m.error || "" })
            break
          case "conflicts":
            client.conflictsFound(m.id || 0, m.existing || [])
            break
          case "renamed":
            client.renamed({ id: m.id || 0, from: m.from, to: m.to || "", error: m.error || "" })
            break
          case "trashavailable":
            client.trashAvailability(m.path, m.available === true)
            break
          }
        }
      }
    }
    }
  }

  readonly property var sock: sockLoader.item

  /// Keeps trying until something actually arrives.
  ///
  /// It used to fire once per failure signal, which cannot work: measured
  /// 2026-09-08, a refused connect raises `error` exactly **once**, and the
  /// re-attempt it triggers raises neither another `error` nor a
  /// `connectionStateChanged` -- it fails in silence. One shot chained off
  /// signals therefore stops after a single try, and a daemon started a second
  /// later is never found.
  ///
  /// So the condition is liveness, not a signal: retry while nothing has
  /// arrived, stop as soon as something has. `live` is already the project's
  /// definition of "the daemon is there" and it is the honest one, because
  /// `Socket.connected` is a write property that does not report live state.
  /// **Only when there is no socket.** `running: !client.live` alone was wrong,
  /// and wrong in a way that cost the product a whole class of recovery: a
  /// daemon that merely goes *quiet* for five seconds — paused, slow, or held
  /// up by a stalling share — had its perfectly good connection thrown away,
  /// and with it every reply still in flight on it.
  ///
  /// Measured 2026-09-08 with `scripts/stallproxy.py` holding the daemon's
  /// traffic for eight seconds: at ~5.3 s the plugin rebuilt the socket, and
  /// the daemon's answer — a completed undo — was flushed to a connection
  /// nobody was reading (`BrokenPipeError` in the proxy log). The window had
  /// already said the undo did not finish; the answer that would have corrected
  /// it could not arrive. Issue 24.
  ///
  /// So: no socket, rebuild (issue 21's case, unchanged, and the one that
  /// socket-activation needs). A socket that is up but silent is a different
  /// thing and gets `probe` below.
  Timer {
    id: retry
    repeat: true
    running: !client.live && !client.attached
    interval: client._backoffMs
    onTriggered: {
      client.reconnects++
      client._backoffMs = Math.min(client._backoffMs * 2, 5000)
      client.attached = false
      sockLoader.active = false
      // Next turn: the old socket has to actually go away before a new one is
      // made, or the loader is left holding the same dead object.
      Qt.callLater(function () { sockLoader.active = true })
    }
  }

  /// A socket that is attached but has gone quiet is *asked*, not replaced.
  ///
  /// `state` is the cheapest question in the protocol and its reply is itself
  /// liveness, so a daemon that comes back answers this and the window recovers
  /// with everything it was waiting for still on the wire. There is no give-up
  /// clause on purpose: a peer that dies raises the state change above, and a
  /// peer that is merely hung would hang a fresh connection exactly as well —
  /// rebuilding buys nothing and costs whatever was in flight.
  Timer {
    id: probe
    repeat: true
    running: !client.live && client.attached
    interval: 2000
    onTriggered: {
      // -1 means the write did not go out, which means this socket is not the
      // thing it claims to be. Hand it to the retry above.
      if (client.resync() === -1) { client.attached = false }
    }
  }
}
