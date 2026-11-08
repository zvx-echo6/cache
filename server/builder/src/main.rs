//! `cache-build`: the library builder's command line.
//!
//!   cache-build pdf <in.pdf...> --out packs/ [--fake-embedder | --embed-url URL] [--doc-id ID] [--doc-version N] [--title T] [--https URL]
//!                                            [--created-at TEXT] [--pieces-out FILE] [--labels FILE.json] [--titles FILE.jsonl] [--classes FILE.json]
//!                                            [--original-blake3 HEX] [--ocr-engine E --ocr-version V [--ocr-pages N] [--ocr-text-pages 1-5,9]] [--ocr-json FILE.json]
//!       Writes revision 4 packs: the `book` block holds the title, the arrival hash (`original_blake3`: the hash of the file as it
//!       came, before compression; --original-blake3 names it when the PDF given is an OCR copy), the compression outcome, the OCR
//!       (--ocr-engine/--ocr-version/--ocr-pages, or --ocr-json: either {engine, version, pages_ocrd, original_blake3?} or an object
//!       of those keyed by input file name) and the suggested division (--labels, source "label"). With an OCR record, every page is
//!       marked as OCR text (`text_source_ocr_pages`: all pages) unless --ocr-text-pages lists the pages that are (partial OCR).
//!       Each PDF is read in a child process (this program run as the hidden `extract-pdf`), so a PDF that crashes MuPDF fails alone and
//!       a long batch goes on; --in-process reads in this process instead (for debugging).
//!   cache-build library --packs <packs dir> --out <libdir> --id ID --title TITLE [--version V] [--archive] [--vector-datatype f32|f16] [--labels FILE.json] [--titles FILE.jsonl] [--classes FILE.json] [--built-at TIME]
//!       (the packs dir may also be given as the first argument) writes shard/, cache-library.json, documents.tsv, log/builder-<id>.jsonl
//!       (the seed log), SHA256SUMS and .local/docs.json (the view)
//!       --built-at is the `at` of every seed event: UTC milliseconds or YYYY-MM-DDTHH:MM:SSZ (default: now; pass a fixed one so a
//!       rebuild is byte-identical);
//!       --classifier MODEL (cache-classifier-N.bin) files the books nothing else placed: each is scored from its vectors; a confident
//!       one gets its division as `suggested` (source "classifier", with the score, the second choice and the classifier version) and
//!       a place and assign in the seed log, any other is left in Unsorted (its best guess is still in the view, with no place event);
//!       --sorter-report FILE.tsv writes one line per book the sorter looked at (division, score, Filed/Unsorted, its top 3);
//!       --labels sets each document's division (source "label") from a labels file ([{id, path, final, second_division}]);
//!       --titles sets its title from a titles file (JSON Lines {id, path, title, source_title, ok, author?, edition?, year?}), keeping the old one as source_title;
//!       --classes names the divisions (default: the server's classes-default.json). Packs are matched by doc_id = id, then source
//!       BLAKE3 = blake3, then the PDF's file name when only one record has it (see PACK-FORMAT.md)
//!   cache-build pages <in.pdf> --out <pages.json>
//!       reads the PDF and writes what the layout step made of it as pages.json (the input of `pack`); for debugging and tests
//!   cache-build pack --pages <pages.json> --out <packs dir> (--fake-embedder | --embed-url URL) (--source FILE | --source-blake3 HEX --source-size N --file-name NAME)
//!                    [--doc-id ID] [--doc-version N] [--title T] [--https URL] [--created-at TEXT] [--meta-title T] [--ppi N] [--year N] [--page-count N]
//!                    [--extractor-name NAME] [--extractor-version V] [--layout-version N] [--ocr-engine E --ocr-version V [--ocr-pages N]] [--ocr-json FILE]
//!                    [--original-blake3 HEX] [--labels FILE.json] [--titles FILE.jsonl] [--classes FILE.json]
//!       the shared writer: the text of any source, page by page, becomes a pack with the same passages `pdf` would make from the same pages
//!       (PACK-FORMAT.md, "pages.json"). A page with "text_source": "ocr" needs --ocr-engine and --ocr-version.
//!   cache-build view --library <libdir> [--packs <packs dir>]
//!       rebuilds <libdir>/.local/docs.json from the packs (default <libdir>/packs) and every log in <libdir>/log/
//!   cache-build view --bookshelves <dir> --library <libdir> [--library <libdir>...]
//!       the Bookshelves view: resolves every log in <dir>/log/ against the libraries' packs and seed logs and writes
//!       <dir>/.local/view.json (LIBRARY-LOG.md, "The Bookshelves view"); the library id is the one in cache-library.json
//!   cache-build zim-pdfs <ZIM> --survey [--limit N] [--skip PATH]... [--in-process]
//!       (each PDF is read in a child process, like `pdf`, so one that crashes MuPDF counts as failed and the survey goes on)
//!       counts the ZIM's PDFs, pages, text layers and estimated pieces (JSON on stdout; nothing written, nothing embedded)
//!   cache-build dump <in.pdf> <page>     (the blocks and lines MuPDF reports for a 1-based page; for debugging)
//!   cache-build passages <in.pdf> <page> (the paragraphs the layout reads from a 1-based page, in reading order, and the passages that touch it; for debugging)

use cache_builder::build::{build_pack_with_extractor, BuildOptions};
use cache_builder::extract::extract_pdf;
use cache_builder::isolate::ChildExtractor;
use cache_builder::embed::{Embedder, FakeEmbedder};
use cache_builder::embed_http::HttpEmbedder;
use cache_builder::zim::{survey as zim_survey, Survey, ZimPdfOptions};
use cache_builder::docs::{default_division_names, division_names, load_labels, load_titles_counted, Applied, Overrides};
use cache_builder::log::{now_ms, parse_utc_ms};
use cache_builder::pack::OcrInfo;
use cache_builder::pagewriter;
use cache_builder::view::rebuild_view;
use serde_json::Value;
use cache_builder::library::{build_library_with, check_library_dir, LibraryOptions, VectorDatatype};
use cache_builder::pack::write_pack;
use std::path::PathBuf;
use std::time::Instant;

fn usage() -> ! {
    eprintln!(
        "usage:\n  cache-build pdf <in.pdf...> --out <packs dir> (--fake-embedder | --embed-url http://host:port) [--doc-id ID] [--doc-version N] [--title T] [--https URL] [--created-at TEXT] [--pieces-out FILE] [--compress off|lossless|smaller_scans[:high|balanced|smallest]] [--in-process]\n  cache-build library --packs <packs dir> --out <library dir> --id ID --title TITLE [--version V] [--archive] [--vector-datatype f32|f16] [--labels FILE.json] [--titles FILE.jsonl] [--classes FILE.json]\n  cache-build zim-pdfs <ZIM> --survey [--limit N] [--skip PATH]... [--in-process]\n  cache-build dump <in.pdf> <page>\n  cache-build passages <in.pdf> <page>"
    );
    eprintln!(
        "more commands:\n  cache-build pages <in.pdf> --out <pages.json>\n  cache-build pack --pages <pages.json> --out <packs dir> (--fake-embedder | --embed-url URL) (--source FILE | --source-blake3 HEX --source-size N --file-name NAME) [the fact options of pdf, --meta-title T, --ppi N, --year N, --page-count N, --extractor-name NAME, --extractor-version V, --layout-version N]\nmore options:\n  pdf: [--labels FILE.json] [--titles FILE.jsonl] [--classes FILE.json] [--original-blake3 HEX] [--ocr-engine E --ocr-version V [--ocr-pages N] [--ocr-text-pages 1-5,9]] [--ocr-json FILE.json]\n  library: [--built-at TIME] [--classifier MODEL] [--sorter-report FILE.tsv]\n  cache-build view --library <library dir> [--packs <packs dir>]\n  cache-build view --bookshelves <dir> --library <library dir> [--library <library dir>...]"
    );
    std::process::exit(2);
}

fn now_utc() -> String {
    // ISO 8601 UTC from the system clock (civil-from-days, no date crate).
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

struct Args {
    pos: Vec<String>,
    opts: Vec<(String, Option<String>)>,
}

fn parse(args: &[String]) -> Args {
    let flags = ["--fake-embedder", "--archive", "--survey", "--in-process"];
    let mut pos = Vec::new();
    let mut opts = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a.starts_with("--") {
            if flags.contains(&a.as_str()) {
                opts.push((a.clone(), None));
            } else {
                i += 1;
                if i >= args.len() {
                    usage();
                }
                opts.push((a.clone(), Some(args[i].clone())));
            }
        } else {
            pos.push(a.clone());
        }
        i += 1;
    }
    Args { pos, opts }
}

impl Args {
    fn get(&self, k: &str) -> Option<String> {
        self.opts.iter().find(|(n, _)| n == k).and_then(|(_, v)| v.clone())
    }
    fn has(&self, k: &str) -> bool {
        self.opts.iter().any(|(n, _)| n == k)
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() {
        usage();
    }
    if argv[0] == "extract-pdf" {
        // Hidden: run by `pdf` for each PDF (see cache_builder::isolate).
        std::process::exit(cache_builder::isolate::child_main());
    }
    let a = parse(&argv[1..]);
    let code = match argv[0].as_str() {
        "pdf" => cmd_pdf(&a),
        "library" => cmd_library(&a),
        "view" => cmd_view(&a),
        "pack" => cmd_pack(&a),
        "pages" => cmd_pages(&a),
        "zim-pdfs" => cmd_zim_pdfs(&a),
        "dump" => cmd_dump(&a),
        "passages" => cmd_passages(&a),
        _ => usage(),
    };
    std::process::exit(code);
}

fn cmd_pdf(a: &Args) -> i32 {
    let Some(out) = a.get("--out") else { usage() };
    if a.pos.is_empty() {
        usage();
    }
    let http: Option<HttpEmbedder> = match a.get("--embed-url") {
        Some(u) => match HttpEmbedder::new(&u) {
            Ok(e) => Some(e),
            Err(e) => {
                eprintln!("error: --embed-url: {e}");
                return 2;
            }
        },
        None => None,
    };
    if http.is_none() && !a.has("--fake-embedder") {
        eprintln!("error: pass --embed-url (a llama-server running bge-m3 Q8_0) or --fake-embedder (stand-in vectors for testing the pipeline)");
        return 2;
    }
    if http.is_some() && a.has("--fake-embedder") {
        eprintln!("error: --embed-url and --fake-embedder cannot be used together");
        return 2;
    }
    let fake = FakeEmbedder;
    let embedder: &dyn Embedder = match &http {
        Some(h) => h,
        None => &fake,
    };
    if a.pos.len() > 1 && (a.get("--doc-id").is_some() || a.get("--title").is_some() || a.get("--https").is_some()) {
        eprintln!("error: --doc-id, --title and --https apply to a single PDF");
        return 2;
    }
    let compress = match a.get("--compress").map(|v| cache_builder::compress::Compression::parse(&v)) {
        Some(Err(e)) => {
            eprintln!("error: --compress: {e}");
            return 2;
        }
        Some(Ok(c)) => Some(c),
        None => None,
    };
    let created = a.get("--created-at").unwrap_or_else(now_utc);
    let over = match overrides_from(a) {
        Ok(o) => o,
        Err(code) => return code,
    };
    let use_over = over.labels.is_some() || over.titles.is_some();
    let mut applied = Applied::default();
    let flag_ocr = match ocr_from_flags(a) {
        Ok(o) => o,
        Err(code) => return code,
    };
    let ocr_text_pages: Option<Vec<usize>> = match a.get("--ocr-text-pages") {
        Some(v) => match parse_page_list(&v) {
            Some(l) => Some(l),
            None => {
                eprintln!("error: --ocr-text-pages takes pages like 1-5,9 (from 1)");
                return 2;
            }
        },
        None => None,
    };
    let sidecar: Option<Value> = match a.get("--ocr-json") {
        Some(f) => match std::fs::read(&f).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
            Some(v) => Some(v),
            None => {
                eprintln!("error: --ocr-json {f}: not a readable JSON file");
                return 2;
            }
        },
        None => None,
    };
    let child = ChildExtractor::current_exe(std::env::temp_dir());
    let in_process = a.has("--in-process");
    let mut failed = 0;
    let mut pieces_out = String::new();
    for f in &a.pos {
        let t0 = Instant::now();
        let bytes = match std::fs::read(f) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("{f}: FAILED reading: {e}");
                failed += 1;
                continue;
            }
        };
        // The file as it arrived: its hash is the book's identity (`book.original_blake3`).
        let arrival = blake3::hash(&bytes).to_hex().to_string();
        // Compress first, then build from the file that would be kept (its hash is the pack's source hash).
        let (bytes, outcome) = match &compress {
            Some(c) => match if in_process { Ok(cache_builder::compress::compress_pdf(&bytes, c)) } else { child.compress(&bytes, c) } {
                Ok((out, r)) => {
                    println!(
                        "{f}: compression {}{}: {} -> {} bytes{}{}",
                        r.level,
                        r.preset.as_ref().map(|p| format!(":{p}")).unwrap_or_default(),
                        r.original_size,
                        r.stored_size,
                        r.psnr_min.map(|p| format!(", min PSNR {p:.1} dB")).unwrap_or_default(),
                        r.kept_reason.as_ref().map(|w| format!(", original kept: {w}")).unwrap_or_default()
                    );
                    (out, Some(r))
                }
                Err(e) => {
                    eprintln!("{f}: FAILED compressing: {e}");
                    failed += 1;
                    continue;
                }
            },
            None => (bytes, None),
        };
        let name = PathBuf::from(f).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| f.clone());
        let mut o = BuildOptions::new(&name, &created);
        o.doc_id = a.get("--doc-id");
        o.title = a.get("--title");
        o.https = a.get("--https");
        let side = match &sidecar {
            Some(v) if v.get("engine").is_some() => ocr_entry(v),
            Some(v) => v.get(name.as_str()).map(ocr_entry).unwrap_or((None, None)),
            None => (None, None),
        };
        o.original_blake3 = Some(a.get("--original-blake3").or(side.1).unwrap_or(arrival));
        o.compression = outcome;
        o.ocr = flag_ocr.clone().or(side.0);
        let ocr_on = o.ocr.is_some();
        if let Some(v) = a.get("--doc-version") {
            o.doc_version = v.parse().unwrap_or(0);
        }
        let extract = |b: &[u8]| if in_process { extract_pdf(b) } else { child.extract(b) };
        match build_pack_with_extractor(&bytes, &o, embedder, &mut |_| {}, &extract) {
            Ok((mut pack, r)) => {
                // Text that came from OCR: with an OCR record, every page's text is OCR (an OCR'd copy has its whole text layer
                // replaced) unless --ocr-text-pages names the pages (partial OCR).
                if ocr_on {
                    let pages: Vec<usize> = ocr_text_pages.clone().unwrap_or_else(|| (1..=pack.header.page_count).collect());
                    if let Some(bad) = pages.iter().find(|p| **p > pack.header.page_count) {
                        eprintln!("{f}: FAILED: --ocr-text-pages names page {bad}, the PDF has {}", pack.header.page_count);
                        failed += 1;
                        continue;
                    }
                    pack.header.text_source_ocr_pages = pages;
                }
                if use_over {
                    apply_overrides(&over, &mut pack, &mut applied);
                }
                let path = match write_pack(&pack, &PathBuf::from(&out)) {
                    Ok(p) => p,
                    Err(e) => {
                        eprintln!("{f}: FAILED writing the pack: {e}");
                        failed += 1;
                        continue;
                    }
                };
                println!(
                    "{name}: pages {} pieces {} words/piece mean {:.0} min {} max {} ocr_pages {} headings {} time {:.1}s -> {}",
                    r.pages,
                    r.pieces,
                    r.mean_words,
                    r.min_words,
                    r.max_words,
                    r.ocr_pages.len(),
                    r.heading_count,
                    t0.elapsed().as_secs_f32(),
                    path.display()
                );
                for (l, h) in &r.headings {
                    println!("    H{l} {h}");
                }
                if a.get("--pieces-out").is_some() {
                    for (i, p) in pack.pieces.iter().enumerate() {
                        pieces_out.push_str(&format!(
                            "=== {name} piece {} | page {}{} | {}\n{}\n\n",
                            i,
                            p.page,
                            p.page_end.as_ref().map(|e| format!("-{e}")).unwrap_or_default(),
                            p.heading_path.join(" > "),
                            p.text
                        ));
                    }
                }
            }
            Err(e) => {
                eprintln!("{f}: FAILED: {e}{}", http.as_ref().and_then(|h| h.last_error()).map(|m| format!(" ({m})")).unwrap_or_default());
                failed += 1;
            }
        }
    }
    if let Some(p) = a.get("--pieces-out") {
        let _ = std::fs::write(p, pieces_out);
    }
    if over.labels.is_some() {
        println!("labels: {} matched, {} ambiguous (file name shared), {} not found", applied.labels_matched, applied.labels_ambiguous, applied.labels_unmatched);
    }
    if over.titles.is_some() {
        println!(
            "titles: {} matched, {} ambiguous (file name shared), {} not found; author/edition/year given to {} documents, {} values dropped as invalid",
            applied.titles_matched, applied.titles_ambiguous, applied.titles_unmatched, applied.facts_applied, applied.facts_dropped
        );
    }
    if failed > 0 {
        1
    } else {
        0
    }
}

/// The `--labels`, `--titles` and `--classes` files (the exit code on error).
fn overrides_from(a: &Args) -> Result<Overrides, i32> {
    let mut over = Overrides { names: default_division_names(), ..Default::default() };
    if let Some(f) = a.get("--classes") {
        match std::fs::read(&f).ok().and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok()) {
            Some(v) => over.names = division_names(&v),
            None => {
                eprintln!("error: --classes {f}: not a readable JSON file");
                return Err(2);
            }
        }
    }
    if let Some(f) = a.get("--labels") {
        match load_labels(&PathBuf::from(&f)) {
            Ok(l) => {
                println!("labels {f}: {} usable records", l.len());
                over.labels = Some(l);
            }
            Err(e) => {
                eprintln!("error: --labels: {e}");
                return Err(2);
            }
        }
    }
    if let Some(f) = a.get("--titles") {
        match load_titles_counted(&PathBuf::from(&f)) {
            Ok((t, dropped)) => {
                println!("titles {f}: {} usable records", t.len());
                over.titles = Some(t);
                over.facts_dropped = dropped;
            }
            Err(e) => {
                eprintln!("error: --titles: {e}");
                return Err(2);
            }
        }
    }
    Ok(over)
}

/// A page list such as `1-5,9`: pages from 1, sorted, each once. `None` when it is not one.
fn parse_page_list(s: &str) -> Option<Vec<usize>> {
    let mut out = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        let (a, b) = match part.split_once('-') {
            Some((a, b)) => (a.trim().parse::<usize>().ok()?, b.trim().parse::<usize>().ok()?),
            None => {
                let n = part.parse::<usize>().ok()?;
                (n, n)
            }
        };
        if a == 0 || b < a {
            return None;
        }
        out.extend(a..=b);
    }
    out.sort_unstable();
    out.dedup();
    (!out.is_empty()).then_some(out)
}

/// `--ocr-engine E --ocr-version V [--ocr-pages N]` (the exit code on error).
fn ocr_from_flags(a: &Args) -> Result<Option<OcrInfo>, i32> {
    match (a.get("--ocr-engine"), a.get("--ocr-version")) {
        (Some(engine), Some(version)) => match a.get("--ocr-pages").map_or(Ok(0), |p| p.parse::<u32>()) {
            Ok(pages_ocrd) => Ok(Some(OcrInfo { engine, version, pages_ocrd })),
            Err(_) => {
                eprintln!("error: --ocr-pages needs a number");
                Err(2)
            }
        },
        (None, None) => Ok(None),
        _ => {
            eprintln!("error: --ocr-engine and --ocr-version go together");
            Err(2)
        }
    }
}

/// A number option (the exit code on error).
fn number_opt(a: &Args, k: &str) -> Result<Option<u64>, i32> {
    match a.get(k) {
        None => Ok(None),
        Some(v) => v.parse::<u64>().map(Some).map_err(|_| {
            eprintln!("error: {k} needs a number");
            2
        }),
    }
}

/// The labels and titles of `over` applied to a pack that was just built (what `pdf` does inline).
fn apply_overrides(over: &Overrides, pack: &mut cache_builder::pack::Pack, applied: &mut Applied) {
    let e = over.entry(&pack.header, applied);
    pack.header.set_title(e.effective_title());
    if let Some(b) = pack.header.book.as_mut() {
        b.source_title = e.source_title.clone();
        b.suggested = e.suggested.clone();
        b.author = e.author.clone();
        b.edition = e.edition.clone();
        b.year = e.year;
    }
}

/// `cache-build pages <in.pdf> --out <pages.json>`: what the layout step makes of the PDF, in the shape `pack` reads.
fn cmd_pages(a: &Args) -> i32 {
    let (Some(f), Some(out)) = (a.pos.first(), a.get("--out")) else { usage() };
    let bytes = match std::fs::read(f) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("{f}: FAILED reading: {e}");
            return 1;
        }
    };
    let ext = match extract_pdf(&bytes) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("{f}: FAILED: {e}");
            return 1;
        }
    };
    let lay = cache_builder::layout::layout(&ext);
    let name = PathBuf::from(f).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| f.clone());
    let (_, pages) = cache_builder::build::pages_of(&ext, &lay, &bytes, &name);
    match pagewriter::pages_json(&pages).and_then(|t| std::fs::write(&out, t).map_err(|e| cache_builder::Error::ctx(&format!("writing {out}"), e))) {
        Ok(()) => {
            println!("{name}: {} pages -> {out}", pages.len());
            0
        }
        Err(e) => {
            eprintln!("FAILED: {e}");
            1
        }
    }
}

/// `cache-build pack`: the shared writer on a `pages.json` (see the header of this file).
fn cmd_pack(a: &Args) -> i32 {
    let (Some(out), Some(pages_file)) = (a.get("--out"), a.get("--pages")) else { usage() };
    let http: Option<HttpEmbedder> = match a.get("--embed-url") {
        Some(u) => match HttpEmbedder::new(&u) {
            Ok(e) => Some(e),
            Err(e) => {
                eprintln!("error: --embed-url: {e}");
                return 2;
            }
        },
        None => None,
    };
    if http.is_none() && !a.has("--fake-embedder") {
        eprintln!("error: pass --embed-url (a llama-server running bge-m3 Q8_0) or --fake-embedder (stand-in vectors for testing the pipeline)");
        return 2;
    }
    if http.is_some() && a.has("--fake-embedder") {
        eprintln!("error: --embed-url and --fake-embedder cannot be used together");
        return 2;
    }
    let fake = FakeEmbedder;
    let embedder: &dyn Embedder = match &http {
        Some(h) => h,
        None => &fake,
    };
    let mut pages = match std::fs::read_to_string(&pages_file).map_err(|e| cache_builder::Error::ctx(&format!("reading {pages_file}"), e)).and_then(|t| pagewriter::parse_pages(&t)) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: --pages: {e}");
            return 2;
        }
    };
    pagewriter::normalize_pages(&mut pages);
    // the file the pages came from
    let (src_hash, size, file_name) = match (a.get("--source"), a.get("--source-blake3"), a.get("--source-size"), a.get("--file-name")) {
        (Some(f), None, None, name) => match std::fs::read(&f) {
            Ok(b) => (blake3::hash(&b).to_hex().to_string(), b.len() as u64, name.unwrap_or_else(|| PathBuf::from(&f).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| f.clone()))),
            Err(e) => {
                eprintln!("{f}: FAILED reading: {e}");
                return 1;
            }
        },
        (None, Some(h), Some(sz), Some(name)) => match sz.parse::<u64>() {
            Ok(n) => (h.to_lowercase(), n, name),
            Err(_) => {
                eprintln!("error: --source-size needs a number");
                return 2;
            }
        },
        _ => {
            eprintln!("error: give the file the pages came from: --source FILE, or --source-blake3 HEX --source-size N --file-name NAME");
            return 2;
        }
    };
    let (ppi, year, page_count, layout_version) = match (number_opt(a, "--ppi"), number_opt(a, "--year"), number_opt(a, "--page-count"), number_opt(a, "--layout-version")) {
        (Ok(p), Ok(y), Ok(c), Ok(l)) => (p.map(|n| n as u32), y.map(|n| n as u32), c.map_or(0, |n| n as usize), l.map(|n| n as u32)),
        _ => return 2,
    };
    let ocr_pages_in_pages = pages.iter().filter(|p| p.text_source == pagewriter::TextSource::Ocr).count();
    let mut ocr = match ocr_from_flags(a) {
        Ok(o) => o,
        Err(code) => return code,
    };
    let mut original = a.get("--original-blake3");
    if let Some(f) = a.get("--ocr-json") {
        match std::fs::read(&f).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
            Some(v) => {
                let (o, h) = ocr_entry(&v);
                ocr = ocr.or(o);
                original = original.or(h);
            }
            None => {
                eprintln!("error: --ocr-json {f}: not a readable JSON file");
                return 2;
            }
        }
    }
    if ocr_pages_in_pages > 0 && ocr.is_none() {
        eprintln!("error: {ocr_pages_in_pages} page(s) have \"text_source\": \"ocr\", so --ocr-engine and --ocr-version (or --ocr-json) are needed");
        return 2;
    }
    let ocr = ocr.map(|mut o| {
        if a.get("--ocr-pages").is_none() && o.pages_ocrd == 0 {
            o.pages_ocrd = ocr_pages_in_pages as u32;
        }
        o
    });
    let over = match overrides_from(a) {
        Ok(o) => o,
        Err(code) => return code,
    };
    let use_over = over.labels.is_some() || over.titles.is_some();
    let created = a.get("--created-at").unwrap_or_else(now_utc);
    let mut o = BuildOptions::new(&file_name, &created);
    o.doc_id = a.get("--doc-id");
    o.title = a.get("--title");
    o.https = a.get("--https");
    if let Some(v) = a.get("--doc-version") {
        o.doc_version = v.parse().unwrap_or(0);
    }
    o.original_blake3 = Some(original.unwrap_or_else(|| src_hash.clone()));
    o.ocr = ocr;
    let src = pagewriter::PagesSource {
        blake3: src_hash,
        size,
        file_name,
        extractor: cache_builder::pack::Tool {
            name: a.get("--extractor-name").unwrap_or_else(|| "pages".into()),
            version: a.get("--extractor-version").unwrap_or_else(|| "1".into()),
            layout_version,
        },
        meta_title: a.get("--meta-title"),
        ppi,
        year,
        page_count,
        ocr_pages: None,
        text_pages: None,
    };
    let t0 = Instant::now();
    match pagewriter::build_pack_from_pages(&src, &pages, &o, embedder, &mut |_| {}) {
        Ok((mut pack, r)) => {
            let mut applied = Applied::default();
            if use_over {
                apply_overrides(&over, &mut pack, &mut applied);
            }
            match write_pack(&pack, &PathBuf::from(&out)) {
                Ok(p) => {
                    println!(
                        "{}: pages {} pieces {} words/piece mean {:.0} min {} max {} ocr_pages {} headings {} time {:.1}s -> {}",
                        src.file_name,
                        r.pages,
                        r.pieces,
                        r.mean_words,
                        r.min_words,
                        r.max_words,
                        r.ocr_pages.len(),
                        r.heading_count,
                        t0.elapsed().as_secs_f32(),
                        p.display()
                    );
                    0
                }
                Err(e) => {
                    eprintln!("FAILED writing the pack: {e}");
                    1
                }
            }
        }
        Err(e) => {
            eprintln!("FAILED: {e}{}", http.as_ref().and_then(|h| h.last_error()).map(|m| format!(" ({m})")).unwrap_or_default());
            1
        }
    }
}

/// The OCR record and the arrival hash of one entry of an `--ocr-json` file: `{engine, version, pages_ocrd, original_blake3}`.
fn ocr_entry(v: &Value) -> (Option<OcrInfo>, Option<String>) {
    let text = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string).filter(|s| !s.is_empty());
    let ocr = match (text("engine"), text("version")) {
        (Some(engine), Some(version)) => Some(OcrInfo { engine, version, pages_ocrd: v.get("pages_ocrd").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok()).unwrap_or(0) }),
        _ => None,
    };
    (ocr, text("original_blake3"))
}

fn cmd_view(a: &Args) -> i32 {
    if let Some(shelves) = a.get("--bookshelves") {
        let libs: Vec<PathBuf> = a.opts.iter().filter(|(n, _)| n == "--library").filter_map(|(_, v)| v.clone()).map(PathBuf::from).collect();
        if libs.is_empty() {
            usage();
        }
        return match cache_builder::bookshelves::rebuild_bookshelves_view(&PathBuf::from(shelves), &libs) {
            Ok(r) => {
                println!("view {}: {} books, {} log files", r.path.display(), r.books, r.log_files);
                0
            }
            Err(e) => {
                eprintln!("FAILED: {e}");
                1
            }
        };
    }
    let Some(lib) = a.get("--library") else { usage() };
    let lib = PathBuf::from(lib);
    let packs = a.get("--packs").map(PathBuf::from).unwrap_or_else(|| lib.join("packs"));
    match rebuild_view(&lib, &packs) {
        Ok(r) => {
            println!("view {}: {} books, {} log files{}", r.path.display(), r.books, r.log_files, if r.skipped > 0 { format!(", {} log lines skipped", r.skipped) } else { String::new() });
            0
        }
        Err(e) => {
            eprintln!("FAILED: {e}");
            1
        }
    }
}

fn cmd_library(a: &Args) -> i32 {
    let (Some(out), Some(id), Some(title)) = (a.get("--out"), a.get("--id"), a.get("--title")) else { usage() };
    let Some(dir) = a.get("--packs").or_else(|| a.pos.first().cloned()) else { usage() };
    let vector_datatype = match a.get("--vector-datatype") {
        None => VectorDatatype::default(),
        Some(v) => match VectorDatatype::parse(&v) {
            Some(d) => d,
            None => {
                eprintln!("error: --vector-datatype takes f32 or f16");
                return 2;
            }
        },
    };
    let mut over = match overrides_from(a) {
        Ok(o) => o,
        Err(code) => return code,
    };
    if let Some(f) = a.get("--classifier") {
        match std::fs::read(&f).map_err(|e| cache_builder::Error::ctx(&format!("reading {f}"), e)).and_then(|b| cache_builder::sorter::load_model(&b)) {
            Ok(m) => {
                println!("classifier {f}: version {}, threshold {}", m.version(), m.threshold());
                over.sorter = Some(m);
            }
            Err(e) => {
                eprintln!("error: --classifier: {e}");
                return 2;
            }
        }
    } else if a.has("--sorter-report") {
        eprintln!("error: --sorter-report needs --classifier");
        return 2;
    }
    let built_at = match a.get("--built-at") {
        Some(v) => match parse_utc_ms(&v) {
            Some(t) => t,
            None => {
                eprintln!("error: --built-at takes UTC milliseconds or YYYY-MM-DDTHH:MM:SSZ");
                return 2;
            }
        },
        None => now_ms(),
    };
    let o = LibraryOptions { id, title, version: a.get("--version").unwrap_or_else(|| "1".into()), vector_datatype, archive: a.has("--archive"), built_at };
    match build_library_with(&PathBuf::from(&dir), &PathBuf::from(&out), &o, &over) {
        Ok((r, ap)) => {
            println!("library {out}: {} points from {} documents", r.points, r.documents);
            if over.labels.is_some() {
                println!("labels: {} matched, {} ambiguous (file name shared), {} not found", ap.labels_matched, ap.labels_ambiguous, ap.labels_unmatched);
            }
            if over.titles.is_some() {
                println!(
                    "titles: {} matched, {} ambiguous (file name shared), {} not found; author/edition/year given to {} documents (the library path does not rewrite packs, so they are not in its output), {} values dropped as invalid",
                    ap.titles_matched, ap.titles_ambiguous, ap.titles_unmatched, ap.facts_applied, ap.facts_dropped
                );
            }
            if over.sorter.is_some() {
                let filed = r.sorter.iter().filter(|s| s.division.is_some()).count();
                println!("sorter: {} books looked at, {} filed, {} left in Unsorted", r.sorter.len(), filed, r.sorter.len() - filed);
                if let Some(f) = a.get("--sorter-report") {
                    let mut t = String::from("doc_id\tfile_name\ttitle\tclassifier_version\tdivision\tscore\tdecision\ttop3\treason\n");
                    for s in &r.sorter {
                        let top: Vec<String> = s.top.iter().map(|x| format!("{}={:.4}", x.division, x.score)).collect();
                        let clean = |x: &str| x.replace(['\t', '\n', '\r'], " ");
                        t.push_str(&format!(
                            "{}\t{}\t{}\t{}\t{}\t{:.4}\t{}\t{}\t{}\n",
                            s.doc_id,
                            clean(&s.file_name),
                            clean(&s.title),
                            s.classifier_version,
                            s.division.clone().unwrap_or_default(),
                            s.score,
                            if s.division.is_some() { "Filed" } else { "Unsorted" },
                            top.join(" "),
                            s.unsure.clone().unwrap_or_default()
                        ));
                    }
                    if let Err(e) = std::fs::write(&f, t) {
                        eprintln!("error: writing {f}: {e}");
                        return 1;
                    }
                    println!("sorter report {f}");
                }
            }
            match check_library_dir(&PathBuf::from(&out)) {
                Ok(c) => println!("check: docs {} whole_library_only {}", c["docs"], c["whole_library_only"]),
                Err(e) => {
                    eprintln!("check FAILED: {e}");
                    return 1;
                }
            }
            if let Some(p) = r.archive {
                println!("archive {}", p.display());
            }
            0
        }
        Err(e) => {
            eprintln!("FAILED: {e}");
            1
        }
    }
}

fn cmd_zim_pdfs(a: &Args) -> i32 {
    let Some(zim) = a.pos.first() else { usage() };
    if !a.has("--survey") {
        eprintln!("error: zim-pdfs only has the --survey mode");
        return 2;
    }
    let limit = match a.get("--limit") {
        Some(v) => match v.parse::<usize>() {
            Ok(n) => Some(n),
            Err(_) => {
                eprintln!("error: --limit needs a number");
                return 2;
            }
        },
        None => None,
    };
    let child = (!a.has("--in-process")).then(|| ChildExtractor::current_exe(std::env::temp_dir()));
    let o = ZimPdfOptions { zim: PathBuf::from(zim), limit, skip: a.opts.iter().filter(|(k, _)| k == "--skip").filter_map(|(_, v)| v.clone()).collect(), child };
    let t0 = Instant::now();
    let mut last = Instant::now();
    let mut progress = |s: &Survey| {
        if last.elapsed().as_secs() >= 30 {
            eprintln!("{} PDFs, {} pages, {} with text, {} pieces, {:.0}s", s.pdfs, s.pages, s.with_text, s.est_pieces, t0.elapsed().as_secs_f32());
            last = Instant::now();
        }
    };
    let mut skipped = |path: &str, why: &str| eprintln!("skipped {path}: {why}");
    match zim_survey(&o, &mut progress, &mut skipped) {
        Ok(s) => {
            eprintln!("done in {:.1}s", t0.elapsed().as_secs_f32());
            println!("{}", serde_json::to_string_pretty(&s.to_json()).unwrap_or_default());
            0
        }
        Err(e) => {
            eprintln!("FAILED: {e}");
            1
        }
    }
}

fn cmd_dump(a: &Args) -> i32 {
    let (Some(f), Some(p)) = (a.pos.first(), a.pos.get(1)) else { usage() };
    let page: usize = p.parse().unwrap_or(1);
    let bytes = std::fs::read(f).expect("read");
    let ext = cache_builder::extract::extract_pdf(&bytes).expect("extract");
    let Some(pg) = ext.pages.get(page - 1) else { return 1 };
    println!("page {} label {} size {}x{} images {}", page, pg.label, pg.width, pg.height, pg.images);
    for (i, b) in pg.blocks.iter().enumerate() {
        println!("block {i}: x {:.0}-{:.0} y {:.0}-{:.0} lines {}", b.x0, b.x1, b.y0, b.y1, b.lines.len());
        for l in &b.lines {
            println!("   [{:.0},{:.0} {:.0},{:.0}] sz {:.1}{}{} {:?}", l.x0, l.y0, l.x1, l.y1, l.size, if l.bold { " B" } else { "" }, if l.italic { " I" } else { "" }, l.text);
        }
    }
    println!("reading order:");
    for (i, b) in cache_builder::layout::reading_blocks(&pg.blocks, cache_builder::layout::body_size(&ext.pages)).iter().enumerate() {
        let first: String = b.lines.first().map(|l| l.text.chars().take(50).collect()).unwrap_or_default();
        println!("   {i}: x {:.0}-{:.0} y {:.0}-{:.0} lines {} {:?}", b.x0, b.x1, b.y0, b.y1, b.lines.len(), first);
    }
    0
}

fn cmd_passages(a: &Args) -> i32 {
    let (Some(f), Some(p)) = (a.pos.first(), a.pos.get(1)) else { usage() };
    let page: usize = p.parse().unwrap_or(1);
    let bytes = std::fs::read(f).expect("read");
    let ext = cache_builder::extract::extract_pdf(&bytes).expect("extract");
    let lay = cache_builder::layout::layout(&ext);
    println!("paragraphs of page {page}:");
    for e in &lay.elements {
        match e {
            cache_builder::layout::Element::Heading { level, text, page: pg } if *pg + 1 == page => println!("  H{level}: {text}"),
            cache_builder::layout::Element::Para { text, page: pg, aside, .. } if *pg + 1 == page => {
                println!("  P{}: {text}", if *aside { " (aside)" } else { "" })
            }
            _ => {}
        }
    }
    println!("passages touching page {page}:");
    for piece in cache_builder::chunk::chunk(&lay.elements) {
        if piece.page < page && page <= piece.page_end + 1 {
            println!("  [{}] pages {}-{} words {}: {}", piece.index, piece.page + 1, piece.page_end + 1, piece.text.split_whitespace().count(), piece.text);
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::parse_page_list;

    #[test]
    fn page_lists_are_ranges_and_numbers() {
        assert_eq!(parse_page_list("1-3,9"), Some(vec![1, 2, 3, 9]));
        assert_eq!(parse_page_list(" 5 , 2-3,3"), Some(vec![2, 3, 5]));
        for bad in ["", "0", "3-2", "a", "1-", "-4", "1,,2"] {
            assert_eq!(parse_page_list(bad), None, "{bad:?}");
        }
    }
}
