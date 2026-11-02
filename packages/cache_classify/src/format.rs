//! The model file: reading and writing. See the crate README for the byte layout.

use crate::Model;
use std::fmt;

/// First four bytes of every model file.
pub const MAGIC: [u8; 4] = *b"CCLS";
/// The only layout this crate reads. A change to the layout bumps it.
pub const FORMAT_VERSION: u16 = 1;
/// Recipe id 1: mean of the selected piece vectors, then L2 normalisation.
pub const RECIPE_MEAN_L2: u8 = 1;

const FLAG_F16: u16 = 1;
const MAX_DIMS: u32 = 65_536;
const MAX_CLASSES: u32 = 4096;

/// One division the model can name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Class {
    /// The division number, e.g. 310.
    pub division: u16,
    pub label: String,
}

/// The book-vector recipe: which piece vectors are averaged.
///
/// The builder keeps the first `first_pieces` text pieces of a book and, if more remain, `spread_pieces` of the rest
/// spread evenly; the book vector is the mean of those piece vectors, L2-normalised ([`crate::book_vector`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Recipe {
    pub first_pieces: u16,
    pub spread_pieces: u16,
}

impl Recipe {
    /// The most piece vectors the recipe uses.
    pub fn max_pieces(&self) -> usize {
        self.first_pieces as usize + self.spread_pieces as usize
    }

    /// Which of `count` pieces (already filtered to real text, in reading order) the recipe uses, as 0-based indices in
    /// ascending order: the first `first_pieces`, then, if more than `spread_pieces` remain, `spread_pieces` of them evenly
    /// spaced (first and last of the rest included), else all that remain.
    pub fn select_indices(&self, count: usize) -> Vec<usize> {
        let first = (self.first_pieces as usize).min(count);
        let mut out: Vec<usize> = (0..first).collect();
        let rest = count - first;
        let spread = self.spread_pieces as usize;
        if rest <= spread {
            out.extend(first..count);
        } else if spread == 1 {
            out.push(first);
        } else if spread > 1 {
            let step = (rest - 1) as f64 / (spread - 1) as f64;
            for i in 0..spread {
                out.push(first + (i as f64 * step).round() as usize);
            }
        }
        out
    }
}

/// Weights as stored in a file.
#[derive(Debug, Clone, PartialEq)]
pub enum Weights {
    /// Row-major `[dims][classes]`.
    F32(Vec<f32>),
    /// Row-major `[dims][classes]`, IEEE half-precision bit patterns.
    F16(Vec<u16>),
}

/// Everything in a model file, for [`encode`].
#[derive(Debug, Clone, PartialEq)]
pub struct ModelSpec {
    pub classifier_version: u32,
    pub embedding_sha256: [u8; 32],
    pub dims: u32,
    pub threshold: f64,
    pub recipe: Recipe,
    pub classes: Vec<Class>,
    pub bias: Vec<f32>,
    pub weights: Weights,
}

/// Why a model file was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError {
    TooShort,
    BadMagic,
    BadChecksum,
    UnsupportedFormat(u16),
    UnsupportedRecipe(u8),
    Corrupt(&'static str),
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LoadError::TooShort => write!(f, "classifier model file is too short"),
            LoadError::BadMagic => write!(f, "not a classifier model file"),
            LoadError::BadChecksum => write!(f, "classifier model file is damaged (checksum mismatch)"),
            LoadError::UnsupportedFormat(v) => write!(f, "classifier model file format {v} is not supported"),
            LoadError::UnsupportedRecipe(r) => write!(f, "classifier model book-vector recipe {r} is not supported"),
            LoadError::Corrupt(why) => write!(f, "classifier model file is corrupt: {why}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// CRC-32 (IEEE, as zlib), the file's trailing checksum.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

/// Widen an IEEE half-precision bit pattern to f32 (exact).
pub fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h as u32) & 0x8000) << 16;
    let exp = ((h >> 10) & 0x1f) as u32;
    let man = (h & 0x3ff) as u32;
    let bits = if exp == 0 {
        if man == 0 {
            sign
        } else {
            // Subnormal: normalise the mantissa.
            let mut e = 127 - 15 + 1;
            let mut m = man;
            while m & 0x400 == 0 {
                m <<= 1;
                e -= 1;
            }
            sign | (e << 23) | ((m & 0x3ff) << 13)
        }
    } else if exp == 31 {
        sign | 0x7f80_0000 | (man << 13)
    } else {
        sign | ((exp + 127 - 15) << 23) | (man << 13)
    };
    f32::from_bits(bits)
}

/// A division number as the three-digit code the library uses ("010", "310").
pub fn division_code(division: u16) -> String {
    format!("{division:03}")
}

/// Write a model file. The crate itself needs this for tests and tools; `spec` is assumed consistent
/// (`bias.len() == classes.len()`, weights `dims * classes.len()` long).
pub fn encode(spec: &ModelSpec) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    let flags = if matches!(spec.weights, Weights::F16(_)) { FLAG_F16 } else { 0 };
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(&spec.classifier_version.to_le_bytes());
    out.extend_from_slice(&spec.dims.to_le_bytes());
    out.extend_from_slice(&(spec.classes.len() as u32).to_le_bytes());
    out.extend_from_slice(&spec.embedding_sha256);
    out.extend_from_slice(&spec.threshold.to_le_bytes());
    out.push(RECIPE_MEAN_L2);
    out.push(0);
    out.extend_from_slice(&spec.recipe.first_pieces.to_le_bytes());
    out.extend_from_slice(&spec.recipe.spread_pieces.to_le_bytes());
    for c in &spec.classes {
        out.extend_from_slice(&c.division.to_le_bytes());
        let label = c.label.as_bytes();
        let n = label.len().min(255);
        out.push(n as u8);
        out.extend_from_slice(&label[..n]);
    }
    for b in &spec.bias {
        out.extend_from_slice(&b.to_le_bytes());
    }
    match &spec.weights {
        Weights::F32(w) => w.iter().for_each(|x| out.extend_from_slice(&x.to_le_bytes())),
        Weights::F16(w) => w.iter().for_each(|x| out.extend_from_slice(&x.to_le_bytes())),
    }
    let crc = crc32(&out);
    out.extend_from_slice(&crc.to_le_bytes());
    out
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], LoadError> {
        let end = self.pos.checked_add(n).ok_or(LoadError::TooShort)?;
        if end > self.bytes.len() {
            return Err(LoadError::TooShort);
        }
        let s = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8, LoadError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, LoadError> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }
    fn u32(&mut self) -> Result<u32, LoadError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    fn f64(&mut self) -> Result<f64, LoadError> {
        let b = self.take(8)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(b);
        Ok(f64::from_le_bytes(a))
    }
}

pub(crate) fn decode(bytes: &[u8]) -> Result<Model, LoadError> {
    if bytes.len() < 8 {
        return Err(LoadError::TooShort);
    }
    if bytes[..4] != MAGIC {
        return Err(LoadError::BadMagic);
    }
    let format = u16::from_le_bytes([bytes[4], bytes[5]]);
    if format != FORMAT_VERSION {
        return Err(LoadError::UnsupportedFormat(format));
    }
    if bytes.len() < 12 {
        return Err(LoadError::TooShort);
    }
    let (body, tail) = bytes.split_at(bytes.len() - 4);
    let want = u32::from_le_bytes([tail[0], tail[1], tail[2], tail[3]]);
    if crc32(body) != want {
        return Err(LoadError::BadChecksum);
    }

    let mut r = Reader { bytes: body, pos: 6 };
    let flags = r.u16()?;
    if flags & !FLAG_F16 != 0 {
        return Err(LoadError::Corrupt("unknown flags"));
    }
    let weights_f16 = flags & FLAG_F16 != 0;
    let classifier_version = r.u32()?;
    let dims = r.u32()?;
    let n = r.u32()?;
    if dims == 0 || dims > MAX_DIMS {
        return Err(LoadError::Corrupt("bad dims"));
    }
    if n == 0 || n > MAX_CLASSES {
        return Err(LoadError::Corrupt("bad class count"));
    }
    let mut embedding_sha256 = [0u8; 32];
    embedding_sha256.copy_from_slice(r.take(32)?);
    let threshold = r.f64()?;
    if !(0.0..=1.0).contains(&threshold) {
        return Err(LoadError::Corrupt("threshold outside 0..1"));
    }
    let recipe_id = r.u8()?;
    if recipe_id != RECIPE_MEAN_L2 {
        return Err(LoadError::UnsupportedRecipe(recipe_id));
    }
    r.u8()?;
    let recipe = Recipe { first_pieces: r.u16()?, spread_pieces: r.u16()? };

    let n = n as usize;
    let dims = dims as usize;
    let mut classes = Vec::with_capacity(n);
    for _ in 0..n {
        let division = r.u16()?;
        let len = r.u8()? as usize;
        let label = std::str::from_utf8(r.take(len)?).map_err(|_| LoadError::Corrupt("label is not UTF-8"))?;
        classes.push(Class { division, label: label.to_string() });
    }
    let wsize: u64 = if weights_f16 { 2 } else { 4 };
    let need = n as u64 * 4 + dims as u64 * n as u64 * wsize;
    if (body.len() - r.pos) as u64 != need {
        return Err(LoadError::Corrupt("weight block has the wrong size"));
    }
    let mut bias = Vec::with_capacity(n);
    for _ in 0..n {
        let b = r.take(4)?;
        bias.push(f32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    }
    let raw = r.take(dims * n * wsize as usize)?;
    let weights: Vec<f32> = if weights_f16 {
        raw.as_chunks::<2>().0.iter().map(|c| f16_to_f32(u16::from_le_bytes(*c))).collect()
    } else {
        raw.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect()
    };
    if bias.iter().chain(weights.iter()).any(|x| x.is_nan() || x.is_infinite()) {
        return Err(LoadError::Corrupt("non-finite weight"));
    }
    Ok(Model { classifier_version, embedding_sha256, dims, threshold, recipe, weights_f16, classes, bias, weights })
}
