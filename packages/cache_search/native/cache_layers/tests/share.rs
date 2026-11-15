//! Maps sync with one writer per file: each device shares its own snapshot, reads the union of its own store and the peers'
//! snapshots, deletes travel as records, and conflict copies an older build left are taken back in (share.rs).

mod common;
use cache_layers::store::{Store, Table};
use cache_layers::{Inner, LayersCfg};
use common::Scratch;
use serde_json::json;
use std::path::Path;
use std::time::Duration;

const NOW: Duration = Duration::ZERO;

fn device(sc: &Scratch, name: &str) -> Inner {
    let i = Inner::open(LayersCfg { dir: sc.path(name).to_string_lossy().into_owned(), defs_dirs: vec![], catalogue_urls: vec![], cache_max_bytes: 1 << 20, online: false }).unwrap();
    i.save_user_def(r#"{"format":1,"id":"basemap","title":"Base map","kind":"vector","transform":"as_is","source":{"type":"xyz","url":"https://example.org/{z}/{x}/{y}.mvt","tile_format":"mvt"}}"#).unwrap();
    i
}

fn meta(created: i64) -> serde_json::Value {
    json!({"bbox": [-115.0, 42.0, -114.0, 43.0], "minzoom": 1, "maxzoom": 1, "created": created})
}

/// This device holds area `id` with one tile at (1, x, y).
fn hold(i: &Inner, id: &str, x: u32, y: u32, created: i64) {
    let s = i.store_create("basemap").unwrap();
    s.put_area(id, "complete", &meta(created)).unwrap();
    s.put_batch(Table::Tiles, &[(1, x, y, format!("tile-{id}").into_bytes())], "v1").unwrap();
}

/// What the sync does: each device's shared folder arrives in the other's (only the share folder; `store/` never syncs).
fn sync(from: &Inner, to: &Inner) {
    let (a, b) = (from.share_root(), to.share_root());
    copy_dir(&a, &b);
}

fn copy_dir(a: &Path, b: &Path) {
    std::fs::create_dir_all(b).unwrap();
    for e in std::fs::read_dir(a).into_iter().flatten().flatten() {
        let name = e.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue; // hidden files never sync
        }
        if e.path().is_dir() {
            copy_dir(&e.path(), &b.join(&name));
        } else {
            std::fs::copy(e.path(), b.join(&name)).unwrap();
        }
    }
}

fn ids(i: &Inner) -> Vec<String> {
    i.areas("basemap").iter().map(|a| a.id.clone()).collect()
}

fn tile(i: &Inner, x: u32, y: u32) -> Option<Vec<u8>> {
    let base = i.base_of("basemap").unwrap();
    i.downloaded_tile(&base, 1, x, y).unwrap()
}

#[test]
fn two_devices_with_different_areas_each_list_and_read_both_with_no_conflict_files() {
    let sc = Scratch::new("share-union");
    let (a, b) = (device(&sc, "a"), device(&sc, "b"));
    hold(&a, "idaho", 0, 0, 100);
    hold(&b, "anguilla", 1, 1, 200);
    assert!(a.maintain_share(NOW).exported == 1 && b.maintain_share(NOW).exported == 1);
    sync(&a, &b);
    sync(&b, &a);
    // each lists both, its own first
    assert_eq!(ids(&a), ["idaho", "anguilla"]);
    assert_eq!(ids(&b), ["anguilla", "idaho"]);
    // each reads both devices' tiles
    for d in [&a, &b] {
        assert_eq!(tile(d, 0, 0).unwrap(), b"tile-idaho");
        assert_eq!(tile(d, 1, 1).unwrap(), b"tile-anguilla");
        assert_eq!(tile(d, 0, 1), None);
    }
    // the peer's area is marked, this device's own is not
    let from = |i: &Inner, id: &str| i.areas("basemap").iter().find(|x| x.id == id).unwrap().meta["shared_from"].as_str().map(str::to_string);
    assert_eq!(from(&a, "anguilla").as_deref(), Some(b.share_id()));
    assert_eq!(from(&a, "idaho"), None);
    // never merged into the live store: A's own store holds A's data only
    let own = Store::open(&a.store_path("basemap"), false).unwrap();
    assert_eq!(own.areas().unwrap().len(), 1);
    assert_eq!(own.tile_count(), 1);
    // the live stores and their logs are not in the shared folder, and nothing is a conflict copy
    for d in [&a, &b] {
        let mut names = Vec::new();
        walk(&d.share_root(), &mut names);
        assert!(names.iter().all(|n| !n.contains("(conflict")), "{names:?}");
        assert!(names.iter().all(|n| !n.ends_with("-wal") && !n.ends_with("-shm")), "{names:?}");
        assert!(names.iter().any(|n| n.ends_with(".sqlite")), "{names:?}");
    }
}

fn walk(p: &Path, out: &mut Vec<String>) {
    for e in std::fs::read_dir(p).into_iter().flatten().flatten() {
        if e.path().is_dir() {
            walk(&e.path(), out);
        } else {
            out.push(e.file_name().to_string_lossy().into_owned());
        }
    }
}

#[test]
fn a_snapshot_is_written_only_when_the_store_changed_and_has_been_quiet() {
    let sc = Scratch::new("share-quiet");
    let a = device(&sc, "a");
    assert!(!a.export_share("basemap", NOW).unwrap(), "no store, no snapshot");
    hold(&a, "idaho", 0, 0, 100);
    assert!(!a.export_share("basemap", Duration::from_secs(3600)).unwrap(), "just written to: not quiet yet");
    assert!(a.export_share("basemap", NOW).unwrap());
    assert!(!a.export_share("basemap", NOW).unwrap(), "unchanged: nothing to write again");
    hold(&a, "utah", 1, 0, 101);
    assert!(a.export_share("basemap", NOW).unwrap());
    let snap = Store::open_peer(&a.export_path("basemap")).unwrap();
    assert_eq!(snap.areas().unwrap().len(), 2);
    // written whole under a hidden temporary name, never left behind
    let mut names = Vec::new();
    walk(&a.share_root(), &mut names);
    assert!(names.iter().all(|n| !n.contains(".tmp")), "{names:?}");
}

#[test]
fn a_delete_on_one_device_removes_the_area_on_the_other_and_a_later_download_wins() {
    let sc = Scratch::new("share-delete");
    let (a, b) = (device(&sc, "a"), device(&sc, "b"));
    // both hold Idaho (B downloaded it too), A also holds Utah
    hold(&a, "idaho", 0, 0, 100);
    hold(&a, "utah", 1, 0, 100);
    hold(&b, "idaho", 0, 0, 100);
    a.maintain_share(NOW);
    b.maintain_share(NOW);
    sync(&a, &b);
    sync(&b, &a);
    assert_eq!(ids(&b), ["idaho", "utah"]);

    // A deletes Idaho and Utah (Utah only B's copy of A's...): A's store loses it, a record is shared
    a.delete_areas("basemap", Some("idaho")).unwrap();
    a.delete_areas("basemap", Some("utah")).unwrap();
    assert_eq!(ids(&a), Vec::<String>::new());
    a.maintain_share(NOW);
    sync(&a, &b);
    // B no longer shows A's copy of Utah, and its own Idaho is removed from its own store by the record
    assert_eq!(ids(&b), ["idaho"], "before B applies the record, its own Idaho is still its own");
    assert_eq!(b.maintain_share(NOW).deleted, 1);
    assert_eq!(ids(&b), Vec::<String>::new());
    assert_eq!(tile(&b, 0, 0), None, "the tiles of the deleted area are gone from B too");
    b.maintain_share(NOW);
    sync(&b, &a);
    assert_eq!(ids(&a), Vec::<String>::new(), "B's snapshot no longer holds it, and B shares no record of its own for it");

    // a download after the delete is newer than it and wins, on the device that made it and on its peers
    let after = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64 + 5;
    hold(&a, "idaho", 0, 0, after);
    assert_eq!(ids(&a), ["idaho"]);
    a.maintain_share(NOW);
    sync(&a, &b);
    assert_eq!(ids(&b), ["idaho"]);
    assert_eq!(tile(&b, 0, 0).unwrap(), b"tile-idaho");
    // and B applying the old record leaves the new area alone
    assert_eq!(b.maintain_share(NOW).deleted, 0);
}

#[test]
fn deleting_an_area_only_a_peer_holds_works_and_is_shared() {
    let sc = Scratch::new("share-delete-peer");
    let (a, b) = (device(&sc, "a"), device(&sc, "b"));
    hold(&a, "idaho", 0, 0, 100);
    a.maintain_share(NOW);
    sync(&a, &b);
    assert_eq!(ids(&b), ["idaho"]);
    // B holds nothing of its own, and still deletes: there is no device-only delete
    b.delete_areas("basemap", Some("idaho")).unwrap();
    assert_eq!(ids(&b), Vec::<String>::new());
    b.maintain_share(NOW);
    sync(&b, &a);
    assert_eq!(a.maintain_share(NOW).deleted, 1);
    assert_eq!(ids(&a), Vec::<String>::new());
    assert!(b.delete_areas("basemap", Some("never-existed")).is_err());
}

fn conflict(i: &Inner, name: &str) -> std::path::PathBuf {
    i.store_path("basemap").parent().unwrap().join(name)
}

#[test]
fn conflict_copies_are_taken_into_the_live_store_and_deleted_and_the_peers_live_file_is_dropped() {
    let sc = Scratch::new("share-rescue");
    let p = device(&sc, "p");
    // what the old build left on P: the other device's store as the live file, P's own as a conflict copy
    {
        let theirs = Store::open(&p.store_path("basemap"), true).unwrap();
        theirs.put_area("server-area", "complete", &meta(50)).unwrap();
        theirs.put_batch(Table::Tiles, &[(1, 1, 1, b"theirs".to_vec())], "v1").unwrap();
    }
    let own_copy = conflict(&p, "basemap (conflict, Android device, 2026-11-15 2040 UTC).sqlite");
    {
        let own = Store::open(&own_copy, true).unwrap();
        own.put_area("anguilla", "complete", &meta(60)).unwrap();
        own.put_batch(Table::Tiles, &[(1, 0, 1, b"mine".to_vec())], "v1").unwrap();
        own.checkpoint();
    }
    // a log of a database that is gone, and a name that only has brackets in it
    let lone = conflict(&p, "regions (conflict, Android device, 2026-11-15 2040 UTC).sqlite-wal");
    std::fs::write(&lone, b"log").unwrap();
    let bracket = conflict(&p, "notes (conflict) final.sqlite");
    std::fs::write(&bracket, b"x").unwrap();

    assert_eq!(p.rescue_conflicts(), 2);
    assert!(!own_copy.exists() && !lone.exists());
    assert!(bracket.exists(), "a name that is not a conflict copy is left alone");
    assert_eq!(ids(&p), ["anguilla"], "P's own data is back, the other device's live file is not treated as P's");
    assert_eq!(tile(&p, 0, 1).unwrap(), b"mine");
    assert_eq!(tile(&p, 1, 1), None);
    // nothing left to do the next time
    assert_eq!(p.rescue_conflicts(), 0);
}

#[test]
fn several_conflict_copies_are_merged_and_a_broken_one_is_left_and_drops_nothing() {
    let sc = Scratch::new("share-rescue-two");
    let p = device(&sc, "p");
    let one = conflict(&p, "basemap (conflict, A, 2026-11-14 1000 UTC).sqlite");
    let two = conflict(&p, "basemap (conflict, A, 2026-11-15 1000 UTC).sqlite");
    for (path, id, x) in [(&one, "one", 0u32), (&two, "two", 1u32)] {
        let s = Store::open(path, true).unwrap();
        s.put_area(id, "partial", &meta(1)).unwrap();
        s.put_batch(Table::Tiles, &[(1, x, 0, id.as_bytes().to_vec())], "v1").unwrap();
        s.checkpoint();
    }
    // the same area, complete, in the second: complete beats partial
    Store::open(&two, false).unwrap().put_area("one", "complete", &meta(1)).unwrap();
    assert_eq!(p.rescue_conflicts(), 2);
    let areas = p.areas("basemap");
    assert_eq!(areas.iter().map(|a| a.id.as_str()).collect::<Vec<_>>().len(), 2);
    assert_eq!(areas.iter().find(|a| a.id == "one").unwrap().state, "complete");
    assert_eq!(tile(&p, 0, 0).unwrap(), b"one");
    assert_eq!(tile(&p, 1, 0).unwrap(), b"two");

    // a copy that is not a database: kept, and the live store is not dropped for it
    let broken = conflict(&p, "basemap (conflict, A, 2026-11-16 1000 UTC).sqlite");
    std::fs::write(&broken, b"not a database at all, not a database at all").unwrap();
    assert_eq!(p.rescue_conflicts(), 0);
    assert!(broken.exists());
    assert_eq!(ids(&p).len(), 2);
}

#[test]
fn files_an_older_build_synced_and_anything_that_is_not_a_snapshot_are_never_read() {
    let sc = Scratch::new("share-old");
    let a = device(&sc, "a");
    hold(&a, "mine", 0, 0, 1);
    // an older device's live store, its log and a conflict copy of one arrive in the old places: a store/ folder is never read
    // for a peer, and in the share folder only `<device>.sqlite` is
    let share = a.share_root().join("basemap");
    std::fs::create_dir_all(&share).unwrap();
    for name in ["basemap.sqlite-wal", "dev (conflict, X, 2026-11-15 2040 UTC).sqlite", ".hidden.sqlite.tmp1", "x.sqlite.part", "bad name.sqlite"] {
        let s = Store::open(&share.join(name), true).unwrap_or_else(|_| panic!("{name}"));
        s.put_area("poison", "complete", &meta(1)).unwrap();
    }
    // a peer's own snapshot that is not a database yet (still arriving)
    std::fs::write(share.join("abc123.sqlite"), b"half").unwrap();
    // this device's own snapshot name is not read as a peer's
    {
        let own = Store::open(&share.join(format!("{}.sqlite", a.share_id())), true).unwrap();
        own.put_area("stale-own", "complete", &meta(1)).unwrap();
    }
    assert_eq!(ids(&a), ["mine"]);
    // the old build's live store in a peer's store/ path is not where a peer is read from either
    let old = a.store_path("basemap");
    assert!(old.is_file());
}

#[test]
fn the_share_name_is_made_once_and_kept_out_of_the_synced_files() {
    let sc = Scratch::new("share-id");
    let a = device(&sc, "a");
    let again = device(&sc, "a");
    assert_eq!(a.share_id(), again.share_id());
    assert!(sc.path("a").join(".share-id").is_file());
    assert!(a.share_id().bytes().all(|c| c.is_ascii_hexdigit()));
}
