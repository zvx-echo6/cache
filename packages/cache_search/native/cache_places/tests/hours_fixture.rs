//! Real `opening_hours` values from the Idaho places pack (build na-places-2026-11-16) and what the card reads from each:
//! `data/opening_hours_fixture.json`, a list of `{"raw", "week"}` (a plain weekly pattern: the week as hours.rs returns it; `"exact": false` when Open and Closed are not answered) or
//! `{"raw", "why"}` (shown as it is: the reason's label). The Flutter test reads the same file. After a change to hours.rs,
//! look at the diff of the file and commit it: `HOURS_UPDATE=1 cargo test -p cache_places --test hours_fixture`.

use cache_places::hours::analyze;
use serde_json::{json, Value};

const FILE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/opening_hours_fixture.json");

fn entry(raw: &str) -> Value {
    match analyze(raw) {
        Ok(r) if r.exact => json!({"raw": raw, "week": r.week}),
        Ok(r) => json!({"raw": raw, "week": r.week, "exact": false}),
        Err(why) => json!({"raw": raw, "why": why.label()}),
    }
}

#[test]
fn every_value_reads_as_recorded() {
    let recorded: Vec<Value> = serde_json::from_str(&std::fs::read_to_string(FILE).unwrap()).unwrap();
    assert!(recorded.len() >= 200, "the fixture is a few hundred real values");
    let fresh: Vec<Value> = recorded.iter().map(|e| entry(e["raw"].as_str().unwrap())).collect();
    if std::env::var("HOURS_UPDATE").is_ok() {
        // One entry to a line, so a diff shows the values that changed.
        let lines: Vec<String> = fresh.iter().map(|e| format!("  {e}")).collect();
        std::fs::write(FILE, format!("[\n{}\n]\n", lines.join(",\n"))).unwrap();
        return;
    }
    for (a, b) in recorded.iter().zip(&fresh) {
        assert_eq!(a, b, "{} reads differently", a["raw"]);
    }
    // Both kinds are in it: the card has to handle each.
    assert!(recorded.iter().any(|e| e.get("week").is_some()));
    assert!(recorded.iter().any(|e| e.get("why").is_some()));
}
