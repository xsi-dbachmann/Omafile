//! Filesystem primitives the engine sequences.
//!
//! ADR 0004: a backend either provides atomic rename, resume from offset, and
//! durable flush, or it is not a backend. These are those primitives. SMB is
//! reached through a `mount.cifs` mount (ADR 0001), so a share is an ordinary
//! path and this module serves it too.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::Path;

/// Ask the kernel to drop this file's pages before we read it back.
///
/// Ticket 13 measured that read-back verification reaches the server even under
/// the default `cache=strict`, so this is not required for correctness. It is
/// free insurance — measured at zero throughput cost — so nobody has to reason
/// about lease state to trust a verification.
pub fn drop_cache(f: &File) {
    unsafe {
        libc::posix_fadvise(f.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED);
    }
}

/// Attempt a copy-on-write clone **into `temp`**, never into the destination.
///
/// Returns false when the filesystem cannot do it — a different filesystem, or
/// one without reflink support. That is not an error: the caller falls back to
/// an ordinary copy (ADR 0004).
///
/// The `temp` argument is the whole point. An earlier version cloned straight
/// into the destination, opening it with `truncate(true)` and removing it if
/// the clone failed — so dragging a file onto an existing one destroyed the
/// existing file before anything was known to have worked. That is exactly what
/// ADR 0002 exists to prevent, and the fast path had quietly opted out of it.
pub fn try_reflink_into_temp(src: &Path, temp: &Path) -> io::Result<bool> {
    const FICLONE: libc::c_ulong = 0x4004_9409;
    let s = File::open(src)?;
    let d = OpenOptions::new().write(true).create(true).truncate(true).open(temp)?;
    let rc = unsafe { libc::ioctl(d.as_raw_fd(), FICLONE, s.as_raw_fd()) };
    if rc == 0 {
        // A clone shares extents; there is nothing buffered to flush, but the
        // file and its directory entry still need to be durable before the
        // commit rename.
        d.sync_all()?;
        Ok(true)
    } else {
        drop(d);
        // Only ever the temp file. The destination has not been touched.
        let _ = std::fs::remove_file(temp);
        Ok(false)
    }
}

/// True when both paths live on the same filesystem, so `rename` cannot fail
/// with `EXDEV` and a move need not copy at all.
pub fn same_filesystem(a: &Path, b: &Path) -> io::Result<bool> {
    use std::os::unix::fs::MetadataExt;
    let da = dir_of(a);
    let db = dir_of(b);
    Ok(std::fs::metadata(da)?.dev() == std::fs::metadata(db)?.dev())
}

fn dir_of(p: &Path) -> &Path {
    p.parent().unwrap_or(Path::new("/"))
}

/// The temporary name a file occupies until it is committed.
///
/// It is deliberately recognisable and deliberately not the final name: ADR
/// 0002 exists so that a partial file can never occupy a final path.
pub fn temp_path_for(dst: &Path) -> std::path::PathBuf {
    let dir = dir_of(dst);
    let name = dst.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    dir.join(format!(".omafile-{name}.part"))
}
