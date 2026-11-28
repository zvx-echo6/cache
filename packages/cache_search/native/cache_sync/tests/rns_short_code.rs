//! The short link code (build 55): `CACHE-` and 34 base32 characters (the device's Reticulum destination, then a 5 byte
//! one-time secret). Strikes, expiry, one use and forged signatures, over Reticulum between engines on loopback TCP.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use common::*;
use serde_json::{json, Value};

const MIN15: u64 = 15 * 60 * 1000;

fn peers(e: &cache_sync::SyncEngine) -> usize {
    call(e, "status", json!({}))["peers"].as_array().unwrap().len()
}

/// A shower and an enterer on one loopback network.
fn pair(tmp: &std::path::Path) -> (cache_sync::SyncEngine, cache_sync::SyncEngine, u16) {
    let port = free_port();
    let a = engine(&tmp.join("a"), "Desk", Some(port), None, None);
    let b = engine(&tmp.join("b"), "Phone", None, Some(port), None);
    (a, b, port)
}

#[test]
fn the_code_is_short_and_round_trips() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _) = pair(tmp.path());
    let shown = call(&a, "link_code", json!({}));
    let code = shown["code"].as_str().unwrap().to_string();
    assert_eq!(shown["valid_secs"], 900);
    let (dest, secret) = short_parts(&code);
    assert_eq!((dest.len(), secret.len()), (16, 5));
    assert_eq!(short_code(&dest, &secret), code, "written the way it is shown");
    println!("RESULT short_code {code} len={}", code.len());
    // Case, spaces, dashes and the prefix's dash do not matter.
    let loose = code.to_lowercase().replace("cache-", "cache ").replace('-', " ");
    let linked = call(&b, "link", json!({"code": format!("  {loose}\n")}));
    assert_eq!(linked["name"], "Desk");
    assert_eq!(peers(&a), 1);
    assert_eq!(peers(&b), 1);
    a.close();
    b.close();
}

#[test]
fn a_wrong_secret_is_refused_and_three_burn_the_code() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _) = pair(tmp.path());
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    let (dest, secret) = short_parts(&code);
    let mut wrong = secret.clone();
    wrong[0] ^= 0x55;
    let bad = short_code(&dest, &wrong);
    for _ in 0..2 {
        let e = b.call("link", &json!({"code": bad})).expect_err("a wrong secret is refused");
        assert!(format!("{e:#}").contains("not right"), "{e:#}");
    }
    assert_eq!(peers(&a) + peers(&b), 0);
    // Two strikes: the right one still works... but this test burns it first, so show it on a second code below.
    let e = b.call("link", &json!({"code": bad})).expect_err("the third");
    assert!(format!("{e:#}").contains("not right"), "{e:#}");
    // Burned: the right secret fails now too.
    let e = b.call("link", &json!({"code": code})).expect_err("a burned code is refused");
    assert!(format!("{e:#}").contains("not being shown any more"), "{e:#}");
    assert_eq!(peers(&a) + peers(&b), 0);
    // Two wrong ones do not burn it.
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    let (_, secret) = short_parts(&code);
    let mut wrong = secret.clone();
    wrong[4] ^= 1;
    for _ in 0..2 {
        assert!(b.call("link", &json!({"code": short_code(&dest, &wrong)})).is_err());
    }
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");
    a.close();
    b.close();
}

#[test]
fn the_code_runs_out_after_fifteen_minutes() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _) = pair(tmp.path());
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(call(&a, "status", json!({}))["showing_code"].as_u64().unwrap() > 880);
    call(&a, "test_skew_code_clock", json!({"ms": MIN15 - 5_000}));
    assert!(call(&a, "status", json!({}))["showing_code"].as_u64().unwrap() <= 5);
    call(&a, "test_skew_code_clock", json!({"ms": MIN15 + 1_000}));
    assert!(call(&a, "status", json!({}))["showing_code"].is_null());
    let e = b.call("link", &json!({"code": code})).expect_err("an old code is refused");
    assert!(format!("{e:#}").contains("not being shown any more"), "{e:#}");
    assert_eq!(peers(&a) + peers(&b), 0);
    a.close();
    b.close();
}

#[test]
fn a_code_works_once() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, port) = pair(tmp.path());
    let c = engine(&tmp.path().join("c"), "Other", None, Some(port), None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");
    let e = c.call("link", &json!({"code": code})).expect_err("the second use is refused");
    assert!(format!("{e:#}").contains("not being shown any more"), "{e:#}");
    assert_eq!(peers(&c), 0);
    assert_eq!(peers(&a), 1);
    a.close();
    b.close();
    c.close();
}

#[test]
fn a_forged_signature_is_refused_and_does_not_burn_the_code() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _) = pair(tmp.path());
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    let (dest, secret) = short_parts(&code);
    let who = call(&b, "status", json!({}))["id"].as_str().unwrap().to_string();
    let hex: String = dest.iter().map(|b| format!("{b:02x}")).collect();
    // The right secret, a device key, and a signature that is not that key's over the destination.
    let forged = |sig: &str| {
        json!({"secret": data_encoding::BASE32_NOPAD.encode(&secret), "hello": {"key": who, "name": "Evil", "rns": {"dest": hex, "sig": sig}}})
    };
    for sig in ["00".repeat(64), "zz".to_string(), String::new()] {
        let r: Value = call(&a, "test_pair_short_raw", json!({"body": forged(&sig)}));
        assert_eq!(r["ok"], false, "{r}");
        assert!(r["error"].as_str().unwrap().contains("signature"), "{r}");
    }
    assert_eq!(peers(&a), 0, "nothing was stored");
    // The code was not used up: the real device links with it.
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");
    a.close();
    b.close();
}
