//! The one-time move of an iroh-blobs 0.103.1 store, from the stores checked in under tests/data/ (made once by
//! tests/gen_fixtures.rs). Nothing here needs iroh-blobs, so these tests survive its removal.

use std::{
    fs,
    path::{Path, PathBuf},
};

use cache_store::{old_store::OldDb, ChunkNum, ChunkRanges, Fault, Hash, Options, Status, Store};
use serde::Deserialize;
use tempfile::TempDir;

#[derive(Deserialize, Clone)]
struct Item {
    name: String,
    seed: u8,
    size: usize,
    kind: String,
    hash: String,
    tag: Option<String>,
}

fn bytes(seed: u8, n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    blake3::Hasher::new().update(&[seed]).finalize_xof().fill(&mut v);
    v
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data").join(name)
}

fn manifest(name: &str) -> Vec<Item> {
    serde_json::from_slice(&fs::read(fixture(name).join("manifest.json")).unwrap()).unwrap()
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let t = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_dir(&e.path(), &t);
        } else {
            fs::copy(e.path(), t).unwrap();
        }
    }
}

/// A working copy of a fixture: `<tmp>/blobs` is the old store, `<tmp>/shared` holds the in-place files (the clean fixture's
/// paths are pointed there), `<tmp>/store` is where the new store goes.
struct Setup {
    dir: TempDir,
    items: Vec<Item>,
}

impl Setup {
    fn new(name: &str) -> Setup {
        let dir = TempDir::new().unwrap();
        copy_dir(&fixture(name).join("blobs"), &dir.path().join("blobs"));
        if fixture(name).join("shared").exists() {
            copy_dir(&fixture(name).join("shared"), &dir.path().join("shared"));
            cache_store::old_store::rewrite_external_prefix(&dir.path().join("blobs/blobs.db"), Path::new("/__shared__"), &dir.path().join("shared")).unwrap();
        }
        Setup { dir, items: manifest(name) }
    }
    fn old(&self) -> PathBuf {
        self.dir.path().join("blobs")
    }
    fn store(&self) -> Store {
        Store::open(&self.dir.path().join("store"), Options::default()).unwrap()
    }
    fn run(&self, store: &Store) -> (Option<cache_store::MoveReport>, Vec<(u64, u64)>) {
        let mut calls = Vec::new();
        let r = store.move_old_store(&self.old(), &mut |d, t| calls.push((d, t))).unwrap();
        (r, calls)
    }
}

fn data_files(dir: &Path) -> Vec<String> {
    let mut v = Vec::new();
    for shard in fs::read_dir(dir.join("store/data")).unwrap() {
        for f in fs::read_dir(shard.unwrap().path()).unwrap() {
            v.push(f.unwrap().file_name().to_string_lossy().into_owned());
        }
    }
    v.sort();
    v
}

/// Everything observable about a store, to compare two runs.
fn signature(s: &Setup, store: &Store) -> Vec<String> {
    let mut sig = Vec::new();
    for it in &s.items {
        let h: Hash = it.hash.parse().unwrap();
        let st = store.status(&h).unwrap();
        let content = match st {
            Status::Complete { .. } => Hash::new(store.get_bytes(&h).unwrap()).to_hex(),
            _ => "-".into(),
        };
        sig.push(format!("{} {st:?} {content}", it.name));
    }
    for (name, h) in store.tags_with_prefix(b"").unwrap() {
        sig.push(format!("tag {} {h}", String::from_utf8_lossy(&name)));
    }
    sig.extend(data_files(s.dir.path()).into_iter().map(|f| format!("file {f}")));
    sig
}

#[test]
fn fixtures_are_what_the_tests_assume() {
    // Each hash in the manifests is the hash of the data it names, and the stores are of the two kinds.
    for name in ["clean", "killed"] {
        for it in manifest(name) {
            assert_eq!(Hash::new(bytes(it.seed, it.size)).to_hex(), it.hash, "{name}/{}", it.name);
        }
    }
    let s = Setup::new("clean");
    assert!(!OldDb::open(&s.old().join("blobs.db"), &s.dir.path().join("scratch.db")).unwrap().was_repaired());
    let k = Setup::new("killed");
    let db = OldDb::open(&k.old().join("blobs.db"), &k.dir.path().join("scratch.db")).unwrap();
    assert!(db.was_repaired(), "a read-only open of the killed store must fail, so it is read through a repaired copy");
}

#[test]
fn every_file_moves_and_is_read_back_to_its_old_id() {
    let s = Setup::new("clean");
    let store = s.store();
    assert!(Store::has_old_store(&s.old()));
    let (report, calls) = s.run(&store);
    let r = report.unwrap();
    assert_eq!((r.inline, r.owned, r.external, r.partials_dropped), (2, 4, 2, 1), "{r:?}");
    assert!(r.failed.is_empty(), "{r:?}");
    assert!(!r.repaired);
    assert_eq!((r.tags, r.tags_dropped), (5, 1), "the partial's tag is left out");

    // Every complete file, read back, hashes to its old id, and its verified pieces serve and verify.
    let scratch = TempDir::new().unwrap();
    let reference = Store::open(&scratch.path().join("ref"), Options::default()).unwrap();
    let mut total = 0u64;
    for it in s.items.iter().filter(|i| i.kind != "partial") {
        let h: Hash = it.hash.parse().unwrap();
        let want = bytes(it.seed, it.size);
        assert_eq!(store.status(&h).unwrap(), Status::Complete { size: it.size as u64 }, "{}", it.name);
        let got = store.get_bytes(&h).unwrap();
        assert_eq!(Hash::new(&got), h, "{} reads back to its old id", it.name);
        assert_eq!(got, want, "{}", it.name);
        let all = ChunkRanges::from(ChunkNum(0)..ChunkNum(1 << 20));
        let rebuilt = reference.add_bytes(&want).unwrap().hash;
        assert_eq!(rebuilt, h);
        assert_eq!(store.encode_ranges_to_vec(&h, &all).unwrap(), reference.encode_ranges_to_vec(&h, &all).unwrap(), "{}: the outboard written by the move is the right one", it.name);
        total += it.size as u64;
    }
    assert_eq!(r.bytes, total);

    // Tags point at the right files.
    for it in s.items.iter().filter(|i| i.kind != "partial") {
        if let Some(t) = &it.tag {
            assert_eq!(store.tags_with_prefix(t.as_bytes()).unwrap(), vec![(t.as_bytes().to_vec(), it.hash.parse().unwrap())], "{t}");
        }
    }
    // The partial is gone, not kept in any form.
    let ph: Hash = s.items.iter().find(|i| i.kind == "partial").unwrap().hash.parse().unwrap();
    assert_eq!(store.status(&ph).unwrap(), Status::Absent);
    assert!(!data_files(s.dir.path()).iter().any(|f| f.starts_with(&ph.to_hex())));

    // New layout: owned data and outboards under data/, nothing from iroh; the in-place files are where they were.
    let names = data_files(s.dir.path());
    assert!(names.iter().all(|n| n.ends_with(".data") || n.ends_with(".obao")), "{names:?}");
    assert_eq!(names.iter().filter(|n| n.ends_with(".data")).count(), 4);
    for it in s.items.iter().filter(|i| i.kind == "external") {
        assert_eq!(fs::read(s.dir.path().join("shared").join(&it.name)).unwrap(), bytes(it.seed, it.size));
        assert!(!names.iter().any(|n| n == &format!("{}.data", it.hash)));
    }
    // The old store is gone, database last; a second call finds nothing to do.
    assert!(!s.old().join("blobs.db").exists());
    assert!(!s.old().join("data").exists());
    assert!(!Store::has_old_store(&s.old()));
    assert!(store.move_old_store(&s.old(), &mut |_, _| {}).unwrap().is_none());
    // Progress: starts at 0, ends at the total, never goes back.
    assert_eq!(calls.first(), Some(&(0, total)));
    assert_eq!(calls.last(), Some(&(total, total)));
    assert!(calls.windows(2).all(|w| w[0].0 <= w[1].0 && w[0].1 == w[1].1));
}

#[test]
fn the_partial_download_is_gone_and_is_fetched_again() {
    let s = Setup::new("clean");
    let store = s.store();
    s.run(&store);
    let it = s.items.iter().find(|i| i.kind == "partial").unwrap();
    let h: Hash = it.hash.parse().unwrap();
    assert_eq!(store.status(&h).unwrap(), Status::Absent);
    // A fetch from another store gives the whole file, intact.
    let scratch = TempDir::new().unwrap();
    let src = Store::open(&scratch.path().join("src"), Options::default()).unwrap();
    src.add_bytes(&bytes(it.seed, it.size)).unwrap();
    let w = ChunkRanges::from(ChunkNum(0)..ChunkNum(1 << 20));
    store.import_ranges(&h, &w, &src.encode_ranges_to_vec(&h, &w).unwrap()).unwrap();
    assert_eq!(store.get_bytes(&h).unwrap(), bytes(it.seed, it.size));
}

fn killed_at(fixture_name: &str, fault: Fault) -> (Setup, Vec<String>, cache_store::MoveReport) {
    let s = Setup::new(fixture_name);
    let store = s.store();
    store.set_fault(Some(fault));
    let err = store.move_old_store(&s.old(), &mut |_, _| {});
    assert!(err.is_err(), "{fault:?} must stop the move");
    // The app is gone: the store is dropped and opened again (as a restart does), then the move runs again.
    store.shutdown().ok();
    drop(store);
    let store = s.store();
    let (r, _) = s.run(&store);
    let sig = signature(&s, &store);
    (s, sig, r.unwrap())
}

#[test]
fn a_move_killed_at_any_point_and_restarted_ends_the_same() {
    let reference = Setup::new("clean");
    let rstore = reference.store();
    let (rr, _) = reference.run(&rstore);
    let rr = rr.unwrap();
    let rsig = signature(&reference, &rstore);
    let entries = reference.items.len();

    let mut faults = vec![Fault::MoveBeforeCleanup];
    for n in 0..entries {
        faults.push(Fault::MoveAfterEntries(n));
        faults.push(Fault::MoveBeforeJournal(n));
    }
    for f in faults {
        let (s, sig, report) = killed_at("clean", f);
        assert_eq!(sig, rsig, "{f:?}: the state differs from an uninterrupted move");
        assert_eq!(report, rr, "{f:?}: the report differs");
        // Nothing doubled: the same files on disk, the old store gone.
        assert!(!s.old().join("blobs.db").exists(), "{f:?}");
        let st = s.store();
        // Moving a second time changes nothing.
        assert!(st.move_old_store(&s.old(), &mut |_, _| {}).unwrap().is_none());
        assert_eq!(signature(&s, &st), rsig, "{f:?}");
    }
}

#[test]
fn a_kill_that_repeats_still_finishes() {
    // Killed twice at different points before it finishes.
    let s = Setup::new("clean");
    for f in [Fault::MoveAfterEntries(2), Fault::MoveAfterEntries(3), Fault::MoveBeforeJournal(1)] {
        let store = s.store();
        store.set_fault(Some(f));
        assert!(store.move_old_store(&s.old(), &mut |_, _| {}).is_err());
        drop(store);
    }
    let store = s.store();
    let (r, _) = s.run(&store);
    let r = r.unwrap();
    assert_eq!((r.inline, r.owned, r.external, r.partials_dropped), (2, 4, 2, 1));
    let reference = Setup::new("clean");
    let rs = reference.store();
    reference.run(&rs);
    assert_eq!(signature(&s, &store), signature(&reference, &rs));
}

#[test]
fn a_store_killed_without_shutdown_is_read_through_a_repaired_copy() {
    let s = Setup::new("killed");
    let original = fs::read(s.old().join("blobs.db")).unwrap();
    let store = s.store();
    // Stop just before the old store is deleted: everything is in, and the original database can be compared.
    store.set_fault(Some(Fault::MoveBeforeCleanup));
    assert!(store.move_old_store(&s.old(), &mut |_, _| {}).is_err());
    assert_eq!(fs::read(s.old().join("blobs.db")).unwrap(), original, "the original database is never written");
    assert!(!s.dir.path().join("store/tmp/old-blobs-repair.db").exists(), "the repaired copy is not left behind");
    drop(store);

    let store = s.store();
    let (r, _) = s.run(&store);
    let r = r.unwrap();
    assert!(r.repaired);
    assert_eq!((r.inline, r.owned, r.external, r.partials_dropped), (2, 4, 0, 1), "{r:?}");
    assert!(r.failed.is_empty());
    for it in s.items.iter().filter(|i| i.kind != "partial") {
        let h: Hash = it.hash.parse().unwrap();
        assert_eq!(store.get_bytes(&h).unwrap(), bytes(it.seed, it.size), "{}", it.name);
    }
    let ph: Hash = s.items.iter().find(|i| i.kind == "partial").unwrap().hash.parse().unwrap();
    assert_eq!(store.status(&ph).unwrap(), Status::Absent);
    assert!(!s.old().join("blobs.db").exists());
    assert_eq!(store.tags_with_prefix(b"share1/").unwrap().len(), 3, "the tags are all there");
}

#[test]
fn a_file_that_fails_the_rehash_is_reported_and_left_out() {
    let s = Setup::new("clean");
    let hex = |name: &str| s.items.iter().find(|i| i.name == name).unwrap().hash.clone();
    // An owned file with a flipped byte (same size), an owned file deleted, an in-place file edited, and an inline file is fine.
    let bad_owned = s.old().join("data").join(format!("{}.data", hex("b.bin")));
    let mut d = fs::read(&bad_owned).unwrap();
    d[1000] ^= 0xff;
    fs::write(&bad_owned, d).unwrap();
    fs::remove_file(s.old().join("data").join(format!("{}.data", hex("c.bin")))).unwrap();
    let mut e = bytes(6, 60_000);
    e[10] ^= 1;
    fs::write(s.dir.path().join("shared/ext1.bin"), e).unwrap();

    let store = s.store();
    let (r, _) = s.run(&store);
    let r = r.unwrap();
    let mut failed: Vec<String> = r.failed.iter().map(|f| f.hash.to_hex()).collect();
    failed.sort();
    let mut want = vec![hex("b.bin"), hex("c.bin"), hex("ext1.bin")];
    want.sort();
    assert_eq!(failed, want, "{r:?}");
    assert!(r.failed.iter().all(|f| !f.reason.is_empty()));
    let kinds: Vec<(String, String)> = {
        let mut k: Vec<_> = r.failed.iter().map(|f| (f.hash.to_hex(), f.kind.clone())).collect();
        k.sort();
        k
    };
    let mut want_kinds = vec![(hex("b.bin"), "owned".to_string()), (hex("c.bin"), "owned".to_string()), (hex("ext1.bin"), "external".to_string())];
    want_kinds.sort();
    assert_eq!(kinds, want_kinds);
    // The log: one line per file left out (id, kind, reason), then one total line.
    let lines = r.log_lines();
    assert_eq!(lines.len(), 4, "{lines:?}");
    assert!(lines[..3].iter().all(|l| l.starts_with("store move: left out ") && (l.contains("(owned)") || l.contains("(external)"))));
    assert!(lines.iter().take(3).any(|l| l.contains(&hex("b.bin"))));
    assert!(lines[3].starts_with("store move: done.") && lines[3].contains("3 left out"), "{}", lines[3]);
    assert_eq!((r.inline, r.owned, r.external), (2, 2, 1));
    // Left out: not in the store under its id, and not under any other (nothing in the store reads back to a different hash).
    for name in ["b.bin", "c.bin", "ext1.bin"] {
        assert_eq!(store.status(&hex(name).parse().unwrap()).unwrap(), Status::Absent, "{name}");
    }
    for it in s.items.iter().filter(|i| ["a.bin", "edge.bin", "tiny.txt", "small.txt", "ext2.bin"].contains(&i.name.as_str())) {
        let h: Hash = it.hash.parse().unwrap();
        assert_eq!(Hash::new(store.get_bytes(&h).unwrap()), h);
    }
    // Their tags are left out too, and the person's edited file is untouched.
    assert!(store.tags_with_prefix(b"share1/b.bin").unwrap().is_empty());
    assert!(store.tags_with_prefix(b"share2/ext1.bin").unwrap().is_empty());
    assert_eq!(fs::read(s.dir.path().join("shared/ext1.bin")).unwrap().len(), 60_000);
    // The move still finished and cleaned up.
    assert!(!s.old().join("blobs.db").exists());
    assert_eq!(r.tags_dropped, 4);
}

#[test]
fn no_old_store_means_nothing_to_do() {
    let d = TempDir::new().unwrap();
    let store = Store::open(&d.path().join("store"), Options::default()).unwrap();
    assert!(!Store::has_old_store(&d.path().join("blobs")));
    assert!(store.move_old_store(&d.path().join("blobs"), &mut |_, _| panic!("no progress without a store")).unwrap().is_none());
}
