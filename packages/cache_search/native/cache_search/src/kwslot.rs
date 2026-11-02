//! The caption and EPUB indexes on a handle: the slots that verify and open their snapshots in the background, the status
//! entries, search by caption (`cs_captions_search`), `read` of their hits and the files inside EPUBs (`cs_zim_get` with `!/`).
//!
//! A slot exists for every saved video, ZIM and kind that has a published snapshot folder under the handle's `indexes_dir`
//! (see `kwindex.rs`); the handle looks again whenever it polls, so a snapshot published by a job or a sync is searched
//! without another `cs_set_sources`.

use crate::epub;
use crate::error::{Error, ErrorCode, Result};
use crate::handle::{Handle, Source};
use crate::html;
use crate::kwbuild;
use crate::kwindex::{self, KwHit, KwIndex, StoredPiece, CAPTIONS, ZIM_CAPTIONS, ZIM_EPUB};
use crate::snapshot;
use crate::vtt;
use crate::zimsrc::{self, RawEntry};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// One source's caption or EPUB index: its newest usable snapshot, verified and opened on a background thread.
pub struct KwSlot {
    pub kind: &'static str,
    /// A ZIM's uuid, or `<host>/<video uuid>`.
    pub source_id: String,
    /// The ZIM's title or the video's name.
    pub title: String,
    /// `<indexes_dir>/<kind>/<encoded source id>`.
    pub dir: PathBuf,
    /// The folders under `snap/` when the snapshot was chosen: another listing means another choice.
    listing: Vec<String>,
    pub state: KwState,
}

pub enum KwState {
    /// Verifying and opening on a background thread; the thread leaves its result (`None`: no usable snapshot) here.
    Opening(Arc<Mutex<Option<Option<KwIndex>>>>),
    Ready(Box<KwIndex>),
    /// No usable snapshot (none published, or none matches this core).
    None,
}

impl KwSlot {
    fn start(kind: &'static str, source_id: String, title: String, dir: PathBuf, listing: Vec<String>) -> KwSlot {
        let cell: Arc<Mutex<Option<Option<KwIndex>>>> = Arc::new(Mutex::new(None));
        let (c, p, id) = (cell.clone(), dir.clone(), source_id.clone());
        let spawned = std::thread::Builder::new()
            .name("cs-open-kwindex".into())
            .spawn(move || {
                let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    kwindex::pick(&p, kind, &id).and_then(|pk| {
                        let opened = KwIndex::open(kind, &pk.name, &pk.dir, pk.manifest.clone()).ok();
                        if opened.is_some() {
                            // local clean-up: usable duplicates and older ones go, the one in use and a rollback stay
                            snapshot::gc(&p, &pk);
                        }
                        opened
                    })
                }))
                .unwrap_or(None);
                if let Ok(mut g) = c.lock() {
                    *g = Some(r);
                }
            });
        let state = if spawned.is_ok() {
            KwState::Opening(cell)
        } else {
            KwState::None
        };
        KwSlot {
            kind,
            source_id,
            title,
            dir,
            listing,
            state,
        }
    }

    pub fn index(&self) -> Option<&KwIndex> {
        match &self.state {
            KwState::Ready(i) => Some(i),
            _ => None,
        }
    }

    pub(crate) fn poll(&mut self) {
        if let KwState::Opening(cell) = &self.state {
            let got = cell.lock().ok().and_then(|mut g| g.take());
            match got {
                Some(Some(i)) => self.state = KwState::Ready(Box::new(i)),
                Some(None) => self.state = KwState::None,
                None => {}
            }
        }
    }

    fn status(&self) -> Value {
        match &self.state {
            KwState::Ready(i) => {
                let mut v = kwindex::status_json(i);
                v["state"] = json!("ready");
                v
            }
            KwState::Opening(_) => json!({"kind": self.kind, "state": "opening"}),
            KwState::None => json!({"kind": self.kind, "state": "none"}),
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// What the ZIMs hold (found once, in the background)

#[derive(Clone, Copy)]
enum Scan {
    Running,
    Done { captions: u64, epubs: u64 },
}

static SCANS: Mutex<Option<HashMap<String, Scan>>> = Mutex::new(None);
/// One ZIM is scanned at a time.
static SCAN_ONE: Mutex<()> = Mutex::new(());

fn scan_state(uuid: &str, path: &Path) -> Option<(u64, u64)> {
    let mut g = SCANS.lock().unwrap_or_else(|e| e.into_inner());
    let map = g.get_or_insert_with(HashMap::new);
    match map.get(uuid) {
        Some(Scan::Done { captions, epubs }) => return Some((*captions, *epubs)),
        Some(Scan::Running) => return None,
        None => {}
    }
    map.insert(uuid.to_string(), Scan::Running);
    let (id, p) = (uuid.to_string(), path.to_path_buf());
    let spawned = std::thread::Builder::new().name("cs-scan-zim".into()).spawn(move || {
        let _one = SCAN_ONE.lock().unwrap_or_else(|e| e.into_inner());
        let found = zimsrc::ZimSource::open(&p)
            .and_then(|z| kwbuild::scan_zim(&z, true))
            .map(|m| (m.captions.len() as u64, m.epubs.len() as u64));
        let (captions, epubs) = found.unwrap_or((0, 0));
        SCANS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_or_insert_with(HashMap::new)
            .insert(id, Scan::Done { captions, epubs });
    });
    if spawned.is_err() {
        map.insert(uuid.to_string(), Scan::Done { captions: 0, epubs: 0 });
    }
    None
}

/// Whether the one-time look at the ZIM's entries (for status) has finished.
pub fn scan_finished(uuid: &str) -> bool {
    matches!(
        SCANS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .and_then(|m| m.get(uuid)),
        Some(Scan::Done { .. })
    )
}

// ---------------------------------------------------------------------------------------------------------
// The handle

impl Handle {
    /// The caption and EPUB index slots beside the ZIMs and the saved videos; slots whose `snap/` listing has not changed are
    /// kept as they are. Without an `indexes_dir` there are none.
    pub(crate) fn attach_kw_indexes(&mut self, mut old: Vec<KwSlot>) {
        self.sources.retain(|s| !matches!(s, Source::Kw(_)));
        let Some(root) = self.indexes_dir.clone() else { return };
        let mut want: Vec<(&'static str, String, String, PathBuf)> = Vec::new();
        for s in &self.sources {
            if let Source::Zim(z) = s {
                for kind in [ZIM_CAPTIONS, ZIM_EPUB] {
                    want.push((
                        kind,
                        z.src.id.clone(),
                        z.src.title.clone(),
                        kwindex::dir_for(&root, kind, &z.src.id),
                    ));
                }
            }
        }
        if let Some(video) = &self.ext.video {
            if let Ok(rd) = std::fs::read_dir(root.join(CAPTIONS)) {
                let mut names: Vec<String> = rd
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect();
                names.sort();
                for n in names {
                    let Some(id) = snapshot::decode_source_id(&n).filter(|i| kwbuild::valid_video_source(i)) else {
                        continue;
                    };
                    let Some((host, uuid)) = id.split_once('/') else {
                        continue;
                    };
                    // the index is searched while the video is saved on this device
                    let Ok(Some(m)) = video.manifest(host, uuid) else {
                        continue;
                    };
                    let title = m["title"]
                        .as_str()
                        .filter(|t| !t.is_empty())
                        .unwrap_or(uuid)
                        .to_string();
                    want.push((CAPTIONS, id.clone(), title, kwindex::dir_for(&root, CAPTIONS, &id)));
                }
            }
        }
        for (kind, id, title, dir) in want {
            if !dir.join(snapshot::SNAP_DIR).is_dir() {
                continue;
            }
            let listing = snapshot::list(&dir);
            let slot = match old
                .iter()
                .position(|o| o.kind == kind && o.source_id == id && o.dir == dir && o.listing == listing)
            {
                Some(k) => old.remove(k),
                None => KwSlot::start(kind, id, title, dir, listing),
            };
            self.sources.push(Source::Kw(slot));
        }
    }

    /// Look again for caption and EPUB snapshots (see the module comment).
    pub(crate) fn refresh_kw_indexes(&mut self) {
        let mut old: Vec<KwSlot> = Vec::new();
        let mut keep: Vec<Source> = Vec::with_capacity(self.sources.len());
        for s in std::mem::take(&mut self.sources) {
            match s {
                Source::Kw(mut k) => {
                    k.poll();
                    old.push(k);
                }
                other => keep.push(other),
            }
        }
        self.sources = keep;
        self.attach_kw_indexes(old);
    }

    /// The opened index of one source and kind, when it has one ready.
    pub fn kw_index(&self, kind: &str, source_id: &str) -> Option<&KwIndex> {
        let id = kwindex::norm_source_id(source_id);
        self.sources.iter().find_map(|s| match s {
            Source::Kw(p) if p.kind == kind && p.source_id == id => p.index(),
            _ => None,
        })
    }

    /// The status entries of the caption and EPUB indexes of a ZIM: `"captionsindex"` and `"epubindex"`, in the shape of
    /// `"pdfindex"` plus `entries`, `source_id` and `needs_build` (only when the ZIM has such entries or an index of that kind). `needs_build` is true when it has entries and no usable snapshot. Starts the
    /// background look at the ZIM's entries; until it is done the keys are absent.
    pub(crate) fn kw_status_for_zim(&self, uuid: &str, path: &Path) -> Vec<(&'static str, Value)> {
        let Some(_) = self.indexes_dir else { return Vec::new() };
        let counts = scan_state(uuid, path);
        let mut out = Vec::new();
        for (key, kind) in [("captionsindex", ZIM_CAPTIONS), ("epubindex", ZIM_EPUB)] {
            let slot = self.sources.iter().find_map(|s| match s {
                Source::Kw(p) if p.kind == kind && p.source_id == uuid => Some(p),
                _ => None,
            });
            let entries = counts.map(|(c, e)| if kind == ZIM_CAPTIONS { c } else { e });
            let mut v = slot
                .map(|p| p.status())
                .unwrap_or_else(|| json!({"kind": kind, "state": "none"}));
            let ready = matches!(slot.map(|p| &p.state), Some(KwState::Ready(_)));
            let Some(entries) = entries else {
                if slot.is_some() {
                    out.push((key, v));
                }
                continue;
            };
            if entries == 0 && slot.is_none() {
                continue;
            }
            v["source_id"] = json!(uuid);
            v["entries"] = json!(entries);
            // a snapshot being opened is not yet known to be usable; one that is published is not rebuilt
            let published = ready
                || kwindex::has_published(
                    &kwindex::dir_for(self.indexes_dir.as_deref().unwrap_or(Path::new("")), kind, uuid),
                    kind,
                    uuid,
                );
            v["needs_build"] = json!(entries > 0 && !published);
            out.push((key, v));
        }
        out
    }

    /// `cs_video_downloads` with, on each saved video that has caption files, `"captions": {"source_id","kind":"captions",
    /// "files","built","needs_build"}` (only when the handle has an `indexes_dir`). `source_id` is what `index_source` takes.
    pub fn video_downloads_json(&self) -> Result<String> {
        let out = self.ext.video_downloads()?;
        let Some(root) = &self.indexes_dir else { return Ok(out) };
        let mut v: Value = serde_json::from_str(&out)?;
        if let Some(list) = v["downloads"].as_array_mut() {
            for d in list {
                let files = d["captions"].as_array().map(|a| a.len()).unwrap_or(0);
                let (Some(inst), Some(uuid)) = (d["instance"].as_str(), d["uuid"].as_str()) else {
                    continue;
                };
                if files == 0 {
                    continue;
                }
                let id = format!("{inst}/{uuid}");
                let built = kwindex::has_published(&kwindex::dir_for(root, CAPTIONS, &id), CAPTIONS, &id);
                d["captions_index"] = json!({"source_id": kwindex::norm_source_id(&id), "kind": CAPTIONS, "files": files, "built": built, "needs_build": !built});
            }
        }
        Ok(v.to_string())
    }
}

// ---------------------------------------------------------------------------------------------------------
// Search by caption

#[derive(Deserialize)]
struct CaptionsQuery {
    query: String,
    #[serde(default)]
    k: Option<usize>,
    #[serde(default)]
    lang: Option<String>,
}

/// Hits kept per video.
const HITS_PER_VIDEO: usize = 3;

struct VideoHits {
    key: String,
    json: Value,
    score: f64,
}

impl Handle {
    /// `cs_captions_search`: `{"query","k"?,"lang"?}` -> `{"videos":[{"source_id","link","title","host","saved","hits":[{"start_s",
    /// "end_s","text","lang"}]}]}`. The videos whose captions match the query, best first (the saved videos and the videos in
    /// ZIMs), with up to 3 hits each.
    pub fn captions_search(&mut self, request_json: &str) -> Result<String> {
        self.poll_opening();
        let q: CaptionsQuery = serde_json::from_str(request_json)?;
        if q.query.trim().is_empty() {
            return Err(Error::bad_json("query must not be empty"));
        }
        let k = q.k.unwrap_or(10).max(1);
        let candidates = self.candidates_per_list.max(1) as usize * 2;
        let min_cov = self.min_term_coverage;
        let mut videos: Vec<VideoHits> = Vec::new();
        for s in &self.sources {
            let Source::Kw(p) = s else { continue };
            if p.kind != CAPTIONS && p.kind != ZIM_CAPTIONS {
                continue;
            }
            let Some(idx) = p.index() else { continue };
            let Ok((hits, _)) = idx.search(&q.query, candidates, q.lang.as_deref()) else {
                continue;
            };
            // by video: a saved video is one index; a ZIM's videos are told apart by the caption's video entry
            let mut groups: Vec<(String, Vec<KwHit>)> = Vec::new();
            for h in hits.into_iter().filter(|h| h.coverage >= min_cov) {
                let key = if p.kind == CAPTIONS {
                    p.source_id.clone()
                } else if h.piece.video.is_empty() {
                    format!("{}/{}", p.source_id, h.piece.item)
                } else {
                    format!("{}/{}", p.source_id, h.piece.video)
                };
                match groups.iter_mut().find(|g| g.0 == key) {
                    Some(g) => g.1.push(h),
                    None => groups.push((key, vec![h])),
                }
            }
            for (key, mut hs) in groups {
                hs.sort_by(|a, b| b.raw.total_cmp(&a.raw).then_with(|| a.piece.pid.cmp(&b.piece.pid)));
                hs.truncate(HITS_PER_VIDEO);
                let best = &hs[0];
                let score = best.raw as f64 * best.coverage as f64;
                let (link, title, host, saved, source_id) = if p.kind == CAPTIONS {
                    let host = p.source_id.split_once('/').map(|(h, _)| h.replacen('_', ":", 1));
                    (
                        kwindex::watch_link(&p.source_id),
                        p.title.clone(),
                        json!(host),
                        true,
                        p.source_id.clone(),
                    )
                } else {
                    let target = if best.piece.video.is_empty() {
                        &best.piece.item
                    } else {
                        &best.piece.video
                    };
                    (
                        zimsrc::format_address(&p.source_id, target),
                        best.piece.title.clone(),
                        Value::Null,
                        false,
                        p.source_id.clone(),
                    )
                };
                let hits_json: Vec<Value> = hs
                    .iter()
                    .map(|h| json!({"start_s": kwindex::secs(h.piece.start_ms), "end_s": kwindex::secs(h.piece.end_ms), "text": h.piece.text, "lang": h.piece.lang}))
                    .collect();
                videos.push(VideoHits {
                    key,
                    json: json!({"source_id": source_id, "link": link, "title": title, "host": host, "saved": saved, "hits": hits_json}),
                    score,
                });
            }
        }
        videos.sort_by(|a, b| b.score.total_cmp(&a.score).then_with(|| a.key.cmp(&b.key)));
        videos.truncate(k);
        Ok(json!({"videos": videos.into_iter().map(|v| v.json).collect::<Vec<_>>()}).to_string())
    }
}

// ---------------------------------------------------------------------------------------------------------
// Read

fn page_json(address: &str, title: &str, text: &str, truncated: bool) -> String {
    json!({"address": address, "title": title, "text": text, "truncated": truncated, "author": Value::Null, "page": Value::Null, "source_type": Value::Null})
        .to_string()
}

/// Seconds before and after a caption hit that `read` shows.
const READ_WINDOW_MS: u64 = 60_000;

/// The model-facing title of a caption hit.
pub fn caption_title(p: &StoredPiece) -> String {
    format!("{}, at {}", p.title, vtt::clock(p.start_ms))
}

/// The model-facing title of an EPUB hit: the book, and the chapter's heading.
pub fn epub_title(p: &StoredPiece) -> String {
    match p.heading_path.last().filter(|h| !h.trim().is_empty()) {
        Some(h) => format!("{}, {}", p.title, h),
        None => {
            let stem = p.chapter.rsplit('/').next().unwrap_or(&p.chapter);
            let stem = stem.rsplit_once('.').map(|(s, _)| s).unwrap_or(stem);
            if stem.is_empty() {
                p.title.clone()
            } else {
                format!("{}, {}", p.title, stem)
            }
        }
    }
}

impl Handle {
    /// `read` of a caption, ZIM caption or EPUB hit.
    pub(crate) fn read_kw(&self, address: &str, max_chars: usize) -> Result<String> {
        let (kind, source_id, pid) = kwindex::parse_address(address)?;
        let idx = self
            .kw_index(kind, &source_id)
            .ok_or_else(|| Error::not_found(format!("no {kind} index for {source_id:?}")))?;
        let hit = idx
            .get(&pid)
            .ok_or_else(|| Error::not_found(format!("no piece {pid:?} in the {kind} index of {source_id}")))?;
        if kind == ZIM_EPUB {
            return self.read_epub(address, &source_id, idx, &hit, max_chars);
        }
        // the passages from 60 s before to 60 s after, one line each: "[mm:ss] text"
        let (lo, hi) = (hit.start_ms.saturating_sub(READ_WINDOW_MS), hit.end_ms + READ_WINDOW_MS);
        let lines: Vec<String> = idx
            .pieces_of(&hit.item)
            .into_iter()
            .filter(|p| p.end_ms >= lo && p.start_ms <= hi)
            .map(|p| format!("[{}] {}", vtt::clock(p.start_ms), p.text))
            .collect();
        let full = if lines.is_empty() {
            format!("[{}] {}", vtt::clock(hit.start_ms), hit.text)
        } else {
            lines.join("\n")
        };
        let (text, truncated) = html::cut_at_paragraph(full.trim(), max_chars);
        Ok(page_json(address, &caption_title(&hit), &text, truncated))
    }

    fn read_epub(
        &self,
        address: &str,
        zim_id: &str,
        idx: &KwIndex,
        hit: &StoredPiece,
        max_chars: usize,
    ) -> Result<String> {
        let heading = hit.heading_path.last().cloned().unwrap_or_default();
        let head = if heading.is_empty() {
            String::new()
        } else {
            format!("Chapter: {heading}\n\n")
        };
        // the chapter's own text from the EPUB, a few blocks before the passage onward; the stored pieces when the EPUB cannot be read
        let from_epub = (|| -> Option<String> {
            let bytes = epub_bytes(self, zim_id, &hit.item).ok()?;
            let zip = epub::Zip::open(&bytes).ok()?;
            let xhtml = String::from_utf8_lossy(&zip.read(&hit.chapter).ok()?).into_owned();
            let blocks = epub::blocks(&xhtml);
            let first = hit.block.saturating_sub(3) as u32;
            let text: Vec<String> = blocks
                .into_iter()
                .filter(|b| b.n >= first && !b.text.is_empty())
                .map(|b| b.text)
                .collect();
            (!text.is_empty()).then(|| text.join("\n\n"))
        })();
        let body = from_epub.unwrap_or_else(|| {
            idx.chapter_pieces(&hit.item, &hit.chapter)
                .into_iter()
                .map(|p| p.text)
                .collect::<Vec<_>>()
                .join("\n\n")
        });
        let body = if body.trim().is_empty() { hit.text.clone() } else { body };
        let (text, truncated) = html::cut_at_paragraph(format!("{head}{body}").trim(), max_chars);
        Ok(page_json(address, &epub_title(hit), &text, truncated))
    }
}

// ---------------------------------------------------------------------------------------------------------
// Files inside an EPUB

static LAST_EPUB: Mutex<Option<(String, Arc<Vec<u8>>)>> = Mutex::new(None);

/// The bytes of an EPUB entry of a ZIM; the last one read is kept, since a chapter asks for its images and styles one by one.
fn epub_bytes(h: &Handle, zim_id: &str, epub_path: &str) -> Result<Arc<Vec<u8>>> {
    let key = format!("{zim_id}/{epub_path}");
    if let Some((k, b)) = LAST_EPUB.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        if *k == key {
            return Ok(b.clone());
        }
    }
    let e = h.zim(zim_id)?.get(epub_path)?;
    let bytes = Arc::new(e.bytes);
    *LAST_EPUB.lock().unwrap_or_else(|e| e.into_inner()) = Some((key, bytes.clone()));
    Ok(bytes)
}

impl Handle {
    /// `cs_zim_get` for `zim:<uuid>/<epub path>!/<inner path>`: the file inside the EPUB with its media type; for XHTML, with
    /// `id="cache-b<n>"` on every block element (the numbering the index uses). `Ok(None)` when the path has no `!/`.
    pub(crate) fn zim_get_in_epub(&self, zim_id: &str, path: &str) -> Result<Option<RawEntry>> {
        let path = path.split('#').next().unwrap_or(path);
        let Some((epub_path, inner)) = path.split_once("!/") else {
            return Ok(None);
        };
        if epub_path.is_empty() || inner.is_empty() {
            return Err(Error::not_found(format!("no file {inner:?} in epub {epub_path:?}")));
        }
        let bytes = epub_bytes(self, zim_id, epub_path)?;
        let zip = epub::Zip::open(&bytes)?;
        let candidates: Vec<String> = zimsrc::percent_decode(inner)
            .into_iter()
            .chain(std::iter::once(inner.to_string()))
            .collect();
        let name = candidates.iter().find(|c| zip.contains(c)).ok_or_else(|| {
            Error::new(
                ErrorCode::NotFound,
                format!("no file {inner:?} in epub {epub_path:?} of zim {zim_id}"),
            )
        })?;
        let mut data = zip.read(name)?;
        let mime = epub::mime_of(name);
        if mime == "application/xhtml+xml" || mime == "text/html" {
            data = epub::add_block_ids(&String::from_utf8_lossy(&data)).into_bytes();
        }
        let title = name.rsplit('/').next().unwrap_or(name).to_string();
        Ok(Some(RawEntry {
            bytes: data,
            mime: mime.to_string(),
            path: format!("{epub_path}!/{name}"),
            title,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn piece(title: &str, chapter: &str, path: &[&str]) -> StoredPiece {
        StoredPiece {
            title: title.into(),
            chapter: chapter.into(),
            heading_path: path.iter().map(|s| s.to_string()).collect(),
            start_ms: 754_000,
            ..Default::default()
        }
    }

    #[test]
    fn titles_the_model_sees() {
        assert_eq!(caption_title(&piece("Flood Safety", "", &[])), "Flood Safety, at 12:34");
        assert_eq!(
            epub_title(&piece("Field Guide", "OEBPS/ch1.xhtml", &["Part I", "Floods"])),
            "Field Guide, Floods"
        );
        assert_eq!(
            epub_title(&piece("Field Guide", "OEBPS/ch1.xhtml", &[])),
            "Field Guide, ch1"
        );
    }
}
