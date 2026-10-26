//! Minimal PMTiles v3 writer for single-zoom tile sets (used to cut an elevation extract). Clustered,
//! gzip directories (root + leaf directories, as the spec recommends), tiles stored uncompressed.
use flate2::write::GzEncoder;
use flate2::Compression;
use std::io::Write;

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8 & 0x7f) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

pub struct Entry {
    pub tile_id: u64,
    pub offset: u64,
    pub length: u32,
    /// 0 = leaf directory pointer
    pub run_length: u32,
}

fn gz(b: &[u8]) -> Vec<u8> {
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}

fn serialize_dir(entries: &[Entry]) -> Vec<u8> {
    let mut b = Vec::new();
    put_varint(&mut b, entries.len() as u64);
    let mut last = 0;
    for e in entries {
        put_varint(&mut b, e.tile_id - last);
        last = e.tile_id;
    }
    for e in entries {
        put_varint(&mut b, e.run_length as u64);
    }
    for e in entries {
        put_varint(&mut b, e.length as u64);
    }
    for (i, e) in entries.iter().enumerate() {
        if i > 0 && e.offset == entries[i - 1].offset + entries[i - 1].length as u64 {
            put_varint(&mut b, 0);
        } else {
            put_varint(&mut b, e.offset + 1);
        }
    }
    gz(&b)
}

/// Build a whole PMTiles file. `tiles`: (tile_id, bytes), any order. bounds_e7: min_lon, min_lat, max_lon, max_lat.
pub fn build(mut tiles: Vec<(u64, Vec<u8>)>, zoom: u8, bounds_e7: [i32; 4], metadata_json: &str) -> Vec<u8> {
    tiles.sort_by_key(|t| t.0);
    let mut data = Vec::new();
    let mut entries = Vec::new();
    for (id, bytes) in &tiles {
        entries.push(Entry { tile_id: *id, offset: data.len() as u64, length: bytes.len() as u32, run_length: 1 });
        data.extend_from_slice(bytes);
    }
    // root + leaves (4096 entries per leaf)
    const LEAF: usize = 4096;
    let (root, leaves) = if entries.len() <= LEAF {
        (serialize_dir(&entries), Vec::new())
    } else {
        let mut leaf_bytes = Vec::new();
        let mut root_entries = Vec::new();
        for chunk in entries.chunks(LEAF) {
            let d = serialize_dir(chunk);
            root_entries.push(Entry { tile_id: chunk[0].tile_id, offset: leaf_bytes.len() as u64, length: d.len() as u32, run_length: 0 });
            leaf_bytes.extend_from_slice(&d);
        }
        (serialize_dir(&root_entries), leaf_bytes)
    };
    let meta = gz(metadata_json.as_bytes());
    let root_off = 127u64;
    let meta_off = root_off + root.len() as u64;
    let leaf_off = meta_off + meta.len() as u64;
    let data_off = leaf_off + leaves.len() as u64;
    let mut h = Vec::with_capacity(127);
    h.extend_from_slice(b"PMTiles");
    h.push(3);
    for v in [root_off, root.len() as u64, meta_off, meta.len() as u64, leaf_off, leaves.len() as u64, data_off, data.len() as u64,
              tiles.len() as u64, tiles.len() as u64, tiles.len() as u64] {
        h.extend_from_slice(&v.to_le_bytes());
    }
    h.push(1); // clustered
    h.push(2); // internal compression gzip
    h.push(1); // tile compression none
    h.push(4); // tile type webp
    h.push(zoom);
    h.push(zoom);
    for v in bounds_e7 {
        h.extend_from_slice(&v.to_le_bytes());
    }
    h.push(zoom); // center zoom
    h.extend_from_slice(&((bounds_e7[0] / 2 + bounds_e7[2] / 2)).to_le_bytes());
    h.extend_from_slice(&((bounds_e7[1] / 2 + bounds_e7[3] / 2)).to_le_bytes());
    assert_eq!(h.len(), 127);
    let mut out = h;
    out.extend_from_slice(&root);
    out.extend_from_slice(&meta);
    out.extend_from_slice(&leaves);
    out.extend_from_slice(&data);
    out
}
