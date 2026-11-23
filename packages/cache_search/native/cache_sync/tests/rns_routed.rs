//! Two engines connected only through a Prns transport node (what rnsd is on a real network): there is no connection between
//! them. They link with a short code over Reticulum (a path request and a routed link, no iroh address in the code) and sync a file.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use common::*;
use serde_json::json;

#[test]
fn two_devices_sync_through_a_transport_node() {
    let tmp = tempfile::tempdir().unwrap();
    let (db, da) = (tmp.path().join("b"), tmp.path().join("a"));
    let (fb, fa) = (tmp.path().join("folder-b"), tmp.path().join("folder-a"));
    std::fs::create_dir_all(&fb).unwrap();
    std::fs::write(fb.join("routed.txt"), "through a transport node").unwrap();
    let big = random(5_000_000, 3);
    std::fs::write(fb.join("routed.bin"), &big).unwrap();

    // B listens; the transport node listens for A and connects to B; A connects only to the transport node.
    let (port_b, port_mid) = (free_port(), free_port());
    rns_only_dirs(&[&db, &da]);
    let b = engine(&db, "Desk", Some(port_b), None, None);
    let _mid = node::transport(port_mid, port_b);
    let a = engine(&da, "Phone", None, Some(port_mid), None);

    // The node and the devices have all come up: each announces again (as it does on a network change), so the node knows
    // the way to both.
    std::thread::sleep(std::time::Duration::from_secs(3));
    call(&b, "network_changed", json!({}));
    call(&a, "network_changed", json!({}));
    std::thread::sleep(std::time::Duration::from_secs(3));

    let code = call(&b, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE-") && !code.starts_with("CACHE1-"), "a short code: {code}");
    let linked = call(&a, "link", json!({"code": code}));
    assert_eq!(linked["name"], "Desk");

    let id = call(&b, "share_add", json!({"path": fb, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&a, "sync_now", json!({}));
    wait("the offer on A", 90, || call(&a, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&a, "share_join", json!({"id": id, "path": fa}));
    call(&a, "sync_now", json!({}));
    wait("the files on A", 90, || fa.join("routed.txt").exists() && fa.join("routed.bin").exists());
    assert_eq!(std::fs::read(fa.join("routed.bin")).unwrap(), big);
    assert_eq!(std::fs::read_to_string(fa.join("routed.txt")).unwrap(), "through a transport node");
    assert_eq!(via(&a, "Desk").as_deref(), Some("reticulum"), "carried over Reticulum, not Wi-Fi");
    a.close();
    b.close();
}
