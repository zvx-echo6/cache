//! Link codes between build 54 and later builds: a device with Reticulum shows a short code, which build 54 rejects (accepted);
//! a new build still reads a `CACHE1-` code from build 54 and links over iroh.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use common::*;
use iroh::EndpointAddr;
use serde::{Deserialize, Serialize};
use serde_json::json;

// Frozen from build-1.1.0-54 (cache_sync/src/lib.rs): the LinkCode struct, its encode and decode_code.
#[derive(Debug, Serialize, Deserialize)]
struct LinkCode {
    a: EndpointAddr,
    t: String,
    n: String,
}

const CODE_PREFIX: &str = "CACHE1-";

fn encode_code(c: &LinkCode) -> String {
    format!("{CODE_PREFIX}{}", data_encoding::BASE32_NOPAD.encode(&serde_json::to_vec(c).unwrap()))
}

fn decode_code(s: &str) -> Result<LinkCode, String> {
    let s: String = s.trim().chars().filter(|c| !c.is_whitespace()).collect::<String>().to_uppercase();
    let Some(body) = s.strip_prefix(CODE_PREFIX) else { return Err("not a code".into()) };
    let bytes = data_encoding::BASE32_NOPAD.decode(body.as_bytes()).map_err(|_| "damaged".to_string())?;
    serde_json::from_slice(&bytes).map_err(|_| "damaged".to_string())
}

#[test]
fn build_54_rejects_a_short_code() {
    // Accepted: a build before 55 cannot link by a short code (its links carry over through iroh).
    let tmp = tempfile::tempdir().unwrap();
    let port = free_port();
    let a = engine(&tmp.path().join("a"), "Desk", Some(port), None, None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE-") && !code.starts_with("CACHE1-"), "{code}");
    assert!(decode_code(&code).is_err(), "build 54 does not read a short code");
    a.close();
}

#[test]
fn a_new_build_reads_a_build_54_code_and_links_over_iroh() {
    let tmp = tempfile::tempdir().unwrap();
    let port = free_port();
    // The shower is a build before Reticulum; the reader is new, with Reticulum on.
    let a = old_engine(&tmp.path().join("a"), "Desk", None);
    let b = engine(&tmp.path().join("b"), "Phone", None, Some(port), None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    // As build 54 writes it: the frozen struct, no `r`.
    let old = encode_code(&decode_code(&code).unwrap());
    assert!(!old.contains("R\""), "no r field");
    let linked = call(&b, "link", json!({"code": old}));
    assert_eq!(linked["name"], "Desk");
    assert_eq!(call(&b, "status", json!({}))["peers"].as_array().unwrap().len(), 1);
    a.close();
    b.close();
}
