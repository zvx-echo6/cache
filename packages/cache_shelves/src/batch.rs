//! The batch form of same-book detection: every match between the copies to check and all the copies a device can see, in one
//! call, from the facts the libraries carry (`copies.jsonl`, else packs).
//!
//! The decision for one pair is [`crate::same::compare`], the same one the single-copy form uses, so the batch output is the union of
//! the single-copy calls, each unordered pair once. Copies are grouped by content hash first (the `blake3` rule needs no
//! comparison); the text rule then looks at pairs only among the copies that carry a fingerprint, with at least one of the pair to be
//! checked and not both already detected (`known`). Nothing is allocated per pair.

use crate::events::How;
use crate::same::{compare_text, Facts, Tuning};
use std::collections::{BTreeSet, HashMap};

/// One match. `copy` is the greater key of the pair and `with` the lesser.
#[derive(Debug, Clone, PartialEq)]
pub struct Pair {
    pub copy: String,
    pub with: String,
    pub how: How,
    pub score: f64,
}

/// Every match between a checked copy and any other copy of `all` (checked copies included). `checked` `None` means all of them.
/// A pair with both copies in `known` is skipped. Copies with a repeated key count once (the first). The result is sorted by
/// (`copy`, `with`).
pub fn find_pairs(all: &[Facts], checked: Option<&BTreeSet<String>>, known: &BTreeSet<String>, t: &Tuning) -> Vec<Pair> {
    // one entry per key, the first seen
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let facts: Vec<&Facts> = all.iter().filter(|f| seen.insert(f.copy.as_str())).collect();
    let check: Vec<bool> = facts.iter().map(|f| checked.is_none_or(|c| c.contains(&f.copy))).collect();
    let old: Vec<bool> = facts.iter().map(|f| known.contains(&f.copy)).collect();
    let wanted = |i: usize, j: usize| (check[i] || check[j]) && !(old[i] && old[j]);

    let mut out: Vec<Pair> = Vec::new();
    let mut push = |a: usize, b: usize, how: How, score: f64| {
        let (x, y) = (&facts[a].copy, &facts[b].copy);
        let (copy, with) = if x > y { (x, y) } else { (y, x) };
        out.push(Pair { copy: copy.clone(), with: with.clone(), how, score });
    };

    // the same content hash: a match, no comparison
    let mut by_hash: HashMap<&str, Vec<usize>> = HashMap::new();
    for (i, f) in facts.iter().enumerate() {
        if let Some(h) = f.blake3.as_deref() {
            by_hash.entry(h).or_default().push(i);
        }
    }
    for group in by_hash.values().filter(|g| g.len() > 1) {
        for (n, &i) in group.iter().enumerate() {
            for &j in &group[n + 1..] {
                if wanted(i, j) {
                    push(i, j, How::Blake3, 1.0);
                }
            }
        }
    }

    // the text rule, among the copies that can be fingerprinted
    let fp: Vec<usize> = (0..facts.len()).filter(|&i| !facts[i].minhash.is_empty() && !facts[i].mean_vector.is_empty()).collect();
    for (n, &i) in fp.iter().enumerate() {
        for &j in &fp[n + 1..] {
            if !wanted(i, j) || (facts[i].blake3.is_some() && facts[i].blake3 == facts[j].blake3) {
                continue;
            }
            if let Some((how, score)) = compare_text(facts[i], facts[j], t) {
                push(i, j, how, score);
            }
        }
    }
    out.sort_by(|a, b| (&a.copy, &a.with).cmp(&(&b.copy, &b.with)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::same::detect;

    fn mh(shift: u32, changed: usize) -> Vec<u32> {
        (0..128u32).map(|i| if (i as usize) < changed { i + shift + 1000 } else { i }).collect()
    }

    fn fx(copy: &str, hash: Option<&str>, changed: Option<usize>, v: [f32; 2]) -> Facts {
        Facts { copy: copy.into(), blake3: hash.map(str::to_string), minhash: changed.map(|c| mh(copy.len() as u32, c)).unwrap_or_default(), mean_vector: if changed.is_some() { v.to_vec() } else { vec![] }, words: None }
    }

    fn fixture() -> Vec<Facts> {
        vec![
            fx("a", Some("h1"), Some(0), [1.0, 0.0]),
            fx("b", Some("h1"), None, [0.0, 0.0]),
            fx("c", Some("h2"), Some(8), [1.0, 0.0]),
            fx("d", Some("h3"), Some(40), [1.0, 0.0]),
            fx("e", Some("h4"), Some(0), [0.0, 1.0]),
            fx("f", None, Some(5), [1.0, 0.0]),
            fx("g", None, None, [0.0, 0.0]),
        ]
    }

    #[test]
    fn the_batch_is_the_union_of_the_single_copy_calls() {
        let all = fixture();
        let t = Tuning::default();
        let mut union: Vec<(String, String, How)> = Vec::new();
        for c in &all {
            for f in detect(c, &all, &t) {
                let (x, y) = if c.copy > f.with { (c.copy.clone(), f.with.clone()) } else { (f.with.clone(), c.copy.clone()) };
                if !union.iter().any(|u| u.0 == x && u.1 == y) {
                    union.push((x, y, f.how));
                }
            }
        }
        union.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
        let batch = find_pairs(&all, None, &BTreeSet::new(), &t);
        assert!(!batch.is_empty());
        assert_eq!(batch.iter().map(|p| (p.copy.clone(), p.with.clone(), p.how)).collect::<Vec<_>>(), union);
        assert!(batch.iter().any(|p| p.how == How::Blake3 && (p.copy.as_str(), p.with.as_str()) == ("b", "a")));
        assert!(batch.iter().all(|p| p.copy > p.with));
        // every score is the one the single call gives
        for p in &batch {
            let c = all.iter().find(|f| f.copy == p.copy).unwrap();
            let found = detect(c, &all, &t).into_iter().find(|f| f.with == p.with).unwrap();
            assert_eq!((found.how, found.score), (p.how, p.score));
        }
    }

    #[test]
    fn only_checked_copies_and_unknown_pairs_are_looked_at() {
        let all = fixture();
        let t = Tuning::default();
        let full = find_pairs(&all, None, &BTreeSet::new(), &t);
        // checking one copy: its pairs with anything, and nothing else
        let only_f: BTreeSet<String> = ["f".to_string()].into();
        let some = find_pairs(&all, Some(&only_f), &BTreeSet::new(), &t);
        let want: Vec<&Pair> = full.iter().filter(|p| p.copy == "f" || p.with == "f").collect();
        assert_eq!(some.iter().collect::<Vec<_>>(), want);
        assert!(!some.is_empty());
        // pairs entirely inside `known` are skipped; a pair with one new copy is not
        let known: BTreeSet<String> = ["a", "b", "c"].iter().map(|s| s.to_string()).collect();
        let rest = find_pairs(&all, None, &known, &t);
        let want: Vec<&Pair> = full.iter().filter(|p| !(known.contains(&p.copy) && known.contains(&p.with))).collect();
        assert_eq!(rest.iter().collect::<Vec<_>>(), want);
        assert!(rest.len() < full.len());
        // a checked copy that is not visible adds nothing
        let ghost: BTreeSet<String> = ["nobody".to_string()].into();
        assert!(find_pairs(&all, Some(&ghost), &BTreeSet::new(), &t).is_empty());
    }

    #[test]
    fn the_order_does_not_depend_on_the_order_given_and_a_repeated_key_counts_once() {
        let mut all = fixture();
        let t = Tuning::default();
        let one = find_pairs(&all, None, &BTreeSet::new(), &t);
        all.reverse();
        assert_eq!(find_pairs(&all, None, &BTreeSet::new(), &t), one);
        let dup = all[0].clone();
        all.push(dup);
        assert_eq!(find_pairs(&all, None, &BTreeSet::new(), &t), one);
    }
}
