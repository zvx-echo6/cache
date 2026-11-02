//! PDF compression: lossless output renders pixel-identical, a file that cannot get smaller is kept, a page that would fall below the
//! quality floor keeps the pictures, and a crash in the compressing child fails that book only.

mod common;

use cache_builder::compress::{compress_pdf, psnr, Compression, Level, Preset, CHECK_DPI, PSNR_IDENTICAL};
use cache_builder::isolate::{ChildExtractor, CRASH_MSG};
use common::*;
use mupdf::{Colorspace, Document, Matrix};
use std::path::PathBuf;

/// A little deterministic generator (no rand crate).
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u8 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (self.0 >> 56) as u8
    }
}

/// A PDF with one page per picture: each picture is raw (uncompressed) 8-bit samples drawn over `inches` square, with a line of text.
/// `noise` is 0 for a smooth photo-like picture, up to 255 for pure noise.
fn picture_pdf(pictures: usize, px: usize, inches: f32, rgb: bool, noise: u8) -> Vec<u8> {
    let n = if rgb { 3 } else { 1 };
    let mut rng = Lcg(7);
    let mut objs: Vec<Vec<u8>> = vec![b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(), vec![], b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_vec()];
    let mut kids = Vec::new();
    for k in 0..pictures {
        let img_id = objs.len() + 1;
        let mut data = Vec::with_capacity(px * px * n);
        for y in 0..px {
            for x in 0..px {
                for c in 0..n {
                    let base = ((x * 3 + y * 2 + c * 40 + k * 11) % 256) as i32 / 2 + 60 + ((x / 16 + y / 16) % 2) as i32 * 20;
                    let jitter = if noise == 0 { 0 } else { (rng.next() as i32 * noise as i32 / 255) - noise as i32 / 2 };
                    data.push((base + jitter).clamp(0, 255) as u8);
                }
            }
        }
        let mut o = format!(
            "<< /Type /XObject /Subtype /Image /Width {px} /Height {px} /ColorSpace /{} /BitsPerComponent 8 /Length {} >>\nstream\n",
            if rgb { "DeviceRGB" } else { "DeviceGray" },
            data.len()
        )
        .into_bytes();
        o.extend_from_slice(&data);
        o.extend_from_slice(b"\nendstream");
        objs.push(o);
        let content_id = objs.len() + 2;
        let page_id = objs.len() + 1;
        let pts = inches * 72.0;
        objs.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {} {}] /Resources << /Font << /F1 3 0 R >> /XObject << /Im1 {img_id} 0 R >> >> /Contents {content_id} 0 R >>", pts + 40.0, pts + 80.0).into_bytes());
        let c = format!("q {pts} 0 0 {pts} 20 20 cm /Im1 Do Q BT /F1 14 Tf 20 {} Td (Page {} of the test book) Tj ET\n", pts + 40.0, k + 1);
        objs.push(format!("<< /Length {} >>\nstream\n{c}endstream", c.len()).into_bytes());
        kids.push(format!("{page_id} 0 R"));
    }
    objs[1] = format!("<< /Type /Pages /Count {pictures} /Kids [{}] >>", kids.join(" ")).into_bytes();
    let mut out = b"%PDF-1.4\n".to_vec();
    let mut offs = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offs.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n", i + 1).as_bytes());
        out.extend_from_slice(o);
        out.extend_from_slice(b"\nendobj\n");
    }
    let x = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for o in offs {
        out.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n", objs.len() + 1).as_bytes());
    out
}

fn pages(pdf: &[u8]) -> Vec<mupdf::Pixmap> {
    let d = Document::from_bytes(pdf, "application/pdf").unwrap();
    let s = CHECK_DPI / 72.0;
    (0..d.page_count().unwrap()).map(|i| d.load_page(i).unwrap().to_pixmap(&Matrix::new_scale(s, s), &Colorspace::device_rgb(), false, true).unwrap()).collect()
}

fn has(pdf: &[u8], what: &[u8]) -> bool {
    pdf.windows(what.len()).any(|w| w == what)
}

#[test]
fn lossless_output_is_smaller_has_object_streams_and_renders_identically() {
    let pdf = picture_pdf(3, 300, 3.0, true, 0);
    let (out, r) = compress_pdf(&pdf, &Compression::LOSSLESS);
    assert!(!r.kept_original, "{:?}", r.kept_reason);
    assert!(out.len() < pdf.len() / 2, "{} -> {}", pdf.len(), out.len());
    assert_eq!((r.original_size, r.stored_size), (pdf.len() as u64, out.len() as u64));
    assert_eq!((r.level.as_str(), r.preset.as_deref()), ("lossless", None));
    assert_eq!(r.psnr_min, Some(PSNR_IDENTICAL));
    assert!(has(&out, b"/ObjStm"), "object streams");
    let (a, b) = (pages(&pdf), pages(&out));
    assert_eq!(a.len(), b.len());
    for (x, y) in a.iter().zip(&b) {
        assert_eq!(x.samples(), y.samples(), "pixel-identical");
    }
}

#[test]
fn off_stores_the_file_as_it_is() {
    let pdf = picture_pdf(1, 100, 1.0, false, 0);
    let (out, r) = compress_pdf(&pdf, &Compression::OFF);
    assert_eq!(out, pdf);
    assert!(r.kept_original);
    assert_eq!(r.level, "off");
}

#[test]
fn a_file_that_cannot_get_smaller_is_kept_as_it_is() {
    // random bytes do not deflate, so nothing is saved
    let pdf = picture_pdf(1, 200, 2.0, false, 255);
    let (once, _) = compress_pdf(&pdf, &Compression::LOSSLESS);
    let (out, r) = compress_pdf(&once, &Compression::LOSSLESS); // already as small as it gets
    assert!(r.kept_original);
    assert_eq!(out, once);
    assert_eq!(r.stored_size, r.original_size);
    assert!(r.kept_reason.unwrap().contains("smaller"));
    // a damaged file is kept too, with the reason
    let (bad, r) = compress_pdf(b"%PDF-1.4\nnot really", &Compression::LOSSLESS);
    assert_eq!(bad, b"%PDF-1.4\nnot really");
    assert!(r.kept_original && r.kept_reason.is_some());
}

#[test]
fn smaller_scans_recompresses_and_downsamples_the_pictures_within_the_floor() {
    // 600 px over 2 inches is 300 pixels per inch, finer than every preset's threshold
    let pdf = picture_pdf(2, 600, 2.0, true, 12);
    for preset in [Preset::High, Preset::Balanced, Preset::Smallest] {
        let c = Compression { level: Level::SmallerScans, preset: Some(preset) };
        let (out, r) = compress_pdf(&pdf, &c);
        assert!(!r.kept_original, "{preset:?}: {:?}", r.kept_reason);
        assert!(r.kept_reason.is_none(), "{preset:?}: no fallback: {:?}", r.kept_reason);
        assert!(out.len() < pdf.len() / 5, "{preset:?}: {} -> {}", pdf.len(), out.len());
        assert_eq!(r.preset.as_deref(), Some(preset.name()));
        assert!(r.psnr_min.unwrap() >= preset.params().psnr_floor, "{preset:?}: {:?}", r.psnr_min);
        assert!(r.psnr_min.unwrap() < PSNR_IDENTICAL, "{preset:?}: the pictures were changed");
        assert_eq!(pages(&out).len(), 2);
    }
    // the default preset is balanced
    let (_, r) = compress_pdf(&pdf, &Compression { level: Level::SmallerScans, preset: None });
    assert_eq!(r.preset.as_deref(), Some("balanced"));
}

#[test]
fn a_page_below_the_floor_keeps_the_pictures_and_says_why() {
    // pure noise drawn at 100 pixels per inch (the check's own resolution): JPEG at the smallest preset cannot get near the floor
    let pdf = picture_pdf(1, 400, 4.0, true, 255);
    let c = Compression { level: Level::SmallerScans, preset: Some(Preset::Smallest) };
    let (out, r) = compress_pdf(&pdf, &c);
    let why = r.kept_reason.clone().unwrap_or_default();
    assert!(why.contains("floor"), "{why}");
    assert!(!r.kept_original, "falls back to the lossless result");
    // what is kept is lossless: identical pages
    for (x, y) in pages(&pdf).iter().zip(&pages(&out)) {
        assert_eq!(x.samples(), y.samples());
    }
    assert_eq!(r.psnr_min, Some(PSNR_IDENTICAL));
}

#[test]
fn psnr_is_infinite_for_equal_pages_and_falls_with_damage() {
    let a = vec![100u8; 1000];
    assert_eq!(psnr(&a, &a), PSNR_IDENTICAL);
    let mut b = a.clone();
    b[0] = 110;
    let p = psnr(&a, &b);
    assert!(p > 40.0 && p < PSNR_IDENTICAL);
}

#[test]
fn compression_settings_parse() {
    assert_eq!(Compression::parse("off").unwrap(), Compression::OFF);
    assert_eq!(Compression::parse("lossless").unwrap(), Compression::LOSSLESS);
    assert_eq!(Compression::parse("smaller_scans:smallest").unwrap(), Compression { level: Level::SmallerScans, preset: Some(Preset::Smallest) });
    assert_eq!(Compression::parse("smaller_scans").unwrap().effective_preset(), Some(Preset::Balanced));
    assert!(Compression::parse("lossless:high").is_err());
    assert!(Compression::parse("smaller_scans:tiny").is_err());
    assert!(Compression::parse("zip").is_err());
}

fn child(tag: &str) -> (ChildExtractor, PathBuf) {
    let tmp = std::env::temp_dir().join(format!("cache-compress-{tag}-{}", std::process::id()));
    let mut e = ChildExtractor::current_exe(tmp.clone());
    e.exe = PathBuf::from(env!("CARGO_BIN_EXE_cache-build"));
    (e, tmp)
}

#[test]
fn the_child_gives_what_an_in_process_compression_gives() {
    let (e, tmp) = child("same");
    let pdf = picture_pdf(2, 300, 3.0, true, 0);
    let (out, r) = e.compress(&pdf, &Compression::LOSSLESS).unwrap();
    let (direct, dr) = compress_pdf(&pdf, &Compression::LOSSLESS);
    assert_eq!(out, direct);
    assert_eq!(r, dr);
    assert_eq!(std::fs::read_dir(&tmp).map(|d| d.count()).unwrap_or(0), 0, "no work folders left");
    let _ = std::fs::remove_dir_all(tmp);
}

#[test]
fn a_crash_while_compressing_fails_that_book_only() {
    for fault in ["segv", "abort"] {
        let (mut e, tmp) = child(fault);
        e.fault = Some(fault.to_string());
        let pdf = picture_pdf(1, 100, 1.0, false, 0);
        assert_eq!(e.compress(&pdf, &Compression::LOSSLESS).unwrap_err().0, CRASH_MSG, "{fault}");
        // the same child setup carries on with the next book
        e.fault = None;
        assert!(e.compress(&pdf, &Compression::LOSSLESS).is_ok());
        let _ = std::fs::remove_dir_all(tmp);
    }
}

#[test]
fn text_pages_are_not_changed_by_smaller_scans() {
    // a text-only PDF has no pictures: the lossy level gives what lossless gives, and the words are still there
    let mut a = Page::new();
    a.block(54.0, 80.0, 10.0, Font::Regular, &["Wells are dug below the water table.", "A lined well keeps the walls from caving in."]);
    let pdf = make_pdf(&[a.clone(), a.clone(), a], Some("Wells"));
    let (out, r) = compress_pdf(&pdf, &Compression { level: Level::SmallerScans, preset: Some(Preset::Smallest) });
    let text = |b: &[u8]| cache_builder::extract::extract_pdf(b).unwrap().pages.iter().map(|p| p.text_chars()).sum::<usize>();
    assert_eq!(text(&out), text(&pdf), "{:?}", r.kept_reason);
}
