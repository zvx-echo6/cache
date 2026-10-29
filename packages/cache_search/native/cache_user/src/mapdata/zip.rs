//! The KML inside a KMZ. A KMZ is a zip archive; this reads its central directory and inflates one entry (stored or
//! deflate) with flate2, which is all a KMZ needs: `doc.kml` when there is one, else the first `.kml` at the top level, else
//! the first `.kml` anywhere.

use super::{bad, MAX_FILE_BYTES};
use std::io::Read;

fn u16_at(b: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?))
}

fn u32_at(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?))
}

struct Entry {
    name: String,
    method: u16,
    comp: usize,
    size: u64,
    local: usize,
}

fn entries(b: &[u8]) -> Option<Vec<Entry>> {
    // the end of central directory record is in the last 22 + 65535 bytes
    let lo = b.len().saturating_sub(22 + 65535);
    let eocd = (lo..b.len().saturating_sub(21)).rev().find(|&i| u32_at(b, i) == Some(0x0605_4b50))?;
    let count = u16_at(b, eocd + 10)? as usize;
    let mut at = u32_at(b, eocd + 16)? as usize;
    let mut out = Vec::new();
    for _ in 0..count {
        if u32_at(b, at)? != 0x0201_4b50 {
            return None;
        }
        let (n, x, c) = (u16_at(b, at + 28)? as usize, u16_at(b, at + 30)? as usize, u16_at(b, at + 32)? as usize);
        out.push(Entry {
            method: u16_at(b, at + 10)?,
            comp: u32_at(b, at + 20)? as usize,
            size: u32_at(b, at + 24)? as u64,
            local: u32_at(b, at + 42)? as usize,
            name: String::from_utf8_lossy(b.get(at + 46..at + 46 + n)?).into_owned(),
        });
        at += 46 + n + x + c;
    }
    Some(out)
}

pub(crate) fn kml_of_kmz(b: &[u8]) -> crate::Result<Vec<u8>> {
    let list = entries(b).ok_or_else(|| bad("KMZ: not a readable zip archive"))?;
    let is_kml = |e: &&Entry| e.name.to_ascii_lowercase().ends_with(".kml");
    let e = list
        .iter()
        .find(|e| e.name.eq_ignore_ascii_case("doc.kml"))
        .or_else(|| list.iter().filter(is_kml).find(|e| !e.name.contains('/')))
        .or_else(|| list.iter().find(is_kml))
        .ok_or_else(|| bad("KMZ: no .kml file inside"))?;
    if e.size > MAX_FILE_BYTES {
        return Err(bad("KMZ: the KML inside is too large"));
    }
    let l = e.local;
    if u32_at(b, l) != Some(0x0403_4b50) {
        return Err(bad("KMZ: not a readable zip archive"));
    }
    let start = l + 30 + u16_at(b, l + 26).unwrap_or(0) as usize + u16_at(b, l + 28).unwrap_or(0) as usize;
    let data = b.get(start..start + e.comp).ok_or_else(|| bad("KMZ: the archive is cut short"))?;
    match e.method {
        0 => Ok(data.to_vec()),
        8 => {
            let mut out = Vec::new();
            flate2::read::DeflateDecoder::new(data)
                .take(MAX_FILE_BYTES + 1)
                .read_to_end(&mut out)
                .map_err(|_| bad("KMZ: the KML inside cannot be unpacked"))?;
            if out.len() as u64 > MAX_FILE_BYTES {
                return Err(bad("KMZ: the KML inside is too large"));
            }
            Ok(out)
        }
        m => Err(bad(format!("KMZ: compression method {m} is not supported"))),
    }
}

/// A zip archive of the given (name, content) files, deflated: the tests' KMZ files.
#[cfg(test)]
pub(crate) fn make(files: &[(&str, &[u8])]) -> Vec<u8> {
    use std::io::Write;
    let (mut out, mut central) = (Vec::new(), Vec::new());
    for (name, content) in files {
        let mut enc = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
        enc.write_all(content).unwrap();
        let comp = enc.finish().unwrap();
        let off = out.len() as u32;
        let head = |sig: u32| {
            let mut h = sig.to_le_bytes().to_vec();
            h.extend_from_slice(&[20, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
            h.extend_from_slice(&(comp.len() as u32).to_le_bytes());
            h.extend_from_slice(&(content.len() as u32).to_le_bytes());
            h.extend_from_slice(&(name.len() as u16).to_le_bytes());
            h.extend_from_slice(&[0, 0]);
            h
        };
        out.extend(head(0x0403_4b50));
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(&comp);
        // central header: version made by, then the same fields, then comment/disk/attrs and the offset
        let mut c = 0x0201_4b50u32.to_le_bytes().to_vec();
        c.extend_from_slice(&[20, 0]);
        c.extend_from_slice(&head(0)[4..]);
        c.extend_from_slice(&[0; 10]);
        c.extend_from_slice(&off.to_le_bytes());
        c.extend_from_slice(name.as_bytes());
        central.extend(c);
    }
    let (cd_off, cd_len) = (out.len() as u32, central.len() as u32);
    out.extend(central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0, 0, 0, 0]);
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&cd_len.to_le_bytes());
    out.extend_from_slice(&cd_off.to_le_bytes());
    out.extend_from_slice(&[0, 0]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doc_kml_is_found_and_inflated() {
        let z = make(&[("files/icon.png", b"\x89PNG"), ("other.kml", b"<kml>other</kml>"), ("doc.kml", b"<kml>doc</kml>")]);
        assert_eq!(kml_of_kmz(&z).unwrap(), b"<kml>doc</kml>");
        let z = make(&[("a/b.kml", b"<kml>deep</kml>"), ("top.kml", b"<kml>top</kml>")]);
        assert_eq!(kml_of_kmz(&z).unwrap(), b"<kml>top</kml>");
    }

    #[test]
    fn broken_archives_are_errors() {
        assert_eq!(kml_of_kmz(b"PK\x03\x04 not really").unwrap_err().code, "bad_json");
        assert!(kml_of_kmz(&make(&[("a.png", b"x")])).unwrap_err().message.contains("no .kml"));
        let mut z = make(&[("doc.kml", b"<kml>doc</kml>")]);
        z.truncate(40);
        assert!(kml_of_kmz(&z).is_err());
    }
}
