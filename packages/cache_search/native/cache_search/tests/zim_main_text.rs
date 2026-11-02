//! Main-content extraction on real ZIMs (`html::extract`): Wikipedia text and snippets stay as they were, and on the
//! menu-heavy sites the snippet and the start of `read` come from the article, not from a menu.
//!
//! Both tests are `#[ignore]`d and need a build with the `xapian` feature on Windows or Android.
//!
//! - `wikipedia_text_is_identical_and_changed_snippets_come_from_menus`: `CS_TEST_ZIM_DIR` (the folder with the big ZIMs). For
//!   articles sampled from Wikipedia (maxi) and wikimed the current `html_to_text` is compared byte for byte with the frozen copy of
//!   the code from before (`tests/legacy/html_before.rs`): every one must be identical. For queries each search snippet is compared
//!   with libzim's own cleaned snippet (what the code returned before): where they differ, the test shows why. libzim picks its
//!   passage from the whole page, so a changed snippet must be text of a menu element (navbox, sidebar, footer) or a passage that
//!   runs from one into the article; anything else fails. `CS_IDENTITY_N` sets the articles per ZIM (default 25).
//! - `chrome_heavy_zims_answer_from_the_article`: `CS_TEST_ZIM_DIR` and, for the test ZIMs, `CS_TEST_ZIM_TEST_DIR` (php.net, devdocs,
//!   Stack Exchange). Optional `CS_TEST_INDEX_DIR` holds one Tantivy index folder per ZIM (named like the ZIM file without `.zim`), and
//!   then each ZIM is also searched through that index (the `lead` snippet path).
//!   Run: `cargo test --release -p cache_search --test zim_main_text -- --ignored --nocapture`.

#![cfg(zimx)]

#[path = "legacy/html_before.rs"]
mod legacy_html;

use cache_search::handle::Handle;
use cache_search::html::{self, Via};
use cache_search::search::{compact, snippet_in_text};
use cache_search::zimx::clean_snippet;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use zim::{MimeType, Namespace, Target};

fn find(dir: &str, prefix: &str) -> Option<PathBuf> {
    std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|f| f.extension().map(|x| x == "zim").unwrap_or(false) && f.file_name().unwrap().to_string_lossy().starts_with(prefix))
}

fn open(zim: &Path, index: Option<&Path>) -> Handle {
    let mut src = json!({"kind": "zim", "path": zim.to_string_lossy()});
    if let Some(i) = index {
        src["index_dir"] = json!(i.to_string_lossy());
        src["builtin_index"] = json!(false);
    }
    Handle::open(&json!({"sources": [src]}).to_string()).expect("open handle")
}

fn source_id(h: &mut Handle) -> String {
    serde_json::from_str::<Value>(&h.status_json()).unwrap()["sources"][0]["id"].as_str().expect("source opened").to_string()
}

fn search(h: &mut Handle, q: &str, k: usize) -> Vec<Value> {
    let v: Value = serde_json::from_str(&h.search(q, Some(&json!({"k": k}).to_string())).expect("search")).unwrap();
    v["results"].as_array().cloned().unwrap_or_default()
}

fn one_line(s: &str, n: usize) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(n).collect()
}

/// HTML articles spread over the first 90% of the ZIM's entries (as `zim_read_identity.rs` samples them).
fn sample_articles(h: &mut Handle, id: &str, n: usize) -> Vec<String> {
    let src = h.zim(id).unwrap();
    let zim = src.zim().expect("crate reader");
    let total = zim.header.article_count as u64;
    let mut out: Vec<String> = Vec::new();
    let starts = (n as u64).max(1);
    for s in 0..starts {
        let mut idx = (total * 9 / 10) * s / starts + s * 101 % 997;
        for _ in 0..3000 {
            if idx >= total {
                break;
            }
            idx += 1;
            let Ok(e) = zim.get_by_url_index(idx as u32) else { continue };
            if !matches!(e.namespace, Namespace::UserContent | Namespace::Articles) || matches!(e.target, Some(Target::Redirect(_))) {
                continue;
            }
            if matches!(&e.mime_type, MimeType::Type(m) if m.starts_with("text/html")) && !out.contains(&e.url) {
                out.push(e.url.clone());
                break;
            }
        }
    }
    out
}

/// All the text of a page, menus included (tags removed, scripts and styles dropped, entities decoded), as libzim sees it.
fn all_text(raw: &str) -> String {
    let b = raw.as_bytes();
    let (mut out, mut i) = (String::new(), 0usize);
    while i < b.len() {
        if b[i] == b'<' {
            let lower = raw[i..].chars().take(8).collect::<String>().to_ascii_lowercase();
            let end = if lower.starts_with("<script") || lower.starts_with("<style") {
                let name = if lower.starts_with("<script") { "</script" } else { "</style" };
                raw[i..].to_ascii_lowercase().find(name).map(|p| i + p)
            } else {
                None
            };
            let from = end.unwrap_or(i);
            i = raw[from..].find('>').map(|p| from + p + 1).unwrap_or(b.len());
            out.push(' ');
        } else {
            let j = raw[i..].find('<').map(|p| i + p).unwrap_or(b.len());
            out.push_str(&html_escape::decode_html_entities(&raw[i..j]));
            i = j;
        }
    }
    out
}

/// Why libzim's snippet is not in the article's main text: text of one menu element ("menu"), or a passage over the edge
/// between a menu and the article ("edge"); `None` when it is in neither (not explained).
fn why_not_main(raw: &str, libzim_snippet: &str) -> Option<&'static str> {
    let flat = libzim_snippet.replace('\u{2026}', "...");
    let frags: Vec<String> = flat.split("...").map(compact).filter(|c| !c.is_empty()).collect();
    let menus: Vec<String> = html::chrome_nodes(raw).iter().map(|(_, s, e)| compact(&html::strip(&raw[*s..*e]))).collect();
    if frags.iter().all(|f| menus.iter().any(|m| m.contains(f.as_str()))) {
        return Some("menu");
    }
    let everything = compact(&all_text(raw));
    if frags.iter().all(|f| everything.contains(f.as_str())) {
        return Some("edge");
    }
    None
}

const WIKI_QUERIES: [&str; 14] = [
    "asthma treatment",
    "heart attack symptoms",
    "river delta formation",
    "roman empire collapse",
    "photosynthesis chlorophyll",
    "diabetes insulin resistance",
    "earthquake magnitude scale",
    "volcano eruption types",
    "world war two causes",
    "malaria transmission mosquito",
    "boise idaho",
    "antibiotic resistance bacteria",
    "solar eclipse path",
    "hypothermia first aid",
];

#[test]
#[ignore]
fn wikipedia_text_is_identical_and_changed_snippets_come_from_menus() {
    let Some(dir) = std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty()) else {
        eprintln!("CS_TEST_ZIM_DIR not set: skipping");
        return;
    };
    let n: usize = std::env::var("CS_IDENTITY_N").ok().and_then(|v| v.parse().ok()).unwrap_or(25);
    let mut diffs: Vec<String> = Vec::new();
    let mut found = 0;
    for prefix in ["wikipedia_en_all_maxi", "wikipedia_en_medicine"] {
        let Some(zim) = find(&dir, prefix) else {
            eprintln!("NOTE: no ZIM starting with {prefix} in {dir}");
            continue;
        };
        found += 1;
        let mut h = open(&zim, None);
        let id = source_id(&mut h);
        // 1. the text of sampled articles, new against the frozen old code
        let paths = sample_articles(&mut h, &id, n);
        let (mut same, mut via_main, mut other) = (0usize, 0usize, 0usize);
        for p in &paths {
            let e = h.zim(&id).unwrap().get(p).expect("entry");
            let raw = String::from_utf8_lossy(&e.bytes).to_string();
            let (new, old) = (html::extract(&raw), legacy_html::html_to_text(&raw));
            if new.text == old {
                same += 1;
            } else {
                diffs.push(format!("{prefix}: text of {p:?} differs ({} vs {} bytes, via {:?})", new.text.len(), old.len(), new.via));
            }
            if new.via == Via::Main {
                via_main += 1;
            } else {
                other += 1;
            }
        }
        eprintln!("IDENTITY {prefix}: {} articles, {same} identical, {via_main} through main, {other} not through main", paths.len());
        // 2. snippets: the search result against libzim's own snippet cut the same way
        let x = h.zim(&id).unwrap().xapian().expect("built-in index");
        let (mut checked, mut equal) = (0usize, 0usize);
        let mut changed: std::collections::BTreeMap<&str, usize> = Default::default();
        let mut queries: Vec<String> = WIKI_QUERIES.iter().map(|s| s.to_string()).collect();
        for p in paths.iter().take(10) {
            let title = h.zim(&id).unwrap().get(p).map(|e| e.title).unwrap_or_default();
            if !title.is_empty() {
                queries.push(title);
            }
        }
        for q in &queries {
            for r in search(&mut h, q, 8) {
                let addr = r["address"].as_str().unwrap().to_string();
                let path = addr.split_once('/').map(|(_, p)| p.to_string()).unwrap_or_default();
                let Ok((hits, _)) = x.search(q, 0, 60) else { continue };
                let Some(xh) = hits.iter().find(|xh| format!("zim:{id}/{}", xh.path) == addr || xh.path == path) else { continue };
                let want = clean_snippet(&xh.snippet, 400);
                if want.is_empty() {
                    continue; // libzim gave none: the code falls back to the article text, which is not what is compared here
                }
                checked += 1;
                if r["snippet"].as_str() == Some(want.as_str()) {
                    equal += 1;
                } else {
                    let raw = h.zim_get(&addr).map(|e| String::from_utf8_lossy(&e.bytes).to_string()).unwrap_or_default();
                    let in_main = snippet_in_text(&want, &compact(&html::html_to_text(&raw)));
                    let line = format!("{prefix}: snippet of {addr} for {q:?}: libzim {:?} vs result {:?}", one_line(&want, 110), one_line(r["snippet"].as_str().unwrap_or(""), 110));
                    match (in_main, why_not_main(&raw, &want)) {
                        (true, _) => diffs.push(format!("{line} -- NOT EXPLAINED: libzim's snippet is main text but was replaced")),
                        (false, Some(kind)) => {
                            *changed.entry(kind).or_default() += 1;
                            eprintln!("CHANGED ({kind}) {line}");
                        }
                        (false, None) => diffs.push(format!("{line} -- NOT EXPLAINED: libzim's snippet is not in the page's text")),
                    }
                }
            }
        }
        eprintln!("IDENTITY {prefix}: {checked} snippets checked against libzim, {equal} identical, changed because libzim took them from a menu: {changed:?}");
    }
    assert!(found > 0, "none of the Wikipedia ZIMs are in {dir}");
    for d in &diffs {
        eprintln!("DIFF {d}");
    }
    assert!(diffs.is_empty(), "{} differences", diffs.len());
}

/// (file-name prefix, folder variable, query). The sites with menus, sidebars, footers or banners around the article.
const CHROME_ZIMS: [(&str, &str, &str); 16] = [
    ("www.ready.gov", "CS_TEST_ZIM_DIR", "earthquake preparedness"),
    ("meshtastic.org", "CS_TEST_ZIM_DIR", "lora region settings"),
    ("meshoskey.com", "CS_TEST_ZIM_DIR", "firmware"),
    ("100r.co", "CS_TEST_ZIM_DIR", "uxn"),
    ("docs.meshcore.io", "CS_TEST_ZIM_DIR", "repeater"),
    ("reticulum.network", "CS_TEST_ZIM_DIR", "transport"),
    ("freq51.net", "CS_TEST_ZIM_DIR", "frequency"),
    ("ifixit", "CS_TEST_ZIM_DIR", "iphone battery replacement"),
    ("armypubs", "CS_TEST_ZIM_DIR", "first aid"),
    ("appropedia", "CS_TEST_ZIM_DIR", "solar cooker"),
    ("cd3wdproject.org", "CS_TEST_ZIM_DIR", "water purification"),
    ("nhs.uk", "CS_TEST_ZIM_DIR", "ibuprofen"),
    ("php.net", "CS_TEST_ZIM_TEST_DIR", "array_map"),
    ("devdocs_en_git", "CS_TEST_ZIM_TEST_DIR", "rebase"),
    ("devdocs_en_css", "CS_TEST_ZIM_TEST_DIR", "flexbox"),
    ("cooking.stackexchange.com", "CS_TEST_ZIM_TEST_DIR", "buttermilk substitute"),
];

/// Failures of one hit: the snippet and the first 300 characters of `read` must be article text, not the text of a menu.
fn check_hit(h: &mut Handle, label: &str, r: &Value, report: &mut Vec<String>) -> Vec<String> {
    let mut bad = Vec::new();
    let addr = r["address"].as_str().unwrap().to_string();
    let snippet = r["snippet"].as_str().unwrap_or("").to_string();
    let e = match h.zim_get(&addr) {
        Ok(e) if e.mime.to_ascii_lowercase().starts_with("text/html") => e,
        _ => return bad,
    };
    let raw = String::from_utf8_lossy(&e.bytes).to_string();
    let x = html::extract(&raw);
    let read: Value = serde_json::from_str(&h.read(&addr, 300).expect("read")).unwrap();
    let text = read["text"].as_str().unwrap_or("").to_string();
    report.push(format!("{label} {} via={:?}<{}>\n      snippet: {}\n      read:    {}", addr.rsplit('/').next().unwrap_or(""), x.via, x.root_name, one_line(&snippet, 110), one_line(&text, 110)));
    if x.via == Via::Whole {
        return bad; // a page too short for the walk: the whole text is the page
    }
    // the chosen element is not inside a menu, banner, aside or footer
    for (name, s, e) in html::chrome_nodes(&raw) {
        if s <= x.root.0 && x.root.1 <= e {
            bad.push(format!("{label} {addr}: the chosen element is inside <{name}>"));
        }
    }
    // the snippet and the start of read are text of the chosen element
    let page = compact(&x.text);
    if !snippet.is_empty() && !snippet_in_text(&snippet, &page) {
        bad.push(format!("{label} {addr}: snippet is not from the main text: {:?}", one_line(&snippet, 100)));
    }
    if !compact(&text).is_empty() && !page.starts_with(&compact(&text)[..compact(&text).len().min(page.len())]) {
        bad.push(format!("{label} {addr}: read does not start with the main text"));
    }
    // neither contains a whole chrome subtree (a menu, a footer, a sidebar) of 30 or more letters and digits
    let (cs, ct) = (compact(&snippet), compact(&text));
    for (name, s, e) in html::chrome_nodes(&raw) {
        let menu = compact(&html::strip(&raw[s..e]));
        if menu.len() >= 30 && (cs.contains(&menu) || ct.contains(&menu)) && !page.contains(&menu) {
            bad.push(format!("{label} {addr}: contains the text of a <{name}> subtree: {:?}", &menu[..menu.len().min(60)]));
        }
    }
    bad
}

#[test]
#[ignore]
fn chrome_heavy_zims_answer_from_the_article() {
    let main_dir = std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty());
    let test_dir = std::env::var("CS_TEST_ZIM_TEST_DIR").ok().filter(|s| !s.is_empty());
    let index_dir = std::env::var("CS_TEST_INDEX_DIR").ok().filter(|s| !s.is_empty());
    if main_dir.is_none() && test_dir.is_none() {
        eprintln!("CS_TEST_ZIM_DIR and CS_TEST_ZIM_TEST_DIR not set: skipping");
        return;
    }
    let (mut failures, mut report, mut ran) = (Vec::<String>::new(), Vec::<String>::new(), 0usize);
    for (prefix, var, query) in CHROME_ZIMS {
        let dir = if var == "CS_TEST_ZIM_DIR" { &main_dir } else { &test_dir };
        let Some(zim) = dir.as_deref().and_then(|d| find(d, prefix)) else {
            eprintln!("NOTE: no ZIM starting with {prefix}");
            continue;
        };
        let stem = zim.file_stem().unwrap().to_string_lossy().to_string();
        let mut engines: Vec<(&str, Option<PathBuf>)> = vec![("xapian", None)];
        if let Some(d) = &index_dir {
            let p = Path::new(d).join(&stem);
            if p.exists() {
                engines.push(("tantivy", Some(p)));
            }
        }
        for (engine, idx) in engines {
            let mut h = open(&zim, idx.as_deref());
            let hits = search(&mut h, query, 5);
            report.push(format!("== {stem} [{engine}] query {query:?}: {} hits", hits.len()));
            if hits.is_empty() {
                failures.push(format!("{stem} [{engine}]: no hits for {query:?}"));
            }
            let label = format!("{stem}[{engine}]");
            for r in &hits {
                failures.extend(check_hit(&mut h, &label, r, &mut report));
            }
            ran += 1;
        }
    }
    for l in &report {
        eprintln!("{l}");
    }
    assert!(ran > 0, "no ZIMs found");
    for f in &failures {
        eprintln!("FAIL {f}");
    }
    assert!(failures.is_empty(), "{} failures", failures.len());
}
