//! Document packs (`.cdoc`): the unit of change. See PACK-FORMAT.md (proposed; shared format pending owner/orchestrator
//! approval).
//!
//! A pack is a gzip-compressed JSON Lines file. Line 1 is the header; each following line is one piece. Vectors are
//! base64 of little-endian f32. Plain text under gzip was chosen over zstd/CBOR because it is inspectable with `zcat`, needs
//! no new crate (flate2 is already in the lockfile), and is deterministic: the same inputs give the same bytes.

use crate::error::{Error, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

/// The pack format version written to every header.
pub const PACK_FORMAT: u32 = 1;
pub const PACK_EXT: &str = "cdoc";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Source {
    /// BLAKE3 of the PDF bytes (hex).
    pub blake3: String,
    pub size: u64,
    pub file_name: String,
    /// Optional address the PDF can be fetched from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub https: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tool {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Chunker {
    pub version: u32,
    pub target_words: u32,
    pub max_words: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EmbeddingInfo {
    /// Which embedder made the vectors (the GGUF name for the real one, "fake-hash-v1" for the test stand-in).
    pub embedder: String,
    pub dims: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Header {
    pub cdoc: u32,
    pub doc_id: String,
    pub doc_version: u32,
    pub title: String,
    pub source: Source,
    pub extractor: Tool,
    pub chunker: Chunker,
    pub embedding: EmbeddingInfo,
    pub created_at: String,
    pub page_count: usize,
    /// 1-based PDF pages skipped because they have no text layer (OCR comes later).
    pub ocr_pages: Vec<usize>,
    pub pieces: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PackPiece {
    pub index: u32,
    pub text: String,
    /// The page label of the piece's first word.
    pub page: String,
    /// The 1-based PDF page of the piece's first word.
    pub pdf_page: u32,
    pub page_end: Option<String>,
    pub heading_path: Vec<String>,
    pub vector: Vec<f32>,
}

#[derive(Serialize, Deserialize)]
struct PieceLine {
    i: u32,
    text: String,
    page: String,
    pdf_page: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    page_end: Option<String>,
    heading_path: Vec<String>,
    vector: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    pub header: Header,
    pub pieces: Vec<PackPiece>,
}

/// The file name of a pack.
pub fn pack_file_name(doc_id: &str, doc_version: u32) -> String {
    format!("{doc_id}@{doc_version}.{PACK_EXT}")
}

/// A document id is used in file names and point ids: letters, digits, `.`, `_` and `-` only.
pub fn valid_doc_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

pub fn encode_vector(v: &[f32]) -> String {
    let mut bytes = Vec::with_capacity(v.len() * 4);
    for x in v {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

pub fn decode_vector(s: &str) -> Result<Vec<f32>> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(s).map_err(|e| Error::ctx("a piece vector is not base64", e))?;
    if bytes.len() % 4 != 0 {
        return Err(Error::new("a piece vector is not a whole number of f32 values"));
    }
    Ok(bytes.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect())
}

/// Serialise a pack to its bytes (gzip of JSON Lines).
pub fn pack_bytes(pack: &Pack) -> Result<Vec<u8>> {
    if pack.header.pieces != pack.pieces.len() {
        return Err(Error::new("the header's piece count does not match the pieces"));
    }
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(6));
    let h = serde_json::to_string(&pack.header).map_err(|e| Error::ctx("writing the header", e))?;
    writeln!(gz, "{h}").map_err(|e| Error::ctx("writing the pack", e))?;
    for p in &pack.pieces {
        let line = PieceLine {
            i: p.index,
            text: p.text.clone(),
            page: p.page.clone(),
            pdf_page: p.pdf_page,
            page_end: p.page_end.clone(),
            heading_path: p.heading_path.clone(),
            vector: encode_vector(&p.vector),
        };
        let s = serde_json::to_string(&line).map_err(|e| Error::ctx("writing a piece", e))?;
        writeln!(gz, "{s}").map_err(|e| Error::ctx("writing the pack", e))?;
    }
    gz.finish().map_err(|e| Error::ctx("writing the pack", e))
}

/// Write a pack into `dir` as `<doc_id>@<doc_version>.cdoc` (made under a temporary name, then renamed).
pub fn write_pack(pack: &Pack, dir: &Path) -> Result<PathBuf> {
    if !valid_doc_id(&pack.header.doc_id) {
        return Err(Error::new(format!("invalid doc_id {:?}: use letters, digits, '.', '_' and '-'", pack.header.doc_id)));
    }
    std::fs::create_dir_all(dir).map_err(|e| Error::ctx(&format!("creating {}", dir.display()), e))?;
    let name = pack_file_name(&pack.header.doc_id, pack.header.doc_version);
    let path = dir.join(&name);
    let tmp = dir.join(format!(".{name}.tmp"));
    let bytes = pack_bytes(pack)?;
    std::fs::write(&tmp, bytes).map_err(|e| Error::ctx(&format!("writing {}", tmp.display()), e))?;
    std::fs::rename(&tmp, &path).map_err(|e| Error::ctx(&format!("writing {}", path.display()), e))?;
    Ok(path)
}

/// Read a pack's bytes back. Checks the format version, the piece count and that every vector has the declared size.
pub fn read_pack_bytes(bytes: &[u8]) -> Result<Pack> {
    let gz = flate2::read::GzDecoder::new(bytes);
    let mut lines = std::io::BufReader::new(gz).lines();
    let first = lines.next().ok_or_else(|| Error::new("empty pack"))?.map_err(|e| Error::ctx("reading the pack", e))?;
    let header: Header = serde_json::from_str(&first).map_err(|e| Error::ctx("the pack header", e))?;
    if header.cdoc != PACK_FORMAT {
        return Err(Error::new(format!("pack format {} is not supported (this reads {PACK_FORMAT})", header.cdoc)));
    }
    let mut pieces = Vec::with_capacity(header.pieces);
    for l in lines {
        let l = l.map_err(|e| Error::ctx("reading the pack", e))?;
        if l.trim().is_empty() {
            continue;
        }
        let p: PieceLine = serde_json::from_str(&l).map_err(|e| Error::ctx("a pack piece", e))?;
        let vector = decode_vector(&p.vector)?;
        if vector.len() != header.embedding.dims {
            return Err(Error::new(format!("piece {} has {} dimensions, the header says {}", p.i, vector.len(), header.embedding.dims)));
        }
        pieces.push(PackPiece { index: p.i, text: p.text, page: p.page, pdf_page: p.pdf_page, page_end: p.page_end, heading_path: p.heading_path, vector });
    }
    if pieces.len() != header.pieces {
        return Err(Error::new(format!("the pack has {} pieces, the header says {}", pieces.len(), header.pieces)));
    }
    Ok(Pack { header, pieces })
}

pub fn read_pack(path: &Path) -> Result<Pack> {
    let bytes = std::fs::read(path).map_err(|e| Error::ctx(&format!("reading {}", path.display()), e))?;
    read_pack_bytes(&bytes).map_err(|e| Error::ctx(&path.display().to_string(), e))
}
