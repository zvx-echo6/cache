//! Reading order of multi-column pages, on PDFs generated at test time. The tests give the words of a page as numbered
//! tokens ("00000", "00001", ...) in the order a reader reads them, so the output must carry the numbers in order, and
//! every number exactly once. Five-digit tokens are all the same width in Helvetica, so the columns have exact widths
//! and gutters.

mod common;

use cache_builder::chunk::chunk;
use cache_builder::extract::extract_pdf;
use cache_builder::layout::{layout, Element};
use common::*;

/// The words of the page in the order the layout reads them (headings and paragraphs).
fn words(pdf: &[u8]) -> Vec<String> {
    let lay = layout(&extract_pdf(pdf).unwrap());
    lay.elements
        .iter()
        .flat_map(|e| match e {
            Element::Heading { text, .. } => text.split_whitespace().map(str::to_string).collect::<Vec<_>>(),
            Element::Para { text, .. } => text.split_whitespace().map(str::to_string).collect::<Vec<_>>(),
        })
        .collect()
}

fn token(n: usize) -> String {
    format!("{n:05}")
}

/// `n` lines of `per` tokens each, numbered from `first`, written as a column at `x`, the first line `y` from the top.
fn column(p: &mut Page, x: f32, y: f32, first: usize, lines: usize, per: usize) {
    for k in 0..lines {
        let t: Vec<String> = (0..per).map(|j| token(first + k * per + j)).collect();
        p.line(x, y + 12.0 * k as f32, 10.0, Font::Regular, &t.join(" "));
    }
}

fn expected(from: usize, to: usize) -> Vec<String> {
    (from..to).map(token).collect()
}

#[test]
fn three_narrow_columns_are_read_one_after_another() {
    // columns 98 points apart and 89 wide (a gutter of 9), the text layer in column order
    let mut p = Page::new();
    for c in 0..3 {
        column(&mut p, 30.0 + 98.0 * c as f32, 100.0, c * 42, 14, 3);
    }
    let pdf = make_pdf(&[p], None);
    assert_eq!(words(&pdf), expected(0, 126));
    // the passages carry the numbers in order too, and every number is in some passage
    let lay = layout(&extract_pdf(&pdf).unwrap());
    let mut seen = std::collections::BTreeSet::new();
    for piece in chunk(&lay.elements) {
        let nums: Vec<usize> = piece.text.split_whitespace().map(|w| w.parse().unwrap()).collect();
        assert!(nums.windows(2).all(|w| w[0] < w[1]), "a passage is out of order: {}", piece.text);
        seen.extend(nums);
    }
    assert_eq!(seen.len(), 126);
}

#[test]
fn a_spread_of_two_pages_with_three_narrow_columns_each() {
    // six columns of two tokens: the spine is the widest gutter, the others are 9 points
    let mut p = Page::new();
    let xs = [14.0, 82.0, 150.0, 234.0, 302.0, 370.0];
    for (c, x) in xs.iter().enumerate() {
        column(&mut p, *x, 100.0, c * 28, 14, 2);
    }
    let pdf = make_pdf(&[p], None);
    assert_eq!(words(&pdf), expected(0, 168));
}

#[test]
fn a_text_layer_written_row_by_row_is_read_by_column() {
    // two columns 110 apart; the lines are written left, right, left, right, ...
    let mut p = Page::new();
    for k in 0..14 {
        let l: Vec<String> = (0..3).map(|j| token(k * 3 + j)).collect();
        let r: Vec<String> = (0..3).map(|j| token(42 + k * 3 + j)).collect();
        p.line(40.0, 100.0 + 12.0 * k as f32, 10.0, Font::Regular, &l.join(" "));
        p.line(150.0, 100.0 + 12.0 * k as f32, 10.0, Font::Regular, &r.join(" "));
    }
    let pdf = make_pdf(&[p], None);
    assert_eq!(words(&pdf), expected(0, 84));
}

#[test]
fn a_full_width_heading_ends_a_band() {
    let mut p = Page::new();
    column(&mut p, 40.0, 100.0, 0, 6, 3);
    column(&mut p, 150.0, 100.0, 18, 6, 3);
    p.line(40.0, 190.0, 14.0, Font::Bold, "WIDE HEADING OVER BOTH COLUMNS");
    column(&mut p, 40.0, 220.0, 36, 6, 3);
    column(&mut p, 150.0, 220.0, 54, 6, 3);
    let pdf = make_pdf(&[p], None);
    let mut want = expected(0, 36);
    want.extend(["WIDE", "HEADING", "OVER", "BOTH", "COLUMNS"].map(str::to_string));
    want.extend(expected(36, 72));
    assert_eq!(words(&pdf), want);
}

#[test]
fn a_table_stays_row_by_row() {
    // three columns of short cells written column by column; the rows are what reads
    let rows = [
        ["Name", "Quantity", "Cost"],
        ["bolt", "forty", "cheap"],
        ["washer", "ninety", "cheaper"],
        ["screw", "twelve", "dearer"],
        ["rivet", "seventy", "costly"],
        ["spring", "sixteen", "pricey"],
        ["anchor", "eighteen", "steep"],
    ];
    let mut p = Page::new();
    for c in 0..3 {
        for (r, row) in rows.iter().enumerate() {
            p.line(40.0 + 100.0 * c as f32, 100.0 + 12.0 * r as f32, 10.0, Font::Regular, row[c]);
        }
    }
    let pdf = make_pdf(&[p], None);
    let want: Vec<String> = rows.iter().flatten().map(|s| s.to_string()).collect();
    assert_eq!(words(&pdf), want);
}

#[test]
fn a_single_column_page_is_read_top_to_bottom() {
    let mut p = Page::new();
    let mut n = 0;
    for k in 0..20 {
        let per = 3 + (k * 5) % 7;
        let t: Vec<String> = (0..per).map(|j| token(n + j)).collect();
        n += per;
        p.line(40.0, 100.0 + 12.0 * k as f32, 10.0, Font::Regular, &t.join(" "));
    }
    let pdf = make_pdf(&[p], None);
    assert_eq!(words(&pdf), expected(0, n));
}
