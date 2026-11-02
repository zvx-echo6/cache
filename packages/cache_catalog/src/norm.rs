//! Text helpers. [`normalise_title`], [`author_surname`] and the ISBN conversion match `tools/build_catalog.py` exactly (the
//! catalogue's keys are made with them), so a book's own title and author must go through these before a lookup.

use std::collections::HashSet;

/// Lower-case, then the maximal runs of alphanumeric characters (Unicode; `_` is not one) joined by single spaces.
/// "Moby-Dick; or, The Whale" becomes "moby dick or the whale".
///
/// The build script does the same with Python's `str.lower` and `str.isalnum`; the two disagree only on a few combining
/// marks of non-Latin scripts, where a title simply fails to match (it never matches a wrong book).
pub fn normalise_title(s: &str) -> String {
    let lower = s.to_lowercase();
    let mut out = String::with_capacity(lower.len());
    let mut gap = false;
    for c in lower.chars() {
        if c.is_alphanumeric() {
            if gap && !out.is_empty() {
                out.push(' ');
            }
            gap = false;
            out.push(c);
        } else {
            gap = true;
        }
    }
    out
}

/// The author's surname as the title key uses it: the last word of the normalised text before the first comma
/// ("Tolkien, J. R. R." gives "tolkien"), or of the whole name when there is no comma ("J. R. R. Tolkien" gives "tolkien").
/// Empty when the name has no letters or digits.
pub fn author_surname(author: &str) -> String {
    let head = author.split(',').next().unwrap_or("");
    normalise_title(head).rsplit(' ').next().unwrap_or("").to_string()
}

fn isbn10_ok(b: &[u8]) -> bool {
    if b.len() != 10 {
        return false;
    }
    let mut total = 0u32;
    for (i, &c) in b.iter().enumerate() {
        let v = match c {
            b'0'..=b'9' => u32::from(c - b'0'),
            b'X' | b'x' if i == 9 => 10,
            _ => return false,
        };
        total += v * (10 - i as u32);
    }
    total % 11 == 0
}

fn isbn13_check(first12: &[u8]) -> u8 {
    let sum: u32 = first12.iter().enumerate().map(|(i, &c)| u32::from(c - b'0') * if i % 2 == 0 { 1 } else { 3 }).sum();
    b'0' + ((10 - sum % 10) % 10) as u8
}

/// An ISBN-10 or ISBN-13 (hyphens and spaces ignored, any other character rejects it) as the 13 digits of its ISBN-13,
/// or `None` when the length or the check digit is wrong. A 13-digit number must start 978 or 979.
pub fn isbn13(s: &str) -> Option<String> {
    let mut digits = Vec::with_capacity(13);
    for c in s.trim().bytes() {
        match c {
            b'0'..=b'9' | b'X' | b'x' => digits.push(c),
            b'-' | b' ' => {}
            _ => return None,
        }
    }
    if digits.len() == 10 && isbn10_ok(&digits) {
        let mut b = b"978".to_vec();
        b.extend_from_slice(&digits[..9]);
        let check = isbn13_check(&b);
        b.push(check);
        return String::from_utf8(b).ok();
    }
    if digits.len() == 13
        && digits.iter().all(u8::is_ascii_digit)
        && (digits.starts_with(b"978") || digits.starts_with(b"979"))
        && isbn13_check(&digits[..12]) == digits[12]
    {
        return String::from_utf8(digits).ok();
    }
    None
}

/// Every valid ISBN in `text`, as ISBN-13 digits, in order of first appearance and without repeats.
///
/// A candidate is a whitespace-separated word (outer punctuation such as brackets and full stops trimmed) made only of digits
/// and hyphens, with an `X` allowed as the last character: "ISBN 978-0-441-17271-9", "0441172717", "(0-441-17271-7)". The
/// check digit must be right, so dates and page ranges are not read as ISBNs. Digit groups split by spaces are not joined.
pub fn extract_isbns(text: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for word in text.split_whitespace() {
        let w = word.trim_matches(|c: char| !c.is_ascii_alphanumeric());
        if w.len() < 10 || !w.bytes().all(|c| c.is_ascii_digit() || c == b'-' || c == b'X' || c == b'x') {
            continue;
        }
        if let Some(i) = isbn13(w) {
            if seen.insert(i.clone()) {
                out.push(i);
            }
        }
    }
    out
}

/// The share of the shorter title's letters (counted by word length, so short words such as "the" weigh little) that the
/// other title also has, below which [`accept_isbn_match`] refuses an ISBN match.
pub const MIN_TITLE_OVERLAP: f64 = 0.6;

/// The safety rule for an ISBN match: accept the catalogue entry only when its title agrees with the book's own title.
///
/// Wikipedia printouts and bibliographies cite other books' ISBNs, so an ISBN found in a book's text is no proof the book is
/// that one. Both titles are normalised and split into words; the score is the total length of the words they share divided
/// by the total length of the words of the shorter title (the book's title may carry a subtitle or file-name noise, the
/// catalogue's may be cut at 100 characters). A match is accepted when the score is at least [`MIN_TITLE_OVERLAP`] (0.6).
/// Weighting by word length keeps "The Stand" from agreeing with "The Great Gatsby" on "the" alone (3 of 8 letters, 0.375).
/// Titles with no words never agree.
pub fn accept_isbn_match(entry_title: &str, book_title: &str) -> bool {
    let a = normalise_title(entry_title);
    let b = normalise_title(book_title);
    let wa: HashSet<&str> = a.split(' ').filter(|w| !w.is_empty()).collect();
    let wb: HashSet<&str> = b.split(' ').filter(|w| !w.is_empty()).collect();
    let weight = |s: &HashSet<&str>| -> usize { s.iter().map(|w| w.chars().count()).sum() };
    let (ta, tb) = (weight(&wa), weight(&wb));
    let smaller = ta.min(tb);
    if smaller == 0 {
        return false;
    }
    let shared: usize = wa.intersection(&wb).map(|w| w.chars().count()).sum();
    shared as f64 / smaller as f64 >= MIN_TITLE_OVERLAP
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalises_like_the_build_script() {
        assert_eq!(normalise_title("Moby-Dick; or, The Whale"), "moby dick or the whale");
        assert_eq!(normalise_title("  A_B  c "), "a b c");
        assert_eq!(normalise_title("Les Misérables"), "les misérables");
        assert_eq!(normalise_title("Война и мир"), "война и мир");
        assert_eq!(normalise_title("Gulliver\u{2019}s Travels"), "gulliver s travels");
        assert_eq!(normalise_title("???"), "");
    }

    #[test]
    fn surnames() {
        assert_eq!(author_surname("Tolkien, J. R. R."), "tolkien");
        assert_eq!(author_surname("J. R. R. Tolkien"), "tolkien");
        assert_eq!(author_surname("Brontë, Emily"), "brontë");
        assert_eq!(author_surname("Plato"), "plato");
        assert_eq!(author_surname("van Gogh, Vincent"), "gogh");
        assert_eq!(author_surname(""), "");
    }

    #[test]
    fn isbn_conversion_and_checksums() {
        assert_eq!(isbn13("0-441-17271-7").as_deref(), Some("9780441172719"));
        assert_eq!(isbn13("0441172717").as_deref(), Some("9780441172719"));
        assert_eq!(isbn13("978-0-441-17271-9").as_deref(), Some("9780441172719"));
        assert_eq!(isbn13("9780441172718"), None);
        assert_eq!(isbn13("0441172718"), None);
        assert_eq!(isbn13("0-8044-2957-X").as_deref(), Some("9780804429573"));
        assert_eq!(isbn13("1234567890123"), None);
        assert_eq!(isbn13("abc"), None);
    }

    #[test]
    fn extracts_isbns_from_text() {
        let t = "See Herbert, Dune (1965), ISBN 978-0-441-17271-9. Also ISBN 0-441-17271-7; bad: 978-0-441-17271-8, \
                 date 2024-01-12, pages 1234567890 and ISBN: 9780141439518.";
        assert_eq!(extract_isbns(t), vec!["9780441172719", "9780141439518"]);
        assert!(extract_isbns("no numbers here").is_empty());
    }

    #[test]
    fn isbn_title_rule() {
        assert!(accept_isbn_match("Dune", "Dune"));
        assert!(accept_isbn_match("Dune", "Dune - Frank Herbert (z-lib.org)"));
        assert!(accept_isbn_match("A Brief History of Time From the Big Bang to Black Holes", "A Brief History of Time"));
        assert!(!accept_isbn_match("The Great Gatsby", "The Stand"));
        assert!(!accept_isbn_match("Introduction to Algorithms", "Dune"));
        assert!(!accept_isbn_match("", "Dune"));
        assert!(!accept_isbn_match("???", "???"));
    }
}
