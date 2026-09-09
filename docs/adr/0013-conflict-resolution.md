# ADR 0013 — Ask before overwriting; report what was replaced

**Status**: Accepted (2026-09-07)

## Context

What happens when a transfer lands on a file that already exists was never
decided. It sat in the v1 map's fog as "Conflict resolution", and the
implementation quietly overwrote and said nothing.

That surfaced in use in the worst possible way: a drag onto files that already
existed **looked exactly like nothing happening**. The panes did not change,
because the filenames were the same. Silent overwriting is not merely
undesirable — it is indistinguishable from failure.

## Decision

**Ask before a Job starts, with Skip / Keep both / Replace**, listing the files
that would collide. The daemon is asked which destinations exist; the user is
asked what to do; only then does the Job start.

**The engine never asks.** It takes a resolved policy. By the time a Job reaches
it, the answer is already known.

**The default is Skip.** A caller that omits the policy cannot destroy anything.

**A completed Job reports how many files it replaced** and how many it left
alone.

## Why

**Overwriting is destructive, and this product asks before destructive things.**
The same reasoning as the delete confirmation, which was learned the same way.

**Asking before rather than during** keeps the engine free of any notion of
waiting for a person, and means a long transfer is never blocked halfway on a
dialog nobody is watching.

**Skip as the default is a safety property, not a preference.** Every other
default in this engine is chosen so that forgetting to be explicit cannot lose
data; `Options::default()` producing `Replace` would have been a loaded gun.

**Reporting replacements is the point of the whole product applied to one more
case.** A transfer that *changed* things is not the same as one that only
*added* things, and Omafile's claim is that you can tell what it did.

## Data-loss bugs found immediately after, 2026-09-07

Adding the conflict policy to `copy` and not to `move` left two paths that destroyed
data. Both were found by a UI design review reading the code, not by the tests written
alongside the feature.

**A skipped move deleted the source.** `move_file_with` ignored `on_conflict` entirely.
Cross-filesystem it called `copy_file_with`, received `SkippedExisting`, and then ran
`remove_file(src)` unconditionally — deleting a file it had never copied. Same
filesystem it renamed straight over the destination whatever the user had chosen.

A move now resolves the conflict exactly as a copy does, and removes the source **only
on a genuine `Copied` outcome**.

**An all-skipped Job reported itself as "Moved".** `all_moved` began true and was only
cleared in the `Copied` arm, so a Job where every file was skipped finished with tier
"Moved". The plugin inferred the operation by string-matching that label, pushed an undo
entry, and a Ctrl+Z would have moved the very file the user had just chosen to keep.

Two fixes: the daemon reports `outcome` as data (`moved` / `copied` / `skipped` /
`failed`) so rewording a human label can never change behaviour, and an all-skipped Job
says "Nothing copied — every file was already there".

**The general lesson**: `Options` gained a field and only one of its two call sites was
taught to honour it. A safety default (`Conflict::Skip`) is not safety if a code path
never consults it.

## Consequences

- **Keep both lands beside as `name-2.ext`**, preserving the extension so the
  copy is still the same kind of file. A leading dot is treated as part of the
  name, not an extension.
- The panel gains "3 replaced" and "2 left alone" alongside the tier.
- Two bugs were found while building this, both in the daemon's event writer,
  and both would have misreported completions to the UI:
  - **Finished Jobs were re-broadcast on every tick**, so a client saw stale
    completions interleaved with live ones. A terminal event is now sent once
    per connection, seeded from the snapshot the connection opens with.
  - **The change flag was global across connections**, so whichever writer
    ticked first consumed it and every other client silently stopped updating.
    Replaced with a revision counter each connection tracks independently.
- ⚠️ The Job registry still grows for the life of the daemon. Not a correctness
  problem while the daemon is short-lived and per-session, but it is unbounded.
