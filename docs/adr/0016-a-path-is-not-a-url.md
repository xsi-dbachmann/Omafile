# ADR 0016 — A path is not a URL, and a listing is not a promise

**Status:** accepted, 2026-09-09
**Context:** issues 06 and 07 of `omafile-polish`

Two decisions about the boundary between a path this product owns and the two
Qt types that consume one. They are recorded together because they were found
together and the second is what makes the first survivable.

## 1. Building a URL

Three sites built one by concatenation — `"file://" + path` — and three
characters in a **name** change what that string means: `#` opens a fragment,
`?` opens a query, `%` opens an escape. A folder called `track #1` asked the
filesystem for `/…/track ` and got nothing. Spaces and non-ASCII were never the
problem; `Fotos Sommer 2024`, `Grüße & Küsse` and `日本語` all worked, and
`50% done` worked *by luck* — `% d` is not a valid escape, while the `%ce` of
`100%cent` is one and decodes to a byte nobody typed.

**Decision: every path crossing into a URL goes through `components/PathUrl.qml`,
and it has two functions rather than one.**

Measured on Qt 6.11.2, over twenty punctuation names and six human ones, on the
`filePath` that came back rather than on a row count:

| | `"file://" + p` | per-segment `encodeURIComponent` | encoded twice |
|---|---|---|---|
| `Image.source` | `#?%` fail | **all pass** | all fail |
| `FolderListModel.folder` | `#?%` fail | `#?%` **still fail** | **all pass** |

`fileUrl()` is the correct, standard construction and `Image` takes it.
`folderModelUrl()` is what one Qt type will accept: `FolderListModel`
percent-decodes **one time too many**, so every escape has to be written twice.
That is a defect being worked around, not a rule, and the difference is not a
matter of taste — each form is *rejected* by the other's sink.

**The workaround is alarmed rather than trusted.** `tests/qml/tst_pathurl.qml`
asserts the asymmetry against real directories and real images. If a later Qt
stops double-decoding, that test fails loudly — instead of `folderModelUrl()`
quietly writing a literal `%20` into every name with a space in it.

## 2. Trusting a listing

`FolderListModel` resolves a folder it cannot open — and an **empty** one — to
the *process's* working directory, and it does not reliably let go of that
listing when a real path arrives afterwards. A `DirPane` is constructed with
`dir: ""`, so the first thing every pane ever lists is `~`; point one at a
directory that does not exist while that is still in flight and the `~` rows
stay, arriving at `Ready` under the new folder's name. Watched in the running
app: `dir=…/no-such-folder-here status=1 count=50 p0=$HOME/Music` — fifty rows
of a home directory under a breadcrumb naming somewhere else, with every
control live.

`status` cannot detect this. `Ready` is what it says, and `folder` reads back
as the path that was *asked for*, so neither is a witness.

**Decision: a pane shows and acts on a row only if it lives under the pane's own
`dir`.**

`DirPane::listingIsOurs` asks the one question that settles it — does row 0
start with `dir + "/"`? — and `pane.count` is zero whenever the answer is no.
Every loop, every count, the header, the ListView's own model and the
enabling of every action read through that one expression, so nothing has to
remember to consult it. It is recomputed on folder, status, count and `dir`
changes rather than bound, because `get(0, …)` is a function call and not a
dependency Qt re-evaluates a binding for.

The pane then has a **third** thing to say. "Empty folder" is only true at
`Ready` with rows of our own; a directory that never answered is neither empty
nor loading, and it used to be drawn as a blank rectangle with no text at all.
It now says *"Nothing came back from this folder — it may be gone, or
unreadable"*, after a 1500 ms grace — ten times the 146 ms a 50,000-entry
listing took (ADR 0015), which is the largest load this project has measured.
The sentence reports the observation rather than a diagnosis, because a folder
slower than the grace period gets it too.

## Consequences

- A pane briefly shows nothing rather than the previous directory's rows while
  a new one loads. That is a change in what the window does, and it is the
  point: the rows on screen now always belong to the path in the breadcrumb.
- `PathUrl` is QtQuick-only, like `Wording` and `Contrast`, so `qmltestrunner`
  can hold it. The test needs a fixture with unspeakable names in it;
  `scripts/test-qml.sh` builds one under `/tmp/omafile-auto/` rather than
  committing directories called `q?mark` into a published tarball.
- The daemon is not involved in either half. Paths reach it as JSON strings and
  never as URLs, and a copy of `note #3.txt` into `track #1/` was verified on
  disk.
