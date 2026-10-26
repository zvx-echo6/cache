//! The JSON Schema of the definition format, generated from the Rust types (feature `schema`) and committed as
//! `packages/cache_search/schema/live-source.schema.json`. `UPDATE_SCHEMA=1 cargo test -p cache_live --features schema`
//! rewrites the file; the test fails when the committed file is out of date.

use crate::def::{SourceDef, FORMAT, MIN_FORMAT};
use serde_json::{json, Value};

pub fn json_schema() -> Value {
    let mut s = serde_json::to_value(schemars::schema_for!(SourceDef)).expect("schema");
    s["$schema"] = json!("http://json-schema.org/draft-07/schema#");
    s["$id"] = json!(format!("https://github.com/zvx-echo6/cache/schema/live-source-format-{FORMAT}.json"));
    s["title"] = json!(format!("Cache live source definition, format {FORMAT} (reads formats {MIN_FORMAT} to {FORMAT})"));
    if let Some(f) = s.pointer_mut("/properties/format") {
        f["minimum"] = json!(MIN_FORMAT);
        f["maximum"] = json!(FORMAT);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn committed_schema_is_current() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../schema/live-source.schema.json");
        let fresh = serde_json::to_string_pretty(&json_schema()).unwrap() + "\n";
        if std::env::var("UPDATE_SCHEMA").is_ok() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &fresh).unwrap();
        }
        let committed = std::fs::read_to_string(&path).expect("schema file (run with UPDATE_SCHEMA=1 to create it)");
        assert_eq!(committed.replace("\r\n", "\n"), fresh, "live-source.schema.json is out of date: UPDATE_SCHEMA=1 cargo test -p cache_live --features schema");
        let v: Value = serde_json::from_str(&committed).unwrap();
        assert_eq!(v["properties"]["format"]["maximum"], FORMAT);
    }
}
