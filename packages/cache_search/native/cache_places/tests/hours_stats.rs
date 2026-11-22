//! How much of a places pack's `opening_hours` the card can read. Not a regular test: it needs a file of
//! `<places>\t<value>` lines (one per distinct value, `HOURS_VALUES=/path cargo test -p cache_places --test hours_stats -- --ignored --nocapture`).

use cache_places::hours::{analyze, Why};
use std::collections::BTreeMap;

#[test]
#[ignore]
fn stats_over_a_pack() {
    let path = std::env::var("HOURS_VALUES").expect("HOURS_VALUES=<file of count<TAB>value lines>");
    let text = std::fs::read_to_string(path).unwrap();
    let (mut ok, mut ok_places, mut total, mut total_places) = (0usize, 0usize, 0usize, 0usize);
    let (mut inexact, mut inexact_places) = (0usize, 0usize);
    let mut by_why: BTreeMap<Why, (usize, usize)> = BTreeMap::new();
    let mut raw: Vec<(usize, String, Why)> = Vec::new();
    for line in text.lines() {
        let Some((n, v)) = line.split_once('\t') else { continue };
        let n: usize = n.parse().unwrap();
        total += 1;
        total_places += n;
        match analyze(v) {
            Ok(r) => {
                ok += 1;
                ok_places += n;
                if !r.exact {
                    inexact += 1;
                    inexact_places += n;
                }
            }
            Err(w) => {
                let e = by_why.entry(w).or_default();
                e.0 += 1;
                e.1 += n;
                raw.push((n, v.to_string(), w));
            }
        }
    }
    println!("distinct values: {total} ({total_places} places)");
    println!("readable: {ok} distinct ({ok_places} places)");
    println!("  of those, shown with no Open/Closed: {inexact} distinct ({inexact_places} places)");
    println!("shown raw: {} distinct ({} places)", total - ok, total_places - ok_places);
    for (w, (d, p)) in &by_why {
        println!("  {:<48} {:>5} distinct {:>6} places", w.label(), d, p);
    }
    raw.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    println!("top 20 raw by places:");
    for (n, v, w) in raw.iter().take(20) {
        println!("  {n:>5}  {:<60} {}", v, w.label());
    }
    println!("top 40 raw syntax errors by places:");
    for (n, v, _) in raw.iter().filter(|r| r.2 == Why::Syntax).take(40) {
        println!("  {n:>5}  {v}");
    }
}
