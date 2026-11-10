//! The ids and payloads of a library's points (docs/LIBRARY-FORMAT.md): one piece of a pack is one point.

use crate::pack::{Pack, PackPiece};
use serde_json::{json, Value};

/// UUIDv5(URL namespace, "https://github.com/zvx-echo6/cache/library-point"), docs/LIBRARY-FORMAT.md.
pub const POINT_NAMESPACE: &str = "c4b95b91-e641-5c16-91a0-13ba2f6f7970";
/// The `source` payload value of every point (mapped as the library's source type).
pub const SOURCE_KIND: &str = "book";

/// The id of passage `index` of a document version.
pub fn point_uuid(doc_id: &str, doc_version: u32, index: u32) -> uuid::Uuid {
    let ns = uuid::Uuid::parse_str(POINT_NAMESPACE).expect("namespace");
    uuid::Uuid::new_v5(&ns, format!("{doc_id}:{doc_version}:{index}").as_bytes())
}

/// A page label as a payload value: a whole number when it is one, else text.
pub fn page_value(label: &str) -> Value {
    match label.parse::<u64>() {
        Ok(n) if label == n.to_string() => json!(n),
        _ => json!(label),
    }
}

/// What a piece's payload needs of its document.
pub struct DocFields<'a> {
    pub title: &'a str,
    pub doc_id: &'a str,
    pub doc_version: u32,
    pub source_blake3: &'a str,
    /// The `link` payload value (empty when the document has no address).
    pub link: &'a str,
    pub author: Option<&'a str>,
    /// `(zim_id, zim_path)` for a PDF inside a ZIM.
    pub zim: Option<(&'a str, &'a str)>,
}

/// The payload of one piece: the fields today's libraries use (`title`, `text`, `page`, `source`, `link`, `doc_id`,
/// `doc_version`; the settings file maps these) plus fields the settings file does not map, so the model never sees them and the
/// keyword index does not cover them: `heading_path`, `pdf_page` and `pdf_page_end` (1-based PDF pages), `page_end` (a page label,
/// only when the piece crosses a page), `source_blake3`, and, when given, `author`, `zim_id` and `zim_path`.
pub fn piece_payload(doc: &DocFields, p: &PackPiece) -> Value {
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
    if let Some(a) = doc.author {
        v["author"] = json!(a);
    }
    if let Some((id, path)) = doc.zim {
        v["zim_id"] = json!(id);
        v["zim_path"] = json!(path);
    }
    v
}

/// The payload of piece `i` of a pack.
pub fn payload_of(pack: &Pack, i: usize) -> Value {
    let h = &pack.header;
    let doc = DocFields {
        title: &h.title,
        doc_id: &h.doc_id,
        doc_version: h.doc_version,
        source_blake3: &h.source.blake3,
        link: h.source.https.as_deref().unwrap_or(""),
        author: None,
        zim: None,
    };
    piece_payload(&doc, &pack.pieces[i])
}
