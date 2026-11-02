//! Building the PDF index of a ZIM (see `pdfindex.rs` for the layout): the resumable build session and the finish job.
//!
//! The session follows the `index_zim` pattern of `index.rs`: a build folder (`.build/`) with a Tantivy index, a record of
//! what it was made for (`pdfindex-build.json`: ZIM uuid, format, chunker, tokenizer; any other value restarts the build),
//! the build `Lock`, and checkpoints. A checkpoint is a Tantivy commit whose payload is `{"entries": N}`; the commit is the
//! authority on resume. `done.tsv` is the per-PDF record: a line is appended (and synced) only after the commit that holds
//! the PDF, and on open only the first N lines (N from the last commit's payload) count. A kill therefore loses at most the
//! PDFs after the last commit; one that was committed but not yet recorded is simply added again, and `add` replaces the
//! pieces of a path, so nothing is duplicated. A PDF is all or nothing: its pieces are added in one call, and a commit
//! happens only between calls.
//!
//! `finish` merges the build to one segment and hands its files to `snapshot.rs`, which copies and hashes them into a temporary
//! folder, writes `manifest.json` last and renames the folder to `snap/<build-id>/` in one step. It can be cancelled until that rename.

use crate::error::{Error, Result};
use crate::index::{make_analyzer, tokenizer_name_for, tv, Lock, Outcome, ANALYZER, LOCK_FILE};
use crate::pdfindex::{
    self, build_schema, fields_of, pid_of, Fields, PdfIndex, PdfRow, CHUNKER_VERSION, FORMAT, KIND, PDFS_FILE, TANTIVY,
};
use crate::snapshot::{self, Manifest, Tokenizer, BUILD_DIR};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tantivy::{doc, Index, IndexWriter, TantivyDocument, Term};

pub const BUILD_META: &str = "pdfindex-build.json";
pub const DONE_FILE: &str = "done.tsv";
/// Files of the build folder that are not part of a snapshot.
const NOT_IN_SNAPSHOT: [&str; 5] = [LOCK_FILE, BUILD_META, DONE_FILE, ".tantivy-writer.lock", ".tantivy-meta.lock"];
/// A commit after this many PDFs or this many seconds, whichever comes first.
const BATCH_PDFS: usize = 20;
const BATCH_SECS: u64 = 30;
const HEAP_BYTES: usize = 50_000_000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct BuildMeta {
    zim_uuid: String,
    format: u32,
    chunker: u32,
    tokenizer: String,
    /// The ZIM's file name without `.zim` (for the manifest); not part of what a resume must match.
    #[serde(default)]
    zim_name: String,
}

impl BuildMeta {
    fn same_build(&self, o: &BuildMeta) -> bool {
        self.zim_uuid == o.zim_uuid
            && self.format == o.format
            && self.chunker == o.chunker
            && self.tokenizer == o.tokenizer
    }
}

fn write_json_atomic(path: &Path, v: &impl Serialize) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let s = serde_json::to_string(v).map_err(|e| Error::internal(e.to_string()))?;
    std::fs::write(&tmp, s).map_err(|e| Error::io(format!("{}: {e}", tmp.display())))?;
    std::fs::rename(&tmp, path).map_err(|e| Error::io(format!("{}: {e}", path.display())))
}

fn read_build_meta(build: &Path) -> Option<BuildMeta> {
    serde_json::from_slice(&std::fs::read(build.join(BUILD_META)).ok()?).ok()
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\t', "\\t").replace('\n', "\\n")
}

fn unesc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('t') => out.push('\t'),
            Some('n') => out.push('\n'),
            Some(o) => out.push(o),
            None => out.push('\\'),
        }
    }
    out
}

/// A PDF that was added: its pieces and, when the app gave them, the size and sha256 of the PDF's bytes.
#[derive(Clone, Default)]
struct Added {
    pieces: u64,
    size: Option<u64>,
    sha256: String,
}

/// A PDF that was skipped, with the reason and the same facts.
#[derive(Clone, Default)]
struct Skipped {
    reason: String,
    size: Option<u64>,
    sha256: String,
}

/// What `done.tsv` says (a line is `d<TAB>path<TAB>pieces<TAB>size<TAB>sha256` or `s<TAB>path<TAB>reason<TAB>size<TAB>sha256`),
/// the last line for a path winning, and the number of lines that counted.
#[derive(Default)]
struct DoneRecord {
    done: BTreeMap<String, Added>,
    skipped: BTreeMap<String, Skipped>,
    lines: usize,
}

fn size_field(f: Option<&str>) -> Option<u64> {
    f.and_then(|x| x.parse().ok())
}

fn line_for(kind: &str, path: &str, what: &str, size: Option<u64>, sha: &str) -> String {
    format!("{kind}\t{}\t{}\t{}\t{}", esc(path), esc(what), size.map(|n| n.to_string()).unwrap_or_default(), sha)
}

/// The first `limit` lines of `done.tsv`.
fn load_done(build: &Path, limit: usize) -> DoneRecord {
    let mut r = DoneRecord::default();
    let Ok(text) = std::fs::read_to_string(build.join(DONE_FILE)) else { return r };
    for line in text.lines().take(limit) {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 {
            continue;
        }
        let path = unesc(f[1]);
        let (size, sha) = (size_field(f.get(3).copied()), f.get(4).copied().unwrap_or("").to_string());
        match f[0] {
            "d" => {
                r.skipped.remove(&path);
                r.done.insert(path, Added { pieces: f[2].parse().unwrap_or(0), size, sha256: sha });
            }
            "s" => {
                r.done.remove(&path);
                r.skipped.insert(path, Skipped { reason: unesc(f[2]), size, sha256: sha });
            }
            _ => continue,
        }
        r.lines += 1;
    }
    r
}

fn payload_entries(index: &Index) -> usize {
    index
        .load_metas()
        .ok()
        .and_then(|m| m.payload)
        .and_then(|p| serde_json::from_str::<Value>(&p).ok())
        .and_then(|v| v.get("entries")?.as_u64())
        .unwrap_or(0) as usize
}

// ---------------------------------------------------------------------------------------------------------
// The session

struct Session {
    build: PathBuf,
    fields: Fields,
    writer: Option<IndexWriter<TantivyDocument>>,
    lock: Option<Lock>,
    rec: DoneRecord,
    /// Lines to append to `done.tsv` once the next commit has happened.
    pending: Vec<String>,
    pending_pdfs: usize,
    last_commit: Instant,
    batch_pdfs: usize,
    batch_secs: u64,
    /// An older edition's published snapshot whose pieces `reuse` may copy.
    previous: Option<Previous>,
}

/// The older edition: its opened snapshot and what its `pdfs.tsv` says about each PDF.
struct Previous {
    index: PdfIndex,
    rows: BTreeMap<String, PdfRow>,
}

static SESSIONS: Mutex<Option<HashMap<u64, Arc<Mutex<Session>>>>> = Mutex::new(None);
static NEXT: AtomicU64 = AtomicU64::new(1);

fn lock_s<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn session_of(id: u64) -> Result<Arc<Mutex<Session>>> {
    lock_s(&SESSIONS)
        .as_ref()
        .and_then(|m| m.get(&id).cloned())
        .ok_or_else(|| Error::not_found(format!("no open pdf index session {id}")))
}

impl Session {
    fn pieces(&self) -> u64 {
        self.rec.done.values().map(|a| a.pieces).sum()
    }

    /// Commit what was added and record it in `done.tsv`.
    fn commit(&mut self) -> Result<()> {
        if self.pending.is_empty() {
            return Ok(());
        }
        let entries = self.rec.lines + self.pending.len();
        let w = self.writer.as_mut().ok_or_else(|| Error::internal("session is closed"))?;
        let mut pc = tv(w.prepare_commit())?;
        pc.set_payload(&json!({"entries": entries}).to_string());
        tv(pc.commit())?;
        let path = self.build.join(DONE_FILE);
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
        let mut text = self.pending.join("\n");
        text.push('\n');
        f.write_all(text.as_bytes())
            .and_then(|_| f.sync_all())
            .map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
        self.rec.lines = entries;
        self.pending.clear();
        self.pending_pdfs = 0;
        self.last_commit = Instant::now();
        Ok(())
    }
}

/// `cs_pdfindex_open`: `{"zim_path","zim_uuid","zim_name"}` -> `{"session","done":[paths],"skipped":[{"path","reason"}],"pieces"}`.
pub fn open_session(params_json: &str) -> Result<String> {
    #[derive(Deserialize)]
    struct P {
        indexes_dir: String,
        zim_uuid: String,
        zim_name: String,
        /// The ZIM's `Language` (as `cs_status` shows it): picks the stemmer. English when absent or unknown.
        #[serde(default)]
        language: Option<String>,
        /// An older edition of this ZIM whose snapshot may supply pieces for PDFs that did not change (see `reuse`).
        #[serde(default)]
        previous: Option<PreviousParams>,
        /// Not in the header: test hooks for the commit batch.
        #[serde(default)]
        batch_pdfs: Option<usize>,
    }
    #[derive(Deserialize)]
    struct PreviousParams {
        zim_uuid: String,
    }
    let p: P = serde_json::from_str(params_json)?;
    if p.indexes_dir.is_empty() || p.zim_name.is_empty() || !crate::zimsrc::is_uuid(&p.zim_uuid) {
        return Err(Error::bad_json("indexes_dir and zim_name must not be empty and zim_uuid must be a uuid"));
    }
    let build = pdfindex::dir_for(Path::new(&p.indexes_dir), &p.zim_uuid).join(BUILD_DIR);
    let lock = Lock::acquire(&build)?;
    let want = BuildMeta {
        zim_uuid: p.zim_uuid.to_ascii_lowercase(),
        format: FORMAT,
        chunker: CHUNKER_VERSION,
        tokenizer: tokenizer_name_for(p.language.as_deref()).to_string(),
        zim_name: p.zim_name.clone(),
    };
    let resume = read_build_meta(&build).is_some_and(|m| m.same_build(&want)) && build.join("meta.json").exists();
    if !resume {
        // another ZIM version, format, chunker or tokenizer (or nothing usable): start over
        crate::index::wipe_dir(&build);
        let _ = std::fs::remove_file(build.join(BUILD_META));
    }
    let (schema, _) = build_schema();
    let index = if resume { tv(Index::open_in_dir(&build))? } else { tv(Index::create_in_dir(&build, schema))? };
    index.tokenizers().register(ANALYZER, make_analyzer(&want.tokenizer));
    let fields = fields_of(&index)?;
    write_json_atomic(&build.join(BUILD_META), &want)?;
    let rec = if resume { load_done(&build, payload_entries(&index)) } else { DoneRecord::default() };
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, 2);
    let writer = tv(index.writer_with_num_threads::<TantivyDocument>(threads, HEAP_BYTES.max(15_000_000 * threads)))?;
    let s = Session {
        build,
        fields,
        writer: Some(writer),
        lock: Some(lock),
        rec,
        pending: Vec::new(),
        pending_pdfs: 0,
        last_commit: Instant::now(),
        batch_pdfs: p.batch_pdfs.unwrap_or(BATCH_PDFS).max(1),
        batch_secs: BATCH_SECS,
        previous: p.previous.and_then(|pv| load_previous(Path::new(&p.indexes_dir), &pv.zim_uuid, &p.zim_name)),
    };
    let reusable: Vec<Value> = s
        .previous
        .iter()
        .flat_map(|pv| pv.rows.values())
        .filter(|r| r.status == "added" && !r.sha256.is_empty() && r.size.is_some())
        .map(|r| json!({"path": r.path, "size": r.size, "sha256": r.sha256}))
        .collect();
    let done: Vec<&String> = s.rec.done.keys().collect();
    let skipped: Vec<Value> = s.rec.skipped.iter().map(|(p, r)| json!({"path": p, "reason": r.reason})).collect();
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    let out = json!({"session": id, "done": done, "skipped": skipped, "pieces": s.pieces(), "reusable": reusable});
    lock_s(&SESSIONS).get_or_insert_with(HashMap::new).insert(id, Arc::new(Mutex::new(s)));
    Ok(out.to_string())
}

struct NewPiece {
    i: u64,
    text: String,
    page: String,
    pdf_page: u64,
    pdf_page_end: Option<u64>,
    heading_path: Vec<String>,
}

fn parse_pieces(v: &Value) -> Result<Vec<NewPiece>> {
    let arr = v.as_array().ok_or_else(|| Error::bad_json("pieces must be an array"))?;
    let mut out = Vec::with_capacity(arr.len());
    for (k, p) in arr.iter().enumerate() {
        let bad = |what: &str| Error::bad_json(format!("pieces[{k}]: {what}"));
        let text = p
            .get("text")
            .and_then(Value::as_str)
            .filter(|t| !t.trim().is_empty())
            .ok_or_else(|| bad("text must be a non-empty string"))?;
        let pdf_page = p
            .get("pdf_page")
            .and_then(Value::as_u64)
            .filter(|n| *n >= 1)
            .ok_or_else(|| bad("pdf_page must be a whole number from 1"))?;
        let page = match p.get("page") {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Number(n)) => n.to_string(),
            None | Some(Value::Null) => String::new(),
            Some(_) => return Err(bad("page must be text or a number")),
        };
        let heading_path = match p.get("heading_path") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(a)) => a
                .iter()
                .map(|h| h.as_str().map(str::to_string).ok_or_else(|| bad("heading_path must hold text")))
                .collect::<Result<_>>()?,
            Some(_) => return Err(bad("heading_path must be an array")),
        };
        out.push(NewPiece {
            i: p.get("i").and_then(Value::as_u64).unwrap_or(k as u64),
            text: text.to_string(),
            page,
            pdf_page,
            pdf_page_end: p.get("pdf_page_end").and_then(Value::as_u64),
            heading_path,
        });
    }
    Ok(out)
}

/// The older edition's snapshot, when it is usable, of the same ZIM name, and has a `pdfs.tsv`.
fn load_previous(indexes_dir: &Path, zim_uuid: &str, zim_name: &str) -> Option<Previous> {
    if !crate::zimsrc::is_uuid(zim_uuid) {
        return None;
    }
    let picked = pdfindex::pick(&pdfindex::dir_for(indexes_dir, zim_uuid), zim_uuid)?;
    if picked.manifest.extra.get("zim_name").and_then(Value::as_str) != Some(zim_name) {
        return None;
    }
    let text = std::fs::read_to_string(picked.dir.join(PDFS_FILE)).ok()?;
    let index = PdfIndex::open(&picked.name, &picked.dir, picked.manifest).ok()?;
    Some(Previous { index, rows: pdfindex::rows_from_tsv(&text).into_iter().map(|r| (r.path.clone(), r)).collect() })
}

fn optional_size_and_sha(v: &Value) -> Result<(Option<u64>, String)> {
    let sha = match v.get("sha256") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) if s.bytes().all(|b| b.is_ascii_hexdigit()) => s.to_ascii_lowercase(),
        Some(_) => return Err(Error::bad_json("sha256 must be hex text")),
    };
    Ok((v.get("size").and_then(Value::as_u64), sha))
}

/// Replace the pieces of `path` with `pieces`, record the PDF and commit when a batch is full.
fn put_pdf(s: &mut Session, path: &str, title: &str, pieces: &[NewPiece], size: Option<u64>, sha: &str) -> Result<()> {
    let f = s.fields;
    {
        let w = s.writer.as_mut().ok_or_else(|| Error::internal("session is closed"))?;
        w.delete_term(Term::from_field_text(f.zim_path, path));
        for p in pieces {
            let mut d = doc!(
                f.pid => pid_of(path, p.i),
                f.zim_path => path,
                f.piece => p.i,
                f.title => title,
                f.text => p.text.as_str(),
                f.page => p.page.as_str(),
                f.pdf_page => p.pdf_page,
                f.heading_path => serde_json::to_string(&p.heading_path).unwrap_or_default()
            );
            if let Some(e) = p.pdf_page_end {
                d.add_u64(f.pdf_page_end, e);
            }
            tv(w.add_document(d))?;
        }
    }
    s.rec.skipped.remove(path);
    s.rec.done.insert(path.to_string(), Added { pieces: pieces.len() as u64, size, sha256: sha.to_string() });
    s.pending.push(line_for("d", path, &pieces.len().to_string(), size, sha));
    s.pending_pdfs += 1;
    if s.pending_pdfs >= s.batch_pdfs || s.last_commit.elapsed() >= Duration::from_secs(s.batch_secs) {
        s.commit()?;
    }
    Ok(())
}

/// `cs_pdfindex_add`: `{"path","title","pieces":[...],"size"?,"sha256"?}` -> `{"pieces": total, "committed": n}`. Replaces any
/// pieces of that path. `size` and `sha256` are those of the PDF's bytes; they go in the snapshot's `pdfs.tsv`.
pub fn add(session: u64, params_json: &str) -> Result<String> {
    let v: Value = serde_json::from_str(params_json)?;
    let path = v
        .get("path")
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
        .ok_or_else(|| Error::bad_json("path must be a non-empty string"))?;
    let title = v.get("title").and_then(Value::as_str).unwrap_or("");
    let title =
        if title.trim().is_empty() { path.rsplit('/').next().unwrap_or(path).trim_end_matches(".pdf") } else { title };
    let pieces = parse_pieces(v.get("pieces").unwrap_or(&Value::Null))?;
    let (size, sha) = optional_size_and_sha(&v)?;
    let s = session_of(session)?;
    let mut s = lock_s(&s);
    put_pdf(&mut s, path, title, &pieces, size, &sha)?;
    Ok(json!({"pieces": s.pieces(), "committed": s.rec.lines}).to_string())
}

/// `cs_pdfindex_reuse`: `{"path","sha256"}` -> `{"reused":true,"pieces":n}` when the older edition's snapshot (see `open`) holds
/// that PDF with that sha256: its stored pieces are copied (no extraction, no chunking). `{"reused":false}` otherwise.
pub fn reuse(session: u64, params_json: &str) -> Result<String> {
    let v: Value = serde_json::from_str(params_json)?;
    let path = v
        .get("path")
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
        .ok_or_else(|| Error::bad_json("path must be a non-empty string"))?;
    let (_, sha) = optional_size_and_sha(&v)?;
    let s = session_of(session)?;
    let mut s = lock_s(&s);
    let found = s.previous.as_ref().and_then(|pv| {
        let row = pv.rows.get(path).filter(|r| r.status == "added" && !sha.is_empty() && r.sha256 == sha)?;
        let stored = pv.index.pieces_of(path);
        (stored.len() as u64 == row.pieces && !stored.is_empty()).then_some((row.size, stored))
    });
    let Some((size, stored)) = found else { return Ok(json!({"reused": false}).to_string()) };
    let title = stored[0].title.clone();
    let pieces: Vec<NewPiece> = stored
        .into_iter()
        .map(|p| NewPiece {
            i: p.i,
            text: p.text,
            page: p.page,
            pdf_page: p.pdf_page,
            pdf_page_end: p.pdf_page_end,
            heading_path: p.heading_path,
        })
        .collect();
    put_pdf(&mut s, path, &title, &pieces, size, &sha)?;
    Ok(json!({"reused": true, "pieces": pieces.len()}).to_string())
}

/// `cs_pdfindex_skip`: `{"path","reason"}` -> `{"skipped": n}`.
pub fn skip(session: u64, params_json: &str) -> Result<String> {
    let v: Value = serde_json::from_str(params_json)?;
    let path = v
        .get("path")
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
        .ok_or_else(|| Error::bad_json("path must be a non-empty string"))?;
    let reason = v.get("reason").and_then(Value::as_str).unwrap_or("");
    if !matches!(reason, "no_text" | "locked" | "damaged") {
        return Err(Error::bad_json("reason must be no_text, locked or damaged"));
    }
    let (size, sha) = optional_size_and_sha(&v)?;
    let s = session_of(session)?;
    let mut s = lock_s(&s);
    let f = s.fields;
    if s.rec.done.remove(path).is_some() {
        // an earlier add of this path is replaced by the skip
        s.writer
            .as_mut()
            .ok_or_else(|| Error::internal("session is closed"))?
            .delete_term(Term::from_field_text(f.zim_path, path));
    }
    s.rec.skipped.insert(path.to_string(), Skipped { reason: reason.to_string(), size, sha256: sha.clone() });
    s.pending.push(line_for("s", path, reason, size, &sha));
    s.pending_pdfs += 1;
    if s.pending_pdfs >= s.batch_pdfs || s.last_commit.elapsed() >= Duration::from_secs(s.batch_secs) {
        s.commit()?;
    }
    Ok(json!({"skipped": s.rec.skipped.len()}).to_string())
}

/// `cs_pdfindex_close`: commit and keep `.build` for resume. -> `{"pieces","committed"}`.
pub fn close(session: u64) -> Result<String> {
    let s = session_of(session)?;
    let out = {
        let mut s = lock_s(&s);
        s.commit()?;
        let out = json!({"pieces": s.pieces(), "committed": s.rec.lines});
        if let Some(w) = s.writer.take() {
            tv(w.wait_merging_threads())?;
        }
        s.lock = None;
        out
    };
    if let Some(m) = lock_s(&SESSIONS).as_mut() {
        m.remove(&session);
    }
    Ok(out.to_string())
}

/// Test hook: the process "dies" without committing: the session is dropped and nothing else is written. (A real kill also
/// leaves the lock file, which the next open treats as stale.)
#[doc(hidden)]
pub fn abandon_for_test(session: u64) {
    let s = lock_s(&SESSIONS).as_mut().and_then(|m| m.remove(&session));
    if let Some(s) = s {
        let mut s = lock_s(&s);
        s.pending.clear();
        s.writer = None;
        s.lock = None;
    }
}

/// `cs_pdfindex_discard`: `{"indexes_dir","zim_uuid"}`: delete `.build`. `busy` while a session or the finish job has it open.
pub fn discard(params_json: &str) -> Result<String> {
    let (indexes_dir, zim_uuid) = dir_params(params_json)?;
    let build = pdfindex::dir_for(&indexes_dir, &zim_uuid).join(BUILD_DIR);
    if !build.exists() {
        return Ok(json!({"discarded": false}).to_string());
    }
    let lock = Lock::acquire(&build)?;
    drop(lock);
    std::fs::remove_dir_all(&build).map_err(|e| Error::io(format!("{}: {e}", build.display())))?;
    Ok(json!({"discarded": true}).to_string())
}

// ---------------------------------------------------------------------------------------------------------
// Finish

/// What `finish` needs, checked and locked by `prepare` before the job's thread starts.
pub struct FinishRequest {
    hold_ms: u64,
    dir: PathBuf,
    build: PathBuf,
    meta: BuildMeta,
    lock: Option<Lock>,
}

impl FinishRequest {
    /// The build lock, to be held by the job for its whole run.
    pub fn take_lock(&mut self) -> Option<Lock> {
        self.lock.take()
    }
}

/// Check the parameters and take the build lock: `not_found` without a build, `busy` while a session has it open.
pub fn prepare_finish(params_json: &str) -> Result<FinishRequest> {
    #[derive(Deserialize)]
    struct Hook {
        /// Not in the header: a test hook that pauses the job (cancellably) before the merge.
        #[serde(default)]
        hold_ms: u64,
    }
    let hold_ms = serde_json::from_str::<Hook>(params_json)?.hold_ms;
    let (indexes_dir, zim_uuid) = dir_params(params_json)?;
    let dir = pdfindex::dir_for(&indexes_dir, &zim_uuid);
    let build = dir.join(BUILD_DIR);
    if !build.join("meta.json").exists() {
        return Err(Error::not_found(format!("no pdf index build for zim {zim_uuid}")));
    }
    let lock = Lock::acquire(&build)?;
    let meta = read_build_meta(&build)
        .ok_or_else(|| Error::not_found(format!("{} is not a pdf index build", build.display())))?;
    if meta.format != FORMAT || meta.chunker != CHUNKER_VERSION {
        return Err(Error::unsupported("the build was made by another format or chunker; discard it and start again"));
    }
    Ok(FinishRequest { hold_ms, dir, build, meta, lock: Some(lock) })
}

/// `{"indexes_dir","zim_uuid"}`.
fn dir_params(params_json: &str) -> Result<(PathBuf, String)> {
    #[derive(Deserialize)]
    struct P {
        indexes_dir: String,
        zim_uuid: String,
    }
    let p: P = serde_json::from_str(params_json)?;
    if p.indexes_dir.is_empty() || !crate::zimsrc::is_uuid(&p.zim_uuid) {
        return Err(Error::bad_json("indexes_dir must not be empty and zim_uuid must be a uuid"));
    }
    Ok((PathBuf::from(p.indexes_dir), p.zim_uuid))
}

/// Merge, write the snapshot and publish it. `progress(phase, done, total)`; `cancelled()` is asked until the publish step.
/// Returns the outcome and, when done, the result `{"pdfs","pieces","skipped","bytes","snapshot"}`.
pub fn finish(
    req: &FinishRequest,
    progress: &dyn Fn(&str, u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<(Outcome, Option<Value>)> {
    let build = &req.build;
    let index = tv(Index::open_in_dir(build))?;
    index.tokenizers().register(ANALYZER, make_analyzer(&req.meta.tokenizer));
    let rec = load_done(build, payload_entries(&index));

    // 1. merge to one segment
    progress("merge", 0, 1);
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(req.hold_ms) && !cancelled() {
        std::thread::sleep(Duration::from_millis(10));
    }
    if cancelled() {
        return Ok((Outcome::Cancelled, None));
    }
    let mut writer = tv(index.writer_with_num_threads::<TantivyDocument>(1, 15_000_000))?;
    let segs = tv(index.searchable_segment_ids())?;
    if segs.len() > 1 {
        let _ = tv(writer.merge(&segs).wait())?;
    }
    tv(writer.garbage_collect_files().wait())?;
    tv(writer.wait_merging_threads())?;
    progress("merge", 1, 1);
    if cancelled() {
        return Ok((Outcome::Cancelled, None));
    }

    let docs = tv(index.reader())?.searcher().num_docs();
    // 2. pdfs.tsv (one row per PDF), then the snapshot's files, moved into the publish folder and hashed as they are read
    let mut rows: Vec<PdfRow> = rec
        .done
        .iter()
        .map(|(p, a)| PdfRow {
            path: p.clone(),
            size: a.size,
            sha256: a.sha256.clone(),
            pieces: a.pieces,
            status: "added".into(),
        })
        .chain(rec.skipped.iter().map(|(p, k)| PdfRow {
            path: p.clone(),
            size: k.size,
            sha256: k.sha256.clone(),
            pieces: 0,
            status: format!("skipped:{}", k.reason),
        }))
        .collect();
    rows.sort_by(|a, b| a.path.cmp(&b.path));
    std::fs::write(build.join(PDFS_FILE), pdfindex::rows_to_tsv(&rows))
        .map_err(|e| Error::io(format!("{PDFS_FILE}: {e}")))?;
    let Some(stage) = snapshot::stage(build, &NOT_IN_SNAPSHOT, &|d, t| progress("manifest", d, t + 1), cancelled)?
    else {
        return Ok((Outcome::Cancelled, None));
    };
    let (pdfs, skipped, bytes, build_id) =
        (rec.done.len() as u64, rec.skipped.len() as u64, stage.bytes, stage.build_id.clone());
    let mut extra = serde_json::Map::new();
    extra.insert("zim_uuid".into(), json!(req.meta.zim_uuid));
    extra.insert("zim_name".into(), json!(req.meta.zim_name));
    extra.insert("pdfs".into(), json!(pdfs));
    extra.insert("pieces".into(), json!(docs));
    extra.insert("skipped".into(), json!(skipped));
    let manifest = Manifest {
        kind: KIND.to_string(),
        source_id: req.meta.zim_uuid.clone(),
        format: FORMAT,
        tantivy: TANTIVY.to_string(),
        tokenizer: Some(Tokenizer {
            name: req.meta.tokenizer.clone(),
            analyzer: ANALYZER.to_string(),
            remove_long: 40,
        }),
        chunker: Some(CHUNKER_VERSION),
        core: env!("CARGO_PKG_VERSION").to_string(),
        created: snapshot::iso_now(),
        extra,
        files: Vec::new(),
    };
    if cancelled() {
        snapshot::abort(&stage);
        return Ok((Outcome::Cancelled, None));
    }

    // 3. publish: manifest last, one rename; the build is no longer needed
    progress("publish", 0, 1);
    snapshot::publish(&req.dir, stage, manifest)?;
    let _ = std::fs::remove_dir_all(build);
    progress("publish", 1, 1);
    Ok((
        Outcome::Done,
        Some(json!({"pdfs": pdfs, "pieces": docs, "skipped": skipped, "bytes": bytes, "snapshot": build_id})),
    ))
}
