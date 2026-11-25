//! The pack reader's "present" marker: a pack with `meta.covered_v` lists every raster tile the builder processed in `covered`
//! (the all-zero ones are left out of `tiles`), so a tile in neither is missing data. A pack without it reads an absent tile as zeros.
use cache_offroad::grid::PACK_TILE;
use cache_offroad::pack::{encode_u8_tile, Layer, PackSource, SqlitePack, SCHEMA};
use rusqlite::{params, Connection};

/// A pack with the three raster layers friction, trails and barriers, a bbox around the tiles, and tile (100, 200) of every layer
/// stored (non-zero). `covered_v`: whether the pack has the marker; `listed`: the tiles it lists as processed beside (100, 200).
fn pack(tag: &str, covered_v: bool, listed: &[(i64, i64)]) -> (SqlitePack, std::path::PathBuf) {
    let path = std::env::temp_dir().join(format!("cs-covered-{}-{tag}.sqlite", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let c = Connection::open(&path).unwrap();
    c.execute_batch(SCHEMA).unwrap();
    let meta = [("format_version", "2"), ("bbox_south", "40"), ("bbox_north", "45"), ("bbox_west", "-117"), ("bbox_east", "-110"), ("layers", "friction,trails,barriers")];
    for (k, v) in meta {
        c.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).unwrap();
    }
    let blob = encode_u8_tile(&vec![7u8; (PACK_TILE * PACK_TILE) as usize], 1);
    for l in ["friction", "trails", "barriers"] {
        c.execute("INSERT INTO tiles(layer, tx, ty, data) VALUES (?1, 100, 200, ?2)", params![l, blob]).unwrap();
    }
    if covered_v {
        c.execute("INSERT INTO meta(key, value) VALUES ('covered_v', '1')", []).unwrap();
        c.execute_batch("CREATE TABLE covered(layer TEXT NOT NULL, z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, PRIMARY KEY(layer,z,x,y)) WITHOUT ROWID;").unwrap();
        for l in ["friction", "trails", "barriers"] {
            for (x, y) in listed.iter().chain(&[(100, 200)]) {
                c.execute("INSERT INTO covered(layer, z, x, y) VALUES (?1, 13, ?2, ?3)", params![l, x, y]).unwrap();
            }
        }
    }
    drop(c);
    (SqlitePack::open(&path).unwrap(), path)
}

/// The window of the two neighbouring tiles (100, 200) and (101, 200), in global pixels.
const WIN: (i64, i64, usize, usize) = (200 * PACK_TILE, 100 * PACK_TILE, PACK_TILE as usize, 2 * PACK_TILE as usize);

#[test]
fn an_old_pack_reads_an_absent_tile_as_zeros_and_says_nothing() {
    let (p, path) = pack("old", false, &[]);
    assert!(p.missing_rects(WIN.0, WIN.1, WIN.2, WIN.3).is_empty());
    let v = p.read_u8(Layer::Trails, WIN.0, WIN.1, WIN.2, WIN.3).unwrap();
    assert_eq!((v[0], v[PACK_TILE as usize]), (7, 0), "the stored tile, then zeros for the absent one");
    let _ = std::fs::remove_file(path);
}

#[test]
fn a_covered_tile_that_is_absent_is_zeros_and_no_warning() {
    let (p, path) = pack("covered", true, &[(101, 200)]);
    assert!(p.missing_rects(WIN.0, WIN.1, WIN.2, WIN.3).is_empty());
    let v = p.read_u8(Layer::Trails, WIN.0, WIN.1, WIN.2, WIN.3).unwrap();
    assert_eq!((v[0], v[PACK_TILE as usize]), (7, 0));
    let _ = std::fs::remove_file(path);
}

#[test]
fn a_tile_neither_stored_nor_covered_is_missing_data() {
    let (p, path) = pack("missing", true, &[]);
    let r = p.missing_rects(WIN.0, WIN.1, WIN.2, WIN.3);
    assert_eq!(r, vec![(200 * PACK_TILE, 101 * PACK_TILE, 201 * PACK_TILE, 102 * PACK_TILE)]);
    // a window that is all stored: nothing
    assert!(p.missing_rects(WIN.0, WIN.1, WIN.2, PACK_TILE as usize).is_empty());
    let _ = std::fs::remove_file(path);
}
