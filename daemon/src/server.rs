//! The socket server.
//!
//! Shaped entirely by ticket 12's measurements. Two threads per connection: a
//! reader handling commands and a writer pushing coalesced events, because the
//! socket is full-duplex and a single thread would have to choose.

use crate::engine::{Conflict, Engine, Options, Outcome};
use crate::journal::Journal;
use crate::trash::{self, Disposal};
use crate::tier::VerificationTier;
use crate::protocol::{
    Event, JobView, Landed, Phase, Request, COALESCE_HZ, HEARTBEAT_SECS, PROTOCOL_VERSION,
};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::io::{FromRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Default)]
struct Registry {
    jobs: HashMap<String, JobView>,
}

#[derive(Clone)]
pub struct Shared {
    registry: Arc<Mutex<Registry>>,
    seq: Arc<AtomicU64>,
    next_job: Arc<AtomicU64>,
    /// Bumped on every change. Each connection tracks the last revision it
    /// sent, rather than sharing one "dirty" flag — a shared flag is consumed
    /// by whichever writer ticks first, so with two clients attached one of
    /// them silently stops updating.
    revision: Arc<AtomicU64>,
}

impl Shared {
    fn new() -> Self {
        Self {
            registry: Arc::new(Mutex::new(Registry::default())),
            seq: Arc::new(AtomicU64::new(0)),
            next_job: Arc::new(AtomicU64::new(1)),
            revision: Arc::new(AtomicU64::new(0)),
        }
    }
    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }
    /// Every Job the daemon is holding. This is the opening `state` reply, and
    /// a reconnecting client's whole picture — so it must be everything.
    ///
    /// Once per connection, not once per tick. See `snapshot_for`.
    fn snapshot(&self) -> Vec<JobView> {
        self.registry.lock().unwrap().jobs.values().cloned().collect()
    }

    /// The Jobs one connection still has something to say about: anything not
    /// yet terminal, plus terminal Jobs whose completion it has not sent.
    ///
    /// Issue 30. The writer used to call `snapshot()` on every tick and then
    /// discard the finished Jobs, because `terminal_sent` already held their
    /// ids — so the whole of a session's history was deep-cloned ten times a
    /// second and thrown away.
    ///
    /// What made that expensive rather than merely wasteful is `landed_as`: one
    /// entry per committed file, so a finished 500-file copy re-cloned 500
    /// names on every later tick. `landed_as` is documented as being kept empty
    /// during flight for exactly this reason — *"a progress frame is cloned on
    /// every chunk, so carrying a growing Vec through it would make a large Job
    /// quadratic"* — and this was the second per-tick clone path, which had
    /// never been told.
    ///
    /// The registry is not the problem and issue 28's eviction policy does not
    /// move: holding finished Jobs is what lets a reconnect learn an outcome.
    /// The writer was simply asking for more than it could use.
    fn snapshot_for(&self, sent: &std::collections::HashSet<String>) -> Vec<JobView> {
        self.registry
            .lock()
            .unwrap()
            .jobs
            .values()
            .filter(|j| {
                let terminal = j.error.is_some() || j.tier.is_some();
                !terminal || !sent.contains(&j.job)
            })
            .cloned()
            .collect()
    }
    fn put(&self, v: JobView) {
        let mut r = self.registry.lock().unwrap();
        r.jobs.insert(v.job.clone(), v);
        drop(r);
        self.revision.fetch_add(1, Ordering::Relaxed);
    }
    /// Issue 28's eviction path. Removing a Job nobody asked to keep is not a
    /// revision-worthy change to broadcast — the only client that could have
    /// cared just told us it is done with this id — so this does not bump
    /// `revision`, unlike `put`.
    fn remove(&self, job: &str) {
        self.registry.lock().unwrap().jobs.remove(job);
    }
    fn revision(&self) -> u64 {
        self.revision.load(Ordering::Relaxed)
    }
}

/// Where the socket lives. Never under the Omarchy plugins directory — a write
/// there tears down every plugin (ADR 0005).
pub fn default_socket_path() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("omafiled.sock")
}

/// systemd passes an activated service its listening sockets as descriptors
/// starting at 3, and says so in the environment. Read directly rather than by
/// linking `libsystemd`, which would be this daemon's first dependency outside
/// Rust in exchange for about twenty lines of convention.
const LISTEN_FDS_START: RawFd = 3;

/// The listener systemd passed us, or `None` when nobody did.
///
/// `LISTEN_PID` is the check that must not be skipped. `LISTEN_FDS` on its own
/// — inherited across an exec, or set by hand — would have the daemon adopt
/// whatever descriptor 3 happens to be and serve it. Both variables are removed
/// as soon as they are read, so nothing this process later spawns inherits a
/// claim on descriptors it does not hold.
///
/// A `LISTEN_PID` addressed to another process is not an error: surviving an
/// inherited one is the entire point of the check. A `LISTEN_PID` addressed to
/// *us* with nothing usable behind it is, because at that point systemd is
/// holding the socket clients will connect to, and binding our own path instead
/// would leave them talking to a listener nobody is accepting on.
pub fn activated_listener() -> std::io::Result<Option<UnixListener>> {
    let Ok(claimed) = std::env::var("LISTEN_PID") else {
        return Ok(None);
    };
    let count = std::env::var("LISTEN_FDS").unwrap_or_default();
    std::env::remove_var("LISTEN_PID");
    std::env::remove_var("LISTEN_FDS");
    std::env::remove_var("LISTEN_FDNAMES");

    if claimed.parse::<u32>() != Ok(std::process::id()) {
        return Ok(None);
    }

    let count: i32 = count.parse().map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("systemd addressed LISTEN_PID to this process but LISTEN_FDS is {count:?}"),
        )
    })?;
    if count < 1 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "systemd started this process for socket activation but passed no sockets",
        ));
    }
    if count > 1 {
        eprintln!(
            "omafiled: systemd passed {count} sockets; serving the first and ignoring the rest"
        );
    }
    if !is_listening_stream_socket(LISTEN_FDS_START) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "the descriptor systemd passed is not a listening AF_UNIX stream socket",
        ));
    }
    // systemd does not set close-on-exec on what it passes.
    unsafe { libc::fcntl(LISTEN_FDS_START, libc::F_SETFD, libc::FD_CLOEXEC) };
    Ok(Some(unsafe { UnixListener::from_raw_fd(LISTEN_FDS_START) }))
}

/// Whether `fd` is something this daemon can `accept()` on.
///
/// Without it a malformed unit — `ListenDatagram`, a FIFO, a descriptor that is
/// not a socket at all — surfaces as `accept()` returning `Invalid argument`
/// forever, which describes the symptom and not the cause.
fn is_listening_stream_socket(fd: RawFd) -> bool {
    unsafe fn opt(fd: RawFd, name: libc::c_int) -> Option<libc::c_int> {
        let mut v: libc::c_int = 0;
        let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                name,
                &mut v as *mut libc::c_int as *mut libc::c_void,
                &mut len,
            )
        };
        if rc == 0 { Some(v) } else { None }
    }
    unsafe {
        opt(fd, libc::SO_ACCEPTCONN) == Some(1)
            && opt(fd, libc::SO_DOMAIN) == Some(libc::AF_UNIX)
            && opt(fd, libc::SO_TYPE) == Some(libc::SOCK_STREAM)
    }
}

/// Bind `path` without evicting a daemon that is already serving it.
///
/// Issue 16. This was `let _ = remove_file(path)` followed by a bind, so a
/// second `omafiled serve` on the same path **silently took over the first
/// one's clients**: the running daemon kept its descriptor while its socket
/// file was replaced underneath it, and the next client to connect reached the
/// newcomer. Any Job the plugin then started ran through a daemon nobody meant
/// to be in charge.
///
/// The unlink cannot simply be deleted. A socket file outlives an unclean exit
/// — nothing removes it, not even a clean `drop` — so refusing whenever the
/// path exists would leave the daemon unable to start after a single crash,
/// trading a silent eviction for a permanent one. Only asking tells the two
/// apart: a stale socket refuses the connection, a live one accepts it.
///
/// A path that exists and is *not* a socket is never removed. It cannot be
/// something this daemon left behind, and `--socket` takes an arbitrary path.
pub fn bind_fresh(path: &Path) -> std::io::Result<UnixListener> {
    match std::fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return UnixListener::bind(path),
        Err(e) => return Err(e),
        Ok(md) if !md.file_type().is_socket() => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                format!("{} exists and is not a socket — refusing to remove it", path.display()),
            ));
        }
        Ok(_) => {}
    }
    match UnixStream::connect(path) {
        Ok(_) => Err(std::io::Error::new(
            std::io::ErrorKind::AddrInUse,
            format!(
                "{} is already served by a running omafiled — refusing to take its clients",
                path.display()
            ),
        )),
        Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
            // Nothing is listening, so this is what an unclean exit leaves.
            std::fs::remove_file(path)?;
            UnixListener::bind(path)
        }
        Err(e) => Err(std::io::Error::new(
            e.kind(),
            format!("cannot tell whether {} is still being served: {e}", path.display()),
        )),
    }
}

pub fn serve(path: &Path) -> std::io::Result<()> {
    let listener = match activated_listener()? {
        // systemd owns this socket: it created the file, the file outlives this
        // process, and the daemon must never remove it (ADR 0005).
        Some(l) => {
            eprintln!("omafiled: listening on the socket systemd passed");
            l
        }
        None => {
            let l = bind_fresh(path)?;
            eprintln!("omafiled: listening on {}", path.display());
            l
        }
    };

    let shared = Shared::new();
    for stream in listener.incoming() {
        let stream = stream?;
        let shared = shared.clone();
        std::thread::spawn(move || {
            if let Err(e) = handle(stream, shared) {
                eprintln!("omafiled: connection ended: {e}");
            }
        });
    }
    Ok(())
}

fn send(out: &Mutex<UnixStream>, ev: &Event) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(ev)?;
    line.push(b'\n');
    let mut g = out.lock().unwrap();
    g.write_all(&line)?;
    g.flush()
}

fn handle(stream: UnixStream, shared: Shared) -> std::io::Result<()> {
    let reader = BufReader::new(stream.try_clone()?);
    let out = Arc::new(Mutex::new(stream));

    // Every connection opens with a version handshake and a full snapshot.
    // There is no reconnect in Quickshell's Socket (ticket 12), so a client
    // that reappears is indistinguishable from a new one — and both need the
    // same thing: the current picture, not a replay.
    send(&out, &Event::Hello {
        seq: shared.next_seq(),
        daemon_version: DAEMON_VERSION.to_string(),
        protocol: PROTOCOL_VERSION,
    })?;
    let opening = shared.snapshot();
    // Jobs already finished when this client connected are conveyed by the
    // snapshot below. Re-sending them as `finished` events afterwards would be
    // the same completion twice, so the writer starts out considering them
    // already delivered.
    let already_terminal: std::collections::HashSet<String> = opening
        .iter()
        .filter(|j| j.error.is_some() || j.tier.is_some())
        .map(|j| j.job.clone())
        .collect();
    send(&out, &Event::State { seq: shared.next_seq(), jobs: opening })?;

    // Writer: pushes at COALESCE_HZ, and only when something changed. The
    // throttle lives here because the UI thread is what cannot keep up.
    {
        let out = out.clone();
        let shared = shared.clone();
        std::thread::spawn(move || {
            let tick = Duration::from_millis(1000 / COALESCE_HZ);
            let idle_ticks_before_beat = COALESCE_HZ * HEARTBEAT_SECS;
            let mut idle: u64 = 0;
            // A Job's terminal event is sent once per connection. Without this
            // the writer re-broadcasts every finished Job on every dirty tick,
            // so a client sees stale completions interleaved with live ones —
            // which is how a single-file transfer came to report counts from an
            // earlier Job.
            let mut terminal_sent = already_terminal;
            let mut last_revision = shared.revision();
            loop {
                std::thread::sleep(tick);
                let rev = shared.revision();
                if rev == last_revision {
                    idle += 1;
                    if idle >= idle_ticks_before_beat {
                        idle = 0;
                        if send(&out, &Event::Tick { seq: shared.next_seq() }).is_err() {
                            return;
                        }
                    }
                    continue;
                }
                last_revision = rev;
                idle = 0;
                // Only what this connection can still say something about
                // (issue 30). Asking for the whole registry here and dropping
                // the answer was cloning every finished Job's landing names on
                // every tick, for the life of the session.
                let jobs = shared.snapshot_for(&terminal_sent);
                for j in jobs {
                    let is_terminal = j.error.is_some() || j.tier.is_some();
                    if is_terminal {
                        terminal_sent.insert(j.job.clone());
                    }
                    let ev = if j.error.is_some() {
                        Event::Failed { seq: shared.next_seq(), job: j }
                    } else if j.tier.is_some() {
                        Event::Finished { seq: shared.next_seq(), job: j }
                    } else {
                        Event::Progress { seq: shared.next_seq(), job: j }
                    };
                    if send(&out, &ev).is_err() {
                        return;
                    }
                }
            }
        });
    }

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let _ = send(&out, &Event::Reply {
                    seq: shared.next_seq(),
                    id: 0,
                    job: None,
                    error: Some(format!("unparseable request: {e}")),
                });
                continue;
            }
        };
        dispatch(req, &shared, &out)?;
    }
    Ok(())
}

fn dispatch(req: Request, shared: &Shared, out: &Arc<Mutex<UnixStream>>) -> std::io::Result<()> {
    match req {
        Request::Hello { id, client_version } => {
            eprintln!("omafiled: client {client_version} attached");
            send(out, &Event::Reply { seq: shared.next_seq(), id, job: None, error: None })
        }
        Request::State { id } => {
            send(out, &Event::Reply { seq: shared.next_seq(), id, job: None, error: None })?;
            send(out, &Event::State { seq: shared.next_seq(), jobs: shared.snapshot() })
        }
        Request::Copy { id, sources, destination_dir, checksum, on_conflict } => {
            start_job(id, sources, destination_dir, checksum, on_conflict, false, shared, out)
        }
        Request::Move { id, sources, destination_dir, checksum, on_conflict } => {
            start_job(id, sources, destination_dir, checksum, on_conflict, true, shared, out)
        }
        Request::Conflicts { id, sources, destination_dir } => {
            let dir = PathBuf::from(&destination_dir);
            let existing: Vec<String> = sources
                .iter()
                .map(|s| file_name_of(s))
                .filter(|n| dir.join(n).exists())
                .collect();
            send(out, &Event::Conflicts { seq: shared.next_seq(), id, existing })
        }
        Request::CanTrash { id, path } => {
            let available = trash::can_trash(Path::new(&path));
            send(out, &Event::TrashAvailable { seq: shared.next_seq(), id, path, available })
        }
        Request::Delete { id, path } => {
            let p = Path::new(&path);
            // Trash where we can, permanent where we cannot, and say which.
            // Never silently substitute one for the other (ADR 0009).
            let ev = match trash::trash(p) {
                Ok(Disposal::Trashed { trashed_as, info }) => Event::Deleted {
                    seq: shared.next_seq(),
                    id,
                    path: path.clone(),
                    recoverable: true,
                    trashed_as: Some(trashed_as.to_string_lossy().into_owned()),
                    info: Some(info.to_string_lossy().into_owned()),
                    error: None,
                },
                Ok(Disposal::Permanent) => match trash::delete_permanently(p) {
                    Ok(_) => Event::Deleted {
                        seq: shared.next_seq(),
                        id,
                        path: path.clone(),
                        recoverable: false,
                        trashed_as: None,
                        info: None,
                        error: None,
                    },
                    Err(e) => Event::Deleted {
                        seq: shared.next_seq(), id, path: path.clone(),
                        recoverable: false, trashed_as: None, info: None,
                        error: Some(e.to_string()),
                    },
                },
                Err(e) => Event::Deleted {
                    seq: shared.next_seq(), id, path: path.clone(),
                    recoverable: false, trashed_as: None, info: None,
                    error: Some(e.to_string()),
                },
            };
            send(out, &ev)
        }
        Request::Rename { id, path, new_name } => {
            let ev = match rename_in_place(&path, &new_name) {
                Ok(to) => Event::Renamed {
                    seq: shared.next_seq(), id, from: path,
                    to: Some(to.to_string_lossy().into_owned()), error: None,
                },
                Err(e) => Event::Renamed {
                    seq: shared.next_seq(), id, from: path, to: None,
                    error: Some(e),
                },
            };
            send(out, &ev)
        }
        Request::Release { id, job } => {
            shared.remove(&job);
            send(out, &Event::Reply { seq: shared.next_seq(), id, job: None, error: None })
        }
        Request::Restore { id, trashed_as, info } => {
            let ev = match trash::restore(Path::new(&trashed_as), Path::new(&info)) {
                Ok(p) => Event::Restored {
                    seq: shared.next_seq(), id,
                    path: Some(p.to_string_lossy().into_owned()), error: None,
                },
                Err(e) => Event::Restored {
                    seq: shared.next_seq(), id, path: None, error: Some(e.to_string()),
                },
            };
            send(out, &ev)
        }
    }
}

/// What a Job's files turned out to be, accumulated as they land.
///
/// This is a value rather than a handful of loop variables because the finished
/// row's facts are the ones this product is trusted for, and they are worth
/// proving without a socket in the way. All three of the falsehoods it replaces
/// were arithmetic, not transport: a byte total summed before anything was
/// skipped, a landing name discarded on the way out, and a tier rank that
/// existed in `tier.rs` and was never shipped.
#[derive(Default)]
struct Tally {
    /// The weakest tier any copied file received — what the Job can honestly
    /// claim for all of them rather than what the luckiest file got.
    weakest: Option<VerificationTier>,
    moved: u32,
    copied: u32,
    replaced: u32,
    skipped_existing: u32,
    /// Bytes that actually arrived, summed as each file commits.
    bytes: u64,
    landed: Vec<Landed>,
    /// The verb the request asked for. A Job that transferred nothing has no
    /// outcome to infer one from, and the completion word is the user's own
    /// verb or it is wrong.
    is_move: bool,
}

/// The terminal facts of a Job.
struct Completion {
    /// What happened, as data — never inferred from the label.
    outcome: &'static str,
    tier: String,
    detail: String,
    /// `tier`'s rank, absent when the outcome is not a verification tier.
    strength: Option<u8>,
}

impl Tally {
    /// `asked` is the source's own filename, so a landing under a different one
    /// is visible as a difference rather than having to be re-derived.
    fn record(&mut self, asked: &str, outcome: Outcome) {
        match outcome {
            Outcome::Moved { committed_as } => {
                self.moved += 1;
                // A move copies nothing, so there is no byte count to carry:
                // the landed file is the only place its size still lives. This
                // reads the path the move actually committed to — reading the
                // path it was *asked* for counted the existing file's size on
                // a keep-both landing.
                self.bytes += std::fs::metadata(&committed_as).map(|m| m.len()).unwrap_or(0);
                self.landed.push(landed(asked, &committed_as));
            }
            Outcome::Copied { tier, bytes, replaced, committed_as } => {
                self.copied += 1;
                if replaced {
                    self.replaced += 1;
                }
                self.weakest = Some(match self.weakest {
                    None => tier,
                    Some(w) => VerificationTier::weakest(w, tier),
                });
                self.bytes += bytes;
                self.landed.push(landed(asked, &committed_as));
            }
            // Nothing moved, nothing copied, nothing landed, no bytes — and
            // specifically not counted as moved: an all-skipped Job that
            // finished as "Moved" pushed a phantom undo whose Ctrl+Z moved the
            // very file the user had just chosen to keep.
            Outcome::SkippedExisting => self.skipped_existing += 1,
        }
    }

    /// Files that actually arrived. Not the loop index: a file left alone was
    /// attempted and did not land, and counting it as done is how a Job that
    /// transferred one of three came to report three.
    fn files_done(&self) -> u32 {
        self.moved + self.copied
    }

    fn finish(&self) -> Completion {
        // A Job carries one verb — `is_move` is a property of the request — so
        // moved and copied are exclusive in practice. Requiring `copied == 0`
        // anyway means that if they ever were not, the Job reports the tier and
        // undo records nothing, rather than offering to reverse a copy.
        //
        // The condition used to be an `all_moved` flag, which a skip cleared:
        // a Job that moved one file and left another alone reported "Nothing
        // copied" while the moved file's source was already gone.
        if self.moved > 0 && self.copied == 0 {
            return Completion {
                outcome: "moved",
                tier: "Moved".to_string(),
                detail: "same filesystem — nothing was copied".to_string(),
                strength: None,
            };
        }
        match self.weakest {
            Some(t) => Completion {
                outcome: "copied",
                tier: t.label().to_string(),
                // The bytes that arrived, never the pre-flight total: that is
                // summed before anything is skipped, so "exactly as expected"
                // was false for every Job with a skip in it.
                detail: t.detail(self.bytes),
                strength: Some(t.strength()),
            },
            // Nothing was transferred at all: every file was already there.
            // Saying "Moved" here is how a no-op came to look like work — but
            // the verb still has to be the one that was asked for. There is no
            // outcome left to infer it from, so it comes from the request.
            None => Completion {
                outcome: "skipped",
                tier: if self.is_move { "Nothing moved" } else { "Nothing copied" }.to_string(),
                detail: "every file was already there — left alone as you asked".to_string(),
                strength: None,
            },
        }
    }
}

fn landed(asked: &str, committed_as: &Path) -> Landed {
    Landed {
        asked: asked.to_string(),
        name: committed_as
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| asked.to_string()),
    }
}

fn start_job(
    id: u64,
    sources: Vec<String>,
    destination_dir: String,
    checksum: bool,
    on_conflict: Conflict,
    is_move: bool,
    shared: &Shared,
    out: &Arc<Mutex<UnixStream>>,
) -> std::io::Result<()> {
    let job = format!("j{}", shared.next_job.fetch_add(1, Ordering::Relaxed));
    let total_files = sources.len() as u32;
    let label = if total_files == 1 {
        file_name_of(&sources[0])
    } else {
        format!("{total_files} files")
    };

    // The size of the whole Job, so progress is across the selection rather
    // than restarting at zero for each file.
    let expected_total: u64 = sources
        .iter()
        .map(|s| std::fs::metadata(s).map(|m| m.len()).unwrap_or(0))
        .sum();

    let base = JobView {
        job: job.clone(),
        label: label.clone(),
        file: sources.first().map(|s| file_name_of(s)).unwrap_or_default(),
        source: sources.first().cloned().unwrap_or_default(),
        destination: destination_dir.clone(),
        phase: Some(Phase::Copying),
        done: 0.0,
        files_done: 0,
        files_total: total_files,
        files_skipped: 0,
        files_replaced: 0,
        files_skipped_existing: 0,
        bytes: 0,
        expected: expected_total,
        outcome: None,
        tier: None,
        strength: None,
        detail: None,
        landed_as: Vec::new(),
        error: None,
    };
    shared.put(base.clone());
    send(out, &Event::Reply { seq: shared.next_seq(), id, job: Some(job.clone()), error: None })?;

    let shared2 = shared.clone();
    std::thread::spawn(move || {
        let journal = match Journal::open_default() {
            Ok(j) => j,
            Err(e) => {
                let mut v = base.clone();
                v.outcome = Some("failed".to_string());
                v.error = Some(e.to_string());
                v.files_skipped = total_files;
                shared2.put(v);
                return;
            }
        };
        let engine = Engine::new(journal);
        let opts = Options { checksum, on_conflict };

        let mut tally = Tally { is_move, ..Tally::default() };

        for (index, source) in sources.iter().enumerate() {
            let name = file_name_of(source);
            let dst = PathBuf::from(&destination_dir).join(&name);
            let src = PathBuf::from(source);
            // What has already arrived, so this file's progress continues the
            // Job's bar rather than restarting it.
            let bytes_before = tally.bytes;

            let mut view = base.clone();
            view.file = name.clone();
            view.source = source.clone();
            view.files_done = tally.files_done();
            view.files_replaced = tally.replaced;
            view.files_skipped_existing = tally.skipped_existing;

            let shared3 = shared2.clone();
            let view_for_progress = view.clone();
            let mut report = |phase: Phase, done: u64, total: u64| {
                let _ = total;
                let mut v = view_for_progress.clone();
                v.phase = Some(phase);
                v.bytes = bytes_before + done;
                v.done = if expected_total > 0 {
                    (bytes_before + done) as f64 / expected_total as f64
                } else {
                    0.0
                };
                shared3.put(v);
            };

            let result = if is_move {
                engine.move_file_with(&src, &dst, opts, &mut report)
            } else {
                engine.copy_file_with(&src, &dst, opts, &mut report)
            };

            match result {
                Ok(outcome) => tally.record(&name, outcome),
                Err(e) => {
                    // ADR 0008: one retry happens inside the engine; a second
                    // failure is evidence the medium is corrupting data, and
                    // the Job stops rather than working through the rest of
                    // the selection. The files never attempted are reported,
                    // because silently doing less than asked is its own lie.
                    let mut v = view.clone();
                    v.phase = None;
                    v.outcome = Some("failed".to_string());
                    v.error = Some(e.to_string());
                    v.files_done = tally.files_done();
                    v.files_skipped = total_files - index as u32 - 1;
                    // What did arrive before the Job stopped. A failure row
                    // reporting zero bytes, or the whole selection's size, is
                    // the one place a wrong number is most likely to be acted
                    // on — the files already at the destination are real.
                    v.bytes = tally.bytes;
                    v.landed_as = tally.landed.clone();
                    v.done = if expected_total > 0 {
                        bytes_before as f64 / expected_total as f64
                    } else {
                        0.0
                    };
                    shared2.put(v);
                    return;
                }
            }
        }

        let completion = tally.finish();

        let mut done_view = base.clone();
        done_view.phase = None;
        done_view.done = 1.0;
        // What landed, not what was asked for. Both of these used to be the
        // pre-flight figures, so a Job that left two of three files alone
        // still finished claiming three files and the whole selection's size.
        done_view.files_done = tally.files_done();
        done_view.bytes = tally.bytes;
        done_view.outcome = Some(completion.outcome.to_string());
        done_view.tier = Some(completion.tier);
        done_view.strength = completion.strength;
        done_view.detail = Some(completion.detail);
        done_view.files_replaced = tally.replaced;
        done_view.files_skipped_existing = tally.skipped_existing;
        done_view.landed_as = tally.landed;
        shared2.put(done_view);
    });
    Ok(())
}

fn file_name_of(p: &str) -> String {
    Path::new(p)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| p.to_string())
}

/// Rename a file within its own directory.
///
/// `new_name` is validated as a bare filename rather than trusted. A rename
/// that accepted a path would be a move to somewhere the user never chose —
/// the same discipline ADR 0007 applies to the privileged helper, for the same
/// reason: validate the shape, do not sanitise a string afterwards.
fn rename_in_place(path: &str, new_name: &str) -> Result<PathBuf, String> {
    if new_name.is_empty() {
        return Err("a name cannot be empty".into());
    }
    if new_name.contains('/') || new_name.contains('\0') {
        return Err("a name cannot contain a path separator".into());
    }
    if new_name == "." || new_name == ".." {
        return Err(format!("'{new_name}' is not a usable name"));
    }
    let from = Path::new(path);
    if !from.exists() {
        return Err(format!("{path} no longer exists"));
    }
    let dir = from.parent().ok_or_else(|| "no parent directory".to_string())?;
    let to = dir.join(new_name);
    if to == from {
        return Ok(to);
    }
    // Never silently replace something else. A rename that clobbers a file is
    // a delete wearing a rename's clothes.
    if to.exists() {
        return Err(format!("{new_name} already exists here"));
    }
    std::fs::rename(from, &to).map_err(|e| e.to_string())?;
    Ok(to)
}

#[cfg(test)]
mod tests {
    //! What a finished row is allowed to claim.
    //!
    //! These test `Tally` rather than a live socket because the falsehoods they
    //! guard against are arithmetic, not transport: a byte count summed before
    //! anything was skipped, a name discarded on the way out, and a rank that
    //! existed in `tier.rs` and was never shipped.

    use super::*;

    fn copied(tier: VerificationTier, bytes: u64, committed_as: &str) -> Outcome {
        Outcome::Copied { tier, bytes, replaced: false, committed_as: PathBuf::from(committed_as) }
    }

    fn moved(committed_as: &str) -> Outcome {
        Outcome::Moved { committed_as: PathBuf::from(committed_as) }
    }

    /// The founding case for rank 9: the row must be able to say the transfer
    /// landed under a different name than the one it asked for.
    #[test]
    fn a_keep_both_transfer_reports_the_name_it_landed_under() {
        let mut t = Tally::default();
        t.record("report.txt", copied(VerificationTier::SizeChecked, 10, "/dst/report-2.txt"));

        assert_eq!(t.landed.len(), 1);
        assert_eq!(t.landed[0].asked, "report.txt");
        assert_eq!(t.landed[0].name, "report-2.txt");
    }

    /// `detail()` used to be handed the pre-flight total, summed before
    /// anything was skipped — so a Job that asked for 1200 bytes and left 900
    /// of them alone still reported 1200, "exactly as expected". The size tier
    /// exists precisely because a size comparison is the thing that catches a
    /// short transfer; a size claim that is not measured is worse than none.
    #[test]
    fn the_finished_row_counts_only_the_bytes_that_landed() {
        let expected_total = 1200u64; // 300 asked for, plus 900 already there

        let mut t = Tally::default();
        t.record("a.bin", copied(VerificationTier::SizeChecked, 300, "/dst/a.bin"));
        t.record("b.bin", Outcome::SkippedExisting);

        assert_eq!(t.bytes, 300, "only the bytes that actually arrived");
        assert_eq!(t.landed.len(), 1, "a file left alone did not land");
        assert_eq!(t.files_done(), 1);

        let c = t.finish();
        assert!(c.detail.contains("300"), "must state what arrived: {}", c.detail);
        assert!(
            !c.detail.contains(&expected_total.to_string()),
            "must not state the total it set out to move: {}",
            c.detail
        );
    }

    /// Rank 12: ship the rank that already exists in `tier.rs`, so the UI can
    /// order the completion words without parsing them.
    #[test]
    fn a_multi_file_job_reports_the_weakest_tier_and_its_rank() {
        let mut t = Tally::default();
        t.record("a", copied(VerificationTier::SharedExtents, 1, "/dst/a"));
        t.record("b", copied(VerificationTier::SizeChecked, 1, "/dst/b"));

        let c = t.finish();
        assert_eq!(c.tier, VerificationTier::SizeChecked.label());
        assert_eq!(c.strength, Some(VerificationTier::SizeChecked.strength()));
    }

    /// The ladder is for verification tiers. "Moved" is a verb and "Nothing
    /// copied" is the absence of work; ranking either against a proof is the
    /// same category error that let a no-op look like a completed move.
    #[test]
    fn only_a_verification_tier_gets_a_strength() {
        let mut checksummed = Tally::default();
        checksummed.record("a", copied(VerificationTier::Checksummed, 1, "/dst/a"));
        assert_eq!(
            checksummed.finish().strength,
            Some(VerificationTier::Checksummed.strength())
        );

        let mut a_move = Tally::default();
        a_move.record("a", moved("/dst/a"));
        assert_eq!(a_move.finish().strength, None, "a move is not a grade");

        let mut all_skipped = Tally::default();
        all_skipped.record("a", Outcome::SkippedExisting);
        assert_eq!(all_skipped.finish().strength, None, "nothing copied is not a grade");
    }

    /// A Job that transferred nothing says so in the verb the user asked for.
    /// The plugin repeats the daemon's word rather than rewording it, so a move
    /// where every file was already there reported "Nothing copied" in both the
    /// action bar and the panel row — watched on screen 2026-09-08. The user
    /// asked to move and was told about a copy.
    #[test]
    fn an_all_skipped_move_does_not_call_itself_a_copy() {
        let mut a_copy = Tally::default();
        a_copy.record("a", Outcome::SkippedExisting);
        assert_eq!(a_copy.finish().tier, "Nothing copied");

        let mut a_move = Tally { is_move: true, ..Tally::default() };
        a_move.record("a", Outcome::SkippedExisting);
        let c = a_move.finish();
        assert_eq!(c.outcome, "skipped", "still a no-op, whatever the verb");
        assert_eq!(c.tier, "Nothing moved", "the user asked to move");
        assert_eq!(c.strength, None, "the absence of work is not a grade");
    }

    /// A Job that moved one file and left another alone has still moved a file:
    /// its source is gone. Reporting "Nothing copied" there tells the user the
    /// opposite of what happened, and denies undo the one entry it needs.
    #[test]
    fn a_job_that_moved_one_file_and_skipped_another_still_says_moved() {
        let mut t = Tally::default();
        t.record("a", moved("/dst/a"));
        t.record("b", Outcome::SkippedExisting);

        let c = t.finish();
        assert_eq!(c.outcome, "moved");
        assert_eq!(t.files_done(), 1);
        assert_eq!(t.skipped_existing, 1);
    }

    /// The plugin binds these names directly. A field that quietly serialised
    /// under another name would leave a QML binding reading `undefined` with
    /// nothing failing — the exact class of silent mismatch this protocol's
    /// version constant exists to prevent.
    #[test]
    fn the_finished_wire_shape_carries_the_landing_names_and_the_rank() {
        let t = VerificationTier::SizeChecked;
        let view = JobView {
            job: "j1".into(),
            label: "report.txt".into(),
            file: "report.txt".into(),
            source: "/src/report.txt".into(),
            destination: "/dst".into(),
            phase: None,
            done: 1.0,
            files_done: 1,
            files_total: 1,
            files_skipped: 0,
            files_replaced: 0,
            files_skipped_existing: 0,
            bytes: 300,
            expected: 300,
            outcome: Some("copied".into()),
            tier: Some(t.label().into()),
            strength: Some(t.strength()),
            detail: Some(t.detail(300)),
            landed_as: vec![landed("report.txt", Path::new("/dst/report-2.txt"))],
            error: None,
        };

        let j: serde_json::Value = serde_json::to_value(&view).unwrap();
        assert_eq!(j["strength"], serde_json::json!(1));
        assert_eq!(j["landed_as"][0]["asked"], serde_json::json!("report.txt"));
        assert_eq!(j["landed_as"][0]["name"], serde_json::json!("report-2.txt"));
        assert_eq!(j["bytes"], serde_json::json!(300));

        // A tier-less outcome sends null rather than a rank, so a UI that reads
        // it as a number cannot accidentally rank a verb.
        let mut moved = view;
        moved.tier = Some("Moved".into());
        moved.strength = None;
        moved.landed_as = vec![landed("report.txt", Path::new("/dst/report.txt"))];
        let j: serde_json::Value = serde_json::to_value(&moved).unwrap();
        assert!(j["strength"].is_null());
        assert_eq!(j["landed_as"][0]["name"], serde_json::json!("report.txt"));
    }

    /// And a Job where every file was already there moved nothing at all.
    #[test]
    fn a_job_that_skipped_everything_says_nothing_copied() {
        let mut t = Tally::default();
        t.record("a", Outcome::SkippedExisting);
        t.record("b", Outcome::SkippedExisting);

        let c = t.finish();
        assert_eq!(c.outcome, "skipped");
        assert_eq!(t.files_done(), 0);
        assert!(t.landed.is_empty());
    }

    /// Issue 28: `release` is the registry's only removal path. A Job the
    /// plugin has explicitly given up on must actually leave the snapshot, not
    /// just stop being reported — a released Job that lingered in `snapshot()`
    /// would still be there for the next `state` reply.
    #[test]
    fn release_removes_a_job_from_the_snapshot() {
        let shared = Shared::new();
        shared.put(JobView {
            job: "j1".into(), label: "a".into(), file: "a".into(), source: "/src/a".into(),
            destination: "/dst".into(), phase: None, done: 1.0, files_done: 1, files_total: 1,
            files_skipped: 0, files_replaced: 0, files_skipped_existing: 0, bytes: 1,
            expected: 1, outcome: Some("copied".into()), tier: Some("Size checked".into()),
            strength: Some(2), detail: None, landed_as: vec![], error: None,
        });
        assert_eq!(shared.snapshot().len(), 1);

        shared.remove("j1");
        assert!(shared.snapshot().is_empty());

        // Releasing an id that is not there, or was never there, is a no-op —
        // the plugin does not have to prove the Job still exists before asking
        // to forget it.
        shared.remove("j1");
        shared.remove("never-existed");
        assert!(shared.snapshot().is_empty());
    }

    /// A finished Job carrying `landed_as`, as the registry actually holds one.
    fn finished_with(job: &str, files: usize) -> JobView {
        JobView {
            job: job.into(), label: format!("{files} files"), file: "last.bin".into(),
            source: "/src".into(), destination: "/dst".into(), phase: None, done: 1.0,
            files_done: files as u32, files_total: files as u32, files_skipped: 0,
            files_replaced: 0, files_skipped_existing: 0, bytes: 1, expected: 1,
            outcome: Some("copied".into()), tier: Some("Size checked".into()),
            strength: Some(2), detail: None, error: None,
            landed_as: (0..files)
                .map(|i| Landed { asked: format!("file-{i}.bin"), name: format!("file-{i}.bin") })
                .collect(),
        }
    }

    /// Issue 30: the writer must not clone history it has already sent.
    ///
    /// The behavioural half of the fix, and the one that would have caught it:
    /// `snapshot_for` is asked exactly what the writer asks it on every tick,
    /// and must hand back only the Job that still has something to say.
    #[test]
    fn the_writer_is_not_offered_completions_it_already_sent() {
        let shared = Shared::new();
        let mut sent = std::collections::HashSet::new();
        for i in 0..50 {
            let id = format!("old-{i}");
            shared.put(finished_with(&id, 200));
            sent.insert(id);
        }
        // One Job still running, which is the only reason the writer woke up.
        let mut live = finished_with("live", 0);
        live.tier = None;
        live.outcome = None;
        shared.put(live);

        assert_eq!(shared.snapshot().len(), 51, "the registry still holds all of it");

        let offered = shared.snapshot_for(&sent);
        assert_eq!(offered.len(), 1, "51 Jobs in the registry, one worth cloning");
        assert_eq!(offered[0].job, "live");

        // A completion this connection has *not* sent is still offered — that is
        // the half a naive "skip terminal Jobs" filter would break.
        let unsent: std::collections::HashSet<String> = std::collections::HashSet::new();
        assert_eq!(shared.snapshot_for(&unsent).len(), 51);
    }

    /// The measurement behind issue 30. Ignored by default because it is a
    /// timing, not an assertion: run it with
    /// `cargo test --release -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn measure_the_per_tick_clone() {
        use std::time::Instant;
        let shared = Shared::new();
        let mut sent = std::collections::HashSet::new();
        for i in 0..50 {
            let id = format!("old-{i}");
            shared.put(finished_with(&id, 200));
            sent.insert(id);
        }
        let mut live = finished_with("live", 0);
        live.tier = None;
        shared.put(live);

        let ticks = 1000;
        let t = Instant::now();
        for _ in 0..ticks {
            std::hint::black_box(shared.snapshot());
        }
        let whole = t.elapsed();

        let t = Instant::now();
        for _ in 0..ticks {
            std::hint::black_box(shared.snapshot_for(&sent));
        }
        let filtered = t.elapsed();

        println!(
            "50 finished Jobs x 200 landed files, {ticks} ticks:\n  \
             snapshot()      {:>9.1?} total, {:>7.1?}/tick\n  \
             snapshot_for()  {:>9.1?} total, {:>7.1?}/tick\n  \
             ratio           {:.0}x",
            whole, whole / ticks,
            filtered, filtered / ticks,
            whole.as_secs_f64() / filtered.as_secs_f64()
        );
    }
}
