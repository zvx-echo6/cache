//! Chunking: verbatim pieces of about 200 words built from whole sentences.
//!
//! - The last one or two sentences of a piece (at most 40 words) are repeated at the start of the next, inside a section.
//! - A heading ends the section: a piece never crosses a heading, and the first piece after one has no overlap.
//! - A piece spans a page break only when a sentence does (a sentence cut by a column or page end is rejoined). It records
//!   the page of its first word and, when different, the page of its last.
//! - A piece is at most 300 words (bge-m3 reads 512 tokens, about 1.3 tokens per word); a longer run is split at sentence
//!   boundaries, and a single sentence over 250 words is split at word boundaries as a last resort.
//! - The text is the book's own words; only whitespace, hyphenation at line ends and ligatures were touched upstream.

use crate::layout::Element;
use crate::text::{ends_sentence, join_pair, split_sentences, word_count};

pub const TARGET_WORDS: usize = 200;
pub const MIN_WORDS: usize = 100;
pub const MAX_WORDS: usize = 300;
pub const OVERLAP_WORDS: usize = 40;
pub const OVERLAP_SENTENCES: usize = 2;
/// A sentence longer than this is split at word boundaries.
pub const MAX_SENTENCE_WORDS: usize = 250;
/// A section's last piece with fewer new words than this is folded into the one before when it fits.
pub const TAIL_WORDS: usize = 50;
/// The chunker's version, recorded in packs.
pub const CHUNKER_VERSION: u32 = 1;

/// One piece of a document.
#[derive(Debug, Clone, PartialEq)]
pub struct Piece {
    pub index: u32,
    pub text: String,
    /// 0-based PDF page of the piece's first word.
    pub page: usize,
    /// 0-based PDF page of its last word (equal to `page` when it does not cross a page break).
    pub page_end: usize,
    /// The headings above it, outermost first.
    pub heading_path: Vec<String>,
}

#[derive(Debug, Clone)]
struct Sent {
    text: String,
    words: usize,
    page: usize,
    page_end: usize,
}

fn hard_split(text: &str) -> Vec<String> {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.len() <= MAX_SENTENCE_WORDS {
        return vec![text.to_string()];
    }
    let n = words.len().div_ceil(MAX_SENTENCE_WORDS);
    let size = words.len().div_ceil(n);
    words.chunks(size).map(|c| c.join(" ")).collect()
}

fn continues(last: &str, next: &str) -> bool {
    if ends_sentence(last) {
        return false;
    }
    let t = last.trim_end();
    t.ends_with([',', '-', '–', '—', '(']) || next.chars().next().is_some_and(|c| c.is_lowercase())
}

fn flush_pending(pending: &mut Vec<(String, usize)>, sents: &mut Vec<Sent>) {
    for (text, page) in pending.drain(..) {
        for part in split_sentences(&text) {
            for sub in hard_split(&part) {
                sents.push(Sent { words: word_count(&sub), text: sub, page, page_end: page });
            }
        }
    }
}

/// Chunk one section (paragraphs under the same heading path).
fn chunk_section(paras: &[(String, usize, bool, bool)], path: &[String], out: &mut Vec<Piece>) {
    let mut sents: Vec<Sent> = Vec::new();
    // Asides (pull-quotes, captions, notes) wait while a sentence is open, so they never cut it in two across a page.
    let mut pending: Vec<(String, usize)> = Vec::new();
    for (text, page, bullet, aside) in paras {
        if *aside && sents.last().is_some_and(|l| !ends_sentence(&l.text)) {
            pending.push((text.clone(), *page));
            continue;
        }
        let parts = split_sentences(text);
        for (k, part) in parts.into_iter().enumerate() {
            if k == 0 && !*bullet {
                if let Some(last) = sents.last_mut() {
                    if continues(&last.text, &part) {
                        last.text = join_pair(&last.text, &part);
                        last.words = word_count(&last.text);
                        last.page_end = *page;
                        continue;
                    }
                }
            }
            for sub in hard_split(&part) {
                sents.push(Sent { words: word_count(&sub), text: sub, page: *page, page_end: *page });
            }
        }
        if !pending.is_empty() && sents.last().is_some_and(|l| ends_sentence(&l.text)) {
            flush_pending(&mut pending, &mut sents);
        }
    }
    flush_pending(&mut pending, &mut sents);
    // A merged sentence can have grown past the limit.
    let mut fixed: Vec<Sent> = Vec::with_capacity(sents.len());
    for s in sents {
        if s.words > MAX_SENTENCE_WORDS {
            let (p, pe) = (s.page, s.page_end);
            for sub in hard_split(&s.text) {
                fixed.push(Sent { words: word_count(&sub), text: sub, page: p, page_end: pe });
            }
        } else {
            fixed.push(s);
        }
    }
    let sents = fixed;
    let n = sents.len();
    let total: usize = sents.iter().map(|s| s.words).sum();
    if n == 0 || total < 3 {
        return;
    }
    // (first sentence incl. overlap, end exclusive, first new sentence)
    let mut ranges: Vec<(usize, usize, usize)> = Vec::new();
    let mut new_start = 0usize;
    while new_start < n {
        let mut a = new_start;
        if new_start > 0 {
            let (mut ow, mut cnt) = (0usize, 0usize);
            while cnt < OVERLAP_SENTENCES && a > 0 && ow + sents[a - 1].words <= OVERLAP_WORDS {
                ow += sents[a - 1].words;
                a -= 1;
                cnt += 1;
            }
        }
        let mut cur: usize = sents[a..new_start].iter().map(|s| s.words).sum();
        let mut e = new_start;
        while e < n {
            let w = sents[e].words;
            if e > new_start {
                if cur + w > MAX_WORDS || cur >= TARGET_WORDS {
                    break;
                }
                if cur + w > TARGET_WORDS && cur >= MIN_WORDS && cur + w - TARGET_WORDS > TARGET_WORDS - cur {
                    break;
                }
            }
            cur += w;
            e += 1;
        }
        ranges.push((a, e, new_start));
        new_start = e;
    }
    if ranges.len() >= 2 {
        let (la, le, ln) = ranges[ranges.len() - 1];
        let new_words: usize = sents[ln..le].iter().map(|s| s.words).sum();
        let (pa, _, _) = ranges[ranges.len() - 2];
        let merged: usize = sents[pa..le].iter().map(|s| s.words).sum();
        let _ = la;
        if new_words < TAIL_WORDS && merged <= MAX_WORDS {
            ranges.pop();
            let k = ranges.len() - 1;
            ranges[k].1 = le;
        }
    }
    for (a, e, _) in ranges {
        let text = sents[a..e].iter().map(|s| s.text.as_str()).collect::<Vec<_>>().join(" ");
        let page = sents[a].page;
        let page_end = sents[a..e].iter().map(|s| s.page_end).max().unwrap_or(page).max(page);
        out.push(Piece { index: out.len() as u32, text, page, page_end, heading_path: path.to_vec() });
    }
}

/// Chunk a document's elements (in reading order) into pieces.
pub fn chunk(elements: &[Element]) -> Vec<Piece> {
    let mut out: Vec<Piece> = Vec::new();
    let mut stack: Vec<(u8, String)> = Vec::new();
    let mut paras: Vec<(String, usize, bool, bool)> = Vec::new();
    let mut path: Vec<String> = Vec::new();
    for el in elements {
        match el {
            Element::Heading { level, text, .. } => {
                chunk_section(&paras, &path, &mut out);
                paras.clear();
                while stack.last().is_some_and(|(l, _)| l >= level) {
                    stack.pop();
                }
                stack.push((*level, text.clone()));
                path = stack.iter().map(|(_, t)| t.clone()).collect();
            }
            Element::Para { text, page, bullet, aside } => paras.push((text.clone(), *page, *bullet, *aside)),
        }
    }
    chunk_section(&paras, &path, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sentence(i: usize, words: usize) -> String {
        let mut s = format!("S{i}");
        for k in 1..words {
            s.push_str(&format!(" w{k}"));
        }
        s.push('.');
        s
    }

    fn para(n: usize, words: usize, page: usize) -> Element {
        let text = (0..n).map(|i| sentence(i, words)).collect::<Vec<_>>().join(" ");
        Element::Para { text, page, bullet: false, aside: false }
    }

    #[test]
    fn sizes_and_overlap() {
        let pieces = chunk(&[para(120, 20, 0)]);
        assert!(pieces.len() > 5);
        for p in &pieces {
            let w = word_count(&p.text);
            assert!(w <= MAX_WORDS, "{w}");
        }
        let body: Vec<usize> = pieces[..pieces.len() - 1].iter().map(|p| word_count(&p.text)).collect();
        let mean = body.iter().sum::<usize>() as f32 / body.len() as f32;
        assert!((170.0..=230.0).contains(&mean), "{mean}");
        // each piece starts with the last sentence(s) of the one before (here one 20-word sentence fits, two make 40)
        for pair in pieces.windows(2) {
            let prev_sents = split_sentences(&pair[0].text);
            let first_next = split_sentences(&pair[1].text)[0].clone();
            let k = prev_sents.iter().position(|s| *s == first_next).expect("overlap sentence from the previous piece");
            let carried = prev_sents.len() - k;
            assert!((1..=2).contains(&carried), "carried {carried}");
            assert!(prev_sents[k..].iter().map(|s| word_count(s)).sum::<usize>() <= OVERLAP_WORDS);
        }
    }

    #[test]
    fn no_overlap_when_the_last_sentence_is_too_long() {
        // 45-word sentences: nothing fits in 40 words, so no overlap and no repeated text
        let pieces = chunk(&[para(30, 45, 0)]);
        for pair in pieces.windows(2) {
            assert!(!pair[1].text.starts_with(split_sentences(&pair[0].text).last().unwrap()));
        }
    }

    #[test]
    fn never_crosses_a_heading() {
        let els = vec![
            Element::Heading { level: 1, text: "Chapter I".into(), page: 0 },
            para(30, 10, 0),
            Element::Heading { level: 4, text: "1. General".into(), page: 1 },
            para(30, 10, 1),
            Element::Heading { level: 1, text: "Chapter II".into(), page: 2 },
            para(4, 10, 2),
        ];
        let pieces = chunk(&els);
        for p in &pieces {
            let inch1 = p.heading_path.first().map(|s| s.as_str()) == Some("Chapter I");
            if p.heading_path.len() == 2 {
                assert_eq!(p.heading_path, vec!["Chapter I", "1. General"]);
                assert!(p.page == 1);
            } else if inch1 {
                assert_eq!(p.page, 0);
            }
        }
        // the first piece after each heading has no text from before it
        let first_general = pieces.iter().find(|p| p.heading_path.len() == 2).unwrap();
        assert!(first_general.text.starts_with("S0 "));
        let c2 = pieces.iter().find(|p| p.heading_path == vec!["Chapter II"]).unwrap();
        assert!(c2.text.starts_with("S0 "));
        assert_eq!(c2.heading_path.len(), 1);
    }

    #[test]
    fn pages_and_page_end() {
        // one sentence cut by a page break is rejoined; the piece records both pages
        let els = vec![
            Element::Para { text: "First sentence here. The second sentence is cut,".into(), page: 4, bullet: false, aside: false },
            Element::Para { text: "and continues on the next page. Third.".into(), page: 5, bullet: false, aside: false },
        ];
        let p = chunk(&els);
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].text, "First sentence here. The second sentence is cut, and continues on the next page. Third.");
        assert_eq!((p[0].page, p[0].page_end), (4, 5));
        // a complete sentence on each page: they are still one piece here (short section), page_end is the last page
        let els = vec![
            Element::Para { text: "A whole sentence ends the page.".into(), page: 1, bullet: false, aside: false },
            Element::Para { text: "Another begins the next one.".into(), page: 2, bullet: false, aside: false },
        ];
        let p = chunk(&els);
        assert_eq!((p[0].page, p[0].page_end), (1, 2));
    }

    #[test]
    fn a_long_run_without_boundaries_is_split() {
        let text = (0..700).map(|i| format!("w{i}")).collect::<Vec<_>>().join(" ");
        let p = chunk(&[Element::Para { text, page: 0, bullet: false, aside: false }]);
        assert!(p.len() >= 3);
        assert!(p.iter().all(|x| word_count(&x.text) <= MAX_WORDS));
    }

    #[test]
    fn a_short_tail_is_folded_in() {
        let p = chunk(&[para(22, 10, 0)]);
        // 220 words: one piece, not a piece and a small leftover
        assert_eq!(p.len(), 1, "{:?}", p.iter().map(|x| word_count(&x.text)).collect::<Vec<_>>());
    }
}
