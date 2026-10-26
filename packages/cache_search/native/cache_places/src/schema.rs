//! The places.sqlite pack format. The builder (`places_pack`) writes it and `Pack` reads it; both use this one schema.

/// Bumped when the layout changes in a way an older reader cannot read.
pub const FORMAT_VERSION: u32 = 1;

pub const SCHEMA: &str = r#"
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;

-- The categories the assistant's tools offer (nearby, navigate). "rules" is the JSON the builder used to fill the
-- category: data, not code. place_count is the number of places in this pack.
CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  rules TEXT NOT NULL,
  place_count INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

-- wikidata_id, wikipedia_title (English Wikipedia), wikivoyage_title and summary (the article's first paragraph, under
-- 500 characters) are filled by the `places_pack wiki` step, only from IDs: OSM wikidata/wikipedia/wikivoyage tags, or an
-- enwiki article whose coordinates and exact title agree. brand_wikidata is the brand's item, not the place's.
-- category is NULL for places that belong to no starter category (they are here for the geocoder); kind is the raw
-- type ("amenity=school", "pharmacy_and_drug_store").
CREATE TABLE places (
  id INTEGER PRIMARY KEY,
  name TEXT,
  category TEXT,
  kind TEXT,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  street TEXT,
  locality TEXT,
  county TEXT,
  state TEXT,
  country TEXT,
  phone TEXT,
  hours TEXT,
  website TEXT,
  wikidata_id TEXT,
  wikipedia_title TEXT,
  wikivoyage_title TEXT,
  summary TEXT,
  brand_wikidata TEXT,
  -- An emergency room row names the hospital it was matched to; that hospital is not listed again as a "likely" one.
  matched_source_id TEXT,
  source TEXT NOT NULL,
  source_id TEXT NOT NULL,
  confidence REAL
);
CREATE INDEX places_category ON places(category);
-- A map result's id ("place:<source_id>") is looked up by this.
CREATE INDEX places_source_id ON places(source_id);
CREATE VIRTUAL TABLE places_rt USING rtree(id, min_lat, max_lat, min_lon, max_lon);
CREATE VIRTUAL TABLE places_fts USING fts5(name, alt_names, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');

-- Cities, towns, villages and hamlets: "nearest town", reverse lookup and bare town names.
CREATE TABLE localities (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  population INTEGER,
  county TEXT,
  state TEXT,
  country TEXT,
  wikidata_id TEXT,
  wikipedia_title TEXT,
  wikivoyage_title TEXT,
  summary TEXT,
  source_id TEXT NOT NULL
);
CREATE VIRTUAL TABLE localities_rt USING rtree(id, min_lat, max_lat, min_lon, max_lon);
CREATE VIRTUAL TABLE localities_fts USING fts5(name, alt_names, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');

-- States and provinces the pack knows (from the admin boundaries): "Stanley, Idaho" and "Stanley, ID".
CREATE TABLE states (code TEXT PRIMARY KEY, name TEXT NOT NULL, country TEXT) WITHOUT ROWID;
"#;

/// Added by `places_pack embed`; absent from a pack that was never embedded (search then runs on keywords only). One row
/// per embedded text: the categories (title and description), places and localities that have a summary (name and
/// summary). `ref` is the category id or the place / locality row id. `vec` is `[f32 scale, little endian][dims x i8]`
/// of the L2-normalised vector (value = i8 * scale), so a pack costs one byte per dimension.
/// meta keys `embed_model` (the id a query vector must carry), `embed_dims`, `embed_model_sha256` and `embed_count`.
pub const VECTORS_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS vectors (
  kind TEXT NOT NULL,
  ref TEXT NOT NULL,
  vec BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS vectors_kind ON vectors(kind);
"#;

/// Quantise a vector as the `vectors.vec` column stores it (the vector is normalised first).
pub fn pack_vector(v: &[f32]) -> Vec<u8> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-12);
    let max = v.iter().map(|x| x.abs() / norm).fold(0.0f32, f32::max).max(1e-12);
    let scale = max / 127.0;
    let mut out = Vec::with_capacity(4 + v.len());
    out.extend_from_slice(&scale.to_le_bytes());
    out.extend(v.iter().map(|x| ((x / norm) / scale).round().clamp(-127.0, 127.0) as i8 as u8));
    out
}

/// Cosine of a packed vector with a query that is already normalised; None when the sizes disagree.
pub fn dot_packed(blob: &[u8], query: &[f32]) -> Option<f32> {
    if blob.len() != 4 + query.len() {
        return None;
    }
    let scale = f32::from_le_bytes([blob[0], blob[1], blob[2], blob[3]]);
    let mut acc = 0.0f32;
    for (b, q) in blob[4..].iter().zip(query) {
        acc += (*b as i8) as f32 * q;
    }
    Some(acc * scale)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packed_vectors_keep_the_cosine() {
        let a: Vec<f32> = (0..64).map(|i| ((i * 7 % 13) as f32) - 6.0).collect();
        let b: Vec<f32> = (0..64).map(|i| ((i * 5 % 11) as f32) - 5.0).collect();
        let norm = |v: &[f32]| v.iter().map(|x| x * x).sum::<f32>().sqrt();
        let exact: f32 = a.iter().zip(&b).map(|(x, y)| x * y).sum::<f32>() / (norm(&a) * norm(&b));
        let bn: Vec<f32> = b.iter().map(|x| x / norm(&b)).collect();
        let got = dot_packed(&pack_vector(&a), &bn).unwrap();
        assert!((got - exact).abs() < 0.02, "{got} vs {exact}");
        assert!(dot_packed(&pack_vector(&a), &bn[..10]).is_none());
    }
}
