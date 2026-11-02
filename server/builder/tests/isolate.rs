//! The crash-proof reader: a PDF read by a child process (the real `cache-build extract-pdf`) gives exactly what an in-process read
//! gives, and a child that crashes, hangs or exits badly fails that one PDF with a plain reason while the test process carries on.

mod common;

use cache_builder::extract::extract_pdf;
use cache_builder::isolate::{ChildExtractor, CRASH_MSG, TIMEOUT_MSG};
use common::*;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn extractor(tag: &str) -> (ChildExtractor, PathBuf) {
    let tmp = std::env::temp_dir().join(format!("cache-isolate-{tag}-{}", std::process::id()));
    let mut e = ChildExtractor::current_exe(tmp.clone());
    e.exe = PathBuf::from(env!("CARGO_BIN_EXE_cache-build"));
    (e, tmp)
}

fn sample() -> Vec<u8> {
    let mut a = Page::new();
    a.line(54.0, 40.0, 14.0, Font::Bold, "Chapter one: water");
    a.block(54.0, 80.0, 10.0, Font::Regular, &["Wells are dug below the water table.", "A lined well keeps the walls from caving in."]);
    a.line(54.0, 140.0, 10.0, Font::Italic, "Boil water before drinking it (ffi: office, flow).");
    let mut b = Page::new();
    b.picture = true;
    let mut c = Page::new();
    c.block(54.0, 80.0, 10.0, Font::Regular, &["Tanks store rain water.", "Cover them to keep the mosquitoes out."]);
    make_pdf(&[a, b, c], Some("Water systems"))
}

fn gone(tmp: &Path) {
    // nothing is left behind, however the child ended
    let left = std::fs::read_dir(tmp).map(|d| d.count()).unwrap_or(0);
    assert_eq!(left, 0, "work folders left in {}", tmp.display());
    let _ = std::fs::remove_dir_all(tmp);
}

#[test]
fn the_child_gives_exactly_what_an_in_process_read_gives() {
    let (e, tmp) = extractor("same");
    let pdf = sample();
    let direct = extract_pdf(&pdf).unwrap();
    let via = e.extract(&pdf).unwrap();
    assert_eq!(via, direct);
    assert_eq!(via.to_wire(), direct.to_wire(), "byte for byte");
    assert_eq!(via.title.as_deref(), Some("Water systems"));
    assert_eq!(via.pages.len(), 3);
    gone(&tmp);
}

#[test]
fn the_wire_format_round_trips_and_refuses_damage() {
    let direct = extract_pdf(&sample()).unwrap();
    let wire = direct.to_wire();
    assert_eq!(cache_builder::extract::Extracted::from_wire(&wire).unwrap(), direct);
    for cut in [0, 3, 10, wire.len() / 2, wire.len() - 1] {
        assert!(cache_builder::extract::Extracted::from_wire(&wire[..cut]).is_err(), "cut at {cut}");
    }
    let mut dated = direct.clone();
    dated.year = Some(2019);
    dated.ppi = Some(300);
    assert_eq!(cache_builder::extract::Extracted::from_wire(&dated.to_wire()).unwrap(), dated);
    let mut more = wire.clone();
    more.push(0);
    assert!(cache_builder::extract::Extracted::from_wire(&more).is_err());
}

#[test]
fn an_ordinary_error_comes_back_with_the_same_words_as_in_process() {
    let (e, tmp) = extractor("err");
    let bad = b"%PDF-1.4\nnot really".to_vec();
    let direct = extract_pdf(&bad);
    assert_eq!(e.extract(&bad), direct);
    gone(&tmp);
}

#[test]
fn a_child_that_crashes_fails_that_pdf_only() {
    for fault in ["segv", "abort", "exit"] {
        let (mut e, tmp) = extractor(fault);
        e.fault = Some(fault.to_string());
        assert_eq!(e.extract(&sample()).unwrap_err().0, CRASH_MSG, "{fault}");
        gone(&tmp);
        // the same extractor, without the fault, reads the next PDF
        e.fault = None;
        assert!(e.extract(&sample()).is_ok());
        gone(&tmp);
    }
}

#[test]
fn a_child_that_hangs_is_stopped_at_the_time_limit() {
    let (mut e, tmp) = extractor("hang");
    e.fault = Some("hang".into());
    e.timeout = Some(Duration::from_millis(500));
    let t = Instant::now();
    assert_eq!(e.extract(&sample()).unwrap_err().0, TIMEOUT_MSG);
    assert!(t.elapsed() < Duration::from_secs(10));
    gone(&tmp);
}

#[test]
fn the_time_and_memory_limits_scale_with_the_file() {
    let (e, _) = extractor("limits");
    assert_eq!(e.timeout_for(1 << 20), Duration::from_secs(135));
    assert!(e.timeout_for(500 << 20) > e.timeout_for(5 << 20));
    assert_eq!(e.timeout_for(usize::MAX >> 4), Duration::from_secs(3600));
    assert!(e.memory_for(5 << 20) > (2u64 << 30));
    assert_eq!(e.memory_for(usize::MAX >> 4), 8u64 << 30);
}
