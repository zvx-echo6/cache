//! BLAKE2b with an 8-byte digest and no key: the title key the build script hashes with Python's
//! `hashlib.blake2b(data, digest_size=8)`.
#![allow(clippy::needless_range_loop)]

const IV: [u64; 8] = [
    0x6a09_e667_f3bc_c908,
    0xbb67_ae85_84ca_a73b,
    0x3c6e_f372_fe94_f82b,
    0xa54f_f53a_5f1d_36f1,
    0x510e_527f_ade6_82d1,
    0x9b05_688c_2b3e_6c1f,
    0x1f83_d9ab_fb41_bd6b,
    0x5be0_cd19_137e_2179,
];

const SIGMA: [[usize; 16]; 10] = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 0, 13],
];

fn g(v: &mut [u64; 16], a: usize, b: usize, c: usize, d: usize, x: u64, y: u64) {
    v[a] = v[a].wrapping_add(v[b]).wrapping_add(x);
    v[d] = (v[d] ^ v[a]).rotate_right(32);
    v[c] = v[c].wrapping_add(v[d]);
    v[b] = (v[b] ^ v[c]).rotate_right(24);
    v[a] = v[a].wrapping_add(v[b]).wrapping_add(y);
    v[d] = (v[d] ^ v[a]).rotate_right(16);
    v[c] = v[c].wrapping_add(v[d]);
    v[b] = (v[b] ^ v[c]).rotate_right(63);
}

fn compress(h: &mut [u64; 8], block: &[u8], counter: u64, last: bool) {
    let mut m = [0u64; 16];
    for (i, word) in m.iter_mut().enumerate() {
        let mut w = [0u8; 8];
        w.copy_from_slice(&block[i * 8..i * 8 + 8]);
        *word = u64::from_le_bytes(w);
    }
    let mut v = [0u64; 16];
    v[..8].copy_from_slice(h);
    v[8..].copy_from_slice(&IV);
    v[12] ^= counter;
    if last {
        v[14] = !v[14];
    }
    for round in 0..12 {
        let s = &SIGMA[round % 10];
        g(&mut v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
        g(&mut v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
        g(&mut v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
        g(&mut v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
        g(&mut v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
        g(&mut v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
        g(&mut v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
        g(&mut v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
    }
    for i in 0..8 {
        h[i] ^= v[i] ^ v[i + 8];
    }
}

/// The 8-byte digest as Python's `int.from_bytes(digest, "big")` reads it.
pub fn blake2b_64(data: &[u8]) -> u64 {
    let mut h = IV;
    h[0] ^= 0x0101_0000 ^ 8;
    if data.is_empty() {
        compress(&mut h, &[0u8; 128], 0, true);
    } else {
        let n = data.len().div_ceil(128);
        for (i, chunk) in data.chunks(128).enumerate() {
            let mut block = [0u8; 128];
            block[..chunk.len()].copy_from_slice(chunk);
            let counter = (i * 128 + chunk.len()) as u64;
            compress(&mut h, &block, counter, i + 1 == n);
        }
    }
    // The digest bytes are h[0] in little-endian order; Python reads them big-endian.
    h[0].swap_bytes()
}

#[cfg(test)]
mod tests {
    use super::blake2b_64;

    #[test]
    fn matches_python_hashlib() {
        // hashlib.blake2b(data, digest_size=8).hexdigest()
        assert_eq!(blake2b_64(b"abc"), 0xd8bb_14d8_33d5_9559);
        assert_eq!(blake2b_64(b""), 0xe4a6_a057_7479_b2b4);
        assert_eq!(blake2b_64(&[b'a'; 200]), 0xb40a_f6d2_f2f3_4472);
    }
}
