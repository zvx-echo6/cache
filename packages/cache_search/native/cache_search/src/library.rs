//! Library sources: a Qdrant collection's shard opened read-only with Qdrant Edge.
//!
//! This slice covers settings, unpacking, the segment manifest, opening, dense (vector) search with the
//! leave-out post-filter, and reading a point. A library has no keyword list yet: the device keyword index
//! (`index_library`, the next slice) is not built, so until then a library contributes only its vector list
//! to a search, and only when the caller's query vector matches the library's embedding model.

use crate::error::{Error, Result};
use crate::html;
use common::universal_io::{MmapFile, MmapFs};
use edge::{
    CountRequest, EdgeShard, EdgeShardRead, JsonPath, LoadProfile, NamedQuery, PointId, QueryEnum, QueryRequestBuilder,
    ReadOnlyEdgeShard, RetrieveRequest, ScoringQuery, ScrollRequest, SearchParams, VectorInternal, WithPayloadInterface,
    WithVector,
};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Once;

pub type Shard = ReadOnlyEdgeShard<MmapFile>;

/// `hnsw_ef` for every dense search. Set here, not exposed to the app.
pub const HNSW_EF: usize = 64;
/// How many payloads are sampled to guess settings.
const GUESS_SAMPLE: usize = 20;
/// The segment manifest file Qdrant Edge's read-only open requires, at the shard root.
pub const MANIFEST_FILE: &str = "segments_manifest.json";

static INIT: Once = Once::new();

/// Qdrant's global feature flags must be initialised once, with the defaults, before any Edge use.
pub fn ensure_init() {
    INIT.call_once(|| common::flags::init_feature_flags(common::flags::FeatureFlags::default()));
}

fn op_io(what: &str, e: impl std::fmt::Display) -> Error {
    Error::io(format!("{what}: {e}"))
}

fn op_internal(what: &str, e: impl std::fmt::Display) -> Error {
    Error::internal(format!("{what}: {e}"))
}

// ---------------------------------------------------------------------------------------------------------
// Settings

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Fields {
    pub title: Option<String>,
    pub title_fallback: Option<String>,
    /// Required in a settings object; empty only while guessing found nothing.
    pub text: String,
    pub summary: Option<String>,
    pub page: Option<String>,
    pub source_type: Option<String>,
    pub author: Option<String>,
    pub link: Option<String>,
    pub document: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Rule {
    Equals(String, Value),
    IsSet(String, bool),
}

impl Rule {
    pub fn field(&self) -> &str {
        match self {
            Rule::Equals(f, _) | Rule::IsSet(f, _) => f,
        }
    }

    /// Whether this rule matches the payload (and so leaves the point out).
    pub fn matches(&self, payload: &Map<String, Value>) -> bool {
        let v = get_path(payload, self.field());
        match self {
            Rule::IsSet(_, want) => is_set(v) == *want,
            Rule::Equals(_, expected) => match v {
                None => false,
                Some(Value::Array(a)) if !expected.is_array() => a.iter().any(|x| json_eq(x, expected)),
                Some(x) => json_eq(x, expected),
            },
        }
    }
}

fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        _ => a == b,
    }
}

/// A field counts as set when it exists and is not null, an empty array or an empty string (what Qdrant's
/// "is empty" condition treats as empty, which is what the leave-out rule was measured against).
fn is_set(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::String(s)) => !s.is_empty(),
        Some(_) => true,
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Embedding {
    /// The dense vector's name; "" is the default vector.
    pub vector: String,
    pub model: String,
    pub sha256: String,
    pub dims: Option<usize>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LibrarySettings {
    pub library_id: String,
    pub title: String,
    pub fields: Fields,
    pub leave_out: Vec<Rule>,
    pub embedding: Embedding,
    /// The settings key: "auto" | "on" | "off".
    pub keyword_index: String,
    /// True when the settings were guessed from the payload (no settings object was given).
    pub guessed: bool,
}

impl LibrarySettings {
    /// The settings in the v1 layout, plus `"guessed"`. Shown by `cs_status`.
    pub fn to_json(&self) -> Value {
        let f = &self.fields;
        json!({
            "format": 1,
            "library_id": self.library_id,
            "title": self.title,
            "fields": {
                "title": f.title, "title_fallback": f.title_fallback, "text": f.text, "summary": f.summary,
                "page": f.page, "source_type": f.source_type, "author": f.author, "link": f.link,
                "document": f.document,
            },
            "leave_out": self.leave_out.iter().map(|r| match r {
                Rule::Equals(field, v) => json!({"field": field, "equals": v}),
                Rule::IsSet(field, b) => json!({"field": field, "is_set": b}),
            }).collect::<Vec<_>>(),
            "embedding": {
                "vector": self.embedding.vector, "model": self.embedding.model,
                "sha256": self.embedding.sha256, "dims": self.embedding.dims,
            },
            "keyword_index": self.keyword_index,
            "guessed": self.guessed,
        })
    }

    /// Parse the v1 settings object. Unknown keys are ignored.
    pub fn parse(v: &Value) -> Result<LibrarySettings> {
        let o = v.as_object().ok_or_else(|| Error::bad_json("library settings must be an object"))?;
        if let Some(fv) = o.get("format") {
            if fv.as_u64() != Some(1) {
                return Err(Error::unsupported(format!("library settings format {fv} is not supported")));
            }
        }
        let library_id = req_str(o, "library_id", "settings")?;
        let title = opt_str(o, "title", "settings")?.unwrap_or_else(|| library_id.clone());
        let fo = match o.get("fields") {
            Some(Value::Object(f)) => f,
            _ => return Err(Error::bad_json("library settings need a \"fields\" object")),
        };
        let fields = Fields {
            title: opt_str(fo, "title", "fields")?,
            title_fallback: opt_str(fo, "title_fallback", "fields")?,
            text: opt_str(fo, "text", "fields")?
                .ok_or_else(|| Error::bad_json("library settings need fields.text"))?,
            summary: opt_str(fo, "summary", "fields")?,
            page: opt_str(fo, "page", "fields")?,
            source_type: opt_str(fo, "source_type", "fields")?,
            author: opt_str(fo, "author", "fields")?,
            link: opt_str(fo, "link", "fields")?,
            document: opt_str(fo, "document", "fields")?,
        };
        let mut leave_out = Vec::new();
        match o.get("leave_out") {
            None | Some(Value::Null) => {}
            Some(Value::Array(a)) => {
                for r in a {
                    let ro = r.as_object().ok_or_else(|| Error::bad_json("leave_out rules must be objects"))?;
                    let field = req_str(ro, "field", "leave_out rule")?;
                    if let Some(eq) = ro.get("equals") {
                        leave_out.push(Rule::Equals(field, eq.clone()));
                    } else if let Some(s) = ro.get("is_set") {
                        let b = s.as_bool().ok_or_else(|| Error::bad_json("leave_out is_set must be true or false"))?;
                        leave_out.push(Rule::IsSet(field, b));
                    } else {
                        return Err(Error::bad_json("a leave_out rule needs \"equals\" or \"is_set\""));
                    }
                }
            }
            Some(_) => return Err(Error::bad_json("leave_out must be an array")),
        }
        let embedding = match o.get("embedding") {
            None | Some(Value::Null) => Embedding { vector: String::new(), model: String::new(), sha256: String::new(), dims: None },
            Some(Value::Object(e)) => Embedding {
                vector: match e.get("vector") {
                    None | Some(Value::Null) => String::new(),
                    Some(Value::String(s)) => s.clone(),
                    Some(_) => return Err(Error::bad_json("embedding.vector must be a string")),
                },
                model: opt_str(e, "model", "embedding")?.unwrap_or_default(),
                sha256: opt_str(e, "sha256", "embedding")?.unwrap_or_default(),
                dims: match e.get("dims") {
                    None | Some(Value::Null) => None,
                    Some(d) => Some(d.as_u64().ok_or_else(|| Error::bad_json("embedding.dims must be a number"))? as usize),
                },
            },
            Some(_) => return Err(Error::bad_json("embedding must be an object")),
        };
        let keyword_index = match o.get("keyword_index") {
            None | Some(Value::Null) => "auto".to_string(),
            Some(Value::String(s)) if matches!(s.as_str(), "auto" | "on" | "off") => s.clone(),
            Some(_) => return Err(Error::bad_json("keyword_index must be \"auto\", \"on\" or \"off\"")),
        };
        Ok(LibrarySettings { library_id, title, fields, leave_out, embedding, keyword_index, guessed: false })
    }
}

fn opt_str(o: &Map<String, Value>, k: &str, ctx: &str) -> Result<Option<String>> {
    match o.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.is_empty() => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(Error::bad_json(format!("{ctx}.{k} must be a string or null"))),
    }
}

fn req_str(o: &Map<String, Value>, k: &str, ctx: &str) -> Result<String> {
    opt_str(o, k, ctx)?.ok_or_else(|| Error::bad_json(format!("{ctx} needs \"{k}\"")))
}

fn get_path<'a>(m: &'a Map<String, Value>, path: &str) -> Option<&'a Value> {
    if let Some(v) = m.get(path) {
        return Some(v);
    }
    let mut it = path.split('.');
    let mut cur = m.get(it.next()?)?;
    for p in it {
        cur = cur.as_object()?.get(p)?;
    }
    Some(cur)
}

fn scalar_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) if !s.trim().is_empty() => Some(s.clone()),
        Value::Number(n) => Some(num_text(n)),
        _ => None,
    }
}

fn num_text(n: &serde_json::Number) -> String {
    match n.as_f64() {
        Some(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", f as i64),
        _ => n.to_string(),
    }
}

// ---------------------------------------------------------------------------------------------------------
// Unpacking and the segment manifest

fn looks_like_uuid(s: &str) -> bool {
    s.len() == 36
        && s.char_indices().all(|(i, c)| if matches!(i, 8 | 13 | 18 | 23) { c == '-' } else { c.is_ascii_hexdigit() })
}

/// Write `segments_manifest.json` at the shard root: every `segments/<uuid>` directory listed as "active".
/// Returns the number of segments listed. Replaces an existing file (atomically, by rename).
pub fn write_segments_manifest(shard_dir: &Path) -> Result<usize> {
    let segs = shard_dir.join("segments");
    let rd = std::fs::read_dir(&segs).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            Error::not_found(format!("{} has no segments directory", shard_dir.display()))
        } else {
            op_io(&format!("reading {}", segs.display()), e)
        }
    })?;
    let mut names: Vec<String> = Vec::new();
    for ent in rd {
        let ent = ent.map_err(|e| op_io("reading segments", e))?;
        let name = ent.file_name().to_string_lossy().into_owned();
        if ent.path().is_dir() && looks_like_uuid(&name) {
            names.push(name.to_ascii_lowercase());
        }
    }
    if names.is_empty() {
        return Err(Error::unsupported(format!("{} has no segments", shard_dir.display())));
    }
    names.sort();
    let mut m = Map::new();
    for n in &names {
        m.insert(n.clone(), Value::String("active".into()));
    }
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = shard_dir.join(format!("{MANIFEST_FILE}.{}.{seq}.tmp", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec(&Value::Object(m)).expect("json")).map_err(|e| op_io("writing manifest", e))?;
    std::fs::rename(&tmp, shard_dir.join(MANIFEST_FILE)).map_err(|e| op_io("writing manifest", e))?;
    Ok(names.len())
}

/// Write the manifest only when it is missing. Returns whether it wrote one.
pub fn ensure_segments_manifest(shard_dir: &Path) -> Result<bool> {
    if shard_dir.join(MANIFEST_FILE).exists() {
        return Ok(false);
    }
    write_segments_manifest(shard_dir)?;
    Ok(true)
}

/// Unpack a Qdrant shard snapshot into `dir` (created if missing) and write its manifest.
/// Returns the number of segments. For jobs and the CLI.
pub fn unpack_library(snapshot_file: &Path, dir: &Path) -> Result<usize> {
    ensure_init();
    std::fs::create_dir_all(dir).map_err(|e| op_io(&format!("creating {}", dir.display()), e))?;
    EdgeShard::unpack_snapshot(snapshot_file, dir).map_err(|e| op_io("unpacking snapshot", e))?;
    write_segments_manifest(dir)
}

// ---------------------------------------------------------------------------------------------------------
// Opening

/// An open library.
pub struct LibSlot {
    pub path: PathBuf,
    pub index_dir: Option<PathBuf>,
    pub settings: LibrarySettings,
    pub shard: Shard,
    pub docs: usize,
}

/// The library's folder name, used as its id and title when settings are guessed.
fn dir_name(path: &Path) -> String {
    path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Settings for a library: parsed from `given` or, without it, guessed from a payload sample and the shard.
pub fn resolve_settings(shard: &Shard, path: &Path, given: Option<&Value>) -> Result<LibrarySettings> {
    match given {
        Some(v) => {
            let mut s = LibrarySettings::parse(v)?;
            if s.embedding.dims.is_none() {
                s.embedding.dims = vector_dims(shard, &s.embedding.vector);
            }
            Ok(s)
        }
        None => guess_settings(shard, path),
    }
}

fn vector_dims(shard: &Shard, vector: &str) -> Option<usize> {
    EdgeShardRead::config_snapshot(shard).vectors.get(vector).map(|p| p.size)
}

fn guess_settings(shard: &Shard, path: &Path) -> Result<LibrarySettings> {
    let mut sr = ScrollRequest::new();
    sr.limit = Some(GUESS_SAMPLE);
    sr.with_payload = Some(WithPayloadInterface::Bool(true));
    sr.with_vector = WithVector::Bool(false);
    let (recs, _) = EdgeShardRead::scroll(shard, sr).map_err(|e| op_internal("sampling payloads", e))?;
    let present = |name: &str| -> bool {
        recs.iter().any(|r| r.payload.as_ref().map(|p| is_set(get_path(&p.0, name))).unwrap_or(false))
    };
    let first = |names: &[&str]| -> Option<String> { names.iter().find(|n| present(n)).map(|n| n.to_string()) };
    let only = |name: &str| -> Option<String> { present(name).then(|| name.to_string()) };
    let text = first(&["content", "text", "body"]).ok_or_else(|| {
        Error::unsupported("cannot guess the library settings: no content, text or body field in the payload sample")
    })?;
    let id = dir_name(path);
    Ok(LibrarySettings {
        library_id: id.clone(),
        title: id,
        fields: Fields {
            title: first(&["title", "name"]),
            title_fallback: only("book_title"),
            text,
            summary: only("summary"),
            page: only("_start_page"),
            source_type: only("source_type"),
            author: only("book_author"),
            link: None,
            document: only("doc_hash"),
        },
        leave_out: Vec::new(),
        embedding: Embedding { vector: String::new(), model: String::new(), sha256: String::new(), dims: vector_dims(shard, "") },
        keyword_index: "auto".into(),
        guessed: true,
    })
}

/// Open a library read-only. Writes nothing to the shard except `segments_manifest.json` when it is missing.
pub fn open_library(path: &Path, index_dir: Option<PathBuf>, settings: Option<&Value>) -> Result<LibSlot> {
    ensure_init();
    // A bad settings object is reported first, before the folder check and the (slow) open.
    let pre = settings.map(LibrarySettings::parse).transpose()?;
    if !path.is_dir() {
        return Err(Error::not_found(format!("library folder {} not found", path.display())));
    }
    ensure_segments_manifest(path)?;
    let vector = pre.as_ref().map(|s| s.embedding.vector.clone()).unwrap_or_default();
    let profile = LoadProfile::for_search(&vector, None, true);
    let shard = Shard::open(MmapFs, path, None, Some(profile)).map_err(|e| op_io(&format!("opening {}", path.display()), e))?;
    let settings = resolve_settings(&shard, path, settings)?;
    let docs = EdgeShardRead::count(&shard, CountRequest::new()).map_err(|e| op_internal("counting points", e))?;
    Ok(LibSlot { path: path.to_path_buf(), index_dir, settings, shard, docs })
}

// ---------------------------------------------------------------------------------------------------------
// Search and read

/// A library hit, ready to merge.
#[derive(Debug, Clone)]
pub struct LibHit {
    pub address: String,
    pub score: f32,
    pub title: String,
    pub snippet: String,
    pub page: Value,
    /// The key duplicates collapse on: document value + title when a document field is mapped and set,
    /// else title + snippet.
    pub key: String,
}

pub struct ReadOut {
    pub title: String,
    pub text: String,
    pub author: Value,
    pub page: Value,
    pub source_type: Value,
}

impl LibSlot {
    pub fn id(&self) -> &str {
        &self.settings.library_id
    }

    /// Whether a query vector of this model and length can be used on this library.
    pub fn accepts_vector(&self, model: &str, len: usize) -> bool {
        let e = &self.settings.embedding;
        !model.is_empty() && e.model == model && e.dims.map(|d| d == len).unwrap_or(true)
    }

    fn payload_fields(&self) -> Vec<String> {
        let f = &self.settings.fields;
        let mut v: Vec<String> = vec![f.text.clone()];
        for x in [&f.title, &f.title_fallback, &f.summary, &f.page, &f.source_type, &f.author, &f.document] {
            if let Some(n) = x {
                v.push(n.clone());
            }
        }
        for r in &self.settings.leave_out {
            v.push(r.field().to_string());
        }
        v.sort();
        v.dedup();
        v
    }

    fn payload_selector(&self) -> WithPayloadInterface {
        let parsed: std::result::Result<Vec<JsonPath>, ()> = self.payload_fields().iter().map(|s| s.parse::<JsonPath>().map_err(|_| ())).collect();
        match parsed {
            Ok(p) => WithPayloadInterface::Fields(p),
            Err(()) => WithPayloadInterface::Bool(true),
        }
    }

    fn left_out(&self, p: &Map<String, Value>) -> bool {
        self.settings.leave_out.iter().any(|r| r.matches(p))
    }

    fn text_field(&self, p: &Map<String, Value>, name: &Option<String>) -> Option<String> {
        name.as_ref().and_then(|n| get_path(p, n)).and_then(scalar_text)
    }

    fn page_value(&self, p: &Map<String, Value>) -> Value {
        match self.settings.fields.page.as_ref().and_then(|n| get_path(p, n)) {
            Some(v @ Value::Number(_)) => v.clone(),
            Some(Value::String(s)) if !s.trim().is_empty() => Value::String(s.clone()),
            _ => Value::Null,
        }
    }

    fn page_text(&self, p: &Map<String, Value>) -> Option<String> {
        match self.page_value(p) {
            Value::Number(n) => Some(num_text(&n)),
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    fn base_title(&self, p: &Map<String, Value>) -> String {
        let f = &self.settings.fields;
        self.text_field(p, &f.title).or_else(|| self.text_field(p, &f.title_fallback)).unwrap_or_default()
    }

    /// The result title: the mapped title (else the fallback), with ", p. <page>" when a page is mapped and set.
    fn hit_title(&self, p: &Map<String, Value>) -> String {
        let t = self.base_title(p);
        match self.page_text(p) {
            Some(pg) if t.is_empty() => format!("p. {pg}"),
            Some(pg) => format!("{t}, p. {pg}"),
            None => t,
        }
    }

    fn snippet(&self, p: &Map<String, Value>, max: usize) -> String {
        let f = &self.settings.fields;
        let src = self.text_field(p, &f.summary).or_else(|| get_path(p, &f.text).and_then(scalar_text)).unwrap_or_default();
        html::snippet_from_text(&src, max)
    }

    fn address(&self, id: &PointId) -> String {
        format!("lib:{}/{}", self.settings.library_id, id)
    }

    /// Dense search with `vector`. Fetches `base` candidates, drops left-out points, and if fewer than `need`
    /// distinct hits survive, widens to 2x then 4x `base` and stops. Hits are in rank order.
    pub fn dense_search(&self, vector: &[f32], need: usize, base: usize, snippet_chars: usize) -> Result<Vec<LibHit>> {
        let name = &self.settings.embedding.vector;
        let selector = self.payload_selector();
        let base = base.max(need).max(1);
        let mut hits: Vec<LibHit> = Vec::new();
        for width in [base, base * 2, base * 4] {
            let nq = if name.is_empty() {
                NamedQuery::default_dense(vector.to_vec())
            } else {
                NamedQuery::new(VectorInternal::Dense(vector.to_vec()), name.clone())
            };
            let mut params = SearchParams::default();
            params.hnsw_ef = Some(HNSW_EF);
            let req = QueryRequestBuilder::new(width)
                .query(ScoringQuery::Vector(QueryEnum::Nearest(nq)))
                .params(params)
                .with_payload(selector.clone())
                .build();
            let res = EdgeShardRead::query(&self.shard, req).map_err(|e| op_internal("dense search", e))?;
            let returned = res.len();
            hits.clear();
            let mut keys: Vec<String> = Vec::new();
            for sp in res {
                let empty = Map::new();
                let p = sp.payload.as_ref().map(|p| &p.0).unwrap_or(&empty);
                if self.left_out(p) {
                    continue;
                }
                let title = self.hit_title(p);
                let snippet = self.snippet(p, snippet_chars);
                let key = match self.text_field(p, &self.settings.fields.document) {
                    Some(d) => format!("d\u{1}{d}\u{1}{title}"),
                    None => format!("t\u{1}{title}\u{1}{snippet}"),
                };
                if !keys.contains(&key) {
                    keys.push(key.clone());
                }
                hits.push(LibHit { address: self.address(&sp.id), score: sp.score, title, snippet, page: self.page_value(p), key });
            }
            if keys.len() >= need || returned < width {
                break;
            }
        }
        Ok(hits)
    }

    /// Read a point by its id as given in an address.
    pub fn read_point(&self, point_id: &str, max_chars: usize) -> Result<(ReadOut, bool)> {
        let id: PointId = point_id.parse().map_err(|_| Error::bad_json(format!("bad point id {point_id:?} in library address")))?;
        let mut req = RetrieveRequest::new(vec![id]);
        req.with_payload = Some(self.payload_selector());
        req.with_vector = Some(WithVector::Bool(false));
        let recs = EdgeShardRead::retrieve(&self.shard, req).map_err(|e| op_internal("reading point", e))?;
        let rec = recs
            .into_iter()
            .next()
            .ok_or_else(|| Error::not_found(format!("point {point_id} is not in library {}", self.settings.library_id)))?;
        let empty = Map::new();
        let p = rec.payload.as_ref().map(|p| &p.0).unwrap_or(&empty);
        let f = &self.settings.fields;
        let full = get_path(p, &f.text).and_then(scalar_text).unwrap_or_default();
        let (text, truncated) = html::cut_at_paragraph(full.trim(), max_chars);
        let opt = |name: &Option<String>| self.text_field(p, name).map(Value::String).unwrap_or(Value::Null);
        Ok((
            ReadOut {
                title: self.base_title(p),
                text,
                author: opt(&f.author),
                page: self.page_value(p),
                source_type: opt(&f.source_type),
            },
            truncated,
        ))
    }
}

/// Split `lib:<library-id>/<point-id>` at the last slash (a point id never contains one).
pub fn parse_lib_address(address: &str) -> Result<(&str, &str)> {
    let rest = address.strip_prefix("lib:").ok_or_else(|| Error::bad_json(format!("not a library address: {address:?}")))?;
    match rest.rfind('/') {
        Some(i) if i > 0 && i + 1 < rest.len() => Ok((&rest[..i], &rest[i + 1..])),
        _ => Err(Error::bad_json(format!("bad library address {address:?}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_split() {
        assert_eq!(parse_lib_address("lib:recon/42").unwrap(), ("recon", "42"));
        assert_eq!(parse_lib_address("lib:a/b/9f1c").unwrap(), ("a/b", "9f1c"));
        for bad in ["lib:", "lib:x", "lib:/1", "lib:x/", "zim:x/1"] {
            assert!(parse_lib_address(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn settings_parse_and_ignore_unknown() {
        let v = json!({"format":1,"library_id":"r","title":"R","extra":1,
            "fields":{"title":"title","title_fallback":null,"text":"content","summary":"summary","page":"_start_page","document":"doc_hash","zzz":1},
            "leave_out":[{"field":"junk","equals":true},{"field":"rep","is_set":true}],
            "embedding":{"vector":"","model":"m","sha256":"x","dims":16},"keyword_index":"off"});
        let s = LibrarySettings::parse(&v).unwrap();
        assert_eq!(s.library_id, "r");
        assert_eq!(s.fields.text, "content");
        assert_eq!(s.fields.title_fallback, None);
        assert_eq!(s.leave_out.len(), 2);
        assert_eq!(s.embedding.dims, Some(16));
        assert_eq!(s.keyword_index, "off");
        assert!(!s.guessed);
        for bad in [
            json!({"library_id":"r","fields":{}}),
            json!({"fields":{"text":"c"}}),
            json!({"library_id":"r","fields":{"text":"c"},"keyword_index":"own"}),
            json!({"library_id":"r","fields":{"text":"c"},"leave_out":[{"field":"x"}]}),
            json!({"format":2,"library_id":"r","fields":{"text":"c"}}),
            json!([]),
        ] {
            assert!(LibrarySettings::parse(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn rules() {
        let p = json!({"junk":true,"n":1,"rep":[],"rep2":["x"],"tags":["a","b"],"nested":{"k":"v"}});
        let p = p.as_object().unwrap();
        assert!(Rule::Equals("junk".into(), json!(true)).matches(p));
        assert!(!Rule::Equals("junk".into(), json!(false)).matches(p));
        assert!(Rule::Equals("n".into(), json!(1.0)).matches(p));
        assert!(Rule::Equals("tags".into(), json!("b")).matches(p));
        assert!(Rule::Equals("nested.k".into(), json!("v")).matches(p));
        assert!(!Rule::Equals("missing".into(), json!(null)).matches(p));
        assert!(!Rule::IsSet("rep".into(), true).matches(p));
        assert!(Rule::IsSet("rep".into(), false).matches(p));
        assert!(Rule::IsSet("rep2".into(), true).matches(p));
        assert!(!Rule::IsSet("missing".into(), true).matches(p));
    }

    #[test]
    fn uuid_shape() {
        assert!(looks_like_uuid("1b4e28ba-2fa1-11d2-883f-0016d3cca427"));
        assert!(!looks_like_uuid("tmp"));
        assert!(!looks_like_uuid("1b4e28ba-2fa1-11d2-883f-0016d3cca42g"));
    }
}
