//! The wire protocol between omafiled and the plugin.
//!
//! Newline-delimited JSON over a Unix socket. Ticket 12 measured Quickshell's
//! `Socket` at 174,739 messages in ten seconds with zero losses, so delivery is
//! not a risk and the protocol carries no loss handling. What it does carry is
//! consequences of the other two findings there:
//!
//! * The **UI thread** is the bottleneck, so the daemon coalesces (see
//!   `COALESCE_HZ`). The client cannot fix this — it can only discard work
//!   already paid for.
//! * There is **no automatic reconnect** and `Socket.connected` does not report
//!   live state, so every connection begins with a `hello` and a full `state`
//!   snapshot. A reattaching client resynchronises; it never replays history,
//!   because by ADR 0008 there is no history to replay.

use serde::{Deserialize, Serialize};

/// Bumped when the message shapes change incompatibly. The plugin ships through
/// git and the daemon through the AUR (ADR 0006), so they drift independently
/// and a silent mismatch in this protocol is exactly the class of failure
/// Omafile exists to prevent.
///
/// **This number is the only thing compatibility is decided on.** Neither
/// `manifest.json`'s version nor this crate's is consulted by the handshake;
/// they move on their own cadences and say who you have, not whether it works
/// (issue 29).
///
/// # When to bump
///
/// Bump when an existing message's shape or meaning changes, when a message is
/// removed, or when a reply contract changes.
///
/// Do **not** bump for a purely additive request — but only once you have run
/// the test that clause stands on: *does an old daemon's refusal of the new
/// message reach the user as an error?* An unknown `op` is answered with
/// `Reply { id: 0, error: "unparseable request: ..." }` and the connection
/// survives; the plugin's request ids start at 1, so `id: 0` matches nothing
/// pending and is dropped without a notice. `Release` was added under exactly
/// that check: against an old daemon "Clear finished" quietly does not clear
/// and the registry keeps growing, which is where the world already was.
///
/// The gate is an equality test, so bumping is not the cautious choice. It puts
/// every user of the older half into browse-only — and doing that over a
/// message whose absence costs them nothing is the more expensive mistake.
pub const PROTOCOL_VERSION: u32 = 1;

/// Every protocol version this project has published, and the daemon version
/// that introduced it. Newest last.
///
/// This table is what makes the AUR ordering rule mechanical rather than
/// remembered. `scripts/lint-qml.sh` asserts on every run that
/// `PROTOCOL_VERSION`, the plugin's `expectedProtocol` and this table's newest
/// entry are the same number, so bumping the protocol cannot be done in one
/// place: it forces a row here naming the daemon version that carries it, and
/// that row is where the rule is stated.
///
/// **The order matters and it is not the obvious one.** The plugin reaches
/// users by `omarchy plugin update`, which fetches the repository's default
/// branch — so a plugin commit is a release the moment it lands there. The
/// daemon reaches them through the AUR, which needs a human. Publish the daemon
/// **first**; a plugin that speaks a protocol no released daemon speaks puts
/// every user into browse-only until they update a package that may not exist.
pub const PROTOCOL_HISTORY: &[(u32, &str)] = &[(1, "0.1.0")];

/// Progress updates per second, per job. Deliberately an order of magnitude
/// below the measured knee of 500–2000/s: a real panel with dozens of animated
/// rows will hit it sooner than the probe did.
pub const COALESCE_HZ: u64 = 10;

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    /// Sent on every connect, not only the first.
    Hello { id: u64, client_version: String },
    /// Ask for the current picture. The answer is a snapshot, never a replay.
    State { id: u64 },
    /// One Job, many files, one destination directory.
    ///
    /// A selection is a single Job rather than one Job per file, because
    /// ADR 0008 says a verification failure stops *the Job* — and a Job that
    /// only ever held one file could not express that. Copying ninety-seven
    /// more files past evidence that the medium is corrupting data is the
    /// behaviour that decision exists to prevent.
    Copy {
        id: u64,
        sources: Vec<String>,
        destination_dir: String,
        #[serde(default)] checksum: bool,
        /// Resolved before the Job starts — the engine never asks mid-transfer.
        /// Absent means Skip, so a caller that forgets cannot destroy anything.
        #[serde(default)] on_conflict: crate::engine::Conflict,
    },
    Move {
        id: u64,
        sources: Vec<String>,
        destination_dir: String,
        #[serde(default)] checksum: bool,
        #[serde(default)] on_conflict: crate::engine::Conflict,
    },
    /// Which of these would land on something that already exists. Asked before
    /// a Job is started so the question can be put to the user first.
    Conflicts { id: u64, sources: Vec<String>, destination_dir: String },
    /// Delete one file. Trashed where the filesystem can host a trash,
    /// permanent where it cannot — the reply says which, and the caller must
    /// tell the truth about it (ADR 0009).
    Delete { id: u64, path: String },
    /// Ask whether a delete here would be recoverable, so the confirmation can
    /// be worded before anything happens.
    CanTrash { id: u64, path: String },
    /// Put a trashed file back. This is what undo calls.
    Restore { id: u64, trashed_as: String, info: String },
    /// Rename within the same directory. `new_name` is a bare filename: the
    /// daemon refuses anything containing a separator, so a rename cannot be
    /// used to move a file somewhere the user did not choose.
    Rename { id: u64, path: String, new_name: String },
    /// Forget a finished Job — issue 28. The registry has no other removal
    /// path, so without this every Job the daemon has ever run stays in memory
    /// for the process's life. The plugin sends this only once it has both
    /// dropped its own TransferPanel row for the Job and confirmed nothing is
    /// still waiting to learn the Job's outcome through a reconnect's `state`
    /// snapshot (an in-flight undo, or a request abandoned by the liveness
    /// path and not yet answered) — see `abandonedUndoJobs` in App.qml.
    /// Releasing a Job that is not terminal, or that does not exist, is a
    /// harmless no-op: an in-flight Job keeps re-inserting itself on its next
    /// progress tick regardless.
    Release { id: u64, job: String },
}

impl Request {
    pub fn id(&self) -> u64 {
        match self {
            Self::Hello { id, .. }
            | Self::State { id }
            | Self::Copy { id, .. }
            | Self::Move { id, .. }
            | Self::Delete { id, .. }
            | Self::CanTrash { id, .. }
            | Self::Restore { id, .. }
            | Self::Rename { id, .. }
            | Self::Release { id, .. }
            | Self::Conflicts { id, .. } => *id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Phase {
    Copying,
    Verifying,
}

/// A file that actually committed, and the name it committed under.
///
/// The two differ only when the conflict policy was Keep both: the engine
/// computes `report-2.txt` and used to discard it, so the finished row named a
/// file the destination did not hold under that name.
#[derive(Debug, Clone, Serialize)]
pub struct Landed {
    /// The name asked for — the source file's own name.
    pub asked: String,
    /// The name it landed under, bare. Equal to `asked` in the ordinary case.
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct JobView {
    pub job: String,
    /// What the Job is, in one phrase: a filename, or "5 files".
    pub label: String,
    /// The file being worked on right now.
    pub file: String,
    pub source: String,
    /// The destination directory.
    pub destination: String,
    pub phase: Option<Phase>,
    /// Overall progress across every file in the Job.
    pub done: f64,
    pub files_done: u32,
    pub files_total: u32,
    /// Files never attempted because the Job stopped. Non-zero here is the
    /// visible consequence of ADR 0008's stop rule.
    pub files_skipped: u32,
    /// Existing files committed over. A transfer that *changed* things is not
    /// the same as one that only added things, and the panel says which.
    pub files_replaced: u32,
    /// Existing files left alone because the policy said to.
    pub files_skipped_existing: u32,
    /// Bytes that actually reached the destination — not the pre-flight total,
    /// which is summed before anything is skipped or fails. This field is a
    /// size claim, and a size claim nobody measured is the founding bug.
    pub bytes: u64,
    pub expected: u64,
    /// What actually happened, as data. The plugin used to infer this by
    /// string-matching `tier` against "Moved" — wrong in both directions: a
    /// cross-filesystem move reports a copy tier, and an all-skipped Job used
    /// to report "Moved". Rewording a label must never change behaviour.
    pub outcome: Option<String>,
    /// Present only once the Job has finished. The **weakest** tier any file
    /// in it received, so the claim holds for every file rather than the
    /// luckiest one. Never the word "done": a tier is a statement of what was
    /// established (ADR 0009).
    pub tier: Option<String>,
    /// `tier`'s rank, 3 strongest, so the UI can order the completion words
    /// without parsing them. Present **only** when `tier` is a verification
    /// tier: "Moved" is a verb and "Nothing copied" is the absence of work, and
    /// neither is a rung on the ladder ADR 0003 defines.
    pub strength: Option<u8>,
    pub detail: Option<String>,
    /// Every file that actually committed, in the order it landed, and under
    /// what name.
    ///
    /// Empty until the Job reaches a terminal state. A progress frame is cloned
    /// on every chunk, so carrying a growing Vec through it would make a large
    /// Job quadratic for a fact nothing reads mid-flight — the landing names
    /// matter to the finished row and to revealing the arrivals, both of which
    /// happen once.
    pub landed_as: Vec<Landed>,
    pub error: Option<String>,
}

/// How often the daemon speaks when it has nothing to say.
///
/// Ticket 12 established that `Socket.connected` does not report live state, so
/// the client infers liveness from recent traffic. That rule is only sound if
/// silence actually means something is wrong — an idle daemon that says nothing
/// is indistinguishable from a dead one. Hence a heartbeat.
pub const HEARTBEAT_SECS: u64 = 2;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Event {
    /// Sent when idle so that silence is diagnostic.
    Tick { seq: u64 },
    Hello { seq: u64, daemon_version: String, protocol: u32 },
    /// A full snapshot of everything the daemon currently knows.
    State { seq: u64, jobs: Vec<JobView> },
    Reply { seq: u64, id: u64, job: Option<String>, error: Option<String> },
    /// The outcome of a delete, and everything undo needs to reverse it.
    Deleted {
        seq: u64,
        id: u64,
        path: String,
        /// false when the filesystem could not host a trash, so it is gone.
        recoverable: bool,
        trashed_as: Option<String>,
        info: Option<String>,
        error: Option<String>,
    },
    /// Whether a delete at this path would be recoverable.
    TrashAvailable { seq: u64, id: u64, path: String, available: bool },
    Restored { seq: u64, id: u64, path: Option<String>, error: Option<String> },
    Renamed { seq: u64, id: u64, from: String, to: Option<String>, error: Option<String> },
    /// Bare filenames in `destination_dir` that already exist.
    Conflicts { seq: u64, id: u64, existing: Vec<String> },
    Progress { seq: u64, job: JobView },
    Finished { seq: u64, job: JobView },
    Failed { seq: u64, job: JobView },
}
