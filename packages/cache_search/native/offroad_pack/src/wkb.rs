//! WKB LineString / MultiLineString -> parts of (lon, lat). Z/M ordinates are skipped.
fn rd_u32(b: &[u8], o: &mut usize, le: bool) -> Option<u32> {
    let s = b.get(*o..*o + 4)?;
    *o += 4;
    Some(if le { u32::from_le_bytes(s.try_into().ok()?) } else { u32::from_be_bytes(s.try_into().ok()?) })
}
fn rd_f64(b: &[u8], o: &mut usize, le: bool) -> Option<f64> {
    let s = b.get(*o..*o + 8)?;
    *o += 8;
    Some(if le { f64::from_le_bytes(s.try_into().ok()?) } else { f64::from_be_bytes(s.try_into().ok()?) })
}

fn dims(t: u32) -> (u32, usize) {
    // returns (base type, ordinates per point)
    let mut ord = 2;
    let mut base = t & 0x0FFF_FFFF;
    if t & 0x8000_0000 != 0 {
        ord += 1; // EWKB Z
    }
    if t & 0x4000_0000 != 0 {
        ord += 1; // EWKB M
    }
    if base >= 3000 {
        ord = 4;
        base -= 3000;
    } else if base >= 2000 {
        ord = 3;
        base -= 2000;
    } else if base >= 1000 {
        ord = 3;
        base -= 1000;
    }
    (base, ord)
}

fn line(b: &[u8], o: &mut usize, le: bool, ord: usize) -> Option<Vec<(f64, f64)>> {
    let n = rd_u32(b, o, le)? as usize;
    let mut pts = Vec::with_capacity(n);
    for _ in 0..n {
        let x = rd_f64(b, o, le)?;
        let y = rd_f64(b, o, le)?;
        for _ in 2..ord {
            rd_f64(b, o, le)?;
        }
        pts.push((x, y));
    }
    Some(pts)
}

pub fn parse_lines(b: &[u8]) -> Option<Vec<Vec<(f64, f64)>>> {
    let mut o = 0usize;
    let le = *b.get(o)? == 1;
    o += 1;
    let t = rd_u32(b, &mut o, le)?;
    let (base, ord) = dims(t);
    match base {
        2 => Some(vec![line(b, &mut o, le, ord)?]),
        5 => {
            let n = rd_u32(b, &mut o, le)? as usize;
            let mut parts = Vec::new();
            for _ in 0..n {
                let le2 = *b.get(o)? == 1;
                o += 1;
                let t2 = rd_u32(b, &mut o, le2)?;
                let (b2, ord2) = dims(t2);
                if b2 != 2 {
                    return None;
                }
                parts.push(line(b, &mut o, le2, ord2)?);
            }
            Some(parts)
        }
        _ => None,
    }
}
