pragma ComponentBehavior: Bound

import QtQuick

// A path is not a URL, and this is where the difference is paid for.
//
// Three sites built one by concatenation — `"file://" + path` — and three
// characters in a *name* change what that string means: `#` starts a fragment,
// `?` starts a query, `%` starts an escape. A folder called `track #1` asked
// for `/…/track ` and got nothing; `100%CASHBACK` asked for a byte nobody
// named. The pane went blank and said nothing, because the one control that
// distinguishes "empty" from "not loaded" only fires when the model reaches
// `Ready`, and a rejected URL never does (issue 06).
//
// Spaces and non-ASCII were never the problem. `Fotos Sommer 2024`, `Grüße &
// Küsse` and `日本語` all worked before this file existed, and `50% done`
// worked *by luck* — `% d` is not a valid escape, so it survived, while
// `%ce` is one and did not. A defect that spares the obvious fixture and takes
// the unlucky name is exactly the shape this project keeps finding.
//
// **The two functions are not the same string, and that is a measured fact
// rather than a taste.** Per-segment `encodeURIComponent` is the correct,
// standard construction and `Image.source` accepts it. `FolderListModel.folder`
// does not: it percent-decodes one time too many, so it needs every escape
// written twice. Measured on Qt 6.11.2 over twenty punctuation names and six
// human ones, checking the `filePath` that came back rather than a row count:
//
//              "file://"+p   encodeURIComponent   encoded twice
//   Image        #?% fail        ALL OK              all fail
//   FolderList   #?% fail        #?% fail            ALL OK
//
// So `fileUrl` is what a URL should be and `folderModelUrl` is what one Qt
// type will accept. If a later Qt fixes the double-decode, `folderModelUrl`
// breaks *everything* rather than the three characters — a space would become
// a literal `%20` in a name — so the asymmetry is asserted in
// `tests/qml/tst_pathurl.qml` against the real filesystem, and that test is
// the alarm.
//
// QtQuick and nothing else, for the reason `Wording.qml` and `Contrast.qml`
// give: `qmltestrunner` can hold it, and cannot hold anything importing
// `qs.Commons`.
QtObject {
  id: pathUrl

  /// A correct `file://` URL for an absolute path. What `Image.source` — and
  /// anything else that parses a URL the way the standard says — wants.
  ///
  /// Encoded per segment, so the separators stay separators and everything
  /// else that could be read as syntax stops being syntax.
  function fileUrl(path) {
    return "file://" + pathUrl._encode(path, false)
  }

  /// The same path for `FolderListModel.folder`, which decodes twice.
  ///
  /// Not a style choice and not a belt-and-braces: `fileUrl` is *rejected* by
  /// that type for `#`, `?` and `%`, and this is the only form it accepts for
  /// all three. See the table above.
  function folderModelUrl(path) {
    return "file://" + pathUrl._encode(path, true)
  }

  function _encode(path, twice) {
    return String(path).split("/").map(function (seg) {
      var e = encodeURIComponent(seg)
      return twice ? encodeURIComponent(e) : e
    }).join("/")
  }
}
