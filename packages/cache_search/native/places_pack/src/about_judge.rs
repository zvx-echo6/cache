//! Trial of the about step's "model as judge" method (spec S14, option 4). Reads the rows listed in an earlier about log
//! (pack file name, table, id) from the packs, and for each summary over 400 characters takes the Unicode sentence
//! boundaries (UAX #29) of the whitespace-collapsed summary that fall at or before 400 characters. From the last one
//! backwards it asks the model `JUDGE` about the text up to that boundary; the first "yes" is the cut (a prefix of the
//! summary by construction), and no "yes" means no `about`. Writes one JSON line per summary with every question and
//! answer. It changes no pack.

use crate::about::{collapse, MAX_CHARS};
use rusqlite::{params, Connection, OpenFlags};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use unicode_segmentation::UnicodeSegmentation;

pub const JUDGE: &str = "Does this text end with a complete sentence? Answer yes or no.";

pub struct Opts {
    pub packs: PathBuf,
    pub rows_from: PathBuf,
    pub llm: String,
    pub model: String,
    pub model_sha256: String,
    pub parallel: usize,
    pub out: PathBuf,
}

/// The texts up to each sentence boundary of `collapsed` that are at most `MAX_CHARS` characters, shortest first.
pub fn candidates(collapsed: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for (start, s) in collapsed.split_sentence_bound_indices() {
        let c = collapsed[..start + s.len()].trim_end();
        if c.chars().count() > MAX_CHARS {
            break;
        }
        if !c.is_empty() && out.last().map(String::as_str) != Some(c) {
            out.push(c.to_string());
        }
    }
    out
}

fn ask(agent: &ureq::Agent, o: &Opts, text: &str) -> Result<String, String> {
    let body = json!({
        "messages": [{"role": "user", "content": format!("{JUDGE}\n\n{text}")}],
        "temperature": 0, "top_k": 1, "seed": 0, "max_tokens": 3, "stream": false,
        "chat_template_kwargs": {"enable_thinking": false},
    });
    let url = format!("{}/v1/chat/completions", o.llm.trim_end_matches('/'));
    let r = agent.post(&url).set("Content-Type", "application/json").send_string(&body.to_string()).map_err(|e| format!("{url}: {e}"))?;
    let v: Value = serde_json::from_str(&r.into_string().map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    Ok(v["choices"][0]["message"]["content"].as_str().unwrap_or("").trim().to_string())
}

/// The model's answer as yes / no: its first word, lower-cased, is "yes" (a machine reading of a one-word answer).
fn is_yes(answer: &str) -> bool {
    answer.split(|c: char| !c.is_alphabetic()).find(|w| !w.is_empty()).is_some_and(|w| w.eq_ignore_ascii_case("yes"))
}

pub fn run(o: &Opts) -> Result<(usize, usize, usize), String> {
    let text = std::fs::read_to_string(&o.rows_from).map_err(|e| format!("{}: {e}", o.rows_from.display()))?;
    let mut keys: Vec<(String, String, i64)> = Vec::new();
    for line in text.lines() {
        let v: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
        if let (Some(p), Some(t), Some(id)) = (v["pack"].as_str(), v["table"].as_str(), v["id"].as_i64()) {
            let name = std::path::Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            keys.push((name, t.to_string(), id));
        }
    }
    let mut rows: Vec<(String, String, i64, Option<String>, String)> = Vec::new();
    for (pack, table, id) in &keys {
        let c = Connection::open_with_flags(o.packs.join(pack), OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| format!("{pack}: {e}"))?;
        let (name, summary): (Option<String>, String) = c
            .query_row(&format!("SELECT name, summary FROM {table} WHERE id = ?1"), params![id], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(|e| format!("{pack} {table} {id}: {e}"))?;
        rows.push((pack.clone(), table.clone(), *id, name, summary));
    }
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(600)).build();
    let next = std::sync::atomic::AtomicUsize::new(0);
    let results: std::sync::Mutex<Vec<Option<Result<Value, String>>>> = std::sync::Mutex::new(vec![None; rows.len()]);
    std::thread::scope(|sc| {
        for _ in 0..o.parallel.max(1) {
            sc.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let Some((pack, table, id, name, summary)) = rows.get(i) else { break };
                let collapsed = collapse(summary);
                let cands = candidates(&collapsed);
                let mut asked = Vec::new();
                let mut cut: Option<String> = None;
                let t = Instant::now();
                let mut err = None;
                for c in cands.iter().rev() {
                    match ask(&agent, o, c) {
                        Ok(a) => {
                            let yes = is_yes(&a);
                            asked.push(json!({"text_end": c.chars().rev().take(60).collect::<String>().chars().rev().collect::<String>(), "chars": c.chars().count(), "answer": a}));
                            if yes {
                                cut = Some(c.clone());
                                break;
                            }
                        }
                        Err(e) => {
                            err = Some(e);
                            break;
                        }
                    }
                }
                let r = match err {
                    Some(e) => Err(e),
                    None => Ok(json!({"pack": pack, "table": table, "id": id, "name": name, "summary": summary, "candidates": cands.len(),
                                      "asked": asked, "about": cut, "secs": (t.elapsed().as_secs_f64() * 10.0).round() / 10.0})),
                };
                results.lock().unwrap()[i] = Some(r);
            });
        }
    });
    let mut out = std::fs::File::create(&o.out).map_err(|e| format!("{}: {e}", o.out.display()))?;
    writeln!(out, "{}", json!({"step": "about-judge", "model": o.model, "model_sha256": o.model_sha256, "server": o.llm, "prompt": JUDGE,
                              "temperature": 0, "top_k": 1, "seed": 0, "enable_thinking": false, "max_chars": MAX_CHARS, "rows_from": o.rows_from.display().to_string()}))
        .map_err(|e| e.to_string())?;
    let (mut cut, mut none, mut calls) = (0, 0, 0);
    for r in results.into_inner().unwrap() {
        let v = r.expect("every row ran")?;
        calls += v["asked"].as_array().map_or(0, Vec::len);
        if v["about"].is_null() { none += 1 } else { cut += 1 }
        writeln!(out, "{v}").map_err(|e| e.to_string())?;
    }
    Ok((cut, none, calls))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_are_the_sentence_ends_within_400_characters() {
        let a = format!("A{}.", "a".repeat(198));
        let b = format!("B{}.", "b".repeat(148));
        let c = format!("C{}.", "c".repeat(100));
        assert_eq!(candidates(&format!("{a} {b} {c}")), vec![a.clone(), format!("{a} {b}")]);
        assert!(candidates(&format!("A{}.", "a".repeat(450))).is_empty());
    }

    #[test]
    fn yes_is_the_first_word() {
        assert!(is_yes("Yes"));
        assert!(is_yes("yes."));
        assert!(!is_yes("No"));
        assert!(!is_yes(""));
    }
}
