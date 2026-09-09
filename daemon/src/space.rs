//! How much of a filesystem a transfer could still use.
//!
//! The engine already sums a Job's sources before it starts (`expected` in
//! `JobView`), so the one fact standing between it and a *pre-flight* refusal is
//! what the destination can still hold. Refusing before the first byte is
//! written is this product's whole argument: a transfer that runs out of space
//! halfway leaves the caller reasoning about a partial result, and reasoning
//! about a partial result is the failure Omafile exists to prevent.
//!
//! This module answers only the question. Nothing here decides whether a Job
//! fits — that judgement needs the Job, and it belongs where the Job is.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// What one filesystem can hold, in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Space {
    /// The size of the filesystem, not of any directory on it.
    pub total: u64,
    /// What an ordinary user could still write. See `query`.
    pub available: u64,
}

/// Ask about the filesystem containing `path`.
///
/// **`available` is `f_bavail`, never `f_bfree`.** The two differ by the block
/// reserve only root may spend — 2.6 GB on this machine's root filesystem — and
/// reporting `f_bfree` would promise space the process asking cannot actually
/// write into. That is the same shape as the founding bug: a number that is
/// technically about the right thing, reported to somebody who will act on it as
/// if it meant something else.
///
/// `total` is `f_blocks`, so the pair reads as "of this much, this much is
/// yours" rather than mixing a whole-filesystem figure with a user-visible one.
///
/// Both are scaled by `f_frsize`, the fundamental block size the block counts
/// are actually expressed in — `f_bsize` is a preferred I/O size and is only
/// incidentally the same number on Linux.
///
/// The error is a string rather than a silent zero. A zero available meaning
/// "I could not tell" is indistinguishable from a full disk, and a caller that
/// refuses transfers on it would refuse every valid one; a caller told *why*
/// can decide to proceed unchecked, which is where it was before it asked.
pub fn query(path: &Path) -> Result<Space, String> {
    // A NUL in a path cannot reach the kernel at all, and it is worth saying so
    // rather than letting it surface as some unrelated errno.
    let c = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("{} is not a usable path", path.display()))?;

    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    if rc != 0 {
        // `statvfs` follows the path, so this is where a destination that does
        // not exist, one on a filesystem that has gone away, and one we may not
        // traverse all arrive — each with an errno that names which.
        return Err(format!("{}: {}", path.display(), std::io::Error::last_os_error()));
    }

    // POSIX allows f_frsize to be 0 where it is meaningless; f_bsize is then the
    // only unit on offer. Multiplying by zero would report an empty filesystem,
    // which is the "silently zero" answer this function exists not to give.
    let unit = if st.f_frsize > 0 { st.f_frsize as u64 } else { st.f_bsize as u64 };
    if unit == 0 {
        return Err(format!("{} reports no block size to count in", path.display()));
    }

    Ok(Space {
        total: (st.f_blocks as u64).saturating_mul(unit),
        available: (st.f_bavail as u64).saturating_mul(unit),
    })
}
