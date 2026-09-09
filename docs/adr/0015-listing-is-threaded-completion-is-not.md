# ADR 0015 — Listing a directory does not block the UI; path completion still belongs to the daemon

**Status:** accepted, 2026-09-09
**Context:** issue 02 of `omafile-polish`; refines the refusal recorded in
`.scratch/omafile-v1/issues/34-direct-path-entry.md`

## The refusal being tested

Tab completion in the path field was refused, in these words:

> completing against a partial path lists a directory per keystroke over
> whatever filesystem the path names, including a stalled SMB mount, which is
> the one thing the UI thread must never block on. That wants the daemon, not a
> `FolderListModel`.

Two claims are bundled there. The first is about **cost** — a listing per
keystroke. The second is about **blocking** — a listing on a filesystem that has
stopped answering. Only the second is load-bearing, and until now neither had a
number.

## What was measured

A generated tree on `/tmp` (tmpfs), driven in a ghost session against the real
`DirPane`, with a 16 ms heartbeat `Timer` in the window. A timer asking for 16 ms
can only be answered when the UI thread is free, so **its worst gap is the
longest the thread was blocked** — wall time alone cannot tell a slow load from
a frozen one.

| Directory | Wall time to Ready | Worst UI-thread stall |
|---|---|---|
| 1,000 entries | 3 ms | **0 ms** |
| 10,000 entries | 26 ms | **0 ms** |
| 50,000 entries | 146 ms | **0 ms** |

And, at 50,000 entries, with a 50 ms reporting threshold: sort by size, re-sort,
filter per keystroke as characters arrive, `PageUp`/`PageDown`, `Home`/`End`,
and `Ctrl+A` selecting all 50,000 — **no stall above 50 ms in any of them.**

`FolderListModel` reads the directory on a worker thread. The window does not
freeze while it does.

## The decision

**The refusal stands, and its first clause is withdrawn.**

Cost is not the reason. A listing per keystroke over a responsive filesystem is
0 ms of UI thread at 50,000 entries, which is far more than any path a person
types into. Arguing from cost was arguing from something never measured, and the
measurement does not support it.

The reason is the second clause, unchanged and untested: **a filesystem that has
stopped answering.** These numbers say nothing about it. tmpfs is the fastest
floor there is, and every figure above is a best case rather than a typical one.
Whether a dead SMB mount blocks the UI thread or merely the worker thread was
**not established here**, because establishing it needs a mount, and mounting is
outside what this project's autonomous sessions may do.

So the refusal survives on the half that was always the real one, and it is now
resting on a stated unknown rather than on an assumed cost.

## What would settle it

A `FolderListModel` pointed at a mount that has stopped answering, with the same
heartbeat running, and the answer to one question: does the stall land on the
worker thread or on the UI thread? If it is the worker thread, this ADR should
be revisited and completion may be buildable in the plugin after all. If it is
the UI thread, the refusal is permanent and correct, and completion wants the
daemon exactly as ticket 34 said.

`scripts/stallproxy.py` does **not** answer this. It stalls the daemon socket,
which is a different thing from a stalled filesystem, and pointing it at this
question would be measuring the wrong stall.

## Consequence for the scrollbar

The same session found that the thumb's 18 px minimum made it unaimable at
50,000 rows, and that a press missing it discarded the drag entirely. That is
fixed in `components/ScrollHint.qml`. It is recorded here only because it is the
other thing a 50,000-entry directory turned out to be good for: this ADR's
measurements say the list is fast, and the reason large directories felt bad was
never speed.
