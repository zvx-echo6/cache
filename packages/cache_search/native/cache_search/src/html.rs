//! HTML to plain text: a small streaming stripper, plus the text-cutting helpers shared by the index,
//! search snippets and `cs_read`.
//!
//! `html_to_text` keeps only a page's main content (see `extract`: a declared `main`/`article`/`role="main"`, else the
//! densest element, else the whole page); the rules below are what the stripper does with the markup it keeps.
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

/// Start tags whose element is page chrome: `role` navigation / banner / contentinfo / complementary / search, or
/// `aria-hidden="true"`.
fn drop_by_attr(tag: &str) -> bool {
    if !has_attr_hint(tag) {
        return false;
    }
    if let Some(r) = attr_value(tag, "role") {
        let r = r.trim().to_ascii_lowercase();
        if matches!(r.as_str(), "navigation" | "banner" | "contentinfo" | "complementary" | "search") {
            return true;
        }
    }
    matches!(attr_value(tag, "aria-hidden"), Some(v) if v.trim().eq_ignore_ascii_case("true"))
}

/// The page's own sectioning elements: a `header` inside one of these is that section's heading (an article's title
/// block, say), not the page banner, so it stays.
const SECTIONING: &[&str] = &["article", "aside", "main", "nav", "section"];

/// Elements that may be open inside a `p` without ending it (so a new block still ends the `p`).
const INLINE: &[&str] = &[
    "a", "abbr", "b", "bdi", "bdo", "big", "cite", "code", "data", "del", "dfn", "em", "font", "i", "ins", "kbd", "mark", "q",
    "s", "samp", "small", "span", "strike", "strong", "sub", "sup", "time", "tt", "u", "var",
];

/// Start tags that end an open `p` (the optional end tag of HTML 4 pages).
const ENDS_P: &[&str] = &[
    "p", "div", "ul", "ol", "dl", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "section", "article",
    "aside", "nav", "header", "footer", "main", "form", "hr", "figure", "fieldset", "address", "details", "li", "dt", "dd",
];

/// An extracted text shorter than this many characters is not trusted when the page declares no main element: the
/// whole page text is used instead (a page that short has no room for a menu to bury it).
pub const MIN_DENSITY_CHARS: usize = 200;

/// The elements the walk may enter: containers. A paragraph, heading or list is never entered, so the heading beside the one
/// big paragraph of a short article stays with it.
const CONTAINERS: &[&str] = &["div", "section", "article", "main", "table", "tbody", "thead", "tr", "td", "th", "center", "font", "form", "body"];

/// Blocks that may be cut as link lists (see `PRUNE_LINK_SHARE`).
const PRUNABLE: &[&str] = &["div", "p", "ul", "ol", "dl", "table", "center", "section", "form"];
/// In the density walk's content, a block of which at least this share of the text is link text, and that holds at least
/// two links, is a list of links (a menu, "previous / next", related pages), not prose, and is left out.
const PRUNE_LINK_SHARE: f64 = 0.8;

/// A child element is entered when it holds at least this share of its parent's text (link text not counted).
const DOMINANT_SHARE: f64 = 0.7;
/// ... and the walk stops when the element holds less than this share of the text it started with.
const KEEP_SHARE: f64 = 0.5;

/// One element of the lightweight tree `parse` builds (byte offsets into the page).
struct Node {
    name: String,
    parent: usize,
    /// Index of the `<` of the start tag.
    start: usize,
    /// Content start (past the start tag) and end (the `<` of the end tag, or where an implied end came).
    cstart: usize,
    cend: usize,
    /// Past the end tag.
    end: usize,
    /// `main`, `article` or `role="main"`.
    main_like: bool,
    /// Left out of the text: `strip` drops it by name or attribute, or it is a banner-like `header`.
    chrome: bool,
    /// Chrome that `strip` would keep (the banner `header`), so the cut list carries it.
    cut: bool,
    /// An `a` with an `href` (an anchor with only a name is just text).
    is_link: bool,
    /// Characters of text under it that are not in chrome, how many of them are link text, and how many links (`a href`)
    /// it holds.
    text: usize,
    link: usize,
    links: usize,
}

const NONE: usize = usize::MAX;

fn is_ws(c: char) -> bool {
    c.is_whitespace() || c == '\u{200b}' || c == '\u{feff}'
}

fn text_len(run: &str) -> usize {
    if run.contains('&') {
        html_escape::decode_html_entities(run).chars().filter(|c| !is_ws(*c)).count()
    } else {
        run.chars().filter(|c| !is_ws(*c)).count()
    }
}

/// The element tree of a page: one pass, tolerant of any markup (an unclosed element ends where its parent ends;
/// the optional end tags of `p`, `li`, `dt`, `dd`, `tr`, `td` and `th` are implied). Elements of raw text, comments and
/// void elements get no node. The text counts are over what `strip` would keep.
fn parse(html: &str) -> Vec<Node> {
    let b = html.as_bytes();
    let mut nodes: Vec<Node> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut chrome_depth = 0usize;
    let mut a_depth = 0usize;
    let mut i = 0usize;

    // Close `stack[pos..]`: the element at `pos` ends at `end`, those above it at `at`.
    fn close(nodes: &mut [Node], stack: &mut Vec<usize>, pos: usize, at: usize, end: usize, chrome_depth: &mut usize, a_depth: &mut usize) {
        while stack.len() > pos {
            let k = stack.pop().unwrap();
            nodes[k].cend = at;
            nodes[k].end = if stack.len() == pos { end } else { at };
            if nodes[k].chrome {
                *chrome_depth -= 1;
            }
            if nodes[k].is_link {
                *a_depth = a_depth.saturating_sub(1);
            }
            let (t, l, n, parent) = (nodes[k].text, nodes[k].link, nodes[k].links, nodes[k].parent);
            if parent != NONE {
                nodes[parent].text += t;
                nodes[parent].link += l;
                nodes[parent].links += n;
            }
        }
    }

    while i < b.len() {
        if b[i] != b'<' {
            let mut j = i + 1;
            while j < b.len() && b[j] != b'<' {
                j += 1;
            }
            if chrome_depth == 0 {
                if let Some(&top) = stack.last() {
                    let n = text_len(&html[i..j]);
                    nodes[top].text += n;
                    if a_depth > 0 {
                        nodes[top].link += n;
                    }
                }
            }
            i = j;
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
            // a stray '<' is text
            if chrome_depth == 0 {
                if let Some(&top) = stack.last() {
                    nodes[top].text += 1;
                }
            }
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
            if let Some(pos) = stack.iter().rposition(|&k| nodes[k].name == name) {
                close(&mut nodes, &mut stack, pos, i, end, &mut chrome_depth, &mut a_depth);
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
        // implied end tags
        let ends: Option<usize> = match name.as_str() {
            "li" => stack.iter().rposition(|&k| nodes[k].name == "li").filter(|&p| !stack[p..].iter().any(|&k| matches!(nodes[k].name.as_str(), "ul" | "ol"))),
            "dt" | "dd" => stack.iter().rposition(|&k| matches!(nodes[k].name.as_str(), "dt" | "dd")).filter(|&p| !stack[p..].iter().any(|&k| nodes[k].name == "dl")),
            "td" | "th" => stack.iter().rposition(|&k| matches!(nodes[k].name.as_str(), "td" | "th")).filter(|&p| !stack[p..].iter().any(|&k| matches!(nodes[k].name.as_str(), "tr" | "table"))),
            "tr" => stack.iter().rposition(|&k| nodes[k].name == "tr").filter(|&p| !stack[p..].iter().any(|&k| nodes[k].name == "table")),
            _ => None,
        };
        if let Some(pos) = ends {
            close(&mut nodes, &mut stack, pos, i, i, &mut chrome_depth, &mut a_depth);
        }
        if ENDS_P.contains(&name.as_str()) {
            // the nearest open `p`, if only inline elements are between it and here
            let mut p = None;
            for (pos, &k) in stack.iter().enumerate().rev() {
                let n = nodes[k].name.as_str();
                if n == "p" {
                    p = Some(pos);
                    break;
                }
                if !INLINE.contains(&n) {
                    break;
                }
            }
            if let Some(pos) = p {
                close(&mut nodes, &mut stack, pos, i, i, &mut chrome_depth, &mut a_depth);
            }
        }
        let tag = &html[ns..end];
        let skip_name = SKIP.contains(&name.as_str());
        let by_attr = !skip_name && drop_by_attr(tag);
        let main_like = name == "main"
            || name == "article"
            || (find_ci(tag.as_bytes(), 0, b"role").is_some()
                && attr_value(tag, "role").map(|r| r.trim().eq_ignore_ascii_case("main")).unwrap_or(false));
        let banner = name == "header" && !stack.iter().any(|&k| SECTIONING.contains(&nodes[k].name.as_str()) || nodes[k].main_like);
        let chrome = skip_name || by_attr || banner;
        let is_link = name == "a" && attr_value(tag, "href").is_some();
        let idx = nodes.len();
        nodes.push(Node {
            name: name.clone(),
            parent: stack.last().copied().unwrap_or(NONE),
            start: i,
            cstart: end,
            cend: b.len(),
            end: b.len(),
            main_like,
            chrome,
            cut: banner,
            is_link,
            text: 0,
            link: 0,
            links: usize::from(is_link),
        });
        if chrome {
            chrome_depth += 1;
        }
        if is_link {
            a_depth += 1;
        }
        stack.push(idx);
        i = end;
    }
    let at = b.len();
    close(&mut nodes, &mut stack, 0, at, at, &mut chrome_depth, &mut a_depth);
    nodes
}

/// How `extract` chose the text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Via {
    /// The largest `main`, `article` or `role="main"` element.
    Main,
    /// The element that holds most of the page's text, found by walking down from `body` (link text not counted).
    Density,
    /// The whole page (the density walk found less than `MIN_DENSITY_CHARS`).
    Whole,
}

/// The text of a page and where it came from.
#[derive(Clone, Debug)]
pub struct Extract {
    pub text: String,
    pub via: Via,
    /// The element the text was cut from: its name and content byte range (the whole page for `Whole`).
    pub root_name: String,
    pub root: (usize, usize),
}

/// Plain text of a page: its main content, with the menus, banners and footers left out. See `extract`.
pub fn html_to_text(html: &str) -> String {
    extract(html).text
}

/// Main-content extraction (structure and measures only; no word lists):
///
/// 1. Elements `strip` drops (`nav`, `aside`, `footer`, `script`, `style`, `head`, forms' controls, ...), elements with
///    `role` navigation, banner, contentinfo, complementary or search, `aria-hidden="true"`, and a `header` that is not inside
///    an `article`, `aside`, `main`, `nav` or `section` are chrome.
/// 2. If the page has `main`, `article` or `role="main"` elements, the largest one is the content (an empty one does not
///    count).
/// 3. Otherwise walk down from `body`: enter the container child (`div`, `section`, `td`, ...) that holds at least 70% of the
///    element's text (link text not counted, so a menu counts for nothing) while it still holds at least half of what `body` held. The element where the walk
///    stops is the content; blocks in it that are mostly links (80% or more of the text, at least two links) are left out. Its
///    text is used when it has at least `MIN_DENSITY_CHARS` characters.
/// 4. Else the whole page text, as `strip` gives it.
pub fn extract(html: &str) -> Extract {
    let nodes = parse(html);
    let cuts_in = |s: usize, e: usize| -> Vec<(usize, usize)> {
        let mut v: Vec<(usize, usize)> = nodes.iter().filter(|n| n.cut && n.start >= s && n.end <= e).map(|n| (n.start, n.end)).collect();
        v.sort();
        v
    };
    // 2. a declared main element
    let mut best: Option<usize> = None;
    for (k, n) in nodes.iter().enumerate() {
        if n.main_like && n.cend > n.cstart && best.map(|bk| n.cend - n.cstart > nodes[bk].cend - nodes[bk].cstart).unwrap_or(true) {
            best = Some(k);
        }
    }
    if let Some(k) = best {
        let n = &nodes[k];
        let t = strip_in(html, n.cstart, n.cend, &cuts_in(n.cstart, n.cend));
        if !t.is_empty() {
            return Extract { text: t, via: Via::Main, root_name: n.name.clone(), root: (n.cstart, n.cend) };
        }
    }
    // 3. the densest element
    let score = |k: usize| nodes[k].text.saturating_sub(nodes[k].link);
    let body = nodes.iter().position(|n| n.name == "body");
    let top: Vec<usize> = (0..nodes.len()).filter(|&k| nodes[k].parent == NONE).collect();
    let start_score: usize = match body {
        Some(k) => score(k),
        None => top.iter().map(|&k| score(k)).sum(),
    };
    let mut cur = body;
    loop {
        let kids: Vec<usize> = match cur {
            Some(c) => (0..nodes.len()).filter(|&k| nodes[k].parent == c).collect(),
            None => top.clone(),
        };
        let cur_score = match cur {
            Some(c) => score(c),
            None => start_score,
        };
        let Some(&kid) = kids.iter().max_by_key(|&&k| score(k)) else { break };
        let ks = score(kid) as f64;
        if CONTAINERS.contains(&nodes[kid].name.as_str())
            && ks >= DOMINANT_SHARE * cur_score as f64
            && ks >= KEEP_SHARE * start_score as f64
            && ks > 0.0
        {
            cur = Some(kid);
        } else {
            break;
        }
    }
    let (s, e, name) = match cur {
        Some(c) => (nodes[c].cstart, nodes[c].cend, nodes[c].name.clone()),
        None => (0, html.len(), String::new()),
    };
    let mut cuts = cuts_in(s, e);
    for (k, n) in nodes.iter().enumerate() {
        if n.start >= s && n.end <= e && Some(k) != cur && !n.chrome && PRUNABLE.contains(&n.name.as_str()) && n.links >= 2 && n.text > 0
            && n.link as f64 >= PRUNE_LINK_SHARE * n.text as f64
        {
            cuts.push((n.start, n.end));
        }
    }
    cuts.sort();
    // outermost only
    let mut kept: Vec<(usize, usize)> = Vec::new();
    for c in cuts {
        if kept.last().is_none_or(|l| c.0 >= l.1) {
            kept.push(c);
        }
    }
    let t = strip_in(html, s, e, &kept);
    if t.chars().count() >= MIN_DENSITY_CHARS {
        return Extract { text: t, via: Via::Density, root_name: name, root: (s, e) };
    }
    // 4. the whole page
    Extract { text: strip(html), via: Via::Whole, root_name: String::new(), root: (0, html.len()) }
}

/// The page's chrome elements as `(name, content start, content end)`: what `extract` leaves out of a page that has a
/// `body` (navigation, asides, footers, banners, role chrome). For tests that check a text did not come from one.
#[doc(hidden)]
pub fn chrome_nodes(html: &str) -> Vec<(String, usize, usize)> {
    const NOT_TEXT: &[&str] = &["head", "script", "style", "template", "svg", "noscript", "select", "button", "textarea", "iframe"];
    parse(html)
        .into_iter()
        .filter(|n| n.chrome && !NOT_TEXT.contains(&n.name.as_str()))
        .map(|n| (n.name, n.cstart, n.cend))
        .collect()
}

/// The streaming stripper (no main-content selection).
pub fn strip(html: &str) -> String {
    strip_in(html, 0, html.len(), &[])
}

/// `strip` over `html[s..e]` (offsets into the whole page, at element boundaries), leaving out the byte ranges in `cuts`
/// (sorted, inside `s..e`).
fn strip_in(html: &str, s: usize, e: usize, cuts: &[(usize, usize)]) -> String {
    let b = &html.as_bytes()[..e];
    let mut ci = 0usize;
    let mut out = Out { buf: String::with_capacity((e - s) / 3), brk: 0, space: false };
    let mut skip: Option<(String, u32)> = None;
    let mut i = s;
    while i < b.len() {
        while ci < cuts.len() && cuts[ci].1 <= i {
            ci += 1;
        }
        if ci < cuts.len() && cuts[ci].0 <= i {
            i = cuts[ci].1;
            out.brk(1);
            continue;
        }
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

    fn prose(n: usize) -> String {
        "The river rises in the northern hills and runs south to the sea. ".repeat(n)
    }

    #[test]
    fn nav_plus_main_takes_main_only() {
        let html = format!(
            "<html><body><nav><a href=a>Home</a> <a href=b>Docs</a></nav><main><h1>Title</h1><p>{}</p></main><footer>Copyright</footer></body></html>",
            prose(5)
        );
        let x = extract(&html);
        assert_eq!(x.via, Via::Main);
        assert_eq!(x.root_name, "main");
        assert!(x.text.starts_with("Title\n\nThe river rises"));
        assert!(!x.text.contains("Home") && !x.text.contains("Copyright"));
        // the structural claim: the text is exactly what sits inside the chosen element
        assert_eq!(x.text, strip(&html[x.root.0..x.root.1]));
    }

    #[test]
    fn aside_sidebars_and_roles_are_left_out_without_a_main_element() {
        let links: String = (0..40).map(|i| format!("<li><a href=p{i}>Section number {i}</a></li>")).collect();
        let html = format!(
            "<body><div class=page><aside class=side><ul>{links}</ul></aside>\
             <div class=content><h1>Rivers</h1><p>{}</p></div>\
             <div role=\"complementary\">Related stories and ads</div><div role=contentinfo>Site footer text</div></div></body>",
            prose(6)
        );
        let x = extract(&html);
        assert_eq!(x.via, Via::Density);
        assert_eq!(x.root_name, "div");
        assert!(x.text.starts_with("Rivers\n\nThe river rises"), "{}", x.text);
        for chrome in ["Section number", "Related stories", "Site footer"] {
            assert!(!x.text.contains(chrome), "{chrome} leaked: {}", x.text);
        }
        // the chosen element is the content div, not an ancestor
        assert_eq!(&html[x.root.0..x.root.0 + 4], "<h1>");
    }

    #[test]
    fn roles_inside_a_declared_main_are_dropped_too() {
        let t = html_to_text("<main><p>Body text.</p><div role=complementary>Side</div><div role=\"contentinfo\">Foot</div></main>");
        assert_eq!(t, "Body text.");
    }

    #[test]
    fn no_semantic_tags_density_wins_over_a_link_menu() {
        // a div menu of links is bigger than the article in raw characters, but link text does not count
        let menu: String = (0..60).map(|i| format!("<div><a href=x{i}>Menu entry number {i} of the site</a></div>")).collect();
        let html = format!(
            "<body><div id=wrap><div id=menu>{menu}</div><div id=story><div><p>{}</p><p>{}</p></div></div></div></body>",
            prose(3),
            prose(3)
        );
        let x = extract(&html);
        assert_eq!(x.via, Via::Density);
        assert!(x.text.starts_with("The river rises"), "{}", x.text);
        assert!(!x.text.contains("Menu entry"));
        assert!(html[x.root.0..x.root.1].contains("The river") && !html[x.root.0..x.root.1].contains("Menu entry"));
    }

    #[test]
    fn the_walk_stops_where_the_text_splits() {
        // two equal columns: neither holds 70%, so the common parent is the content
        let html = format!("<body><div id=cols><div>{}</div><div>{}</div></div></body>", prose(4), prose(4));
        let x = extract(&html);
        assert_eq!(x.via, Via::Density);
        assert!(html[x.root.0..x.root.1].starts_with("<div>") && html[x.root.0..x.root.1].matches("<div>").count() == 2);
    }

    #[test]
    fn short_extraction_falls_back_to_the_whole_page() {
        let t = html_to_text("<body><nav>Menu words here</nav><div><p>Tiny page.</p></div></body>");
        assert_eq!(t, "Tiny page.");
        let x = extract("<header>Banner</header><p>Short body.</p><footer>f</footer>");
        assert_eq!(x.via, Via::Whole);
        assert_eq!(x.text, "Banner\n\nShort body.");
        // just under and over the threshold
        let under = "a".repeat(MIN_DENSITY_CHARS - 1);
        let over = "a".repeat(MIN_DENSITY_CHARS);
        assert_eq!(extract(&format!("<header>H</header><p>{under}</p>")).via, Via::Whole);
        assert_eq!(extract(&format!("<header>H</header><p>{over}</p>")).via, Via::Density);
        // an empty main falls through to the density walk
        assert_eq!(extract(&format!("<main><img src=x></main><p>{over}</p>")).via, Via::Density);
    }

    #[test]
    fn banner_header_goes_but_a_header_inside_a_section_stays() {
        let html = format!("<body><header><h1>Site name</h1></header><section><header><h2>Part one</h2></header><p>{}</p></section></body>", prose(5));
        let x = extract(&html);
        assert_eq!(x.via, Via::Density);
        assert!(!x.text.contains("Site name"));
        assert!(x.text.starts_with("Part one"));
    }

    #[test]
    fn optional_end_tags_do_not_nest_the_page_deeper() {
        // HTML 4 style: unclosed p, li and td; the second paragraph must not become a child of the first
        let html = format!("<body><div><p>{}<p>{}<ul><li>one<li>two</ul><table><tr><td>a<td>b<tr><td>c</table></div></body>", prose(3), prose(3));
        let nodes = parse(&html);
        let ps: Vec<&Node> = nodes.iter().filter(|n| n.name == "p").collect();
        assert_eq!(ps.len(), 2);
        assert!(ps.iter().all(|p| nodes[p.parent].name == "div"));
        let lis: Vec<&Node> = nodes.iter().filter(|n| n.name == "li").collect();
        assert!(lis.iter().all(|l| nodes[l.parent].name == "ul"));
        let tds: Vec<&Node> = nodes.iter().filter(|n| n.name == "td").collect();
        assert!(tds.iter().all(|d| nodes[d.parent].name == "tr"));
    }

    #[test]
    fn old_page_with_the_body_tag_after_the_menu_row() {
        // the content is under a later <body>; the menu row sits before it and is not part of the walk
        let html = format!(
            "<html><head><title>t</title></head><p><img src=logo></p><body><div><a href=h>Back to Home</a> or <a href=l>list</a></div><hr>\
             <br><a href=a>Home</a> - <a href=b>English</a><br><font><div>{}<br>{}</div></font></body></html>",
            prose(5),
            prose(5)
        );
        let x = extract(&html);
        assert_eq!(x.via, Via::Density);
        assert!(x.text.starts_with("The river rises"), "{}", x.text);
        assert!(!x.text.contains("Back to Home"));
    }

    #[test]
    fn link_blocks_are_left_out_of_walk_content_but_not_out_of_a_declared_main() {
        let html = format!(
            "<body><center><a href=a>Back to Home</a> or <a href=b>Back to list</a></center><hr>\
             <p><a name=x>56. Sugar</a></p><p>{}</p><p><a href=c>Previous</a> - <a href=d>Next</a></p><p>{}</p>\
             <ul><li><a href=e>Related one</a></li><li><a href=f>Related two</a></li></ul></body>",
            prose(3),
            prose(3)
        );
        let x = extract(&html);
        assert_eq!(x.via, Via::Density);
        assert!(x.text.starts_with("56. Sugar"), "{}", x.text);
        for gone in ["Back to Home", "Previous", "Related one"] {
            assert!(!x.text.contains(gone), "{gone}: {}", x.text);
        }
        // a single link is a sentence with a link in it, not a list; a name-only anchor is not a link
        let one = format!("<body><div><p><a href=z>One linked sentence stands here.</a></p><p>{}</p></div></body>", prose(4));
        assert!(extract(&one).text.starts_with("One linked sentence"));
        // inside a declared main nothing is pruned (a Wikipedia "See also" list is content)
        let m = format!("<main><p>{}</p><ul><li><a href=e>Related one</a></li><li><a href=f>Related two</a></li></ul></main>", prose(2));
        assert!(extract(&m).text.contains("Related two"));
    }

    #[test]
    fn malformed_pages_never_panic_in_extraction() {
        for h in ["", "<", "<<main>", "<main>", "</main></body>", "<body><div><p>x", "<aside><main>t", "<header><header><header>", "<a><a><a>t", "<nav>x<body>y"] {
            let _ = extract(h);
            let _ = extract(&format!("{h}{}", prose(8)));
        }
    }

    #[test]
    fn attr_parsing() {
        assert_eq!(attr_value("div class=\"a b\" role = 'main' id=x>", "role").as_deref(), Some("main"));
        assert_eq!(attr_value("div ROLE=Main>", "role").as_deref(), Some("Main"));
        assert_eq!(attr_value("div data-x=\"role=main\">", "role"), None);
        assert_eq!(attr_value("input disabled aria-hidden=true >", "aria-hidden").as_deref(), Some("true"));
    }
}
