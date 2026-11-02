//! Road tiles as a folder (the downloaded regions, docs/REGIONS.md) beside the single tiles.tar: the Valhalla config each gets,
//! when routing counts as installed, the region's name and age, and which one wins when both are there.

use cache_navigate::{valhalla_config, NavCore, NavigateCfg, PlaceSlot, TileStream, ValhallaCfg};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

struct Tmp(PathBuf);

impl Tmp {
    fn new(name: &str) -> Tmp {
        let d = std::env::temp_dir().join(format!("cache-navigate-tiles-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        Tmp(d)
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A tile folder with one tile in it, and a file standing in for the shim library.
fn folder(t: &Tmp) -> (PathBuf, PathBuf) {
    let dir = t.0.join("tiles").join("na-2026-10-18");
    std::fs::create_dir_all(dir.join("2/000/763")).unwrap();
    std::fs::write(dir.join("2/000/763/464.gph"), b"tile").unwrap();
    let shim = t.0.join("libvalhalla_shim.so");
    std::fs::write(&shim, b"").unwrap();
    (dir, shim)
}

fn cfg(tiles: &Path, shim: &Path, region: Option<&str>) -> NavigateCfg {
    NavigateCfg {
        valhalla: Some(ValhallaCfg { tiles: tiles.to_string_lossy().into_owned(), shim: shim.to_string_lossy().into_owned(), region: region.map(String::from) }),
        offroad: None,
    }
}

struct Stream {
    dir: Option<PathBuf>,
    calls: Mutex<usize>,
}

impl TileStream for Stream {
    fn prepare(&self, _points: &[(f64, f64)]) {
        *self.calls.lock().unwrap() += 1;
    }
    fn tile_dir(&self) -> Option<PathBuf> {
        self.dir.clone()
    }
}

#[test]
fn a_folder_of_tiles_is_a_tile_dir_and_a_tar_a_tile_extract() {
    let t = Tmp::new("config");
    let (dir, _) = folder(&t);
    let c: Value = serde_json::from_str(&valhalla_config(&dir)).unwrap();
    assert_eq!(c["mjolnir"]["tile_dir"], &*dir.to_string_lossy());
    assert!(c["mjolnir"].get("tile_extract").is_none(), "a folder has no tile_extract");
    assert_eq!(c["mjolnir"]["hierarchy"], true, "the rest of the template is kept");
    let tar = t.0.join("tiles.tar");
    std::fs::write(&tar, b"").unwrap();
    let c: Value = serde_json::from_str(&valhalla_config(&tar)).unwrap();
    assert_eq!(c["mjolnir"]["tile_extract"], &*tar.to_string_lossy());
    assert!(c["mjolnir"].get("tile_dir").is_none());
}

#[test]
fn a_folder_counts_as_installed_and_takes_its_name_from_region() {
    let t = Tmp::new("installed");
    let (dir, shim) = folder(&t);
    let core = NavCore::new(cfg(&dir, &shim, Some("Southern Idaho, Utah")), PlaceSlot::default());
    assert!(core.routing_installed());
    assert_eq!(core.tiles_path(), Some(dir.to_string_lossy().into_owned()));
    let (name, age) = core.region_info("2099-01-01T00:00:00Z");
    assert_eq!(name, "Southern Idaho, Utah");
    assert!(age.ends_with("days old"), "{age}");
    // A folder without a region name has no name (not the folder's).
    let (name, _) = NavCore::new(cfg(&dir, &shim, None), PlaceSlot::default()).region_info("2099-01-01T00:00:00Z");
    assert_eq!(name, "");
    // No folder, or no shim: not installed.
    assert!(!NavCore::new(cfg(&t.0.join("missing"), &shim, None), PlaceSlot::default()).routing_installed());
    assert!(!NavCore::new(cfg(&dir, &t.0.join("no-shim.so"), None), PlaceSlot::default()).routing_installed());
}

#[test]
fn the_streams_folder_is_used_unless_a_tar_is_there() {
    let t = Tmp::new("stream");
    let (dir, shim) = folder(&t);
    // No tiles configured: the stream's folder, and a route asks the stream first.
    let core = NavCore::new(cfg(Path::new(""), &shim, Some("Idaho")), PlaceSlot::default());
    assert!(!core.routing_installed());
    let s = Arc::new(Stream { dir: Some(dir.clone()), calls: Mutex::new(0) });
    let ts: Arc<dyn TileStream> = s.clone();
    core.set_stream(Some(ts));
    assert!(core.routing_installed());
    assert_eq!(core.tiles_path(), Some(dir.to_string_lossy().into_owned()));
    core.prepare_tiles(&[(42.5, -113.8)]);
    assert_eq!(*s.calls.lock().unwrap(), 1);
    // A tiles.tar that is there holds its whole region: it is used, and nothing is streamed.
    let tar = t.0.join("tiles.tar");
    std::fs::write(&tar, b"").unwrap();
    let core = NavCore::new(cfg(&tar, &shim, Some("Idaho")), PlaceSlot::default());
    let ts: Arc<dyn TileStream> = s.clone();
    core.set_stream(Some(ts));
    assert_eq!(core.tiles_path(), Some(tar.to_string_lossy().into_owned()));
    core.prepare_tiles(&[(42.5, -113.8)]);
    assert_eq!(*s.calls.lock().unwrap(), 1, "not asked again");
}
