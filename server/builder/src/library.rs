//! Packs to a normal Cache library: a read-write Qdrant Edge shard (one unnamed 1024-dimension Cosine vector), points
//! with the ids and payload fields of docs/LIBRARY-FORMAT.md, and `cache-library.json`. The result is checked with the
//! core's own `check_library`.

use crate::docs::{write_docs, Applied, DocEntry, Docs, Overrides, DOCS_FILE};
use crate::embed::DIMS;
use crate::error::{Error, Result};
use crate::pack::{read_pack, valid_doc_id, Pack, PackPiece, PACK_EXT};
use edge::{
    Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointId, PointInsertOperations, PointOperations, PointStruct, UpdateOperation,
    VectorStorageDatatype,
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// UUIDv5(URL namespace, "https://github.com/zvx-echo6/cache/library-point"), docs/LIBRARY-FORMAT.md.
pub const POINT_NAMESPACE: &str = "c4b95b91-e641-5c16-91a0-13ba2f6f7970";
/// The settings file, beside the shard and at the root of a `.cache-library`.
pub const SETTINGS_FILE: &str = "cache-library.json";
/// The per-document table written beside the shard.
pub const DOCUMENTS_FILE: &str = "documents.tsv";
/// The checksums of every other file in the folder.
pub const SUMS_FILE: &str = "SHA256SUMS";
/// The `source` payload value of every point (mapped as the library's source type).
pub const SOURCE_KIND: &str = "book";

/// The id of passage `index` of a document version.
pub fn point_uuid(doc_id: &str, doc_version: u32, index: u32) -> uuid::Uuid {
    let ns = uuid::Uuid::parse_str(POINT_NAMESPACE).expect("namespace");
    uuid::Uuid::new_v5(&ns, format!("{doc_id}:{doc_version}:{index}").as_bytes())
}

fn page_value(label: &str) -> Value {
    match label.parse::<u64>() {
        Ok(n) if label == n.to_string() => json!(n),
        _ => json!(label),
    }
}

/// Where a document came from inside a ZIM, recorded in two unmapped payload fields (`zim_id`, `zim_path`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZimRef {
    /// The ZIM header UUID, lowercase with dashes (8-4-4-4-12), as in the core's `zim:<uuid>/<path>` addresses.
    pub id: String,
    /// The entry path within the ZIM, as the core's `zim:` addresses carry it.
    pub path: String,
}

/// Whether `s` is a UUID in lowercase 8-4-4-4-12 form.
pub fn valid_zim_id(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == b'-',
            _ => c.is_ascii_digit() || (b'a'..=b'f').contains(&c),
        })
}

/// One document for the library writer: what a pack holds, without the pack. Anything that can make pieces with vectors
/// (packs, PDFs read from a ZIM, PDFs on disk) feeds the writer through this.
#[derive(Debug, Clone)]
pub struct LibDoc {
    pub title: String,
    /// Letters, digits, `.`, `_`, `-`; unique across the library.
    pub doc_id: String,
    pub doc_version: u32,
    /// BLAKE3 (hex) of the source PDF.
    pub source_blake3: String,
    /// The `link` payload value (empty when the document has no address).
    pub link: String,
    /// The `author` payload value (unmapped), when known.
    pub author: Option<String>,
    pub zim: Option<ZimRef>,
    /// Pages in the source PDF (the `pages` column of documents.tsv; empty when unknown).
    pub pages: Option<usize>,
    /// Each piece carries its own text, printed page label, PDF pages, heading path and vector.
    pub pieces: Vec<PackPiece>,
    /// What `docs.json` says about the document (division, title before and after). `None`: no division, the title as it is.
    pub entry: Option<DocEntry>,
}

impl LibDoc {
    /// The adapter from a pack.
    pub fn from_pack(pack: &Pack) -> LibDoc {
        let h = &pack.header;
        LibDoc {
            title: h.title.clone(),
            doc_id: h.doc_id.clone(),
            doc_version: h.doc_version,
            source_blake3: h.source.blake3.clone(),
            link: h.source.https.clone().unwrap_or_default(),
            author: None,
            zim: None,
            pages: Some(h.page_count),
            pieces: pack.pieces.clone(),
            entry: Some(DocEntry::new(&h.title, h.division.as_ref())),
        }
    }
}

/// The payload of piece `i` of a document: the fields today's libraries use (`title`, `text`, `page`, `source`, `link`,
/// `doc_id`, `doc_version`; the settings file maps these) plus fields the settings file does not map, so the model never
/// sees them and the keyword index does not cover them: `heading_path`, `pdf_page` and `pdf_page_end` (1-based PDF pages),
/// `page_end` (a page label, only when the piece crosses a page), `source_blake3`, and, when given, `author`, `zim_id` and
/// `zim_path`.
pub fn doc_payload(doc: &LibDoc, i: usize) -> Value {
    let p = &doc.pieces[i];
    let mut v = json!({
        "title": doc.title,
        "text": p.text,
        "page": page_value(&p.page),
        "source": SOURCE_KIND,
        "link": doc.link,
        "doc_id": doc.doc_id,
        "doc_version": doc.doc_version,
        "heading_path": p.heading_path,
        "source_blake3": doc.source_blake3,
    });
    if let Some(n) = p.pdf_page {
        v["pdf_page"] = json!(n);
    }
    if let Some(pe) = &p.page_end {
        v["page_end"] = page_value(pe);
    }
    if let Some(n) = p.pdf_page_end {
        v["pdf_page_end"] = json!(n);
    }
    if let Some(a) = &doc.author {
        v["author"] = json!(a);
    }
    if let Some(z) = &doc.zim {
        v["zim_id"] = json!(z.id);
        v["zim_path"] = json!(z.path);
    }
    v
}

/// The payload of piece `i` of a pack.
pub fn payload_of(pack: &Pack, i: usize) -> Value {
    let mut d = LibDoc::from_pack(pack);
    d.pieces = vec![pack.pieces[i].clone()];
    doc_payload(&d, 0)
}

/// How the shard stores its vectors. Packs always hold f32; this changes only the written shard. Queries are f32 either way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VectorDatatype {
    /// Single precision (Qdrant `float32`), the default.
    #[default]
    F32,
    /// Half precision (Qdrant `float16`): about half the vector storage. The choice lives only in the shard's own config
    /// (`cache-library.json` has no field for it), so a reader needs nothing extra.
    F16,
}

impl VectorDatatype {
    pub fn parse(s: &str) -> Option<VectorDatatype> {
        match s {
            "f32" => Some(VectorDatatype::F32),
            "f16" => Some(VectorDatatype::F16),
            _ => None,
        }
    }

    fn storage(self) -> VectorStorageDatatype {
        match self {
            VectorDatatype::F32 => VectorStorageDatatype::Float32,
            VectorDatatype::F16 => VectorStorageDatatype::Float16,
        }
    }
}

pub struct LibraryOptions {
    pub id: String,
    pub title: String,
    pub version: String,
    /// How the shard stores vectors (default f32).
    pub vector_datatype: VectorDatatype,
    /// Also write `<out>.cache-library` (the shard as a snapshot tar with the settings file at its root).
    pub archive: bool,
}

#[derive(Debug, Clone)]
pub struct LibraryReport {
    pub points: usize,
    pub documents: usize,
    pub shard_dir: PathBuf,
    pub settings_path: PathBuf,
    pub archive: Option<PathBuf>,
}

/// The pack files in a folder, sorted by name.
pub fn list_packs(dir: &Path) -> Result<Vec<PathBuf>> {
    let rd = std::fs::read_dir(dir).map_err(|e| Error::ctx(&format!("reading {}", dir.display()), e))?;
    let mut v: Vec<PathBuf> = rd
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == PACK_EXT) && !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')))
        .collect();
    v.sort();
    Ok(v)
}

/// Read the live packs of a folder: for each document id, the pack with the highest version.
pub fn live_packs(dir: &Path) -> Result<Vec<Pack>> {
    let mut best: std::collections::BTreeMap<String, Pack> = std::collections::BTreeMap::new();
    for p in list_packs(dir)? {
        let pack = read_pack(&p)?;
        let keep = best.get(&pack.header.doc_id).is_none_or(|b| b.header.doc_version < pack.header.doc_version);
        if keep {
            best.insert(pack.header.doc_id.clone(), pack);
        }
    }
    Ok(best.into_values().collect())
}

/// The settings file of a library written with a `docs.json`: [`library_settings`] plus `"docs": "docs.json"` (the only key added to
/// the shipped guide library's).
pub fn library_settings_with_docs(id: &str, title: &str, version: &str) -> Value {
    let mut s = library_settings(id, title, version);
    s["docs"] = json!(DOCS_FILE);
    s
}

/// The settings file of a library: the template with this library's id, title and version.
pub fn library_settings(id: &str, title: &str, version: &str) -> Value {
    let mut s = cache_search::libadd::template_settings();
    s["library_id"] = json!(id);
    s["title"] = json!(title);
    s["version"] = json!(version);
    s
}

/// Writes a library one document at a time: `shard/`, then (on [`LibraryWriter::finish`]) `cache-library.json`,
/// `documents.tsv` and `SHA256SUMS`. Any source of pieces with vectors uses it: packs (through [`LibDoc::from_pack`]), PDFs
/// read from a ZIM, PDFs on disk. It writes no `index/`: the keyword index is built on the device when the library is
/// added (`keyword_index` "auto"; the core's `index_library` job makes it in the app's `index_dir`), as for every library.
pub struct LibraryWriter {
    out: PathBuf,
    shard_dir: PathBuf,
    opts: LibraryOptions,
    shard: EdgeShard,
    points: usize,
    ids: std::collections::HashSet<String>,
    rows: Vec<String>,
    docs: Docs,
}

/// A tab-separated field: tabs and line breaks become spaces.
fn tsv_field(s: &str) -> String {
    s.chars().map(|c| if matches!(c, '\t' | '\n' | '\r') { ' ' } else { c }).collect()
}

impl LibraryWriter {
    /// Start a library in `out` (it must not exist, or be empty).
    pub fn create(out: &Path, opts: &LibraryOptions) -> Result<LibraryWriter> {
        if opts.id.trim().is_empty() {
            return Err(Error::new("the library needs an id"));
        }
        if out.exists() {
            let empty = std::fs::read_dir(out).map(|mut r| r.next().is_none()).unwrap_or(false);
            if !out.is_dir() || !empty {
                return Err(Error::new(format!("{} already exists", out.display())));
            }
        }
        let shard_dir = out.join("shard");
        std::fs::create_dir_all(&shard_dir).map_err(|e| Error::ctx(&format!("creating {}", shard_dir.display()), e))?;
        cache_search::library::ensure_init();
        // As libadd::make_blank_shard: one unnamed dense vector, Cosine, no write-ahead log; here it stays open to be written.
        let params = EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).datatype(opts.vector_datatype.storage()).build();
        let cfg = EdgeConfig::builder().vector("", params).wal_enabled(false).build();
        let shard = match EdgeShard::new(&shard_dir, cfg) {
            Ok(s) => s,
            Err(e) => {
                let _ = std::fs::remove_dir_all(out);
                return Err(Error::ctx("making the library shard", e));
            }
        };
        let opts = LibraryOptions { id: opts.id.clone(), title: opts.title.clone(), version: opts.version.clone(), vector_datatype: opts.vector_datatype, archive: opts.archive };
        Ok(LibraryWriter { out: out.to_path_buf(), shard_dir, opts, shard, points: 0, ids: Default::default(), rows: Vec::new(), docs: Docs::default() })
    }

    /// Add one document's pieces.
    pub fn add(&mut self, doc: &LibDoc) -> Result<()> {
        if !valid_doc_id(&doc.doc_id) {
            return Err(Error::new(format!("invalid doc_id {:?}: use letters, digits, '.', '_' and '-'", doc.doc_id)));
        }
        if doc.doc_version == 0 {
            return Err(Error::new(format!("{}: doc_version starts at 1", doc.doc_id)));
        }
        if !self.ids.insert(doc.doc_id.clone()) {
            return Err(Error::new(format!("doc_id {} is in the library twice", doc.doc_id)));
        }
        if let Some(z) = &doc.zim {
            if !valid_zim_id(&z.id) {
                return Err(Error::new(format!("{}: zim_id {:?} is not a lowercase 8-4-4-4-12 UUID", doc.doc_id, z.id)));
            }
            if z.path.is_empty() {
                return Err(Error::new(format!("{}: zim_path is empty", doc.doc_id)));
            }
        }
        let mut seen = std::collections::HashSet::new();
        for p in &doc.pieces {
            if p.vector.len() != DIMS {
                return Err(Error::new(format!("{} has {}-dimension vectors; a Cache library has {DIMS}", doc.doc_id, p.vector.len())));
            }
            if !seen.insert(p.index) {
                return Err(Error::new(format!("{}: piece index {} is used twice", doc.doc_id, p.index)));
            }
        }
        let up = |pts: Vec<_>| -> Result<()> {
            self.shard
                .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts))))
                .map_err(|e| Error::ctx("adding points", e))
        };
        let mut batch = Vec::new();
        for (i, p) in doc.pieces.iter().enumerate() {
            let id = PointId::Uuid(point_uuid(&doc.doc_id, doc.doc_version, p.index));
            batch.push(PointStruct::new(id, p.vector.clone(), doc_payload(doc, i)).0);
            if batch.len() >= 256 {
                up(std::mem::take(&mut batch))?;
            }
        }
        if !batch.is_empty() {
            up(batch)?;
        }
        self.points += doc.pieces.len();
        let mut entry = doc.entry.clone().unwrap_or_else(|| DocEntry::new(&doc.title, None));
        entry.title = doc.title.clone();
        self.docs.docs.insert(doc.doc_id.clone(), entry);
        self.rows.push(format!(
            "{}\t{}\t{}\t{}\t{}\t{}",
            doc.doc_id,
            doc.doc_version,
            tsv_field(&doc.title),
            doc.source_blake3,
            doc.pieces.len(),
            doc.pages.map(|n| n.to_string()).unwrap_or_default()
        ));
        Ok(())
    }

    /// Flush the shard and write `cache-library.json`, `documents.tsv` and `SHA256SUMS` (and the archive, when asked).
    pub fn finish(self) -> Result<LibraryReport> {
        let LibraryWriter { out, shard_dir, opts, shard, points, rows, docs, .. } = self;
        shard.flush().map_err(|e| Error::ctx("flushing the library shard", e))?;
        drop(shard);
        cache_search::library::write_segments_manifest(&shard_dir).map_err(|e| Error::ctx("writing the segments manifest", e.message))?;
        let settings = library_settings_with_docs(&opts.id, &opts.title, &opts.version);
        let settings_path = out.join(SETTINGS_FILE);
        let text = serde_json::to_string_pretty(&settings).map_err(|e| Error::ctx("settings", e))? + "\n";
        std::fs::write(&settings_path, &text).map_err(|e| Error::ctx(&format!("writing {}", settings_path.display()), e))?;
        let mut tsv = String::from("doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n");
        for r in &rows {
            tsv.push_str(r);
            tsv.push('\n');
        }
        let tsv_path = out.join(DOCUMENTS_FILE);
        std::fs::write(&tsv_path, tsv).map_err(|e| Error::ctx(&format!("writing {}", tsv_path.display()), e))?;
        write_docs(&out, &docs)?;
        write_sha256sums(&out)?;
        let archive = if opts.archive {
            let name = out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "library".into());
            let path = out.with_file_name(format!("{name}.cache-library"));
            write_archive(&shard_dir, &text, &docs.to_bytes()?, &path)?;
            Some(path)
        } else {
            None
        };
        Ok(LibraryReport { points, documents: rows.len(), shard_dir, settings_path, archive })
    }

    /// Give up: remove what was written.
    pub fn abandon(self) {
        let out = self.out.clone();
        drop(self);
        let _ = std::fs::remove_dir_all(out);
    }
}

/// The general writer: the documents (from packs, a ZIM's PDFs, or anything else that makes pieces with vectors) to the
/// library folder `out` (it must not exist, or be empty): `shard/`, `cache-library.json`, `documents.tsv`, `SHA256SUMS`.
pub fn write_library<I: IntoIterator<Item = LibDoc>>(out: &Path, opts: &LibraryOptions, docs: I) -> Result<LibraryReport> {
    let mut w = LibraryWriter::create(out, opts)?;
    for d in docs {
        if let Err(e) = w.add(&d) {
            w.abandon();
            return Err(e);
        }
    }
    if w.rows.is_empty() {
        w.abandon();
        return Err(Error::new("no documents to write"));
    }
    w.finish().inspect_err(|_| {
        let _ = std::fs::remove_dir_all(out);
    })
}

/// `SHA256SUMS` at the root of `dir`: `<sha256 hex>  <relative path>` for every file in the folder (sorted by path, `/`
/// separators), except itself. Checkable with `sha256sum -c SHA256SUMS`.
pub fn write_sha256sums(dir: &Path) -> Result<()> {
    use sha2::{Digest, Sha256};
    fn walk(base: &Path, dir: &Path, out: &mut Vec<String>) -> Result<()> {
        for e in std::fs::read_dir(dir).map_err(|e| Error::ctx(&format!("reading {}", dir.display()), e))? {
            let e = e.map_err(|e| Error::ctx("reading a folder", e))?;
            let path = e.path();
            let ft = e.file_type().map_err(|e| Error::ctx("reading a folder", e))?;
            if ft.is_dir() {
                walk(base, &path, out)?;
            } else if ft.is_file() {
                let rel = path.strip_prefix(base).unwrap_or(&path).components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect::<Vec<_>>().join("/");
                if rel != SUMS_FILE {
                    out.push(rel);
                }
            }
        }
        Ok(())
    }
    let mut files = Vec::new();
    walk(dir, dir, &mut files)?;
    files.sort();
    let mut text = String::new();
    for rel in &files {
        let mut f = std::fs::File::open(dir.join(rel)).map_err(|e| Error::ctx(&format!("reading {rel}"), e))?;
        let mut h = Sha256::new();
        std::io::copy(&mut f, &mut h).map_err(|e| Error::ctx(&format!("reading {rel}"), e))?;
        let hex: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        text.push_str(&format!("{hex}  {rel}\n"));
    }
    std::fs::write(dir.join(SUMS_FILE), text).map_err(|e| Error::ctx("writing SHA256SUMS", e))
}

/// Build the library folder `out` from the packs in `packs_dir` (the live pack of each document): `shard/`,
/// `cache-library.json`, `documents.tsv`, `SHA256SUMS`. A thin layer over [`write_library`].
pub fn build_library(packs_dir: &Path, out: &Path, opts: &LibraryOptions) -> Result<LibraryReport> {
    build_library_with(packs_dir, out, opts, &Overrides::default()).map(|(r, _)| r)
}

/// [`build_library`] with the labels and titles of a rebuild applied: each document's division and title in `docs.json` (and the
/// title in the search payloads and `documents.tsv`) come from `over` where it has a match, else from the pack.
pub fn build_library_with(packs_dir: &Path, out: &Path, opts: &LibraryOptions, over: &Overrides) -> Result<(LibraryReport, Applied)> {
    if opts.id.trim().is_empty() {
        return Err(Error::new("the library needs an id"));
    }
    let packs = live_packs(packs_dir)?;
    if packs.is_empty() {
        return Err(Error::new(format!("no packs (*.{PACK_EXT}) in {}", packs_dir.display())));
    }
    let embedder = packs[0].header.embedding.embedder.clone();
    for p in &packs {
        if p.header.embedding.dims != DIMS {
            return Err(Error::new(format!("{} has {}-dimension vectors; a Cache library has {DIMS}", p.header.doc_id, p.header.embedding.dims)));
        }
        if p.header.embedding.embedder != embedder {
            return Err(Error::new(format!(
                "the packs were embedded by different embedders ({embedder} and {}); they cannot share a library",
                p.header.embedding.embedder
            )));
        }
    }
    let mut applied = Applied::default();
    let docs: Vec<LibDoc> = packs
        .iter()
        .map(|p| {
            let mut d = LibDoc::from_pack(p);
            let e = over.entry(&p.header, &mut applied);
            d.title = e.title.clone();
            d.entry = Some(e);
            d
        })
        .collect();
    write_library(out, opts, docs).map(|r| (r, applied))
}

/// Pack the shard with the core's `pack_snapshot`, then add `cache-library.json` at the archive's root (the core's
/// snapshot packer writes only the shard; this appends one more tar entry before the end-of-archive marker).
fn write_archive(shard_dir: &Path, settings: &str, docs_json: &[u8], out: &Path) -> Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    let tmp = out.with_file_name(format!(".{}.tmp", out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()));
    cache_search::libadd::pack_snapshot(shard_dir, &tmp).map_err(|e| Error::ctx("packing the library", e.message))?;
    let mut f = std::fs::OpenOptions::new().read(true).write(true).open(&tmp).map_err(|e| Error::ctx("opening the snapshot", e))?;
    let len = f.metadata().map_err(|e| Error::ctx("snapshot size", e))?.len();
    if len < 1024 {
        return Err(Error::new("the snapshot is too short"));
    }
    f.seek(SeekFrom::Start(len - 1024)).map_err(|e| Error::ctx("snapshot", e))?;
    let mut tail = [0u8; 1024];
    f.read_exact(&mut tail).map_err(|e| Error::ctx("snapshot", e))?;
    if tail.iter().any(|b| *b != 0) {
        return Err(Error::new("the snapshot does not end with a tar end marker"));
    }
    f.seek(SeekFrom::Start(len - 1024)).map_err(|e| Error::ctx("snapshot", e))?;
    let mut b = tar::Builder::new(&mut f);
    let mut h = tar::Header::new_gnu();
    h.set_size(settings.len() as u64);
    h.set_mode(0o644);
    h.set_mtime(0);
    h.set_cksum();
    b.append_data(&mut h, SETTINGS_FILE, settings.as_bytes()).map_err(|e| Error::ctx("adding the settings file", e))?;
    let mut h = tar::Header::new_gnu();
    h.set_size(docs_json.len() as u64);
    h.set_mode(0o644);
    h.set_mtime(0);
    h.set_cksum();
    b.append_data(&mut h, DOCS_FILE, docs_json).map_err(|e| Error::ctx("adding docs.json", e))?;
    b.finish().map_err(|e| Error::ctx("finishing the archive", e))?;
    drop(b);
    f.sync_all().map_err(|e| Error::ctx("snapshot", e))?;
    std::fs::rename(&tmp, out).map_err(|e| Error::ctx("snapshot", e))
}

/// Check a built library folder with the core's own check: opens the shard read-only, counts the points, resolves the
/// settings. The result is the core's JSON (`docs`, `whole_library_only`, `resolved`, ...).
pub fn check_library_dir(dir: &Path) -> Result<Value> {
    let settings: Value = serde_json::from_slice(&std::fs::read(dir.join(SETTINGS_FILE)).map_err(|e| Error::ctx("reading cache-library.json", e))?)
        .map_err(|e| Error::ctx("cache-library.json", e))?;
    cache_search::libadd::check_library(&dir.join("shard"), Some(&settings)).map_err(|e| Error::ctx("library check", e.message))
}
