//! Library of Congress class keys and the table that converts them to Cache divisions.

/// One row of the conversion table: a subclass, optionally limited to a range of class numbers.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Rule {
    subclass: String,
    range: Option<(u32, u32)>,
    division: String,
}

/// The LCC to Cache division table (`lcc_to_division.tsv`: subclass, from, to, division, note), as embedded in the file.
#[derive(Debug, Clone, Default)]
pub struct LccTable {
    rules: Vec<Rule>,
}

impl LccTable {
    /// Parses the tab-separated text; lines starting with `#` and blank lines are skipped, bad rows are ignored.
    pub fn parse(text: &str) -> LccTable {
        let mut rules = Vec::new();
        for line in text.lines() {
            if line.starts_with('#') || line.trim().is_empty() {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 4 || f[0].is_empty() || f[3].trim().is_empty() {
                continue;
            }
            let num = |s: &str| s.trim().parse::<u32>().ok();
            let range = match (num(f[1]), num(f[2])) {
                (Some(a), Some(b)) => Some((a, b)),
                (None, None) => None,
                _ => continue,
            };
            rules.push(Rule { subclass: f[0].trim().to_string(), range, division: f[3].trim().to_string() });
        }
        LccTable { rules }
    }

    /// The Cache division for an LCC class such as "PS3558" or "QA76.73", or `None` when no rule covers it or the rule says
    /// "none" (the sorter decides). The most specific rule wins: a rule for the full subclass beats one for its first letter,
    /// and a narrower number range beats a wider one; on a tie the earlier row wins.
    pub fn division(&self, lcc: &str) -> Option<&str> {
        let up = lcc.trim_start().to_uppercase();
        let letters: String = up.chars().take_while(|c| c.is_ascii_uppercase()).take(3).collect();
        if letters.is_empty() {
            return None;
        }
        let rest = up[letters.len()..].trim_start().trim_start_matches('.').trim_start();
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        let number = digits.parse::<u32>().ok();
        let first = &letters[..1];
        let mut best: Option<((usize, i64), &str)> = None;
        for r in &self.rules {
            if r.subclass != letters && r.subclass != first {
                continue;
            }
            let score = match r.range {
                None => (r.subclass.len(), 0i64),
                Some((a, b)) => match number {
                    Some(n) if (a..=b).contains(&n) => (r.subclass.len(), 1_000_000 - i64::from(b - a)),
                    _ => continue,
                },
            };
            if best.is_none_or(|(s, _)| score > s) {
                best = Some((score, r.division.as_str()));
            }
        }
        match best {
            Some((_, d)) if d != "none" => Some(d),
            _ => None,
        }
    }
}

/// The class a catalogue record stores as a 32-bit key: up to three subclass letters (5 bits each, A = 1, padded with 0)
/// above the 14-bit class number. Returns text such as "PS3558".
pub fn lcc_text(code: u32) -> String {
    let number = code & 0x3fff;
    let c = code >> 14;
    let mut s = String::new();
    for v in [(c >> 10) & 31, (c >> 5) & 31, c & 31] {
        if v != 0 {
            s.push((b'@' + v as u8) as char);
        }
    }
    s.push_str(&number.to_string());
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    const TABLE: &str = "# subclass\tfrom\tto\tdivision\tnote\nB\t\t\t070\tphilosophy\nBF\t\t\t280\tpsychology\nBF\t1001\t2055\t070\toccult\n\
                         Q\t\t\tnone\tscience\nQA\t\t\t110\tmath\nQA\t75\t76\t760\tcomputing\nE\t\t\t990\thistory\n";

    #[test]
    fn most_specific_rule_wins() {
        let t = LccTable::parse(TABLE);
        assert_eq!(t.division("BF441"), Some("280"));
        assert_eq!(t.division("BF1500"), Some("070"));
        assert_eq!(t.division("BD100"), Some("070"));
        assert_eq!(t.division("QA76.73.C153"), Some("760"));
        assert_eq!(t.division("QA9"), Some("110"));
        assert_eq!(t.division("QB1"), None);
        assert_eq!(t.division("E185"), Some("990"));
        assert_eq!(t.division("ZZ1"), None);
        assert_eq!(t.division("123"), None);
    }

    #[test]
    fn decodes_the_key() {
        // PS3558: P = 16, S = 19, no third letter.
        let code = (((16u32 * 32 + 19) * 32) << 14) | 3558;
        assert_eq!(lcc_text(code), "PS3558");
        let e = (((5u32 * 32) * 32) << 14) | 185;
        assert_eq!(lcc_text(e), "E185");
    }
}
