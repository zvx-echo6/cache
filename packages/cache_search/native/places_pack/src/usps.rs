//! A street's written-out form for `addr_streets.street_expanded`: the street suffix and directional abbreviations of the
//! address data expanded with USPS Publication 28 (the table is data, `usps-pub28.tsv`), so "S State St" is also stored
//! as "South State Street". The suffix itself is stored in the table's form with a capital first letter ("ST" -> "St"). This is applied to the source data when the builder writes it, never to what a person types
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

/// The word with a capital first letter and the rest in lower case ("ST" -> "St", "NORTHEAST" -> "Northeast").
fn title(word: &str) -> String {
    let mut c = word.chars();
    c.next().map(|f| f.to_uppercase().to_string() + &c.as_str().to_lowercase()).unwrap_or_default()
}

fn lookup<'a>(map: &'a HashMap<String, String>, word: &str) -> Option<&'a String> {
    map.get(&word.trim_end_matches('.').to_uppercase())
}

/// Where Publication 28 applies in a street's words: (pre-directional, the suffix's index, post-directional).
fn positions<S: AsRef<str>>(words: &[S]) -> (bool, Option<usize>, bool) {
    let t = table();
    let n = words.len();
    if n < 2 {
        return (false, None, false);
    }
    let is_dir = |w: &S| lookup(&t.directional, w.as_ref()).is_some();
    let is_suffix = |w: &S| lookup(&t.suffix, w.as_ref()).is_some();
    // Post-directional: the last word, when something other than a pre-directional is before it.
    let post = is_dir(&words[n - 1]) && !(n == 2 && is_dir(&words[0]));
    let last_name = if post { n - 2 } else { n - 1 };
    // Suffix: the last word before any post-directional, with a word before it.
    let suffix = last_name >= 1 && is_suffix(&words[last_name]);
    // Pre-directional: the first word, when a name word is left between it and the suffix or post-directional.
    let first_after = if suffix { last_name } else { last_name + 1 };
    let pre = is_dir(&words[0]) && first_after > 1;
    (pre, suffix.then_some(last_name), post)
}

/// The street with its Publication 28 street suffix in the table's form with a capital first letter ("W Malbar ST" ->
/// "W Malbar St"), whatever case the source wrote it in. Directionals stay as written. Words are split on single spaces,
/// so the rest of the street is unchanged byte for byte; a street with other white space is left as it is.
pub fn suffix_in_title_case(street: &str) -> String {
    let mut words: Vec<String> = street.split(' ').map(str::to_string).collect();
    if words.iter().any(|w| w.is_empty() || w.contains(char::is_whitespace)) {
        return street.to_string();
    }
    match positions(&words).1 {
        Some(i) => {
            words[i] = title(&words[i]);
            words.join(" ")
        }
        None => street.to_string(),
    }
}

/// The street with its Publication 28 abbreviations written out, each with a capital first letter ("W Malbar St" ->
/// "West Malbar Street"), or None when that changes nothing.
pub fn expand(street: &str) -> Option<String> {
    let t = table();
    let mut words: Vec<String> = street.split_whitespace().map(str::to_string).collect();
    let (pre, suffix, post) = positions(&words);
    let n = words.len();
    let mut changed = false;
    let mut set = |w: &mut String, primary: &String| {
        let e = title(primary);
        if e != *w {
            *w = e;
            changed = true;
        }
    };
    if post {
        let p = lookup(&t.directional, &words[n - 1]).cloned().unwrap_or_default();
        set(&mut words[n - 1], &p);
    }
    if let Some(i) = suffix {
        let p = lookup(&t.suffix, &words[i]).cloned().unwrap_or_default();
        set(&mut words[i], &p);
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
        assert_eq!(expand("S State St").as_deref(), Some("South State Street"));
        assert_eq!(expand("W Malbar St").as_deref(), Some("West Malbar Street"));
        assert_eq!(expand("N Medical Dr.").as_deref(), Some("North Medical Drive"));
        assert_eq!(expand("W 300 S").as_deref(), Some("West 300 South"));
        assert_eq!(expand("300 W").as_deref(), Some("300 West"));
        assert_eq!(expand("Main St NE").as_deref(), Some("Main Street Northeast"));
        assert_eq!(expand("Overland Ave").as_deref(), Some("Overland Avenue"));
        // The written-out words have a capital first letter whatever case the source used.
        assert_eq!(expand("UNIVERSITY PKWY").as_deref(), Some("UNIVERSITY Parkway"));
        assert_eq!(expand("elm st").as_deref(), Some("elm Street"));
        assert_eq!(expand("Main STREET").as_deref(), Some("Main Street"));
        // A street called N, and nothing to expand.
        assert_eq!(expand("N St").as_deref(), Some("N Street"));
        assert_eq!(expand("N"), None);
        assert_eq!(expand("South 4500 West"), None, "already written out");
        assert_eq!(expand("Main Street"), None);
        assert_eq!(expand("Broadway"), None);
        // Only the suffix position: a leading ST is not a suffix.
        assert_eq!(expand("ST Johns"), None);
        assert_eq!(expand("ST Johns Rd").as_deref(), Some("ST Johns Road"));
        // The middle of a name is left alone.
        assert_eq!(expand("S West Temple").as_deref(), Some("South West Temple"));
        assert_eq!(expand("Road N").as_deref(), Some("Road North"));
        assert_eq!(expand("County Road 3H N").as_deref(), Some("County Road 3H North"));
    }

    #[test]
    fn the_suffix_in_title_case() {
        assert_eq!(suffix_in_title_case("W Malbar ST"), "W Malbar St");
        assert_eq!(suffix_in_title_case("E Rooster CT"), "E Rooster Ct");
        assert_eq!(suffix_in_title_case("W Sky Wood LN"), "W Sky Wood Ln");
        assert_eq!(suffix_in_title_case("Main ST NE"), "Main St NE", "directionals stay as written");
        assert_eq!(suffix_in_title_case("Overland ave"), "Overland Ave");
        assert_eq!(suffix_in_title_case("N Medical DR."), "N Medical Dr.");
        assert_eq!(suffix_in_title_case("Main Street"), "Main Street");
        assert_eq!(suffix_in_title_case("ST Johns"), "ST Johns", "a leading ST is not a suffix");
        assert_eq!(suffix_in_title_case("Broadway"), "Broadway");
        assert_eq!(suffix_in_title_case("Main  ST"), "Main  ST", "other white space: left as it is");
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
