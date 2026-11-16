//! How many threads opening libraries costs. Each read-only library shard used to build its own two rayon pools
//! (`edge-search-N` and `edge-load-N`, four threads per CPU each), so five libraries on a 9-core phone were 360 threads at
//! every start. The shards now share one pool of each kind (library.rs `shard_pools`): the count must not grow with the number
//! of libraries. Linux only (the threads are counted in /proc/self/task); it prints the counts.

#![cfg(target_os = "linux")]

use cache_search::library::{ensure_init, open_shard_for_scroll, write_segments_manifest};
use edge::{Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn edge_threads() -> (usize, usize) {
    let (mut search, mut load) = (0, 0);
    for t in std::fs::read_dir("/proc/self/task").unwrap().flatten() {
        let name = std::fs::read_to_string(t.path().join("comm")).unwrap_or_default();
        if name.starts_with("edge-search") {
            search += 1;
        } else if name.starts_with("edge-load") {
            load += 1;
        }
    }
    (search, load)
}

fn make_shard(root: &Path, n: usize) -> PathBuf {
    let shard = root.join(format!("lib{n}")).join("shard");
    std::fs::create_dir_all(&shard).unwrap();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(8, Distance::Cosine).build()).wal_enabled(false).build();
    let s = EdgeShard::new(&shard, cfg).unwrap();
    s.flush().unwrap();
    drop(s);
    write_segments_manifest(&shard).unwrap();
    shard
}

/// The writing shards' own pools go away when they are dropped, a moment later.
fn settle() {
    let end = Instant::now() + Duration::from_secs(10);
    while edge_threads() != (0, 0) && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn opening_more_libraries_does_not_add_threads() {
    ensure_init();
    let root = std::env::temp_dir().join(format!("edge-threads-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let shards: Vec<PathBuf> = (0..8).map(|n| make_shard(&root, n)).collect();
    settle();
    assert_eq!(edge_threads(), (0, 0), "no pool is left from making the libraries");
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);

    let mut open = Vec::new();
    let mut counts = Vec::new();
    for (i, p) in shards.iter().enumerate() {
        open.push(open_shard_for_scroll(p).unwrap());
        counts.push(edge_threads());
        println!("{} libraries open ({} cpus): edge-search {} edge-load {}", i + 1, cpus, counts[i].0, counts[i].1);
    }
    let (s, l) = counts[7];
    assert!(s <= cpus.max(2) && l <= cpus.max(2), "pools are sized to the cores, not 4 per core per library: {s} + {l}");
    assert_eq!(counts[0], counts[7], "eight libraries cost no more threads than one");
    drop(open);
    let _ = std::fs::remove_dir_all(&root);
}
