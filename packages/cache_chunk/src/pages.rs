//! The pages-only entry: plain text per page (no layout information) in, pieces with page labels out.

use crate::text::{join_lines, normalize_ws};
use crate::{chunk, Element};
use std::collections::HashMap;

/// One page of extracted text.
#[derive(Debug, Clone, PartialEq)]
pub struct PageInput {
    /// 0-based PDF page index.
    pub index: usize,
    /// The printed page label ("iv", "17"); may be empty, in which case the piece's `page` is the 1-based PDF page.
    pub label: String,
    pub text: String,
}

/// A heading found by the caller, placed at the start of the PDF page `index` (0-based).
#[derive(Debug, Clone, PartialEq)]
pub struct PageHeading {
    pub level: u8,
    pub text: String,
    pub index: usize,
}

/// One piece, in the shape the on-device index stores.
#[derive(Debug, Clone, PartialEq)]
pub struct PdfPiece {
    /// Position of the piece in the document, from 0.
    pub i: u32,
    pub text: String,
    /// Printed page label of the piece's first word (the 1-based PDF page as text when the page has no label).
    pub page: String,
    /// 1-based PDF page of the piece's first word.
    pub pdf_page: usize,
    /// 1-based PDF page of its last word; `None` when it does not cross a page break.
    pub pdf_page_end: Option<usize>,
    /// The headings above it, outermost first (empty without headings).
    pub heading_path: Vec<String>,
}

/// The result of [`chunk_pages`].
#[derive(Debug, Clone, PartialEq)]
pub struct PagesChunked {
    pub pieces: Vec<PdfPiece>,
    /// 0-based indexes of pages with no text at all, in input order.
    pub empty_pages: Vec<usize>,
}

/// Chunk plain page text without headings.
pub fn chunk_pages(pages: &[PageInput]) -> PagesChunked {
    chunk_pages_with_headings(pages, &[])
}

/// Chunk plain page text. A page's text is split into paragraphs at blank lines; the lines of a paragraph are joined
/// into flowing text (whitespace normalised, line-end hyphenation made whole). `headings` are placed before the text of
/// their page, in the order given.
pub fn chunk_pages_with_headings(pages: &[PageInput], headings: &[PageHeading]) -> PagesChunked {
    let mut order: Vec<&PageInput> = pages.iter().collect();
    order.sort_by_key(|p| p.index);
    let mut elements: Vec<Element> = Vec::new();
    let mut empty_pages: Vec<usize> = Vec::new();
    let mut labels: HashMap<usize, &str> = HashMap::new();
    for p in &order {
        labels.insert(p.index, p.label.as_str());
        for h in headings.iter().filter(|h| h.index == p.index) {
            let text = normalize_ws(&h.text);
            if !text.is_empty() {
                elements.push(Element::Heading { level: h.level, text, page: p.index });
            }
        }
        let mut any = false;
        let mut lines: Vec<&str> = Vec::new();
        let flush = |lines: &mut Vec<&str>, any: &mut bool, elements: &mut Vec<Element>| {
            let text = join_lines(lines.drain(..));
            if !text.is_empty() {
                *any = true;
                elements.push(Element::Para { text, page: p.index, bullet: false, aside: false });
            }
        };
        for line in p.text.lines() {
            if line.trim().is_empty() {
                flush(&mut lines, &mut any, &mut elements);
            } else {
                lines.push(line);
            }
        }
        flush(&mut lines, &mut any, &mut elements);
        if !any {
            empty_pages.push(p.index);
        }
    }
    let label_of = |idx: usize| -> String {
        match labels.get(&idx) {
            Some(l) if !l.is_empty() => (*l).to_string(),
            _ => (idx + 1).to_string(),
        }
    };
    let pieces = chunk(&elements)
        .into_iter()
        .map(|p| PdfPiece {
            i: p.index,
            page: label_of(p.page),
            pdf_page: p.page + 1,
            pdf_page_end: (p.page_end != p.page).then_some(p.page_end + 1),
            heading_path: p.heading_path,
            text: p.text,
        })
        .collect();
    PagesChunked { pieces, empty_pages }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(index: usize, label: &str, text: &str) -> PageInput {
        PageInput { index, label: label.into(), text: text.into() }
    }

    #[test]
    fn pages_only_maps_labels_and_pdf_pages() {
        let pages = vec![
            page(0, "", "   \n\n"),
            page(1, "iv", "First sentence here. The second sentence is cut,"),
            page(2, "v", "and continues on the next\npage. Third."),
            page(3, "", "A new page with its own sentence."),
        ];
        let r = chunk_pages(&pages);
        assert_eq!(r.empty_pages, vec![0]);
        assert_eq!(r.pieces.len(), 1);
        let p = &r.pieces[0];
        assert_eq!(p.i, 0);
        assert_eq!(p.page, "iv");
        assert_eq!((p.pdf_page, p.pdf_page_end), (2, Some(4)));
        assert!(p.heading_path.is_empty());
        assert!(p.text.starts_with("First sentence here. The second sentence is cut, and continues on the next page. Third."));
    }

    #[test]
    fn single_page_piece_has_no_page_end_and_label_falls_back_to_pdf_page() {
        let r = chunk_pages(&[page(4, "", "One whole sentence. Another one.")]);
        assert!(r.empty_pages.is_empty());
        assert_eq!(r.pieces.len(), 1);
        assert_eq!((r.pieces[0].page.as_str(), r.pieces[0].pdf_page, r.pieces[0].pdf_page_end), ("5", 5, None));
    }

    #[test]
    fn blank_lines_split_paragraphs_and_hyphens_are_rejoined() {
        let r = chunk_pages(&[page(0, "1", "the informa-\ntion about it.\n\nNext paragraph here.")]);
        assert_eq!(r.pieces[0].text, "the information about it. Next paragraph here.");
    }

    #[test]
    fn pages_only_matches_chunk_on_the_same_elements() {
        let sentence = |i: usize| format!("S{i} w1 w2 w3 w4 w5 w6 w7 w8 w9.");
        let text0 = (0..40).map(sentence).collect::<Vec<_>>().join(" ");
        let text1 = (40..90).map(sentence).collect::<Vec<_>>().join(" ");
        let r = chunk_pages(&[page(0, "a", &text0), page(1, "b", &text1)]);
        let direct = chunk(&[
            Element::Para { text: text0.clone(), page: 0, bullet: false, aside: false },
            Element::Para { text: text1.clone(), page: 1, bullet: false, aside: false },
        ]);
        assert_eq!(r.pieces.len(), direct.len());
        for (a, b) in r.pieces.iter().zip(&direct) {
            assert_eq!(a.text, b.text);
            assert_eq!(a.pdf_page, b.page + 1);
            assert_eq!(a.pdf_page_end, (b.page_end != b.page).then_some(b.page_end + 1));
            assert_eq!(a.page, if b.page == 0 { "a" } else { "b" });
        }
        assert!(r.pieces.iter().any(|p| p.pdf_page_end.is_some()) || r.pieces.iter().any(|p| p.pdf_page == 2));
    }

    #[test]
    fn headings_open_sections_on_their_page() {
        let body = |n: usize| (0..n).map(|i| format!("S{i} a b c d e f g h i.")).collect::<Vec<_>>().join(" ");
        let pages = vec![page(0, "1", &body(30)), page(1, "2", &body(30))];
        let heads = vec![
            PageHeading { level: 1, text: "Chapter I".into(), index: 0 },
            PageHeading { level: 1, text: "Chapter II".into(), index: 1 },
        ];
        let r = chunk_pages_with_headings(&pages, &heads);
        assert!(r.pieces.iter().all(|p| p.heading_path.len() == 1));
        let second: Vec<_> = r.pieces.iter().filter(|p| p.heading_path[0] == "Chapter II").collect();
        assert!(!second.is_empty() && second.iter().all(|p| p.pdf_page == 2));
        assert!(second[0].text.starts_with("S0 "));
        assert!(r.pieces.iter().filter(|p| p.heading_path[0] == "Chapter I").all(|p| p.pdf_page_end.is_none()));
    }
}
