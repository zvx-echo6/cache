//! The embed_texts example writes, byte for byte, the vector cache_embed gives the same text (the app's query path).
//! Needs CACHE_EMBED_LIB (the cache_llama library) and CACHE_EMBED_MODEL (bge-m3-Q8_0.gguf); skips without them.

#[path = "../examples/embed_texts.rs"]
mod embed_texts;

#[test]
fn the_example_writes_cache_embeds_vector_byte_for_byte() {
    let (Ok(lib), Ok(model)) = (std::env::var("CACHE_EMBED_LIB"), std::env::var("CACHE_EMBED_MODEL")) else {
        eprintln!("CACHE_EMBED_LIB / CACHE_EMBED_MODEL not set: skipping");
        return;
    };
    let dir = std::env::temp_dir().join(format!("embed-texts-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let texts = ["Where is the nearest hospital?", "How do I purify water with bleach?"];
    let input = dir.join("texts.jsonl");
    std::fs::write(&input, texts.iter().map(|t| serde_json::json!({"text": t}).to_string() + "\n").collect::<String>()).unwrap();
    let (out, meta) = (dir.join("out.f32"), dir.join("out.meta.json"));
    let s = |p: &std::path::Path| p.to_string_lossy().into_owned();
    let args: Vec<String> = ["--model", &model, "--lib", &lib, "--in", &s(&input), "--out", &s(&out), "--meta", &s(&meta)].iter().map(|x| x.to_string()).collect();
    assert_eq!(embed_texts::run(&args).unwrap(), 2);

    let e = cache_embed::Embedder::load(&lib, &model, None, Some(cache_embed::DECIDED_MODEL_SHA256), cache_embed::EMBED_DEFAULT_THREADS).unwrap();
    let want: Vec<u8> = texts.iter().flat_map(|t| e.embed(t).unwrap()).flat_map(|x| x.to_le_bytes()).collect();
    assert_eq!(e.n_embd, 1024);
    assert_eq!(std::fs::read(&out).unwrap(), want);
    let m: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&meta).unwrap()).unwrap();
    assert_eq!((m["dims"].as_u64(), m["rows"].as_u64(), m["model_file"].as_str()), (Some(1024), Some(2), Some("bge-m3-Q8_0.gguf")));
    assert_eq!(m["output_sha256"].as_str().unwrap(), cache_embed::sha256_file(&s(&out)).unwrap());
    let _ = std::fs::remove_dir_all(&dir);
}
