//! Parity with the numpy scorer on the 298 held-out books.
//!
//! The fixture folder is made by tools/classifier/parity_fixture.py (it needs the trained weights and the test book
//! vectors, which are not in the repository). Point CACHE_CLASSIFIER_PARITY_DIR at it, or put it at
//! packages/cache_classify/tests/parity. With no fixture the test prints a note and passes.
//!
//! Files: model_f32.bin, model_f16.bin (cache-classifier files), vectors_f32.bin (n * dims little-endian f32 book
//! vectors), expected.tsv (id, then for f32 and for f16: numpy top-1 index, numpy top probability, filed 0/1),
//! pieces_f16.bin + pieces.tsv (id, piece count, numpy book vector index) for a few books' piece vectors.

use cache_classify::*;
use std::path::PathBuf;

fn dir() -> Option<PathBuf> {
    let d = match std::env::var("CACHE_CLASSIFIER_PARITY_DIR") {
        Ok(v) => PathBuf::from(v),
        Err(_) => PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/parity"),
    };
    if d.join("expected.tsv").exists() {
        Some(d)
    } else {
        None
    }
}

fn f32s(bytes: &[u8]) -> Vec<f32> {
    bytes.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

#[test]
fn rust_matches_numpy_on_the_test_books() {
    let Some(d) = dir() else {
        println!("parity fixture not found; skipped");
        return;
    };
    let m32 = Model::load(&std::fs::read(d.join("model_f32.bin")).unwrap()).unwrap();
    let m16 = Model::load(&std::fs::read(d.join("model_f16.bin")).unwrap()).unwrap();
    let dims = m32.dims();
    let vectors = f32s(&std::fs::read(d.join("vectors_f32.bin")).unwrap());
    let expected = std::fs::read_to_string(d.join("expected.tsv")).unwrap();
    let rows: Vec<Vec<&str>> = expected.lines().filter(|l| !l.is_empty()).map(|l| l.split('\t').collect()).collect();
    assert_eq!(vectors.len(), rows.len() * dims);

    // [top1 agree, filed agree, max |dp|] for f32 and f16
    let mut agree = [0usize; 2];
    let mut filed_agree = [0usize; 2];
    let mut max_dp = [0f32; 2];
    let mut filed_n = [0usize; 2];
    for (i, row) in rows.iter().enumerate() {
        let v = &vectors[i * dims..(i + 1) * dims];
        for (k, m) in [&m32, &m16].into_iter().enumerate() {
            let want_idx: usize = row[1 + 3 * k].parse().unwrap();
            let want_p: f32 = row[2 + 3 * k].parse().unwrap();
            let want_filed = row[3 + 3 * k] == "1";
            let r = m.classify(v).unwrap();
            if r.top().division == m.classes()[want_idx].division {
                agree[k] += 1;
            } else if k == 0 {
                println!("f32 top-1 DISAGREES on {}: rust {} numpy {}", row[0], r.top().division, m.classes()[want_idx].division);
            }
            if r.filed() == want_filed {
                filed_agree[k] += 1;
            }
            if r.filed() {
                filed_n[k] += 1;
            }
            max_dp[k] = max_dp[k].max((r.score() - want_p).abs());
        }
    }
    let n = rows.len();
    println!("books {n}");
    println!("f32: top-1 agree {}/{}, filed/unsorted agree {}/{}, filed {}, max |dp| {:e}", agree[0], n, filed_agree[0], n, filed_n[0], max_dp[0]);
    println!("f16: top-1 agree {}/{}, filed/unsorted agree {}/{}, filed {}, max |dp| {:e}", agree[1], n, filed_agree[1], n, filed_n[1], max_dp[1]);
    assert_eq!(agree[0], n, "f32 top-1 must agree with numpy on every book");
    assert!(max_dp[0] < 1e-4);
    assert!(filed_agree[0] + 1 >= n, "filed/unsorted may differ at most at the threshold edge");
    assert!(agree[1] * 100 >= n * 99, "f16 should agree on at least 99% of books");
}

#[test]
fn book_vector_matches_numpy_on_real_pieces() {
    let Some(d) = dir() else {
        println!("parity fixture not found; skipped");
        return;
    };
    let m = Model::load(&std::fs::read(d.join("model_f32.bin")).unwrap()).unwrap();
    let dims = m.dims();
    let vectors = f32s(&std::fs::read(d.join("vectors_f32.bin")).unwrap());
    let pieces = std::fs::read(d.join("pieces_f16.bin")).unwrap();
    let index = std::fs::read_to_string(d.join("pieces.tsv")).unwrap();
    let all: Vec<f32> = pieces.chunks_exact(2).map(|c| f16_to_f32(u16::from_le_bytes([c[0], c[1]]))).collect();
    let mut at = 0;
    let mut worst = 0f32;
    let mut books = 0;
    for line in index.lines().filter(|l| !l.is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        let count: usize = f[1].parse().unwrap();
        let which: usize = f[2].parse().unwrap();
        let slices: Vec<&[f32]> = (0..count).map(|p| &all[(at + p) * dims..(at + p + 1) * dims]).collect();
        at += count;
        let got = book_vector(&slices);
        let want = &vectors[which * dims..(which + 1) * dims];
        for (a, b) in got.iter().zip(want) {
            worst = worst.max((a - b).abs());
        }
        books += 1;
    }
    println!("book_vector: {books} books, max element difference {worst:e}");
    assert!(books > 0);
    assert!(worst < 1e-6);
}
