// Builds a Cache library shard and its snapshot from the points file tools/guide/assemble.py writes (id, vector, payload).
// usage: cargo run --example build_guide -- POINTS.json SHARD_DIR SNAPSHOT_OUT   (see tools/guide/BUILD.md)
use cache_search::libadd;
use cache_search::library::ensure_init;
use edge::{Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointId, PointInsertOperations, PointOperations, PointStruct, UpdateOperation};
use std::path::Path;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (points, shard_dir, snap) = (&a[1], &a[2], &a[3]);
    let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(points).unwrap()).unwrap();
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(1024, Distance::Cosine).build()).wal_enabled(false).build();
    let shard = EdgeShard::new(Path::new(shard_dir), cfg).unwrap();
    let mut pts = Vec::new();
    for p in v.as_array().unwrap() {
        let id = PointId::Uuid(uuid::Uuid::parse_str(p["id"].as_str().unwrap()).unwrap());
        let vec: Vec<f32> = p["vector"].as_array().unwrap().iter().map(|x| x.as_f64().unwrap() as f32).collect();
        assert_eq!(vec.len(), 1024);
        pts.push(PointStruct::new(id, vec, p["payload"].clone()).0);
    }
    let n = pts.len();
    shard.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts)))).unwrap();
    shard.flush().unwrap();
    drop(shard);
    libadd::pack_snapshot(Path::new(shard_dir), Path::new(snap)).unwrap();
    println!("points {n}");
}
