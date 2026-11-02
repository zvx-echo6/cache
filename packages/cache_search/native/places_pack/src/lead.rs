//! The first paragraph of a Wikipedia article from its wikitext: markup removed, under ~500 characters. This is markup
//! stripping (templates, references, links), not language handling; an article it cannot read gives None.

pub const MAX_CHARS: usize = 500;

/// Removes `open ... close` spans, nesting-aware (templates `{{ }}`, tables `{| |}`).
fn strip_nested(s: &str, open: &str, close: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let (mut depth, mut i) = (0usize, 0usize);
    while i < s.len() {
        let rest = &s[i..];
        if rest.starts_with(open) {
            depth += 1;
            i += open.len();
        } else if depth > 0 && rest.starts_with(close) {
            depth -= 1;
            i += close.len();
        } else {
            let c = rest.chars().next().unwrap();
            if depth == 0 {
                out.push(c);
            }
            i += c.len_utf8();
        }
    }
    out
}

/// Removes `<tag ...>...</tag>` and `<tag ... />` (case-insensitive tag name).
fn strip_tag(s: &str, tag: &str) -> String {
    let lower = s.to_lowercase();
    // to_lowercase can change byte lengths for a few characters; fall back to no change if it does.
    if lower.len() != s.len() {
        return s.to_string();
    }
    let (open, close) = (format!("<{tag}"), format!("</{tag}>"));
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while let Some(p) = lower[i..].find(&open) {
        let start = i + p;
        let after = start + open.len();
        // Must be the tag itself, not e.g. <references> when stripping <ref>.
        if !matches!(lower.as_bytes().get(after), Some(b'>') | Some(b' ') | Some(b'/') | Some(b'\n')) {
            out.push_str(&s[i..after]);
            i = after;
            continue;
        }
        out.push_str(&s[i..start]);
        let Some(gt) = lower[after..].find('>') else {
            i = s.len();
            break;
        };
        let tag_end = after + gt;
        if lower.as_bytes()[tag_end - 1] == b'/' {
            i = tag_end + 1;
        } else {
            i = match lower[tag_end..].find(&close) {
                Some(c) => tag_end + c + close.len(),
                None => s.len(),
            };
        }
    }
    out.push_str(&s[i.min(s.len())..]);
    out
}

fn strip_comments(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(p) = rest.find("<!--") {
        out.push_str(&rest[..p]);
        rest = match rest[p..].find("-->") {
            Some(e) => &rest[p + e + 3..],
            None => "",
        };
    }
    out.push_str(rest);
    out
}

/// `[[File:..|caption [[link]]]]` and categories: removed with nesting.
fn strip_files(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let rest = &s[i..];
        let lower: String = rest.chars().take(12).collect::<String>().to_lowercase();
        if rest.starts_with("[[") && ["file:", "image:", "category:", "media:"].iter().any(|p| lower[2..].starts_with(p)) {
            let (mut depth, mut j) = (0usize, i);
            while j < s.len() {
                if s[j..].starts_with("[[") {
                    depth += 1;
                    j += 2;
                } else if s[j..].starts_with("]]") {
                    depth -= 1;
                    j += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    j += s[j..].chars().next().unwrap().len_utf8();
                }
            }
            i = j;
        } else {
            let c = rest.chars().next().unwrap();
            out.push(c);
            i += c.len_utf8();
        }
    }
    out
}

/// `[[a|b]]` -> b, `[[a]]` -> a, `[http://x text]` -> text.
fn links(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let rest = &s[i..];
        if rest.starts_with("[[") {
            if let Some(e) = rest.find("]]") {
                let inner = &rest[2..e];
                out.push_str(inner.rsplit('|').next().unwrap_or(inner));
                i += e + 2;
                continue;
            }
        } else if rest.starts_with('[') && (rest[1..].starts_with("http") || rest[1..].starts_with("//")) {
            if let Some(e) = rest.find(']') {
                let inner = &rest[1..e];
                if let Some(sp) = inner.find(' ') {
                    out.push_str(&inner[sp + 1..]);
                }
                i += e + 1;
                continue;
            }
        }
        let c = rest.chars().next().unwrap();
        out.push(c);
        i += c.len_utf8();
    }
    out
}

fn unescape_entities(s: &str) -> String {
    s.replace("&nbsp;", " ").replace("&ndash;", "\u{2013}").replace("&mdash;", "\u{2014}").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&amp;", "&")
}

/// Removes parenthesised groups that hold no letters or digits (what is left of a pronunciation template).
fn drop_empty_parens(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '(' {
            if let Some(rel) = chars[i..].iter().position(|c| *c == ')') {
                let inner = &chars[i + 1..i + rel];
                if !inner.contains(&'(') && !inner.iter().any(|c| c.is_alphanumeric()) {
                    i += rel + 1;
                    if out.ends_with(' ') && chars.get(i) == Some(&' ') {
                        i += 1;
                    }
                    continue;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn tidy(s: &str) -> String {
    let s = drop_empty_parens(s);
    let s = s.replace("'''", "").replace("''", "").replace(" ,", ",").replace(" .", ".").replace("( ", "(").replace(" )", ")");
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn cut(s: &str) -> String {
    if s.chars().count() <= MAX_CHARS {
        return s.to_string();
    }
    let head: String = s.chars().take(MAX_CHARS).collect();
    // Prefer the end of the last whole sentence that fits.
    if let Some(p) = head.rfind(". ").filter(|p| *p > 120) {
        return head[..=p].to_string();
    }
    let cut = head.rfind(' ').unwrap_or(head.len());
    format!("{}\u{2026}", head[..cut].trim_end_matches([',', ';', ' ']))
}

/// The lead paragraph of `wikitext`, or None for a redirect or when nothing readable is found.
pub fn lead_paragraph(wikitext: &str) -> Option<String> {
    if wikitext.trim_start().to_uppercase().starts_with("#REDIRECT") {
        return None;
    }
    let mut s = strip_comments(wikitext);
    for t in ["ref", "gallery", "math", "timeline", "imagemap", "noinclude", "nowiki", "syntaxhighlight", "source"] {
        s = strip_tag(&s, t);
    }
    s = strip_nested(&s, "{{", "}}");
    s = strip_nested(&s, "{|", "|}");
    s = strip_files(&s);
    for para in s.split("\n\n") {
        let Some(first) = para.trim_start().chars().next() else { continue };
        if "=*#:;|!{<".contains(first) {
            // A heading ends the lead; lists, indents and leftover table or template lines are not prose.
            if first == '=' {
                return None;
            }
            continue;
        }
        let mut text = links(para);
        text = text.replace("<br />", " ").replace("<br/>", " ").replace("<br>", " ");
        // Remaining HTML tags (small, sup, span...).
        let mut plain = String::new();
        let mut in_tag = false;
        for c in text.chars() {
            match c {
                '<' => in_tag = true,
                '>' if in_tag => in_tag = false,
                _ if !in_tag => plain.push(c),
                _ => {}
            }
        }
        let t = tidy(&unescape_entities(&plain));
        if t.chars().count() >= 40 && !t.starts_with('{') && !t.starts_with('|') {
            return Some(cut(&t));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const BURLEY: &str = "{{Short description|City in Idaho, United States}}\n{{Infobox settlement\n| name = Burley\n| pop = {{increase}} 10,345\n}}\n[[File:Burley.jpg|thumb|Main street [[downtown]]]]\n'''Burley''' is a city in and the county seat of [[Cassia County, Idaho|Cassia County]], [[Idaho]], United States.<ref>{{cite web|url=http://x|title=Y}}</ref> The population was 10,345 at the 2020 census.{{efn|note}} It is on the [[Snake River]].\n\n==History==\nMore.";

    #[test]
    fn lead_of_a_typical_article() {
        let p = lead_paragraph(BURLEY).unwrap();
        assert_eq!(
            p,
            "Burley is a city in and the county seat of Cassia County, Idaho, United States. The population was 10,345 at the 2020 census. It is on the Snake River."
        );
    }

    #[test]
    fn pronunciation_leftovers_and_entities() {
        let t = "'''Boise''' ({{IPAc-en|ˈ|b|ɔɪ|s|i}}) is the capital of [[Idaho]]&nbsp;and a city &amp; hub of the [[Treasure Valley|valley]], with many people living there.";
        assert_eq!(lead_paragraph(t).unwrap(), "Boise is the capital of Idaho and a city & hub of the valley, with many people living there.");
    }

    #[test]
    fn redirects_and_empty() {
        assert!(lead_paragraph("#REDIRECT [[Burley, Idaho]]").is_none());
        assert!(lead_paragraph("{{stub}}\n\n==Heading==\nText").is_none());
    }

    #[test]
    fn long_paragraphs_are_cut_at_a_sentence() {
        let sentence = "This is a fairly ordinary sentence about a place in Idaho that goes on for a while. ";
        let t = sentence.repeat(10);
        let p = lead_paragraph(&t).unwrap();
        assert!(p.chars().count() <= MAX_CHARS && p.ends_with('.'), "{p}");
    }
}
