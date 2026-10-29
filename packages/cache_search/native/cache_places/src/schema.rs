//! The places.sqlite pack format. The builder (`places_pack`) writes it and `Pack` reads it; both use this one schema.

/// Bumped when the layout changes in a way an older reader cannot read. What the builder writes.
///
/// 1: first layout. 2: every place carries a `kind_id` (what kind of place it is: `drinking_water`, `picnic_shelter`,
/// `pharmacy`, ...) and the pack has a `kinds` table (label and one-line description per kind). The places' `arrival_lat`
/// and `arrival_lon` were added later without a new number: a pack, tile or merged database without them reads as before.
pub const FORMAT_VERSION: u32 = 2;

/// The oldest format `Pack` still reads. A format 1 pack has no kinds: its places read with `kind_id` None.
pub const MIN_FORMAT_VERSION: u32 = 1;

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

-- What kinds of place the pack's places are (format 2). id is the stable machine id a place's kind_id holds; label is how a
-- person says it ("Drinking water tap"); description is one line. category is the starter category the kind belongs to
-- (NULL for kinds of places that are only here for the geocoder). rules is the JSON the builder used (data, not code; "[]"
-- for a kind the builder derived from a source tag without a rule). place_count is the number of places of the kind.
CREATE TABLE kinds (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT,
  rules TEXT NOT NULL,
  place_count INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

-- wikidata_id, wikipedia_title (English Wikipedia), wikivoyage_title and summary (the article's first paragraph, under
-- 500 characters) are filled by the `places_pack wiki` step, only from IDs: OSM wikidata/wikipedia/wikivoyage tags, or an
-- enwiki article whose coordinates and exact title agree. brand_wikidata is the brand's item, not the place's.
-- category is NULL for places that belong to no starter category (they are here for the geocoder); kind is the raw
-- type ("amenity=school", "pharmacy_and_drug_store"); kind_id is the stable kind (see `kinds`), derived from the source's
-- tags by the kind rules, or from the raw type when no rule says more.
CREATE TABLE places (
  id INTEGER PRIMARY KEY,
  name TEXT,
  category TEXT,
  kind TEXT,
  kind_id TEXT,
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
  confidence REAL,
  -- Where a route to the place goes, when that is not its own point: an airport's passenger terminal, a building's main
  -- entrance, a park's or campus's parking (NULL: the place's point). Added after the first layout; a reader checks for it.
  arrival_lat REAL,
  arrival_lon REAL
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

/// The house number codec of `addr_streets.numbers` (format 3 and tiles).
pub use crate::addr;

// ---------------------------------------------------------------------------------------------------------------------------
// Places in regions (docs/PLACES-TILES.md): the server publishes places cut on Valhalla's level 1 grid, one SQLite file per
// tile plus one common file per build, and the phone merges the tiles it has into one database (format 3).

/// The tile and common file layout (`meta.tile_schema` of both, and `current.json`'s `tile_schema`). A reader refuses a
/// number it does not know, and the app can tell before downloading anything.
pub const TILE_SCHEMA: u32 = 1;

/// The merged database's `format_version`. Format 2 is still what `places_pack` writes for one region (`FORMAT_VERSION`).
pub const MERGED_FORMAT_VERSION: u32 = 3;

/// A merged row id is `(tile << TILE_SHIFT) | local id`, so one tile is one id range; local ids are 1 to 2^24 - 1.
pub const TILE_SHIFT: u32 = 24;
pub const MAX_LOCAL_ID: i64 = (1 << TILE_SHIFT) - 1;

/// The merged id of a tile's local row id.
pub fn merged_id(tile: u32, local: i64) -> i64 {
    ((tile as i64) << TILE_SHIFT) | (local & MAX_LOCAL_ID)
}

/// The merged ids of one tile, first and last (for `BETWEEN`).
pub fn tile_id_range(tile: u32) -> (i64, i64) {
    (merged_id(tile, 0), merged_id(tile, MAX_LOCAL_ID))
}

/// Columns of Valhalla's level 1 grid (1 degree): 360 by 180 tiles, ids below 64,800.
const L1_COLUMNS: u32 = 360;
const L1_ROWS: u32 = 180;

/// The level 1 tile that holds the point, as `cache_regions::geo::tile_id(1, lon, lat)` computes it: row * 360 + column
/// from the south-west corner of the world, a point on a cell edge going to the cell north-east of it, and coordinates
/// outside the world clamped to its edge. (Replicated here because cache_regions depends on this crate; its tests
/// cross-check the two.)
pub fn tile_id_l1(lat: f64, lon: f64) -> u32 {
    let col = ((lon.clamp(-180.0, 180.0) + 180.0).floor().max(0.0) as u32).min(L1_COLUMNS - 1);
    let row = ((lat.clamp(-90.0, 90.0) + 90.0).floor().max(0.0) as u32).min(L1_ROWS - 1);
    row * L1_COLUMNS + col
}

/// A level 1 tile's path as the server lays it out (and Valhalla does), without the extension: 47586 is `1/047/586`.
pub fn tile_path_l1(tile: u32) -> String {
    format!("1/{:03}/{:03}", tile / 1000, tile % 1000)
}

/// "1/047/586" (or with ".sqlite") is 47586; anything else, another level, or an id beyond the grid is None.
pub fn parse_tile_path_l1(p: &str) -> Option<u32> {
    let stem = p.strip_suffix(".sqlite").unwrap_or(p);
    let rest = stem.strip_prefix("1/")?;
    let (a, b) = rest.split_once('/')?;
    if a.len() != 3 || b.len() != 3 || !a.bytes().chain(b.bytes()).all(|c| c.is_ascii_digit()) {
        return None;
    }
    let id = a.parse::<u32>().ok()? * 1000 + b.parse::<u32>().ok()?;
    (id < L1_COLUMNS * L1_ROWS).then_some(id)
}

/// The cell of a level 1 tile: [west, south, east, north].
pub fn tile_rect_l1(tile: u32) -> [f64; 4] {
    let (w, s) = (-180.0 + (tile % L1_COLUMNS) as f64, -90.0 + (tile / L1_COLUMNS) as f64);
    [w, s, w + 1.0, s + 1.0]
}

/// `<build>/common.sqlite`: everything of a build that is not per tile. One file per build.
/// meta keys: tile_schema ("1"), build, built_at (ISO 8601 with offset), overture_release, osm_source, sources,
/// builder_rules (categories.json as used), attribution, embed_model ("bge-m3-Q8_0", as cache_embed reports it),
/// embed_dims ("1024"), embed_model_sha256, levels ("[1]").
/// `vectors`: kind is 'category' or 'kind', ref the id, vec as [`pack_vector`] writes it; the text embedded is
/// "{title or label}: {description}".
pub const COMMON_SQL: &str = r#"
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
-- No place_count: the phone counts what it has (tile_counts).
CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  rules TEXT NOT NULL,
  sort INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
CREATE TABLE kinds (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT,
  rules TEXT NOT NULL,
  sort INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
-- Every state and province of the build's area.
CREATE TABLE states (code TEXT PRIMARY KEY, name TEXT NOT NULL, country TEXT) WITHOUT ROWID;
CREATE TABLE vectors (kind TEXT NOT NULL, ref TEXT NOT NULL, vec BLOB NOT NULL);
"#;

/// `<build>/<path>.sqlite`: one level 1 tile. Every feature is in the tile that holds its point, once; the phone ATTACHes
/// the file to merge it, and builds the FTS and R-tree indexes itself, so the tile has none.
/// meta keys: tile_schema ("1"), build, tile (the level 1 id, decimal), path ("1/047/586"), counts (JSON, as tile_counts).
/// Row ids are local, 1 to 2^24 - 1 ([`MAX_LOCAL_ID`]).
pub const TILE_SQL: &str = r#"
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;

-- As format 2's places, plus alt_names ("; "-joined; the FTS column on the phone). street, locality and state were
-- worked out on the builder with all the data, so they never depend on which neighbouring tiles the phone has.
CREATE TABLE places (
  id INTEGER PRIMARY KEY,
  name TEXT,
  alt_names TEXT,
  category TEXT,
  kind TEXT,
  kind_id TEXT,
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
  matched_source_id TEXT,
  source TEXT NOT NULL,
  source_id TEXT NOT NULL,
  confidence REAL,
  -- Where a route to the place goes, when that is not its own point: an airport's passenger terminal, a building's main
  -- entrance, a park's or campus's parking (NULL: the place's point). Added after the first layout; a reader checks for it.
  arrival_lat REAL,
  arrival_lon REAL
);

CREATE TABLE localities (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  alt_names TEXT,
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

-- Cities, towns and villages (not hamlets) outside the cell but within 25 km of it: "nearest town" and the anchor step at
-- the edge of what the phone has. Used only while the tile that owns the town is not on the phone.
CREATE TABLE localities_ctx (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  population INTEGER,
  state TEXT,
  country TEXT,
  source_id TEXT NOT NULL
);

-- One street within this tile, grouped by (street as written, postcode, postal_city or locality); units dropped.
-- street is the source's form ("MAIN ST"); street_expanded the same with its USPS Publication 28 suffix and directional
-- abbreviations written out ("MAIN STREET"), NULL when that changes nothing; both are searched. uid is the first 16 hex
-- characters of sha256(street_norm|postcode|locality|tile), stable across builds of the same data. lat/lon is the centre
-- of the numbers, which `numbers` (see `addr`) stores relative to.
CREATE TABLE addr_streets (
  id INTEGER PRIMARY KEY,
  uid TEXT NOT NULL,
  street TEXT NOT NULL,
  street_expanded TEXT,
  locality TEXT,
  postal_city TEXT,
  postcode TEXT,
  state TEXT,
  country TEXT,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  min_lat REAL NOT NULL,
  max_lat REAL NOT NULL,
  min_lon REAL NOT NULL,
  max_lon REAL NOT NULL,
  n INTEGER NOT NULL,
  numbers BLOB NOT NULL
);

-- Notable places and towns (those with a summary), embedded as "{name}. {summary}". kind is 'place' or 'locality', ref
-- the local row id.
CREATE TABLE vectors (kind TEXT NOT NULL, ref INTEGER NOT NULL, vec BLOB NOT NULL);

-- How many places of each category and kind the tile holds. what is 'category' or 'kind'.
CREATE TABLE tile_counts (what TEXT NOT NULL, id TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (what, id)) WITHOUT ROWID;
"#;

/// The merged database on the phone (`regions/places/<build>.sqlite`, format [`MERGED_FORMAT_VERSION`]): every tile it has,
/// merged by `merged::merge_tile`, read by `Pack` like any other pack. It is format 2's [`SCHEMA`] with these changes:
/// place, locality, context locality and street ids are [`merged_id`]s (FTS rowids, R-tree ids and vector refs too), so a
/// tile is one id range; places get an index on kind_id; localities_ctx, the address tables, tiles and tile_counts are
/// added; category and kind place_count are the sums of tile_counts, recomputed on every merge and removal.
/// meta keys: format_version ("3"), kind ("merged"), build, built_at (the build's), region_id ("device"), region_name (the
/// regions' names joined), min_lat, min_lon, max_lat, max_lon (the box around the tiles), and the common file's meta keys
/// (embed_model and the rest). The database runs in WAL mode with auto_vacuum = INCREMENTAL (set by `merged::create`).
pub const MERGED_SCHEMA: &str = r#"
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;

CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  rules TEXT NOT NULL,
  place_count INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

CREATE TABLE kinds (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT,
  rules TEXT NOT NULL,
  place_count INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

CREATE TABLE places (
  id INTEGER PRIMARY KEY,
  name TEXT,
  category TEXT,
  kind TEXT,
  kind_id TEXT,
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
  matched_source_id TEXT,
  source TEXT NOT NULL,
  source_id TEXT NOT NULL,
  confidence REAL,
  -- Where a route to the place goes, when that is not its own point: an airport's passenger terminal, a building's main
  -- entrance, a park's or campus's parking (NULL: the place's point). Added after the first layout; a reader checks for it.
  arrival_lat REAL,
  arrival_lon REAL
);
CREATE INDEX places_category ON places(category);
CREATE INDEX places_source_id ON places(source_id);
CREATE INDEX places_kind ON places(kind_id);
CREATE VIRTUAL TABLE places_rt USING rtree(id, min_lat, max_lat, min_lon, max_lon);
CREATE VIRTUAL TABLE places_fts USING fts5(name, alt_names, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');

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

-- The tiles' context towns, by the tile that carried them; read only while the town's own tile is absent, deduped by
-- source_id.
CREATE TABLE localities_ctx (
  id INTEGER PRIMARY KEY,
  tile INTEGER NOT NULL,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  population INTEGER,
  state TEXT,
  country TEXT,
  source_id TEXT NOT NULL
);
CREATE INDEX localities_ctx_tile ON localities_ctx(tile);

CREATE TABLE states (code TEXT PRIMARY KEY, name TEXT NOT NULL, country TEXT) WITHOUT ROWID;

CREATE TABLE addr_streets (
  id INTEGER PRIMARY KEY,
  uid TEXT NOT NULL,
  street TEXT NOT NULL,
  street_expanded TEXT,
  locality TEXT,
  postal_city TEXT,
  postcode TEXT,
  state TEXT,
  country TEXT,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  min_lat REAL NOT NULL,
  max_lat REAL NOT NULL,
  min_lon REAL NOT NULL,
  max_lon REAL NOT NULL,
  n INTEGER NOT NULL,
  numbers BLOB NOT NULL
);
-- An address result's id ("addr:<uid>/<number>") is looked up by this.
CREATE INDEX addr_streets_uid ON addr_streets(uid);
CREATE VIRTUAL TABLE addr_rt USING rtree(id, min_lat, max_lat, min_lon, max_lon);
CREATE VIRTUAL TABLE addr_fts USING fts5(street, street_expanded, tokenize = 'unicode61 remove_diacritics 2', prefix = '1 2 3');

-- Category and kind rows come from the common file; place and locality refs are merged ids.
CREATE TABLE vectors (kind TEXT NOT NULL, ref TEXT NOT NULL, vec BLOB NOT NULL);
CREATE INDEX vectors_kind ON vectors(kind);

-- The tiles merged in, and what each holds. This table, not the folder, is what the phone has.
CREATE TABLE tiles (tile INTEGER PRIMARY KEY, path TEXT NOT NULL, sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, merged_at INTEGER NOT NULL);
CREATE TABLE tile_counts (tile INTEGER NOT NULL, what TEXT NOT NULL, id TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (tile, what, id)) WITHOUT ROWID;
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

    #[test]
    fn level_1_tiles() {
        // Burley, Idaho (as cache_regions' own test), Salt Lake City, and the world's corners and edges.
        assert_eq!(tile_id_l1(42.54, -113.79), 132 * 360 + 66);
        assert_eq!(tile_id_l1(40.76, -111.89), 130 * 360 + 68);
        assert_eq!(tile_path_l1(tile_id_l1(40.76, -111.89)), "1/046/868");
        assert_eq!(tile_path_l1(47586), "1/047/586");
        assert_eq!(tile_path_l1(0), "1/000/000");
        assert_eq!(tile_id_l1(-90.0, -180.0), 0);
        assert_eq!(tile_id_l1(90.0, 180.0), 64799, "the last cell, not one beyond");
        assert_eq!(tile_id_l1(-95.0, -200.0), 0, "clamped");
        // A point on a cell edge goes to the cell north-east of it.
        assert_eq!(tile_id_l1(41.0, -112.0), 131 * 360 + 68);
        assert_eq!(tile_rect_l1(130 * 360 + 68), [-112.0, 40.0, -111.0, 41.0]);
        assert_eq!(parse_tile_path_l1("1/047/586"), Some(47586));
        assert_eq!(parse_tile_path_l1("1/047/586.sqlite"), Some(47586));
        assert_eq!(parse_tile_path_l1("2/047/586"), None);
        assert_eq!(parse_tile_path_l1("1/064/800"), None, "beyond the grid");
        assert_eq!(parse_tile_path_l1("1/04/7586"), None);
        assert_eq!(parse_tile_path_l1("1/../586"), None);
        for t in [0, 47586, 64799] {
            assert_eq!(parse_tile_path_l1(&tile_path_l1(t)), Some(t));
        }
    }

    #[test]
    fn merged_ids_are_one_range_per_tile() {
        assert_eq!(merged_id(0, 1), 1);
        assert_eq!(merged_id(64799, MAX_LOCAL_ID), (64799i64 << 24) | 0xFF_FFFF);
        let (lo, hi) = tile_id_range(47586);
        assert!(lo < merged_id(47586, 1) && merged_id(47586, MAX_LOCAL_ID) == hi && hi < merged_id(47587, 0));
    }

    #[test]
    fn the_schemas_create() {
        for (name, sql) in [("tile", TILE_SQL), ("common", COMMON_SQL), ("merged", MERGED_SCHEMA)] {
            let c = rusqlite::Connection::open_in_memory().unwrap();
            c.execute_batch(sql).unwrap_or_else(|e| panic!("{name}: {e}"));
        }
    }
}
