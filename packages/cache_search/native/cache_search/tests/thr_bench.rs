//! Speed of library open and dense search, for comparing thread-pool setups. Run:
//!   BENCH_DIR=/path cargo test --release -p cache_search --test thr_bench -- --ignored --nocapture
//! The libraries are built once into BENCH_DIR (marker file `.done`) and reused; every run prints one `RESULT` line.
use cache_search::library::{ensure_init, open_library, LibSlot};
use edge::{
    Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointInsertOperations, PointOperations, PointStruct,
    UpdateOperation,
};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Barrier};
use std::time::Instant;

const DIMS: usize = 384;
const SIZES: [u64; 4] = [30_000, 15_000, 15_000, 15_000];

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
    }
}
fn vec_for(seed: u64) -> Vec<f32> {
    let mut r = Lcg(seed.wrapping_mul(7919).wrapping_add(13));
    let mut v: Vec<f32> = (0..DIMS).map(|_| r.next()).collect();
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    v.iter_mut().for_each(|x| *x /= n);
    v
}

fn build(dir: &Path, lib: usize, n: u64) {
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    let base = (lib as u64 + 1) * 10_000_000;
    let mut i = 1;
    while i <= n {
        let end = (i + 499).min(n);
        let list: Vec<_> = (i..=end)
            .map(|k| {
                PointStruct::new(
                    k,
                    vec_for(base + k),
                    json!({"title": format!("Book {}", k / 20), "content": format!("Paragraph {k}. Text about topic {}. More follows here.", k % 37),
                           "doc_hash": format!("h{}", k / 20), "source_type": "book", "_start_page": k % 500 + 1, "book_author": "A. Writer"}),
                )
                .0
            })
            .collect();
        shard.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(list)))).unwrap();
        i = end + 1;
    }
    shard.flush().unwrap();
    shard.optimize().unwrap();
    shard.flush().unwrap();
}

fn settings() -> serde_json::Value {
    json!({"format":1,"library_id":"t","title":"T","fields":{"title":"title","text":"content","page":"_start_page","source_type":"source_type","author":"book_author","link":null,"document":"doc_hash"},
           "leave_out":[],"embedding":{"vector":"","model":"m.gguf","sha256":"x","dims":DIMS},"keyword_index":"auto"})
}

fn pct(v: &mut Vec<f64>, p: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[(((v.len() - 1) as f64) * p).round() as usize]
}

#[test]
#[ignore]
fn thr_bench() {
    ensure_init();
    let root = PathBuf::from(std::env::var("BENCH_DIR").expect("BENCH_DIR"));
    let dirs: Vec<PathBuf> = (0..SIZES.len()).map(|i| root.join(format!("lib{i}"))).collect();
    if !root.join(".done").exists() {
        let t = Instant::now();
        for (i, d) in dirs.iter().enumerate() {
            let _ = std::fs::remove_dir_all(d);
            std::fs::create_dir_all(d).unwrap();
            build(d, i, SIZES[i]);
            eprintln!("built lib{i} ({} docs) at {:.0}s", SIZES[i], t.elapsed().as_secs_f64());
        }
        std::fs::write(root.join(".done"), "x").unwrap();
        return;
    }
    let s = settings();
    let t = Instant::now();
    let slots: Vec<LibSlot> = dirs.iter().map(|d| open_library(d, None, Some(&s)).unwrap()).collect();
    let open_ms = t.elapsed().as_secs_f64() * 1e3;
    let slots = Arc::new(slots);
    let q = |seed: u64| vec_for(777_000_000 + seed);
    // warm up (page cache, first-query costs)
    for i in 0..30u64 {
        slots[(i % 4) as usize].dense_search(&q(i), 10, 30, 200).unwrap();
    }
    // single queries on the big library, 200 of them
    let mut lat = Vec::new();
    for i in 0..200u64 {
        let v = q(1000 + i);
        let t = Instant::now();
        let r = slots[0].dense_search(&v, 10, 30, 200).unwrap();
        lat.push(t.elapsed().as_secs_f64() * 1e3);
        assert!(!r.is_empty());
    }
    let (s50, s95) = (pct(&mut lat.clone(), 0.5), pct(&mut lat, 0.95));
    let mut out = format!("RESULT open_ms={open_ms:.1} single_p50={s50:.2} single_p95={s95:.2}");
    for threads in [4usize, 8] {
        let per = 200u64;
        let bar = Arc::new(Barrier::new(threads + 1));
        let hs: Vec<_> = (0..threads)
            .map(|th| {
                let slots = slots.clone();
                let bar = bar.clone();
                std::thread::spawn(move || {
                    bar.wait();
                    let mut l = Vec::new();
                    for i in 0..per {
                        let v = vec_for(5000 + th as u64 * 10_000 + i);
                        let t = Instant::now();
                        slots[(th + i as usize) % 4].dense_search(&v, 10, 30, 200).unwrap();
                        l.push(t.elapsed().as_secs_f64() * 1e3);
                    }
                    l
                })
            })
            .collect();
        bar.wait();
        let t = Instant::now();
        let mut all: Vec<f64> = Vec::new();
        for h in hs {
            all.extend(h.join().unwrap());
        }
        let wall = t.elapsed().as_secs_f64();
        let qps = (threads as u64 * per) as f64 / wall;
        out += &format!(" c{threads}_qps={qps:.1} c{threads}_p50={:.2} c{threads}_p95={:.2}", pct(&mut all.clone(), 0.5), pct(&mut all, 0.95));
    }
    println!("{out}");
}
