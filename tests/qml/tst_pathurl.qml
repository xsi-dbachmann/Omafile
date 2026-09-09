pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Qt.labs.folderlistmodel
import "../../components"

// `PathUrl` is arithmetic on a string, and half of it could be tested as one.
// The other half cannot: the claim is that **two Qt sinks want two different
// encodings of the same path**, and a string assertion would only repeat what
// this file believes rather than what Qt does. So the sinks are driven against
// real directories and real images, and what comes back is the `filePath` —
// not a row count, which cannot tell "listed the right folder" from "listed
// some folder".
//
// The negative cases are the point. Asserting that `fileUrl` — the *correct*
// URL — is REJECTED by `FolderListModel` is an alarm, not a preference: on the
// day a Qt release stops double-decoding, that assertion fails here, loudly,
// instead of `folderModelUrl` quietly turning every space in a name into a
// literal `%20`.
//
// The fixture is made by `scripts/test-qml.sh` under `/tmp/omafile-auto/`,
// where this project's files are allowed to live, rather than committed —
// a directory called `q?mark` in a published tarball is a gift to nobody.
TestCase {
  id: tc
  name: "PathUrl"
  when: windowShown

  PathUrl { id: pathUrl }
  Item { id: holder }

  readonly property string root: "/tmp/omafile-auto/pathurl-fixture"

  // Names that carry a character a URL reads as syntax, and names that do not.
  readonly property var breaking: ["h#hash", "q?mark", "p%cent"]
  readonly property var innocent: ["plain", "sp ace", "Grüße & Küsse", "日本語",
                                   "a&amp", "pl+us"]

  // ---- the string, which is arithmetic ----

  function test_fileurl_encodes_each_segment_and_keeps_the_separators() {
    compare(pathUrl.fileUrl("/tmp/a b/c.txt"), "file:///tmp/a%20b/c.txt")
    compare(pathUrl.fileUrl("/tmp/track #1"), "file:///tmp/track%20%231")
    compare(pathUrl.fileUrl("/tmp/q?mark"), "file:///tmp/q%3Fmark")
    compare(pathUrl.fileUrl("/tmp/50% done"), "file:///tmp/50%25%20done")
    compare(pathUrl.fileUrl("/"), "file:///")
  }

  function test_foldermodelurl_writes_every_escape_twice() {
    compare(pathUrl.folderModelUrl("/tmp/a b/c.txt"), "file:///tmp/a%2520b/c.txt")
    compare(pathUrl.folderModelUrl("/tmp/track #1"), "file:///tmp/track%2520%25231")
    compare(pathUrl.folderModelUrl("/tmp/50% done"), "file:///tmp/50%2525%2520done")
  }

  function test_a_path_with_nothing_to_escape_is_left_alone() {
    compare(pathUrl.fileUrl("/tmp/omafile-auto/file-000123-alpha.txt"),
            "file:///tmp/omafile-auto/file-000123-alpha.txt")
    compare(pathUrl.folderModelUrl("/tmp/omafile-auto/big"),
            "file:///tmp/omafile-auto/big")
  }

  // ---- the sinks, which are Qt ----

  function lister(url) {
    var m = Qt.createQmlObject(
      'import Qt.labs.folderlistmodel; FolderListModel {'
      + ' showDirs: true; showDotAndDotDot: false; showHidden: false }', holder)
    m.folder = url
    return m
  }

  function image(url) {
    var im = Qt.createQmlObject('import QtQuick; Image { asynchronous: false }', holder)
    im.source = url
    return im
  }

  /// One `wait` for the whole matrix rather than one per case: a folder that
  /// will load reaches `Ready` well inside this, and one that was rejected sits
  /// at `Null` from the assignment onwards and will never move. Waiting per
  /// case turned a 36 ms suite into an eight-second one for no extra fact.
  readonly property int settle: 400

  function test_the_fixture_is_there_before_anything_is_concluded_from_it() {
    var m = lister(pathUrl.folderModelUrl(tc.root))
    wait(tc.settle)
    verify(m.status === FolderListModel.Ready,
           "fixture missing at " + tc.root + " — run scripts/test-qml.sh, which makes it")
    var seen = []
    for (var i = 0; i < m.count; i++) seen.push(String(m.get(i, "fileName")))
    var want = tc.breaking.concat(tc.innocent)
    for (var j = 0; j < want.length; j++)
      verify(seen.indexOf(want[j]) !== -1, "fixture has no '" + want[j] + "'")
    m.destroy()
  }

  function test_folderlistmodel_opens_every_name_through_folderModelUrl() {
    var names = tc.breaking.concat(tc.innocent), models = []
    for (var i = 0; i < names.length; i++)
      models.push(lister(pathUrl.folderModelUrl(tc.root + "/" + names[i])))
    wait(tc.settle)
    for (var k = 0; k < names.length; k++) {
      var m = models[k]
      compare(m.status, FolderListModel.Ready, names[k] + " never loaded")
      compare(m.count, 1, names[k] + " listed the wrong thing")
      compare(String(m.get(0, "filePath")), tc.root + "/" + names[k] + "/found.txt",
              names[k] + " listed a different directory")
      m.destroy()
    }
  }

  /// What a rejected URL leaves behind, and why the assertion is phrased as
  /// "did not list the right directory" rather than "failed".
  ///
  /// A refused folder does not settle on one observable state. Over five runs
  /// the same URL left the model at `Null` once and **Ready over the process's
  /// working directory** four times — `FolderListModel` falls back to the CWD
  /// for a path it could not resolve, which `DirPane.qml:331` already knew for
  /// the empty-path case. Asserting `Null` is therefore a flaky test *and* the
  /// wrong claim: the failure that matters is that the rows are not the rows
  /// that were asked for.
  function rows(m) {
    var out = []
    for (var i = 0; i < m.count; i++) out.push(String(m.get(i, "filePath")))
    return out.join(",")
  }

  /// The bug, stated as an assertion. `"file://" + path` is what all three
  /// call sites did before issue 06.
  function test_plain_concatenation_is_what_broke() {
    var models = []
    for (var i = 0; i < tc.breaking.length; i++)
      models.push(lister("file://" + tc.root + "/" + tc.breaking[i]))
    wait(tc.settle)
    for (var k = 0; k < tc.breaking.length; k++) {
      verify(tc.rows(models[k]) !== tc.root + "/" + tc.breaking[k] + "/found.txt",
             "'" + tc.breaking[k] + "' now opens from a concatenated path — "
             + "if Qt fixed this, PathUrl needs revisiting")
      models[k].destroy()
    }
  }

  /// The alarm. A correct URL is not enough for this one type, and the day it
  /// is, this fails.
  function test_folderlistmodel_still_rejects_the_correct_url() {
    var models = []
    for (var i = 0; i < tc.breaking.length; i++)
      models.push(lister(pathUrl.fileUrl(tc.root + "/" + tc.breaking[i])))
    wait(tc.settle)
    for (var k = 0; k < tc.breaking.length; k++) {
      verify(tc.rows(models[k]) !== tc.root + "/" + tc.breaking[k] + "/found.txt",
             "FolderListModel now opens a properly encoded '" + tc.breaking[k]
             + "' — it has stopped decoding twice, and folderModelUrl() is now "
             + "the bug: it would put a literal %20 in every name with a space")
      models[k].destroy()
    }
  }

  function test_image_takes_the_standard_url_and_not_the_doubled_one() {
    var names = ["plain.png", "sp ace.png", "h#hash.png", "q?mark.png",
                 "p%cent.png", "Grüße.png"]
    var good = [], concat = [], doubled = []
    for (var i = 0; i < names.length; i++) {
      good.push(image(pathUrl.fileUrl(tc.root + "/" + names[i])))
      concat.push(image("file://" + tc.root + "/" + names[i]))
      doubled.push(image(pathUrl.folderModelUrl(tc.root + "/" + names[i])))
    }
    wait(tc.settle)
    for (var k = 0; k < names.length; k++) {
      compare(good[k].status, Image.Ready, names[k] + " did not load through fileUrl()")
      // Everything but `plain.png` has something to escape, so the doubled form
      // must fail: that is why Preview does not use folderModelUrl().
      if (names[k] !== "plain.png")
        compare(doubled[k].status, Image.Error,
                names[k] + " loaded through the doubled form — the two encodings "
                + "have stopped being different and PathUrl should collapse")
      good[k].destroy(); concat[k].destroy(); doubled[k].destroy()
    }
  }
}
