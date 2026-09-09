# ADR 0002 — Temp name, `fsync`, atomic rename is the commit point

**Status**: Accepted (2026-09-07)

## Context

In the founding incident, a file that had received 0.09% of its bytes sat at its
final path with ordinary metadata, indistinguishable from a real file. It was
not detected because nothing compared what arrived against what was expected —
and it was *possible* because the destination was written in place.

The checksum is not what would have prevented that. Never letting a partial file
occupy the final name is.

## Decision

Every transferred file is written to a **temporary name**, `fsync`ed, checked,
and then moved to its final path with a **single atomic rename**. Nothing is
ever written in place.

The journal entry for a Job is **deleted when the rename returns, not when
verification passes.**

## Consequences

- A partial file cannot occupy a final path. Any file found at a final path is
  whole. This holds regardless of whether `--checksum` is on (ADR 0003).
- **`fsync` before the rename is mandatory.** `close()` is documented as not a
  durability signal, and cifs's `->release` return code is explicitly ignored in
  the kernel.
- On a cifs mount the rename is **not unconditionally atomic**. Measured
  behaviour: overwriting a destination nobody has open is a single rename with
  no unlink. Overwriting one **held open by another process** makes the kernel
  retry, then unlink the destination and re-rename — reproduced 5/5, with the
  gap between unlink and rename measured at **0.5–1.9 ms, mean 0.899 ms**.
- **That window is acceptable**, because it is a window of *absence*, not of
  partial content. It cannot produce the failure this ADR exists to prevent. And
  because the rename always comes from a temp name, the new data is never in
  flight: a deliberate failure test confirmed the temp file survives untouched.
  A crash inside the window loses the *previous* version while the new one sits
  complete on disk.
- **Therefore no pre-check and no rename-aside dance.** Detecting the open
  destination requires attempting the rename, which is what triggers the
  fallback; a pre-check adds a TOCTOU window of its own. The rename-aside
  alternative trades one sub-millisecond kernel-internal window for three
  network round-trips and visible debris.
- **The journal's deletion point is load-bearing.** Deleting on verification
  rather than on commit would leave a crash inside the window with verified data
  at a temp name and nothing recording where it belongs — turning a recoverable
  state into an orphan. On restart, an entry naming a temp file whose
  destination is absent is re-committed by re-renaming.
