# ADR 0014 — The pixel budget: a notice row, draggable boundaries, and a header that counts both

**Status**: Accepted (2026-09-08), amended 2026-09-09 (see the amendment below)

## Context

Three complaints had been open since 2026-09-07 and were being answered one slice
at a time, each taking width from the others:

- **Nothing in the layout is resizable.** Sidebar 190 px, panes an exact 50/50
  split, a 1 px non-draggable divider, action bar 46 px, pane header 36 px. There
  is no `SplitView` anywhere, so the obvious response to a clipped filename —
  widen that pane — is impossible. `Ctrl+B` is the only lever and buys 95.5 px per
  pane.
- **Source and destination selection is not usable** (the user's words). A path
  cannot be typed or pasted anywhere; `Backspace` is the only way up and has no
  on-screen affordance; one shared sidebar sends whichever pane is "active", and
  that same 2 px accent edge also means "this pane is the transfer source".
- **The panes have no scroll affordance** (issue 17).

The 2026-09-07 review deferred resizing on the grounds that it *"answers 'I want
more room', not 'I cannot tell what it did'"*. That was a reasonable call on the
evidence then available. New evidence overturns it.

## The measurement that changed the answer

The action bar resolves right-to-left: the checksum chip is fixed, the buttons
take what they need beside it, and **the notice gets whatever is left**. Measured
off screen captures at the 720 px minimum on 2026-09-08, from the left edge of the
first button rectangle:

| State | Notice budget at 720 |
|---|---|
| no undo entry | **265 px** |
| undo entry, label `Rename back to renamed.txt` | **83 px** — about 11 characters |

The undo button's width is a **filename**. So the width of the product's only
channel for refusals is set by user data, and it is narrowest in the situation
where the sentence matters most.

Every refusal watched on 2026-09-08 was cut at that boundary:
`Could not p...` · `omafiled an...` ·
`omafiled is not answering — nothing was ...`

This is not a cosmetic finding. Rank 7's repair (2026-09-08) was *"every refusal
says why"*, and item 0b added more sentences still — the late-answer notice, the
unchecked-send refusal. **Those sentences are unreadable exactly when something
has gone wrong.** "I cannot tell what it did" is precisely what the space problem
now causes.

## Decision

**1. The notice gets its own row.** The action bar goes from 46 px to ~66 px:
buttons on one line, the notice on a full-width line beneath. It costs 20 px of
pane height at every window size and gives the notice roughly 690 px instead of
83 px. A sentence explaining what just happened can no longer be squeezed out by
the length of a filename.

Rejected: shrinking the undo button to an icon with the filename in a tooltip. It
reclaims the width at no height cost, but the undo label is the one place the
product names *what* `Ctrl+Z` would undo, and a keyboard-first tool must not hide
that behind a hover.

Rejected: moving notices to the transfer panel header. It has the width, but it
separates "what you just did" from the control you did it with.

**2. The pane divider and the sidebar edge become draggable.** This answers the
clipped-filename complaint directly and permanently, and it makes every later
width question the user's to settle rather than ours.

It persists nothing of the layout. (Settings did later get a home —
`components/Settings.qml` writes `$XDG_CONFIG_HOME/omafile/settings.json` — but
pane widths are deliberately not among them; see "Not
done"), and inventing one here would be a second decision smuggled in behind the
first.

**3. The pane header names both counts.** `4 files, 1 folder` and `1 file of 4`,
rather than `5 items` and `1 of 5`. The header and the action bar previously
described different things in the same breath — `5 items` beside `1 file
selected` — and read as a contradiction. Naming both is also where the folder
restriction becomes visible before the user asks for something that will be
refused.

`scripts/lint-qml.sh` deliberately exempts `DirPane.qml` from the rank 7
`selection` rule, because the header legitimately counts what the pane *shows*.
That exemption stands and is not a bug to be fixed.

## Consequences

- 20 px of every window goes to the notice row, permanently. At the 620 px
  minimum height that is a little over 3% of the window, spent on the only
  channel the product has for saying no.
- Draggable boundaries mean pane width is no longer a number this project
  chooses, so future layout work argues about *minimums*, not splits.
- Issue 17 (no scroll affordance) is **not** decided here. It is an affordance
  question, not a width question, and the panel already hand-builds a scrollbar
  next door that it can borrow.

## What this does not do

It does not add the per-pane location door (`Go▾` and a clickable breadcrumb in
the 36 px header) or make the sidebar name its target in words. That design was
judged against five concrete tasks and remains the right answer to "source and
destination selection is not usable" — but it is a feature, and this ADR is a
budget. Draggable boundaries were chosen first because they are what makes the
door's eventual 36 px affordable.

## Amendment (2026-09-09) — how long a notice lives, and what a size says

This ADR gave the notice **room** and said nothing about **time**, and it set the
size column's 52 px without saying what goes in it. Issue 19's last two items are
both that omission, found by the first person to drive the UI.

### 4. A notice lives as long as its sentence

The lifetime was a flat 6000 ms, inherited from rank 2, whose defect was a
present-tense string that never cleared. That constant was therefore tuned for
*dismissal*, and nothing has ever tuned it for *reading* — while decision 1
above deliberately made the sentences longer, by giving them 690 px to be long
in. The user, on the copy they had just run: *"message disappeared shortly
after, could not manage to get exact message read."*

**`Wording::noticeLifeMs()` = 2000 ms + 80 ms a character, floored at 4 s, capped
at 14 s.** 80 ms a character is about 150 words a minute, which is
reading-off-a-screen speed. **50 characters lands on exactly 6000**, so the
short notices the old constant was chosen around are unchanged; only the long
ones stay longer.

Rejected: **pausing the timer on hover.** It asks the reader to reach for the
mouse to finish a sentence, in a product whose own keyboard-first argument this
ADR's decision 1 rests on.

Rejected: **a larger flat constant.** It buys the completion sentence its time by
leaving every two-word refusal on screen just as long, which is how a bar becomes
the status line the timer exists to prevent.

Rejected: **"the transfer-panel row is the durable record, so the notice is only
a nudge."** True for Jobs, and false for everything else: the notice is the only
channel the product has for a delete, an undo, or a refusal, none of which ever
get a panel row.

### 5. A size is decimal

The size column divided by 1024 and labelled the answer `KB`/`MB`, so a
3,000,000-byte file read **`2.9 MB`** in the pane while its own transfer-panel
row, in the same window, read **`3000000 bytes, exactly as expected`**. Two
numbers describing one file, disagreeing on screen, in a product whose argument
is that it tells you the truth about bytes.

**`Wording::sizePhrase()` divides by 1000 and keeps `KB`/`MB`/`GB`/`TB`.** The
rounding picks the unit rather than the other way round: 999,950 bytes is
999.95 KB, which *prints* as `1000 KB`, and reads `1.0 MB`.

Rejected: **labelling it `MiB`.** Equally true, and it fixes the wrong half — the
exact byte count is what a reader reconciles the column against, and `3.0 MB`
reconciles by eye where `2.9 MiB` needs powers of two explained first. It is also
a third character in the 52 px this ADR budgeted.

Rejected: **keeping binary maths and putting the exact bytes in a tooltip.** A
hover for the truth, in a keyboard-first tool, and it leaves the disagreement on
screen for anyone who does not hover.

### Consequences

- A 40-character refusal now goes at 5.2 s rather than 6 s. Deliberate: the rule
  is the sentence's length, in both directions.
- **The pane's free-space figure is decimal too**, since it goes through the same
  function. `33 GB free` now means 33 × 10⁹ and will read about 7% larger than
  `df -h` says for the same filesystem. That is the price of agreeing with the
  daemon rather than with `df`.
- Anything that prints a size must go through `Wording::sizePhrase()`, and
  anything that writes a notice must let `setNotice()` set the interval.
  `prototypes/PaneListing.qml` still carries the original 1024 copy; it is a
  frozen artifact, not a second implementation to keep in step.
- Both rules are arithmetic, so both are checked by `qmltestrunner` rather than
  by looking (`tests/qml/tst_wording.qml`). The lifetime case builds its
  sentence with `copyPhrase()` rather than quoting one, so the timing claim
  cannot drift from the sentence it is about.
