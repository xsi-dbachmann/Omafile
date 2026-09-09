# ADR 0004 — Backend primitives are a precondition; the engine owns the commit

**Status**: Accepted (2026-09-07). Extends ADR 0003's tier table.

## Context

v1 ships local and SMB. ADR 0001 reaches SMB through a mount, so an SMB share is
an ordinary path — which means v1 may have only one real backend, and any
abstraction over "protocols" is speculative until a second one exists.

Separately, every backend the research rejected was rejected for *lacking* one of
three things: atomic rename, resume from offset, durable flush.

## Decision

**The seam exists in v1 with a single implementation.** The interface is
unexercised, and an abstraction with one implementation is a guess — but writing
it down forces the engine to state what it actually requires.

**The three primitives are a precondition of being a backend, not negotiable
capabilities.** A backend provides atomic rename, resume from offset, and durable
flush, or it is not a backend. The engine never branches on capability.

**The engine owns the commit discipline.** Backends supply primitives; the engine
sequences temp-write, `fsync`, size check, optional checksum, and atomic rename.

**Local gets a full fast path**, including same-filesystem renames for moves and
reflinks for copies on copy-on-write filesystems.

## Why

A capability flag that only ever has one value is a lie. On the evidence, every
qualifying backend has all three primitives and every disqualified one lacked
them — so the honest expression is a precondition, not a negotiation. It also
means an unsuitable protocol is excluded at the door rather than silently
degraded into a promise Omafile cannot keep.

The commit discipline is the product's single core promise. Putting the one thing
that must never vary into the one place that varies would be perverse.

## Consequences

- **SFTP plausibly qualifies. FTP almost certainly does not**, and would become a
  separate explicitly weaker mode or leave the product. Accepted.
- **A fourth verification tier exists, above checksum: shared extents.** A reflink
  is not a copy — it shares the source's extents copy-on-write, so divergence is
  impossible by construction, which is a stronger claim than a checksum's "the
  bytes matched at one moment". This extends the table in ADR 0003 rather than
  contradicting it.
- **Reflinks need the same filesystem and btrfs or XFS.** A cross-filesystem local
  copy is an ordinary copy on the ordinary tiers. The engine must detect this,
  and the fallback is the normal path, never an error.
- The local fast path is an engine-level decision about *how to produce the
  committed file* — never a licence for a backend to skip the commit.
