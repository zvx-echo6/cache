//! Writing the meaning-search vectors into a places pack (`places_pack embed`; the tests use it with a stand-in embedder).
//!
//! What is embedded: every category (`title: description`), and every place and town that has a summary
//! (`name. summary`). The query side (`map::PlacesCore::search`) compares a query vector with exactly these.

use crate::schema::{pack_vector, VECTORS_SCHEMA};
use rusqlite::{params, Connection};
use std::path::Path;

#[derive(Debug, Default)]
pub struct EmbedReport {
    pub categories: usize,
    pub places: usize,
    pub localities: usize,
    pub dims: usize,
}

/// Replace the pack's vectors. `embed` returns the vector of a text (any length; all must be equal); `model_id` is what
/// a query vector has to be labelled with, `model_sha256` is recorded for reference.
pub fn embed_pack(
    path: &Path,
    model_id: &str,
    model_sha256: &str,
    embed: &mut dyn FnMut(&str) -> Result<Vec<f32>, String>,
    progress: &mut dyn FnMut(&str),
) -> Result<EmbedReport, String> {
    let mut conn = Connection::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    conn.execute_batch(VECTORS_SCHEMA).map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM vectors", []).map_err(|e| e.to_string())?;
    let mut rep = EmbedReport::default();
    let texts = |sql: &str, join: &str| -> Result<Vec<(String, String)>, String> {
        let mut st = conn.prepare(sql).map_err(|e| e.to_string())?;
        let rows = st
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))
            .map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for r in rows {
            let (id, a, b) = r.map_err(|e| e.to_string())?;
            out.push((id, format!("{a}{join}{b}")));
        }
        Ok(out)
    };
    let cats = texts("SELECT id, title, description FROM categories ORDER BY sort", ": ")?;
    let places = texts("SELECT CAST(id AS TEXT), name, summary FROM places WHERE summary IS NOT NULL AND summary <> '' AND name IS NOT NULL", ". ")?;
    let locs = texts("SELECT CAST(id AS TEXT), name, summary FROM localities WHERE summary IS NOT NULL AND summary <> ''", ". ")?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    for (kind, list) in [("category", &cats), ("place", &places), ("locality", &locs)] {
        for (i, (id, text)) in list.iter().enumerate() {
            let v = embed(text)?;
            if rep.dims == 0 {
                rep.dims = v.len();
            } else if rep.dims != v.len() {
                return Err(format!("the embedder returned {} values for {kind} {id} after {}", v.len(), rep.dims));
            }
            tx.execute("INSERT INTO vectors(kind, ref, vec) VALUES (?1, ?2, ?3)", params![kind, id, pack_vector(&v)]).map_err(|e| e.to_string())?;
            if (i + 1) % 500 == 0 {
                progress(&format!("{kind}: {}/{}", i + 1, list.len()));
            }
        }
    }
    rep.categories = cats.len();
    rep.places = places.len();
    rep.localities = locs.len();
    for (k, v) in [
        ("embed_model", model_id.to_string()),
        ("embed_dims", rep.dims.to_string()),
        ("embed_model_sha256", model_sha256.to_string()),
        ("embed_count", (rep.categories + rep.places + rep.localities).to_string()),
    ] {
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value", params![k, v]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    drop(conn);
    let conn = Connection::open(path).map_err(|e| e.to_string())?;
    conn.execute_batch("VACUUM;").map_err(|e| e.to_string())?;
    Ok(rep)
}
