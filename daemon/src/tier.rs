use serde::{Deserialize, Serialize};
use std::fmt;

/// What was actually established about a committed file.
///
/// Ranked strongest first. Note the ranking is *not* "more checking is better":
/// `SharedExtents` involves no checking at all and is the strongest, because it
/// removes the possibility of divergence rather than testing for it.
///
/// See ADR 0003 (tiers) and ADR 0004 (which added `SharedExtents`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VerificationTier {
    /// The copy shares the source's extents copy-on-write. There is no second
    /// set of bytes that could differ.
    SharedExtents,
    /// The committed file was read back and hashed against the source. The
    /// bytes matched at the moment of verification.
    Checksummed,
    /// The transferred byte count matched the source size. Unconditional and
    /// free: the size is already known. This tier alone would have caught all
    /// 41 files in the incident that motivated omafile.
    SizeChecked,
}

impl VerificationTier {
    /// Strongest first, so a Job can report the weakest tier any of its files
    /// received. Note this is not "least checking": SharedExtents involves no
    /// checking at all and is strongest, because it removes the possibility of
    /// divergence rather than testing for it.
    pub fn strength(&self) -> u8 {
        match self {
            Self::SharedExtents => 3,
            Self::Checksummed => 2,
            Self::SizeChecked => 1,
        }
    }

    /// The weaker of two tiers — what a multi-file Job can honestly claim.
    pub fn weakest(a: Self, b: Self) -> Self {
        if a.strength() <= b.strength() { a } else { b }
    }

    /// The words shown to a person. Never "done" — a tick is a claim, a
    /// statement of what was checked is a proof. See ADR 0009.
    pub fn label(&self) -> &'static str {
        match self {
            Self::SharedExtents => "Shared extents",
            Self::Checksummed => "Checksummed",
            Self::SizeChecked => "Size checked",
        }
    }

    pub fn detail(&self, bytes: u64) -> String {
        match self {
            Self::SharedExtents => "same data as the source — cannot diverge".into(),
            Self::Checksummed => "bytes read back and matched the source".into(),
            Self::SizeChecked => format!("{bytes} bytes, exactly as expected"),
        }
    }
}

impl fmt::Display for VerificationTier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}
