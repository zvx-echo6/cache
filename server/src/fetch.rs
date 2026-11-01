//! Outbound HTTP for the library features: the catalogue fetch proxy (`GET /api/fetch`) and the address rules the downloads share.
//!
//! The client is `ureq`, the one the Cache core crates use (blocking, rustls with the bundled web roots), so every call here
//! runs in `spawn_blocking`. Redirects are never followed by the client: this module follows them itself so each hop can be
//! checked against the allow-list.

use std::io::Read;
use std::time::Duration;

/// The hosts the app's catalogue screens read from, and nothing else (app/lib, checked 2026-11-01):
///   opds.library.kiwix.org  the Kiwix OPDS catalogue (browse/opds.dart `kiwixCatalogHost`) and its icons
///   data.cached.info        Cache's published data: region and off-road catalogues, routing and places, `app/latest.json`,
///                           `models/recommended.json` (search/core_config.dart `kDataBaseUrl`)
///   cache.echo6.co          the same bucket under its other name, and the connector catalogue
///                           (settings/app_settings.dart `kDefaultCatalogueUrl`, `catalogue.json`)
/// The big files (ZIMs and library packages) are not fetched through here: they are server-side downloads.
pub const FETCH_HOSTS: [&str; 3] = ["opds.library.kiwix.org", "data.cached.info", "cache.echo6.co"];

/// The most a fetched answer may be: catalogues, not files.
pub const FETCH_MAX_BYTES: u64 = 50 << 20;

/// How long to wait for a connection.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

const USER_AGENT: &str = concat!("Cache-Server/", env!("CARGO_PKG_VERSION"));

/// An address taken apart. Only what the rules need.
#[derive(Debug, PartialEq)]
pub struct Parsed {
    pub https: bool,
    pub host: String,
    pub port: Option<u16>,
}

/// `localhost` and `127.0.0.1`: a test server on this machine, the one case where plain `http` is accepted (as the phone's
/// own `isFetchAllowed` does).
pub fn is_loopback(host: &str) -> bool {
    host == "localhost" || host == "127.0.0.1"
}

/// Take an `http(s)://host[:port]/...` address apart. Strict on purpose: anything the allow-list check and the client could read
/// differently (user names, backslashes, spaces, non-ASCII, IPv6 brackets, odd host characters) is refused.
pub fn parse_url(s: &str) -> Option<Parsed> {
    if s.len() > 2048 || !s.is_ascii() || s.bytes().any(|b| b <= 0x20 || b == 0x7f || b == b'\\') {
        return None;
    }
    let (https, rest) = if let Some(r) = s.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = s.strip_prefix("http://") {
        (false, r)
    } else {
        return None;
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let auth = &rest[..end];
    if auth.is_empty() || auth.contains('@') || auth.contains('[') || auth.contains('%') {
        return None;
    }
    let (host, port) = match auth.rsplit_once(':') {
        Some((h, p)) => (h, Some(p.parse::<u16>().ok()?)),
        None => (auth, None),
    };
    let ok_char = |c: char| c.is_ascii_alphanumeric() || c == '.' || c == '-';
    if host.is_empty() || !host.chars().all(ok_char) || host.starts_with(['.', '-']) || host.ends_with(['.', '-']) {
        return None;
    }
    Some(Parsed { https, host: host.to_ascii_lowercase(), port })
}

/// True for an address a download or fetch may use: `https`, or `http` to this machine. A port other than the scheme's own is
/// accepted only for this machine.
pub fn scheme_ok(p: &Parsed) -> bool {
    if is_loopback(&p.host) {
        return true;
    }
    p.https && matches!(p.port, None | Some(443))
}

/// Why a fetch was not made or did not finish.
#[derive(Debug, PartialEq)]
pub enum FetchError {
    /// Not an address this server will read (shape, scheme).
    BadUrl,
    /// A host that is not on the allow-list (also a redirect to one).
    Denied(String),
    /// The upstream answered with this status.
    Upstream(u16),
    /// The answer is, or says it is, over the size cap.
    TooLarge,
    TooManyRedirects,
    /// No connection, a timeout, a broken answer.
    Unreachable(String),
}

/// Check an address against the allow-list.
pub fn check(hosts: &[String], url: &str) -> Result<Parsed, FetchError> {
    let p = parse_url(url).ok_or(FetchError::BadUrl)?;
    if !hosts.iter().any(|h| h.eq_ignore_ascii_case(&p.host)) {
        return Err(FetchError::Denied(p.host));
    }
    if !scheme_ok(&p) {
        return Err(FetchError::BadUrl);
    }
    Ok(p)
}

/// The address a `Location` header points to, from the address it came with.
pub fn resolve(base: &str, loc: &str) -> Option<String> {
    if loc.starts_with("http://") || loc.starts_with("https://") {
        return Some(loc.to_string());
    }
    let after = base.find("://")? + 3;
    let auth_end = base[after..].find(['/', '?', '#']).map_or(base.len(), |i| i + after);
    if let Some(rest) = loc.strip_prefix("//") {
        return Some(format!("{}//{rest}", &base[..after - 2]));
    }
    if loc.starts_with('/') {
        return Some(format!("{}{loc}", &base[..auth_end]));
    }
    let path_end = base.find(['?', '#']).unwrap_or(base.len());
    match base[..path_end].rfind('/').filter(|&i| i >= auth_end) {
        Some(i) => Some(format!("{}{loc}", &base[..=i])),
        None => Some(format!("{}/{loc}", &base[..auth_end])),
    }
}

/// `%XX` and `+` decoded; None for a bad escape or text that is not UTF-8.
pub fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => {
                let hex = s.get(i + 1..i + 3)?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

/// The decoded value of `name` in a query string.
pub fn query_param(query: &str, name: &str) -> Option<String> {
    query.split('&').filter_map(|kv| kv.split_once('=')).find(|(k, _)| *k == name).and_then(|(_, v)| percent_decode(v))
}

/// A client that follows no redirects and gives up connecting after [`CONNECT_TIMEOUT`].
pub fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(CONNECT_TIMEOUT)
        .timeout_read(Duration::from_secs(60))
        .user_agent(USER_AGENT)
        .build()
}

/// An answer being read.
pub struct Opened {
    pub content_type: Option<String>,
    pub reader: Box<dyn Read + Send + Sync>,
}

/// GET `url` (blocking), following up to six redirects, each of which must be on the allow-list too. The answer's declared size is
/// held to `max`.
pub fn open(hosts: &[String], url: &str, max: u64) -> Result<Opened, FetchError> {
    let agent = agent();
    let mut cur = url.to_string();
    for _ in 0..7 {
        check(hosts, &cur)?;
        let resp = match agent.get(&cur).call() {
            Ok(r) => r,
            Err(ureq::Error::Status(code, _)) => return Err(FetchError::Upstream(code)),
            Err(e) => return Err(FetchError::Unreachable(e.to_string())),
        };
        let status = resp.status();
        if matches!(status, 301 | 302 | 303 | 307 | 308) {
            let loc = resp.header("location").ok_or_else(|| FetchError::Unreachable("a redirect with no address".into()))?;
            cur = resolve(&cur, loc).ok_or(FetchError::BadUrl)?;
            continue;
        }
        if status != 200 {
            return Err(FetchError::Upstream(status));
        }
        if resp.header("content-length").and_then(|v| v.trim().parse::<u64>().ok()).is_some_and(|n| n > max) {
            return Err(FetchError::TooLarge);
        }
        let content_type = resp.header("content-type").map(str::to_string);
        return Ok(Opened { content_type, reader: resp.into_reader() });
    }
    Err(FetchError::TooManyRedirects)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hosts() -> Vec<String> {
        FETCH_HOSTS.iter().map(|h| h.to_string()).collect()
    }

    #[test]
    fn the_catalogue_hosts_are_allowed_and_nothing_else() {
        let h = hosts();
        for u in [
            "https://opds.library.kiwix.org/catalog/v2/entries?count=20",
            "https://data.cached.info/regions/catalogue.json",
            "https://cache.echo6.co/connectors/catalogue.json",
            "https://DATA.cached.info/x",
        ] {
            assert!(check(&h, u).is_ok(), "{u}");
        }
        for u in [
            "https://download.kiwix.org/zim/x.zim",
            "https://evil.example/",
            "https://data.cached.info.evil.example/",
            "https://evildata.cached.info/",
            "https://example.com/?u=https://data.cached.info/",
        ] {
            assert!(matches!(check(&h, u), Err(FetchError::Denied(_))), "{u}");
        }
        for u in [
            "http://data.cached.info/x",
            "ftp://data.cached.info/x",
            "file:///etc/passwd",
            "data.cached.info/x",
            "https://data.cached.info:8443/x",
            "https://user@data.cached.info/x",
            "https://data.cached.info\\@evil.example/",
            "https://data.cached.info@evil.example/",
            "https://data.cached.info /x",
            "https://[::1]/x",
            "https://",
            "",
        ] {
            assert_eq!(check(&h, u).unwrap_err(), FetchError::BadUrl, "{u}");
        }
        // a test server on this machine is reachable over plain http only when it is on the list
        assert!(matches!(check(&h, "http://127.0.0.1:8080/x"), Err(FetchError::Denied(_))));
        assert!(check(&["127.0.0.1".to_string()], "http://127.0.0.1:8080/x").is_ok());
    }

    #[test]
    fn redirects_resolve_like_a_browser() {
        assert_eq!(resolve("https://a.example/x/y?q=1", "https://b.example/z").as_deref(), Some("https://b.example/z"));
        assert_eq!(resolve("https://a.example/x/y?q=1", "//b.example/z").as_deref(), Some("https://b.example/z"));
        assert_eq!(resolve("https://a.example/x/y?q=1", "/z").as_deref(), Some("https://a.example/z"));
        assert_eq!(resolve("https://a.example/x/y?q=1", "z").as_deref(), Some("https://a.example/x/z"));
        assert_eq!(resolve("https://a.example", "z").as_deref(), Some("https://a.example/z"));
        assert_eq!(resolve("https://a.example?q=/", "/z").as_deref(), Some("https://a.example/z"));
    }

    #[test]
    fn query_values_are_decoded() {
        assert_eq!(query_param("url=https%3A%2F%2Fa.example%2Fx%3Fy%3D1&n=2", "url").as_deref(), Some("https://a.example/x?y=1"));
        assert_eq!(query_param("kind=zim&name=a+b.zim", "name").as_deref(), Some("a b.zim"));
        assert_eq!(query_param("kind=zim", "name"), None);
        assert_eq!(query_param("name=%zz", "name"), None);
        assert_eq!(query_param("name=%FF", "name"), None);
    }
}
