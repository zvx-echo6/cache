//! Redirects are followed by the request code itself, one checked hop at a time (request.rs, `redirect_target`): https never
//! becomes http, a request that carries a key goes on only to hosts its definition names, and every hop counts against the
//! quota. The client's own following kept every header but `Authorization` and `Cookie`, so a key in another header went to
//! whatever host a redirect named.
//!
//! Everything here runs against servers on this machine, where plain http is allowed: another port stands in for another host
//! (a host is its name and port). The https rules themselves are in request.rs's own test of `redirect_target`.

use cache_live::{Live, LiveCfg};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

const T0: &str = "2026-11-07T12:40:00-07:00";
/// A key no other host, error or log line may get.
const KEY: &str = "SENTINEL-REDIRECT-KEY-63fe-do-not-leak";

fn fixture(name: &str) -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

/// A server on this machine: `reply` makes the raw answer from the request's head, and every head is noted.
struct Srv {
    port: u16,
    seen: Arc<Mutex<Vec<String>>>,
}

impl Srv {
    fn start(reply: impl Fn(&str) -> String + Send + 'static) -> Srv {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let s = Srv { port: l.local_addr().unwrap().port(), seen: Arc::default() };
        let seen = s.seen.clone();
        std::thread::spawn(move || {
            for c in l.incoming() {
                let Ok(mut c) = c else { break };
                let mut raw = Vec::new();
                let mut buf = [0u8; 2048];
                while !raw.windows(4).any(|w| w == b"\r\n\r\n") {
                    match c.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => raw.extend_from_slice(&buf[..n]),
                    }
                }
                let head = String::from_utf8_lossy(&raw).into_owned();
                let answer = reply(&head);
                seen.lock().unwrap().push(head);
                let _ = c.write_all(answer.as_bytes());
            }
        });
        s
    }
    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
    fn seen(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }
}

/// The recorded gauge answer.
fn ok() -> String {
    let body = fixture("own_source_response.json");
    format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
}

fn redirect(to: &str) -> String {
    format!("HTTP/1.1 302 Found\r\nLocation: {to}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
}

/// The creek gauge definition at `base`. With `keyed` it needs its key, in the address (as the fixture has it) and, with
/// `header`, in a request header too; without, it has no key at all.
fn definition(base: &str, keyed: bool, header: bool) -> Value {
    let mut d: Value = serde_json::from_str(&fixture("own_source_def.json")).unwrap();
    if keyed {
        d["request"]["url"] = json!(format!("{base}/api/creek?site=12&lat={{lat}}&lon={{lon}}&key={{api_key}}"));
        if header {
            d["request"]["headers"] = json!({"X-Api-Key": "{api_key}"});
        }
    } else {
        d["request"]["url"] = json!(format!("{base}/api/creek?site=12&lat={{lat}}&lon={{lon}}"));
        d.as_object_mut().unwrap().remove("api_key");
    }
    d
}

/// One download as `cs_live_preview` makes it (the request code of every fetch; nothing stored).
fn run(def: &Value, keyed: bool) -> Result<Value, cache_live::Error> {
    let mut req = json!({"definition": def, "place": {"lat": 42.536, "lon": -113.792, "name": "Burley, ID"}, "now": T0});
    if keyed {
        req["api_key"] = json!(KEY);
    }
    cache_live::preview::preview(&req.to_string()).map(|s| serde_json::from_str(&s).unwrap())
}

#[test]
fn a_key_is_not_carried_to_a_host_the_definition_does_not_name() {
    for header in [true, false] {
        let other = Srv::start(|_| ok());
        let to = format!("{}/api/creek", other.base());
        let first = Srv::start(move |_| redirect(&to));
        let e = run(&definition(&first.base(), true, header), true).unwrap_err();
        assert_eq!(e.code, "fetch_failed", "{e:?}");
        assert!(e.message.contains("which the definition does not name; not followed with the key"), "{e:?}");
        assert!(!e.message.contains(KEY), "{e:?}");
        assert_eq!(first.seen().len(), 1);
        assert_eq!(first.seen()[0].to_ascii_lowercase().contains(&format!("x-api-key: {}", KEY.to_ascii_lowercase())), header, "the first host is the definition's own");
        assert!(other.seen().is_empty(), "the other host was asked: {:?}", other.seen());
    }
}

#[test]
fn a_redirect_on_the_same_host_is_followed_with_the_key() {
    let srv = Srv::start(|head| if head.starts_with("GET /api/creek") { redirect("/v2/creek?moved=1") } else { ok() });
    let v = run(&definition(&srv.base(), true, true), true).unwrap();
    assert!(v.get("mapping_error").is_none(), "{v}");
    assert_eq!(v["items"][0]["label"], "Water level 1.42");
    let seen = srv.seen();
    assert_eq!(seen.len(), 2, "{seen:?}");
    assert!(seen[1].starts_with("GET /v2/creek?moved=1 "), "{seen:?}");
    assert!(seen[1].to_ascii_lowercase().contains(&format!("x-api-key: {}", KEY.to_ascii_lowercase())), "the key stays with its host");
    // both requests are in the request list, the key scrubbed from the address
    let listed = v["requests"].as_array().unwrap();
    assert_eq!(listed.iter().map(|r| r["status"].as_u64().unwrap()).collect::<Vec<_>>(), [302, 200]);
    assert!(!v.to_string().contains(KEY));
}

#[test]
fn without_a_key_a_redirect_to_another_host_is_followed() {
    let other = Srv::start(|_| ok());
    let to = format!("{}/elsewhere", other.base());
    let first = Srv::start(move |_| redirect(&to));
    let v = run(&definition(&first.base(), false, false), false).unwrap();
    assert_eq!(v["items"][0]["label"], "Water level 1.42");
    assert_eq!((first.seen().len(), other.seen().len()), (1, 1));
    assert!(other.seen()[0].starts_with("GET /elsewhere "));
}

#[test]
fn a_redirect_to_plain_http_elsewhere_is_refused_with_a_key_and_without() {
    for keyed in [true, false] {
        // 192.0.2.1 is a documentation address: it is refused by the rule, before anything connects
        let first = Srv::start(|_| redirect("http://192.0.2.1/api/creek"));
        let t = std::time::Instant::now();
        let e = run(&definition(&first.base(), keyed, keyed), keyed).unwrap_err();
        assert_eq!(e.code, "fetch_failed", "{e:?}");
        assert!(e.message.contains("not https"), "{e:?}");
        assert!(t.elapsed().as_secs() < 5, "nothing was connected to");
        assert_eq!(first.seen().len(), 1);
    }
}

#[test]
fn a_chain_of_redirects_ends_after_five() {
    let srv = Srv::start(|_| redirect("/again"));
    let e = run(&definition(&srv.base(), false, false), false).unwrap_err();
    assert_eq!((e.code, e.message.as_str()), ("fetch_failed", "more than 5 redirects"));
    assert_eq!(srv.seen().len(), 6, "the request and five redirects");
}

#[test]
fn every_hop_counts_against_the_quota() {
    let srv = Srv::start(|head| {
        if head.starts_with("GET /api/creek") {
            redirect("/a")
        } else if head.starts_with("GET /a ") {
            redirect("/b")
        } else {
            ok()
        }
    });
    let mut d = definition(&srv.base(), false, false);
    d["quota"] = json!({"per_minute": 2});
    let dir = std::env::temp_dir().join(format!("cache-live-redirects-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sources")).unwrap();
    std::fs::write(dir.join("sources/own-creek-level-at-the-bridge.json"), d.to_string()).unwrap();
    let live = Live::new(LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy()));
    let places = UserStore::new(dir.join("user.sqlite"));
    let (_, errors) = live.defs();
    assert!(errors.is_empty(), "{errors:?}");
    let req = json!({"source": "own-creek-level-at-the-bridge", "place": {"key": "burley", "name": "Burley, ID", "lat": 42.536, "lon": -113.792}, "now": T0});
    let e = live.fetch(&req.to_string(), &places).unwrap_err();
    assert_eq!(e.code, "quota", "{e:?}");
    assert_eq!(srv.seen().len(), 2, "the third request (the second redirect) was over the limit and never sent");
    let _ = std::fs::remove_dir_all(&dir);
}
