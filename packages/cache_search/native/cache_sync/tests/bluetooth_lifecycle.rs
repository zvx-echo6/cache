//! Software-only mobile bridge lifecycle through the public sync API. No native adapter, radio, relay or discovery service.
#![cfg(all(feature = "bluetooth", any(target_os = "linux", target_os = "android")))]

use cache_sync::{Config, SyncEngine};
use serde_json::json;

fn engine(dir: &std::path::Path, reticulum: bool) -> SyncEngine {
    SyncEngine::open(serde_json::from_value::<Config>(json!({
        "dir": dir, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 600, "reticulum": if reticulum { json!("entries") } else { json!(false) },
    })).unwrap()).unwrap()
}

#[test]
fn mobile_callbacks_are_revoked_on_stop_and_engine_close() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path(), true);
    assert!(e.call("bluetooth_status", &json!({})).unwrap()["handle"].is_null());
    let first = e.call("bluetooth_start", &json!({})).unwrap()["handle"].as_u64().unwrap();
    assert_eq!(e.call("bluetooth_start", &json!({})).unwrap()["handle"], first, "start is idempotent");
    assert!(cache_rns::bluetooth::android_bridge(first).is_some());
    e.call("bluetooth_stop", &json!({})).unwrap();
    e.call("bluetooth_stop", &json!({})).unwrap();
    assert!(cache_rns::bluetooth::android_bridge(first).is_none());
    let second = e.call("bluetooth_start", &json!({})).unwrap()["handle"].as_u64().unwrap();
    assert_ne!(first, second);
    assert!(cache_rns::bluetooth::android_bridge(second).is_some());
    e.close();
    assert!(cache_rns::bluetooth::android_bridge(second).is_none(), "closing the engine also closes its platform callbacks");
}

#[test]
fn an_iroh_only_engine_does_not_create_a_bluetooth_session() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path(), false);
    assert!(e.call("bluetooth_start", &json!({})).is_err());
    assert!(e.call("bluetooth_status", &json!({})).unwrap()["handle"].is_null());
    e.close();
}

#[test]
fn ip_permission_is_independent_of_the_local_sync_session() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path(), true);
    e.call("set_policy", &json!({"network": true, "ip_network": false})).unwrap();
    let first = e.call("bluetooth_start", &json!({})).unwrap()["handle"].as_u64().unwrap();
    let status = e.call("status", &json!({})).unwrap();
    assert_eq!(status["network"], true, "local sync can run without IP permission");
    assert_eq!(status["ip_network"], false);
    e.call("set_policy", &json!({"network": true, "ip_network": false})).unwrap();
    assert_eq!(e.call("bluetooth_status", &json!({})).unwrap()["handle"], first, "reapplying policy does not restart the carrier");
    e.call("set_policy", &json!({"network": true, "ip_network": true})).unwrap();
    let second = e.call("bluetooth_status", &json!({})).unwrap()["handle"].as_u64().unwrap();
    assert_ne!(first, second, "new carrier configuration has a new callback epoch");
    assert!(cache_rns::bluetooth::android_bridge(first).is_none());
    e.close();
    assert!(cache_rns::bluetooth::android_bridge(second).is_none());
}

#[test]
fn linked_engines_sync_markdown_over_virtual_gatt_with_ip_denied() {
    use std::time::{Duration, Instant};
    use cache_rns::bluetooth::{android_bridge, AndroidBleIngressAdmission};
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("notes-a"), tmp.path().join("notes-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    let note = b"# BLE-only note\nThis Markdown must sync while IP permission is denied.\n";
    let mut file = std::fs::File::create(fa.join("proof.md")).unwrap();
    std::io::Write::write_all(&mut file, note).unwrap();
    file.set_modified(std::time::SystemTime::now() - Duration::from_secs(60)).unwrap();
    drop(file);
    let a = engine(&tmp.path().join("a"), true);
    let b = engine(&tmp.path().join("b"), true);
    for e in [&a, &b] {
        e.call("set_policy", &json!({"network": true, "ip_network": false})).unwrap();
    }
    let ah = a.call("bluetooth_start", &json!({})).unwrap()["handle"].as_u64().unwrap();
    let bh = b.call("bluetooth_start", &json!({})).unwrap()["handle"].as_u64().unwrap();
    let ab = android_bridge(ah).unwrap();
    let bb = android_bridge(bh).unwrap();
    let start = Instant::now();
    while ab.radio_state() == 0 || bb.radio_state() == 0 {
        assert!(start.elapsed() < Duration::from_secs(10), "both virtual adapters are requested");
        std::thread::sleep(Duration::from_millis(10));
    }
    ab.set_psm(0);
    bb.set_psm(0);
    assert!(ab.link_up(1, [2, 0, 0, 0, 0, 2], None, false));
    assert!(bb.link_up(1, [2, 0, 0, 0, 0, 1], None, true));
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let pump = runtime.spawn(async move {
        let mut bytes = vec![0; 4096];
        loop {
            for (from, to) in [(&ab, &bb), (&bb, &ab)] {
                let n = from.control_out(1, &mut bytes);
                if n > 0 && to.control_in(1, &bytes[..n]) == AndroidBleIngressAdmission::Accepted {
                    assert!(from.commit_control_out(1));
                }
                let n = from.data_out(1, &mut bytes);
                if n > 0 && to.data_in(1, &bytes[..n]) == AndroidBleIngressAdmission::Accepted {
                    assert!(from.commit_data_out(1));
                }
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    });
    let start = Instant::now();
    while [&a, &b].iter().any(|e| e.call("bluetooth_status", &json!({})).unwrap()["peers"].as_u64().unwrap() == 0) {
        assert!(start.elapsed() < Duration::from_secs(10), "native BLE negotiation creates both data interfaces");
        std::thread::sleep(Duration::from_millis(10));
    }
    a.call("pairing_open", &json!({"name": "BLE Desk", "kind": "computer"})).unwrap();
    b.call("pairing_open", &json!({"name": "BLE Phone", "kind": "phone"})).unwrap();
    let start = Instant::now();
    for e in [&a, &b] {
        loop {
            let nearby = e.call("nearby_list", &json!({})).unwrap();
            let devices = nearby["devices"].as_array().unwrap();
            if !devices.is_empty() {
                assert!(devices.iter().all(|d| d["via"] == "bluetooth"));
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(15), "Nearby discovers the Bluetooth peer without IP");
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    a.call("pairing_close", &json!({})).unwrap();
    b.call("pairing_close", &json!({})).unwrap();
    let code = a.call("link_code", &json!({})).unwrap()["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE-"));
    b.call("link", &json!({"code": code})).unwrap();
    a.call("share_add", &json!({"id": "notebooks", "name": "Notebooks", "path": fa})).unwrap();
    b.call("share_add", &json!({"id": "notebooks", "name": "Notebooks", "path": fb})).unwrap();
    let start = Instant::now();
    while std::fs::read(fb.join("proof.md")).ok().as_deref() != Some(note.as_slice()) {
        assert!(start.elapsed() < Duration::from_secs(30), "Markdown crosses the BLE-only engine path");
        a.call("sync_now", &json!({})).unwrap();
        b.call("sync_now", &json!({})).unwrap();
        std::thread::sleep(Duration::from_millis(200));
    }
    for e in [&a, &b] {
        let status = e.call("status", &json!({})).unwrap();
        assert_eq!(status["ip_network"], false);
        assert_eq!(status["network"], true);
        assert!(status["peers"].as_array().unwrap().iter().any(|p| p["via"] == "bluetooth" && p["live"] == true));
    }
    pump.abort();
    let _ = runtime.block_on(pump);
    a.close();
    b.close();
    assert!(android_bridge(ah).is_none() && android_bridge(bh).is_none());
}
