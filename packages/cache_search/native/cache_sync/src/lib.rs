//! Sharing and sync between Cache devices, peer to peer over iroh.
//!
//! A device has an identity (an iroh key pair kept in its sync folder). Two devices link once: one shows a link code (a QR code in
//! the app), the other reads it, and from then on each knows the other's key; connections from any key that is not linked are
//! refused before any protocol runs. A device shares folders; a linked device sees them offered and joins the ones it wants into a
//! folder of its own. From then on the two keep that folder the same: each sends the other its index (file, hash, size, version)
//! and fetches what is newer, as BLAKE3-verified chunks (iroh-blobs), from every linked device that has it, so a third device
//! adds a third source. An interrupted transfer resumes from the verified chunks already stored. Files are kept in place (the store
//! references them rather than copying), so sharing a folder does not double its size.
//!
//! Devices find each other on the local network (mDNS), through the Mainline DHT, and through n0's lookup service; traffic goes
//! direct where it can (hole punching) and through a relay where it cannot. Relays and lookups see keys and addresses, never
//! content (everything is end-to-end encrypted by QUIC). Each of these can be switched off or pointed at one's own servers.
//!
//! The engine runs on its own Tokio runtime; [`SyncEngine::call`] is the whole interface (JSON in, JSON out), the same one the C
//! ABI (`cs_sync_*` in cache_search) and the `cache-sync` desktop binary use.

pub mod index;

use anyhow::{anyhow, bail, Context, Result};
use index::{Action, Entry, Index, Ver};
use iroh::{
    endpoint::{presets, AfterHandshakeOutcome, Connection, EndpointHooks, VarInt},
    protocol::{AcceptError, ProtocolHandler, Router},
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey,
};
use iroh_blobs::{
    api::{
        blobs::{AddPathOptions, ExportMode, ExportOptions, ImportMode},
        downloader::{DownloadOptions, DownloadProgressItem, Shuffled, SplitStrategy},
    },
    store::{
        fs::{options::Options as StoreOptions, FsStore},
        GcConfig, ProtectOutcome,
    },
    BlobFormat, BlobsProtocol, Hash, HashAndFormat,
};
use n0_future::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, RwLock,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::Notify;

/// Linking: open to any key, but only with the one-time code a device is showing.
pub const PAIR_ALPN: &[u8] = b"cache/pair/1";
/// The index exchange between linked devices.
pub const SYNC_ALPN: &[u8] = b"cache/sync/1";

/// A transfer with no new data for this long is dropped and retried in the next round (from its verified chunks).
const STALL: Duration = Duration::from_secs(20);
/// A file changed less than this long ago is still being written and waits for a later round.
const SETTLE: Duration = Duration::from_secs(5);
/// How long a shown link code stays valid.
const LINK_WINDOW: Duration = Duration::from_secs(15 * 60);
/// An index larger than this is refused (about a million files).
const MAX_INDEX: usize = 256 * 1024 * 1024;

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn t<T>() -> bool {
    true
}

/// The `cs_sync_open` config.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// Where the identity, the store and the indexes live (the app's private storage).
    pub dir: PathBuf,
    /// The name other devices see (the app passes the device's name until the person changes it).
    #[serde(default)]
    pub name: Option<String>,
    /// Find devices on the local network.
    #[serde(default = "t::<()>")]
    pub mdns: bool,
    /// Publish to and look up in the Mainline DHT.
    #[serde(default = "t::<()>")]
    pub dht: bool,
    /// Publish to and look up in a lookup service: n0's by default, or `lookup_url` (an iroh-dns-server).
    #[serde(default = "t::<()>")]
    pub lookup: bool,
    #[serde(default)]
    pub lookup_url: Option<String>,
    /// Relays: n0's public ones by default, the listed ones instead when given, none when `relay` is false.
    #[serde(default = "t::<()>")]
    pub relay: bool,
    #[serde(default)]
    pub relay_urls: Vec<String>,
    /// Never fill the disk past this many free bytes; transfers pause with the reason instead.
    #[serde(default)]
    pub reserve_bytes: Option<u64>,
    /// Seconds between sync rounds (a change or Sync now starts one at once).
    #[serde(default)]
    pub interval_secs: Option<u64>,
    /// Bind to this port (tests and fixed firewall rules); 0 or absent picks one.
    #[serde(default)]
    pub port: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Peer {
    id: String,
    name: String,
    linked: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Share {
    id: String,
    name: String,
    path: PathBuf,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Saved {
    name: String,
    #[serde(default)]
    peers: Vec<Peer>,
    #[serde(default)]
    shares: Vec<Share>,
}

/// Local-only facts about a file in a shared folder: the size and modification time it had when it was last hashed.
type Seen = BTreeMap<String, (u64, i64)>;

/// Files this device is writing into a shared folder, by path, recorded before the first byte goes in. Copying a finished file
/// into place is not instant (on a phone the store and the shared folders are on different file systems, so a big file takes
/// seconds), and if Cache is stopped meanwhile the next start finds a half-written file here: it is replaced, never taken for an
/// edit and sent to the other devices. While a path is listed, its file being missing is not a delete either.
type Writes = BTreeMap<String, Entry>;

/// What [`Inner::relocate`] calls the original while the store hands the same content back.
const ASIDE_SUFFIX: &str = ".cache-sync-old";

/// One shared folder as a peer describes it.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RemoteShare {
    id: String,
    name: String,
    index: Index,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RemoteIndex {
    name: String,
    shares: Vec<RemoteShare>,
}

#[derive(Debug, Clone, Default)]
struct PeerState {
    last_seen: Option<u64>,
    via: Option<String>,
    error: Option<String>,
    index: Option<RemoteIndex>,
}

#[derive(Debug, Clone, Serialize)]
struct Transfer {
    share: String,
    path: String,
    size: u64,
    done: u64,
    from: Vec<String>,
}

#[derive(Default)]
struct Run {
    peers: HashMap<String, PeerState>,
    transfer: Option<Transfer>,
    paused: Option<String>,
    log: Vec<(u64, String)>,
    rounds: u64,
    last_round: Option<u64>,
}

impl Run {
    fn note(&mut self, msg: impl Into<String>) {
        self.log.push((now_ms(), msg.into()));
        if self.log.len() > 200 {
            self.log.drain(..self.log.len() - 200);
        }
    }
}

/// Refuses every connection from a key that is not linked, except on the linking protocol (which wants the one-time code).
#[derive(Debug)]
struct Gate {
    allowed: Arc<RwLock<HashSet<EndpointId>>>,
}

impl EndpointHooks for Gate {
    async fn after_handshake<'a>(&'a self, conn: &'a Connection) -> AfterHandshakeOutcome {
        if conn.alpn() == PAIR_ALPN || self.allowed.read().map(|a| a.contains(&conn.remote_id())).unwrap_or(false) {
            AfterHandshakeOutcome::accept()
        } else {
            AfterHandshakeOutcome::Reject { error_code: VarInt::from_u32(403), reason: b"not linked".to_vec() }
        }
    }
}

struct Inner {
    dir: PathBuf,
    me: String,
    endpoint: Endpoint,
    store: FsStore,
    saved: Mutex<Saved>,
    allowed: Arc<RwLock<HashSet<EndpointId>>>,
    /// The code being shown, and until when.
    pairing: Mutex<Option<(String, Instant)>>,
    run: Mutex<Run>,
    /// Hashes being fetched or about to be: kept from garbage collection so an interrupted transfer resumes.
    wanted: Arc<Mutex<HashSet<Hash>>>,
    wake: Notify,
    network: AtomicBool,
    reserve: AtomicU64,
    round: tokio::sync::Mutex<()>,
    stop: AtomicBool,
    /// A rescan left a file that was still being written: the next round comes after [`SETTLE`], not the full interval.
    settle_again: Arc<AtomicBool>,
    /// The first round has put right what an interrupted write left (see [`Writes`]).
    recovered: AtomicBool,
}

pub struct SyncEngine {
    rt: tokio::runtime::Runtime,
    inner: Arc<Inner>,
    router: Option<Router>,
}

/// The code a device shows for linking: its address, a one-time token, and its name.
#[derive(Debug, Serialize, Deserialize)]
struct LinkCode {
    a: EndpointAddr,
    t: String,
    n: String,
}

const CODE_PREFIX: &str = "CACHE1-";

fn encode_code(c: &LinkCode) -> Result<String> {
    Ok(format!("{CODE_PREFIX}{}", data_encoding::BASE32_NOPAD.encode(&serde_json::to_vec(c)?)))
}

fn decode_code(s: &str) -> Result<LinkCode> {
    let s: String = s.trim().chars().filter(|c| !c.is_whitespace()).collect::<String>().to_uppercase();
    let body = s.strip_prefix(CODE_PREFIX).ok_or_else(|| anyhow!("this is not a Cache link code"))?;
    let bytes = data_encoding::BASE32_NOPAD.decode(body.as_bytes()).map_err(|_| anyhow!("the link code is damaged"))?;
    serde_json::from_slice(&bytes).map_err(|_| anyhow!("the link code is damaged"))
}

fn token() -> String {
    use rand::Rng;
    let b: [u8; 16] = rand::rng().random();
    data_encoding::BASE32_NOPAD.encode(&b)
}

fn rel_path(root: &Path, p: &Path) -> Option<String> {
    let r = p.strip_prefix(root).ok()?;
    let parts: Vec<String> = r.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    if parts.iter().any(|c| c.starts_with('.')) {
        return None;
    }
    Some(parts.join("/"))
}

/// A path from a peer, made safe to join under a shared folder (no parent steps, no absolute paths, no hidden parts).
fn safe_join(root: &Path, rel: &str) -> Option<PathBuf> {
    let mut p = root.to_path_buf();
    for c in rel.split('/') {
        if c.is_empty() || c == "." || c == ".." || c.starts_with('.') || c.contains('\\') || c.contains(':') {
            return None;
        }
        p.push(c);
    }
    Some(p)
}

fn mtime_ms(m: &std::fs::Metadata) -> i64 {
    m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf, std::fs::Metadata)>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(m) = std::fs::symlink_metadata(&p) else { continue };
        if m.file_type().is_symlink() {
            continue;
        }
        let Some(rel) = rel_path(root, &p) else { continue };
        if m.is_dir() {
            walk(root, &p, out);
        } else if m.is_file() {
            out.push((rel, p, m));
        }
    }
}

/// The originals [`Inner::relocate`] left renamed aside under `dir` (hidden files, which [`walk`] skips).
fn find_asides(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(m) = std::fs::symlink_metadata(&p) else { continue };
        let name = e.file_name().to_string_lossy().into_owned();
        if m.is_dir() && !name.starts_with('.') {
            find_asides(&p, out);
        } else if m.is_file() && name.starts_with('.') && name.ends_with(ASIDE_SUFFIX) {
            out.push(p);
        }
    }
}

/// Folders a delete left empty go too, up to (not including) the shared folder itself.
fn prune_empty(root: &Path, removed: &Path) {
    let mut d = removed.parent();
    while let Some(dir) = d {
        if dir == root || !dir.starts_with(root) || std::fs::remove_dir(dir).is_err() {
            break;
        }
        d = dir.parent();
    }
}

/// The BLAKE3 hash of a file's content, as the store names it.
fn hash_file(p: &Path) -> std::io::Result<String> {
    let mut h = blake3::Hasher::new();
    h.update_reader(std::fs::File::open(p)?)?;
    Ok(Hash::from(h.finalize()).to_hex().to_string())
}

fn human(n: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", U[i])
    }
}

impl Inner {
    fn saved_path(&self) -> PathBuf {
        self.dir.join("sync.json")
    }

    fn index_path(&self, share: &str) -> PathBuf {
        self.dir.join("index").join(format!("{share}.json"))
    }

    fn seen_path(&self, share: &str) -> PathBuf {
        self.dir.join("index").join(format!("{share}.seen.json"))
    }

    fn save(&self) -> Result<()> {
        let s = self.saved.lock().unwrap().clone();
        write_json(&self.saved_path(), &s)
    }

    fn load_index(&self, share: &str) -> Index {
        read_json(&self.index_path(share)).unwrap_or_default()
    }

    fn load_seen(&self, share: &str) -> Seen {
        read_json(&self.seen_path(share)).unwrap_or_default()
    }

    fn store_index(&self, share: &str, idx: &Index, seen: &Seen) -> Result<()> {
        write_json(&self.index_path(share), idx)?;
        write_json(&self.seen_path(share), seen)
    }

    fn writes_path(&self, share: &str) -> PathBuf {
        self.dir.join("index").join(format!("{share}.writing.json"))
    }

    fn load_writes(&self, share: &str) -> Writes {
        read_json(&self.writes_path(share)).unwrap_or_default()
    }

    fn store_writes(&self, share: &str, w: &Writes) -> Result<()> {
        if w.is_empty() {
            let _ = std::fs::remove_file(self.writes_path(share));
            return Ok(());
        }
        write_json(&self.writes_path(share), w)
    }

    fn mark_writing(&self, share: &str, path: &str, entry: &Entry) -> Result<()> {
        let mut w = self.load_writes(share);
        w.insert(path.to_string(), entry.clone());
        self.store_writes(share, &w)
    }

    fn unmark_writing(&self, share: &str, path: &str) -> Result<()> {
        let mut w = self.load_writes(share);
        if w.remove(path).is_some() {
            self.store_writes(share, &w)?;
        }
        Ok(())
    }

    /// A file now whole at `full`: the store keeps it under its name, the index takes `entry`, and it is no longer being written.
    async fn written(&self, sh: &Share, path: &str, full: &Path, entry: Entry) -> Result<()> {
        let hash: Hash = entry.hash.parse().map_err(|_| anyhow!("bad hash for {path}"))?;
        self.store.tags().set(Self::tag_name(&sh.id, path).as_bytes(), HashAndFormat::raw(hash)).await.map_err(|e| anyhow!("{e}"))?;
        let mut idx = self.load_index(&sh.id);
        let mut seen = self.load_seen(&sh.id);
        let m = std::fs::metadata(full)?;
        seen.insert(path.to_string(), (m.len(), mtime_ms(&m)));
        idx.files.insert(path.to_string(), entry);
        self.store_index(&sh.id, &idx, &seen)?;
        self.unmark_writing(&sh.id, path)
    }

    /// After a start, before anything scans a shared folder: puts right what a write that was cut off left there.
    async fn recover(&self, sh: &Share) {
        if !sh.path.is_dir() {
            return;
        }
        // An original renamed aside by `relocate`: it goes back, over whatever part of the copy got written.
        let root = sh.path.clone();
        let asides = tokio::task::spawn_blocking(move || {
            let mut v = Vec::new();
            find_asides(&root, &mut v);
            v
        })
        .await
        .unwrap_or_default();
        let mut again = Vec::new();
        for aside in asides {
            let Some(name) = aside.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_prefix('.')).and_then(|n| n.strip_suffix(ASIDE_SUFFIX)) else {
                continue;
            };
            let target = aside.with_file_name(name);
            let _ = std::fs::remove_file(&target);
            match std::fs::rename(&aside, &target) {
                Ok(()) => {
                    if let Some(rel) = rel_path(&sh.path, &target) {
                        if let Some(e) = self.load_index(&sh.id).files.get(&rel).filter(|e| !e.deleted) {
                            again.push(e.hash.clone());
                        }
                    }
                }
                Err(e) => self.note(format!("{}: could not put back {}: {e}", sh.name, target.display())),
            }
        }
        // The store may still hold a copy of what was put back: handing it over again drops that copy.
        for h in again {
            self.repoint(&h, None).await;
        }
        // A file being fetched: kept if it is whole, else replaced from the store, or left for the next fetch.
        for (path, entry) in self.load_writes(&sh.id) {
            let Some(full) = safe_join(&sh.path, &path) else {
                let _ = self.unmark_writing(&sh.id, &path);
                continue;
            };
            let f2 = full.clone();
            let want = entry.hash.clone();
            let size = entry.size;
            let whole = tokio::task::spawn_blocking(move || {
                std::fs::metadata(&f2).map(|m| m.len() == size).unwrap_or(false) && hash_file(&f2).map(|h| h == want).unwrap_or(false)
            })
            .await
            .unwrap_or(false);
            if whole {
                if let Err(e) = self.written(sh, &path, &full, entry.clone()).await {
                    self.note(format!("{}: {path}: {e:#}", sh.name));
                }
                self.repoint(&entry.hash, None).await;
                continue;
            }
            if full.exists() {
                if let Err(e) = std::fs::remove_file(&full) {
                    self.note(format!("{}: could not remove the half-written {path}: {e}", sh.name));
                    continue;
                }
            }
            let Ok(hash) = entry.hash.parse::<Hash>() else { continue };
            let have = self.store.blobs().status(hash).await.map(|s| matches!(s, iroh_blobs::api::proto::BlobStatus::Complete { .. })).unwrap_or(false);
            let put = have
                && self.store.export_with_opts(ExportOptions { hash, mode: ExportMode::TryReference, target: full.clone() }).finish().await.is_ok();
            if put {
                let _ = self.written(sh, &path, &full, entry).await;
                self.note(format!("{}: {path} was cut off while being written; written again", sh.name));
            } else {
                let _ = std::fs::remove_file(&full);
                // If the index already names this content as here, it would never be asked for again: forget it, so the next
                // comparison with a device that has it fetches it.
                let mut idx = self.load_index(&sh.id);
                if idx.files.get(&path) == Some(&entry) {
                    let mut seen = self.load_seen(&sh.id);
                    idx.files.remove(&path);
                    seen.remove(&path);
                    let _ = self.store_index(&sh.id, &idx, &seen);
                }
                self.note(format!("{}: {path} was cut off while being written; it comes again with the next sync", sh.name));
            }
        }
    }

    fn note(&self, msg: impl Into<String>) {
        self.run.lock().unwrap().note(msg);
    }

    fn peer_name(&self, id: &str) -> String {
        self.saved.lock().unwrap().peers.iter().find(|p| p.id == id).map(|p| p.name.clone()).unwrap_or_else(|| id[..8.min(id.len())].to_string())
    }

    /// Network use stops the moment the policy says so: before each file and during every transfer, not only between rounds.
    fn may_use_network(&self) -> bool {
        self.network.load(Ordering::Relaxed) && !self.stop.load(Ordering::Relaxed)
    }

    /// Every file on this device (in any shared folder) whose current content is `hash`, by its index.
    fn live_paths(&self, hash: &str) -> Vec<PathBuf> {
        let shares = self.saved.lock().unwrap().shares.clone();
        let mut out = Vec::new();
        for sh in shares {
            for (rel, e) in self.load_index(&sh.id).files {
                if !e.deleted && e.hash == hash {
                    if let Some(p) = safe_join(&sh.path, &rel) {
                        if p.is_file() {
                            out.push(p);
                        }
                    }
                }
            }
        }
        out
    }

    /// The store keeps files in place and reads a hash from the first path it was given. When that file moved, changed or
    /// became a conflict copy while the same content still lives at another path, the store would read the wrong place and
    /// every device asking for it would get data that fails verification. So the content is taken into the store once (owned
    /// data replaces every outside path) and handed back to the live path, which the store then references alone. The file
    /// is briefly stored twice; nothing is lost if a step fails (the original is renamed aside first and put back).
    async fn repoint(&self, hash: &str, except: Option<&Path>) {
        let Some(target) = self.live_paths(hash).into_iter().find(|p| Some(p.as_path()) != except) else { return };
        if let Err(e) = self.relocate(hash, &target).await {
            self.note(format!("could not refresh {}: {e:#}", target.display()));
        }
    }

    async fn relocate(&self, hash: &str, target: &Path) -> Result<()> {
        let h: Hash = hash.parse().map_err(|_| anyhow!("bad hash"))?;
        let added = self
            .store
            .add_path_with_opts(AddPathOptions { path: target.to_path_buf(), format: BlobFormat::Raw, mode: ImportMode::Copy })
            .temp_tag()
            .await
            .map_err(|e| anyhow!("{e}"))?;
        if added.hash() != h {
            bail!("{} changed meanwhile", target.display());
        }
        let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let aside = target.with_file_name(format!(".{name}{ASIDE_SUFFIX}"));
        std::fs::rename(target, &aside)?;
        match self.store.export_with_opts(ExportOptions { hash: h, mode: ExportMode::TryReference, target: target.to_path_buf() }).finish().await {
            Ok(_) => {
                let _ = std::fs::remove_file(&aside);
            }
            Err(e) => {
                let _ = std::fs::remove_file(target);
                std::fs::rename(&aside, target)?;
                bail!("{e}");
            }
        }
        drop(added);
        Ok(())
    }

    fn tag_name(share: &str, path: &str) -> String {
        format!("f/{share}/{path}")
    }

    /// Brings a shared folder's index up to date with what is on disk: new and changed files are hashed (and referenced by the
    /// store, not copied), vanished files become deletes. Returns whether anything changed.
    async fn rescan(&self, share: &Share) -> Result<bool> {
        let mut idx = self.load_index(&share.id);
        let mut seen = self.load_seen(&share.id);
        if !share.path.is_dir() {
            bail!("{} is missing", share.path.display());
        }
        let root = share.path.clone();
        let files = tokio::task::spawn_blocking(move || {
            let mut v = Vec::new();
            walk(&root, &root, &mut v);
            v
        })
        .await?;
        let mut changed = false;
        let mut unsettled = false;
        let mut writes = self.load_writes(&share.id);
        let writes_before = writes.len();
        // Content whose file here moved, changed or went: if it lives on at another path, the store must read it from there.
        let mut stale: Vec<String> = Vec::new();
        let mut present = HashSet::new();
        for (rel, full, m) in files {
            present.insert(rel.clone());
            // After the start-up recovery a file at a path still waiting to be written is a new one put there by someone.
            writes.remove(&rel);
            let key = (m.len(), mtime_ms(&m));
            if seen.get(&rel) == Some(&key) && idx.files.get(&rel).map(|e| !e.deleted).unwrap_or(false) {
                continue;
            }
            // Still being written (a copy or a download in progress): left for a later round, so half a file never goes out.
            if (now_ms() as i64).saturating_sub(key.1) < SETTLE.as_millis() as i64 {
                unsettled = true;
                continue;
            }
            let tag = Self::tag_name(&share.id, &rel);
            let added = self
                .store
                .add_path_with_opts(AddPathOptions { path: full.clone(), format: BlobFormat::Raw, mode: ImportMode::TryReference })
                .with_named_tag(tag.as_bytes())
                .await
                .map_err(|e| anyhow!("could not read {}: {e}", full.display()))?;
            let hash = added.hash.to_hex().to_string();
            let entry = match idx.files.get(&rel) {
                Some(old) if !old.deleted && old.hash == hash => None,
                Some(old) => {
                    if !old.deleted {
                        stale.push(old.hash.clone());
                    }
                    Some(old.next(&self.me, now_ms(), hash, m.len(), false))
                }
                None => Some(Entry { hash, size: m.len(), deleted: false, ver: Ver { at: now_ms(), by: self.me.clone() }, hist: vec![] }),
            };
            if let Some(e) = entry {
                idx.files.insert(rel.clone(), e);
                changed = true;
            }
            seen.insert(rel, key);
        }
        // A file still waiting to be written (cut off, to come again) has not gone.
        let gone: Vec<String> =
            idx.files.iter().filter(|(p, e)| !e.deleted && !present.contains(*p) && !writes.contains_key(*p)).map(|(p, _)| p.clone()).collect();
        for p in gone {
            let old = idx.files[&p].clone();
            stale.push(old.hash.clone());
            idx.files.insert(p.clone(), old.next(&self.me, now_ms(), old.hash.clone(), old.size, true));
            seen.remove(&p);
            let _ = self.store.tags().delete(Self::tag_name(&share.id, &p).as_bytes()).await;
            changed = true;
        }
        self.store_index(&share.id, &idx, &seen)?;
        if writes.len() != writes_before {
            self.store_writes(&share.id, &writes)?;
        }
        for h in stale {
            self.repoint(&h, None).await;
        }
        if unsettled {
            // Look again soon rather than at the next full interval.
            self.settle_again.store(true, Ordering::Relaxed);
        }
        Ok(changed)
    }

    fn our_index(&self) -> RemoteIndex {
        let s = self.saved.lock().unwrap().clone();
        RemoteIndex {
            name: s.name.clone(),
            shares: s.shares.iter().map(|sh| RemoteShare { id: sh.id.clone(), name: sh.name.clone(), index: self.load_index(&sh.id) }).collect(),
        }
    }

    fn free_bytes(path: &Path) -> Option<u64> {
        let mut p = path.to_path_buf();
        while !p.exists() {
            if !p.pop() {
                return None;
            }
        }
        Self::volume_free(&p)
    }

    /// Free bytes on the volume holding the existing path `p` (fs4, statvfs on unix).
    #[cfg(not(target_os = "ios"))]
    fn volume_free(p: &Path) -> Option<u64> {
        fs4::available_space(p).ok()
    }

    /// iPhone: the app's `cache_free_bytes_on_disk` (same binary), which counts the space iOS can purge as iPhone Storage in
    /// Settings does; statvfs leaves it out.
    #[cfg(target_os = "ios")]
    fn volume_free(p: &Path) -> Option<u64> {
        use std::os::unix::ffi::OsStrExt;
        extern "C" {
            fn cache_free_bytes_on_disk(path: *const std::ffi::c_char) -> i64;
        }
        let c = std::ffi::CString::new(p.as_os_str().as_bytes()).ok()?;
        // SAFETY: `c` is a valid NUL-terminated path; the helper only reads it.
        u64::try_from(unsafe { cache_free_bytes_on_disk(c.as_ptr()) }).ok()
    }

    /// One round: rescan every shared folder, then for every linked device fetch its index and apply what is newer there.
    async fn round(self: &Arc<Self>) {
        let _one = self.round.lock().await;
        let shares = self.saved.lock().unwrap().shares.clone();
        if !self.recovered.swap(true, Ordering::Relaxed) {
            for sh in &shares {
                self.recover(sh).await;
            }
        }
        for sh in &shares {
            if let Err(e) = self.rescan(sh).await {
                self.note(format!("{}: {e}", sh.name));
            }
        }
        if !self.network.load(Ordering::Relaxed) {
            self.run.lock().unwrap().paused = Some("Sync is paused: no network it may use".into());
            return;
        }
        let peers = self.saved.lock().unwrap().peers.clone();
        // First every reachable peer's index, so each file can be fetched from every peer that has it.
        for p in &peers {
            if !self.may_use_network() {
                break;
            }
            let res = self.fetch_index(&p.id).await;
            let mut run = self.run.lock().unwrap();
            let st = run.peers.entry(p.id.clone()).or_default();
            match res {
                Ok((idx, via)) => {
                    st.last_seen = Some(now_ms());
                    st.via = Some(via);
                    st.error = None;
                    st.index = Some(idx);
                }
                Err(e) => {
                    st.via = None;
                    st.error = Some(format!("{e:#}"));
                }
            }
        }
        let mut paused = None;
        for p in &peers {
            let Some(remote) = self.run.lock().unwrap().peers.get(&p.id).filter(|s| s.error.is_none()).and_then(|s| s.index.clone()) else {
                continue;
            };
            for rs in &remote.shares {
                let Some(sh) = shares.iter().find(|s| s.id == rs.id) else { continue };
                match self.apply(sh, &rs.index, &p.id).await {
                    Ok(()) => {}
                    Err(e) => {
                        let msg = format!("{e:#}");
                        if msg.starts_with("Paused:") || msg.contains("paused, no network") {
                            paused = Some(msg);
                        } else {
                            self.note(format!("{} from {}: {msg}", sh.name, p.name));
                        }
                    }
                }
            }
        }
        let mut run = self.run.lock().unwrap();
        run.paused = if self.network.load(Ordering::Relaxed) { paused } else { Some("Sync is paused: no network it may use".into()) };
        run.rounds += 1;
        run.last_round = Some(now_ms());
    }

    async fn fetch_index(&self, peer: &str) -> Result<(RemoteIndex, String)> {
        let id: EndpointId = peer.parse().map_err(|_| anyhow!("bad device key"))?;
        let conn = tokio::time::timeout(Duration::from_secs(30), self.endpoint.connect(id, SYNC_ALPN))
            .await
            .map_err(|_| anyhow!("not reachable"))?
            .map_err(|e| anyhow!("not reachable: {e}"))?;
        let via = conn.paths().iter().find(|p| p.is_selected()).map(|p| if p.is_relay() { "relay" } else { "direct" }).unwrap_or("direct").to_string();
        let (mut send, mut recv) = conn.open_bi().await.map_err(|e| anyhow!("{e}"))?;
        send.write_all(b"index").await.map_err(|e| anyhow!("{e}"))?;
        send.finish().map_err(|e| anyhow!("{e}"))?;
        let bytes = tokio::time::timeout(Duration::from_secs(120), recv.read_to_end(MAX_INDEX))
            .await
            .map_err(|_| anyhow!("timed out reading the file list"))?
            .map_err(|e| anyhow!("{e}"))?;
        conn.close(0u32.into(), b"done");
        Ok((serde_json::from_slice(&bytes).context("the file list from the device is not valid")?, via))
    }

    /// Who has `hash` (by their last index), us excluded.
    fn providers(&self, hash: &str) -> Vec<EndpointId> {
        let run = self.run.lock().unwrap();
        run.peers
            .iter()
            .filter(|(_, s)| s.error.is_none())
            .filter(|(_, s)| s.index.as_ref().map(|i| i.shares.iter().any(|sh| sh.index.files.values().any(|e| !e.deleted && e.hash == hash))).unwrap_or(false))
            .filter_map(|(id, _)| id.parse().ok())
            .collect()
    }

    async fn apply(self: &Arc<Self>, sh: &Share, remote: &Index, from: &str) -> Result<()> {
        let actions = index::merge(&self.load_index(&sh.id), remote);
        for a in actions {
            if self.stop.load(Ordering::Relaxed) {
                break;
            }
            match a {
                Action::Adopt { path, entry } => {
                    let mut idx = self.load_index(&sh.id);
                    let seen = self.load_seen(&sh.id);
                    idx.files.insert(path, entry);
                    self.store_index(&sh.id, &idx, &seen)?;
                }
                Action::Keep { path } => {
                    let mut idx = self.load_index(&sh.id);
                    let seen = self.load_seen(&sh.id);
                    if let (Some(l), Some(r)) = (idx.files.get(&path).cloned(), remote.files.get(&path)) {
                        // A version newer than the delete that still names our edit: the peer will fetch it back.
                        let mut keep = l.next(&self.me, now_ms().max(r.ver.at + 1), l.hash.clone(), l.size, false);
                        keep.hist.push(r.ver.clone());
                        idx.files.insert(path.clone(), keep);
                        self.store_index(&sh.id, &idx, &seen)?;
                        self.note(format!("{}: kept {path}, changed here after {} deleted it", sh.name, self.peer_name(from)));
                    }
                }
                Action::Delete { path, entry } => {
                    let Some(full) = safe_join(&sh.path, &path) else { continue };
                    let mut idx = self.load_index(&sh.id);
                    let mut seen = self.load_seen(&sh.id);
                    // Only what is still exactly the version the peer deleted (a newer local change shows up as a newer version).
                    if let Ok(m) = std::fs::metadata(&full) {
                        if seen.get(&path) != Some(&(m.len(), mtime_ms(&m))) {
                            continue;
                        }
                        std::fs::remove_file(&full).with_context(|| format!("could not delete {path}"))?;
                        prune_empty(&sh.path, &full);
                    }
                    let _ = self.store.tags().delete(Self::tag_name(&sh.id, &path).as_bytes()).await;
                    seen.remove(&path);
                    idx.files.insert(path.clone(), entry);
                    self.store_index(&sh.id, &idx, &seen)?;
                    self.unmark_writing(&sh.id, &path)?;
                    self.note(format!("{}: {} deleted {path}", sh.name, self.peer_name(from)));
                }
                Action::Fetch { path, entry, conflict } => self.fetch(sh, &path, entry, conflict, from).await?,
            }
        }
        Ok(())
    }

    async fn fetch(self: &Arc<Self>, sh: &Share, path: &str, entry: Entry, conflict: bool, from: &str) -> Result<()> {
        let Some(full) = safe_join(&sh.path, path) else {
            self.note(format!("{}: skipped an unsafe name from {}", sh.name, self.peer_name(from)));
            return Ok(());
        };
        // A file here that is not what this device last indexed (an edit still settling, or a new file of the same name not
        // scanned yet) is never written over: the next scan indexes it, and the comparison after that keeps both if they differ.
        if let Ok(m) = std::fs::metadata(&full) {
            if self.load_seen(&sh.id).get(path) != Some(&(m.len(), mtime_ms(&m))) {
                self.settle_again.store(true, Ordering::Relaxed);
                return Ok(());
            }
        }
        let hash: Hash = entry.hash.parse().map_err(|_| anyhow!("bad hash for {path}"))?;
        let have = self.store.blobs().status(hash).await.map(|s| matches!(s, iroh_blobs::api::proto::BlobStatus::Complete { .. })).unwrap_or(false);
        if !have {
            if !self.may_use_network() {
                bail!("Paused: no network it may use");
            }
            let reserve = self.reserve.load(Ordering::Relaxed);
            let need = entry.size;
            // The store takes it first; where the shared folder is on another file system (a phone's internal and shared
            // storage) the copy into place needs the room there too.
            for at in [&self.dir, &full] {
                if let Some(free) = Self::free_bytes(at) {
                    if free < need.saturating_add(reserve) {
                        bail!(
                            "Paused: {} needs {}, {} is free and {} is kept free",
                            path,
                            human(need),
                            human(free),
                            human(reserve)
                        );
                    }
                }
            }
            let providers = self.providers(&entry.hash);
            if providers.is_empty() {
                bail!("no linked device has {path} right now");
            }
            self.wanted.lock().unwrap().insert(hash);
            self.run.lock().unwrap().transfer = Some(Transfer {
                share: sh.name.clone(),
                path: path.to_string(),
                size: entry.size,
                done: 0,
                from: providers.iter().map(|p| self.peer_name(&p.to_string())).collect(),
            });
            let strategy = if providers.len() > 1 { SplitStrategy::Split } else { SplitStrategy::None };
            let dl = self.store.downloader(&self.endpoint);
            let mut stream = dl
                .download_with_opts(DownloadOptions::new(HashAndFormat::raw(hash), Shuffled::new(providers), strategy))
                .stream()
                .await
                .map_err(|e| anyhow!("{e}"))?;
            let mut failed = None;
            let mut last_progress = Instant::now();
            loop {
                // Woken every second even when nothing arrives, so a pause or a stalled path is noticed.
                match tokio::time::timeout(Duration::from_secs(1), stream.next()).await {
                    Ok(None) => break,
                    Ok(Some(item)) => match item {
                        DownloadProgressItem::Progress(n) => {
                            last_progress = Instant::now();
                            if let Some(t) = self.run.lock().unwrap().transfer.as_mut() {
                                t.done = n;
                            }
                        }
                        DownloadProgressItem::Error(e) => failed = Some(format!("{e}")),
                        DownloadProgressItem::DownloadError => failed = Some("the transfer stopped".into()),
                        _ => {}
                    },
                    Err(_) => {}
                }
                if !self.may_use_network() {
                    // Dropping the stream ends the transfer; the verified chunks stay in the store for the resume.
                    failed = Some("paused, no network it may use".into());
                    break;
                }
                if last_progress.elapsed() > STALL {
                    failed = Some("no data for 20 seconds".into());
                    break;
                }
            }
            self.run.lock().unwrap().transfer = None;
            if let Some(f) = failed {
                // What arrived stays in the store (still wanted), so the next round carries on from there.
                bail!("{path}: {f} (will resume)");
            }
        }
        // In place: a conflicting local file first becomes a copy beside it.
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let old_hash = self.load_index(&sh.id).files.get(path).filter(|e| !e.deleted).map(|e| e.hash.clone());
        self.mark_writing(&sh.id, path, &entry)?;
        let mut conflict_copy = None;
        if conflict && full.exists() {
            let stamp = chrono_stamp();
            let copy = index::conflict_name(path, &self.saved.lock().unwrap().name, &stamp);
            if let Some(cfull) = safe_join(&sh.path, &copy) {
                std::fs::rename(&full, &cfull)?;
                self.note(format!("{}: {path} was changed here and on {}; kept ours as {copy}", sh.name, self.peer_name(from)));
                // Picked up as a new file by the next scan; the store is pointed at it below.
                conflict_copy = Some(cfull);
            }
        }
        if full.exists() {
            std::fs::remove_file(&full).with_context(|| format!("could not replace {path}"))?;
        }
        #[cfg(feature = "test-hooks")]
        if std::env::var("CACHE_SYNC_CUT_WRITE").map(|v| v == path).unwrap_or(false) {
            // As if Cache were stopped half way through writing this file: half of it at the real path, nothing cleaned up.
            let bytes = self.store.blobs().get_bytes(hash).await.map_err(|e| anyhow!("{e}"))?;
            std::fs::write(&full, &bytes[..bytes.len() / 2])?;
            self.stop.store(true, Ordering::Relaxed);
            bail!("test: cut off writing {path}");
        }
        if let Err(e) = self.store.export_with_opts(ExportOptions { hash, mode: ExportMode::TryReference, target: full.clone() }).finish().await {
            // Whatever part got written goes; the content stays in the store and the next round writes it again.
            if std::fs::remove_file(&full).is_err() && full.exists() {
                // Left for the recovery a start does, before the next scan could take it for an edit.
                self.recovered.store(false, Ordering::Relaxed);
            }
            bail!("could not write {path}: {e}");
        }
        self.wanted.lock().unwrap().remove(&hash);
        let entry_hash = entry.hash.clone();
        let size = entry.size;
        self.written(sh, path, &full, entry).await?;
        self.note(format!("{}: got {path} ({})", sh.name, human(size)));
        // The content that was here: kept as a conflict copy, or still in use at another path.
        if let Some(c) = conflict_copy {
            if let Some(h) = &old_hash {
                if let Err(e) = self.relocate(h, &c).await {
                    self.note(format!("could not refresh {}: {e:#}", c.display()));
                }
            }
        } else if let Some(h) = old_hash.filter(|h| *h != entry_hash) {
            self.repoint(&h, Some(&full)).await;
        }
        Ok(())
    }
}

fn chrono_stamp() -> String {
    // UTC, minute resolution, without pulling in a date crate: days since 1970 to a civil date.
    let s = (now_ms() / 1000) as i64;
    let (days, rem) = (s.div_euclid(86400), s.rem_euclid(86400));
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02} {:02}{:02} UTC", rem / 3600, (rem % 3600) / 60)
}

fn read_json<T: for<'de> Deserialize<'de>>(p: &Path) -> Option<T> {
    serde_json::from_slice(&std::fs::read(p).ok()?).ok()
}

fn write_json<T: Serialize>(p: &Path, v: &T) -> Result<()> {
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = p.with_extension("tmp");
    std::fs::write(&tmp, serde_json::to_vec(v)?)?;
    std::fs::rename(&tmp, p)?;
    Ok(())
}

/// Answers linking requests that carry the code being shown.
#[derive(Clone)]
struct PairProto(Arc<Inner>);

impl std::fmt::Debug for PairProto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairProto")
    }
}

#[derive(Serialize, Deserialize)]
struct PairHello {
    token: String,
    name: String,
}

impl ProtocolHandler for PairProto {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let (mut send, mut recv) = conn.accept_bi().await?;
        let bytes = recv.read_to_end(4096).await.map_err(AcceptError::from_err)?;
        let hello: Option<PairHello> = serde_json::from_slice(&bytes).ok();
        let inner = &self.0;
        let ok = {
            let mut p = inner.pairing.lock().unwrap();
            match (&*p, &hello) {
                (Some((tok, until)), Some(h)) if *tok == h.token && Instant::now() < *until => {
                    *p = None; // one use
                    true
                }
                _ => false,
            }
        };
        let reply = if let (true, Some(h)) = (ok, hello) {
            let id = conn.remote_id();
            add_peer(inner, &id.to_string(), &h.name);
            inner.note(format!("Linked with {}", h.name));
            inner.wake.notify_one();
            json!({"ok": true, "name": inner.saved.lock().unwrap().name})
        } else {
            json!({"ok": false, "error": "that code is not being shown any more"})
        };
        send.write_all(reply.to_string().as_bytes()).await.map_err(AcceptError::from_err)?;
        send.finish()?;
        conn.closed().await;
        Ok(())
    }
}

fn add_peer(inner: &Inner, id: &str, name: &str) {
    {
        let mut s = inner.saved.lock().unwrap();
        s.peers.retain(|p| p.id != id);
        s.peers.push(Peer { id: id.to_string(), name: name.to_string(), linked: now_ms() });
    }
    if let Ok(k) = id.parse::<EndpointId>() {
        inner.allowed.write().unwrap().insert(k);
    }
    let _ = inner.save();
}

/// Sends a linked device this device's index.
#[derive(Clone)]
struct SyncProto(Arc<Inner>);

impl std::fmt::Debug for SyncProto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SyncProto")
    }
}

impl ProtocolHandler for SyncProto {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let (mut send, mut recv) = conn.accept_bi().await?;
        let _ask = recv.read_to_end(64).await.map_err(AcceptError::from_err)?;
        let inner = self.0.clone();
        let body = tokio::task::spawn_blocking(move || serde_json::to_vec(&inner.our_index()).unwrap_or_default())
            .await
            .map_err(AcceptError::from_err)?;
        send.write_all(&body).await.map_err(AcceptError::from_err)?;
        send.finish()?;
        conn.closed().await;
        // A peer asking means it may have changes too: compare soon.
        self.0.wake.notify_one();
        Ok(())
    }
}

impl SyncEngine {
    /// Opens (or creates) the identity, store and settings in `cfg.dir`, binds the endpoint and starts the sync rounds.
    pub fn open(cfg: Config) -> Result<SyncEngine> {
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("cache-sync").enable_all().build()?;
        let (inner, router) = rt.block_on(Self::start(cfg.clone()))?;
        let inner2 = inner.clone();
        let every = Duration::from_secs(cfg.interval_secs.unwrap_or(30).max(5));
        rt.spawn(async move {
            loop {
                if inner2.stop.load(Ordering::Relaxed) {
                    break;
                }
                inner2.round().await;
                let wait = if inner2.settle_again.swap(false, Ordering::Relaxed) { SETTLE + Duration::from_secs(1) } else { every };
                let _ = tokio::time::timeout(wait, inner2.wake.notified()).await;
            }
        });
        Ok(SyncEngine { rt, inner, router: Some(router) })
    }

    async fn start(cfg: Config) -> Result<(Arc<Inner>, Router)> {
        std::fs::create_dir_all(&cfg.dir)?;
        let key_path = cfg.dir.join("identity.key");
        let secret = match std::fs::read(&key_path) {
            Ok(b) if b.len() == 32 => SecretKey::from_bytes(&b.try_into().unwrap()),
            _ => {
                let k = SecretKey::generate();
                write_secret(&key_path, &k.to_bytes())?;
                k
            }
        };
        let mut saved: Saved = read_json(&cfg.dir.join("sync.json")).unwrap_or_default();
        if saved.name.is_empty() {
            saved.name = cfg.name.clone().unwrap_or_else(|| "Cache device".into());
        }
        let allowed: Arc<RwLock<HashSet<EndpointId>>> =
            Arc::new(RwLock::new(saved.peers.iter().filter_map(|p| p.id.parse().ok()).collect()));

        let mut b = Endpoint::builder(presets::Minimal).secret_key(secret.clone()).hooks(Gate { allowed: allowed.clone() });
        b = if !cfg.relay {
            b.relay_mode(RelayMode::Disabled)
        } else if !cfg.relay_urls.is_empty() {
            let urls: Vec<RelayUrl> = cfg.relay_urls.iter().filter_map(|u| u.parse().ok()).collect();
            b.relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter(urls)))
        } else {
            b.relay_mode(RelayMode::Default)
        };
        if cfg.lookup {
            match cfg.lookup_url.as_deref().and_then(|u| u.parse::<url::Url>().ok()) {
                Some(u) => {
                    b = b
                        .address_lookup(iroh::address_lookup::PkarrPublisher::builder(u.clone()))
                        .address_lookup(iroh::address_lookup::PkarrResolver::builder(u));
                }
                None => {
                    b = b
                        .address_lookup(iroh::address_lookup::PkarrPublisher::n0_dns())
                        .address_lookup(iroh::address_lookup::PkarrResolver::n0_dns())
                        .address_lookup(iroh::address_lookup::DnsAddressLookup::n0_dns());
                }
            }
        }
        if cfg.dht {
            b = b.address_lookup(iroh_mainline_address_lookup::DhtAddressLookup::builder());
        }
        if cfg.mdns {
            b = b.address_lookup(iroh_mdns_address_lookup::MdnsAddressLookup::builder());
        }
        if let Some(port) = cfg.port.filter(|p| *p != 0) {
            b = b.bind_addr(std::net::SocketAddr::from(([0, 0, 0, 0], port))).map_err(|e| anyhow!("{e}"))?;
        }
        let endpoint = b.bind().await.map_err(|e| anyhow!("could not start networking: {e}"))?;

        let wanted: Arc<Mutex<HashSet<Hash>>> = Arc::default();
        let w2 = wanted.clone();
        let gc = GcConfig {
            interval: Duration::from_secs(600),
            add_protected: Some(Arc::new(move |live: &mut HashSet<Hash>| {
                live.extend(w2.lock().unwrap().iter().copied());
                Box::pin(async { ProtectOutcome::Continue })
            })),
        };
        let store_dir = cfg.dir.join("blobs");
        let mut opts = StoreOptions::new(&store_dir);
        opts.gc = Some(gc);
        let store = FsStore::load_with_opts(store_dir.join("blobs.db"), opts).await.map_err(|e| anyhow!("could not open the store: {e}"))?;

        let inner = Arc::new(Inner {
            dir: cfg.dir.clone(),
            me: endpoint.id().to_string(),
            endpoint: endpoint.clone(),
            store: store.clone(),
            saved: Mutex::new(saved),
            allowed,
            pairing: Mutex::new(None),
            run: Mutex::new(Run::default()),
            wanted,
            wake: Notify::new(),
            network: AtomicBool::new(true),
            reserve: AtomicU64::new(cfg.reserve_bytes.unwrap_or(1024 * 1024 * 1024)),
            round: tokio::sync::Mutex::new(()),
            stop: AtomicBool::new(false),
            settle_again: Arc::default(),
            recovered: AtomicBool::new(false),
        });
        inner.save()?;
        let blobs = BlobsProtocol::new(&store, None);
        let router = Router::builder(endpoint)
            .accept(iroh_blobs::ALPN, blobs)
            .accept(PAIR_ALPN, PairProto(inner.clone()))
            .accept(SYNC_ALPN, SyncProto(inner.clone()))
            .spawn();
        inner.note("Started");
        Ok((inner, router))
    }

    /// The whole interface: `method` with JSON `args`, a JSON answer. Errors come back as `{"error": "..."}` from the C ABI.
    pub fn call(&self, method: &str, args: &Value) -> Result<Value> {
        let inner = &self.inner;
        let s = |k: &str| args.get(k).and_then(|v| v.as_str()).map(|s| s.to_string());
        match method {
            "status" => Ok(self.status()),
            "set_name" => {
                let name = s("name").filter(|n| !n.trim().is_empty()).ok_or_else(|| anyhow!("name is required"))?;
                inner.saved.lock().unwrap().name = name.trim().to_string();
                inner.save()?;
                Ok(json!({"ok": true}))
            }
            "link_code" => {
                let tok = token();
                *inner.pairing.lock().unwrap() = Some((tok.clone(), Instant::now() + LINK_WINDOW));
                let ep = inner.endpoint.clone();
                let addr = self.rt.block_on(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(5), ep.online()).await;
                    ep.addr()
                });
                let code = encode_code(&LinkCode { a: addr, t: tok, n: inner.saved.lock().unwrap().name.clone() })?;
                Ok(json!({"code": code, "valid_secs": LINK_WINDOW.as_secs()}))
            }
            "link" => {
                let code = decode_code(&s("code").ok_or_else(|| anyhow!("code is required"))?)?;
                if code.a.id == inner.endpoint.id() {
                    bail!("that is this device's own code");
                }
                let name = inner.saved.lock().unwrap().name.clone();
                let ep = inner.endpoint.clone();
                let peer = code.a.id;
                // Allowed before connecting: the reply comes back on our own connection, and from now on it may connect to us.
                inner.allowed.write().unwrap().insert(peer);
                let reply: Result<Value> = self.rt.block_on(async move {
                    let conn = tokio::time::timeout(Duration::from_secs(45), ep.connect(code.a, PAIR_ALPN))
                        .await
                        .map_err(|_| anyhow!("the other device did not answer"))?
                        .map_err(|e| anyhow!("could not reach the other device: {e}"))?;
                    let (mut send, mut recv) = conn.open_bi().await.map_err(|e| anyhow!("{e}"))?;
                    send.write_all(&serde_json::to_vec(&PairHello { token: code.t, name })?).await.map_err(|e| anyhow!("{e}"))?;
                    send.finish().map_err(|e| anyhow!("{e}"))?;
                    let bytes = recv.read_to_end(4096).await.map_err(|e| anyhow!("{e}"))?;
                    conn.close(0u32.into(), b"done");
                    Ok(serde_json::from_slice(&bytes)?)
                });
                let reply = match reply {
                    Ok(r) => r,
                    Err(e) => {
                        if !inner.saved.lock().unwrap().peers.iter().any(|p| p.id == peer.to_string()) {
                            inner.allowed.write().unwrap().remove(&peer);
                        }
                        return Err(e);
                    }
                };
                if reply.get("ok").and_then(|v| v.as_bool()) != Some(true) {
                    inner.allowed.write().unwrap().remove(&peer);
                    bail!("{}", reply.get("error").and_then(|v| v.as_str()).unwrap_or("the other device refused the link"));
                }
                let pname = reply.get("name").and_then(|v| v.as_str()).unwrap_or(&code.n).to_string();
                add_peer(inner, &peer.to_string(), &pname);
                inner.note(format!("Linked with {pname}"));
                inner.wake.notify_one();
                Ok(json!({"ok": true, "peer": peer.to_string(), "name": pname}))
            }
            "unlink" => {
                let id = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                inner.saved.lock().unwrap().peers.retain(|p| p.id != id);
                if let Ok(k) = id.parse::<EndpointId>() {
                    inner.allowed.write().unwrap().remove(&k);
                }
                inner.run.lock().unwrap().peers.remove(&id);
                inner.save()?;
                Ok(json!({"ok": true}))
            }
            "share_add" => {
                let path = PathBuf::from(s("path").ok_or_else(|| anyhow!("path is required"))?);
                if !path.is_dir() {
                    bail!("{} is not a folder", path.display());
                }
                let name = s("name").unwrap_or_else(|| path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "Shared".into()));
                let id = s("id").unwrap_or_else(|| token()[..13].to_lowercase());
                {
                    let mut sv = inner.saved.lock().unwrap();
                    if sv.shares.iter().any(|x| x.id == id || x.path == path) {
                        bail!("that folder is already shared");
                    }
                    sv.shares.push(Share { id: id.clone(), name, path });
                }
                inner.save()?;
                inner.wake.notify_one();
                Ok(json!({"ok": true, "id": id}))
            }
            "share_join" => {
                // An offered share: same id, into a folder of this device's choosing.
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let path = PathBuf::from(s("path").ok_or_else(|| anyhow!("path is required"))?);
                std::fs::create_dir_all(&path)?;
                let name = s("name")
                    .or_else(|| {
                        let run = inner.run.lock().unwrap();
                        run.peers.values().filter_map(|p| p.index.as_ref()).flat_map(|i| i.shares.iter()).find(|x| x.id == id).map(|x| x.name.clone())
                    })
                    .unwrap_or_else(|| "Shared".into());
                {
                    let mut sv = inner.saved.lock().unwrap();
                    if sv.shares.iter().any(|x| x.id == id) {
                        bail!("already joined");
                    }
                    sv.shares.push(Share { id: id.clone(), name, path });
                }
                inner.save()?;
                inner.wake.notify_one();
                Ok(json!({"ok": true}))
            }
            "share_remove" => {
                // Stops sharing; the files stay where they are.
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                inner.saved.lock().unwrap().shares.retain(|x| x.id != id);
                inner.save()?;
                let _ = std::fs::remove_file(inner.index_path(&id));
                let _ = std::fs::remove_file(inner.seen_path(&id));
                let store = inner.store.clone();
                let prefix = format!("f/{id}/");
                self.rt.block_on(async move {
                    if let Ok(mut tags) = store.tags().list_prefix(prefix.as_bytes()).await {
                        let mut names = Vec::new();
                        while let Some(Ok(t)) = tags.next().await {
                            names.push(t.name);
                        }
                        for n in names {
                            let _ = store.tags().delete(n).await;
                        }
                    }
                });
                Ok(json!({"ok": true}))
            }
            "sync_now" => {
                inner.wake.notify_one();
                Ok(json!({"ok": true}))
            }
            "set_policy" => {
                if let Some(n) = args.get("network").and_then(|v| v.as_bool()) {
                    inner.network.store(n, Ordering::Relaxed);
                }
                if let Some(r) = args.get("reserve_bytes").and_then(|v| v.as_u64()) {
                    inner.reserve.store(r, Ordering::Relaxed);
                }
                inner.wake.notify_one();
                Ok(json!({"ok": true}))
            }
            "network_changed" => {
                // The phone moved between Wi-Fi and mobile data: find new paths at once.
                let ep = inner.endpoint.clone();
                self.rt.block_on(async move { ep.network_change().await });
                inner.wake.notify_one();
                Ok(json!({"ok": true}))
            }
            _ => bail!("unknown method {method}"),
        }
    }

    fn status(&self) -> Value {
        let inner = &self.inner;
        let saved = inner.saved.lock().unwrap().clone();
        let run = inner.run.lock().unwrap();
        let joined: HashSet<&str> = saved.shares.iter().map(|s| s.id.as_str()).collect();
        let mut offers = Vec::new();
        let peers: Vec<Value> = saved
            .peers
            .iter()
            .map(|p| {
                let st = run.peers.get(&p.id).cloned().unwrap_or_default();
                if let Some(idx) = &st.index {
                    for sh in &idx.shares {
                        if !joined.contains(sh.id.as_str()) {
                            let live = sh.index.files.values().filter(|e| !e.deleted);
                            let (n, b) = live.fold((0u64, 0u64), |(n, b), e| (n + 1, b + e.size));
                            offers.push(json!({"peer": p.id, "peer_name": p.name, "id": sh.id, "name": sh.name, "files": n, "bytes": b}));
                        }
                    }
                }
                json!({"id": p.id, "name": p.name, "linked": p.linked, "last_seen": st.last_seen, "via": st.via, "error": st.error})
            })
            .collect();
        let shares: Vec<Value> = saved
            .shares
            .iter()
            .map(|sh| {
                let idx = inner.load_index(&sh.id);
                let live: Vec<&Entry> = idx.files.values().filter(|e| !e.deleted).collect();
                // What linked devices have that this one does not yet.
                let mut pending = 0u64;
                let mut pending_bytes = 0u64;
                for st in run.peers.values() {
                    if let Some(rs) = st.index.as_ref().and_then(|i| i.shares.iter().find(|x| x.id == sh.id)) {
                        for a in index::merge(&idx, &rs.index) {
                            if let Action::Fetch { entry, .. } = a {
                                pending += 1;
                                pending_bytes += entry.size;
                            }
                        }
                    }
                }
                json!({
                    "id": sh.id, "name": sh.name, "path": sh.path,
                    "files": live.len(), "bytes": live.iter().map(|e| e.size).sum::<u64>(),
                    "pending_files": pending, "pending_bytes": pending_bytes,
                })
            })
            .collect();
        let addr = inner.endpoint.addr();
        json!({
            "id": inner.me,
            "name": saved.name,
            "relay": addr.relay_urls().next().map(|u| u.to_string()),
            "direct": addr.ip_addrs().map(|a| a.to_string()).collect::<Vec<_>>(),
            "network": inner.network.load(Ordering::Relaxed),
            "reserve_bytes": inner.reserve.load(Ordering::Relaxed),
            "free_bytes": Inner::free_bytes(&inner.dir),
            "showing_code": inner.pairing.lock().unwrap().as_ref().map(|(_, until)| until.saturating_duration_since(Instant::now()).as_secs()),
            "peers": peers,
            "shares": shares,
            "offers": offers,
            "transfer": run.transfer,
            "paused": run.paused,
            "rounds": run.rounds,
            "last_round": run.last_round,
            "log": run.log.iter().rev().take(50).map(|(t, m)| json!({"at": t, "text": m})).collect::<Vec<_>>(),
        })
    }

    /// Stops the rounds, closes connections and flushes the store.
    pub fn close(mut self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        self.inner.wake.notify_one();
        let router = self.router.take();
        let store = self.inner.store.clone();
        self.rt.block_on(async move {
            if let Some(r) = router {
                let _ = tokio::time::timeout(Duration::from_secs(5), r.shutdown()).await;
            }
            let _ = store.shutdown().await;
        });
    }
}

fn write_secret(p: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = p.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, p)?;
    Ok(())
}
