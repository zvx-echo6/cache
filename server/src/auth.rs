//! Sign-in: one user, a password and no username.
//!
//! The password is kept as PBKDF2-HMAC-SHA256 (600000 iterations, a random 16-byte salt, a 32-byte hash) in `auth.json`.
//! A sign-in gives a random session token in a cookie; only the SHA-256 of the token is stored, in `sessions.json`, so a
//! restart or a reboot does not sign anyone out and a copy of the file is no use to someone who wants a session.
//!
//! A running server follows both files without a restart (no watcher): a sign-in re-reads `auth.json` when its modification
//! stamp has changed, and every session check re-reads `sessions.json` the same way, so `set-password` (and its
//! `--sign-out-all`) take effect at once.
//!
//! `auth.json` also holds the sign-in setting (`mode`, `start_with_password`), the registered security keys (WebAuthn
//! credentials) and the key files (an id and a SHA-256 of the secret; the secret is never stored). The keys' own sign-in
//! logic is in `keys`; the pages that use all this are in `pages`.

use crate::write_private;
use webauthn_rs::prelude::{SecurityKey, SecurityKeyAuthentication, SecurityKeyRegistration, Webauthn};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ring::rand::{SecureRandom, SystemRandom};
use ring::{digest, pbkdf2};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
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
/// The cookie that says the password was right and a key is still to come (mode `both`).
pub const HALF_COOKIE_NAME: &str = "cache_half";
/// How long the password step of `both` stays good, in seconds.
pub const HALF_SECS: u64 = 300;
/// How long a /zim/ token lasts, in seconds (12 hours).
pub const ZIM_TOKEN_SECS: u64 = 12 * 3600;
/// The largest key file taken, in bytes.
pub const KEYFILE_MAX: usize = 4096;
/// The first line of a key file.
pub const KEYFILE_MAGIC: &str = "cache-key-1";

/// Seconds since the Unix epoch.
pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub(crate) fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut b = [0u8; N];
    SystemRandom::new().fill(&mut b).map_err(|_| io::Error::other("no random bytes available"))?;
    Ok(b)
}

/// A file's modification time and length, or `None` when it does not exist. Two different stamps mean the file changed.
pub(crate) type Stamp = Option<(SystemTime, u64)>;

pub(crate) fn stamp(path: &Path) -> Stamp {
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

    /// Hash with a chosen iteration count (tests use a small one; `new` is the real thing).
    pub fn with_iterations(password: &str, iterations: u32) -> io::Result<StoredPassword> {
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
}

/// How a person may sign in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// The password only.
    #[default]
    Password,
    /// The password, or a key.
    Either,
    /// The password, then a key.
    Both,
    /// A key only.
    Key,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Password => "password",
            Mode::Either => "either",
            Mode::Both => "both",
            Mode::Key => "key",
        }
    }

    pub fn parse(s: &str) -> Option<Mode> {
        Some(match s {
            "password" => Mode::Password,
            "either" => Mode::Either,
            "both" => Mode::Both,
            "key" => Mode::Key,
            _ => return None,
        })
    }

    /// Whether the password endpoint answers at all.
    pub fn allows_password(self) -> bool {
        self != Mode::Key
    }

    /// Whether the key endpoints answer at all.
    pub fn allows_key(self) -> bool {
        self != Mode::Password
    }

    /// Whether signing in needs a key (so a person without a usable key would be locked out).
    pub fn needs_key(self) -> bool {
        matches!(self, Mode::Both | Mode::Key)
    }
}

/// A registered security key (a WebAuthn credential).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityKeyEntry {
    pub id: String,
    pub name: String,
    pub added: u64,
    pub last_used: Option<u64>,
    pub key: SecurityKey,
}

/// A key file: the id written in the file and the SHA-256 of its secret.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyFileEntry {
    pub id: String,
    pub name: String,
    pub added: u64,
    pub last_used: Option<u64>,
    pub hash: String,
}

/// Everything `auth.json` holds. The password fields sit at the top level of the file (as before keys existed), so a file
/// written by an older build still loads.
#[derive(Debug, Clone, Default)]
pub struct AuthFile {
    pub password: Option<StoredPassword>,
    pub mode: Mode,
    pub start_with_password: bool,
    pub security_keys: Vec<SecurityKeyEntry>,
    pub key_files: Vec<KeyFileEntry>,
}

#[derive(Serialize, Deserialize, Default)]
struct RawAuth {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    algorithm: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    iterations: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    salt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hash: Option<String>,
    #[serde(default)]
    mode: Mode,
    #[serde(default)]
    start_with_password: bool,
    #[serde(default)]
    security_keys: Vec<SecurityKeyEntry>,
    #[serde(default)]
    key_files: Vec<KeyFileEntry>,
}

impl AuthFile {
    pub fn parse(text: &str) -> Result<AuthFile, serde_json::Error> {
        let r: RawAuth = serde_json::from_str(text)?;
        let password = match (r.algorithm, r.iterations, r.salt, r.hash) {
            (Some(algorithm), Some(iterations), Some(salt), Some(hash)) => Some(StoredPassword { algorithm, iterations, salt, hash }),
            _ => None,
        };
        Ok(AuthFile { password, mode: r.mode, start_with_password: r.start_with_password, security_keys: r.security_keys, key_files: r.key_files })
    }

    pub fn to_json(&self) -> io::Result<String> {
        let p = self.password.clone();
        let raw = RawAuth {
            algorithm: p.as_ref().map(|p| p.algorithm.clone()),
            iterations: p.as_ref().map(|p| p.iterations),
            salt: p.as_ref().map(|p| p.salt.clone()),
            hash: p.map(|p| p.hash),
            mode: self.mode,
            start_with_password: self.start_with_password,
            security_keys: self.security_keys.clone(),
            key_files: self.key_files.clone(),
        };
        serde_json::to_string_pretty(&raw).map_err(io::Error::other)
    }

    /// The file, or `None` when it does not exist.
    pub fn load(path: &Path) -> io::Result<Option<AuthFile>> {
        match std::fs::read_to_string(path) {
            Ok(t) => AuthFile::parse(&t).map(Some).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{}: {e}", path.display()))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Written to a temporary file and renamed over the target, readable by the owner only.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        write_private(path, self.to_json()?.as_bytes())
    }

    /// Keys that can sign in right now: key files, and security keys when WebAuthn is set up.
    pub fn usable_keys(&self, webauthn: bool) -> usize {
        self.key_files.len() + if webauthn { self.security_keys.len() } else { 0 }
    }

    /// What `set-password` does: the new password, the sign-in setting back to password only, the keys kept.
    pub fn reset_with_password(&mut self, password: StoredPassword) {
        self.password = Some(password);
        self.mode = Mode::Password;
        self.start_with_password = false;
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

    /// True when the session whose token hashes to `hash` is still valid at `now` (a /zim/ token is tied to one).
    fn has_hash(&mut self, hash: &str, now: u64) -> bool {
        self.refresh();
        self.entries.get(hash).is_some_and(|exp| *exp > now)
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
    let secs = if n > 5 { MAX_DELAY_SECS } else { (1u64 << (n - 1)).min(MAX_DELAY_SECS) };
    Duration::from_secs(secs)
}

/// The file in memory, and where it came from so a change on disk can be picked up.
struct AuthState {
    file: AuthFile,
    /// `auth.json`, when this state follows a file.
    path: Option<PathBuf>,
    seen: Stamp,
}

impl AuthState {
    /// Read the file again if it changed since this process last read or wrote it. A file that cannot be read right now
    /// leaves the previous contents in place.
    fn refresh(&mut self) {
        let Some(path) = self.path.clone() else { return };
        let now_stamp = stamp(&path);
        if now_stamp == self.seen {
            return;
        }
        match AuthFile::load(&path) {
            Ok(f) => {
                eprintln!("cache: auth.json changed; using the new settings");
                self.file = f.unwrap_or_default();
                self.seen = now_stamp;
            }
            Err(e) => eprintln!("cache: auth.json could not be read ({e}); keeping the previous settings"),
        }
    }
}

/// Why a settings change or a key operation was refused.
#[derive(Debug)]
pub enum SettingsError {
    /// Would leave no way to sign in (the text is the plain label for the page).
    Locked(&'static str),
    /// A bad name, id or setting.
    Invalid(&'static str),
    NotFound,
    /// Security keys need a hostname and a trusted certificate (`--public-origin`).
    NoWebauthn,
    Io(io::Error),
}

/// What a password sign-in came to.
#[derive(Debug, PartialEq, Eq)]
pub enum Login {
    /// Signed in: the session token.
    Full(String),
    /// The password was right and a key is still to come: the half token (mode `both`).
    Half(String),
    Wrong,
    /// The sign-in setting does not take a password.
    NotAllowed,
}

/// Why the key endpoints will not even look at an attempt.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Gate {
    /// The sign-in setting does not take a key.
    NotAllowed,
    /// Mode `both`: the password step has not been done (or has expired).
    NeedHalf,
}

/// What a key-file sign-in came to.
#[derive(Debug, PartialEq, Eq)]
pub enum KeyLogin {
    Full(String),
    Wrong,
    Gate(Gate),
}

/// The sign-in state of the server.
pub struct Auth {
    state: Mutex<AuthState>,
    sessions: Mutex<Sessions>,
    /// Password steps of mode `both` that wait for a key: hash of the half token -> expiry. Memory only.
    halves: Mutex<HashMap<String, u64>>,
    failures: Mutex<u32>,
    /// Tokens for /zim/ (ZIM pages shown in a sandboxed frame): hash of the token -> (hash of the session token it belongs to,
    /// expiry). Memory only, so a restart ends them. They open nothing but /zim/.
    zim_tokens: Mutex<HashMap<String, (String, u64)>>,
    /// How long a /zim/ token lasts, in seconds (a field so a test can shorten it).
    pub zim_secs: u64,
    /// Whether the cookie is marked Secure (everything but `--no-tls`).
    pub secure_cookie: bool,
    /// How long the half cookie lasts, in seconds (a field so a test can shorten it).
    pub half_secs: u64,
    /// WebAuthn, when `--public-origin` names a hostname.
    pub(crate) webauthn: Option<Webauthn>,
    pub(crate) pending_auth: Mutex<HashMap<String, (SecurityKeyAuthentication, u64)>>,
    pub(crate) pending_reg: Mutex<HashMap<String, (SecurityKeyRegistration, String, u64)>>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Auth {
    fn build(state: AuthState, sessions: Sessions, secure_cookie: bool) -> Auth {
        Auth {
            state: Mutex::new(state),
            sessions: Mutex::new(sessions),
            halves: Mutex::new(HashMap::new()),
            failures: Mutex::new(0),
            zim_tokens: Mutex::new(HashMap::new()),
            zim_secs: ZIM_TOKEN_SECS,
            secure_cookie,
            half_secs: HALF_SECS,
            webauthn: None,
            pending_auth: Mutex::new(HashMap::new()),
            pending_reg: Mutex::new(HashMap::new()),
        }
    }

    pub fn load(data: &Path, secure_cookie: bool) -> io::Result<Auth> {
        let path = data.join("auth.json");
        let seen = stamp(&path);
        let file = AuthFile::load(&path)?.unwrap_or_default();
        Ok(Auth::build(AuthState { file, path: Some(path), seen }, Sessions::load(&data.join("sessions.json")), secure_cookie))
    }

    /// An `Auth` that holds `password` and never looks at `auth.json` again.
    pub fn new(password: Option<StoredPassword>, sessions: Sessions, secure_cookie: bool) -> Auth {
        let file = AuthFile { password, ..AuthFile::default() };
        Auth::build(AuthState { file, path: None, seen: None }, sessions, secure_cookie)
    }

    /// Turn on security keys. `webauthn` comes from `keys::build_webauthn`.
    pub fn with_webauthn(mut self, webauthn: Option<Webauthn>) -> Auth {
        self.webauthn = webauthn;
        self
    }

    /// Run `f` on the current file contents (read again first if it changed on disk).
    pub(crate) fn read<R>(&self, f: impl FnOnce(&AuthFile) -> R) -> R {
        let mut st = lock(&self.state);
        st.refresh();
        f(&st.file)
    }

    /// Change the file: `f` works on a copy; when it succeeds the copy is written (atomically, owner only) and becomes current.
    pub(crate) fn update<R>(&self, f: impl FnOnce(&mut AuthFile) -> Result<R, SettingsError>) -> Result<R, SettingsError> {
        let mut st = lock(&self.state);
        st.refresh();
        let mut next = st.file.clone();
        let r = f(&mut next)?;
        if let Some(p) = st.path.clone() {
            next.save(&p).map_err(SettingsError::Io)?;
            st.seen = stamp(&p);
        }
        st.file = next;
        Ok(r)
    }

    pub fn has_password(&self) -> bool {
        self.read(|f| f.password.is_some())
    }

    pub fn mode(&self) -> Mode {
        self.read(|f| f.mode)
    }

    /// Whether a security key can sign in: WebAuthn is set up and at least one is registered.
    pub fn security_key_available(&self) -> bool {
        self.webauthn.is_some() && self.read(|f| !f.security_keys.is_empty())
    }

    pub fn webauthn_configured(&self) -> bool {
        self.webauthn.is_some()
    }

    /// What the sign-in page may know before anyone has signed in, and nothing else.
    pub fn public_state(&self) -> Value {
        let wa = self.webauthn.is_some();
        self.read(|f| {
            json!({
                "mode": f.mode.as_str(),
                "start_with_password": f.start_with_password,
                "security_key_available": wa && !f.security_keys.is_empty(),
                "key_file_available": !f.key_files.is_empty(),
            })
        })
    }

    /// Check a password (this takes a fraction of a second: call it from a blocking thread).
    pub fn password_login(&self, password: &str) -> io::Result<Login> {
        let (mode, stored) = self.read(|f| (f.mode, f.password.clone()));
        if !mode.allows_password() {
            return Ok(Login::NotAllowed);
        }
        if !stored.is_some_and(|p| p.verify(password)) {
            return Ok(Login::Wrong);
        }
        self.reset_failures();
        if mode == Mode::Both {
            return Ok(Login::Half(self.create_half(now())?));
        }
        lock(&self.sessions).create(now()).map(Login::Full)
    }

    /// Count a failed sign-in (all callers share one count) and say how long to hold the 401.
    pub fn record_failure(&self) -> Duration {
        let mut n = lock(&self.failures);
        *n = n.saturating_add(1);
        delay_for(*n)
    }

    pub(crate) fn reset_failures(&self) {
        *lock(&self.failures) = 0;
    }

    /// Start a full session (after a key has been accepted).
    pub(crate) fn new_session(&self) -> io::Result<String> {
        lock(&self.sessions).create(now())
    }

    pub fn is_signed_in(&self, token: &str) -> bool {
        lock(&self.sessions).is_valid(token, now())
    }

    pub fn logout(&self, token: &str) -> io::Result<()> {
        let hash = token_hash(token);
        lock(&self.zim_tokens).retain(|_, (session, _)| *session != hash);
        lock(&self.sessions).remove(token)
    }

    // ---- /zim/ tokens

    /// A token for /zim/, tied to the signed-in session `session` (its cookie value). It is not a session: no `/api/` call takes it.
    pub fn create_zim_token(&self, session: &str) -> io::Result<String> {
        let at = now();
        let token = URL_SAFE_NO_PAD.encode(random_bytes::<32>()?);
        let mut t = lock(&self.zim_tokens);
        t.retain(|_, (_, exp)| *exp > at);
        t.insert(token_hash(&token), (token_hash(session), at + self.zim_secs));
        Ok(token)
    }

    /// True when `token` is a /zim/ token that has not expired at time `at` and whose session is still signed in.
    pub fn zim_token_valid_at(&self, token: &str, at: u64) -> bool {
        let Some((session, exp)) = lock(&self.zim_tokens).get(&token_hash(token)).cloned() else { return false };
        exp > at && lock(&self.sessions).has_hash(&session, at)
    }

    pub fn zim_token_valid(&self, token: &str) -> bool {
        self.zim_token_valid_at(token, now())
    }

    // ---- the half session of mode `both`

    fn create_half(&self, at: u64) -> io::Result<String> {
        let token = URL_SAFE_NO_PAD.encode(random_bytes::<32>()?);
        let mut h = lock(&self.halves);
        h.retain(|_, exp| *exp > at);
        h.insert(token_hash(&token), at + self.half_secs);
        Ok(token)
    }

    /// True when `token` is a password step that has not expired at time `at`.
    pub fn half_valid_at(&self, token: &str, at: u64) -> bool {
        lock(&self.halves).get(&token_hash(token)).is_some_and(|exp| *exp > at)
    }

    pub fn half_valid(&self, token: &str) -> bool {
        self.half_valid_at(token, now())
    }

    pub(crate) fn consume_half(&self, token: Option<&str>) {
        if let Some(t) = token {
            lock(&self.halves).remove(&token_hash(t));
        }
    }

    /// Whether the key endpoints will look at an attempt at all.
    pub fn key_gate(&self, half: Option<&str>) -> Result<(), Gate> {
        let mode = self.mode();
        if !mode.allows_key() {
            return Err(Gate::NotAllowed);
        }
        if mode == Mode::Both && !half.is_some_and(|t| self.half_valid(t)) {
            return Err(Gate::NeedHalf);
        }
        Ok(())
    }

    // ---- key files

    /// Check a key file's bytes. `half` is the half token (needed in mode `both`).
    pub fn keyfile_login(&self, bytes: &[u8], half: Option<&str>) -> io::Result<KeyLogin> {
        if let Err(g) = self.key_gate(half) {
            return Ok(KeyLogin::Gate(g));
        }
        let Some((id, secret)) = parse_key_file(bytes) else { return Ok(KeyLogin::Wrong) };
        let got = digest::digest(&digest::SHA256, &secret);
        let found = self.read(|f| f.key_files.iter().find(|k| k.id == id).map(|k| k.hash.clone()));
        // An unknown id is compared against a dummy hash, so it takes as long as a wrong secret.
        let want = found.as_deref().and_then(|h| STANDARD.decode(h).ok()).unwrap_or_else(|| vec![0u8; 32]);
        let same: bool = got.as_ref().ct_eq(&want[..]).into();
        if !same || found.is_none() {
            return Ok(KeyLogin::Wrong);
        }
        match self.update(|f| {
            if let Some(k) = f.key_files.iter_mut().find(|k| k.id == id) {
                k.last_used = Some(now());
            }
            Ok(())
        }) {
            Ok(()) => {}
            Err(SettingsError::Io(e)) => return Err(e),
            Err(_) => {}
        }
        self.reset_failures();
        self.consume_half(half);
        self.new_session().map(KeyLogin::Full)
    }

    /// Make a key file. Returns its id and the file's bytes (the only time the secret exists outside the person's hands).
    pub fn add_key_file(&self, name: &str) -> Result<(String, Vec<u8>), SettingsError> {
        let name = clean_name(name)?;
        let id = hex(&random_bytes::<8>().map_err(SettingsError::Io)?);
        let secret = random_bytes::<32>().map_err(SettingsError::Io)?;
        let hash = STANDARD.encode(digest::digest(&digest::SHA256, &secret));
        let file = format!("{KEYFILE_MAGIC}\n{id}\n{}\n", URL_SAFE_NO_PAD.encode(secret)).into_bytes();
        self.update(|f| {
            f.key_files.push(KeyFileEntry { id: id.clone(), name, added: now(), last_used: None, hash });
            Ok(())
        })?;
        Ok((id, file))
    }

    pub fn remove_key_file(&self, id: &str) -> Result<(), SettingsError> {
        let wa = self.webauthn.is_some();
        self.update(|f| {
            let Some(i) = f.key_files.iter().position(|k| k.id == id) else { return Err(SettingsError::NotFound) };
            if f.mode.needs_key() && f.usable_keys(wa) <= 1 {
                return Err(SettingsError::Locked(LAST_KEY));
            }
            f.key_files.remove(i);
            Ok(())
        })
    }

    pub fn remove_security_key(&self, id: &str) -> Result<(), SettingsError> {
        let wa = self.webauthn.is_some();
        self.update(|f| {
            let Some(i) = f.security_keys.iter().position(|k| k.id == id) else { return Err(SettingsError::NotFound) };
            // a key that cannot sign in (no WebAuthn set up) does not count, so removing it never locks anyone out
            let counts = if wa { 1 } else { 0 };
            if f.mode.needs_key() && counts > 0 && f.usable_keys(wa) <= 1 {
                return Err(SettingsError::Locked(LAST_KEY));
            }
            f.security_keys.remove(i);
            Ok(())
        })
    }

    // ---- the sign-in setting

    /// Change how people sign in. Takes effect on the next request.
    pub fn set_signin(&self, mode: Mode, start_with_password: bool) -> Result<(), SettingsError> {
        let wa = self.webauthn.is_some();
        self.update(|f| {
            if mode.needs_key() && f.usable_keys(wa) == 0 {
                return Err(SettingsError::Locked(NO_KEY));
            }
            f.mode = mode;
            f.start_with_password = start_with_password;
            Ok(())
        })
    }

    /// The settings page's view: the setting and both lists (no secrets, no credential data).
    pub fn settings_view(&self) -> Value {
        let wa = self.webauthn.is_some();
        self.read(|f| {
            let sk: Vec<Value> = f.security_keys.iter().map(|k| json!({"id": k.id, "name": k.name, "added": k.added, "last_used": k.last_used})).collect();
            let kf: Vec<Value> = f.key_files.iter().map(|k| json!({"id": k.id, "name": k.name, "added": k.added, "last_used": k.last_used})).collect();
            json!({
                "mode": f.mode.as_str(),
                "start_with_password": f.start_with_password,
                "webauthn_available": wa,
                "usable_keys": f.usable_keys(wa),
                "security_keys": sk,
                "key_files": kf,
            })
        })
    }

    /// The `Set-Cookie` value that carries `token` (an empty token with `max_age` 0 clears it).
    pub fn cookie(&self, token: &str, max_age: u64) -> String {
        let secure = if self.secure_cookie { "; Secure" } else { "" };
        format!("{COOKIE_NAME}={token}; HttpOnly{secure}; SameSite=Strict; Path=/; Max-Age={max_age}")
    }

    /// The half cookie: only sent to the sign-in endpoints, so nothing else ever sees it.
    pub fn half_cookie(&self, token: &str, max_age: u64) -> String {
        let secure = if self.secure_cookie { "; Secure" } else { "" };
        format!("{HALF_COOKIE_NAME}={token}; HttpOnly{secure}; SameSite=Strict; Path=/auth; Max-Age={max_age}")
    }
}

/// The plain labels the settings page shows for the two lock-out guards.
pub const NO_KEY: &str = "Register a key first.";
pub const LAST_KEY: &str = "The last key is needed for this sign-in setting.";

pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// A name for a key as the page shows it: trimmed, 1 to 64 characters, no control characters.
pub(crate) fn clean_name(name: &str) -> Result<String, SettingsError> {
    let n = name.trim();
    if n.is_empty() || n.chars().count() > 64 || n.chars().any(char::is_control) {
        return Err(SettingsError::Invalid("A name is needed (up to 64 characters)."));
    }
    Ok(n.to_string())
}

/// The file name a key file is downloaded as: `cache-<name>.key`, the name cut down to letters, digits, `.`, `_` and `-`.
pub fn key_file_name(name: &str) -> String {
    let mut s: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' { c } else { '-' }).collect();
    s = s.trim_matches(['-', '.']).to_string();
    if s.is_empty() {
        s = "key".into();
    }
    format!("cache-{s}.key")
}

/// The id and the 32-byte secret in a key file, or `None` when the bytes are not a key file.
fn parse_key_file(bytes: &[u8]) -> Option<(String, Vec<u8>)> {
    if bytes.len() > KEYFILE_MAX {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let mut lines = text.lines();
    if lines.next()? != KEYFILE_MAGIC {
        return None;
    }
    let id = lines.next()?.to_string();
    let secret = URL_SAFE_NO_PAD.decode(lines.next()?.trim()).ok()?;
    if secret.len() != 32 || id.is_empty() || id.len() > 32 || lines.next().is_some_and(|l| !l.trim().is_empty()) {
        return None;
    }
    Some((id, secret))
}

/// The session token in a `Cookie` request header.
pub fn token_from_cookie(header: &str) -> Option<&str> {
    cookie_value(header, COOKIE_NAME)
}

/// The half token in a `Cookie` request header.
pub fn half_from_cookie(header: &str) -> Option<&str> {
    cookie_value(header, HALF_COOKIE_NAME)
}

fn cookie_value<'a>(header: &'a str, name: &str) -> Option<&'a str> {
    header.split(';').filter_map(|p| p.trim().split_once('=')).find(|(k, _)| *k == name).map(|(_, v)| v).filter(|v| !v.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    /// Set the password in `auth.json`, keeping everything else in it (what `set-password` does, minus the mode reset).
    fn put(path: &Path, pw: &str) {
        let mut f = AuthFile::load(path).unwrap().unwrap_or_default();
        f.password = Some(StoredPassword::with_iterations(pw, 1000).unwrap());
        f.save(path).unwrap();
    }

    /// The session token of a password sign-in in a mode that signs in at once.
    fn login(a: &Auth, pw: &str) -> io::Result<Option<String>> {
        Ok(match a.password_login(pw)? {
            Login::Full(t) => Some(t),
            _ => None,
        })
    }

    #[test]
    fn password_round_trip() {
        let p = StoredPassword::new("correct horse").unwrap();
        assert_eq!(p.iterations, 600_000);
        assert_eq!(STANDARD.decode(&p.salt).unwrap().len(), 16);
        assert_eq!(STANDARD.decode(&p.hash).unwrap().len(), 32);
        assert!(p.verify("correct horse"));
        let dir = TempDir::new("pw");
        let path = dir.0.join("auth.json");
        AuthFile { password: Some(p), ..AuthFile::default() }.save(&path).unwrap();
        assert!(AuthFile::load(&path).unwrap().unwrap().password.unwrap().verify("correct horse"));
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
        put(&path, "old password");
        let auth = Auth::load(&dir.0, true).unwrap();
        assert!(login(&auth, "old password").unwrap().is_some());
        assert!(login(&auth, "new password").unwrap().is_none());
        tick();
        put(&path, "new password");
        assert!(login(&auth, "old password").unwrap().is_none(), "the old password must stop working");
        assert!(login(&auth, "new password").unwrap().is_some(), "the new password must work");
    }

    #[test]
    fn a_first_password_is_picked_up_too() {
        let dir = TempDir::new("first");
        let auth = Auth::load(&dir.0, true).unwrap();
        assert!(!auth.has_password());
        assert!(login(&auth, "pw").unwrap().is_none());
        put(&dir.0.join("auth.json"), "pw");
        assert!(login(&auth, "pw").unwrap().is_some());
        assert!(auth.has_password());
    }

    #[test]
    fn existing_sessions_survive_a_password_change() {
        let dir = TempDir::new("keep");
        let path = dir.0.join("auth.json");
        put(&path, "one");
        let auth = Auth::load(&dir.0, true).unwrap();
        let token = login(&auth, "one").unwrap().unwrap();
        tick();
        put(&path, "two");
        assert!(login(&auth, "two").unwrap().is_some());
        assert!(auth.is_signed_in(&token));
    }

    #[test]
    fn sign_out_all_drops_sessions_in_a_running_server() {
        let dir = TempDir::new("all");
        put(&dir.0.join("auth.json"), "pw");
        let auth = Auth::load(&dir.0, true).unwrap();
        let (a, b) = (login(&auth, "pw").unwrap().unwrap(), login(&auth, "pw").unwrap().unwrap());
        assert!(auth.is_signed_in(&a) && auth.is_signed_in(&b));
        tick();
        // what `set-password --sign-out-all` does to the file
        Sessions::clear_file(&dir.0.join("sessions.json")).unwrap();
        assert!(!auth.is_signed_in(&a));
        assert!(!auth.is_signed_in(&b));
        // a fresh sign-in works and is kept
        let c = login(&auth, "pw").unwrap().unwrap();
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

    // ---- the sign-in setting, keys and the half session

    fn auth_with(dir: &TempDir, pw: &str) -> Auth {
        put(&dir.0.join("auth.json"), pw);
        Auth::load(&dir.0, true).unwrap()
    }

    #[test]
    fn an_old_file_with_only_a_password_loads_and_gets_the_defaults() {
        let dir = TempDir::new("old");
        let p = StoredPassword::with_iterations("pw", 1000).unwrap();
        let old = serde_json::to_string_pretty(&p).unwrap();
        assert!(!old.contains("mode"));
        std::fs::write(dir.0.join("auth.json"), old).unwrap();
        let f = AuthFile::load(&dir.0.join("auth.json")).unwrap().unwrap();
        assert!(f.password.unwrap().verify("pw"));
        assert_eq!((f.mode, f.start_with_password, f.security_keys.len(), f.key_files.len()), (Mode::Password, false, 0, 0));
    }

    #[test]
    fn auth_json_keeps_the_password_at_the_top_level_and_everything_survives_a_round_trip() {
        let dir = TempDir::new("rt");
        let auth = auth_with(&dir, "pw");
        auth.add_key_file("usb").unwrap();
        auth.set_signin(Mode::Either, true).unwrap();
        let v: Value = serde_json::from_str(&std::fs::read_to_string(dir.0.join("auth.json")).unwrap()).unwrap();
        assert_eq!(v["algorithm"], "pbkdf2-hmac-sha256");
        assert_eq!((v["mode"].clone(), v["start_with_password"].clone()), (json!("either"), json!(true)));
        assert_eq!(v["key_files"].as_array().unwrap().len(), 1);
        assert!(v["key_files"][0]["hash"].is_string() && v["key_files"][0].get("secret").is_none());
        let again = Auth::load(&dir.0, true).unwrap();
        assert_eq!(again.mode(), Mode::Either);
        assert_eq!(again.public_state()["key_file_available"], true);
    }

    #[cfg(unix)]
    #[test]
    fn auth_json_is_written_owner_only_and_leaves_no_temp_file() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new("perm");
        let auth = auth_with(&dir, "pw");
        auth.add_key_file("usb").unwrap();
        let mode = std::fs::metadata(dir.0.join("auth.json")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert!(!dir.0.join("auth.tmp").exists());
    }

    #[test]
    fn modes_decide_what_the_password_endpoint_does() {
        let dir = TempDir::new("modes");
        let auth = auth_with(&dir, "pw");
        auth.add_key_file("usb").unwrap();
        assert!(matches!(auth.password_login("pw").unwrap(), Login::Full(_)));
        assert_eq!(auth.password_login("nope").unwrap(), Login::Wrong);
        auth.set_signin(Mode::Either, false).unwrap();
        assert!(matches!(auth.password_login("pw").unwrap(), Login::Full(_)));
        auth.set_signin(Mode::Both, false).unwrap();
        let Login::Half(h) = auth.password_login("pw").unwrap() else { panic!("expected a half session") };
        assert!(!auth.is_signed_in(&h), "the half token is not a session");
        assert!(auth.half_valid(&h));
        assert_eq!(auth.password_login("nope").unwrap(), Login::Wrong);
        auth.set_signin(Mode::Key, false).unwrap();
        assert_eq!(auth.password_login("pw").unwrap(), Login::NotAllowed);
    }

    #[test]
    fn the_half_session_expires_and_is_used_once() {
        let dir = TempDir::new("half");
        let auth = auth_with(&dir, "pw");
        let (_, file) = auth.add_key_file("usb").unwrap();
        auth.set_signin(Mode::Both, false).unwrap();
        let Login::Half(h) = auth.password_login("pw").unwrap() else { panic!() };
        assert!(auth.half_valid_at(&h, now() + HALF_SECS - 5));
        assert!(!auth.half_valid_at(&h, now() + HALF_SECS + 5), "five minutes and it is gone");
        assert!(!auth.half_valid("forged"));
        // no half token: the key file is not even looked at
        assert_eq!(auth.keyfile_login(&file, None).unwrap(), KeyLogin::Gate(Gate::NeedHalf));
        assert_eq!(auth.keyfile_login(&file, Some("forged")).unwrap(), KeyLogin::Gate(Gate::NeedHalf));
        let KeyLogin::Full(t) = auth.keyfile_login(&file, Some(&h)).unwrap() else { panic!("expected a session") };
        assert!(auth.is_signed_in(&t));
        assert!(!auth.half_valid(&h), "the half token is spent");
        assert_eq!(auth.keyfile_login(&file, Some(&h)).unwrap(), KeyLogin::Gate(Gate::NeedHalf));
    }

    #[test]
    fn key_files_right_wrong_unknown_and_malformed() {
        let dir = TempDir::new("kf");
        let auth = auth_with(&dir, "pw");
        let (id, file) = auth.add_key_file("Blue USB stick").unwrap();
        let (_, other) = auth.add_key_file("second").unwrap();
        // nothing but the id and a hash of the secret is stored
        let stored = std::fs::read_to_string(dir.0.join("auth.json")).unwrap();
        let secret_line = std::str::from_utf8(&file).unwrap().lines().nth(2).unwrap().to_string();
        assert!(!stored.contains(&secret_line), "the secret must not be stored");
        assert!(stored.contains(&id));
        auth.set_signin(Mode::Key, false).unwrap();
        assert!(matches!(auth.keyfile_login(&file, None).unwrap(), KeyLogin::Full(_)));
        assert!(matches!(auth.keyfile_login(&other, None).unwrap(), KeyLogin::Full(_)));
        // a valid id with another key's secret
        let text = String::from_utf8(file.clone()).unwrap();
        let other_text = String::from_utf8(other.clone()).unwrap();
        let mixed = format!("{}\n{}\n{}\n", KEYFILE_MAGIC, text.lines().nth(1).unwrap(), other_text.lines().nth(2).unwrap());
        assert_eq!(auth.keyfile_login(mixed.as_bytes(), None).unwrap(), KeyLogin::Wrong);
        // an unknown id, a wrong magic, garbage, empty, a short secret, binary
        let unknown = format!("{}\nffffffffffffffff\n{}\n", KEYFILE_MAGIC, text.lines().nth(2).unwrap());
        let bad_magic = text.replacen(KEYFILE_MAGIC, "cache-key-9", 1);
        let short = format!("{}\n{}\nAAAA\n", KEYFILE_MAGIC, id);
        for bad in [unknown.as_bytes(), bad_magic.as_bytes(), b"hello", b"", short.as_bytes(), &[0xff, 0xfe, 0x00][..]] {
            assert_eq!(auth.keyfile_login(bad, None).unwrap(), KeyLogin::Wrong, "{bad:?}");
        }
        // more than 4 KB is refused even if it starts like a key file
        let mut big = file.clone();
        big.resize(KEYFILE_MAX + 1, b' ');
        assert_eq!(auth.keyfile_login(&big, None).unwrap(), KeyLogin::Wrong);
        // last_used was recorded
        assert!(auth.settings_view()["key_files"][0]["last_used"].is_u64());
        // a removed key file stops working
        auth.set_signin(Mode::Password, false).unwrap();
        auth.remove_key_file(&id).unwrap();
        auth.set_signin(Mode::Either, false).unwrap();
        assert_eq!(auth.keyfile_login(&file, None).unwrap(), KeyLogin::Wrong);
    }

    #[test]
    fn the_password_mode_takes_no_keys() {
        let dir = TempDir::new("pwonly");
        let auth = auth_with(&dir, "pw");
        let (_, file) = auth.add_key_file("usb").unwrap();
        assert_eq!(auth.keyfile_login(&file, None).unwrap(), KeyLogin::Gate(Gate::NotAllowed));
    }

    #[test]
    fn lock_out_guards() {
        let dir = TempDir::new("guards");
        let auth = auth_with(&dir, "pw");
        // no key: Key only and Password and key are refused, the others are fine
        assert!(matches!(auth.set_signin(Mode::Key, false), Err(SettingsError::Locked(NO_KEY))));
        assert!(matches!(auth.set_signin(Mode::Both, false), Err(SettingsError::Locked(NO_KEY))));
        auth.set_signin(Mode::Either, true).unwrap();
        auth.set_signin(Mode::Password, false).unwrap();
        let (a, _) = auth.add_key_file("a").unwrap();
        let (b, _) = auth.add_key_file("b").unwrap();
        auth.set_signin(Mode::Key, false).unwrap();
        auth.remove_key_file(&a).unwrap();
        // the last key cannot go while the mode needs one
        assert!(matches!(auth.remove_key_file(&b), Err(SettingsError::Locked(LAST_KEY))));
        auth.set_signin(Mode::Both, false).unwrap();
        assert!(matches!(auth.remove_key_file(&b), Err(SettingsError::Locked(LAST_KEY))));
        // Either does not need a key, so the last one may go
        auth.set_signin(Mode::Either, false).unwrap();
        auth.remove_key_file(&b).unwrap();
        assert!(matches!(auth.remove_key_file(&b), Err(SettingsError::NotFound)));
        assert_eq!(auth.settings_view()["usable_keys"], 0);
        // names
        assert!(matches!(auth.add_key_file("   "), Err(SettingsError::Invalid(_))));
        assert!(matches!(auth.add_key_file(&"x".repeat(65)), Err(SettingsError::Invalid(_))));
    }

    #[test]
    fn set_password_resets_the_mode_and_keeps_the_keys() {
        let dir = TempDir::new("reset");
        let auth = auth_with(&dir, "old");
        auth.add_key_file("usb").unwrap();
        auth.set_signin(Mode::Key, false).unwrap();
        auth.set_signin(Mode::Key, true).unwrap();
        tick();
        // what the command does to the file
        let path = dir.0.join("auth.json");
        let mut f = AuthFile::load(&path).unwrap().unwrap();
        f.reset_with_password(StoredPassword::with_iterations("new", 1000).unwrap());
        f.save(&path).unwrap();
        // the running server follows it at once
        assert_eq!(auth.mode(), Mode::Password);
        assert!(!auth.read(|f| f.start_with_password));
        assert!(login(&auth, "new").unwrap().is_some());
        assert_eq!(auth.settings_view()["key_files"].as_array().unwrap().len(), 1, "the registered keys stay");
    }

    #[test]
    fn a_settings_change_is_seen_by_a_second_reader_of_the_same_file() {
        let dir = TempDir::new("two");
        let a = auth_with(&dir, "pw");
        let b = Auth::load(&dir.0, true).unwrap();
        tick();
        a.add_key_file("usb").unwrap();
        a.set_signin(Mode::Either, true).unwrap();
        assert_eq!(b.mode(), Mode::Either);
        assert_eq!(b.public_state()["key_file_available"], true);
    }

    #[test]
    fn public_state_reveals_only_four_fields() {
        let dir = TempDir::new("pub");
        let auth = auth_with(&dir, "pw");
        let v = auth.public_state();
        let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, ["key_file_available", "mode", "security_key_available", "start_with_password"]);
        assert_eq!(v["security_key_available"], false, "no WebAuthn set up");
    }

    #[test]
    fn key_file_names() {
        assert_eq!(key_file_name("Blue USB stick"), "cache-Blue-USB-stick.key");
        assert_eq!(key_file_name("../../etc/passwd"), "cache-etc-passwd.key");
        assert_eq!(key_file_name("***"), "cache-key.key");
        assert_eq!(key_file_name("a\r\nb"), "cache-a--b.key");
    }

    #[test]
    fn failures_are_shared_and_reset_on_success() {
        let dir = TempDir::new("thr");
        let auth = auth_with(&dir, "pw");
        assert_eq!(auth.record_failure(), Duration::ZERO);
        assert_eq!(auth.record_failure(), Duration::from_secs(2));
        assert_eq!(auth.record_failure(), Duration::from_secs(4));
        assert!(login(&auth, "pw").unwrap().is_some());
        assert_eq!(auth.record_failure(), Duration::ZERO, "a good sign-in starts the count again");
    }
}
