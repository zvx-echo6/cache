//! Sign-in: one user, a password and no username.
//!
//! The password is kept as PBKDF2-HMAC-SHA256 (600000 iterations, a random 16-byte salt, a 32-byte hash) in `auth.json`.
//! A sign-in gives a random session token in a cookie; only the SHA-256 of the token is stored, in `sessions.json`, so a
//! restart or a reboot does not sign anyone out and a copy of the file is no use to someone who wants a session.
//!
//! A running server follows both files without a restart (no watcher): a sign-in re-reads `auth.json` when its modification
//! stamp has changed, and every session check re-reads `sessions.json` the same way, so `set-password` (and its
//! `--sign-out-all`) take effect at once.

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

/// A file's modification time and length, or `None` when it does not exist. Two different stamps mean the file changed.
type Stamp = Option<(SystemTime, u64)>;

fn stamp(path: &Path) -> Stamp {
    let m = std::fs::metadata(path).ok()?;
    Some((m.modified().ok()?, m.len()))
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
    /// The stamp of the file as last read or written; a different stamp on disk means someone else changed it.
    seen: Stamp,
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
        let seen = stamp(path);
        let entries = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str::<SessionsFile>(&t).ok()).unwrap_or_default().sessions;
        Sessions { path: path.to_path_buf(), entries, seen }
    }

    /// Re-read the file if it changed since this process last read or wrote it (`set-password --sign-out-all` clears it).
    fn refresh(&mut self) {
        if stamp(&self.path) != self.seen {
            *self = Sessions::load(&self.path);
        }
    }

    fn save(&mut self) -> io::Result<()> {
        let f = SessionsFile { sessions: self.entries.clone() };
        write_private(&self.path, serde_json::to_string(&f).map_err(io::Error::other)?.as_bytes())?;
        self.seen = stamp(&self.path);
        Ok(())
    }

    /// Empty the sessions file, so every browser has to sign in again (a running server notices on its next request).
    pub fn clear_file(path: &Path) -> io::Result<()> {
        let f = SessionsFile::default();
        write_private(path, serde_json::to_string(&f).map_err(io::Error::other)?.as_bytes())
    }

    /// Start a session at time `now`; returns the token for the cookie.
    pub fn create(&mut self, now: u64) -> io::Result<String> {
        let token = URL_SAFE_NO_PAD.encode(random_bytes::<32>()?);
        self.refresh();
        self.entries.retain(|_, exp| *exp > now);
        self.entries.insert(token_hash(&token), now + SESSION_SECS);
        self.save()?;
        Ok(token)
    }

    pub fn is_valid(&mut self, token: &str, now: u64) -> bool {
        self.refresh();
        self.entries.get(&token_hash(token)).is_some_and(|exp| *exp > now)
    }

    pub fn remove(&mut self, token: &str) -> io::Result<()> {
        self.refresh();
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
    password: Mutex<PasswordState>,
    sessions: Mutex<Sessions>,
    failures: Mutex<u32>,
    /// Whether the cookie is marked Secure (everything but `--no-tls`).
    pub secure_cookie: bool,
}

/// The password in memory, and where it came from so a change on disk can be picked up.
struct PasswordState {
    current: Option<StoredPassword>,
    /// `auth.json`, when this state follows a file.
    path: Option<PathBuf>,
    seen: Stamp,
}

impl Auth {
    pub fn load(data: &Path, secure_cookie: bool) -> io::Result<Auth> {
        let path = data.join("auth.json");
        let seen = stamp(&path);
        let current = StoredPassword::load(&path)?;
        let password = PasswordState { current, path: Some(path), seen };
        Ok(Auth { password: Mutex::new(password), sessions: Mutex::new(Sessions::load(&data.join("sessions.json"))), failures: Mutex::new(0), secure_cookie })
    }

    /// An `Auth` that holds `password` and never looks at `auth.json` again.
    pub fn new(password: Option<StoredPassword>, sessions: Sessions, secure_cookie: bool) -> Auth {
        let password = PasswordState { current: password, path: None, seen: None };
        Auth { password: Mutex::new(password), sessions: Mutex::new(sessions), failures: Mutex::new(0), secure_cookie }
    }

    pub fn has_password(&self) -> bool {
        self.password.lock().unwrap_or_else(|e| e.into_inner()).current.is_some()
    }

    /// The password to check against: `auth.json` is read again first if it changed since it was last read.
    fn current_password(&self) -> Option<StoredPassword> {
        let mut st = self.password.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(path) = st.path.clone() {
            let now_stamp = stamp(&path);
            if now_stamp != st.seen {
                match StoredPassword::load(&path) {
                    Ok(p) => {
                        eprintln!("cache-server: auth.json changed; using the new password");
                        st.current = p;
                        st.seen = now_stamp;
                    }
                    // unreadable right now: keep the old password and try again on the next sign-in
                    Err(e) => eprintln!("cache-server: auth.json could not be read ({e}); keeping the previous password"),
                }
            }
        }
        st.current.clone()
    }

    /// Check a password (this takes a fraction of a second: call it from a blocking thread). `Some(token)` on success.
    pub fn login(&self, password: &str) -> io::Result<Option<String>> {
        if !self.current_password().is_some_and(|p| p.verify(password)) {
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
        let mut s2 = Sessions::load(&path);
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

    /// Filesystems stamp files in ticks of a few milliseconds; wait one out so a rewrite gets a new stamp.
    fn tick() {
        std::thread::sleep(Duration::from_millis(50));
    }

    #[test]
    fn password_change_applies_without_a_restart() {
        let dir = TempDir::new("reload");
        let path = dir.0.join("auth.json");
        StoredPassword::with_iterations("old password", 1000).unwrap().save(&path).unwrap();
        let auth = Auth::load(&dir.0, true).unwrap();
        assert!(auth.login("old password").unwrap().is_some());
        assert!(auth.login("new password").unwrap().is_none());
        tick();
        StoredPassword::with_iterations("new password", 1000).unwrap().save(&path).unwrap();
        assert!(auth.login("old password").unwrap().is_none(), "the old password must stop working");
        assert!(auth.login("new password").unwrap().is_some(), "the new password must work");
    }

    #[test]
    fn a_first_password_is_picked_up_too() {
        let dir = TempDir::new("first");
        let auth = Auth::load(&dir.0, true).unwrap();
        assert!(!auth.has_password());
        assert!(auth.login("pw").unwrap().is_none());
        StoredPassword::with_iterations("pw", 1000).unwrap().save(&dir.0.join("auth.json")).unwrap();
        assert!(auth.login("pw").unwrap().is_some());
        assert!(auth.has_password());
    }

    #[test]
    fn existing_sessions_survive_a_password_change() {
        let dir = TempDir::new("keep");
        let path = dir.0.join("auth.json");
        StoredPassword::with_iterations("one", 1000).unwrap().save(&path).unwrap();
        let auth = Auth::load(&dir.0, true).unwrap();
        let token = auth.login("one").unwrap().unwrap();
        tick();
        StoredPassword::with_iterations("two", 1000).unwrap().save(&path).unwrap();
        assert!(auth.login("two").unwrap().is_some());
        assert!(auth.is_signed_in(&token));
    }

    #[test]
    fn sign_out_all_drops_sessions_in_a_running_server() {
        let dir = TempDir::new("all");
        StoredPassword::with_iterations("pw", 1000).unwrap().save(&dir.0.join("auth.json")).unwrap();
        let auth = Auth::load(&dir.0, true).unwrap();
        let (a, b) = (auth.login("pw").unwrap().unwrap(), auth.login("pw").unwrap().unwrap());
        assert!(auth.is_signed_in(&a) && auth.is_signed_in(&b));
        tick();
        // what `set-password --sign-out-all` does to the file
        Sessions::clear_file(&dir.0.join("sessions.json")).unwrap();
        assert!(!auth.is_signed_in(&a));
        assert!(!auth.is_signed_in(&b));
        // a fresh sign-in works and is kept
        let c = auth.login("pw").unwrap().unwrap();
        assert!(auth.is_signed_in(&c));
        // and a restart sees an empty file's worth of sessions, not the old ones
        let mut again = Sessions::load(&dir.0.join("sessions.json"));
        assert!(!again.is_valid(&a, now()));
        assert!(again.is_valid(&c, now()));
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
