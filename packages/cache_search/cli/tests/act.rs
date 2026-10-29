//! `cs serve` playing the host of the act tool: `--actions`, `--action-results` and the `/act/*` endpoints.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-clitest-act-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
    fn write(&self, f: &str, content: &str) -> String {
        let p = self.0.join(f);
        std::fs::write(&p, content).unwrap();
        p.to_string_lossy().into_owned()
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn defs() -> Value {
    json!([
        {"id":"places.save","module":"places","title":"Save a place","description":"Save a place to the user's saved places.","effect":"change",
         "fields":{"name":{"type":"string","maxLength":80},"place":{"type":"place"},"note":{"type":"string","maxLength":500}},"required":["name","place"]},
        {"id":"places.list","module":"places","title":"List places","description":"The user's saved places.","effect":"read","fields":{}},
        {"id":"places.open","module":"places","title":"Open guidance","description":"Open guidance to a place.","effect":"open","fields":{"to":{"type":"place"}},"required":["to"]},
        {"id":"places.delete","module":"places","title":"Delete a place","description":"Delete a saved place.","effect":"change","fields":{"name":{"type":"string"}},"required":["name"]},
        {"id":"home.source_switch","module":"home","title":"Switch a source","description":"Turn a Home data source on or off.","effect":"change",
         "fields":{"source":{"type":"string","enum":["wildfires","alerts","weather"]},"on":{"type":"boolean"}},"required":["source","on"]},
        {"id":"bad id","module":"x","title":"T","description":"D","effect":"read"}
    ])
}

fn results() -> Value {
    json!({
        "run": {"places.list": {"ok": true, "result": {"places": [{"address": "place:home", "name": "Home"}]}},
                "places.open": {"ok": false, "error": {"type": "unavailable", "detail": "Maps is not installed"}}},
        "tap": {"places.save": {"status": "done", "result": {"saved": "Elk camp"}},
                "places.delete": {"status": "declined"},
                "home.source_switch": {"status": "failed", "error": {"type": "denied", "detail": "location is off"}}}
    })
}

struct Serve {
    child: Child,
    addr: String,
    stderr_line: String,
    _tmp: TempDir,
}

impl Serve {
    fn start(name: &str, extra: impl FnOnce(&TempDir) -> Vec<String>) -> Serve {
        let tmp = TempDir::new(name);
        let cfg = tmp.write("sources.json", &json!({"sources": [], "user": {"db_path": tmp.0.join("user.sqlite").to_string_lossy()}}).to_string());
        let args = extra(&tmp);
        let mut child = Command::new(env!("CARGO_BIN_EXE_cs"))
            .arg("serve")
            .args(["--config", &cfg, "--listen", "127.0.0.1:0"])
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn cs serve");
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).expect("listening line");
        let addr = line.trim().strip_prefix("listening ").unwrap_or_else(|| panic!("unexpected first line {line:?}")).to_string();
        // with --actions the report is written before the listening line, so it is already there; without, nothing is
        let mut stderr_line = String::new();
        if args.iter().any(|a| a == "--actions") {
            BufReader::new(child.stderr.as_mut().unwrap()).read_line(&mut stderr_line).expect("stderr line");
        }
        Serve { child, addr, stderr_line, _tmp: tmp }
    }

    fn with_host(name: &str) -> Serve {
        Serve::start(name, |t| {
            vec!["--actions".into(), t.write("defs.json", &defs().to_string()), "--action-results".into(), t.write("results.json", &results().to_string())]
        })
    }

    fn req(&self, method: &str, path: &str, body: Option<&Value>) -> (u16, String) {
        let mut s = TcpStream::connect(&self.addr).unwrap();
        let b = body.map(|b| b.to_string()).unwrap_or_default();
        write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{b}", b.len()).unwrap();
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).unwrap();
        let text = String::from_utf8(raw).unwrap();
        let (head, body) = text.split_once("\r\n\r\n").expect("http response");
        (head.split_whitespace().nth(1).unwrap().parse().unwrap(), body.to_string())
    }

    fn conv(&self) -> String {
        let (code, b) = self.req("POST", "/conversations", None);
        assert_eq!(code, 200);
        serde_json::from_str::<Value>(&b).unwrap()["id"].as_str().unwrap().to_string()
    }

    /// The content of an `act` call, as the string the model would see.
    fn act(&self, conv: &str, args: Value) -> String {
        let (code, b) = self.req("POST", &format!("/conversations/{conv}/tool"), Some(&json!({"name": "act", "args": args, "now": "2026-10-29T12:00:00-06:00"})));
        assert_eq!(code, 200, "{b}");
        serde_json::from_str::<Value>(&b).unwrap()["content"].as_str().unwrap().to_string()
    }
}

impl Drop for Serve {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn j(s: &str) -> Value {
    serde_json::from_str(s).unwrap_or_else(|e| panic!("{e}: {s}"))
}

#[test]
fn actions_are_installed_at_start_and_the_report_is_on_stderr() {
    let s = Serve::with_host("start");
    let line = s.stderr_line.trim();
    let report = j(line.strip_prefix("actions ").unwrap_or_else(|| panic!("{line}")));
    assert_eq!(report["accepted"], 5);
    assert_eq!(report["rejected"][0]["reason"], "bad_id");
    let (_, tools) = s.req("GET", "/tools", None);
    let names: Vec<String> = j(&tools).as_array().unwrap().iter().map(|t| t["function"]["name"].as_str().unwrap().to_string()).collect();
    assert_eq!(names, ["search", "read", "calculate", "act"]);
}

#[test]
fn a_whole_conversation_runs_headless_through_the_scripted_host() {
    let s = Serve::with_host("flow");
    let c = s.conv();

    // a read: host_run, then the scripted reply finishes it, with the address numbered
    let run = s.act(&c, json!({"action": "places.list"}));
    assert_eq!(run, r#"{"ok":true,"status":"host_run","run_id":"r1","action":"places.list","fields":{}}"#);
    let (code, done) = s.req("POST", &format!("/conversations/{c}/act/finish"), Some(&json!({"run_id": "r1"})));
    assert_eq!((code, done.as_str()), (200, r#"{"ok":true,"status":"done","action":"places.list","result":{"places":[{"n":1,"name":"Home"}]}}"#));
    let (_, ids) = s.req("GET", &format!("/conversations/{c}/ids"), None);
    assert_eq!(ids, r#"{"ids":[{"n":1,"address":"place:home","title":"Home"}]}"#);

    // a change: a card, then the scripted tap
    let card = s.act(&c, json!({"action": "places.save", "fields": {"name": "Elk camp", "place": "44.21,-114.93"}}));
    assert_eq!(
        card,
        r#"{"ok":true,"status":"needs_confirmation","confirm_id":"c1","action":"places.save","title":"Save a place","summary":{"name":"Elk camp","place":"44.21000, -114.93000"}}"#
    );
    let (code, out) = s.req("POST", &format!("/conversations/{c}/act/outcome"), Some(&json!({"confirm_id": "c1"})));
    assert_eq!(
        (code, out.as_str()),
        (200, r#"{"host_event":"act_outcome","ok":true,"status":"done","confirm_id":"c1","action":"places.save","result":{"saved":"Elk camp"}}"#)
    );
    // declined and failed taps
    s.act(&c, json!({"action": "places.delete", "fields": {"name": "Elk camp"}}));
    let (_, out) = s.req("POST", &format!("/conversations/{c}/act/outcome"), Some(&json!({"confirm_id": "c2"})));
    assert_eq!(out, r#"{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c2","action":"places.delete"}"#);
    s.act(&c, json!({"action": "home.source_switch", "fields": {"source": "alerts", "on": true}}));
    let (_, out) = s.req("POST", &format!("/conversations/{c}/act/outcome"), Some(&json!({"confirm_id": "c3"})));
    assert_eq!(out, r#"{"host_event":"act_outcome","ok":false,"status":"failed","confirm_id":"c3","action":"home.source_switch","error":{"type":"denied","detail":"location is off"}}"#);

    // a scripted failure of a run
    s.act(&c, json!({"action": "places.open", "fields": {"to": "44.2,-114.9"}}));
    let (_, out) = s.req("POST", &format!("/conversations/{c}/act/finish"), Some(&json!({"run_id": "r2"})));
    assert_eq!(out, r#"{"ok":false,"error":{"type":"unavailable","detail":"Maps is not installed"}}"#);

    // a bad call is content, like any tool failure
    assert_eq!(
        s.act(&c, json!({"action": "places.save", "fields": {"name": "x"}})),
        r#"{"ok":false,"error":{"type":"bad_arguments","detail":"place: required","field":"place","reason":"missing"}}"#
    );
}

#[test]
fn a_reply_or_an_outcome_can_be_given_instead_of_the_script() {
    let s = Serve::with_host("explicit");
    let c = s.conv();
    s.act(&c, json!({"action": "places.list"}));
    let (code, out) = s.req("POST", &format!("/conversations/{c}/act/finish"), Some(&json!({"run_id": "r1", "reply": {"ok": true, "result": {"places": []}}})));
    assert_eq!((code, out.as_str()), (200, r#"{"ok":true,"status":"done","action":"places.list","result":{"places":[]}}"#));
    let o = json!({"ok": true, "status": "declined", "confirm_id": "c9", "action": "whatever.x"});
    let (code, out) = s.req("POST", &format!("/conversations/{c}/act/outcome"), Some(&json!({"outcome": o})));
    assert_eq!((code, out.as_str()), (200, r#"{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c9","action":"whatever.x"}"#));
    // a card for an action with no scripted tap needs the outcome given
    s.act(&c, json!({"action": "places.save", "fields": {"name": "x", "place": "1,2"}}));
    let (code, _) = s.req("POST", &format!("/conversations/{c}/act/outcome"), Some(&json!({"confirm_id": "c1", "action": "nothing.here"})));
    assert_eq!(code, 404);
}

#[test]
fn finishing_what_was_not_handed_out_is_refused() {
    let s = Serve::with_host("refused");
    let (a, b) = (s.conv(), s.conv());
    s.act(&a, json!({"action": "places.list"}));
    // another conversation, an unknown run, a run finished twice, a malformed reply
    let fin = |c: &str, body: Value| s.req("POST", &format!("/conversations/{c}/act/finish"), Some(&body));
    let (code, body) = fin(&b, json!({"run_id": "r1"}));
    assert_eq!(code, 404, "{body}");
    assert_eq!(j(&body)["code"], "not_found");
    let (code, _) = fin(&b, json!({"run_id": "r1", "reply": {"ok": true, "result": {}}}));
    assert_eq!(code, 404);
    let (code, body) = fin(&a, json!({"run_id": "r1", "reply": {"ok": true}}));
    assert_eq!((code, j(&body)["code"].as_str().unwrap().to_string()), (400, "bad_json".to_string()));
    assert_eq!(fin(&a, json!({"run_id": "r1"})).0, 200);
    let (code, body) = fin(&a, json!({"run_id": "r1"}));
    assert_eq!(code, 404, "{body}");
    assert!(j(&body)["message"].as_str().unwrap().contains("already finished"), "{body}");
    assert_eq!(fin("c99", json!({"run_id": "r1"})).0, 404);
    assert_eq!(s.req("POST", &format!("/conversations/{a}/act/outcome"), Some(&json!({"outcome": {"status": "done"}}))).0, 400);
    assert_eq!(s.req("POST", &format!("/conversations/{a}/act/outcome"), Some(&json!({"confirm_id": "c7"}))).0, 404);
}

#[test]
fn the_endpoints_mirror_the_definition_calls() {
    let s = Serve::start("endpoints", |_| vec![]);
    assert_eq!(s.stderr_line, "");
    let (_, tools) = s.req("GET", "/tools", None);
    assert_eq!(j(&tools).as_array().unwrap().len(), 3);
    let (code, report) = s.req("POST", "/act/definitions", Some(&defs()));
    assert_eq!(code, 200, "{report}");
    assert_eq!(j(&report)["accepted"], 5);
    assert_eq!(s.req("POST", "/act/definitions", Some(&json!({}))).0, 400);
    let (code, r) = s.req("POST", "/act/resolve", Some(&json!({"action": "places.save", "fields": {"name": "Elk", "place": "44.2,-114.9"}})));
    assert_eq!((code, r.as_str()), (200, r#"{"ok":true,"action":"places.save","fields":{"name":"Elk","place":{"lat":44.2,"lon":-114.9}}}"#));
    let (_, r) = s.req("POST", "/act/resolve", Some(&json!({"action": "places.list"})));
    assert_eq!(r, r#"{"ok":true,"action":"places.list","fields":{}}"#);
    let (_, r) = s.req("POST", "/act/resolve", Some(&json!({"action": "nope.x"})));
    assert_eq!(j(&r)["error"]["type"], "unknown_action");
    assert_eq!(s.req("POST", "/act/modules-off", Some(&json!(["places", "home"]))).1, r#"{"ok":true}"#);
    let (_, tools) = s.req("GET", "/tools", None);
    assert_eq!(j(&tools).as_array().unwrap().len(), 3);
    assert_eq!(s.req("POST", "/act/modules-off", Some(&json!([]))).1, r#"{"ok":true}"#);
    let (_, tools) = s.req("GET", "/tools", None);
    assert_eq!(j(&tools).as_array().unwrap().len(), 4);
    assert_eq!(s.req("POST", "/act/modules-off", Some(&json!({"a": 1}))).0, 400);
    // without a script, finishing by run id alone cannot work
    let c = s.conv();
    s.act(&c, json!({"action": "places.list"}));
    let (code, body) = s.req("POST", &format!("/conversations/{c}/act/finish"), Some(&json!({"run_id": "r1"})));
    assert_eq!(code, 404, "{body}");
    assert!(j(&body)["message"].as_str().unwrap().contains("no scripted reply"), "{body}");
}

fn run_cs(args: &[&str]) -> (bool, String, String) {
    let o = Command::new(env!("CARGO_BIN_EXE_cs")).args(args).stdin(Stdio::null()).output().expect("run cs");
    (o.status.success(), String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
}

#[test]
fn a_bad_actions_or_results_file_stops_the_server_before_it_listens() {
    let t = TempDir::new("badfiles");
    let cfg = t.write("sources.json", r#"{"sources":[]}"#);
    let bad_results = [
        "not json",
        "[]",
        r#"{"runs":{}}"#,
        r#"{"run":[]}"#,
        r#"{"run":{"a.b":{"result":{}}}}"#,
        r#"{"tap":{"a.b":{"status":"done"}}}"#,
        r#"{"tap":{"a.b":{"status":"ran"}}}"#,
        r#"{"tap":{"a.b":{"status":"failed"}}}"#,
    ];
    for (i, text) in bad_results.iter().enumerate() {
        let f = t.write(&format!("r{i}.json"), text);
        let (ok, out, err) = run_cs(&["serve", "--config", &cfg, "--listen", "127.0.0.1:0", "--action-results", &f]);
        assert!(!ok && out.is_empty(), "{text}: {out}");
        assert_eq!(j(err.lines().last().unwrap())["code"], "bad_json", "{text}: {err}");
    }
    let (ok, out, err) = run_cs(&["serve", "--config", &cfg, "--listen", "127.0.0.1:0", "--action-results", &t.0.join("missing.json").to_string_lossy()]);
    assert!(!ok && out.is_empty(), "{err}");
    let f = t.write("defs.json", "{}");
    let (ok, out, err) = run_cs(&["serve", "--config", &cfg, "--listen", "127.0.0.1:0", "--actions", &f]);
    assert!(!ok && out.is_empty(), "{err}");
    assert_eq!(j(err.lines().last().unwrap())["code"], "bad_json");
}

#[test]
fn the_help_documents_the_flags_and_the_results_format() {
    let (_, _, err) = run_cs(&[]);
    for want in ["--actions <defs.json>", "--action-results <results.json>", "\"run\"", "\"tap\"", "cs_act_finish", "cs_act_outcome"] {
        assert!(err.contains(want), "{want}");
    }
}
