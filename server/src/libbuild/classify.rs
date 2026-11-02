//! Cache Decimal System (CDS): the classes, how a book is scored against them, call numbers and the names of filed files.
//! The classes are `build/classes.json` (a built-in default is written when it is missing, and any edit to it is picked up); it
//! names the folders and says which divisions are in use. Which division a book goes in is decided by the trained classifier
//! (`cache_classify`): its weights are a data file, `<data>/models/cache-classifier-<version>.bin`, loaded by [`ModelStore`].
//! The book vector is the mean of the book's selected piece vectors; a confident book is filed, any other goes to Unsorted with
//! the top 3 divisions kept as suggestions. With no model file every book is left in Unsorted with no suggestions. There are
//! no keyword rules. See `vault/projects/cache-classification.md`.

use cache_builder::pack::PackPiece;
use cache_classify::{division_code, Decision, Model};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

/// The classes a device starts with (the table in the classification note, with a draft description for each division).
pub const DEFAULT_CLASSES: &str = include_str!("classes-default.json");

/// The folder (and name) of the books that could not be placed.
pub const UNSORTED: &str = "Unsorted";

fn one() -> u32 {
    1
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Division {
    pub number: String,
    pub name: String,
    /// One or two plain sentences of what belongs here. Empty means the number is not in use.
    #[serde(default)]
    pub description: String,
}

impl Division {
    pub fn assigned(&self) -> bool {
        !self.description.trim().is_empty()
    }
    pub fn folder(&self) -> String {
        format!("{} {}", self.number, safe_part(&self.name, 80))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Class {
    pub number: String,
    pub name: String,
    pub divisions: Vec<Division>,
}

impl Class {
    pub fn folder(&self) -> String {
        format!("{} {}", self.number, safe_part(&self.name, 80))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Classes {
    #[serde(default = "one")]
    pub version: u32,
    pub classes: Vec<Class>,
}

impl Classes {
    pub fn default_classes() -> Classes {
        serde_json::from_str(DEFAULT_CLASSES).expect("the built-in classes are valid")
    }

    pub fn find(&self, division: &str) -> Option<(&Class, &Division)> {
        self.classes.iter().find_map(|c| c.divisions.iter().find(|d| d.number == division).map(|d| (c, d)))
    }

    pub fn find_class(&self, number: &str) -> Option<&Class> {
        self.classes.iter().find(|c| c.number == number)
    }

    pub fn assigned_divisions(&self) -> impl Iterator<Item = &Division> {
        self.classes.iter().flat_map(|c| c.divisions.iter()).filter(|d| d.assigned())
    }

    /// The folder of a division inside a filing tree: `<class>/<division>`, or `Unsorted`.
    pub fn folder_rel(&self, division: Option<&str>) -> PathBuf {
        match division.and_then(|d| self.find(d)) {
            Some((c, d)) => PathBuf::from(c.folder()).join(d.folder()),
            None => PathBuf::from(UNSORTED),
        }
    }
}

/// One candidate division and the classifier's probability for it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Suggestion {
    pub division: String,
    pub score: f32,
}

/// How a book scored.
#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    /// The three best divisions, best first.
    pub top: Vec<Suggestion>,
    /// The division chosen; `None` when the book is unsure.
    pub division: Option<String>,
    /// Why it is unsure: `low` (not confident enough) or `no_text`.
    pub unsure: Option<String>,
    /// The classifier version that decided.
    pub version: u32,
}

/// Does a piece hold real running text (not a table of numbers, a page of dots or an index)? The classifier was trained on
/// vectors of such pieces only: at least 15 words of two letters or more, and letters making up at least half of the
/// non-space characters.
pub fn is_real_text(t: &str) -> bool {
    let (mut words, mut letters, mut run) = (0usize, 0usize, 0usize);
    let mut total = 0usize;
    for c in t.chars() {
        if !c.is_whitespace() {
            total += 1;
        }
        if c.is_alphabetic() {
            run += 1;
        } else {
            if run >= 2 {
                words += 1;
                letters += run;
            }
            run = 0;
        }
    }
    if run >= 2 {
        words += 1;
        letters += run;
    }
    words >= 15 && letters as f64 / total.max(1) as f64 >= 0.5
}

/// The book vector of a book's pieces by the model's recipe: the real-text pieces are chosen ([`cache_classify::Recipe::select_indices`]),
/// each vector is made unit length, and the model averages them. Empty when the book has no real text.
pub fn book_vector_of(model: &Model, pieces: &[PackPiece]) -> Vec<f32> {
    let real: Vec<&PackPiece> = pieces.iter().filter(|p| !p.vector.is_empty() && is_real_text(&p.text)).collect();
    let units: Vec<Vec<f32>> = model
        .recipe()
        .select_indices(real.len())
        .into_iter()
        .map(|i| {
            let v = &real[i].vector;
            let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            v.iter().map(|x| x / (n + 1e-12)).collect()
        })
        .collect();
    let refs: Vec<&[f32]> = units.iter().map(|v| v.as_slice()).collect();
    cache_classify::book_vector(&refs)
}

/// Score a book: confident means filed in the best division, otherwise Unsorted with the top 3 as suggestions.
pub fn classify(model: &Model, pieces: &[PackPiece]) -> Result<Verdict, String> {
    let version = model.version();
    let book = book_vector_of(model, pieces);
    if book.is_empty() {
        return Ok(Verdict { top: vec![], division: None, unsure: Some("no_text".into()), version });
    }
    let r = model.classify(&book).map_err(|e| e.to_string())?;
    let top = r.top_k(3).iter().map(|c| Suggestion { division: division_code(c.division), score: c.probability }).collect();
    Ok(match r.decision() {
        Decision::Filed(d) => Verdict { top, division: Some(division_code(d)), unsure: None, version },
        Decision::Unsorted => Verdict { top, division: None, unsure: Some("low".into()), version },
    })
}

/// The classifier model files in `<data>/models/`: `cache-classifier-<version>.bin`, the highest version that loads is used. The
/// folder is looked at again whenever a file appears, goes or changes, so a model dropped in takes effect without a restart.
pub struct ModelStore {
    dir: PathBuf,
    state: Mutex<StoreState>,
}

type Signature = Vec<(u32, Option<SystemTime>, u64)>;

#[derive(Default)]
struct StoreState {
    seen: Option<Signature>,
    model: Option<Arc<Model>>,
}

impl ModelStore {
    pub fn new(data: &Path) -> ModelStore {
        ModelStore { dir: data.join("models"), state: Mutex::new(StoreState::default()) }
    }

    fn candidates(&self) -> Vec<(u32, PathBuf, Option<SystemTime>, u64)> {
        let Ok(rd) = std::fs::read_dir(&self.dir) else { return vec![] };
        let mut out: Vec<(u32, PathBuf, Option<SystemTime>, u64)> = rd
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                let n: u32 = name.strip_prefix("cache-classifier-")?.strip_suffix(".bin")?.parse().ok()?;
                let md = e.metadata().ok().filter(|m| m.is_file())?;
                Some((n, e.path(), md.modified().ok(), md.len()))
            })
            .collect();
        out.sort_by_key(|a| std::cmp::Reverse(a.0));
        out
    }

    /// The model in use now, or `None` when there is no usable model file.
    pub fn current(&self) -> Option<Arc<Model>> {
        let cands = self.candidates();
        let sig: Signature = cands.iter().map(|c| (c.0, c.2, c.3)).collect();
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if st.seen.as_ref() == Some(&sig) {
            return st.model.clone();
        }
        let mut found = None;
        for (n, path, _, _) in &cands {
            match std::fs::read(path).map_err(|e| e.to_string()).and_then(|b| Model::load(&b).map_err(|e| e.to_string())) {
                Ok(m) if m.embedding_sha256_hex() == cache_embed::DECIDED_MODEL_SHA256 => {
                    found = Some(Arc::new(m));
                    break;
                }
                Ok(_) => eprintln!("cache-server: classifier model {n} was trained on another embedding model; not used"),
                Err(e) => eprintln!("cache-server: classifier model {n} is not usable: {e}"),
            }
        }
        st.seen = Some(sig);
        st.model = found.clone();
        found
    }
}

/// Three letters of a title for a call number, skipping a leading "The", "A" or "An": `The Water Purification Handbook` is `WAT`.
pub fn call_letters(title: &str) -> String {
    let words: Vec<&str> = title.split_whitespace().collect();
    let skip = usize::from(words.len() > 1 && matches!(words[0].to_lowercase().as_str(), "the" | "a" | "an"));
    let mut out: String = words[skip..].join(" ").chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_uppercase).take(3).collect();
    while out.chars().count() < 3 {
        out.push('X');
    }
    out
}

/// `530 · KEA`, or `KEA` for a book that is not placed; a suffix (a year or `2e`) follows the letters.
pub fn call_number(division: Option<&str>, letters: &str, suffix: Option<&str>) -> String {
    let tail = match suffix {
        Some(s) if !s.is_empty() => format!("{letters} {s}"),
        _ => letters.to_string(),
    };
    match division {
        Some(d) => format!("{d} · {tail}"),
        None => tail,
    }
}

/// A piece of a file or folder name: characters that Windows or exFAT disks refuse become dashes, spaces are tidied, and the part
/// is cut to `max` characters.
pub fn safe_part(s: &str, max: usize) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            ':' => out.push_str(" -"),
            '/' | '\\' | '*' | '?' | '"' | '<' | '>' | '|' => out.push('-'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    let tidy = out.split_whitespace().collect::<Vec<_>>().join(" ");
    let cut: String = tidy.chars().take(max).collect();
    let cut = cut.trim_matches(|c: char| c == '.' || c.is_whitespace()).to_string();
    if cut.is_empty() {
        "Untitled".to_string()
    } else {
        cut
    }
}

/// The name of a filed book: `530 · KEA  The Water Purification Handbook.pdf`.
pub fn file_name(call: &str, title: &str) -> String {
    format!("{}  {}.pdf", safe_part(call, 40), safe_part(title, 120))
}

/// A short sentence for why a book is in Unsorted.
pub fn unsure_message(reason: &str) -> &'static str {
    match reason {
        "low" => "The sorter was not sure enough to file this book.",
        "close" => "Two or more divisions matched about equally.",
        "no_text" => "The book has no text to go by.",
        _ => "This book has not been looked at yet.",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_built_in_classes_match_the_table() {
        let c = Classes::default_classes();
        assert_eq!(c.classes.len(), 10);
        assert!(c.classes.iter().all(|k| k.divisions.len() == 9));
        let (class, div) = c.find("530").unwrap();
        assert_eq!((class.number.as_str(), class.name.as_str(), div.name.as_str()), ("500", "Water and Energy", "Water treatment"));
        assert_eq!(c.find("060").unwrap().1.name, "(unassigned)");
        assert!(!c.find("060").unwrap().1.assigned());
        assert_eq!(c.assigned_divisions().count(), 89);
        assert!(c.find("000").is_none());
    }

    #[test]
    fn call_numbers_skip_leading_articles() {
        assert_eq!(call_letters("The Water Purification Handbook"), "WAT");
        assert_eq!(call_letters("A Field Guide"), "FIE");
        assert_eq!(call_letters("An Introduction"), "INT");
        assert_eq!(call_letters("The"), "THE");
        assert_eq!(call_letters("1984"), "198");
        assert_eq!(call_letters("Hi"), "HIX");
        assert_eq!(call_number(Some("530"), "WAT", None), "530 · WAT");
        assert_eq!(call_number(Some("530"), "WAT", Some("2019")), "530 · WAT 2019");
        assert_eq!(call_number(None, "WAT", None), "WAT");
    }

    #[test]
    fn filed_names_are_safe() {
        assert_eq!(file_name("530 · KEA", "The Water Purification Handbook"), "530 · KEA  The Water Purification Handbook.pdf");
        assert_eq!(safe_part("Vehicles: cars, bikes and boats", 80), "Vehicles - cars, bikes and boats");
        assert_eq!(safe_part("a/b\\c*d?e", 80), "a-b-c-d-e");
        assert_eq!(safe_part("  ..  ", 80), "Untitled");
        assert_eq!(safe_part(&"x".repeat(300), 120).chars().count(), 120);
        let c = Classes::default_classes();
        assert_eq!(c.folder_rel(Some("690")), PathBuf::from("600 Building, Making and Repair").join("690 Vehicles - cars, bikes and boats"));
        assert_eq!(c.folder_rel(None), PathBuf::from("Unsorted"));
        assert_eq!(c.folder_rel(Some("999")), PathBuf::from("Unsorted"));
    }

    // ---- the classifier

    use cache_classify::{encode, Class, ModelSpec, Recipe, Weights};

    /// A 4-value model: axis d votes for division 110, 120, 130 (axis 3 votes for nothing). Threshold 0.6.
    pub(crate) fn tiny_model(version: u32, sha: &str) -> Vec<u8> {
        let mut sha_bytes = [0u8; 32];
        for (i, b) in sha_bytes.iter_mut().enumerate() {
            *b = u8::from_str_radix(&sha[i * 2..i * 2 + 2], 16).unwrap();
        }
        encode(&ModelSpec {
            classifier_version: version,
            embedding_sha256: sha_bytes,
            dims: 4,
            threshold: 0.6,
            recipe: Recipe { first_pieces: 2, spread_pieces: 1 },
            classes: vec![Class { division: 110, label: "A".into() }, Class { division: 120, label: "B".into() }, Class { division: 130, label: "C".into() }],
            bias: vec![0.0; 3],
            weights: Weights::F32(vec![6.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.0, 0.0]),
        })
    }

    fn piece(text: &str, vector: Vec<f32>) -> PackPiece {
        PackPiece { index: 0, text: text.to_string(), page: "1".into(), pdf_page: Some(1), page_end: None, pdf_page_end: None, heading_path: vec![], vector }
    }

    const PROSE: &str = "The well note explains how the well works in the field and why it matters to anyone digging a new one by hand";

    #[test]
    fn real_text_is_running_prose() {
        assert!(is_real_text(PROSE));
        assert!(!is_real_text("1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20"), "numbers are not words");
        assert!(!is_real_text("too short to be a passage"));
        assert!(!is_real_text(". . . . . . . . . . . . . . . . . . . . . . . . . . . . ab ab"), "dot leaders");
        assert!(!is_real_text(""));
    }

    #[test]
    fn the_book_vector_uses_real_pieces_by_the_recipe() {
        let m = Model::load(&tiny_model(1, cache_embed::DECIDED_MODEL_SHA256)).unwrap();
        // two real pieces and one that is not text: only the real ones are averaged (recipe: first 2, then 1 spread)
        let pieces = vec![piece(PROSE, vec![2.0, 0.0, 0.0, 0.0]), piece("1 2 3", vec![0.0, 9.0, 0.0, 0.0]), piece(PROSE, vec![0.0, 3.0, 0.0, 0.0])];
        let v = book_vector_of(&m, &pieces);
        let r = std::f32::consts::FRAC_1_SQRT_2;
        assert!((v[0] - r).abs() < 1e-5 && (v[1] - r).abs() < 1e-5 && v[2] == 0.0, "{v:?}");
        assert!(book_vector_of(&m, &[piece("1 2 3", vec![1.0, 0.0, 0.0, 0.0])]).is_empty());
        assert!(book_vector_of(&m, &[]).is_empty());
    }

    #[test]
    fn a_confident_book_is_filed_and_an_unsure_one_keeps_three_suggestions() {
        let m = Model::load(&tiny_model(3, cache_embed::DECIDED_MODEL_SHA256)).unwrap();
        let v = classify(&m, &[piece(PROSE, vec![0.0, 1.0, 0.0, 0.0])]).unwrap();
        assert_eq!((v.division.as_deref(), v.unsure.as_deref(), v.version), (Some("120"), None, 3));
        assert_eq!(v.top.len(), 3);
        assert_eq!(v.top[0].division, "120");
        assert!(v.top[0].score > 0.9);
        // between 110 and 130: the best is under the threshold
        let v = classify(&m, &[piece(PROSE, vec![1.0, 0.0, 1.05, 0.0])]).unwrap();
        assert_eq!((v.division, v.unsure.as_deref()), (None, Some("low")));
        assert_eq!(v.top.iter().map(|s| s.division.as_str()).collect::<Vec<_>>(), vec!["130", "110", "120"]);
        assert!(v.top[0].score < 0.6 && v.top[0].score >= v.top[1].score && v.top[1].score >= v.top[2].score);
        // no real text at all
        let v = classify(&m, &[piece("1 2 3", vec![1.0, 0.0, 0.0, 0.0])]).unwrap();
        assert_eq!((v.division, v.unsure.as_deref(), v.top.len()), (None, Some("no_text"), 0));
        // a vector of the wrong length is an error, not a guess
        assert!(classify(&m, &[piece(PROSE, vec![1.0, 0.0])]).is_err());
    }

    #[test]
    fn the_model_store_picks_the_highest_usable_version_and_notices_changes() {
        let d = crate::TempDir::new("store");
        let store = ModelStore::new(&d.0);
        assert!(store.current().is_none(), "no models folder");
        std::fs::create_dir_all(d.0.join("models")).unwrap();
        assert!(store.current().is_none(), "no model file");
        let sha = cache_embed::DECIDED_MODEL_SHA256;
        std::fs::write(d.0.join("models/cache-classifier-2.bin"), tiny_model(2, sha)).unwrap();
        std::fs::write(d.0.join("models/notes.txt"), b"x").unwrap();
        std::fs::write(d.0.join("models/cache-classifier-x.bin"), b"x").unwrap();
        assert_eq!(store.current().unwrap().version(), 2);
        // a newer file that is damaged, or trained on another embedder, is skipped
        std::fs::write(d.0.join("models/cache-classifier-9.bin"), b"damaged").unwrap();
        assert_eq!(store.current().unwrap().version(), 2);
        std::fs::write(d.0.join("models/cache-classifier-9.bin"), tiny_model(9, &"ab".repeat(32))).unwrap();
        assert_eq!(store.current().unwrap().version(), 2);
        // a good newer file is used at once, without a restart
        std::fs::write(d.0.join("models/cache-classifier-4.bin"), tiny_model(4, sha)).unwrap();
        assert_eq!(store.current().unwrap().version(), 4);
        std::fs::remove_file(d.0.join("models/cache-classifier-4.bin")).unwrap();
        assert_eq!(store.current().unwrap().version(), 2);
        std::fs::remove_file(d.0.join("models/cache-classifier-2.bin")).unwrap();
        assert!(store.current().is_none());
    }
}
