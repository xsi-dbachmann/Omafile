import QtQuick
import QtTest

import "../../components"

// The extension rules, which are the half of icons that can be wrong silently.
//
// A wrong glyph is not a crash and not a lint failure; it is a row that quietly
// claims to be something it is not, in a product whose whole argument is that
// it does not do that.
TestCase {
  name: "FileKind"

  FileKind { id: k }

  function test_a_folder_is_a_folder_whatever_it_is_called() {
    compare(k.iconFor("photos", true), k.folder)
    // The trap: a directory whose name ends in an archive extension. The
    // archive glyph would be a lie about what opening it does.
    compare(k.iconFor("photos.zip", true), k.folder)
    compare(k.iconFor("notes.txt", true), k.folder)
  }

  function test_a_dotfile_has_no_extension() {
    // ".bashrc" is hidden, not a file of type "bashrc". Reading the tail as an
    // extension would give every dotfile whatever that word happened to match.
    compare(k.extensionOf(".bashrc"), "")
    compare(k.extensionOf(".gitignore"), "")
    compare(k.iconFor(".bashrc", false), k.generic)
  }

  function test_a_trailing_dot_is_not_an_extension() {
    compare(k.extensionOf("weird."), "")
    compare(k.iconFor("weird.", false), k.generic)
  }

  function test_no_extension_at_all() {
    compare(k.extensionOf("Makefile"), "")
    compare(k.iconFor("Makefile", false), k.generic)
  }

  function test_case_does_not_matter() {
    compare(k.extensionOf("IMG_2481.JPG"), "jpg")
    compare(k.iconFor("IMG_2481.JPG", false), k.iconFor("img.jpg", false))
    compare(k.iconFor("CLIP.MoV", false), k.iconFor("clip.mov", false))
  }

  function test_only_the_last_extension_counts() {
    // archive.tar.gz is a gzip; the icon follows the outermost thing, which is
    // what a user acts on.
    compare(k.extensionOf("archive.tar.gz"), "gz")
    compare(k.iconFor("archive.tar.gz", false), k.iconFor("x.gz", false))
  }

  function test_families_share_a_glyph() {
    // Grouped by what a person would do with the file, not by format family.
    compare(k.iconFor("a.jpg", false), k.iconFor("b.webp", false))
    compare(k.iconFor("a.mp4", false), k.iconFor("b.mkv", false))
    compare(k.iconFor("a.mp3", false), k.iconFor("b.flac", false))
    compare(k.iconFor("a.zip", false), k.iconFor("b.7z", false))
  }

  function test_unknown_extensions_fall_back_rather_than_break() {
    compare(k.iconFor("thing.qqqq", false), k.generic)
    compare(k.iconFor("", false), k.generic)
  }

  function test_kinds_are_actually_distinct() {
    // A table where two families collided would pass every test above while
    // making the icons useless.
    var seen = [k.folder, k.generic,
                k.iconFor("a.jpg", false), k.iconFor("a.mp4", false),
                k.iconFor("a.mp3", false), k.iconFor("a.pdf", false),
                k.iconFor("a.zip", false), k.iconFor("a.txt", false),
                k.iconFor("a.py", false)]
    for (var i = 0; i < seen.length; i++)
      for (var j = i + 1; j < seen.length; j++)
        verify(seen[i] !== seen[j], "glyphs " + i + " and " + j + " are the same")
  }
}
