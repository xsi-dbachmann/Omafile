use std::fmt;
use std::path::PathBuf;

#[derive(Debug)]
pub enum TransferError {
    /// The source was short, or grew, or the write did not land in full. This
    /// is the founding failure: it must never pass silently.
    SizeMismatch { path: PathBuf, expected: u64, got: u64 },
    /// Read-back hashing disagreed with the source, twice.
    ChecksumMismatch { path: PathBuf },
    Io(std::io::Error),
}

impl fmt::Display for TransferError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SizeMismatch { path, expected, got } => write!(
                f,
                "{}: expected {expected} bytes, got {got} — nothing was written",
                path.display()
            ),
            Self::ChecksumMismatch { path } => write!(
                f,
                "{}: checksum mismatch on retry — nothing was written",
                path.display()
            ),
            Self::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for TransferError {}

impl From<std::io::Error> for TransferError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
