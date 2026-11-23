//! Link codes between build 54 and later builds: the format stays `CACHE1-` and base32 JSON; a code from a new build still
//! decodes as build 54 reads it, and a new build reads a code from build 54 and links over iroh.
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
fn build_54_reads_a_new_code() {
    let tmp = tempfile::tempdir().unwrap();
    let port = free_port();
    let a = engine(&tmp.path().join("a"), "Desk", Some(port), None, None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE1-"));
    // The new code does carry the Reticulum destination...
    let body = data_encoding::BASE32_NOPAD.decode(code.trim_start_matches("CACHE1-").as_bytes()).unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["r"]["d"].as_str().map(str::len), Some(32), "{v}");
    // ...and build 54's decoder still reads it (the unknown field is ignored).
    let old = decode_code(&code).expect("build 54 decodes a new code");
    assert_eq!(old.n, "Desk");
    assert!(!old.t.is_empty());
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
