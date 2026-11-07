//! The shared `cache_chunk` crate must give byte-identical pieces to the chunker the builder had before it moved.
//!
//! `tests/legacy/{chunk,text}.rs` are the old builder files, copied verbatim (used here for comparison only). They run
//! against the same inputs as the crate: PDFs generated at test time and put through the real extraction and layout, plus
//! many deterministic synthetic element sequences covering headings, bullets, asides, abbreviations, long sentences and
//! page breaks inside sentences.
#![allow(dead_code, unused_imports)]

mod common;

// The legacy chunker names these paths from its own crate root.
mod layout {
    pub use cache_builder::layout::Element;
}
#[path = "legacy/text.rs"]
mod text;
#[path = "legacy/chunk.rs"]
mod legacy_chunk;

use cache_builder::extract::extract_pdf;
use cache_builder::layout::{layout, Element};
use common::*;

type Flat = Vec<(u32, String, usize, usize, Vec<String>)>;

fn old(els: &[Element]) -> Flat {
    legacy_chunk::chunk(els).into_iter().map(|p| (p.index, p.text, p.page, p.page_end, p.heading_path)).collect()
}

fn new(els: &[Element]) -> Flat {
    cache_builder::chunk::chunk(els).into_iter().map(|p| (p.index, p.text, p.page, p.page_end, p.heading_path)).collect()
}

fn same(els: &[Element], what: &str) -> usize {
    let (o, n) = (old(els), new(els));
    assert_eq!(o.len(), n.len(), "{what}: piece count");
    for (a, b) in o.iter().zip(&n) {
        assert_eq!(a, b, "{what}");
        assert_eq!(a.1.as_bytes(), b.1.as_bytes(), "{what}");
    }
    n.len()
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

const WORDS: [&str; 12] = ["river", "carries", "the", "silt", "and", "Delta", "of", "Mr.", "U.S.", "e.g.", "12.", "water,"];

fn sentence(r: &mut Rng, id: usize) -> String {
    let n = match r.below(10) {
        0 => 260 + r.below(60), // longer than a sentence may be
        1 | 2 => 35 + r.below(20),
        _ => 4 + r.below(30),
    };
    let mut s = format!("S{id}");
    for _ in 1..n {
        s.push(' ');
        s.push_str(WORDS[r.below(WORDS.len())]);
    }
    s.push_str(["."," .", "!", "?", ".\"", ":"][r.below(6)]);
    s
}

fn synthetic(seed: u64) -> Vec<Element> {
    let mut r = Rng(seed);
    let mut els = Vec::new();
    let mut page = 0usize;
    let mut id = 0usize;
    for _ in 0..(3 + r.below(25)) {
        match r.below(6) {
            0 => els.push(Element::Heading { level: 1 + r.below(4) as u8, text: format!("Heading {}", r.below(1000)), page }),
            _ => {
                let k = 1 + r.below(8);
                let mut text = String::new();
                for _ in 0..k {
                    if !text.is_empty() {
                        text.push(' ');
                    }
                    text.push_str(&sentence(&mut r, id));
                    id += 1;
                }
                // sometimes cut mid-sentence so the next paragraph continues it
                if r.below(4) == 0 {
                    text = text.trim_end_matches(['.', '!', '?', ':', '"', ' ']).to_string();
                    if r.below(2) == 0 {
                        text.push(',');
                    }
                }
                els.push(Element::Para { text, page, bullet: r.below(8) == 0, aside: r.below(7) == 0 });
            }
        }
        if r.below(3) == 0 {
            page += 1;
        }
    }
    els
}

#[test]
fn synthetic_inputs_are_identical() {
    let mut pieces = 0;
    let mut multi_page = 0;
    for seed in 0..600u64 {
        let els = synthetic(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ 0x1234_5678);
        pieces += same(&els, &format!("seed {seed}"));
        multi_page += new(&els).iter().filter(|p| p.3 > p.2).count();
    }
    assert!(pieces > 200, "{pieces}");
    assert!(multi_page > 0, "{multi_page}");
}

#[test]
fn edge_inputs_are_identical() {
    assert_eq!(same(&[], "empty"), 0);
    same(&[Element::Para { text: "Hi.".into(), page: 0, bullet: false, aside: false }], "tiny");
    same(&[Element::Heading { level: 1, text: "Only".into(), page: 0 }], "heading only");
    let long = (0..700).map(|i| format!("w{i}")).collect::<Vec<_>>().join(" ");
    same(&[Element::Para { text: long, page: 3, bullet: false, aside: false }], "700 words");
}

/// A book-like PDF: chapters with headings, body text in ordinary type over several pages, sentences running across pages.
fn book(chapters: usize, paras: usize) -> Vec<u8> {
    let mut r = Rng(42);
    let mut pages: Vec<Page> = Vec::new();
    let mut cur = Page::new();
    let mut y = 50.0f32;
    let flush_if_full = |cur: &mut Page, y: &mut f32, pages: &mut Vec<Page>, need: f32| {
        if *y + need > 600.0 {
            pages.push(std::mem::take(cur));
            *y = 50.0;
        }
    };
    for c in 0..chapters {
        flush_if_full(&mut cur, &mut y, &mut pages, 400.0);
        cur.line(45.0, y, 18.0, Font::Regular, &format!("Chapter {}", c + 1));
        y += 30.0;
        for s in 0..2 {
            flush_if_full(&mut cur, &mut y, &mut pages, 60.0);
            cur.line(45.0, y, 10.0, Font::Bold, &format!("{}. Section {} of chapter {}", s + 1, s + 1, c + 1));
            y += 18.0;
            for _ in 0..paras {
                let mut text = String::new();
                for k in 0..(4 + r.below(10)) {
                    text.push_str(&format!("The river number {} carries silt to the sea and builds the delta over {} years of slow work. ", k, 10 + r.below(90)));
                }
                let lines = wrap(&text, 80);
                for l in &lines {
                    flush_if_full(&mut cur, &mut y, &mut pages, 14.0);
                    cur.line(45.0, y, 10.0, Font::Regular, l);
                    y += 12.0;
                }
                y += 8.0;
            }
        }
    }
    pages.push(cur);
    make_pdf(&pages, Some("Chunk identity fixture"))
}

#[test]
fn pdf_fixtures_are_identical() {
    let mut total = 0;
    for (chapters, paras) in [(1, 2), (3, 4), (6, 6)] {
        let pdf = book(chapters, paras);
        let ext = extract_pdf(&pdf).unwrap();
        let lay = layout(&ext);
        assert!(lay.elements.iter().any(|e| matches!(e, Element::Heading { .. })), "headings found");
        total += same(&lay.elements, &format!("book {chapters}x{paras}"));
    }
    assert!(total > 10, "{total}");
}

#[test]
fn version_is_unchanged() {
    assert_eq!(cache_builder::chunk::CHUNKER_VERSION, 1);
    assert_eq!(legacy_chunk::CHUNKER_VERSION, cache_builder::chunk::CHUNKER_VERSION);
    assert_eq!(legacy_chunk::TARGET_WORDS, cache_builder::chunk::TARGET_WORDS);
    assert_eq!(legacy_chunk::MAX_WORDS, cache_builder::chunk::MAX_WORDS);
    assert_eq!(legacy_chunk::MIN_WORDS, cache_builder::chunk::MIN_WORDS);
    assert_eq!(legacy_chunk::OVERLAP_WORDS, cache_builder::chunk::OVERLAP_WORDS);
    assert_eq!(legacy_chunk::TAIL_WORDS, cache_builder::chunk::TAIL_WORDS);
    assert_eq!(legacy_chunk::SMALL_PIECE_WORDS, cache_builder::chunk::SMALL_PIECE_WORDS);
}
