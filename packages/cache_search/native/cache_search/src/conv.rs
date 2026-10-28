//! `cs_conversation_*` and `cs_format`: the `[n]` numbering for one chat.

use crate::error::{Error, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;

/// The id map of one chat. Numbers start at 1 and never change once given.
#[derive(Debug, Default)]
pub struct Conversation {
    /// `(address, title)` in number order: entry `i` is number `i + 1`.
    entries: Vec<(String, String)>,
    by_address: HashMap<String, usize>,
}

#[derive(Debug, Deserialize)]
struct Item {
    address: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    snippet: String,
}

/// One line of text: every run of whitespace (including line breaks) becomes a single space.
fn one_line(s: &str) -> String {
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
            let idx = match self.by_address.get(&it.address) {
                Some(&i) => i,
                None => {
                    self.entries.push((it.address.clone(), it.title.clone()));
                    self.by_address.insert(it.address.clone(), self.entries.len() - 1);
                    self.entries.len() - 1
                }
            };
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

    #[test]
    fn unicode_titles() {
        let mut c = Conversation::new();
        let v = call(&mut c, r#"[{"address":"a","title":"Café 日本","snippet":"über"}]"#);
        assert_eq!(v["tool_message"], "[1] Caf\u{e9} \u{65e5}\u{672c} \u{2014} \u{fc}ber");
    }
}
