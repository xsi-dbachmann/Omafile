//! Durable working state that makes resume possible.
//!
//! The journal is **not a history** (ADR 0005, ADR 0008). It records work that
//! has *not finished*, so it can be continued or recovered. An entry is deleted
//! once its file is committed — and specifically **after the rename returns,
//! not after verification passes** (ADR 0002). Deleting on verification would
//! leave a crash inside the commit window with verified data at a temp name and
//! nothing recording where it belongs.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub source: PathBuf,
    pub destination: PathBuf,
    pub temp: PathBuf,
    pub expected_size: u64,
    pub bytes_done: u64,
    pub checksum_requested: bool,
}

pub struct Journal {
    dir: PathBuf,
}

impl Journal {
    /// Lives in `$XDG_STATE_HOME/omafile/journal`, never under the Omarchy
    /// plugins directory — a write there triggers a teardown of every plugin
    /// (ADR 0005).
    pub fn open_default() -> io::Result<Self> {
        let base = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
            });
        Self::open_at(base.join("omafile/journal"))
    }

    pub fn open_at(dir: PathBuf) -> io::Result<Self> {
        fs::create_dir_all(&dir)?;
        Ok(Self { dir })
    }

    fn path_for(&self, destination: &Path) -> PathBuf {
        use sha2::{Digest, Sha256};
        let mut h = Sha256::new();
        h.update(destination.as_os_str().as_encoded_bytes());
        self.dir.join(format!("{:x}.json", h.finalize()))
    }

    pub fn record(&self, e: &Entry) -> io::Result<()> {
        let p = self.path_for(&e.destination);
        // The journal itself is written by the same discipline it serves: a
        // half-written journal entry would be its own kind of partial file.
        let tmp = p.with_extension("json.part");
        fs::write(&tmp, serde_json::to_vec_pretty(e)?)?;
        let f = fs::File::open(&tmp)?;
        f.sync_all()?;
        fs::rename(&tmp, &p)
    }

    pub fn get(&self, destination: &Path) -> Option<Entry> {
        let raw = fs::read(self.path_for(destination)).ok()?;
        serde_json::from_slice(&raw).ok()
    }

    /// Called only after the commit rename has returned.
    pub fn clear(&self, destination: &Path) -> io::Result<()> {
        match fs::remove_file(self.path_for(destination)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }

    /// Entries left behind by an interrupted run: everything the journal still
    /// holds is, by construction, unfinished.
    pub fn unfinished(&self) -> io::Result<Vec<Entry>> {
        let mut out = Vec::new();
        for e in fs::read_dir(&self.dir)? {
            let p = e?.path();
            if p.extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            if let Ok(raw) = fs::read(&p) {
                if let Ok(entry) = serde_json::from_slice::<Entry>(&raw) {
                    out.push(entry);
                }
            }
        }
        Ok(out)
    }
}
