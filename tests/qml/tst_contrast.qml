import QtQuick
import QtTest
import "../../components"

// Issue 05. Under a light theme the inactive pane's Modified and Size columns
// measured 1.0:1 -- text the same luminance as its background -- because
// "recede" was alpha, which composites toward whatever is behind and therefore
// means opposite things on a dark and a light ground.
TestCase {
  name: "Contrast"

  Contrast { id: c }

  readonly property color white: Qt.rgba(1, 1, 1, 1)
  readonly property color black: Qt.rgba(0, 0, 0, 1)
  // The two grounds that actually caused this: Solitude's panes and Flexoki
  // Light's, measured off the captured frames (27/15 and 255/201 of 255).
  readonly property color darkPane: Qt.rgba(15 / 255, 15 / 255, 15 / 255, 1)
  readonly property color lightPane: Qt.rgba(201 / 255, 201 / 255, 201 / 255, 1)

  function test_luminance_endpoints() {
    compare(Math.round(c.luminance(white) * 1000) / 1000, 1)
    compare(Math.round(c.luminance(black) * 1000) / 1000, 0)
  }

  function test_ratio_is_the_wcag_range_and_order_free() {
    compare(Math.round(c.ratio(white, black) * 100) / 100, 21)
    compare(c.ratio(white, black), c.ratio(black, white))
    compare(c.ratio(white, white), 1)
  }

  function test_mix_endpoints_and_midpoint() {
    compare(c.mix(black, white, 0).r, 0)
    compare(c.mix(black, white, 1).r, 1)
    compare(Math.round(c.mix(black, white, 0.5).r * 100) / 100, 0.5)
  }

  function test_mix_clamps_rather_than_extrapolating() {
    compare(c.mix(black, white, -3).r, 0)
    compare(c.mix(black, white, 9).r, 1)
  }

  // Case 1: there is room, so the recede happens and the floor is not reached.
  function test_a_recede_with_room_is_left_alone() {
    var out = c.recede(white, darkPane, 0.45, 2.5)
    verify(c.ratio(out, darkPane) >= 2.5)
    // It really did recede: less contrast than the untouched base.
    verify(c.ratio(out, darkPane) < c.ratio(white, darkPane))
  }

  // Case 3, and the whole reason this file exists. A mid grey on a light pane
  // fails the floor even at full strength, so it must be pushed PAST the base
  // rather than merely un-receded.
  function test_muted_on_a_light_pane_is_pushed_past_its_base() {
    var muted = Qt.rgba(0.55, 0.55, 0.55, 1)
    verify(c.ratio(muted, lightPane) < 2.5)          // the bug, stated
    var out = c.recede(muted, lightPane, 0.45, 2.5)
    verify(c.ratio(out, lightPane) >= 2.5)           // the fix, asserted
    // Pushed toward black, because the surface is the light one.
    verify(c.luminance(out) < c.luminance(muted))
  }

  function test_the_same_call_on_a_dark_pane_goes_the_other_way() {
    var muted = Qt.rgba(0.35, 0.35, 0.35, 1)
    var out = c.recede(muted, darkPane, 0.0, 4.0)
    verify(c.ratio(out, darkPane) >= 4.0)
    verify(c.luminance(out) > c.luminance(muted))
  }

  // The floor is a floor at every amount, including "erase it entirely".
  function test_a_full_recede_still_meets_the_floor() {
    var out = c.recede(white, lightPane, 1.0, 3.0)
    verify(c.ratio(out, lightPane) >= 3.0)
  }

  function test_an_impossible_floor_returns_the_furthest_available() {
    // 21:1 is white-on-black; nothing meets it against a mid grey. It must
    // still return the best it can rather than the failed candidate.
    var out = c.recede(Qt.rgba(0.5, 0.5, 0.5, 1), lightPane, 0.5, 21)
    compare(Math.round(c.luminance(out) * 1000) / 1000, 0)
  }

  // Both panes, both themes, one rule: whatever comes back is readable.
  function test_every_pane_and_ground_combination_clears_its_floor() {
    var grounds = [darkPane, lightPane]
    var bases = [white, black, Qt.rgba(0.55, 0.55, 0.55, 1), Qt.rgba(0.35, 0.5, 0.7, 1)]
    for (var g = 0; g < grounds.length; g++)
      for (var b = 0; b < bases.length; b++)
        for (var a = 0; a <= 1.0001; a += 0.25)
          verify(c.ratio(c.recede(bases[b], grounds[g], a, 2.5), grounds[g]) >= 2.5)
  }
}
