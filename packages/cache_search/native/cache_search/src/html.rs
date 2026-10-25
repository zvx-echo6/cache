//! HTML to plain text: a small streaming stripper, plus the text-cutting helpers shared by the index,
//! search snippets and `cs_read`.
//!
//! Output rules: content of `script`, `style`, `head`, `title`, `nav`, `footer`, `aside`, `noscript`,
//! `template`, `svg`, `iframe`, `select`, `button`, `textarea` and comments is dropped. Block tags
//! become line breaks (headings, paragraphs, lists, tables and blockquotes are separated by a blank line;
//! `div`, `li`, `tr`, `br` by a single newline). Whitespace inside a line collapses to one space.
//! Entities are decoded (`html-escape`). Malformed markup never panics; an unclosed skipped element
//! drops the rest of the document.

/// Elements whose whole content is dropped.
const SKIP: &[&str] = &[
    "script", "style", "head", "title", "nav", "footer", "aside", "noscript", "template", "svg", "iframe",
    "select", "button", "textarea",
];
/// Skipped elements whose content is raw text (may contain `<`), so the end tag is searched for directly.
const RAW: &[&str] = &["script", "style", "title", "textarea"];
/// Tags that end a paragraph-level block (blank line before and after).
const PARA: &[&str] = &[
    "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table", "ul", "ol", "dl", "section",
    "article", "figure", "details", "hr",
];
/// Tags that start a new line.
const LINE: &[&str] = &[
    "div", "li", "tr", "br", "dt", "dd", "header", "main", "figcaption", "caption", "summary", "address",
    "form", "fieldset",
];

struct Out {
    buf: String,
    brk: u8,
    space: bool,
}

impl Out {
    fn text(&mut self, s: &str) {
        for c in s.chars() {
            if c.is_whitespace() || c == '\u{200b}' || c == '\u{feff}' {
                self.space = true;
                continue;
            }
            if !self.buf.is_empty() {
                if self.brk > 0 {
                    for _ in 0..self.brk {
                        self.buf.push('\n');
                    }
                } else if self.space {
                    self.buf.push(' ');
                }
            }
            self.brk = 0;
            self.space = false;
            self.buf.push(c);
        }
    }
    fn brk(&mut self, n: u8) {
        if n > self.brk {
            self.brk = n;
        }
    }
}

fn find_ci(hay: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    let last = hay.len() - needle.len();
    let mut i = from;
    while i <= last {
        if hay[i..i + needle.len()].eq_ignore_ascii_case(needle) {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// End of the tag starting at `start` (index of '<'): the index just past its '>', honouring quoted
/// attribute values. `None` if the tag never ends.
fn tag_end(b: &[u8], start: usize) -> Option<usize> {
    let mut i = start + 1;
    let mut quote = 0u8;
    while i < b.len() {
        let c = b[i];
        if quote != 0 {
            if c == quote {
                quote = 0;
            }
        } else if c == b'"' || c == b'\'' {
            quote = c;
        } else if c == b'>' {
            return Some(i + 1);
        }
        i += 1;
    }
    None
}

/// Elements with no content and no end tag.
const VOID: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
];

/// Value of attribute `name` in the source of one start tag (`div class="x" role=main>`).
fn attr_value(tag: &str, name: &str) -> Option<String> {
    let b = tag.as_bytes();
    let mut i = 0;
    while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'>' && b[i] != b'/' {
        i += 1; // the tag name
    }
    loop {
        while i < b.len() && (b[i].is_ascii_whitespace() || b[i] == b'/') {
            i += 1;
        }
        if i >= b.len() || b[i] == b'>' {
            return None;
        }
        let ns = i;
        while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'=' && b[i] != b'>' && b[i] != b'/' {
            i += 1;
        }
        let an = &tag[ns..i];
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        let mut val = "";
        if i < b.len() && b[i] == b'=' {
            i += 1;
            while i < b.len() && b[i].is_ascii_whitespace() {
                i += 1;
            }
            if i < b.len() && (b[i] == b'"' || b[i] == b'\'') {
                let q = b[i];
                let vs = i + 1;
                i = vs;
                while i < b.len() && b[i] != q {
                    i += 1;
                }
                val = &tag[vs..i.min(b.len())];
                i += 1;
            } else {
                let vs = i;
                while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'>' {
                    i += 1;
                }
                val = &tag[vs..i];
            }
        }
        if an.eq_ignore_ascii_case(name) {
            return Some(val.to_string());
        }
    }
}

fn has_attr_hint(tag: &str) -> bool {
    let b = tag.as_bytes();
    find_ci(b, 0, b"role").is_some() || find_ci(b, 0, b"aria-hidden").is_some()
}

/// Start tags whose element is page chrome: `role` navigation / banner / search, or `aria-hidden="true"`.
fn drop_by_attr(tag: &str) -> bool {
    if !has_attr_hint(tag) {
        return false;
    }
    if let Some(r) = attr_value(tag, "role") {
        let r = r.trim().to_ascii_lowercase();
        if r == "navigation" || r == "banner" || r == "search" {
            return true;
        }
    }
    matches!(attr_value(tag, "aria-hidden"), Some(v) if v.trim().eq_ignore_ascii_case("true"))
}

/// Byte range (content only) of the largest `<main>`, `<article>` or `role="main"` element, if any.
fn find_main(html: &str) -> Option<(usize, usize)> {
    let b = html.as_bytes();
    // (name, content start, candidate?)
    let mut stack: Vec<(String, usize, bool)> = Vec::new();
    let mut best: Option<(usize, usize)> = None;
    let consider = |s: usize, e: usize, best: &mut Option<(usize, usize)>| {
        if e > s && best.map(|(bs, be)| e - s > be - bs).unwrap_or(true) {
            *best = Some((s, e));
        }
    };
    let mut i = 0usize;
    while i < b.len() {
        if b[i] != b'<' {
            i += 1;
            continue;
        }
        if b[i..].starts_with(b"<!--") {
            i = find_ci(b, i + 4, b"-->").map(|p| p + 3).unwrap_or(b.len());
            continue;
        }
        let next = b.get(i + 1).copied().unwrap_or(0);
        if next == b'!' || next == b'?' {
            i = tag_end(b, i).unwrap_or(b.len());
            continue;
        }
        if !(next == b'/' || next.is_ascii_alphabetic()) {
            i += 1;
            continue;
        }
        let Some(end) = tag_end(b, i) else { break };
        let closing = next == b'/';
        let ns = if closing { i + 2 } else { i + 1 };
        let mut ne = ns;
        while ne < end && (b[ne].is_ascii_alphanumeric() || b[ne] == b':' || b[ne] == b'-') {
            ne += 1;
        }
        let name = html[ns..ne].to_ascii_lowercase();
        let self_closing = end >= 2 && b[end - 2] == b'/';
        if closing {
            if let Some(pos) = stack.iter().rposition(|s| s.0 == name) {
                for (_, cs, cand) in stack.drain(pos..) {
                    if cand {
                        consider(cs, i, &mut best);
                    }
                }
            }
            i = end;
            continue;
        }
        if self_closing || VOID.contains(&name.as_str()) {
            i = end;
            continue;
        }
        if RAW.contains(&name.as_str()) {
            let pat = format!("</{name}");
            i = match find_ci(b, end, pat.as_bytes()) {
                Some(p) => tag_end(b, p).unwrap_or(b.len()),
                None => b.len(),
            };
            continue;
        }
        let cand = name == "main"
            || name == "article"
            || (find_ci(html[ns..end].as_bytes(), 0, b"role").is_some()
                && attr_value(&html[ns..end], "role").map(|r| r.trim().eq_ignore_ascii_case("main")).unwrap_or(false));
        stack.push((name, end, cand));
        i = end;
    }
    for (_, cs, cand) in stack {
        if cand {
            consider(cs, b.len(), &mut best);
        }
    }
    best
}

/// Plain text of a page. If it has a `<main>`, `<article>` or `role="main"` element, only the largest such
/// element is used (so site headers, banners and menus outside it are left out); otherwise the whole
/// document. Inside, `role` navigation / banner / search and `aria-hidden="true"` elements are dropped.
pub fn html_to_text(html: &str) -> String {
    if let Some((s, e)) = find_main(html) {
        let t = strip(&html[s..e]);
        if !t.is_empty() {
            return t;
        }
    }
    strip(html)
}

/// The streaming stripper (no main-content selection).
pub fn strip(html: &str) -> String {
    let b = html.as_bytes();
    let mut out = Out { buf: String::with_capacity(html.len() / 3), brk: 0, space: false };
    let mut skip: Option<(String, u32)> = None;
    let mut i = 0usize;
    while i < b.len() {
        if b[i] == b'<' {
            if b[i..].starts_with(b"<!--") {
                i = match find_ci(b, i + 4, b"-->") {
                    Some(p) => p + 3,
                    None => b.len(),
                };
                continue;
            }
            let next = b.get(i + 1).copied().unwrap_or(0);
            if next == b'!' || next == b'?' {
                i = tag_end(b, i).unwrap_or(b.len());
                continue;
            }
            if next == b'/' || next.is_ascii_alphabetic() {
                let end = match tag_end(b, i) {
                    Some(e) => e,
                    None => break,
                };
                let closing = next == b'/';
                let ns = if closing { i + 2 } else { i + 1 };
                let mut ne = ns;
                while ne < end && (b[ne].is_ascii_alphanumeric() || b[ne] == b':' || b[ne] == b'-') {
                    ne += 1;
                }
                let name = html[ns..ne].to_ascii_lowercase();
                let self_closing = end >= 2 && b[end - 2] == b'/';
                i = end;
                if let Some((sname, depth)) = skip.as_mut() {
                    if name == sname.as_str() {
                        if closing {
                            if *depth <= 1 {
                                skip = None;
                            } else {
                                *depth -= 1;
                            }
                        } else if !self_closing {
                            *depth += 1;
                        }
                    }
                    continue;
                }
                if !closing && !self_closing {
                    if let Some(s) = SKIP.iter().find(|s| **s == name) {
                        if RAW.contains(s) {
                            // jump past the matching end tag
                            let pat = format!("</{s}");
                            match find_ci(b, i, pat.as_bytes()) {
                                Some(p) => i = tag_end(b, p).unwrap_or(b.len()),
                                None => i = b.len(),
                            }
                        } else {
                            skip = Some((s.to_string(), 1));
                        }
                        continue;
                    }
                    if !VOID.contains(&name.as_str()) && drop_by_attr(&html[ns..end]) {
                        skip = Some((name, 1));
                        continue;
                    }
                }
                if PARA.contains(&name.as_str()) {
                    out.brk(2);
                } else if LINE.contains(&name.as_str()) {
                    out.brk(1);
                } else if name == "td" || name == "th" {
                    out.space = true;
                }
                continue;
            }
            // a stray '<' is text
        }
        // text run up to the next '<' (a stray '<' is included as the first char)
        let mut j = i + 1;
        while j < b.len() && b[j] != b'<' {
            j += 1;
        }
        if skip.is_none() {
            let decoded = html_escape::decode_html_entities(&html[i..j]);
            out.text(&decoded);
        }
        i = j;
    }
    out.buf
}

/// Cut `s` to at most `max` chars, preferably at a paragraph end (a newline), else at a sentence end,
/// else at a word boundary, else hard. Returns the text and whether it was cut.
pub fn cut_at_paragraph(s: &str, max: usize) -> (String, bool) {
    if s.chars().count() <= max {
        return (s.trim_end().to_string(), false);
    }
    let end_byte = s.char_indices().nth(max).map(|(i, _)| i).unwrap_or(s.len());
    let head = &s[..end_byte];
    // `s[end_byte..]` starts a new char; if it is a newline the head already ends a paragraph.
    if s[end_byte..].starts_with('\n') {
        return (head.trim_end().to_string(), true);
    }
    if let Some(p) = head.rfind('\n') {
        let cut = head[..p].trim_end();
        if !cut.is_empty() {
            return (cut.to_string(), true);
        }
    }
    if let Some(e) = last_sentence_end(head) {
        return (head[..e].trim_end().to_string(), true);
    }
    if let Some(p) = head.rfind(char::is_whitespace) {
        if p > 0 {
            return (head[..p].trim_end().to_string(), true);
        }
    }
    (head.to_string(), true)
}

/// Byte index just past the last sentence end (`.`, `!`, `?` followed by whitespace or the end of `s`),
/// optionally with closing quotes or brackets.
fn last_sentence_end(s: &str) -> Option<usize> {
    let mut best = None;
    let mut it = s.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        if matches!(c, '.' | '!' | '?' | '\u{2026}' | '\u{3002}') {
            let mut end = i + c.len_utf8();
            while let Some(&(j, d)) = it.peek() {
                if matches!(d, '"' | '\'' | ')' | ']' | '\u{201d}' | '\u{2019}') {
                    end = j + d.len_utf8();
                    it.next();
                } else {
                    break;
                }
            }
            match it.peek() {
                None => best = Some(end),
                Some(&(_, d)) if d.is_whitespace() => best = Some(end),
                _ => {}
            }
        }
    }
    best
}

/// A snippet of at most `max` chars from `text` (whitespace collapsed to single spaces): the whole text if
/// it fits, else cut at a sentence end that keeps at least 40% of `max`, else at a word boundary with a
/// trailing `…` (counted in `max`).
pub fn snippet_from_text(text: &str, max: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if max == 0 {
        return String::new();
    }
    if flat.chars().count() <= max {
        return flat;
    }
    let end_byte = flat.char_indices().nth(max).map(|(i, _)| i).unwrap_or(flat.len());
    let head = &flat[..end_byte];
    if let Some(e) = last_sentence_end(head) {
        if head[..e].chars().count() * 10 >= max * 4 {
            return head[..e].to_string();
        }
    }
    let budget = max.saturating_sub(1);
    let end_byte = flat.char_indices().nth(budget).map(|(i, _)| i).unwrap_or(flat.len());
    let head = &flat[..end_byte];
    let cut = match head.rfind(' ') {
        Some(p) if p > 0 => &head[..p],
        _ => head,
    };
    format!("{}\u{2026}", cut.trim_end_matches(|c: char| c.is_ascii_punctuation() && c != '.'))
}

/// Tidy a search-engine snippet fragment (already plain text, at most `max` chars): collapse whitespace; if it
/// does not end at a sentence end, cut back to one that keeps at least 40% of it.
pub fn tidy_fragment(frag: &str) -> String {
    let flat = frag.split_whitespace().collect::<Vec<_>>().join(" ");
    if last_sentence_end(&flat) == Some(flat.len()) {
        return flat;
    }
    if let Some(e) = last_sentence_end(&flat) {
        if flat[..e].chars().count() * 10 >= flat.chars().count() * 4 {
            return flat[..e].to_string();
        }
    }
    flat
}

/// The first ~`max` chars of `text` for the `lead` field: whole text if it fits, else cut at a word
/// boundary in the last 15%.
pub fn lead_of(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let end_byte = text.char_indices().nth(max).map(|(i, _)| i).unwrap_or(text.len());
    let head = &text[..end_byte];
    let floor = head.char_indices().nth(max * 85 / 100).map(|(i, _)| i).unwrap_or(0);
    match head.rfind(char::is_whitespace) {
        Some(p) if p >= floor => head[..p].to_string(),
        _ => head.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_tags_and_decodes_entities() {
        let t = html_to_text("<p>Tom &amp; Jerry&nbsp;are <b>here</b>&#33; caf&eacute;</p>");
        assert_eq!(t, "Tom & Jerry are here! café");
    }

    #[test]
    fn headings_and_paragraphs_get_their_own_lines() {
        let t = html_to_text("<h1>Title</h1><p>One two.</p><p>Three<br>four</p><ul><li>a</li><li>b</li></ul>");
        assert_eq!(t, "Title\n\nOne two.\n\nThree\nfour\n\na\nb");
    }

    #[test]
    fn drops_script_style_nav_head_and_comments() {
        let t = html_to_text(
            "<html><head><title>T</title><style>p{}</style></head><body><nav><ul><li>menu</li></ul></nav>\
             <script>if (a<b && c>d) { x(\"</p>\") }</script><!-- hidden <p>x</p> --><p>Body</p>\
             <footer>foot</footer><aside>side</aside></body></html>",
        );
        assert_eq!(t, "Body");
    }

    #[test]
    fn nested_same_name_skip() {
        let t = html_to_text("<nav>a<nav>b</nav>c</nav><p>x</p>");
        assert_eq!(t, "x");
    }

    #[test]
    fn quoted_gt_in_attribute() {
        let t = html_to_text("<a title=\"a > b\" href='x'>link</a> text");
        assert_eq!(t, "link text");
    }

    #[test]
    fn stray_lt_and_malformed_do_not_panic() {
        assert_eq!(html_to_text("1 < 2 and 3 > 2"), "1 < 2 and 3 > 2");
        assert_eq!(html_to_text("<p>unterminated <b"), "unterminated");
        assert_eq!(html_to_text("<script>never closed"), "");
        assert_eq!(html_to_text(""), "");
        let _ = html_to_text("<<<>>><!<?>&&&&;<");
    }

    #[test]
    fn table_cells_separated_by_spaces() {
        assert_eq!(html_to_text("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>"), "a b\nc");
    }

    #[test]
    fn unicode_is_preserved() {
        assert_eq!(html_to_text("<p>日本語 — ünï</p>"), "日本語 — ünï");
    }

    #[test]
    fn cut_at_paragraph_prefers_newline() {
        let s = "First paragraph here.\nSecond paragraph is longer than the rest.";
        let (t, cut) = cut_at_paragraph(s, 30);
        assert!(cut);
        assert_eq!(t, "First paragraph here.");
        let (t, cut) = cut_at_paragraph(s, 1000);
        assert!(!cut);
        assert_eq!(t, s);
    }

    #[test]
    fn cut_at_paragraph_falls_back_to_sentence_word_hard() {
        let (t, _) = cut_at_paragraph("One sentence. Two sentence goes on and on", 25);
        assert_eq!(t, "One sentence.");
        let (t, _) = cut_at_paragraph("alpha beta gamma delta", 12);
        assert_eq!(t, "alpha beta");
        let (t, c) = cut_at_paragraph("abcdefghijklmnop", 5);
        assert_eq!((t.as_str(), c), ("abcde", true));
        let (t, _) = cut_at_paragraph("ééééééé", 3);
        assert_eq!(t, "ééé");
    }

    #[test]
    fn cut_exactly_at_paragraph_boundary() {
        let (t, cut) = cut_at_paragraph("abc\ndef", 3);
        assert_eq!((t.as_str(), cut), ("abc", true));
    }

    #[test]
    fn snippet_cuts_at_sentence_end() {
        let s = "The quick brown fox jumps. It then rests under the old tree for a long while and sleeps.";
        let t = snippet_from_text(s, 40);
        assert_eq!(t, "The quick brown fox jumps.");
        assert!(t.chars().count() <= 40);
    }

    #[test]
    fn snippet_ellipsis_when_no_sentence_end() {
        let s = "word ".repeat(100);
        let t = snippet_from_text(&s, 50);
        assert!(t.chars().count() <= 50, "{t}");
        assert!(t.ends_with('\u{2026}'));
        assert_eq!(snippet_from_text("short text", 50), "short text");
        assert_eq!(snippet_from_text("a\n\nb   c", 50), "a b c");
    }

    #[test]
    fn tidy_fragment_trims_trailing_partial_sentence() {
        assert_eq!(tidy_fragment("Floods are bad. They happen when it"), "Floods are bad.");
        assert_eq!(tidy_fragment("only a fragment of text"), "only a fragment of text");
        assert_eq!(tidy_fragment("Complete sentence."), "Complete sentence.");
    }

    #[test]
    fn lead_cuts_on_word_boundary() {
        let s = "word ".repeat(1000);
        let l = lead_of(&s, 1500);
        assert!(l.chars().count() <= 1500 && l.chars().count() > 1400);
        assert!(l.ends_with("word"));
        assert_eq!(lead_of("tiny", 1500), "tiny");
    }

    #[test]
    fn main_content_only() {
        let t = html_to_text(
            "<body><header><a>Skip to main content</a> Search the site</header><nav>menu</nav>\
             <main><h1>Real title</h1><p>Real text.</p></main><footer>foot</footer></body>",
        );
        assert_eq!(t, "Real title\n\nReal text.");
    }

    #[test]
    fn largest_main_candidate_wins_and_role_main_counts() {
        let t = html_to_text(
            "<div><article>card</article><div role=\"main\"><p>The big body of the page with lots of words.</p>\
             <article>inner</article></div></div>",
        );
        assert_eq!(t, "The big body of the page with lots of words.\n\ninner");
    }

    #[test]
    fn no_main_falls_back_to_whole_document_including_header() {
        let t = html_to_text("<header>Site</header><p>Body</p><footer>f</footer>");
        assert_eq!(t, "Site\n\nBody");
        // a main with no text falls back too
        assert_eq!(html_to_text("<main><img src=x></main><p>Body</p>"), "Body");
    }

    #[test]
    fn header_inside_main_is_kept_chrome_roles_are_dropped() {
        let t = html_to_text(
            "<main><header><h1>Article head</h1></header>\
             <div role=\"navigation\"><div>nested</div>links</div><div role='banner'>ban</div>\
             <form role=search><div>find</div></form><span aria-hidden=\"true\">icon</span>\
             <p aria-hidden=\"false\">visible</p><img aria-hidden=\"true\" src=a><p>end</p></main>",
        );
        assert_eq!(t, "Article head\n\nvisible\n\nend");
    }

    #[test]
    fn attr_parsing() {
        assert_eq!(attr_value("div class=\"a b\" role = 'main' id=x>", "role").as_deref(), Some("main"));
        assert_eq!(attr_value("div ROLE=Main>", "role").as_deref(), Some("Main"));
        assert_eq!(attr_value("div data-x=\"role=main\">", "role"), None);
        assert_eq!(attr_value("input disabled aria-hidden=true >", "aria-hidden").as_deref(), Some("true"));
    }
}
