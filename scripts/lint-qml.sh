#!/usr/bin/env bash
# Lint the QML half of omafile, and fail if anything is wrong.
#
# Three things here are deliberate, and each of them is a bug this script
# exists because of (ticket 20):
#
#   1. The Qt 6 linter is called by ABSOLUTE PATH. Bare `qmllint` on this
#      machine resolves to /usr/bin/qmllint, which is Qt 5's (qt5-declarative).
#      It exits 0 on a file containing an undefined property and exits 255 with
#      no output at all on App.qml — through a pipe, indistinguishable from
#      success. Every "qmllint is clean" claim this project made was that.
#
#   2. The version is asserted. A PATH change, a Qt 5 fallback or a packaging
#      shuffle must fail loudly rather than silently passing everything.
#
#   3. Warnings fail the run. The Qt 6 linter exits 0 with warnings present, so
#      the exit code alone is not a gate — the output is inspected.
#
# Quickshell's `qs.*` modules live in the shell tree, so the linter needs an
# import root containing a `qs` directory. Without it every `Color.*` reference
# is reported as unqualified access and the output is worse than useless.
set -euo pipefail

QMLLINT=/usr/lib/qt6/bin/qmllint
SHELL_QML="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -x $QMLLINT ]] || {
  printf 'lint-qml: %s is missing. Install qt6-declarative.\n' "$QMLLINT" >&2
  exit 2
}

version="$("$QMLLINT" --version 2>&1)"
[[ $version == *"qmllint 6."* ]] || {
  printf 'lint-qml: expected the Qt 6 linter, got "%s" from %s.\n' "$version" "$QMLLINT" >&2
  printf 'lint-qml: Qt 5 qmllint reports nothing and passes everything — refusing to pretend.\n' >&2
  exit 2
}

[[ -d $SHELL_QML/Commons ]] || {
  printf 'lint-qml: no Quickshell modules at %s; qs.Commons would not resolve.\n' "$SHELL_QML" >&2
  exit 2
}

shim="$(mktemp -d)"
trap 'rm -rf "$shim"' EXIT
ln -s "$SHELL_QML" "$shim/qs"

cd "$project_dir"

# Rank 7 -- arming and acting must be the same expression (instance #8).
#
# A pane's `selection` is names, files and folders alike; the actions run on
# selectedPaths(), which drops folders. Every control armed from
# `selection.length` therefore lit for a folder and then did nothing -- Copy,
# Move and Delete, in the menu and in the action bar, watched failing on
# 2026-09-08 with the daemon log, the journal and the destination all
# untouched. DirPane.selectedFileCount() and DirPane.containsDir are the
# expressions the actions agree with, so outside DirPane.qml nothing reads
# `.selection` directly, and popupAt() is never handed a literal for `dir`.
# Both greps are anchored on a dot or a call, so prose mentioning "the
# selection" in a comment does not trip them.
raw_selection="$( { grep -nE '\.selection\b' App.qml components/*.qml || true; } \
                 | { grep -v '^components/DirPane.qml:' || true; } )"
literal_dir="$( { grep -nE 'popupAt\([^)]*,[[:space:]]*(true|false)[[:space:]]*\)' App.qml components/*.qml || true; } )"
if [[ -n $raw_selection$literal_dir ]]; then
  [[ -n $raw_selection ]] && printf '%s\n' "$raw_selection"
  [[ -n $literal_dir ]] && printf '%s\n' "$literal_dir"
  printf 'lint-qml: a control is armed from selection.length, or popupAt is told a literal dir (rank 7).\n' >&2
  printf 'lint-qml: arm from DirPane.selectedFileCount() and DirPane.containsDir -- the expressions the actions run on.\n' >&2
  exit 1
fi

# Issue 39 -- a stacked layer's input guard must be a MouseArea, not a TapHandler.
#
# All five overlays swallowed input with `TapHandler { onSingleTapped: ... }` at
# the root, and Shortcuts.qml even claimed in a comment that this meant "a stray
# press while the sheet is up cannot land on a file row underneath it". It does
# not. A TapHandler takes only a PASSIVE grab on press, so delivery continues to
# items below -- and a `DragHandler` down there takes the press quite happily.
#
# Watched on 2026-09-09: with the conflict dialog open, a drag on the pane behind
# it ran. `beginTransfer` refused the second transfer ("one at a time"), so the
# guard held, but `pane.activated()` fired on the way and App.qml answers that
# with `browser.forceActiveFocus()` -- so the dialog lost the keyboard and
# stopped answering Escape while still saying "Escape cancels".
#
# A MouseArea does not fix it either, and that was watched failing too: Qt 6
# offers a press to every item's pointer HANDLERS first, front to back, and only
# then to the items, so a DragHandler below is served before any MouseArea above
# it. Neither does a TapHandler with `gesturePolicy: WithinBounds`, which takes
# the exclusive grab and then drops it the instant the point moves -- which is
# when a drag begins. `components/InputShield.qml` carries the measurements.
#
# What stops a handler is `enabled`, and App.qml's `modalOpen` is where that
# lives. InputShield is still required here because it is what stops everything
# that is NOT a handler -- every MouseArea beneath, and hover, and the wheel.
#
# The scan is structural: a TapHandler at brace depth 1 is a direct child of the
# file's ROOT item, and therefore covers the whole component. That alone is
# fine -- FileRow is a row-sized tap target and legitimately does it. It is only
# a hazard when the component is a STACKED layer, which is what a root-level
# `z:` declares. So both conditions are required, which is why ContextMenu's
# per-row handlers (depth > 1) and FileRow's (no root z) do not trip it.
bad_shield="$(awk '
  FILENAME ~ /InputShield\.qml$/ { next }
  FNR == 1 { depth = 0; rootz = 0; hits = "" }
  {
    if (depth == 1 && $0 ~ /^  z: [0-9]+/) rootz = 1
    if (depth == 1 && $0 ~ /TapHandler[[:space:]]*\{/) hits = hits FILENAME ":" FNR ": " $0 "\n"
    n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m
  }
  ENDFILE { if (rootz && hits != "") printf "%s", hits }
' App.qml components/*.qml)"
if [[ -n $bad_shield ]]; then
  printf '%s\n' "$bad_shield"
  printf 'lint-qml: a stacked layer guards its surface with a TapHandler (issue 39).\n' >&2
  printf 'lint-qml: a TapHandler takes a passive grab, so a DragHandler underneath still gets the press.\n' >&2
  printf 'lint-qml: use InputShield, which is a MouseArea and takes an exclusive one.\n' >&2
  exit 1
fi

# Every _send's return must be checked.
#
# DaemonClient's senders return the request id, or **-1 if nothing was sent**,
# and their doc comment says every caller must check: a caller that assumed the
# request went out has already told the user it did. `daemon.canTrash()` was the
# one that did not. Its own `canTransfer` guard does not cover it -- liveness is
# inferred from traffic in the last five seconds, so the socket can be shut
# while the daemon still reads as live -- and in that window Delete put up no
# dialog, no notice and no refusal at all. Watched on screen 2026-09-08.
#
# A bare call at the start of a statement is by construction a discarded return.
# Anything that keeps it -- `var id = ...`, `if (... !== -1)`, `=== -1` -- does
# not match, because the call is not the first thing on the line.
unchecked_send="$( { grep -nE '^[[:space:]]*daemon\.(copy|move|conflicts|del|canTrash|rename|restore)\(' \
                       App.qml components/*.qml || true; } )"
if [[ -n $unchecked_send ]]; then
  printf '%s\n' "$unchecked_send"
  printf 'lint-qml: a daemon request is sent and its return thrown away.\n' >&2
  printf 'lint-qml: -1 means nothing was sent. Check it, or the refusal is silent.\n' >&2
  exit 1
fi

# Issue 17 -- a list that clips must say that it is clipping.
#
# `DirPane`'s ListView had `clip: true` and no indicator of any kind: a pane
# whose header read "40 files" drew nineteen of them and nothing on screen
# suggested the other twenty-one existed. `TransferPanel`, a few pixels below,
# hand-built exactly the missing indicator, which made the omission look
# deliberate. Both now instantiate `ScrollHint`, and the next clipping list
# added cannot repeat this quietly.
#
# The scan is structural, not a file-wide grep for `clip: true`: brace depth is
# tracked from each `ListView {` so an unrelated clipping Rectangle in the same
# file does not demand a scrollbar.
missing_hint="$(awk '
  FILENAME ~ /ScrollHint\.qml$/ { next }
  FNR == 1 { inlist = 0; depth = 0; clip = 0 }
  !inlist && /(^|[^A-Za-z_.])ListView[[:space:]]*\{/ { inlist = 1; depth = 0; clip = 0 }
  inlist {
    if ($0 ~ /clip:[[:space:]]*true/) clip = 1
    depth += gsub(/\{/, "{")
    depth -= gsub(/\}/, "}")
    if (depth <= 0) { if (clip) clippers[FILENAME] = 1; inlist = 0 }
  }
  /ScrollHint[[:space:]]*\{/ { hinted[FILENAME] = 1 }
  END { for (f in clippers) if (!(f in hinted)) print f }
' App.qml components/*.qml)"
if [[ -n $missing_hint ]]; then
  printf '%s\n' "$missing_hint"
  printf 'lint-qml: a ListView clips its content and shows no scroll affordance (issue 17).\n' >&2
  printf 'lint-qml: add `ScrollHint { list: <id> }` as a sibling -- it is an overlay and costs no width.\n' >&2
  exit 1
fi

# The protocol pairing: the plugin, the daemon, and the recorded history must
# all name the same number (issue 29).
#
# Stateless on purpose. The obvious check -- "did this diff touch
# PROTOCOL_VERSION" -- passes silently in a clean checkout, which is almost
# always, so it would be absent exactly when someone runs the lint to be sure.
# This reads the three live values and asserts they agree, on every run.
#
# Two constants have to match across a language boundary and nothing checked
# them before: DaemonClient.qml's `expectedProtocol` against protocol.rs's
# `PROTOCOL_VERSION`. That is this project's signature defect with a compiler
# on only one side of it.
p_daemon="$(sed -n 's/^pub const PROTOCOL_VERSION: u32 = \([0-9]*\);.*/\1/p' daemon/src/protocol.rs)"
p_plugin="$(sed -n 's/.*readonly property int expectedProtocol: \([0-9]*\).*/\1/p' components/DaemonClient.qml)"
p_row="$(sed -n 's/.*PROTOCOL_HISTORY[^=]*= *&\[\(.*\)\];.*/\1/p' daemon/src/protocol.rs | grep -oE '\([0-9]+, "[^"]+"\)' | tail -1)"
p_hist="${p_row%%,*}"; p_hist="${p_hist#(}"
p_since="${p_row##*\"*\"}"; p_since="$(grep -oE '"[^"]+"' <<<"$p_row" | tr -d '"')"

if [[ -z $p_daemon || -z $p_plugin || -z $p_hist || -z $p_since ]]; then
  printf 'lint-qml: cannot read the protocol pairing (daemon=%s plugin=%s history=%s since=%s).\n' \
    "${p_daemon:-?}" "${p_plugin:-?}" "${p_hist:-?}" "${p_since:-?}" >&2
  printf 'lint-qml: PROTOCOL_VERSION, PROTOCOL_HISTORY or expectedProtocol changed shape.\n' >&2
  exit 1
fi

if [[ $p_daemon != "$p_plugin" || $p_daemon != "$p_hist" ]]; then
  printf 'lint-qml: the protocol number disagrees across the two halves.\n' >&2
  printf '  daemon/src/protocol.rs   PROTOCOL_VERSION   = %s\n' "$p_daemon" >&2
  printf '  components/DaemonClient.qml expectedProtocol = %s\n' "$p_plugin" >&2
  printf '  daemon/src/protocol.rs   PROTOCOL_HISTORY   = %s (since daemon %s)\n' "$p_hist" "$p_since" >&2
  printf 'lint-qml: the handshake is an equality test, so a mismatch here is browse-only for\n' >&2
  printf 'lint-qml: every user of the half that is behind. Bumping the protocol means: add a\n' >&2
  printf 'lint-qml: PROTOCOL_HISTORY row, bump daemon/Cargo.toml, set expectedProtocol -- and\n' >&2
  printf 'lint-qml: PUBLISH THE AUR PACKAGE BEFORE the plugin commit reaches the release\n' >&2
  printf 'lint-qml: branch, because a plugin commit is a release the moment it lands there.\n' >&2
  exit 1
fi

cargo_ver="$(sed -n 's/^version = "\(.*\)"/\1/p' daemon/Cargo.toml | head -1)"
if [[ $p_since != "$cargo_ver" ]] && ! printf '%s\n%s\n' "$p_since" "$cargo_ver" | sort -V -C; then
  printf 'lint-qml: PROTOCOL_HISTORY says protocol %s arrived in daemon %s, which is NEWER\n' "$p_hist" "$p_since" >&2
  printf 'lint-qml: than daemon/Cargo.toml (%s). The table names a daemon that does not exist.\n' "$cargo_ver" >&2
  exit 1
fi

out="$("$QMLLINT" -I . -I "$shim" App.qml components/*.qml 2>&1 || true)"

# The linter does not always terminate a diagnostic with a newline, so
# consecutive warnings run together on one line: `grep -c '^Warning'` undercounts
# badly (it reported 6 for a run of 17). Count occurrences, not lines.
# `grep -o | wc -l` exits non-zero when there is nothing to match, and under
# `set -euo pipefail` that aborts the script *on the clean path* — exit 1 with
# no output, which is precisely the silent-failure shape this script exists to
# stop. Swallow grep's status; wc reports the count.
n=$( { grep -oE '(Warning|Error):' <<<"$out" || true; } | wc -l )
if (( n > 0 )); then
  printf '%s\n\n' "$out"
  printf 'lint-qml: %s problem(s) with %s.\n' "$n" "$version" >&2
  exit 1
fi

printf 'lint-qml: clean (%s, %s files).\n' "$version" "$(ls App.qml components/*.qml | wc -l)"
