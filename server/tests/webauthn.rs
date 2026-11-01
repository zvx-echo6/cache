//! Security keys end to end, through `route`, against a software authenticator written here (an ES256 key made with ring,
//! "none" attestation). webauthn-rs has no soft token of its own, so this is what stands in for a real key: it checks the
//! server's state handling, challenge matching, origin and RP ID checks, replay refusal and the session that follows.
//! What it cannot show is a real key's USB/NFC behaviour or a browser's WebAuthn dialog: that needs hardware.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use cache_server::auth::{Auth, AuthFile, StoredPassword};
use cache_server::http::{route, App, Reply};
use cache_server::keys::build_webauthn;
use cache_server::library::Library;
use ring::digest;
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

const ORIGIN: &str = "https://cache.example.com";
const RP_ID: &str = "cache.example.com";

struct Dir(PathBuf);
impl Dir {
    fn new(tag: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("cache-server-wa-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn b64(b: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(b)
}
fn unb64(s: &str) -> Vec<u8> {
    URL_SAFE_NO_PAD.decode(s).unwrap()
}
fn sha256(b: &[u8]) -> Vec<u8> {
    digest::digest(&digest::SHA256, b).as_ref().to_vec()
}

fn cbor_bytes(out: &mut Vec<u8>, b: &[u8]) {
    match b.len() {
        n if n < 24 => out.push(0x40 | n as u8),
        n if n < 256 => out.extend([0x58, n as u8]),
        n => out.extend([0x59, (n >> 8) as u8, n as u8]),
    }
    out.extend(b);
}

/// A stand-in security key: an ES256 key pair and a credential id.
struct Soft {
    pair: EcdsaKeyPair,
    cred_id: Vec<u8>,
    counter: u32,
}

impl Soft {
    fn new() -> Soft {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        let mut cred_id = vec![0u8; 32];
        rng.fill(&mut cred_id).unwrap();
        Soft { pair, cred_id, counter: 0 }
    }

    /// What `navigator.credentials.create` would give back for these creation options.
    fn register(&self, options: &Value, origin: &str, rp_id: &str) -> Value {
        let pk = &options["publicKey"];
        let challenge = pk["challenge"].as_str().unwrap();
        let client = json!({"type": "webauthn.create", "challenge": challenge, "origin": origin, "crossOrigin": false}).to_string();
        let point = self.pair.public_key().as_ref();
        assert_eq!(point.len(), 65);
        let mut cose = vec![0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20];
        cose.extend(&point[1..33]);
        cose.extend([0x22, 0x58, 0x20]);
        cose.extend(&point[33..65]);
        let mut auth = sha256(rp_id.as_bytes());
        auth.push(0x41); // user present + attested credential data
        auth.extend(self.counter.to_be_bytes());
        auth.extend([0u8; 16]); // aaguid
        auth.extend((self.cred_id.len() as u16).to_be_bytes());
        auth.extend(&self.cred_id);
        auth.extend(cose);
        let mut obj = vec![0xA3, 0x63];
        obj.extend(b"fmt");
        obj.push(0x64);
        obj.extend(b"none");
        obj.push(0x67);
        obj.extend(b"attStmt");
        obj.push(0xA0);
        obj.push(0x68);
        obj.extend(b"authData");
        cbor_bytes(&mut obj, &auth);
        json!({
            "id": b64(&self.cred_id), "rawId": b64(&self.cred_id), "type": "public-key", "extensions": {},
            "response": {"attestationObject": b64(&obj), "clientDataJSON": b64(client.as_bytes())}
        })
    }

    /// What `navigator.credentials.get` would give back for these request options.
    fn assert(&mut self, options: &Value, origin: &str, rp_id: &str) -> Value {
        let pk = &options["publicKey"];
        let challenge = pk["challenge"].as_str().unwrap();
        let allowed: Vec<Vec<u8>> = pk["allowCredentials"].as_array().unwrap().iter().map(|c| unb64(c["id"].as_str().unwrap())).collect();
        assert!(allowed.contains(&self.cred_id), "the server must allow this key");
        let client = json!({"type": "webauthn.get", "challenge": challenge, "origin": origin, "crossOrigin": false}).to_string();
        self.counter += 1;
        let mut auth = sha256(rp_id.as_bytes());
        auth.push(0x01); // user present
        auth.extend(self.counter.to_be_bytes());
        let mut msg = auth.clone();
        msg.extend(sha256(client.as_bytes()));
        let sig = self.pair.sign(&SystemRandom::new(), &msg).unwrap();
        json!({
            "id": b64(&self.cred_id), "rawId": b64(&self.cred_id), "type": "public-key", "extensions": {},
            "response": {"authenticatorData": b64(&auth), "clientDataJSON": b64(client.as_bytes()), "signature": b64(sig.as_ref()), "userHandle": null}
        })
    }
}

struct Rig {
    dir: Dir,
    app: App,
}

fn rig(tag: &str, origin: Option<&str>) -> Rig {
    let dir = Dir::new(tag);
    let file = AuthFile { password: Some(StoredPassword::with_iterations("pw", 1000).unwrap()), ..AuthFile::default() };
    file.save(&dir.0.join("auth.json")).unwrap();
    let wa = build_webauthn(origin).unwrap();
    let auth = Auth::load(&dir.0, true).unwrap().with_webauthn(wa);
    Rig { app: App { auth: Arc::new(auth), helper: None, web: dir.0.join("web"), library: Library::new(dir.0.clone(), None), embed: cache_server::embed::EmbedService::new(dir.0.clone(), dir.0.join("none.so")) }, dir }
}

fn cookie(r: &Reply, name: &str) -> String {
    r.headers.iter().filter(|(k, _)| *k == "Set-Cookie").map(|(_, v)| v.split(';').next().unwrap().to_string()).find(|c| c.starts_with(&format!("{name}="))).unwrap()
}

fn json_of(r: &Reply) -> Value {
    serde_json::from_slice(&r.body).unwrap_or(Value::Null)
}

async fn sign_in(rig: &Rig) -> String {
    let r = route(&rig.app, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
    assert_eq!(r.status, 204);
    cookie(&r, "cache_session")
}

/// Register `key` through the settings API. Returns the session cookie used.
async fn register(rig: &Rig, key: &Soft, name: &str) -> String {
    let c = sign_in(rig).await;
    let r = route(&rig.app, "POST", "/api/settings/security-keys/start", Some(&c), json!({"name": name}).to_string().as_bytes()).await;
    assert_eq!(r.status, 200, "{}", String::from_utf8_lossy(&r.body));
    let v = json_of(&r);
    let pk = &v["result"]["options"]["publicKey"];
    assert_eq!(pk["rp"]["id"], RP_ID);
    assert_ne!(pk["authenticatorSelection"]["userVerification"], "required", "one touch: presence only");
    let cred = key.register(&v["result"]["options"], ORIGIN, RP_ID);
    let r = route(&rig.app, "POST", "/api/settings/security-keys/finish", Some(&c), json!({"id": v["result"]["id"], "credential": cred}).to_string().as_bytes()).await;
    assert_eq!(r.status, 200, "{}", String::from_utf8_lossy(&r.body));
    c
}

async fn start(rig: &Rig, cookie: Option<&str>) -> (u16, Value) {
    let r = route(&rig.app, "POST", "/auth/webauthn/start", cookie, b"").await;
    (r.status, json_of(&r))
}

async fn finish(rig: &Rig, cookie: Option<&str>, id: &Value, cred: &Value) -> Reply {
    route(&rig.app, "POST", "/auth/webauthn/finish", cookie, json!({"id": id, "credential": cred}).to_string().as_bytes()).await
}

#[tokio::test]
async fn register_then_sign_in_with_a_security_key() {
    let rig = rig("basic", Some(ORIGIN));
    let mut key = Soft::new();
    // nothing registered: not available, and the start endpoint says so
    assert_eq!(json_of(&route(&rig.app, "GET", "/auth/state", None, b"").await)["security_key_available"], false);
    rig.app.auth.set_signin(cache_server::auth::Mode::Either, false).unwrap();
    assert_eq!(start(&rig, None).await.0, 404);
    let c = register(&rig, &key, "YubiKey 5C").await;
    let view = json_of(&route(&rig.app, "GET", "/api/settings/signin", Some(&c), b"").await);
    assert_eq!(view["result"]["security_keys"][0]["name"], "YubiKey 5C");
    assert_eq!(view["result"]["webauthn_available"], true);
    assert_eq!(json_of(&route(&rig.app, "GET", "/auth/state", None, b"").await)["security_key_available"], true);
    // the stored credential is in auth.json, with no private part (there is none)
    assert!(std::fs::read_to_string(rig.dir.0.join("auth.json")).unwrap().contains("YubiKey 5C"));

    // sign in: start, touch, finish
    let (s, v) = start(&rig, None).await;
    assert_eq!(s, 200);
    let cred = key.assert(&v["options"], ORIGIN, RP_ID);
    let r = finish(&rig, None, &v["id"], &cred).await;
    assert_eq!(r.status, 204);
    let session = cookie(&r, "cache_session");
    assert_eq!(route(&rig.app, "GET", "/auth/check", Some(&session), b"").await.status, 204);
    // last used was noted
    let view = json_of(&route(&rig.app, "GET", "/api/settings/signin", Some(&session), b"").await);
    assert!(view["result"]["security_keys"][0]["last_used"].is_u64());
    // an answer is good once: the same one again is refused
    assert_eq!(finish(&rig, None, &v["id"], &cred).await.status, 401);
    // and it does not work against a new challenge (replay)
    let (_, v2) = start(&rig, None).await;
    assert_eq!(finish(&rig, None, &v2["id"], &cred).await.status, 401);
    // the next touch signs in again (the counter went up)
    let (_, v3) = start(&rig, None).await;
    let cred3 = key.assert(&v3["options"], ORIGIN, RP_ID);
    assert_eq!(finish(&rig, None, &v3["id"], &cred3).await.status, 204);
}

#[tokio::test]
async fn a_wrong_key_wrong_origin_or_unknown_challenge_is_refused() {
    let rig = rig("wrong", Some(ORIGIN));
    let key = Soft::new();
    register(&rig, &key, "k").await;
    rig.app.auth.set_signin(cache_server::auth::Mode::Key, false).unwrap();
    // a different key that claims the same credential id (signs with another private key)
    let mut impostor = Soft::new();
    impostor.cred_id = key.cred_id.clone();
    let (_, v) = start(&rig, None).await;
    let bad = impostor.assert(&v["options"], ORIGIN, RP_ID);
    let r = finish(&rig, None, &v["id"], &bad).await;
    assert_eq!(r.status, 401);
    assert!(!r.headers.iter().any(|(k, _)| *k == "Set-Cookie"));
    // the right key on the wrong origin (each wrong answer waits longer than the one before)
    let mut key = key;
    let (_, v) = start(&rig, None).await;
    let evil = key.assert(&v["options"], "https://evil.example.net", RP_ID);
    assert_eq!(finish(&rig, None, &v["id"], &evil).await.status, 401);
    // an unknown challenge id
    let (_, v) = start(&rig, None).await;
    let ok = key.assert(&v["options"], ORIGIN, RP_ID);
    assert_eq!(finish(&rig, None, &json!("not-a-challenge"), &ok).await.status, 401);
    // garbage credential
    assert_eq!(finish(&rig, None, &v["id"], &json!({"id": 1})).await.status, 400);
}

#[tokio::test]
async fn in_mode_both_the_key_endpoints_need_the_half_cookie_and_it_completes_the_session() {
    let rig = rig("both", Some(ORIGIN));
    let mut key = Soft::new();
    register(&rig, &key, "k").await;
    rig.app.auth.set_signin(cache_server::auth::Mode::Both, false).unwrap();
    assert_eq!(start(&rig, None).await.0, 409);
    let r = route(&rig.app, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
    assert_eq!(r.status, 200);
    let half = cookie(&r, "cache_half");
    assert_eq!(route(&rig.app, "GET", "/auth/check", Some(&half), b"").await.status, 401);
    let (s, v) = start(&rig, Some(&half)).await;
    assert_eq!(s, 200);
    let cred = key.assert(&v["options"], ORIGIN, RP_ID);
    // without the half cookie the finish is refused even with a good answer
    assert_eq!(finish(&rig, None, &v["id"], &cred).await.status, 409);
    // (that did not use up the challenge) with it, the session starts
    let (_, v) = start(&rig, Some(&half)).await;
    let cred = key.assert(&v["options"], ORIGIN, RP_ID);
    let r = finish(&rig, Some(&half), &v["id"], &cred).await;
    assert_eq!(r.status, 204);
    let session = cookie(&r, "cache_session");
    assert_eq!(route(&rig.app, "GET", "/auth/check", Some(&session), b"").await.status, 204);
    // the half is spent
    assert_eq!(start(&rig, Some(&half)).await.0, 409);
}

#[tokio::test]
async fn the_last_security_key_cannot_be_removed_while_a_key_is_required() {
    let rig = rig("guard", Some(ORIGIN));
    let key = Soft::new();
    let c = register(&rig, &key, "only").await;
    assert_eq!(route(&rig.app, "PUT", "/api/settings/signin", Some(&c), br#"{"mode":"key"}"#).await.status, 200);
    let view = json_of(&route(&rig.app, "GET", "/api/settings/signin", Some(&c), b"").await);
    let id = view["result"]["security_keys"][0]["id"].as_str().unwrap().to_string();
    let r = route(&rig.app, "DELETE", &format!("/api/settings/security-keys/{id}"), Some(&c), b"").await;
    assert_eq!((r.status, json_of(&r)["error"]["code"].clone()), (409, json!("locked_out")));
    assert_eq!(route(&rig.app, "PUT", "/api/settings/signin", Some(&c), br#"{"mode":"either"}"#).await.status, 200);
    assert_eq!(route(&rig.app, "DELETE", &format!("/api/settings/security-keys/{id}"), Some(&c), b"").await.status, 200);
    let view = json_of(&route(&rig.app, "GET", "/api/settings/signin", Some(&c), b"").await);
    assert_eq!(view["result"]["security_keys"].as_array().unwrap().len(), 0);
    // registering the same key twice is refused
    register(&rig, &key, "again").await;
    let r = route(&rig.app, "POST", "/api/settings/security-keys/start", Some(&c), br#"{"name":"dup"}"#).await;
    let v = json_of(&r);
    let cred = key.register(&v["result"]["options"], ORIGIN, RP_ID);
    let r = route(&rig.app, "POST", "/api/settings/security-keys/finish", Some(&c), json!({"id": v["result"]["id"], "credential": cred}).to_string().as_bytes()).await;
    assert_eq!(r.status, 400);
}

#[tokio::test]
async fn without_a_host_name_security_keys_are_off() {
    for origin in [None, Some("https://203.0.113.7:8443"), Some("http://cache.example.com")] {
        let rig = rig("off", origin);
        let c = sign_in(&rig).await;
        let r = route(&rig.app, "POST", "/api/settings/security-keys/start", Some(&c), br#"{"name":"yk"}"#).await;
        assert_eq!((r.status, json_of(&r)["error"]["code"].clone()), (409, json!("needs_hostname")), "{origin:?}");
        let view = json_of(&route(&rig.app, "GET", "/api/settings/signin", Some(&c), b"").await);
        assert_eq!(view["result"]["webauthn_available"], false);
        assert_eq!(json_of(&route(&rig.app, "GET", "/auth/state", None, b"").await)["security_key_available"], false);
    }
}
