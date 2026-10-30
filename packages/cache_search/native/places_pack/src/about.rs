//! The about step (spec S14): fills the `about` column of places and towns, what the model in the app sees of a summary.
//!
//! For every row with a summary, whitespace collapsed (every run of white space one space, ends trimmed):
//! - 400 characters (Unicode scalar values) or fewer: the summary is `about` whole. No model call.
//! - Longer: a local instruct model (an OpenAI-style `/v1/chat/completions` server, llama.cpp's, at temperature 0) is given
//!   the summary's first 400 characters and asked to return them up to the end of the last complete sentence, copied
//!   exactly. Its answer is kept only when, whitespace collapsed, it is a non-empty prefix of the summary, at most 400
//!   characters, and ends in `.`, `!` or `?`, optionally followed by exactly one closing `"` `'` `”` `’` `)` or `]`;
//!   otherwise the place has no `about` (NULL).
//!
//! `--from-log` takes the answers of an earlier run's log instead of calling the model (to re-apply the checks).
//! `--no-model` calls no model: a summary over 400 characters gets no `about`.
//!
//! The model never writes text of its own into the data: what is stored is always the summary's own opening. The step
//! records the model, its SHA-256, the prompt and every model answer with its verdict in a JSON-lines log.

use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub const MAX_CHARS: usize = 400;

/// The instruction, followed by a blank line and the first `MAX_CHARS` characters of the summary.
pub const PROMPT: &str = "Below is the first 400 characters of a longer place description, so its last sentence may be cut off. \
Copy it exactly, from its first character up to and including the end of its last complete sentence, and stop there. \
Do not change, add, reorder or remove any character before that point. Reply with the copied text only: no quotes, no notes.";

pub struct Opts {
    pub packs: Vec<PathBuf>,
    /// The server's base address, e.g. `http://127.0.0.1:8085`.
    pub llm: String,
    /// The model file's name and SHA-256, for the log.
    pub model: String,
    pub model_sha256: String,
    /// Only rows of this state (`ID`); every row when None.
    pub state: Option<String>,
    /// Model calls in flight at once (the server's `-np` slots).
    pub parallel: usize,
    pub log: PathBuf,
    /// An earlier run's log: its answers are used instead of model calls, by (pack file name, table, id).
    pub from_log: Option<PathBuf>,
    /// No model: a summary over `MAX_CHARS` gets no `about` (the whole-or-nothing rule).
    pub no_model: bool,
}

#[derive(Default, Debug)]
pub struct Report {
    pub whole: usize,
    pub model_cut: usize,
    pub dropped: usize,
    pub calls: usize,
    pub call_secs: f64,
}

/// Every run of white space as one space, ends trimmed.
pub fn collapse(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The first `n` characters of `s`.
fn head(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

/// Whether `a` ends a sentence: `.`, `!` or `?`, optionally followed by exactly one closing quote or bracket.
fn ends_sentence(a: &str) -> bool {
    let mut back = a.chars().rev();
    match back.next() {
        Some('.' | '!' | '?') => true,
        Some('"' | '\'' | '\u{201d}' | '\u{2019}' | ')' | ']') => matches!(back.next(), Some('.' | '!' | '?')),
        _ => false,
    }
}

/// The checks on a model answer for the summary `collapsed` (already whitespace collapsed): its collapsed text when it is a
/// non-empty prefix of the summary, at most `MAX_CHARS` characters, ending a sentence (`ends_sentence`).
pub fn accept(collapsed: &str, answer: &str) -> Option<String> {
    let a = collapse(answer);
    let ok = !a.is_empty() && collapsed.starts_with(&a) && a.chars().count() <= MAX_CHARS && ends_sentence(&a);
    ok.then_some(a)
}

/// What a summary gives without the model: itself when it is short enough, else None (the model decides).
pub fn whole(summary: &str) -> Option<String> {
    let c = collapse(summary);
    (!c.is_empty() && c.chars().count() <= MAX_CHARS).then_some(c)
}

fn ask(agent: &ureq::Agent, o: &Opts, collapsed: &str) -> Result<String, String> {
    let body = json!({
        "messages": [{"role": "user", "content": format!("{PROMPT}\n\n{}", head(collapsed, MAX_CHARS))}],
        "temperature": 0, "top_k": 1, "seed": 0, "max_tokens": 200, "stream": false,
        // a copying task: no thinking turn before the answer (Gemma 4's template otherwise puts the answer after one)
        "chat_template_kwargs": {"enable_thinking": false},
    });
    let url = format!("{}/v1/chat/completions", o.llm.trim_end_matches('/'));
    let r = agent.post(&url).set("Content-Type", "application/json").send_string(&body.to_string()).map_err(|e| format!("{url}: {e}"))?;
    let v: Value = serde_json::from_str(&r.into_string().map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    Ok(v["choices"][0]["message"]["content"].as_str().unwrap_or("").to_string())
}

/// The answers of an earlier run's log by (pack file name, table, id).
fn logged_answers(path: &PathBuf) -> Result<std::collections::HashMap<(String, String, i64), String>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut m = std::collections::HashMap::new();
    for line in text.lines() {
        let v: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
        if let (Some(p), Some(t), Some(id), Some(a)) = (v["pack"].as_str(), v["table"].as_str(), v["id"].as_i64(), v["answer"].as_str()) {
            let name = std::path::Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            m.insert((name, t.to_string(), id), a.to_string());
        }
    }
    Ok(m)
}

pub fn run(o: &Opts) -> Result<Report, String> {
    let logged = o.from_log.as_ref().map(logged_answers).transpose()?;
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(600)).build();
    let mut log = std::fs::OpenOptions::new().create(true).append(true).open(&o.log).map_err(|e| format!("{}: {e}", o.log.display()))?;
    let mut put = |v: Value| writeln!(log, "{v}").map_err(|e| e.to_string());
    put(json!({"step": "about", "model": o.model, "model_sha256": o.model_sha256, "server": o.llm, "temperature": 0, "top_k": 1, "seed": 0,
               "enable_thinking": false, "parallel": o.parallel,
               "no_model": o.no_model, "from_log": o.from_log.as_ref().map(|p| p.display().to_string()), "max_chars": MAX_CHARS, "prompt": PROMPT, "state": o.state, "packs": o.packs.iter().map(|p| p.display().to_string()).collect::<Vec<_>>()}))?;
    let mut rep = Report::default();
    for pack in &o.packs {
        let c = Connection::open(pack).map_err(|e| format!("{}: {e}", pack.display()))?;
        for table in ["places", "localities"] {
            if c.prepare(&format!("SELECT about FROM {table} LIMIT 0")).is_err() {
                c.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN about TEXT;")).map_err(|e| e.to_string())?;
            }
            let rows: Vec<(i64, Option<String>, String)> = {
                let mut st = c
                    .prepare(&format!("SELECT id, name, summary FROM {table} WHERE summary IS NOT NULL AND summary <> '' AND (?1 IS NULL OR state = ?1) ORDER BY id"))
                    .map_err(|e| e.to_string())?;
                let it = st.query_map(params![o.state], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).map_err(|e| e.to_string())?;
                it.collect::<rusqlite::Result<_>>().map_err(|e| e.to_string())?
            };
            // the model's answers for the long summaries first, `parallel` calls at a time, in row order
            let long: Vec<usize> = if o.no_model { Vec::new() } else { (0..rows.len()).filter(|&i| whole(&rows[i].2).is_none()).collect() };
            let next = std::sync::atomic::AtomicUsize::new(0);
            let answers: std::sync::Mutex<Vec<Option<(Result<String, String>, f64)>>> = std::sync::Mutex::new(vec![None; rows.len()]);
            std::thread::scope(|sc| {
                for _ in 0..o.parallel.max(1) {
                    sc.spawn(|| loop {
                        let k = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        let Some(&i) = long.get(k) else { break };
                        let t = Instant::now();
                        let a = match &logged {
                            Some(m) => {
                                let name = pack.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                                m.get(&(name, table.to_string(), rows[i].0)).cloned().ok_or_else(|| format!("{}: {table} {} is not in the log", pack.display(), rows[i].0))
                            }
                            None => ask(&agent, o, &collapse(&rows[i].2)),
                        };
                        answers.lock().unwrap()[i] = Some((a, t.elapsed().as_secs_f64()));
                    });
                }
            });
            let answers = answers.into_inner().unwrap();
            for (i, (id, name, summary)) in rows.iter().enumerate() {
                let collapsed = collapse(summary);
                let about = match (&answers[i], whole(summary)) {
                    (_, Some(w)) => {
                        rep.whole += 1;
                        Some(w)
                    }
                    (Some((answer, secs)), None) => {
                        let answer = answer.clone()?;
                        rep.calls += 1;
                        rep.call_secs += secs;
                        let kept = accept(&collapsed, &answer);
                        if kept.is_some() { rep.model_cut += 1 } else { rep.dropped += 1 }
                        put(json!({"pack": pack.display().to_string(), "table": table, "id": id, "name": name, "summary": summary,
                                   "answer": answer, "about": kept, "verdict": if kept.is_some() { "model_cut" } else { "dropped" }, "secs": (secs * 100.0).round() / 100.0}))?;
                        kept
                    }
                    (None, None) => {
                        // --no-model: too long to keep whole, and nothing asked
                        rep.dropped += 1;
                        None
                    }
                };
                c.execute(&format!("UPDATE {table} SET about = ?1 WHERE id = ?2"), params![about, id]).map_err(|e| e.to_string())?;
            }
        }
    }
    put(json!({"step": "about", "done": true, "whole": rep.whole, "model_cut": rep.model_cut, "dropped": rep.dropped, "calls": rep.calls,
               "secs_per_call": if rep.calls > 0 { (rep.call_secs / rep.calls as f64 * 100.0).round() / 100.0 } else { 0.0 }}))?;
    Ok(rep)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_summaries_are_whole_and_need_no_model() {
        assert_eq!(whole("  Shoshone Falls is a waterfall\n on the Snake River. "), Some("Shoshone Falls is a waterfall on the Snake River.".into()));
        let s = format!("A{}.", "a".repeat(398));
        assert_eq!(whole(&s), Some(s.clone()));
        assert_eq!(whole(&format!("A{}.", "a".repeat(399))), None);
        assert_eq!(whole(" \n "), None);
        // characters, not bytes
        let s = format!("{}.", "é".repeat(399));
        assert_eq!(whole(&s), Some(s.clone()));
    }

    #[test]
    fn a_model_answer_is_kept_only_as_an_exact_prefix_ending_a_sentence() {
        let src = collapse("Grangeville is a city in Idaho. It is served by U.S. Route 95 and has a rodeo. More text follows here.");
        assert_eq!(accept(&src, "Grangeville is a city in Idaho. It is served by U.S. Route 95 and has a rodeo."), Some("Grangeville is a city in Idaho. It is served by U.S. Route 95 and has a rodeo.".into()));
        // white space in the answer is collapsed before the check
        assert_eq!(accept(&src, "  Grangeville is a city in Idaho.\n"), Some("Grangeville is a city in Idaho.".into()));
        // a changed word, an added word, quotes, an ending that is not . ! ?, nothing at all
        assert_eq!(accept(&src, "Grangeville is a town in Idaho."), None);
        assert_eq!(accept(&src, "Summary: Grangeville is a city in Idaho."), None);
        assert_eq!(accept(&src, "\"Grangeville is a city in Idaho.\""), None);
        // one closing quote or bracket may follow the sentence end, and only one
        let q = collapse("It has the \"world's largest egg toss.\" More (a lot more.) Then [this.] And \u{201c}that.\u{201d} End.\")) x");
        assert_eq!(accept(&q, "It has the \"world's largest egg toss.\""), Some("It has the \"world's largest egg toss.\"".into()));
        assert_eq!(accept(&q, "It has the \"world's largest egg toss.\" More (a lot more.)"), Some("It has the \"world's largest egg toss.\" More (a lot more.)".into()));
        assert!(accept(&q, "It has the \"world's largest egg toss.\" More (a lot more.) Then [this.]").is_some());
        assert!(accept(&q, "It has the \"world's largest egg toss.\" More (a lot more.) Then [this.] And \u{201c}that.\u{201d}").is_some());
        assert_eq!(accept(&q, "It has the \"world's largest egg toss.\" More (a lot more.) Then [this.] And \u{201c}that.\u{201d} End.\")"), None);
        assert_eq!(accept(&q, "It has the \"world"), None);
        assert_eq!(accept(&src, "Grangeville is a city in Idaho. It is served by U.S. Route 95"), None);
        assert_eq!(accept(&src, ""), None);
        // longer than 400 characters
        let long = format!("A{}. B{}.", "a".repeat(250), "b".repeat(200));
        assert_eq!(accept(&long, &long), None);
        assert_eq!(accept(&long, &format!("A{}.", "a".repeat(250))), Some(format!("A{}.", "a".repeat(250))));
    }

    #[test]
    fn the_model_sees_the_first_400_characters() {
        let s = "é".repeat(500);
        assert_eq!(head(&s, MAX_CHARS).chars().count(), 400);
        assert_eq!(head("short", MAX_CHARS), "short");
    }
}
