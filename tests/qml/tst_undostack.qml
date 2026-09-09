import QtQuick
import QtTest
import "../../components"

// The undo stack, tested where it can be: it is a QtObject with no window, no
// daemon and no imports beyond QtQuick, which makes it the one piece of this
// plugin that a headless runner can hold.
//
// Every case here is a bug this project actually shipped or nearly shipped. The
// stack has been wrong in three different ways — popping before anything was
// attempted, spending the wrong entry, and spending an entry for a Job that left
// the file alone — and each was found by a person looking at a screen. These are
// the ones that need not be.
TestCase {
  id: t
  name: "UndoStack"

  UndoStack { id: stack }

  function init() { stack.clear() }

  function make(name) {
    return { kind: "rename", payload: name, label: "Rename back to " + name,
             busyLabel: "Renaming back to " + name + "…",
             path: "/tmp/" + name, originalName: name }
  }

  function test_push_and_peek() {
    stack.push(t.make("a"))
    stack.push(t.make("b"))
    compare(stack.entries.length, 2)
    compare(stack.peek().payload, "b")
    verify(stack.hasEntries)
    verify(stack.canUndo)
  }

  // Ctrl+Z with the daemon down used to pop the top entry before anything had
  // been attempted, so the offer vanished and nothing happened — which looks
  // exactly like the undo bug it was hiding.
  function test_begin_leaves_the_entry_on_the_stack() {
    var e = t.make("a")
    stack.push(e)
    stack.begin()
    compare(stack.entries.length, 1)
    verify(stack.busy)
    verify(!stack.canUndo)      // nothing else may be undone while one is in flight
    verify(stack.hasEntries)    // but it keeps its place in the bar
    compare(stack.nextLabel, "Renaming back to a…")
  }

  function test_release_puts_it_back_within_reach() {
    var e = t.make("a")
    stack.push(e)
    stack.begin()
    stack.release()
    verify(!stack.busy)
    compare(stack.entries.length, 1)
    compare(stack.peek(), e)
    compare(stack.nextLabel, "Rename back to a")
  }

  // The reason `inFlight` is held by identity: nothing stops a new mutation
  // being recorded while an undo is on its way, and a positional pop would then
  // spend the entry the user has not asked about.
  function test_commit_spends_the_in_flight_entry_not_the_top() {
    var first = t.make("first")
    stack.push(first)
    stack.begin()
    var later = t.make("later")
    stack.push(later)
    var spent = stack.commit()
    compare(spent, first)
    compare(stack.entries.length, 1)
    compare(stack.peek(), later)
  }

  // Issue 22. A reply that arrives after the window gave up waiting has no
  // `inFlight` to work from — `release()` cleared it — so it must name the entry
  // it belongs to. Spending the top instead would spend a different file.
  function test_retire_names_its_entry() {
    var abandoned = t.make("abandoned")
    stack.push(abandoned)
    stack.begin()
    stack.release()
    var fresh = t.make("fresh")
    stack.push(fresh)

    var gone = stack.retire(abandoned)
    compare(gone, abandoned)
    compare(stack.entries.length, 1)
    compare(stack.peek(), fresh)
  }

  // "Already spent" is an ordinary outcome, not an error: the user may have
  // undone it themselves while the daemon was quiet.
  function test_retire_of_an_entry_already_gone() {
    var e = t.make("a")
    stack.push(e)
    compare(stack.retire(e), e)
    compare(stack.retire(e), null)
    compare(stack.retire(null), null)
    compare(stack.entries.length, 0)
  }

  // The fallback exists so a commit is never a no-op, and it is exactly what
  // makes retire() necessary: with no inFlight, commit takes the top.
  function test_commit_without_in_flight_takes_the_top() {
    var a = t.make("a")
    var b = t.make("b")
    stack.push(a)
    stack.push(b)
    compare(stack.commit(), b)
    compare(stack.entries.length, 1)
  }

  // A session stack, deep enough for real mistakes and bounded so a long
  // session cannot grow it without limit. The oldest goes.
  function test_bounded_at_fifty() {
    for (var i = 0; i < 55; i++) stack.push(t.make("f" + i))
    compare(stack.entries.length, 50)
    compare(stack.entries[0].payload, "f5")
    compare(stack.peek().payload, "f54")
  }

  // Historical bug #6: a Keep-both move lands beside the occupant, so recording
  // the asked-for name would arm a Ctrl+Z that moves the file the user
  // explicitly chose to keep.
  function test_record_move_uses_the_landed_name() {
    stack.recordMove("/src/report.txt", "/dst", "report-2.txt")
    var e = stack.peek()
    compare(e.payload, "report-2.txt")
    compare(e.destination, "/dst/report-2.txt")
    compare(e.sourceDir, "/src")
    compare(e.label, "Move report-2.txt back")
  }

  function test_record_move_falls_back_to_the_source_name() {
    stack.recordMove("/src/report.txt", "/dst", "")
    compare(stack.peek().payload, "report.txt")
  }

  // One confirmation is one entry. Five files pushed five entries once, so the
  // "Ctrl+Z to put this back" the dialog had just promised put one file back and
  // left four in the trash.
  function test_trash_batch_is_one_entry() {
    stack.recordTrashBatch([{ path: "/a/one.txt", trashedAs: "x1", info: "i1" },
                            { path: "/a/two.txt", trashedAs: "x2", info: "i2" }])
    compare(stack.entries.length, 1)
    compare(stack.peek().payload, "2 items")
    compare(stack.peek().items.length, 2)
  }

  function test_empty_trash_batch_records_nothing() {
    stack.recordTrashBatch([])
    stack.recordTrashBatch(null)
    compare(stack.entries.length, 0)
    verify(!stack.hasEntries)
    compare(stack.nextLabel, "")
    compare(stack.peek(), null)
  }
}
