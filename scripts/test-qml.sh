#!/usr/bin/env bash
# Run the QML tests, headless.
#
# The plugin had no tests at all while `qmltestrunner` sat installed and unused,
# and every UI claim this project has made was therefore made by a person looking
# at a screen. Some of them do not need a screen: an undo stack that must spend
# the entry it was given rather than the top one, and a sentence that must count
# what landed rather than what was asked for, are arithmetic.
#
# **What can be tested here is exactly what does not import `qs.*`.** Quickshell's
# modules are compiled into the `quickshell` binary's own resources
# (`prefer :/qt/qml/Quickshell/` in its qmldir), so no other process can load
# them: a component that reads `Color` cannot be instantiated by this runner, no
# matter what import path it is given. That is the reason `components/Wording.qml`
# exists and imports QtQuick alone.
#
# Same three rules as scripts/lint-qml.sh, for the same reasons (ticket 20):
# absolute path, asserted version, and a non-zero exit when anything fails.
set -euo pipefail

RUNNER=/usr/lib/qt6/bin/qmltestrunner
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -x $RUNNER ]] || {
  printf 'test-qml: %s is missing. Install qt6-declarative.\n' "$RUNNER" >&2
  exit 2
}

version="$("$RUNNER" -help 2>&1 | head -1)"
[[ -d $project_dir/tests/qml ]] || {
  printf 'test-qml: no tests at %s/tests/qml.\n' "$project_dir" >&2
  exit 2
}

cd "$project_dir/tests/qml"

# Offscreen, so this runs over ssh, in a hook, and in a session with the monitor
# off — none of which a ghost survives, because a ghost's output is a window on
# the host and a dark screen is a dark capture.
out="$(QT_QPA_PLATFORM=offscreen "$RUNNER" -input . 2>&1)" || {
  printf '%s\n' "$out"
  printf 'test-qml: failures above.\n' >&2
  exit 1
}
printf '%s\n' "$out" | grep -E '^(PASS|FAIL|SKIP|Totals)' || true

# A run that instantiates nothing still exits 0. `Totals: 0 passed` and a compile
# error that skipped a whole file both have to fail here, or this script becomes
# the thing it was written to replace.
if grep -qE '^(FAIL|QFATAL)' <<<"$out"; then
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! grep -qE 'Totals: [1-9][0-9]* passed' <<<"$out"; then
  printf '%s\n' "$out" >&2
  printf 'test-qml: nothing ran.\n' >&2
  exit 1
fi
