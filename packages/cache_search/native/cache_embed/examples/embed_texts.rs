//! Embeds texts exactly as the app embeds a query (cache_embed: cl_embed with bge-m3 Q8_0, context 512, the pooling the GGUF
//! reports, normalised vectors, the decided model's sha256 checked), for training and evaluation that must match the phone.
//!
//! embed_texts --model <bge-m3-Q8_0.gguf> [--lib <cache_llama library>] --in texts.jsonl --out exemplars.f32 --meta exemplars.meta.json
//!
//! Input: one JSON object a line with a "text" field. Output: raw little-endian float32, n_embd (1024) a row, in input order.
//! Meta: model_file, model_sha256, dims, rows, and the sha256 of the input and output files.

use std::collections::HashMap;
use std::io::{BufRead, BufWriter, Write};

/// The cache_llama library's file name on this system (beside the program when --lib is not given).
fn default_lib() -> String {
    let name = if cfg!(windows) {
        "cache_llama.dll"
    } else if cfg!(target_os = "macos") {
        "libcache_llama.dylib"
    } else {
        "libcache_llama.so"
    };
    std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.join(name))).map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|| name.to_string())
}

/// Runs with `args` (without the program name); returns the number of rows written.
pub fn run(args: &[String]) -> Result<usize, String> {
    let mut a: HashMap<&str, &str> = HashMap::new();
    let mut i = 0;
    while i < args.len() {
        let k = args[i].strip_prefix("--").ok_or_else(|| format!("unexpected argument {:?}", args[i]))?;
        let v = args.get(i + 1).ok_or_else(|| format!("--{k} needs a value"))?;
        a.insert(k, v);
        i += 2;
    }
    let need = |k: &str| a.get(k).map(|s| s.to_string()).ok_or_else(|| format!("--{k} is required"));
    let (model, input, out, meta) = (need("model")?, need("in")?, need("out")?, need("meta")?);
    let lib = a.get("lib").map(|s| s.to_string()).unwrap_or_else(default_lib);
    let e = cache_embed::Embedder::load(&lib, &model, None, Some(cache_embed::DECIDED_MODEL_SHA256), cache_embed::EMBED_DEFAULT_THREADS)
        .map_err(|e| e.to_string())?;
    let reader = std::io::BufReader::new(std::fs::File::open(&input).map_err(|e| format!("opening {input}: {e}"))?);
    let mut w = BufWriter::new(std::fs::File::create(&out).map_err(|e| format!("creating {out}: {e}"))?);
    let mut rows = 0usize;
    for (n, line) in reader.lines().enumerate() {
        let line = line.map_err(|e| format!("reading {input}: {e}"))?;
        if line.trim().is_empty() {
            continue;
        }
        let j: serde_json::Value = serde_json::from_str(&line).map_err(|e| format!("{input} line {}: {e}", n + 1))?;
        let text = j["text"].as_str().ok_or_else(|| format!("{input} line {}: no \"text\" string", n + 1))?;
        let v = e.embed(text).map_err(|e| format!("{input} line {}: {e}", n + 1))?;
        for x in &v {
            w.write_all(&x.to_le_bytes()).map_err(|e| format!("writing {out}: {e}"))?;
        }
        rows += 1;
    }
    w.flush().map_err(|e| format!("writing {out}: {e}"))?;
    drop(w);
    let file = std::path::Path::new(&model).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    let m = serde_json::json!({
        "model_file": file,
        "model_sha256": cache_embed::DECIDED_MODEL_SHA256,
        "dims": e.n_embd,
        "rows": rows,
        "input_sha256": cache_embed::sha256_file(&input).map_err(|e| e.to_string())?,
        "output_sha256": cache_embed::sha256_file(&out).map_err(|e| e.to_string())?,
    });
    std::fs::write(&meta, serde_json::to_string_pretty(&m).unwrap() + "\n").map_err(|e| format!("writing {meta}: {e}"))?;
    Ok(rows)
}

#[allow(dead_code)]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(n) => eprintln!("{n} rows"),
        Err(e) => {
            eprintln!("embed_texts: {e}");
            std::process::exit(1);
        }
    }
}
