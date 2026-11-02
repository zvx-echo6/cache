//! The house numbers of one street row (`addr_streets.numbers`, docs/PLACES-TILES.md): the builder writes the blob and
//! the geocoder reads it.
//!
//! ```text
//! numbers := ver:u8 (=1) count:varint entry*count
//! entry   := dnum:varint            numeric part minus the previous entry's (first: minus 0); sorted by (num, suffix)
//!            suf_len:u8 suf:utf8    the rest of the number after its leading digits ("A", "-1/2", "" = none)
//!            dlat:zigzag-varint     latitude  in 1e-6 degrees minus the previous entry's (first: minus the row's)
//!            dlon:zigzag-varint     longitude in 1e-6 degrees minus the previous entry's (first: minus the row's)
//! ```
//!
//! The numeric part is the run of leading digits when it is a plain number (no leading zero) that fits a u32; anything else
//! ("0", "007", "A12", a run of 20 digits) has num 0 and the whole string as its suffix. So a number reads back exactly as
//! it was written: num 0 is the suffix alone, otherwise num then suffix. A number that appears more than once is kept once,
//! with its first point (the builder sorts a street's points by source id first, so which one is deterministic).

/// The blob's layout version (its first byte).
pub const NUMBERS_VERSION: u8 = 1;

/// Coordinates are stored in steps of 1e-6 degrees (about 0.11 m).
const STEP: f64 = 1e6;

/// One house number and its point.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// The numeric part (0 when the number has no plain leading digits).
    pub num: u32,
    /// The rest of the number: "A", "-1/2", "" (or the whole number when `num` is 0).
    pub suffix: String,
    pub lat: f64,
    pub lon: f64,
}

impl Entry {
    /// The number as written: "350", "12A", "1/2".
    pub fn number(&self) -> String {
        if self.num == 0 {
            self.suffix.clone()
        } else {
            format!("{}{}", self.num, self.suffix)
        }
    }
}

/// A house number's numeric part and the rest ("12A" is (12, "A"); "A12", "0" and "007" are (0, the whole string)).
pub fn split_number(s: &str) -> (u32, &str) {
    let digits = s.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 || s.starts_with('0') {
        return (0, s);
    }
    match s[..digits].parse::<u32>() {
        Ok(n) => (n, &s[digits..]),
        Err(_) => (0, s),
    }
}

fn quantise(v: f64) -> i64 {
    (v * STEP).round() as i64
}

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

fn unzigzag(v: u64) -> i64 {
    ((v >> 1) as i64) ^ -((v & 1) as i64)
}

/// The blob for a street row centred on (`row_lat`, `row_lon`): `numbers` are (house number, lat, lon) in the builder's
/// order; they are sorted and duplicates dropped here. Fails on a non-finite point, an empty number or a suffix longer than
/// 255 bytes.
pub fn encode<S: AsRef<str>>(row_lat: f64, row_lon: f64, numbers: &[(S, f64, f64)]) -> Result<Vec<u8>, String> {
    if !row_lat.is_finite() || !row_lon.is_finite() {
        return Err("the street row's centre is not a finite point".into());
    }
    let mut entries: Vec<(u32, &str, f64, f64)> = Vec::with_capacity(numbers.len());
    for (n, lat, lon) in numbers {
        let n = n.as_ref();
        if n.is_empty() {
            return Err("a house number is empty".into());
        }
        if !lat.is_finite() || !lon.is_finite() {
            return Err(format!("house number {n:?} has no finite point"));
        }
        let (num, suffix) = split_number(n);
        if suffix.len() > u8::MAX as usize {
            return Err(format!("house number {n:?} is longer than {} bytes after its digits", u8::MAX));
        }
        entries.push((num, suffix, *lat, *lon));
    }
    // Stable: of two equal numbers the first given stays first, and the dedupe keeps it.
    entries.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
    entries.dedup_by(|b, a| (a.0, a.1) == (b.0, b.1));

    let mut out = Vec::with_capacity(1 + 5 + entries.len() * 8);
    out.push(NUMBERS_VERSION);
    put_varint(&mut out, entries.len() as u64);
    let (mut num, mut lat, mut lon) = (0u32, quantise(row_lat), quantise(row_lon));
    for (n, suffix, la, lo) in entries {
        let (qa, qo) = (quantise(la), quantise(lo));
        put_varint(&mut out, (n - num) as u64);
        out.push(suffix.len() as u8);
        out.extend_from_slice(suffix.as_bytes());
        put_varint(&mut out, zigzag(qa - lat));
        put_varint(&mut out, zigzag(qo - lon));
        (num, lat, lon) = (n, qa, qo);
    }
    Ok(out)
}

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn byte(&mut self) -> Result<u8, String> {
        let v = *self.b.get(self.at).ok_or("the numbers blob ends early")?;
        self.at += 1;
        Ok(v)
    }

    fn varint(&mut self) -> Result<u64, String> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let b = self.byte()?;
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
        }
        Err("a varint in the numbers blob is longer than 64 bits".into())
    }

    fn bytes(&mut self, n: usize) -> Result<&[u8], String> {
        let end = self.at.checked_add(n).filter(|e| *e <= self.b.len()).ok_or("the numbers blob ends early")?;
        let s = &self.b[self.at..end];
        self.at = end;
        Ok(s)
    }
}

/// The entries of a blob written by [`encode`], in its order (by number), for the row centred on (`row_lat`, `row_lon`).
pub fn decode(blob: &[u8], row_lat: f64, row_lon: f64) -> Result<Vec<Entry>, String> {
    let mut r = Reader { b: blob, at: 0 };
    let ver = r.byte()?;
    if ver != NUMBERS_VERSION {
        return Err(format!("numbers blob version {ver} is not supported (this reader reads {NUMBERS_VERSION})"));
    }
    let count = r.varint()?;
    // Each entry takes at least 4 bytes, so a count beyond that is a damaged blob (and is not allocated for).
    if count > (blob.len() as u64) / 4 {
        return Err(format!("the numbers blob says {count} entries but holds {} bytes", blob.len()));
    }
    let mut out = Vec::with_capacity(count as usize);
    let (mut num, mut lat, mut lon) = (0u32, quantise(row_lat), quantise(row_lon));
    for _ in 0..count {
        let d = r.varint()?;
        num = u32::try_from(num as u64 + d).map_err(|_| "a house number in the numbers blob is beyond u32".to_string())?;
        let n = r.byte()? as usize;
        let suffix = std::str::from_utf8(r.bytes(n)?).map_err(|_| "a suffix in the numbers blob is not UTF-8".to_string())?.to_string();
        lat = lat.checked_add(unzigzag(r.varint()?)).ok_or("a latitude in the numbers blob overflows")?;
        lon = lon.checked_add(unzigzag(r.varint()?)).ok_or("a longitude in the numbers blob overflows")?;
        out.push(Entry { num, suffix, lat: lat as f64 / STEP, lon: lon as f64 / STEP });
    }
    if r.at != blob.len() {
        return Err(format!("the numbers blob has {} bytes after its last entry", blob.len() - r.at));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() <= 0.5e-6 + 1e-12
    }

    #[test]
    fn numbers_split_into_digits_and_the_rest() {
        assert_eq!(split_number("350"), (350, ""));
        assert_eq!(split_number("12A"), (12, "A"));
        assert_eq!(split_number("101-1/2"), (101, "-1/2"));
        assert_eq!(split_number("A12"), (0, "A12"));
        assert_eq!(split_number("0"), (0, "0"));
        assert_eq!(split_number("007"), (0, "007"));
        assert_eq!(split_number("99999999999"), (0, "99999999999"), "beyond u32");
        assert_eq!(split_number("N1234"), (0, "N1234"));
    }

    #[test]
    fn a_street_round_trips_sorted_and_deduped() {
        let (rl, ro) = (40.7608, -111.8910);
        let given = [
            ("352", 40.76101, -111.88812),
            ("350", 40.761, -111.888),
            ("12A", 40.7581234, -111.8909876),
            ("12", 40.7581, -111.891),
            ("350", 41.0, -112.0), // a second point for 350: dropped, the first is kept
            ("1/2", 40.7590, -111.8900),
            ("007", 40.7591, -111.8901),
            ("0", 40.7592, -111.8902),
            ("101-1/2", 40.7593, -111.8903),
        ];
        let blob = encode(rl, ro, &given).unwrap();
        assert_eq!(blob[0], NUMBERS_VERSION);
        let got = decode(&blob, rl, ro).unwrap();
        let numbers: Vec<String> = got.iter().map(Entry::number).collect();
        // num 0 first (by suffix), then by number and suffix.
        assert_eq!(numbers, ["0", "007", "1/2", "12", "12A", "101-1/2", "350", "352"]);
        for e in &got {
            let (_, lat, lon) = given.iter().find(|g| g.0 == e.number()).unwrap();
            assert!(close(e.lat, *lat) && close(e.lon, *lon), "{} {} {}", e.number(), e.lat, e.lon);
        }
        assert!(close(got.iter().find(|e| e.num == 350).unwrap().lat, 40.761), "the first 350 is the one kept");
        assert_eq!(got.iter().find(|e| e.num == 12 && e.suffix == "A").unwrap().suffix, "A");
    }

    #[test]
    fn deltas_are_small_on_a_real_street() {
        // A residential street: 200 houses 15 m apart, numbers 2 apart. Each entry should take a handful of bytes.
        let (rl, ro) = (40.70, -111.90);
        let pts: Vec<(String, f64, f64)> = (0..200).map(|i| (format!("{}", 1000 + 2 * i), 40.70, -111.90 + i as f64 * 0.000178)).collect();
        let blob = encode(rl, ro, &pts).unwrap();
        let per = blob.len() as f64 / 200.0;
        assert!(per <= 6.0, "{per} bytes per address");
        // dnum 2 (1 byte), no suffix (1), dlat 0 (1), dlon 178 zigzagged = 356 (2): 5 bytes, after the first.
        assert_eq!(blob.len(), 1 + 2 + (2 + 1 + 1 + 1) + 199 * 5);
        let back = decode(&blob, rl, ro).unwrap();
        assert_eq!(back.len(), 200);
        assert!(back.iter().zip(&pts).all(|(e, p)| e.number() == p.0 && close(e.lat, p.1) && close(e.lon, p.2)));
    }

    #[test]
    fn edge_cases() {
        // No numbers at all.
        let empty = encode::<&str>(1.0, 2.0, &[]).unwrap();
        assert_eq!(empty, [NUMBERS_VERSION, 0]);
        assert!(decode(&empty, 1.0, 2.0).unwrap().is_empty());
        // Negative deltas both ways, across the antimeridian's neighbourhood and the poles.
        let pts = [("1", -89.999999, 179.999999), ("2", 89.999999, -179.999999), ("3", 0.0, 0.0)];
        let back = decode(&encode(0.0, 0.0, &pts).unwrap(), 0.0, 0.0).unwrap();
        assert!(back.iter().zip(&pts).all(|(e, p)| close(e.lat, p.1) && close(e.lon, p.2)));
        // The largest plain number and a 255-byte suffix.
        let long = format!("7{}", "x".repeat(255));
        let pts = [(u32::MAX.to_string(), 1.0, 1.0), (long.clone(), 1.0, 1.0)];
        let back = decode(&encode(1.0, 1.0, &pts).unwrap(), 1.0, 1.0).unwrap();
        assert_eq!(back.iter().map(Entry::number).collect::<Vec<_>>(), [long, u32::MAX.to_string()]);
        // Unicode suffixes are bytes in the blob, characters when read.
        let back = decode(&encode(1.0, 1.0, &[("5\u{bd}", 1.0, 1.0)]).unwrap(), 1.0, 1.0).unwrap();
        assert_eq!(back[0].number(), "5\u{bd}");
        // What encode refuses.
        assert!(encode(1.0, 1.0, &[(format!("7{}", "x".repeat(256)), 1.0, 1.0)]).is_err());
        assert!(encode(1.0, 1.0, &[("", 1.0, 1.0)]).is_err());
        assert!(encode(1.0, 1.0, &[("3", f64::NAN, 1.0)]).is_err());
        assert!(encode(f64::INFINITY, 1.0, &[("3", 1.0, 1.0)]).is_err());
    }

    #[test]
    fn damaged_blobs_are_errors_not_panics() {
        let good = encode(40.0, -111.0, &[("10", 40.001, -111.001), ("12B", 40.002, -111.002)]).unwrap();
        assert!(decode(&[], 40.0, -111.0).is_err());
        assert!(decode(&[2, 0], 40.0, -111.0).is_err(), "unknown version");
        for cut in 1..good.len() {
            assert!(decode(&good[..cut], 40.0, -111.0).is_err(), "cut at {cut}");
        }
        let mut extra = good.clone();
        extra.push(0);
        assert!(decode(&extra, 40.0, -111.0).is_err(), "trailing bytes");
        assert!(decode(&[1, 0xff, 0xff, 0xff, 0xff, 0x0f], 40.0, -111.0).is_err(), "a count larger than the blob");
        assert!(decode(&[1, 1, 0, 1, 0xff, 0, 0], 40.0, -111.0).is_err(), "suffix not UTF-8");
        assert!(decode(&[1, 1, 0xff, 0xff, 0xff, 0xff, 0x7f, 0, 0, 0], 40.0, -111.0).is_err(), "number beyond u32");
        assert!(decode(&[1, 1, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0], 40.0, -111.0).is_err(), "varint too long");
    }
}
