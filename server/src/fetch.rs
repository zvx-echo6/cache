//! Outbound HTTP for the library features: the catalog fetch proxy (`GET /api/fetch`) and the address rules the downloads share.
//!
//! The client is `ureq`, the one the Cache core crates use (blocking, rustls with the bundled web roots), so every call here
//! runs in `spawn_blocking`. Redirects are never followed by the client: this module follows them itself so each hop can be
//! checked against the allow-list.
//!
//! Which addresses may be read, and what may come back, is decided per scope in `fetch_scope` (catalog, models, video, user);
//! the catalog scope is this file's [`FETCH_HOSTS`] and is the default of `GET /api/fetch`.
//!
//! The server only ever connects to public addresses for an address a tab supplied: the fetch scopes other than catalog, and the
//! library downloads, their checksum files and icons (`fetch_scope::guarded_agent`). Private, loopback, link-local (including the
//! metadata address 169.254.169.254) and Tailscale 100.64/10 are refused when the connection is made, on every redirect. The
//! three catalog hosts are the one exception.

use crate::fetch_scope::{Policy, PublicResolver, Scope};
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The hosts the app's catalog screens read from, and nothing else (app/lib, checked 2026-11-01):
///   opds.library.kiwix.org  the Kiwix OPDS catalog (browse/opds.dart `kiwixCatalogHost`) and its icons
///   data.cached.info        Cache's published data: region and off-road catalogs, routing and places, `app/latest.json`,
///                           `models/recommended.json` (search/core_config.dart `kDataBaseUrl`)
///   cache.echo6.co          the same bucket under its other name, and the connector catalog
///                           (settings/app_settings.dart `kDefaultCatalogueUrl`, `catalogue.json`)
/// The big files (ZIMs and library packages) are not fetched through here: they are server-side downloads.
pub const FETCH_HOSTS: [&str; 3] = ["opds.library.kiwix.org", "data.cached.info", "cache.echo6.co"];

/// The most a fetched answer may be: catalogs, not files.
pub const FETCH_MAX_BYTES: u64 = 50 << 20;

/// How long to wait for a connection.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

const USER_AGENT: &str = concat!("Cache/", env!("CARGO_PKG_VERSION"));

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
    } else {
        (false, s.strip_prefix("http://")?)
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
    /// The answer is not a kind of thing this scope hands on (a page, a video, a file).
    BadType(String),
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
    agent_with(None)
}

/// [`agent`], with a resolver that decides which addresses a name may connect to (see `fetch_scope::PublicResolver`).
pub fn agent_with(resolver: Option<PublicResolver>) -> ureq::Agent {
    let b = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(CONNECT_TIMEOUT)
        .timeout_read(Duration::from_secs(60))
        .user_agent(USER_AGENT);
    match resolver {
        Some(r) => b.resolver(r).build(),
        None => b.build(),
    }
}

/// A Kiwix catalog icon asked for at a size the catalog does not have (it answers 404 for anything but the 48 px its feed
/// links): the same icon at 48. None for any other address, or one already at 48 (so the retry happens once).
pub fn illustration_fallback(url: &str) -> Option<String> {
    let p = parse_url(url)?;
    if p.host != "opds.library.kiwix.org" {
        return None;
    }
    let (base, query) = url.split_once('?')?;
    if !base.contains("/catalog/v2/illustration/") || query.split('&').any(|kv| kv == "size=48") {
        return None;
    }
    let rest: Vec<&str> = query.split('&').filter(|kv| !kv.starts_with("size=")).collect();
    let mut out = format!("{base}?size=48");
    for kv in rest {
        out.push('&');
        out.push_str(kv);
    }
    Some(out)
}

/// An answer being read.
pub struct Opened {
    pub content_type: Option<String>,
    pub reader: Box<dyn Read + Send + Sync>,
}

/// GET `url` (blocking) in the `catalog` scope: [`open_with`] on the catalog hosts.
pub fn open(hosts: &[String], url: &str, max: u64) -> Result<Opened, FetchError> {
    open_with(&Policy::new(Scope::Catalog, hosts.to_vec()), url, max)
}

/// GET `url` (blocking) under `policy`, following up to six redirects, each of which must pass it too. The answer's declared size
/// is held to `max`, and its type to the scope's (see `fetch_scope`).
pub fn open_with(policy: &Policy, url: &str, max: u64) -> Result<Opened, FetchError> {
    let refused = Arc::new(AtomicBool::new(false));
    let agent = if policy.public_only() { agent_with(Some(PublicResolver { refused: refused.clone(), exempt: vec![] })) } else { agent() };
    let mut cur = url.to_string();
    let started = Instant::now();
    for hop in 0..7 {
        policy.check(&cur, hop == 0)?;
        let mut req = agent.get(&cur);
        if policy.scope != Scope::Catalog {
            // one deadline for the whole read, redirects and body included
            let left = policy.deadline.saturating_sub(started.elapsed());
            if left.is_zero() {
                return Err(FetchError::Unreachable("it took too long".into()));
            }
            req = req.timeout(left);
        }
        let resp = match req.call() {
            Ok(r) => r,
            Err(ureq::Error::Status(404, _)) if illustration_fallback(&cur).is_some() => {
                // The catalog only serves its icons at the size its own feed links (48); another size is a 404.
                cur = illustration_fallback(&cur).unwrap_or_default();
                continue;
            }
            Err(ureq::Error::Status(code, _)) => return Err(FetchError::Upstream(code)),
            Err(_) if refused.load(Ordering::Relaxed) => return Err(FetchError::Denied(parse_url(&cur).map(|p| p.host).unwrap_or_default())),
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
        if !policy.type_ok(content_type.as_deref()) {
            return Err(FetchError::BadType(content_type.unwrap_or_default()));
        }
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

    #[test]
    fn a_catalogue_icon_at_another_size_falls_back_to_48() {
        let u = "https://opds.library.kiwix.org/catalog/v2/illustration/abc/?size=96";
        assert_eq!(illustration_fallback(u).as_deref(), Some("https://opds.library.kiwix.org/catalog/v2/illustration/abc/?size=48"));
        assert_eq!(
            illustration_fallback("https://opds.library.kiwix.org/catalog/v2/illustration/abc/?x=1&size=128").as_deref(),
            Some("https://opds.library.kiwix.org/catalog/v2/illustration/abc/?size=48&x=1")
        );
        // already 48, no query, another path or another host: no retry
        assert_eq!(illustration_fallback("https://opds.library.kiwix.org/catalog/v2/illustration/abc/?size=48"), None);
        assert_eq!(illustration_fallback("https://opds.library.kiwix.org/catalog/v2/illustration/abc/"), None);
        assert_eq!(illustration_fallback("https://opds.library.kiwix.org/catalog/v2/entries?size=96"), None);
        assert_eq!(illustration_fallback("https://data.cached.info/catalog/v2/illustration/abc/?size=96"), None);
    }
}
