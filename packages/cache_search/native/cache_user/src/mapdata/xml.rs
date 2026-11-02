//! A small element tree over quick-xml for the KML and GPX readers: local names (no namespace prefixes), attributes and
//! text (CDATA included), character references decoded.

use super::{bad, decode_entities};
use quick_xml::events::Event;
use quick_xml::Reader;

#[derive(Debug, Default)]
pub(crate) struct El {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<El>,
    /// The element's own text (its text and CDATA children joined).
    pub text: String,
}

/// Elements nested deeper than this make the file unreadable (a guard, not a format rule).
const MAX_DEPTH: usize = 200;

fn local(name: &[u8]) -> String {
    let n = String::from_utf8_lossy(name);
    match n.rsplit_once(':') {
        Some((_, l)) => l.to_string(),
        None => n.into_owned(),
    }
}

fn start(e: &quick_xml::events::BytesStart) -> El {
    let mut el = El { name: local(e.name().as_ref()), ..Default::default() };
    for a in e.attributes().flatten() {
        el.attrs.push((local(a.key.as_ref()), decode_entities(&String::from_utf8_lossy(&a.value))));
    }
    el
}

/// The document's root element.
pub(crate) fn parse(text: &str, what: &str) -> crate::Result<El> {
    let mut r = Reader::from_str(text);
    r.config_mut().check_end_names = true;
    let mut stack: Vec<El> = vec![El::default()];
    loop {
        let ev = r.read_event().map_err(|e| bad(format!("{what}: not readable XML ({e})")))?;
        match ev {
            Event::Start(e) => {
                if stack.len() > MAX_DEPTH {
                    return Err(bad(format!("{what}: nested too deeply")));
                }
                stack.push(start(&e));
            }
            Event::Empty(e) => {
                let el = start(&e);
                stack.last_mut().expect("root").children.push(el);
            }
            Event::End(_) => {
                if stack.len() < 2 {
                    return Err(bad(format!("{what}: not readable XML (unbalanced tags)")));
                }
                let el = stack.pop().expect("checked");
                stack.last_mut().expect("root").children.push(el);
            }
            Event::Text(t) => stack.last_mut().expect("root").text.push_str(&decode_entities(&String::from_utf8_lossy(&t))),
            Event::CData(t) => stack.last_mut().expect("root").text.push_str(&String::from_utf8_lossy(&t)),
            Event::Eof => break,
            _ => {}
        }
    }
    if stack.len() != 1 {
        return Err(bad(format!("{what}: not readable XML (unclosed tags)")));
    }
    let mut root = stack.pop().expect("one");
    let el = root.children.drain(..).next().ok_or_else(|| bad(format!("{what}: empty file")))?;
    Ok(el)
}

impl El {
    pub fn child(&self, name: &str) -> Option<&El> {
        self.children.iter().find(|c| c.name == name)
    }
    pub fn kids<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a El> + 'a {
        self.children.iter().filter(move |c| c.name == name)
    }
    /// The trimmed text of a child, None when it is missing or empty.
    pub fn child_text(&self, name: &str) -> Option<String> {
        self.child(name).map(|c| c.text.trim().to_string()).filter(|t| !t.is_empty())
    }
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }
}

/// `&`, `<`, `>`, `"` escaped for XML text and attributes.
pub(crate) fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => o.push_str("&amp;"),
            '<' => o.push_str("&lt;"),
            '>' => o.push_str("&gt;"),
            '"' => o.push_str("&quot;"),
            c => o.push(c),
        }
    }
    o
}
