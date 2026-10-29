//! `cs_conversation_*` and `cs_format`: the `[n]` numbering for one chat.

use crate::error::{Error, Result};
use crate::web::WebNote;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::HashMap;

/// The id map of one chat. Numbers start at 1 and never change once given.
#[derive(Debug, Default)]
pub struct Conversation {
    /// `(address, title)` in number order: entry `i` is number `i + 1`.
    entries: Vec<(String, String)>,
    by_address: HashMap<String, usize>,
    /// What `web_search` showed for each `web:<url>` address (title, snippet, fetch time), so `read` can fall back to
    /// the snippet. Lives and dies with the conversation; never written to disk.
    web: HashMap<String, WebNote>,
    /// What tools count across calls (the `act` tool's confirm ids and host runs). Only `confirms` is exported.
    pub tool_state: cache_tool::ConvState,
}

#[derive(Debug, Deserialize)]
struct Item {
    address: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    snippet: String,
}

/// The version of the export format `export_json` writes and `import_json` reads.
pub const EXPORT_FORMAT: u64 = 1;

/// The shape of an export on the way in. Unknown keys are ignored, so a later version may add keys without breaking
/// this one; `format` is checked before this is read.
#[derive(Debug, Deserialize)]
struct Export {
    next_n: u64,
    ids: Vec<ExportId>,
    #[serde(default)]
    web_hits: HashMap<String, ExportHit>,
    /// The `act` tool's confirm cards so far; absent in an export of a conversation that had none.
    #[serde(default)]
    confirms: u32,
}

#[derive(Debug, Deserialize)]
struct ExportId {
    n: u64,
    address: String,
    #[serde(default)]
    title: String,
}

#[derive(Debug, Deserialize)]
struct ExportHit {
    #[serde(default)]
    title: String,
    #[serde(default)]
    snippet: String,
    #[serde(default)]
    fetched: String,
}

/// One line of text: every run of whitespace (including line breaks) becomes a single space.
pub fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

impl Conversation {
    pub fn new() -> Self {
        Self::default()
    }

    fn id_json(&self, i: usize) -> Value {
        let (a, t) = &self.entries[i];
        json!({"n": i + 1, "address": a, "title": t})
    }

    /// `{"n","address","title"}` for number `n` (from 1); `n` must have been given.
    pub fn id_value(&self, n: usize) -> Value {
        self.id_json(n - 1)
    }

    /// The `(address, title)` given number `n` (from 1), if any.
    pub fn entry(&self, n: usize) -> Option<&(String, String)> {
        n.checked_sub(1).and_then(|i| self.entries.get(i))
    }

    /// Remember a web result. The first note for an address is the one kept.
    pub fn note_web(&mut self, address: &str, note: WebNote) {
        self.web.entry(address.to_string()).or_insert(note);
    }

    /// What was remembered of the web result at `address`.
    pub fn web_note(&self, address: &str) -> Option<&WebNote> {
        self.web.get(address)
    }

    /// The number of `address`, giving it the next number (with `title`) when it has none. The bool is true
    /// when the number is new. The first title seen is the one kept.
    pub fn number(&mut self, address: &str, title: &str) -> (usize, bool) {
        if let Some(&i) = self.by_address.get(address) {
            return (i + 1, false);
        }
        self.entries.push((address.to_string(), title.to_string()));
        self.by_address.insert(address.to_string(), self.entries.len() - 1);
        (self.entries.len(), true)
    }

    /// Number the results and build the tool message. Input is validated before anything is numbered, so a
    /// bad call changes nothing.
    pub fn format(&mut self, results_json: &str) -> Result<String> {
        let items: Vec<Item> = serde_json::from_str(results_json)
            .map_err(|e| Error::bad_json(format!("results_json must be a list of objects with \"address\": {e}")))?;
        if items.is_empty() {
            return Ok(json!({"tool_message": "No results found.", "ids": []}).to_string());
        }
        let mut seen: Vec<usize> = Vec::new();
        let mut lines: Vec<String> = Vec::new();
        for it in items {
            let idx = self.number(&it.address, &it.title).0 - 1;
            if seen.contains(&idx) {
                continue;
            }
            seen.push(idx);
            let title = one_line(&it.title);
            let snippet = one_line(&it.snippet);
            lines.push(if snippet.is_empty() {
                format!("[{}] {}", idx + 1, title)
            } else {
                format!("[{}] {} \u{2014} {}", idx + 1, title, snippet)
            });
        }
        let ids: Vec<Value> = seen.iter().map(|&i| self.id_json(i)).collect();
        Ok(json!({"tool_message": lines.join("\n"), "ids": ids}).to_string())
    }

    /// The whole state of the conversation as JSON, enough for `import_json` to continue numbering and reading exactly
    /// as this conversation would. Keys come out in this order: `format` (1), `next_n` (the number the next new
    /// address gets), `ids` (`{"n","address","title"}` in number order), `web_hits` (what `web_search` showed, by
    /// `web:<url>` address in sorted order, each `{"title","snippet","fetched"}`; the snippet is what `read` falls back
    /// to), and `confirms` (the number of confirm cards the `act` tool has issued; left out while it is 0, so a conversation
    /// that never used `act` exports as it always did). Same state, same bytes. Pending host runs are not exported.
    pub fn export_json(&self) -> String {
        let ids: Vec<Value> = (0..self.entries.len()).map(|i| self.id_json(i)).collect();
        let mut hits: Vec<(&String, &WebNote)> = self.web.iter().collect();
        hits.sort_by(|a, b| a.0.cmp(b.0));
        let mut web_hits = Map::new();
        for (address, w) in hits {
            web_hits.insert(address.clone(), json!({"title": w.title, "snippet": w.snippet, "fetched": w.fetched}));
        }
        let mut out = json!({"format": EXPORT_FORMAT, "next_n": self.entries.len() + 1, "ids": ids, "web_hits": web_hits});
        // only once the act tool has issued a confirm card, so a conversation without one exports as it always did
        if self.tool_state.confirms > 0 {
            out["confirms"] = json!(self.tool_state.confirms);
        }
        out.to_string()
    }

    /// A conversation from `export_json`'s output. Malformed JSON, a missing or non-integer `format`, ids that are
    /// not numbered 1, 2, 3... in order, a repeated address, or a `next_n` that is not one past the last id are
    /// `bad_json`; a `format` other than 1 is `unsupported`. Nothing is partly built: a bad import gives no conversation.
    pub fn import_json(json: &str) -> Result<Conversation> {
        let v: Value = serde_json::from_str(json).map_err(|e| Error::bad_json(format!("conversation export: {e}")))?;
        let Some(obj) = v.as_object() else { return Err(Error::bad_json("conversation export must be a JSON object")) };
        match obj.get("format").and_then(Value::as_u64) {
            None => return Err(Error::bad_json("conversation export has no integer \"format\"")),
            Some(EXPORT_FORMAT) => {}
            Some(other) => return Err(Error::unsupported(format!("conversation export format {other} is not supported (this core reads format {EXPORT_FORMAT})"))),
        }
        let e: Export = serde_json::from_value(v).map_err(|e| Error::bad_json(format!("conversation export: {e}")))?;
        let mut c = Conversation::new();
        for (i, id) in e.ids.into_iter().enumerate() {
            if id.n != i as u64 + 1 {
                return Err(Error::bad_json(format!("conversation export: id {} is at position {}; ids must be numbered 1, 2, 3... in order", id.n, i + 1)));
            }
            if !c.number(&id.address, &id.title).1 {
                return Err(Error::bad_json(format!("conversation export: address {:?} is numbered twice", id.address)));
            }
        }
        if e.next_n != c.entries.len() as u64 + 1 {
            return Err(Error::bad_json(format!("conversation export: next_n is {} but {} ids end at {}", e.next_n, c.entries.len(), c.entries.len())));
        }
        for (address, h) in e.web_hits {
            c.web.insert(address, WebNote { title: h.title, snippet: h.snippet, fetched: h.fetched });
        }
        c.tool_state.confirms = e.confirms;
        Ok(c)
    }

    /// `{"ids":[...]}`, every number given so far, ascending.
    pub fn ids_json(&self) -> String {
        let ids: Vec<Value> = (0..self.entries.len()).map(|i| self.id_json(i)).collect();
        json!({"ids": ids}).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    fn call(c: &mut Conversation, j: &str) -> Value {
        serde_json::from_str(&c.format(j).unwrap()).unwrap()
    }

    #[test]
    fn exact_tool_message_and_ids() {
        let mut c = Conversation::new();
        let v = call(
            &mut c,
            r#"[{"address":"zim:u/a","title":"Alpha","snippet":"First one.","source_id":"x"},
                {"address":"zim:u/b","title":"Beta","snippet":"Second."},
                {"address":"pack:p/3","title":"Gamma: Delta","snippet":"Third, with — a dash."}]"#,
        );
        assert_eq!(
            v["tool_message"],
            "[1] Alpha \u{2014} First one.\n[2] Beta \u{2014} Second.\n[3] Gamma: Delta \u{2014} Third, with \u{2014} a dash."
        );
        assert_eq!(
            v["ids"],
            json!([
                {"n":1,"address":"zim:u/a","title":"Alpha"},
                {"n":2,"address":"zim:u/b","title":"Beta"},
                {"n":3,"address":"pack:p/3","title":"Gamma: Delta"}
            ])
        );
        assert!(!v["tool_message"].as_str().unwrap().ends_with('\n'));
    }

    #[test]
    fn numbers_continue_and_known_addresses_keep_theirs() {
        let mut c = Conversation::new();
        call(&mut c, r#"[{"address":"a","title":"A","snippet":"s"},{"address":"b","title":"B","snippet":"s"}]"#);
        let v = call(&mut c, r#"[{"address":"c","title":"C","snippet":"s"},{"address":"a","title":"A2","snippet":"t"}]"#);
        assert_eq!(v["tool_message"], "[3] C \u{2014} s\n[1] A2 \u{2014} t");
        assert_eq!(v["ids"][0]["n"], 3);
        assert_eq!(v["ids"][1]["n"], 1);
        // the first title seen is the one kept in the id map
        assert_eq!(v["ids"][1]["title"], "A");
        let all: Value = serde_json::from_str(&c.ids_json()).unwrap();
        let ns: Vec<u64> = all["ids"].as_array().unwrap().iter().map(|x| x["n"].as_u64().unwrap()).collect();
        assert_eq!(ns, [1, 2, 3]);
        assert_eq!(all["ids"][2]["address"], "c");
    }

    #[test]
    fn duplicate_address_in_one_call_appears_once() {
        let mut c = Conversation::new();
        let v = call(&mut c, r#"[{"address":"a","title":"A","snippet":"s"},{"address":"a","title":"A","snippet":"s"},{"address":"b","title":"B","snippet":"s"}]"#);
        assert_eq!(v["tool_message"], "[1] A \u{2014} s\n[2] B \u{2014} s");
        assert_eq!(v["ids"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn empty_list() {
        let mut c = Conversation::new();
        let v = call(&mut c, "[]");
        assert_eq!(v["tool_message"], "No results found.");
        assert_eq!(v["ids"], json!([]));
        assert_eq!(c.ids_json(), r#"{"ids":[]}"#);
    }

    #[test]
    fn bad_json_changes_nothing() {
        let mut c = Conversation::new();
        call(&mut c, r#"[{"address":"a","title":"A","snippet":"s"}]"#);
        for bad in ["", "{", "{}", "null", r#"["x"]"#, r#"[{"title":"no address"}]"#, r#"[{"address":"b","title":"B"},{"title":"x"}]"#] {
            assert_eq!(c.format(bad).unwrap_err().code, ErrorCode::BadJson, "{bad}");
        }
        let v = call(&mut c, r#"[{"address":"b","title":"B","snippet":"s"}]"#);
        assert_eq!(v["ids"][0]["n"], 2);
    }

    #[test]
    fn lines_stay_single_lines_and_empty_snippet_has_no_separator() {
        let mut c = Conversation::new();
        let v = call(&mut c, r#"[{"address":"a","title":"A\nB","snippet":"x\r\n  y"},{"address":"b","title":"Only title","snippet":""}]"#);
        assert_eq!(v["tool_message"], "[1] A B \u{2014} x y\n[2] Only title");
    }

    fn note(t: &str, s: &str) -> WebNote {
        WebNote { title: t.into(), snippet: s.into(), fetched: "2026-10-25 14:20".into() }
    }

    #[test]
    fn export_has_a_fixed_key_order_and_sorted_hits() {
        let mut c = Conversation::new();
        call(&mut c, r#"[{"address":"web:https://b/","title":"B","snippet":"s"},{"address":"web:https://a/","title":"A","snippet":"s"}]"#);
        c.note_web("web:https://b/", note("B", "bee"));
        c.note_web("web:https://a/", note("A", "ay"));
        assert_eq!(
            c.export_json(),
            r#"{"format":1,"next_n":3,"ids":[{"n":1,"address":"web:https://b/","title":"B"},{"n":2,"address":"web:https://a/","title":"A"}],"web_hits":{"web:https://a/":{"title":"A","snippet":"ay","fetched":"2026-10-25 14:20"},"web:https://b/":{"title":"B","snippet":"bee","fetched":"2026-10-25 14:20"}}}"#
        );
    }

    #[test]
    fn confirms_are_exported_only_when_above_zero_and_come_back() {
        let mut c = Conversation::new();
        call(&mut c, r#"[{"address":"a","title":"A","snippet":"s"}]"#);
        assert!(!c.export_json().contains("confirms"));
        c.tool_state.confirms = 3;
        c.tool_state.runs = 5;
        c.tool_state.pending.push(("r5".into(), "x.y".into()));
        let e = c.export_json();
        assert_eq!(e, r#"{"format":1,"next_n":2,"ids":[{"n":1,"address":"a","title":"A"}],"web_hits":{},"confirms":3}"#);
        let d = Conversation::import_json(&e).unwrap();
        assert_eq!(d.tool_state.confirms, 3);
        // runs and pending runs are not part of an export
        assert_eq!((d.tool_state.runs, d.tool_state.pending.len()), (0, 0));
        assert_eq!(d.export_json(), e);
    }

    #[test]
    fn empty_conversation_round_trips() {
        let c = Conversation::new();
        assert_eq!(c.export_json(), r#"{"format":1,"next_n":1,"ids":[],"web_hits":{}}"#);
        let mut d = Conversation::import_json(&c.export_json()).unwrap();
        assert_eq!(d.export_json(), c.export_json());
        assert_eq!(call(&mut d, r#"[{"address":"a","title":"A","snippet":"s"}]"#)["ids"][0]["n"], 1);
    }

    #[test]
    fn import_rejects_bad_exports() {
        use crate::error::ErrorCode;
        for bad in ["", "{", "[]", "null", "{}", r#"{"format":"1","next_n":1,"ids":[]}"#, r#"{"format":1}"#, r#"{"format":1,"next_n":1,"ids":[{"n":2,"address":"a"}]}"#,
            r#"{"format":1,"next_n":3,"ids":[{"n":1,"address":"a"},{"n":2,"address":"a"}]}"#, r#"{"format":1,"next_n":5,"ids":[{"n":1,"address":"a"}]}"#, r#"{"format":1,"next_n":1,"ids":[],"web_hits":[]}"#] {
            assert_eq!(Conversation::import_json(bad).unwrap_err().code, ErrorCode::BadJson, "{bad}");
        }
        assert_eq!(Conversation::import_json(r#"{"format":2,"next_n":1,"ids":[]}"#).unwrap_err().code, ErrorCode::Unsupported);
        assert_eq!(Conversation::import_json(r#"{"format":0}"#).unwrap_err().code, ErrorCode::Unsupported);
    }

    #[test]
    fn unicode_titles() {
        let mut c = Conversation::new();
        let v = call(&mut c, r#"[{"address":"a","title":"Café 日本","snippet":"über"}]"#);
        assert_eq!(v["tool_message"], "[1] Caf\u{e9} \u{65e5}\u{672c} \u{2014} \u{fc}ber");
    }
}
