//! SqlitePack: tile codec round trips, window reads across tile edges, point and MVUM queries.
use cache_offroad::pack::*;
use rusqlite::{params, Connection};

fn write_pack(path: &std::path::Path) -> (Vec<u32>, Vec<u8>) {
    let _ = std::fs::remove_file(path);
    let c = Connection::open(path).unwrap();
    c.execute_batch(SCHEMA).unwrap();
    for (k, v) in [
        ("format_version", FORMAT_VERSION), ("bbox_south", "42.0"), ("bbox_north", "43.0"), ("bbox_west", "-116.0"),
        ("bbox_east", "-115.0"), ("layers", "elev,friction,trails"),
    ] {
        c.execute("INSERT INTO meta VALUES (?1, ?2)", params![k, v]).unwrap();
    }
    // elevation tile (tx=3, ty=2): a smooth-ish pattern with all three terrarium bytes in use
    let mut q = vec![0u32; 65536];
    for i in 0..65536usize {
        q[i] = ((((32768 + 1000 + (i % 256) / 7) as u32) << 8) | ((i / 256 * 37) % 256) as u32) & 0xFF_FFFF;
        q[i] |= 0x80_0000 & 0; // keep within 24 bits
    }
    c.execute("INSERT INTO tiles VALUES ('elev', 3, 2, ?1)", params![encode_elev_tile(&q, 9)]).unwrap();
    let f: Vec<u8> = (0..65536usize).map(|i| (i % 251) as u8).collect();
    c.execute("INSERT INTO tiles VALUES ('friction', 3, 2, ?1)", params![encode_u8_tile(&f, 9)]).unwrap();
    c.execute("INSERT INTO parking VALUES (1, 42.5, -115.5, 'lot', 'surface', 'yes')", []).unwrap();
    c.execute("INSERT INTO parking_idx VALUES (1, -115.5, -115.5, 42.5, 42.5)", []).unwrap();
    c.execute("INSERT INTO trailheads VALUES (1, 42.6, -115.4, 'th', 'track')", []).unwrap();
    c.execute("INSERT INTO trailheads_idx VALUES (1, -115.4, -115.4, 42.6, 42.6)", []).unwrap();
    let lines = vec![vec![(-115.5, 42.5), (-115.4, 42.6)]];
    c.execute("INSERT INTO mvum VALUES (1, 0, '1', 'yearlong', NULL, NULL, NULL, 'open', '05/01-11/30', NULL, NULL, ?1)", params![encode_lines(&lines)]).unwrap();
    c.execute("INSERT INTO mvum_idx VALUES (1, -115.5, -115.4, 42.5, 42.6)", []).unwrap();
    (q, f)
}

#[test]
fn sqlite_pack_round_trip() {
    let dir = std::env::temp_dir().join(format!("offroad_pack_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("t.sqlite");
    let (q, f) = write_pack(&path);
    let p = SqlitePack::open(&path).unwrap();
    assert!(p.has_layer(Layer::Elevation) && !p.has_layer(Layer::Class));
    // window straddling the tile's top-left corner: tile origin is row 512, col 768
    let (r0, c0) = (510i64, 766i64);
    let e = p.read_elevation(r0, c0, 6, 6).unwrap();
    let u = p.read_u8(Layer::Friction, r0, c0, 6, 6).unwrap();
    for r in 0..6i64 {
        for c in 0..6i64 {
            let (gr, gc) = (r0 + r, c0 + c);
            let i = (r * 6 + c) as usize;
            if gr >= 512 && gc >= 768 {
                let ti = ((gr - 512) * 256 + (gc - 768)) as usize;
                assert_eq!(e[i].to_bits(), terrarium_f32(q[ti]).to_bits());
                assert_eq!(u[i], f[ti]);
            } else {
                assert!(e[i].is_nan());
                assert_eq!(u[i], 0);
            }
        }
    }
    let pk = p.parking_in_box(-116.0, -115.0, 42.0, 43.0).unwrap();
    assert_eq!(pk.len(), 1);
    assert_eq!(pk[0].name, "lot");
    assert!(p.parking_in_box(-114.0, -113.0, 42.0, 43.0).unwrap().is_empty());
    assert_eq!(p.trailheads_in_box(-116.0, -115.0, 42.0, 43.0).unwrap()[0].kind, "track");
    let m = p.mvum_in_box(42.0, 43.0, -116.0, -115.0).unwrap();
    assert_eq!(m.len(), 1);
    assert_eq!(m[0].lines[0].len(), 2);
    assert_eq!(m[0].access[1].0.as_deref(), Some("open"));
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn elevation_codec_is_lossless_for_all_bytes() {
    // every 24-bit value pattern round-trips, including wrap of the delta
    let mut q = vec![0u32; 65536];
    for (i, v) in q.iter_mut().enumerate() {
        *v = (i as u32).wrapping_mul(2654435761) & 0xFF_FFFF;
    }
    let dec = decode_elev_tile(&encode_elev_tile(&q, 3)).unwrap();
    for (a, b) in dec.iter().zip(&q) {
        assert_eq!(a.to_bits(), terrarium_f32(*b).to_bits());
    }
}

#[test]
fn terrarium_matches_navi_formula() {
    // navi: (r*256.0 + g + b/256.0) - 32768.0 in float32
    let q = (130u32 << 16) | (45 << 8) | 200;
    let want = (130f32 * 256.0 + 45.0 + 200f32 / 256.0) - 32768.0;
    assert_eq!(terrarium_f32(q).to_bits(), want.to_bits());
}
