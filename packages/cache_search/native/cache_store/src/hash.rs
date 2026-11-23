// The BLAKE3 hash type. Its text and binary forms are those of iroh-blobs' `Hash` (iroh-blobs 0.103.1, src/hash.rs,
// Copyright n0, Inc., MIT OR Apache-2.0), so ids already stored in sync.json and index files, and ids sent in sync messages,
// read the same on either side. No iroh code is used; the forms are re-implemented and cross-checked in tests/crosscheck.rs.

use std::{cmp::Ordering, fmt, str::FromStr};

use serde::{de, Deserialize, Deserializer, Serialize, Serializer};

/// A BLAKE3 hash: the id of a file's content.
#[derive(PartialEq, Eq, Copy, Clone, Hash)]
pub struct Hash([u8; 32]);

impl Hash {
    /// The hash of the empty byte range.
    pub const EMPTY: Hash = Hash([
        175, 19, 73, 185, 245, 249, 161, 166, 160, 64, 77, 234, 54, 220, 201, 73, 155, 203, 37, 201, 173, 193, 18, 183, 204, 154, 147, 202, 228,
        31, 50, 98,
    ]);

    /// The hash of `buf`.
    pub fn new(buf: impl AsRef<[u8]>) -> Self {
        Hash(*blake3::hash(buf.as_ref()).as_bytes())
    }

    /// The raw bytes.
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// From raw bytes.
    pub const fn from_bytes(bytes: [u8; 32]) -> Self {
        Hash(bytes)
    }

    /// Lower-case hex, 64 characters.
    pub fn to_hex(&self) -> String {
        data_encoding::HEXLOWER.encode(&self.0)
    }

    /// The first five bytes in hex, for log lines.
    pub fn fmt_short(&self) -> String {
        data_encoding::HEXLOWER.encode(&self.0[..5])
    }
}

impl fmt::Debug for Hash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Hash({})", self.to_hex())
    }
}

impl fmt::Display for Hash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_hex())
    }
}

impl PartialOrd for Hash {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Hash {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.cmp(&other.0)
    }
}

impl AsRef<[u8]> for Hash {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

impl From<blake3::Hash> for Hash {
    fn from(h: blake3::Hash) -> Self {
        Hash(*h.as_bytes())
    }
}

impl From<Hash> for blake3::Hash {
    fn from(h: Hash) -> Self {
        blake3::Hash::from_bytes(h.0)
    }
}

impl From<[u8; 32]> for Hash {
    fn from(b: [u8; 32]) -> Self {
        Hash(b)
    }
}

impl From<&[u8; 32]> for Hash {
    fn from(b: &[u8; 32]) -> Self {
        Hash(*b)
    }
}

impl From<Hash> for [u8; 32] {
    fn from(h: Hash) -> Self {
        h.0
    }
}

/// A string that is not a hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseHashError(String);

impl fmt::Display for ParseHashError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "not a hash: {}", self.0)
    }
}

impl std::error::Error for ParseHashError {}

impl FromStr for Hash {
    type Err = ParseHashError;

    /// 64 hex characters, or (as iroh-blobs accepts) 52 base32 characters.
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let mut bytes = [0u8; 32];
        let hex = s.len() == 64;
        let enc = if hex { &data_encoding::HEXLOWER } else { &data_encoding::BASE32_NOPAD };
        // iroh-blobs decodes into the 32 bytes without this check and panics on a string of any other length.
        if enc.decode_len(s.len()).ok() != Some(32) {
            return Err(ParseHashError("invalid length".into()));
        }
        let res = if hex { enc.decode_mut(s.as_bytes(), &mut bytes) } else { enc.decode_mut(s.to_ascii_uppercase().as_bytes(), &mut bytes) };
        match res {
            Ok(32) => Ok(Hash(bytes)),
            Ok(_) => Err(ParseHashError("invalid length".into())),
            Err(partial) => Err(ParseHashError(partial.error.to_string())),
        }
    }
}

impl Serialize for Hash {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        if serializer.is_human_readable() {
            serializer.serialize_str(&self.to_hex())
        } else {
            self.0.serialize(serializer)
        }
    }
}

impl<'de> Deserialize<'de> for Hash {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        if deserializer.is_human_readable() {
            let s = String::deserialize(deserializer)?;
            s.parse().map_err(de::Error::custom)
        } else {
            let data: [u8; 32] = Deserialize::deserialize(deserializer)?;
            Ok(Hash(data))
        }
    }
}
