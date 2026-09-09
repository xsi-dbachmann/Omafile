pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import qs.Commons

// One half of the browser: a directory, its selection, and nothing else.
//
// Dual-pane exists so the destination is a fact of the layout rather than
// something held in the head (ticket 08). This component therefore knows what
// it is showing and what is picked in it, and knows nothing about transfers.
Rectangle {
  id: pane

  property string dir: ""
  property bool active: false
  property var selection: []          // file names, not paths
  /// The shared sidebar's data, handed down so the per-pane Go▾ door (ADR
  /// 0014) can offer the same places and mounts without scanning for them a
  /// second time -- there is one `findmnt` poll for both panes, not two.
  property var places: []
  property var mounts: []
  /// How many rows this pane has, which is not always how many the model has.
  /// See `listingIsOurs`: a model listing somewhere else has no rows that
  /// belong to this pane, whatever it says it counted.
  readonly property int count: pane.listingIsOurs ? folderModel.count : 0
  /// The pane's arithmetic-bearing sentences. `Wording` imports QtQuick and
  /// nothing else, which is what lets `qmltestrunner` hold it (issue 26).
  property Wording wording: Wording {}
  /// A path is not a URL. `PathUrl` is the one place that difference is paid
  /// for, and `folderModelUrl` rather than `fileUrl` because this one Qt type
  /// decodes twice -- issue 06, where `track #1` opened nothing and said so
  /// nowhere.
  property PathUrl pathUrl: PathUrl {}
  /// The keyboard cursor. Exposed so the window can drive a pane without
  /// depending on where Qt happens to have put focus.
  property alias cursorIndex: list.currentIndex

  signal activated()                  // this pane was interacted with
  /// A row that is not a directory was activated. The pane does not open
  /// files itself -- opening is the window's business, exactly as it is for
  /// Enter, so both gestures go through one function and cannot diverge.
  signal openRequested()
  /// Show dotfiles. Persisted by the window (Ctrl+H).
  property bool showHidden: false
  property bool showIcons: true
  /// Sorting is the window's, not the pane's: two panes sorted differently
  /// cannot be compared, and comparing them is what dual-pane is for.
  property int sortField: FolderListModel.Name
  property bool sortReversed: false
  signal sortRequested(int field)

  /// What this pane's filesystem can still take, from the daemon.
  ///
  /// -1 means "not asked, or could not tell" and is deliberately NOT 0: zero is
  /// a full disk, a real answer somebody will act on, and treating "unknown" as
  /// "full" would refuse every transfer to a path the daemon merely could not
  /// stat.
  property real freeBytes: -1
  property real totalBytes: -1
  /// Asked whenever the directory changes, because free space is a fact about
  /// the filesystem the pane is now looking at, not about the one it left.
  signal spaceWanted(string path)

  /// The size of what is picked, for the pre-flight fit check. Folders count as
  /// nothing because this version does not transfer them, which is the same
  /// rule `selectedFileCount()` applies -- arming and acting stay one
  /// expression.
  function selectedBytes() {
    var total = 0
    for (var i = 0; i < pane.count; i++) {
      if (folderModel.get(i, "fileIsDir")) continue
      if (pane.selection.indexOf(String(folderModel.get(i, "fileName"))) === -1) continue
      total += Number(folderModel.get(i, "fileSize")) || 0
    }
    return total
  }

  /// Where this pane has been, and where it was before it went back.
  ///
  /// Recorded in `onDirChanged` rather than in `enter()`, `goUp()` and the four
  /// other places that assign `dir`. One gate, for the same reason
  /// `noteMutation()` is one gate: a navigation added later that forgets to
  /// record itself is a back button that silently skips a step.
  property var backStack: []
  property var forwardStack: []
  readonly property bool canGoBack: pane.backStack.length > 0
  readonly property bool canGoForward: pane.forwardStack.length > 0
  /// Suppresses recording while back/forward are themselves moving `dir`,
  /// which would otherwise push the place you just left back onto the stack
  /// and make Back oscillate between two directories forever.
  property bool _replaying: false
  property string _lastDir: ""

  onDirChanged: {
    // Rows belonging to the directory we just left are not this one's. Checked
    // before the early return, because a back/forward replay changes directory
    // too. See `listingIsOurs`.
    pane._checkListing()
    if (pane._replaying) { pane._lastDir = pane.dir; return }
    if (pane._lastDir !== "" && pane._lastDir !== pane.dir) {
      // Capped. A session that browses for hours should not accumulate an
      // unbounded array of strings for a button that reaches back nine or ten.
      var b = pane.backStack.concat([pane._lastDir])
      pane.backStack = b.length > 100 ? b.slice(b.length - 100) : b
      // Going somewhere new abandons the forward branch, as every browser does.
      pane.forwardStack = []
    }
    pane._lastDir = pane.dir
    // A filter belongs to the directory it was typed in. Carrying it across a
    // navigation would have a new folder open already hiding most of itself,
    // with the reason two directories behind you.
    pane.filter = ""
    filterInput.text = ""
    pane.filtering = false
    // Leaving the editor open across a navigation showed a field holding the
    // path you *came from* while the pane listed somewhere else -- and typing
    // was the only way back to a breadcrumb. It was cleared on the one route
    // that commits a typed path and on none of the five others that set `dir`,
    // which is exactly why this gate exists.
    pane.editingPath = false
    if (pane.dir !== "") pane.spaceWanted(pane.dir)
  }

  /// True while the path strip is a text field rather than a breadcrumb.
  property bool editingPath: false

  /// Narrowing what the pane lists, by substring.
  ///
  /// A filter hides files, and a pane that hides files without saying so is the
  /// same failure as a pane that draws nineteen of forty rows and shows no
  /// scrollbar (issue 17). So the strip is visible whenever a filter is set,
  /// and it states how many of how many survived.
  property string filter: ""
  property bool filtering: false

  function beginFilter() {
    pane.activated()
    pane.filtering = true
    filterInput.forceActiveFocus()
    filterInput.selectAll()
  }

  function endFilter(keepText) {
    pane.filtering = false
    if (!keepText) { pane.filter = ""; filterInput.text = "" }
    list.forceActiveFocus()
  }

  function beginPathEdit() {
    pane.activated()
    pathEdit.text = pane.dir
    // Focus is taken in the field's own onVisibleChanged; see there.
    pane.editingPath = true
  }

  /// Refuses rather than obeys. An empty pane pointed at a path that does not
  /// exist looks identical to an empty directory, and the user would have no
  /// way to tell which they had just done to themselves.
  function commitPath(text) {
    var want = String(text).trim()
    if (want === "") { pane.editingPath = false; return }
    if (want.charAt(0) === "~") want = pane.homePath + want.substring(1)
    // A trailing slash is how people type directories; it is not part of one.
    while (want.length > 1 && want.charAt(want.length - 1) === "/")
      want = want.substring(0, want.length - 1)
    pane.pathChecked(want)
  }

  signal pathChecked(string path)

  /// Set by the window, which owns the home directory.
  property string homePath: ""

  function goBack() {
    if (!pane.canGoBack) return
    var b = pane.backStack.slice()
    var to = b.pop()
    pane._replaying = true
    pane.forwardStack = [pane.dir].concat(pane.forwardStack)
    pane.backStack = b
    pane.dir = to
    pane._replaying = false
    pane.clearSelection()
  }

  function goForward() {
    if (!pane.canGoForward) return
    var f = pane.forwardStack.slice()
    var to = f.shift()
    pane._replaying = true
    pane.backStack = pane.backStack.concat([pane.dir])
    pane.forwardStack = f
    pane.dir = to
    pane._replaying = false
    pane.clearSelection()
  }

  /// Clicking anywhere in the pane makes it the active one -- the empty space
  /// below the rows, the header, the gutter. Before this, `activated()` was
  /// emitted only by FileRow, so the sole way to point the sidebar at a pane
  /// was to click a file in it: you could not aim without also selecting.
  ///
  /// A TapHandler rather than a MouseArea, and on the root rather than over
  /// the list, so it sees only taps the rows and the header controls did not
  /// take. It must not steal a click from a breadcrumb or from Go▾.
  /// Default gesturePolicy, deliberately -- the same correction the handler
  /// inside the ListView needed. ReleaseWithinBounds takes an *exclusive* grab
  /// on press, and on the pane's root that grab covers every child: it ate the
  /// scrollbar's clicks entirely, and the scrollbar was rewritten twice chasing
  /// a bug that was never in it. DragThreshold takes a passive grab and leaves
  /// controls inside the pane working.
  TapHandler {
    onSingleTapped: pane.activated()
  }
  signal contextRequested(real gx, real gy)
  signal dragBegan()
  signal dragReleased(real sx, real sy)
  signal dragMoved(real sx, real sy)
  /// True while this pane is the one a drag would land on.
  property bool dropTarget: false

  /// Bare filenames currently being flashed by reveal(). Reassigned whole so
  /// the rows' bindings re-evaluate; never mutated in place.
  property var revealed: []
  /// Names reveal() was asked for but could not find in the model yet, and how
  /// many times we have looked. FolderListModel refreshes off
  /// QFileSystemWatcher, which need not have caught the committing rename by
  /// the time the daemon reports the Job done.
  property var pendingReveal: []
  property int revealAttempts: 0

  /// Focus is brightness, not a border. A 2px accent stripe on the active
  /// pane's edge was easy to miss at a glance and easy to mistake for a
  /// divider; the pane you are aiming at should simply be the lit one.
  ///
  /// Derived from `Color.background` rather than written down, so it follows
  /// the user's theme and satisfies the lint's no-literal-colours rule.
  /// Named, because `FileRow` has to measure its text against the exact colour
  /// this paints (issue 05). Two expressions for one surface is how a row ends
  /// up computing legibility against a background it is not actually on.
  readonly property color surface: pane.active ? Qt.lighter(Color.background, 1.45)
                                               : Qt.darker(Color.background, 1.25)
  color: pane.surface

  /// A file's size, as `Wording::sizePhrase()` decides it: decimal, so the
  /// number here and the daemon's exact byte count reconcile in the head
  /// (issue 19 item 4b). This divided by 1024 and labelled the answer `MB`,
  /// and a 3,000,000-byte file therefore read `2.9 MB` in the column beside a
  /// panel row saying `3000000 bytes, exactly as expected`.
  ///
  /// Kept as a function on the pane because its callers ask the pane —
  /// `App.qml`'s not-enough-room notice asks `srcPane.humanSize(need)`, and
  /// the free-space label below asks for its own. The name stays; the
  /// arithmetic moved somewhere a headless runner can check it.
  function humanSize(bytes) {
    return pane.wording.sizePhrase(bytes)
  }

  /// When the file last changed, worded for a column 52px wide.
  ///
  /// Precision where it earns its place: a file that arrived in this session
  /// is identified by its clock time, one from this year by its date, and an
  /// older one by month and year -- nobody reads a 2019 timestamp to the
  /// minute, and the pixels go to the name instead.
  function humanTime(when) {
    var d = (when instanceof Date) ? when : new Date(when)
    if (!d || isNaN(d.getTime())) return ""
    // An unset mtime comes back as the epoch; a date column reading
    // "Jan 1970" for every row of a share is noise, not information.
    if (d.getFullYear() < 1971) return ""
    var now = new Date()
    if (d.getFullYear() === now.getFullYear()) {
      if (d.getMonth() === now.getMonth() && d.getDate() === now.getDate())
        return Qt.formatDateTime(d, "HH:mm")
      return Qt.formatDateTime(d, "d MMM")
    }
    return Qt.formatDateTime(d, "MMM yyyy")
  }

  function isSelected(name) { return selection.indexOf(name) !== -1 }

  function isRevealed(name) { return revealed.indexOf(name) !== -1 }

  function toggle(name) {
    var next = selection.slice()
    var i = next.indexOf(name)
    if (i === -1) next.push(name); else next.splice(i, 1)
    selection = next
  }

  function selectOnly(name) {
    selection = [name]
  }

  function clearSelection() {
    selection = []
  }

  function selectAllFiles() {
    var next = []
    for (var i = 0; i < pane.count; i++) {
      if (!folderModel.get(i, "fileIsDir"))
        next.push(String(folderModel.get(i, "fileName")))
    }
    selection = next
  }

  function toggleAtCursor() {
    var n = String(folderModel.get(list.currentIndex, "fileName"))
    if (n) toggle(n)
  }

  function moveCursor(delta) {
    var n = list.currentIndex + delta
    if (n < 0) n = 0
    if (n >= pane.count) n = pane.count - 1
    list.currentIndex = n
  }

  /// The file under the cursor, or "" when the cursor is on a folder or on
  /// nothing. Preview is a per-file gesture and a folder has nothing to show.
  function fileAtCursor() {
    var i = list.currentIndex
    if (i < 0 || i >= pane.count) return ""
    if (folderModel.get(i, "fileIsDir")) return ""
    return String(folderModel.get(i, "filePath"))
  }

  function moveCursorHome() { list.currentIndex = 0 }
  function moveCursorEnd() { list.currentIndex = pane.count - 1 }

  /// A page is however many rows the list actually shows, not a constant --
  /// the pane's height is not fixed (ADR 0014 made the divider draggable), and
  /// a PageDown that jumps a fixed 10 rows would over- or under-shoot a pane
  /// that has been resized. Issue 23.
  function moveCursorPage(sign) {
    moveCursor(sign * Math.max(1, Math.floor(list.height / 30)))
  }

  /// The path as clickable segments (ADR 0014's breadcrumb): `label` is what
  /// is drawn, `path` is what a click sets `dir` to. The root segment's path
  /// is "/", never "" -- FolderListModel resolves an empty folder to whatever
  /// the process's working directory happens to be, which is not this pane.
  function crumbs() {
    var p = String(pane.dir).replace(/\/+$/, "")
    if (p === "") p = "/"
    var parts = p.split("/").filter(function (s) { return s !== "" })
    var out = [{ label: "/", path: "/" }]
    var acc = ""
    for (var i = 0; i < parts.length; i++) {
      acc += "/" + parts[i]
      out.push({ label: parts[i], path: acc })
    }
    return out
  }

  function enterAtCursor() { enter(list.currentIndex) }

  /// Absolute paths for what is picked. Directories are excluded: v1 transfers
  /// files, and silently walking a tree would be a promise the engine does not
  /// yet make.
  function selectedPaths() {
    var out = []
    for (var i = 0; i < pane.count; i++) {
      var n = String(folderModel.get(i, "fileName"))
      if (isSelected(n) && !folderModel.get(i, "fileIsDir"))
        out.push(String(folderModel.get(i, "filePath")))
    }
    return out
  }

  /// The selection counted the way the actions count it.
  ///
  /// Controls were armed from `selection.length` while every action ran on
  /// `selectedPaths()`, which drops directories -- so right-clicking a folder,
  /// the most natural thing to right-click in a file manager, lit Copy, Move
  /// and Delete and then returned without doing or saying anything. Arming and
  /// acting have to be the same expression, so this is that expression.
  ///
  /// Safe to call from a binding: it reads `selection` and `pane.count`,
  /// so the binding re-evaluates when either changes.
  function selectedFileCount() { return selectedPaths().length }

  /// True when the selection includes at least one directory. The control that
  /// is refusing needs to be able to say *why* it is refusing, and "you picked
  /// a folder" is a different sentence from "you picked nothing".
  readonly property bool containsDir: {
    for (var i = 0; i < pane.count; i++) {
      var n = String(folderModel.get(i, "fileName"))
      if (isSelected(n) && folderModel.get(i, "fileIsDir")) return true
    }
    return false
  }

  /// How many of the rows on screen are directories. The header names files and
  /// folders separately (ADR 0014): `5 items` beside the action bar's `1 file
  /// selected` described two different things in the same breath and read as a
  /// contradiction, and the folder restriction is worth stating before someone
  /// asks for something that will be refused.
  readonly property int dirCount: {
    var n = 0
    for (var i = 0; i < pane.count; i++)
      if (folderModel.get(i, "fileIsDir")) n++
    return n
  }

  /// Whether this pane is holding a selection the controls can see.
  ///
  /// The action bar arms on `selectedFileCount()` and `containsDir` -- App.qml
  /// passes it exactly those two -- and both count the **visible** rows. The
  /// header used to choose its form and its colour from `selection.length`,
  /// which is the raw list of names and includes files the filter has taken off
  /// screen. Two expressions of one fact, and on 2026-09-09 they disagreed in
  /// the same frame: the header lit accent and read `0 files of 0` three rows
  /// above a bar reading `Nothing selected` (issue 09). Named once here so they
  /// cannot drift apart again.
  readonly property bool showsSelection: pane.selectedFileCount() > 0 || pane.containsDir

  /// Picked names the filter has taken off screen.
  ///
  /// The selection survives a filter -- it is a list of names, not of rows --
  /// so this is the count that makes `showsSelection` false while the pane is
  /// still holding something. The filter strip says it; see
  /// `Wording::filterPhrase()` for why it is said there and not in the header.
  readonly property int hiddenPicked: {
    var n = 0
    for (var i = 0; i < pane.selection.length; i++)
      if (pane.indexOfName(pane.selection[i]) === -1) n++
    return n
  }

  /// The single file an act-on-one action would act on, or "".
  ///
  /// "Exactly one thing is picked" is not `selectedFileCount() === 1`: a file
  /// and a folder picked together are two things, and one of them is a file.
  /// Rename, Open and Properties arm on this and act on this, so the menu row
  /// and the F2 key cannot disagree about what a mixed selection means.
  function selectedSingleFile() {
    var p = selectedPaths()
    return (p.length === 1 && !containsDir) ? p[0] : ""
  }

  function indexOfName(name) {
    for (var i = 0; i < pane.count; i++) {
      if (String(folderModel.get(i, "fileName")) === name) return i
    }
    return -1
  }

  /// Point at files that just arrived: scroll the first of them into view and
  /// flash them all for about two seconds.
  ///
  /// This is the one thing a pane could not do. A row draws no arrival, so a
  /// Replace onto a same-named, same-sized file redrew to identical pixels,
  /// and a newly created file appeared wherever name order put it -- usually
  /// off screen, which is exactly the report the user could not find.
  ///
  /// `names` are bare filenames **as they landed**: pass the Keep-both name
  /// (`landed_as`), not the name that was asked for, or the flash lands on
  /// nothing. `dir` is optional; when given, the reveal is dropped unless this
  /// pane is still showing that directory, so a transfer that finishes after
  /// the user has navigated away does not flash whatever now sits at that name.
  ///
  /// The selection is deliberately left alone: selecting the arrivals would
  /// arm Delete and Move on files the user never picked.
  function reveal(names, dir) {
    if (!names || names.length === 0) return
    if (typeof dir === "string" && dir !== "" && !sameDir(dir, pane.dir)) return
    pendingReveal = names.slice()
    revealAttempts = 0
    // Any flash already running is left to clear on its own timer: stopping it
    // here would strand it lit if this reveal never finds its files.
    if (!showPending(false)) revealRetry.restart()
  }

  function sameDir(a, b) {
    return String(a).replace(/\/+$/, "") === String(b).replace(/\/+$/, "")
  }

  /// Flash pendingReveal once the model can see it. Returns false while the
  /// model is still behind, which is the retry's cue to look again.
  ///
  /// A Job commits its files one rename at a time, so an early attempt can see
  /// two of five. Unless this is the last look (`lastTry`), hold out for the
  /// whole set rather than flashing two files and calling that the report.
  function showPending(lastTry) {
    var found = []
    var first = -1
    for (var i = 0; i < pendingReveal.length; i++) {
      var idx = indexOfName(String(pendingReveal[i]))
      if (idx === -1) continue
      found.push(String(pendingReveal[i]))
      if (first === -1 || idx < first) first = idx
    }
    if (first === -1) return false
    if (found.length < pendingReveal.length && !lastTry) return false
    // Contain, not Beginning: a file already on screen should not make the
    // pane jump under the user.
    list.positionViewAtIndex(first, ListView.Contain)
    revealed = found
    pendingReveal = []
    revealHold.restart()
    return true
  }

  Timer {
    id: revealRetry
    interval: 120
    repeat: true
    onTriggered: {
      pane.revealAttempts++
      // ~1.4s of looking. Past that the files are not coming: the pane is
      // showing somewhere else, or the watcher never saw the write -- inotify
      // does not see what another machine writes to a share.
      var lastTry = pane.revealAttempts >= 12
      if (pane.showPending(lastTry) || lastTry) {
        stop()
        pane.pendingReveal = []
      }
    }
  }

  Timer {
    id: revealHold
    interval: 2000
    onTriggered: pane.revealed = []
  }

  function enter(index) {
    if (index < 0 || index >= pane.count) return
    if (!folderModel.get(index, "fileIsDir")) return
    pane.dir = String(folderModel.get(index, "filePath"))
    clearSelection()
  }

  function goUp() {
    var p = String(pane.dir)
    if (p === "/" || p === "") return
    var cut = p.lastIndexOf("/")
    pane.dir = cut > 0 ? p.substring(0, cut) : "/"
    clearSelection()
  }

  FolderListModel {
    id: folderModel
    folder: pane.pathUrl.folderModelUrl(pane.dir)
    showDirsFirst: true
    // Substring, not a glob the user has to know they are writing. Someone
    // typing "img" means "anything with img in it", and requiring *img* would
    // make the common case the one that needs syntax.
    nameFilters: pane.filter === "" ? ["*"] : ["*" + pane.filter + "*"]
    caseSensitive: false
    sortField: pane.sortField
    sortReversed: pane.sortReversed
    showDotAndDotDot: false
    showHidden: pane.showHidden
    onFolderChanged: {
      pane._checkListing()
      pane.clearSelection()
      // A reveal is about one directory. Leaving it armed across a navigation
      // would flash a same-named file somewhere else.
      revealRetry.stop()
      pane.pendingReveal = []
      pane.revealed = []
      // A new folder is innocent until it has had its 1500 ms.
      pane.notAnswering = false
      openWatch.restart()
    }
    onStatusChanged: {
      pane._checkListing()
      if (folderModel.status === FolderListModel.Ready && pane.listingIsOurs) {
        pane.notAnswering = false
        openWatch.stop()
      }
    }
    onCountChanged: pane._checkListing()
    // A pane summoned straight at an unopenable directory never *changes*
    // folder and never changes status either -- it is born at `Null` and stays
    // there in silence, which is precisely the case this is for. Watched
    // failing: with only the two handlers above, a pane opened on a missing
    // path said nothing at all, exactly as before the fix.
    Component.onCompleted: { pane._checkListing(); openWatch.restart() }
  }

  /// Whether the model is listing the directory this pane was asked for.
  ///
  /// It is not always. `FolderListModel` resolves an **empty** folder to the
  /// process's working directory -- `DirPane` already knew that, one screen up,
  /// about the breadcrumb -- and a pane is born with `dir: ""`, so the first
  /// thing every pane in this window ever lists is `~`. Normally the real path
  /// arrives and it re-lists. Assign one it cannot open while that first
  /// listing is still in flight and the `~` rows **stay**, arriving at `Ready`
  /// under the new folder's name: fifty rows of somebody's home directory
  /// beneath a breadcrumb reading `no-such-folder-here`, with every control
  /// live (issue 07). A race, so it is intermittent, which is why review never
  /// saw it.
  ///
  /// So the pane asks the only question that settles it: does the first row
  /// live under `dir`? Everything else in here counts through `pane.count`,
  /// which is zero when the answer is no -- the guard is one expression and
  /// nothing has to remember to consult it.
  ///
  /// Recomputed rather than bound: `get(0, …)` is a function call, not a
  /// dependency Qt will re-evaluate a binding for.
  property bool listingIsOurs: false
  function _checkListing() {
    if (pane.dir === "") { pane.listingIsOurs = false; return }
    if (folderModel.count === 0 || folderModel.status !== FolderListModel.Ready) {
      // Nothing to disown yet. An empty *real* directory is ours; one that has
      // not answered has no rows either way, and `notAnswering` is what speaks
      // for that case.
      pane.listingIsOurs = folderModel.status === FolderListModel.Ready
      return
    }
    var prefix = pane.dir === "/" ? "/" : pane.dir + "/"
    pane.listingIsOurs = String(folderModel.get(0, "filePath")).indexOf(prefix) === 0
  }

  /// The third state the pane had no words for.
  ///
  /// "Empty folder" is only ever said at `Ready`, and a folder that cannot be
  /// resolved never gets there -- so `track #1` drew an empty list under a
  /// breadcrumb naming it and said nothing at all (issue 06).
  ///
  /// It has to be a wait rather than a status test. A directory that loads
  /// passes through `Loading`, but one that cannot be resolved is born at
  /// `Null` and emits **no status change at all**, so there is no signal whose
  /// arrival means "did not open" -- only the absence of the one that means it
  /// did.
  ///
  /// 1500 ms is ten times the 146 ms a 50,000-entry listing took (issue 02),
  /// the largest load this project has measured. A folder slower than that
  /// gets the sentence early, which is why the sentence reports the
  /// observation -- nothing has come back -- rather than a diagnosis.
  property bool notAnswering: false
  Timer {
    id: openWatch
    interval: 1500
    onTriggered: pane.notAnswering = !pane.listingIsOurs
  }

  // The active pane is marked with an accent edge rather than a border: a box
  // around one of two adjacent panes fights the "two halves of one thing"
  // reading (ticket 08).

  Item {
    id: header
    anchors { top: parent.top; left: parent.left; right: parent.right }
    height: 36
    clip: true

    // The path, as segments you can click straight to (ADR 0014). Backspace
    // was the only way up before this, and it has no on-screen affordance --
    // "source and destination selection is not usable" was the user's oldest
    // open complaint about this project.
    Item {
      id: breadcrumbArea
      anchors { verticalCenter: parent.verticalCenter; left: goButton.right; leftMargin: 10; right: cnt.left; rightMargin: 8 }
      height: 18
      clip: true

      /// Typing a path, without losing the breadcrumb.
      ///
      /// The breadcrumb stays what it is -- clicking a segment jumps to it, and
      /// that was worth keeping. Double-clicking the path turns the same strip
      /// into a field holding the full path, which is the browser convention
      /// and needs no second control competing for a 36px header.
      ///
      /// Escape restores the breadcrumb and changes nothing. Enter navigates,
      /// but only somewhere that exists: a typo must not blank the pane, and a
      /// path naming a file rather than a directory is a mistake worth saying
      /// out loud rather than obeying.
      TextInput {
        id: pathEdit
        anchors.fill: parent
        visible: pane.editingPath
        verticalAlignment: TextInput.AlignVCenter
        color: Color.foreground
        selectionColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
        selectedTextColor: Color.foreground
        font.pixelSize: 12
        clip: true
        onAccepted: pane.commitPath(pathEdit.text)
        Keys.onEscapePressed: pane.editingPath = false

        // Focus here, not in beginPathEdit(). That function flips
        // `editingPath` and calls forceActiveFocus() in the same frame, before
        // this item is actually visible -- and focusing an invisible item does
        // nothing, so the field opened and then swallowed nothing: every
        // keystroke went to the window's own handler instead. Watched exactly
        // that way, with the path unchanged after typing a new one.
        // Deferred with callLater, not taken directly. beginPathEdit() emits
        // activated() first, and the window answers that by calling
        // browser.forceActiveFocus() -- so focus taken here in the same turn is
        // handed straight back and the field opens deaf. Watched exactly that
        // way: the editor appeared, and every keystroke went to the window's
        // key handler instead of into it. callLater runs after the whole
        // activation settles, and is the last word.
        onVisibleChanged: if (pathEdit.visible) Qt.callLater(pathEdit.takeFocus)
        function takeFocus() {
          pathEdit.forceActiveFocus()
          pathEdit.selectAll()
        }
      }

      Row {
        id: crumbRow
        visible: !pane.editingPath
        // Right-anchored: when the path is wider than the area, the directory
        // actually open matters more than the root, so the tail is what stays
        // on screen rather than eliding it away.
        x: Math.min(0, breadcrumbArea.width - width)
        height: parent.height
        spacing: 2

        Repeater {
          model: pane.crumbs()
          Row {
            id: crumb
            required property var modelData
            required property int index
            spacing: 2
            height: parent.height
            Text {
              visible: crumb.index > 0
              anchors.verticalCenter: parent.verticalCenter
              text: "›"
              color: Color.muted
              font.pixelSize: 11
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: crumb.index > 0 ? 2 : 0
              text: crumb.modelData.label
              color: pane.active ? Color.foreground : Color.muted
              font.pixelSize: 12
              font.bold: pane.active && crumb.index === pane.crumbs().length - 1
              // One handler with both callbacks. Two TapHandlers on the same
              // item do not share a gesture: the single-tap one takes it and
              // the double-tap one never fires -- watched, with a double-click
              // on the path navigating instead of opening the editor.
              TapHandler {
                onSingleTapped: { pane.activated(); pane.dir = crumb.modelData.path }
                onDoubleTapped: pane.beginPathEdit()
              }
            }
          }
        }
      }
    }

    // The door itself: a list of places and mounts a pane can jump straight
    // to, independent of the shared sidebar and of which pane is the transfer
    // source. Named "Go" rather than the sidebar's own vocabulary because this
    // is the one word a keyboard-first tool can bind a mnemonic to later.
    /// Back and forward, in the order a browser puts them, left of everything
    /// else in the header. Drawn muted and inert rather than hidden when there
    /// is nowhere to go: a control that vanishes teaches nothing about why.
    Row {
      id: navRow
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 12 }
      spacing: 8
      Text {
        text: "‹"
        font.pixelSize: 15
        color: pane.canGoBack ? (backHover.hovered ? Color.foreground : Color.muted)
                              : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.35)
        HoverHandler { id: backHover; enabled: pane.canGoBack }
        TapHandler { onSingleTapped: { pane.activated(); pane.goBack() } }
      }
      Text {
        text: "›"
        font.pixelSize: 15
        color: pane.canGoForward ? (fwdHover.hovered ? Color.foreground : Color.muted)
                                 : Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.35)
        HoverHandler { id: fwdHover; enabled: pane.canGoForward }
        TapHandler { onSingleTapped: { pane.activated(); pane.goForward() } }
      }
    }

    /// Typing a path, as a button rather than only as a gesture.
    ///
    /// Double-clicking the path opens the same editor, but a double-click is
    /// invisible: nothing on screen says the path can be typed. This says it,
    /// and it is also the only way in that cannot be lost to the breadcrumb's
    /// own click handling.
    Text {
      id: editPath
      anchors { verticalCenter: parent.verticalCenter; left: navRow.right; leftMargin: 10 }
      text: "✎"
      color: pane.editingPath ? Color.accent
                              : (editHover.hovered ? Color.foreground : Color.muted)
      font.pixelSize: 12
      HoverHandler { id: editHover }
      TapHandler { onSingleTapped: pane.beginPathEdit() }
    }

    Text {
      id: goButton
      // Left of the path, not right of it. The menu opens at the pane's left
      // edge, so a button on the far right meant the list appeared most of a
      // pane away from the cursor that summoned it -- found by using it.
      anchors { verticalCenter: parent.verticalCenter; left: editPath.right; leftMargin: 10 }
      text: "Go ▾"
      color: goMenu.open ? Color.accent : Color.muted
      font.pixelSize: 11
      TapHandler { onSingleTapped: goMenu.open = !goMenu.open }
    }

    /// Free space, right of the count. Dropped rather than elided below 420px --
    /// a truncated byte figure is worse than none, because "42 G" and "4.2 GB"
    /// are both plausible readings of the same clipped string.
    Text {
      id: freeText
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 14 }
      visible: pane.freeBytes >= 0 && pane.width > 420
      text: pane.humanSize(pane.freeBytes) + " free"
      color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, pane.active ? 1.0 : 0.55)
      font.pixelSize: 11
    }

    Text {
      id: cnt
      anchors { verticalCenter: parent.verticalCenter
                right: freeText.visible ? freeText.left : parent.right; rightMargin: 14 }
      // Files and folders counted separately, and the selection counted the way
      // the actions count it (ADR 0014). This is the one place `selection` may
      // still be read directly -- the header describes what the pane *shows*,
      // not what a control would act on -- which is why scripts/lint-qml.sh
      // exempts this file and only this file.
      text: {
        var files = pane.count - pane.dirCount
        var picked = pane.selectedFileCount()
        if (pane.showsSelection)
          return picked + " file" + (picked === 1 ? "" : "s") + " of " + files
                 + (pane.containsDir ? " · folder picked" : "")
        return files + " file" + (files === 1 ? "" : "s")
               + (pane.dirCount > 0
                  ? ", " + pane.dirCount + " folder" + (pane.dirCount === 1 ? "" : "s")
                  : "")
      }
      color: pane.showsSelection ? Color.accent : Color.muted
      font.pixelSize: 11
    }
  }

  Rectangle {
    id: rule
    anchors { top: header.bottom; left: parent.left; right: parent.right }
    height: 1
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
  }

  // Lit while a drag would land here, so the destination is visible before
  // the button is released rather than announced afterwards.
  Rectangle {
    anchors.fill: parent
    visible: pane.dropTarget
    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.07)
    border.width: 1
    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.45)
    z: 40
  }

  /// An empty directory and one that has not loaded looked identical: both a
  /// blank pane. Says which.
  Text {
    anchors.centerIn: list
    visible: pane.count === 0 && pane.listingIsOurs
            && folderModel.status === FolderListModel.Ready
    text: pane.showHidden ? "Empty folder" : "Nothing here — Ctrl+H shows hidden files"
    color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, pane.active ? 1.0 : 0.55)
    font.pixelSize: 12
  }

  /// And the third: asked for, never answered.
  Text {
    anchors.centerIn: list
    visible: pane.notAnswering && !pane.listingIsOurs
    text: "Nothing came back from this folder — it may be gone, or unreadable"
    color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, pane.active ? 1.0 : 0.55)
    font.pixelSize: 12
  }

  ColumnHeader {
    id: columns
    anchors { top: rule.bottom; left: parent.left; right: parent.right }
    sortField: pane.sortField
    sortReversed: pane.sortReversed
    paneActive: pane.active
    rowWidth: pane.width
    onSortRequested: function (field) { pane.sortRequested(field) }
  }

  /// Costs nothing when there is no filter: zero height, not merely hidden.
  Rectangle {
    id: filterBar
    anchors { top: columns.bottom; left: parent.left; right: parent.right }
    height: (pane.filtering || pane.filter !== "") ? 26 : 0
    visible: height > 0
    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)

    Text {
      id: filterLabel
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 12 }
      text: "Filter"
      color: Color.muted
      font.pixelSize: 11
    }

    TextInput {
      id: filterInput
      anchors { verticalCenter: parent.verticalCenter; left: filterLabel.right
                leftMargin: 8; right: filterCount.left; rightMargin: 10 }
      color: Color.foreground
      selectionColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
      selectedTextColor: Color.foreground
      font.pixelSize: 12
      clip: true
      onTextChanged: pane.filter = filterInput.text
      // Enter leaves the field but keeps the filter: you have finished typing
      // it, not finished with it. Escape is the one that undoes.
      onAccepted: pane.endFilter(true)
      Keys.onEscapePressed: pane.endFilter(false)
    }

    /// What is being hidden, always. This is the whole reason the strip stays
    /// on screen while a filter is set.
    Text {
      id: filterCount
      anchors { verticalCenter: parent.verticalCenter; right: parent.right; rightMargin: 14 }
      // Files, not rows: `nameFilters` never applied to the folders, so counting
      // them here claimed the filter had chosen a row it had ignored. See
      // `Wording::filterPhrase()` for why the folders stay on screen at all.
      // 420 is the width `freeText` above already yields at, so a pane narrow
      // enough to drop the free-space figure is narrow enough to drop the
      // duplicated match count too. See `Wording::filterPhrase()`.
      text: pane.wording.filterPhrase(pane.count - pane.dirCount, pane.hiddenPicked,
                                      pane.width > 420)
      color: Color.muted
      font.pixelSize: 11
    }
  }

  ListView {
    id: list
    // Issue 39, the in-pane case. GoMenu's scrim is a MouseArea, which stops a
    // click on a row below and cannot stop a drag — so the rows themselves stop
    // taking input while the menu is up. The menu is a child of the pane, so
    // this is the list rather than the pane: disabling the pane would disable
    // the menu asking the question.
    enabled: !goMenu.open
    anchors { top: filterBar.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }
    clip: true
    /// Not `folderModel` unconditionally: a listing that is not ours must not
    /// be on screen, let alone clickable (issue 07).
    model: pane.listingIsOurs ? folderModel : null
    focus: pane.active
    highlightMoveDuration: 0

    /// The empty space below the rows still belongs to this pane (issue 31).
    ///
    /// This handler is inside the ListView on purpose. A TapHandler on the
    /// pane's root never sees a tap here: a ListView is a Flickable and takes
    /// the press for a possible drag, so the root handler fires for the header
    /// and the gutter and for nothing in the list at all. Watched failing
    /// exactly that way -- clicking below the rows left the transfer direction
    /// unchanged.
    ///
    /// The default gesturePolicy (DragThreshold) is load-bearing, not an
    /// omission. ReleaseWithinBounds takes an *exclusive* grab on press, which
    /// this handler held for the whole list -- so a row's TapHandler never saw
    /// the second tap and onDoubleTapped stopped firing entirely. Double-click
    /// to open was broken by the fix that made the pane clickable, and only a
    /// report of "menu Open works, double-click does not" separated them.
    /// DragThreshold takes a passive grab, so the rows still get their taps.
    TapHandler {
      onSingleTapped: pane.activated()
    }

    delegate: FileRow {
      required property var model
      required property int index

      width: list.width
      surface: pane.surface
      fileName: model.fileName
      isDir: model.fileIsDir
      selected: pane.isSelected(model.fileName)
      cursor: pane.active && index === list.currentIndex
      paneActive: pane.active
      showIcons: pane.showIcons
      sizeText: model.fileIsDir ? "" : pane.humanSize(model.fileSize)
      timeText: pane.humanTime(model.fileModified)
      flash: pane.isRevealed(model.fileName)

      onClicked: function (ctrl) {
        pane.activated()
        list.currentIndex = index
        if (ctrl) pane.toggle(model.fileName)
        else pane.selectOnly(model.fileName)
      }
      onActivated: {
        pane.activated()
        // Enter has done this since it was written (App.qml): a directory is
        // entered, a file is opened. Double-click did only the first half and
        // silently did nothing on a file -- the commonest gesture in any file
        // manager, landing on nothing at all.
        if (model.fileIsDir) pane.enter(index)
        else pane.openRequested()
      }
      onContextRequested: function (gx, gy) {
        pane.activated()
        // Right-clicking something unselected acts on it, not on a selection
        // you had forgotten about somewhere off screen.
        if (!pane.isSelected(model.fileName)) pane.selectOnly(model.fileName)
        list.currentIndex = index
        pane.contextRequested(gx, gy)
      }
      onDragStarted: {
        pane.activated()
        if (!pane.isSelected(model.fileName)) pane.selectOnly(model.fileName)
        pane.dragBegan()
      }
      onDragReleased: function (sx, sy) { pane.dragReleased(sx, sy) }
      onDragMoved: function (sx, sy) { pane.dragMoved(sx, sy) }
    }

    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Space) {
        var n = String(folderModel.get(list.currentIndex, "fileName"))
        if (n) pane.toggle(n)
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        pane.enter(list.currentIndex); event.accepted = true
      } else if (event.key === Qt.Key_Backspace) {
        pane.goUp(); event.accepted = true
      } else if (event.key === Qt.Key_Home) {
        pane.moveCursorHome(); event.accepted = true
      } else if (event.key === Qt.Key_End) {
        pane.moveCursorEnd(); event.accepted = true
      } else if (event.key === Qt.Key_PageUp) {
        pane.moveCursorPage(-1); event.accepted = true
      } else if (event.key === Qt.Key_PageDown) {
        pane.moveCursorPage(1); event.accepted = true
      }
    }
  }

  // Declared after the list so it paints over the rows, and last so nothing
  // paints over it except the drop-target wash (z: 40), which covers the pane
  // deliberately. Issue 17: before this, a pane whose header said "40 files"
  // drew nineteen and said nothing about the rest.
  ScrollHint { list: list }

  GoMenu {
    id: goMenu
    places: pane.places
    mounts: pane.mounts
    onChosen: function (path) { pane.dir = path }
  }
}
