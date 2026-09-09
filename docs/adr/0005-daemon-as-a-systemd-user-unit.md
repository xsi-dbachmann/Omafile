# ADR 0005 — The daemon is a socket-activated `systemd --user` unit

**Status**: Accepted (2026-09-07)

## Context

Omafile's engine runs as a separate process so that checksumming multi-gigabyte
files does not stutter the process drawing the desktop bar. The obvious way to
start it — Quickshell's `Process` — is disqualified by a discovered behaviour:

`PluginRegistry` watches `~/.config/omarchy/plugins/` with a **recursive
`inotifywait`**, and the shell tears down *every* plugin on any write there.
`Process::~Process()` kills its child. So a supervised daemon would be SIGKILLed
mid-transfer because the user edited an unrelated plugin — the exact failure
Omafile exists to prevent.

## Decision

The daemon runs as a **`systemd --user` unit, started by socket activation**. It
is not a child of the shell. It starts on demand and lingers while Jobs are in
flight or a client is attached.

**The journal lives in `$XDG_STATE_HOME/omafile/`** and survives reboot.

## Why not `Process.startDetached()`

It would outlive the QML object, but it surrenders all three stdio to
`/dev/null`, returns no pid, and emits no `exited` signal. The plugin would learn
the daemon had died only when the socket dropped, and diagnosing a failed
transfer would be guesswork.

## Hazard found later, 2026-09-07 — closed 2026-09-09

`serve` unlinked the socket path before binding, so a second `omafiled serve` on
the same path silently evicted the first and took over its clients. Under socket
activation that code path does not run — but `serve` existed precisely because
the packaging did not yet, so the hazard was live.

Found by red-teaming a prompt for an unattended session, not by reading the code.
Tracked as ticket 16.

**Fixed with the packaging rather than by it** (issue 29). "Activation makes it
moot" was not good enough: every developer runs `omafiled serve` by hand, and so
does every user whose activation is broken. `bind_fresh()` now asks before it
removes anything — a live socket answers and the bind is refused, a stale one
refuses the connection and is cleared, and a path that is not a socket at all is
never removed. The unlink could not simply be deleted: nothing removes a socket
file on exit, not even a clean `drop`, so refusing whenever the path exists would
have traded a silent eviction for a permanent one after a single crash.

## The activated daemon does not exit when idle, 2026-09-09

This ADR's own list of what activation hands over free named "keeps the reattach
path exercised on ordinary use rather than only after a crash". That argues for
an idle timeout, and the timeout was still rejected.

The Job registry lives in the daemon's process memory, and a reconnecting plugin
builds its picture from that registry, not from the live event stream. An idle
exit while a window is open would hand that window an empty snapshot for Jobs it
is still waiting to hear the outcome of — which is precisely the stale-offer
failure issues 22 and 24 closed. Issue 28's release protocol already makes the
registry shrink exactly when it is safe to; an idle exit would make it vanish
when it is not.

So: activated on the first connection, and it stays until the user session ends.
`Restart=no`, because a crashed daemon is brought back by the next connection —
that *is* the activation path — and a restart loop would only race the socket
unit's trigger limit.

## Consequences

- **Socket activation hands over three things for free**: single-instance
  (systemd owns the socket, so two daemons cannot race), stale-socket handling,
  and discovery at a fixed known path. The plugin connects; it never spawns.
- **On-demand activation keeps the reattach path exercised** on ordinary use
  rather than only after a crash, which is the worst time to first run code.
- **The journal must survive reboot.** `XDG_RUNTIME_DIR` is cleared at logout,
  which would leave a verified-but-uncommitted file as an orphan with nothing
  recording where it belonged — the failure ADR 0002 guards against.
- This does not weaken the no-history rule: journal entries are still deleted on
  commit. What persists is only work that has not finished.
- **No Omafile state may live under `~/.config/omarchy/plugins/`** — journal,
  socket, pidfile — because a write there triggers the teardown storm above.
- **A unit must be installed**, which the plugin mechanism cannot do. See
  ADR 0006. Built 2026-09-09: `packaging/omafiled.socket` and
  `packaging/omafiled.service`, installed to `/usr/lib/systemd/user/` by the
  package built from `packaging/PKGBUILD`.
- **Installing the unit is not enabling it.** An Arch package may not enable its
  own units, so `makepkg -si` alone leaves the socket unlistened and the
  plugin still browse-only. The browse-only banner therefore names both steps,
  the install and the `systemctl --user enable --now omafiled.socket`.
- **The daemon reads the activation protocol itself** — `LISTEN_PID`/`LISTEN_FDS`
  and descriptor 3 — rather than linking `libsystemd`, which would have been the
  first non-Rust dependency in exchange for about twenty lines of convention.
  `LISTEN_PID` is checked, not assumed: without it an inherited `LISTEN_FDS`
  would have the daemon adopt whatever descriptor 3 happens to be and serve it.
