//! Telling the same book in another file: the rules that compare a new book with one already in the library, and which copy is
//! better. The numbers are `build/tuning.json` (defaults here); the text fingerprint and the mean meaning vector come from the
//! builder. See "Same book, different file" in `vault/projects/cache-classification.md`.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Tuning {
    /// Estimated Jaccard similarity of the 5-word shingles from which two files are the same book.
    pub same_jaccard: f32,
    /// Mean-vector cosine needed with it.
    pub same_cosine: f32,
    /// From this Jaccard up to `same_jaccard` (with the same cosine) a copy may be a new edition.
    pub edition_jaccard: f32,
    /// The shorter book's text must be at least this share of the longer's, or it is an excerpt.
    pub min_length_ratio: f32,
}

impl Default for Tuning {
    fn default() -> Self {
        Tuning { same_jaccard: 0.85, same_cosine: 0.95, edition_jaccard: 0.5, min_length_ratio: 0.8 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Match {
    /// Not the same book (or an excerpt).
    Different,
    /// The same book in another file.
    Same,
    /// The same work, noticeably different content: maybe a new edition.
    Edition,
}

pub fn judge(t: &Tuning, jaccard: f32, cosine: f32, new_words: usize, old_words: usize) -> Match {
    let (lo, hi) = (new_words.min(old_words) as f32, new_words.max(old_words) as f32);
    if hi <= 0.0 || lo / hi < t.min_length_ratio {
        return Match::Different;
    }
    if cosine < t.same_cosine {
        return Match::Different;
    }
    if jaccard >= t.same_jaccard {
        Match::Same
    } else if jaccard >= t.edition_jaccard {
        Match::Edition
    } else {
        Match::Different
    }
}

/// What makes one copy better than another.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Quality {
    pub text_pages: u32,
    pub pages: u32,
    pub ppi: u32,
    pub size: u64,
}

fn size_text(b: u64) -> String {
    if b >= 1 << 20 {
        format!("{:.1} MB", b as f64 / (1u64 << 20) as f64)
    } else {
        format!("{} KB", b.div_ceil(1024))
    }
}

/// Is `new` strictly better than `old`, and why. In order: more pages with real text, more pages, sharper page images, a smaller file.
pub fn better(new: &Quality, old: &Quality) -> Option<String> {
    if new.text_pages != old.text_pages {
        return (new.text_pages > old.text_pages).then(|| format!("the new copy has {} text pages vs {}", new.text_pages, old.text_pages));
    }
    if new.pages != old.pages {
        return (new.pages > old.pages).then(|| format!("the new copy has {} pages vs {}", new.pages, old.pages));
    }
    if new.ppi != old.ppi {
        return (new.ppi > old.ppi).then(|| format!("the new copy has sharper page images ({} vs {} ppi)", new.ppi, old.ppi));
    }
    (new.size < old.size).then(|| format!("the new copy is a smaller file ({} vs {})", size_text(new.size), size_text(old.size)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_rules_pick_same_edition_or_different() {
        let t = Tuning::default();
        assert_eq!(judge(&t, 0.95, 0.99, 1000, 1000), Match::Same);
        assert_eq!(judge(&t, 0.85, 0.95, 1000, 900), Match::Same);
        assert_eq!(judge(&t, 0.70, 0.98, 1000, 1000), Match::Edition);
        assert_eq!(judge(&t, 0.40, 0.98, 1000, 1000), Match::Different);
        assert_eq!(judge(&t, 0.95, 0.80, 1000, 1000), Match::Different, "the meaning must agree too");
        // an excerpt is never the same book, however alike the part is
        assert_eq!(judge(&t, 0.95, 0.99, 1000, 700), Match::Different);
        assert_eq!(judge(&t, 0.70, 0.99, 1000, 700), Match::Different);
        assert_eq!(judge(&t, 0.95, 0.99, 0, 0), Match::Different);
    }

    #[test]
    fn quality_goes_text_pages_then_pages_then_sharpness_then_size() {
        let q = |t, p, r, s| Quality { text_pages: t, pages: p, ppi: r, size: s };
        assert!(better(&q(312, 320, 100, 9), &q(298, 400, 300, 1)).unwrap().contains("312 text pages vs 298"));
        assert!(better(&q(300, 320, 100, 9), &q(300, 310, 300, 1)).unwrap().contains("320 pages vs 310"));
        assert!(better(&q(300, 300, 300, 9), &q(300, 300, 150, 1)).unwrap().contains("300 vs 150 ppi"));
        assert!(better(&q(300, 300, 150, 1000), &q(300, 300, 150, 2000)).unwrap().contains("smaller"));
        assert_eq!(better(&q(300, 300, 150, 2000), &q(300, 300, 150, 2000)), None, "equal is not better");
        assert_eq!(better(&q(10, 300, 150, 1), &q(11, 20, 10, 9)), None);
        assert_eq!(better(&q(300, 300, 150, 3000), &q(300, 300, 150, 2000)), None);
    }
}
