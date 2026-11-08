//! A minimal PNG writer for 8-bit grayscale pages (zlib from flate2, CRC32 by table). Used by the PDF engines to hand a page image
//! to an OCR engine.

use std::io::Write;

fn crc32(chunk_type: &[u8], data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (n, t) in table.iter_mut().enumerate() {
        let mut c = n as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
        }
        *t = c;
    }
    let mut c = 0xFFFF_FFFFu32;
    for b in chunk_type.iter().chain(data.iter()) {
        c = table[((c ^ *b as u32) & 0xFF) as usize] ^ (c >> 8);
    }
    c ^ 0xFFFF_FFFF
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&crc32(kind, data).to_be_bytes());
}

/// Encodes `pixels` (`width * height` gray bytes, row by row, `stride` bytes per row) as a grayscale PNG.
pub fn encode_gray(width: u32, height: u32, stride: usize, pixels: &[u8]) -> Result<Vec<u8>, String> {
    if width == 0 || height == 0 || stride < width as usize || pixels.len() < stride * (height as usize - 1) + width as usize {
        return Err("the page image has the wrong size".to_string());
    }
    let mut raw = Vec::with_capacity((width as usize + 1) * height as usize);
    for y in 0..height as usize {
        raw.push(0u8); // filter: none
        raw.extend_from_slice(&pixels[y * stride..y * stride + width as usize]);
    }
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::new(6));
    z.write_all(&raw).map_err(|e| e.to_string())?;
    let idat = z.finish().map_err(|e| e.to_string())?;
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 0, 0, 0, 0]); // 8 bits, gray, deflate, adaptive filter, no interlace
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &idat);
    chunk(&mut out, b"IEND", &[]);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_png_has_the_signature_the_size_and_a_valid_crc() {
        let png = encode_gray(2, 2, 2, &[0, 255, 255, 0]).unwrap();
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        assert_eq!(&png[12..16], b"IHDR");
        assert_eq!(u32::from_be_bytes(png[16..20].try_into().unwrap()), 2);
        // the CRC of IHDR (type and 13 data bytes)
        assert_eq!(u32::from_be_bytes(png[29..33].try_into().unwrap()), crc32(b"IHDR", &png[16..29]));
        assert!(encode_gray(0, 2, 2, &[]).is_err());
        assert!(encode_gray(2, 2, 2, &[0, 1, 2]).is_err());
    }
}
