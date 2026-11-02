//! `cache-build`: the library builder's command line.
//!
//!   cache-build pdf <in.pdf...> --out packs/ [--fake-embedder | --embed-url URL] [--doc-id ID] [--doc-version N] [--title T] [--https URL]
//!                                            [--created-at TEXT] [--pieces-out FILE]
//!       Each PDF is read in a child process (this program run as the hidden `extract-pdf`), so a PDF that crashes MuPDF fails alone and
//!       a long batch goes on; --in-process reads in this process instead (for debugging).
//!   cache-build library --packs <packs dir> --out <libdir> --id ID --title TITLE [--version V] [--archive]
//!       (the packs dir may also be given as the first argument) writes shard/, cache-library.json, documents.tsv, SHA256SUMS
//!   cache-build zim-pdfs <ZIM> --survey [--limit N] [--skip PATH]... [--in-process]
//!       (each PDF is read in a child process, like `pdf`, so one that crashes MuPDF counts as failed and the survey goes on)
//!       counts the ZIM's PDFs, pages, text layers and estimated pieces (JSON on stdout; nothing written, nothing embedded)
//!   cache-build dump <in.pdf> <page>     (the blocks and lines MuPDF reports for a 1-based page; for debugging)

use cache_builder::build::{build_pack_with_extractor, BuildOptions};
use cache_builder::extract::extract_pdf;
use cache_builder::isolate::ChildExtractor;
use cache_builder::embed::{Embedder, FakeEmbedder};
use cache_builder::embed_http::HttpEmbedder;
use cache_builder::zim::{survey as zim_survey, Survey, ZimPdfOptions};
use cache_builder::library::{build_library, check_library_dir, LibraryOptions};
use cache_builder::pack::write_pack;
use std::path::PathBuf;
use std::time::Instant;

fn usage() -> ! {
    eprintln!(
        "usage:\n  cache-build pdf <in.pdf...> --out <packs dir> (--fake-embedder | --embed-url http://host:port) [--doc-id ID] [--doc-version N] [--title T] [--https URL] [--created-at TEXT] [--pieces-out FILE] [--compress off|lossless|smaller_scans[:high|balanced|smallest]] [--in-process]\n  cache-build library --packs <packs dir> --out <library dir> --id ID --title TITLE [--version V] [--archive]\n  cache-build zim-pdfs <ZIM> --survey [--limit N] [--skip PATH]... [--in-process]\n  cache-build dump <in.pdf> <page>"
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
        "zim-pdfs" => cmd_zim_pdfs(&a),
        "dump" => cmd_dump(&a),
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
        // Compress first, then build from the file that would be kept (its hash is the pack's source hash).
        let bytes = match &compress {
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
                    out
                }
                Err(e) => {
                    eprintln!("{f}: FAILED compressing: {e}");
                    failed += 1;
                    continue;
                }
            },
            None => bytes,
        };
        let name = PathBuf::from(f).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| f.clone());
        let mut o = BuildOptions::new(&name, &created);
        o.doc_id = a.get("--doc-id");
        o.title = a.get("--title");
        o.https = a.get("--https");
        if let Some(v) = a.get("--doc-version") {
            o.doc_version = v.parse().unwrap_or(0);
        }
        let extract = |b: &[u8]| if in_process { extract_pdf(b) } else { child.extract(b) };
        match build_pack_with_extractor(&bytes, &o, embedder, &mut |_| {}, &extract) {
            Ok((pack, r)) => {
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
    if failed > 0 {
        1
    } else {
        0
    }
}

fn cmd_library(a: &Args) -> i32 {
    let (Some(out), Some(id), Some(title)) = (a.get("--out"), a.get("--id"), a.get("--title")) else { usage() };
    let Some(dir) = a.get("--packs").or_else(|| a.pos.first().cloned()) else { usage() };
    let o = LibraryOptions { id, title, version: a.get("--version").unwrap_or_else(|| "1".into()), archive: a.has("--archive") };
    match build_library(&PathBuf::from(&dir), &PathBuf::from(&out), &o) {
        Ok(r) => {
            println!("library {out}: {} points from {} documents", r.points, r.documents);
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
    let order = cache_builder::layout::reading_order(&pg.blocks, cache_builder::layout::body_size(&ext.pages));
    println!("reading order: {order:?}");
    0
}
