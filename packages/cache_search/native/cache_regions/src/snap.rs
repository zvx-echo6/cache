//! The fetched tile indexes (routing `region-index`, places `places-index`) as syncable snapshots (cache_snapshot).
//!
//! ```text
//! <indexes_dir>/region-index/<build>/snap/<build id>/    index.tsv + manifest.json (written last)
//! <indexes_dir>/places-index/<build>/snap/<build id>/
//! ```
//!
//! The source id is the server's build name; an index is immutable per build, so a snapshot is never replaced, only added for
//! a build the device does not have. The TSV is the gunzipped file the server publishes; the gzip file's SHA-256 (the one
//! `current.json` carries) is recorded in the manifest as `index_sha256`. Without an `indexes_dir` the engine keeps the index
//! where it always did, `<dir>/index/<build>.tsv` (`<dir>/places/index/` for places): the legacy place, which is also what
//! is read, and sealed into a snapshot, when an `indexes_dir` is given later.

use crate::index::Current;
use cache_snapshot::{self as snapshot, Compat, Manifest};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub(crate) const KIND_REGION: &str = "region-index";
pub(crate) const KIND_PLACES: &str = "places-index";
/// The one file of a snapshot.
pub(crate) const FILE: &str = "index.tsv";

fn compat_region(m: &Manifest) -> Result<(), String> {
    if m.format != 1 {
        return Err(format!("the index is format {}, this version of Cache reads format 1", m.format));
    }
    Ok(())
}

fn compat_places(m: &Manifest) -> Result<(), String> {
    compat_region(m)?;
    let schema = m.extra.get("tile_schema").and_then(Value::as_u64);
    if schema != Some(u64::from(cache_places::schema::TILE_SCHEMA)) {
        return Err(format!(
            "the places are in layout {schema:?}, this version reads {}",
            cache_places::schema::TILE_SCHEMA
        ));
    }
    Ok(())
}

/// Where a build's index is on this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Location {
    Snapshot,
    Legacy,
    None,
}

impl Location {
    pub fn as_str(self) -> &'static str {
        match self {
            Location::Snapshot => "snapshot",
            Location::Legacy => "legacy",
            Location::None => "none",
        }
    }
}

enum Src<'a> {
    Bytes(&'a [u8]),
    /// A file to move in (copied when a rename is not possible); put back if publishing fails.
    Move(&'a Path),
}

/// One kind's indexes: the snapshots under `indexes_dir` (when given) and the legacy folder.
pub(crate) struct IndexStore {
    root: Option<PathBuf>,
    kind: &'static str,
    places: bool,
    /// `<dir>/index` (routing) or `<dir>/places/index`.
    legacy: PathBuf,
    /// The `index_sha256` of each build's index as the last current.json known here named it (lower case).
    expect: Mutex<HashMap<String, String>>,
}

impl IndexStore {
    pub fn new(root: Option<&Path>, places: bool, legacy: PathBuf) -> IndexStore {
        IndexStore {
            root: root.map(Path::to_path_buf),
            kind: if places { KIND_PLACES } else { KIND_REGION },
            places,
            legacy,
            expect: Mutex::new(HashMap::new()),
        }
    }

    /// Remembers what current.json says the build's index checksum is (from the server, or cached in regions.sqlite).
    pub fn note(&self, c: &Current) {
        let mut m = self.expect.lock().unwrap_or_else(|e| e.into_inner());
        m.insert(c.build.clone(), c.index_sha256.to_ascii_lowercase());
    }

    /// The earliest-created usable snapshot of the build that matches the checksum current.json names, when it is known and
    /// the snapshot recorded one. A snapshot of another publish is skipped, not deleted. Of the matching ones every device
    /// picks the same (the `pick` rule). `Picked.usable` lists only the matching ones, so `gc` never removes the others.
    fn pick(&self, sd: &Path, build: &str) -> Option<snapshot::Picked> {
        let want = self.expect.lock().unwrap_or_else(|e| e.into_inner()).get(build).cloned();
        let mut ok: Vec<(String, String, Manifest)> = Vec::new();
        for name in snapshot::list(sd) {
            let Ok(m) = snapshot::verify(&sd.join(snapshot::SNAP_DIR).join(&name), self.kind, build, self.compat())
            else {
                continue;
            };
            let recorded = m.extra.get("index_sha256").and_then(Value::as_str);
            if let (Some(w), Some(r)) = (&want, recorded) {
                if !r.eq_ignore_ascii_case(w) {
                    continue;
                }
            }
            ok.push((m.created.clone(), name, m));
        }
        ok.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
        let usable: Vec<(String, String)> = ok.iter().map(|(c, n, _)| (c.clone(), n.clone())).collect();
        ok.into_iter().next().map(|(_, name, manifest)| snapshot::Picked {
            dir: sd.join(snapshot::SNAP_DIR).join(&name),
            name,
            manifest,
            usable,
        })
    }

    fn compat(&self) -> Compat {
        if self.places {
            compat_places
        } else {
            compat_region
        }
    }

    pub fn legacy_file(&self, build: &str) -> PathBuf {
        self.legacy.join(format!("{build}.tsv"))
    }

    fn source_dir(&self, build: &str) -> Option<PathBuf> {
        self.root.as_ref().map(|r| snapshot::source_dir(r, self.kind, build))
    }

    /// The build's index text and parsed form: from a verified snapshot, else from the legacy file (sealed into a snapshot
    /// when there is an `indexes_dir`). `parse` says whether the text is a usable index; a snapshot that verifies but does not
    /// parse is removed (this device only), a legacy file that does not parse is left to be overwritten by the next fetch.
    pub fn find<T>(&self, build: &str, seq: u64, parse: &dyn Fn(&str) -> Option<T>) -> Option<T> {
        if let Some(sd) = self.source_dir(build) {
            while let Some(p) = self.pick(&sd, build) {
                let parsed = std::fs::read_to_string(p.dir.join(FILE)).ok().and_then(|t| parse(&t));
                match parsed {
                    Some(v) => {
                        // Two devices that built at once: every device keeps the same one, this one deletes the other.
                        let _ = snapshot::gc(&sd, &p);
                        return Some(v);
                    }
                    None => {
                        if std::fs::remove_dir_all(&p.dir).is_err() {
                            break;
                        }
                    }
                }
            }
        }
        let legacy = self.legacy_file(build);
        let v = std::fs::read_to_string(&legacy).ok().and_then(|t| parse(&t))?;
        if self.root.is_some() {
            // Seal it: a move, so the bytes are not held twice. If that fails the legacy file keeps serving.
            let _ = self.publish(build, Src::Move(&legacy), 1, Map::new(), seq);
        }
        Some(v)
    }

    /// Keeps a freshly fetched (and already checked) index: as a snapshot, or, without an `indexes_dir` or when publishing
    /// fails, as the legacy file.
    pub fn save(&self, c: &Current, text: &str, seq: u64) -> std::io::Result<()> {
        if self.root.is_some() {
            let mut extra = Map::new();
            extra.insert("index_sha256".into(), json!(c.index_sha256.to_ascii_lowercase()));
            if self.publish(&c.build, Src::Bytes(text.as_bytes()), c.format, extra, seq).is_ok() {
                return Ok(());
            }
        }
        crate::write_whole(&self.legacy_file(&c.build), text.as_bytes(), seq)
    }

    fn publish(
        &self,
        build: &str,
        src: Src,
        format: u32,
        mut extra: Map<String, Value>,
        seq: u64,
    ) -> Result<(), String> {
        let sd = self.source_dir(build).ok_or("no indexes_dir")?;
        let work = snapshot::build_dir(&sd).join(format!("fetch-{}-{seq}", std::process::id()));
        let _ = std::fs::remove_dir_all(&work);
        std::fs::create_dir_all(&work).map_err(|e| e.to_string())?;
        let target = work.join(FILE);
        let mut moved: Option<&Path> = None;
        let put = match src {
            Src::Bytes(b) => crate::write_whole(&target, b, seq),
            Src::Move(p) => match std::fs::rename(p, &target) {
                Ok(()) => {
                    moved = Some(p);
                    Ok(())
                }
                Err(_) => std::fs::copy(p, &target).map(|_| ()),
            },
        };
        let copied_from = if let (Src::Move(p), None) = (&src, moved) { Some(*p) } else { None };
        let run = || -> Result<(), String> {
            put.map_err(|e| e.to_string())?;
            extra.insert("component".into(), json!(if self.places { "places" } else { "routing" }));
            if self.places {
                extra.insert("tile_schema".into(), json!(cache_places::schema::TILE_SCHEMA));
            }
            let stage = snapshot::stage(&work, &[], false, &|_, _| {}, &|| false).map_err(|e| e.to_string())?;
            let stage = stage.ok_or("cancelled")?;
            let manifest = Manifest {
                kind: self.kind.to_string(),
                source_id: build.to_string(),
                format,
                tantivy: String::new(),
                tokenizer: None,
                chunker: None,
                core: env!("CARGO_PKG_VERSION").to_string(),
                created: snapshot::iso_now(),
                extra,
                files: Vec::new(),
            };
            snapshot::publish(&sd, stage, manifest).map_err(|e| e.to_string())?;
            Ok(())
        };
        let res = run();
        match (&res, moved) {
            (Err(_), Some(p)) => {
                let _ = std::fs::rename(&target, p);
            }
            (Ok(()), None) => {
                if let Some(p) = copied_from {
                    let _ = std::fs::remove_file(p);
                }
            }
            _ => {}
        }
        let _ = std::fs::remove_dir_all(&work);
        res
    }

    /// The build is no longer kept: its snapshots and legacy file go (on this device only).
    pub fn forget(&self, build: &str) {
        let _ = std::fs::remove_file(self.legacy_file(build));
        if let Some(sd) = self.source_dir(build) {
            let _ = std::fs::remove_dir_all(sd);
        }
    }

    /// The newest build that has a verified snapshot here (by `created`), for a device that knows no build yet.
    pub fn newest_build(&self) -> Option<String> {
        let root = self.root.as_ref()?;
        let mut best: Option<(String, String)> = None;
        for e in std::fs::read_dir(root.join(self.kind)).ok()?.flatten() {
            let Some(build) = snapshot::decode_source_id(&e.file_name().to_string_lossy()) else { continue };
            if !crate::index::safe_build(&build) {
                continue;
            }
            if let Some(p) = snapshot::pick(&e.path(), self.kind, &build, self.compat()) {
                let created = p.manifest.created.clone();
                if best.as_ref().map(|(c, _)| created > *c).unwrap_or(true) {
                    best = Some((created, build));
                }
            }
        }
        best.map(|(_, b)| b)
    }

    /// Where the build's index is, without hashing anything (for `status`): a snapshot whose manifest and files are all
    /// there with the listed sizes counts.
    pub fn location(&self, build: &str) -> (Location, Vec<String>) {
        let mut names = Vec::new();
        if let Some(sd) = self.source_dir(build) {
            for name in snapshot::list(&sd) {
                let dir = sd.join(snapshot::SNAP_DIR).join(&name);
                let ok = std::fs::read(dir.join(snapshot::MANIFEST))
                    .ok()
                    .and_then(|b| serde_json::from_slice::<Manifest>(&b).ok())
                    .filter(|m| m.kind == self.kind && m.source_id == build && (self.compat())(m).is_ok())
                    .map(|m| {
                        m.files
                            .iter()
                            .all(|f| std::fs::metadata(dir.join(&f.path)).map(|md| md.len() == f.size).unwrap_or(false))
                    })
                    .unwrap_or(false);
                if ok {
                    names.push(name);
                }
            }
        }
        if !names.is_empty() {
            (Location::Snapshot, names)
        } else if self.legacy_file(build).is_file() {
            (Location::Legacy, names)
        } else {
            (Location::None, names)
        }
    }

    /// `{"kind", "source_id", "location", "snapshots": [build ids]}`.
    pub fn status(&self, build: &str) -> Value {
        let (loc, names) = self.location(build);
        json!({"kind": self.kind, "source_id": build, "location": loc.as_str(), "snapshots": names})
    }
}
