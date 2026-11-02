//! EPUBs: reading the zip, the package (spine order, title) and the text blocks of a chapter, all in plain Rust.
//!
//! An EPUB is a zip of XHTML chapters. [`Zip`] reads one from bytes (stored and deflated members; the central directory is
//! the authority, so data descriptors are fine). [`package`] finds the spine through `META-INF/container.xml` and the
//! OPF. [`blocks`] cuts a chapter into its text blocks (`p`, `li`, `h1`-`h6`, `td`), and [`add_block_ids`] writes the same
//! numbering into the served file as `id="cache-b<n>"`, so a citation's `#cache-b<n>` is an ordinary anchor.
//!
//! The numbering is the one rule both share: the blocks of a chapter are numbered 0, 1, 2... in the order their start
//! tags appear, whether or not they hold text. Text inside `script` and `style` is not text.

use crate::error::{Error, Result};
use std::io::Read;

// ---------------------------------------------------------------------------------------------------------
// Zip

/// The most one member may unpack to (a damaged or hostile file cannot fill the memory).
pub const MAX_MEMBER_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone)]
struct Member {
    name: String,
    method: u16,
    comp_size: u64,
    size: u64,
    offset: u64,
}

/// A zip archive held in memory.
pub struct Zip<'a> {
    data: &'a [u8],
    members: Vec<Member>,
}

fn u16_at(b: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?))
}

fn u32_at(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?))
}

fn u64_at(b: &[u8], i: usize) -> Option<u64> {
    Some(u64::from_le_bytes(b.get(i..i + 8)?.try_into().ok()?))
}

fn bad(msg: &str) -> Error {
    Error::unsupported(format!("not a readable epub: {msg}"))
}

impl<'a> Zip<'a> {
    pub fn open(data: &'a [u8]) -> Result<Zip<'a>> {
        // end of central directory: the last 0x06054b50 within the final 64 KiB + 22 bytes
        let lo = data.len().saturating_sub(22 + 65_535);
        let eocd = (lo..data.len().saturating_sub(21))
            .rev()
            .find(|&i| u32_at(data, i) == Some(0x0605_4b50))
            .ok_or_else(|| bad("no zip directory"))?;
        let mut count = u16_at(data, eocd + 10).ok_or_else(|| bad("short directory"))? as u64;
        let mut dir_off = u32_at(data, eocd + 16).ok_or_else(|| bad("short directory"))? as u64;
        // zip64: the end record points at a zip64 end record that holds the real count and offset
        if count == 0xFFFF || dir_off == 0xFFFF_FFFF {
            let loc = eocd.checked_sub(20).filter(|&l| u32_at(data, l) == Some(0x0706_4b50));
            if let Some(l) = loc {
                let z64 = u64_at(data, l + 8).ok_or_else(|| bad("short zip64 locator"))? as usize;
                if u32_at(data, z64) == Some(0x0606_4b50) {
                    count = u64_at(data, z64 + 32).ok_or_else(|| bad("short zip64 record"))?;
                    dir_off = u64_at(data, z64 + 48).ok_or_else(|| bad("short zip64 record"))?;
                }
            }
        }
        let mut members = Vec::new();
        let mut p = dir_off as usize;
        for _ in 0..count {
            if u32_at(data, p) != Some(0x0201_4b50) {
                return Err(bad("damaged directory"));
            }
            let method = u16_at(data, p + 10).ok_or_else(|| bad("damaged directory"))?;
            let mut comp_size = u32_at(data, p + 20).ok_or_else(|| bad("damaged directory"))? as u64;
            let mut size = u32_at(data, p + 24).ok_or_else(|| bad("damaged directory"))? as u64;
            let (n, m, k) = (
                u16_at(data, p + 28).ok_or_else(|| bad("damaged directory"))? as usize,
                u16_at(data, p + 30).ok_or_else(|| bad("damaged directory"))? as usize,
                u16_at(data, p + 32).ok_or_else(|| bad("damaged directory"))? as usize,
            );
            let mut offset = u32_at(data, p + 42).ok_or_else(|| bad("damaged directory"))? as u64;
            let name = String::from_utf8_lossy(data.get(p + 46..p + 46 + n).ok_or_else(|| bad("damaged directory"))?)
                .into_owned();
            // zip64 extra field (id 1): the sizes and offset that did not fit, in this order
            let extra = data
                .get(p + 46 + n..p + 46 + n + m)
                .ok_or_else(|| bad("damaged directory"))?;
            let mut e = 0;
            while e + 4 <= extra.len() {
                let (id, len) = (
                    u16_at(extra, e).unwrap_or(0),
                    u16_at(extra, e + 2).unwrap_or(0) as usize,
                );
                if id == 1 {
                    let mut q = e + 4;
                    for field in [&mut size, &mut comp_size, &mut offset] {
                        if *field == 0xFFFF_FFFF {
                            if let Some(v) = u64_at(extra, q) {
                                *field = v;
                                q += 8;
                            }
                        }
                    }
                }
                e += 4 + len;
            }
            members.push(Member {
                name,
                method,
                comp_size,
                size,
                offset,
            });
            p += 46 + n + m + k;
        }
        Ok(Zip { data, members })
    }

    /// The names of the members, in directory order (folders end in `/`).
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.members.iter().map(|m| m.name.as_str())
    }

    pub fn contains(&self, name: &str) -> bool {
        self.members.iter().any(|m| m.name == name)
    }

    /// The unpacked bytes of a member. `not_found` for an unknown name, `unsupported` for a method other than stored or
    /// deflate or a member over [`MAX_MEMBER_BYTES`], `io` for damaged data.
    pub fn read(&self, name: &str) -> Result<Vec<u8>> {
        let m = self
            .members
            .iter()
            .find(|m| m.name == name)
            .ok_or_else(|| Error::not_found(format!("no {name:?} in the epub")))?;
        if m.size > MAX_MEMBER_BYTES {
            return Err(Error::unsupported(format!(
                "{name:?} in the epub is {} bytes, over the limit",
                m.size
            )));
        }
        let h = m.offset as usize;
        if u32_at(self.data, h) != Some(0x0403_4b50) {
            return Err(Error::io(format!("{name:?} in the epub: damaged local header")));
        }
        let (n, e) = (
            u16_at(self.data, h + 26).unwrap_or(0) as usize,
            u16_at(self.data, h + 28).unwrap_or(0) as usize,
        );
        let start = h + 30 + n + e;
        let raw = self
            .data
            .get(start..start.saturating_add(m.comp_size as usize))
            .ok_or_else(|| Error::io(format!("{name:?} in the epub: data runs past the end of the file")))?;
        match m.method {
            0 => Ok(raw.to_vec()),
            8 => {
                let mut out = Vec::with_capacity(m.size as usize);
                flate2::read::DeflateDecoder::new(raw)
                    .take(MAX_MEMBER_BYTES + 1)
                    .read_to_end(&mut out)
                    .map_err(|e| Error::io(format!("{name:?} in the epub: {e}")))?;
                if out.len() as u64 > MAX_MEMBER_BYTES {
                    return Err(Error::unsupported(format!(
                        "{name:?} in the epub unpacks past the limit"
                    )));
                }
                Ok(out)
            }
            other => Err(Error::unsupported(format!(
                "{name:?} in the epub uses compression method {other}"
            ))),
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// A small XML/XHTML tokenizer

/// One token of a markup file. Offsets are byte positions in the input.
#[derive(Debug)]
pub enum Tok<'a> {
    /// `<name a="b">`: `name` is lowercase without a namespace prefix; `end` is just past the `>`; `close` is where the
    /// closing `>` (or `/>`) begins, the place to add an attribute.
    Start {
        name: String,
        attrs: Vec<(String, String)>,
        self_closing: bool,
        start: usize,
        close: usize,
        end: usize,
    },
    End {
        name: String,
    },
    Text(&'a str),
}

fn local_lower(name: &str) -> String {
    name.rsplit(':').next().unwrap_or(name).to_ascii_lowercase()
}

/// Walk the tags and text of `s`. Comments, processing instructions, doctypes and the content of `script` and `style` are
/// skipped; CDATA is text.
pub fn scan<'a>(s: &'a str, mut f: impl FnMut(Tok<'a>)) {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'<' {
            let j = s[i..].find('<').map(|k| i + k).unwrap_or(b.len());
            f(Tok::Text(&s[i..j]));
            i = j;
            continue;
        }
        let rest = &s[i..];
        if rest.starts_with("<!--") {
            i = rest.find("-->").map(|k| i + k + 3).unwrap_or(b.len());
        } else if rest.starts_with("<![CDATA[") {
            let body = i + 9;
            let e = s[body..].find("]]>").map(|k| body + k).unwrap_or(b.len());
            f(Tok::Text(&s[body..e]));
            i = (e + 3).min(b.len());
        } else if rest.starts_with("<?") || rest.starts_with("<!") {
            i = rest.find('>').map(|k| i + k + 1).unwrap_or(b.len());
        } else if rest.starts_with("</") {
            let e = rest.find('>').map(|k| i + k).unwrap_or(b.len());
            f(Tok::End {
                name: local_lower(s[i + 2..e].trim()),
            });
            i = (e + 1).min(b.len());
        } else {
            // a start tag: name, then attributes up to the '>' that is not inside quotes
            let mut j = i + 1;
            while j < b.len() && !b[j].is_ascii_whitespace() && b[j] != b'>' && b[j] != b'/' {
                j += 1;
            }
            let name = local_lower(&s[i + 1..j]);
            if name.is_empty() {
                // a lone '<' in text
                f(Tok::Text(&s[i..i + 1]));
                i += 1;
                continue;
            }
            let mut attrs = Vec::new();
            let mut self_closing = false;
            let mut close = b.len();
            while j < b.len() {
                match b[j] {
                    b'>' => {
                        close = j;
                        break;
                    }
                    b'/' if b.get(j + 1) == Some(&b'>') => {
                        self_closing = true;
                        close = j;
                        j += 1;
                        break;
                    }
                    c if c.is_ascii_whitespace() || c == b'/' => j += 1,
                    _ => {
                        let k0 = j;
                        while j < b.len() && !b[j].is_ascii_whitespace() && !matches!(b[j], b'=' | b'>' | b'/') {
                            j += 1;
                        }
                        let key = local_lower(&s[k0..j]);
                        while j < b.len() && b[j].is_ascii_whitespace() {
                            j += 1;
                        }
                        let mut val = String::new();
                        if b.get(j) == Some(&b'=') {
                            j += 1;
                            while j < b.len() && b[j].is_ascii_whitespace() {
                                j += 1;
                            }
                            match b.get(j) {
                                Some(&q) if q == b'"' || q == b'\'' => {
                                    let v0 = j + 1;
                                    let v1 = s[v0..].find(q as char).map(|k| v0 + k).unwrap_or(b.len());
                                    val = s[v0..v1].to_string();
                                    j = (v1 + 1).min(b.len());
                                }
                                _ => {
                                    let v0 = j;
                                    while j < b.len() && !b[j].is_ascii_whitespace() && b[j] != b'>' {
                                        j += 1;
                                    }
                                    val = s[v0..j].to_string();
                                }
                            }
                        }
                        attrs.push((key, val));
                    }
                }
            }
            let end = (j + 1).min(b.len());
            let skip_body = !self_closing && (name == "script" || name == "style");
            f(Tok::Start {
                name: name.clone(),
                attrs,
                self_closing,
                start: i,
                close: close.min(b.len()),
                end,
            });
            i = end;
            if skip_body {
                let needle = format!("</{name}");
                let lower = s[i..].to_ascii_lowercase();
                i = lower.find(&needle).map(|k| i + k).unwrap_or(b.len());
            }
        }
    }
}

fn attr<'a>(attrs: &'a [(String, String)], key: &str) -> Option<&'a str> {
    attrs.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}

/// `&amp;` and friends, in XML or HTML text.
pub fn decode_entities(s: &str) -> String {
    if s.contains('&') {
        html_escape::decode_html_entities(s).into_owned()
    } else {
        s.to_string()
    }
}

// ---------------------------------------------------------------------------------------------------------
// The package

/// What an EPUB's package says.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Package {
    /// `dc:title`, when it has one.
    pub title: Option<String>,
    /// The paths (inside the zip) of the XHTML chapters in reading order.
    pub spine: Vec<String>,
}

fn is_html_type(t: &str) -> bool {
    let t = t.to_ascii_lowercase();
    t.contains("xhtml") || t == "text/html" || t == "application/x-dtbook+xml"
}

/// Resolve `href` against the folder of `base` (a path inside the zip), dropping `..`, `.`, a `#fragment` and percent escapes.
pub fn resolve(base: &str, href: &str) -> String {
    let href = href.split(['#', '?']).next().unwrap_or("");
    let href = crate::zimsrc::percent_decode(href).unwrap_or_else(|| href.to_string());
    let mut parts: Vec<&str> = if href.starts_with('/') {
        Vec::new()
    } else {
        base.rsplit_once('/')
            .map(|(d, _)| d.split('/').collect())
            .unwrap_or_default()
    };
    for seg in href.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

/// The title and spine of an EPUB. Without a usable package, every `.xhtml`/`.html`/`.htm` member in name order.
pub fn package(zip: &Zip) -> Package {
    let opf_path = zip.read("META-INF/container.xml").ok().and_then(|c| {
        let text = String::from_utf8_lossy(&c).into_owned();
        let mut found = None;
        scan(&text, |t| {
            if let Tok::Start { name, attrs, .. } = t {
                if name == "rootfile" && found.is_none() {
                    found = attr(&attrs, "full-path").map(str::to_string);
                }
            }
        });
        found
    });
    let mut pkg = Package::default();
    if let Some(opf) = opf_path.as_deref().and_then(|p| {
        zip.read(p)
            .ok()
            .map(|b| (p.to_string(), String::from_utf8_lossy(&b).into_owned()))
    }) {
        let (opf_path, text) = opf;
        let mut manifest: Vec<(String, String, bool)> = Vec::new();
        let mut spine_ids: Vec<String> = Vec::new();
        let mut in_title = false;
        let mut title = String::new();
        scan(&text, |t| match t {
            Tok::Start {
                name,
                attrs,
                self_closing,
                ..
            } => match name.as_str() {
                "item" => {
                    if let (Some(id), Some(href)) = (attr(&attrs, "id"), attr(&attrs, "href")) {
                        let html = attr(&attrs, "media-type").is_some_and(is_html_type);
                        manifest.push((id.to_string(), resolve(&opf_path, &decode_entities(href)), html));
                    }
                }
                "itemref" => {
                    if let Some(r) = attr(&attrs, "idref") {
                        spine_ids.push(r.to_string());
                    }
                }
                "title" if title.is_empty() && !self_closing => in_title = true,
                _ => {}
            },
            Tok::End { name } if name == "title" => in_title = false,
            Tok::Text(s) if in_title => title.push_str(s),
            _ => {}
        });
        let t = decode_entities(&title).split_whitespace().collect::<Vec<_>>().join(" ");
        pkg.title = (!t.is_empty()).then_some(t);
        for id in spine_ids {
            if let Some((_, path, true)) = manifest.iter().find(|(i, _, _)| *i == id) {
                if zip.contains(path) && !pkg.spine.contains(path) {
                    pkg.spine.push(path.clone());
                }
            }
        }
    }
    if pkg.spine.is_empty() {
        let mut all: Vec<String> = zip
            .names()
            .filter(|n| {
                let l = n.to_ascii_lowercase();
                l.ends_with(".xhtml") || l.ends_with(".html") || l.ends_with(".htm")
            })
            .map(str::to_string)
            .collect();
        all.sort();
        pkg.spine = all;
    }
    pkg
}

// ---------------------------------------------------------------------------------------------------------
// Chapter text

/// The tag names that are text blocks.
pub fn block_level(name: &str) -> Option<u8> {
    match name {
        "p" | "li" | "td" => Some(0),
        "h1" => Some(1),
        "h2" => Some(2),
        "h3" => Some(3),
        "h4" => Some(4),
        "h5" => Some(5),
        "h6" => Some(6),
        _ => None,
    }
}

fn inline(name: &str) -> bool {
    matches!(
        name,
        "a" | "span"
            | "b"
            | "i"
            | "em"
            | "strong"
            | "sup"
            | "sub"
            | "small"
            | "u"
            | "code"
            | "abbr"
            | "cite"
            | "q"
            | "mark"
            | "font"
            | "tt"
            | "kbd"
            | "samp"
            | "var"
            | "big"
            | "s"
            | "del"
            | "ins"
            | "dfn"
            | "time"
            | "bdi"
            | "bdo"
            | "ruby"
            | "rb"
            | "rt"
            | "rp"
            | "wbr"
    )
}

/// One text block of a chapter.
#[derive(Debug, Clone, PartialEq)]
pub struct Block {
    /// The block's number in its chapter (see the module comment).
    pub n: u32,
    /// 0 for `p`, `li`, `td`; 1-6 for `h1`-`h6`.
    pub level: u8,
    /// `true` for `li`.
    pub item: bool,
    /// The block's own text (nested blocks have their own), whitespace collapsed.
    pub text: String,
}

/// The text blocks of a chapter, in document order (so by `n`).
pub fn blocks(xhtml: &str) -> Vec<Block> {
    let mut out: Vec<Block> = Vec::new();
    let mut raw: Vec<String> = Vec::new();
    let mut stack: Vec<(usize, String)> = Vec::new();
    scan(xhtml, |t| match t {
        Tok::Start { name, self_closing, .. } => {
            if let Some(level) = block_level(&name) {
                let n = out.len();
                out.push(Block {
                    n: n as u32,
                    level,
                    item: name == "li",
                    text: String::new(),
                });
                raw.push(String::new());
                if let Some((top, _)) = stack.last() {
                    raw[*top].push(' ');
                }
                if !self_closing {
                    stack.push((n, name));
                }
            } else if let Some((top, _)) = stack.last() {
                if name == "br" || !inline(&name) {
                    raw[*top].push(' ');
                }
            }
        }
        Tok::End { name } => {
            if block_level(&name).is_some() {
                if let Some(k) = stack.iter().rposition(|(_, nm)| *nm == name) {
                    stack.truncate(k);
                }
            }
            if let Some((top, _)) = stack.last() {
                if !inline(&name) {
                    raw[*top].push(' ');
                }
            }
        }
        Tok::Text(s) => {
            if let Some((top, _)) = stack.last() {
                raw[*top].push_str(&decode_entities(s));
            }
        }
    });
    for (b, r) in out.iter_mut().zip(raw) {
        b.text = r.split_whitespace().collect::<Vec<_>>().join(" ");
    }
    out
}

/// The chapter with `id="cache-b<n>"` on every block element, numbered as [`blocks`] numbers them. A block that already has
/// an `id` keeps it, and an empty `<a id="cache-b<n>"/>` follows its start tag instead. The bytes between the changes are
/// the file's own.
pub fn add_block_ids(xhtml: &str) -> String {
    let mut inserts: Vec<(usize, String)> = Vec::new();
    let mut n = 0u32;
    scan(xhtml, |t| {
        if let Tok::Start {
            name,
            attrs,
            self_closing,
            close,
            end,
            ..
        } = t
        {
            if block_level(&name).is_some() {
                if attr(&attrs, "id").is_some() && !self_closing {
                    inserts.push((end, format!("<a id=\"cache-b{n}\"></a>")));
                } else if attr(&attrs, "id").is_none() {
                    inserts.push((close, format!(" id=\"cache-b{n}\"")));
                }
                n += 1;
            }
        }
    });
    let mut out = String::with_capacity(xhtml.len() + inserts.len() * 20);
    let mut at = 0;
    for (pos, text) in inserts {
        out.push_str(&xhtml[at..pos]);
        out.push_str(&text);
        at = pos;
    }
    out.push_str(&xhtml[at..]);
    out
}

/// The media type served for a member of an EPUB, by its extension.
pub fn mime_of(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "xhtml" | "xht" => "application/xhtml+xml",
        "html" | "htm" => "text/html",
        "css" => "text/css",
        "js" => "text/javascript",
        "xml" | "opf" => "application/xml",
        "ncx" => "application/x-dtbncx+xml",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        "txt" => "text/plain",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
pub(crate) mod testutil {
    use std::io::Write;

    /// A zip with the given members, stored or deflated (`true`), for tests.
    pub fn make_zip(members: &[(&str, &[u8], bool)]) -> Vec<u8> {
        let mut out: Vec<u8> = Vec::new();
        let mut dir: Vec<u8> = Vec::new();
        for (name, data, deflate) in members {
            let off = out.len() as u32;
            let (method, body) = if *deflate {
                let mut e = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
                e.write_all(data).unwrap();
                (8u16, e.finish().unwrap())
            } else {
                (0u16, data.to_vec())
            };
            out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
            out.extend_from_slice(&[20, 0, 0, 0]);
            out.extend_from_slice(&method.to_le_bytes());
            out.extend_from_slice(&[0, 0, 0, 0]);
            out.extend_from_slice(&0u32.to_le_bytes()); // crc (not checked)
            out.extend_from_slice(&(body.len() as u32).to_le_bytes());
            out.extend_from_slice(&(data.len() as u32).to_le_bytes());
            out.extend_from_slice(&(name.len() as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&body);
            dir.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
            dir.extend_from_slice(&[20, 0, 20, 0, 0, 0]);
            dir.extend_from_slice(&method.to_le_bytes());
            dir.extend_from_slice(&[0, 0, 0, 0]);
            dir.extend_from_slice(&0u32.to_le_bytes());
            dir.extend_from_slice(&(body.len() as u32).to_le_bytes());
            dir.extend_from_slice(&(data.len() as u32).to_le_bytes());
            dir.extend_from_slice(&(name.len() as u16).to_le_bytes());
            dir.extend_from_slice(&[0u8; 12]);
            dir.extend_from_slice(&off.to_le_bytes());
            dir.extend_from_slice(name.as_bytes());
        }
        let dir_off = out.len() as u32;
        let dir_len = dir.len() as u32;
        out.extend_from_slice(&dir);
        out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(&(members.len() as u16).to_le_bytes());
        out.extend_from_slice(&(members.len() as u16).to_le_bytes());
        out.extend_from_slice(&dir_len.to_le_bytes());
        out.extend_from_slice(&dir_off.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }

    pub const CONTAINER: &str = r#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#;

    pub fn opf(title: &str, items: &[(&str, &str)], spine: &[&str]) -> String {
        let mut s = format!("<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>{title}</dc:title></metadata><manifest>");
        for (id, href) in items {
            let t = if href.ends_with(".xhtml") {
                "application/xhtml+xml"
            } else {
                "text/css"
            };
            s.push_str(&format!("<item id=\"{id}\" href=\"{href}\" media-type=\"{t}\"/>"));
        }
        s.push_str("</manifest><spine>");
        for r in spine {
            s.push_str(&format!("<itemref idref=\"{r}\"/>"));
        }
        s.push_str("</spine></package>");
        s
    }
}

#[cfg(test)]
mod tests {
    use super::testutil::*;
    use super::*;

    #[test]
    fn zip_reads_stored_and_deflated_members() {
        let big = "line of text\n".repeat(500);
        let z = make_zip(&[("a.txt", b"hello", false), ("dir/b.txt", big.as_bytes(), true)]);
        let zip = Zip::open(&z).unwrap();
        assert_eq!(zip.names().collect::<Vec<_>>(), ["a.txt", "dir/b.txt"]);
        assert_eq!(zip.read("a.txt").unwrap(), b"hello");
        assert_eq!(zip.read("dir/b.txt").unwrap(), big.as_bytes());
        assert_eq!(zip.read("nope").unwrap_err().code, crate::ErrorCode::NotFound);
        assert!(Zip::open(b"PK not a zip").is_err());
        assert!(Zip::open(&z[..z.len() - 30]).is_err());
    }

    #[test]
    fn package_gives_spine_order_title_and_resolves_paths() {
        let opf = opf(
            "A Field Guide",
            &[("c2", "text/two.xhtml"), ("c1", "one%20x.xhtml"), ("css", "s.css")],
            &["c1", "c2", "css", "missing"],
        );
        let z = make_zip(&[
            ("mimetype", b"application/epub+zip", false),
            ("META-INF/container.xml", CONTAINER.as_bytes(), true),
            ("OEBPS/content.opf", opf.as_bytes(), true),
            ("OEBPS/one x.xhtml", b"<html/>", true),
            ("OEBPS/text/two.xhtml", b"<html/>", true),
        ]);
        let p = package(&Zip::open(&z).unwrap());
        assert_eq!(p.title.as_deref(), Some("A Field Guide"));
        assert_eq!(
            p.spine,
            ["OEBPS/one x.xhtml", "OEBPS/text/two.xhtml"],
            "spine order, not name order; non-html and missing dropped"
        );
        assert_eq!(resolve("OEBPS/text/two.xhtml", "../img/a.png#x"), "OEBPS/img/a.png");
        // no package: every html member by name
        let z = make_zip(&[
            ("b.html", b"x", false),
            ("a.xhtml", b"x", false),
            ("c.png", b"x", false),
        ]);
        assert_eq!(package(&Zip::open(&z).unwrap()).spine, ["a.xhtml", "b.html"]);
    }

    const CHAPTER: &str = "<?xml version=\"1.0\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title><style>p { color: red }</style></head>\n<body><!-- c --><h1 id=\"top\">Floods &amp; Fords</h1><p>First <i>para</i>graph, with <br/>a break.</p>\n<ul><li>One<ul><li>Nested</li></ul></li><li>Two</li></ul><table><tr><td>cell</td><th>head</th></tr></table><div>loose text</div><p/><p class=\"x\">Last &#233;t&eacute;.</p><script>var p = '<p>';</script></body></html>";

    #[test]
    fn blocks_are_numbered_by_start_tag_and_keep_their_own_text() {
        let b = blocks(CHAPTER);
        let got: Vec<(u32, u8, &str)> = b.iter().map(|x| (x.n, x.level, x.text.as_str())).collect();
        assert_eq!(
            got,
            [
                (0, 1, "Floods & Fords"),
                (1, 0, "First paragraph, with a break."),
                (2, 0, "One"),
                (3, 0, "Nested"),
                (4, 0, "Two"),
                (5, 0, "cell"),
                (6, 0, ""),
                (7, 0, "Last \u{e9}t\u{e9}."),
            ]
        );
        assert!(b[2].item && !b[1].item);
    }

    #[test]
    fn block_ids_use_the_same_numbers_and_keep_existing_ids() {
        let out = add_block_ids(CHAPTER);
        assert!(out.contains("<h1 id=\"top\"><a id=\"cache-b0\"></a>Floods"), "{out}");
        assert!(out.contains("<p id=\"cache-b1\">First"));
        assert!(out.contains("<li id=\"cache-b2\">One<ul><li id=\"cache-b3\">Nested"));
        assert!(out.contains("<td id=\"cache-b5\">cell"));
        assert!(out.contains("<p id=\"cache-b6\"/>"));
        assert!(out.contains("<p class=\"x\" id=\"cache-b7\">Last"));
        // the <p> inside the script is not a block
        assert!(out.contains("var p = '<p>';"));
        // deterministic, and removing the additions gives the original
        assert_eq!(out, add_block_ids(CHAPTER));
        let stripped = out.replace("<a id=\"cache-b0\"></a>", "");
        let mut s = stripped;
        for n in 1..8 {
            s = s.replace(&format!(" id=\"cache-b{n}\""), "");
        }
        assert_eq!(s, CHAPTER);
        // ids in the output are found by the block scanner as the same blocks
        assert_eq!(blocks(&out).len(), blocks(CHAPTER).len());
    }

    #[test]
    fn mime_types() {
        assert_eq!(mime_of("a/b.XHTML"), "application/xhtml+xml");
        assert_eq!(mime_of("c.css"), "text/css");
        assert_eq!(mime_of("noext"), "application/octet-stream");
    }
}
