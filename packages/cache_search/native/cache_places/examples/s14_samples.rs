//! Writes S14 place samples through the core's own path: each row is read from its pack by `Pack` (the reader nearby,
//! locate and navigate use) and `about` / `wikipedia` come from `cache_places::about`, so the values are the bytes the
//! tools emit. `cargo run -p cache_places --example s14_samples -- <packs dir> <picks.json> <out.json>`, where picks is a
//! JSON array of `{"block": "2985", "table": "places" | "localities", "source_id": "...", ...}` (any other keys are
//! passed through after the sample's own keys).

use cache_places::about::{about_of, wikipedia_of};
use cache_places::Pack;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let [_, dir, picks, out] = &args[..] else {
        eprintln!("usage: s14_samples <packs dir> <picks.json> <out.json>");
        std::process::exit(2);
    };
    let picks: Vec<Map<String, Value>> = serde_json::from_slice(&std::fs::read(picks).expect("read picks")).expect("picks is a JSON array of objects");
    let mut packs: HashMap<String, Pack> = HashMap::new();
    let mut res = Vec::new();
    for p in picks {
        let block = p["block"].as_str().expect("block").to_string();
        let pack = packs.entry(block.clone()).or_insert_with(|| Pack::open(&Path::new(dir).join(format!("{block}.sqlite"))).expect("open pack"));
        let sid = p["source_id"].as_str().expect("source_id");
        let mut m = Map::new();
        if p["table"] == "localities" {
            let r = pack.locality_by_source_id(sid).expect("read").expect("the town is in the pack");
            m.insert("id".into(), json!(r.id));
            m.insert("name".into(), json!(r.name));
            m.insert("kind".into(), json!(r.kind));
            m.insert("lat".into(), json!(r.lat));
            m.insert("lon".into(), json!(r.lon));
            m.insert("locality".into(), Value::Null);
            m.insert("summary".into(), json!(r.summary));
            if let Some(a) = about_of(r.about.as_deref()) {
                m.insert("about".into(), json!(a));
            }
            if let Some(w) = wikipedia_of(r.wikipedia_title.as_deref()) {
                m.insert("wikipedia".into(), json!(w));
            }
        } else {
            let r = pack.place_by_source_id(sid).expect("read").expect("the place is in the pack");
            m.insert("id".into(), json!(r.id));
            m.insert("name".into(), json!(r.name));
            m.insert("kind".into(), json!(r.kind_id.clone().or(r.kind.clone())));
            m.insert("lat".into(), json!(r.lat));
            m.insert("lon".into(), json!(r.lon));
            m.insert("locality".into(), json!(r.locality));
            m.insert("summary".into(), json!(r.summary));
            if let Some(a) = about_of(r.about.as_deref()) {
                m.insert("about".into(), json!(a));
            }
            if let Some(w) = wikipedia_of(r.wikipedia_title.as_deref()) {
                m.insert("wikipedia".into(), json!(w));
            }
        }
        for (k, v) in p {
            if !m.contains_key(&k) {
                m.insert(k, v);
            }
        }
        res.push(Value::Object(m));
    }
    let mut text = serde_json::to_string_pretty(&res).expect("json");
    text.push('\n');
    std::fs::write(out, text).expect("write");
    eprintln!("{} samples", res.len());
}
