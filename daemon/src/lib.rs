//! Omafile's transfer engine.
//!
//! It exists because copying files over SMB through Nautilus silently produced
//! partial files that reported success — one 886 MB video arrived as 802 KB,
//! 0.09% of it, and nothing said so. Every design decision here is downstream
//! of making that impossible rather than merely unlikely.
//!
//! See `docs/adr/` for the decisions and the measurements behind them.

pub mod engine;
pub mod error;
pub mod fs_ops;
pub mod journal;
pub mod protocol;
pub mod server;
pub mod trash;
pub mod tier;

pub use engine::{Engine, Options, Outcome};
pub use error::TransferError;
pub use journal::Journal;
pub use tier::VerificationTier;
