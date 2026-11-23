use std::{fmt, io};

/// What can go wrong in the store.
#[derive(Debug)]
pub enum Error {
    /// A file operation failed.
    Io(io::Error),
    /// The index failed.
    Db(rusqlite::Error),
    /// Data did not match its hash.
    Verify(String),
    /// The store has no complete copy of this hash (or, for ranges, not the ranges asked for).
    Missing(String),
    /// A file being imported changed while it was read.
    FileChanged(String),
    /// A bad argument or an index that makes no sense.
    Invalid(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io(e) => write!(f, "file error: {e}"),
            Error::Db(e) => write!(f, "index error: {e}"),
            Error::Verify(m) => write!(f, "the data did not verify: {m}"),
            Error::Missing(m) => write!(f, "not in the store: {m}"),
            Error::FileChanged(m) => write!(f, "the file changed while it was read: {m}"),
            Error::Invalid(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(e) => Some(e),
            Error::Db(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error::Io(e)
    }
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::Db(e)
    }
}

impl Error {
    /// True when a write failed because the disk is full.
    pub fn is_no_space(&self) -> bool {
        matches!(self, Error::Io(e) if e.kind() == io::ErrorKind::StorageFull)
    }
}
