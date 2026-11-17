//! The server's own log for the browser's Settings > Storage > Advanced: Cache's app events (what failed, what it did), never the
//! system journal. A size-capped rolling file under `<data>/log/`: `cache.log` turns over at 1 MiB into `cache.1.log` (the one
//! before that goes), so the log never holds more than 2 MiB. The level is kept in `<data>/log/level.json`, as the phone keeps its
//! own; Everything goes back to the level before it after 24 hours. Lines are redacted before they are written, so the file never holds
//! a password, a token, a cookie or the query part of a link.

use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// A log file turns over at this size; with [`FILES`] of them the log is at most 2 MiB.
pub const FILE_BYTES: u64 = 1 << 20;
pub const FILES: usize = 2;
/// How long Everything stays on.
pub const EVERYTHING_SECS: u64 = 24 * 60 * 60;

/// How much is written, as on the phone. Each level writes what the one before it writes, and more.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Level {
    /// What failed, with no file names or content.
    Minimal,
    /// What the server does (the default).
    Standard,
    /// Also names and timings.
    Detailed,
    /// Also content. Goes back after 24 hours.
    Everything,
}

impl Level {
    pub fn name(self) -> &'static str {
        match self {
            Level::Minimal => "minimal",
            Level::Standard => "standard",
            Level::Detailed => "detailed",
            Level::Everything => "everything",
        }
    }

    pub fn parse(s: &str) -> Option<Level> {
        [Level::Minimal, Level::Standard, Level::Detailed, Level::Everything].into_iter().find(|l| l.name() == s)
    }
}

struct State {
    level: Level,
    before: Level,
    /// When Everything ends, in seconds since the epoch.
    until: Option<u64>,
}

pub struct AppLog {
    dir: PathBuf,
    file_bytes: u64,
    state: Mutex<State>,
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl AppLog {
    /// Opens the log in `dir` (made when missing) and reads the level.
    pub fn open(dir: PathBuf) -> AppLog {
        AppLog::with_file_bytes(dir, FILE_BYTES)
    }

    pub fn with_file_bytes(dir: PathBuf, file_bytes: u64) -> AppLog {
        let _ = std::fs::create_dir_all(&dir);
        let mut st = State { level: Level::Standard, before: Level::Standard, until: None };
        if let Some(j) = std::fs::read_to_string(dir.join("level.json")).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
            st.level = j["level"].as_str().and_then(Level::parse).unwrap_or(Level::Standard);
            st.before = j["before"].as_str().and_then(Level::parse).unwrap_or(Level::Standard);
            st.until = j["until"].as_u64();
        }
        AppLog { dir, file_bytes, state: Mutex::new(st) }
    }

    fn file(&self, i: usize) -> PathBuf {
        self.dir.join(if i == 0 { "cache.log".to_string() } else { format!("cache.{i}.log") })
    }

    fn save(&self, st: &State) {
        let j = json!({"level": st.level.name(), "before": st.before.name(), "until": st.until});
        let _ = crate::write_private(&self.dir.join("level.json"), j.to_string().as_bytes());
    }

    /// Everything ends by itself after 24 hours.
    fn expire(&self, st: &mut State) -> bool {
        match st.until {
            Some(u) if st.level == Level::Everything && now_secs() >= u => {
                st.level = st.before;
                st.until = None;
                self.save(st);
                true
            }
            _ => false,
        }
    }

    /// The level now.
    pub fn level(&self) -> Level {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if self.expire(&mut st) {
            self.write_line(&mut st, "LOG", "Log level back after 24 hours of Everything");
        }
        st.level
    }

    /// When Everything ends (seconds since the epoch), null when it is not on.
    pub fn everything_until(&self) -> Option<u64> {
        let st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if st.level == Level::Everything { st.until } else { None }
    }

    /// Sets the level. Everything remembers the level before it.
    pub fn set_level(&self, l: Level) {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if l == Level::Everything && st.level != Level::Everything {
            st.before = st.level;
            st.until = Some(now_secs() + EVERYTHING_SECS);
        } else if l != Level::Everything {
            st.until = None;
        }
        st.level = l;
        self.save(&st);
        self.write_line(&mut st, "LOG", &format!("Log level: {}", l.name()));
    }

    /// A line at `l`: written when the level is at least that.
    pub fn add(&self, l: Level, tag: &str, line: &str) {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        self.expire(&mut st);
        if l <= st.level {
            self.write_line(&mut st, tag, line);
        }
    }

    fn write_line(&self, _st: &mut State, tag: &str, line: &str) {
        let text = format!("{} {} {}\n", crate::library::now_rfc3339(), tag, redact(line).replace('\n', " "));
        let f0 = self.file(0);
        if std::fs::metadata(&f0).map(|m| m.len()).unwrap_or(0) >= self.file_bytes {
            // turn over: the file becomes .1 (the old .1 goes)
            for i in (1..FILES).rev() {
                let _ = std::fs::rename(self.file(i - 1), self.file(i));
            }
        }
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&f0) {
            let _ = f.write_all(text.as_bytes());
        }
    }

    /// The log, oldest line first.
    pub fn text(&self) -> String {
        let _g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = String::new();
        for i in (0..FILES).rev() {
            if let Ok(t) = std::fs::read_to_string(self.file(i)) {
                out.push_str(&t);
            }
        }
        out
    }

    /// The log's size on the disk.
    pub fn bytes(&self) -> u64 {
        (0..FILES).map(|i| std::fs::metadata(self.file(i)).map(|m| m.len()).unwrap_or(0)).sum()
    }

    /// Removes every log line (the level stays) and starts the log again with a line saying so.
    pub fn clear(&self) {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        for i in 0..FILES {
            let _ = std::fs::remove_file(self.file(i));
        }
        self.write_line(&mut st, "LOG", "Log cleared");
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

/// A line with what must never be in a log taken out: the query part of a link (keys and tokens travel there), and the value after
/// `password`, `token`, `secret`, `key`, `cookie` or `authorization` written as `name=value` or `name: value`, and after `Bearer`.
pub fn redact(line: &str) -> String {
    const NAMES: [&str; 6] = ["password", "token", "secret", "key", "cookie", "authorization"];
    let mut out: Vec<String> = Vec::new();
    let mut mask_next = false;
    for word in line.split(' ') {
        let lower = word.to_ascii_lowercase();
        if mask_next {
            // "Authorization: Bearer <token>": the scheme stays, the token goes
            if lower == "bearer" || lower == "basic" {
                out.push(word.into());
            } else {
                out.push("[hidden]".into());
                mask_next = false;
            }
            continue;
        }
        if lower == "bearer" || lower == "basic" {
            out.push(word.into());
            mask_next = true;
            continue;
        }
        if lower.starts_with("http://") || lower.starts_with("https://") {
            out.push(match word.find(['?', '#']) {
                Some(i) => format!("{}?[hidden]", &word[..i]),
                None => word.into(),
            });
            continue;
        }
        // name=value or name:value
        if let Some(i) = word.find(['=', ':']) {
            let name = lower[..i].trim_start_matches(['"', '\'', '{', ',']).trim_end_matches(['"', '\'']);
            if NAMES.iter().any(|n| name == *n || name.ends_with(&format!("_{n}")) || name.ends_with(&format!("-{n}"))) {
                let value = &word[i + 1..];
                if value.is_empty() {
                    out.push(word.into());
                    mask_next = true;
                } else {
                    out.push(format!("{}[hidden]", &word[..=i]));
                }
                continue;
            }
        }
        out.push(word.into());
    }
    out.join(" ")
}
