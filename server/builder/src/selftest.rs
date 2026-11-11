//! Test PDFs the builder makes for itself: pages of ordinary text and pages that are only a 300 dpi picture of text (no text layer),
//! like a scan. Used by the OCR tests and by `cache-build selftest-pdfs`, which a release check runs on the target system (a
//! Raspberry Pi OS container) to prove that a scanned PDF comes out searchable there. Generated, never committed.

use std::io::Write;

const PAGE_W: f32 = 432.0;
const PAGE_H: f32 = 648.0;

/// One page of a test PDF.
pub enum Mixed {
    /// Lines of ordinary text (a text layer).
    Text(Vec<String>),
    /// The same kind of lines, but as a picture of the page with no text layer, like a scan.
    Scan(Vec<String>),
}

/// Five sentences of one of three topics (`topic` counts from 0 and wraps).
pub fn sample_lines(topic: usize) -> Vec<String> {
    let all = [
        ["Rainwater tanks should be covered to keep mosquitoes out.", "A clean reservoir supplies the village with drinking water.", "Irrigation channels carry the flood across the valley.", "Boil the water for one minute before you drink it.", "Wells are dug below the water table and lined with stone."],
        ["Fresh bread needs flour, water, salt and a warm kitchen.", "The baker kneads the dough until it feels smooth and elastic.", "Let the dough rise near the stove for about an hour.", "A hot oven gives the loaf a golden crust.", "Store the bread in a cloth bag to keep it soft."],
        ["Mountain trails cross the ridge above the lake.", "Hikers carry extra socks, a compass and a first aid kit.", "Storms arrive quickly in the afternoon, so start early.", "Follow the stream down to the old wooden bridge.", "Camp away from the water to protect the shoreline."],
    ];
    all[topic % 3].iter().map(|s| s.to_string()).collect()
}

fn esc(s: &str) -> String {
    s.chars().map(|c| if matches!(c, '(' | ')' | '\\') { format!("\\{c}") } else if c.is_ascii() { c.to_string() } else { "?".into() }).collect()
}

fn text_content(lines: &[String]) -> String {
    std::iter::once("BT /F1 14 Tf 16.8 TL 54 568 Td\n".to_string()).chain(lines.iter().map(|l| format!("({}) Tj T*\n", esc(l)))).chain(std::iter::once("ET\n".to_string())).collect()
}

/// The lines as a 300 dpi gray bitmap of the page (what a scanner makes): width, height, one byte per pixel.
fn scanned_bitmap(lines: &[String]) -> (u32, u32, Vec<u8>) {
    use mupdf::{Colorspace, Document, Matrix};
    let pdf = make_mixed_pdf(&[Mixed::Text(lines.to_vec())]);
    let doc = Document::from_bytes(&pdf, "application/pdf").expect("open the page to scan");
    let p = doc.load_page(0).expect("load the page to scan");
    let s = 300.0 / 72.0;
    let pix = p.to_pixmap(&Matrix::new_scale(s, s), &Colorspace::device_gray(), false, false).expect("draw the page to scan");
    assert_eq!(pix.n(), 1);
    // The picture must really hold text: a blank page would make every OCR test read nothing and look like an OCR failure.
    let dark = pix.samples().iter().filter(|&&v| v < 128).count() as f64 / pix.samples().len().max(1) as f64;
    eprintln!("selftest scan bitmap {}x{}: {:.2}% dark pixels", pix.width(), pix.height(), dark * 100.0);
    assert!(dark > 0.002 && dark < 0.5, "the generated scan is blank or solid ({:.3}% dark pixels): its text was not drawn", dark * 100.0);
    (pix.width(), pix.height(), pix.samples().to_vec())
}

/// A PDF of text pages and scanned pages, in order. A scanned page carries one Flate-compressed image and nothing else.
pub fn make_mixed_pdf(pages: &[Mixed]) -> Vec<u8> {
    let mut objs: Vec<Vec<u8>> = vec![b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(), Vec::new(), b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".to_vec()];
    let mut kids = Vec::new();
    for p in pages {
        let page_id = objs.len() + 1;
        kids.push(format!("{page_id} 0 R"));
        match p {
            Mixed::Text(lines) => {
                let content = text_content(lines);
                objs.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>", page_id + 1).into_bytes());
                objs.push(format!("<< /Length {} >>\nstream\n{}endstream", content.len(), content).into_bytes());
            }
            Mixed::Scan(lines) => {
                let (w, h, gray) = scanned_bitmap(lines);
                let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::fast());
                z.write_all(&gray).expect("compress the scan");
                let z = z.finish().expect("compress the scan");
                objs.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] /Resources << /XObject << /Im1 {} 0 R >> >> /Contents {} 0 R >>", page_id + 2, page_id + 1).into_bytes());
                let content = format!("q {PAGE_W} 0 0 {PAGE_H} 0 0 cm /Im1 Do Q\n");
                objs.push(format!("<< /Length {} >>\nstream\n{}endstream", content.len(), content).into_bytes());
                let mut img = format!("<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length {} >>\nstream\n", z.len()).into_bytes();
                img.extend_from_slice(&z);
                img.extend_from_slice(b"\nendstream");
                objs.push(img);
            }
        }
    }
    objs[1] = format!("<< /Type /Pages /Count {} /Kids [{}] >>", pages.len(), kids.join(" ")).into_bytes();
    let mut out: Vec<u8> = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n", i + 1).as_bytes());
        out.extend_from_slice(o);
        out.extend_from_slice(b"\nendobj\n");
    }
    let xref = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for o in offsets {
        out.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).as_bytes());
    out
}
