//! Tests with a tiny synthetic model (3 dims, 3 divisions); no real weights.

use cache_classify::*;

fn spec(weights: Weights) -> ModelSpec {
    ModelSpec {
        classifier_version: 7,
        embedding_sha256: [0xab; 32],
        dims: 3,
        threshold: 0.6,
        recipe: Recipe { first_pieces: 8, spread_pieces: 16 },
        classes: vec![
            Class { division: 10, label: "Encyclopedias and almanacs".into() },
            Class { division: 310, label: "Gardening".into() },
            Class { division: 580, label: "Batteries, generators and fuels".into() },
        ],
        // Each input axis votes for one class: row d is the weights of axis d over the three classes.
        bias: vec![0.0, 0.0, 0.0],
        weights,
    }
}

// Axis 0 -> class 0, axis 1 -> class 1, axis 2 -> class 2, strength 4.
fn w32() -> Weights {
    Weights::F32(vec![4.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 4.0])
}

// The same matrix as half-precision bits: 4.0 = 0x4400, 0.0 = 0x0000.
fn w16() -> Weights {
    Weights::F16(vec![0x4400, 0, 0, 0, 0x4400, 0, 0, 0, 0x4400])
}

fn model(w: Weights) -> Model {
    Model::load(&encode(&spec(w))).expect("synthetic model loads")
}

#[test]
fn crc32_matches_zlib_check_value() {
    assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
}

#[test]
fn f16_widening() {
    assert_eq!(f16_to_f32(0x3c00), 1.0);
    assert_eq!(f16_to_f32(0xc000), -2.0);
    assert_eq!(f16_to_f32(0x3800), 0.5);
    assert_eq!(f16_to_f32(0x0000), 0.0);
    assert_eq!(f16_to_f32(0x0001), 2f32.powi(-24));
    assert_eq!(f16_to_f32(0x03ff), 1023.0 * 2f32.powi(-24));
    assert_eq!(f16_to_f32(0x7bff), 65504.0);
    assert!(f16_to_f32(0x7c00).is_infinite());
    assert!(f16_to_f32(0x7e00).is_nan());
    assert_eq!(f16_to_f32(0xbc00), -1.0);
}

#[test]
fn load_round_trip_f32_and_f16() {
    for (w, is16) in [(w32(), false), (w16(), true)] {
        let m = model(w);
        assert_eq!(m.version(), 7);
        assert_eq!(m.dims(), 3);
        assert_eq!(m.threshold(), 0.6);
        assert_eq!(m.weights_are_f16(), is16);
        assert_eq!(m.embedding_sha256(), &[0xab; 32]);
        assert_eq!(m.embedding_sha256_hex(), "ab".repeat(32));
        assert_eq!(m.recipe(), Recipe { first_pieces: 8, spread_pieces: 16 });
        assert_eq!(m.classes().len(), 3);
        assert_eq!(m.classes()[1], Class { division: 310, label: "Gardening".into() });
    }
}

#[test]
fn f16_and_f32_models_score_alike() {
    let (a, b) = (model(w32()), model(w16()));
    let v = [0.2, 0.9, 0.1];
    let (ra, rb) = (a.classify(&v).unwrap(), b.classify(&v).unwrap());
    assert_eq!(ra.top().division, rb.top().division);
    assert!((ra.score() - rb.score()).abs() < 1e-6);
}

#[test]
fn load_refuses_bad_files() {
    let good = encode(&spec(w32()));
    assert_eq!(Model::load(&[]).unwrap_err(), LoadError::TooShort);
    assert_eq!(Model::load(&good[..9]).unwrap_err(), LoadError::TooShort);
    let mut bad = good.clone();
    bad[0] = b'X';
    assert_eq!(Model::load(&bad).unwrap_err(), LoadError::BadMagic);
    let mut bad = good.clone();
    bad[4] = 9;
    assert_eq!(Model::load(&bad).unwrap_err(), LoadError::UnsupportedFormat(9));
    let mut bad = good.clone();
    let mid = bad.len() / 2;
    bad[mid] ^= 0x55;
    assert_eq!(Model::load(&bad).unwrap_err(), LoadError::BadChecksum);
    let truncated = &good[..good.len() - 7];
    assert!(Model::load(truncated).is_err());
    // Every prefix of a good file is refused without panicking.
    for n in 0..good.len() {
        assert!(Model::load(&good[..n]).is_err(), "prefix {n}");
    }
}

#[test]
fn load_refuses_inconsistent_sizes_even_with_a_valid_checksum() {
    // One weight too few: re-seal the checksum so only the size check can catch it.
    let mut s = spec(w32());
    s.weights = Weights::F32(vec![0.0; 8]);
    assert!(matches!(Model::load(&encode(&s)), Err(LoadError::Corrupt(_))));
    // Threshold outside 0..1.
    let mut s = spec(w32());
    s.threshold = 1.5;
    assert!(matches!(Model::load(&encode(&s)), Err(LoadError::Corrupt(_))));
    // A weight that is not a number.
    let mut s = spec(w32());
    s.weights = Weights::F32(vec![f32::NAN; 9]);
    assert!(matches!(Model::load(&encode(&s)), Err(LoadError::Corrupt(_))));
}

#[test]
fn book_vector_is_mean_then_unit_length() {
    let a: &[f32] = &[1.0, 0.0];
    let b: &[f32] = &[0.0, 1.0];
    let v = book_vector(&[a, b]);
    let r = std::f32::consts::FRAC_1_SQRT_2;
    assert!((v[0] - r).abs() < 1e-6 && (v[1] - r).abs() < 1e-6);
    let one = book_vector(&[&[3.0, 4.0]]);
    assert!((one[0] - 0.6).abs() < 1e-6 && (one[1] - 0.8).abs() < 1e-6);
    // Opposite pieces cancel to the zero vector, not NaN.
    let z = book_vector(&[&[1.0, 0.0], &[-1.0, 0.0]]);
    assert!(z.iter().all(|x| *x == 0.0));
}

#[test]
fn book_vector_edge_cases() {
    assert!(book_vector(&[]).is_empty());
    // A piece of another length is ignored.
    let v = book_vector(&[&[3.0, 4.0], &[1.0], &[3.0, 4.0]]);
    assert!((v[0] - 0.6).abs() < 1e-6 && (v[1] - 0.8).abs() < 1e-6);
}

#[test]
fn confident_book_is_filed() {
    let m = model(w32());
    let r = m.classify(&[0.0, 1.0, 0.0]).unwrap();
    assert!(r.filed());
    assert_eq!(r.decision(), Decision::Filed(310));
    assert_eq!(r.top().label, "Gardening");
    assert_eq!(r.version(), 7);
    assert!(r.score() > 0.9);
    let total: f32 = r.ranked().iter().map(|c| c.probability).sum();
    assert!((total - 1.0).abs() < 1e-5);
}

#[test]
fn unsure_book_is_unsorted_with_ranked_candidates() {
    let m = model(w32());
    // Axis 1 slightly ahead of axis 2: top probability about 0.53, under the 0.6 threshold.
    let r = m.classify(&[0.0, 0.52, 0.48]).unwrap();
    assert!(!r.filed());
    assert_eq!(r.decision(), Decision::Unsorted);
    let top: Vec<u16> = r.top_k(3).iter().map(|c| c.division).collect();
    assert_eq!(top, vec![310, 580, 10]);
    assert!(r.ranked().windows(2).all(|w| w[0].probability >= w[1].probability));
}

#[test]
fn top_k_clamps_and_orders() {
    let m = model(w32());
    let r = m.classify(&[1.0, 0.0, 0.0]).unwrap();
    assert_eq!(r.top_k(0).len(), 0);
    assert_eq!(r.top_k(1)[0].division, 10);
    assert_eq!(r.top_k(2).len(), 2);
    assert_eq!(r.top_k(99).len(), 3);
}

#[test]
fn threshold_is_inclusive() {
    // A uniform model: every class gets 1/3, so a threshold of exactly the top probability still files.
    let mut s = spec(Weights::F32(vec![0.0; 9]));
    s.threshold = 1.0 / 3.0;
    let m = Model::load(&encode(&s)).unwrap();
    let r = m.classify(&[1.0, 0.0, 0.0]).unwrap();
    assert!(r.filed());
    // Ties keep model order.
    assert_eq!(r.top().division, 10);
    s.threshold = 0.34;
    let m = Model::load(&encode(&s)).unwrap();
    assert!(!m.classify(&[1.0, 0.0, 0.0]).unwrap().filed());
}

#[test]
fn bias_shifts_the_scores() {
    let mut s = spec(Weights::F32(vec![0.0; 9]));
    s.bias = vec![0.0, 6.0, 0.0];
    let m = Model::load(&encode(&s)).unwrap();
    let r = m.classify(&[0.0, 0.0, 0.0]).unwrap();
    assert_eq!(r.top().division, 310);
    assert!(r.filed());
}

#[test]
fn bad_vectors_are_errors_not_panics() {
    let m = model(w32());
    assert_eq!(m.classify(&[1.0, 2.0]).unwrap_err(), ClassifyError::DimensionMismatch { expected: 3, got: 2 });
    assert_eq!(m.classify(&[]).unwrap_err(), ClassifyError::DimensionMismatch { expected: 3, got: 0 });
    assert_eq!(m.classify(&[f32::NAN, 0.0, 0.0]).unwrap_err(), ClassifyError::NonFinite);
    assert_eq!(m.classify(&[f32::INFINITY, 0.0, 0.0]).unwrap_err(), ClassifyError::NonFinite);
}

#[test]
fn classify_pieces_builds_the_vector_first() {
    let m = model(w32());
    let a: &[f32] = &[0.0, 2.0, 0.0];
    let b: &[f32] = &[0.0, 1.0, 0.1];
    let r = m.classify_pieces(&[a, b]).unwrap();
    assert_eq!(r.decision(), Decision::Filed(310));
}

#[test]
fn recipe_selects_first_then_spreads() {
    let r = Recipe { first_pieces: 8, spread_pieces: 16 };
    assert_eq!(r.max_pieces(), 24);
    assert!(r.select_indices(0).is_empty());
    assert_eq!(r.select_indices(5), vec![0, 1, 2, 3, 4]);
    // 8 first + 16 rest: everything.
    assert_eq!(r.select_indices(24), (0..24).collect::<Vec<_>>());
    // More than 24: the first 8, then 16 spread over the remaining pieces, first and last of the rest included.
    let s = r.select_indices(8 + 31);
    assert_eq!(s.len(), 24);
    assert_eq!(&s[..8], &[0, 1, 2, 3, 4, 5, 6, 7]);
    assert_eq!(s[8], 8);
    assert_eq!(s[23], 8 + 30);
    assert!(s.windows(2).all(|w| w[0] < w[1]));
    // numpy: np.linspace(0, 99, 16).round() for 100 remaining pieces.
    let s = r.select_indices(108);
    let want = [0, 7, 13, 20, 26, 33, 40, 46, 53, 59, 66, 73, 79, 86, 92, 99];
    let got: Vec<usize> = s[8..].iter().map(|i| i - 8).collect();
    assert_eq!(got, want);
}

#[test]
fn division_code_pads_to_three_digits() {
    assert_eq!(division_code(10), "010");
    assert_eq!(division_code(310), "310");
}
