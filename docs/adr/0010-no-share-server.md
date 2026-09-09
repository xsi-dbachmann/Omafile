# ADR 0010 — Omafile does not run a share server; use Taildrive

**Status**: Accepted (2026-09-07)

## Context

"Create SMB shares from this machine" was on the original wish list and was ruled
out of scope in the v1 map as a server-administration tool with a different
threat model. The user redrew that boundary and it was chartered as a separate
effort with its own map, whose settled decisions were: own devices only, tailnet
reachability only, read-only by default, and tailnet membership as the sole
access check with no Samba password.

The map's first ticket asked whether Tailscale already solved the problem, and
was written to be allowed to close the map.

## Decision

**Omafile does not create shares and does not run a share server.** Sharing a
folder with the user's own devices is served by **Taildrive**, which is
Tailscale's own feature for exactly this.

## Why

**The tailnet-only decision made the SMB component pointless before it was
built.** Any device that could consume a tailnet-only SMB share must already be
running Tailscale — which is almost exactly the set of devices that can consume
Taildrive. Building smbd would not have reached a single additional device. It
would have re-served the same devices over a second protocol, replacing a
listener `tailscaled` already runs with a root-owned one.

**Exposure is strictly lower.** Taildrive adds a path to tailscaled's existing
socket rather than opening a new one, drops privileges to the sharing user, and
denies by default. Most importantly there is **no interface binding to get
wrong** — retiring the risk that the sharing map identified as its sharpest, and
that this project had already tripped over once while building a test fixture,
where naming an interface silently bound smbd to a globally routable IPv6
address.

**The best-supported clients are the ones actually in use**: iOS reaches
Taildrive natively through the Files app, macOS through Finder.

## Consequences

- **Omafile has exactly one privileged component**, the mount helper in
  ADR 0007, rather than two. The security review it already needs does not grow.
- **Taildrive is alpha** and may change without warning. Accepted as a smaller
  risk than maintaining a root SMB listener.
- **A one-time tailnet policy edit** is required in the Tailscale admin console
  (`drive:share` and `drive:access` grants). Omafile cannot perform it, so any
  future Omafile involvement would be *guiding* setup, never doing it.
- **The TV is not served, by either option.** A Samsung, LG or Roku device
  cannot run Tailscale, so it could never reach a tailnet-only share by any
  protocol. This is not a reason to build a share server; it is a different
  problem — a media server or an HTTP-fetching player app — and has not been
  chartered.
- **Rejected alternatives**: Taildrop is push-only with no browsable directory;
  `tailscale serve` yields a web page rather than a mountable folder.
- If Apple TV support were ever needed, Taildrive is broken on tvOS — but the
  workaround points at an **unprivileged user-space WebDAV server**, which Infuse
  can consume, long before it points back at Samba.

## A later finding that reinforces this

Research that landed after the decision established that the map's no-password
choice would have failed on **client compatibility** as well as on security.
Guest SMB is rejected by default on every Windows edition except Home, and on
Windows 11 24H2 and Server 2025 it is rejected twice over because required
signing is mutually exclusive with guest. Windows blocks the
`SMB2_SESSION_FLAG_IS_GUEST` protocol flag rather than a username, so no framing
of "guest" gets past it.

The corollary is worth keeping: a *real* account — even one named `guest` with a
throwaway password — sets no such flag, signs and encrypts normally, and works
on every client surveyed. Had this map continued, the credential decision would
have had to be revisited on compatibility grounds alone.

## What remains true from the sharing map

A local Samba installation stays on the development machine, but only as a
**test fixture** for Omafile's *mount* path. It is bound to loopback by
deliberate choice for that purpose, is not enabled at boot, and has nothing to
do with this decision.
