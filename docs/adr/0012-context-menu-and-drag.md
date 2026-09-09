# ADR 0012 — A drag always copies; one path to every destructive action

**Status**: Accepted (2026-09-07)

## Context

The browser needed the conventional affordances — a right-click menu and
drag-and-drop between panes. Both introduce *second* ways to reach actions that
already exist, and the project had just been bitten by exactly that shape: the
delete mechanism existed, the keyboard path used it, and the confirmation the
ADR required was never wired in.

## Decision

**A drag between panes always copies. It never moves.** Moving requires the
explicit Move button or Ctrl+M.

**The right-click menu offers**: Copy and Move to the other pane, Open, Rename,
Delete, Properties. Nothing that the engine cannot honour today.

**A control is armed from the expression its action runs on, and from no other**
(added 2026-09-08). Copy, Move and Delete act on `DirPane.selectedPaths()`,
which excludes directories, so they arm from `selectedFileCount()`. Open,
Rename and Properties act on `selectedSingleFile()`, which is empty unless
exactly one file and no directory is picked, so they arm from that same
emptiness. **A control that refuses says why**: `containsDir` carries the
reason to the sentence, because "you picked a folder" is a different sentence
from "you picked nothing".

**Delete in the menu routes through the identical confirmation as the Delete
key** — the same function, not a parallel implementation.

**Rename is a daemon operation**, and the daemon validates the *shape* of a
name rather than sanitising a string.

**External drag-and-drop is out of scope for v1** — drags work between Omafile's
own panes only.

## Why

**Dragging is easy to do by accident.** An unwanted copy costs disk space; an
unwanted move relocates your files. In a product that exists because files went
missing, the safer default wins over the familiar one. The common alternative —
copy across filesystems, move within one — makes the same gesture mean different
things depending on where you are, and the difference is invisible until
afterwards.

**Two paths to a destructive action is how the delete gap happened.** The menu
calls `deleteSelection()`, the same function the Delete key calls, so the
confirmation cannot be bypassed by taking the other route.

**Rename refuses rather than guesses.** A `new_name` containing a separator
would be a move to somewhere the user never chose; a rename onto an existing
file is a delete wearing a rename's clothes. Both are refused, along with `.`,
`..` and empty. This is the same discipline ADR 0007 applies to the privileged
helper — validate the shape, never sanitise afterwards — applied to an
unprivileged operation because the reasoning does not depend on privilege.

**Open is deliberately not routed through the daemon.** The daemon owns
filesystem *mutation*; opening a file mutates nothing, so sending it through
would widen the daemon's surface for no gain.

**External drag-and-drop was excluded** because it means implementing Wayland's
data-device protocol and URI negotiation with poor failure modes, in a toolkit
with no precedent for it — and a file dropped in from a browser would bypass the
commit discipline entirely unless carefully routed.

## Consequences

- **Right-clicking an unselected file acts on it**, replacing the selection,
  rather than acting on a selection scrolled off screen and forgotten.
- **Rename uses a dialog rather than in-place editing.** In-place is nicer, but
  in a browser where Space, Delete and Ctrl+C all do things, it makes "am I
  typing a filename or a shortcut" ambiguous.
- **The daemon's refusal text is shown verbatim** rather than reworded, so there
  is not a second place for the two to disagree about what went wrong.
- Menu items that cannot act are drawn disabled rather than hidden, so the menu
  does not change shape under the cursor.
- **Arming and acting drifted apart anyway, and it took a year of instances to
  see it** (2026-09-08). Every control was armed from `pane.selection.length`,
  which counts folders, while every action ran on `selectedPaths()`, which drops
  them: right-clicking a folder — the most natural thing to right-click in a
  file manager — lit Copy, Move and Delete, and clicking Copy did nothing and
  said nothing. Watched failing before it was fixed: no Job reached the daemon,
  the journal stayed empty and the destination was untouched. The expressions
  that close it were written, documented and left uncalled for a day, so
  `scripts/lint-qml.sh` now fails the build if any control outside `DirPane.qml`
  reads `.selection` or hands `popupAt()` a literal for `dir`. A rule nothing
  enforces is a rule that has already been broken somewhere you have not looked.
