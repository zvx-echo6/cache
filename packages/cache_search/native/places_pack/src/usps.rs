//! A street's written-out form for `addr_streets.street_expanded`: the street suffix and directional abbreviations of the
//! address data expanded with USPS Publication 28 (the table is data, `usps-pub28.tsv`), so "S STATE ST" is also stored
//! as "SOUTH STATE STREET". This is applied to the source data when the builder writes it, never to what a person types
//! (a project decision, 2026-10-28; docs/PLACES-TILES.md).
//!
//! Only the positions Publication 28 defines are touched: the first word as a pre-directional, the last word as a
//! post-directional, and the street suffix (the last word, or the one before a post-directional). A word is only expanded
//! where a name is left beside it, so "N ST" (a street called N) stays "N STREET" and "N" alone stays "N".

use std::collections::HashMap;
use std::sync::OnceLock;

const TABLE: &str = include_str!("../usps-pub28.tsv");

struct Pub28 {
    suffix: HashMap<String, String>,
    directional: HashMap<String, String>,
}

fn table() -> &'static Pub28 {
    static T: OnceLock<Pub28> = OnceLock::new();
    T.get_or_init(|| {
        let mut t = Pub28 { suffix: HashMap::new(), directional: HashMap::new() };
        for line in TABLE.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()) {
            let mut f = line.split('\t');
            let (kind, primary, forms) = (f.next().unwrap_or(""), f.next().unwrap_or(""), f.next().unwrap_or(""));
            let map = if kind == "directional" { &mut t.directional } else { &mut t.suffix };
            for form in forms.split_whitespace() {
                // A form listed under two names (C1 has MDW under MEADOW and MEADOWS) keeps the first.
                map.entry(form.to_string()).or_insert_with(|| primary.to_string());
            }
        }
        t
    })
}

/// The written-out word in the case the source wrote the abbreviation in ("ST" -> "STREET", "St" -> "Street",
/// "st." -> "street").
fn in_case_of(word: &str, primary: &str) -> String {
    let letters: Vec<char> = word.chars().filter(|c| c.is_alphabetic()).collect();
    if letters.iter().all(|c| c.is_uppercase()) {
        primary.to_string()
    } else if letters.first().is_some_and(|c| c.is_uppercase()) {
        let mut c = primary.chars();
        c.next().map(|f| f.to_string() + &c.as_str().to_lowercase()).unwrap_or_default()
    } else {
        primary.to_lowercase()
    }
}

fn lookup<'a>(map: &'a HashMap<String, String>, word: &str) -> Option<&'a String> {
    map.get(&word.trim_end_matches('.').to_uppercase())
}

/// The street with its Publication 28 abbreviations written out, or None when that changes nothing.
pub fn expand(street: &str) -> Option<String> {
    let t = table();
    let mut words: Vec<String> = street.split_whitespace().map(str::to_string).collect();
    let n = words.len();
    if n < 2 {
        return None;
    }
    let is_dir = |w: &str| lookup(&t.directional, w).is_some();
    let is_suffix = |w: &str| lookup(&t.suffix, w).is_some();
    // Post-directional: the last word, when something other than a pre-directional is before it.
    let post = is_dir(&words[n - 1]) && !(n == 2 && is_dir(&words[0]));
    let last_name = if post { n - 2 } else { n - 1 };
    // Suffix: the last word before any post-directional, with a word before it.
    let suffix = last_name >= 1 && is_suffix(&words[last_name]);
    // Pre-directional: the first word, when a name word is left between it and the suffix or post-directional.
    let first_after = if suffix { last_name } else { last_name + 1 };
    let pre = is_dir(&words[0]) && first_after > 1;
    let mut changed = false;
    let mut set = |w: &mut String, primary: &String| {
        let e = in_case_of(w, primary);
        if e != *w {
            *w = e;
            changed = true;
        }
    };
    if post {
        let p = lookup(&t.directional, &words[n - 1]).cloned().unwrap_or_default();
        set(&mut words[n - 1], &p);
    }
    if suffix {
        let p = lookup(&t.suffix, &words[last_name]).cloned().unwrap_or_default();
        set(&mut words[last_name], &p);
    }
    if pre {
        let p = lookup(&t.directional, &words[0]).cloned().unwrap_or_default();
        set(&mut words[0], &p);
    }
    changed.then(|| words.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffixes_and_directionals() {
        assert_eq!(expand("S STATE ST").as_deref(), Some("SOUTH STATE STREET"));
        assert_eq!(expand("S State St").as_deref(), Some("South State Street"));
        assert_eq!(expand("N Medical Dr.").as_deref(), Some("North Medical Drive"));
        assert_eq!(expand("W 300 S").as_deref(), Some("WEST 300 SOUTH"));
        assert_eq!(expand("300 W").as_deref(), Some("300 WEST"));
        assert_eq!(expand("MAIN ST NE").as_deref(), Some("MAIN STREET NORTHEAST"));
        assert_eq!(expand("Overland Ave").as_deref(), Some("Overland Avenue"));
        assert_eq!(expand("UNIVERSITY PKWY").as_deref(), Some("UNIVERSITY PARKWAY"));
        // A street called N, and nothing to expand.
        assert_eq!(expand("N ST").as_deref(), Some("N STREET"));
        assert_eq!(expand("N"), None);
        assert_eq!(expand("South 4500 West"), None, "already written out");
        assert_eq!(expand("Main Street"), None);
        assert_eq!(expand("Broadway"), None);
        // Only the suffix position: a leading ST is not a suffix.
        assert_eq!(expand("ST JOHNS"), None);
        assert_eq!(expand("ST JOHNS RD").as_deref(), Some("ST JOHNS ROAD"));
        // The middle of a name is left alone.
        assert_eq!(expand("S WEST TEMPLE").as_deref(), Some("SOUTH WEST TEMPLE"));
    }

    #[test]
    fn the_table_reads() {
        let t = table();
        assert!(t.suffix.len() > 400, "{}", t.suffix.len());
        assert_eq!(t.directional.len(), 16);
        assert_eq!(t.suffix["HWY"], "HIGHWAY");
        assert_eq!(t.suffix["MDW"], "MEADOW");
    }
}
