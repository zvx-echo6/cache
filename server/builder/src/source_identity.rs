//! Portable arrival-hash aliases, bound to an exact document version and stored PDF hash.
use crate::pack::valid_doc_id;
use serde::{Deserialize, Serialize};
use std::{io, path::Path};

pub const SOURCE_IDENTITIES_FILE: &str = "source-identities.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceIdentity {
    pub doc_id: String,
    pub version: u32,
    pub source_blake3: String,
    pub original_blake3: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceIdentities {
    version: u32,
    entries: Vec<SourceIdentity>,
}

fn invalid(message: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("{SOURCE_IDENTITIES_FILE}: {message}"))
}

fn normalize(entries: &mut [SourceIdentity]) -> io::Result<()> {
    for e in entries.iter_mut() {
        let hash_ok = |h: &str| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit());
        if !valid_doc_id(&e.doc_id) || e.version == 0 || !hash_ok(&e.source_blake3) || !hash_ok(&e.original_blake3) {
            return Err(invalid("invalid document id, version, or BLAKE3 hash"));
        }
        e.source_blake3.make_ascii_lowercase();
        e.original_blake3.make_ascii_lowercase();
    }
    entries.sort_by(|a, b| (&a.doc_id, a.version, &a.source_blake3, &a.original_blake3)
        .cmp(&(&b.doc_id, b.version, &b.source_blake3, &b.original_blake3)));
    if entries.windows(2).any(|w| w[0].doc_id == w[1].doc_id && w[0].version == w[1].version) {
        return Err(invalid("duplicate document version"));
    }
    Ok(())
}

/// Missing metadata is a valid legacy library; malformed or unsupported metadata is an error.
pub fn read_source_identities(library: &Path) -> io::Result<Vec<SourceIdentity>> {
    let bytes = match std::fs::read(library.join(SOURCE_IDENTITIES_FILE)) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(io::Error::new(e.kind(), format!("{SOURCE_IDENTITIES_FILE}: {e}"))),
    };
    let mut data: SourceIdentities = serde_json::from_slice(&bytes).map_err(invalid)?;
    if data.version != 1 {
        return Err(invalid(format!("unsupported format version {}", data.version)));
    }
    normalize(&mut data.entries)?;
    Ok(data.entries)
}

/// Canonical row order and lowercase hashes make exports independent of document insertion order.
pub fn write_source_identities(library: &Path, mut entries: Vec<SourceIdentity>) -> io::Result<()> {
    normalize(&mut entries)?;
    let mut bytes = serde_json::to_vec_pretty(&SourceIdentities { version: 1, entries }).map_err(invalid)?;
    bytes.push(b'\n');
    std::fs::write(library.join(SOURCE_IDENTITIES_FILE), bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Temp(std::path::PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
    }
    fn temp() -> Temp {
        let path = std::env::temp_dir().join(format!("source-identities-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir(&path).unwrap();
        Temp(path)
    }
    fn entry(id: &str) -> SourceIdentity {
        SourceIdentity { doc_id: id.into(), version: 2, source_blake3: "AB".repeat(32), original_blake3: "CD".repeat(32) }
    }
    #[test]
    fn deterministic_export_retains_every_identity_and_normalizes_hashes() {
        let t = temp();
        write_source_identities(&t.0, vec![entry("z"), entry("a")]).unwrap();
        let first = std::fs::read(t.0.join(SOURCE_IDENTITIES_FILE)).unwrap();
        write_source_identities(&t.0, vec![entry("a"), entry("z")]).unwrap();
        assert_eq!(first, std::fs::read(t.0.join(SOURCE_IDENTITIES_FILE)).unwrap());
        let entries = read_source_identities(&t.0).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].doc_id, "a");
        assert!(entries.iter().all(|e| e.source_blake3 == "ab".repeat(32) && e.original_blake3 == "cd".repeat(32)));
    }
    #[test]
    fn optional_legacy_file_and_invalid_metadata_have_distinct_results() {
        let t = temp();
        assert!(read_source_identities(&t.0).unwrap().is_empty());
        for bytes in ["{", r#"{"version":2,"entries":[]}"#, r#"{"version":1,"entries":[{}]}"#] {
            std::fs::write(t.0.join(SOURCE_IDENTITIES_FILE), bytes).unwrap();
            let error = read_source_identities(&t.0).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidData);
            assert!(error.to_string().contains(SOURCE_IDENTITIES_FILE));
        }
        assert!(write_source_identities(&t.0, vec![entry("a"), entry("a")]).is_err());
        for bad in ["", "bad/id"] {
            assert!(write_source_identities(&t.0, vec![entry(bad)]).is_err());
        }
        let mut bad = entry("a");
        bad.version = 0;
        assert!(write_source_identities(&t.0, vec![bad]).is_err());
        let mut bad = entry("a");
        bad.original_blake3 = "g".repeat(64);
        assert!(write_source_identities(&t.0, vec![bad]).is_err());
    }
}
