//! Entry points (step 4): the rnsds a person enters, kept in `entry_points.json` in the sync folder beside `identity.key` and shared
//! with every linked device. This module is the list itself: one [`Record`] per entry (or per removal), the merge that makes two
//! devices' lists the same, the hash they compare ([`version`], the `entries_v` of the file list), and the file.
//!
//! A removal is a tombstone: `{id, removed: true, t, dev}`, kept [`TOMBSTONE_MS`] and at most [`MAX_TOMBSTONES`], so a device that was
//! away learns of it. The newest `t` wins per id; on the same `t` the greater device id wins, as for a link's copy.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::path::Path;

/// The file's name in the sync folder.
pub const FILE: &str = "entry_points.json";
/// A removal is kept this long (60 days).
pub const TOMBSTONE_MS: u64 = 60 * 24 * 60 * 60 * 1000;
/// At most this many removals are kept (the newest).
pub const MAX_TOMBSTONES: usize = 500;
/// The file cap an entry starts with: 50 MB.
pub const DEFAULT_CAP_BYTES: u64 = 50 * 1024 * 1024;

fn yes() -> bool {
    true
}
fn no(b: &bool) -> bool {
    !*b
}
fn zero(n: &u16) -> bool {
    *n == 0
}
fn cap() -> u64 {
    DEFAULT_CAP_BYTES
}

/// One entry point, or the removal of one.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    /// 16 random bytes in hex: the key every change is matched by.
    pub id: String,
    /// A removal: only `id`, `t` and `dev` mean anything.
    #[serde(default, skip_serializing_if = "no")]
    pub removed: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub host: String,
    #[serde(default, skip_serializing_if = "zero")]
    pub port: u16,
    /// A private rnsd (IFAC): it has a network name or a passphrase.
    #[serde(default, skip_serializing_if = "no")]
    pub private: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub passphrase: Option<String>,
    /// Switched on. Off keeps the settings but is not connected.
    #[serde(default = "yes")]
    pub on: bool,
    /// The biggest file that goes through this entry point.
    #[serde(default = "cap")]
    pub cap_bytes: u64,
    /// When it was last changed, in ms since the Unix epoch.
    #[serde(default)]
    pub t: u64,
    /// The device that made that change (its id).
    #[serde(default)]
    pub dev: String,
}

impl std::fmt::Debug for Record {
    // Never the passphrase.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Record")
            .field("id", &self.id)
            .field("removed", &self.removed)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("on", &self.on)
            .field("has_passphrase", &self.passphrase.as_ref().is_some_and(|p| !p.is_empty()))
            .field("t", &self.t)
            .field("dev", &self.dev)
            .finish()
    }
}

impl Record {
    /// An entry that is on, with no network name or passphrase and the default cap.
    pub fn entry(id: &str, host: &str, port: u16, t: u64, dev: &str) -> Record {
        Record {
            id: id.into(),
            removed: false,
            host: host.into(),
            port,
            private: false,
            network_name: None,
            passphrase: None,
            on: true,
            cap_bytes: DEFAULT_CAP_BYTES,
            t,
            dev: dev.into(),
        }
    }

    /// The removal of the entry `id`.
    pub fn tombstone(id: &str, t: u64, dev: &str) -> Record {
        Record { id: id.into(), removed: true, host: String::new(), port: 0, private: false, network_name: None, passphrase: None, on: false, cap_bytes: 0, t, dev: dev.into() }
    }

    /// A removal carries nothing of the entry; an entry carries no empty name or passphrase. The same facts always look the same.
    fn normalized(mut self) -> Record {
        if self.removed {
            return Record::tombstone(&self.id, self.t, &self.dev);
        }
        self.network_name = self.network_name.filter(|n| !n.is_empty());
        self.passphrase = self.passphrase.filter(|p| !p.is_empty());
        self
    }

    /// What the node and the engine's start take of it (an entry, not a removal).
    pub fn point(&self) -> EntryPoint {
        EntryPoint { id: self.id.clone(), host: self.host.clone(), port: self.port, network_name: self.network_name.clone(), passphrase: self.passphrase.clone(), on: self.on, cap_bytes: self.cap_bytes }
    }

    /// The facts that decide a tie: the same moment from the same device with different contents still has one answer.
    fn tie_key(&self) -> Vec<u8> {
        encode(self)
    }
}

/// An entry point as the network is given it: where to connect and how it is keyed. Also what a test says in
/// `Config::rns_interfaces.entries` (no cap, no time).
#[derive(Clone, Deserialize)]
pub struct EntryPoint {
    #[serde(default)]
    pub id: String,
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub network_name: Option<String>,
    #[serde(default)]
    pub passphrase: Option<String>,
    #[serde(default = "yes")]
    pub on: bool,
    /// The most a file may be to go through this entry point (bytes).
    #[serde(default = "cap")]
    pub cap_bytes: u64,
}

impl std::fmt::Debug for EntryPoint {
    // Never the passphrase: this is what a log line or a failed assert prints.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EntryPoint")
            .field("id", &self.id)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("network_name", &self.network_name)
            .field("has_passphrase", &self.passphrase.as_ref().is_some_and(|p| !p.is_empty()))
            .field("on", &self.on)
            .field("cap_bytes", &self.cap_bytes)
            .finish()
    }
}

fn put(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u64).to_le_bytes());
    out.extend_from_slice(b);
}

/// One record in a fixed form (every field, length-prefixed), for hashing and for ties; independent of the JSON field order.
fn encode(r: &Record) -> Vec<u8> {
    let mut o = Vec::new();
    put(&mut o, r.id.as_bytes());
    o.push(r.removed as u8);
    put(&mut o, r.host.as_bytes());
    put(&mut o, &r.port.to_le_bytes());
    o.push(r.private as u8);
    put(&mut o, r.network_name.as_deref().unwrap_or("").as_bytes());
    put(&mut o, r.passphrase.as_deref().unwrap_or("").as_bytes());
    o.push(r.on as u8);
    put(&mut o, &r.cap_bytes.to_le_bytes());
    put(&mut o, &r.t.to_le_bytes());
    put(&mut o, r.dev.as_bytes());
    o
}

/// Whether `theirs` replaces `mine` (the same id): the later `t`; on the same `t` the greater device id; then, so both devices still
/// agree, a removal over an entry, then the greater contents.
fn replaces(mine: &Record, theirs: &Record) -> bool {
    let order = (theirs.t, &theirs.dev, theirs.removed).cmp(&(mine.t, &mine.dev, mine.removed));
    match order {
        Ordering::Greater => true,
        Ordering::Less => false,
        Ordering::Equal => theirs.tie_key() > mine.tie_key(),
    }
}

/// Forgets removals past [`TOMBSTONE_MS`] (against `now`) and all but the newest [`MAX_TOMBSTONES`], and puts the list in order.
fn tidy(mut list: Vec<Record>, now: u64) -> Vec<Record> {
    list.retain(|r| !r.removed || now.saturating_sub(r.t) <= TOMBSTONE_MS);
    let mut tombs: Vec<(u64, String)> = list.iter().filter(|r| r.removed).map(|r| (r.t, r.id.clone())).collect();
    if tombs.len() > MAX_TOMBSTONES {
        // Newest first; ties by id so every device keeps the same ones.
        tombs.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        let drop: std::collections::HashSet<String> = tombs[MAX_TOMBSTONES..].iter().map(|t| t.1.clone()).collect();
        list.retain(|r| !(r.removed && drop.contains(&r.id)));
    }
    list.sort_by(|a, b| a.id.cmp(&b.id));
    list
}

/// The two lists as one: per id the winner, removals past their time forgotten. The same list whichever device does it.
pub fn merge(mine: &[Record], theirs: &[Record], now: u64) -> Vec<Record> {
    let mut by_id: std::collections::HashMap<String, Record> = std::collections::HashMap::new();
    for r in mine.iter().chain(theirs.iter()).cloned().map(Record::normalized) {
        match by_id.get(&r.id) {
            Some(have) if !replaces(have, &r) => {}
            _ => {
                by_id.insert(r.id.clone(), r);
            }
        }
    }
    dedupe(&mut by_id);
    tidy(by_id.into_values().collect(), now)
}

/// One live entry per address. Two devices that each enter the same host and port (any letter case of the host) while apart make two
/// ids for one rnsd; of such entries the newer `t` stays, on the same `t` the greater device id, then the greater id. Every other
/// becomes a removal that carries the WINNER's `t` and device: it is then the same record on every device whichever makes it, so the
/// lists and their `entries_v` end equal with nothing to send back, and it is never older than the entry it replaces (the same or a
/// later `t`; on the same `t` the winner's device is not the lesser; on both the same, a removal beats an entry), so it replaces that
/// entry wherever it is still held. A made-up time such as now would differ by device and never settle.
fn dedupe(by_id: &mut std::collections::HashMap<String, Record>) {
    let mut groups: std::collections::HashMap<(String, u16), Vec<&Record>> = std::collections::HashMap::new();
    for r in by_id.values().filter(|r| !r.removed) {
        groups.entry((r.host.to_lowercase(), r.port)).or_default().push(r);
    }
    let mut lost: Vec<Record> = Vec::new();
    for group in groups.into_values().filter(|g| g.len() > 1) {
        let winner = group.iter().copied().max_by(|a, b| (a.t, &a.dev, &a.id).cmp(&(b.t, &b.dev, &b.id))).expect("a group has a member");
        for r in group.iter().filter(|r| r.id != winner.id) {
            lost.push(Record::tombstone(&r.id, winner.t, &winner.dev));
        }
    }
    for t in lost {
        by_id.insert(t.id.clone(), t);
    }
}

/// A list as a device holds it: normalised, removals past their time forgotten, in order.
pub fn tidied(list: Vec<Record>, now: u64) -> Vec<Record> {
    merge(&list, &[], now)
}

/// The `entries_v` of a list: a BLAKE3 hash of every record, removals included, in the order of their ids (hex). It says nothing of
/// what the records hold.
pub fn version(list: &[Record]) -> String {
    let mut sorted: Vec<&Record> = list.iter().collect();
    sorted.sort_by(|a, b| a.id.cmp(&b.id));
    let mut h = blake3::Hasher::new();
    h.update(b"cache entry points v1");
    h.update(&(sorted.len() as u64).to_le_bytes());
    for r in sorted {
        h.update(&encode(r));
    }
    h.finalize().to_hex().to_string()
}

/// A fresh id: 16 random bytes in hex.
pub fn new_id() -> String {
    let b: [u8; 16] = rand::Rng::random(&mut rand::rng());
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Whether `id` could be one: 32 hex characters (what is taken from another device is checked, not trusted).
pub fn id_ok(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|c| c.is_ascii_hexdigit())
}

/// Why an entry may not be saved, in words for the person. `Ok` when it may.
pub fn validate(host: &str, port: u32, private: bool, network_name: Option<&str>, passphrase: Option<&str>) -> Result<(), String> {
    if host.trim().is_empty() {
        return Err("Enter the address of the entry point.".into());
    }
    if host.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("The address cannot have spaces in it.".into());
    }
    if !(1..=65535).contains(&port) {
        return Err("The port has to be a number from 1 to 65535.".into());
    }
    let has = |v: Option<&str>| v.is_some_and(|s| !s.is_empty());
    if private && !has(network_name) && !has(passphrase) {
        return Err("A private entry point needs a network name or a passphrase.".into());
    }
    Ok(())
}

/// Reads the file: the records it holds, normalised. A missing file is an empty list; one that cannot be parsed is moved aside
/// (to `entry_points.bad`, never deleted) and the list starts empty.
pub fn load(dir: &Path) -> Vec<Record> {
    let p = dir.join(FILE);
    let Ok(bytes) = std::fs::read(&p) else { return Vec::new() };
    match serde_json::from_slice::<Vec<Record>>(&bytes) {
        Ok(v) => v.into_iter().filter(|r| id_ok(&r.id)).map(Record::normalized).collect(),
        Err(_) => {
            let _ = std::fs::rename(&p, dir.join("entry_points.bad"));
            Vec::new()
        }
    }
}

/// Writes the file through a temporary one and a rename (owner-only on Unix: it holds passphrases).
pub fn save(dir: &Path, list: &[Record]) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join("entry_points.tmp");
    std::fs::write(&tmp, serde_json::to_vec(list)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, dir.join(FILE))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_prints_without_its_passphrase() {
        let mut r = Record::entry("aa", "h", 1, 1, "d");
        r.passphrase = Some("sekret-in-debug".into());
        assert!(!format!("{r:?}").contains("sekret-in-debug"));
    }

    #[test]
    fn a_removal_writes_only_what_it_is() {
        let v = serde_json::to_value(Record::tombstone("aa", 5, "d")).unwrap();
        let keys: std::collections::BTreeSet<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        // `on` and `cap_bytes` are written (a reader that wants them has them); nothing of an address or a passphrase is.
        assert!(keys.contains("removed") && !keys.contains("host") && !keys.contains("passphrase") && !keys.contains("network_name"));
    }

    #[test]
    fn a_removal_read_with_extra_fields_is_a_plain_removal() {
        let r: Record = serde_json::from_str(r#"{"id":"aa","removed":true,"t":3,"dev":"d","host":"x","passphrase":"p"}"#).unwrap();
        assert_eq!(r.normalized(), Record::tombstone("aa", 3, "d"));
    }
}
