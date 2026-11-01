//! A tiny PDF writer for the tests (text pages with a standard font, and pages that are only a picture). Generated at test time,
//! so no PDF is committed.

const PAGE_W: f32 = 432.0;
const PAGE_H: f32 = 648.0;

/// One page: its lines of text, or a picture with no text layer.
pub struct Page {
    pub lines: Vec<String>,
    pub picture: bool,
}

/// A page of ordinary text: `words` words of `topic`-flavoured sentences, wrapped to 70 characters.
pub fn text_page(topic: &str, page_no: usize, words: usize) -> Page {
    let mut text = String::new();
    let mut n = 0;
    while text.split_whitespace().count() < words {
        n += 1;
        text.push_str(&format!("The {topic} note {page_no}-{n} explains how the {topic} works in the field and why it matters. "));
    }
    Page { lines: wrap(&text, 70), picture: false }
}

pub fn picture_page() -> Page {
    Page { lines: vec![], picture: true }
}

fn wrap(text: &str, max: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut cur = String::new();
    for w in text.split_whitespace() {
        if !cur.is_empty() && cur.len() + 1 + w.len() > max {
            lines.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(w);
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    lines
}

fn esc(s: &str) -> String {
    s.chars().map(|c| if matches!(c, '(' | ')' | '\\') { format!("\\{c}") } else if c.is_ascii() { c.to_string() } else { "?".into() }).collect()
}

/// A PDF of `pages`, with `title` in its metadata when given.
pub fn make_pdf(pages: &[Page], title: Option<&str>) -> Vec<u8> {
    let mut objs: Vec<String> = Vec::new();
    // 1 catalog, 2 pages (filled below), 3 font, 4 image, 5 info
    objs.push("<< /Type /Catalog /Pages 2 0 R >>".into());
    objs.push(String::new());
    objs.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".into());
    objs.push("<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 4 >>\nstream\n\u{1}\u{80}\u{80}\u{1}\nendstream".into());
    objs.push(format!("<< /Producer (cache tests) {} >>", title.map(|t| format!("/Title ({})", esc(t))).unwrap_or_default()));
    let mut kids = Vec::new();
    for p in pages {
        let page_id = objs.len() + 1;
        kids.push(format!("{page_id} 0 R"));
        objs.push(format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] /Resources << /Font << /F1 3 0 R >> /XObject << /Im1 4 0 R >> >> /Contents {} 0 R >>",
            page_id + 1
        ));
        let mut c = String::new();
        if p.picture {
            c.push_str("q 400 0 0 600 16 24 cm /Im1 Do Q\n");
        }
        for (i, l) in p.lines.iter().enumerate() {
            c.push_str(&format!("BT /F1 10 Tf 45 {} Td ({}) Tj ET\n", PAGE_H - 60.0 - i as f32 * 12.0, esc(l)));
        }
        objs.push(format!("<< /Length {} >>\nstream\n{}endstream", c.len(), c));
    }
    objs[1] = format!("<< /Type /Pages /Count {} /Kids [{}] >>", pages.len(), kids.join(" "));
    let mut out: Vec<u8> = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        let bytes: Vec<u8> = o.chars().map(|c| c as u32 as u8).collect();
        out.extend_from_slice(format!("{} 0 obj\n", i + 1).as_bytes());
        out.extend_from_slice(&bytes);
        out.extend_from_slice(b"\nendobj\n");
    }
    let xref = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for o in offsets {
        out.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R /Info 5 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).as_bytes());
    out
}

/// A book of `n` text pages about `topic`.
pub fn book(topic: &str, n: usize, title: Option<&str>) -> Vec<u8> {
    let pages: Vec<Page> = (1..=n).map(|i| text_page(topic, i, 120)).collect();
    make_pdf(&pages, title)
}
