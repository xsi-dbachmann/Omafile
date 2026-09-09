# ADR 0011 — Newline-delimited JSON, coalesced daemon-side at 10 Hz

**Status**: Accepted (2026-09-07)

## Context

The plugin and the daemon are separate processes (ADR 0005), so they need a
protocol. No Omarchy plugin had ever used Quickshell's `Socket`, so the rate at
which the UI stops keeping up was unknown — and that number decides the design,
because the whole reason the engine is a separate process is to keep the desktop
smooth.

It was measured before anything was locked.

| Emitted | Received | Sequence gaps | Frames / 10 s | Frames > 33 ms |
|---|---|---|---|---|
| 100/s | 1,102 | **0** | 680 (~57 fps) | 0 |
| 500/s | 5,000 | **0** | 615 (~61 fps) | 1 |
| 2,000/s | 20,000 | **0** | 482 (~48 fps) | 83 |
| 17,440/s | 174,739 | **0** | 239 (~24 fps) | 189 |

## Decision

**Newline-delimited JSON over a Unix socket**, with the daemon coalescing
progress to **10 Hz per Job**.

**Every connection opens with a version handshake and a full state snapshot**,
never a replay.

**The client owns reconnection** with backoff, and infers liveness from recent
traffic — never from `Socket.connected`.

**The daemon heartbeats every 2 s when idle.**

## Why

**The socket is not the bottleneck; the UI thread is.** Zero dropped events at
every rate, including 174,739 messages in ten seconds while parsing each one. So
the protocol carries no loss handling, and sequence numbers exist only to
recognise a reconnect.

**The cost is a steady frame-rate tax, not a stutter.** No frame exceeded 100 ms
at any rate — it never freezes, it just degrades. That is *worse* for diagnosis
than a freeze: a constant 24 fps reads as "this machine feels sluggish" rather
than "Omafile is doing something".

**10 Hz is an order of magnitude below the measured knee of 500–2,000/s, on
purpose.** The probe drew two text items and a rectangle; a real transfer panel
with dozens of animated rows will hit the ceiling sooner, not later. Coalescing
belongs on the daemon because it knows what changed — the client can only
discard work already paid for.

**Reconnection is the client's job because Quickshell has none.** After the
server closed, the socket stayed dead and a server restarted on the same path
was never noticed. And `Socket.connected` is a *write* property, a request to
connect: during the measurement it read "waiting" while thousands of events per
second were arriving.

**The heartbeat exists because liveness-from-traffic is unsound without it.** An
idle daemon that says nothing is indistinguishable from a dead one — observed in
use, where the panel reported "omafiled not running" while it was running fine.
Silence is only diagnostic if a healthy daemon breaks it.

## Consequences

- **The version handshake happens on every connect, not only the first**, because
  the plugin ships through git and the daemon as a package the user builds
  (ADR 0006), and they
  drift independently. A silent mismatch in the commit protocol is precisely the
  failure class Omafile exists to prevent.
- **A reattaching client is indistinguishable from a new one**, and both want the
  same thing: current state. There is no history to replay by design (ADR 0008).
- Verification reports progress across **both** files it reads. Reporting only
  the read-back left the bar frozen through the slower half of every checksummed
  transfer — the shape of the failure Omafile exists to correct. Fixing it took
  the event rate from 2.3/s to 9.3/s with a longest silent gap of 0.20 s.
- The measurements were taken on one machine with a trivial client. Treat
  ~500/s as a generous upper bound and 10 Hz as the design point.
