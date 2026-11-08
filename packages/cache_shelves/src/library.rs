//! What the Bookshelves log needs to know about a library: the facts in its pack headers, and its seed log.
//!
//! This crate links no gzip code (a pack is gzip-compressed JSON Lines), so the caller passes a [`HeaderReader`] that returns the
//! first line of a pack, which is its header. The builder and the core each have one.

use crate::error::{Error, Result};
use crate::events::Kind;
use crate::quality::CopyQuality;
use crate::same::{mean_vector_from, minhash_from, Facts};
use crate::store::{log_file_names, parse_legacy_log, LOG_DIR};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Returns the first line of a pack (its header, as JSON text).
pub type HeaderReader<'a> = &'a dyn Fn(&Path) -> std::result::Result<String, String>;

pub const PACK_EXT: &str = "cdoc";
/// The seed log of a published library is `log/builder-<library_id>.jsonl`.
pub const SEED_PREFIX: &str = "builder-";

/// Where a library is: its id, its folder (with `log/`), and its packs (default `<dir>/packs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryRef {
    pub library_id: String,
    pub dir: PathBuf,
    pub packs_dir: Option<PathBuf>,
}

impl LibraryRef {
    pub fn new(library_id: &str, dir: &Path) -> LibraryRef {
        LibraryRef { library_id: library_id.to_string(), dir: dir.to_path_buf(), packs_dir: None }
    }

    pub fn packs(&self) -> PathBuf {
        self.packs_dir.clone().unwrap_or_else(|| self.dir.join("packs"))
    }
}

/// The division a pack suggests for a book (`book.suggested`, else revision 3's `division`).
#[derive(Debug, Clone, PartialEq)]
pub struct SuggestedDiv {
    pub div: String,
    pub label: String,
}

/// What a pack header says about one copy.
#[derive(Debug, Clone, PartialEq)]
pub struct PackFacts {
    /// The copy key: `book.original_blake3`, else the `doc_id`.
    pub copy: String,
    pub doc_id: String,
    pub version: u32,
    /// The book's title (`book.title`, else the header's).
    pub title: String,
    pub suggested: Option<SuggestedDiv>,
    /// The content hash: `book.original_blake3`, else `source.blake3`.
    pub blake3: Option<String>,
    /// `samebook`, when the pack has it (revision 3 and later).
    pub same: Option<SameInfo>,
}

/// The `samebook` block of a pack.
#[derive(Debug, Clone, PartialEq)]
pub struct SameInfo {
    pub minhash: Vec<u32>,
    pub mean_vector: Vec<f32>,
    pub text_pages: u32,
    pub pages: u32,
    pub ppi: Option<u32>,
    pub source_size: u64,
}

fn suggested_of(s: &Value, div_key: &str) -> Option<SuggestedDiv> {
    let text = |k: &str| s.get(k).and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
    Some(SuggestedDiv { div: text(div_key)?, label: text("label").unwrap_or_default() })
}

fn same_of(s: &Value) -> Result<SameInfo> {
    let num = |k: &str| s.get(k).and_then(Value::as_u64);
    Ok(SameInfo {
        minhash: minhash_from(s.get("minhash").unwrap_or(&Value::Null))?,
        mean_vector: mean_vector_from(s.get("mean_vector").unwrap_or(&Value::Null))?,
        text_pages: num("text_pages").and_then(|n| u32::try_from(n).ok()).unwrap_or(0),
        pages: num("pages").and_then(|n| u32::try_from(n).ok()).unwrap_or(0),
        ppi: num("ppi").and_then(|n| u32::try_from(n).ok()),
        source_size: num("source_size").unwrap_or(0),
    })
}

impl PackFacts {
    /// Reads the header line of a pack (`{"cdoc":1,"doc_id":...}`).
    pub fn from_header_line(line: &str) -> Result<PackFacts> {
        let h: Value = serde_json::from_str(line.trim()).map_err(|e| Error::ctx("the pack header", e))?;
        let text = |v: Option<&Value>| v.and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
        let doc_id = text(h.get("doc_id")).ok_or_else(|| Error::new("the pack header has no doc_id"))?;
        let book = h.get("book").filter(|b| b.is_object());
        let original = book.and_then(|b| text(b.get("original_blake3")));
        let blake3 = original.clone().or_else(|| text(h.get("source").and_then(|s| s.get("blake3"))));
        let title = book.and_then(|b| text(b.get("title"))).or_else(|| text(h.get("title"))).unwrap_or_default();
        let suggested = match book {
            Some(b) => b.get("suggested").and_then(|s| suggested_of(s, "div")),
            None => h.get("division").and_then(|s| suggested_of(s, "division")),
        };
        let same = h.get("samebook").filter(|s| s.is_object()).map(same_of).transpose()?;
        Ok(PackFacts {
            copy: original.unwrap_or_else(|| doc_id.clone()),
            doc_id,
            version: h.get("doc_version").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok()).unwrap_or(0),
            title,
            suggested,
            blake3,
            same,
        })
    }

    /// The facts same-book detection looks at.
    pub fn detect_facts(&self) -> Facts {
        Facts {
            copy: self.copy.clone(),
            blake3: self.blake3.clone(),
            minhash: self.same.as_ref().map(|s| s.minhash.clone()).unwrap_or_default(),
            mean_vector: self.same.as_ref().map(|s| s.mean_vector.clone()).unwrap_or_default(),
            words: None,
        }
    }

    /// What the reading-copy order looks at; `None` for a pack without `samebook`. The copy key stands in for the doc id in the
    /// last tie-break, so every device breaks the tie the same way.
    pub fn quality(&self) -> Option<CopyQuality> {
        self.same.as_ref().map(|s| CopyQuality { doc_id: self.copy.clone(), text_pages: s.text_pages, pages: s.pages, ppi: s.ppi, size: s.source_size })
    }
}

/// What a published library's seed log suggests, by `doc_id`. Its `assign` numbers are never read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Seed {
    /// The latest `place` (`Some(division)`) or `unsort` (`None`) of each book.
    pub place: BTreeMap<String, Option<String>>,
    /// The publisher's latest `title` of each book.
    pub title: BTreeMap<String, String>,
}

/// Reads the seed logs (`log/builder-*.jsonl`) of a library. Missing logs give an empty seed.
pub fn read_seed(library_dir: &Path) -> Result<Seed> {
    let dir = library_dir.join(LOG_DIR);
    let mut stamped: Vec<(u64, String, usize, Kind)> = Vec::new();
    for name in log_file_names(&dir)?.into_iter().filter(|n| n.starts_with(SEED_PREFIX)) {
        let bytes = std::fs::read(dir.join(&name)).map_err(|e| Error::ctx(&format!("reading {name}"), e))?;
        for (i, e) in parse_legacy_log(&String::from_utf8_lossy(&bytes)).0.into_iter().enumerate() {
            stamped.push((e.at, e.dev, i, e.kind));
        }
    }
    stamped.sort_by(|a, b| (a.0, &a.1, a.2).cmp(&(b.0, &b.1, b.2)));
    let mut seed = Seed::default();
    for (_, _, _, kind) in stamped {
        match kind {
            Kind::Place { copy, div, .. } => {
                seed.place.insert(copy, Some(div));
            }
            Kind::Unsort { copy, .. } => {
                seed.place.insert(copy, None);
            }
            Kind::Title { copy, title } => {
                seed.title.insert(copy, title);
            }
            _ => {}
        }
    }
    Ok(seed)
}

/// A library read: its copies and its seed.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LibraryInput {
    pub library_id: String,
    pub dir: PathBuf,
    /// One entry per live pack (the highest version of each `doc_id`).
    pub copies: Vec<PackFacts>,
    pub seed: Seed,
    /// Packs whose header could not be read.
    pub unreadable: usize,
}

/// Reads a library: the live pack of each book, and the seed log.
pub fn load_library(lib: &LibraryRef, read_header: HeaderReader) -> Result<LibraryInput> {
    let packs = lib.packs();
    // pick the highest version of each doc_id from the file names (`<doc_id>@<version>.cdoc`)
    let mut best: BTreeMap<String, (u32, PathBuf)> = BTreeMap::new();
    match std::fs::read_dir(&packs) {
        Ok(rd) => {
            for entry in rd.filter_map(|e| e.ok()) {
                let name = entry.file_name().to_string_lossy().into_owned();
                let Some(stem) = name.strip_suffix(&format!(".{PACK_EXT}")) else { continue };
                if name.starts_with('.') {
                    continue;
                }
                let (doc, ver) = match stem.rsplit_once('@') {
                    Some((d, v)) => (d.to_string(), v.parse::<u32>().unwrap_or(0)),
                    None => (stem.to_string(), 0),
                };
                if best.get(&doc).is_none_or(|(v, _)| *v < ver) {
                    best.insert(doc, (ver, entry.path()));
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(Error::ctx(&format!("reading {}", packs.display()), e)),
    }
    let mut copies = Vec::new();
    let mut unreadable = 0;
    for (_, path) in best.into_values() {
        match read_header(&path).map_err(Error::new).and_then(|l| PackFacts::from_header_line(&l)) {
            Ok(f) => copies.push(f),
            Err(_) => unreadable += 1,
        }
    }
    copies.sort_by(|a, b| a.doc_id.cmp(&b.doc_id));
    Ok(LibraryInput { library_id: lib.library_id.clone(), dir: lib.dir.clone(), copies, seed: read_seed(&lib.dir)?, unreadable })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_header_gives_the_copy_key_the_title_and_the_samebook_facts() {
        let line = r#"{"cdoc":1,"doc_id":"wm","doc_version":2,"title":"Old","source":{"blake3":"srcsrc"},"book":{"title":"Wilderness Medicine","original_blake3":"orig","suggested":{"div":"610","label":"Medicine","source":"classifier"}},"samebook":{"minhash":[1,2],"mean_vector":"ADwAOA==","text_pages":300,"pages":310,"ppi":150,"source_size":999}}"#;
        let f = PackFacts::from_header_line(line).unwrap();
        assert_eq!((f.copy.as_str(), f.doc_id.as_str(), f.version, f.title.as_str(), f.blake3.as_deref()), ("orig", "wm", 2, "Wilderness Medicine", Some("orig")));
        assert_eq!(f.suggested, Some(SuggestedDiv { div: "610".into(), label: "Medicine".into() }));
        let q = f.quality().unwrap();
        assert_eq!((q.doc_id.as_str(), q.text_pages, q.pages, q.ppi, q.size), ("orig", 300, 310, Some(150), 999));
        assert_eq!(f.detect_facts().mean_vector, vec![1.0, 0.5]);
    }

    #[test]
    fn a_revision_3_header_without_book_uses_the_doc_id_and_division() {
        let line = r#"{"cdoc":1,"doc_id":"old","doc_version":1,"title":"Stone","source":{"blake3":"srcsrc"},"division":{"division":"440","label":"Stone","source":"sorter"}}"#;
        let f = PackFacts::from_header_line(line).unwrap();
        assert_eq!((f.copy.as_str(), f.title.as_str(), f.blake3.as_deref()), ("old", "Stone", Some("srcsrc")));
        assert_eq!(f.suggested.unwrap().div, "440");
        assert!(f.same.is_none() && PackFacts::from_header_line("{").is_err());
    }
}
