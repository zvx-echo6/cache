//! The iroh bridge against iroh-blobs 0.103.1 itself: a file given to the view by reference is left in place, the store never
//! deletes or moves a file the view reads, and a download is moved into the store without a copy.

use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

use cache_store::{ExportMode, Hash, ImportMode, Options, Status, Store};
use cache_sync::bridge::Bridge;
use tempfile::TempDir;

fn bytes(seed: u8, n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    blake3::Hasher::new().update(&[seed]).finalize_xof().fill(&mut v);
    v
}

struct Rig {
    dir: TempDir,
    store: Store,
    bridge: Arc<Bridge>,
    wanted: Arc<Mutex<HashSet<Hash>>>,
    lent: Arc<Mutex<HashSet<Hash>>>,
}

fn rig() -> Rig {
    let dir = TempDir::new().unwrap();
    let wanted: Arc<Mutex<HashSet<Hash>>> = Arc::default();
    let lent: Arc<Mutex<HashSet<Hash>>> = Arc::default();
    let (w, l) = (wanted.clone(), lent.clone());
    let store = Store::open(
        &dir.path().join("store"),
        Options { protect: Some(Arc::new(move || w.lock().unwrap().clone())), lent: Some(Arc::new(move || l.lock().unwrap().clone())), ..Options::default() },
    )
    .unwrap();
    let bridge = Bridge::new(dir.path().join("blobs-iroh-view"), wanted.clone(), lent.clone());
    bridge.set_store(store.clone());
    Rig { dir, store, bridge, wanted, lent }
}

#[derive(Debug, PartialEq, Eq)]
struct Fingerprint {
    #[cfg(unix)]
    inode: u64,
    len: u64,
    mtime: SystemTime,
    bytes: Vec<u8>,
}

fn print(p: &Path) -> Fingerprint {
    let m = fs::metadata(p).unwrap();
    Fingerprint {
        #[cfg(unix)]
        inode: std::os::unix::fs::MetadataExt::ino(&m),
        len: m.len(),
        mtime: m.modified().unwrap(),
        bytes: fs::read(p).unwrap(),
    }
}

/// Every file under `dir` at least this big (a copy of the data would be one).
fn big_files(dir: &Path, at_least: u64) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(big_files(&p, at_least));
        } else if fs::metadata(&p).map(|m| m.len() >= at_least).unwrap_or(false) {
            out.push(p);
        }
    }
    out
}

#[tokio::test(flavor = "multi_thread")]
async fn a_file_given_to_the_view_by_reference_is_left_alone() {
    let r = rig();
    let data = bytes(1, 700_000);
    let h = r.store.add_bytes(&data).unwrap().hash;
    let (own, owned) = r.store.file_path(&h).unwrap();
    assert!(owned);
    let before = print(&own);

    r.bridge.ensure(h).await.unwrap();
    let view = r.bridge.view().await.unwrap().clone();
    assert!(r.lent.lock().unwrap().contains(&h), "lent before the view can read it");

    // iroh-blobs 0.103.1 reads it from where it is: complete in the view, the same bytes, and no copy of it anywhere in the view.
    let ih = iroh_blobs::Hash::from_bytes(*h.as_bytes());
    assert!(matches!(view.blobs().status(ih).await.unwrap(), iroh_blobs::api::blobs::BlobStatus::Complete { size: 700_000 }));
    assert_eq!(view.blobs().get_bytes(ih).await.unwrap().to_vec(), data);
    // (The view's database is a file of its own, about a megabyte; what must not be there is a data file.)
    let copies: Vec<_> = big_files(&r.dir.path().join("blobs-iroh-view"), 1).into_iter().filter(|p| p.extension().is_some_and(|e| e == "data")).collect();
    assert!(copies.is_empty(), "no second copy of the data: {copies:?}");
    // No rename, no truncation, no takeover: same file, same inode, same size, same time, same bytes.
    assert_eq!(print(&own), before);

    // Store GC runs while the view references the file: nothing is deleted, and the view still reads it.
    assert_eq!(r.store.gc().unwrap().entries, 0);
    assert_eq!(print(&own), before);
    assert_eq!(view.blobs().get_bytes(ih).await.unwrap().to_vec(), data);
    // A move out of the store is refused while the view reads the file: the content is copied, the file stays.
    let target = r.dir.path().join("shared/out.bin");
    assert_eq!(r.store.export(&h, &target, ExportMode::Move).unwrap().how, cache_store::ExportHow::Copied);
    assert_eq!(print(&own), before);

    // The view lets go (it waits until iroh-blobs' collection has dropped the entry), and only then is the file unlent.
    assert_eq!(r.bridge.prune(Duration::ZERO).await, 1);
    assert!(!r.lent.lock().unwrap().contains(&h));
    assert!(matches!(view.blobs().status(ih).await.unwrap(), iroh_blobs::api::blobs::BlobStatus::NotFound));
    // iroh-blobs' own GC dropped its entry and did not touch the file it referenced.
    assert_eq!(print(&own), before, "the entry's removal leaves the referenced file");
    // Now the store may collect it.
    assert_eq!(r.store.gc().unwrap().entries, 1);
    assert!(!own.exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn inline_files_are_copied_and_the_persons_files_are_read_in_place() {
    let r = rig();
    let small = r.store.add_bytes(b"small file").unwrap().hash;
    r.bridge.ensure(small).await.unwrap();
    let view = r.bridge.view().await.unwrap().clone();
    let ih = iroh_blobs::Hash::from_bytes(*small.as_bytes());
    assert_eq!(view.blobs().get_bytes(ih).await.unwrap().to_vec(), b"small file");
    assert!(!r.lent.lock().unwrap().contains(&small), "inline data is copied, nothing of the store's is lent");

    let mine = r.dir.path().join("mine.bin");
    let data = bytes(2, 400_000);
    fs::write(&mine, &data).unwrap();
    let m = r.store.add_path(&mine, ImportMode::Reference).unwrap().hash;
    let before = print(&mine);
    r.bridge.ensure(m).await.unwrap();
    assert!(!r.lent.lock().unwrap().contains(&m), "the person's file is not the store's to lend");
    let im = iroh_blobs::Hash::from_bytes(*m.as_bytes());
    assert_eq!(view.blobs().get_bytes(im).await.unwrap().to_vec(), data);
    r.bridge.prune(Duration::ZERO).await;
    assert_eq!(print(&mine), before, "the person's file is untouched by the view");

    // A hash the store does not hold is an error (the provider then answers "not found" itself).
    assert!(r.bridge.ensure(Hash::new(b"nothing")).await.is_err());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_download_is_moved_into_the_store_without_a_copy() {
    let r = rig();
    let view = r.bridge.view().await.unwrap().clone();
    let data = bytes(3, 900_000);
    // What a finished download looks like: a complete entry in the view, kept while it is wanted.
    let tt = view.add_bytes(data.clone()).temp_tag().await.unwrap();
    let ih = tt.hash();
    let h = Hash::from_bytes(*ih.as_bytes());
    r.wanted.lock().unwrap().insert(h);
    let view_file = r.dir.path().join("blobs-iroh-view/data").join(format!("{}.data", h.to_hex()));
    let ino = print(&view_file);
    assert_eq!(r.store.status(&h).unwrap(), Status::Absent);

    r.bridge.land(h).await.unwrap();
    assert_eq!(r.store.status(&h).unwrap(), Status::Complete { size: 900_000 });
    assert_eq!(r.store.get_bytes(&h).unwrap(), data);
    let (own, owned) = r.store.file_path(&h).unwrap();
    assert!(owned);
    #[cfg(unix)]
    assert_eq!(print(&own).inode, ino.inode, "the file the view downloaded is the file the store keeps: moved, not copied");
    assert!(!view_file.exists());
    // The view's entry for it goes (it is no longer wanted-and-landed).
    drop(tt);
    r.wanted.lock().unwrap().remove(&h);
    let mut gone = false;
    for _ in 0..80 {
        if matches!(view.blobs().status(ih).await.unwrap(), iroh_blobs::api::blobs::BlobStatus::NotFound) {
            gone = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(gone, "the view dropped its entry");
    assert_eq!(r.store.get_bytes(&h).unwrap(), data);
    // A request for it now builds a fresh entry from the store's file.
    r.bridge.ensure(h).await.unwrap();
    assert_eq!(view.blobs().get_bytes(ih).await.unwrap().to_vec(), data);
}

#[tokio::test(flavor = "multi_thread")]
async fn nothing_is_built_until_it_is_needed() {
    let r = rig();
    assert!(!r.bridge.is_open());
    assert!(!r.dir.path().join("blobs-iroh-view").exists());
    r.bridge.view().await.unwrap();
    assert!(r.bridge.is_open());
    assert!(r.dir.path().join("blobs-iroh-view").exists());
}
