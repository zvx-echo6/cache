//! The `--labels` and `--titles` files of a rebuild (`cache-build library`, and `cache-build pdf`): which division and which
//! title a book gets from them, and how a pack finds its record.
//!
//! The labels become a book's suggested division (source `label`), and a replaced title is kept as `source_title`. Where the
//! book is shelved and what it is called afterwards is the log's business (see LIBRARY-LOG.md): the seed log records a division
//! as `place` and `assign`, and a replaced title as `title`.

use crate::error::{Error, Result};
use crate::pack::{Header, Suggested};
use crate::view::BookFacts;
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

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
    /// The new title; `None` when the line has no usable title (or is not `ok`).
    pub title: Option<String>,
    pub author: Option<String>,
    pub edition: Option<String>,
    pub year: Option<u32>,
}

impl TitleRec {
    fn has_facts(&self) -> bool {
        self.author.is_some() || self.edition.is_some() || self.year.is_some()
    }
}

/// A string book fact: trimmed, 1..=`max` characters. `Err(())` when the field is present but unusable; `Ok(None)` when absent.
fn fact_text(r: &Value, k: &str, max: usize) -> std::result::Result<Option<String>, ()> {
    match r.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            let t = s.trim();
            if t.is_empty() || t.chars().count() > max {
                Err(())
            } else {
                Ok(Some(t.to_string()))
            }
        }
        Some(_) => Err(()),
    }
}

/// The year book fact: a JSON integer in 1400..=2100.
fn fact_year(r: &Value) -> std::result::Result<Option<u32>, ()> {
    match r.get("year") {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_i64() {
            Some(y) if (1400..=2100).contains(&y) => Ok(Some(y as u32)),
            _ => Err(()),
        },
    }
}

pub type Titles = KeyedFile<TitleRec>;

/// Reads a titles file: JSON Lines `{id, path, title, source_title, method, ok, author?, edition?, year?}`. A line that is not
/// `ok`, or has no title, gives no title (the existing one stays). `author` (1..200 characters after trimming), `edition`
/// (1..60 characters) and `year` (an integer, 1400..2100) are optional; a value that fails its check is dropped on its own, not
/// the line, and counted (see [`load_titles_counted`]). A line with no usable title can still carry them, and they are taken
/// even when `ok` is false. A blank line is ignored; any other line that is not JSON is an error.
pub fn load_titles(path: &Path) -> Result<Titles> {
    load_titles_counted(path).map(|(t, _)| t)
}

/// [`load_titles`], and how many author, edition or year values were dropped for failing their checks.
pub fn load_titles_counted(path: &Path) -> Result<(Titles, usize)> {
    let raw = std::fs::read_to_string(path).map_err(|e| Error::ctx(&format!("reading {}", path.display()), e))?;
    let mut recs = Vec::new();
    let mut dropped = 0usize;
    for (n, line) in raw.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let r: Value = serde_json::from_str(line).map_err(|e| Error::ctx(&format!("{} line {}", path.display(), n + 1), e))?;
        let title = if r.get("ok").and_then(|x| x.as_bool()) == Some(false) { None } else { text(&r, "title") };
        let mut keep = |res: std::result::Result<Option<String>, ()>| match res {
            Ok(v) => v,
            Err(()) => {
                dropped += 1;
                None
            }
        };
        let author = keep(fact_text(&r, "author", 200));
        let edition = keep(fact_text(&r, "edition", 60));
        let year = keep_year(fact_year(&r), &mut dropped);
        let value = TitleRec { title, author, edition, year };
        if value.title.is_none() && !value.has_facts() {
            continue;
        }
        let name = text(&r, "path").map(|p| file_name_of(&p)).unwrap_or_default();
        recs.push(Keyed { id: text(&r, "id"), blake3: text(&r, "blake3"), name, value });
    }
    Ok((KeyedFile::new(recs), dropped))
}

fn keep_year(res: std::result::Result<Option<u32>, ()>, dropped: &mut usize) -> Option<u32> {
    match res {
        Ok(v) => v,
        Err(()) => {
            *dropped += 1;
            None
        }
    }
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
    /// Documents that got an author, edition or year from the titles file.
    pub facts_applied: usize,
    /// Author, edition or year values the titles file had that failed their checks and were dropped (set when it was read).
    pub facts_dropped: usize,
}

/// The overrides of a rebuild: both are optional.
#[derive(Default)]
pub struct Overrides {
    pub labels: Option<Labels>,
    pub titles: Option<Titles>,
    /// Author, edition and year values of the titles file dropped as invalid, for the report.
    pub facts_dropped: usize,
    /// Names for the divisions of `labels`; a division without a name gets its code as its label.
    pub names: HashMap<String, String>,
    /// The division sorter (`cache-build library --classifier`): files the books no label and no pack has placed.
    pub sorter: Option<cache_classify::Model>,
}

impl Overrides {
    /// The facts for a pack: its own, then the labels file's division (source `label`) and the titles file's title, the old
    /// title kept as `source_title`.
    pub fn entry(&self, h: &Header, applied: &mut Applied) -> BookFacts {
        let mut e = BookFacts::from_header(h);
        applied.facts_dropped = self.facts_dropped;
        if let Some(l) = &self.labels {
            match l.find(h) {
                Found::One(r) => {
                    applied.labels_matched += 1;
                    e.suggested = Some(Suggested {
                        div: r.division.clone(),
                        label: r.label.clone().or_else(|| self.names.get(&r.division).cloned()).unwrap_or_else(|| r.division.clone()),
                        score: None,
                        classifier_version: None,
                        source: "label".into(),
                        second_div: r.second_division.clone(),
                        filed: None,
                        suggestions: Vec::new(),
                    });
                }
                Found::Ambiguous => applied.labels_ambiguous += 1,
                Found::None => applied.labels_unmatched += 1,
            }
        }
        if let Some(t) = &self.titles {
            match t.find(h) {
                Found::One(r) => {
                    applied.titles_matched += 1;
                    if let Some(t) = &r.title {
                        if *t != e.title {
                            e.source_title = Some(e.title.clone());
                            e.title_override = Some(t.clone());
                        }
                    }
                    if r.has_facts() {
                        applied.facts_applied += 1;
                        e.titles_facts = cache_shelves::events::FactFields { author: r.author.clone(), edition: r.edition.clone(), year: r.year };
                        if r.author.is_some() {
                            e.author = r.author.clone();
                        }
                        if r.edition.is_some() {
                            e.edition = r.edition.clone();
                        }
                        if r.year.is_some() {
                            e.year = r.year;
                        }
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
    fn titles_file_facts_are_checked_one_by_one() {
        let dir = std::env::temp_dir().join(format!("cache-titles-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("t.jsonl");
        let long_author = "a".repeat(201);
        let lines = [
            serde_json::json!({"id": "1", "title": "T", "author": " Ann ", "edition": "3rd", "year": 1400}),
            serde_json::json!({"id": "2", "author": long_author, "edition": "", "year": 2101}),
            serde_json::json!({"id": "3", "ok": false, "title": "No", "year": 2100, "edition": 5}),
            serde_json::json!({"id": "4", "title": "", "path": "x.pdf"}),
        ];
        std::fs::write(&f, lines.iter().map(|l| l.to_string()).collect::<Vec<_>>().join("\n") + "\n\n").unwrap();
        let (t, dropped) = load_titles_counted(&f).unwrap();
        std::fs::remove_dir_all(&dir).ok();
        // line 2 has nothing usable left, line 4 has nothing at all: both are not records; line 3 keeps only its year
        assert_eq!(t.len(), 2);
        assert_eq!(dropped, 4);
        let by = |id: &str| t.recs.iter().find(|r| r.id.as_deref() == Some(id)).map(|r| r.value.clone());
        assert_eq!(by("1"), Some(TitleRec { title: Some("T".into()), author: Some("Ann".into()), edition: Some("3rd".into()), year: Some(1400) }));
        assert_eq!(by("3"), Some(TitleRec { title: None, author: None, edition: None, year: Some(2100) }));
        assert_eq!(by("2"), None);
    }

    #[test]
    fn division_codes_are_three_digits() {
        assert!(valid_division("440"));
        assert!(!valid_division("unsure"));
        assert!(!valid_division("44"));
    }
}
