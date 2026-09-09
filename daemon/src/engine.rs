//! The transfer engine.
//!
//! ADR 0004: the engine owns the commit discipline. Backends supply primitives;
//! the engine sequences temp-write, `fsync`, size check, optional checksum, and
//! atomic rename. The one thing that must never vary does not live in the place
//! that varies.

use crate::error::TransferError;
use crate::fs_ops;
use crate::journal::{Entry, Journal};
use crate::protocol::Phase;
use crate::tier::VerificationTier;
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const CHUNK: usize = 4 << 20;

/// What to do when the destination already exists.
///
/// There is no "ask" here: asking happens in the UI before the Job starts, so
/// the engine is never waiting on a person mid-transfer. By the time a Job
/// reaches the engine the answer is already known.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Conflict {
    /// Leave the existing file alone and do not transfer this one.
    #[default]
    Skip,
    /// Commit over it. The existing file is gone once the rename returns.
    Replace,
    /// Land beside it under a free name.
    KeepBoth,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Options {
    /// `--checksum`. Default off (ADR 0003): read-back hashing was measured at
    /// 2.5–2.7× wall-clock. The size check below is unconditional and free, and
    /// alone would have caught every file in the founding incident.
    pub checksum: bool,
    /// Defaults to `Skip`: if a caller forgets to say, the engine must not
    /// destroy anything.
    pub on_conflict: Conflict,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The file was never copied: a same-filesystem move is a rename of the
    /// same inode. There is no tier here because there is nothing to verify.
    Moved {
        /// Where it ended up. Not always the path the caller asked for — a move
        /// under `KeepBoth` lands beside the existing file.
        committed_as: PathBuf,
    },
    Copied {
        tier: VerificationTier,
        bytes: u64,
        /// True when an existing file was committed over. A Job reports these
        /// separately, because a transfer that *changed* things is not the same
        /// as one that only added things.
        replaced: bool,
        /// The path the commit rename actually landed on. `KeepBoth` computes
        /// `report-2.txt` here, and this outcome used to discard it — so the
        /// caller named `report.txt` in a directory that still held a different
        /// `report.txt`, and the user went hunting.
        committed_as: PathBuf,
    },
    /// The destination existed and the policy was to leave it alone.
    SkippedExisting,
}

pub struct Engine {
    journal: Journal,
}

impl Engine {
    pub fn new(journal: Journal) -> Self {
        Self { journal }
    }

    /// Move a file. Same-filesystem moves are a rename and copy nothing;
    /// anything else is a verified copy followed by removing the source.
    pub fn move_file(&self, src: &Path, dst: &Path, opts: Options) -> Result<Outcome, TransferError> {
        self.move_file_with(src, dst, opts, &mut |_, _, _| {})
    }

    /// As `move_file`, reporting progress as it goes.
    pub fn move_file_with(
        &self,
        src: &Path,
        dst: &Path,
        opts: Options,
        on_progress: &mut dyn FnMut(Phase, u64, u64),
    ) -> Result<Outcome, TransferError> {
        // A move honours the conflict policy exactly as a copy does. It did not:
        // the same-filesystem path renamed straight over the destination, and
        // the cross-filesystem path removed the source even when the copy had
        // been skipped — deleting a file it had never copied.
        let existed = dst.exists();
        let dst: PathBuf = match (existed, opts.on_conflict) {
            (false, _) => dst.to_path_buf(),
            (true, Conflict::Skip) => return Ok(Outcome::SkippedExisting),
            (true, Conflict::Replace) => dst.to_path_buf(),
            (true, Conflict::KeepBoth) => free_name_beside(dst)?,
        };
        let dst = dst.as_path();

        if fs_ops::same_filesystem(src, dst)? {
            std::fs::rename(src, dst)?;
            return Ok(Outcome::Moved { committed_as: dst.to_path_buf() });
        }

        let outcome = self.copy_file_with(src, dst, opts, on_progress)?;
        // The source is removed only when the bytes are demonstrably at the
        // destination. Any other outcome leaves it alone.
        match outcome {
            // The copy's landing path carries through: a cross-filesystem move
            // under `KeepBoth` lands under a free name just as a copy does, and
            // the row that reports it has to be able to say so.
            Outcome::Copied { committed_as, .. } => {
                std::fs::remove_file(src)?;
                Ok(Outcome::Moved { committed_as })
            }
            other => Ok(other),
        }
    }

    /// Copy a file, committing it by atomic rename or not at all.
    pub fn copy_file(&self, src: &Path, dst: &Path, opts: Options) -> Result<Outcome, TransferError> {
        self.copy_file_with(src, dst, opts, &mut |_, _, _| {})
    }

    /// As `copy_file`, reporting progress as it goes.
    ///
    /// The callback is invoked on every chunk. **Coalescing is the caller's
    /// job**, and specifically the daemon's: ticket 12 measured that the UI
    /// thread, not the socket, is what cannot keep up, so throttling has to
    /// happen where the events are produced rather than where they arrive.
    pub fn copy_file_with(
        &self,
        src: &Path,
        dst: &Path,
        opts: Options,
        on_progress: &mut dyn FnMut(Phase, u64, u64),
    ) -> Result<Outcome, TransferError> {
        let expected = std::fs::metadata(src)?.len();

        // Resolve the conflict before anything is written. The engine never
        // asks; the answer arrived with the Job.
        let existed = dst.exists();
        let dst: PathBuf = match (existed, opts.on_conflict) {
            (false, _) => dst.to_path_buf(),
            (true, Conflict::Skip) => return Ok(Outcome::SkippedExisting),
            (true, Conflict::Replace) => dst.to_path_buf(),
            (true, Conflict::KeepBoth) => free_name_beside(dst)?,
        };
        let dst = dst.as_path();
        let replaced = existed && opts.on_conflict == Conflict::Replace;

        let temp = fs_ops::temp_path_for(dst);

        // Fast path: a reflink shares the source's extents copy-on-write, so
        // there is no second set of bytes that could differ (ADR 0004). It is
        // not a copy, so there is nothing to verify.
        //
        // It still goes through the temp name and the commit rename. The fast
        // path is a faster way to *fill* the temp file, never a licence to skip
        // the commit — the destination stays untouched until the rename, the
        // same as every other path.
        if fs_ops::same_filesystem(src, dst)? {
            if let Ok(true) = fs_ops::try_reflink_into_temp(src, &temp) {
                match std::fs::rename(&temp, dst) {
                    Ok(()) => {
                        return Ok(Outcome::Copied {
                            tier: VerificationTier::SharedExtents,
                            bytes: expected,
                            replaced,
                            committed_as: dst.to_path_buf(),
                        })
                    }
                    Err(e) => {
                        let _ = std::fs::remove_file(&temp);
                        return Err(TransferError::Io(e));
                    }
                }
            }
        }

        let resume_from = self.resume_offset(dst, &temp, expected, opts.checksum);

        self.journal.record(&Entry {
            source: src.to_path_buf(),
            destination: dst.to_path_buf(),
            temp: temp.clone(),
            expected_size: expected,
            bytes_done: resume_from,
            checksum_requested: opts.checksum,
        })?;

        let written = match self.stream(src, &temp, resume_from, expected, on_progress) {
            Ok(n) => n,
            Err(e) => {
                // Never leave a partial file behind under any name we might
                // later mistake for progress we can trust.
                let _ = std::fs::remove_file(&temp);
                let _ = self.journal.clear(dst);
                return Err(e);
            }
        };

        // Unconditional size check. The founding bug *is* the absence of this:
        // gvfs already held the source size for its progress bar and never
        // compared it (ADR 0003).
        if written != expected {
            let _ = std::fs::remove_file(&temp);
            let _ = self.journal.clear(dst);
            return Err(TransferError::SizeMismatch {
                path: dst.to_path_buf(),
                expected,
                got: written,
            });
        }

        let tier = if opts.checksum {
            self.verify_with_retry_reporting(src, &temp, dst, on_progress)?;
            VerificationTier::Checksummed
        } else {
            VerificationTier::SizeChecked
        };

        // The commit. Until this returns, the destination does not exist under
        // its final name (ADR 0002).
        std::fs::rename(&temp, dst)?;

        // Only now. Clearing on verification instead would leave a crash inside
        // the rename window with verified data at a temp name and nothing
        // recording where it belongs (ADR 0002).
        self.journal.clear(dst)?;

        Ok(Outcome::Copied { tier, bytes: expected, replaced, committed_as: dst.to_path_buf() })
    }

    /// A partially written temp file is resumable only if the journal agrees it
    /// belongs to this destination and this request. Anything else starts over:
    /// a stray `.part` file is not evidence of trustworthy progress.
    fn resume_offset(&self, dst: &Path, temp: &Path, expected: u64, checksum: bool) -> u64 {
        let Some(entry) = self.journal.get(dst) else { return 0 };
        if entry.temp != temp || entry.expected_size != expected || entry.checksum_requested != checksum {
            return 0;
        }
        match std::fs::metadata(temp) {
            Ok(m) if m.len() == entry.bytes_done && m.len() < expected => m.len(),
            _ => 0,
        }
    }

    fn stream(
        &self,
        src: &Path,
        temp: &Path,
        from: u64,
        expected: u64,
        on_progress: &mut dyn FnMut(Phase, u64, u64),
    ) -> Result<u64, TransferError> {
        let mut fi = File::open(src)?;
        let mut fo = if from > 0 {
            OpenOptions::new().write(true).open(temp)?
        } else {
            OpenOptions::new().write(true).create(true).truncate(true).open(temp)?
        };
        if from > 0 {
            fi.seek(SeekFrom::Start(from))?;
            fo.seek(SeekFrom::Start(from))?;
        }

        let mut buf = vec![0u8; CHUNK];
        let mut total = from;
        loop {
            let n = fi.read(&mut buf)?;
            if n == 0 {
                break;
            }
            fo.write_all(&buf[..n])?;
            total += n as u64;
            on_progress(Phase::Copying, total, expected);
        }
        fo.flush()?;
        // `close()` is not a durability signal — measured: write plus close
        // issues zero SMB2 FLUSH operations, write plus fsync issues one
        // (ADR 0001).
        fo.sync_all()?;
        Ok(total)
    }

    /// Read the committed bytes back and compare. One retry catches transient
    /// corruption; a second failure is evidence the medium is corrupting data,
    /// and the Job stops (ADR 0008).
    pub fn verify_with_retry(&self, src: &Path, temp: &Path, dst: &Path) -> Result<(), TransferError> {
        self.verify_with_retry_reporting(src, temp, dst, &mut |_, _, _| {})
    }

    /// As `verify_with_retry`, reporting progress as it reads.
    ///
    /// Verification is the *slow* half — measured at 40 MB/s against 69 MB/s
    /// for the copy on a 1 GbE link — so a verify that reported only "started"
    /// and "finished" would leave the bar frozen for the majority of a large
    /// transfer. That is the shape of the bug Omafile exists to correct.
    pub fn verify_with_retry_reporting(
        &self,
        src: &Path,
        temp: &Path,
        dst: &Path,
        on_progress: &mut dyn FnMut(Phase, u64, u64),
    ) -> Result<(), TransferError> {
        let size = std::fs::metadata(temp).map(|m| m.len()).unwrap_or(0);
        // Verification reads *both* files, so the bar spans both. Reporting
        // only the read-back would leave it frozen through the source hash --
        // half the wait, showing nothing. On a product whose entire purpose is
        // that progress never lies, a silent half is not acceptable.
        let total = size.saturating_mul(2);
        for attempt in 0..2 {
            let want = hash_file_reporting(src, total, 0, on_progress)?;
            let got = hash_file_reporting(temp, total, size, on_progress)?;
            if want == got {
                return Ok(());
            }
            if attempt == 0 {
                continue;
            }
        }
        let _ = std::fs::remove_file(temp);
        let _ = self.journal.clear(dst);
        Err(TransferError::ChecksumMismatch { path: dst.to_path_buf() })
    }
}

/// `offset` places this file's bytes within a larger unit of work, so a
/// verification that reads two files still draws one continuous bar.
fn hash_file_reporting(
    p: &Path,
    total: u64,
    offset: u64,
    on_progress: &mut dyn FnMut(Phase, u64, u64),
) -> Result<[u8; 32], TransferError> {
    let mut f = File::open(p)?;
    // Free insurance, measured at zero throughput cost: nobody should have to
    // reason about SMB lease state to trust a verification (ticket 13).
    fs_ops::drop_cache(&f);
    let mut h = Sha256::new();
    let mut buf = vec![0u8; CHUNK];
    let mut done = 0u64;
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        done += n as u64;
        if total > 0 {
            on_progress(Phase::Verifying, offset + done, total);
        }
    }
    Ok(h.finalize().into())
}

/// A free name beside `dst`, in the shape people expect: `report-2.txt`.
fn free_name_beside(dst: &Path) -> Result<PathBuf, TransferError> {
    let dir = dst.parent().unwrap_or(Path::new("."));
    let name = dst.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let (stem, ext) = match name.rfind('.') {
        // A leading dot is part of the name, not an extension.
        Some(i) if i > 0 => (name[..i].to_string(), name[i..].to_string()),
        _ => (name.clone(), String::new()),
    };
    for n in 2..10_000 {
        let candidate = dir.join(format!("{stem}-{n}{ext}"));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(TransferError::Io(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "no free name beside the destination",
    )))
}
