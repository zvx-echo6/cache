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
