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

pub mod identity;
pub mod index;

use anyhow::{anyhow, bail, Context, Result};
use index::{Action, Entry, Index, Ver};
use iroh::{
    endpoint::{presets, AfterHandshakeOutcome, Connection, EndpointHooks, VarInt},
    protocol::{AcceptError, ProtocolHandler, Router},
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl,
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
/// How long a link made by showing a code may wait for the other device to show that it holds the link too, before it is
/// removed here ([`Peer::unconfirmed`]). A slow clean-up, not a time limit: removing a real link is worse than keeping a
/// dead entry, and the other device may be put away for days right after linking. Counted from the time saved with the
/// link, so a restart does not start the wait again. A clock that is behind never removes anything; a clock wrongly far
/// ahead could remove such a link early, which is accepted because only links never confirmed are ever touched.
const CONFIRM_WINDOW: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// An index larger than this is refused (about a million files).
const MAX_INDEX: usize = 256 * 1024 * 1024;

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// `true`, for serde defaults.
fn t() -> bool {
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
    #[serde(default = "t")]
    pub mdns: bool,
    /// Publish to and look up in the Mainline DHT.
    #[serde(default = "t")]
    pub dht: bool,
    /// Publish to and look up in a lookup service: n0's by default, or `lookup_url` (an iroh-dns-server).
    #[serde(default = "t")]
    pub lookup: bool,
    #[serde(default)]
    pub lookup_url: Option<String>,
    /// Relays: n0's public ones by default, the listed ones instead when given, none when `relay` is false.
    #[serde(default = "t")]
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
    /// What never syncs in a shared folder, by share id: things each device builds or caches for itself (a library's search index,
    /// a viewed-tile cache, SQLite's shared-memory files). Each pattern is a path of segments: `*` within a segment matches any run
    /// of characters (`*` alone is any one segment, `*-shm` any name ending so), and a `**` segment any number of segments
    /// (`**/*-shm` is such a file at any depth). A pattern covers what it names and everything in it (`*/index` is the `index`
    /// folder of every top-level folder, with its files). Such a path is not listed, sent, fetched or deleted; a copy already here
    /// stays (it is this device's now), and entries for it that an earlier version listed are forgotten, not deleted, so no other
    /// device loses its own copy.
    #[serde(default)]
    pub exclude: BTreeMap<String, Vec<String>>,
    /// Paths whose deletion stays on this device, by share id (patterns as for `exclude`): when such a file goes here, the other
    /// devices are not told (they keep theirs), and a delete of one from another device is not done here. This device remembers
    /// what it deleted, so it does not fetch it back. For things each device replaces on its own (sealed search index snapshots).
    #[serde(default)]
    pub local_deletes: BTreeMap<String, Vec<String>>,
    /// What this device fetches from the others, by share id (patterns as for `exclude`): a share listed here takes only the paths
    /// its patterns cover (an empty list: nothing), until `set_only` replaces the list. Its own files are offered to the others
    /// all the same. A share not listed fetches everything.
    #[serde(default)]
    pub only: BTreeMap<String, Vec<String>>,
    /// Fetched after everything else that comes in the same round, by share id (patterns as for `exclude`): a file whose arrival
    /// says the rest is there (a snapshot's manifest).
    #[serde(default)]
    pub last: BTreeMap<String, Vec<String>>,
    /// What this device never fetches, by share id (patterns as for `exclude`), on top of `only`: snapshots its own core found
    /// unusable and removed. `set_never_fetch` replaces a share's list later. Its own files are offered all the same.
    #[serde(default)]
    pub never_fetch: BTreeMap<String, Vec<String>>,
    /// Hidden files that do sync, by share id (patterns as for `exclude`, naming the hidden part): a name starting with "." is
    /// otherwise never listed, sent or fetched (the folders' own working files). Tantivy keeps `.managed.json` in every index
    /// and a snapshot's manifest lists it, so the indexes folder lets it, and the empty `.tantivy-meta.lock` beside it, travel.
    #[serde(default)]
    pub hidden: BTreeMap<String, Vec<String>>,
    /// What this device has switched off in a shared folder, by share id (patterns as for `exclude`): the person's choice of
    /// items in one share (a library, a map layer, a model). Such a path is neither fetched here nor offered to the others, and
    /// its deletes stay here, but this device keeps listing it with its history, so switching it on again carries on where it
    /// left off (and a copy deleted here meanwhile comes back from the devices that kept theirs). `set_off` replaces a share's
    /// list later.
    #[serde(default)]
    pub off: BTreeMap<String, Vec<String>>,
    /// Shares kept only with some linked devices, by share id: the link kinds ([`Link`]'s `mode`) a device must have for the share
    /// to be offered to it and taken from it. A link starts `"off"` until the person answers ([`new_link`]); links made before
    /// that were given `"match"` once ([`migrate_links`]). A link with no mode at all counts as `"match"`. A share not listed goes to every linked device. The person's
    /// Bookshelves log is `["match"]` (their own devices only), the settings log `["match", "send"]`. `set_share_with` replaces a
    /// share's list later.
    #[serde(default)]
    pub with: BTreeMap<String, Vec<String>>,
}

/// Whether `rel` (a path in a shared folder) is one of `patterns` or inside one (see [`Config::exclude`]).
pub fn excluded(patterns: &[String], rel: &str) -> bool {
    let parts: Vec<&str> = rel.split('/').collect();
    patterns.iter().any(|pat| {
        let segs: Vec<&str> = pat.split('/').filter(|s| !s.is_empty()).collect();
        !segs.is_empty() && covers(&segs, &parts)
    })
}

/// Whether the pattern segments `pat` match the start of `parts` (what follows is inside what they name).
fn covers(pat: &[&str], parts: &[&str]) -> bool {
    match pat.split_first() {
        None => true,
        Some((&"**", rest)) => covers(rest, parts) || (!parts.is_empty() && covers(pat, &parts[1..])),
        Some((seg, rest)) => parts.split_first().map(|(p, more)| glob(seg, p) && covers(rest, more)).unwrap_or(false),
    }
}

/// One segment against its pattern, where `*` matches any run of characters.
fn glob(pat: &str, name: &str) -> bool {
    let Some((head, tail)) = pat.split_once('*') else { return pat == name };
    let Some(mut rest) = name.strip_prefix(head) else { return false };
    let pieces: Vec<&str> = tail.split('*').collect();
    let (last, middle) = pieces.split_last().expect("split gives one piece at least");
    for piece in middle {
        match rest.find(piece) {
            Some(i) => rest = &rest[i + piece.len()..],
            None => return false,
        }
    }
    rest.len() >= last.len() && rest.ends_with(last)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Peer {
    id: String,
    name: String,
    linked: u64,
    /// What the two devices agreed about this link, as last set on either ([`Link`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    link: Option<Link>,
    /// When the device last answered (ms since 1970) and how (`direct` or `relay`), so a start does not forget it. Written at most
    /// about once a minute ([`Peer::seen`]). Absent in files saved by older versions, and until the device has answered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_seen: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    via: Option<String>,
    /// The name the device last called itself. `name` follows it when it changes, and stays as the person set it ("Rename") until
    /// the device announces a different one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    announced: Option<String>,
    /// Set on the device that showed the link code, until the other device has shown that it holds the link too: its answer to
    /// the code may never have reached it, and then it does not know it is linked. Absent once confirmed, on the device that
    /// read the code, and in files saved by older versions.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    unconfirmed: bool,
}

/// The least time between two writes of a device's last seen time.
const SEEN_SAVE_EVERY_MS: u64 = 60_000;

impl Peer {
    /// Notes that the device answered at `now` through `via`. True when that changed what is saved (the first time, and then at
    /// most once in [`SEEN_SAVE_EVERY_MS`]), so the caller writes the file.
    fn seen(&mut self, now: u64, via: &str) -> bool {
        let due = match self.last_seen {
            None => true,
            Some(t) => now < t || now - t >= SEEN_SAVE_EVERY_MS,
        };
        if due {
            self.last_seen = Some(now);
            self.via = Some(via.to_string());
        }
        due
    }

    /// Takes the name the device now calls itself. True when it was new (the caller writes the file). A name the person gave this
    /// device here stays until the device announces a different one.
    fn adopt_name(&mut self, announced: &str) -> bool {
        let announced = announced.trim();
        if announced.is_empty() || self.announced.as_deref() == Some(announced) {
            return false;
        }
        self.announced = Some(announced.to_string());
        self.name = announced.to_string();
        true
    }
}

/// What two linked devices keep about their link, the same on both: the app's value (for Cache, how settings go between them:
/// `{"mode": "match" | "send" | "off", "from": <the device the settings come from>, ...}`) and when it was last set. Each
/// device sends its copy with its file list; the one set later is taken by the other (`set_link`), so the device the person
/// chooses it on is where it comes from. The engine itself reads only `mode`, for [`Config::with`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Link {
    v: Value,
    t: u64,
}

/// Who answered a link's first question and when (`by`, `at` in the app's value), if anyone has.
fn link_answer(l: &Link) -> Option<(&str, u64)> {
    let by = l.v.get("by")?.as_str()?;
    Some((by, l.v.get("at").and_then(|a| a.as_u64()).unwrap_or(u64::MAX)))
}

/// Whether `theirs` (the copy `peer` sent) replaces `mine`, so both devices end up with the same one. The first answer to the
/// link's question is the pair's: a record with an answer beats one without; of two answers the earlier `at` wins, then the
/// lower device id. The same answer on both: the later `t` wins (a change made since on the device's page), and on the same
/// `t` the device with the greater key, so both still agree.
fn link_replaces(mine: &Link, theirs: &Link, peer: &str, me: &str) -> bool {
    match (link_answer(mine), link_answer(theirs)) {
        (None, Some(_)) => return true,
        (Some(_), None) => return false,
        (Some(a), Some(b)) if a != b => return (b.1, b.0) < (a.1, a.0),
        _ => {}
    }
    theirs.t > mine.t || (theirs.t == mine.t && theirs.v != mine.v && peer > me)
}

/// A link's kind for [`Config::with`]: its `mode`, or `"match"` while it has none (a link only an older version of the other
/// device knows about; every link here has one, see [`new_link`] and [`migrate_links`]).
fn link_mode(link: Option<&Link>) -> String {
    link.and_then(|l| l.v.get("mode")).and_then(|m| m.as_str()).unwrap_or("match").to_string()
}

/// Names a set of secrets for one device without saying what they are (blake3 of their JSON), so it can tell when they change.
fn secrets_digest(m: &BTreeMap<String, String>) -> String {
    blake3::hash(&serde_json::to_vec(m).unwrap_or_default()).to_hex().to_string()
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
    /// The links made before new links started Off have been given `"match"` ([`migrate_links`]); done once, never again.
    #[serde(default)]
    links_migrated: bool,
}

/// A link as it is made: Off, waiting for the person's answer (`ask`), until either device sets it. Its time is 0, so any
/// link set later on either device wins, and both devices start with the same one.
fn new_link() -> Link {
    Link { v: json!({"mode": "off", "ask": true}), t: 0 }
}

/// Once, the first time this version opens: every link made before new links started Off, still with no kind, becomes
/// `"match"` (what it counted as), so only links made from now on start Off. Returns whether anything changed.
fn migrate_links(saved: &mut Saved) -> bool {
    if saved.links_migrated {
        return false;
    }
    for p in saved.peers.iter_mut().filter(|p| p.link.is_none()) {
        p.link = Some(Link { v: json!({"mode": "match"}), t: 0 });
    }
    saved.links_migrated = true;
    true
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
    /// The free space on the device that sent it (older versions do not say).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    free_bytes: Option<u64>,
    /// The sender's copy of its link with the device it sends this to ([`Link`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    link: Option<Link>,
    /// The sender keeps links (older versions do not).
    #[serde(default)]
    links: bool,
    /// The sender holds secrets for the device it sends this to ([`secrets_digest`]); the device asks for them when it changes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    secrets: Option<String>,
}

/// What one round covers: everything (the rounds on their own, and `sync_now` with no scope), or, for `sync_now` with a scope,
/// one linked device, some shared folders, and within them the paths `paths` covers (patterns as for [`Config::exclude`]).
#[derive(Debug, Clone, Default)]
struct Scope {
    peer: Option<String>,
    shares: Option<Vec<String>>,
    paths: Option<Vec<String>>,
}

impl Scope {
    fn whole(&self) -> bool {
        self.peer.is_none() && self.shares.is_none() && self.paths.is_none()
    }

    fn has_share(&self, id: &str) -> bool {
        self.shares.as_ref().map(|s| s.iter().any(|x| x == id)).unwrap_or(true)
    }

    fn has_peer(&self, id: &str) -> bool {
        self.peer.as_deref().map(|p| p == id).unwrap_or(true)
    }

    /// `remote` narrowed to the paths of the scope.
    fn narrow(&self, remote: &Index) -> Index {
        match &self.paths {
            None => remote.clone(),
            Some(p) => Index { files: remote.files.iter().filter(|(rel, _)| excluded(p, rel)).map(|(k, v)| (k.clone(), v.clone())).collect() },
        }
    }
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

/// What one linked device last sent of its secrets: their digest, and the secrets until the app takes them.
type Received = (String, Option<BTreeMap<String, String>>);

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
    /// Files dated in the future (a device with a wrong clock), by share then path: the size and modification time each was
    /// last seen with, and since when. Their date cannot say whether they are still being written, so they count as settled
    /// once they have stayed the same for [`SETTLE`]. In memory only; an entry goes when its file settles, changes or goes.
    settling: Mutex<HashMap<String, HashMap<String, Settling>>>,
    /// The first round has put right what an interrupted write left (see [`Writes`]).
    recovered: AtomicBool,
    /// What never syncs, by share id ([`Config::exclude`]).
    exclude: BTreeMap<String, Vec<String>>,
    /// [`Config::local_deletes`].
    local_deletes: BTreeMap<String, Vec<String>>,
    /// [`Config::only`], as `set_only` last left it.
    only: Mutex<BTreeMap<String, Vec<String>>>,
    /// [`Config::last`].
    last: BTreeMap<String, Vec<String>>,
    /// [`Config::hidden`].
    hidden: BTreeMap<String, Vec<String>>,
    /// [`Config::never_fetch`], as `set_never_fetch` last left it.
    never_fetch: Mutex<BTreeMap<String, Vec<String>>>,
    /// [`Config::off`], as `set_off` last left it.
    off: Mutex<BTreeMap<String, Vec<String>>>,
    /// Deletes kept here that `set_only` made fetchable again, by share: forgotten by the next rescan of the share, inside its
    /// round, so a round already running cannot write them back (set_only does not wait for the round).
    refetch: Mutex<HashMap<String, Vec<String>>>,
    /// [`Config::with`], as `set_share_with` last left it.
    with: Mutex<BTreeMap<String, Vec<String>>>,
    /// Secrets for one linked device each (the app's API keys the person ticked for it), by device: in memory only, never
    /// written anywhere by the engine, and sent only to that device over its own end-to-end encrypted connection when it asks.
    secrets: Mutex<HashMap<String, BTreeMap<String, String>>>,
    /// The secrets each linked device last sent here, by device: their digest (so they are asked for once per change) and,
    /// until the app takes them (`take_secrets`), the secrets themselves. In memory only.
    received: Mutex<HashMap<String, Received>>,
}

/// A file dated in the future as a rescan last saw it: its size and modification time, and since when they have not changed.
type Settling = ((u64, i64), Instant);

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
    rel_path_with(root, p, &[])
}

/// [`rel_path`], where a hidden path that `hidden` covers ([`Config::hidden`]) counts too.
fn rel_path_with(root: &Path, p: &Path, hidden: &[String]) -> Option<String> {
    let r = p.strip_prefix(root).ok()?;
    let parts: Vec<String> = r.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    let rel = parts.join("/");
    if parts.iter().any(|c| c.starts_with('.')) && !excluded(hidden, &rel) {
        return None;
    }
    Some(rel)
}

/// A path from a peer, made safe to join under a shared folder (no parent steps, no absolute paths, no hidden parts).
fn safe_join(root: &Path, rel: &str) -> Option<PathBuf> {
    safe_join_with(root, rel, &[])
}

/// [`safe_join`], where a hidden path that `hidden` covers ([`Config::hidden`]) is allowed.
fn safe_join_with(root: &Path, rel: &str, hidden: &[String]) -> Option<PathBuf> {
    let mut p = root.to_path_buf();
    let hidden_ok = excluded(hidden, rel);
    for c in rel.split('/') {
        if c.is_empty() || c == "." || c == ".." || (c.starts_with('.') && !hidden_ok) || c.contains('\\') || c.contains(':') {
            return None;
        }
        p.push(c);
    }
    Some(p)
}

fn mtime_ms(m: &std::fs::Metadata) -> i64 {
    m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0)
}

///
/// `complete` is cleared when anything could not be read (a folder that cannot be listed, a file whose details cannot be
/// read): what is missing from `out` then may only be unreadable, so a scan must not take it as gone.
fn walk(root: &Path, dir: &Path, skip: &[String], hidden: &[String], out: &mut Vec<(String, PathBuf, std::fs::Metadata)>, complete: &mut bool) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        *complete = false;
        return;
    };
    for e in rd {
        let Ok(e) = e else {
            *complete = false;
            continue;
        };
        let p = e.path();
        let Ok(m) = std::fs::symlink_metadata(&p) else {
            *complete = false;
            continue;
        };
        if m.file_type().is_symlink() {
            continue;
        }
        let Some(rel) = rel_path_with(root, &p, hidden) else { continue };
        if excluded(skip, &rel) {
            continue;
        }
        if m.is_dir() {
            walk(root, &p, skip, hidden, out, complete);
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

/// Folders a delete left empty go too, up to (not including) the shared folder itself. A folder left holding only what never
/// syncs (`skip`: a removed library's search index, built here from files that are now gone) counts as empty.
fn prune_empty(root: &Path, removed: &Path, skip: &[String]) {
    let mut d = removed.parent();
    while let Some(dir) = d {
        if dir == root || !dir.starts_with(root) {
            break;
        }
        if std::fs::remove_dir(dir).is_err() && !remove_if_only_excluded(root, dir, skip) {
            break;
        }
        d = dir.parent();
    }
}

/// Removes `dir` when everything in it is excluded from sync (and there is something); false when anything else is there or a
/// removal fails.
fn remove_if_only_excluded(root: &Path, dir: &Path, skip: &[String]) -> bool {
    let Ok(rd) = std::fs::read_dir(dir) else { return false };
    let mut derived = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        match rel_path(root, &p) {
            Some(rel) if excluded(skip, &rel) => derived.push(p),
            _ => return false,
        }
    }
    if derived.is_empty() {
        return false;
    }
    for p in derived {
        let gone = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
        if gone.is_err() {
            return false;
        }
    }
    std::fs::remove_dir(dir).is_ok()
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

    /// Set (holding the new path) while a share re-pointed to a new folder has not yet had its first, reconciling scan.
    fn moved_path(&self, share: &str) -> PathBuf {
        self.dir.join("index").join(format!("{share}.moved"))
    }

    fn moved_marker(&self, share: &str) -> Option<PathBuf> {
        std::fs::read_to_string(self.moved_path(share)).ok().map(PathBuf::from)
    }

    /// Adds a share, or re-points one this device already has (same id) at `path`: the folder's absolute path changes when the
    /// app's container moves (an iOS update). The name stays; the share is marked so its first scan never records deletes.
    /// The same folder under another id is refused. Returns whether the share was already there.
    fn upsert_share(&self, id: &str, name: String, path: PathBuf) -> Result<bool> {
        let existed;
        let moved;
        let share_name;
        {
            let mut sv = self.saved.lock().unwrap();
            if sv.shares.iter().any(|x| x.id != id && x.path == path) {
                bail!("that folder is already shared");
            }
            if let Some(x) = sv.shares.iter_mut().find(|x| x.id == id) {
                existed = true;
                moved = x.path != path;
                x.path = path.clone();
                share_name = x.name.clone();
            } else {
                existed = false;
                moved = false;
                share_name = name.clone();
                sv.shares.push(Share { id: id.to_string(), name, path: path.clone() });
            }
        }
        if moved {
            std::fs::create_dir_all(self.dir.join("index"))?;
            std::fs::write(self.moved_path(id), path.to_string_lossy().as_bytes())?;
            self.save()?;
            self.note(format!("{share_name}: folder moved after an update; checking files"));
        } else if !existed {
            self.save()?;
        }
        Ok(existed)
    }

    /// Writes the links and shares to disk. The lock is held through the write: one save at a time, and what is on disk is
    /// never older than what a later save wrote (two saves at once would share the temporary file and could land out of order).
    fn save(&self) -> Result<()> {
        let s = self.saved.lock().unwrap();
        write_saved(&self.saved_path(), &s)
    }

    /// Hidden paths that do sync in `share` ([`Config::hidden`]).
    fn hidden_ok(&self, share: &str) -> &[String] {
        self.hidden.get(share).map(|v| v.as_slice()).unwrap_or(&[])
    }

    /// The patterns that never sync in `share`.
    fn skip(&self, share: &str) -> &[String] {
        self.exclude.get(share).map(|v| v.as_slice()).unwrap_or(&[])
    }

    /// `idx` without the paths that never sync in `share` (what a peer lists for them is not looked at).
    fn without_excluded(&self, share: &str, idx: &Index) -> Index {
        let skip = self.skip(share);
        if skip.is_empty() {
            return idx.clone();
        }
        Index { files: idx.files.iter().filter(|(p, _)| !excluded(skip, p)).map(|(p, e)| (p.clone(), e.clone())).collect() }
    }

    /// A deletion of `rel` in `share` stays on this device ([`Config::local_deletes`]).
    fn delete_stays_here(&self, share: &str, rel: &str) -> bool {
        self.local_deletes.get(share).map(|p| excluded(p, rel)).unwrap_or(false)
    }

    /// This device fetches `rel` in `share` from the others ([`Config::only`], [`Config::never_fetch`]).
    fn wants(&self, share: &str, rel: &str) -> bool {
        let only = self.only.lock().unwrap().get(share).map(|p| excluded(p, rel)).unwrap_or(true);
        only && !self.never_fetch.lock().unwrap().get(share).map(|p| excluded(p, rel)).unwrap_or(false) && !self.is_off(share, rel)
    }

    /// `rel` in `share` is switched off on this device ([`Config::off`]): neither fetched nor offered.
    fn is_off(&self, share: &str, rel: &str) -> bool {
        self.off.lock().unwrap().get(share).map(|p| excluded(p, rel)).unwrap_or(false)
    }

    /// What this device takes from a peer's list of `share`: not what never syncs, not what it does not fetch, and not a delete
    /// that stays on the device it was made on.
    fn remote_view(&self, share: &str, remote: &Index) -> Index {
        let skip = self.skip(share);
        Index {
            files: remote
                .files
                .iter()
                .filter(|(p, e)| !excluded(skip, p) && self.wants(share, p) && !(e.deleted && self.delete_stays_here(share, p)))
                .map(|(p, e)| (p.clone(), e.clone()))
                .collect(),
        }
    }

    /// What this device offers the others of `share`: not what never syncs, not what is switched off here, and not its deletes
    /// that stay here.
    /// A delete waiting to be forgotten because its item was switched on again ([`Inner::refetch`]) is not offered either, so
    /// the other devices never take it meanwhile. The waiting deletes are read before the index: a rescan stores the index
    /// without them first and only then stops holding them back, so whichever index is read here, a delete in it that is
    /// waiting to be forgotten is in `again`.
    fn offered(&self, share: &str) -> Index {
        let skip = self.skip(share);
        let off = self.off.lock().unwrap().get(share).cloned().unwrap_or_default();
        let again: HashSet<String> = self.refetch.lock().unwrap().get(share).map(|v| v.iter().cloned().collect()).unwrap_or_default();
        let idx = self.load_index(share);
        Index {
            files: idx
                .files
                .iter()
                .filter(|(p, e)| !excluded(skip, p) && !excluded(&off, p) && !(e.deleted && (again.contains(*p) || self.delete_stays_here(share, p))))
                .map(|(p, e)| (p.clone(), e.clone()))
                .collect(),
        }
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
            // A write an earlier version started into what never syncs now: whatever is there stays, and it is not finished.
            if excluded(self.skip(&sh.id), &path) {
                let _ = self.unmark_writing(&sh.id, &path);
                continue;
            }
            let Some(full) = safe_join_with(&sh.path, &path, self.hidden_ok(&sh.id)) else {
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
                    if let Some(p) = safe_join_with(&sh.path, &rel, self.hidden_ok(&sh.id)) {
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
        // Deletes made fetchable again since the last round ([`Inner::refetch`]): forgotten, so the merge below fetches them.
        let again = self.refetch.lock().unwrap().get(&share.id).cloned().unwrap_or_default();
        let mut refetched = false;
        for p in &again {
            if idx.files.get(p).map(|e| e.deleted).unwrap_or(false) {
                idx.files.remove(p);
                seen.remove(p);
                refetched = true;
            }
        }
        // Stored at once, and only then no longer held back from what is offered ([`Inner::offered`]): until the index without
        // them is on disk, an answer to another device reads the one with them, and must still leave them out.
        if refetched {
            self.store_index(&share.id, &idx, &seen)?;
        }
        if !again.is_empty() {
            let mut refetch = self.refetch.lock().unwrap();
            if let Some(v) = refetch.get_mut(&share.id) {
                v.retain(|p| !again.contains(p));
                if v.is_empty() {
                    refetch.remove(&share.id);
                }
            }
        }
        if !share.path.is_dir() {
            bail!("{} is missing", share.path.display());
        }
        let root = share.path.clone();
        let skip = self.skip(&share.id).to_vec();
        let hidden = self.hidden_ok(&share.id).to_vec();
        let (files, complete) = tokio::task::spawn_blocking(move || {
            let mut v = Vec::new();
            let mut complete = true;
            walk(&root, &root, &skip, &hidden, &mut v, &mut complete);
            (v, complete)
        })
        .await?;
        // The first scan after the folder was re-pointed ([`Inner::repoint_share`]) only reconciles: what the index lists and the
        // folder lacks is forgotten (the other devices bring it back if they have it), never recorded as a delete. A scan that
        // could not read everything records no deletes either.
        let moved = self.moved_marker(&share.id).as_deref() == Some(share.path.as_path());
        #[cfg(feature = "test-hooks")]
        {
            // A rescan caught between reading the index and storing it: held while `<dir>/hold-rescan` exists (it says so with
            // `<dir>/hold-rescan.held`), so a test can call in meanwhile.
            let hold = self.dir.join("hold-rescan");
            if hold.exists() {
                let _ = std::fs::write(self.dir.join("hold-rescan.held"), b"");
                while hold.exists() {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                let _ = std::fs::remove_file(self.dir.join("hold-rescan.held"));
            }
        }
        let mut changed = refetched;
        // What an earlier version listed under a path that never syncs now is forgotten, not marked deleted: a delete would go to
        // the other devices and remove their own copies.
        let forget: Vec<String> = idx.files.keys().filter(|p| excluded(self.skip(&share.id), p)).cloned().collect();
        for p in forget {
            idx.files.remove(&p);
            seen.remove(&p);
            let _ = self.store.tags().delete(Self::tag_name(&share.id, &p).as_bytes()).await;
            changed = true;
        }
        let mut unsettled = false;
        // The files dated in the future that the last rescan held back, and the ones this rescan holds back ([`Inner::settling`]).
        let watched = self.settling.lock().unwrap().get(&share.id).cloned().unwrap_or_default();
        let mut watching: HashMap<String, Settling> = HashMap::new();
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
            let age = (now_ms() as i64).saturating_sub(key.1);
            if age < SETTLE.as_millis() as i64 {
                // A date in the future says nothing about when the file was last written (a wrong clock on the device that
                // made it): such a file waits until it has been seen unchanged for as long, and no longer.
                let since = match watched.get(&rel) {
                    Some(&(k, since)) if k == key => since,
                    _ => Instant::now(),
                };
                if age >= 0 || since.elapsed() < SETTLE {
                    if age < 0 {
                        watching.insert(rel.clone(), (key, since));
                    }
                    unsettled = true;
                    continue;
                }
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
        // Only what is still held back stays watched: a file that settled, changed or went is dropped.
        if watching.is_empty() {
            self.settling.lock().unwrap().remove(&share.id);
        } else {
            self.settling.lock().unwrap().insert(share.id.clone(), watching);
        }
        // A file still waiting to be written (cut off, to come again) has not gone.
        let gone: Vec<String> = if complete {
            idx.files.iter().filter(|(p, e)| !e.deleted && !present.contains(*p) && !writes.contains_key(*p)).map(|(p, _)| p.clone()).collect()
        } else {
            Vec::new()
        };
        for p in gone {
            if moved {
                stale.push(idx.files[&p].hash.clone());
                idx.files.remove(&p);
                seen.remove(&p);
                let _ = self.store.tags().delete(Self::tag_name(&share.id, &p).as_bytes()).await;
                changed = true;
                continue;
            }
            let old = idx.files[&p].clone();
            stale.push(old.hash.clone());
            idx.files.insert(p.clone(), old.next(&self.me, now_ms(), old.hash.clone(), old.size, true));
            seen.remove(&p);
            let _ = self.store.tags().delete(Self::tag_name(&share.id, &p).as_bytes()).await;
            changed = true;
        }
        self.store_index(&share.id, &idx, &seen)?;
        // Reconciled: normal delete detection resumes (unless the scan was cut short, then the next scan reconciles too).
        if moved && complete && self.moved_marker(&share.id).as_deref() == Some(share.path.as_path()) {
            let _ = std::fs::remove_file(self.moved_path(&share.id));
        }
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

    /// This device's file list as `peer` gets it: only the shares kept with it ([`Config::with`]), with this device's copy of
    /// their link and whether there are secrets for it.
    fn our_index_for(&self, peer: &str) -> RemoteIndex {
        let s = self.saved.lock().unwrap().clone();
        let link = s.peers.iter().find(|p| p.id == peer).and_then(|p| p.link.clone());
        let secrets = self.secrets.lock().unwrap().get(peer).filter(|m| !m.is_empty()).map(secrets_digest);
        RemoteIndex {
            free_bytes: Self::free_bytes(&self.dir),
            name: s.name.clone(),
            shares: s
                .shares
                .iter()
                .filter(|sh| self.shares_with(&sh.id, peer))
                .map(|sh| RemoteShare { id: sh.id.clone(), name: sh.name.clone(), index: self.offered(&sh.id) })
                .collect(),
            link,
            links: true,
            secrets,
        }
    }

    /// `share` is kept with the linked device `peer` ([`Config::with`]).
    fn shares_with(&self, share: &str, peer: &str) -> bool {
        let Some(modes) = self.with.lock().unwrap().get(share).cloned() else { return true };
        let mode = link_mode(self.saved.lock().unwrap().peers.iter().find(|p| p.id == peer).and_then(|p| p.link.as_ref()));
        modes.contains(&mode)
    }

    /// The linked device `peer` has shown that it holds the link too: the link is no longer waiting ([`Peer::unconfirmed`]).
    fn confirm_peer(&self, peer: &str) {
        let changed = {
            let mut sv = self.saved.lock().unwrap();
            sv.peers.iter_mut().find(|p| p.id == peer).map(|p| std::mem::take(&mut p.unconfirmed)).unwrap_or(false)
        };
        if changed {
            let _ = self.save();
        }
    }

    /// How long a link may stay unconfirmed ([`CONFIRM_WINDOW`]).
    fn confirm_window(&self) -> Duration {
        #[cfg(feature = "test-hooks")]
        if let Some(ms) = std::fs::read_to_string(self.dir.join("confirm-window-ms")).ok().and_then(|v| v.trim().parse().ok()) {
            // A test's own, shorter wait: the milliseconds in `<dir>/confirm-window-ms`.
            return Duration::from_millis(ms);
        }
        CONFIRM_WINDOW
    }

    /// Removes the links made here by showing a code that the other device still has not confirmed [`CONFIRM_WINDOW`] after
    /// they were made: it never learned it was linked, so the entry here would stay for ever as a device that never answers.
    /// A confirmed link is never touched.
    fn drop_unconfirmed(&self) {
        let window = self.confirm_window().as_millis() as u64;
        let now = now_ms();
        let mut gone: Vec<Peer> = Vec::new();
        // Saturating: a link dated after now (the clock went back) has waited no time at all.
        self.saved.lock().unwrap().peers.retain(|p| {
            if !p.unconfirmed || now.saturating_sub(p.linked) < window {
                return true;
            }
            gone.push(p.clone());
            false
        });
        if gone.is_empty() {
            return;
        }
        for p in &gone {
            if let Ok(k) = p.id.parse::<EndpointId>() {
                self.allowed.write().unwrap().remove(&k);
            }
            self.run.lock().unwrap().peers.remove(&p.id);
            self.secrets.lock().unwrap().remove(&p.id);
            self.received.lock().unwrap().remove(&p.id);
            self.note(format!("{} did not finish linking with this device, so the link was removed. Link the two again to connect them.", p.name));
        }
        let _ = self.save();
    }

    /// The link as `peer` last set it, when it should replace the copy here (see [`link_replaces`]).
    fn adopt_link(&self, peer: &str, theirs: Link) {
        let changed = {
            let mut sv = self.saved.lock().unwrap();
            let Some(p) = sv.peers.iter_mut().find(|p| p.id == peer) else { return };
            let newer = match &p.link {
                None => true,
                Some(l) => link_replaces(l, &theirs, peer, self.me.as_str()),
            };
            if newer {
                p.link = Some(theirs);
            }
            newer
        };
        if changed {
            let _ = self.save();
        }
    }

    /// Asks `peer` for the secrets it holds for this device.
    async fn fetch_secrets(&self, peer: &str) -> Result<BTreeMap<String, String>> {
        let id: EndpointId = peer.parse().map_err(|_| anyhow!("bad device key"))?;
        let conn = tokio::time::timeout(Duration::from_secs(30), self.endpoint.connect(id, SYNC_ALPN))
            .await
            .map_err(|_| anyhow!("not reachable"))?
            .map_err(|e| anyhow!("not reachable: {e}"))?;
        let (mut send, mut recv) = conn.open_bi().await.map_err(|e| anyhow!("{e}"))?;
        send.write_all(b"secrets").await.map_err(|e| anyhow!("{e}"))?;
        send.finish().map_err(|e| anyhow!("{e}"))?;
        let bytes = tokio::time::timeout(Duration::from_secs(30), recv.read_to_end(1024 * 1024))
            .await
            .map_err(|_| anyhow!("timed out reading the keys"))?
            .map_err(|e| anyhow!("{e}"))?;
        conn.close(0u32.into(), b"done");
        serde_json::from_slice(&bytes).context("the keys from the device are not valid")
    }

    /// Free bytes now on the volume holding `path` (or its nearest existing parent): the figure shown on screen.
    fn free_bytes(path: &Path) -> Option<u64> {
        Self::volume_free(&Self::existing(path)?, false)
    }

    /// What a transfer may count on before the reserve: [`Inner::free_bytes`] everywhere except iPhone, where it also counts half
    /// of the space iOS can purge. Every space check uses this, so the reserve is the only margin.
    fn allowed_bytes(path: &Path) -> Option<u64> {
        Self::volume_free(&Self::existing(path)?, true)
    }

    fn existing(path: &Path) -> Option<PathBuf> {
        let mut p = path.to_path_buf();
        while !p.exists() {
            if !p.pop() {
                return None;
            }
        }
        Some(p)
    }

    /// Free bytes on the volume holding the existing path `p` (fs4, statvfs on unix); `allowance` makes no difference here.
    #[cfg(not(target_os = "ios"))]
    fn volume_free(p: &Path, _allowance: bool) -> Option<u64> {
        fs4::available_space(p).ok()
    }

    /// iPhone: the app's `cache_free_now_bytes_on_disk` (statvfs, same binary) for the figure shown, and its
    /// `cache_free_bytes_on_disk` (free now plus half of what iOS can purge) for the checks.
    #[cfg(target_os = "ios")]
    fn volume_free(p: &Path, allowance: bool) -> Option<u64> {
        use std::os::unix::ffi::OsStrExt;
        extern "C" {
            fn cache_free_bytes_on_disk(path: *const std::ffi::c_char) -> i64;
            fn cache_free_now_bytes_on_disk(path: *const std::ffi::c_char) -> i64;
        }
        let c = std::ffi::CString::new(p.as_os_str().as_bytes()).ok()?;
        // SAFETY: `c` is a valid NUL-terminated path; the helpers only read it.
        let n = unsafe { if allowance { cache_free_bytes_on_disk(c.as_ptr()) } else { cache_free_now_bytes_on_disk(c.as_ptr()) } };
        u64::try_from(n).ok()
    }

    /// One round: rescan every shared folder, then for every linked device fetch its index and apply what is newer there.
    async fn round(self: &Arc<Self>) {
        self.round_with(&Scope::default()).await
    }

    /// A round over what `scope` covers only (Sync now for one device, one kind or one item); the same steps as [`Inner::round`].
    async fn round_with(self: &Arc<Self>, scope: &Scope) {
        let _one = self.round.lock().await;
        let all = self.saved.lock().unwrap().shares.clone();
        if !self.recovered.swap(true, Ordering::Relaxed) {
            for sh in &all {
                self.recover(sh).await;
            }
        }
        let shares: Vec<Share> = all.into_iter().filter(|s| scope.has_share(&s.id)).collect();
        for sh in &shares {
            if let Err(e) = self.rescan(sh).await {
                self.note(format!("{}: {e}", sh.name));
            }
        }
        if !self.network.load(Ordering::Relaxed) {
            self.run.lock().unwrap().paused = Some("Sync is paused: no network it may use".into());
            return;
        }
        self.drop_unconfirmed();
        let peers: Vec<Peer> = self.saved.lock().unwrap().peers.iter().filter(|p| scope.has_peer(&p.id)).cloned().collect();
        // First every reachable peer's index, so each file can be fetched from every peer that has it.
        for p in &peers {
            if !self.may_use_network() {
                break;
            }
            let res = self.fetch_index(&p.id).await;
            let mut asks = None;
            let mut learned = None;
            // A file list that carries the device's own copy of the link shows it holds the link too. (That it answered is not
            // enough: a device still waiting for the answer to a code already lets this one in.)
            if p.unconfirmed && res.as_ref().map(|(idx, _)| idx.link.is_some()).unwrap_or(false) {
                self.confirm_peer(&p.id);
            }
            {
                let mut run = self.run.lock().unwrap();
                let st = run.peers.entry(p.id.clone()).or_default();
                match res {
                    Ok((idx, via)) => {
                        st.last_seen = Some(now_ms());
                        learned = Some((idx.name.clone(), via.clone()));
                        st.via = Some(via);
                        st.error = None;
                        asks = Some((idx.link.clone(), idx.secrets.clone()));
                        st.index = Some(idx);
                    }
                    Err(e) => {
                        st.via = None;
                        st.error = Some(format!("{e:#}"));
                    }
                }
            }
            if let Some((name, via)) = learned {
                // Saved with the time and the name the device gave itself, so "last seen" survives a restart and a rename shows.
                let changed = {
                    let mut sv = self.saved.lock().unwrap();
                    sv.peers.iter_mut().find(|x| x.id == p.id).map(|sp| sp.seen(now_ms(), &via) | sp.adopt_name(&name)).unwrap_or(false)
                };
                if changed {
                    let _ = self.save();
                }
            }
            let Some((link, secrets)) = asks else { continue };
            if let Some(l) = link {
                self.adopt_link(&p.id, l);
            }
            if let Some(d) = secrets {
                let have = self.received.lock().unwrap().get(&p.id).map(|(x, _)| x.clone());
                if have.as_deref() != Some(d.as_str()) {
                    match self.fetch_secrets(&p.id).await {
                        Ok(m) => {
                            self.received.lock().unwrap().insert(p.id.clone(), (secrets_digest(&m), Some(m)));
                        }
                        Err(e) => self.note(format!("Keys from {}: {e:#}", p.name)),
                    }
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
                if !self.shares_with(&sh.id, &p.id) {
                    continue;
                }
                match self.apply(sh, &scope.narrow(&rs.index), &p.id).await {
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
        if scope.whole() {
            run.rounds += 1;
            run.last_round = Some(now_ms());
        }
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

    /// Who has `hash` (by their last index), us excluded, among the devices `share` is kept with.
    fn providers(&self, share: &str, hash: &str) -> Vec<EndpointId> {
        let found: Vec<String> = {
            let run = self.run.lock().unwrap();
            run.peers
                .iter()
                .filter(|(_, s)| s.error.is_none())
                .filter(|(_, s)| s.index.as_ref().map(|i| i.shares.iter().any(|sh| sh.index.files.values().any(|e| !e.deleted && e.hash == hash))).unwrap_or(false))
                .map(|(id, _)| id.clone())
                .collect()
        };
        found.into_iter().filter(|id| self.shares_with(share, id)).filter_map(|id| id.parse().ok()).collect()
    }

    /// Takes from `from` what is newer there. A file that cannot be fetched or deleted is noted and the rest goes on, so one
    /// bad file does not hold up its share; only losing the network stops it. A file with no room for it is passed over and
    /// comes back as the error at the end, so the status still says sync is paused.
    async fn apply(self: &Arc<Self>, sh: &Share, remote: &Index, from: &str) -> Result<()> {
        let remote = &self.remote_view(&sh.id, remote);
        let mut actions = index::merge(&self.load_index(&sh.id), remote);
        // What says the rest has come comes after the rest ([`Config::last`]); the sort keeps the order otherwise.
        let last: &[String] = self.last.get(&sh.id).map(|v| v.as_slice()).unwrap_or(&[]);
        if !last.is_empty() {
            actions.sort_by_key(|a| matches!(a, Action::Fetch { path, .. } if excluded(last, path)));
        }
        // Something did not come or go in this call (it failed, or was put off): what says the rest has come must wait too.
        let mut held = false;
        let mut no_room: Option<anyhow::Error> = None;
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
                    let Some(full) = safe_join_with(&sh.path, &path, self.hidden_ok(&sh.id)) else { continue };
                    let done: Result<()> = async {
                        let mut idx = self.load_index(&sh.id);
                        let mut seen = self.load_seen(&sh.id);
                        // Only what is still exactly the version the peer deleted (a newer local change shows up as a newer version).
                        if let Ok(m) = std::fs::metadata(&full) {
                            if seen.get(&path) != Some(&(m.len(), mtime_ms(&m))) {
                                return Ok(());
                            }
                            std::fs::remove_file(&full).with_context(|| format!("could not delete {path}"))?;
                            prune_empty(&sh.path, &full, self.skip(&sh.id));
                        }
                        let _ = self.store.tags().delete(Self::tag_name(&sh.id, &path).as_bytes()).await;
                        seen.remove(&path);
                        idx.files.insert(path.clone(), entry);
                        self.store_index(&sh.id, &idx, &seen)?;
                        self.unmark_writing(&sh.id, &path)?;
                        self.note(format!("{}: {} deleted {path}", sh.name, self.peer_name(from)));
                        Ok(())
                    }
                    .await;
                    if let Err(e) = done {
                        held = true;
                        self.note(format!("{} from {}: {e:#}", sh.name, self.peer_name(from)));
                    }
                }
                Action::Fetch { path, entry, conflict } => {
                    // Not while anything before it is missing: it stays for a later round.
                    if held && excluded(last, &path) {
                        continue;
                    }
                    match self.fetch(sh, &path, entry, conflict, from).await {
                        Ok(true) => {}
                        Ok(false) => held = true,
                        Err(e) => {
                            held = true;
                            let msg = format!("{e:#}");
                            // With no network it may use nothing else can come either: the round says sync is paused.
                            if !self.may_use_network() || msg.starts_with("Paused: no network") || msg.contains("paused, no network") {
                                return Err(e);
                            }
                            if msg.starts_with("Paused:") {
                                // No room for this one; a smaller file after it may still fit.
                                if no_room.is_none() {
                                    no_room = Some(e);
                                }
                            } else {
                                self.note(format!("{} from {}: {msg}", sh.name, self.peer_name(from)));
                            }
                        }
                    }
                }
            }
        }
        match no_room {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Fetches one file and writes it in place. False when it was put off (the file here is not what was last indexed), so
    /// the caller knows it has not come yet.
    async fn fetch(self: &Arc<Self>, sh: &Share, path: &str, entry: Entry, conflict: bool, from: &str) -> Result<bool> {
        #[cfg(feature = "test-hooks")]
        if std::fs::read_to_string(self.dir.join("fail-fetch")).map(|v| v.trim() == path).unwrap_or(false) {
            // A file that cannot be fetched: the one `<dir>/fail-fetch` names, for as long as it names it.
            bail!("test: could not fetch {path}");
        }
        let Some(full) = safe_join_with(&sh.path, path, self.hidden_ok(&sh.id)) else {
            self.note(format!("{}: skipped an unsafe name from {}", sh.name, self.peer_name(from)));
            return Ok(true);
        };
        // A file here that is not what this device last indexed (an edit still settling, or a new file of the same name not
        // scanned yet) is never written over: the next scan indexes it, and the comparison after that keeps both if they differ.
        if let Ok(m) = std::fs::metadata(&full) {
            if self.load_seen(&sh.id).get(path) != Some(&(m.len(), mtime_ms(&m))) {
                self.settle_again.store(true, Ordering::Relaxed);
                return Ok(false);
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
                if let Some(free) = Self::allowed_bytes(at) {
                    if free < need.saturating_add(reserve) {
                        bail!(
                            "Paused: {} needs {}, {} is free and {} is kept free",
                            path,
                            human(need),
                            human(Self::free_bytes(at).unwrap_or(free)),
                            human(reserve)
                        );
                    }
                }
            }
            let providers = self.providers(&sh.id, &entry.hash);
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
                        DownloadProgressItem::Error(e) => failed = Some(if is_no_space(&e) { NO_SPACE.to_string() } else { format!("{e}") }),
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
                if f == NO_SPACE {
                    bail!("Paused: no room to keep {path} ({} needed). Free up space and it carries on.", human(need));
                }
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
        let size_of_entry = entry.size;
        if let Err(e) = self.store.export_with_opts(ExportOptions { hash, mode: ExportMode::TryReference, target: full.clone() }).finish().await {
            // Whatever part got written goes; the content stays in the store and the next round writes it again.
            if std::fs::remove_file(&full).is_err() && full.exists() {
                // Left for the recovery a start does, before the next scan could take it for an edit.
                self.recovered.store(false, Ordering::Relaxed);
            }
            if is_no_space(&e) {
                bail!("Paused: no room to write {path} ({} needed). Free up space and it carries on.", human(size_of_entry));
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
        Ok(true)
    }
}

/// The failure text that stands for a full disk while a transfer is fetched (so it is not shown as a raw error).
const NO_SPACE: &str = "no space left on the device";

/// True when `e` (or an error it wraps) is the operating system's "disk full" (ENOSPC, 28 on iOS, Android and Linux).
fn is_no_space(e: &(dyn std::error::Error + 'static)) -> bool {
    let mut cur: Option<&(dyn std::error::Error + 'static)> = Some(e);
    while let Some(err) = cur {
        if let Some(io) = err.downcast_ref::<std::io::Error>() {
            if io.raw_os_error() == Some(28) {
                return true;
            }
        }
        cur = err.source();
    }
    false
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

/// Reads the links and shares (`sync.json`), and what to say in the activity if they were not simply read. A missing file is a
/// fresh start. A file that is there but cannot be read is an error, so nothing is saved over it and the app can try again. A
/// file that does not parse is moved aside (never deleted) and the last good copy (`sync.json.bak`) is used; with no good copy
/// the device starts with no links.
fn load_saved(p: &Path) -> Result<(Saved, Option<String>)> {
    let bytes = match std::fs::read(p) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Saved::default(), None)),
        Err(e) => bail!("could not read {}: {e}", p.display()),
    };
    if let Ok(saved) = serde_json::from_slice::<Saved>(&bytes) {
        return Ok((saved, None));
    }
    // An earlier damaged file is kept too.
    let mut aside = p.with_extension("json.damaged");
    if aside.exists() {
        aside = p.with_extension(format!("json.damaged.{}", now_ms()));
    }
    std::fs::rename(p, &aside).with_context(|| format!("could not move the damaged {} aside", p.display()))?;
    let bak = p.with_extension("json.bak");
    match read_json::<Saved>(&bak) {
        Some(saved) => {
            // Put back at once, so a start that fails further on does not leave the next one with no links file at all.
            std::fs::copy(&bak, p).with_context(|| format!("could not restore {}", p.display()))?;
            Ok((saved, Some("The saved links could not be read; they were restored from the last good copy".into())))
        }
        None => Ok((
            Saved::default(),
            Some(format!(
                "The saved links could not be read and there was no good copy: this device starts with no links (the damaged file is kept as {})",
                aside.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            )),
        )),
    }
}

/// Writes the links and shares (`sync.json`): flushed to disk before it replaces the file, and the file it replaces is kept as
/// `sync.json.bak` when it is a good one, so a damaged file can be put right at the next start ([`load_saved`]).
fn write_saved(p: &Path, v: &Saved) -> Result<()> {
    use std::io::Write as _;
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = p.with_extension("tmp");
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(&serde_json::to_vec(v)?)?;
    f.sync_all()?;
    drop(f);
    // Only a file that still parses is worth keeping; failing to keep it does not stop the save.
    if let Ok(old) = std::fs::read(p) {
        if serde_json::from_slice::<Saved>(&old).is_ok() {
            let bak_tmp = p.with_extension("bak.tmp");
            if std::fs::write(&bak_tmp, &old).is_ok() {
                let _ = std::fs::rename(&bak_tmp, p.with_extension("json.bak"));
            }
        }
    }
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
            // Not confirmed until the other device comes back: this answer may never reach it.
            add_peer(inner, &id.to_string(), &h.name, true);
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

fn add_peer(inner: &Inner, id: &str, name: &str, unconfirmed: bool) {
    {
        let mut s = inner.saved.lock().unwrap();
        s.peers.retain(|p| p.id != id);
        s.peers.push(Peer { id: id.to_string(), name: name.to_string(), linked: now_ms(), link: Some(new_link()), last_seen: None, via: None, announced: Some(name.to_string()), unconfirmed });
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
        let ask = recv.read_to_end(64).await.map_err(AcceptError::from_err)?;
        let peer = conn.remote_id().to_string();
        // Only a device that holds the link asks: a link made here by showing a code is confirmed by it.
        self.0.confirm_peer(&peer);
        if ask == b"secrets" {
            // Only the secrets set for the device asking, over its own connection (end to end encrypted to its key).
            let mine = self.0.secrets.lock().unwrap().get(&peer).cloned().unwrap_or_default();
            send.write_all(&serde_json::to_vec(&mine).unwrap_or_default()).await.map_err(AcceptError::from_err)?;
            send.finish()?;
            conn.closed().await;
            return Ok(());
        }
        let inner = self.0.clone();
        let body = tokio::task::spawn_blocking(move || serde_json::to_vec(&inner.our_index_for(&peer)).unwrap_or_default())
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
                // The round runs as a task of its own: if it panics, only that round ends, and the next one comes after the usual
                // wait (in the loop itself a panic would end every later round until the app is started again).
                let inner3 = inner2.clone();
                let one = tokio::spawn(async move {
                    #[cfg(feature = "test-hooks")]
                    {
                        // One round that panics: when `<dir>/panic-round` exists (taken away first, so only one does).
                        let marker = inner3.dir.join("panic-round");
                        if marker.exists() {
                            let _ = std::fs::remove_file(&marker);
                            panic!("test: a round panicked");
                        }
                    }
                    inner3.round().await
                });
                if let Err(e) = one.await {
                    if e.is_panic() {
                        let p = e.into_panic();
                        let msg = p.downcast_ref::<&str>().map(|m| m.to_string()).or_else(|| p.downcast_ref::<String>().cloned()).unwrap_or_else(|| "no details".into());
                        // Said even if the panic left the run log's lock poisoned: this line must not end the loop too.
                        inner2.run.lock().unwrap_or_else(|l| l.into_inner()).note(format!("Sync stopped on an internal error and started again: {msg}"));
                    }
                }
                let wait = if inner2.settle_again.swap(false, Ordering::Relaxed) { SETTLE + Duration::from_secs(1) } else { every };
                let _ = tokio::time::timeout(wait, inner2.wake.notified()).await;
            }
        });
        Ok(SyncEngine { rt, inner, router: Some(router) })
    }

    async fn start(cfg: Config) -> Result<(Arc<Inner>, Router)> {
        std::fs::create_dir_all(&cfg.dir)?;
        // Read before anything is written: if the links cannot be read now, nothing here may be changed.
        let (mut saved, saved_note) = load_saved(&cfg.dir.join("sync.json"))?;
        let (secret, _) = identity::load_or_create(&cfg.dir)?;
        if saved.name.is_empty() {
            saved.name = cfg.name.clone().unwrap_or_else(|| "Cache device".into());
        }
        if migrate_links(&mut saved) {
            write_saved(&cfg.dir.join("sync.json"), &saved)?;
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
            settling: Mutex::new(HashMap::new()),
            recovered: AtomicBool::new(false),
            exclude: cfg.exclude.clone(),
            local_deletes: cfg.local_deletes.clone(),
            only: Mutex::new(cfg.only.clone()),
            last: cfg.last.clone(),
            never_fetch: Mutex::new(cfg.never_fetch.clone()),
            hidden: cfg.hidden.clone(),
            off: Mutex::new(cfg.off.clone()),
            refetch: Mutex::new(HashMap::new()),
            with: Mutex::new(cfg.with.clone()),
            secrets: Mutex::new(HashMap::new()),
            received: Mutex::new(HashMap::new()),
        });
        inner.save()?;
        let blobs = BlobsProtocol::new(&store, None);
        let router = Router::builder(endpoint)
            .accept(iroh_blobs::ALPN, blobs)
            .accept(PAIR_ALPN, PairProto(inner.clone()))
            .accept(SYNC_ALPN, SyncProto(inner.clone()))
            .spawn();
        inner.note("Started");
        if let Some(n) = saved_note {
            inner.note(n);
        }
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
                add_peer(inner, &peer.to_string(), &pname, false);
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
                inner.secrets.lock().unwrap().remove(&id);
                inner.received.lock().unwrap().remove(&id);
                inner.save()?;
                Ok(json!({"ok": true}))
            }
            "set_link" => {
                // What the two devices keep about their link (see Link), set here now: the other device takes it from the next
                // file list it gets, so both end up the same.
                let id = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                let v = args.get("link").cloned().filter(|v| v.is_object()).ok_or_else(|| anyhow!("link must be an object"))?;
                let t = {
                    let mut sv = inner.saved.lock().unwrap();
                    let p = sv.peers.iter_mut().find(|p| p.id == id).ok_or_else(|| anyhow!("that device is not linked"))?;
                    let t = now_ms().max(p.link.as_ref().map(|l| l.t + 1).unwrap_or(0));
                    p.link = Some(Link { v, t });
                    t
                };
                inner.save()?;
                inner.wake.notify_one();
                Ok(json!({"ok": true, "t": t}))
            }
            "set_share_with" => {
                // Which link kinds a share is kept with from now on (null: every linked device). See Config::with.
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                match args.get("with") {
                    None | Some(Value::Null) => {
                        inner.with.lock().unwrap().remove(&id);
                    }
                    Some(Value::Array(a)) => {
                        let list: Vec<String> = a.iter().filter_map(|v| v.as_str().map(String::from)).collect();
                        inner.with.lock().unwrap().insert(id, list);
                    }
                    Some(_) => bail!("with must be a list of link kinds or null"),
                }
                inner.wake.notify_one();
                Ok(json!({"ok": true}))
            }
            "set_secrets" => {
                // The secrets for one linked device ({name: value}; empty: none). Kept in memory only, never written by the
                // engine, and sent only to that device when it asks (it is told they changed with this device's file list).
                let id = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                if !inner.saved.lock().unwrap().peers.iter().any(|p| p.id == id) {
                    bail!("that device is not linked");
                }
                let mut m = BTreeMap::new();
                match args.get("secrets") {
                    None | Some(Value::Null) => {}
                    Some(Value::Object(o)) => {
                        for (k, v) in o {
                            let v = v.as_str().ok_or_else(|| anyhow!("each secret must be a string"))?;
                            m.insert(k.clone(), v.to_string());
                        }
                    }
                    Some(_) => bail!("secrets must be an object"),
                }
                let changed = {
                    let mut sec = inner.secrets.lock().unwrap();
                    let was = sec.get(&id).cloned().unwrap_or_default();
                    if m.is_empty() {
                        sec.remove(&id);
                    } else {
                        sec.insert(id, m.clone());
                    }
                    was != m
                };
                if changed {
                    inner.wake.notify_one();
                }
                Ok(json!({"ok": true}))
            }
            "take_secrets" => {
                // The secrets linked devices sent since the last call, by device, handed over once (the app keeps them in the
                // phone's secure storage); the engine keeps only their digest.
                let mut out = serde_json::Map::new();
                for (peer, (_, m)) in inner.received.lock().unwrap().iter_mut() {
                    if let Some(m) = m.take() {
                        out.insert(peer.clone(), json!(m));
                    }
                }
                Ok(json!({"secrets": out}))
            }
            "share_add" => {
                let path = PathBuf::from(s("path").ok_or_else(|| anyhow!("path is required"))?);
                if !path.is_dir() {
                    bail!("{} is not a folder", path.display());
                }
                let name = s("name").unwrap_or_else(|| path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "Shared".into()));
                let id = s("id").unwrap_or_else(|| token()[..13].to_lowercase());
                inner.upsert_share(&id, name, path)?;
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
                inner.upsert_share(&id, name, path)?;
                inner.wake.notify_one();
                Ok(json!({"ok": true}))
            }
            "set_only" => {
                // What this device fetches of a share from now on (null: everything). Deletes kept here under paths it starts
                // fetching again are forgotten, so what it lists comes back (a source added again gets its snapshots again).
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let new: Option<Vec<String>> = match args.get("only") {
                    None | Some(Value::Null) => None,
                    Some(Value::Array(a)) => Some(a.iter().filter_map(|v| v.as_str().map(String::from)).collect()),
                    Some(_) => bail!("only must be a list of patterns or null"),
                };
                let was = inner.only.lock().unwrap().get(&id).cloned();
                let now_wanted = |p: &str| new.as_ref().map(|n| excluded(n, p)).unwrap_or(true);
                let was_wanted = |p: &str| was.as_ref().map(|n| excluded(n, p)).unwrap_or(true);
                // The index is only read here: the next round forgets these deletes inside its own rescan, so a round that is
                // running now cannot store its copy of the index over the change (it did, now and then, and they never came back).
                let idx = inner.load_index(&id);
                let back: Vec<String> = idx
                    .files
                    .iter()
                    .filter(|(p, e)| e.deleted && inner.delete_stays_here(&id, p) && now_wanted(p) && !was_wanted(p))
                    .map(|(p, _)| p.clone())
                    .collect();
                if !back.is_empty() {
                    inner.refetch.lock().unwrap().entry(id.clone()).or_default().extend(back.iter().cloned());
                }
                {
                    let mut only = inner.only.lock().unwrap();
                    match new {
                        Some(n) => only.insert(id.clone(), n),
                        None => only.remove(&id),
                    };
                }
                inner.wake.notify_one();
                Ok(json!({"ok": true, "fetchable_again": back.len()}))
            }
            "set_never_fetch" => {
                // What this device never fetches of a share from now on, on top of what it fetches (null or []: nothing more).
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let list: Vec<String> = match args.get("never_fetch") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
                    Some(_) => bail!("never_fetch must be a list of patterns or null"),
                };
                {
                    let mut nf = inner.never_fetch.lock().unwrap();
                    if list.is_empty() {
                        nf.remove(&id);
                    } else {
                        nf.insert(id.clone(), list);
                    }
                }
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
                // With no scope, a round of everything now. With one, a round of just that (one device, some shared folders,
                // some paths in them) on its own, after any round running now: what Sync now on a device, a kind or an item does.
                let list = |k: &str| -> Result<Option<Vec<String>>> {
                    match args.get(k) {
                        None | Some(Value::Null) => Ok(None),
                        Some(Value::Array(a)) => Ok(Some(a.iter().filter_map(|v| v.as_str().map(String::from)).collect())),
                        Some(_) => bail!("{k} must be a list"),
                    }
                };
                let scope = Scope { peer: s("peer"), shares: list("shares")?.or_else(|| s("share").map(|x| vec![x])), paths: list("paths")? };
                if scope.whole() {
                    inner.wake.notify_one();
                    return Ok(json!({"ok": true}));
                }
                {
                    let sv = inner.saved.lock().unwrap();
                    if let Some(p) = &scope.peer {
                        if !sv.peers.iter().any(|x| x.id == *p) {
                            bail!("that device is not linked");
                        }
                    }
                    for id in scope.shares.iter().flatten() {
                        if !sv.shares.iter().any(|x| x.id == *id) {
                            bail!("{id} is not shared");
                        }
                    }
                }
                let inner2 = inner.clone();
                self.rt.spawn(async move { inner2.round_with(&scope).await });
                Ok(json!({"ok": true}))
            }
            "set_off" => {
                // What this device has switched off in a share from now on (null or []: nothing). Deletes made here under paths
                // switched on again are forgotten, so the copies the other devices kept come back.
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let list: Vec<String> = match args.get("off") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
                    Some(_) => bail!("off must be a list of patterns or null"),
                };
                let was = inner.off.lock().unwrap().get(&id).cloned().unwrap_or_default();
                let back: Vec<String> = inner
                    .load_index(&id)
                    .files
                    .iter()
                    .filter(|(p, e)| e.deleted && excluded(&was, p) && !excluded(&list, p))
                    .map(|(p, _)| p.clone())
                    .collect();
                if !back.is_empty() {
                    inner.refetch.lock().unwrap().entry(id.clone()).or_default().extend(back.iter().cloned());
                }
                {
                    let mut off = inner.off.lock().unwrap();
                    if list.is_empty() {
                        off.remove(&id);
                    } else {
                        off.insert(id.clone(), list);
                    }
                }
                inner.wake.notify_one();
                Ok(json!({"ok": true, "fetchable_again": back.len()}))
            }
            "share_items" => {
                // A share's items: its paths grouped by their first `depth` segments (a library's folder, a ZIM, a map layer's
                // file), with what this device holds of each and what each linked device offers, so the person can choose items
                // a device has not fetched yet.
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let depth = args.get("depth").and_then(|v| v.as_u64()).unwrap_or(1).clamp(1, 16) as usize;
                let key = |p: &str| p.split('/').take(depth).collect::<Vec<_>>().join("/");
                #[derive(Default)]
                struct Item {
                    files: u64,
                    bytes: u64,
                    peers: BTreeMap<String, (u64, u64)>,
                }
                let saved = inner.saved.lock().unwrap().clone();
                let mut items: BTreeMap<String, Item> = BTreeMap::new();
                if saved.shares.iter().any(|x| x.id == id) {
                    for (p, e) in inner.load_index(&id).files.iter().filter(|(p, e)| !e.deleted && !excluded(inner.skip(&id), p)) {
                        let it = items.entry(key(p)).or_default();
                        it.files += 1;
                        it.bytes += e.size;
                    }
                }
                {
                    let run = inner.run.lock().unwrap();
                    for p in &saved.peers {
                        if !inner.shares_with(&id, &p.id) {
                            continue;
                        }
                        let Some(rs) = run.peers.get(&p.id).and_then(|st| st.index.as_ref()).and_then(|i| i.shares.iter().find(|x| x.id == id)) else {
                            continue;
                        };
                        for (path, e) in inner.without_excluded(&id, &rs.index).files.iter().filter(|(_, e)| !e.deleted) {
                            let c = items.entry(key(path)).or_default().peers.entry(p.id.clone()).or_default();
                            c.0 += 1;
                            c.1 += e.size;
                        }
                    }
                }
                let peer_name = |id: &str| saved.peers.iter().find(|p| p.id == id).map(|p| p.name.clone()).unwrap_or_default();
                let out: Vec<Value> = items
                    .iter()
                    .map(|(name, it)| {
                        let peers: Vec<Value> =
                            it.peers.iter().map(|(pid, (n, b))| json!({"peer": pid, "peer_name": peer_name(pid), "files": n, "bytes": b})).collect();
                        json!({"name": name, "files": it.files, "bytes": it.bytes, "peers": peers})
                    })
                    .collect();
                Ok(json!({"items": out}))
            }
            "set_peer_name" => {
                // What this device calls a linked device (its own name for itself stays its own).
                let id = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                let name = s("name").map(|n| n.trim().to_string()).filter(|n| !n.is_empty()).ok_or_else(|| anyhow!("name is required"))?;
                {
                    let mut sv = inner.saved.lock().unwrap();
                    let p = sv.peers.iter_mut().find(|p| p.id == id).ok_or_else(|| anyhow!("that device is not linked"))?;
                    p.name = name;
                }
                inner.save()?;
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
                        if !joined.contains(sh.id.as_str()) && inner.shares_with(&sh.id, &p.id) {
                            let offered = inner.without_excluded(&sh.id, &sh.index);
                            let live = offered.files.values().filter(|e| !e.deleted);
                            let (n, b) = live.fold((0u64, 0u64), |(n, b), e| (n + 1, b + e.size));
                            offers.push(json!({"peer": p.id, "peer_name": p.name, "id": sh.id, "name": sh.name, "files": n, "bytes": b}));
                        }
                    }
                }
                let free = st.index.as_ref().and_then(|i| i.free_bytes);
                json!({
                    "id": p.id, "name": p.name, "linked": p.linked, "last_seen": st.last_seen.or(p.last_seen), "via": st.via.clone().or(p.via.clone()), "live": st.last_seen.is_some(), "error": st.error,
                    "free_bytes": free,
                    "link": p.link.as_ref().map(|l| l.v.clone()), "link_t": p.link.as_ref().map(|l| l.t),
                    "link_known": st.index.as_ref().map(|i| i.links).unwrap_or(false),
                    "unconfirmed": p.unconfirmed,
                })
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
                for (pid, st) in run.peers.iter() {
                    if !inner.shares_with(&sh.id, pid) {
                        continue;
                    }
                    if let Some(rs) = st.index.as_ref().and_then(|i| i.shares.iter().find(|x| x.id == sh.id)) {
                        for a in index::merge(&idx, &inner.remote_view(&sh.id, &rs.index)) {
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
                    "only": inner.only.lock().unwrap().get(&sh.id).cloned(),
                    "never_fetch": inner.never_fetch.lock().unwrap().get(&sh.id).cloned(),
                    "off": inner.off.lock().unwrap().get(&sh.id).cloned(),
                    "with": inner.with.lock().unwrap().get(&sh.id).cloned(),
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

    /// The UDP port this device listens on (IPv4): the one `port` named, or the one the system gave when `port` was 0 or
    /// absent. A device found again only by its address (no lookup service) is opened again on it.
    pub fn port(&self) -> Option<u16> {
        self.inner.endpoint.bound_sockets().into_iter().find(|a| a.is_ipv4()).map(|a| a.port())
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


#[cfg(test)]
mod space_tests {
    use super::*;

    #[derive(Debug)]
    struct Wrapped(std::io::Error);
    impl std::fmt::Display for Wrapped {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("could not export")
        }
    }
    impl std::error::Error for Wrapped {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            Some(&self.0)
        }
    }

    #[test]
    fn a_full_disk_is_told_from_other_errors() {
        assert!(is_no_space(&std::io::Error::from_raw_os_error(28)));
        assert!(is_no_space(&Wrapped(std::io::Error::from_raw_os_error(28))));
        assert!(!is_no_space(&std::io::Error::from_raw_os_error(13)));
        assert!(!is_no_space(&std::io::Error::new(std::io::ErrorKind::NotFound, "gone")));
    }

    #[test]
    fn checks_use_the_allowance_and_screens_the_free_figure() {
        // Off iPhone the two are the same statvfs figure; on iPhone the allowance can be larger, never smaller.
        let d = std::env::temp_dir();
        let (now, allowed) = (Inner::free_bytes(&d).unwrap(), Inner::allowed_bytes(&d).unwrap());
        assert!(allowed >= now.saturating_sub(1 << 20));
    }
}

#[cfg(test)]
mod link_merge_tests {
    use super::*;

    fn l(v: Value, t: u64) -> Link {
        Link { v, t }
    }
    fn answered(mode: &str, by: &str, at: u64, t: u64) -> Link {
        l(json!({"mode": mode, "from": by, "by": by, "at": at}), t)
    }

    #[test]
    fn an_answer_beats_the_pending_question() {
        let pending = new_link();
        let a = answered("send", "a", 100, 100);
        assert!(link_replaces(&pending, &a, "a", "b"));
        assert!(!link_replaces(&a, &pending, "b", "a"));
    }

    #[test]
    fn the_earlier_answer_wins_whatever_the_stamp() {
        let first = answered("send", "a", 100, 100);
        // b answered Off later but its record was stamped later too.
        let late = answered("off", "b", 200, 205);
        assert!(!link_replaces(&first, &late, "b", "a"));
        assert!(link_replaces(&late, &first, "a", "b"));
    }

    #[test]
    fn the_same_moment_goes_to_the_lower_id_and_both_agree() {
        let a = answered("send", "a", 100, 100);
        let b = answered("off", "b", 100, 101);
        assert!(!link_replaces(&a, &b, "b", "a"));
        assert!(link_replaces(&b, &a, "a", "b"));
    }

    #[test]
    fn a_later_change_to_the_same_answer_wins() {
        let a = answered("send", "a", 100, 100);
        let mut changed = answered("match", "a", 100, 300);
        changed.v["from"] = json!("b");
        assert!(link_replaces(&a, &changed, "a", "b"));
        assert!(!link_replaces(&changed, &a, "a", "b"));
    }

    #[test]
    fn records_with_no_answer_keep_the_later_stamp_rule() {
        let old = l(json!({"mode": "match"}), 5);
        let newer = l(json!({"mode": "off"}), 9);
        assert!(link_replaces(&old, &newer, "p", "m"));
        assert!(!link_replaces(&newer, &old, "p", "m"));
    }
}

#[cfg(test)]
mod peer_tests {
    use super::*;

    fn peer() -> Peer {
        Peer { id: "p".into(), name: "Android device".into(), linked: 1, link: None, last_seen: None, via: None, announced: Some("Android device".into()), unconfirmed: false }
    }

    #[test]
    fn last_seen_and_via_survive_a_save() {
        let mut p = peer();
        assert!(p.seen(1_000_000, "relay"));
        let back: Peer = serde_json::from_slice(&serde_json::to_vec(&p).unwrap()).unwrap();
        assert_eq!((back.last_seen, back.via.as_deref()), (Some(1_000_000), Some("relay")));
    }

    #[test]
    fn a_file_saved_before_last_seen_existed_loads_with_none() {
        let old = r#"{"name":"Me","peers":[{"id":"p","name":"Desk","linked":5}],"shares":[]}"#;
        let saved: Saved = serde_json::from_str(old).unwrap();
        let p = &saved.peers[0];
        assert_eq!((p.last_seen, p.via.clone(), p.announced.clone()), (None, None, None));
        // Nothing new is written for a device that never answered.
        assert!(!serde_json::to_string(p).unwrap().contains("last_seen"));
    }

    #[test]
    fn the_time_is_written_at_most_about_once_a_minute() {
        let mut p = peer();
        assert!(p.seen(1_000_000, "direct"), "the first time is written");
        assert!(!p.seen(1_000_000 + 59_999, "relay"), "not again within the minute");
        assert_eq!((p.last_seen, p.via.as_deref()), (Some(1_000_000), Some("direct")));
        assert!(p.seen(1_000_000 + 60_000, "relay"), "after the minute it is");
        assert_eq!((p.last_seen, p.via.as_deref()), (Some(1_060_000), Some("relay")));
        assert!(p.seen(500_000, "direct"), "a clock that went back does not stop it");
    }

    #[test]
    fn a_rename_on_the_other_device_is_taken() {
        let mut p = peer();
        assert!(!p.adopt_name("Android device"), "same name: nothing to write");
        assert!(p.adopt_name("Pixel nine"));
        assert_eq!(p.name, "Pixel nine");
        assert!(!p.adopt_name("Pixel nine"));
        assert!(!p.adopt_name("  "), "an empty name is ignored");
        assert_eq!(p.name, "Pixel nine");
    }

    #[test]
    fn a_name_set_here_stays_until_the_device_renames_itself() {
        let mut p = peer();
        p.name = "Kitchen tablet".into(); // Rename on this device
        assert!(!p.adopt_name("Android device"), "the device still calls itself what it did");
        assert_eq!(p.name, "Kitchen tablet");
        assert!(p.adopt_name("Pixel 9"));
        assert_eq!(p.name, "Pixel 9");
    }

    #[test]
    fn an_old_file_takes_the_name_the_device_announces() {
        let old = r#"{"id":"p","name":"Android device","linked":5}"#;
        let mut p: Peer = serde_json::from_str(old).unwrap();
        assert!(p.adopt_name("Pixel nine"));
        assert_eq!(p.name, "Pixel nine");
    }
}
