//! The small error type of the snapshot core. `cache_search` converts it to its own `Error` with the same code.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    BadJson,
    Unsupported,
    Io,
    Internal,
}

impl ErrorCode {
    /// The stable string (the same one `cache_search`'s error code of that name has).
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::BadJson => "bad_json",
            ErrorCode::Unsupported => "unsupported",
            ErrorCode::Io => "io",
            ErrorCode::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, thiserror::Error)]
#[error("{}: {message}", .code.as_str())]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Error { code, message: message.into() }
    }
    pub fn bad_json(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadJson, m)
    }
    pub fn unsupported(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Unsupported, m)
    }
    pub fn io(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Io, m)
    }
    pub fn internal(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, m)
    }
}
