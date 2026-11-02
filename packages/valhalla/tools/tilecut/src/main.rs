//! tilecut: cut a bbox subset out of a Valhalla tile_extract tar, or explode a whole tar into one file per tile.
//!
//! usage: tilecut <in.tar> <min_lon> <min_lat> <max_lon> <max_lat> [--tar out.tar] [--dir out_dir]
//!        tilecut --explode <in.tar> <out_dir>
//!
//! `--explode` writes every tile to `<out_dir>/<level>/<aaa>/<bbb>/<ccc>.gph` (the tar's own paths) and `<out_dir>/index.tsv`,
//! one line per tile: `<path without .gph>\t<bytes>\t<sha256 hex>`, sorted by path. That is what Cache publishes: a phone
//! works out which tiles a region needs from the region's polygon (the tiling below is fixed), looks them up in the index
//! (a tile that is not there has no roads) and fetches each one by its path; tiles of one build always fit together.
//!
//! Valhalla tiling (valhalla/baldr/tilehierarchy.cc): level 0 = 4 deg, level 1 = 1 deg,
//! level 2 = 0.25 deg tiles over the world box (-180,-90)..(180,90). Tile id = row * ncolumns + col,
//! with col = floor((lon+180)/size), row = floor((lat+90)/size). A tile's path in the tar / tile_dir is
//! `<level>/<id digits, zero padded to a multiple of 3, split in groups of 3>.gph`
//! (e.g. level 2 id 818660 -> `2/000/818/660.gph`). We parse level and id back out of the path,
//! keep every tile whose cell intersects the bbox, and copy its tar entry byte for byte.
//! The input is read sequentially once; unwanted entries are skipped with seeks.

use std::fs::{self, File};
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;

const LEVEL_SIZE: [f64; 3] = [4.0, 1.0, 0.25];

fn parse_octal(b: &[u8]) -> Option<u64> {
    if !b.is_empty() && b[0] & 0x80 != 0 {
        // GNU base-256
        let mut v: u64 = (b[0] & 0x7f) as u64;
        for x in &b[1..] {
            v = (v << 8) | *x as u64;
        }
        return Some(v);
    }
    let s: String = b.iter().take_while(|c| **c != 0).map(|c| *c as char).collect();
    let s = s.trim();
    if s.is_empty() {
        return Some(0);
    }
    u64::from_str_radix(s, 8).ok()
}

fn cstr(b: &[u8]) -> String {
    String::from_utf8_lossy(&b[..b.iter().position(|c| *c == 0).unwrap_or(b.len())]).into_owned()
}

/// path like "2/000/818/660.gph" -> (level, tile id)
fn parse_tile_path(p: &str) -> Option<(usize, u64)> {
    let p = p.trim_start_matches("./");
    let stem = p.strip_suffix(".gph")?;
    let mut parts = stem.split('/');
    let level: usize = parts.next()?.parse().ok()?;
    let mut digits = String::new();
    for g in parts {
        if g.is_empty() || !g.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        digits.push_str(g);
    }
    if digits.is_empty() {
        return None;
    }
    Some((level, digits.parse().ok()?))
}

/// Every tile of the tar to its own file, plus the index.
fn explode(input: &str, out: &str) {
    let mut inp = File::open(input).expect("open input tar");
    let total = inp.metadata().unwrap().len();
    fs::create_dir_all(out).unwrap();
    let mut index: Vec<(String, u64, String)> = Vec::new();
    let (mut pos, mut seen) = (0u64, 0u64);
    let mut hdr = [0u8; 512];
    loop {
        inp.seek(SeekFrom::Start(pos)).unwrap();
        if inp.read_exact(&mut hdr).is_err() || hdr.iter().all(|b| *b == 0) {
            break;
        }
        let size = parse_octal(&hdr[124..136]).expect("bad size field");
        let typeflag = hdr[156];
        let mut name = cstr(&hdr[0..100]);
        if &hdr[257..262] == b"ustar" {
            let prefix = cstr(&hdr[345..500]);
            if !prefix.is_empty() {
                name = format!("{prefix}/{name}");
            }
        }
        let data_pos = pos + 512;
        pos = data_pos + (size + 511) / 512 * 512;
        seen += 1;
        if typeflag != b'0' && typeflag != 0 {
            continue;
        }
        let rel = name.trim_start_matches("./").to_string();
        let Some((level, _)) = parse_tile_path(&rel) else {
            eprintln!("skip non-tile entry {name}");
            continue;
        };
        if level >= 3 {
            continue;
        }
        let mut data = vec![0u8; size as usize];
        inp.seek(SeekFrom::Start(data_pos)).unwrap();
        inp.read_exact(&mut data).unwrap();
        let p = Path::new(out).join(&rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, &data).unwrap();
        index.push((rel.trim_end_matches(".gph").to_string(), size, sha256::hex(&data)));
        if seen % 20_000 == 0 {
            eprintln!("..{:.1}% of input", 100.0 * pos as f64 / total as f64);
        }
    }
    index.sort();
    let mut w = BufWriter::new(File::create(Path::new(out).join("index.tsv")).unwrap());
    for (p, n, h) in &index {
        writeln!(w, "{p}\t{n}\t{h}").unwrap();
    }
    w.flush().unwrap();
    let bytes: u64 = index.iter().map(|t| t.1).sum();
    println!("tiles: {}; bytes: {bytes}", index.len());
}

/// SHA-256 (FIPS 180-4), so the tool stays without dependencies.
mod sha256 {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
        0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
        0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    pub fn hex(data: &[u8]) -> String {
        let mut h: [u32; 8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
        let mut msg = data.to_vec();
        let bits = (data.len() as u64).wrapping_mul(8);
        msg.push(0x80);
        while msg.len() % 64 != 56 {
            msg.push(0);
        }
        msg.extend_from_slice(&bits.to_be_bytes());
        for block in msg.chunks(64) {
            let mut w = [0u32; 64];
            for i in 0..16 {
                w[i] = u32::from_be_bytes([block[4 * i], block[4 * i + 1], block[4 * i + 2], block[4 * i + 3]]);
            }
            for i in 16..64 {
                let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
                let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
            }
            let mut v = h;
            for i in 0..64 {
                let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
                let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
                let t1 = v[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
                let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
                let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
                let t2 = s0.wrapping_add(maj);
                v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
            }
            for i in 0..8 {
                h[i] = h[i].wrapping_add(v[i]);
            }
        }
        h.iter().map(|x| format!("{x:08x}")).collect()
    }

    #[cfg(test)]
    mod tests {
        #[test]
        fn known_digests() {
            assert_eq!(super::hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
            assert_eq!(super::hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
            let long = vec![b'a'; 1_000_000];
            assert_eq!(super::hex(&long), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
        }
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() == 4 && a[1] == "--explode" {
        explode(&a[2], &a[3]);
        return;
    }
    if a.len() < 6 {
        eprintln!("usage: tilecut <in.tar> <min_lon> <min_lat> <max_lon> <max_lat> [--tar out.tar] [--dir out_dir]");
        std::process::exit(2);
    }
    let f = |i: usize| -> f64 { a[i].parse().expect("bbox number") };
    let (min_lon, min_lat, max_lon, max_lat) = (f(2), f(3), f(4), f(5));
    let (mut out_tar, mut out_dir) = (None, None);
    let mut i = 6;
    while i < a.len() {
        match a[i].as_str() {
            "--tar" => { out_tar = Some(a[i + 1].clone()); i += 2; }
            "--dir" => { out_dir = Some(a[i + 1].clone()); i += 2; }
            o => { eprintln!("unknown option {o}"); std::process::exit(2); }
        }
    }

    // per level: inclusive col/row ranges
    let ranges: Vec<(u64, u64, u64, u64, u64)> = LEVEL_SIZE
        .iter()
        .map(|s| {
            let ncols = (360.0 / s).round() as u64;
            let nrows = (180.0 / s).round() as u64;
            let c0 = (((min_lon + 180.0) / s).floor() as u64).min(ncols - 1);
            let c1 = (((max_lon + 180.0) / s).floor() as u64).min(ncols - 1);
            let r0 = (((min_lat + 90.0) / s).floor() as u64).min(nrows - 1);
            let r1 = (((max_lat + 90.0) / s).floor() as u64).min(nrows - 1);
            (ncols, c0, c1, r0, r1)
        })
        .collect();

    let mut inp = File::open(&a[1]).expect("open input tar");
    let total = inp.metadata().unwrap().len();
    let mut tar_out = out_tar.as_ref().map(|p| BufWriter::with_capacity(1 << 20, File::create(p).expect("create out tar")));
    if let Some(d) = &out_dir { fs::create_dir_all(d).unwrap(); }

    let mut pos: u64 = 0;
    let mut hdr = [0u8; 512];
    let (mut kept, mut kept_bytes, mut seen, mut skipped_other) = ([0u64; 3], 0u64, 0u64, 0u64);
    loop {
        inp.seek(SeekFrom::Start(pos)).unwrap();
        if inp.read_exact(&mut hdr).is_err() { break; }
        if hdr.iter().all(|b| *b == 0) { break; }
        let size = parse_octal(&hdr[124..136]).expect("bad size field");
        let typeflag = hdr[156];
        let mut name = cstr(&hdr[0..100]);
        if &hdr[257..262] == b"ustar" {
            let prefix = cstr(&hdr[345..500]);
            if !prefix.is_empty() { name = format!("{prefix}/{name}"); }
        }
        let data_pos = pos + 512;
        let padded = (size + 511) / 512 * 512;
        pos = data_pos + padded;
        seen += 1;
        if typeflag != b'0' && typeflag != 0 { skipped_other += 1; continue; }
        let Some((level, id)) = parse_tile_path(&name) else { skipped_other += 1; eprintln!("skip non-tile entry {name}"); continue; };
        if level >= 3 { continue; }
        let (ncols, c0, c1, r0, r1) = ranges[level];
        let (col, row) = (id % ncols, id / ncols);
        if col < c0 || col > c1 || row < r0 || row > r1 { continue; }

        let mut data = vec![0u8; size as usize];
        inp.seek(SeekFrom::Start(data_pos)).unwrap();
        inp.read_exact(&mut data).unwrap();
        if let Some(w) = tar_out.as_mut() {
            w.write_all(&hdr).unwrap();
            w.write_all(&data).unwrap();
            w.write_all(&vec![0u8; (padded - size) as usize]).unwrap();
        }
        if let Some(d) = &out_dir {
            let p = Path::new(d).join(name.trim_start_matches("./"));
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, &data).unwrap();
        }
        kept[level] += 1;
        kept_bytes += size;
        if seen % 200_000 == 0 { eprintln!("..{:.1}% of input scanned", 100.0 * pos as f64 / total as f64); }
    }
    if let Some(mut w) = tar_out {
        w.write_all(&[0u8; 1024]).unwrap();
        w.flush().unwrap();
    }
    println!("entries scanned: {seen}; non-tile entries skipped: {skipped_other}");
    println!("kept tiles: level0={} level1={} level2={}; tile bytes={}", kept[0], kept[1], kept[2], kept_bytes);
}
