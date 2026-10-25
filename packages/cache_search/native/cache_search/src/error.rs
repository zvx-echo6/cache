//! Error type carrying the header's stable error codes.

use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    BadJson,
    NotFound,
    IndexMissing,
    IndexStale,
    Busy,
    Unsupported,
    Io,
    Cancelled,
    Internal,
}

impl ErrorCode {
    /// The stable string used in `cs_last_error` and job errors.
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::BadJson => "bad_json",
            ErrorCode::NotFound => "not_found",
            ErrorCode::IndexMissing => "index_missing",
            ErrorCode::IndexStale => "index_stale",
            ErrorCode::Busy => "busy",
            ErrorCode::Unsupported => "unsupported",
            ErrorCode::Io => "io",
            ErrorCode::Cancelled => "cancelled",
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
    pub fn not_found(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::NotFound, m)
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

    /// `{"code","message"}`, the shape returned by `cs_last_error`.
    pub fn to_json(&self) -> String {
        json!({"code": self.code.as_str(), "message": self.message}).to_string()
    }
}

impl From<zim::Error> for Error {
    fn from(e: zim::Error) -> Self {
        use zim::Error as Z;
        let code = match e {
            Z::UnknownCompression(_)
            | Z::UnsupportedCompression(_)
            | Z::InvalidMagicNumber
            | Z::InvalidVersion(_)
            | Z::InvalidHeader(_)
            | Z::InvalidClusterExtension => ErrorCode::Unsupported,
            _ => ErrorCode::Io,
        };
        Error::new(code, e.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::bad_json(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_stable() {
        let all = [
            (ErrorCode::BadJson, "bad_json"),
            (ErrorCode::NotFound, "not_found"),
            (ErrorCode::IndexMissing, "index_missing"),
            (ErrorCode::IndexStale, "index_stale"),
            (ErrorCode::Busy, "busy"),
            (ErrorCode::Unsupported, "unsupported"),
            (ErrorCode::Io, "io"),
            (ErrorCode::Cancelled, "cancelled"),
            (ErrorCode::Internal, "internal"),
        ];
        for (c, s) in all {
            assert_eq!(c.as_str(), s);
        }
    }

    #[test]
    fn error_json_shape() {
        let e = Error::not_found("no such \"entry\"\n");
        let v: serde_json::Value = serde_json::from_str(&e.to_json()).unwrap();
        assert_eq!(v["code"], "not_found");
        assert_eq!(v["message"], "no such \"entry\"\n");
        assert_eq!(v.as_object().unwrap().len(), 2);
    }

    #[test]
    fn serde_error_is_bad_json() {
        let e: Error = serde_json::from_str::<serde_json::Value>("{").unwrap_err().into();
        assert_eq!(e.code, ErrorCode::BadJson);
    }
}
