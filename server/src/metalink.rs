//! Kiwix's metalink (`<download address>.meta4`): the mirrors of a file in order of preference, its SHA-256 and its size.
//!
//! The document is read by a small strict XML reader (no new dependency): declaration and comments are skipped, a DOCTYPE or
//! any entity beyond the five predefined ones is refused, and tags must nest and close exactly. Anything that does not read
//! cleanly gives `None`, and the caller then uses the redirect and the `.sha256` beside the file, as before.

/// What a metalink says about its first `<file>`.
#[derive(Debug, PartialEq)]
pub struct Metalink {
    /// Mirror addresses, lowest priority number first (a `<url>` with no priority goes last; ties keep document order).
    pub mirrors: Vec<String>,
    /// The `<hash type="sha-256">`, lower case, 64 hex digits.
    pub sha256: Option<String>,
    pub size: Option<u64>,
}

struct Open {
    name: String,
    priority: Option<u32>,
    hash_type: Option<String>,
    text: String,
}

fn local(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

fn decode(s: &str) -> Option<String> {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        let end = after.find(';')?;
        out.push(match &after[..end] {
            "amp" => '&',
            "lt" => '<',
            "gt" => '>',
            "quot" => '"',
            "apos" => '\'',
            _ => return None,
        });
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Some(out)
}

fn name_ok(n: &str) -> bool {
    !n.is_empty() && n.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
}

/// Parse a metalink document; None when it is not well-formed or has no `<file>`.
pub fn parse(text: &str) -> Option<Metalink> {
    let mut i = 0;
    let mut stack: Vec<Open> = vec![];
    let mut root_seen = false;
    let mut files = 0;
    let mut urls: Vec<(u32, usize, String)> = vec![];
    let mut sha256 = None;
    let mut size = None;
    // A finished element: only the children of the first `<file>` count.
    let mut close = |e: Open, parent: Option<&str>, files: &mut i32| {
        let name = local(&e.name).to_string();
        if *files != 1 || parent.map(local) != Some("file") {
            return;
        }
        let t = e.text.trim().to_string();
        match name.as_str() {
            "url" if !t.is_empty() => {
                let n = urls.len();
                urls.push((e.priority.unwrap_or(u32::MAX), n, t));
            }
            "hash" if e.hash_type.as_deref().map(str::to_ascii_lowercase).as_deref() == Some("sha-256") => {
                if t.len() == 64 && t.chars().all(|c| c.is_ascii_hexdigit()) {
                    sha256 = Some(t.to_ascii_lowercase());
                }
            }
            "size" => size = t.parse::<u64>().ok().filter(|n| *n > 0),
            _ => {}
        }
    };
    while i < text.len() {
        let rest = &text[i..];
        if let Some(r) = rest.strip_prefix("<?") {
            i += 2 + r.find("?>")? + 2;
        } else if let Some(r) = rest.strip_prefix("<!--") {
            i += 4 + r.find("-->")? + 3;
        } else if rest.starts_with("<!") {
            return None;
        } else if let Some(r) = rest.strip_prefix("</") {
            let end = r.find('>')?;
            let name = r[..end].trim();
            let open = stack.pop()?;
            if open.name != name {
                return None;
            }
            let parent = stack.last().map(|p| p.name.clone());
            close(open, parent.as_deref(), &mut files);
            i += 2 + end + 1;
        } else if let Some(r) = rest.strip_prefix('<') {
            if stack.is_empty() && root_seen {
                return None;
            }
            let end_name = r.find(|c: char| c.is_whitespace() || c == '/' || c == '>')?;
            let name = &r[..end_name];
            if !name_ok(name) {
                return None;
            }
            let mut open = Open { name: name.to_string(), priority: None, hash_type: None, text: String::new() };
            let mut p = &r[end_name..];
            let mut consumed = end_name;
            let self_closing;
            loop {
                let t = p.trim_start();
                consumed += p.len() - t.len();
                p = t;
                if p.starts_with("/>") {
                    consumed += 2;
                    self_closing = true;
                    break;
                }
                if p.starts_with('>') {
                    consumed += 1;
                    self_closing = false;
                    break;
                }
                let eq = p.find('=')?;
                let key = p[..eq].trim();
                if !name_ok(key) {
                    return None;
                }
                let v = p[eq + 1..].trim_start();
                let q = v.chars().next().filter(|c| *c == '"' || *c == '\'')?;
                let vend = v[1..].find(q)?;
                let raw = &v[1..1 + vend];
                if raw.contains('<') {
                    return None;
                }
                let val = decode(raw)?;
                match local(key) {
                    "priority" => open.priority = val.trim().parse().ok(),
                    "type" => open.hash_type = Some(val),
                    _ => {}
                }
                let used = p.len() - v[1 + vend + 1..].len();
                consumed += used;
                p = &v[1 + vend + 1..];
            }
            root_seen = true;
            if local(&open.name) == "file" {
                files += 1;
            }
            i += 1 + consumed;
            if self_closing {
                let parent = stack.last().map(|p| p.name.clone());
                close(open, parent.as_deref(), &mut files);
            } else {
                stack.push(open);
            }
        } else {
            let end = rest.find('<').unwrap_or(rest.len());
            let chunk = &rest[..end];
            match stack.last_mut() {
                Some(top) => top.text.push_str(&decode(chunk)?),
                None if chunk.trim().is_empty() => {}
                None => return None,
            }
            i += end;
        }
    }
    if !stack.is_empty() || !root_seen || files == 0 {
        return None;
    }
    urls.sort();
    Some(Metalink { mirrors: urls.into_iter().map(|(_, _, u)| u).collect(), sha256, size })
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn reads_mirrors_in_priority_order_with_the_hash_and_size() {
        let doc = format!(
            "<?xml version=\"1.0\"?>\n<!-- c --><metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"><file name=\"a.zim\"><size>42</size>\
             <hash type=\"sha-256\">{}</hash><hash type=\"md5\">zz</hash>\
             <url location=\"x\">https://none.example/a.zim</url>\
             <url priority=\"2\">https://two.example/a?x=1&amp;y=2</url><url priority=\"1\">https://one.example/a.zim</url></file></metalink>",
            HASH.to_uppercase()
        );
        let m = parse(&doc).unwrap();
        assert_eq!(m.mirrors, ["https://one.example/a.zim", "https://two.example/a?x=1&y=2", "https://none.example/a.zim"]);
        assert_eq!((m.sha256.as_deref(), m.size), (Some(HASH), Some(42)));
    }

    #[test]
    fn refuses_what_is_not_well_formed() {
        for bad in [
            "",
            "plain text",
            "<metalink><file><url>x</metalink>",
            "<metalink><file></metalink></file>",
            "<metalink><file/></metalink><extra/>",
            "<!DOCTYPE x [<!ENTITY e \"1\">]><metalink><file><size>&e;</size></file></metalink>",
            "<metalink><file><size>&unknown;</size></file></metalink>",
            "<metalink><file a=b></file></metalink>",
            "<metalink></metalink>",
        ] {
            assert!(parse(bad).is_none(), "{bad:?}");
        }
    }
}
