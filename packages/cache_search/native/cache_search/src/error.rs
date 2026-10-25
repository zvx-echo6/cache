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
    NoSpace,
    Damaged,
    NotConfigured,
    FetchFailed,
    Quota,
    KeyMissing,
    BadResponse,
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
            ErrorCode::NoSpace => "no_space",
            ErrorCode::Damaged => "damaged",
            ErrorCode::NotConfigured => "not_configured",
            ErrorCode::FetchFailed => "fetch_failed",
            ErrorCode::Quota => "quota",
            ErrorCode::KeyMissing => "key_missing",
            ErrorCode::BadResponse => "bad_response",
            ErrorCode::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, thiserror::Error)]
#[error("{}: {message}", .code.as_str())]
pub struct Error {
    pub code: ErrorCode,
    pub message: String,
    /// `(needed, available)` in bytes, set only for `no_space`; it becomes the numeric `needed` and `available`
    /// fields of the error JSON.
    pub space: Option<(u64, u64)>,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Error { code, message: message.into(), space: None }
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
    /// A library's files are incomplete (the manifest lists segments that are missing). Nothing was changed.
    pub fn damaged(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Damaged, m)
    }
    pub fn internal(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, m)
    }
    /// Not enough free space: `needed` and `available` are bytes, and are also numeric fields of the error JSON.
    pub fn no_space(message: impl Into<String>, needed: u64, available: u64) -> Self {
        Error { code: ErrorCode::NoSpace, message: message.into(), space: Some((needed, available)) }
    }

    /// `{"code","message"}`, the shape returned by `cs_last_error` and in job errors; `no_space` adds the numbers
    /// `"needed"` and `"available"`.
    pub fn to_value(&self) -> serde_json::Value {
        let mut v = json!({"code": self.code.as_str(), "message": self.message});
        if let Some((needed, available)) = self.space {
            v["needed"] = json!(needed);
            v["available"] = json!(available);
        }
        v
    }

    /// [`Error::to_value`] as text.
    pub fn to_json(&self) -> String {
        self.to_value().to_string()
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

impl ErrorCode {
    /// The code for a stable code string from `cache_live` or `cache_user`; anything unknown is `internal`.
    pub fn from_str_code(s: &str) -> ErrorCode {
        match s {
            "bad_json" => ErrorCode::BadJson,
            "not_found" => ErrorCode::NotFound,
            "io" => ErrorCode::Io,
            "not_configured" => ErrorCode::NotConfigured,
            "fetch_failed" => ErrorCode::FetchFailed,
            "quota" => ErrorCode::Quota,
            "key_missing" => ErrorCode::KeyMissing,
            "bad_response" => ErrorCode::BadResponse,
            _ => ErrorCode::Internal,
        }
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
            (ErrorCode::NoSpace, "no_space"),
            (ErrorCode::Damaged, "damaged"),
            (ErrorCode::NotConfigured, "not_configured"),
            (ErrorCode::FetchFailed, "fetch_failed"),
            (ErrorCode::Quota, "quota"),
            (ErrorCode::KeyMissing, "key_missing"),
            (ErrorCode::BadResponse, "bad_response"),
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
    fn no_space_json_carries_the_numbers() {
        let v = Error::no_space("short", 10, 4).to_value();
        assert_eq!(v, json!({"code":"no_space","message":"short","needed":10,"available":4}));
    }

    #[test]
    fn serde_error_is_bad_json() {
        let e: Error = serde_json::from_str::<serde_json::Value>("{").unwrap_err().into();
        assert_eq!(e.code, ErrorCode::BadJson);
    }
}
