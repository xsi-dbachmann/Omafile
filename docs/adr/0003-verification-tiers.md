# ADR 0003 — Three verification tiers; only the checksum is optional

**Status**: Accepted (2026-09-07). Supersedes the original always-on decision.

## Context

The project was chartered on "100% sure transfers are working", and verification
was initially settled as always-on with no opt-out, on the reasoning that a
toggle reintroduces the doubt the product exists to remove.

Measurement changed the picture. Read-back checksumming was measured at roughly
**2.5–2.7× wall-clock** in both directions — on a 400 MiB upload, 5.8 s to copy
and 10.1 s to verify, because reads run slower than writes on this link. A 10 GB
transfer goes from about 2.4 minutes to about 6.5.

The decisive counter-measurement: an exact **size comparison would have caught
41 of 41** damaged files in the founding incident, and it costs nothing.

## Decision

Verification is **three separable tiers**, not one switch:

| Tier | Status | Cost |
|---|---|---|
| Structural — temp name, `fsync`, atomic rename (ADR 0002) | unconditional | ~free |
| Size — transferred bytes vs. source size | **unconditional** | free |
| Checksum — read the committed file back and hash it | **`--checksum`, default off** | 2.5–2.7× |

The flag is named **`--checksum`**, not `--verify`, and carries that exact name
wherever it surfaces: the daemon's CLI, the plugin's settings key, and any
per-job override.

## Why

- The founding bug **is** a failure to do the free check. gvfs's
  `copy_stream_with_progress()` already holds the source size for the progress
  bar and never compares it. Putting the size check behind a flag would give
  Omafile's default path the same blind spot.
- `--verify` would imply nothing is checked when off, which is false. Naming the
  expensive tier honestly keeps the claim true.
- The cost is real and the user's to weigh. Leaving the expensive tier opt-in is
  a defensible trade *because* the free tiers still catch the motivating case.

## Correction from implementation, 2026-09-07

The tiers describe **copies**. Implementing the engine surfaced a case they do
not cover: a **same-filesystem move is a rename of the same inode**, so nothing
is copied and there is nothing to verify. Stretching one of the tiers to cover it
would have been dishonest.

The engine's `Outcome` therefore distinguishes `Moved` from `Copied { tier }`,
and a Job that only moved reports "Moved — same filesystem, nothing was copied"
rather than claiming a verification tier it did not earn.

ADR 0004 later added a fourth tier, `SharedExtents`, above `Checksummed`.

## Consequences

- **Completion has grades.** A finished Job may have been structurally
  committed, size-checked, or checksummed. The UI must convey which without
  nagging about a setting the user chose deliberately — a single green tick
  would be a claim the product cannot always support.
- A completed Job must **record which tier it got**, or "was this one checked?"
  becomes unanswerable. This is in tension with the journal being working state
  that deletes itself on commit; the tension is unresolved.
- **Cache bypass is not required.** It was assumed that read-back verification
  had to defeat the page cache or it would hash its own memory and always pass.
  Measured false: verification reads reach the server under the default
  `cache=strict`. `POSIX_FADV_DONTNEED` is free insurance, not a requirement.
- The 2.5–2.7× figure was measured with the verify pass **serialised** after the
  copy. Pipelining the verify of one file against the copy of the next is
  untested and might recover much of it — which would weaken the case for the
  default.
