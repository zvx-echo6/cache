//! The builder's error type: a message, nothing more. Every failure is reported to the caller as text (a bad PDF never
//! panics, so one bad file never stops a batch).

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub String);

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(msg: impl Into<String>) -> Self {
        Error(msg.into())
    }
    pub fn ctx(what: &str, e: impl fmt::Display) -> Self {
        Error(format!("{what}: {e}"))
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}
