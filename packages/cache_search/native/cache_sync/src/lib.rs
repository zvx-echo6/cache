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

pub mod blobs;
pub mod bridge;
pub mod delta;
pub mod identity;
pub mod index;
pub mod transport;
#[cfg(any(target_os = "linux", target_os = "android"))]
mod rns_transport;

use anyhow::{anyhow, bail, Context, Result};
use index::{Action, Entry, Index, Ver};
use iroh::{
    endpoint::{presets, VarInt},
    Endpoint, EndpointAddr, PublicKey, RelayMode, RelayUrl, SecretKey, Signature,
};
use blobs::Blobs;
use cache_store::{Hash, Options as StoreOptions, Store};
use n0_future::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::Notify;
use transport::{Ask, Delta, FetchEvent, IrohTransport, PairTarget, Serve, Speed, Transport};

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
/// Two refusals of "not linked" from the same device must be at least this far apart before this device drops the link.
const UNLINK_INTERVAL: Duration = Duration::from_secs(10 * 60);
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

/// The lines the open has said and nobody has taken yet, oldest first. Nothing calls out to the app: a callback into Dart from an
/// engine thread aborted the process in a background (WorkManager) isolate ("Cannot invoke native callback from a leaf call"), so the
/// app asks for the lines instead ([`take_log`]).
static LOG_BUF: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// The most lines kept: an app that never asks must not grow it without end (the oldest go first).
const LOG_KEEP: usize = 2000;

/// Returns the lines said since the last call, oldest first, and clears them.
pub fn take_log() -> Vec<String> {
    std::mem::take(&mut *LOG_BUF.lock().unwrap_or_else(|l| l.into_inner()))
}

/// The cache.log line for a Reticulum link that closed. Prns's close event carries the reason only (not the keepalive or the
/// time of the last packet), so the line has the reason, how long the link was open and the round trip time it opened with.
fn link_closed_line(name: &str, reason: &str, open_secs: Option<u64>, rtt_ms: Option<u64>) -> String {
    let after = open_secs.map(|s| format!(" after {s} s")).unwrap_or_default();
    let rtt = rtt_ms.map(|r| format!(" (rtt {r} ms)")).unwrap_or_default();
    format!("reticulum link to {name} closed: {reason}{after}{rtt}")
}

/// The steps of one open, each said with the milliseconds since the open began (into [`take_log`]'s buffer).
struct OpenSteps(Instant);

/// Says a line into [`take_log`]'s buffer, so it reaches the app's own log (cache.log) as well as the Activity.
fn say(line: &str) {
    let mut b = LOG_BUF.lock().unwrap_or_else(|l| l.into_inner());
    if b.len() >= LOG_KEEP {
        b.remove(0);
    }
    b.push(line.to_string());
}

impl OpenSteps {
    fn step(&self, name: &str) {
        say(&format!("sync open: {name} +{} ms", self.0.elapsed().as_millis()));
    }
}

/// Everything the view of a share that a linked device gets depends on, read at one moment ([`Inner::offered_with`]): the patterns
/// that never sync, what is switched off (the kinds and items the person turned off, the private items, which the app sends as
/// patterns), the photos held back, the waiting deletes (`again`, which change the view while they wait) and the deletes that
/// stay on this device. What a device does not fetch (`only`, `never_fetch`) is its own and is applied to the mirror, not here.
#[derive(Debug, Clone, Default)]
struct ViewInputs {
    skip: Vec<String>,
    off: Vec<String>,
    gate: Option<SendGate>,
    again: HashSet<String>,
    local_deletes: Vec<String>,
}

impl ViewInputs {
    fn admits(&self, path: &str, e: &Entry) -> bool {
        !excluded(&self.skip, path)
            && !excluded(&self.off, path)
            && !self.gate.as_ref().is_some_and(|g| g.holds_back(path))
            && !(e.deleted && (self.again.contains(path) || excluded(&self.local_deletes, path)))
    }

    /// A hash of the inputs, each part sorted so the same inputs always give the same fingerprint.
    fn fingerprint(&self) -> String {
        let sorted = |v: &[String]| {
            let mut v = v.to_vec();
            v.sort();
            v.dedup();
            v
        };
        let gate = match &self.gate {
            Some(g) => {
                let mut v = vec![g.dir.trim_matches('/').to_string()];
                v.extend(sorted(&g.allow));
                v
            }
            None => Vec::new(),
        };
        let again: Vec<String> = self.again.iter().cloned().collect();
        delta::fingerprint(&[
            ("skip", sorted(&self.skip)),
            ("off", sorted(&self.off)),
            ("gate", gate),
            ("again", sorted(&again)),
            ("local_deletes", sorted(&self.local_deletes)),
        ])
    }
}

/// A send-only allow list for one folder of a share ([`Config::send_gate`]).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SendGate {
    /// The folder, relative to the share's root ("photos").
    #[serde(default)]
    pub dir: String,
    /// The files under it that may be offered, as paths relative to the share's root.
    #[serde(default)]
    pub allow: Vec<String>,
}

impl SendGate {
    /// `rel` is held back: it is under the folder and not in the allow list.
    fn holds_back(&self, rel: &str) -> bool {
        let dir = self.dir.trim_matches('/');
        !dir.is_empty() && rel.strip_prefix(dir).is_some_and(|r| r.starts_with('/')) && !self.allow.iter().any(|a| a == rel)
    }
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
    /// Seconds between safety rounds: a device that answers summaries and is reached over Reticulum has no timer round (a notice,
    /// being reachable again, or Sync now starts one), but is asked for a summary this often in case a notice was lost. Default
    /// 900 (15 minutes).
    #[serde(default)]
    pub safety_secs: Option<u64>,
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
    /// Shares whose files the Activity does not list one by one (share ids): the app says what arrived in its own words (the
    /// notebooks: "3 entries arrived from your other devices"), and a file line would name the person's notebook files. Only the
    /// lines that announce a normal change to a file (got, deleted by a device, kept, conflict copy) are left out; a failure or a
    /// stop of the share is still said.
    #[serde(default)]
    pub quiet: Vec<String>,
    /// What this device has switched off in a shared folder, by share id (patterns as for `exclude`): the person's choice of
    /// items in one share (a library, a map layer, a model). Such a path is neither fetched here nor offered to the others, and
    /// its deletes stay here, but this device keeps listing it with its history, so switching it on again carries on where it
    /// left off (and a copy deleted here meanwhile comes back from the devices that kept theirs). `set_off` replaces a share's
    /// list later.
    #[serde(default)]
    pub off: BTreeMap<String, Vec<String>>,
    /// Folders of a share whose files are OFFERED only when listed, by share id: `{"dir": "photos", "allow": ["photos/a.jpg"]}`
    /// offers a file under `photos/` only if it is in `allow` (every other path of the share is unaffected). Unlike `off` it
    /// governs sending only: a file under `dir` is still fetched from the other devices, so what arrives is never held back.
    /// Nothing already sent is recalled. `set_gate` replaces a share's gate later.
    #[serde(default)]
    #[serde(rename = "gate")]
    pub send_gate: BTreeMap<String, SendGate>,
    /// Shares kept only with some linked devices, by share id: the link kinds ([`Link`]'s `mode`) a device must have for the share
    /// to be offered to it and taken from it. A link starts `"off"` until the person answers ([`new_link`]); links made before
    /// that were given `"match"` once ([`migrate_links`]). A link with no mode at all counts as `"match"`. A share not listed goes to every linked device. The person's
    /// Bookshelves log is `["match"]` (their own devices only), the settings log `["match", "send"]`. `set_share_with` replaces a
    /// share's list later.
    #[serde(default)]
    pub with: BTreeMap<String, Vec<String>>,
    /// The engine stops itself this many seconds after it opened, whether or not it was closed: no more rounds, the router and
    /// the store shut down (so another engine can open the folder). For a background run, whose process may be stopped by the
    /// system before it can close the engine; absent: no limit (the app's own engine).
    #[serde(default)]
    pub lifetime_secs: Option<u64>,
    /// Run Reticulum beside iroh (Android and Linux; ignored elsewhere). Off unless asked: with no `rns_interfaces`, it listens
    /// and finds devices on the local network (Wi-Fi auto).
    #[serde(default)]
    pub reticulum: bool,
    /// For tests: the Reticulum interfaces to use instead of Wi-Fi auto.
    #[serde(default)]
    pub rns_interfaces: Option<RnsInterfaces>,
    /// What kind of device this is, as Nearby linking tells a device that asks: `"phone"`, `"tablet"` or `"computer"` (anything
    /// else counts as not set).
    #[serde(default)]
    pub device_kind: Option<String>,
    /// The shared folders of the big kinds, by share id (maps, libraries, ZIMs, models, videos): their files wait on a Medium link
    /// whatever their size (design 2b). Default: the ids the app gives those kinds (`library`, `libraries`, `models`, `maps`,
    /// `regions`, `videos`).
    #[serde(default = "default_bulk")]
    pub bulk: Vec<String>,
    /// The page of differences asked for on a Medium link, in bytes (default 64 KB, about 3 s at the 20 KB/s floor).
    #[serde(default)]
    pub medium_page_bytes: Option<usize>,
    /// Tests only: how long a Reticulum link may go without a measurement before the next request is preceded by a small one that
    /// measures it, in ms (default 10 s).
    #[serde(default)]
    pub speed_probe_ms: Option<u64>,
    /// How often the link of a device this device holds files back from is measured, in ms (default 5 s).
    #[serde(default)]
    pub resume_check_ms: Option<u64>,
    /// How long a link must allow what was held back before a round for that device is started, in ms (default 30 s, design 2b).
    #[serde(default)]
    pub resume_hold_ms: Option<u64>,
    /// The most that hold grows to after repeated slow cancels, in ms (default 10 min).
    #[serde(default)]
    pub resume_backoff_max_ms: Option<u64>,
}

fn default_bulk() -> Vec<String> {
    ["library", "libraries", "models", "maps", "regions", "videos"].into_iter().map(String::from).collect()
}

/// The Reticulum interfaces a test asks for ([`Config::rns_interfaces`]).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RnsInterfaces {
    /// Accept TCP connections on this address.
    #[serde(default)]
    pub tcp_listen: Option<String>,
    /// Connect to a TCP listener at this address.
    #[serde(default)]
    pub tcp_connect: Option<String>,
    /// Wi-Fi/LAN auto discovery as well.
    #[serde(default)]
    pub wifi: bool,
    /// Test only: Nearby pairing announces go out on, and are listed from, TCP interfaces too (loopback has no Wi-Fi). Off in
    /// production, where a pairing announce is only ever sent on local Wi-Fi/LAN interfaces.
    #[serde(default)]
    pub pair_local_tcp: bool,
}

/// A linked device's Reticulum address, as saved in `sync.json` (absent for links with no Reticulum address yet, and in files
/// saved by builds 48 to 54).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RnsPeer {
    /// The destination, 32 hex characters.
    dest: String,
}

/// A device's Reticulum destination and its device key's signature over it (both hex): what a pairing and an index carry.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RnsProof {
    dest: String,
    sig: String,
}

/// The Reticulum part of a link code.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RnsCode {
    /// The destination, 32 hex characters.
    d: String,
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
    /// Where the device is on Reticulum, once known (from its link code, its pairing or its file list).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rns: Option<RnsPeer>,
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
    /// The devices this one has unlinked, signed, kept [`REMOVAL_KEEP_MS`] and offered to every linked device in its file list
    /// ([`Removal`]). Absent in files saved by builds before this one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    removals: Vec<Removal>,
    /// The devices this one was linked with and no longer is (it unlinked them, or was told to, or the other device unlinked
    /// this one), with when, kept [`REMOVAL_KEEP_MS`]. Over Reticulum a hello from one of them is answered "not linked"
    /// ([`Transport::set_former`]), which is how it learns it was unlinked. Absent in files saved by builds before this one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    former: Vec<Former>,
}

/// A device that used to be linked, and when it was dropped (ms since 1970).
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Former {
    id: String,
    t: u64,
}

/// How long an unlink is kept and offered to the other linked devices: 30 days.
const REMOVAL_KEEP_MS: u64 = 30 * 24 * 60 * 60 * 1000;

/// The start of what a Removal signs.
const REMOVAL_PREFIX: &[u8] = b"cache remove v1";

/// "`by` unlinked `target` at `t`", signed with `by`'s device key. A device that unlinks another hands this to the devices it is
/// still linked with, in its file list, so they unlink it too. Older builds do not know the field and ignore it.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Removal {
    /// The unlinked device's id.
    target: String,
    /// The id of the device that unlinked it (and signed).
    by: String,
    /// When (ms since 1970, on `by`'s clock).
    t: u64,
    /// `by`'s signature over [`removal_message`], hex.
    sig: String,
}

/// What a Removal's signature covers: the prefix, the target's id and the time (8 bytes, big endian).
fn removal_message(target: &str, t: u64) -> Vec<u8> {
    let mut m = REMOVAL_PREFIX.to_vec();
    m.extend_from_slice(target.as_bytes());
    m.extend_from_slice(&t.to_be_bytes());
    m
}

fn sign_removal(key: &SecretKey, target: &str, t: u64) -> Removal {
    let sig = data_encoding::HEXLOWER.encode(&key.sign(&removal_message(target, t)).to_bytes());
    Removal { target: target.to_string(), by: key.public().to_string(), t, sig }
}

/// Whether `r.sig` is `r.by`'s signature over the removal.
fn removal_checks_out(r: &Removal) -> bool {
    let Ok(by) = r.by.parse::<PublicKey>() else { return false };
    let Ok(bytes) = data_encoding::HEXLOWER.decode(r.sig.as_bytes()) else { return false };
    let Ok(bytes) = <[u8; 64]>::try_from(bytes.as_slice()) else { return false };
    by.verify(&removal_message(&r.target, r.t), &Signature::from_bytes(&bytes)).is_ok()
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
    /// The fingerprint of what decides the view of this folder the sender gives the device it sends this to
    /// ([`ViewInputs::fingerprint`]); older versions do not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fp: Option<String>,
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
    /// The sender's Reticulum destination and its device key's signature over it (older versions do not say), so a link made
    /// before Reticulum learns where to reach the sender.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rns: Option<RnsProof>,
    /// The devices the sender has unlinked, signed by it, so this one unlinks them too (older versions do not say).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    removed: Vec<Removal>,
    /// The sender answers the summary and differences requests ([`Delta`]); older versions do not say. A summary is this same
    /// structure with no entries in its shares (only each share's id, name, epoch, counter and fingerprint).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    summary: bool,
    /// In a summary: the file the sender is fetching right now (from this device or another): the shared folder's id and how far it
    /// has got, no path. It is how a device that only sends sees a transfer to the other one (older versions do not say).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fetching: Option<Fetching>,
}

/// What a device says of the file it is fetching at the moment: no path, only the folder and the progress.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Fetching {
    share: String,
    size: u64,
    done: u64,
}

/// What a device last served of one file to a linked device that fetches it from this one ([`Inner::serving`]).
#[derive(Debug, Clone)]
struct Serving {
    hash: String,
    /// The folder holding the file, and its size there; none when no folder of this device lists the hash.
    share: Option<String>,
    size: u64,
    /// The highest byte offset a window served reached.
    high: u64,
    at: Instant,
}

/// What the status says an item that a link's class holds back is waiting for.
const WAITING_FOR_FASTER: &str = "Waiting for a faster connection";

/// An item the link's class does not allow now: a file too big for it (or of a big kind), or a folder's whole list. Not a
/// failure: it stays wanted and goes when the link allows it.
#[derive(Debug)]
struct Waiting;

impl std::fmt::Display for Waiting {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(WAITING_FOR_FASTER)
    }
}

impl std::error::Error for Waiting {}

fn is_waiting(e: &anyhow::Error) -> bool {
    e.chain().any(|c| c.downcast_ref::<Waiting>().is_some())
}

/// A held back item as the status lists it: (device, folder id, path; empty for a folder's whole list).
type WaitKey = (String, String, String);

/// How long a link must allow what is held back before a retry, after `cancels` slow cancels in a row: the base, doubled for each
/// one, up to `cap`.
fn backoff_hold(base: Duration, cancels: u32, cap: Duration) -> Duration {
    let _ = (cancels, cap);
    base
}

/// A device that is served windows is "fetching from this one" until this long after the last window.
const SERVING_FOR: Duration = Duration::from_secs(10);
/// Notices to one device are sent at most this often (a burst of writes makes one, with the latest counter).
const NOTICE_EVERY: Duration = Duration::from_millis(800);
/// A device heard reachable again is asked this long after: a round at that very instant can ask before the link can be made.
const REACHABLE_DELAY: Duration = Duration::from_secs(2);

/// What one round covers: everything (the rounds on their own, and `sync_now` with no scope), or, for `sync_now` with a scope,
/// one linked device, some shared folders, and within them the paths `paths` covers (patterns as for [`Config::exclude`]).
#[derive(Debug, Clone, Default)]
struct Scope {
    peer: Option<String>,
    shares: Option<Vec<String>>,
    paths: Option<Vec<String>>,
    /// The rounds of the loop between Sync nows: only these devices (those that are due), the rest left alone.
    peers: Option<Vec<String>>,
}

impl Scope {
    fn whole(&self) -> bool {
        self.peer.is_none() && self.shares.is_none() && self.paths.is_none() && self.peers.is_none()
    }

    fn has_share(&self, id: &str) -> bool {
        self.shares.as_ref().map(|s| s.iter().any(|x| x == id)).unwrap_or(true)
    }

    fn has_peer(&self, id: &str) -> bool {
        self.peer.as_deref().map(|p| p == id).unwrap_or(true) && self.peers.as_ref().map(|l| l.iter().any(|p| p == id)).unwrap_or(true)
    }

    /// A round of the loop that asked at least one device counts as a round; one that only rescanned does not.
    fn counts(&self) -> bool {
        self.whole() || (self.peer.is_none() && self.shares.is_none() && self.paths.is_none() && self.peers.as_ref().is_some_and(|l| !l.is_empty()))
    }

    /// `remote` narrowed to the paths of the scope.
    fn narrow(&self, remote: &Index) -> Index {
        match &self.paths {
            None => remote.clone(),
            Some(p) => Index { files: remote.files.iter().filter(|(rel, _)| excluded(p, rel)).map(|(k, v)| (k.clone(), v.clone())).collect(), ..Index::default() },
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
    /// The shared folder's id (`share` is its name).
    share_id: String,
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

/// Whether `e`, or anything it wraps, is a connection closed by the other device with code 403 (its Gate: "not linked").
///
/// Why not the error's text: the other device's Gate closes the connection only after the handshake (iroh endpoint/connection.rs
/// `conn.close(error_code, &reason)` in conn_from_noq_conn), and this side's connect() finishes before that close arrives. Where
/// the close is then met decides what the error says. At connect or open_bi it is `ConnectionError::ApplicationClosed`, whose text
/// is "closed by peer: not linked (code 403)" (noq-proto connection/mod.rs ConnectionError). On a slower machine it is met at
/// write_all or read_to_end instead, as `WriteError::ConnectionLost` (noq send_stream.rs) or `ReadToEndError::Read(ReadError::
/// ConnectionLost)` (noq recv_stream.rs), whose text is only "connection lost" / "read error: connection lost": the reason is in
/// the error's source, not in its text. The close code is the same in every case, so it is what is looked for.
///
/// What it cannot see, and why that cannot stick: iroh's `ConnectingError::HandshakeFailure` ("Failure finalizing the handshake",
/// connection.rs conn_from_noq_conn) carries no 403. But it is raised only when the connection has no ALPN or peer certificate AND
/// no close reason (iroh: "if the authentication error raced with a connection error, the connection error wins"). A close by the
/// other device's Gate always sets the close reason (noq connection.rs `close_reason`: "when the connection is closed ... is always
/// true"), and the handshake data is read from the crypto session, which a close does not clear. So a Gate close can never come out
/// as a HandshakeFailure: it is met at connect, open_bi, write or read, each of which this finds. A HandshakeFailure can only be a
/// peer whose handshake gave no ALPN or certificate; it is not the Gate's verdict, is never taken for one, and unlinks nothing.
fn closed_403(e: &(dyn std::error::Error + 'static)) -> bool {
    closed_code(e) == Some(403)
}

/// The code of the close by the other device that `e`, or anything it wraps, is (see [`closed_403`] for why by code).
fn closed_code(e: &(dyn std::error::Error + 'static)) -> Option<u32> {
    let mut cur: Option<&(dyn std::error::Error + 'static)> = Some(e);
    while let Some(x) = cur {
        if let Some(iroh::endpoint::ConnectionError::ApplicationClosed(c)) = x.downcast_ref::<iroh::endpoint::ConnectionError>() {
            return [403u32, 409, 503].into_iter().find(|n| c.error_code == VarInt::from_u32(*n));
        }
        cur = x.source();
    }
    None
}

/// What a device's Gate knows besides who is linked: whether it may say "not linked" at all.
#[derive(Debug, Default)]
struct GateState {
    /// The links file has been read and the device is up. Before that the Gate does not know who is linked.
    ready: AtomicBool,
    /// How many writes of `sync.json` are running now.
    writing: AtomicUsize,
    /// Until when (ms since 1970) the links are not to be trusted to be complete: after a recovery of the links file (or a fresh
    /// start). 0: they are.
    grace_until: AtomicU64,
}

/// What the Gate answers a key that is not linked, by close code. Only [`Refusal::NotLinked`] is ever taken by the other device
/// for an unlink; the others are never.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refusal {
    /// 403 "not linked": the links come from a healthy file and this key is not in them.
    NotLinked,
    /// 409 "links reset": the links were recovered or just made, so this may be a device that was linked and is forgotten.
    LinksReset,
    /// 503 "busy": the links are not loaded yet, or the file is being rewritten; try again later.
    Busy,
}

impl Refusal {
    fn code(self) -> u32 {
        match self {
            Refusal::NotLinked => 403,
            Refusal::LinksReset => 409,
            Refusal::Busy => 503,
        }
    }
    fn reason(self) -> &'static [u8] {
        match self {
            Refusal::NotLinked => b"not linked",
            Refusal::LinksReset => b"links reset",
            Refusal::Busy => b"busy",
        }
    }
}

impl GateState {
    /// The answer to a key that is not linked. "Not linked" only when the links are loaded, no rewrite of them is running, and
    /// they did not come from a recovery lately: a device that lost its links must never tell the others they were unlinked.
    fn refusal(&self, now: u64) -> Refusal {
        if !self.ready.load(Ordering::SeqCst) || self.writing.load(Ordering::SeqCst) > 0 {
            Refusal::Busy
        } else if now < self.grace_until.load(Ordering::SeqCst) {
            Refusal::LinksReset
        } else {
            Refusal::NotLinked
        }
    }
}

/// What one linked device last sent of its secrets: their digest, and the secrets until the app takes them.
type Received = (String, Option<BTreeMap<String, String>>);

struct Inner {
    dir: PathBuf,
    me: String,
    /// The network: iroh today, Reticulum beside it in 1.2 ([`transport`]).
    net: Arc<dyn Transport>,
    store: Blobs,
    saved: Mutex<Saved>,
    /// What the Gate needs besides `allowed` ([`GateState`]).
    gate: Arc<GateState>,
    /// Devices whose Gate refused the last check-in with 403 "not linked", and when the first of those was (see
    /// [`Inner::refused_by`]). In memory only: a restart starts the count again, which can only keep a link longer.
    refused: Mutex<HashMap<String, Instant>>,
    /// The unlinks refused as older than their link (target, by, time), so the line is said once ([`Inner::apply_removals`]).
    refused_removals: Mutex<std::collections::HashSet<(String, String, u64)>>,
    /// The code being shown, and until when.
    pairing: Mutex<Option<(String, Instant)>>,
    /// The short code being shown (only one code is live at a time: showing one ends the other kind).
    short: Mutex<Option<ShortCode>>,
    /// Tests only: how far the short code's clock is moved on.
    code_skew_ms: AtomicU64,
    run: Mutex<Run>,
    /// Hashes being fetched or about to be: kept from garbage collection so an interrupted transfer resumes.
    wanted: Arc<Mutex<HashSet<Hash>>>,
    wake: Notify,
    /// The round interval, and when each asking device last woke a round: a device that asks may have changes, so a round comes
    /// soon, but at most once per interval per device (two idle devices asking each other must not keep each other awake).
    every: Duration,
    asked_at: Mutex<HashMap<String, Instant>>,
    /// Per device: the files (share id, path) a round wanted from it and could not get whole. While any is left the device is not
    /// quiet ([`Inner::quiet_peer`]): the timer round retries them.
    held_from: Mutex<HashMap<String, HashSet<(String, String)>>>,
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
    /// [`Config::quiet`].
    quiet: HashSet<String>,
    /// [`Config::never_fetch`], as `set_never_fetch` last left it.
    never_fetch: Mutex<BTreeMap<String, Vec<String>>>,
    /// [`Config::off`], as `set_off` last left it.
    off: Mutex<BTreeMap<String, Vec<String>>>,
    /// [`Config::send_gate`], as `set_gate` last left it.
    send_gate: Mutex<BTreeMap<String, SendGate>>,
    /// Deletes kept here that `set_only` made fetchable again, by share: forgotten by the next rescan of the share, inside its
    /// round, so a round already running cannot write them back (set_only does not wait for the round).
    refetch: Mutex<HashMap<String, Vec<String>>>,
    /// [`Config::with`], as `set_share_with` last left it.
    with: Mutex<BTreeMap<String, Vec<String>>>,
    /// Secrets for one linked device each (the app's API keys the person ticked for it), by device: in memory only, never
    /// written anywhere by the engine, and sent only to that device over its own end-to-end encrypted connection when it asks.
    secrets: Mutex<HashMap<String, BTreeMap<String, String>>>,
    /// [`Config::device_kind`], when valid.
    device_kind: Option<String>,
    /// The secrets each linked device last sent here, by device: their digest (so they are asked for once per change) and,
    /// until the app takes them (`take_secrets`), the secrets themselves. In memory only.
    received: Mutex<HashMap<String, Received>>,
    /// Linked devices whose file list said they answer summaries and differences ([`RemoteIndex::summary`]); in memory only
    /// (a saved mirror also says so, see [`Inner::peer_has_summary`]).
    summary_peers: Mutex<HashSet<String>>,
    /// How many summary, differences and whole-list requests this device has made: for the tests.
    asked_summary: AtomicU64,
    asked_diff: AtomicU64,
    asked_full: AtomicU64,
    /// Step 3 part 2. How often a device that answers summaries and is reached over Reticulum is asked for a summary when nothing
    /// else asked (the safety round).
    safety: Duration,
    /// Linked devices a round is due with (a notice came, or they are reachable again), and the wake that says so.
    due: Mutex<HashSet<String>>,
    wake_due: Notify,
    /// Why each due device is due, for the line a round says ("notice from <name>"); and why the loop was woken for a whole round
    /// (the first cause that woke it since it last ran).
    due_why: Mutex<HashMap<String, String>>,
    wake_why: Mutex<Option<String>>,
    /// When each linked device was last asked in a round (the safety round counts from it).
    last_contact: Mutex<HashMap<String, Instant>>,
    /// Folders whose counter or epoch moved and whose linked devices have not been told yet, and the wake that says so.
    notice_dirty: Mutex<HashSet<String>>,
    notice_wake: Notify,
    /// Per linked device, the folders a notice is waiting to be sent for, and whether a task is sending to it now.
    notice_out: Mutex<HashMap<String, (HashSet<String>, bool)>>,
    notice_sent: AtomicU64,
    notice_got: AtomicU64,
    /// Small files taken from a device's page of differences, and ones whose bytes did not match the entry's hash.
    inline_ok: AtomicU64,
    inline_bad: AtomicU64,
    /// What each linked device is being served from this device's files (the windows it asks for), by device.
    serving: Mutex<HashMap<String, Serving>>,
    /// Linked devices that have asked this device something since it started: they can reach it, so they can send it notices.
    /// (A device only this one can reach has to be polled, as before.)
    heard_from: Mutex<HashSet<String>>,
    /// Linked devices heard reachable again, and when a round with each becomes due ([`REACHABLE_DELAY`]).
    reach_pending: Mutex<HashMap<String, Instant>>,
    /// [`Config::resume_check_ms`] and [`Config::resume_hold_ms`].
    resume_check: Duration,
    resume_hold: Duration,
    /// Per device: since when its link has allowed what was held back from it.
    resume_since: Mutex<HashMap<String, Instant>>,
    /// [`Config::resume_backoff_max_ms`].
    resume_cap: Duration,
    /// Per device: how many retries the watcher started ended as a slow cancel, one after the other (the hold doubles for each).
    resume_cancels: Mutex<HashMap<String, u32>>,
    /// Devices the watcher started a round for whose result is not known yet: the next item of one that goes back to waiting is a
    /// slow cancel.
    resume_trial: Mutex<HashSet<String>>,
    /// Per device: the node's interface count of changes when the watcher last looked.
    resume_gen: Mutex<HashMap<String, u64>>,
    /// Tests only: when (ms since 1970) a round was started by the resume watcher.
    #[cfg(feature = "test-hooks")]
    resume_fires: Mutex<Vec<u64>>,
    /// What each link's class holds back now, per item ([`WaitKey`]) and its size. Kept in step with `held_from`.
    waiting: Mutex<BTreeMap<WaitKey, u64>>,
    /// [`Config::bulk`].
    bulk: HashSet<String>,
    /// [`Config::medium_page_bytes`].
    medium_page: usize,
    /// The one-time move of an older store into the new one has finished (or there was none); rounds wait for it.
    store_ready: AtomicBool,
    /// While that move runs: bytes done and bytes in all.
    store_move: Mutex<Option<(u64, u64)>>,
}

/// A file dated in the future as a rescan last saw it: its size and modification time, and since when they have not changed.
type Settling = ((u64, i64), Instant);

pub struct SyncEngine {
    rt: tokio::runtime::Runtime,
    inner: Arc<Inner>,
    /// Held while this engine lives: the folder is not opened a second time in this process.
    _folder: FolderGuard,
}

/// The folders engines of this process run on. A second `open` on one of them (the app's own engine is running and a background
/// round opens another on the same folder, in the same process) answers at once with an error instead of waiting on the first
/// one's store, which a background round did without ever coming back (found on a Pixel).
static OPEN_FOLDERS: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

struct FolderGuard(PathBuf);

impl FolderGuard {
    fn take(dir: &Path) -> Result<FolderGuard> {
        let key = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
        let mut open = OPEN_FOLDERS.lock().unwrap_or_else(|l| l.into_inner());
        if open.contains(&key) {
            bail!("another engine of this app already runs on this folder");
        }
        open.push(key.clone());
        Ok(FolderGuard(key))
    }
}

impl Drop for FolderGuard {
    fn drop(&mut self) {
        OPEN_FOLDERS.lock().unwrap_or_else(|l| l.into_inner()).retain(|p| p != &self.0);
    }
}

/// The code a device shows for linking: its address, a one-time token, and its name.
#[derive(Debug, Serialize, Deserialize)]
struct LinkCode {
    a: EndpointAddr,
    t: String,
    n: String,
    /// The Reticulum destination (absent from codes of builds before 55, which ignore it when it is there).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    r: Option<RnsCode>,
}

const CODE_PREFIX: &str = "CACHE1-";

fn encode_code(c: &LinkCode) -> Result<String> {
    Ok(format!("{CODE_PREFIX}{}", data_encoding::BASE32_NOPAD.encode(&serde_json::to_vec(c)?)))
}

/// Why a link code cannot be read. The text is what the person may be shown; [`LinkCodeError::kind`] is the stable name the app
/// tells the cases apart by (the answer's `kind`, never the text).
#[derive(Debug, PartialEq, Eq)]
pub enum LinkCodeError {
    /// Not a Cache link code at all.
    NotACode,
    /// A `CACHE1-` code whose body cannot be read.
    Damaged,
    /// `CACHE<n>-` with n above 1: made by a newer Cache.
    Newer,
}

impl LinkCodeError {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::NotACode => "link_code_not_a_code",
            Self::Damaged => "link_code_damaged",
            Self::Newer => "link_code_newer",
        }
    }
}

impl std::fmt::Display for LinkCodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::NotACode => "this is not a Cache link code",
            Self::Damaged => "the link code is damaged",
            Self::Newer => "this link code is from a newer version of Cache",
        })
    }
}

impl std::error::Error for LinkCodeError {}

/// The kind of a failure that is a [`LinkCodeError`], for the answer to the app.
pub fn error_kind(e: &anyhow::Error) -> Option<&'static str> {
    e.downcast_ref::<LinkCodeError>().map(LinkCodeError::kind)
}

/// What a link code holds: an old `CACHE1-` code (the other device's iroh address, a token and its name), or a short one (its
/// Reticulum destination and a one-time secret).
#[derive(Debug)]
enum Code {
    Old(LinkCode),
    Short { dest: [u8; 16], secret: [u8; 5] },
}

/// The short code's prefix, and how long its base32 body is (21 bytes: the 16 byte destination, the 5 byte secret).
const SHORT_PREFIX: &str = "CACHE";
const SHORT_LEN: usize = 34;

/// `CACHE-` then base32 of the destination and the secret, in groups of four.
fn encode_short(dest: &[u8; 16], secret: &[u8; 5]) -> String {
    let mut raw = dest.to_vec();
    raw.extend_from_slice(secret);
    let body = data_encoding::BASE32_NOPAD.encode(&raw);
    let groups: Vec<&str> = body.as_bytes().chunks(4).map(|c| std::str::from_utf8(c).unwrap_or("")).collect();
    format!("{SHORT_PREFIX}-{}", groups.join("-"))
}

/// Reads either kind of code. Case, spaces and dashes do not matter; the short prefix may come with or without its dash.
fn decode_any(s: &str) -> Result<Code> {
    let s: String = s.trim().chars().filter(|c| !c.is_whitespace()).collect::<String>().to_uppercase();
    if s.starts_with(CODE_PREFIX) || made_by_newer(&s) {
        return Ok(Code::Old(decode_code(&s)?));
    }
    let Some(rest) = s.strip_prefix(SHORT_PREFIX) else { return Err(LinkCodeError::NotACode.into()) };
    let body: String = rest.chars().filter(|c| *c != '-').collect();
    if body.len() != SHORT_LEN {
        return Err(LinkCodeError::NotACode.into());
    }
    let raw = data_encoding::BASE32_NOPAD.decode(body.as_bytes()).map_err(|_| LinkCodeError::NotACode)?;
    let (Ok(dest), Ok(secret)) = (<[u8; 16]>::try_from(&raw[..16]), <[u8; 5]>::try_from(&raw[16..])) else {
        return Err(LinkCodeError::NotACode.into());
    };
    Ok(Code::Short { dest, secret })
}

/// Equal bytes, taking the same time whatever they hold.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

/// The short code being shown: its secret, until when, and how many wrong secrets it has met.
struct ShortCode {
    secret: [u8; 5],
    expires_ms: u64,
    strikes: u8,
}

/// Wrong secrets a short code takes before it is burned.
const SHORT_STRIKES: u8 = 3;

/// A short code's pairing request.
#[derive(Serialize, Deserialize)]
struct ShortPair {
    /// The one-time secret, base32.
    secret: String,
    hello: ShortHello,
}

/// What each side tells the other in a short code's pairing: who it is, where iroh finds it, and its Reticulum destination.
#[derive(Serialize, Deserialize)]
struct ShortHello {
    key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    iroh: Option<EndpointAddr>,
    name: String,
    rns: RnsProof,
}

fn decode_code(s: &str) -> Result<LinkCode> {
    let s: String = s.trim().chars().filter(|c| !c.is_whitespace()).collect::<String>().to_uppercase();
    let Some(body) = s.strip_prefix(CODE_PREFIX) else {
        return Err(if made_by_newer(&s) { LinkCodeError::Newer } else { LinkCodeError::NotACode }.into());
    };
    let bytes = data_encoding::BASE32_NOPAD.decode(body.as_bytes()).map_err(|_| LinkCodeError::Damaged)?;
    Ok(serde_json::from_slice(&bytes).map_err(|_| LinkCodeError::Damaged)?)
}

/// `CACHE<n>-` (already upper-cased) with n above 1: a code from a later format. A number too big to read is later too.
fn made_by_newer(s: &str) -> bool {
    let Some(rest) = s.strip_prefix("CACHE") else { return false };
    let Some((n, _)) = rest.split_once('-') else { return false };
    !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) && n.parse::<u64>().map_or(true, |n| n > 1)
}

/// A Reticulum destination (32 hex characters) as bytes.
fn rns_dest_bytes(hex: &str) -> Option<[u8; 16]> {
    if hex.len() != 32 || !hex.is_ascii() {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(out)
}

fn dest_hex_of(d: &[u8; 16]) -> String {
    d.iter().map(|b| format!("{b:02x}")).collect()
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

    /// Set (holding the new path) while a share re-pointed to a new folder has not yet had its first, reconciling scan. A mark
    /// naming a folder the share does not have (the app stopped between writing it and changing the path) is ignored.
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
                if moved {
                    // The mark is on disk before the path changes, and both happen under the lock a round copies the shares
                    // under: no round can scan the new folder as an ordinary one and record what it lacks as deleted, and
                    // two re-points of one share at once cannot leave the mark naming one folder and the share the other.
                    // If it cannot be written the re-point fails with nothing changed.
                    std::fs::create_dir_all(self.dir.join("index"))?;
                    std::fs::write(self.moved_path(id), path.to_string_lossy().as_bytes())?;
                }
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
        // The Gate does not say "not linked" while the file is being rewritten.
        struct Writing<'a>(&'a AtomicUsize);
        impl Drop for Writing<'_> {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::SeqCst);
            }
        }
        self.gate.writing.fetch_add(1, Ordering::SeqCst);
        let _w = Writing(&self.gate.writing);
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
        Index { files: idx.files.iter().filter(|(p, _)| !excluded(skip, p)).map(|(p, e)| (p.clone(), e.clone())).collect(), ..Index::default() }
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
            ..Index::default()
        }
    }

    /// What this device offers the others of `share`: not what never syncs, not what is switched off here, and not its deletes
    /// that stay here.
    /// A delete waiting to be forgotten because its item was switched on again ([`Inner::refetch`]) is not offered either, so
    /// the other devices never take it meanwhile. The waiting deletes are read before the index: a rescan stores the index
    /// without them first and only then stops holding them back, so whichever index is read here, a delete in it that is
    /// waiting to be forgotten is in `again`.
    /// Everything that decides what this device offers of `share`, read once (the waiting deletes first, see [`Inner::offered_with`]).
    fn view_inputs(&self, share: &str) -> ViewInputs {
        ViewInputs {
            skip: self.skip(share).to_vec(),
            off: self.off.lock().unwrap().get(share).cloned().unwrap_or_default(),
            gate: self.send_gate.lock().unwrap().get(share).cloned(),
            again: self.refetch.lock().unwrap().get(share).map(|v| v.iter().cloned().collect()).unwrap_or_default(),
            local_deletes: self.local_deletes.get(share).cloned().unwrap_or_default(),
        }
    }

    /// [`Inner::offered_with`], and the fingerprint of the inputs it was made with. The index carries the epoch and counter it was
    /// read at.
    fn offered_with(&self, share: &str) -> (Index, String) {
        let inputs = self.view_inputs(share);
        let idx = self.load_index(share);
        let view = Index {
            files: idx.files.iter().filter(|(p, e)| inputs.admits(p, e)).map(|(p, e)| (p.clone(), e.clone())).collect(),
            epoch: idx.epoch.clone(),
            counter: idx.counter,
        };
        (view, inputs.fingerprint())
    }

    fn load_index(&self, share: &str) -> Index {
        read_json(&self.index_path(share)).unwrap_or_default()
    }

    fn load_seen(&self, share: &str) -> Seen {
        read_json(&self.seen_path(share)).unwrap_or_default()
    }

    /// The only writer of the index, and so the one place that counts changes: every entry that differs from the saved one
    /// takes the folder's next counter, and an entry gone from the index starts a new epoch ([`delta::stamp`]).
    fn store_index(&self, share: &str, idx: &Index, seen: &Seen) -> Result<()> {
        let old = self.load_index(share);
        let stamped = delta::stamp(&old, idx);
        write_json(&self.index_path(share), &stamped)?;
        write_json(&self.seen_path(share), seen)?;
        if (stamped.epoch.as_str(), stamped.counter) != (old.epoch.as_str(), old.counter) {
            // Never blocks or fails the write: the linked devices are told by a task of their own.
            self.notice_dirty.lock().unwrap().insert(share.to_string());
            self.notice_wake.notify_one();
        }
        Ok(())
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
        self.store.set_tag(Self::tag_name(&sh.id, path).as_bytes(), hash).await.map_err(|e| anyhow!("{e}"))?;
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
            let have = self.store.is_complete(hash).await;
            let put = have && self.store.export_move(hash, full.clone()).await.is_ok();
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

    /// A line that announces a normal change to one file of share `share_id`: left out when the share is [`Config::quiet`].
    fn note_file(&self, share_id: &str, msg: impl Into<String>) {
        if !self.quiet.contains(share_id) {
            self.note(msg);
        }
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
        let added = self.store.add_path_copy_held(target).await.map_err(|e| anyhow!("{e}"))?;
        if added.hash() != h {
            bail!("{} changed meanwhile", target.display());
        }
        let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let aside = target.with_file_name(format!(".{name}{ASIDE_SUFFIX}"));
        std::fs::rename(target, &aside)?;
        match self.store.export_move(h, target.to_path_buf()).await {
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
        // Stored at once, and only then no longer held back from what is offered ([`Inner::offered_with`]): until the index without
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
            let _ = self.store.delete_tag(Self::tag_name(&share.id, &p).as_bytes()).await;
            changed = true;
        }
        let mut unsettled = false;
        // The sizes of the files this scan holds back as still being written: a file that went and one of the same size that
        // is still settling may be a rename, whose delete waits for the scan that also lists the new path (below).
        let mut settling_sizes: HashSet<u64> = HashSet::new();
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
                    settling_sizes.insert(m.len());
                    continue;
                }
            }
            let tag = Self::tag_name(&share.id, &rel);
            let added = self
                .store
                .add_path_ref_tagged(full.clone(), tag.as_bytes())
                .await
                .map_err(|e| anyhow!("could not read {}: {e}", full.display()))?;
            let hash = added.to_hex().to_string();
            let entry = match idx.files.get(&rel) {
                Some(old) if !old.deleted && old.hash == hash => None,
                Some(old) => {
                    if !old.deleted {
                        stale.push(old.hash.clone());
                    }
                    Some(old.next(&self.me, now_ms(), hash, m.len(), false))
                }
                None => Some(Entry { hash, size: m.len(), deleted: false, ver: Ver { at: now_ms(), by: self.me.clone() }, hist: vec![], ctr: 0 }),
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
                let _ = self.store.delete_tag(Self::tag_name(&share.id, &p).as_bytes()).await;
                changed = true;
                continue;
            }
            let old = idx.files[&p].clone();
            // Perhaps renamed to a file still being written (a rename of a file that arrived moments ago keeps that file's
            // time): the delete waits for the next scan, so the other devices learn the new path in the same list and write
            // it before they delete the old one, while their store can still read the content from it.
            if settling_sizes.contains(&old.size) {
                continue;
            }
            stale.push(old.hash.clone());
            idx.files.insert(p.clone(), old.next(&self.me, now_ms(), old.hash.clone(), old.size, true));
            seen.remove(&p);
            let _ = self.store.delete_tag(Self::tag_name(&share.id, &p).as_bytes()).await;
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
        self.index_for(peer, true)
    }

    /// [`Inner::our_index_for`] (`full`), or its summary: the same, with the shares carrying no entries, only their epoch,
    /// counter and fingerprint.
    fn index_for(&self, peer: &str, full: bool) -> RemoteIndex {
        let s = self.saved.lock().unwrap().clone();
        let link = s.peers.iter().find(|p| p.id == peer).and_then(|p| p.link.clone());
        let secrets = self.secrets.lock().unwrap().get(peer).filter(|m| !m.is_empty()).map(secrets_digest);
        let mut out = RemoteIndex {
            free_bytes: Self::free_bytes(&self.dir),
            name: s.name.clone(),
            shares: s
                .shares
                .iter()
                .filter(|sh| self.shares_with(&sh.id, peer))
                .map(|sh| {
                    let (index, fp) = if full {
                        self.offered_with(&sh.id)
                    } else {
                        let idx = self.load_index(&sh.id);
                        (Index { epoch: idx.epoch, counter: idx.counter, ..Index::default() }, self.view_inputs(&sh.id).fingerprint())
                    };
                    RemoteShare { id: sh.id.clone(), name: sh.name.clone(), index, fp: Some(fp) }
                })
                .collect(),
            link,
            links: true,
            secrets,
            rns: self.rns_info().map(|(dest, sig)| RnsProof { dest, sig }),
            removed: self.removals_to_offer(&s),
            summary: true,
            fetching: None,
        };
        if !full {
            out.fetching = self.run.lock().unwrap().transfer.as_ref().map(|t| Fetching { share: t.share_id.clone(), size: t.size, done: t.done });
            #[cfg(feature = "test-hooks")]
            if self.dir.join("no-summary-fetching").exists() {
                out.fetching = None;
            }
        }
        #[cfg(feature = "test-hooks")]
        if self.dir.join("no-summary").exists() {
            // Acts as an older build: no counters, no fingerprints, and it does not say it answers summaries.
            out.summary = false;
            for sh in &mut out.shares {
                sh.fp = None;
                sh.index.epoch.clear();
                sh.index.counter = 0;
                for e in sh.index.files.values_mut() {
                    e.ctr = 0;
                }
            }
        }
        out
    }

    /// The answer to a request for differences from `peer` ([`delta::DiffAsk`]): a page, or "full" when it cannot follow.
    fn diff_answer(&self, peer: &str, body: &[u8]) -> Vec<u8> {
        let full = || serde_json::to_vec(&delta::Page { full: true, ..delta::Page::default() }).unwrap_or_default();
        let Ok(ask) = serde_json::from_slice::<delta::DiffAsk>(body) else { return full() };
        if !self.shares_with(&ask.share, peer) || !self.saved.lock().unwrap().shares.iter().any(|x| x.id == ask.share) {
            return full();
        }
        let inputs = self.view_inputs(&ask.share);
        // Another filter than the one the asking device was told: it asks for the whole list.
        if inputs.fingerprint() != ask.fp {
            return full();
        }
        #[allow(unused_mut)]
        let mut cap = delta::PAGE_BYTES;
        #[cfg(feature = "test-hooks")]
        if let Some(n) = std::fs::read_to_string(self.dir.join("diff-page-bytes")).ok().and_then(|t| t.trim().parse::<usize>().ok()) {
            cap = n;
        }
        // The asker may ask for less than the class carries (the answering end's cap is put in `max` before it gets here).
        if let Some(m) = ask.max {
            cap = cap.min(m.max(1));
        }
        // A Slow asker gets the bytes of its small files (8 KB or less) with their entries; they come from this device's own store.
        let store = self.store.raw().clone();
        #[cfg(feature = "test-hooks")]
        let corrupt = self.dir.join("corrupt-inline").exists();
        let inline = |_: &str, e: &Entry| -> Option<Vec<u8>> {
            if !ask.inl {
                return None;
            }
            let hash: Hash = e.hash.parse().ok()?;
            #[allow(unused_mut)]
            let mut bytes = store.get_bytes(&hash).ok().filter(|b| b.len() as u64 == e.size)?;
            #[cfg(feature = "test-hooks")]
            if corrupt {
                // Acts as a build that sends wrong bytes: one byte flipped.
                if let Some(b) = bytes.first_mut() {
                    *b ^= 0xff;
                }
            }
            Some(bytes)
        };
        let page = delta::diff_page_with(&self.load_index(&ask.share), &ask.epoch, ask.c, ask.p.as_deref(), &|p, e| inputs.admits(p, e), cap, &inline);
        serde_json::to_vec(&page).unwrap_or_default()
    }

    fn mirror_path(&self, peer: &str, share: &str) -> PathBuf {
        let clean = |s: &str| s.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' }).collect::<String>();
        self.dir.join("mirror").join(format!("{}-{}.json", clean(peer), clean(share)))
    }

    fn load_mirror(&self, peer: &str, share: &str) -> Option<delta::Mirror> {
        read_json(&self.mirror_path(peer, share))
    }

    /// The saved mirror files of `peer`, except those of the shares in `keep`.
    fn mirror_files(&self, peer: &str, keep: &[String]) -> Vec<PathBuf> {
        let prefix = self.mirror_path(peer, "").file_name().and_then(|n| n.to_str()).map(|n| n.trim_end_matches(".json").to_string()).unwrap_or_default();
        let Ok(rd) = std::fs::read_dir(self.dir.join("mirror")) else { return Vec::new() };
        rd.flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "json") && p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with(&prefix)))
            .filter(|p| !keep.iter().any(|k| *p == self.mirror_path(peer, k)))
            .collect()
    }

    /// Whether `peer` is known to answer summaries: its file list said so, or a mirror of it was saved.
    fn peer_has_summary(&self, peer: &str) -> bool {
        self.summary_peers.lock().unwrap().contains(peer) || !self.mirror_files(peer, &[]).is_empty()
    }

    /// Whether `peer` needs no timer round: it answers summaries, was last reached over Reticulum (so it sends notices and is
    /// found again when reachable), and its last round was good. Any other device keeps today's round every interval.
    fn quiet_peer(&self, peer: &str) -> bool {
        if !self.peer_has_summary(peer) || !self.net.reached_over_rns(peer) || !self.heard_from.lock().unwrap().contains(peer) {
            return false;
        }
        if self.held_from.lock().unwrap().get(peer).is_some_and(|s| !s.is_empty()) {
            // Still has files to get from it: the timer round retries them until a round leaves nothing held.
            return false;
        }
        self.run.lock().unwrap().peers.get(peer).is_some_and(|s| s.error.is_none() && s.last_seen.is_some())
    }

    /// A device that asked for our list may have changes too, so a round comes soon, at most once per interval per device. Not for
    /// a [`Inner::quiet_peer`]: its notice replaces this. Whether a round was woken.
    fn asked_wakes(&self, peer: &str) -> bool {
        if self.quiet_peer(peer) {
            return false;
        }
        let now = Instant::now();
        let mut at = self.asked_at.lock().unwrap();
        if at.get(peer).is_none_or(|t| now.duration_since(*t) >= self.every) {
            at.insert(peer.to_string(), now);
            drop(at);
            self.wake_for(&format!("asked by {}", self.peer_name(peer)));
            true
        } else {
            false
        }
    }

    /// A round with `peer` is due (a notice from it came, or it is reachable again).
    fn make_due(&self, peer: &str) {
        self.due.lock().unwrap().insert(peer.to_string());
        self.due_why.lock().unwrap().entry(peer.to_string()).or_insert_with(|| format!("notice from {}", self.peer_name(peer)));
        self.wake_due.notify_one();
    }

    /// A shared folder's name for the log (its id when no name is known).
    fn share_name(&self, id: &str) -> String {
        if let Some(s) = self.saved.lock().unwrap().shares.iter().find(|s| s.id == id) {
            return s.name.clone();
        }
        self.run.lock().unwrap().peers.values().filter_map(|p| p.index.as_ref()).flat_map(|i| i.shares.iter()).find(|x| x.id == id).map(|x| x.name.clone()).unwrap_or_else(|| id.to_string())
    }

    /// Wakes the loop for a whole round, remembering the first cause that did so (it is said when the round runs).
    fn wake_for(&self, why: &str) {
        self.wake_why.lock().unwrap().get_or_insert_with(|| why.to_string());
        self.wake.notify_one();
    }

    /// Says why a round that asks `n` devices runs (nothing when it asks none: a loop tick that only rescans is silent).
    fn say_round(&self, causes: &[String], n: usize) {
        if n == 0 || !self.network.load(Ordering::Relaxed) {
            return;
        }
        let mut list: Vec<&str> = Vec::new();
        for c in causes {
            if !list.contains(&c.as_str()) {
                list.push(c);
            }
        }
        say(&format!("sync round: {} ({n} device{})", list.join(", "), if n == 1 { "" } else { "s" }));
    }

    /// What the loop's next round covers when no one asked for a round: the devices that are due, the quiet ones not asked for a
    /// safety interval, and every other device not asked for an interval. All of them: a whole round, as before.
    fn loop_scope(&self) -> (Scope, Vec<String>, usize) {
        let ids: Vec<String> = self.saved.lock().unwrap().peers.iter().map(|p| p.id.clone()).collect();
        let mut due = std::mem::take(&mut *self.due.lock().unwrap());
        let mut why = std::mem::take(&mut *self.due_why.lock().unwrap());
        let now = Instant::now();
        self.reach_pending.lock().unwrap().retain(|p, t| {
            if *t <= now {
                due.insert(p.clone());
                why.entry(p.clone()).or_insert_with(|| format!("{} reachable again", self.peer_name(p)));
                false
            } else {
                true
            }
        });
        let list: Vec<String> = ids
            .iter()
            .filter(|id| {
                let since = self.last_contact.lock().unwrap().get(*id).map(|t| now.duration_since(*t));
                due.contains(*id) || since.is_none_or(|d| d >= if self.quiet_peer(id) { self.safety } else { self.every })
            })
            .cloned()
            .collect();
        let causes: Vec<String> = list
            .iter()
            .map(|id| {
                why.get(id).cloned().unwrap_or_else(|| if self.quiet_peer(id) { "safety round".to_string() } else { "timer".to_string() })
            })
            .collect();
        let n = list.len();
        if n == ids.len() {
            (Scope::default(), causes, n)
        } else {
            (Scope { peers: Some(list), ..Scope::default() }, causes, n)
        }
    }

    /// How long until a quiet device is next due its safety round (the loop wakes for it).
    fn next_safety_in(&self) -> Option<Duration> {
        if !self.network.load(Ordering::Relaxed) {
            return None;
        }
        let now = Instant::now();
        let pending = self.reach_pending.lock().unwrap().values().map(|t| t.saturating_duration_since(now)).min();
        let ids: Vec<String> = self.saved.lock().unwrap().peers.iter().map(|p| p.id.clone()).collect();
        let safety = ids
            .iter()
            .filter(|id| self.quiet_peer(id))
            .filter_map(|id| self.last_contact.lock().unwrap().get(id).map(|t| (*t + self.safety).saturating_duration_since(now)))
            .min();
        [pending, safety].into_iter().flatten().min().map(|d| d.max(Duration::from_millis(500)))
    }

    /// Watches the devices this device holds files or lists back from because their link was too slow (design 2b, "It speeds up"):
    /// each is measured every few seconds, and when its class allows what waits, a round for it is started at once if a new link
    /// came up, or once the class has allowed it for 30 seconds. The rate cannot be measured while nothing flows, so the round
    /// that follows is the measurement: a link that is not fast after all gives the item back to waiting.
    async fn resume_loop(self: Arc<Self>) {
        loop {
            tokio::time::sleep(self.resume_check).await;
            if self.stop.load(Ordering::Relaxed) {
                break;
            }
            if !self.network.load(Ordering::Relaxed) {
                continue;
            }
            let mut held: BTreeMap<String, Vec<(String, String, u64)>> = BTreeMap::new();
            for ((peer, share, path), size) in self.waiting.lock().unwrap().iter() {
                held.entry(peer.clone()).or_default().push((share.clone(), path.clone(), *size));
            }
            self.resume_since.lock().unwrap().retain(|p, _| held.contains_key(p));
            // Nothing held from a device any more (it all came, or went): its backoff is over.
            let gone: Vec<String> = self.resume_cancels.lock().unwrap().keys().chain(self.resume_trial.lock().unwrap().iter()).filter(|p| !held.contains_key(*p)).cloned().collect();
            for p in gone {
                self.end_backoff(&p);
            }
            let iface_gen = self.net.interface_gen();
            for (peer, items) in held {
                let mut fresh = self.net.measure(&peer).await;
                // An interface of this device came up or went down since the watcher last looked: the path may be faster.
                fresh |= self.resume_gen.lock().unwrap().insert(peer.clone(), iface_gen).is_some_and(|g| g != iface_gen);
                if fresh {
                    // A new link or a change of interface ends the backoff at once, so a real speed-up is caught right away.
                    self.end_backoff(&peer);
                }
                let class = self.class_of(&peer);
                let allowed = items.iter().any(|(share, path, size)| if path.is_empty() { class != Speed::Slow } else { self.class_allows(class, share, *size) });
                if !allowed {
                    self.resume_since.lock().unwrap().remove(&peer);
                    continue;
                }
                let since = *self.resume_since.lock().unwrap().entry(peer.clone()).or_insert_with(Instant::now);
                if fresh || since.elapsed() >= self.resume_hold_for(&peer) {
                    self.resume_since.lock().unwrap().remove(&peer);
                    self.resume_trial.lock().unwrap().insert(peer.clone());
                    #[cfg(feature = "test-hooks")]
                    self.resume_fires.lock().unwrap().push(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64));
                    self.due.lock().unwrap().insert(peer.clone());
                    self.due_why.lock().unwrap().insert(peer.clone(), format!("faster connection to {}", self.peer_name(&peer)));
                    self.wake_due.notify_one();
                }
            }
        }
    }

    /// How long the link of `peer` must allow what is held back before a round for it is started.
    fn resume_hold_for(&self, peer: &str) -> Duration {
        let cancels = self.resume_cancels.lock().unwrap().get(peer).copied().unwrap_or(0);
        backoff_hold(self.resume_hold, cancels, self.resume_cap)
    }

    /// A round the watcher started for `peer` gave an item back to waiting: a slow cancel, the next retry waits twice as long.
    fn note_slow_cancel(&self, peer: &str) {
        if self.resume_trial.lock().unwrap().remove(peer) {
            *self.resume_cancels.lock().unwrap().entry(peer.to_string()).or_insert(0) += 1;
        }
    }

    /// What the watcher held against `peer` is over: the backoff starts again.
    fn end_backoff(&self, peer: &str) {
        self.resume_trial.lock().unwrap().remove(peer);
        self.resume_cancels.lock().unwrap().remove(peer);
    }

    /// Tells the linked devices that keep a folder when its counter or epoch moves ([`Inner::store_index`]): one notice per device
    /// and folder for a burst of writes, carrying the latest counter. Runs for as long as the engine does.
    async fn notice_loop(self: Arc<Self>) {
        loop {
            self.notice_wake.notified().await;
            if self.stop.load(Ordering::Relaxed) {
                break;
            }
            tokio::time::sleep(NOTICE_EVERY).await;
            let dirty: Vec<String> = std::mem::take(&mut *self.notice_dirty.lock().unwrap()).into_iter().collect();
            let peers: Vec<String> = self.saved.lock().unwrap().peers.iter().map(|p| p.id.clone()).collect();
            for peer in peers {
                let wanted: Vec<String> = dirty.iter().filter(|sh| self.shares_with(sh, &peer)).cloned().collect();
                if !wanted.is_empty() && self.peer_has_summary(&peer) {
                    self.queue_notices(&peer, wanted);
                }
            }
        }
    }

    fn queue_notices(self: &Arc<Self>, peer: &str, shares: Vec<String>) {
        let start = {
            let mut out = self.notice_out.lock().unwrap();
            let e = out.entry(peer.to_string()).or_default();
            e.0.extend(shares);
            !std::mem::replace(&mut e.1, true)
        };
        if start {
            let (me, peer) = (self.clone(), peer.to_string());
            tokio::spawn(async move { me.send_notices(&peer).await });
        }
    }

    /// Sends what is queued for `peer`, folder by folder, until nothing is. A notice that fails is let go: the round when the
    /// device is reachable again, and the safety round, cover it.
    async fn send_notices(self: Arc<Self>, peer: &str) {
        loop {
            let batch: Vec<String> = {
                let mut out = self.notice_out.lock().unwrap();
                let Some(e) = out.get_mut(peer) else { return };
                if e.0.is_empty() || self.stop.load(Ordering::Relaxed) {
                    e.1 = false;
                    return;
                }
                e.0.drain().collect()
            };
            for share in batch {
                #[cfg(feature = "test-hooks")]
                if self.dir.join("no-notice").exists() {
                    continue;
                }
                let idx = self.load_index(&share);
                if idx.epoch.is_empty() {
                    continue;
                }
                let Ok(body) = serde_json::to_vec(&delta::Notice { s: share.clone(), e: idx.epoch, c: idx.counter }) else { continue };
                self.notice_sent.fetch_add(1, Ordering::Relaxed);
                let (name, sh, c) = (self.peer_name(peer), self.share_name(&share), idx.counter);
                if self.net.send_notice(peer, body).await.is_ok() {
                    say(&format!("notice sent to {name}: {sh} at {c}"));
                }
            }
        }
    }

    /// What `peer` is doing with this device's files, for the status: what this device serves it (the windows it asks for, until
    /// [`SERVING_FOR`] after the last one), else what its last summary said it fetches (while that summary is fresh).
    /// The class of the link to `peer` for what this device asks of it ([`Transport::speed`]; iroh paths are Fast). Tests only: a
    /// device with `<dir>/ignore-class` acts as a build that does not check its own class (the answering end still does).
    fn class_of(&self, peer: &str) -> Speed {
        #[cfg(feature = "test-hooks")]
        if self.dir.join("ignore-class").exists() {
            return Speed::Fast;
        }
        self.net.speed(peer)
    }

    /// A file of `size` in folder `share` may be asked for over a link of class `class`: a Medium link carries files up to 10 MiB
    /// and not the big kinds ([`Config::bulk`]); a Slow link carries none as a window (a file of 8 KB or less
    /// comes inline with its entry and is then in the store already).
    fn class_allows(&self, class: Speed, share: &str, size: u64) -> bool {
        class.carries_file(size) && !(class == Speed::Medium && self.bulk.contains(share))
    }

    /// The page of differences to ask for over a link of class `class` (none: the answering end's own, 1 MB).
    fn page_ask(&self, class: Speed) -> Option<usize> {
        match class {
            Speed::Fast => None,
            Speed::Medium => Some(self.medium_page),
            Speed::Slow => Some(transport::SLOW_PAGE_BYTES),
        }
    }

    fn fetching_by(&self, peer: &str, summary: Option<&RemoteIndex>, last_seen: Option<u64>) -> Option<Value> {
        let served = {
            let mut sv = self.serving.lock().unwrap();
            sv.retain(|_, s| s.at.elapsed() < SERVING_FOR * 6);
            sv.get(peer).filter(|s| s.at.elapsed() < SERVING_FOR).and_then(|s| s.share.as_ref().map(|sh| json!({"share": sh, "size": s.size, "done": s.high})))
        };
        served.or_else(|| {
            let fresh = last_seen.is_some_and(|t| now_ms().saturating_sub(t) < 2 * self.every.as_millis() as u64);
            summary.filter(|_| fresh).and_then(|i| i.fetching.as_ref()).map(|f| json!({"share": f.share, "size": f.size, "done": f.done}))
        })
    }

    /// What `peer` last offered, as a file list: its summary, and for each shared folder the mirror brought up to what the summary
    /// says (nothing asked when all is equal; the differences when only the counter moved; the folder's whole list otherwise).
    /// Any failure ends in [`Inner::fetch_index`], today's request, which also replaces the mirrors.
    async fn fetch_remote(&self, peer: &str, closed: &AtomicU32) -> Result<(RemoteIndex, String)> {
        if self.peer_has_summary(peer) {
            match self.fetch_by_summary(peer, closed).await {
                Ok(v) => return Ok(v),
                #[cfg(feature = "test-hooks")]
                Err(e) if format!("{e:#}").starts_with("test: killed") => return Err(e),
                // Not the whole list over a slow link, which is what a failed summary would fall back to.
                Err(e) if self.class_of(peer) == Speed::Slow => return Err(e),
                Err(_) => {}
            }
        }
        if self.class_of(peer) == Speed::Slow {
            // A device that cannot give a summary, over a slow link: its whole list waits for a faster one.
            return Err(anyhow::Error::new(Waiting));
        }
        let (idx, via) = self.fetch_index(peer, closed).await?;
        self.take_full(peer, &idx);
        Ok((idx, via))
    }

    /// A whole file list was taken from `peer`: what it says of summaries is noted, and each folder's list becomes its mirror.
    fn take_full(&self, peer: &str, idx: &RemoteIndex) {
        if !idx.summary {
            self.summary_peers.lock().unwrap().remove(peer);
            for f in self.mirror_files(peer, &[]) {
                let _ = std::fs::remove_file(f);
            }
            return;
        }
        self.summary_peers.lock().unwrap().insert(peer.to_string());
        let mut keep = Vec::new();
        for rs in &idx.shares {
            keep.push(rs.id.clone());
            if let Some(fp) = rs.fp.as_deref().filter(|_| !rs.index.epoch.is_empty()) {
                if let Err(e) = write_json(&self.mirror_path(peer, &rs.id), &delta::Mirror::from_full(&rs.index, fp)) {
                    self.note(format!("{}: {e:#}", rs.name));
                }
            }
        }
        for f in self.mirror_files(peer, &keep) {
            let _ = std::fs::remove_file(f);
        }
    }

    async fn fetch_by_summary(&self, peer: &str, closed: &AtomicU32) -> Result<(RemoteIndex, String)> {
        let (bytes, via) = self.net.ask_delta(peer, Delta::Summary, Vec::new(), closed).await?;
        self.asked_summary.fetch_add(1, Ordering::Relaxed);
        let mut sum: RemoteIndex = serde_json::from_slice(&bytes).context("the summary from the device is not valid")?;
        if !sum.summary {
            bail!("the device did not send a summary");
        }
        let mut full = None;
        let mut held_back = Vec::new();
        for rs in sum.shares.iter_mut() {
            match self.catch_up(peer, rs, closed, &mut full).await? {
                Some(idx) => {
                    rs.index = idx;
                    self.waiting.lock().unwrap().remove(&(peer.to_string(), rs.id.clone(), String::new()));
                }
                None => held_back.push(rs.id.clone()),
            }
        }
        let ids: Vec<String> = sum.shares.iter().map(|x| x.id.clone()).collect();
        // A folder this device keeps, whose whole list a slow link does not carry: it waits for a faster one, and nothing of it is
        // compared meanwhile (what is known of it stays as it was).
        if !held_back.is_empty() {
            let joined: HashSet<String> = self.saved.lock().unwrap().shares.iter().map(|s| s.id.clone()).collect();
            for id in &held_back {
                if joined.contains(id) {
                    self.waiting.lock().unwrap().insert((peer.to_string(), id.clone(), String::new()), 0);
                }
            }
            sum.shares.retain(|x| !held_back.contains(&x.id));
        }
        for f in self.mirror_files(peer, &ids) {
            let _ = std::fs::remove_file(f);
        }
        Ok((sum, via))
    }

    /// The bytes of small files that came inline with their entries (Slow link): each is checked against its entry's BLAKE3 hash and
    /// size, and only then put in the store, where the ordinary fetch finds it complete. Bytes that do not match are dropped: the file
    /// stays wanted and waits like any file a slow link does not carry. They are held against clean-up until the file is written.
    async fn take_inline(&self, page: &delta::Page) {
        for ch in &page.changes {
            let (Some(e), Some(bytes)) = (ch.e.as_ref().filter(|e| !e.deleted), delta::inline_bytes(ch)) else { continue };
            let Ok(hash) = e.hash.parse::<Hash>() else { continue };
            if bytes.len() as u64 != e.size || e.size > delta::INLINE_MAX || Hash::new(&bytes) != hash {
                self.inline_bad.fetch_add(1, Ordering::Relaxed);
                say(&format!("a small file's bytes from a device did not match its hash, so {} was not taken that way", ch.p));
                continue;
            }
            if self.store.is_complete(hash).await {
                continue;
            }
            let st = self.store.raw().clone();
            let added = tokio::task::spawn_blocking(move || st.add_bytes(&bytes).map(|a| a.hash())).await;
            if matches!(added, Ok(Ok(h)) if h == hash) {
                self.wanted.lock().unwrap().insert(hash);
                self.inline_ok.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    /// The view `peer` has of the folder `rs` summarises: the mirror when it already is at the summary's counter, the mirror
    /// followed to it page by page (each page applied and saved in one write before the next is asked for), or the folder's
    /// whole list (asked once for all the folders that need it, in `full`), which replaces the mirror.
    async fn catch_up(&self, peer: &str, rs: &RemoteShare, closed: &AtomicU32, full: &mut Option<RemoteIndex>) -> Result<Option<Index>> {
        let fp = rs.fp.clone().ok_or_else(|| anyhow!("the summary has no fingerprint for {}", rs.name))?;
        let (epoch, counter) = (rs.index.epoch.clone(), rs.index.counter);
        let class = self.class_of(peer);
        let mut start = self.load_mirror(peer, &rs.id).filter(|m| m.follows(&epoch, &fp, counter));
        if start.is_none() && class == Speed::Medium && !epoch.is_empty() {
            // The whole comparison on a medium link goes in pages: the differences since nothing, from an empty mirror.
            start = Some(delta::Mirror { epoch: epoch.clone(), fp: fp.clone(), ..Default::default() });
        }
        if let Some(mut m) = start {
          loop {
            if m.is_at(counter) {
                return Ok(Some(m.index()));
            }
            let ask = delta::DiffAsk { share: rs.id.clone(), epoch: epoch.clone(), fp: fp.clone(), c: m.ctr, p: m.after.clone(), max: self.page_ask(class), inl: class == Speed::Slow };
            let (bytes, _) = self.net.ask_delta(peer, Delta::Diff, serde_json::to_vec(&ask)?, closed).await?;
            self.asked_diff.fetch_add(1, Ordering::Relaxed);
            let page: delta::Page = serde_json::from_slice(&bytes).context("the differences from the device are not valid")?;
            if page.full {
                break;
            }
            if class == Speed::Slow {
                self.take_inline(&page).await;
            }
            let before = (m.ctr, m.after.clone());
            m.take(&page);
            if page.more && (m.ctr, m.after.clone()) == before {
                bail!("the differences from the device do not move on");
            }
            #[cfg(feature = "test-hooks")]
            {
                // The process is stopped after the page was taken and before it was saved (for as long as `<dir>/kill-before-mirror-save`
                // exists): half the file reaches the temporary name, and the saved mirror stays as it was.
                if self.dir.join("kill-before-mirror-save").exists() {
                    let path = self.mirror_path(peer, &rs.id);
                    let bytes = serde_json::to_vec(&m)?;
                    std::fs::create_dir_all(path.parent().unwrap())?;
                    std::fs::write(path.with_extension("tmp"), &bytes[..bytes.len() / 2])?;
                    bail!("test: killed before the mirror was saved");
                }
            }
            write_json(&self.mirror_path(peer, &rs.id), &m)?;
          }
        }
        // The requests above have measured the link again: a slow one does not carry the whole list.
        if self.class_of(peer) == Speed::Slow {
            return Ok(None);
        }
        if full.is_none() {
            *full = Some(self.fetch_index(peer, closed).await?.0);
        }
        let f = full.as_ref().and_then(|f| f.shares.iter().find(|x| x.id == rs.id)).ok_or_else(|| anyhow!("{} is not in the device's file list", rs.name))?;
        if let Some(fp) = f.fp.as_deref().filter(|_| !f.index.epoch.is_empty()) {
            write_json(&self.mirror_path(peer, &rs.id), &delta::Mirror::from_full(&f.index, fp))?;
        }
        Ok(Some(f.index.clone()))
    }

    /// The unlinks this device offers in its file list: the kept ones, newer than [`REMOVAL_KEEP_MS`].
    fn removals_to_offer(&self, s: &Saved) -> Vec<Removal> {
        #[cfg(feature = "test-hooks")]
        {
            if self.dir.join("no-removed-field").exists() {
                // Acts as build 54, which says nothing about unlinks.
                return Vec::new();
            }
            if let Some(v) = read_json::<Vec<Removal>>(&self.dir.join("inject-removals.json")) {
                // Exactly these, signed or not as the test made them.
                return v;
            }
        }
        let now = now_ms();
        s.removals.iter().filter(|r| now.saturating_sub(r.t) < REMOVAL_KEEP_MS).cloned().collect()
    }

    /// `share` is kept with the linked device `peer` ([`Config::with`]).
    fn shares_with(&self, share: &str, peer: &str) -> bool {
        let Some(modes) = self.with.lock().unwrap().get(share).cloned() else { return true };
        let mode = link_mode(self.saved.lock().unwrap().peers.iter().find(|p| p.id == peer).and_then(|p| p.link.as_ref()));
        modes.contains(&mode)
    }

    /// What to do with `remote` (a linked device's view of `share`, [`Inner::remote_view`]): [`index::merge`] with this device's
    /// index. Everything a linked device changes, replaces or deletes arrives here as it is.
    fn merge_from(&self, share: &str, remote: &Index, _peer: &str) -> Vec<Action> {
        index::merge(&self.load_index(share), remote)
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

    /// How long two refusals of "not linked" must be apart before the link is dropped ([`UNLINK_INTERVAL`]).
    fn unlink_interval(&self) -> Duration {
        #[cfg(feature = "test-hooks")]
        if let Some(ms) = std::fs::read_to_string(self.dir.join("unlink-interval-ms")).ok().and_then(|v| v.trim().parse().ok()) {
            return Duration::from_millis(ms);
        }
        UNLINK_INTERVAL
    }

    /// Takes the link to `id` out of everything this device holds about it: the saved links, who may connect, what was learned and
    /// received. The same for a link taken off here and for one the other device unlinked. Files already here stay.
    fn remove_peer(&self, id: &str) -> Result<()> {
        {
            let mut sv = self.saved.lock().unwrap();
            let was_linked = sv.peers.iter().any(|p| p.id == id);
            sv.peers.retain(|p| p.id != id);
            let now = now_ms();
            sv.former.retain(|f| f.id != id && now.saturating_sub(f.t) < REMOVAL_KEEP_MS);
            if was_linked && id != self.me {
                sv.former.push(Former { id: id.to_string(), t: now });
            }
        }
        self.push_former();
        self.net.disallow(id);
        self.run.lock().unwrap().peers.remove(id);
        self.waiting.lock().unwrap().retain(|(p, _, _), _| p != id);
        self.summary_peers.lock().unwrap().remove(id);
        for f in self.mirror_files(id, &[]) {
            let _ = std::fs::remove_file(f);
        }
        self.due.lock().unwrap().remove(id);
        self.heard_from.lock().unwrap().remove(id);
        self.reach_pending.lock().unwrap().remove(id);
        self.last_contact.lock().unwrap().remove(id);
        self.serving.lock().unwrap().remove(id);
        self.notice_out.lock().unwrap().remove(id);
        self.secrets.lock().unwrap().remove(id);
        self.received.lock().unwrap().remove(id);
        self.refused.lock().unwrap().remove(id);
        self.save()
    }

    /// Tells the transport which devices used to be linked and are not now (the kept ones, newer than [`REMOVAL_KEEP_MS`]).
    fn push_former(&self) {
        let now = now_ms();
        let ids: Vec<String> = self.saved.lock().unwrap().former.iter().filter(|f| now.saturating_sub(f.t) < REMOVAL_KEEP_MS).map(|f| f.id.clone()).collect();
        self.net.set_former(&ids);
    }

    /// The person unlinks `id` here: [`Inner::remove_peer`], then a signed [`Removal`] kept for the other linked devices
    /// ([`REMOVAL_KEEP_MS`]), which unlink it too when they next see this device's file list. A device that is not linked is only
    /// cleaned up, and nothing is offered.
    fn remove_device(&self, id: &str) -> Result<()> {
        let linked = self.saved.lock().unwrap().peers.iter().any(|p| p.id == id);
        if linked && id != self.me {
            let (key, _) = identity::load_or_create(&self.dir)?;
            let now = now_ms();
            let mut sv = self.saved.lock().unwrap();
            sv.removals.retain(|r| r.target != id && now.saturating_sub(r.t) < REMOVAL_KEEP_MS);
            sv.removals.push(sign_removal(&key, id, now));
        }
        self.remove_peer(id)
    }

    /// A linked device's file list carries unlinks: applies each that holds up, as a local unlink without a new Removal (so
    /// nothing echoes). It holds up when `by` is linked here, the signature is `by`'s, the target is linked here and is not this
    /// device, and `t` is after this device linked with the target (a link with no time saved counts as older).
    fn apply_removals(&self, list: &[Removal]) {
        for r in list {
            if r.target == self.me || r.by == self.me {
                continue;
            }
            let (by, target) = {
                let sv = self.saved.lock().unwrap();
                (sv.peers.iter().find(|p| p.id == r.by).cloned(), sv.peers.iter().find(|p| p.id == r.target).cloned())
            };
            let (Some(by), Some(target)) = (by, target) else { continue };
            if !removal_checks_out(r) {
                continue;
            }
            if r.t <= target.linked {
                // Said once for each, not on every round: the sender keeps offering it.
                if self.refused_removals.lock().unwrap().insert((r.target.clone(), r.by.clone(), r.t)) {
                    self.note(format!(
                        "Not unlinked {}: the request from {} is older than this link (check the clocks on both devices)",
                        target.name, by.name
                    ));
                }
                continue;
            }
            if self.remove_peer(&target.id).is_ok() {
                self.note(format!("{} unlinked {}", by.name, target.name));
            }
        }
    }

    /// Notes how a check-in with `peer` ended, and drops the link when the other device has refused it as "not linked" (403) in
    /// two rounds at least [`UNLINK_INTERVAL`] apart. `closed` is the close code of the other device's Gate, if that is what ended
    /// it, and `answered` that it answered. Only 403 ever counts: a 409 (its links were reset), a 503 (busy), a timeout or any other
    /// error is never an unlink, and a 409 or an answer forgets the 403 seen before. Nothing is sent and nothing is said: the other
    /// device does not list this one, and this one stops listing it. True when the link was dropped.
    fn check_in_ended(&self, peer: &str, closed: Option<u32>, answered: bool) -> bool {
        #[cfg(feature = "test-hooks")]
        if self.dir.join("no-unlink-on-403").exists() {
            // A device that acts as an older build, which does not know this rule.
            return false;
        }
        let drop_it = {
            let mut m = self.refused.lock().unwrap();
            if closed == Some(403) {
                let first = *m.entry(peer.to_string()).or_insert_with(Instant::now);
                first.elapsed() >= self.unlink_interval()
            } else {
                if answered || closed == Some(409) {
                    m.remove(peer);
                }
                false
            }
        };
        if !drop_it {
            return false;
        }
        // The name this device had saved for it, read before the entry goes.
        let name = self.peer_name(peer);
        if self.remove_peer(peer).is_err() {
            return false;
        }
        let line = format!("{name} unlinked this device");
        self.note(line.clone());
        say(&line);
        true
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
            self.net.disallow(&p.id);
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
        let (bytes, _) = self.net.ask(peer, Ask::Secrets, &AtomicU32::new(0)).await?;
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
        if !self.store_ready.load(Ordering::SeqCst) {
            // The file store is being moved to its new format; nothing is scanned or fetched until it is done.
            return;
        }
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
        // Also lets a former device that is past its 30 days go.
        self.push_former();
        let peers: Vec<Peer> = self.saved.lock().unwrap().peers.iter().filter(|p| scope.has_peer(&p.id)).cloned().collect();
        {
            // Every device this round covers has been asked as of now (the safety round counts from it).
            let (mut lc, now) = (self.last_contact.lock().unwrap(), Instant::now());
            for p in &peers {
                lc.insert(p.id.clone(), now);
            }
        }
        // First every reachable peer's index, so each file can be fetched from every peer that has it.
        for p in &peers {
            if !self.may_use_network() {
                break;
            }
            if !self.saved.lock().unwrap().peers.iter().any(|x| x.id == p.id) {
                // Unlinked meanwhile (a linked device's unlink of it, in this round).
                continue;
            }
            let closed = AtomicU32::new(0);
            let res = self.fetch_remote(&p.id, &closed).await;
            // Whether the other device has unlinked this one (see check_in_ended): then there is nothing more to do with it.
            let code = Some(closed.load(Ordering::Relaxed)).filter(|c| *c != 0);
            if self.check_in_ended(&p.id, code, res.is_ok()) {
                continue;
            }
            let mut asks = None;
            let mut learned = None;
            // The device unlinked others and says so (signed): this one unlinks them too.
            if let Some(list) = res.as_ref().ok().map(|(idx, _)| idx.removed.clone()).filter(|l| !l.is_empty()) {
                self.apply_removals(&list);
            }
            // A file list from a device linked before Reticulum (or from build 54) tells where to reach it.
            if let Some(r) = res.as_ref().ok().and_then(|(idx, _)| idx.rns.clone()) {
                if p.rns.as_ref().map(|x| x.dest.as_str()) != Some(r.dest.as_str()) {
                    self.learn_rns(&p.id, &r);
                }
            }
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
        if scope.counts() {
            run.rounds += 1;
            run.last_round = Some(now_ms());
        }
    }

    async fn fetch_index(&self, peer: &str, closed: &AtomicU32) -> Result<(RemoteIndex, String)> {
        let (bytes, via) = self.net.ask(peer, Ask::Index, closed).await?;
        self.asked_full.fetch_add(1, Ordering::Relaxed);
        Ok((serde_json::from_slice(&bytes).context("the file list from the device is not valid")?, via))
    }

    /// Who has `hash` (by their last index), us excluded, among the devices `share` is kept with.
    fn providers(&self, share: &str, hash: &str) -> Vec<String> {
        let found: Vec<String> = {
            let run = self.run.lock().unwrap();
            run.peers
                .iter()
                .filter(|(_, s)| s.error.is_none())
                .filter(|(_, s)| s.index.as_ref().map(|i| i.shares.iter().any(|sh| sh.index.files.values().any(|e| !e.deleted && e.hash == hash))).unwrap_or(false))
                .map(|(id, _)| id.clone())
                .collect()
        };
        found.into_iter().filter(|id| self.shares_with(share, id)).collect()
    }

    /// Takes from `from` what is newer there. A file that cannot be fetched or deleted is noted and the rest goes on, so one
    /// bad file does not hold up its share; only losing the network stops it. A file with no room for it is passed over and
    /// comes back as the error at the end, so the status still says sync is paused.
    async fn apply(self: &Arc<Self>, sh: &Share, remote: &Index, from: &str) -> Result<()> {
        let remote = &self.remote_view(&sh.id, remote);
        let mut actions = self.merge_from(&sh.id, remote, from);
        // Deletes come after what is fetched: a rename here is a delete of the old path and a fetch of the new one, and the store
        // may read that content from the old path, so it must still be there when the new one is written (the store is pointed
        // at the new path once the old one goes, below). What says the rest has come comes after the rest ([`Config::last`]),
        // deletes included. The sort keeps the order otherwise.
        let last: &[String] = self.last.get(&sh.id).map(|v| v.as_slice()).unwrap_or(&[]);
        actions.sort_by_key(|a| match a {
            Action::Fetch { path, .. } if excluded(last, path) => 2,
            Action::Delete { .. } => 1,
            _ => 0,
        });
        // Something did not come or go in this call (it failed, or was put off): what says the rest has come must wait too.
        let mut held = false;
        let mut no_room: Option<anyhow::Error> = None;
        let fetch_paths: HashSet<String> = actions.iter().filter_map(|a| if let Action::Fetch { path, .. } = a { Some(path.clone()) } else { None }).collect();
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
                        self.note_file(&sh.id, format!("{}: kept {path}, changed here after {} deleted it", sh.name, self.peer_name(from)));
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
                        let _ = self.store.delete_tag(Self::tag_name(&sh.id, &path).as_bytes()).await;
                        seen.remove(&path);
                        let gone = idx.files.get(&path).filter(|e| !e.deleted).map(|e| e.hash.clone());
                        idx.files.insert(path.clone(), entry);
                        self.store_index(&sh.id, &idx, &seen)?;
                        self.unmark_writing(&sh.id, &path)?;
                        self.note_file(&sh.id, format!("{}: {} deleted {path}", sh.name, self.peer_name(from)));
                        // The content that was here may live on at another path (a rename): the store reads it from there now.
                        if let Some(h) = gone {
                            self.repoint(&h, None).await;
                        }
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
                    let size = entry.size;
                    let key = (sh.id.clone(), path.clone());
                    let wkey = (from.to_string(), sh.id.clone(), path.clone());
                    match self.fetch(sh, &path, entry, conflict, from).await {
                        Ok(true) => {
                            self.waiting.lock().unwrap().remove(&wkey);
                            self.end_backoff(from);
                            if self.held_from.lock().unwrap().get_mut(from).is_some_and(|s| s.remove(&key)) {
                                say(&format!("fetch from {} resumed and finished ({} MB)", self.peer_name(from), size / 1_048_576));
                            }
                        }
                        Ok(false) => {
                            held = true;
                            self.waiting.lock().unwrap().remove(&wkey);
                            if let Some(s) = self.held_from.lock().unwrap().get_mut(from) {
                                s.remove(&key);
                            }
                        }
                        // The link's class holds it back: listed as waiting, still wanted (held like a file not yet fetched, so
                        // the next round asks again), and not an error.
                        Err(e) if is_waiting(&e) => {
                            held = true;
                            self.note_slow_cancel(from);
                            self.held_from.lock().unwrap().entry(from.to_string()).or_default().insert(key);
                            self.waiting.lock().unwrap().insert(wkey, size);
                        }
                        Err(e) => {
                            held = true;
                            self.held_from.lock().unwrap().entry(from.to_string()).or_default().insert(key);
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
        if !self.stop.load(Ordering::Relaxed) {
            // What this device no longer wants from `from` (gone or replaced there) is not held.
            if let Some(s) = self.held_from.lock().unwrap().get_mut(from) {
                s.retain(|(id, p)| *id != sh.id || fetch_paths.contains(p));
            }
            self.waiting.lock().unwrap().retain(|(f, id, p), _| p.is_empty() || f != from || *id != sh.id || fetch_paths.contains(p));
        }
        match no_room {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Makes sure the store holds `entry`'s content (fetched from the devices that have it), to be written at `full` (`path` in
    /// `sh`): the room needed is checked where the store is and where `full` is.
    async fn ensure_blob(self: &Arc<Self>, sh: &Share, path: &str, full: &Path, entry: &Entry) -> Result<Hash> {
        let hash: Hash = entry.hash.parse().map_err(|_| anyhow!("bad hash for {path}"))?;
        let have = self.store.is_complete(hash).await;
        if !have {
            if !self.may_use_network() {
                bail!("Paused: no network it may use");
            }
            let reserve = self.reserve.load(Ordering::Relaxed);
            let need = entry.size;
            // The store takes it first; where the shared folder is on another file system (a phone's internal and shared
            // storage) the copy into place needs the room there too.
            for at in [self.dir.as_path(), full] {
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
            // Only from the devices whose link carries it: the others hold it back, and it waits for a faster link.
            let providers: Vec<String> = providers.into_iter().filter(|p| self.class_allows(self.class_of(p), &sh.id, entry.size)).collect();
            if providers.is_empty() {
                return Err(anyhow::Error::new(Waiting));
            }
            self.run.lock().unwrap().transfer = Some(Transfer {
                share_id: sh.id.clone(),
                share: sh.name.clone(),
                path: path.to_string(),
                size: entry.size,
                done: 0,
                from: providers.iter().map(|p| self.peer_name(p)).collect(),
            });
            let mut stream = self.net.fetch(self.store.raw(), hash, providers.clone()).await?;
            let mut failed = None;
            let mut too_slow = false;
            let mut last_progress = Instant::now();
            loop {
                // Woken every second even when nothing arrives, so a pause or a stalled path is noticed.
                match tokio::time::timeout(Duration::from_secs(1), stream.next()).await {
                    Ok(None) => break,
                    Ok(Some(item)) => match item {
                        FetchEvent::Progress(n) => {
                            last_progress = Instant::now();
                            if let Some(t) = self.run.lock().unwrap().transfer.as_mut() {
                                t.done = n;
                            }
                            #[cfg(feature = "test-hooks")]
                            if n > 0 && self.dir.join("drop-fetch-mid").exists() {
                                // A link that drops part way: while `<dir>/drop-fetch-mid` exists a fetch fails after its first window.
                                failed = Some("test: link dropped".to_string());
                                break;
                            }
                            #[cfg(feature = "test-hooks")]
                            {
                                // A fetch caught part way (after its first window): held while `<dir>/hold-fetch-mid` exists, and
                                // it says so with `<dir>/hold-fetch.held`.
                                let hold = self.dir.join("hold-fetch-mid");
                                if n > 0 && hold.exists() {
                                    let _ = std::fs::write(self.dir.join("hold-fetch.held"), b"");
                                    while hold.exists() {
                                        tokio::time::sleep(Duration::from_millis(50)).await;
                                    }
                                    let _ = std::fs::remove_file(self.dir.join("hold-fetch.held"));
                                    last_progress = Instant::now();
                                }
                            }
                        }
                        FetchEvent::Failed(m) => failed = Some(m),
                        FetchEvent::Waiting(m) => {
                            failed = Some(m);
                            too_slow = true;
                        }
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
            let done = self.run.lock().unwrap().transfer.as_ref().map(|t| t.done).unwrap_or(0);
            self.run.lock().unwrap().transfer = None;
            if let Some(f) = failed {
                if too_slow {
                    // Either end says the link is too slow for it: held back, not failed. What arrived stays in the store.
                    return Err(anyhow::Error::new(Waiting));
                }
                let names: Vec<String> = providers.iter().map(|p| self.peer_name(p)).collect();
                say(&format!("fetch from {} stopped at {}/{} MB: {f} (will retry)", names.join(", "), done / 1_048_576, need / 1_048_576));
                // What arrived stays in the store (still wanted), so the next round carries on from there.
                if f == NO_SPACE {
                    bail!("Paused: no room to keep {path} ({} needed). Free up space and it carries on.", human(need));
                }
                bail!("{path}: {f} (will resume)");
            }
        }
        Ok(hash)
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
        let hash = self.ensure_blob(sh, path, &full, &entry).await?;
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
                self.note_file(&sh.id, format!("{}: {path} was changed here and on {}; kept ours as {copy}", sh.name, self.peer_name(from)));
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
            let bytes = self.store.get_bytes(hash).await.map_err(|e| anyhow!("{e}"))?;
            std::fs::write(&full, &bytes[..bytes.len() / 2])?;
            self.stop.store(true, Ordering::Relaxed);
            bail!("test: cut off writing {path}");
        }
        let size_of_entry = entry.size;
        if let Err(e) = self.store.export_move(hash, full.clone()).await {
            // Whatever part got written goes; the content stays in the store and the next round writes it again.
            if std::fs::remove_file(&full).is_err() && full.exists() {
                // Left for the recovery a start does, before the next scan could take it for an edit.
                self.recovered.store(false, Ordering::Relaxed);
            }
            if is_no_space(e.as_ref()) {
                bail!("Paused: no room to write {path} ({} needed). Free up space and it carries on.", human(size_of_entry));
            }
            bail!("could not write {path}: {e}");
        }
        self.wanted.lock().unwrap().remove(&hash);
        let entry_hash = entry.hash.clone();
        let size = entry.size;
        self.written(sh, path, &full, entry).await?;
        self.note_file(&sh.id, format!("{}: got {path} ({})", sh.name, human(size)));
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
    #[cfg(feature = "test-hooks")]
    if let Some(d) = p.parent() {
        // A rewrite caught part way: held while `<dir>/hold-write` exists (it says so with `<dir>/hold-write.held`).
        let hold = d.join("hold-write");
        if hold.exists() {
            let _ = std::fs::write(d.join("hold-write.held"), b"");
            while hold.exists() {
                std::thread::sleep(Duration::from_millis(50));
            }
            let _ = std::fs::remove_file(d.join("hold-write.held"));
        }
    }
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

/// How long after a recovery of the links file (or a fresh start) the Gate says "links reset" instead of "not linked": the same
/// time a link may wait to be confirmed ([`CONFIRM_WINDOW`]); `<dir>/grace-ms` makes it shorter in tests.
fn links_grace(dir: &Path) -> Duration {
    #[cfg(feature = "test-hooks")]
    if let Some(ms) = std::fs::read_to_string(dir.join("grace-ms")).ok().and_then(|v| v.trim().parse().ok()) {
        return Duration::from_millis(ms);
    }
    let _ = dir;
    CONFIRM_WINDOW
}

/// Until when (ms since 1970) this start's links are not to be trusted to be complete, 0 for never. `recovered`: this start used
/// the last good copy of the links, recreated them empty, or is a fresh start. That is written to `<dir>/links-recovered-at` (and
/// flushed) before the Gate answers anyone, so the grace goes on across restarts; a start from a healthy file only reads it.
fn links_grace_until(dir: &Path, recovered: bool) -> Result<u64> {
    use std::io::Write as _;
    let marker = dir.join("links-recovered-at");
    let at = if recovered {
        let now = now_ms();
        let tmp = dir.join("links-recovered-at.tmp");
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(now.to_string().as_bytes())?;
        f.sync_all()?;
        drop(f);
        std::fs::rename(&tmp, &marker)?;
        now
    } else {
        // A marker that cannot be read is no marker (a healthy file is what the links come from).
        std::fs::read_to_string(&marker).ok().and_then(|t| t.trim().parse::<u64>().ok()).unwrap_or(0)
    };
    if at == 0 {
        return Ok(0);
    }
    Ok(at.saturating_add(links_grace(dir).as_millis() as u64))
}

#[derive(Serialize, Deserialize)]
struct PairHello {
    token: String,
    name: String,
    /// The device key of the sender, for a pairing over Reticulum (over iroh the connection proves it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    key: Option<String>,
    /// The sender's Reticulum destination and signature.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rns: Option<RnsProof>,
}

/// What the network asks of the engine: answers linking requests that carry the code being shown, and the questions of linked devices.
impl Serve for Inner {
    fn pair_hello(&self, peer: &str, bytes: &[u8]) -> Vec<u8> {
        let hello: Option<PairHello> = serde_json::from_slice(bytes).ok();
        let ok = {
            let mut p = self.pairing.lock().unwrap();
            match (&*p, &hello) {
                (Some((tok, until)), Some(h)) if *tok == h.token && Instant::now() < *until => {
                    *p = None; // one use
                    true
                }
                _ => false,
            }
        };
        let reply = if let (true, Some(h)) = (ok, hello) {
            // Not confirmed until the other device comes back: this answer may never reach it.
            add_peer(self, peer, &h.name, true);
            if let Some(r) = &h.rns {
                self.learn_rns(peer, r);
            }
            self.note(format!("Linked with {}", h.name));
            self.wake.notify_one();
            let mut reply = json!({"ok": true, "name": self.saved.lock().unwrap().name});
            if let Some((dest, sig)) = self.rns_info() {
                reply["rns"] = json!({"dest": dest, "sig": sig});
            }
            reply
        } else {
            json!({"ok": false, "error": "that code is not being shown any more"})
        };
        reply.to_string().into_bytes()
    }

    fn pair_short(self: Arc<Self>, body: Vec<u8>) -> transport::BoxFut<'static, Vec<u8>> {
        Box::pin(async move {
            let refuse = |why: &str| json!({"ok": false, "error": why}).to_string().into_bytes();
            let Ok(req) = serde_json::from_slice::<ShortPair>(&body) else { return refuse("not a pairing request") };
            let secret = data_encoding::BASE32_NOPAD.decode(req.secret.as_bytes()).unwrap_or_default();
            // The checks, in order: a code is being shown and has not run out; the secret is right (three wrong ones burn the
            // code); the requester's signature checks out. Only a good one uses the code up.
            {
                let mut live = self.short.lock().unwrap();
                let now = self.code_now();
                match live.as_mut() {
                    Some(c) if now < c.expires_ms => {
                        if !ct_eq(&c.secret, &secret) {
                            c.strikes += 1;
                            if c.strikes >= SHORT_STRIKES {
                                *live = None;
                            }
                            return refuse("that code is not right");
                        }
                    }
                    _ => {
                        *live = None;
                        return refuse("that code is not being shown any more");
                    }
                }
                if !self.net.verify_rns(&req.hello.key, &req.hello.rns.dest, &req.hello.rns.sig) {
                    return refuse("the hello's signature does not check out");
                }
                *live = None; // one use
            }
            let h = req.hello;
            if let Some(a) = h.iroh.clone() {
                self.net.learn_iroh(a);
            }
            // Not confirmed until the other device comes back: this answer may never reach it.
            add_peer(&self, &h.key, &h.name, true);
            self.learn_rns(&h.key, &h.rns);
            self.note(format!("Linked with {}", h.name));
            self.wake.notify_one();
            let Some((dest, sig)) = self.rns_info() else { return refuse("Reticulum is not running here") };
            let net = self.net.clone();
            let iroh = self.hello_iroh(net.link_addr().await.0);
            let hello = ShortHello { key: self.me.clone(), iroh, name: self.saved.lock().unwrap().name.clone(), rns: RnsProof { dest, sig } };
            json!({"ok": true, "hello": hello}).to_string().into_bytes()
        })
    }

    fn answer(self: Arc<Self>, peer: String, ask: Ask) -> transport::BoxFut<'static, Vec<u8>> {
        Box::pin(async move {
            // Only a device that holds the link asks: a link made here by showing a code is confirmed by it.
            self.confirm_peer(&peer);
            self.heard_from.lock().unwrap().insert(peer.clone());
            match ask {
                Ask::Secrets => {
                    // Only the secrets set for the device asking, over its own connection (end to end encrypted to its key).
                    let mine = self.secrets.lock().unwrap().get(&peer).cloned().unwrap_or_default();
                    serde_json::to_vec(&mine).unwrap_or_default()
                }
                Ask::Index => tokio::task::spawn_blocking(move || serde_json::to_vec(&self.our_index_for(&peer)).unwrap_or_default())
                    .await
                    .unwrap_or_default(),
            }
        })
    }

    fn answer_delta(self: Arc<Self>, peer: String, what: Delta, body: Vec<u8>) -> transport::BoxFut<'static, Vec<u8>> {
        Box::pin(async move {
            self.confirm_peer(&peer);
            self.heard_from.lock().unwrap().insert(peer.clone());
            #[cfg(feature = "test-hooks")]
            if self.dir.join("no-delta").exists() {
                return b"error: test: not answered".to_vec();
            }
            tokio::task::spawn_blocking(move || match what {
                Delta::Summary => serde_json::to_vec(&self.index_for(&peer, false)).unwrap_or_default(),
                Delta::Diff => self.diff_answer(&peer, &body),
            })
            .await
            .unwrap_or_default()
        })
    }

    fn asked(&self, peer: &str) {
        self.asked_wakes(peer);
    }

    fn page_cap(&self, speed: Speed) -> usize {
        match speed {
            Speed::Fast => delta::PAGE_BYTES,
            Speed::Medium => self.medium_page,
            Speed::Slow => transport::SLOW_PAGE_BYTES,
        }
    }

    /// The big kinds do not go over a Medium link: a window is refused when every folder kept with `peer` that lists the file is
    /// one of them. A file no folder lists (or any folder that is not a big kind lists) goes, subject to its size.
    #[cfg(feature = "test-hooks")]
    fn test_refuse_blobs(&self) -> bool {
        // A device with `<dir>/refuse-blobs` refuses every window as too slow (a link that turned out slow at the answering end).
        self.dir.join("refuse-blobs").exists()
    }

    fn blob_allowed(&self, peer: &str, hash: &str, speed: Speed) -> bool {
        if speed != Speed::Medium {
            return true;
        }
        let shares = self.saved.lock().unwrap().shares.clone();
        let listing: Vec<&Share> = shares
            .iter()
            .filter(|sh| self.shares_with(&sh.id, peer))
            .filter(|sh| self.load_index(&sh.id).files.values().any(|e| !e.deleted && e.hash == hash))
            .collect();
        listing.is_empty() || listing.iter().any(|sh| !self.bulk.contains(&sh.id))
    }

    fn link_closed(&self, peer: &str, reason: &str, open_secs: Option<u64>, rtt_ms: Option<u64>) {
        say(&link_closed_line(&self.peer_name(peer), reason, open_secs, rtt_ms));
    }

    fn notice(&self, peer: &str, body: &[u8]) -> Vec<u8> {
        // The network lets only a linked device's notice through; the engine checks again, since a notice starts a round.
        if !self.saved.lock().unwrap().peers.iter().any(|p| p.id == peer) {
            say("notice from a device that is no longer linked: refused");
            return b"not linked".to_vec();
        }
        let Ok(n) = serde_json::from_slice::<delta::Notice>(body) else { return b"not a notice".to_vec() };
        self.notice_got.fetch_add(1, Ordering::Relaxed);
        self.heard_from.lock().unwrap().insert(peer.to_string());
        // Caught up already (the saved mirror is at this epoch and counter or past it): nothing to ask.
        let behind = self.load_mirror(peer, &n.s).is_none_or(|m| m.epoch != n.e || n.c > m.ctr || m.after.is_some());
        say(&format!("notice from {}: {} at {}{}", self.peer_name(peer), self.share_name(&n.s), n.c, if behind { "" } else { " (already up to date)" }));
        if behind {
            self.make_due(peer);
        }
        b"ok".to_vec()
    }

    fn reachable(&self, peer: &str) {
        if self.saved.lock().unwrap().peers.iter().any(|p| p.id == peer) {
            // A moment later: a round the instant an announce is heard can ask before the link to the device can be made.
            self.reach_pending.lock().unwrap().insert(peer.to_string(), Instant::now() + REACHABLE_DELAY);
            self.wake_due.notify_one();
        }
    }

    fn blobs_ready(&self) -> bool {
        #[cfg(feature = "test-hooks")]
        if self.dir.join("hold-store-ready").exists() {
            return false;
        }
        self.store_ready.load(Ordering::SeqCst)
    }

    fn served(&self, peer: &str, hash: &str, end: u64) {
        #[cfg(feature = "test-hooks")]
        if self.dir.join("no-serve-signal").exists() {
            return;
        }
        let now = Instant::now();
        {
            let mut sv = self.serving.lock().unwrap();
            if let Some(s) = sv.get_mut(peer).filter(|s| s.hash == hash) {
                s.high = s.high.max(if s.size > 0 { end.min(s.size) } else { end });
                s.at = now;
                return;
            }
        }
        // The first window of a file: which folder of ours lists it, and its size there (our own index).
        let shares = self.saved.lock().unwrap().shares.clone();
        let found = shares.iter().filter(|sh| self.shares_with(&sh.id, peer)).find_map(|sh| {
            self.load_index(&sh.id).files.values().find(|e| !e.deleted && e.hash == hash).map(|e| (sh.id.clone(), e.size))
        });
        let (share, size) = found.map(|(a, b)| (Some(a), b)).unwrap_or((None, 0));
        let high = if size > 0 { end.min(size) } else { end };
        self.serving.lock().unwrap().insert(peer.to_string(), Serving { hash: hash.to_string(), share, size, high, at: now });
    }

    fn nearby_linked(&self, peer: &str, name: &str, dest: &str, sig: &str) {
        // Both people confirmed and the signature checked out: stored exactly as a link made with a code is (the same
        // add_peer, the Reticulum address learned the same way), and confirmed on both sides, since both were present.
        add_peer(self, peer, name, false);
        self.learn_rns(peer, &RnsProof { dest: dest.to_string(), sig: sig.to_string() });
        self.note(format!("Linked with {name}"));
        self.wake.notify_one();
    }
}

impl Inner {
    /// The iroh address this device puts in a short code's hello. With `<dir>/no-iroh-in-hello` present (test hook) it gives none,
    /// so the other device can only reach it over Reticulum.
    fn hello_iroh(&self, addr: EndpointAddr) -> Option<EndpointAddr> {
        #[cfg(feature = "test-hooks")]
        if self.dir.join("no-iroh-in-hello").exists() {
            return None;
        }
        Some(addr)
    }

    /// The clock a short code runs on (tests move it on).
    fn code_now(&self) -> u64 {
        now_ms() + self.code_skew_ms.load(Ordering::Relaxed)
    }

    /// The name and kind this device gives a device that asks over Nearby.
    fn nearby_self(&self) -> (String, Option<String>) {
        (self.saved.lock().unwrap().name.clone(), self.device_kind.clone())
    }

    /// This device's Reticulum destination and signature, for what it sends other devices. With `<dir>/no-rns-fields` present
    /// (test hook) it says nothing, like a build before Reticulum.
    fn rns_info(&self) -> Option<(String, String)> {
        #[cfg(feature = "test-hooks")]
        if self.dir.join("no-rns-fields").exists() {
            return None;
        }
        self.net.rns_info()
    }

    /// Stores the Reticulum address `proof` gives for the linked device `peer`, when the device's own signature is on it.
    fn learn_rns(&self, peer: &str, proof: &RnsProof) {
        if !self.net.learn_rns(peer, &proof.dest, &proof.sig) {
            return;
        }
        let changed = {
            let mut s = self.saved.lock().unwrap();
            match s.peers.iter_mut().find(|p| p.id == peer) {
                Some(p) if p.rns.as_ref().map(|x| x.dest.as_str()) != Some(proof.dest.as_str()) => {
                    p.rns = Some(RnsPeer { dest: proof.dest.clone() });
                    true
                }
                _ => false,
            }
        };
        if changed {
            let _ = self.save();
        }
    }
}

fn add_peer(inner: &Inner, id: &str, name: &str, unconfirmed: bool) {
    {
        let mut s = inner.saved.lock().unwrap();
        s.peers.retain(|p| p.id != id);
        // Linked again: an unlink offered before no longer holds.
        s.removals.retain(|r| r.target != id);
        s.former.retain(|f| f.id != id);
        s.peers.push(Peer { id: id.to_string(), name: name.to_string(), linked: now_ms(), link: Some(new_link()), last_seen: None, via: None, announced: Some(name.to_string()), unconfirmed, rns: None });
    }
    inner.net.allow(id);
    inner.push_former();
    let _ = inner.save();
}

impl SyncEngine {
    /// Opens (or creates) the identity, store and settings in `cfg.dir`, binds the endpoint and starts the sync rounds.
    pub fn open(cfg: Config) -> Result<SyncEngine> {
        let steps = OpenSteps(Instant::now());
        steps.step("started");
        std::fs::create_dir_all(&cfg.dir)?;
        let folder = match FolderGuard::take(&cfg.dir) {
            Ok(g) => g,
            Err(e) => {
                steps.step("folder already open in this process");
                return Err(e);
            }
        };
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("cache-sync").enable_all().build()?;
        let inner = match rt.block_on(Self::start(cfg.clone(), &steps)) {
            Ok(v) => v,
            Err(e) => {
                steps.step("failed");
                return Err(e);
            }
        };
        let inner2 = inner.clone();
        let every = Duration::from_secs(cfg.interval_secs.unwrap_or(30).max(5));
        rt.spawn(async move {
            // What woke the loop: a round asked for (the first, a change, Sync now, a device that asked) covers every device; the
            // timer and a due device cover those that need a round ([`Inner::loop_scope`]).
            let mut asked_for = true;
            let mut first = true;
            loop {
                if inner2.stop.load(Ordering::Relaxed) {
                    break;
                }
                let (scope, causes, asks) = if asked_for {
                    inner2.due.lock().unwrap().clear();
                    inner2.due_why.lock().unwrap().clear();
                    let why = inner2.wake_why.lock().unwrap().take().unwrap_or_else(|| if first { "start".into() } else { "a change here".into() });
                    (Scope::default(), vec![why], inner2.saved.lock().unwrap().peers.len())
                } else {
                    inner2.loop_scope()
                };
                first = false;
                inner2.say_round(&causes, asks);
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
                    if scope.whole() {
                        inner3.round().await
                    } else {
                        inner3.round_with(&scope).await
                    }
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
                // Also never longer than the safety interval: which devices are quiet can change while the loop sleeps (a device that
                // asks this one becomes quiet), and the safety round must not wait on a wake-up computed before that.
                let wait = inner2.next_safety_in().map(|d| d.min(wait)).unwrap_or(wait).min(inner2.safety);
                asked_for = tokio::select! {
                    _ = tokio::time::sleep(wait) => false,
                    _ = inner2.wake.notified() => true,
                    _ = inner2.wake_due.notified() => false,
                };
            }
        });
        let inner5 = inner.clone();
        rt.spawn(async move { inner5.notice_loop().await });
        let inner6 = inner.clone();
        rt.spawn(async move { inner6.resume_loop().await });
        if let Some(secs) = cfg.lifetime_secs {
            let inner4 = inner.clone();
            let net4 = inner.net.clone();
            rt.spawn(async move {
                tokio::time::sleep(Duration::from_secs(secs)).await;
                // Closed already (close sets `stop` first): nothing left to do.
                if inner4.stop.swap(true, Ordering::Relaxed) {
                    return;
                }
                inner4.note("Stopped: the time limit of this run was reached");
                inner4.wake.notify_one();
                let _ = tokio::time::timeout(Duration::from_secs(5), net4.shutdown()).await;
                let _ = inner4.store.shutdown().await;
            });
        }
        steps.step("done");
        Ok(SyncEngine { rt, inner, _folder: folder })
    }

    async fn start(cfg: Config, steps: &OpenSteps) -> Result<Arc<Inner>> {
        std::fs::create_dir_all(&cfg.dir)?;
        // Read before anything is written: if the links cannot be read now, nothing here may be changed.
        let fresh = !cfg.dir.join("sync.json").exists();
        let (mut saved, saved_note) = load_saved(&cfg.dir.join("sync.json"))?;
        // Whether the links can be trusted to be complete, for what the Gate may say to a key that is not linked.
        let gate = Arc::new(GateState::default());
        gate.grace_until.store(links_grace_until(&cfg.dir, fresh || saved_note.is_some())?, Ordering::SeqCst);
        steps.step("links loaded");
        let (secret, _) = identity::load_or_create(&cfg.dir)?;
        steps.step("identity loaded");
        if saved.name.is_empty() {
            saved.name = cfg.name.clone().unwrap_or_else(|| "Cache device".into());
        }
        if migrate_links(&mut saved) {
            write_saved(&cfg.dir.join("sync.json"), &saved)?;
        }

        let mut b = Endpoint::builder(presets::Minimal).secret_key(secret.clone());
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
        let wanted: Arc<Mutex<HashSet<Hash>>> = Arc::default();
        // Hashes whose files in the store the iroh bridge reads (see `bridge`): the store never deletes or moves those.
        let lent: Arc<Mutex<HashSet<Hash>>> = Arc::default();
        let bridge = bridge::Bridge::new(cfg.dir.join("blobs-iroh-view"), wanted.clone(), lent.clone());
        let iroh_net = IrohTransport::bind(b, saved.peers.iter().map(|p| p.id.clone()), gate.clone(), bridge).await?;
        // Reticulum beside iroh (Android and Linux), when asked: the saved links with the destination saved for each.
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let multi = cfg.reticulum.then(|| {
            rns_transport::MultiTransport::new(iroh_net.clone(), saved.peers.iter().map(|p| (p.id.clone(), p.rns.as_ref().map(|r| r.dest.clone()))))
        });
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let net: Arc<dyn Transport> = match &multi {
            Some(m) => m.clone(),
            None => iroh_net.clone(),
        };
        #[cfg(not(any(target_os = "linux", target_os = "android")))]
        let net: Arc<dyn Transport> = iroh_net.clone();
        steps.step("endpoint bound");

        let (w2, l2) = (wanted.clone(), lent.clone());
        let opts = StoreOptions {
            protect: Some(Arc::new(move || w2.lock().unwrap().clone())),
            lent: Some(Arc::new(move || l2.lock().unwrap().clone())),
            ..StoreOptions::default()
        };
        let store_dir = cfg.dir.join("store");
        let raw = {
            let dir = store_dir.clone();
            tokio::task::spawn_blocking(move || Store::open(&dir, opts)).await?.map_err(|e| anyhow!("could not open the store: {e}"))?
        };
        let store = Blobs::new(raw);
        steps.step("blob store opened");

        let inner = Arc::new(Inner {
            dir: cfg.dir.clone(),
            me: net.id(),
            net,
            store: store.clone(),
            saved: Mutex::new(saved),
            gate: gate.clone(),
            refused: Mutex::new(HashMap::new()),
            refused_removals: Mutex::new(Default::default()),
            pairing: Mutex::new(None),
            short: Mutex::new(None),
            code_skew_ms: AtomicU64::new(0),
            run: Mutex::new(Run::default()),
            wanted,
            wake: Notify::new(),
            every: Duration::from_secs(cfg.interval_secs.unwrap_or(30).max(5)),
            asked_at: Mutex::new(HashMap::new()),
            held_from: Mutex::new(HashMap::new()),
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
            quiet: cfg.quiet.iter().cloned().collect(),
            off: Mutex::new(cfg.off.clone()),
            send_gate: Mutex::new(cfg.send_gate.clone()),
            refetch: Mutex::new(HashMap::new()),
            with: Mutex::new(cfg.with.clone()),
            secrets: Mutex::new(HashMap::new()),
            device_kind: cfg.device_kind.clone().filter(|k| matches!(k.as_str(), "phone" | "tablet" | "computer")),
            received: Mutex::new(HashMap::new()),
            summary_peers: Mutex::new(HashSet::new()),
            asked_summary: AtomicU64::new(0),
            asked_diff: AtomicU64::new(0),
            asked_full: AtomicU64::new(0),
            safety: Duration::from_secs(cfg.safety_secs.unwrap_or(900).max(1)),
            due: Mutex::new(HashSet::new()),
            wake_due: Notify::new(),
            due_why: Mutex::new(HashMap::new()),
            wake_why: Mutex::new(None),
            last_contact: Mutex::new(HashMap::new()),
            notice_dirty: Mutex::new(HashSet::new()),
            notice_wake: Notify::new(),
            notice_out: Mutex::new(HashMap::new()),
            notice_sent: AtomicU64::new(0),
            notice_got: AtomicU64::new(0),
            inline_ok: AtomicU64::new(0),
            inline_bad: AtomicU64::new(0),
            serving: Mutex::new(HashMap::new()),
            heard_from: Mutex::new(HashSet::new()),
            reach_pending: Mutex::new(HashMap::new()),
            waiting: Mutex::new(BTreeMap::new()),
            resume_check: Duration::from_millis(cfg.resume_check_ms.unwrap_or(5_000).max(50)),
            resume_hold: Duration::from_millis(cfg.resume_hold_ms.unwrap_or(30_000)),
            resume_since: Mutex::new(HashMap::new()),
            resume_cap: Duration::from_millis(cfg.resume_backoff_max_ms.unwrap_or(600_000)),
            resume_cancels: Mutex::new(HashMap::new()),
            resume_trial: Mutex::new(HashSet::new()),
            resume_gen: Mutex::new(HashMap::new()),
            #[cfg(feature = "test-hooks")]
            resume_fires: Mutex::new(Vec::new()),
            bulk: cfg.bulk.iter().cloned().collect(),
            medium_page: cfg.medium_page_bytes.unwrap_or(transport::MEDIUM_PAGE_BYTES).max(512),
            store_ready: AtomicBool::new(false),
            store_move: Mutex::new(None),
        });
        inner.save()?;
        steps.step("state saved");
        // From here the links are loaded and written: the Gate may answer "not linked" (when the grace allows it).
        gate.ready.store(true, Ordering::SeqCst);
        #[cfg(any(target_os = "linux", target_os = "android"))]
        if let Some(m) = &multi {
            // After the store has opened: the node serves from it. Without Reticulum the device carries on over iroh alone.
            let ifaces = match &cfg.rns_interfaces {
                Some(t) => {
                    let mut v = Vec::new();
                    v.extend(t.tcp_listen.iter().map(|a| cache_rns::Iface::TcpListen(a.clone())));
                    v.extend(t.tcp_connect.iter().map(|a| cache_rns::Iface::TcpConnect(a.clone())));
                    if t.wifi {
                        v.push(cache_rns::Iface::WifiAuto);
                    }
                    v
                }
                None => vec![cache_rns::Iface::WifiAuto],
            };
            let pair_local_tcp = cfg.rns_interfaces.as_ref().is_some_and(|t| t.pair_local_tcp);
            inner.push_former();
            #[cfg(feature = "test-hooks")]
            if let Some(ms) = std::fs::read_to_string(cfg.dir.join("reach-gap-ms")).ok().and_then(|v| v.trim().parse::<u64>().ok()) {
                m.set_reach_gap(Duration::from_millis(ms));
            }
            if let Some(ms) = cfg.speed_probe_ms {
                m.set_probe_every(Duration::from_millis(ms));
            }
            if let Err(e) = m.start_rns(secret.clone(), inner.store.raw(), inner.clone(), ifaces, pair_local_tcp).await {
                inner.note(format!("Reticulum did not start: {e:#}"));
            }
        }
        // An older (iroh-blobs) store is moved into the new one first, in the background; rounds and serving wait for it.
        let old_dir = cfg.dir.join("blobs");
        if Store::has_old_store(&old_dir) {
            say("store move: moving the file store to its new format");
            inner.note("Moving the file store to its new format");
            let (inner2, iroh2) = (inner.clone(), iroh_net.clone());
            tokio::spawn(async move {
                let (store, i3) = (inner2.store.raw().clone(), inner2.clone());
                let moved = tokio::task::spawn_blocking(move || {
                    store.move_old_store(&old_dir, &mut |done, total| {
                        *i3.store_move.lock().unwrap() = Some((done, total));
                    })
                })
                .await;
                match moved {
                    Ok(Ok(Some(report))) => {
                        // The summary, each file left out and each tag dropped: to the Activity and to cache.log.
                        for l in report.log_lines() {
                            say(&l);
                            inner2.note(l);
                        }
                    }
                    Ok(Ok(None)) => {}
                    Ok(Err(e)) => {
                        let l = format!("store move: stopped: {e} (it resumes at the next start)");
                        say(&l);
                        inner2.note(l);
                    }
                    Err(e) => {
                        let l = format!("store move: stopped: {e} (it resumes at the next start)");
                        say(&l);
                        inner2.note(l);
                    }
                }
                *inner2.store_move.lock().unwrap() = None;
                inner2.store_ready.store(true, Ordering::SeqCst);
                iroh2.serve(inner2.store.raw(), inner2.clone());
                inner2.wake.notify_one();
            });
        } else {
            inner.store_ready.store(true, Ordering::SeqCst);
            iroh_net.serve(inner.store.raw(), inner.clone());
        }
        inner.note("Started");
        if let Some(n) = saved_note {
            inner.note(n);
        }
        Ok(inner)
    }

    /// Entering a short code: a path request to its destination, a link, and the pairing request with the secret and this
    /// device's hello; the shower's hello comes back and is checked the same way.
    fn link_short(&self, dest: [u8; 16], secret: [u8; 5]) -> Result<Value> {
        let inner = &self.inner;
        let dest_hex = dest_hex_of(&dest);
        let Some((my_dest, my_sig)) = inner.rns_info() else { bail!(transport::NO_REACH) };
        if my_dest == dest_hex {
            bail!("that is this device's own code");
        }
        let name = inner.saved.lock().unwrap().name.clone();
        let net = inner.net.clone();
        let me = net.id();
        let to = dest_hex.clone();
        let inner2 = inner.clone();
        let reply: Result<Value> = self.rt.block_on(async move {
            let iroh = inner2.hello_iroh(net.link_addr().await.0);
            let body = ShortPair {
                secret: data_encoding::BASE32_NOPAD.encode(&secret),
                hello: ShortHello { key: me, iroh, name, rns: RnsProof { dest: my_dest, sig: my_sig } },
            };
            let bytes = net.pair_short(&to, serde_json::to_vec(&body)?).await?;
            Ok(serde_json::from_slice(&bytes)?)
        });
        let reply = reply?;
        if reply.get("ok").and_then(|v| v.as_bool()) != Some(true) {
            bail!("{}", reply.get("error").and_then(|v| v.as_str()).unwrap_or("the other device refused the link"));
        }
        let hello: ShortHello = serde_json::from_value(reply.get("hello").cloned().unwrap_or(Value::Null)).map_err(|_| anyhow!("the other device's answer could not be read"))?;
        // Its hello must be signed by the key it names, over the destination the code named.
        if hello.rns.dest.to_lowercase() != dest_hex || !inner.net.verify_rns(&hello.key, &hello.rns.dest, &hello.rns.sig) {
            bail!("the other device's answer did not check out");
        }
        if hello.key == inner.me {
            bail!("that is this device's own code");
        }
        if let Some(a) = hello.iroh.clone() {
            inner.net.learn_iroh(a);
        }
        add_peer(inner, &hello.key, &hello.name, false);
        inner.learn_rns(&hello.key, &hello.rns);
        inner.note(format!("Linked with {}", hello.name));
        inner.wake.notify_one();
        Ok(json!({"ok": true, "peer": hello.key, "name": hello.name}))
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
            "link_code" if inner.rns_info().is_some() => {
                // The short code: this device's Reticulum destination and a one-time secret. Where iroh finds this device, its
                // name and its signature travel inside the pairing, never in the code.
                let (dest, _) = inner.rns_info().ok_or_else(|| anyhow!("Reticulum is not running"))?;
                let dest = rns_dest_bytes(&dest).ok_or_else(|| anyhow!("bad Reticulum destination"))?;
                let secret: [u8; 5] = rand::Rng::random(&mut rand::rng());
                *inner.pairing.lock().unwrap() = None;
                *inner.short.lock().unwrap() = Some(ShortCode { secret, expires_ms: inner.code_now() + LINK_WINDOW.as_millis() as u64, strikes: 0 });
                Ok(json!({"code": encode_short(&dest, &secret), "valid_secs": LINK_WINDOW.as_secs()}))
            }
            #[cfg(feature = "test-hooks")]
            "test_round" => {
                // One whole round now, and back when it is over.
                let inner2 = inner.clone();
                let scope = Scope { peer: s("peer"), ..Scope::default() };
                self.rt.block_on(async move { inner2.round_with(&scope).await });
                Ok(json!({}))
            }
            #[cfg(feature = "test-hooks")]
            "test_view" => {
                // What `peer` gets as this device's whole file list (today's request), without counters on its entries.
                let peer = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                Ok(serde_json::to_value(inner.our_index_for(&peer))?)
            }
            #[cfg(feature = "test-hooks")]
            "test_mirror" => {
                let (peer, share) = (s("peer").ok_or_else(|| anyhow!("peer is required"))?, s("share").ok_or_else(|| anyhow!("share is required"))?);
                Ok(serde_json::to_value(inner.load_mirror(&peer, &share))?)
            }
            #[cfg(feature = "test-hooks")]
            "test_asked" => Ok(json!({
                "summary": inner.asked_summary.load(Ordering::Relaxed),
                "diff": inner.asked_diff.load(Ordering::Relaxed),
                "full": inner.asked_full.load(Ordering::Relaxed),
                "notice_sent": inner.notice_sent.load(Ordering::Relaxed),
                "notice_got": inner.notice_got.load(Ordering::Relaxed),
                "inline_ok": inner.inline_ok.load(Ordering::Relaxed),
                "inline_bad": inner.inline_bad.load(Ordering::Relaxed),
            })),
            #[cfg(feature = "test-hooks")]
            "test_resume" => {
                // The resume watcher: when it started rounds (ms since 1970), and the hold it now waits for `peer`.
                let peer = s("peer").unwrap_or_default();
                Ok(json!({"fires": inner.resume_fires.lock().unwrap().clone(), "hold_ms": inner.resume_hold_for(&peer).as_millis() as u64}))
            }
            #[cfg(feature = "test-hooks")]
            "test_relink" => {
                // The link to `peer` drops; the next request makes a new one.
                inner.net.test_relink(&s("peer").ok_or_else(|| anyhow!("peer is required"))?);
                Ok(json!({}))
            }
            #[cfg(feature = "test-hooks")]
            "test_attach_iface" => {
                inner.net.test_attach_iface();
                Ok(json!({}))
            }
            #[cfg(feature = "test-hooks")]
            "test_quiet" => {
                let peer = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                Ok(json!({"quiet": inner.quiet_peer(&peer)}))
            }
            #[cfg(feature = "test-hooks")]
            "test_ask" => {
                // `peer` asked for this device's list: whether that woke a round (the rate limit counts as it does for a real ask).
                let peer = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                Ok(json!({"wakes": inner.asked_wakes(&peer)}))
            }
            #[cfg(feature = "test-hooks")]
            "test_skew_code_clock" => {
                inner.code_skew_ms.store(args.get("ms").and_then(|v| v.as_u64()).unwrap_or(0), Ordering::Relaxed);
                Ok(json!({}))
            }
            #[cfg(feature = "test-hooks")]
            "test_pair_short_raw" => {
                // A short pairing request as written by the caller (to try what a real device would not send).
                let body = serde_json::to_vec(args.get("body").unwrap_or(&Value::Null))?;
                let inner2 = inner.clone();
                let reply = self.rt.block_on(async move { Serve::pair_short(inner2, body).await });
                Ok(serde_json::from_slice(&reply)?)
            }
            "link_code" => {
                *inner.short.lock().unwrap() = None;
                let tok = token();
                *inner.pairing.lock().unwrap() = Some((tok.clone(), Instant::now() + LINK_WINDOW));
                let net = inner.net.clone();
                let (addr, rns) = self.rt.block_on(async move { net.link_addr().await });
                let code = encode_code(&LinkCode { a: addr, t: tok, n: inner.saved.lock().unwrap().name.clone(), r: rns.filter(|_| inner.rns_info().is_some()).map(|d| RnsCode { d }) })?;
                Ok(json!({"code": code, "valid_secs": LINK_WINDOW.as_secs()}))
            }
            "link" => {
                let code = match decode_any(&s("code").ok_or_else(|| anyhow!("code is required"))?)? {
                    Code::Old(c) => c,
                    Code::Short { dest, secret } => return self.link_short(dest, secret),
                };
                if code.a.id.to_string() == inner.net.id() {
                    bail!("that is this device's own code");
                }
                let name = inner.saved.lock().unwrap().name.clone();
                let net = inner.net.clone();
                let inner2 = inner.clone();
                let peer = code.a.id;
                // Allowed before connecting: the reply comes back on our own connection, and from now on it may connect to us.
                inner.net.allow(&peer.to_string());
                let reply: Result<Value> = self.rt.block_on(async move {
                    let rns = inner2.rns_info().map(|(dest, sig)| RnsProof { dest, sig });
                    let hello = PairHello { token: code.t, name, key: Some(net.id()), rns };
                    let bytes = net.pair(PairTarget { iroh: code.a, rns: code.r.map(|r| r.d) }, serde_json::to_vec(&hello)?).await?;
                    Ok(serde_json::from_slice(&bytes)?)
                });
                let reply = match reply {
                    Ok(r) => r,
                    Err(e) => {
                        if !inner.saved.lock().unwrap().peers.iter().any(|p| p.id == peer.to_string()) {
                            inner.net.disallow(&peer.to_string());
                        }
                        return Err(e);
                    }
                };
                if reply.get("ok").and_then(|v| v.as_bool()) != Some(true) {
                    // Only if the device was not linked already: a refused second try must not lock out a device that is.
                    if !inner.saved.lock().unwrap().peers.iter().any(|p| p.id == peer.to_string()) {
                        inner.net.disallow(&peer.to_string());
                    }
                    bail!("{}", reply.get("error").and_then(|v| v.as_str()).unwrap_or("the other device refused the link"));
                }
                let pname = reply.get("name").and_then(|v| v.as_str()).unwrap_or(&code.n).to_string();
                add_peer(inner, &peer.to_string(), &pname, false);
                if let Some(r) = reply.get("rns").and_then(|v| serde_json::from_value::<RnsProof>(v.clone()).ok()) {
                    inner.learn_rns(&peer.to_string(), &r);
                }
                inner.note(format!("Linked with {pname}"));
                inner.wake.notify_one();
                Ok(json!({"ok": true, "peer": peer.to_string(), "name": pname}))
            }
            // Nearby linking (Android and Linux, with Reticulum on): the app drives it with these five calls and polls the
            // list and the state while its link-code page is open.
            "pairing_open" => {
                let (name, kind) = inner.nearby_self();
                let net = inner.net.clone();
                self.rt.block_on(async move { net.pairing_open(name, kind).await })?;
                Ok(json!({}))
            }
            #[cfg(feature = "test-hooks")]
            "test_skew_clock" => {
                inner.net.skew_clock(args.get("ms").and_then(|v| v.as_u64()).unwrap_or(0));
                Ok(json!({}))
            }
            "pairing_close" => {
                let net = inner.net.clone();
                self.rt.block_on(async move { net.pairing_close().await });
                Ok(json!({}))
            }
            "nearby_list" => Ok(inner.net.nearby_list()),
            "nearby_state" => Ok(inner.net.nearby_state()),
            "nearby_link" => {
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let (name, kind) = inner.nearby_self();
                let net = inner.net.clone();
                self.rt.block_on(async move { net.nearby_link(id, name, kind).await })?;
                Ok(json!({}))
            }
            "nearby_answer" => {
                let ok = args.get("ok").and_then(|v| v.as_bool()).ok_or_else(|| anyhow!("ok is required"))?;
                let net = inner.net.clone();
                self.rt.block_on(async move { net.nearby_answer(ok).await })?;
                Ok(json!({}))
            }
            "unlink" => {
                let id = s("peer").ok_or_else(|| anyhow!("peer is required"))?;
                inner.remove_device(&id)?;
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
                // Stops sharing; the files stay where they are. `keep_history` (bool, default false) keeps the share's index, its
                // seen file and its store tags, so adding the same id again later picks its history up: a kind switched off and
                // on again then tells an edit or a delete made meanwhile from a file it never had. Without it (a share retired
                // for good) all of that is deleted.
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let keep = args.get("keep_history").and_then(|v| v.as_bool()).unwrap_or(false);
                inner.saved.lock().unwrap().shares.retain(|x| x.id != id);
                inner.save()?;
                if keep {
                    return Ok(json!({"ok": true}));
                }
                let _ = std::fs::remove_file(inner.index_path(&id));
                let _ = std::fs::remove_file(inner.seen_path(&id));
                let store = inner.store.clone();
                let prefix = format!("f/{id}/");
                self.rt.block_on(async move {
                    if let Ok(names) = store.tag_names(prefix.as_bytes()).await {
                        for n in names {
                            let _ = store.delete_tag(&n).await;
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
                let scope = Scope { peer: s("peer"), shares: list("shares")?.or_else(|| s("share").map(|x| vec![x])), paths: list("paths")?, ..Scope::default() };
                if scope.whole() {
                    inner.wake_for("Sync now");
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
                let asks = if scope.peer.is_some() { 1 } else { inner.saved.lock().unwrap().peers.len() };
                inner.say_round(&["Sync now".to_string()], asks);
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
            "set_gate" => {
                // What a share offers from one folder, from now on: only the files in `allow` (see [`Config::send_gate`]); no `dir`
                // (or null) removes the gate. Receiving is never affected.
                let id = s("id").ok_or_else(|| anyhow!("id is required"))?;
                let dir = s("dir").unwrap_or_default();
                let allow: Vec<String> = match args.get("allow") {
                    None | Some(Value::Null) => Vec::new(),
                    Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
                    Some(_) => bail!("allow must be a list of paths or null"),
                };
                {
                    let mut g = inner.send_gate.lock().unwrap();
                    if dir.is_empty() {
                        g.remove(&id);
                    } else {
                        g.insert(id, SendGate { dir, allow });
                    }
                }
                inner.wake.notify_one();
                Ok(json!({"ok": true}))
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
                let net = inner.net.clone();
                self.rt.block_on(async move { net.network_change().await });
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
                    "fetching": inner.fetching_by(&p.id, st.index.as_ref(), st.last_seen),
                    // How the link to it is judged now (fast, medium or slow); iroh paths are fast.
                    "speed": inner.net.speed(&p.id).as_str(),
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
                        for a in inner.merge_from(&sh.id, &inner.remote_view(&sh.id, &rs.index), pid) {
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
        // What a link's class holds back (engine field only; the wording on the device row is part 4): files and whole lists.
        let waiting: Vec<Value> = inner
            .waiting
            .lock()
            .unwrap()
            .iter()
            .map(|((peer, share, path), size)| {
                let peer_name = saved.peers.iter().find(|p| p.id == *peer).map(|p| p.name.clone());
                let share_name = saved.shares.iter().find(|s| s.id == *share).map(|s| s.name.clone());
                json!({
                    "peer": peer, "peer_name": peer_name, "share_id": share, "share": share_name, "path": path,
                    "what": if path.is_empty() { "list" } else { "file" }, "size": size, "reason": WAITING_FOR_FASTER,
                })
            })
            .collect();
        let (relay, direct) = inner.net.addresses();
        json!({
            "id": inner.me,
            "name": saved.name,
            "relay": relay,
            "direct": direct,
            "network": inner.network.load(Ordering::Relaxed),
            "reserve_bytes": inner.reserve.load(Ordering::Relaxed),
            "free_bytes": Inner::free_bytes(&inner.dir),
            "showing_code": inner.pairing.lock().unwrap().as_ref().map(|(_, until)| until.saturating_duration_since(Instant::now()).as_secs()).or_else(|| {
                let now = inner.code_now();
                inner.short.lock().unwrap().as_ref().filter(|c| c.expires_ms > now).map(|c| (c.expires_ms - now) / 1000)
            }),
            "peers": peers,
            "shares": shares,
            "offers": offers,
            "transfer": run.transfer,
            "waiting": waiting,
            "paused": run.paused,
            "store_move": inner.store_move.lock().unwrap().map(|(done, total)| json!({"done": done, "total": total})),
            "rounds": run.rounds,
            "last_round": run.last_round,
            "log": run.log.iter().rev().take(50).map(|(t, m)| json!({"at": t, "text": m})).collect::<Vec<_>>(),
        })
    }

    /// The UDP port this device listens on (IPv4): the one `port` named, or the one the system gave when `port` was 0 or
    /// absent. A device found again only by its address (no lookup service) is opened again on it.
    pub fn port(&self) -> Option<u16> {
        self.inner.net.port()
    }

    /// Stops the rounds, closes connections and flushes the store.
    pub fn close(self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        self.inner.wake.notify_one();
        self.inner.notice_wake.notify_one();
        let net = self.inner.net.clone();
        let store = self.inner.store.clone();
        self.rt.block_on(async move {
            net.shutdown().await;
            let _ = store.shutdown().await;
        });
    }
}


#[cfg(test)]
mod resume_backoff_tests {
    use super::*;

    const S: fn(u64) -> Duration = Duration::from_secs;

    /// The test clock is the schedule itself: each retry's gap is the hold after the slow cancels so far (the real constants: a 30 s
    /// hold and a 5 s look, so the gaps are about 35 s, 65 s, 125 s ... up to 10 min and a look).
    #[test]
    fn the_hold_doubles_with_each_slow_cancel_and_stops_at_the_cap() {
        let holds: Vec<Duration> = (0..8).map(|n| backoff_hold(S(30), n, S(600))).collect();
        assert_eq!(holds, [S(30), S(60), S(120), S(240), S(480), S(600), S(600), S(600)]);
        // No overflow however many in a row, and a base over the cap is held to it.
        assert_eq!(backoff_hold(S(30), 1000, S(600)), S(600));
        assert_eq!(backoff_hold(S(30), u32::MAX, S(600)), S(600));
        assert_eq!(backoff_hold(S(900), 0, S(600)), S(600));
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
        Peer { id: "p".into(), name: "Android device".into(), linked: 1, link: None, last_seen: None, via: None, announced: Some("Android device".into()), unconfirmed: false, rns: None }
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

#[cfg(test)]
mod gate_close_tests {
    use super::*;
    use iroh::endpoint::{ApplicationClose, ConnectionError, ReadError, ReadToEndError, WriteError};

    fn gate_close(code: u32) -> ConnectionError {
        ConnectionError::ApplicationClosed(ApplicationClose { error_code: VarInt::from_u32(code), reason: (&b"not linked"[..]).into() })
    }

    /// What the earlier check looked at: the error's text, as `anyhow!("{e:#}")` makes it.
    fn old_text_check<E: std::error::Error>(e: &E) -> bool {
        format!("{e:#}").to_lowercase().contains("not linked")
    }

    #[test]
    fn a_403_met_while_writing_or_reading_is_found_by_its_code_not_its_text() {
        // Met at connect or open_bi: the text carries the reason, and the code is found too.
        let at_connect = gate_close(403);
        assert!(old_text_check(&at_connect));
        assert!(closed_403(&at_connect));
        // Met while writing the message: the text says only "connection lost"; the old check misses it, the code is found.
        let at_write = WriteError::ConnectionLost(gate_close(403));
        assert!(!old_text_check(&at_write), "{at_write:#}");
        assert!(closed_403(&at_write));
        // Met while reading the answer.
        let at_read = ReadToEndError::Read(ReadError::ConnectionLost(gate_close(403)));
        assert!(!old_text_check(&at_read), "{at_read:#}");
        assert!(closed_403(&at_read));
        // Any other close is not taken for the Gate's.
        assert!(!closed_403(&WriteError::ConnectionLost(gate_close(7))));
        assert!(!closed_403(&ReadToEndError::Read(ReadError::ConnectionLost(ConnectionError::TimedOut))));
        assert!(!closed_403(&WriteError::ClosedStream));
    }
}

#[cfg(test)]
mod gate_refusal_tests {
    use super::*;

    fn state(ready: bool, writing: usize, grace_until: u64) -> GateState {
        let s = GateState::default();
        s.ready.store(ready, Ordering::SeqCst);
        s.writing.store(writing, Ordering::SeqCst);
        s.grace_until.store(grace_until, Ordering::SeqCst);
        s
    }

    #[test]
    fn not_linked_is_said_only_from_loaded_links_not_being_rewritten_and_not_in_the_grace() {
        assert_eq!(state(true, 0, 0).refusal(1_000), Refusal::NotLinked);
        // Before the links are loaded, or while sync.json is rewritten: a retryable refusal, never 403.
        assert_eq!(state(false, 0, 0).refusal(1_000), Refusal::Busy);
        assert_eq!(state(true, 1, 0).refusal(1_000), Refusal::Busy);
        // In the grace after a recovery or a fresh start: 409, never 403; and 403 again once it has passed.
        assert_eq!(state(true, 0, 5_000).refusal(1_000), Refusal::LinksReset);
        assert_eq!(state(true, 0, 5_000).refusal(5_000), Refusal::NotLinked);
        assert_eq!(state(false, 0, 5_000).refusal(1_000), Refusal::Busy);
        assert_eq!(Refusal::NotLinked.code(), 403);
        assert_ne!(Refusal::LinksReset.code(), 403);
        assert_ne!(Refusal::Busy.code(), 403);
    }

    #[test]
    fn the_grace_is_written_before_it_is_used_and_a_healthy_start_only_reads_it() {
        let d = tempfile::tempdir().unwrap();
        // A healthy start with no marker: no grace.
        assert_eq!(links_grace_until(d.path(), false).unwrap(), 0);
        // A recovery: the marker is written, and the grace runs from now.
        let until = links_grace_until(d.path(), true).unwrap();
        assert!(until >= now_ms() + CONFIRM_WINDOW.as_millis() as u64 - 5_000);
        assert!(d.path().join("links-recovered-at").exists());
        // A later healthy start reads it back: the same grace.
        assert_eq!(links_grace_until(d.path(), false).unwrap() / 1000, until / 1000);
    }
}

#[cfg(test)]
mod link_code_tests {
    use super::*;

    fn kind(s: &str) -> Option<&'static str> {
        decode_code(s).err().as_ref().and_then(error_kind)
    }

    #[test]
    fn a_code_from_a_newer_cache_is_told_apart() {
        for s in ["CACHE2-ABCDEF", "cache3-abcdef", "  CACHE12-\nAB CD ", "CACHE2-", "CACHE99999999999999999999999-X"] {
            assert_eq!(kind(s), Some("link_code_newer"), "{s}");
        }
        assert_eq!(decode_code("CACHE2-ABC").unwrap_err().to_string(), "this link code is from a newer version of Cache");
    }

    #[test]
    fn the_other_cases_keep_their_kinds() {
        assert_eq!(kind("CACHE1-"), Some("link_code_damaged"));
        assert_eq!(kind("CACHE1-!!!!"), Some("link_code_damaged"));
        assert_eq!(kind("cache1-TESTCODE"), Some("link_code_damaged"));
        for s in ["HELLO", "", "CACHE-ABC", "CACHE0-ABC", "CACHEX-ABC", "CACHE2ABC"] {
            assert_eq!(kind(s), Some("link_code_not_a_code"), "{s}");
        }
        assert_eq!(decode_code("HELLO").unwrap_err().to_string(), "this is not a Cache link code");
    }

    #[test]
    fn a_real_code_still_decodes() {
        let c = LinkCode { a: EndpointAddr::new(iroh::SecretKey::from_bytes(&[7; 32]).public()), t: "TOK".into(), n: "Desk".into(), r: None };
        let code = encode_code(&c).unwrap();
        assert!(code.starts_with("CACHE1-"));
        let back = decode_code(&format!("  {} ", code.to_lowercase())).unwrap();
        assert_eq!((back.t, back.n, back.a.id), ("TOK".to_string(), "Desk".to_string(), c.a.id));
    }
}

#[cfg(test)]
mod short_code_tests {
    use super::*;

    #[test]
    fn a_short_code_reads_back_with_any_spelling() {
        let (dest, secret) = ([0xA5u8; 16], [1u8, 2, 3, 4, 5]);
        let code = encode_short(&dest, &secret);
        assert!(code.starts_with("CACHE-"));
        assert_eq!(code.matches('-').count(), 9);
        assert_eq!(code.replace('-', "").len(), "CACHE".len() + SHORT_LEN);
        for s in [code.clone(), code.to_lowercase(), format!("  {} ", code.replace('-', " ")), code.replace("CACHE-", "CACHE"), code.replace('-', "")] {
            match decode_any(&s).unwrap() {
                Code::Short { dest: d, secret: k } => assert_eq!((d, k), (dest, secret), "{s}"),
                c => panic!("{s}: {c:?}"),
            }
        }
    }

    #[test]
    fn a_short_code_of_the_wrong_length_or_alphabet_is_not_a_code() {
        let code = encode_short(&[9; 16], &[7; 5]);
        for s in [code[..code.len() - 1].to_string(), format!("{code}A"), format!("CACHE-1{}", &code[7..]), "CACHE-".to_string(), "CACHE-!!!!".to_string()] {
            assert_eq!(decode_any(&s).err().as_ref().and_then(error_kind), Some("link_code_not_a_code"), "{s}");
        }
    }

    #[test]
    fn old_and_newer_codes_are_still_told_apart() {
        let c = LinkCode { a: EndpointAddr::new(iroh::SecretKey::from_bytes(&[7; 32]).public()), t: "TOK".into(), n: "Desk".into(), r: None };
        assert!(matches!(decode_any(&encode_code(&c).unwrap()).unwrap(), Code::Old(_)));
        assert_eq!(decode_any("CACHE2-ABC").err().as_ref().and_then(error_kind), Some("link_code_newer"));
        assert_eq!(decode_any("CACHE1-!!!").err().as_ref().and_then(error_kind), Some("link_code_damaged"));
        assert_eq!(decode_any("HELLO").err().as_ref().and_then(error_kind), Some("link_code_not_a_code"));
    }

    #[test]
    fn the_secret_compare() {
        assert!(ct_eq(&[1, 2, 3, 4, 5], &[1, 2, 3, 4, 5]));
        assert!(!ct_eq(&[1, 2, 3, 4, 5], &[1, 2, 3, 4, 6]));
        assert!(!ct_eq(&[1, 2, 3, 4, 5], &[1, 2, 3, 4]));
    }
}

#[cfg(test)]
mod former_tests {
    use super::*;

    #[test]
    fn a_closed_link_line_names_the_device_the_reason_and_what_is_known() {
        assert_eq!(
            link_closed_line("Pixel", "timeout (nothing heard on it for too long)", Some(44), Some(90)),
            "reticulum link to Pixel closed: timeout (nothing heard on it for too long) after 44 s (rtt 90 ms)"
        );
        assert_eq!(link_closed_line("Pixel", "closed by the other device", None, None), "reticulum link to Pixel closed: closed by the other device");
    }

    #[test]
    fn a_saved_file_without_former_devices_loads_and_does_not_write_the_field() {
        let old = r#"{"name":"Desk","peers":[],"shares":[]}"#;
        let s: Saved = serde_json::from_str(old).unwrap();
        assert!(s.former.is_empty());
        assert!(!serde_json::to_string(&s).unwrap().contains("former"));
        let with: Saved = serde_json::from_str(r#"{"name":"Desk","former":[{"id":"x","t":5}]}"#).unwrap();
        assert_eq!(with.former.len(), 1);
    }
}
