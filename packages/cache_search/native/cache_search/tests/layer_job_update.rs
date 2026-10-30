//! A `layer_download` job asked to update (or carry on) an area names the area and no shape. 1.0.27 checked the shape of the
//! request as asked, so every update failed at once with "a download needs \"bbox\" ... or \"polygon\" ..." (the raw text then
//! showed on the phone when Update was tapped on a region). The job now takes the stored area's shape first.

use cache_search::job::Job;
use serde_json::json;

fn scratch(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("cs-layer-job-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn an_update_of_a_stored_area_starts() {
    let dir = scratch("update");
    let cfg = json!({"dir": dir.join("layers").to_string_lossy(), "defs_dirs": [], "catalogue_urls": [], "cache_max_bytes": 1 << 20, "online": false});
    let inner = cache_layers::Inner::open(serde_json::from_value(cfg.clone()).unwrap()).unwrap();
    inner
        .save_user_def(
            &json!({
                "format": 1, "id": "base", "title": "base", "kind": "vector", "transform": "as_is",
                "source": {"type": "xyz", "url": "http://127.0.0.1:1/{z}/{x}/{y}", "minzoom": 0, "maxzoom": 12, "tile_format": "mvt"},
                "attribution": "test", "license": "test", "update": {"version": "2"}, "offline": {"allowed": true}
            })
            .to_string(),
        )
        .unwrap();
    // An area as a download leaves it (the meta of run_download).
    let store = inner.store_create("base").unwrap();
    store
        .put_area("r1", "complete", &json!({"id": "r1", "name": "Idaho", "layer": "base", "bbox": [-117.25, 41.98, -111.04, 49.0], "polygon": null, "minzoom": 0, "maxzoom": 6, "version": "1", "tiles_requested": 10, "source": "x"}))
        .unwrap();
    drop(store);
    drop(inner);

    let update = json!({"layers": cfg, "layer": "base", "area": "r1", "update": true}).to_string();
    let job = Job::start("layer_download", &update);
    assert!(job.is_ok(), "an update names only the area: {:?}", job.err().map(|e| e.to_string()));
    job.unwrap().cancel();

    // An area that does not exist is still refused, in the core's words for it (not the shape message).
    let missing = json!({"layers": cfg, "layer": "base", "area": "nope", "update": true}).to_string();
    let e = Job::start("layer_download", &missing).err().expect("no such area").to_string();
    assert!(!e.contains("needs \"bbox\""), "{e}");

    // A request with neither an area nor a shape is still a bad request.
    let bad = json!({"layers": cfg, "layer": "base"}).to_string();
    assert!(Job::start("layer_download", &bad).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}
