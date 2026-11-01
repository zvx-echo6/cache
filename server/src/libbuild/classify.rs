//! Cache Decimal Classification: the classes, how a book is scored against them, call numbers and the names of filed files.
//! The classes and their descriptions are `build/classes.json` (a built-in default is written when it is missing, and any edit
//! to it is picked up). The decision is the embedder's: the book's opening pages are compared with each division's description
//! by cosine similarity. There are no keyword rules. See `vault/projects/cache-classification.md`.

use cache_builder::fingerprint::cosine;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// The classes a device starts with (the table in the classification note, with a draft description for each division).
pub const DEFAULT_CLASSES: &str = include_str!("classes-default.json");

/// The folder (and name) of the books that could not be placed.
pub const UNSORTED: &str = "Unsorted";

fn one() -> u32 {
    1
}
fn default_below() -> f32 {
    0.40
}
fn default_margin() -> f32 {
    0.015
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Division {
    pub number: String,
    pub name: String,
    /// One or two plain sentences of what belongs here. Used only by the classifier; empty means the number is not in use.
    #[serde(default)]
    pub description: String,
}

impl Division {
    pub fn assigned(&self) -> bool {
        !self.description.trim().is_empty()
    }
    /// The text the embedder reads for this division.
    pub fn embed_text(&self) -> String {
        format!("{}. {}", self.name, self.description.trim())
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
    /// A book whose best division scores below this is unsure.
    #[serde(default = "default_below")]
    pub unsure_below: f32,
    /// A book whose best division beats the second by less than this is unsure.
    #[serde(default = "default_margin")]
    pub min_margin: f32,
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

    /// Identifies the texts the vectors were made from.
    pub fn digest(&self, model: &str) -> String {
        let mut h = blake3::Hasher::new();
        h.update(model.as_bytes());
        for d in self.assigned_divisions() {
            h.update(d.number.as_bytes());
            h.update(&[0]);
            h.update(d.embed_text().as_bytes());
            h.update(&[1]);
        }
        h.finalize().to_hex().to_string()
    }
}

/// The vectors of the divisions' texts.
#[derive(Clone, Debug)]
pub struct ClassVectors {
    pub digest: String,
    pub vectors: Vec<(String, Vec<f32>)>,
}

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
    /// Why it is unsure: `low` (nothing matched well), `close` (the best two are too near), `no_text`.
    pub unsure: Option<String>,
}

/// Score a book vector against the divisions. Unsure when the best score is under `unsure_below` or the margin to the second
/// is under `min_margin`.
pub fn classify(book: &[f32], vecs: &ClassVectors, cls: &Classes) -> Verdict {
    if book.is_empty() {
        return Verdict { top: vec![], division: None, unsure: Some("no_text".into()) };
    }
    let mut scored: Vec<Suggestion> = vecs.vectors.iter().map(|(d, v)| Suggestion { division: d.clone(), score: cosine(book, v) }).collect();
    scored.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal).then(a.division.cmp(&b.division)));
    scored.truncate(3);
    let Some(best) = scored.first() else { return Verdict { top: scored, division: None, unsure: Some("low".into()) } };
    let margin = best.score - scored.get(1).map_or(0.0, |s| s.score);
    let (division, unsure) = if best.score < cls.unsure_below {
        (None, Some("low".to_string()))
    } else if margin < cls.min_margin {
        (None, Some("close".to_string()))
    } else {
        (Some(best.division.clone()), None)
    };
    Verdict { top: scored, division, unsure }
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
        "low" => "No division matched this book clearly.",
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

    #[test]
    fn a_book_goes_to_its_nearest_division_unless_unsure() {
        let cls = Classes { version: 1, unsure_below: 0.5, min_margin: 0.1, classes: vec![] };
        let vecs = ClassVectors { digest: String::new(), vectors: vec![("110".into(), vec![1.0, 0.0]), ("120".into(), vec![0.0, 1.0]), ("130".into(), vec![0.7071, 0.7071])] };
        let v = classify(&[1.0, 0.05], &vecs, &cls);
        assert_eq!((v.division.as_deref(), v.unsure.as_deref()), (Some("110"), None));
        assert_eq!(v.top.len(), 3);
        assert!(v.top[0].score >= v.top[1].score && v.top[1].score >= v.top[2].score);
        // between two divisions: too close to call
        let v = classify(&[0.7, 0.7], &vecs, &cls);
        assert_eq!(v.unsure.as_deref(), Some("close"));
        // nothing near enough
        let strict = Classes { unsure_below: 0.99, ..cls.clone() };
        assert_eq!(classify(&[1.0, 0.3], &vecs, &strict).unsure.as_deref(), Some("low"));
        assert_eq!(classify(&[], &vecs, &cls).unsure.as_deref(), Some("no_text"));
    }
}
