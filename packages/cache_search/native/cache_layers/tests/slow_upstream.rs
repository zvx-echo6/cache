//! One slow layer must never starve the others: the local tile server over HTTP against fake hosts on 127.0.0.1,
//! one of them deliberately slow. Everything here is time-bounded.

mod common;
use cache_layers::{Layers, LayersCfg};
use common::*;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

/// How long the server waits for one upstream request in these tests.
const TIMEOUT: Duration = Duration::from_millis(1500);

fn xyz_def(id: &str, port: u16, prefix: &str, extra: Value) -> String {
    let mut d = json!({
        "format": 1, "id": id, "title": id, "kind": "vector", "transform": "as_is",
        "source": {"type": "xyz", "url": format!("http://127.0.0.1:{port}/{prefix}/{{z}}/{{x}}/{{y}}"), "minzoom": 0, "maxzoom": 14, "tile_format": "mvt"},
        "attribution": "test", "license": "test", "update": {"version": "1"}
    });
    for (k, v) in extra.as_object().unwrap() {
        d[k] = v.clone();
    }
    d.to_string()
}

fn body(z: u8, x: u32, y: u32) -> Vec<u8> {
    format!("tile-{z}-{x}-{y}").into_bytes()
}

/// `/prefix/z/x/y` -> (prefix, z, x, y)
fn parse(url: &str) -> Option<(String, u8, u32, u32)> {
    let p: Vec<&str> = url.trim_start_matches('/').split('/').collect();
    if p.len() != 4 {
        return None;
    }
    Some((p[0].to_string(), p[1].parse().ok()?, p[2].parse().ok()?, p[3].parse().ok()?))
}

struct Get {
    status: u16,
    body: Vec<u8>,
    cache: Option<String>,
    took: Duration,
}

fn get(base: &str, path: &str) -> Get {
    let t = Instant::now();
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(30)).build();
    let (status, body, cache) = match agent.get(&format!("{base}{path}")).call() {
        Ok(r) => {
            let (st, h) = (r.status(), r.header("X-Cache-Status").map(String::from));
            let mut b = Vec::new();
            std::io::Read::read_to_end(&mut r.into_reader(), &mut b).unwrap();
            (st, b, h)
        }
        Err(ureq::Error::Status(c, r)) => {
            let h = r.header("X-Cache-Status").map(String::from);
            let mut b = Vec::new();
            let _ = std::io::Read::read_to_end(&mut r.into_reader(), &mut b);
            if c >= 500 {
                eprintln!("{path}: {c} {}", String::from_utf8_lossy(&b));
            }
            (c, b, h)
        }
        Err(e) => panic!("{path}: {e}"),
    };
    Get { status, body, cache, took: t.elapsed() }
}

/// (Fetch limits are kept per layer id for the whole process, so each test uses ids of its own.)
fn layers(sc: &Scratch) -> Layers {
    cache_layers::http::set_upstream_timeout(TIMEOUT);
    Layers::new(LayersCfg { dir: sc.path("l").to_string_lossy().into_owned(), defs_dirs: vec![], catalogue_urls: vec![], cache_max_bytes: 1 << 24, online: true }).unwrap()
}

#[test]
fn a_slow_layer_does_not_starve_the_others() {
    let sc = Scratch::new("slow");
    let slow_on = Arc::new(AtomicBool::new(false));
    let on = slow_on.clone();
    // plenty of serving threads so the fake host itself is never the bottleneck
    let host = fake_host_n(64, 0, move |url, _| {
        let Some((prefix, z, x, y)) = parse(url) else { return (404, vec![]) };
        if prefix == "slow" && on.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_secs(4));
        }
        (200, body(z, x, y))
    });
    let layers = layers(&sc);
    layers.inner.save_user_def(&xyz_def("slow", host.port, "slow", json!({"offline": {"allowed": true, "max_parallel": 3}}))).unwrap();
    layers.inner.save_user_def(&xyz_def("fast", host.port, "fast", json!({}))).unwrap();
    let base = layers.serve().unwrap()["base_url"].as_str().unwrap().to_string();

    // a tile of the slow layer viewed before the upstream went slow: a local (cache) hit from now on
    assert_eq!(get(&base, "/layers/slow/6/1/1").status, 200);

    // the upstream goes slow and the map asks for 30 different tiles of it at once (twice the server's 8 workers)
    slow_on.store(true, Ordering::SeqCst);
    let flood: Vec<_> = (0..30u32)
        .map(|i| {
            let base = base.clone();
            std::thread::spawn(move || get(&base, &format!("/layers/slow/9/{i}/7")))
        })
        .collect();
    std::thread::sleep(Duration::from_millis(400));

    // meanwhile the base map and local hits answer quickly
    let mut worst = Duration::ZERO;
    for i in 0..10u32 {
        let g = get(&base, &format!("/layers/fast/9/{i}/7"));
        assert_eq!((g.status, g.body.as_slice(), g.cache.as_deref()), (200, body(9, i, 7).as_slice(), Some("network")), "fast tile {i}");
        worst = worst.max(g.took);
        let g = get(&base, "/layers/slow/6/1/1");
        assert_eq!((g.status, g.cache.as_deref()), (200, Some("cache")), "local hit of the slow layer");
        worst = worst.max(g.took);
    }
    let h = get(&base, "/health");
    assert_eq!(h.status, 200);
    worst = worst.max(h.took);
    eprintln!("slow upstream running: worst answer for the other layer / local hits / health = {worst:?}");
    assert!(worst < Duration::from_millis(750), "other layers and local hits must not wait behind the slow one: {worst:?}");

    // the slow layer itself: clean misses once the upstream timeout has passed, never more than max_parallel in flight
    let mut misses = 0;
    for h in flood {
        let g = h.join().unwrap();
        if g.status == 404 && g.cache.as_deref() == Some("miss") {
            misses += 1;
            assert!(g.took < Duration::from_secs(12), "a miss comes soon: {:?}", g.took);
        } else {
            assert_eq!(g.status, 200, "{}", g.took.as_millis());
        }
    }
    assert!(misses > 0, "slow tiles answered as clean misses");
}

#[test]
fn a_layers_upstream_fetches_stay_within_its_max_parallel() {
    let sc = Scratch::new("cap");
    let host = fake_host_n(32, 300, |url, _| match parse(url) {
        Some((_, z, x, y)) => (200, body(z, x, y)),
        None => (404, vec![]),
    });
    let layers = layers(&sc);
    layers.inner.save_user_def(&xyz_def("capped", host.port, "l", json!({"offline": {"allowed": true, "max_parallel": 2}}))).unwrap();
    let base = layers.serve().unwrap()["base_url"].as_str().unwrap().to_string();
    let hs: Vec<_> = (0..6u32)
        .map(|i| {
            let base = base.clone();
            std::thread::spawn(move || get(&base, &format!("/layers/capped/8/{i}/9")))
        })
        .collect();
    for h in hs {
        assert_eq!(h.join().unwrap().status, 200);
    }
    assert_eq!(host.stats.max_in_flight.load(Ordering::SeqCst), 2);
}

#[test]
fn an_upstream_timeout_is_a_clean_miss_that_is_retried_later() {
    let sc = Scratch::new("timeout");
    let slow = Arc::new(AtomicBool::new(true));
    let s2 = slow.clone();
    let host = fake_host_n(16, 0, move |url, _| {
        let Some((_, z, x, y)) = parse(url) else { return (404, vec![]) };
        if s2.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_secs(4));
        }
        (200, body(z, x, y))
    });
    let layers = layers(&sc);
    layers.inner.save_user_def(&xyz_def("timing", host.port, "l", json!({}))).unwrap();
    let base = layers.serve().unwrap()["base_url"].as_str().unwrap().to_string();
    let g = get(&base, "/layers/timing/5/3/3");
    assert_eq!((g.status, g.cache.as_deref()), (404, Some("miss")));
    assert!(g.took >= Duration::from_millis(1200) && g.took < Duration::from_millis(3500), "gave up at the timeout: {:?}", g.took);
    // the miss is not remembered: when the upstream recovers the tile comes
    slow.store(false, Ordering::SeqCst);
    let g = get(&base, "/layers/timing/5/3/3");
    assert_eq!((g.status, g.body, g.cache.as_deref()), (200, body(5, 3, 3), Some("network")));
}

#[test]
fn requests_for_the_same_tile_share_one_fetch() {
    let sc = Scratch::new("coalesce");
    let host = fake_host_n(16, 400, |url, _| match parse(url) {
        Some((_, z, x, y)) => (200, body(z, x, y)),
        None => (404, vec![]),
    });
    let layers = layers(&sc);
    layers.inner.save_user_def(&xyz_def("shared", host.port, "l", json!({}))).unwrap();
    let base = layers.serve().unwrap()["base_url"].as_str().unwrap().to_string();
    let gate = Arc::new(Barrier::new(8));
    let hs: Vec<_> = (0..8)
        .map(|_| {
            let (base, gate) = (base.clone(), gate.clone());
            std::thread::spawn(move || {
                gate.wait();
                get(&base, "/layers/shared/7/20/30")
            })
        })
        .collect();
    for h in hs {
        let g = h.join().unwrap();
        assert_eq!((g.status, g.body), (200, body(7, 20, 30)));
    }
    assert_eq!(host.stats.per_url.lock().unwrap().get("/l/7/20/30").copied(), Some(1), "one upstream request for eight identical ones");
}
