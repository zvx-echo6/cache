//! `places_pack embed --packs <dir> [--common common.sqlite]`: the meaning-search vectors of the tiled build.
//!
//! - Every block: its notable places and towns, those with a summary from the wiki step (`"{name}. {summary}"`, as
//!   `cache_places::embedpack` embeds them). `cut` copies them into the tiles.
//! - The common file: every category (`"{title}: {description}"`) and every kind (`"{label}: {description}"`, the
//!   description `common` wrote: the rules', kinds-described.tsv's, or the taxonomy path).
//!
//! Vectors come from `cache_embed` (cl_embed, context 512, normalised, the model's own CLS pooling): the same C calls with
//! the same settings as the phone's query embedder, so a query vector and these compare directly. They are stored as
//! `schema::pack_vector` (f32 scale, then dims x i8).
//!
//! embed-cache.sqlite keeps every stored vector by sha256(model sha256, text), so a later build embeds only texts that are
//! new or changed, and a different model file never reuses another's vectors.

use cache_places::schema::{pack_vector, VECTORS_SCHEMA};
use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const EMBED_CACHE_SQL: &str = "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;
CREATE TABLE IF NOT EXISTS vectors (key BLOB PRIMARY KEY, vec BLOB NOT NULL) WITHOUT ROWID;";

/// The embedder behind a persistent cache: a text's stored vector, embedded only when the cache does not have it.
pub struct Cached<'a> {
    cache: Option<Connection>,
    model_sha256: String,
    embed: &'a mut dyn FnMut(&str) -> Result<Vec<f32>, String>,
    pub dims: usize,
    pub hits: usize,
    pub embedded: usize,
}

impl<'a> Cached<'a> {
    /// `cache`: embed-cache.sqlite (created when missing); None embeds every text.
    pub fn new(cache: Option<&Path>, model_sha256: &str, embed: &'a mut dyn FnMut(&str) -> Result<Vec<f32>, String>) -> Result<Cached<'a>, String> {
        let cache = match cache {
            Some(p) => {
                let c = Connection::open(p).map_err(|e| format!("{}: {e}", p.display()))?;
                c.execute_batch(EMBED_CACHE_SQL).map_err(|e| e.to_string())?;
                Some(c)
            }
            None => None,
        };
        Ok(Cached { cache, model_sha256: model_sha256.to_ascii_lowercase(), embed, dims: 0, hits: 0, embedded: 0 })
    }

    fn key(&self, text: &str) -> Vec<u8> {
        let mut h = Sha256::new();
        h.update(self.model_sha256.as_bytes());
        h.update([0u8]);
        h.update(text.as_bytes());
        h.finalize().to_vec()
    }

    /// The stored form of `text`'s vector.
    pub fn vector(&mut self, text: &str) -> Result<Vec<u8>, String> {
        let key = self.key(text);
        if let Some(c) = &self.cache {
            let hit: Option<Vec<u8>> = c.query_row("SELECT vec FROM vectors WHERE key = ?1", params![key], |r| r.get(0)).optional().map_err(|e| e.to_string())?;
            if let Some(v) = hit.filter(|v| self.dims == 0 || v.len() == 4 + self.dims) {
                self.dims = v.len() - 4;
                self.hits += 1;
                return Ok(v);
            }
        }
        let v = (self.embed)(text)?;
        if self.dims != 0 && v.len() != self.dims {
            return Err(format!("the embedder returned {} values after {}", v.len(), self.dims));
        }
        self.dims = v.len();
        self.embedded += 1;
        let packed = pack_vector(&v);
        if let Some(c) = &self.cache {
            c.execute("INSERT OR REPLACE INTO vectors(key, vec) VALUES (?1, ?2)", params![key, packed]).map_err(|e| e.to_string())?;
        }
        Ok(packed)
    }
}

#[derive(Debug, Default)]
pub struct EmbedReport {
    pub blocks: usize,
    pub places: usize,
    pub localities: usize,
    pub categories: usize,
    pub kinds: usize,
}

/// The text a category or kind is embedded with.
pub fn label_text(label: &str, description: &str) -> String {
    if description.trim().is_empty() {
        label.to_string()
    } else {
        format!("{label}: {description}")
    }
}

/// The text a notable place or town is embedded with.
pub fn summary_text(name: &str, summary: &str) -> String {
    format!("{name}. {summary}")
}

fn texts(c: &Connection, sql: &str, text: fn(&str, &str) -> String) -> Result<Vec<(String, String)>, String> {
    let mut st = c.prepare(sql).map_err(|e| e.to_string())?;
    let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for r in rows {
        let (id, a, b) = r.map_err(|e| e.to_string())?;
        out.push((id, text(&a, &b)));
    }
    Ok(out)
}

fn write(c: &mut Connection, kinds: &[&str], rows: &[(&str, String, Vec<u8>)], meta: &[(&str, String)]) -> Result<(), String> {
    let tx = c.transaction().map_err(|e| e.to_string())?;
    for k in kinds {
        tx.execute("DELETE FROM vectors WHERE kind = ?1", params![k]).map_err(|e| e.to_string())?;
    }
    for (kind, r, v) in rows {
        tx.execute("INSERT INTO vectors(kind, ref, vec) VALUES (?1, ?2, ?3)", params![kind, r, v]).map_err(|e| e.to_string())?;
    }
    for (k, v) in meta {
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value", params![k, v]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())
}

fn embed_meta(model_id: &str, dims: usize, model_sha256: &str, count: usize) -> Vec<(&'static str, String)> {
    vec![
        ("embed_model", model_id.to_string()),
        ("embed_dims", dims.to_string()),
        ("embed_model_sha256", model_sha256.to_string()),
        ("embed_count", count.to_string()),
    ]
}

/// Every block's notable places and towns, then the common file's categories and kinds.
pub fn embed(blocks: &[PathBuf], common: Option<&Path>, model_id: &str, model_sha256: &str, e: &mut Cached, progress: &mut dyn FnMut(&str)) -> Result<EmbedReport, String> {
    let mut rep = EmbedReport::default();
    for p in blocks {
        let mut c = Connection::open(p).map_err(|e| format!("{}: {e}", p.display()))?;
        c.execute_batch(VECTORS_SCHEMA).map_err(|e| e.to_string())?;
        let places = texts(&c, "SELECT CAST(id AS TEXT), name, summary FROM places WHERE summary IS NOT NULL AND summary <> '' AND name IS NOT NULL ORDER BY id", summary_text)?;
        let locs = texts(&c, "SELECT CAST(id AS TEXT), name, summary FROM localities WHERE summary IS NOT NULL AND summary <> '' ORDER BY id", summary_text)?;
        let mut rows = Vec::new();
        for (kind, list) in [("place", &places), ("locality", &locs)] {
            for (id, text) in list {
                rows.push((kind, id.clone(), e.vector(text)?));
            }
        }
        write(&mut c, &["place", "locality"], &rows, &if rows.is_empty() { vec![] } else { embed_meta(model_id, e.dims, model_sha256, rows.len()) })?;
        rep.blocks += 1;
        rep.places += places.len();
        rep.localities += locs.len();
        progress(&format!("{}: {} places, {} towns ({} embedded so far, {} from the cache)", p.display(), places.len(), locs.len(), e.embedded, e.hits));
    }
    if let Some(p) = common {
        let mut c = Connection::open(p).map_err(|e| format!("{}: {e}", p.display()))?;
        let cats = texts(&c, "SELECT id, title, description FROM categories ORDER BY sort", label_text)?;
        let kinds = texts(&c, "SELECT id, label, description FROM kinds ORDER BY sort", label_text)?;
        let mut rows = Vec::new();
        for (kind, list) in [("category", &cats), ("kind", &kinds)] {
            for (i, (id, text)) in list.iter().enumerate() {
                rows.push((kind, id.clone(), e.vector(text)?));
                if (i + 1) % 500 == 0 {
                    progress(&format!("{kind}: {}/{}", i + 1, list.len()));
                }
            }
        }
        write(&mut c, &["category", "kind"], &rows, &embed_meta(model_id, e.dims, model_sha256, rows.len()))?;
        drop(c);
        Connection::open(p).and_then(|c| c.execute_batch("VACUUM;")).map_err(|e| e.to_string())?;
        rep.categories = cats.len();
        rep.kinds = kinds.len();
    }
    Ok(rep)
}
