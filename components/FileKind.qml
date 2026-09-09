pragma ComponentBehavior: Bound

import QtQuick

// What a row is, as a glyph — and nothing else.
//
// This is the second component to exist for the reason `Wording.qml` does:
// it imports **QtQuick alone**, so `qmltestrunner` can instantiate it. Anything
// reaching `qs.Commons` cannot be loaded by any process but Quickshell's own
// binary, and a lookup table with thirty-odd entries is exactly the kind of
// thing that should be tested rather than eyeballed once in a screenshot.
//
// Issue 36: a row drew one glyph — `▸` for a directory, `·` for a file — and
// the *same* column was how a picked row was shown. Three independent facts
// sharing one 8px character, which is why "with the dot it is not clear if it
// is a selection, folder or file" was the first thing a new user said about it.
// Kind moved here; picked-ness is now a mark of its own.
//
// The glyphs are Nerd Font codepoints. That is not a new dependency: Omarchy's
// own bar already renders `JetBrainsMono Nerd Font`, so the font is present
// wherever this plugin can run at all. Shipping SVGs instead would have put
// binary assets in a repository whose update mechanism shows the user a
// `git diff` (ADR 0006), which is the argument that keeps the daemon binary out
// of it too.
QtObject {
  id: kinds

  readonly property string folder: ""
  readonly property string generic: ""

  /// Extension to glyph. Lower-case keys; `kindOf` does the folding.
  ///
  /// Grouped by what a person would do with the file rather than by format
  /// family: a `.webp` and a `.jpg` are the same thing to someone looking for a
  /// photo, and no row is improved by distinguishing them.
  readonly property var table: ({
    "jpg": "", "jpeg": "", "png": "", "gif": "",
    "webp": "", "bmp": "", "tif": "", "tiff": "",
    "svg": "", "heic": "", "raf": "", "cr2": "",
    "nef": "", "dng": "", "arw": "",

    "mp4": "", "mkv": "", "mov": "", "avi": "",
    "webm": "", "m4v": "", "mpg": "", "mpeg": "",

    "mp3": "", "flac": "", "wav": "", "ogg": "",
    "opus": "", "m4a": "", "aac": "",

    "pdf": "",

    "zip": "", "gz": "", "bz2": "", "xz": "",
    "zst": "", "tar": "", "7z": "", "rar": "",

    "txt": "", "md": "", "log": "", "csv": "",

    "js": "", "ts": "", "py": "", "rs": "",
    "sh": "", "c": "", "h": "", "cpp": "",
    "qml": "", "json": "", "toml": "", "yaml": "",
    "yml": "", "html": "", "css": ""
  })

  /// The extension, lower-cased, or "" when there is not one.
  ///
  /// A leading dot is a hidden file and not an extension: `.bashrc` has no
  /// extension, and treating "bashrc" as one would give every dotfile the icon
  /// of whatever that word happened to match. A trailing dot is not one either.
  function extensionOf(name) {
    var n = String(name)
    var cut = n.lastIndexOf(".")
    if (cut <= 0 || cut === n.length - 1) return ""
    return n.substring(cut + 1).toLowerCase()
  }

  /// The glyph for a row. Directories never consult the table: a folder called
  /// `photos.zip` is a folder, and the archive icon would be a lie about what
  /// double-clicking it does.
  function iconFor(name, isDir) {
    if (isDir) return kinds.folder
    var ext = kinds.extensionOf(name)
    var hit = kinds.table[ext]
    return hit !== undefined ? hit : kinds.generic
  }
}
