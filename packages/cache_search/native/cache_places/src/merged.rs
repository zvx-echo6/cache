//! The merged places database on the phone (`regions/places/<build>.sqlite`, schema `MERGED_SCHEMA`, format 3): the
//! regions engine is its one writer and merges each places tile into it as the tile arrives; `Pack` reads it like any
//! other pack. See docs/PLACES-TILES.md.
//!
//! Every row of a tile has a merged id `(tile << 24) | local id` (`schema::merged_id`), so a tile is one id range: merging
//! copies the tile's rows in with their ids moved into its range and builds the full-text and R-tree rows from them, and
//! removing a tile deletes that range. Category and kind place counts are the sums of the tiles' `tile_counts`.

use crate::pack::{Error, Result};
use crate::schema::{merged_id, tile_id_range, tile_path_l1, tile_rect_l1, MAX_LOCAL_ID, MERGED_FORMAT_VERSION, MERGED_SCHEMA, TILE_SCHEMA};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use std::collections::HashSet;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// What one `merge_tile` put in.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MergeReport {
    /// The level 1 tile id.
    pub tile: u32,
    /// The tile was already merged and was replaced.
    pub replaced: bool,
    pub places: u64,
    pub localities: u64,
    pub localities_ctx: u64,
    /// `addr_streets` rows, and the house numbers in them.
    pub streets: u64,
    pub addresses: u64,
    pub vectors: u64,
}

/// FTS 'optimize' runs once this many tiles were merged since the last time.
const OPTIMIZE_EVERY: i64 = 8;
/// meta key: tiles merged since the last FTS optimize.
const SINCE_OPTIMIZE: &str = "merges_since_optimize";

fn err(m: impl Into<String>) -> Error {
    Error { message: m.into() }
}

fn meta_get(c: &Connection, schema: &str, key: &str) -> Result<Option<String>> {
    Ok(c.query_row(&format!("SELECT value FROM {schema}.meta WHERE key = ?1"), params![key], |r| r.get::<_, String>(0)).optional()?)
}

fn meta_set(c: &Connection, key: &str, value: &str) -> Result<()> {
    c.execute("INSERT OR REPLACE INTO main.meta(key, value) VALUES (?1, ?2)", params![key, value])?;
    Ok(())
}

fn path_text(p: &Path) -> Result<String> {
    p.to_str().map(str::to_string).ok_or_else(|| err(format!("{}: not a usable path", p.display())))
}

/// A new merged database at `db` from the build's common file (meta, categories, kinds, states, category and kind
/// vectors), with no tiles. WAL mode, auto_vacuum = INCREMENTAL. Fails if `db` exists or the common file's tile_schema is
/// not `TILE_SCHEMA`.
pub fn create(db: &Path, common: &Path) -> Result<Connection> {
    if db.exists() {
        return Err(err(format!("{}: already exists", db.display())));
    }
    if !common.is_file() {
        return Err(err(format!("{}: no common file", common.display())));
    }
    let made = (|| -> Result<Connection> {
        let c = Connection::open(db)?;
        // auto_vacuum has to be set before the first table.
        c.execute_batch("PRAGMA auto_vacuum = INCREMENTAL;")?;
        c.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
        c.execute_batch("PRAGMA synchronous = NORMAL;")?;
        c.execute("ATTACH DATABASE ?1 AS c", params![path_text(common)?])?;
        let res = (|| -> Result<()> {
            let schema = meta_get(&c, "c", "tile_schema")?.unwrap_or_default();
            if schema != TILE_SCHEMA.to_string() {
                return Err(err(format!("{}: tile_schema {schema:?}, this reader reads {TILE_SCHEMA}", common.display())));
            }
            let build = meta_get(&c, "c", "build")?.ok_or_else(|| err(format!("{}: meta build is missing", common.display())))?;
            let built_at = meta_get(&c, "c", "built_at")?.unwrap_or_default();
            c.execute_batch("BEGIN")?;
            c.execute_batch(MERGED_SCHEMA)?;
            c.execute_batch(
                "INSERT INTO main.meta(key, value) SELECT key, value FROM c.meta;
                 INSERT INTO main.categories(id, title, description, rules, place_count, sort) SELECT id, title, description, rules, 0, sort FROM c.categories;
                 INSERT INTO main.kinds(id, label, description, category, rules, place_count, sort) SELECT id, label, description, category, rules, 0, sort FROM c.kinds;
                 INSERT INTO main.states(code, name, country) SELECT code, name, country FROM c.states;
                 INSERT INTO main.vectors(kind, ref, vec) SELECT kind, ref, vec FROM c.vectors WHERE kind IN ('category', 'kind');",
            )?;
            for (k, v) in [
                ("format_version", MERGED_FORMAT_VERSION.to_string()),
                ("kind", "merged".to_string()),
                ("build", build),
                ("built_at", built_at),
                ("region_id", "device".to_string()),
                ("region_name", String::new()),
                (SINCE_OPTIMIZE, "0".to_string()),
            ] {
                meta_set(&c, k, &v)?;
            }
            set_bbox(&c)?;
            c.execute_batch("COMMIT")?;
            Ok(())
        })();
        if res.is_err() {
            let _ = c.execute_batch("ROLLBACK");
        }
        let _ = c.execute_batch("DETACH DATABASE c");
        res.map(|_| c)
    })();
    if made.is_err() {
        for ext in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{ext}", db.display()));
        }
    }
    made
}

/// meta min/max lat/lon: the box around the merged tiles' cells (0 with no tiles).
fn set_bbox(c: &Connection) -> Result<()> {
    let mut b = [f64::MAX, f64::MAX, f64::MIN, f64::MIN];
    let mut any = false;
    {
        let mut st = c.prepare("SELECT tile FROM main.tiles")?;
        for t in st.query_map([], |r| r.get::<_, i64>(0))? {
            let r = tile_rect_l1(t? as u32);
            b = [b[0].min(r[0]), b[1].min(r[1]), b[2].max(r[2]), b[3].max(r[3])];
            any = true;
        }
    }
    if !any {
        b = [0.0; 4];
    }
    for (k, v) in [("min_lon", b[0]), ("min_lat", b[1]), ("max_lon", b[2]), ("max_lat", b[3])] {
        meta_set(c, k, &v.to_string())?;
    }
    Ok(())
}

/// Category and kind place_count from the tiles' counts.
fn recount(c: &Connection) -> Result<()> {
    c.execute_batch(
        "UPDATE main.categories SET place_count = COALESCE((SELECT SUM(n) FROM main.tile_counts WHERE what = 'category' AND id = categories.id), 0);
         UPDATE main.kinds SET place_count = COALESCE((SELECT SUM(n) FROM main.tile_counts WHERE what = 'kind' AND id = kinds.id), 0);",
    )?;
    Ok(())
}

/// Deletes every row of `tile` (not the counts' recompute). Index rows first, by the base rows' ids.
fn delete_rows(c: &Connection, tile: u32) -> Result<()> {
    let (lo, hi) = tile_id_range(tile);
    for (base, rt, fts) in [("places", "places_rt", "places_fts"), ("localities", "localities_rt", "localities_fts"), ("addr_streets", "addr_rt", "addr_fts")] {
        c.execute(&format!("DELETE FROM main.{fts} WHERE rowid BETWEEN ?1 AND ?2"), params![lo, hi])?;
        // An R-tree only looks ids up one at a time, so the ids come from the base table's range.
        c.execute(&format!("DELETE FROM main.{rt} WHERE id IN (SELECT id FROM main.{base} WHERE id BETWEEN ?1 AND ?2)"), params![lo, hi])?;
        c.execute(&format!("DELETE FROM main.{base} WHERE id BETWEEN ?1 AND ?2"), params![lo, hi])?;
    }
    c.execute("DELETE FROM main.localities_ctx WHERE tile = ?1", params![tile])?;
    c.execute("DELETE FROM main.vectors WHERE kind IN ('place', 'locality') AND CAST(ref AS INTEGER) BETWEEN ?1 AND ?2", params![lo, hi])?;
    c.execute("DELETE FROM main.tile_counts WHERE tile = ?1", params![tile])?;
    c.execute("DELETE FROM main.tiles WHERE tile = ?1", params![tile])?;
    Ok(())
}

/// Whether `schema.table` has the column (`arrival_lat` is newer than the first tiles and databases).
pub(crate) fn has_column(c: &Connection, schema: &str, table: &str, column: &str) -> Result<bool> {
    let mut st = c.prepare(&format!("PRAGMA {schema}.table_info({table})"))?;
    let names = st.query_map([], |r| r.get::<_, String>(1))?;
    for n in names {
        if n? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Gives a database made before the places' arrival points their columns (empty), so a newer tile's points merge in.
fn add_arrival_columns(c: &Connection) -> Result<()> {
    if !has_column(c, "main", "places", "arrival_lat")? {
        c.execute_batch("ALTER TABLE main.places ADD COLUMN arrival_lat REAL; ALTER TABLE main.places ADD COLUMN arrival_lon REAL;")?;
    }
    Ok(())
}

fn count(c: &Connection, sql: &str) -> Result<u64> {
    Ok(c.query_row(sql, [], |r| r.get::<_, i64>(0))? as u64)
}

/// Copies the attached tile `t` in as `tile` (its rows already gone).
fn insert_rows(tx: &Transaction, tile: u32, rep: &mut MergeReport) -> Result<()> {
    let base = merged_id(tile, 0);
    let mid = |col: &str| format!("({base} + {col})");
    for table in ["places", "localities", "localities_ctx", "addr_streets"] {
        let bad = count(tx, &format!("SELECT COUNT(*) FROM t.{table} WHERE id < 1 OR id > {MAX_LOCAL_ID}"))?;
        if bad > 0 {
            return Err(err(format!("tile {tile}: {bad} {table} rows have an id outside 1 to {MAX_LOCAL_ID}")));
        }
    }
    let p = mid("id");
    // A tile cut before the arrival points has none.
    let arrival = if has_column(tx, "t", "places", "arrival_lat")? { "arrival_lat, arrival_lon" } else { "NULL, NULL" };
    tx.execute_batch(&format!(
        "INSERT INTO main.places(id, name, category, kind, kind_id, lat, lon, street, locality, county, state, country, phone, hours, website,
                                 wikidata_id, wikipedia_title, wikivoyage_title, summary, brand_wikidata, matched_source_id, source, source_id, confidence,
                                 arrival_lat, arrival_lon)
           SELECT {p}, name, category, kind, kind_id, lat, lon, street, locality, county, state, country, phone, hours, website,
                  wikidata_id, wikipedia_title, wikivoyage_title, summary, brand_wikidata, matched_source_id, source, source_id, confidence,
                  {arrival} FROM t.places;
         INSERT INTO main.places_rt(id, min_lat, max_lat, min_lon, max_lon) SELECT {p}, lat, lat, lon, lon FROM t.places;
         INSERT INTO main.places_fts(rowid, name, alt_names) SELECT {p}, name, alt_names FROM t.places WHERE name IS NOT NULL AND name <> '';
         INSERT INTO main.localities(id, name, kind, lat, lon, population, county, state, country, wikidata_id, wikipedia_title, wikivoyage_title, summary, source_id)
           SELECT {p}, name, kind, lat, lon, population, county, state, country, wikidata_id, wikipedia_title, wikivoyage_title, summary, source_id FROM t.localities;
         INSERT INTO main.localities_rt(id, min_lat, max_lat, min_lon, max_lon) SELECT {p}, lat, lat, lon, lon FROM t.localities;
         INSERT INTO main.localities_fts(rowid, name, alt_names) SELECT {p}, name, alt_names FROM t.localities;
         INSERT INTO main.localities_ctx(id, tile, name, kind, lat, lon, population, state, country, source_id)
           SELECT {p}, {tile}, name, kind, lat, lon, population, state, country, source_id FROM t.localities_ctx;
         INSERT INTO main.addr_streets(id, uid, street, street_expanded, locality, postal_city, postcode, state, country, lat, lon,
                                       min_lat, max_lat, min_lon, max_lon, n, numbers)
           SELECT {p}, uid, street, street_expanded, locality, postal_city, postcode, state, country, lat, lon,
                  min_lat, max_lat, min_lon, max_lon, n, numbers FROM t.addr_streets;
         INSERT INTO main.addr_rt(id, min_lat, max_lat, min_lon, max_lon) SELECT {p}, min_lat, max_lat, min_lon, max_lon FROM t.addr_streets;
         INSERT INTO main.addr_fts(rowid, street, street_expanded) SELECT {p}, street, street_expanded FROM t.addr_streets;
         INSERT INTO main.vectors(kind, ref, vec) SELECT kind, CAST({r} AS TEXT), vec FROM t.vectors WHERE kind IN ('place', 'locality');
         INSERT INTO main.tile_counts(tile, what, id, n) SELECT {tile}, what, id, n FROM t.tile_counts;",
        r = mid("ref"),
    ))?;
    rep.places = count(tx, "SELECT COUNT(*) FROM t.places")?;
    rep.localities = count(tx, "SELECT COUNT(*) FROM t.localities")?;
    rep.localities_ctx = count(tx, "SELECT COUNT(*) FROM t.localities_ctx")?;
    rep.streets = count(tx, "SELECT COUNT(*) FROM t.addr_streets")?;
    rep.addresses = count(tx, "SELECT COALESCE(SUM(n), 0) FROM t.addr_streets")?;
    rep.vectors = count(tx, "SELECT COUNT(*) FROM t.vectors WHERE kind IN ('place', 'locality')")?;
    Ok(())
}

/// Merges the (uncompressed) tile file `shard` as level 1 tile `tile`, in one transaction: a tile already there is removed
/// first, so merging is idempotent. A tile whose tile_schema, build or tile id disagrees is refused and nothing changes.
/// `sha256` and `bytes` are the index's, recorded in `tiles`. The shard file is deleted after the commit.
pub fn merge_tile(c: &mut Connection, tile: u32, shard: &Path, sha256: &str, bytes: u64) -> Result<MergeReport> {
    if !shard.is_file() {
        return Err(err(format!("{}: no tile file", shard.display())));
    }
    if tile >= 64800 {
        return Err(err(format!("{tile} is not a level 1 tile")));
    }
    c.execute("ATTACH DATABASE ?1 AS t", params![path_text(shard)?])?;
    let res = (|| -> Result<MergeReport> {
        let schema = meta_get(c, "t", "tile_schema")?.unwrap_or_default();
        if schema != TILE_SCHEMA.to_string() {
            return Err(err(format!("tile {tile}: tile_schema {schema:?}, this reader reads {TILE_SCHEMA}")));
        }
        let (ours, theirs) = (meta_get(c, "main", "build")?.unwrap_or_default(), meta_get(c, "t", "build")?.unwrap_or_default());
        if ours != theirs {
            return Err(err(format!("tile {tile} is of build {theirs:?}, the database is {ours:?}")));
        }
        let said = meta_get(c, "t", "tile")?.unwrap_or_default();
        if said != tile.to_string() {
            return Err(err(format!("the file for tile {tile} says it is tile {said:?}")));
        }
        let tx = c.transaction()?;
        let mut rep = MergeReport { tile, ..Default::default() };
        rep.replaced = tx.query_row("SELECT 1 FROM main.tiles WHERE tile = ?1", params![tile], |_| Ok(())).optional()?.is_some();
        delete_rows(&tx, tile)?;
        add_arrival_columns(&tx)?;
        insert_rows(&tx, tile, &mut rep)?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        tx.execute(
            "INSERT INTO main.tiles(tile, path, sha256, bytes, merged_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![tile, tile_path_l1(tile), sha256, bytes as i64, now],
        )?;
        recount(&tx)?;
        set_bbox(&tx)?;
        let since: i64 = meta_get(&tx, "main", SINCE_OPTIMIZE)?.and_then(|v| v.parse().ok()).unwrap_or(0);
        meta_set(&tx, SINCE_OPTIMIZE, &(since + 1).to_string())?;
        tx.commit()?;
        Ok(rep)
    })();
    let _ = c.execute_batch("DETACH DATABASE t");
    if res.is_ok() {
        let _ = std::fs::remove_file(shard);
    }
    res
}

/// Removes every row of `tile` (one id range: FTS, R-tree, base, context, address and vector rows, its tile_counts and
/// its `tiles` row) and recomputes the place counts, in one transaction. A tile that is not there is not an error.
pub fn remove_tile(c: &mut Connection, tile: u32) -> Result<()> {
    let tx = c.transaction()?;
    delete_rows(&tx, tile)?;
    recount(&tx)?;
    set_bbox(&tx)?;
    tx.commit()?;
    Ok(())
}

/// The level 1 tiles merged in (the `tiles` table): what the phone has.
pub fn tiles(c: &Connection) -> Result<HashSet<u32>> {
    let mut st = c.prepare("SELECT tile FROM main.tiles")?;
    let rows = st.query_map([], |r| r.get::<_, i64>(0))?;
    let mut out = HashSet::new();
    for r in rows {
        out.insert(r? as u32);
    }
    Ok(out)
}

/// Sets meta `region_name` (the downloaded regions' names, joined by the engine).
pub fn set_regions(c: &Connection, names: &str) -> Result<()> {
    meta_set(c, "region_name", names)
}

/// Housekeeping between merges: FTS 'optimize' once 8 or more tiles were merged since the last one, then
/// incremental_vacuum.
pub fn maintain(c: &Connection) -> Result<()> {
    let since: i64 = meta_get(c, "main", SINCE_OPTIMIZE)?.and_then(|v| v.parse().ok()).unwrap_or(0);
    if since >= OPTIMIZE_EVERY {
        for fts in ["places_fts", "localities_fts", "addr_fts"] {
            c.execute(&format!("INSERT INTO main.{fts}({fts}) VALUES ('optimize')"), [])?;
        }
        meta_set(c, SINCE_OPTIMIZE, "0")?;
    }
    c.execute_batch("PRAGMA incremental_vacuum;")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixture::{fixture_tiles, write_fixture_common, write_fixture_shard, FIXTURE_BUILD};
    use crate::schema::{tile_id_l1, TILE_SHIFT};
    use std::path::PathBuf;

    struct Tmp(PathBuf);
    impl Tmp {
        fn new(name: &str) -> Tmp {
            let p = std::env::temp_dir().join(format!("cp-merged-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&p);
            std::fs::create_dir_all(&p).unwrap();
            Tmp(p)
        }
        fn shard(&self, tile: u32) -> PathBuf {
            let p = self.0.join(format!("{tile}.sqlite"));
            write_fixture_shard(&p, tile, FIXTURE_BUILD);
            p
        }
    }
    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn n(c: &Connection, sql: &str) -> i64 {
        c.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    fn fresh(t: &Tmp) -> Connection {
        let common = t.0.join("common.sqlite");
        write_fixture_common(&common, FIXTURE_BUILD);
        create(&t.0.join("merged.sqlite"), &common).unwrap()
    }

    const BURLEY: (f64, f64) = (42.5357, -113.7928);
    const STANLEY: (f64, f64) = (44.2210, -114.9360);

    /// Every row count that a tile adds, as one tuple, to compare before and after.
    fn sizes(c: &Connection) -> Vec<i64> {
        [
            "places", "places_rt", "places_fts", "localities", "localities_rt", "localities_fts", "localities_ctx", "addr_streets", "addr_rt",
            "addr_fts", "tile_counts", "tiles",
        ]
        .iter()
        .map(|t| n(c, &format!("SELECT COUNT(*) FROM {t}")))
        .chain([n(c, "SELECT COUNT(*) FROM vectors WHERE kind IN ('place', 'locality')"), n(c, "SELECT COUNT(*) FROM vectors")])
        .collect()
    }

    #[test]
    fn a_new_database_has_the_common_file_and_no_tiles() {
        let t = Tmp::new("create");
        let c = fresh(&t);
        let meta = |k: &str| meta_get(&c, "main", k).unwrap().unwrap();
        assert_eq!(meta("format_version"), "3");
        assert_eq!(meta("kind"), "merged");
        assert_eq!(meta("build"), FIXTURE_BUILD);
        assert_eq!(meta("region_id"), "device");
        assert_eq!(meta("embed_model"), crate::fixture::FAKE_MODEL);
        assert_eq!(n(&c, "SELECT COUNT(*) FROM categories"), 8);
        assert_eq!(n(&c, "SELECT COUNT(*) FROM vectors WHERE kind = 'kind'"), 15);
        assert_eq!(n(&c, "SELECT SUM(place_count) FROM categories"), 0);
        assert_eq!(c.query_row("PRAGMA journal_mode", [], |r| r.get::<_, String>(0)).unwrap(), "wal");
        assert_eq!(n(&c, "PRAGMA auto_vacuum"), 2, "incremental");
        assert!(tiles(&c).unwrap().is_empty());
        // Never over an existing file; a common file of another tile_schema is refused and leaves nothing.
        assert!(create(&t.0.join("merged.sqlite"), &t.0.join("common.sqlite")).is_err());
        let other = t.0.join("common2.sqlite");
        write_fixture_common(&other, FIXTURE_BUILD);
        Connection::open(&other).unwrap().execute("UPDATE meta SET value = '99' WHERE key = 'tile_schema'", []).unwrap();
        assert!(create(&t.0.join("m2.sqlite"), &other).unwrap_err().message.contains("tile_schema"));
        assert!(!t.0.join("m2.sqlite").exists());
    }

    #[test]
    fn two_tiles_merge_with_their_ids_ranges_index_and_vectors() {
        let t = Tmp::new("two");
        let mut c = fresh(&t);
        let (burley, stanley) = (tile_id_l1(BURLEY.0, BURLEY.1), tile_id_l1(STANLEY.0, STANLEY.1));
        let shard = t.shard(burley);
        let rep = merge_tile(&mut c, burley, &shard, "aa", 123).unwrap();
        assert!(!shard.exists(), "the tile file goes after the merge");
        assert!(!rep.replaced && rep.places > 0 && rep.streets == 3 && rep.addresses > 100, "{rep:?}");
        let rep2 = merge_tile(&mut c, stanley, &t.shard(stanley), "bb", 456).unwrap();
        assert_eq!(rep2.vectors, 3, "Stanley's tile has the summaries' vectors");
        assert_eq!(tiles(&c).unwrap(), HashSet::from([burley, stanley]));

        let (lo, hi) = tile_id_range(burley);
        assert_eq!(n(&c, &format!("SELECT COUNT(*) FROM places WHERE id BETWEEN {lo} AND {hi}")) as u64, rep.places);
        assert_eq!(n(&c, "SELECT COUNT(*) FROM places") as u64, rep.places + rep2.places);
        // Ids, FTS rowids, R-tree ids and vector refs are the same merged ids.
        let walgreens = n(&c, "SELECT id FROM places WHERE name = 'Walgreens'");
        assert_eq!(walgreens >> TILE_SHIFT, burley as i64);
        assert_eq!(n(&c, "SELECT rowid FROM places_fts WHERE places_fts MATCH 'walgreens'"), walgreens);
        assert_eq!(n(&c, "SELECT id FROM places_rt WHERE min_lat > 42.538 AND max_lat < 42.540 AND min_lon > -113.788 AND max_lon < -113.786"), walgreens);
        let spring = n(&c, "SELECT id FROM places WHERE name = 'Sawtooth Spring'");
        assert_eq!(c.query_row("SELECT ref FROM vectors WHERE kind = 'place' AND CAST(ref AS INTEGER) = ?1", [spring], |r| r.get::<_, String>(0)).unwrap(), spring.to_string());
        let town = n(&c, "SELECT id FROM localities WHERE name = 'Stanley' AND state = 'ID'");
        assert_eq!(n(&c, &format!("SELECT COUNT(*) FROM vectors WHERE kind = 'locality' AND ref = '{town}'")), 1);
        // Streets: their own FTS on both forms, and the R-tree over their box.
        let overland = n(&c, "SELECT id FROM addr_streets WHERE street = 'Overland Ave'");
        assert_eq!(n(&c, "SELECT rowid FROM addr_fts WHERE addr_fts MATCH 'avenue AND overland'"), overland);
        assert_eq!(n(&c, &format!("SELECT COUNT(*) FROM addr_rt WHERE id = {overland} AND min_lat <= 42.539 AND max_lat >= 42.539")), 1);
        // Counts follow the tiles: three pharmacies in Burley's tile, none in Stanley's.
        assert_eq!(n(&c, "SELECT place_count FROM categories WHERE id = 'pharmacy'"), 3);
        assert_eq!(n(&c, "SELECT place_count FROM kinds WHERE id = 'pharmacy'"), 3);
        let sha: String = c.query_row("SELECT sha256 FROM tiles WHERE tile = ?1", [stanley], |r| r.get(0)).unwrap();
        assert_eq!(sha, "bb");
        // The box is the two cells'.
        let r = |k: &str| meta_get(&c, "main", k).unwrap().unwrap().parse::<f64>().unwrap();
        assert_eq!((r("min_lat"), r("max_lat"), r("min_lon"), r("max_lon")), (42.0, 45.0, -115.0, -113.0));
    }

    #[test]
    fn removing_a_tile_takes_exactly_its_rows_and_merging_again_is_idempotent() {
        let t = Tmp::new("remove");
        let mut c = fresh(&t);
        let (burley, stanley) = (tile_id_l1(BURLEY.0, BURLEY.1), tile_id_l1(STANLEY.0, STANLEY.1));
        let empty = sizes(&c);
        merge_tile(&mut c, stanley, &t.shard(stanley), "s", 1).unwrap();
        let with_stanley = sizes(&c);
        let water = n(&c, "SELECT place_count FROM categories WHERE id = 'water'");
        merge_tile(&mut c, burley, &t.shard(burley), "b", 1).unwrap();
        let both = sizes(&c);
        // Merged again: replaced, the same rows, the same counts.
        let rep = merge_tile(&mut c, burley, &t.shard(burley), "b2", 1).unwrap();
        assert!(rep.replaced);
        assert_eq!(sizes(&c), both);
        assert_eq!(n(&c, "SELECT place_count FROM categories WHERE id = 'pharmacy'"), 3);
        remove_tile(&mut c, burley).unwrap();
        assert_eq!(sizes(&c), with_stanley);
        assert_eq!(n(&c, "SELECT COUNT(*) FROM places_fts WHERE places_fts MATCH 'walgreens'"), 0);
        assert_eq!(n(&c, "SELECT place_count FROM categories WHERE id = 'pharmacy'"), 0);
        assert_eq!(n(&c, "SELECT place_count FROM categories WHERE id = 'water'"), water);
        remove_tile(&mut c, burley).unwrap();
        remove_tile(&mut c, stanley).unwrap();
        assert_eq!(sizes(&c), empty);
        assert_eq!(n(&c, "SELECT SUM(place_count) FROM kinds"), 0);
        assert_eq!(n(&c, "SELECT COUNT(*) FROM vectors"), empty[13], "the category and kind vectors stay");
        maintain(&c).unwrap();
    }

    #[test]
    fn a_tile_of_another_build_schema_or_id_changes_nothing() {
        let t = Tmp::new("refuse");
        let mut c = fresh(&t);
        let burley = tile_id_l1(BURLEY.0, BURLEY.1);
        merge_tile(&mut c, burley + 1, &t.shard(burley + 1), "e", 1).unwrap();
        let before = sizes(&c);
        let other = t.0.join("other.sqlite");
        write_fixture_shard(&other, burley, "na-places-2099-01-01");
        assert!(merge_tile(&mut c, burley, &other, "x", 1).unwrap_err().message.contains("build"));
        assert!(other.exists(), "a refused tile file is left for the caller");
        let bad = t.shard(burley);
        Connection::open(&bad).unwrap().execute("UPDATE meta SET value = '2' WHERE key = 'tile_schema'", []).unwrap();
        assert!(merge_tile(&mut c, burley, &bad, "x", 1).unwrap_err().message.contains("tile_schema"));
        assert!(merge_tile(&mut c, burley, &t.shard(burley + 1), "x", 1).is_err(), "the file is another tile");
        assert!(merge_tile(&mut c, burley, &t.0.join("none.sqlite"), "x", 1).is_err());
        assert_eq!(sizes(&c), before);
        assert_eq!(tiles(&c).unwrap(), HashSet::from([burley + 1]));
        // The connection is still usable: nothing is left attached.
        merge_tile(&mut c, burley, &t.shard(burley), "b", 1).unwrap();
    }

    #[test]
    fn arrival_points_merge_and_older_tiles_and_databases_still_merge() {
        let t = Tmp::new("arrival");
        let mut c = fresh(&t);
        let (burley, stanley) = (tile_id_l1(BURLEY.0, BURLEY.1), tile_id_l1(STANLEY.0, STANLEY.1));
        // A tile whose Walgreens has an arrival point (its door).
        let shard = t.shard(burley);
        Connection::open(&shard).unwrap().execute("UPDATE places SET arrival_lat = 42.5392, arrival_lon = -113.7868 WHERE name = 'Walgreens'", []).unwrap();
        merge_tile(&mut c, burley, &shard, "a", 1).unwrap();
        let got: (f64, f64) = c.query_row("SELECT arrival_lat, arrival_lon FROM places WHERE name = 'Walgreens'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!(got, (42.5392, -113.7868));
        assert_eq!(n(&c, "SELECT COUNT(*) FROM places WHERE arrival_lat IS NOT NULL"), 1);
        // A tile cut before arrival points existed (no columns): its places merge with none.
        let old = t.shard(stanley);
        Connection::open(&old).unwrap().execute_batch("ALTER TABLE places DROP COLUMN arrival_lat; ALTER TABLE places DROP COLUMN arrival_lon;").unwrap();
        let rep = merge_tile(&mut c, stanley, &old, "o", 1).unwrap();
        assert!(rep.places > 0);
        let (lo, hi) = tile_id_range(stanley);
        assert_eq!(n(&c, &format!("SELECT COUNT(*) FROM places WHERE id BETWEEN {lo} AND {hi} AND arrival_lat IS NULL")) as u64, rep.places);
        // A database made before them gets the columns on its next merge.
        c.execute_batch("ALTER TABLE places DROP COLUMN arrival_lat; ALTER TABLE places DROP COLUMN arrival_lon;").unwrap();
        assert!(!has_column(&c, "main", "places", "arrival_lat").unwrap());
        let again = t.shard(burley);
        Connection::open(&again).unwrap().execute("UPDATE places SET arrival_lat = 1.5, arrival_lon = 2.5 WHERE name = 'Walgreens'", []).unwrap();
        merge_tile(&mut c, burley, &again, "a2", 1).unwrap();
        assert_eq!(n(&c, "SELECT COUNT(*) FROM places WHERE arrival_lat = 1.5 AND arrival_lon = 2.5"), 1);
    }

    #[test]
    fn every_fixture_tile_merges_and_optimize_runs_after_eight() {
        let t = Tmp::new("all");
        let mut c = fresh(&t);
        let all = fixture_tiles();
        for (i, &tile) in all.iter().enumerate() {
            merge_tile(&mut c, tile, &t.shard(tile), "h", 1).unwrap();
            maintain(&c).unwrap();
            let since: i64 = meta_get(&c, "main", SINCE_OPTIMIZE).unwrap().unwrap().parse().unwrap();
            assert_eq!(since, (i as i64 + 1) % OPTIMIZE_EVERY, "after {} merges", i + 1);
        }
        assert_eq!(tiles(&c).unwrap().len(), all.len());
        set_regions(&c, "Idaho").unwrap();
        assert_eq!(meta_get(&c, "main", "region_name").unwrap().unwrap(), "Idaho");
    }
}
