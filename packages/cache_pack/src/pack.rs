//! Document packs (`.cdoc`): the unit of change. See PACK-FORMAT.md (proposed; shared format pending owner/orchestrator
//! approval).
//!
//! A pack is a gzip-compressed JSON Lines file. Line 1 is the header; each following line is one piece. Vectors are
//! base64 of little-endian f32. Plain text under gzip was chosen over zstd/CBOR because it is inspectable with `zcat`, needs
//! no new crate (flate2 is already in the lockfile), and is deterministic: the same inputs give the same bytes.

use crate::compression::CompressionOutcome;
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
    /// The version of the layout step that turned the extracted pages into headings and paragraphs (`layout::LAYOUT_VERSION`);
    /// absent in packs written before it was recorded, and when the pages were laid out by something else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_version: Option<u32>,
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
    /// 1-based PDF pages whose text came from OCR; every other page's text came from the PDF's own text layer. Absent (empty):
    /// all from the text layer (revision 2 to 4 packs written before pages could be OCR'd).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub text_source_ocr_pages: Vec<usize>,
    pub pieces: usize,
    /// Revision 3 only, read-only: the division the document was filed in. Revision 4 replaces it with `book.suggested`
    /// ([`Header::suggested`] maps it), so it is never written; a pack that carries it is written back as revision 4.
    #[serde(default, skip_serializing)]
    pub division: Option<Division>,
    /// Revision 4, optional: the facts about the book (title, arrival hash, compression, OCR, suggested division).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub book: Option<BookBlock>,
    /// Revision 3, optional: what is needed to tell whether two files are the same book and to pick the better copy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub samebook: Option<Samebook>,
}

/// Where a division came from: `label` (a hand/LLM-made label), `sorter` (the classifier) or `user`.
pub const DIVISION_SOURCES: [&str; 3] = ["label", "sorter", "user"];

/// The division a document is filed in (pack revision 3).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Division {
    /// The three-digit division code, e.g. `"440"`.
    pub division: String,
    pub label: String,
    #[serde(default)]
    pub score: Option<f32>,
    #[serde(default)]
    pub classifier_version: Option<u32>,
    /// One of [`DIVISION_SOURCES`].
    pub source: String,
    #[serde(default)]
    pub second_division: Option<String>,
}

impl Division {
    fn check(&self) -> Result<()> {
        if !DIVISION_SOURCES.contains(&self.source.as_str()) {
            return Err(Error::new(format!("division source {:?} is not one of label, sorter, user", self.source)));
        }
        Ok(())
    }
}

/// Where a suggested division came from: `classifier` or `label`.
pub const SUGGESTED_SOURCES: [&str; 2] = ["classifier", "label"];

/// The division suggested for a book (pack revision 4; revision 3's `division` mapped).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Suggested {
    /// The three-digit division code, e.g. `"440"`.
    pub div: String,
    pub label: String,
    #[serde(default)]
    pub score: Option<f32>,
    #[serde(default)]
    pub classifier_version: Option<u32>,
    /// One of [`SUGGESTED_SOURCES`].
    pub source: String,
    #[serde(default)]
    pub second_div: Option<String>,
    /// Whether the sorter was confident enough to file the book in `div` (the book is placed there when it is added). `false`: the
    /// book stays in Unsorted and `suggestions` are offered. Absent in packs written before it was recorded; a reader takes absent as
    /// "not confident" and never files the book from `div` alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filed: Option<bool>,
    /// The sorter's top three divisions, best first (each with its label and score); `div` is the first. Absent in older packs, which
    /// have only `div` and `second_div`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub suggestions: Vec<ShelfSuggestion>,
}

/// One of the sorter's top divisions for a book (`book.suggested.suggestions`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShelfSuggestion {
    /// The three-digit division code, e.g. `"440"`.
    pub div: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub score: Option<f32>,
}

impl Suggested {
    fn check(&self) -> Result<()> {
        if !SUGGESTED_SOURCES.contains(&self.source.as_str()) {
            return Err(Error::new(format!("suggested source {:?} is not one of classifier, label", self.source)));
        }
        Ok(())
    }

    /// Revision 3's division as a suggestion: `sorter` is the classifier; `label` and `user` are labels.
    pub fn from_division(d: &Division) -> Suggested {
        Suggested {
            div: d.division.clone(),
            label: d.label.clone(),
            score: d.score,
            classifier_version: d.classifier_version,
            source: if d.source == "sorter" { "classifier".into() } else { "label".into() },
            second_div: d.second_division.clone(),
            filed: None,
            suggestions: Vec::new(),
        }
    }
}

/// What OCR did to the book's text: the engine and version, and how many pages it read.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OcrInfo {
    pub engine: String,
    pub version: String,
    pub pages_ocrd: u32,
    /// The mean confidence (0 to 1) the engine reported for the pages it read, when it reports one. Written only when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f32>,
}

/// The `book` block of a revision 4 header: facts that belong to the book and never change after it is built.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BookBlock {
    pub title: String,
    /// The title before a caller or a titles file replaced it; `null` when it was not replaced.
    #[serde(default)]
    pub source_title: Option<String>,
    /// BLAKE3 (hex) of the file as it arrived. A book's identity is this hash even when the stored file was compressed or the
    /// text came from an OCR copy.
    pub original_blake3: String,
    #[serde(default)]
    pub compression: Option<CompressionOutcome>,
    #[serde(default)]
    pub ocr: Option<OcrInfo>,
    #[serde(default)]
    pub suggested: Option<Suggested>,
    /// Optional, additive (no revision change): who wrote the book. Written only when known, never `null` or empty.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    /// Optional: the edition, e.g. "7th edition". Written only when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition: Option<String>,
    /// Optional: the year of this edition (1400..2100). Written only when known, as a JSON integer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<u32>,
}

impl Header {
    /// The suggested division: the `book` block's, else revision 3's `division` mapped.
    pub fn suggested(&self) -> Option<Suggested> {
        match &self.book {
            Some(b) => b.suggested.clone(),
            None => self.division.as_ref().map(Suggested::from_division),
        }
    }

    /// The book's title: the `book` block's, else the header's.
    pub fn book_title(&self) -> &str {
        self.book.as_ref().map_or(self.title.as_str(), |b| b.title.as_str())
    }

    /// Changes the title in the header and in the `book` block together.
    pub fn set_title(&mut self, title: &str) {
        self.title = title.to_string();
        if let Some(b) = self.book.as_mut() {
            b.title = title.to_string();
        }
    }

    fn check(&self) -> Result<()> {
        if let Some(d) = &self.division {
            d.check()?;
        }
        if let Some(s) = self.book.as_ref().and_then(|b| b.suggested.as_ref()) {
            s.check()?;
        }
        Ok(())
    }

    /// The header as it is written: a revision 3 header (a `division`, no `book`) gets the `book` block it lacks.
    fn for_writing(&self) -> Header {
        let mut h = self.clone();
        if h.book.is_none() {
            if let Some(d) = &h.division {
                h.book = Some(BookBlock {
                    title: h.title.clone(),
                    source_title: None,
                    original_blake3: h.source.blake3.clone(),
                    compression: None,
                    ocr: None,
                    suggested: Some(Suggested::from_division(d)),
                    author: None,
                    edition: None,
                    year: None,
                });
            }
        }
        h
    }
}

/// The fingerprint of a document for the same-book check (pack revision 3).
#[derive(Debug, Clone, PartialEq)]
pub struct Samebook {
    /// The MinHash of the text (128 numbers; empty for a very short text).
    pub minhash: Vec<u32>,
    /// The mean vector of all the pieces, scaled to length 1. Stored as half precision (f16), so [`Samebook::new`] rounds it
    /// the same way and a pack reads back equal to what was written.
    pub mean_vector: Vec<f32>,
    /// Pages with real text.
    pub text_pages: u32,
    pub pages: u32,
    /// Typical page-image resolution (pixels per inch); `None` when the PDF has no page images.
    pub ppi: Option<u32>,
    /// Size of the source file in bytes.
    pub source_size: u64,
}

impl Samebook {
    pub fn new(minhash: Vec<u32>, mean_vector: &[f32], text_pages: u32, pages: u32, ppi: Option<u32>, source_size: u64) -> Samebook {
        let mean_vector = mean_vector.iter().map(|x| f16_to_f32(f32_to_f16(*x))).collect();
        Samebook { minhash, mean_vector, text_pages, pages, ppi, source_size }
    }
}

#[derive(Serialize, Deserialize)]
struct SamebookLine {
    minhash: Vec<u32>,
    /// Base64 of little-endian f16 values.
    mean_vector: String,
    text_pages: u32,
    pages: u32,
    #[serde(default)]
    ppi: Option<u32>,
    source_size: u64,
}

impl Serialize for Samebook {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        SamebookLine {
            minhash: self.minhash.clone(),
            mean_vector: encode_vector_f16(&self.mean_vector),
            text_pages: self.text_pages,
            pages: self.pages,
            ppi: self.ppi,
            source_size: self.source_size,
        }
        .serialize(s)
    }
}

impl<'de> Deserialize<'de> for Samebook {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Samebook, D::Error> {
        let l = SamebookLine::deserialize(d)?;
        let mean_vector = decode_vector_f16(&l.mean_vector).map_err(serde::de::Error::custom)?;
        Ok(Samebook { minhash: l.minhash, mean_vector, text_pages: l.text_pages, pages: l.pages, ppi: l.ppi, source_size: l.source_size })
    }
}

/// f32 to IEEE 754 half-precision bits (round to nearest, ties to even).
pub fn f32_to_f16(x: f32) -> u16 {
    let b = x.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let exp = ((b >> 23) & 0xff) as i32;
    let man = b & 0x7f_ffff;
    if exp == 0xff {
        return sign | 0x7c00 | if man != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 0x1f {
        return sign | 0x7c00;
    }
    if e <= 0 {
        if e < -10 {
            return sign;
        }
        let m = man | 0x80_0000;
        let shift = (14 - e) as u32;
        let half = m >> shift;
        let rem = m & ((1 << shift) - 1);
        let mid = 1 << (shift - 1);
        let round = (rem > mid || (rem == mid && half & 1 == 1)) as u32;
        return sign | (half + round) as u16;
    }
    let half = ((e as u32) << 10) | (man >> 13);
    let rem = man & 0x1fff;
    let round = (rem > 0x1000 || (rem == 0x1000 && half & 1 == 1)) as u32;
    // a carry out of the mantissa correctly bumps the exponent (and to infinity at the top)
    sign | (half + round) as u16
}

/// Half-precision bits to f32.
pub fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h & 0x8000) as u32) << 16;
    let exp = ((h >> 10) & 0x1f) as u32;
    let man = (h & 0x3ff) as u32;
    let bits = match (exp, man) {
        (0, 0) => sign,
        (0, m) => {
            // subnormal: normalize
            let mut e = 113;
            let mut m = m;
            while m & 0x400 == 0 {
                m <<= 1;
                e -= 1;
            }
            sign | ((e as u32) << 23) | ((m & 0x3ff) << 13)
        }
        (0x1f, 0) => sign | 0x7f80_0000,
        (0x1f, m) => sign | 0x7f80_0000 | (m << 13),
        (e, m) => sign | ((e + 127 - 15) << 23) | (m << 13),
    };
    f32::from_bits(bits)
}

pub fn encode_vector_f16(v: &[f32]) -> String {
    let mut bytes = Vec::with_capacity(v.len() * 2);
    for x in v {
        bytes.extend_from_slice(&f32_to_f16(*x).to_le_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

pub fn decode_vector_f16(s: &str) -> Result<Vec<f32>> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(s).map_err(|e| Error::ctx("a mean vector is not base64", e))?;
    if bytes.len() % 2 != 0 {
        return Err(Error::new("a mean vector is not a whole number of f16 values"));
    }
    Ok(bytes.as_chunks::<2>().0.iter().map(|c| f16_to_f32(u16::from_le_bytes(*c))).collect())
}

#[derive(Debug, Clone, PartialEq)]
pub struct PackPiece {
    pub index: u32,
    pub text: String,
    /// The page label of the piece's first word.
    pub page: String,
    /// The 1-based PDF page of the piece's first word. `None` in packs written before the field was required, and then
    /// left out of the library payload.
    pub pdf_page: Option<u32>,
    /// The label of the last page, only when the piece crosses a page break.
    pub page_end: Option<String>,
    /// The 1-based PDF page of the last word, only when the piece crosses a page break (`page_end`'s PDF page).
    pub pdf_page_end: Option<u32>,
    pub heading_path: Vec<String>,
    pub vector: Vec<f32>,
}

#[derive(Serialize, Deserialize)]
struct PieceLine {
    i: u32,
    text: String,
    page: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pdf_page: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    page_end: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pdf_page_end: Option<u32>,
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

/// Serialize a pack to its bytes (gzip of JSON Lines).
pub fn pack_bytes(pack: &Pack) -> Result<Vec<u8>> {
    if pack.header.pieces != pack.pieces.len() {
        return Err(Error::new("the header's piece count does not match the pieces"));
    }
    pack.header.check()?;
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(6));
    let h = serde_json::to_string(&pack.header.for_writing()).map_err(|e| Error::ctx("writing the header", e))?;
    writeln!(gz, "{h}").map_err(|e| Error::ctx("writing the pack", e))?;
    for p in &pack.pieces {
        let line = PieceLine {
            i: p.index,
            text: p.text.clone(),
            page: p.page.clone(),
            pdf_page: p.pdf_page,
            page_end: p.page_end.clone(),
            pdf_page_end: p.pdf_page_end,
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
    header.check()?;
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
        pieces.push(PackPiece {
            index: p.i,
            text: p.text,
            page: p.page,
            pdf_page: p.pdf_page,
            page_end: p.page_end,
            pdf_page_end: p.pdf_page_end,
            heading_path: p.heading_path,
            vector,
        });
    }
    if pieces.len() != header.pieces {
        return Err(Error::new(format!("the pack has {} pieces, the header says {}", pieces.len(), header.pieces)));
    }
    Ok(Pack { header, pieces })
}

/// Reads only a pack's header (the first line), so a library of thousands of books can be listed without reading their vectors.
pub fn read_header(path: &Path) -> Result<Header> {
    let ctx = |e: Error| Error::ctx(&path.display().to_string(), e);
    let f = std::fs::File::open(path).map_err(|e| Error::ctx(&format!("reading {}", path.display()), e))?;
    let mut lines = std::io::BufReader::new(flate2::read::GzDecoder::new(f)).lines();
    let first = lines.next().ok_or_else(|| ctx(Error::new("empty pack")))?.map_err(|e| ctx(Error::ctx("reading the pack", e)))?;
    let header: Header = serde_json::from_str(&first).map_err(|e| ctx(Error::ctx("the pack header", e)))?;
    if header.cdoc != PACK_FORMAT {
        return Err(ctx(Error::new(format!("pack format {} is not supported (this reads {PACK_FORMAT})", header.cdoc))));
    }
    header.check().map_err(ctx)?;
    Ok(header)
}

pub fn read_pack(path: &Path) -> Result<Pack> {
    let bytes = std::fs::read(path).map_err(|e| Error::ctx(&format!("reading {}", path.display()), e))?;
    read_pack_bytes(&bytes).map_err(|e| Error::ctx(&path.display().to_string(), e))
}
