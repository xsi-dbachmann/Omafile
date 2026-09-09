pragma ComponentBehavior: Bound

import QtQuick

// Colour arithmetic that has to stay legible on somebody else's theme.
//
// Omarchy ships 22 themes and at least three are light. Every screenshot this
// project took for its first week was dark, and under `Flexoki Light` the
// inactive pane's Modified and Size columns measured **1.0:1** contrast —
// text the same luminance as the row behind it. Not dim. Gone. Those are the
// columns carrying the byte facts the product's whole argument rests on.
//
// The cause was that "recede" was implemented as **alpha**:
// `Qt.rgba(Color.muted.r, .g, .b, 0.55)` composites the colour *toward whatever
// is behind it*. On a dark ground that moves a light grey toward black and the
// gap survives. On a light ground it moves a mid grey toward near-white and the
// gap closes. One operation, opposite outcomes, decided entirely by a theme the
// component never sees.
//
// So receding is expressed here as **less contrast against my own surface**,
// which means the same thing on both grounds, with a floor below which it will
// not go however hard it is pushed. If the base colour *already* fails the floor
// — which is the light-theme `muted` case even at full strength — it is pushed
// past the base, away from the surface, until it passes.
//
// QtQuick and nothing else, deliberately: `qmltestrunner` can hold this and
// cannot hold anything importing `qs.Commons`, which is the same reason
// `Wording.qml` exists. Colour that decides whether a number can be read is
// arithmetic, and arithmetic is checkable without a display.
// See `tests/qml/tst_contrast.qml`.
QtObject {
  id: contrast

  /// WCAG relative luminance. The channel curve is not decorative: a plain
  /// average calls #767676 and #949494 equally far from white, and they are not.
  function channel(v) {
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
  }

  function luminance(c) {
    return 0.2126 * contrast.channel(c.r)
         + 0.7152 * contrast.channel(c.g)
         + 0.0722 * contrast.channel(c.b)
  }

  /// The WCAG ratio, always >= 1 and order-independent.
  function ratio(a, b) {
    var la = contrast.luminance(a)
    var lb = contrast.luminance(b)
    var hi = Math.max(la, lb)
    var lo = Math.min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
  }

  function mix(a, b, t) {
    var k = Math.max(0, Math.min(1, t))
    return Qt.rgba(a.r + (b.r - a.r) * k,
                   a.g + (b.g - a.g) * k,
                   a.b + (b.b - a.b) * k,
                   1)
  }

  /// `base`, receded toward `surface` by `amount` (0 keeps it, 1 would erase
  /// it), but never below `floor` contrast against that same surface.
  ///
  /// Three cases, in the order they are tried:
  ///
  ///   1. The receded colour already passes — use it. This is the common path
  ///      and costs one ratio.
  ///   2. It fails, but `base` passes: give back exactly as much of the recede
  ///      as the floor allows, so a theme with room still gets the effect.
  ///   3. `base` itself fails — the light-theme `muted` case. Push *past* base,
  ///      away from the surface, toward black or white depending on which way
  ///      the surface is. This is the branch that makes a size column readable
  ///      on a cream background, and it is why this returns a colour rather
  ///      than an opacity.
  ///
  /// The walk is 24 fixed steps rather than a solve. It is deterministic, which
  /// is what makes it testable, and 4% of a colour ramp is finer than an eye
  /// reads off a 12px label.
  function recede(base, surface, amount, floor) {
    var wanted = contrast.mix(base, surface, amount)
    if (contrast.ratio(wanted, surface) >= floor) return wanted

    // Case 2: walk back from the receded colour toward base.
    var steps = 24
    for (var i = 1; i <= steps; i++) {
      var back = contrast.mix(wanted, base, i / steps)
      if (contrast.ratio(back, surface) >= floor) return back
    }

    // Case 3: base is not enough either. Head for the far end.
    var away = contrast.luminance(surface) > 0.45 ? Qt.rgba(0, 0, 0, 1)
                                                  : Qt.rgba(1, 1, 1, 1)
    for (var j = 1; j <= steps; j++) {
      var past = contrast.mix(base, away, j / steps)
      if (contrast.ratio(past, surface) >= floor) return past
    }
    return away
  }
}
