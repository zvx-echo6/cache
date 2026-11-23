//! The iroh bridge (step 6a until step 6b removes iroh, and this with it, along with its folder `blobs-iroh-view/`).
//!
//! iroh-blobs serves and fetches through its own store. Cache's files now live in [`cache_store`], so the iroh transport works
//! through a small iroh-blobs store used only as a view:
//!
//! - **Serving.** When a linked device asks for a hash, the provider event holds the request while the file is added to the view
//!   by reference, in place (`TryReference`): iroh-blobs hashes it once for its own outboard and reads the bytes from where they
//!   are. For a file the store owns, that is the store's own data file, so there is no second copy; the hash is first put in the
//!   store's lent set ([`cache_store::Options::lent`]) and stays there until the view entry is gone, so the store never deletes,
//!   moves or rewrites a file the view reads. A file the person keeps in a shared folder is referenced where it is. Inline data
//!   is copied into the view. Entries nobody has asked for lately are dropped. Nothing is added until a device asks, so a device
//!   with no iroh peers never builds the view, and one with peers only holds what they ask for.
//! - **Fetching.** Downloads land in the view, then are exported out of it by rename and moved into the store (checked against the
//!   hash), and the view's entry is dropped.

use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Result};
use cache_store::{Hash, Store};
use iroh::protocol::{AcceptError, ProtocolHandler};
use iroh::endpoint::Connection;
use iroh_blobs::{
    api::{
        blobs::{AddPathOptions, BlobStatus, ExportMode, ExportOptions, ImportMode},
    },
    provider::events::{EventMask, EventSender, ProviderMessage, RequestMode},
    store::{
        fs::{options::Options as StoreOptions, FsStore},
        GcConfig, ProtectOutcome,
    },
    BlobFormat, BlobsProtocol,
};
use tokio::sync::OnceCell;

/// How often the view's own garbage collection runs. A dropped entry is gone within about this long.
const VIEW_GC: Duration = Duration::from_secs(5);
/// A view entry nobody has asked for in this long is dropped.
const IDLE: Duration = Duration::from_secs(600);
/// How long a request waits for a stale entry of the same hash to leave the view.
const STALE_WAIT: Duration = Duration::from_secs(20);

pub(crate) fn theirs(h: &Hash) -> iroh_blobs::Hash {
    iroh_blobs::Hash::from_bytes(*h.as_bytes())
}

pub(crate) fn ours(h: iroh_blobs::Hash) -> Hash {
    Hash::from_bytes(*h.as_bytes())
}

pub struct Bridge {
    dir: PathBuf,
    store: OnceLock<Store>,
    view: OnceCell<FsStore>,
    protocol: OnceCell<BlobsProtocol>,
    /// Hashes whose files in the store the view reads (shared with the store's `lent` option).
    lent: Arc<Mutex<HashSet<Hash>>>,
    /// Hashes being fetched: the view's collection keeps their partial data.
    wanted: Arc<Mutex<HashSet<Hash>>>,
    /// Entries added for a request, and when each was last asked for.
    served: Mutex<HashMap<Hash, Instant>>,
    /// Downloads moved out into the store whose view entry is not gone yet (it points at a file that is not there).
    landed: Arc<Mutex<HashSet<Hash>>>,
    /// One add (or drop) at a time for each hash; different hashes run in parallel. The map is locked only to find or make a
    /// hash's lock, never across work.
    locks: Mutex<HashMap<Hash, Arc<tokio::sync::Mutex<()>>>>,
    closed: std::sync::atomic::AtomicBool,
    /// Test hooks: a pause before each add of a store-owned file (milliseconds), and how many adds were made.
    #[cfg(feature = "test-hooks")]
    pub add_delay_ms: std::sync::atomic::AtomicU64,
    #[cfg(feature = "test-hooks")]
    pub adds: std::sync::atomic::AtomicUsize,
}

impl Bridge {
    /// `dir` is the view's folder (`blobs-iroh-view`); nothing is created until it is needed.
    pub fn new(dir: PathBuf, wanted: Arc<Mutex<HashSet<Hash>>>, lent: Arc<Mutex<HashSet<Hash>>>) -> Arc<Bridge> {
        Arc::new(Bridge {
            dir,
            store: OnceLock::new(),
            view: OnceCell::new(),
            protocol: OnceCell::new(),
            lent,
            wanted,
            served: Mutex::new(HashMap::new()),
            landed: Arc::default(),
            locks: Mutex::new(HashMap::new()),
            closed: std::sync::atomic::AtomicBool::new(false),
            #[cfg(feature = "test-hooks")]
            add_delay_ms: std::sync::atomic::AtomicU64::new(0),
            #[cfg(feature = "test-hooks")]
            adds: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    /// The store the view serves from and downloads into.
    pub fn set_store(&self, store: Store) {
        let _ = self.store.set(store);
    }

    fn store(&self) -> Result<&Store> {
        self.store.get().ok_or_else(|| anyhow!("the file store is not open"))
    }

    /// The lock for `hash`'s changes to the view.
    fn lock_of(&self, hash: &Hash) -> Arc<tokio::sync::Mutex<()>> {
        self.locks.lock().unwrap().entry(*hash).or_default().clone()
    }

    /// Forgets `hash`'s lock when nobody else holds or waits on it.
    fn release(&self, hash: &Hash, mine: Arc<tokio::sync::Mutex<()>>) {
        let mut m = self.locks.lock().unwrap();
        // The map's copy and ours: no one else has it.
        if Arc::strong_count(&mine) == 2 {
            m.remove(hash);
        }
    }

    /// Whether the view has been built.
    pub fn is_open(&self) -> bool {
        self.view.get().is_some()
    }

    /// The view, built on first use. What an earlier run left in it is dropped first (its references point at files this run's
    /// store has not lent), except partial downloads, which resume.
    pub async fn view(self: &Arc<Self>) -> Result<&FsStore> {
        self.view
            .get_or_try_init(|| async {
                std::fs::create_dir_all(&self.dir)?;
                let (wanted, landed) = (self.wanted.clone(), self.landed.clone());
                let gc = GcConfig {
                    interval: VIEW_GC,
                    add_protected: Some(Arc::new(move |live: &mut HashSet<iroh_blobs::Hash>| {
                        // What is being fetched keeps its partial data, unless it has been moved out into the store already.
                        let landed = landed.lock().unwrap().clone();
                        live.extend(wanted.lock().unwrap().iter().filter(|h| !landed.contains(h)).map(theirs));
                        Box::pin(async { ProtectOutcome::Continue })
                    })),
                };
                let mut opts = StoreOptions::new(&self.dir);
                opts.gc = Some(gc);
                let view = FsStore::load_with_opts(self.dir.join("blobs.db"), opts).await.map_err(|e| anyhow!("could not open the iroh view: {e}"))?;
                // Old references: every named tag of an earlier run goes, and the collection takes what nothing holds.
                let _ = view.tags().delete_prefix(b"view/").await;
                let me = self.clone();
                tokio::spawn(async move { me.prune_loop().await });
                Ok::<_, anyhow::Error>(view)
            })
            .await
    }

    /// The blob protocol over the view, which holds each request until the file it names is in the view.
    pub async fn protocol(self: &Arc<Self>) -> Result<BlobsProtocol> {
        let me = self.clone();
        self.protocol
            .get_or_try_init(|| async move {
                let view = me.view().await?.clone();
                let mask = EventMask { get: RequestMode::Intercept, get_many: RequestMode::Intercept, ..EventMask::DEFAULT };
                let (events, mut rx) = EventSender::channel(32, mask);
                let bridge = me.clone();
                tokio::spawn(async move {
                    while let Some(msg) = rx.recv().await {
                        let bridge = bridge.clone();
                        match msg {
                            ProviderMessage::GetRequestReceived(m) => {
                                tokio::spawn(async move {
                                    let _ = bridge.ensure(ours(m.inner.request.hash)).await;
                                    let _ = m.tx.send(Ok(())).await;
                                });
                            }
                            ProviderMessage::GetManyRequestReceived(m) => {
                                tokio::spawn(async move {
                                    for h in m.inner.request.hashes.iter() {
                                        let _ = bridge.ensure(ours(*h)).await;
                                    }
                                    let _ = m.tx.send(Ok(())).await;
                                });
                            }
                            _ => {}
                        }
                    }
                });
                Ok::<_, anyhow::Error>(BlobsProtocol::new(&view, Some(events)))
            })
            .await
            .cloned()
    }

    /// Makes sure the view holds `hash`, to be served: by reference in place where the file is the store's or the person's, by
    /// copy where it is inline. Errors when the store does not hold it (the provider then answers "not found" itself).
    pub async fn ensure(self: &Arc<Self>, hash: Hash) -> Result<()> {
        let view = self.view().await?.clone();
        // One add at a time for this hash: a second request waits for the first and then finds the entry made. Other hashes
        // are not held up by it.
        let lock = self.lock_of(&hash);
        let result = {
            let _one = lock.lock().await;
            self.ensure_locked(&view, hash).await
        };
        self.release(&hash, lock);
        result
    }

    async fn ensure_locked(self: &Arc<Self>, view: &FsStore, hash: Hash) -> Result<()> {
        if let Some(t) = self.served.lock().unwrap().get_mut(&hash) {
            *t = Instant::now();
            return Ok(());
        }
        // A download that was moved out is still in the view until the collection takes it; the file it names is not there.
        if self.landed.lock().unwrap().contains(&hash) {
            let until = Instant::now() + STALE_WAIT;
            while self.in_view(view, &hash).await {
                if Instant::now() > until {
                    bail!("an old copy of {} is still leaving the view", hash.fmt_short());
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            self.landed.lock().unwrap().remove(&hash);
        }
        let store = self.store()?.clone();
        let name = format!("view/{}", hash.to_hex());
        let found = tokio::task::spawn_blocking({
            let (store, hash) = (store.clone(), hash);
            move || (store.file_path(&hash), store.has(&hash).unwrap_or(false))
        })
        .await?;
        match found {
            (Some((path, owned)), _) => {
                if owned {
                    // Lent before the view can read it, and until the entry is gone.
                    self.lent.lock().unwrap().insert(hash);
                    #[cfg(feature = "test-hooks")]
                    {
                        let ms = self.add_delay_ms.load(std::sync::atomic::Ordering::Relaxed);
                        if ms > 0 {
                            tokio::time::sleep(Duration::from_millis(ms)).await;
                        }
                    }
                }
                #[cfg(feature = "test-hooks")]
                self.adds.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let added = view
                    .add_path_with_opts(AddPathOptions { path, format: BlobFormat::Raw, mode: ImportMode::TryReference })
                    .with_named_tag(name.as_bytes())
                    .await
                    .map_err(|e| anyhow!("{e}"));
                match added {
                    Ok(t) if ours(t.hash) == hash => {}
                    Ok(_) => {
                        // The file is not what the store has recorded (a person's file edited since): not served.
                        self.drop_entry(view, &hash, &name).await;
                        bail!("the file for {} changed", hash.fmt_short());
                    }
                    Err(e) => {
                        self.drop_entry(view, &hash, &name).await;
                        return Err(e);
                    }
                }
            }
            (None, true) => {
                let data = tokio::task::spawn_blocking(move || store.get_bytes(&hash)).await??;
                view.add_bytes(data).with_named_tag(name.as_bytes()).await.map_err(|e| anyhow!("{e}"))?;
            }
            (None, false) => bail!("{} is not in the store", hash.fmt_short()),
        }
        self.served.lock().unwrap().insert(hash, Instant::now());
        Ok(())
    }

    async fn in_view(&self, view: &FsStore, hash: &Hash) -> bool {
        !matches!(view.blobs().status(theirs(hash)).await, Ok(BlobStatus::NotFound))
    }

    /// Takes the named tag off `hash` and waits for the collection to drop the entry; only then is the file no longer lent.
    async fn drop_entry(&self, view: &FsStore, hash: &Hash, name: &str) -> bool {
        let _ = view.tags().delete(name.as_bytes()).await;
        self.served.lock().unwrap().remove(hash);
        let until = Instant::now() + VIEW_GC * 4;
        while self.in_view(view, hash).await {
            if Instant::now() > until {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        self.lent.lock().unwrap().remove(hash);
        true
    }

    /// Closes the view's database, so an engine opened again on the same folder (in this process) can open it.
    pub async fn shutdown(&self) {
        self.closed.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(v) = self.view.get() {
            let _ = v.shutdown().await;
        }
    }

    /// Drops every entry nobody asked for in [`IDLE`] (and so unlends the files).
    pub async fn prune(self: &Arc<Self>, idle: Duration) -> usize {
        let Some(view) = self.view.get().cloned() else { return 0 };
        let old: Vec<Hash> = self.served.lock().unwrap().iter().filter(|(_, t)| t.elapsed() >= idle).map(|(h, _)| *h).collect();
        let mut n = 0;
        for h in old {
            let lock = self.lock_of(&h);
            {
                let _one = lock.lock().await;
                // Asked for again while this waited: it stays.
                let idle_still = self.served.lock().unwrap().get(&h).is_some_and(|t| t.elapsed() >= idle);
                if idle_still && self.drop_entry(&view, &h, &format!("view/{}", h.to_hex())).await {
                    n += 1;
                }
            }
            self.release(&h, lock);
        }
        let gone: Vec<Hash> = self.landed.lock().unwrap().iter().copied().collect();
        for h in gone {
            if !self.in_view(&view, &h).await {
                self.landed.lock().unwrap().remove(&h);
            }
        }
        n
    }

    async fn prune_loop(self: Arc<Self>) {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            if self.closed.load(std::sync::atomic::Ordering::Relaxed) {
                break;
            }
            self.prune(IDLE).await;
        }
    }

    /// A download that finished in the view: moved out of it into the store (checked against `hash`). The view entry is left to
    /// the collection, which drops it within [`VIEW_GC`].
    pub async fn land(self: &Arc<Self>, hash: Hash) -> Result<()> {
        let view = self.view().await?.clone();
        let store = self.store()?.clone();
        match view.blobs().status(theirs(&hash)).await.map_err(|e| anyhow!("{e}"))? {
            BlobStatus::Complete { .. } => {}
            _ => bail!("the transfer stopped"),
        }
        let staging = store.staging_path();
        // The view's data file is renamed out to `staging` (copied if that cannot be), and the entry then refers to it there.
        view.export_with_opts(ExportOptions { hash: theirs(&hash), mode: ExportMode::TryReference, target: staging.clone() })
            .finish()
            .await
            .map_err(|e| anyhow!("{e}"))?;
        self.landed.lock().unwrap().insert(hash);
        let moved = tokio::task::spawn_blocking(move || store.add_path_move(&staging, Some(&hash))).await?;
        moved?;
        Ok(())
    }
}

/// The blob protocol's handler: builds the view when the first linked device asks for a file.
#[derive(Clone)]
pub struct BlobsGate(pub Arc<Bridge>);

impl std::fmt::Debug for BlobsGate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("BlobsGate")
    }
}

impl ProtocolHandler for BlobsGate {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let proto = self.0.protocol().await.map_err(|e| AcceptError::from_err(std::io::Error::other(e.to_string())))?;
        proto.accept(conn).await
    }
}
