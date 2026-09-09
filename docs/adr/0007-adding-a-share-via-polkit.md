# ADR 0007 — A polkit helper adds shares and owns the credentials file

**Status**: Accepted (2026-09-07). **Implementation deferred past v1** (2026-09-09).
⚠️ Requires security review before shipping.

The decision below stands: polkit is still the right mechanism if this is built.
What left scope is the *building* of it. v1 ships without any privileged
component at all, and the README documents the manual `mount.cifs` procedure
instead — a one-time `sudo` per share, which is what a user does today anyway.

Deferred rather than downgraded on purpose. The reasoning here — why not setuid,
why not the keyring, why fstab needs an allowlist rather than escaping — is the
expensive part and it does not expire. Marking this Proposed again would invite
someone to re-derive it.

The gate to lift before it is built: a threat model naming the exact input
grammar per field, the constrained mount root, the exact-entry removal rule and
the hard refusals — reviewed **before** any helper code exists, not after.

## Context

ADR 0001 reaches SMB through `mount.cifs`. That needs a root-written `/etc/fstab`
entry per share: `mount.cifs` is setuid, but fstab is the gate, and **cifs is not
`FS_USERNS_MOUNT`**, so the user-namespace route returns `EPERM`. Verified
empirically. There is no way around the one-time root step.

Adding a network drive is roughly the second thing a user does, so "now open a
terminal and run sudo" collides directly with the product's UX ambition.

## Decision

**Omafile ships a polkit policy and a small privileged helper.** Adding a share
raises one standard desktop authentication dialog — the same one the user already
knows — and then it works. The package built from `packaging/PKGBUILD`
(ADR 0006) would install the policy, which it can do because it already installs
the systemd unit.

**One-off shares use the same flow**, with an offer to remove the fstab entry and
credentials when the Job is done. One code path, no second-class transient mode.

**The helper writes the root-owned 0600 credentials file in the same
authenticated action** as the fstab line. `mount.cifs` reads it as euid 0, so
**Omafile never holds the password and neither does the daemon.**

## Why not the alternatives

Instructing the user to run a command is transparent but drops them into a
terminal immediately. A setuid binary of our own is a serious security surface
for a file browser — get it wrong once and it is a local root exploit; polkit at
least puts the authentication decision in a reviewed, system-wide mechanism. The
keyring was rejected for the credentials because it puts the secret in two places
with a synchronisation between them that can rot.

## Consequences — this is the product's one privileged component

It writes `/etc/fstab`, and this must be designed rather than assumed:

- **`/etc/fstab` is line-oriented and unquoted.** A share name, mount point, or
  option containing whitespace or a newline could inject a second entry. Every
  field must be validated against a strict allowlist, not escaped after the fact.
- **The helper takes structured input, never a pre-formed line.** Host, share and
  mount name as separate validated arguments; the helper constructs the entry.
- **The mount point must be constrained** to a directory Omafile owns, so a share
  cannot be mounted over an arbitrary path.
- **Removal must match the exact entry Omafile wrote**, never a pattern that
  could match a line the user added themselves.
- This ADR should not be considered settled in implementation until a security
  review has looked at the helper.
