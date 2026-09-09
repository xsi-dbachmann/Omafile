pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// Asked before a transfer starts, when it would land on files that already
// exist. Never mid-transfer: the engine takes an answer, it does not wait for
// one (ADR 0013).
//
// Silently overwriting was the previous behaviour and it was the worst of the
// options — not because overwriting is wrong, but because it was invisible. A
// drag onto files that already existed looked identical to nothing happening.
Rectangle {
  id: dialog

  property var existing: []
  property string destination: ""
  /// How many files the Job is carrying, not how many of them collide. The
  /// difference between the two is the entire difference between Skip and
  /// Cancel, and until issue 18 the dialog did not know it.
  property int jobFiles: 0

  /// True when skipping and cancelling are actually different things: some file
  /// in this Job is not in the way, so skipping still transfers something.
  ///
  /// When every file in the Job collides — and always when the Job is one file
  /// — "skip these" and "transfer nothing" are the same instruction, and
  /// offering both is what made the first person to operate this dialog press
  /// the wrong one while knowing exactly what they wanted (issue 18).
  readonly property bool skipDiffers: dialog.jobFiles > dialog.existing.length

  // The destination folder as the panes name it, for the heading. A trailing
  // slash, and "/" itself, must still leave the heading reading as a sentence;
  // the full path stays in the body, where it disambiguates two folders that
  // share a name.
  readonly property string destName: {
    var d = String(dialog.destination).replace(/\/+$/, "")
    var n = d.substring(d.lastIndexOf("/") + 1)
    return n !== "" ? n : (d !== "" ? d : "this folder")
  }

  // What "Keep both" actually produces. The rule is the engine's and it is
  // stated in Wording, which imports no theme and is therefore the half of this
  // dialog a headless test can check (tests/qml/tst_wording.qml).
  property Wording wording: Wording {}
  readonly property string keepBothAs: dialog.existing.length === 0
    ? ""
    : dialog.wording.keepBothAs(dialog.existing[0])

  signal chose(string policy)   // "skip" | "replace" | "keep_both"
  signal cancelled()

  visible: false
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.82)
  z: 95

  function ask(names, dest, fileCount) {
    existing = names
    destination = dest
    // Defaulting to "all of them collide" is the safe way round: it hides Skip
    // rather than offering an option that would do nothing.
    jobFiles = Number(fileCount) > 0 ? Number(fileCount) : names.length
    visible = true
    keys.forceActiveFocus()
  }
  function done() { visible = false }

  // Swallows the click. Answering this dialog is deliberate (issue 18), so
  // there is nothing to connect: a press on the dim area does nothing, and
  // now genuinely reaches nothing either (issue 39).
  InputShield {}

  Item {
    id: keys
    anchors.fill: parent
    focus: dialog.visible
    Keys.onPressed: function (event) {
      // Escape cancels. Return is deliberately left unbound rather than
      // wired to whichever button happens to be first or last: Replace is
      // the one answer here that destroys data, and this dialog's whole
      // design (issue 18's rule above) is that no button may be pressed by
      // habit. S and K reach the two answers that do not, so the keyboard
      // is not mouse-only any more (issue 25) without ever making Enter a
      // way to replace something.
      if (event.key === Qt.Key_Escape) {
        dialog.done(); dialog.cancelled(); event.accepted = true
      } else if (event.key === Qt.Key_S && dialog.skipDiffers) {
        dialog.done(); dialog.chose("skip"); event.accepted = true
      } else if (event.key === Qt.Key_K) {
        dialog.done(); dialog.chose("keep_both"); event.accepted = true
      }
    }
  }

  Rectangle {
    anchors.centerIn: parent
    width: 500
    height: heading.implicitHeight + list.implicitHeight + 150
    radius: 6
    color: Color.background
    border.width: 1
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.20)

    Text {
      id: heading
      anchors { top: parent.top; topMargin: 20; left: parent.left; leftMargin: 22; right: parent.right; rightMargin: 22 }
      wrapMode: Text.WordWrap
      // Name the place in the heading rather than saying "here" and making the
      // reader find it: the answer to this question depends entirely on which
      // folder is about to be written into.
      text: dialog.existing.length === 1
        ? "One file is already in " + dialog.destName
        : dialog.existing.length + " files are already in " + dialog.destName
      color: Color.foreground
      font.pixelSize: 15
      font.bold: true
    }

    Text {
      id: list
      anchors { top: heading.bottom; topMargin: 10; left: parent.left; leftMargin: 22; right: parent.right; rightMargin: 22 }
      wrapMode: Text.WordWrap
      // Names first — they are what the answer is about. The full path comes
      // after them, and the one button whose outcome is not readable from its
      // own label explains itself last.
      text: dialog.existing.slice(0, 4).join("\n")
            + (dialog.existing.length > 4 ? "\n… and " + (dialog.existing.length - 4) + " more" : "")
            + "\n\n" + dialog.destination
            + (dialog.existing.length > 0
               ? "\n\nKeep both adds a number rather than replacing: "
                 + dialog.existing[0] + " arrives as " + dialog.keepBothAs
                 + ", or the next free number."
               : "")
            // Said only when it is true, and it is the sentence the labels
            // cannot carry: which files each of the two non-transferring
            // answers leaves behind.
            + (dialog.skipDiffers
               ? "\n\nSkip leaves " + (dialog.existing.length === 1 ? "this one" : "these")
                 + " alone and transfers the other "
                 + (dialog.jobFiles - dialog.existing.length) + "."
               : "")
            // Keyboard: K and, when it differs from Cancel, S -- Replace has
            // no key, on purpose (issue 25).
            + "\n\n" + (dialog.skipDiffers ? "K keeps both · S skips · Escape cancels."
                                            : "K keeps both · Escape cancels.")
      color: Color.muted
      font.pixelSize: 12
      lineHeight: 1.25
    }

    Row {
      anchors { bottom: parent.bottom; bottomMargin: 18; right: parent.right; rightMargin: 22 }
      spacing: 10

      Repeater {
        // The rule here is that **no two buttons may produce the same outcome**.
        //
        // The labels were once "Don't transfer" and "Leave it alone", picked so
        // the button would echo the transfer panel's "2 left alone". That rule
        // was self-imposed — the panel builds its own string
        // (TransferPanel.qml:237) and never reads a label from here — and it
        // cost more than it bought: asked to skip, the first person to operate
        // this dialog read the two as synonyms and pressed cancel. Renaming
        // them to Cancel and Skip made the words conventional and left the
        // real problem standing, which is that **for a single-file transfer the
        // two do the same thing on disk** (issue 18).
        //
        // So Skip appears only when it means something the other buttons do
        // not: some file in this Job is not in the way. When it does appear,
        // Cancel stops being a bare dismissal and names its whole-Job
        // consequence, because that is the thing the reader is choosing between.
        //
        // Cancel is the only option that does not proceed, so it is drawn
        // quiet — no fill — rather than as a peer with equal weight.
        //
        // Measured on screen, not estimated — the widest case there is, five
        // files with two of them in the way, so every label is at its longest:
        // `Transfer nothing` 93 · `Skip these` 89 · `Keep both` 86 ·
        // `Replace them` 110, and with the 10px gaps the row spans **419px**
        // against the 456 this 500px box leaves between its margins. Keep new
        // copy under that, and measure it rather than counting characters.
        model: {
          var rows = []
          rows.push({ key: "cancel",
                      label: dialog.skipDiffers ? "Transfer nothing" : "Cancel",
                      danger: false, quiet: true })
          if (dialog.skipDiffers)
            rows.push({ key: "skip",
                        label: dialog.existing.length === 1 ? "Skip this one" : "Skip these",
                        danger: false, quiet: false })
          rows.push({ key: "keep_both", label: "Keep both", danger: false, quiet: false })
          // Replace destroys the existing files, so it carries the urgent role.
          rows.push({ key: "replace",
                      label: dialog.existing.length === 1 ? "Replace it" : "Replace them",
                      danger: true, quiet: false })
          return rows
        }
        Rectangle {
          id: btn
          required property var modelData
          width: label.width + 28
          height: 32
          radius: 4
          color: modelData.danger
            ? (h.hovered ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.40)
                         : Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.24))
            : modelData.quiet
            ? (h.hovered ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                         : "transparent")
            : (h.hovered ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.16)
                         : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08))
          Text {
            id: label
            anchors.centerIn: parent
            text: btn.modelData.label
            color: Color.foreground
            font.pixelSize: 12
            font.bold: btn.modelData.danger
          }
          HoverHandler { id: h }
          TapHandler {
            onSingleTapped: {
              dialog.done()
              if (btn.modelData.key === "cancel") dialog.cancelled()
              else dialog.chose(btn.modelData.key)
            }
          }
        }
      }
    }
  }
}
