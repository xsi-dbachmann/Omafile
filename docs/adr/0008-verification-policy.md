# ADR 0008 — Verification policy: granularity, recording, and failure

**Status**: Accepted (2026-09-07). Completes ADR 0003, which set the tiers.

## Context

ADR 0003 established the tiers and made `--checksum` opt-in. Three questions
remained: how granular the flag is, where "this Job was checksummed" lives once
the journal has deleted the entry, and what happens when a checksum fails.

The recording question carried a real tension: a durable per-job record of
assurance is a durable record of what you copied — the thing ruled out on
privacy grounds.

## Decision

**Granularity: a global default plus a per-job override.** One setting rarely
touched, plus the ability to turn checksumming on for a Job that matters. The
override lives in the action bar, beside the button that starts the Job.

**Recording: the session panel, and nothing on disk.** A completed Job stays
visible with its tier until Omafile is closed.

**Failure: retry the file once, then stop the Job.** The temp file is discarded
and the destination is never touched.

## Why

Keying the flag on destination type (on for network, off for local) was rejected
even though it matches where the risk lives: an automatic rule is a rule you must
remember exists when a transfer is unexpectedly slow, and it removes the
deliberate act from the one case where deliberateness is the point.

The extended-attribute alternative for recording was rejected on principle rather
than practicality — it is a durable record of what was copied — and it would have
been unreliable anyway, since xattrs do not survive most copies.

One retry catches transient corruption cheaply. A second failure is evidence that
something is genuinely wrong — a failing disk, a lying server, a bad cable — and
copying hundreds more files past that evidence is not helpful. Stopping with no
retry was rejected for turning a single bit flip into a halted 10,000-file
transfer; skip-and-continue was rejected for working on while holding evidence
that the medium is corrupting data.

## Implementation note, added 2026-09-07

"Stop the Job" was recorded here before anything could express it: the first
implementation made every file its own Job, so a failure on file three of a
hundred stopped only that file and the remaining ninety-seven proceeded — the
exact behaviour this decision exists to prevent. Found by auditing the ADRs
against the code after a related gap surfaced in use.

A selection is now **one Job with many files**. When a file fails after its
retry, the Job stops and reports how many files were never attempted, because
silently doing less than was asked is its own kind of lie.

A multi-file Job reports the **weakest** tier any of its files received, so the
claim holds for every file rather than the luckiest one — a selection where some
files reflinked and others were checksummed reports Checksummed, not Shared
extents.

## Consequences

- **The state model has a clean shape.** The journal holds *incomplete* Jobs and
  deletes on commit. The panel holds *completed* Jobs and dies on exit. Neither
  is a history, and between them nothing about finished work outlives the
  session.
- **Four completion states reach the UI**, so no row may say only "done" — see
  ADR 0009.
- **A Job halted by verification failure needs a visible resting state**: it is
  neither complete nor resumable-by-default.
- **The 2.5–2.7× cost was measured with verification serialised** after each
  copy. Pipelining the verify of file N against the copy of N+1 is untested and
  may recover much of it; if it does, the default is worth revisiting.
