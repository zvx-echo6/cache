//! `docs.json`: the per-document sidecar at the library root (listed in `cache-library.json` as `"docs": "docs.json"`).
//!
//! It holds what the app shows about a document and the search payloads never carry: its division and its title. It is never
//! part of a search payload. See PACK-FORMAT.md ("docs.json").
//!
//! The writer builds it from the packs' `division` headers and titles. [`Labels`] and [`Titles`] (the `--labels` and `--titles`
//! files of `cache-build library`) override those for the rebuild. Readers apply the app's `overrides.json` on top; writing
//! `overrides.json` is the app's job.

use crate::error::{Error, Result};
use crate::pack::{Division, Header};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

/// The file name, at the library root.
pub const DOCS_FILE: &str = "docs.json";
pub const DOCS_FORMAT: u32 = 1;

/// One document's entry. Every key is always written (`null` when unknown).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocEntry {
    pub division: Option<String>,
    pub label: Option<String>,
    pub score: Option<f32>,
    pub classifier_version: Option<u32>,
    /// `label`, `sorter` or `user`; `null` when the document has no division.
    pub source: Option<String>,
    pub second_division: Option<String>,
    pub title: String,
    /// The title before a titles file replaced it; `null` when the title was not replaced.
    pub source_title: Option<String>,
}

impl DocEntry {
    pub fn new(title: &str, division: Option<&Division>) -> DocEntry {
        DocEntry {
            division: division.map(|d| d.division.clone()),
            label: division.map(|d| d.label.clone()),
            score: division.and_then(|d| d.score),
            classifier_version: division.and_then(|d| d.classifier_version),
            source: division.map(|d| d.source.clone()),
            second_division: division.and_then(|d| d.second_division.clone()),
            title: title.to_string(),
            source_title: None,
        }
    }
}

/// The whole file: `{"format": 1, "docs": {doc_id: entry}}`, the documents in doc_id order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Docs {
    pub format: u32,
    pub docs: BTreeMap<String, DocEntry>,
}

impl Default for Docs {
    fn default() -> Self {
        Docs { format: DOCS_FORMAT, docs: BTreeMap::new() }
    }
}

impl Docs {
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        let mut s = serde_json::to_string_pretty(self).map_err(|e| Error::ctx("docs.json", e))?;
        s.push('\n');
        Ok(s.into_bytes())
    }

    /// Reads a `docs.json`; rejects any format but 1.
    pub fn from_bytes(b: &[u8]) -> Result<Docs> {
        let d: Docs = serde_json::from_slice(b).map_err(|e| Error::ctx("docs.json", e))?;
        if d.format != DOCS_FORMAT {
            return Err(Error::new(format!("docs.json format {} is not supported (this reads {DOCS_FORMAT})", d.format)));
        }
        Ok(d)
    }
}

/// Writes `docs.json` in `dir` atomically: a temporary file in the same folder, flushed to disk, then renamed over the name, so a
/// reader (or a crash) sees the old file or the new one, never half of one.
pub fn write_docs(dir: &Path, docs: &Docs) -> Result<std::path::PathBuf> {
    let bytes = docs.to_bytes()?;
    let path = dir.join(DOCS_FILE);
    let tmp = dir.join(format!(".{DOCS_FILE}.tmp"));
    let write = || -> std::io::Result<()> {
        use std::io::Write;
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, &path)
    };
    write().map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        Error::ctx(&format!("writing {}", path.display()), e)
    })?;
    Ok(path)
}

// ------------------------------------------------------------------------------------------------ labels and titles

/// One line/record of a file keyed by a document: how a pack finds it.
#[derive(Debug, Clone)]
struct Keyed<T> {
    id: Option<String>,
    blake3: Option<String>,
    name: String,
    value: T,
}

/// The records of a labels or titles file, findable from a pack's header.
///
/// A pack records its `doc_id`, its source's BLAKE3 and the source's *file name* (not its folder). A record is matched, in this
/// order, by (1) `doc_id` equal to the record's `id`, (2) the source BLAKE3 equal to the record's `blake3` (when the record has
/// one), (3) the file name equal to the last part of the record's `path`, only when exactly one record has that name. Records
/// whose file name is shared are only matched by (1) or (2).
#[derive(Debug, Clone)]
pub struct KeyedFile<T> {
    recs: Vec<Keyed<T>>,
    by_id: HashMap<String, usize>,
    by_blake3: HashMap<String, usize>,
    by_name: HashMap<String, Vec<usize>>,
}

/// What a lookup found.
#[derive(Debug, Clone, PartialEq)]
pub enum Found<'a, T> {
    One(&'a T),
    /// The file name is shared by several records and neither the id nor the BLAKE3 settled it.
    Ambiguous,
    None,
}

impl<T> KeyedFile<T> {
    fn new(recs: Vec<Keyed<T>>) -> KeyedFile<T> {
        let mut by_id = HashMap::new();
        let mut by_blake3 = HashMap::new();
        let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
        for (i, r) in recs.iter().enumerate() {
            if let Some(id) = &r.id {
                by_id.entry(id.clone()).or_insert(i);
            }
            if let Some(b) = &r.blake3 {
                by_blake3.entry(b.to_lowercase()).or_insert(i);
            }
            by_name.entry(r.name.clone()).or_default().push(i);
        }
        KeyedFile { recs, by_id, by_blake3, by_name }
    }

    pub fn len(&self) -> usize {
        self.recs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.recs.is_empty()
    }

    pub fn find(&self, h: &Header) -> Found<'_, T> {
        if let Some(&i) = self.by_id.get(&h.doc_id) {
            return Found::One(&self.recs[i].value);
        }
        if let Some(&i) = self.by_blake3.get(&h.source.blake3.to_lowercase()) {
            return Found::One(&self.recs[i].value);
        }
        match self.by_name.get(&h.source.file_name).map(|v| v.as_slice()) {
            Some([i]) => Found::One(&self.recs[*i].value),
            Some(v) if v.len() > 1 => Found::Ambiguous,
            _ => Found::None,
        }
    }
}

fn file_name_of(path: &str) -> String {
    path.rsplit(['/', '\\']).next().unwrap_or(path).to_string()
}

fn text(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// A division code: three digits.
pub fn valid_division(s: &str) -> bool {
    s.len() == 3 && s.bytes().all(|c| c.is_ascii_digit())
}

/// What a labels file says about one document.
#[derive(Debug, Clone, PartialEq)]
pub struct LabelRec {
    pub division: String,
    pub second_division: Option<String>,
    pub label: Option<String>,
}

pub type Labels = KeyedFile<LabelRec>;

/// Reads a labels file: a JSON array of objects `{id, path, final, second_division}` (what `final_labels_v2.json` holds; other
/// keys are ignored), plus an optional `blake3` and `label` per object. A record whose `final` is not a three-digit division
/// ("unsure") is skipped.
pub fn load_labels(path: &Path) -> Result<Labels> {
    let raw = std::fs::read(path).map_err(|e| Error::ctx(&format!("reading {}", path.display()), e))?;
    let v: Value = serde_json::from_slice(&raw).map_err(|e| Error::ctx(&path.display().to_string(), e))?;
    let arr = v.as_array().ok_or_else(|| Error::new(format!("{}: expected a JSON array of label records", path.display())))?;
    let mut recs = Vec::new();
    for r in arr {
        let Some(fin) = text(r, "final").or_else(|| text(r, "division")) else { continue };
        if !valid_division(&fin) {
            continue;
        }
        let second = text(r, "second_division").filter(|s| valid_division(s));
        let name = text(r, "path").map(|p| file_name_of(&p)).unwrap_or_default();
        recs.push(Keyed {
            id: text(r, "id"),
            blake3: text(r, "blake3"),
            name,
            value: LabelRec { division: fin, second_division: second, label: text(r, "label") },
        });
    }
    Ok(KeyedFile::new(recs))
}

/// What a titles file says about one document.
#[derive(Debug, Clone, PartialEq)]
pub struct TitleRec {
    pub title: String,
}

pub type Titles = KeyedFile<TitleRec>;

/// Reads a titles file: JSON Lines `{id, path, title, source_title, method, ok}`. A line that is not `ok`, or has no title, is
/// skipped (the existing title stays). A blank line is ignored; any other line that is not JSON is an error.
pub fn load_titles(path: &Path) -> Result<Titles> {
    let raw = std::fs::read_to_string(path).map_err(|e| Error::ctx(&format!("reading {}", path.display()), e))?;
    let mut recs = Vec::new();
    for (n, line) in raw.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let r: Value = serde_json::from_str(line).map_err(|e| Error::ctx(&format!("{} line {}", path.display(), n + 1), e))?;
        if r.get("ok").and_then(|x| x.as_bool()) == Some(false) {
            continue;
        }
        let Some(title) = text(&r, "title") else { continue };
        let name = text(&r, "path").map(|p| file_name_of(&p)).unwrap_or_default();
        recs.push(Keyed { id: text(&r, "id"), blake3: text(&r, "blake3"), name, value: TitleRec { title } });
    }
    Ok(KeyedFile::new(recs))
}

/// The names of the divisions, from a classes file (`{"classes":[{"divisions":[{"number","name"}]}]}`, the format of the
/// server's `classes-default.json`).
pub fn division_names(classes: &Value) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for c in classes.get("classes").and_then(|c| c.as_array()).into_iter().flatten() {
        for d in c.get("divisions").and_then(|d| d.as_array()).into_iter().flatten() {
            if let (Some(n), Some(name)) = (text(d, "number"), text(d, "name")) {
                m.insert(n, name);
            }
        }
    }
    m
}

/// The division names the server ships by default.
pub fn default_division_names() -> HashMap<String, String> {
    serde_json::from_str::<Value>(include_str!("../../src/libbuild/classes-default.json")).map(|v| division_names(&v)).unwrap_or_default()
}

/// How many documents each override reached, for the report.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Applied {
    pub labels_matched: usize,
    pub labels_ambiguous: usize,
    pub labels_unmatched: usize,
    pub titles_matched: usize,
    pub titles_ambiguous: usize,
    pub titles_unmatched: usize,
}

/// The overrides of a rebuild: both are optional.
#[derive(Default)]
pub struct Overrides {
    pub labels: Option<Labels>,
    pub titles: Option<Titles>,
    /// Names for the divisions of `labels`; a division without a name gets its code as its label.
    pub names: HashMap<String, String>,
}

impl Overrides {
    /// The entry for a pack: its own division (or none) and title, then the labels file's division (source `label`) and the
    /// titles file's title, the original title kept as `source_title`. Returns the title the library should use.
    pub fn entry(&self, h: &Header, applied: &mut Applied) -> DocEntry {
        let mut e = DocEntry::new(&h.title, h.division.as_ref());
        if let Some(l) = &self.labels {
            match l.find(h) {
                Found::One(r) => {
                    applied.labels_matched += 1;
                    e.division = Some(r.division.clone());
                    e.label = Some(r.label.clone().or_else(|| self.names.get(&r.division).cloned()).unwrap_or_else(|| r.division.clone()));
                    e.score = None;
                    e.classifier_version = None;
                    e.source = Some("label".into());
                    e.second_division = r.second_division.clone();
                }
                Found::Ambiguous => applied.labels_ambiguous += 1,
                Found::None => applied.labels_unmatched += 1,
            }
        }
        if let Some(t) = &self.titles {
            match t.find(h) {
                Found::One(r) => {
                    applied.titles_matched += 1;
                    if r.title != h.title {
                        e.source_title = Some(h.title.clone());
                        e.title = r.title.clone();
                    }
                }
                Found::Ambiguous => applied.titles_ambiguous += 1,
                Found::None => applied.titles_unmatched += 1,
            }
        }
        e
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_names_come_from_either_slash() {
        assert_eq!(file_name_of("/mnt/library/A/b c.pdf"), "b c.pdf");
        assert_eq!(file_name_of("C:\\x\\y.pdf"), "y.pdf");
        assert_eq!(file_name_of("plain.pdf"), "plain.pdf");
    }

    #[test]
    fn division_codes_are_three_digits() {
        assert!(valid_division("440"));
        assert!(!valid_division("unsure"));
        assert!(!valid_division("44"));
    }
}
