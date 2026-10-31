//! Sign-in: one user, a password and no username.
//!
//! The password is kept as PBKDF2-HMAC-SHA256 (600000 iterations, a random 16-byte salt, a 32-byte hash) in `auth.json`.
//! A sign-in gives a random session token in a cookie; only the SHA-256 of the token is stored, in `sessions.json`, so a
//! restart or a reboot does not sign anyone out and a copy of the file is no use to someone who wants a session.

use crate::write_private;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ring::rand::{SecureRandom, SystemRandom};
use ring::{digest, pbkdf2};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;

pub const ITERATIONS: u32 = 600_000;
pub const SESSION_SECS: u64 = 30 * 24 * 3600;
/// The longest a wrong password is made to wait, in seconds.
pub const MAX_DELAY_SECS: u64 = 30;
pub const COOKIE_NAME: &str = "cache_session";

/// Seconds since the Unix epoch.
pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut b = [0u8; N];
    SystemRandom::new().fill(&mut b).map_err(|_| io::Error::other("no random bytes available"))?;
    Ok(b)
}

/// What `auth.json` holds.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredPassword {
    pub algorithm: String,
    pub iterations: u32,
    pub salt: String,
    pub hash: String,
}

fn derive(password: &str, salt: &[u8], iterations: u32) -> Option<[u8; 32]> {
    let n = NonZeroU32::new(iterations)?;
    let mut out = [0u8; 32];
    pbkdf2::derive(pbkdf2::PBKDF2_HMAC_SHA256, n, salt, password.as_bytes(), &mut out);
    Some(out)
}

impl StoredPassword {
    /// Hash `password` with a fresh salt. An empty password is refused.
    pub fn new(password: &str) -> io::Result<StoredPassword> {
        Self::with_iterations(password, ITERATIONS)
    }

    fn with_iterations(password: &str, iterations: u32) -> io::Result<StoredPassword> {
        if password.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "the password is empty"));
        }
        let salt = random_bytes::<16>()?;
        let hash = derive(password, &salt, iterations).ok_or_else(|| io::Error::other("bad iteration count"))?;
        Ok(StoredPassword { algorithm: "pbkdf2-hmac-sha256".into(), iterations, salt: STANDARD.encode(salt), hash: STANDARD.encode(hash) })
    }

    /// True when `password` is the stored one. The hashes are compared in constant time.
    pub fn verify(&self, password: &str) -> bool {
        if self.algorithm != "pbkdf2-hmac-sha256" {
            return false;
        }
        let (Ok(salt), Ok(want)) = (STANDARD.decode(&self.salt), STANDARD.decode(&self.hash)) else { return false };
        let Some(got) = derive(password, &salt, self.iterations) else { return false };
        got.ct_eq(&want[..]).into()
    }

    pub fn load(path: &Path) -> io::Result<Option<StoredPassword>> {
        match std::fs::read_to_string(path) {
            Ok(t) => serde_json::from_str(&t).map(Some).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{}: {e}", path.display()))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        write_private(path, serde_json::to_string_pretty(self).map_err(io::Error::other)?.as_bytes())
    }
}

/// The signed-in sessions, kept in `sessions.json` as `{"sessions": {"<sha256 of token>": <expiry>}}`.
pub struct Sessions {
    path: PathBuf,
    entries: HashMap<String, u64>,
}

#[derive(Serialize, Deserialize, Default)]
struct SessionsFile {
    sessions: HashMap<String, u64>,
}

fn token_hash(token: &str) -> String {
    STANDARD.encode(digest::digest(&digest::SHA256, token.as_bytes()))
}

impl Sessions {
    /// Read the file; a missing or unreadable one means no sessions (everyone signs in again).
    pub fn load(path: &Path) -> Sessions {
        let entries = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str::<SessionsFile>(&t).ok()).unwrap_or_default().sessions;
        Sessions { path: path.to_path_buf(), entries }
    }

    fn save(&self) -> io::Result<()> {
        let f = SessionsFile { sessions: self.entries.clone() };
        write_private(&self.path, serde_json::to_string(&f).map_err(io::Error::other)?.as_bytes())
    }

    /// Start a session at time `now`; returns the token for the cookie.
    pub fn create(&mut self, now: u64) -> io::Result<String> {
        let token = URL_SAFE_NO_PAD.encode(random_bytes::<32>()?);
        self.entries.retain(|_, exp| *exp > now);
        self.entries.insert(token_hash(&token), now + SESSION_SECS);
        self.save()?;
        Ok(token)
    }

    pub fn is_valid(&self, token: &str, now: u64) -> bool {
        self.entries.get(&token_hash(token)).is_some_and(|exp| *exp > now)
    }

    pub fn remove(&mut self, token: &str) -> io::Result<()> {
        if self.entries.remove(&token_hash(token)).is_some() {
            self.save()?;
        }
        Ok(())
    }
}

/// How long to hold the answer to the `n`th failure in a row: nothing for the first, then 2, 4, 8, 16 and 30 seconds.
pub fn delay_for(n: u32) -> Duration {
    if n < 2 {
        return Duration::ZERO;
    }
    let secs = if n - 1 >= 5 { MAX_DELAY_SECS } else { (1u64 << (n - 1)).min(MAX_DELAY_SECS) };
    Duration::from_secs(secs)
}

/// The sign-in state of the server.
pub struct Auth {
    password: Option<StoredPassword>,
    sessions: Mutex<Sessions>,
    failures: Mutex<u32>,
    /// Whether the cookie is marked Secure (everything but `--no-tls`).
    pub secure_cookie: bool,
}

impl Auth {
    pub fn load(data: &Path, secure_cookie: bool) -> io::Result<Auth> {
        let password = StoredPassword::load(&data.join("auth.json"))?;
        Ok(Auth::new(password, Sessions::load(&data.join("sessions.json")), secure_cookie))
    }

    pub fn new(password: Option<StoredPassword>, sessions: Sessions, secure_cookie: bool) -> Auth {
        Auth { password, sessions: Mutex::new(sessions), failures: Mutex::new(0), secure_cookie }
    }

    pub fn has_password(&self) -> bool {
        self.password.is_some()
    }

    /// Check a password (this takes a fraction of a second: call it from a blocking thread). `Some(token)` on success.
    pub fn login(&self, password: &str) -> io::Result<Option<String>> {
        if !self.password.as_ref().is_some_and(|p| p.verify(password)) {
            return Ok(None);
        }
        *self.failures.lock().unwrap_or_else(|e| e.into_inner()) = 0;
        self.sessions.lock().unwrap_or_else(|e| e.into_inner()).create(now()).map(Some)
    }

    /// Count a failed sign-in (all callers share one count) and say how long to hold the 401.
    pub fn record_failure(&self) -> Duration {
        let mut n = self.failures.lock().unwrap_or_else(|e| e.into_inner());
        *n = n.saturating_add(1);
        delay_for(*n)
    }

    pub fn is_signed_in(&self, token: &str) -> bool {
        self.sessions.lock().unwrap_or_else(|e| e.into_inner()).is_valid(token, now())
    }

    pub fn logout(&self, token: &str) -> io::Result<()> {
        self.sessions.lock().unwrap_or_else(|e| e.into_inner()).remove(token)
    }

    /// The `Set-Cookie` value that carries `token` (an empty token with `max_age` 0 clears it).
    pub fn cookie(&self, token: &str, max_age: u64) -> String {
        let secure = if self.secure_cookie { "; Secure" } else { "" };
        format!("{COOKIE_NAME}={token}; HttpOnly{secure}; SameSite=Strict; Path=/; Max-Age={max_age}")
    }
}

/// The session token in a `Cookie` request header.
pub fn token_from_cookie(header: &str) -> Option<&str> {
    header.split(';').filter_map(|p| p.trim().split_once('=')).find(|(k, _)| *k == COOKIE_NAME).map(|(_, v)| v).filter(|v| !v.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    #[test]
    fn password_round_trip() {
        let p = StoredPassword::new("correct horse").unwrap();
        assert_eq!(p.iterations, 600_000);
        assert_eq!(STANDARD.decode(&p.salt).unwrap().len(), 16);
        assert_eq!(STANDARD.decode(&p.hash).unwrap().len(), 32);
        assert!(p.verify("correct horse"));
        let dir = TempDir::new("pw");
        let path = dir.0.join("auth.json");
        p.save(&path).unwrap();
        assert!(StoredPassword::load(&path).unwrap().unwrap().verify("correct horse"));
    }

    #[test]
    fn wrong_password_is_rejected() {
        let p = StoredPassword::with_iterations("secret", 1000).unwrap();
        assert!(!p.verify("Secret"));
        assert!(!p.verify(""));
        assert!(StoredPassword::with_iterations("", 1000).is_err());
    }

    #[test]
    fn session_survives_a_reload() {
        let dir = TempDir::new("sess");
        let path = dir.0.join("sessions.json");
        let mut s = Sessions::load(&path);
        let t = s.create(1000).unwrap();
        assert!(s.is_valid(&t, 1001));
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains(&t), "the token itself must not be stored");
        let s2 = Sessions::load(&path);
        assert!(s2.is_valid(&t, 1001));
        assert!(!s2.is_valid("not a token", 1001));
    }

    #[test]
    fn expired_session_is_rejected() {
        let dir = TempDir::new("exp");
        let mut s = Sessions::load(&dir.0.join("sessions.json"));
        let t = s.create(1000).unwrap();
        assert!(s.is_valid(&t, 1000 + SESSION_SECS - 1));
        assert!(!s.is_valid(&t, 1000 + SESSION_SECS));
    }

    #[test]
    fn logout_removes_the_session() {
        let dir = TempDir::new("out");
        let mut s = Sessions::load(&dir.0.join("sessions.json"));
        let t = s.create(now()).unwrap();
        s.remove(&t).unwrap();
        assert!(!s.is_valid(&t, now()));
    }

    #[test]
    fn failures_slow_down() {
        let secs: Vec<u64> = (1..=8).map(|n| delay_for(n).as_secs()).collect();
        assert_eq!(secs, [0, 2, 4, 8, 16, 30, 30, 30]);
        assert_eq!(delay_for(u32::MAX).as_secs(), 30);
    }

    #[test]
    fn cookie_header_is_parsed() {
        assert_eq!(token_from_cookie("a=b; cache_session=xyz; c=d"), Some("xyz"));
        assert_eq!(token_from_cookie("a=b"), None);
        assert_eq!(token_from_cookie("cache_session="), None);
    }
}
