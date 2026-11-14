//! A library shard's vectors must have an HNSW graph once they are past the indexing threshold: a build that packs a plain segment
//! of gigabytes makes every meaning search read all of it. The check reports how many KB of vectors are in no graph
//! (`check_library`'s `unindexed_vectors_kb`) and a build refuses more than the threshold (`require_vectors_indexed`);
//! `EdgeShard::optimize()` gives them their graph.

use cache_search::libadd::{check_library, require_vectors_indexed};
use cache_search::library::{ensure_init, open_shard_for_scroll, unindexed_vectors_kb, write_segments_manifest, INDEXING_THRESHOLD_KB};
use edge::{
    Distance, EdgeConfig, EdgeShard, EdgeShardRead, EdgeVectorParamsBuilder, NamedQuery, PointInsertOperations, PointOperations,
    PointStruct, QueryEnum, QueryRequestBuilder, ScoringQuery, UpdateOperation,
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const DIMS: usize = 1024;
/// 3,000 vectors of 1024 float32 are about 12 MB, past the 10,000 KB threshold.
const POINTS: u64 = 3000;

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn vector(seed: u64) -> Vec<f32> {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    let v: Vec<f32> = (0..DIMS)
        .map(|_| {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((x >> 33) as f32 / (1u64 << 31) as f32) - 0.5
        })
        .collect();
    let n = v.iter().map(|a| a * a).sum::<f32>().sqrt();
    v.into_iter().map(|a| a / n).collect()
}

/// A library shard as the builder makes it: every point upserted into one EdgeShard, flushed, the manifest written.
fn build(dir: &Path, optimize: bool) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).wal_enabled(false).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    for chunk in (1..=POINTS).collect::<Vec<_>>().chunks(500) {
        let list = chunk.iter().map(|&i| PointStruct::new(i, vector(i), json!({"title": format!("Piece {i}"), "text": "words"})).0).collect();
        shard.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(list)))).unwrap();
    }
    if optimize {
        shard.optimize().unwrap();
    }
    shard.flush().unwrap();
    drop(shard);
    write_segments_manifest(dir).unwrap();
}

fn index_types(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir.join("segments")).unwrap().flatten() {
        if let Ok(t) = std::fs::read_to_string(e.path().join("segment.json")) {
            let j: Value = serde_json::from_str(&t).unwrap();
            for v in j["config"]["vector_data"].as_object().unwrap().values() {
                out.push(v["index"]["type"].as_str().unwrap().to_string());
            }
        }
    }
    out.sort();
    out
}

fn tmp(name: &str) -> TempDir {
    let d = std::env::temp_dir().join(format!("cs-vecidx-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    TempDir(d)
}

#[test]
fn a_library_built_without_optimize_is_reported_and_a_build_refuses_it() {
    let t = tmp("plain");
    build(&t.0, false);
    assert_eq!(index_types(&t.0), vec!["plain"], "the builder's shard as it was: one plain segment");
    let kb = unindexed_vectors_kb(&t.0).unwrap();
    assert_eq!(kb, POINTS * DIMS as u64 * 4 / 1024, "every vector, 4 bytes a value, is in no graph");
    assert!(kb > INDEXING_THRESHOLD_KB);
    let d = check_library(&t.0, None).unwrap();
    assert_eq!(d["unindexed_vectors_kb"], json!(kb), "reported, not refused, by the check devices run: {d}");
    let e = require_vectors_indexed(&t.0).unwrap_err();
    assert!(e.message.contains("not indexed") && e.message.contains("optimize"), "{}", e.message);
}

#[test]
fn optimize_gives_the_vectors_their_graph_and_search_still_finds_a_point() {
    let t = tmp("hnsw");
    build(&t.0, true);
    assert!(index_types(&t.0).iter().any(|t| t == "hnsw"), "{:?}", index_types(&t.0));
    assert_eq!(unindexed_vectors_kb(&t.0).unwrap(), 0, "every vector is in the graph");
    require_vectors_indexed(&t.0).unwrap();
    assert_eq!(check_library(&t.0, None).unwrap()["unindexed_vectors_kb"], json!(0));
    // the read-only open the devices use finds a point by its own vector
    let shard = open_shard_for_scroll(&t.0).unwrap();
    let req = QueryRequestBuilder::new(3).query(ScoringQuery::Vector(QueryEnum::Nearest(NamedQuery::default_dense(vector(1234))))).build();
    let hits = EdgeShardRead::query(&shard, req).unwrap();
    assert_eq!(hits[0].id.to_string(), "1234", "{hits:?}");
}

#[test]
fn a_small_library_needs_no_graph_and_passes() {
    // below the threshold a plain segment is fine (the phone's own libraries, the guide)
    let t = tmp("small");
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).wal_enabled(false).build();
    let shard = EdgeShard::new(&t.0, cfg).unwrap();
    let list = (1..=100u64).map(|i| PointStruct::new(i, vector(i), json!({"title": "x"})).0).collect();
    shard.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(list)))).unwrap();
    shard.flush().unwrap();
    drop(shard);
    write_segments_manifest(&t.0).unwrap();
    assert_eq!(unindexed_vectors_kb(&t.0).unwrap(), 100 * DIMS as u64 * 4 / 1024, "400 KB in no graph, below the threshold");
    require_vectors_indexed(&t.0).unwrap();
}
