//! Minimal PMTiles v3 reader (read-only): header, gzip directories, tile lookup. Pure Rust.
use flate2::read::GzDecoder;
use memmap2::Mmap;
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;

pub struct PmTiles {
    mmap: Mmap,
    pub tile_type: u8,
    pub tile_compression: u8,
    pub min_zoom: u8,
    pub max_zoom: u8,
    data_offset: u64,
    /// tile id -> (offset into tile data, length)
    index: HashMap<u64, (u64, u32)>,
}

fn u64le(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}

fn varint(b: &[u8], pos: &mut usize) -> u64 {
    let mut v = 0u64;
    let mut shift = 0;
    loop {
        let x = b[*pos];
        *pos += 1;
        v |= ((x & 0x7f) as u64) << shift;
        if x & 0x80 == 0 {
            return v;
        }
        shift += 7;
    }
}

fn rotate(n: u64, x: &mut u64, y: &mut u64, rx: bool, ry: bool) {
    if !ry {
        if rx {
            *x = n - 1 - *x;
            *y = n - 1 - *y;
        }
        std::mem::swap(x, y);
    }
}

pub fn zxy_to_tile_id(z: u8, x: u64, y: u64) -> u64 {
    let mut base = 0u64;
    for i in 0..z {
        base += 1u64 << (2 * i as u64);
    }
    let n = 1u64 << z;
    let (mut x, mut y) = (x, y);
    let mut d = 0u64;
    let mut s = n / 2;
    while s > 0 {
        let rx = (x & s) > 0;
        let ry = (y & s) > 0;
        d += s * s * ((3 * rx as u64) ^ ry as u64);
        rotate(n, &mut x, &mut y, rx, ry);
        s /= 2;
    }
    base + d
}

fn decompress(data: &[u8], comp: u8) -> Result<Vec<u8>, String> {
    match comp {
        1 | 0 => Ok(data.to_vec()),
        2 => {
            let mut out = Vec::new();
            GzDecoder::new(data).read_to_end(&mut out).map_err(|e| e.to_string())?;
            Ok(out)
        }
        c => Err(format!("unsupported PMTiles compression {c}")),
    }
}

fn read_dir(
    mm: &[u8], off: u64, len: u64, internal: u8, leaf_base: u64, out: &mut HashMap<u64, (u64, u32)>, depth: u32,
) -> Result<(), String> {
    let raw = decompress(&mm[off as usize..(off + len) as usize], internal)?;
    let mut p = 0usize;
    let n = varint(&raw, &mut p) as usize;
    let mut ids = vec![0u64; n];
    let mut last = 0u64;
    for id in ids.iter_mut() {
        last += varint(&raw, &mut p);
        *id = last;
    }
    let runs: Vec<u64> = (0..n).map(|_| varint(&raw, &mut p)).collect();
    let lens: Vec<u64> = (0..n).map(|_| varint(&raw, &mut p)).collect();
    let mut offs = vec![0u64; n];
    for i in 0..n {
        let v = varint(&raw, &mut p);
        offs[i] = if v == 0 && i > 0 { offs[i - 1] + lens[i - 1] } else { v.saturating_sub(1) };
    }
    for i in 0..n {
        if runs[i] == 0 {
            if depth > 3 {
                return Err("PMTiles directory too deep".into());
            }
            read_dir(mm, leaf_base + offs[i], lens[i], internal, leaf_base, out, depth + 1)?;
        } else {
            for k in 0..runs[i] {
                out.insert(ids[i] + k, (offs[i], lens[i] as u32));
            }
        }
    }
    Ok(())
}

impl PmTiles {
    pub fn open(path: &Path) -> Result<PmTiles, String> {
        let f = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let mmap = unsafe { Mmap::map(&f) }.map_err(|e| e.to_string())?;
        if &mmap[0..7] != b"PMTiles" || mmap[7] != 3 {
            return Err("not a PMTiles v3 file".into());
        }
        let root_off = u64le(&mmap, 8);
        let root_len = u64le(&mmap, 16);
        let leaf_off = u64le(&mmap, 40);
        let data_off = u64le(&mmap, 56);
        let internal = mmap[97];
        let mut index = HashMap::new();
        read_dir(&mmap, root_off, root_len, internal, leaf_off, &mut index, 0)?;
        Ok(PmTiles {
            tile_compression: mmap[98], tile_type: mmap[99], min_zoom: mmap[100], max_zoom: mmap[101],
            data_offset: data_off, index, mmap,
        })
    }

    pub fn tile_count(&self) -> usize {
        self.index.len()
    }

    /// Raw (possibly compressed) tile bytes.
    pub fn get(&self, z: u8, x: u64, y: u64) -> Option<&[u8]> {
        let id = zxy_to_tile_id(z, x, y);
        let &(off, len) = self.index.get(&id)?;
        let s = (self.data_offset + off) as usize;
        Some(&self.mmap[s..s + len as usize])
    }
}
