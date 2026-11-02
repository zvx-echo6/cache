//! From raw pages to a stream of headings and paragraphs in reading order.
//!
//! - Running heads, footers and page numbers are filtered (text repeated at the same height on many pages, bare numbers
//!   and roman numerals in the page margins).
//! - Pages with almost no text but with pictures are recorded as needing OCR and skipped (OCR comes later).
//! - Headings: a line at least 12% above the document's body size (character-weighted median), or a short bold line at
//!   body size. Levels follow size rank (H1 to H3); a bold body-size line is H4.
//! - Reading order: a page with columns (one vertical gap or several, as in three narrow columns or a two-page spread) is
//!   read in bands: full-width blocks (titles, headings) end a band, and inside a band each column is read top to bottom,
//!   left to right; a block with lines in several columns is cut into one block per column; a band of short cells in rows
//!   is a table and is read row by row; pull-quotes, sidebars and blocks in a distinct style go after the column text of
//!   the page, so they never interrupt a sentence. Only line geometry is used, never the words.
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

/// Find the gutters of a page: the vertical strips that (almost) no narrow line crosses, with real text on both sides,
/// left to right. One gutter makes two columns, two make three, and so on (a two-page spread of narrow columns has
/// five). Each returned pair is (left edge, right edge). Only line geometry is used.
fn find_gutters(blocks: &[&Block]) -> Vec<(f32, f32)> {
    let x_min = blocks.iter().map(|b| b.x0).fold(f32::MAX, f32::min);
    let x_max = blocks.iter().map(|b| b.x1).fold(f32::MIN, f32::max);
    let w = x_max - x_min;
    if w < 150.0 {
        return Vec::new();
    }
    let total: usize = blocks.iter().map(|b| b.chars()).sum();
    // The narrow lines (shorter than 0.6 of the text width): headings, titles and wide captions are left out.
    let mut lines: Vec<(f32, f32, usize)> = Vec::new();
    for b in blocks {
        for l in &b.lines {
            if l.x1 - l.x0 < 0.6 * w {
                lines.push((l.x0, l.x1, l.text.chars().count()));
            }
        }
    }
    let narrow_chars: usize = lines.iter().map(|l| l.2).sum();
    if lines.len() < 4 || (narrow_chars as f32) < 0.4 * total as f32 {
        return Vec::new();
    }
    let nbins = w.ceil() as usize + 1;
    let mut cov = vec![0u32; nbins];
    for &(x0, x1, _) in &lines {
        let a = ((x0 - x_min).floor().max(0.0)) as usize;
        let z = (((x1 - x_min).ceil()) as usize).min(nbins - 1);
        for c in cov.iter_mut().take(z + 1).skip(a) {
            *c += 1;
        }
    }
    let peak = *cov.iter().max().unwrap_or(&0);
    if peak < 4 {
        return Vec::new();
    }
    let thr = (peak as f32 * 0.08).floor() as u32;
    // Only between the first and the last covered bin: the ragged margins are not gutters.
    let (Some(lo), Some(hi)) = (cov.iter().position(|&c| c > thr), cov.iter().rposition(|&c| c > thr)) else { return Vec::new() };
    let min_width = (4.0f32).max(0.008 * w);
    let mut gutters: Vec<(f32, f32)> = Vec::new();
    let mut i = lo;
    while i <= hi {
        if cov[i] <= thr {
            let s = i;
            while i <= hi && cov[i] <= thr {
                i += 1;
            }
            let e = i - 1;
            if ((e - s + 1) as f32) >= min_width {
                gutters.push((x_min + s as f32, x_min + e as f32 + 1.0));
            }
        } else {
            i += 1;
        }
    }
    // Every column must hold real text (three lines and an eighth of the narrow characters); a gutter beside a thin strip
    // (a column of page numbers, a margin note) is dropped, which joins the strip to its neighbour.
    let nc = narrow_chars.max(1) as f32;
    loop {
        if gutters.is_empty() {
            return gutters;
        }
        let mut region_lines = vec![0usize; gutters.len() + 1];
        let mut region_chars = vec![0usize; gutters.len() + 1];
        for &(x0, x1, n) in &lines {
            // The column a line sits in entirely (a line over a gutter belongs to none).
            for r in 0..=gutters.len() {
                let left_ok = r == 0 || x0 >= gutters[r - 1].1 - 1.0;
                let right_ok = r == gutters.len() || x1 <= gutters[r].0 + 1.0;
                if left_ok && right_ok {
                    region_lines[r] += 1;
                    region_chars[r] += n;
                    break;
                }
            }
        }
        let bad = (0..region_lines.len()).find(|&r| region_lines[r] < 3 || (region_chars[r] as f32) < 0.125 * nc);
        let Some(r) = bad else { return gutters };
        if r == 0 {
            gutters.remove(0);
        } else if r == gutters.len() {
            gutters.pop();
        } else if gutters[r - 1].1 - gutters[r - 1].0 <= gutters[r].1 - gutters[r].0 {
            gutters.remove(r - 1);
        } else {
            gutters.remove(r);
        }
    }
}

/// The column (0-based, left to right) a line sits in, or None when it crosses a gutter (a heading, a title, a wide caption).
fn column_of(l: &Line, gutters: &[(f32, f32)]) -> Option<usize> {
    if gutters.iter().any(|g| l.x0 < g.0 - 1.0 && l.x1 > g.1 + 1.0) {
        return None;
    }
    let centre = (l.x0 + l.x1) / 2.0;
    Some(gutters.iter().filter(|g| (g.0 + g.1) / 2.0 < centre).count())
}

/// Rows of a table band: when the lines of a band (each with its column) sit in rows across the columns and are short
/// next to the spacing of the columns (cells, not running text), the blocks of the band are its rows, each row's cells
/// left to right. Otherwise None and the band is read column by column.
fn table_rows(items: &[(usize, &Block)], ncols: usize) -> Option<Vec<Block>> {
    let mut cells: Vec<(usize, &Line)> = Vec::new();
    for (c, b) in items {
        for l in &b.lines {
            cells.push((*c, l));
        }
    }
    if cells.len() < 4 {
        return None;
    }
    let yc = |l: &Line| (l.y0 + l.y1) / 2.0;
    let mut order: Vec<usize> = (0..cells.len()).collect();
    order.sort_by(|&a, &b| yc(cells[a].1).total_cmp(&yc(cells[b].1)).then(cells[a].1.x0.total_cmp(&cells[b].1.x0)));
    // Rows: lines whose middles are within 0.4 of their size of the row's first line.
    let mut rows: Vec<Vec<usize>> = Vec::new();
    let mut row_y = f32::MIN;
    for &i in &order {
        let l = cells[i].1;
        let same_row = !rows.is_empty() && (yc(l) - row_y).abs() <= 0.4 * l.size.max(1.0);
        if same_row {
            if let Some(r) = rows.last_mut() {
                r.push(i);
            }
        } else {
            row_y = yc(l);
            rows.push(vec![i]);
        }
    }
    let mut multi_rows = 0usize;
    let mut multi_lines = 0usize;
    for r in &rows {
        let mut cs: Vec<usize> = r.iter().map(|&i| cells[i].0).collect();
        cs.sort_unstable();
        cs.dedup();
        if cs.len() >= 2 {
            multi_rows += 1;
            multi_lines += r.len();
        }
    }
    if multi_rows < 2 || multi_lines * 5 < cells.len() * 4 {
        return None;
    }
    // Cells are short next to the spacing of the columns; running text fills its column.
    let mut starts = vec![f32::MAX; ncols];
    for (c, l) in &cells {
        starts[*c] = starts[*c].min(l.x0);
    }
    let mut fills: Vec<f32> = Vec::new();
    for (c, l) in &cells {
        if let Some(k) = ((*c + 1)..ncols).find(|&k| starts[k] < f32::MAX) {
            let pitch = starts[k] - starts[*c];
            if pitch > 1.0 {
                fills.push((l.x1 - l.x0) / pitch);
            }
        }
    }
    if fills.is_empty() {
        return None;
    }
    fills.sort_by(|a, b| a.total_cmp(b));
    if fills[fills.len() / 2] >= 0.5 {
        return None;
    }
    let mut out = Vec::with_capacity(rows.len());
    for r in &rows {
        let mut idx = r.clone();
        idx.sort_by(|&a, &b| cells[a].1.x0.total_cmp(&cells[b].1.x0));
        out.push(Block::from_lines(idx.into_iter().map(|i| cells[i].1.clone()).collect()));
    }
    Some(out)
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

/// The blocks of a page in reading order. A block that has lines in more than one column comes back as one block per
/// column, so the blocks are not always the page's own (every line comes back exactly once).
pub fn reading_blocks(blocks: &[Block], body: f32) -> Vec<Block> {
    reading_order_with(blocks, &Style { body, levels: Vec::new(), bold_rule: false, italic_body: false }).into_iter().map(|x| x.0).collect()
}

/// The reading order with a flag per block: true for blocks moved to the end of the page.
///
/// A page with no gutter is read in the order MuPDF found (the content stream), which is top to bottom for ordinary pages.
/// A page with gutters (two or more columns) is read in bands: a block whose lines cross a gutter (a title, a heading)
/// ends one band and starts the next, and inside a band each column is read top to bottom, left to right. A block with
/// lines in several columns is first cut into one block per column. A band whose lines sit in rows across short cells is
/// a table and is read row by row. Pull-quotes, sidebars and blocks in a distinct style go after the page's text.
fn reading_order_with(blocks: &[Block], style: &Style) -> Vec<(Block, bool)> {
    let refs: Vec<&Block> = blocks.iter().collect();
    let gutters = find_gutters(&refs);
    if gutters.is_empty() {
        return blocks.iter().map(|b| (b.clone(), false)).collect();
    }
    let x_min = blocks.iter().map(|b| b.x0).fold(f32::MAX, f32::min);
    let x_max = blocks.iter().map(|b| b.x1).fold(f32::MIN, f32::max);
    let w = x_max - x_min;
    let mut full: Vec<Block> = Vec::new();
    let mut in_columns: Vec<(usize, Block)> = Vec::new();
    let mut deferred: Vec<Block> = Vec::new();
    for b in blocks {
        let heading = b.lines.first().is_some_and(|l| style.heading_level(l, b.lines.get(1), false).is_some());
        if !heading && is_aside_style(b, style) {
            // A pull-quote, epigraph, caption or note in a distinct style.
            deferred.push(b.clone());
            continue;
        }
        let cols: Vec<Option<usize>> = b.lines.iter().map(|l| column_of(l, &gutters)).collect();
        if cols.iter().any(Option::is_none) {
            if b.width() >= 0.6 * w {
                full.push(b.clone());
            } else {
                // A pull-quote or sidebar sitting over a gutter.
                deferred.push(b.clone());
            }
            continue;
        }
        for c in 0..=gutters.len() {
            let mut lines: Vec<Line> = Vec::new();
            for (l, k) in b.lines.iter().zip(cols.iter()) {
                if *k == Some(c) {
                    lines.push(l.clone());
                }
            }
            if !lines.is_empty() {
                in_columns.push((c, Block::from_lines(lines)));
            }
        }
    }
    let cy = |b: &Block| (b.y0 + b.y1) / 2.0;
    full.sort_by(|a, b| cy(a).total_cmp(&cy(b)));
    let mut out: Vec<(Block, bool)> = Vec::with_capacity(blocks.len());
    for k in 0..=full.len() {
        if k > 0 {
            out.push((full[k - 1].clone(), false));
        }
        // The column blocks of this band: those below k full blocks and above the next.
        let mut band: Vec<(usize, &Block)> = Vec::new();
        for (c, b) in &in_columns {
            if full.iter().filter(|f| cy(*f) < cy(b)).count() == k {
                band.push((*c, b));
            }
        }
        if let Some(rows) = table_rows(&band, gutters.len() + 1) {
            out.extend(rows.into_iter().map(|r| (r, false)));
            continue;
        }
        for c in 0..=gutters.len() {
            let mut v: Vec<&Block> = band.iter().filter(|(col, _)| *col == c).map(|(_, b)| *b).collect();
            v.sort_by(|a, b| a.y0.total_cmp(&b.y0));
            out.extend(v.into_iter().map(|b| (b.clone(), false)));
        }
    }
    deferred.sort_by(|a, b| a.y0.total_cmp(&b.y0).then(a.x0.total_cmp(&b.x0)));
    out.extend(deferred.into_iter().map(|b| (b, true)));
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
        for (b, aside) in &order {
            let aside = *aside;
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

    // ---- reading order on plain data (no PDF): lines are given their boxes, so the geometry is exact

    fn ln(text: &str, x0: f32, y0: f32, x1: f32) -> Line {
        Line { text: text.to_string(), x0, y0, x1, y1: y0 + 12.0, size: 10.0, bold: false, italic: false }
    }

    /// A column of `n` lines at x0, 12 points apart from y0, each 90 wide, with words "<tag><k>" (three to a line).
    fn column(tag: &str, x0: f32, y0: f32, n: usize) -> Block {
        let lines = (0..n).map(|k| ln(&format!("{tag}{} {tag}{} {tag}{}", 3 * k, 3 * k + 1, 3 * k + 2), x0, y0 + 12.0 * k as f32, x0 + 90.0)).collect();
        Block::from_lines(lines)
    }

    fn words_of(blocks: &[Block]) -> Vec<String> {
        blocks.iter().flat_map(|b| b.lines.iter()).flat_map(|l| l.text.split_whitespace().map(str::to_string)).collect()
    }

    fn sorted(mut v: Vec<String>) -> Vec<String> {
        v.sort();
        v
    }

    fn order(blocks: &[Block]) -> Vec<Block> {
        reading_blocks(blocks, 10.0)
    }

    #[test]
    fn three_narrow_columns_are_read_one_after_another() {
        // gutters of 10 points; the blocks are given out of order
        let c1 = column("a", 40.0, 100.0, 14);
        let c2 = column("b", 140.0, 100.0, 14);
        let c3 = column("c", 240.0, 100.0, 14);
        let blocks = vec![c3.clone(), c1.clone(), c2.clone()];
        let got = order(&blocks);
        assert_eq!(got, vec![c1.clone(), c2.clone(), c3.clone()]);
        assert_eq!(sorted(words_of(&got)), sorted(words_of(&blocks)));
        // the same page as the page's own order (a, b, c)
        assert_eq!(order(&[c1.clone(), c2.clone(), c3.clone()]), vec![c1, c2, c3]);
    }

    #[test]
    fn a_two_page_spread_of_three_columns_each_is_read_column_by_column() {
        // The old code found only the spine, then sorted each page's blocks by height, mixing its three columns.
        let xs = [20.0, 120.0, 220.0, 380.0, 480.0, 580.0];
        let tags = ["a", "b", "c", "d", "e", "f"];
        // every column is two blocks (a paragraph and the next), listed bottom block first
        let mut blocks = Vec::new();
        for (x, t) in xs.iter().zip(tags) {
            blocks.push(column(t, *x, 200.0, 8));
            blocks.push(column(t, *x, 100.0, 8));
        }
        let got = order(&blocks);
        assert_eq!(got.len(), 12);
        for (i, b) in got.iter().enumerate() {
            let col = i / 2;
            assert!(b.x0 > xs[col] - 1.0 && b.x0 < xs[col] + 1.0, "block {i} is in column {col}: {b:?}");
            if i % 2 == 1 {
                assert!(b.y0 > got[i - 1].y0, "top to bottom inside a column");
            }
        }
        assert_eq!(sorted(words_of(&got)), sorted(words_of(&blocks)));
    }

    #[test]
    fn a_block_with_lines_in_several_columns_is_cut_into_columns() {
        // One block whose lines alternate between two columns (a text layer written row by row).
        let mut lines = Vec::new();
        for k in 0..12 {
            let y = 100.0 + 12.0 * k as f32;
            lines.push(ln(&format!("L{k}a L{k}b L{k}c"), 40.0, y, 130.0));
            lines.push(ln(&format!("R{k}a R{k}b R{k}c"), 160.0, y, 250.0));
        }
        let page = Block::from_lines(lines);
        let got = order(std::slice::from_ref(&page));
        assert_eq!(got.len(), 2);
        assert!(got[0].lines.iter().all(|l| l.text.starts_with('L')));
        assert!(got[1].lines.iter().all(|l| l.text.starts_with('R')));
        assert_eq!(sorted(words_of(&got)), sorted(words_of(&[page])));
    }

    #[test]
    fn a_full_width_heading_splits_the_columns_into_bands() {
        let top = [column("a", 40.0, 100.0, 5), column("b", 160.0, 100.0, 5)];
        let heading = Block::from_lines(vec![ln("A HEADING OVER BOTH COLUMNS", 40.0, 180.0, 250.0)]);
        let below = [column("c", 40.0, 210.0, 5), column("d", 160.0, 210.0, 5)];
        let mut blocks = vec![below[1].clone(), heading.clone(), top[1].clone(), below[0].clone(), top[0].clone()];
        let got = order(&blocks);
        assert_eq!(got, vec![top[0].clone(), top[1].clone(), heading.clone(), below[0].clone(), below[1].clone()]);
        blocks.reverse();
        assert_eq!(order(&blocks), got);
    }

    #[test]
    fn a_table_stays_row_by_row() {
        // three columns of short cells, five rows, the cells given column by column
        let cells = [["Item", "bolt", "nut", "washer", "screw"], ["Qty", "40", "250", "90", "12"], ["Cost", "1250", "875", "310", "4400"]];
        let mut blocks = Vec::new();
        for (c, col) in cells.iter().enumerate() {
            let lines = col.iter().enumerate().map(|(r, t)| ln(t, 40.0 + 100.0 * c as f32, 100.0 + 12.0 * r as f32, 40.0 + 100.0 * c as f32 + 6.0 * t.len() as f32)).collect();
            blocks.push(Block::from_lines(lines));
        }
        let got = order(&blocks);
        assert_eq!(got.len(), 5, "one block per row: {got:?}");
        let rows: Vec<String> = got.iter().map(|b| b.lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join(" ")).collect();
        assert_eq!(rows, vec!["Item Qty Cost", "bolt 40 1250", "nut 250 875", "washer 90 310", "screw 12 4400"]);
    }

    #[test]
    fn a_single_column_page_is_unchanged() {
        // ragged lines, a short last line, an indented paragraph start: no gutter
        let mut blocks = Vec::new();
        for p in 0..4 {
            let lines = (0..6).map(|k| ln(&format!("p{p}l{k} word word word word word"), if k == 0 { 56.0 } else { 40.0 }, 100.0 + 90.0 * p as f32 + 12.0 * k as f32, 160.0 + 20.0 * ((p + k) % 6) as f32)).collect();
            blocks.push(Block::from_lines(lines));
        }
        let got = order(&blocks);
        assert_eq!(got, blocks);
        // and two blocks only, a page too narrow for columns
        let small = vec![column("a", 40.0, 100.0, 6), column("b", 40.0, 200.0, 6)];
        assert_eq!(order(&small), small);
    }

    #[test]
    fn page_numbers_beside_a_list_are_not_a_column() {
        // a contents page: titles at the left, a thin column of page numbers at the right
        let mut lines = Vec::new();
        for k in 0..12 {
            let y = 100.0 + 12.0 * k as f32;
            lines.push(ln(&format!("Chapter {k} title of the chapter goes here"), 40.0, y, 200.0));
            lines.push(ln(&format!("{}", 10 + k), 330.0, y, 342.0));
        }
        let page = Block::from_lines(lines);
        assert_eq!(order(std::slice::from_ref(&page)), vec![page]);
    }

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
