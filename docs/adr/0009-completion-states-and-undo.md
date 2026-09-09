# ADR 0009 — Completion is stated, not ticked; undo is a session stack

**Status**: Accepted (2026-09-07)

## Context

Two questions that look unrelated turn out to share an answer.

The founding failure was a progress bar that reached the end and vanished while
being wrong. With four verification tiers (ADR 0004 extending ADR 0003), a single
green tick would be a claim the product cannot always support.

Separately, undo and trash both cross a boundary the desktop conventions do not
anticipate: moving a file off an SMB share is a copy-then-delete, so undoing it
is a full verified transfer, and SMB shares frequently cannot host the
`.Trash-$uid` directory the freedesktop spec expects.

## Decision

**No completed row ever says only "done".** Every finished transfer states its
tier in words, with the evidence beneath it — "bytes read back and matched the
source", "404,625,057 bytes, exactly as expected", "same data as the source —
cannot diverge".

**Progress fills the row; there is no separate bar.** The row *is* the Job.

**Cross-boundary undo is a visible reverse Job**, verified like any other, not a
fake-instant operation.

**Copy is not undoable.** Reversing a copy means deleting what was written, which
is destructive rather than restorative, and is presented as a delete.

**Remote deletion is permanent where the share cannot host a trash directory**,
with a confirmation worded differently from the local one.

**Undo is a session stack**, held in memory, gone when Omafile closes.

## Why

A tick is a claim; a statement of what was checked is a proof. Stating the tier
also solves the nagging problem — a size-checked row reports what it did rather
than scolding the user for a setting they chose deliberately. Ranking is carried
by wording and weight, not by warning colours.

Making undo a real Job matters beyond honesty: a copy-back on some second,
weaker path would be the one operation in the product capable of producing a
partial file.

Copying remote deletions to local trash was rejected for turning a 10 GB delete
into a 10 GB download. Honouring `.Trash-$uid` where available and falling back
otherwise is the most spec-correct option but makes behaviour vary per share
unpredictably — one predictable rule, plainly stated, is better.

A durable undo stack was rejected as exactly the record of what you copied and
deleted that was ruled out.

## Implementation note, 2026-09-07

This ADR states that move **and rename** are reversible. Rename shipped with no
undo entry: the daemon operation was added, the plugin handled its event, and
nothing recorded it on the stack. Reported from use — rename, then Ctrl+Z, and
nothing happened.

That is the **third** gap of this shape in the project: the delete confirmation
that was specified and never wired, "stop the Job" that was specified before
anything could express it, and now rename undo. The common cause is that adding
a mutation and deciding its undo disposition were separate acts, and the second
one was easy to skip.

Every filesystem mutation now passes through a single `noteMutation()` gate with
a case per kind, including explicit cases for the two that are deliberately *not*
undoable (permanent delete, copy). An unrecognised kind warns rather than
silently doing nothing, so the next mutation added cannot quietly skip the
decision.

## Consequences

- **The session note is load-bearing, not decoration**: the panel states that the
  list is kept for this session only, *before* the user goes looking for last
  week's transfer.
- **Undo of a running Job is cancel, not undo**, and they leave different states
  behind. The panel must not offer both for the same Job.
- **The trash confirmation is per-destination**, decided at confirmation time, so
  the dialog must know whether the target share can host a trash directory before
  it draws itself.
- ⚠️ **"Shared extents" is filesystem jargon** and ranks highest while reading as
  most obscure. The concept and its rank are settled; the word is not.
