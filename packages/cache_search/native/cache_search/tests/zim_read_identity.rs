//! `cs_read` and `cs_zim_get` through libzim's archive against the `zim` crate reader they replaced, on real ZIMs
//! (DESIGN.md "Memory budget": one archive per ZIM). Both readers run side by side in this one build: `ZimSource::get_crate`
//! is the old path (kept for builds without libzim and for this test), `ZimSource::get` / `Handle::read` / `Handle::zim_get`
//! are what the library uses.
//!
//! `#[ignore]`d; needs `CS_TEST_ZIM_DIR` (the folder with the ZIMs) and a build with the `xapian` feature on Windows or
//! Android. Run: `cargo test --release -p cache_search --test zim_read_identity -- --ignored --nocapture`. `CS_IDENTITY_N` sets
//! how many articles are sampled per ZIM (default 10). Every difference is printed; the test fails if there is one.

#![cfg(zimx)]

use cache_search::error::Result;
use cache_search::handle::Handle;
use cache_search::search::read_zim_entry;
use cache_search::zimsrc::{format_address, RawEntry, ZimSource};
use serde_json::json;
use std::path::PathBuf;
use zim::{MimeType, Namespace, Target};

/// ZIMs tested, by file-name prefix: Wikipedia maxi, wikimed (the medicine ZIM), ready.gov, iFixit, NHS, Appropedia, armypubs.
const PREFIXES: [&str; 7] = [
    "wikipedia_en_all_maxi",
    "wikipedia_en_medicine",
    "www.ready.gov",
    "ifixit",
    "nhs.uk",
    "appropedia",
    "armypubs",
];

fn same_err(a: &cache_search::error::Error, b: &cache_search::error::Error) -> bool {
    a.code == b.code && a.message == b.message
}

/// Compare two results of the same lookup; `Err(description)` on a difference.
fn compare_entries(old: &Result<RawEntry>, new: &Result<RawEntry>) -> std::result::Result<&'static str, String> {
    match (old, new) {
        (Ok(a), Ok(b)) => {
            if a.bytes != b.bytes {
                Err(format!("bytes differ: {} vs {} bytes", a.bytes.len(), b.bytes.len()))
            } else if a.mime != b.mime {
                Err(format!("mime differs: {:?} vs {:?}", a.mime, b.mime))
            } else if a.path != b.path {
                Err(format!("path differs: {:?} vs {:?}", a.path, b.path))
            } else if a.title != b.title {
                Err(format!("title differs: {:?} vs {:?}", a.title, b.title))
            } else {
                Ok("found")
            }
        }
        (Err(a), Err(b)) if same_err(a, b) => Ok("same error"),
        (Err(a), Err(b)) => Err(format!("both fail, differently: {:?} {:?} vs {:?} {:?}", a.code, a.message, b.code, b.message)),
        (Ok(a), Err(b)) => Err(format!("old found {:?} ({} bytes), new fails: {:?} {}", a.path, a.bytes.len(), b.code, b.message)),
        (Err(a), Ok(b)) => Err(format!("old fails ({:?} {}), new found {:?} ({} bytes)", a.code, a.message, b.path, b.bytes.len())),
    }
}

fn compare_text(old: &Result<String>, new: &Result<String>) -> std::result::Result<&'static str, String> {
    match (old, new) {
        (Ok(a), Ok(b)) if a == b => Ok("same json"),
        (Ok(a), Ok(b)) => Err(format!("read JSON differs ({} vs {} bytes)", a.len(), b.len())),
        (Err(a), Err(b)) if same_err(a, b) => Ok("same error"),
        (Err(a), Err(b)) => Err(format!("read fails differently: {:?} {} vs {:?} {}", a.code, a.message, b.code, b.message)),
        (Ok(_), Err(b)) => Err(format!("old read ok, new fails: {:?} {}", b.code, b.message)),
        (Err(a), Ok(_)) => Err(format!("old read fails ({:?} {}), new ok", a.code, a.message)),
    }
}

/// What kind of entry a sample is (for the report and so every kind is covered).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Article,
    Redirect,
    Image,
    Layout,
    Other,
}

struct Sample {
    path: String,
    kind: Kind,
}

/// Sample entries spread over the ZIM with the crate reader: `n_art` HTML articles, and (as far as the ZIM has them) two
/// redirects, two images, one CSS/JS file and one other type.
fn sample(src: &ZimSource, n_art: usize) -> Vec<Sample> {
    let zim = src.zim().expect("crate reader");
    let total = zim.header.article_count as u64;
    let mut out: Vec<Sample> = Vec::new();
    let want = |k: Kind, out: &Vec<Sample>| {
        let have = out.iter().filter(|s| s.kind == k).count();
        match k {
            Kind::Article => have < n_art,
            Kind::Redirect | Kind::Image => have < 2,
            Kind::Layout | Kind::Other => have < 1,
        }
    };
    // 24 start points over the first 90% of the entries (the user content comes first; indexes and metadata last), each
    // scanned forward a few thousand entries
    let starts = 24u64;
    for s in 0..starts {
        let mut idx = (total * 9 / 10) * s / starts + s * 101 % 997;
        for _ in 0..3000 {
            if idx >= total {
                break;
            }
            idx += 1;
            let Ok(e) = zim.get_by_url_index(idx as u32) else { continue };
            if !matches!(e.namespace, Namespace::UserContent | Namespace::Articles | Namespace::ImagesFile | Namespace::Layout) {
                continue;
            }
            let kind = match (&e.target, &e.mime_type) {
                (Some(Target::Redirect(_)), _) => Kind::Redirect,
                (_, MimeType::Type(m)) if m.starts_with("text/html") => Kind::Article,
                (_, MimeType::Type(m)) if m.starts_with("image/") => Kind::Image,
                (_, MimeType::Type(m)) if m.starts_with("text/css") || m.contains("javascript") => Kind::Layout,
                _ => Kind::Other,
            };
            if want(kind, &out) && !out.iter().any(|x| x.path == e.url) {
                out.push(Sample { path: e.url.clone(), kind });
                break;
            }
        }
    }
    out
}

fn percent_encode(s: &str) -> String {
    let mut o = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~/".contains(&b) {
            o.push(b as char);
        } else {
            o.push_str(&format!("%{b:02X}"));
        }
    }
    o
}

#[test]
#[ignore]
fn read_and_zim_get_match_the_crate_reader() {
    let Some(dir) = std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty()) else {
        eprintln!("CS_TEST_ZIM_DIR not set: skipping");
        return;
    };
    let n_art: usize = std::env::var("CS_IDENTITY_N").ok().and_then(|v| v.parse().ok()).unwrap_or(10);
    let mut paths: Vec<PathBuf> = Vec::new();
    for p in PREFIXES {
        let found = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .find(|f| f.extension().map(|x| x == "zim").unwrap_or(false) && f.file_name().unwrap().to_string_lossy().starts_with(p));
        match found {
            Some(f) => paths.push(f),
            None => eprintln!("NOTE: no ZIM starting with {p} in {dir}"),
        }
    }
    assert!(!paths.is_empty(), "none of the ZIMs are in {dir}");
    let cfg = json!({"sources": paths.iter().map(|p| json!({"kind": "zim", "path": p.to_string_lossy()})).collect::<Vec<_>>()});
    let mut h = Handle::open(&cfg.to_string()).expect("open handle");
    let ids: Vec<String> = serde_json::from_str::<serde_json::Value>(&h.status_json()).unwrap()["sources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().expect("source opened").to_string())
        .collect();

    let mut diffs: Vec<String> = Vec::new();
    let mut total_checks = 0usize;
    for id in &ids {
        let (name, samples) = {
            let src = h.zim(id).unwrap();
            // the handle must not be holding the crate reader (xapian builds drop it after open)
            (src.path.file_name().unwrap().to_string_lossy().to_string(), sample(src, n_art))
        };
        let mut counts = std::collections::BTreeMap::<String, usize>::new();
        // the lookups: samples as stored, then variants of the first article and the odd cases
        let mut lookups: Vec<(String, String)> = samples.iter().map(|s| (format!("{:?}", s.kind), s.path.clone())).collect();
        if let Some(a) = samples.iter().find(|s| s.kind == Kind::Article) {
            lookups.push(("fragment".into(), format!("{}#section", a.path)));
            lookups.push(("percent-encoded".into(), percent_encode(&a.path)));
            lookups.push(("query".into(), format!("{}?x=1", a.path)));
            lookups.push(("namespace-prefixed".into(), format!("A/{}", a.path)));
        }
        lookups.push(("missing".into(), "zz-no-such-entry-xyz".into()));
        lookups.push(("index entry".into(), "X/fulltext/xapian".into()));
        lookups.push(("metadata entry".into(), "M/Title".into()));
        lookups.push(("main page path".into(), "mainPage".into()));
        lookups.push(("index.html".into(), "index.html".into()));

        // main page, both readers
        {
            let src = h.zim(id).unwrap();
            let old = src.main_page_crate();
            let new = src.main_page_path();
            total_checks += 1;
            match (&old, &new) {
                (Ok(a), Ok(b)) if a == b => *counts.entry("main page same".into()).or_default() += 1,
                (Err(a), Err(b)) if same_err(a, b) => *counts.entry("main page same error".into()).or_default() += 1,
                _ => diffs.push(format!("{name}: main page differs: old {old:?} new {new:?}")),
            }
            // and with the main page as an entry
            if let Ok(p) = &new {
                lookups.push(("main page".into(), p.clone()));
            }
        }

        for (label, path) in &lookups {
            total_checks += 1;
            let (old, new) = {
                let src = h.zim(id).unwrap();
                (src.get_crate(path), src.get(path))
            };
            match compare_entries(&old, &new) {
                Ok(what) => *counts.entry(format!("{label}: {what}")).or_default() += 1,
                Err(d) => diffs.push(format!("{name}: zim_get {label} {path:?}: {d}")),
            }
            // cs_zim_get itself, through the handle
            // a sample's path is stored as is, so its address is built the way the library builds them (`%` and `#` encoded); the
            // variants (fragment, percent-encoded, query) are written the way a link or the model would give them
            let addr = if samples.iter().any(|s| &s.path == path) { format_address(id, path) } else { format!("zim:{id}/{path}") };
            let via_handle = h.zim_get(&addr);
            if let Err(d) = compare_entries(&old, &via_handle) {
                diffs.push(format!("{name}: Handle::zim_get {label} {path:?}: {d}"));
            }
            // cs_read: the JSON, at two cut lengths
            for max in [300, 6000] {
                let old_read = old.as_ref().map_err(|e| e.clone()).and_then(|e| read_zim_entry(&addr, e, max));
                let new_read = h.read(&addr, max);
                match compare_text(&old_read, &new_read) {
                    Ok(what) => *counts.entry(format!("read {what}")).or_default() += 1,
                    Err(d) => diffs.push(format!("{name}: cs_read({max}) {label} {path:?}: {d}")),
                }
                total_checks += 1;
            }
        }
        eprintln!(
            "IDENTITY {name}: {} samples; {counts:?}; libzim archive open: {}",
            samples.len(),
            h.zim(id).unwrap().archive_open()
        );
    }
    eprintln!("IDENTITY checks: {total_checks}; differences: {}", diffs.len());
    for d in &diffs {
        eprintln!("DIFF {d}");
    }
    assert!(diffs.is_empty(), "{} differences", diffs.len());
}
