//! tilecut: cut a bbox subset out of a Valhalla tile_extract tar.
//!
//! usage: tilecut <in.tar> <min_lon> <min_lat> <max_lon> <max_lat> [--tar out.tar] [--dir out_dir]
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

fn main() {
    let a: Vec<String> = std::env::args().collect();
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
