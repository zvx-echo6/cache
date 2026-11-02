//! From raw pages to a stream of headings and paragraphs in reading order.
//!
//! - Running heads, footers and page numbers are filtered (text repeated at the same height on many pages, bare numbers
//!   and roman numerals in the page margins).
//! - Pages with almost no text but with pictures are recorded as needing OCR and skipped (OCR comes later).
//! - Headings: a line at least 12% above the document's body size (character-weighted median), or a short bold line at
//!   body size. Levels follow size rank (H1 to H3); a bold body-size line is H4.
//! - Reading order: a two-column page is read left column, then right column, top to bottom in each; full-width blocks
//!   (titles, headings) stay where their height says; pull-quotes, sidebars and blocks in a distinct style go after the
//!   column text of the page, so they never interrupt a sentence.
//! - Lines are rejoined into paragraphs, including justified text that MuPDF splits word by word, and words hyphenated
//!   at a line end are made whole again.

use crate::extract::{Block, Extracted, Line, RawPage};
use crate::text::{ends_sentence, join_lines, normalize_ws};

/// A heading or paragraph in reading order (defined in `cache_chunk`, which chunks them).
pub use cache_chunk::Element;

/// The result of laying a document out.
#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub elements: Vec<Element>,
    /// 0-based pages with (almost) no text but with pictures: they need OCR and are skipped here.
    pub ocr_pages: Vec<usize>,
    pub body_size: f32,
}

/// A page with fewer text characters than this, and pictures, needs OCR.
pub const MIN_PAGE_CHARS: usize = 30;
/// A line this much above the body size (12%) is a heading.
pub const HEADING_RATIO: f32 = 1.12;

// ---------------------------------------------------------------------------------------------------------
// Running heads, footers, page numbers

fn roman_value(s: &str) -> Option<u32> {
    let mut total = 0u32;
    let mut prev = 0u32;
    for c in s.chars().rev() {
        let v = match c.to_ascii_uppercase() {
            'I' => 1,
            'V' => 5,
            'X' => 10,
            'L' => 50,
            'C' => 100,
            'D' => 500,
            'M' => 1000,
            _ => return None,
        };
        if v < prev {
            total = total.checked_sub(v)?;
        } else {
            total += v;
            prev = v;
        }
    }
    Some(total)
}

fn roman_string(mut n: u32) -> String {
    let table = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")];
    let mut out = String::new();
    for (v, s) in table {
        while n >= v {
            out.push_str(s);
            n -= v;
        }
    }
    out
}

/// True for a bare page number: 1 to 4 digits, a roman numeral, or either between dashes or brackets ("- 12 -").
pub fn is_page_number(text: &str) -> bool {
    let t = text.trim().trim_matches(|c: char| matches!(c, '-' | '–' | '—' | '[' | ']' | '(' | ')' | '.' | '·' | '•')).trim();
    if t.is_empty() || t.chars().count() > 8 {
        return false;
    }
    if t.len() <= 4 && t.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    // Chapter-numbered pages: "I-2", "A-14", "II-3".
    if let Some((a, b)) = t.split_once('-') {
        if !a.is_empty() && a.len() <= 4 && a.chars().all(|c| c.is_ascii_alphabetic()) && !b.is_empty() && b.len() <= 3 && b.chars().all(|c| c.is_ascii_digit()) {
            return true;
        }
    }
    if t.chars().all(|c| c.is_ascii_alphabetic()) {
        let up = t.to_ascii_uppercase();
        if t == up || t == t.to_ascii_lowercase() {
            if let Some(v) = roman_value(&up) {
                return v > 0 && roman_string(v) == up;
            }
        }
    }
    false
}

fn shape(text: &str) -> String {
    let mut out = String::new();
    for c in text.trim().chars() {
        if c.is_ascii_digit() {
            if !out.ends_with('#') {
                out.push('#');
            }
        } else if c.is_whitespace() {
            if !out.ends_with(' ') {
                out.push(' ');
            }
        } else {
            out.extend(c.to_lowercase());
        }
    }
    out
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
enum Zone {
    Top,
    Bottom,
}

fn zone_of(l: &Line, page_h: f32) -> Option<Zone> {
    if page_h <= 0.0 {
        return None;
    }
    if l.y1 <= page_h * 0.12 {
        Some(Zone::Top)
    } else if l.y0 >= page_h * 0.88 {
        Some(Zone::Bottom)
    } else {
        None
    }
}

/// Remove running heads, footers and page numbers from the pages' blocks (in place).
fn strip_furniture(pages: &mut [RawPage]) {
    use std::collections::{HashMap, HashSet};
    let text_pages = pages.iter().filter(|p| p.text_chars() >= MIN_PAGE_CHARS).count();
    // (zone, shape, y bucket of 4 points) -> the pages it appears on
    let mut seen: HashMap<(Zone, String, i32), HashSet<usize>> = HashMap::new();
    for p in pages.iter() {
        for b in &p.blocks {
            for l in &b.lines {
                if let Some(z) = zone_of(l, p.height) {
                    seen.entry((z, shape(&l.text), (l.y0 / 4.0).round() as i32)).or_default().insert(p.index);
                }
            }
        }
    }
    // Furniture: at the same height on many pages (15% of the pages), or on three or more pages that mostly sit next to
    // each other (a running head of a chapter), which chapter-opening titles on far apart pages never do.
    let threshold = if text_pages >= 6 { (text_pages as f32 * 0.15).ceil().max(3.0) as usize } else { usize::MAX };
    let furniture = |set: &HashSet<usize>| -> bool {
        if set.len() >= threshold {
            return true;
        }
        if text_pages < 6 || set.len() < 3 {
            return false;
        }
        let near = set.iter().filter(|&&p| set.contains(&(p + 1)) || set.contains(&(p + 2)) || (p >= 1 && set.contains(&(p - 1))) || (p >= 2 && set.contains(&(p - 2)))).count();
        near * 10 >= set.len() * 6
    };
    for p in pages.iter_mut() {
        let h = p.height;
        let idx = p.index;
        for b in p.blocks.iter_mut() {
            b.lines.retain(|l| {
                let Some(z) = zone_of(l, h) else { return true };
                if is_page_number(&l.text) {
                    return false;
                }
                let _ = idx;
                !seen.get(&(z, shape(&l.text), (l.y0 / 4.0).round() as i32)).is_some_and(furniture)
            });
        }
        p.blocks.retain(|b| !b.lines.is_empty());
        for b in p.blocks.iter_mut() {
            *b = Block::from_lines(std::mem::take(&mut b.lines));
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// Statistics

fn weighted_median(mut v: Vec<(i32, usize)>) -> Option<i32> {
    if v.is_empty() {
        return None;
    }
    v.sort();
    let total: usize = v.iter().map(|x| x.1).sum();
    let mut acc = 0;
    for (k, w) in &v {
        acc += w;
        if acc * 2 >= total {
            return Some(*k);
        }
    }
    v.last().map(|x| x.0)
}

/// The body size: the character-weighted median line size (tenths of a point, back to points).
pub fn body_size(pages: &[RawPage]) -> f32 {
    let mut v = Vec::new();
    for p in pages {
        for b in &p.blocks {
            for l in &b.lines {
                v.push(((l.size * 10.0).round() as i32, l.text.chars().filter(|c| !c.is_whitespace()).count()));
            }
        }
    }
    weighted_median(v).map(|k| k as f32 / 10.0).unwrap_or(10.0)
}

/// Whether a line of text can be a heading at all, whatever its size or weight: it does not start in lowercase, has at
/// least three letters that are most of its characters, is not a page or figure reference, a time or a "NOTE:"-style
/// callout, and does not end in a sentence period (unless it is a short numbered title such as "3-17. EFFECTS OF HUMIDITY.").
pub fn plausible_heading(text: &str) -> bool {
    let t = text.trim();
    let Some(first) = t.chars().next() else { return false };
    if first.is_lowercase() {
        return false;
    }
    let letters = t.chars().filter(|c| c.is_alphabetic()).count();
    let non_space = t.chars().filter(|c| !c.is_whitespace()).count();
    if letters < 3 || letters * 2 < non_space {
        return false;
    }
    let word = t.split(|c: char| !c.is_alphabetic()).next().unwrap_or("").to_ascii_uppercase();
    if matches!(word.as_str(), "NOTE" | "NOTES" | "CAUTION" | "WARNING" | "DANGER") && t[word.len()..].trim_start().starts_with(':') {
        return false;
    }
    if t.chars().all(|c| c.is_ascii_digit() || matches!(c, '-' | '–' | ':' | '.' | ' ' | '/')) {
        return false;
    }
    let low = t.to_lowercase();
    if (low.starts_with("figure ") || low.starts_with("fig.") || low.starts_with("fig ")) && t.chars().any(|c| c.is_ascii_digit()) {
        return false;
    }
    let end = t.trim_end_matches(['"', '”', '’', ')']);
    if end.ends_with('.') {
        let tok = t.split_whitespace().next().unwrap_or("");
        let numbered = tok.chars().any(|c| c.is_ascii_digit()) && tok.chars().all(|c| c.is_ascii_digit() || matches!(c, '-' | '.' | '–'));
        let all_caps = !t.chars().any(|c| c.is_lowercase());
        return (numbered || all_caps) && t.split_whitespace().count() <= 8;
    }
    true
}

struct Style {
    body: f32,
    /// Heading sizes (rounded to half points), largest first; only sizes that occur on 3 or more lines.
    levels: Vec<f32>,
    bold_rule: bool,
    italic_body: bool,
}

fn half(s: f32) -> f32 {
    (s * 2.0).round() / 2.0
}

fn compute_style(pages: &[RawPage]) -> Style {
    let body = body_size(pages);
    let mut counts: Vec<(i32, usize)> = Vec::new();
    let (mut chars, mut bold_chars, mut ital_chars) = (0usize, 0usize, 0usize);
    for p in pages {
        for b in &p.blocks {
            for l in &b.lines {
                let n = l.text.chars().filter(|c| !c.is_whitespace()).count();
                chars += n;
                if l.bold {
                    bold_chars += n;
                }
                if l.italic {
                    ital_chars += n;
                }
                if l.size >= body * HEADING_RATIO && l.text.chars().count() <= 200 {
                    let k = (half(l.size) * 2.0) as i32;
                    match counts.iter_mut().find(|c| c.0 == k) {
                        Some(c) => c.1 += 1,
                        None => counts.push((k, 1)),
                    }
                }
            }
        }
    }
    let mut levels: Vec<f32> = counts.iter().filter(|c| c.1 >= 3).map(|c| c.0 as f32 / 2.0).collect();
    levels.sort_by(|a, b| b.partial_cmp(a).unwrap());
    Style { body, levels, bold_rule: (bold_chars as f32) < 0.35 * chars.max(1) as f32, italic_body: (ital_chars as f32) > 0.3 * chars.max(1) as f32 }
}

impl Style {
    /// The heading level (1 to 4) of a line, or None for body text. `next` is the line after it in its block, and
    /// `block_all_bold_long` says the block is more than three bold lines (bold body text, not headings).
    fn heading_level(&self, l: &Line, next: Option<&Line>, block_all_bold_long: bool) -> Option<u8> {
        let chars = l.text.trim().chars().count();
        if chars == 0 {
            return None;
        }
        if l.size >= self.body * HEADING_RATIO && chars <= 200 {
            // Not a drop cap or a lone mark.
            if chars <= 1 {
                return None;
            }
            let s = half(l.size);
            let rank = self.levels.iter().filter(|&&x| x > s + 0.01).count() + 1;
            return Some(rank.min(3) as u8);
        }
        // A bold line at body size is a heading only when it is short, stands alone (the next line starts a new block, or
        // is bold too, as in a title wrapped over two lines) and is not the first line of a paragraph that carries on.
        let words = l.text.split_whitespace().count();
        let wrapped = next.is_some_and(|n| n.text.trim_start().chars().next().is_some_and(|c| c.is_lowercase()));
        let alone = next.is_none_or(|n| n.bold);
        if self.bold_rule && l.bold && alone && !wrapped && !block_all_bold_long && l.size >= self.body * 0.95 && chars <= 80 && words <= 8 && !l.text.trim_end().ends_with(',') {
            return Some(4);
        }
        None
    }
}

// ---------------------------------------------------------------------------------------------------------
// Reading order

fn block_median_size(b: &Block) -> f32 {
    let v: Vec<(i32, usize)> = b.lines.iter().map(|l| ((l.size * 10.0).round() as i32, l.text.chars().count())).collect();
    weighted_median(v).map(|k| k as f32 / 10.0).unwrap_or(0.0)
}

/// Find the gutter of a two-column page: the widest vertical strip in the middle that (almost) no narrow block's line
/// crosses, with real text on both sides. Returns (left edge, right edge).
fn find_gutter(blocks: &[&Block]) -> Option<(f32, f32)> {
    if blocks.len() < 2 {
        return None;
    }
    let x_min = blocks.iter().map(|b| b.x0).fold(f32::MAX, f32::min);
    let x_max = blocks.iter().map(|b| b.x1).fold(f32::MIN, f32::max);
    let w = x_max - x_min;
    if w < 150.0 {
        return None;
    }
    let total: usize = blocks.iter().map(|b| b.chars()).sum();
    let narrow: Vec<&&Block> = blocks.iter().filter(|b| b.width() < 0.6 * w).collect();
    let narrow_chars: usize = narrow.iter().map(|b| b.chars()).sum();
    if narrow.len() < 2 || (narrow_chars as f32) < 0.4 * total as f32 {
        return None;
    }
    let nbins = w.ceil() as usize + 1;
    let mut cov = vec![0u32; nbins];
    let mut lines = Vec::new();
    for b in &narrow {
        for l in &b.lines {
            lines.push((l.x0, l.x1, l.text.chars().count()));
            let a = ((l.x0 - x_min).floor().max(0.0)) as usize;
            let z = (((l.x1 - x_min).ceil()) as usize).min(nbins - 1);
            for c in cov.iter_mut().take(z + 1).skip(a) {
                *c += 1;
            }
        }
    }
    let peak = *cov.iter().max().unwrap_or(&0);
    if peak < 4 {
        return None;
    }
    let thr = (peak as f32 * 0.08).floor() as u32;
    let lo = (0.3 * w) as usize;
    let hi = ((0.7 * w) as usize).min(nbins - 1);
    let mut best: Option<(usize, usize)> = None;
    let mut i = lo;
    while i <= hi {
        if cov[i] <= thr {
            let s = i;
            while i <= hi && cov[i] <= thr {
                i += 1;
            }
            let e = i - 1;
            if best.is_none_or(|(bs, be)| e - s > be - bs) {
                best = Some((s, e));
            }
        } else {
            i += 1;
        }
    }
    let (s, e) = best?;
    let (g0, g1) = (x_min + s as f32, x_min + e as f32 + 1.0);
    if g1 - g0 < (5.0f32).max(0.012 * w) {
        return None;
    }
    let (mut lc, mut rc, mut ln, mut rn) = (0usize, 0usize, 0usize, 0usize);
    for (a, z, n) in &lines {
        if *z <= g0 + 1.0 {
            lc += n;
            ln += 1;
        } else if *a >= g1 - 1.0 {
            rc += n;
            rn += 1;
        }
    }
    let nc = narrow_chars.max(1) as f32;
    if ln < 3 || rn < 3 || (lc as f32) < 0.2 * nc || (rc as f32) < 0.2 * nc {
        return None;
    }
    Some((g0, g1))
}

fn is_aside_style(b: &Block, style: &Style) -> bool {
    let words: usize = b.lines.iter().map(|l| l.text.split_whitespace().count()).sum();
    let s = block_median_size(b);
    let differs = s > 0.0 && (s < style.body * 0.92 || s > style.body * 1.08);
    if differs && words <= 80 {
        return true;
    }
    !style.italic_body && words <= 60 && b.lines.iter().all(|l| l.italic)
}

/// The blocks of a page in reading order (indexes into `blocks`).
pub fn reading_order(blocks: &[Block], body: f32) -> Vec<usize> {
    reading_order_with(blocks, &Style { body, levels: Vec::new(), bold_rule: false, italic_body: false }).into_iter().map(|x| x.0).collect()
}

/// The reading order with a flag per block: true for blocks moved to the end of the page.
fn reading_order_with(blocks: &[Block], style: &Style) -> Vec<(usize, bool)> {
    let refs: Vec<&Block> = blocks.iter().collect();
    let Some((g0, g1)) = find_gutter(&refs) else {
        // One column: the order MuPDF found (the content stream), which is top to bottom for ordinary pages.
        return (0..blocks.len()).map(|i| (i, false)).collect();
    };
    let x_min = blocks.iter().map(|b| b.x0).fold(f32::MAX, f32::min);
    let x_max = blocks.iter().map(|b| b.x1).fold(f32::MIN, f32::max);
    let w = x_max - x_min;
    let gmid = (g0 + g1) / 2.0;
    let mut full: Vec<usize> = Vec::new();
    let mut left: Vec<usize> = Vec::new();
    let mut right: Vec<usize> = Vec::new();
    let mut deferred: Vec<usize> = Vec::new();
    for (i, b) in blocks.iter().enumerate() {
        let spans = b.x0 < g0 - 1.0 && b.x1 > g1 + 1.0;
        let heading = b.lines.first().is_some_and(|l| style.heading_level(l, b.lines.get(1), false).is_some());
        if !heading && is_aside_style(b, style) {
            // A pull-quote, epigraph, caption or note in a distinct style.
            deferred.push(i);
        } else if b.width() >= 0.6 * w {
            full.push(i);
        } else if spans {
            // A pull-quote or sidebar sitting over the gutter.
            deferred.push(i);
        } else if (b.x0 + b.x1) / 2.0 < gmid {
            left.push(i);
        } else {
            right.push(i);
        }
    }
    let cy = |i: usize| (blocks[i].y0 + blocks[i].y1) / 2.0;
    full.sort_by(|&a, &b| cy(a).partial_cmp(&cy(b)).unwrap());
    let band = |i: usize| full.iter().filter(|&&f| cy(f) < cy(i)).count();
    let mut out = Vec::with_capacity(blocks.len());
    for k in 0..=full.len() {
        if k > 0 {
            out.push((full[k - 1], false));
        }
        for col in [&left, &right] {
            let mut v: Vec<usize> = col.iter().copied().filter(|&i| band(i) == k).collect();
            v.sort_by(|&a, &b| blocks[a].y0.partial_cmp(&blocks[b].y0).unwrap());
            out.extend(v.into_iter().map(|i| (i, false)));
        }
    }
    deferred.sort_by(|&a, &b| blocks[a].y0.partial_cmp(&blocks[b].y0).unwrap().then(blocks[a].x0.partial_cmp(&blocks[b].x0).unwrap()));
    out.extend(deferred.into_iter().map(|i| (i, true)));
    out
}

// ---------------------------------------------------------------------------------------------------------
// Paragraphs

fn starts_bullet(t: &str) -> bool {
    let mut it = t.trim_start().chars();
    match it.next() {
        Some('•' | '▪' | '●' | '◦' | '■' | '‣' | '∙' | '○') => true,
        Some('-' | '–' | '—') => it.next().is_some_and(char::is_whitespace),
        _ => false,
    }
}

/// A list marker at the start of a line: "a. ", "1. ", "(a) ", "(1) ".
fn starts_list_marker(t: &str) -> bool {
    let t = t.trim_start();
    let mut it = t.chars();
    match it.next() {
        Some('(') => {
            let inner: String = it.by_ref().take_while(|c| *c != ')').collect();
            !inner.is_empty() && inner.chars().count() <= 3 && inner.chars().all(|c| c.is_ascii_alphanumeric()) && t.chars().nth(inner.chars().count() + 2) == Some(' ')
        }
        Some(c) if c.is_ascii_alphanumeric() => {
            let mut n = 1;
            let mut rest = it.clone();
            while let Some(d) = rest.next() {
                if d.is_ascii_digit() && c.is_ascii_digit() && n < 3 {
                    n += 1;
                    continue;
                }
                return d == '.' && rest.next() == Some(' ');
            }
            false
        }
        _ => false,
    }
}

/// Split a run of body lines (one block's) into paragraphs and join each into flowing text.
fn paragraphs_of(lines: &[&Line], block_x0: f32) -> Vec<(String, bool)> {
    let mut paras: Vec<Vec<&Line>> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        let new = if i == 0 {
            true
        } else {
            let a = lines[i - 1];
            let on_new_line = l.y0 >= a.y0 + 0.5 * l.size;
            let gap = l.y0 - a.y1;
            on_new_line
                && (starts_bullet(&l.text)
                    || gap > 0.45 * l.size
                    || l.x0 - block_x0 > 1.2 * l.size
                    || (starts_list_marker(&l.text) && ends_sentence(&a.text)))
        };
        if new {
            paras.push(vec![l]);
        } else {
            paras.last_mut().unwrap().push(l);
        }
    }
    paras
        .into_iter()
        .filter_map(|p| {
            let bullet = starts_bullet(&p[0].text);
            let t = join_lines(p.iter().map(|l| l.text.as_str()));
            if t.is_empty() {
                None
            } else {
                Some((t, bullet))
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------------------------------------
// The document

/// Lay out a whole extracted document.
pub fn layout(ext: &Extracted) -> Layout {
    let mut pages: Vec<RawPage> = ext.pages.clone();
    let mut ocr_pages = Vec::new();
    for p in &pages {
        if p.text_chars() < MIN_PAGE_CHARS && p.images > 0 {
            ocr_pages.push(p.index);
        }
    }
    strip_furniture(&mut pages);
    let style = compute_style(&pages);
    let mut elements: Vec<Element> = Vec::new();
    for p in &pages {
        if p.text_chars() < MIN_PAGE_CHARS {
            continue;
        }
        let order = reading_order_with(&p.blocks, &style);
        for &(bi, aside) in &order {
            let b = &p.blocks[bi];
            let long_bold = b.lines.len() > 3 && b.lines.iter().all(|l| l.bold);
            // Runs of lines of one kind: a heading level, or body.
            let mut lvls: Vec<Option<u8>> = (0..b.lines.len()).map(|k| style.heading_level(&b.lines[k], b.lines.get(k + 1), long_bold)).collect();
            // A "heading" that runs over more than three lines is a paragraph set in large type.
            let mut k = 0;
            while k < lvls.len() {
                let mut e = k + 1;
                while e < lvls.len() && lvls[e] == lvls[k] {
                    e += 1;
                }
                if lvls[k].is_some() && e - k > 3 {
                    for v in &mut lvls[k..e] {
                        *v = None;
                    }
                }
                k = e;
            }
            let mut i = 0;
            while i < b.lines.len() {
                let lvl = lvls[i];
                let mut j = i + 1;
                while j < b.lines.len() && lvls[j] == lvl {
                    // A heading wrapped over two lines is one heading; a new gap would be a new one.
                    if lvl.is_some() && b.lines[j].y0 - b.lines[j - 1].y1 > 0.8 * b.lines[j].size {
                        break;
                    }
                    j += 1;
                }
                let run: Vec<&Line> = b.lines[i..j].iter().collect();
                // The candidate heading must also read as one (see `plausible_heading`); otherwise it is body text.
                let lvl = lvl.filter(|_| plausible_heading(&normalize_ws(&join_lines(run.iter().map(|l| l.text.as_str())))));
                match lvl {
                    Some(level) => {
                        let text = normalize_ws(&join_lines(run.iter().map(|l| l.text.as_str())));
                        if !text.is_empty() {
                            elements.push(Element::Heading { level, text, page: p.index });
                        }
                    }
                    None => {
                        for (text, bullet) in paragraphs_of(&run, b.x0) {
                            elements.push(Element::Para { text, page: p.index, bullet, aside });
                        }
                    }
                }
                i = j;
            }
        }
    }
    // A heading that repeats on 4 or more pages and always stands alone on its page is a page notice ("This page
    // intentionally left blank"), not structure. (Headings such as "1. General" repeat in every chapter and stay.)
    let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut alone: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut page_chars: std::collections::HashMap<usize, usize> = std::collections::HashMap::new();
    for e in &elements {
        match e {
            Element::Heading { text, page, .. } => *page_chars.entry(*page).or_default() += text.chars().count(),
            Element::Para { text, page, .. } => *page_chars.entry(*page).or_default() += text.chars().count(),
        }
    }
    for e in &elements {
        if let Element::Heading { text, page, .. } = e {
            *counts.entry(text.clone()).or_default() += 1;
            if page_chars.get(page).copied().unwrap_or(0) < text.chars().count() + 100 {
                *alone.entry(text.clone()).or_default() += 1;
            }
        }
    }
    elements.retain(|e| match e {
        Element::Heading { text, .. } => {
            let n = counts.get(text).copied().unwrap_or(0);
            !(n >= 4 && alone.get(text).copied().unwrap_or(0) == n)
        }
        _ => true,
    });
    Layout { elements, ocr_pages, body_size: style.body }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn false_headings_are_rejected() {
        // started lowercase
        assert!(!plausible_heading("equivalent camouflage to improve concealment."));
        assert!(!plausible_heading("and hospitalization of sick and wounded"));
        // a sentence period
        assert!(!plausible_heading("Clarification of terms."));
        assert!(!plausible_heading("The team will not initiate contact."));
        // but a short numbered title may end in one
        assert!(plausible_heading("3-17. EFFECTS OF HUMIDITY."));
        assert!(plausible_heading("3-17. EFFECTS OF HUMIDITY"));
        assert!(plausible_heading("1. General"));
        // a short all-capitals title may end in a period ("CHAPTER III.")
        assert!(plausible_heading("CHAPTER III."));
        // too few letters, mostly punctuation
        assert!(!plausible_heading(".\u{201C}.\u{2014}"));
        assert!(!plausible_heading("A1"));
        assert!(!plausible_heading("-- 12 --"));
        // page, figure and time references
        assert!(!plausible_heading("6-7"));
        assert!(!plausible_heading("0800"));
        assert!(!plausible_heading("Figure 3-2"));
        assert!(!plausible_heading("Figure A-4"));
        // callouts
        assert!(!plausible_heading("NOTE: The team will not initiate contact"));
        assert!(!plausible_heading("CAUTION: Do not touch"));
        assert!(!plausible_heading("WARNING: Hot"));
        assert!(plausible_heading("NOTES ON THE TEXT"));
        assert!(plausible_heading("MARKSMANSHIP"));
    }
}
