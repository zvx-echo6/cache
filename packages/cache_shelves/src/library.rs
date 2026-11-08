//! What the Bookshelves log needs to know about a library: the facts in its pack headers, and its seed log.
//!
//! This crate links no gzip code (a pack is gzip-compressed JSON Lines), so the caller passes a [`HeaderReader`] that returns the
//! first line of a pack, which is its header. The builder and the core each have one.

use crate::error::{Error, Result};
use crate::events::{FactFields, Kind};
use crate::quality::CopyQuality;
use crate::same::{mean_vector_from, mean_vector_to, minhash_from, minhash_to, Facts};
use crate::store::{log_file_names, parse_legacy_log, LOG_DIR};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Returns the first line of a pack (its header, as JSON text).
pub type HeaderReader<'a> = &'a dyn Fn(&Path) -> std::result::Result<String, String>;

pub const PACK_EXT: &str = "cdoc";
/// The seed log of a published library is `log/builder-<library_id>.jsonl`.
pub const SEED_PREFIX: &str = "builder-";
/// A library's copies file at its root: one JSON line per document, with everything the Bookshelves log reads from a pack. A
/// library that has it needs no packs. See [`PackFacts::to_copies_line`].
pub const COPIES_FILE: &str = "copies.jsonl";

/// THE copy key: the book's `original_blake3`, else the `doc_id`. The builder (when it writes `copies.jsonl`) and the resolver
/// (when it reads a pack header or a copies line) both call this, so the key is the same whichever way a library is read.
pub fn copy_key(original_blake3: Option<&str>, doc_id: &str) -> String {
    match original_blake3 {
        Some(o) if !o.is_empty() => o.to_string(),
        _ => doc_id.to_string(),
    }
}

/// THE content hash: the `original_blake3`, else the source's `blake3`. Two copies with the same hash are one book.
pub fn content_hash(original_blake3: Option<&str>, source_blake3: Option<&str>) -> Option<String> {
    original_blake3.filter(|o| !o.is_empty()).or(source_blake3.filter(|s| !s.is_empty())).map(str::to_string)
}

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

/// What a pack header (or a line of `copies.jsonl`) says about one copy.
#[derive(Debug, Clone, PartialEq, Default)]
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
    /// `book.original_blake3`, when the pack has it.
    pub original_blake3: Option<String>,
    /// `source.blake3`, when the pack has it.
    pub source_blake3: Option<String>,
    /// `samebook`, when the pack has it (revision 3 and later).
    pub same: Option<SameInfo>,
    /// `book.author`, `book.edition` and `book.year`, each kept only if it passes the `facts` checks.
    pub fields: FactFields,
}

/// The `samebook` block of a pack.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SameInfo {
    pub minhash: Vec<u32>,
    pub mean_vector: Vec<f32>,
    pub text_pages: u32,
    pub pages: u32,
    pub ppi: Option<u32>,
    pub source_size: u64,
    /// Words in the text, when known (a pack header does not carry it).
    pub words: Option<u32>,
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
        words: num("words").and_then(|n| u32::try_from(n).ok()),
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
        let source = text(h.get("source").and_then(|s| s.get("blake3")));
        let blake3 = content_hash(original.as_deref(), source.as_deref());
        let title = book.and_then(|b| text(b.get("title"))).or_else(|| text(h.get("title"))).unwrap_or_default();
        let suggested = match book {
            Some(b) => b.get("suggested").and_then(|s| suggested_of(s, "div")),
            None => h.get("division").and_then(|s| suggested_of(s, "division")),
        };
        let same = h.get("samebook").filter(|s| s.is_object()).map(same_of).transpose()?;
        Ok(PackFacts {
            copy: copy_key(original.as_deref(), &doc_id),
            original_blake3: original,
            source_blake3: source,
            doc_id,
            version: h.get("doc_version").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok()).unwrap_or(0),
            title,
            suggested,
            blake3,
            same,
            fields: book.map(FactFields::from_value).unwrap_or_default(),
        })
    }

    /// The facts same-book detection looks at.
    pub fn detect_facts(&self) -> Facts {
        Facts {
            copy: self.copy.clone(),
            blake3: self.blake3.clone(),
            minhash: self.same.as_ref().map(|s| s.minhash.clone()).unwrap_or_default(),
            mean_vector: self.same.as_ref().map(|s| s.mean_vector.clone()).unwrap_or_default(),
            words: self.same.as_ref().and_then(|s| s.words),
        }
    }

    /// The line of `copies.jsonl` for this copy: compact JSON, keys in a fixed order, no line break. The same facts
    /// always give the same bytes. `samebook` holds the pack's own encodings (a MinHash as base64 of little-endian u32, a mean
    /// vector as base64 of little-endian f16), so a copy that was in a pack reads back equal.
    pub fn to_copies_line(&self) -> String {
        let mut o = serde_json::Map::new();
        o.insert("doc_id".into(), json!(self.doc_id));
        o.insert("doc_version".into(), json!(self.version));
        o.insert("copy".into(), json!(self.copy));
        if let Some(h) = &self.original_blake3 {
            o.insert("original_blake3".into(), json!(h));
        }
        if let Some(h) = &self.source_blake3 {
            o.insert("source_blake3".into(), json!(h));
        }
        o.insert("title".into(), json!(self.title));
        if let Some(s) = &self.suggested {
            o.insert("suggested".into(), json!({"div": s.div, "label": s.label}));
        }
        if let Some(a) = &self.fields.author {
            o.insert("author".into(), json!(a));
        }
        if let Some(e) = &self.fields.edition {
            o.insert("edition".into(), json!(e));
        }
        if let Some(y) = self.fields.year {
            o.insert("year".into(), json!(y));
        }
        if let Some(s) = &self.same {
            let mut b = serde_json::Map::new();
            b.insert("minhash".into(), json!(minhash_to(&s.minhash)));
            b.insert("mean_vector".into(), json!(mean_vector_to(&s.mean_vector)));
            b.insert("text_pages".into(), json!(s.text_pages));
            b.insert("pages".into(), json!(s.pages));
            if let Some(p) = s.ppi {
                b.insert("ppi".into(), json!(p));
            }
            b.insert("source_size".into(), json!(s.source_size));
            if let Some(w) = s.words {
                b.insert("words".into(), json!(w));
            }
            o.insert("samebook".into(), Value::Object(b));
        }
        Value::Object(o).to_string()
    }

    /// Reads one line of `copies.jsonl`. The copy key and the content hash are worked out again by [`copy_key`] and
    /// [`content_hash`] from `original_blake3`, `source_blake3` and `doc_id` (the line's own `copy` is for readers that do not
    /// link this crate), so they cannot differ from what a pack header gives.
    pub fn from_copies_line(line: &str) -> Result<PackFacts> {
        let h: Value = serde_json::from_str(line.trim()).map_err(|e| Error::ctx("a copies line", e))?;
        let text = |k: &str| h.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
        let doc_id = text("doc_id").ok_or_else(|| Error::new("a copies line has no doc_id"))?;
        let (original, source) = (text("original_blake3"), text("source_blake3"));
        Ok(PackFacts {
            copy: copy_key(original.as_deref(), &doc_id),
            blake3: content_hash(original.as_deref(), source.as_deref()),
            original_blake3: original,
            source_blake3: source,
            doc_id,
            version: h.get("doc_version").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok()).unwrap_or(0),
            title: text("title").unwrap_or_default(),
            suggested: h.get("suggested").and_then(|s| suggested_of(s, "div")),
            same: h.get("samebook").filter(|s| s.is_object()).map(same_of).transpose()?,
            fields: FactFields::from_value(&h),
        })
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
    /// The publisher's `facts`, per field the latest (by `at`, `dev`, line) that has the field.
    pub facts: BTreeMap<String, FactFields>,
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
            Kind::Facts { copy, fields } => {
                let cur = seed.facts.entry(copy).or_default();
                *cur = fields.or(cur);
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

/// Where a library's copies file is: `<dir>/copies.jsonl`, else `<dir>/shard/copies.jsonl` (where unpacking a `.cache-library`
/// leaves it until the app moves it to the root, as it does `documents.tsv`).
pub fn copies_path(dir: &Path) -> Option<PathBuf> {
    [dir.join(COPIES_FILE), dir.join("shard").join(COPIES_FILE)].into_iter().find(|p| p.is_file())
}

/// Reads a copies file: the highest version of each `doc_id`, in `doc_id` order, and the number of lines that were not readable.
pub fn read_copies(path: &Path) -> Result<(Vec<PackFacts>, usize)> {
    let bytes = std::fs::read(path).map_err(|e| Error::ctx(&format!("reading {}", path.display()), e))?;
    let mut best: BTreeMap<String, PackFacts> = BTreeMap::new();
    let mut unreadable = 0;
    for line in String::from_utf8_lossy(&bytes).lines().filter(|l| !l.trim().is_empty()) {
        match PackFacts::from_copies_line(line) {
            Ok(f) => {
                if best.get(&f.doc_id).is_none_or(|b| b.version < f.version) {
                    best.insert(f.doc_id.clone(), f);
                }
            }
            Err(_) => unreadable += 1,
        }
    }
    Ok((best.into_values().collect(), unreadable))
}

/// Reads a library: its copies file when it has one (no pack is opened), else the live pack of each book; and the seed log.
pub fn load_library(lib: &LibraryRef, read_header: HeaderReader) -> Result<LibraryInput> {
    if let Some(path) = copies_path(&lib.dir) {
        let (copies, unreadable) = read_copies(&path)?;
        return Ok(LibraryInput { library_id: lib.library_id.clone(), dir: lib.dir.clone(), copies, seed: read_seed(&lib.dir)?, unreadable });
    }
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

    #[test]
    fn a_copies_line_reads_back_equal_and_gives_the_same_key_as_the_pack() {
        let line = r#"{"cdoc":1,"doc_id":"wm","doc_version":2,"title":"Old","source":{"blake3":"srcsrc"},"book":{"title":"Wilderness Medicine","original_blake3":"orig","author":"A. Writer","year":2018,"suggested":{"div":"610","label":"Medicine","source":"classifier"}},"samebook":{"minhash":[1,2],"mean_vector":"ADwAOA==","text_pages":300,"pages":310,"ppi":150,"source_size":999}}"#;
        let from_pack = PackFacts::from_header_line(line).unwrap();
        let copies_line = from_pack.to_copies_line();
        assert!(!copies_line.contains('\n'));
        let back = PackFacts::from_copies_line(&copies_line).unwrap();
        assert_eq!(back, from_pack);
        assert_eq!((back.copy.as_str(), back.blake3.as_deref(), back.original_blake3.as_deref(), back.source_blake3.as_deref()), ("orig", Some("orig"), Some("orig"), Some("srcsrc")));
        assert_eq!(back.to_copies_line(), copies_line, "the same facts give the same bytes");
        // no original: the key is the doc id and the hash is the source's
        let old = r#"{"cdoc":1,"doc_id":"old","doc_version":1,"title":"Stone","source":{"blake3":"srcsrc"}}"#;
        let from_pack = PackFacts::from_header_line(old).unwrap();
        let back = PackFacts::from_copies_line(&from_pack.to_copies_line()).unwrap();
        assert_eq!(back, from_pack);
        assert_eq!((back.copy.as_str(), back.blake3.as_deref()), ("old", Some("srcsrc")));
        assert_eq!(copy_key(Some(""), "d"), "d");
        assert_eq!(copy_key(Some("o"), "d"), "o");
        assert_eq!(content_hash(None, Some("s")).as_deref(), Some("s"));
        assert!(PackFacts::from_copies_line("{").is_err() && PackFacts::from_copies_line("{}").is_err());
    }
}
