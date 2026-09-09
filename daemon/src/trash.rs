//! Trash, per the freedesktop.org Trash specification.
//!
//! Implemented here rather than by shelling out to `gio trash` for two reasons.
//! It is a destructive operation, and routing destructive operations through
//! gvfs — the stack whose silently-successful failure started this project —
//! is not a trade worth making. And the spec is small enough that owning it is
//! cheaper than trusting someone else's error reporting.
//!
//! ADR 0009: where a filesystem cannot host a trash directory (SMB shares
//! frequently cannot), deletion is permanent and the caller must say so in
//! different words. This module reports which case applies; it never silently
//! substitutes one for the other.

use crate::error::TransferError;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Where a deleted file went, so the caller can tell the truth about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Disposal {
    /// Recoverable: the file is in the trash at this path, with this info file.
    Trashed { trashed_as: PathBuf, info: PathBuf },
    /// Gone. The filesystem could not host a trash directory.
    Permanent,
}

/// The home trash: `$XDG_DATA_HOME/Trash`, per the spec.
pub fn home_trash() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share")
        })
        .join("Trash")
}

/// True when `path` can be trashed rather than destroyed.
///
/// The spec requires the trash to be on the same filesystem as the file, so
/// that trashing is a rename and never a copy. A file on a different device —
/// an SMB share, a USB stick without a `.Trash-$uid` — cannot use the home
/// trash, and this returns false rather than quietly copying gigabytes across
/// a network to make a delete look reversible (ADR 0009).
pub fn can_trash(path: &Path) -> bool {
    can_trash_in(&home_trash(), path)
}

/// As `can_trash`, against an explicit trash root.
///
/// The root is a parameter rather than read from the environment so that this
/// is testable without a process-global `XDG_DATA_HOME`, which tests running in
/// parallel would race on.
pub fn can_trash_in(root: &Path, path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    let anchor = if root.exists() {
        root.to_path_buf()
    } else {
        root.parent().unwrap_or(Path::new("/")).to_path_buf()
    };
    let (Ok(a), Ok(b)) = (
        fs::metadata(path.parent().unwrap_or(Path::new("/"))),
        fs::metadata(&anchor),
    ) else {
        return false;
    };
    a.dev() == b.dev()
}

/// Move a file to the home trash, writing the `.trashinfo` record the spec
/// requires so other tools can restore it.
pub fn trash(path: &Path) -> Result<Disposal, TransferError> {
    trash_in(&home_trash(), path)
}

/// As `trash`, against an explicit trash root.
pub fn trash_in(root: &Path, path: &Path) -> Result<Disposal, TransferError> {
    if !can_trash_in(root, path) {
        return Ok(Disposal::Permanent);
    }
    let files = root.join("files");
    let info = root.join("info");
    fs::create_dir_all(&files)?;
    fs::create_dir_all(&info)?;

    let stem = path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".into());

    // The spec requires the name in the trash to be unique, and the info file
    // to be created before the file is moved, so a crash cannot leave a
    // trashed file with no record of where it came from.
    let (name, info_path) = unique_name(&files, &info, &stem)?;
    let dest = files.join(&name);

    let original = path
        .canonicalize()
        .unwrap_or_else(|_| path.to_path_buf());
    fs::write(
        &info_path,
        format!(
            "[Trash Info]\nPath={}\nDeletionDate={}\n",
            uri_escape(&original.to_string_lossy()),
            iso8601_local_now()
        ),
    )?;

    match fs::rename(path, &dest) {
        Ok(()) => Ok(Disposal::Trashed { trashed_as: dest, info: info_path }),
        Err(e) => {
            // Never leave an info file pointing at nothing.
            let _ = fs::remove_file(&info_path);
            Err(TransferError::Io(e))
        }
    }
}

/// Put a trashed file back where it came from. This is what undo uses.
pub fn restore(trashed_as: &Path, info: &Path) -> Result<PathBuf, TransferError> {
    let raw = fs::read_to_string(info)?;
    let mut original: Option<PathBuf> = None;
    for line in raw.lines() {
        if let Some(v) = line.strip_prefix("Path=") {
            original = Some(PathBuf::from(uri_unescape(v)));
        }
    }
    let Some(original) = original else {
        return Err(TransferError::Io(io::Error::new(
            io::ErrorKind::InvalidData,
            "trashinfo has no Path",
        )));
    };
    if let Some(parent) = original.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::rename(trashed_as, &original)?;
    let _ = fs::remove_file(info);
    Ok(original)
}

/// Delete without trash. Used where `can_trash` is false, and only ever when
/// the caller has said so plainly.
pub fn delete_permanently(path: &Path) -> Result<Disposal, TransferError> {
    if path.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(Disposal::Permanent)
}

fn unique_name(files: &Path, info: &Path, stem: &str) -> io::Result<(String, PathBuf)> {
    for n in 0..10_000 {
        let candidate = if n == 0 { stem.to_string() } else { format!("{stem}.{n}") };
        let info_path = info.join(format!("{candidate}.trashinfo"));
        if !files.join(&candidate).exists() && !info_path.exists() {
            return Ok((candidate, info_path));
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free name in trash"))
}

/// The spec stores Path percent-encoded. Only the characters that actually
/// need it, so a restored path is still readable in the info file.
fn uri_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The inverse, and it must not trust what it is reading.
///
/// `restore` is a socket request that names its own `.trashinfo`, and a trash
/// directory is shared with every other tool on the machine. A record *we* wrote
/// can never carry a bare `%` -- `uri_escape` above escapes every byte that is
/// not unreserved -- but a tool that escapes less can, and a name like
/// `50%日本.txt` puts a multi-byte character directly after one.
///
/// This walks **bytes**. The previous version reached for `&s[i + 1..i + 3]`,
/// which slices a `str` by byte index, and on that name those indices land
/// inside the `日`: *end byte index 21 is not a char boundary* -- a panic in the
/// process that is holding somebody's transfer open.
fn uri_unescape(s: &str) -> String {
    let b = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(hi), Some(lo)) = (hex_digit(b[i + 1]), hex_digit(b[i + 2])) {
                out.push(hi * 16 + lo);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// One hex digit, or nothing.
///
/// Spelled out rather than left to `u8::from_str_radix`, which also accepts a
/// leading sign: it read `%+1` as the byte 0x01, where the spec has no such
/// escape and those two characters belong in the name unchanged.
fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// `YYYY-MM-DDThh:mm:ss` in local time, as the spec asks.
fn iso8601_local_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let local = secs + local_utc_offset_secs();
    let (y, mo, d, h, mi, s) = civil_from_unix(local);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}")
}

fn local_utc_offset_secs() -> i64 {
    // `date +%z` rather than a dependency: this is the only place the daemon
    // needs a timezone, and it needs it for a human-readable field.
    std::process::Command::new("date")
        .arg("+%z")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            let s = s.trim();
            if s.len() < 5 { return None }
            let sign = if s.starts_with('-') { -1 } else { 1 };
            let h: i64 = s[1..3].parse().ok()?;
            let m: i64 = s[3..5].parse().ok()?;
            Some(sign * (h * 3600 + m * 60))
        })
        .unwrap_or(0)
}

/// Days-from-civil, inverted. Howard Hinnant's algorithm.
fn civil_from_unix(secs: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d, (rem / 3600) as u32, ((rem % 3600) / 60) as u32, (rem % 60) as u32)
}
