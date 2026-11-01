//! The embedder on the server must give the phone's vectors: bge-m3 Q8_0, context 512, normalised, CLS pooling, through the same
//! `cache_embed` code the `cs` command line and the places pack builder use. These tests need the real model and the Linux
//! cache_llama library, so they are `#[ignore]`d and run by the CI workflow (and by hand on a build machine) with:
//!
//!   CACHE_EMBED_LIB=<libcache_llama.so> CACHE_EMBED_MODEL=<bge-m3-Q8_0.gguf> CACHE_EMBED_REF=<exemplars.f32> \
//!     cargo test -p cache_server --test embed_exact -- --ignored --nocapture
//!
//! CACHE_EMBED_REF is the raw little-endian float32 file that cache_embed's own example (`embed_texts`, the program the pack
//! builder and the evaluation use) wrote for tests/data/embed_texts.jsonl in the same environment.

use cache_server::embed::EmbedService;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set (see the top of tests/embed_exact.rs)"))
}

/// A service whose data folder holds the model (a link to it), so nothing is downloaded.
fn service() -> (Arc<EmbedService>, PathBuf) {
    let data = std::env::temp_dir().join(format!("cache-embed-exact-{}", std::process::id()));
    std::fs::create_dir_all(data.join("models")).unwrap();
    let model = PathBuf::from(env("CACHE_EMBED_MODEL"));
    let link = data.join("models").join("bge-m3-Q8_0.gguf");
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(&model, &link).unwrap();
    (EmbedService::new(data.clone(), PathBuf::from(env("CACHE_EMBED_LIB"))), data)
}

fn texts() -> Vec<String> {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/embed_texts.jsonl");
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()["text"].as_str().unwrap().to_string())
        .collect()
}

fn cosine(a: &[f32], b: &[f32]) -> f64 {
    let (mut dot, mut na, mut nb) = (0f64, 0f64, 0f64);
    for (x, y) in a.iter().zip(b) {
        dot += (*x as f64) * (*y as f64);
        na += (*x as f64).powi(2);
        nb += (*y as f64).powi(2);
    }
    dot / (na.sqrt() * nb.sqrt())
}

fn kb(field: &str) -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .unwrap()
        .lines()
        .find_map(|l| l.strip_prefix(field).and_then(|r| r.trim().trim_end_matches("kB").trim().parse().ok()))
        .unwrap_or(0)
}

#[test]
#[ignore = "needs the real model and the cache_llama library (run by CI)"]
fn server_vectors_match_the_phone_path() {
    let (svc, data) = service();
    let texts = texts();
    assert_eq!(texts.len(), 3);
    let got = svc.embed_batch(&texts).expect("embed_batch");
    let raw = std::fs::read(env("CACHE_EMBED_REF")).unwrap();
    let reference: Vec<f32> = (0..raw.len() / 4).map(|i| f32::from_le_bytes(raw[i * 4..i * 4 + 4].try_into().unwrap())).collect();
    assert_eq!(reference.len(), texts.len() * 1024, "the reference file is 3 rows of 1024 floats");
    for (i, v) in got.iter().enumerate() {
        assert_eq!(v.len(), 1024);
        let c = cosine(v, &reference[i * 1024..(i + 1) * 1024]);
        let norm: f64 = v.iter().map(|x| (*x as f64).powi(2)).sum::<f64>().sqrt();
        println!("text {i}: cosine to the reference {c:.7}, norm {norm:.6}");
        assert!(c >= 0.9999, "text {i}: cosine {c}");
        assert!((norm - 1.0).abs() < 1e-3, "text {i}: norm {norm}");
    }
    // a batch and one text at a time give the same vectors (the context is reused between texts)
    for (i, t) in texts.iter().enumerate() {
        let one = svc.embed_batch(std::slice::from_ref(t)).unwrap();
        let c = cosine(&one[0], &got[i]);
        assert!(c >= 0.99999, "text {i}: batch vs single {c}");
    }
    // an empty-ish text is refused, not crashed on
    assert_eq!(svc.embed_batch(&["\u{0}".to_string()]).unwrap_err().status, 400);
    drop(svc);
    let _ = std::fs::remove_dir_all(data);
}

#[test]
#[ignore = "needs the real model and the cache_llama library (run by CI)"]
fn embed_performance() {
    let (svc, data) = service();
    // 200-word passages from a fixed vocabulary (deterministic, different from each other)
    let vocab: Vec<&str> = "water river mountain trail camp fire stove map compass weather storm shelter forest valley ridge snow route bridge road fuel \
        radio signal antenna battery solar canyon desert lake ice wind rain night morning north south east west plan food rope knife tent boot pack"
        .split_whitespace()
        .collect();
    let passage = |n: usize| -> String { (0..200).map(|i| vocab[(i * 7 + n * 13 + i * i) % vocab.len()]).collect::<Vec<_>>().join(" ") };
    let batch: Vec<String> = (0..40).map(passage).collect();
    let rss0 = kb("VmRSS:");
    let t = Instant::now();
    svc.embed_batch(&batch[..1]).unwrap();
    let first = t.elapsed();
    let rss1 = kb("VmRSS:");
    let t = Instant::now();
    let out = svc.embed_batch(&batch).unwrap();
    let secs = t.elapsed().as_secs_f64();
    assert_eq!(out.len(), 40);
    println!("PERF load+first text: {:.2} s", first.as_secs_f64());
    println!("PERF rss before load: {} MB, after load and one text: {} MB, peak (VmHWM): {} MB", rss0 / 1024, rss1 / 1024, kb("VmHWM:") / 1024);
    println!("PERF throughput: {:.2} texts/s (40 passages of 200 words in {:.1} s, {} threads)", 40.0 / secs, secs, cache_embed::EMBED_DEFAULT_THREADS);
    drop(svc);
    let _ = std::fs::remove_dir_all(data);
}
