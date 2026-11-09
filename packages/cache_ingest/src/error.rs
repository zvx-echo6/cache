//! The job's error type: the stable codes of INGEST-API.md and a message.

use std::fmt;

/// The error codes of the ingest calls (the `code` of `cs_last_error` and of a `failed` status).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Code {
    BadJson,
    Io,
    NotFound,
    Busy,
    Cancelled,
    NotPdf,
    /// Password-protected.
    Locked,
    Damaged,
    NoSpace,
    /// The embedder failed.
    Embed,
    /// No page of the book has any text (OCR off, or every OCR'd page empty).
    NoText,
}

impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Code::BadJson => "bad_json",
            Code::Io => "io",
            Code::NotFound => "not_found",
            Code::Busy => "busy",
            Code::Cancelled => "cancelled",
            Code::NotPdf => "not_pdf",
            Code::Locked => "locked",
            Code::Damaged => "damaged",
            Code::NoSpace => "no_space",
            Code::Embed => "embed",
            Code::NoText => "no_text",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Error {
    pub code: Code,
    pub message: String,
    /// `(needed, available)` in bytes, for `no_space`.
    pub space: Option<(u64, u64)>,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: Code, message: impl Into<String>) -> Error {
        Error { code, message: message.into(), space: None }
    }
    pub fn bad_json(m: impl Into<String>) -> Error {
        Error::new(Code::BadJson, m)
    }
    pub fn io(what: &str, e: impl fmt::Display) -> Error {
        Error::new(Code::Io, format!("{what}: {e}"))
    }
    pub fn busy(m: impl Into<String>) -> Error {
        Error::new(Code::Busy, m)
    }
    pub fn not_found(m: impl Into<String>) -> Error {
        Error::new(Code::NotFound, m)
    }
    pub fn no_space(m: impl Into<String>, needed: u64, available: u64) -> Error {
        Error { code: Code::NoSpace, message: m.into(), space: Some((needed, available)) }
    }
    /// `{"code","message"}` (plus `needed` and `available` for `no_space`).
    pub fn to_value(&self) -> serde_json::Value {
        let mut v = serde_json::json!({"code": self.code.as_str(), "message": self.message});
        if let Some((n, a)) = self.space {
            v["needed"] = serde_json::json!(n);
            v["available"] = serde_json::json!(a);
        }
        v
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for Error {}

impl From<cache_pack::Error> for Error {
    fn from(e: cache_pack::Error) -> Error {
        Error::new(Code::Io, e.0)
    }
}
