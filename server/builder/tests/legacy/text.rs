//! Text helpers: whitespace normalization, joining lines, dehyphenation and sentence splitting. Only layout-level
//! work on the book's own words; nothing is rewritten.

/// Replace leader dots (four or more dots in a row, with or without spaces between them: "Chapter 1 ........ 12") with a
/// space. They are layout, not words.
pub fn strip_leaders(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < chars.len() {
        if matches!(chars[i], '.' | '…' | '·') {
            let mut j = i;
            let mut dots = 0;
            while j < chars.len() && (matches!(chars[j], '.' | '…' | '·') || (chars[j] == ' ' && j + 1 < chars.len() && matches!(chars[j + 1], '.' | '…' | '·'))) {
                if chars[j] != ' ' {
                    dots += 1;
                }
                j += 1;
            }
            if dots >= 4 {
                out.push(' ');
                i = j;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// Collapse every run of whitespace (including no-break and zero-width spaces) to one space, drop soft hyphens and control
/// characters, trim.
pub fn normalize_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    for c in s.chars() {
        if c == '\u{00AD}' || c == '\u{200B}' || c == '\u{FEFF}' {
            continue;
        }
        if c.is_whitespace() || c == '\u{00A0}' {
            space = true;
            continue;
        }
        if c.is_control() {
            continue;
        }
        if space && !out.is_empty() {
            out.push(' ');
        }
        space = false;
        out.push(c);
    }
    out
}

fn is_hyphen(c: char) -> bool {
    matches!(c, '-' | '\u{2010}' | '\u{2011}')
}

/// Join `a` and `b` where `a` ends a line and `b` starts the next: a word hyphenated at the line end (a letter, a hyphen,
/// then a lowercase letter) is made whole, anything else gets one space.
pub fn join_pair(a: &str, b: &str) -> String {
    let a = a.trim_end();
    let b = b.trim_start();
    if a.is_empty() {
        return b.to_string();
    }
    if b.is_empty() {
        return a.to_string();
    }
    let mut ac = a.chars().rev();
    let last = ac.next().unwrap();
    let prev = ac.next();
    if is_hyphen(last) && prev.is_some_and(|p| p.is_alphabetic()) && b.chars().next().is_some_and(|c| c.is_lowercase()) {
        let mut s = a[..a.len() - last.len_utf8()].to_string();
        s.push_str(b);
        return s;
    }
    format!("{a} {b}")
}

/// Join lines into one flowing paragraph (whitespace normalized, hyphenated words made whole).
pub fn join_lines<'a>(lines: impl IntoIterator<Item = &'a str>) -> String {
    let mut cur = String::new();
    for l in lines {
        let l = normalize_ws(&strip_leaders(l));
        if l.is_empty() {
            continue;
        }
        cur = join_pair(&cur, &l);
    }
    cur
}

/// The number of words.
pub fn word_count(s: &str) -> usize {
    s.split_whitespace().count()
}

fn closes(c: char) -> bool {
    matches!(c, '"' | '\'' | '”' | '’' | ')' | ']' | '»')
}

fn opens_sentence(c: char) -> bool {
    c.is_uppercase() || matches!(c, '"' | '\'' | '“' | '‘' | '(' | '[' | '«' | '•' | '▪' | '●' | '¿' | '¡')
}

/// A list marker ahead ("b. ", "12. ") followed by a capital letter: it starts a new item, so the text before it ended.
fn list_marker_at(chars: &[(usize, char)], k: usize) -> bool {
    let mut i = k;
    let mut n = 0;
    while i < chars.len() && chars[i].1.is_ascii_alphanumeric() && n < 3 {
        i += 1;
        n += 1;
    }
    if n == 0 || n > 2 || i + 2 >= chars.len() || chars[i].1 != '.' || !chars[i + 1].1.is_whitespace() {
        return false;
    }
    if n == 2 && !chars[k].1.is_ascii_digit() {
        return false;
    }
    chars[i + 2..].iter().find(|c| !c.1.is_whitespace()).is_some_and(|c| c.1.is_uppercase())
}

/// True when the period ending `before` (the text up to and including the period) is an abbreviation or a list marker
/// and not the end of a sentence: an initial or a single character ("a.", "1."), a token with a period inside ("U.S.",
/// "e.g."), or a short capitalized token ("Mr.", "Dr.", "St.", "Gen.").
fn is_abbrev(before: &str) -> bool {
    let tok = before.rsplit(char::is_whitespace).next().unwrap_or("");
    let tok = tok.trim_start_matches(|c: char| !c.is_alphanumeric());
    let core = tok.trim_end_matches('.');
    let n = core.chars().count();
    if n == 0 {
        return false;
    }
    if n == 1 {
        return true;
    }
    if core.contains('.') {
        return true;
    }
    // A number that opens the sentence is a list marker ("12. Another item.").
    if !before.trim().contains(char::is_whitespace) && core.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    n <= 3 && core.chars().next().is_some_and(|c| c.is_uppercase()) && core.chars().skip(1).all(|c| c.is_lowercase())
}

/// Split a paragraph into sentences. A boundary is a `.`, `!` or `?` (and closing quotes or brackets) followed by
/// whitespace and a capital letter or an opening quote, unless the period belongs to an abbreviation or a list marker.
pub fn split_sentences(text: &str) -> Vec<String> {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut i = 0;
    while i < chars.len() {
        let (pos, c) = chars[i];
        if matches!(c, '.' | '!' | '?' | '…') {
            let mut j = i + 1;
            while j < chars.len() && (closes(chars[j].1) || matches!(chars[j].1, '.' | '!' | '?')) {
                j += 1;
            }
            // whitespace then a sentence opener
            let mut k = j;
            while k < chars.len() && chars[k].1.is_whitespace() {
                k += 1;
            }
            if k > j && k < chars.len() && (opens_sentence(chars[k].1) || list_marker_at(&chars, k)) {
                let end = if j < chars.len() { chars[j].0 } else { text.len() };
                let before = &text[start..pos + c.len_utf8()];
                if !(c == '.' && j == i + 1 && is_abbrev(before)) {
                    let s = text[start..end].trim();
                    if !s.is_empty() {
                        out.push(s.to_string());
                    }
                    start = chars[k].0;
                }
            }
            i = j.max(i + 1);
            continue;
        }
        i += 1;
    }
    let tail = text[start..].trim();
    if !tail.is_empty() {
        out.push(tail.to_string());
    }
    out
}

/// True when the text ends a sentence (terminal punctuation, optionally followed by closing quotes or brackets, or a colon).
pub fn ends_sentence(t: &str) -> bool {
    let t = t.trim_end().trim_end_matches(|c: char| closes(c));
    t.ends_with(['.', '!', '?', '…', ':', ';'])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whitespace_is_normalised() {
        assert_eq!(normalize_ws("  a \u{00A0}\n b\tc\u{00AD}d "), "a b cd");
    }

    #[test]
    fn hyphenated_words_are_made_whole() {
        assert_eq!(join_lines(["the informa-", "tion about"]), "the information about");
        // a real compound before a capital letter or a digit keeps its hyphen
        assert_eq!(join_lines(["the Anglo-", "Saxon"]), "the Anglo- Saxon");
        assert_eq!(join_lines(["well", "known"]), "well known");
        // a dash that is not after a letter
        assert_eq!(join_lines(["range 1 -", "5"]), "range 1 - 5");
    }

    #[test]
    fn sentences() {
        let s = split_sentences("The U.S. Army went. Mr. Smith agreed! \"Why?\" he asked. Done.");
        assert_eq!(s, vec!["The U.S. Army went.", "Mr. Smith agreed!", "\"Why?\" he asked.", "Done."]);
        assert_eq!(split_sentences("no end"), vec!["no end"]);
        assert_eq!(split_sentences("It was so. b. The next item. 12. Another."), vec!["It was so.", "b. The next item.", "12. Another."]);
    }

    #[test]
    fn leaders_are_dropped() {
        assert_eq!(join_lines(["Chapter 1 ........ 12"]), "Chapter 1 12");
        assert_eq!(join_lines(["Wait... what. Ok. . . . . 5"]), "Wait... what. Ok 5");
    }

    #[test]
    fn sentence_end() {
        assert!(ends_sentence("It ends.\""));
        assert!(!ends_sentence("it goes on,"));
    }
}
