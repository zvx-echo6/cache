//! The builder's stored vectors and the phone's query vectors are the same vectors.
//!
//! `packages/cache_llama/test/fixtures/bge-m3-golden.json` holds, for a few texts, the builder's vector (cl_embed through
//! cache_embed, f32) and what it stores (`embed::Cached::vector`, the int8 `schema::pack_vector` of it), made on the build
//! host with the pinned model. This test checks that the builder still makes that vector and those bytes, and how a query
//! of the same text scores the stored form with `schema::dot_packed`, the reader's own scoring (below 1 only by the int8
//! rounding). `app/test/query_embedder_parity_test.dart` checks the phone's
//! side against the same file.
//!
//! Needs the pinned model and a built cache_llama: `PLACES_EMBED_LIB` (libcache_llama.so or cache_llama.dll) and
//! `PLACES_EMBED_MODEL` (bge-m3-Q8_0.gguf); skipped without them. `PLACES_EMBED_GOLDEN_WRITE=1` writes the file instead.

use crate::embed::Cached;
use cache_embed::{Embedder, DECIDED_MODEL_FILE, DECIDED_MODEL_SHA256, EMBED_N_CTX, EMBED_POOLING};
use cache_places::schema::{dot_packed, pack_vector};
use serde_json::{json, Value};
use std::path::PathBuf;

/// Short and long, a kind's text, a notable place's, a query, accents and a text past the 512-token context.
fn texts() -> Vec<String> {
    vec![
        "pharmacy".to_string(),
        "ER".to_string(),
        "Pharmacy: pharmacies and drug stores, where medicine and prescriptions are sold".to_string(),
        "Breakfast and brunch restaurant: A restaurant that serves breakfast and brunch dishes.".to_string(),
        "Temple Square. Temple Square is a 10-acre (4 ha) complex owned by The Church of Jesus Christ of Latter-day Saints in the center of Salt Lake City, Utah.".to_string(),
        "Café Rio, Señor Frog's, Zürich – naïve façade".to_string(),
        "Salt Lake City. ".to_string() + &"The city sits in a valley between the Wasatch Range and the Oquirrh Mountains near the Great Salt Lake. ".repeat(40),
    ]
}

fn golden_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../cache_llama/test/fixtures/bge-m3-golden.json")
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn unpack(b: &[u8]) -> Vec<f32> {
    let scale = f32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    b[4..].iter().map(|x| (*x as i8) as f32 * scale).collect()
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let n = |v: &[f32]| v.iter().map(|x| x * x).sum::<f32>().sqrt();
    dot / (n(a) * n(b))
}

#[test]
fn builder_vectors_are_the_phones_query_vectors() {
    let (Ok(lib), Ok(model)) = (std::env::var("PLACES_EMBED_LIB"), std::env::var("PLACES_EMBED_MODEL")) else {
        eprintln!("PLACES_EMBED_LIB and PLACES_EMBED_MODEL not set: skipping");
        return;
    };
    let e = Embedder::load(&lib, &model, None, Some(DECIDED_MODEL_SHA256), 4).expect("the pinned model");
    // The phone's query vectors carry the GGUF's file name (CacheEmbedder.modelId), and the reader compares it with the
    // common file's embed_model, which the builder takes from here.
    assert_eq!(e.model_id, DECIDED_MODEL_FILE);
    assert_eq!(e.n_embd, 1024);
    let dir = std::env::temp_dir().join(format!("pp-parity-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut f = |t: &str| e.embed(t).map_err(|x| x.to_string());
    let mut built = Cached::new(Some(&dir.join("embed-cache.sqlite")), DECIDED_MODEL_SHA256, &mut f).unwrap();
    let stored: Vec<Vec<u8>> = texts().iter().map(|t| built.vector(t).unwrap()).collect();
    let vectors: Vec<Vec<f32>> = texts().iter().map(|t| e.embed(t).unwrap()).collect();
    for (v, s) in vectors.iter().zip(&stored) {
        assert_eq!(&pack_vector(v), s, "the stored form is the vector's pack_vector");
    }
    // From the cache, the same bytes.
    for (t, s) in texts().iter().zip(&stored) {
        assert_eq!(&built.vector(t).unwrap(), s);
    }
    assert_eq!((built.embedded, built.hits), (texts().len(), texts().len()));
    drop(built);
    let _ = std::fs::remove_dir_all(&dir);

    if std::env::var("PLACES_EMBED_GOLDEN_WRITE").is_ok() {
        let items: Vec<Value> = texts()
            .iter()
            .zip(&stored)
            .zip(&vectors)
            .map(|((t, s), v)| json!({"text": t, "vector": hex(&v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>()), "stored": hex(s)}))
            .collect();
        let doc = json!({
            "about": "For each text, the places builder's vector (cl_embed through cache_embed: 1024 x f32 little-endian) and what it stores (pack_vector: f32 scale, then 1024 x i8), made on the build host. places_pack/src/parity_tests.rs and app/test/query_embedder_parity_test.dart check the builder and the phone against it.",
            "model": DECIDED_MODEL_FILE, "model_sha256": DECIDED_MODEL_SHA256, "n_ctx": EMBED_N_CTX, "pooling": EMBED_POOLING, "normalize": true, "dims": e.n_embd,
            "items": items,
        });
        std::fs::create_dir_all(golden_path().parent().unwrap()).unwrap();
        std::fs::write(golden_path(), serde_json::to_string_pretty(&doc).unwrap() + "\n").unwrap();
        eprintln!("wrote {}", golden_path().display());
        return;
    }

    let golden: Value = serde_json::from_str(&std::fs::read_to_string(golden_path()).unwrap()).unwrap();
    assert_eq!(golden["model"], DECIDED_MODEL_FILE);
    assert_eq!(golden["model_sha256"], DECIDED_MODEL_SHA256);
    let items = golden["items"].as_array().unwrap();
    assert_eq!(items.len(), texts().len());
    let mut worst = 1.0f32;
    for (((item, t), s), v) in items.iter().zip(texts()).zip(&stored).zip(&vectors) {
        assert_eq!(item["text"].as_str().unwrap(), t);
        let gv: Vec<f32> = unhex(item["vector"].as_str().unwrap()).chunks(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
        let gs = unhex(item["stored"].as_str().unwrap());
        assert_eq!((gv.len(), gs.len()), (1024, 4 + 1024));
        // The builder makes the golden vector (to rounding: another CPU may differ in the last bits) and stores its pack_vector.
        let c = cosine(v, &gv);
        assert!(c > 0.99999, "builder vs golden for {t:?}: cosine {c}");
        assert!(cosine(&unpack(s), &unpack(&gs)) > 0.9999);
        assert_eq!(pack_vector(&gv), gs);
        // A query of the same text scores the stored form at 1 less the int8 rounding.
        let score = dot_packed(&gs, v).unwrap();
        assert!(score > 0.995, "query vs stored for {t:?}: {score}");
        worst = worst.min(score);
    }
    eprintln!("lowest query-vs-stored score {worst}");
}
