//! Which addresses `GET /api/fetch` may read, by scope.
//!
//! The phone reads any https address its features name. A browser can read none (cross-origin), so on web the server reads for
//! it. The server must not become a way for a signed-in tab to reach any host, so each kind of read gets its own scope, with
//! its own rule for host and path, and the answer is held to the kind of thing that scope reads (catalogs, captions, icons).
//!
//!   catalog  the three hosts the catalog screens read (`fetch::FETCH_HOSTS`); the default, and what the route did before scopes
//!   models   Hugging Face's model API (`/api/models...`) and the catalog hosts (Cache's published `models/recommended.json`);
//!            with `download` set (the models item's server-side download) also its file paths and its file hosts
//!   video    a PeerTube site: only its REST API (`/api/v1/`) and its caption and thumbnail files (`/lazy-static/`, `/static/`);
//!            a redirect (to its object storage) may go to any public host
//!   user     an address the person typed (an own data source's "Try this address"): any public host, nothing else relaxed
//!
//! Every scope but `catalog` also holds to: no address that is not on the public internet. The check is made on the addresses a
//! name resolves to, at connect time ([`PublicResolver`]), so a redirect, a rebinding name or an odd spelling of 127.0.0.1 gets no
//! further than a plain one. Anything but a small text, JSON, XML or image answer is refused, and answers are capped at
//! [`SMALL_MAX_BYTES`]; a big file is a download job, which is where the phone's data policy applies (design:
//! `renders/linux-parity/fetch-design.md`).

use crate::fetch::{is_loopback, parse_url, FetchError, Parsed};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// The most a non-catalog scope may answer: listings, captions and icons, not files.
pub const SMALL_MAX_BYTES: u64 = 8 << 20;

/// Hugging Face's host (the model API, and the file addresses a download starts from).
pub const HF_HOST: &str = "huggingface.co";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Catalog,
    Models,
    Video,
    User,
}

impl Scope {
    /// `catalog`, `models`, `video` or `user`; None for anything else.
    pub fn parse(s: &str) -> Option<Scope> {
        Some(match s {
            "catalog" => Scope::Catalog,
            "models" => Scope::Models,
            "video" => Scope::Video,
            "user" => Scope::User,
            _ => return None,
        })
    }
}

/// The rules of one read.
#[derive(Clone, Debug)]
pub struct Policy {
    pub scope: Scope,
    /// The `catalog` hosts (also the hosts `models` may read besides Hugging Face).
    pub catalog_hosts: Vec<String>,
    /// Plain `http` (port 80) is accepted as well as `https`: the caller said the phone's `httpsOnly` is off (a video server's captions).
    pub plain: bool,
    /// For a download job: `models` also accepts Hugging Face file paths and its file hosts. No cap and no type check then.
    pub download: bool,
    /// Tests only: addresses on this machine are readable.
    pub allow_private: bool,
    /// The most one read may take in all (each request, redirects included, and its body), so a slow trickle cannot hold a slot.
    /// The catalog scope has none: its reads are few and from our own hosts.
    pub deadline: std::time::Duration,
}

/// How long one read of a non-catalog scope may take in all.
pub const READ_DEADLINE: std::time::Duration = std::time::Duration::from_secs(90);

impl Policy {
    pub fn new(scope: Scope, catalog_hosts: Vec<String>) -> Policy {
        Policy { scope, catalog_hosts, plain: false, download: false, allow_private: false, deadline: READ_DEADLINE }
    }

    /// Whether the connection must be refused for any address that is not public.
    pub fn public_only(&self) -> bool {
        self.scope != Scope::Catalog && !self.allow_private
    }

    /// The most the answer may be, given the catalog cap.
    pub fn max_bytes(&self, catalog_max: u64) -> u64 {
        if self.scope == Scope::Catalog {
            catalog_max
        } else {
            SMALL_MAX_BYTES
        }
    }

    /// Check an address. `first` is the address asked for; a later one is a redirect hop.
    pub fn check(&self, url: &str, first: bool) -> Result<Parsed, FetchError> {
        let p = parse_url(url).ok_or(FetchError::BadUrl)?;
        let path = path_of(url);
        let host_listed = self.catalog_hosts.iter().any(|h| h.eq_ignore_ascii_case(&p.host));
        match self.scope {
            Scope::Catalog => {
                if !host_listed {
                    return Err(FetchError::Denied(p.host));
                }
            }
            Scope::Models => {
                let hf = p.host == HF_HOST;
                let ok = if self.download {
                    hf || host_listed || is_hf_file_host(&p.host)
                } else {
                    (hf && (path == "/api/models" || path.starts_with("/api/models/"))) || host_listed
                };
                if !ok || (hf && !self.download && !path_clean(path)) {
                    return Err(FetchError::Denied(p.host));
                }
            }
            Scope::Video => {
                if !self.allow_private && !public_name(&p.host) {
                    return Err(FetchError::Denied(p.host));
                }
                let api = ["/api/v1/", "/lazy-static/", "/static/"].iter().any(|pre| path.starts_with(pre));
                if first && !(api && path_clean(path)) {
                    return Err(FetchError::Denied(p.host));
                }
            }
            Scope::User => {
                if !self.allow_private && !public_name(&p.host) {
                    return Err(FetchError::Denied(p.host));
                }
            }
        }
        if !self.scheme_ok(&p) {
            return Err(FetchError::BadUrl);
        }
        Ok(p)
    }

    fn scheme_ok(&self, p: &Parsed) -> bool {
        if self.scope == Scope::Catalog {
            // the rule the catalog route always had (https, or plain http to this machine)
            return crate::fetch::scheme_ok(p);
        }
        if self.allow_private && is_loopback(&p.host) {
            return true;
        }
        if p.https {
            return matches!(p.port, None | Some(443));
        }
        // Plain http is only for a scope that reads other people's servers, and only when the caller asked for it.
        self.plain && self.scope != Scope::Catalog && self.scope != Scope::Models && matches!(p.port, None | Some(80))
    }

    /// Whether an answer of this type may be handed on. `catalog` and a download take whatever the host sends.
    pub fn type_ok(&self, content_type: Option<&str>) -> bool {
        if self.scope == Scope::Catalog || self.download {
            return true;
        }
        let t = content_type.and_then(|c| c.split(';').next()).unwrap_or("").trim().to_ascii_lowercase();
        match t.as_str() {
            "" | "text/html" | "application/xhtml+xml" | "image/svg+xml" => false,
            "application/json" | "application/xml" | "application/x-subrip" => true,
            _ => t.ends_with("+json") || t.ends_with("+xml") || t.starts_with("text/") || t.starts_with("image/"),
        }
    }
}

/// The path of an address (between the host and any `?` or `#`); "/" when there is none. The address has passed `parse_url`.
fn path_of(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let from = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let tail = &rest[from..];
    let path = &tail[..tail.find(['?', '#']).unwrap_or(tail.len())];
    if path.is_empty() {
        "/"
    } else {
        path
    }
}

/// No `..` segment, and no escaped dot, slash or backslash that a server might turn into one.
fn path_clean(path: &str) -> bool {
    let l = path.to_ascii_lowercase();
    !path.split('/').any(|s| s == "..") && !["%2e", "%2f", "%5c"].iter().any(|e| l.contains(e))
}

/// Hugging Face's file hosts (its CDN and its Xet bridge), which a model download is redirected to.
fn is_hf_file_host(host: &str) -> bool {
    host == "hf.co" || host.ends_with(".hf.co") || host.ends_with(".huggingface.co")
}

/// A name that can be on the public internet: it has a dot, its last label is not a number (that is an address, in some spelling),
/// and it does not end in a suffix that means a private network. The real check is [`PublicResolver`]; this one stops the
/// obvious before any lookup.
pub fn public_name(host: &str) -> bool {
    let Some((_, last)) = host.rsplit_once('.') else { return false };
    if last.is_empty() || last.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    !["local", "localhost", "internal", "lan", "home", "localdomain", "intranet", "corp", "arpa"].contains(&last)
}

/// Whether an address is on the public internet. Everything that is private, loopback, link-local (cloud metadata is 169.254.169.254),
/// shared (100.64/10 is Tailscale and carrier NAT), unspecified, multicast, documentation or reserved is not.
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => is_public_v4(a),
        IpAddr::V6(a) => is_public_v6(a),
    }
}

fn is_public_v4(a: Ipv4Addr) -> bool {
    let o = a.octets();
    !(a.is_unspecified()
        || a.is_loopback()
        || a.is_private()
        || a.is_link_local()
        || a.is_broadcast()
        || a.is_multicast()
        || o[0] == 0
        || (o[0] == 100 && (o[1] & 0xc0) == 64) // 100.64.0.0/10
        || (o[0] == 192 && o[1] == 0 && o[2] == 0) // 192.0.0.0/24
        || (o[0] == 192 && o[1] == 0 && o[2] == 2) // 192.0.2.0/24
        || (o[0] == 198 && (o[1] & 0xfe) == 18) // 198.18.0.0/15
        || (o[0] == 198 && o[1] == 51 && o[2] == 100) // 198.51.100.0/24
        || (o[0] == 203 && o[1] == 0 && o[2] == 113) // 203.0.113.0/24
        || o[0] >= 240) // 240.0.0.0/4
}

fn is_public_v6(a: Ipv6Addr) -> bool {
    let s = a.segments();
    // An IPv4 address carried inside one: ::ffff:a.b.c.d, ::a.b.c.d, 64:ff9b::a.b.c.d and 2002:aabb:ccdd:: (6to4).
    let inner = |hi: u16, lo: u16| Ipv4Addr::new((hi >> 8) as u8, hi as u8, (lo >> 8) as u8, lo as u8);
    if s[..5] == [0, 0, 0, 0, 0] && s[5] == 0xffff {
        return is_public_v4(inner(s[6], s[7]));
    }
    if s[..6] == [0, 0, 0, 0, 0, 0] && !a.is_unspecified() && !a.is_loopback() {
        return is_public_v4(inner(s[6], s[7]));
    }
    if s[0] == 0x64 && s[1] == 0xff9b && s[2..6] == [0, 0, 0, 0] {
        return is_public_v4(inner(s[6], s[7]));
    }
    if s[0] == 0x2002 {
        return is_public_v4(inner(s[1], s[2]));
    }
    !(a.is_unspecified()
        || a.is_loopback()
        || a.is_multicast()
        || (s[..4] == [0, 0, 0, 0] && s[4] == 0xffff && s[5] == 0) // ::ffff:0:0/96 (IPv4-translated, ::ffff:0:a.b.c.d)
        || (s[0] == 0x64 && s[1] == 0xff9b && s[2] == 1) // 64:ff9b:1::/48 (local-use NAT64)
        || (s[0] == 0x2001 && s[1] == 0) // 2001::/32 Teredo
        || (s[0] & 0xfe00) == 0xfc00 // fc00::/7 unique local
        || (s[0] & 0xffc0) == 0xfe80 // fe80::/10 link-local
        || (s[0] & 0xffc0) == 0xfec0 // fec0::/10 site-local
        || (s[0] == 0x2001 && s[1] == 0x0db8) // documentation
        || (s[0] == 0x100 && s[1..4] == [0, 0, 0])) // 100::/64 discard
}

/// Looks a name up like the system does and refuses it when any address it gives is not public. It is the connect-time check:
/// the connection can only go to an address that was checked.
#[derive(Debug)]
pub struct PublicResolver {
    /// Set when an address was refused, so the caller can say "not allowed" and not "unreachable".
    pub refused: Arc<AtomicBool>,
    /// Host names that are looked up without the check: the catalog hosts, which the server has always read.
    pub exempt: Vec<String>,
}

impl ureq::Resolver for PublicResolver {
    fn resolve(&self, netloc: &str) -> io::Result<Vec<SocketAddr>> {
        let addrs: Vec<SocketAddr> = netloc.to_socket_addrs()?.collect();
        let host = netloc.rsplit_once(':').map_or(netloc, |(h, _)| h).to_ascii_lowercase();
        if self.exempt.iter().any(|h| h.eq_ignore_ascii_case(&host)) && !addrs.is_empty() {
            return Ok(addrs);
        }
        if addrs.is_empty() || addrs.iter().any(|a| !is_public(a.ip())) {
            self.refused.store(true, Ordering::Relaxed);
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "that address is not on the public internet"));
        }
        Ok(addrs)
    }
}

/// The client for a read of an address a tab supplied (a download, its checksum, its icon): it connects only to public addresses,
/// on every hop, except for the `exempt` catalog hosts. The flag is set when it refused one. `allow_private` is for tests.
pub fn guarded_agent(exempt: &[String], allow_private: bool) -> (ureq::Agent, Arc<AtomicBool>) {
    let refused = Arc::new(AtomicBool::new(false));
    if allow_private {
        return (crate::fetch::agent(), refused);
    }
    (crate::fetch::agent_with(Some(PublicResolver { refused: refused.clone(), exempt: exempt.to_vec() })), refused)
}

/// The early answer for an address a tab supplied: false for one that cannot be public (an address in any spelling, `localhost`,
/// `.local`). A name that looks public is still checked at connect time. The `exempt` catalog hosts and `allow_private` pass.
pub fn address_ok(p: &Parsed, exempt: &[String], allow_private: bool) -> bool {
    if allow_private || exempt.iter().any(|h| h.eq_ignore_ascii_case(&p.host)) {
        return true;
    }
    match p.host.parse::<Ipv4Addr>() {
        Ok(a) => is_public_v4(a),
        Err(_) => public_name(&p.host),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pol(scope: Scope) -> Policy {
        Policy::new(scope, crate::fetch::FETCH_HOSTS.iter().map(|h| h.to_string()).collect())
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn only_public_addresses_are_public() {
        for a in [
            "8.8.8.8", "1.1.1.1", "93.184.216.34", "172.32.0.1", "100.63.255.255", "100.128.0.1", "2606:4700:4700::1111", "2a00:1450:4001::200e",
            "::ffff:8.8.8.8", "64:ff9b::808:808", "2001:4860:4860::8888",
        ] {
            assert!(is_public(ip(a)), "{a}");
        }
        for a in [
            "0.0.0.0", "0.1.2.3", "127.0.0.1", "127.9.9.9", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.240", "169.254.169.254",
            "100.64.0.4", "100.127.255.255", "192.0.0.1", "192.0.2.1", "198.18.0.1", "198.19.255.255", "198.51.100.1", "203.0.113.9", "224.0.0.1",
            "240.0.0.1", "255.255.255.255", "::", "::1", "fe80::1", "fc00::1", "fd12:3456::1", "fec0::1", "ff02::1", "2001:db8::1",
            "::ffff:0:8.8.8.8", "::ffff:0:127.0.0.1", "64:ff9b:1::808:808", "64:ff9b:1::1", "2001::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2",
            "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254", "::127.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::1", "2002:c0a8:101::",
        ] {
            assert!(!is_public(ip(a)), "{a}");
        }
    }

    #[test]
    fn names_that_cannot_be_public_are_stopped_before_any_lookup() {
        for h in ["peertube.example", "a.b.example.org", "xn--e1afmkfd.xn--p1ai"] {
            assert!(public_name(h), "{h}");
        }
        for h in ["localhost", "intranet", "127.0.0.1", "10.1.2.3", "2130706433", "127.1", "printer.local", "nas.lan", "x.internal", "a.localhost", "1.0.0.127.in-addr.arpa", "router.home"] {
            assert!(!public_name(h), "{h}");
        }
    }

    #[test]
    fn catalog_scope_is_the_old_allow_list() {
        let p = pol(Scope::Catalog);
        assert!(p.check("https://data.cached.info/a.json", true).is_ok());
        assert!(matches!(p.check("https://peertube.example/api/v1/videos", true), Err(FetchError::Denied(_))));
        assert!(matches!(p.check("https://huggingface.co/api/models", true), Err(FetchError::Denied(_))));
        let mut plain = pol(Scope::Catalog);
        plain.plain = true;
        assert_eq!(plain.check("http://data.cached.info/a.json", true).unwrap_err(), FetchError::BadUrl);
    }

    #[test]
    fn models_scope_reads_the_hugging_face_api_and_the_catalog_hosts() {
        let p = pol(Scope::Models);
        for u in [
            "https://huggingface.co/api/models?search=gemma&filter=gguf",
            "https://huggingface.co/api/models/acme/tiny-GGUF/tree/main?recursive=true",
            "https://data.cached.info/models/recommended.json",
        ] {
            assert!(p.check(u, true).is_ok(), "{u}");
        }
        for u in [
            "https://huggingface.co/acme/tiny-GGUF/resolve/main/m.gguf", // a file: a download job
            "https://huggingface.co/api/models/../../x",
            "https://huggingface.co/api/models/%2e%2e/x",
            "https://huggingface.co/api/modelsx",
            "https://huggingface.co.evil.example/api/models",
            "https://cdn-lfs.hf.co/x",
            "https://evil.example/api/models",
        ] {
            assert!(matches!(p.check(u, true), Err(FetchError::Denied(_))), "{u}");
        }
        assert_eq!(p.check("http://huggingface.co/api/models", true).unwrap_err(), FetchError::BadUrl);
        // plain http is never taken for models, even when asked
        let mut plain = pol(Scope::Models);
        plain.plain = true;
        assert_eq!(plain.check("http://huggingface.co/api/models", true).unwrap_err(), FetchError::BadUrl);
    }

    #[test]
    fn models_download_takes_hugging_face_files_and_their_hosts() {
        let mut p = pol(Scope::Models);
        p.download = true;
        for u in [
            "https://huggingface.co/acme/tiny-GGUF/resolve/main/m.gguf",
            "https://cdn-lfs.hf.co/repos/ab/cd/x?response-content-disposition=attachment",
            "https://cas-bridge.xethub.hf.co/xet-bridge-us/x",
            "https://cdn-lfs-us-1.huggingface.co/x",
            "https://data.cached.info/models/tuned.gguf",
        ] {
            assert!(p.check(u, true).is_ok(), "{u}");
        }
        for u in ["https://evil.example/x", "https://hf.co.evil.example/x", "https://nothf.co/x", "https://peertube.example/api/v1/videos"] {
            assert!(matches!(p.check(u, true), Err(FetchError::Denied(_))), "{u}");
        }
        assert!(p.type_ok(Some("application/octet-stream")));
        assert!(p.public_only());
    }

    #[test]
    fn video_scope_reads_only_the_peertube_api_and_its_files() {
        let p = pol(Scope::Video);
        for u in [
            "https://peertube.example/api/v1/videos/abc/captions",
            "https://tube.example.org/lazy-static/video-captions/x-en.vtt",
            "https://tube.example.org/static/thumbnails/x.jpg",
        ] {
            assert!(p.check(u, true).is_ok(), "{u}");
        }
        for u in [
            "https://peertube.example/",
            "https://peertube.example/admin/x",
            "https://peertube.example/api/v2/x",
            "https://peertube.example/api/v1/../../etc/passwd",
            "https://peertube.example/lazy-static/%2e%2e/x",
            "https://localhost/api/v1/videos",
            "https://127.0.0.1/api/v1/videos",
            "https://2130706433/api/v1/videos",
            "https://nas.local/api/v1/videos",
            "https://192.168.1.240/api/v1/videos",
        ] {
            assert!(matches!(p.check(u, true), Err(FetchError::Denied(_))), "{u}");
        }
        // a redirect to the site's object storage may go to any public host and any path, not to a private one
        assert!(p.check("https://s3.example.net/bucket/captions/x.vtt?sig=1", false).is_ok());
        assert!(matches!(p.check("https://192.168.1.1/x", false), Err(FetchError::Denied(_))));
        for u in ["https://169.254.169.254/latest/meta-data", "http://localhost/x", "https://10.0.0.1/x", "https://100.64.0.4/x"] {
            assert!(matches!(p.check(u, false), Err(FetchError::Denied(_))), "{u}");
        }
        // http only when asked, and only on port 80
        assert_eq!(p.check("http://peertube.example/api/v1/videos", true).unwrap_err(), FetchError::BadUrl);
        let mut plain = pol(Scope::Video);
        plain.plain = true;
        assert!(plain.check("http://peertube.example/api/v1/videos", true).is_ok());
        assert_eq!(plain.check("http://peertube.example:8080/api/v1/videos", true).unwrap_err(), FetchError::BadUrl);
        assert_eq!(plain.check("https://peertube.example:8443/api/v1/videos", true).unwrap_err(), FetchError::BadUrl);
    }

    #[test]
    fn user_scope_reads_any_public_name_and_no_private_one() {
        let p = pol(Scope::User);
        assert!(p.check("https://api.example.org/data.json?x=1", true).is_ok());
        for u in ["https://localhost/x", "https://127.0.0.1/x", "https://10.0.0.5/x", "https://[::1]/x", "https://metadata.internal/x", "https://100.64.0.4/x"] {
            assert!(p.check(u, true).is_err(), "{u}");
        }
        assert_eq!(p.check("http://api.example.org/x", true).unwrap_err(), FetchError::BadUrl);
    }

    #[test]
    fn only_small_readable_types_leave_a_non_catalog_scope() {
        let p = pol(Scope::User);
        for t in ["application/json", "application/json; charset=utf-8", "application/atom+xml", "text/vtt", "text/plain", "image/png", "image/jpeg", "APPLICATION/XML", "application/x-subrip"] {
            assert!(p.type_ok(Some(t)), "{t}");
        }
        for t in ["text/html", "text/html; charset=utf-8", "application/xhtml+xml", "image/svg+xml", "application/octet-stream", "video/mp4", "application/zip", ""] {
            assert!(!p.type_ok(Some(t)), "{t}");
        }
        assert!(!p.type_ok(None));
        assert!(pol(Scope::Catalog).type_ok(None));
    }

    #[test]
    fn scopes_are_named_and_non_catalog_ones_are_capped_small() {
        assert_eq!(Scope::parse("video"), Some(Scope::Video));
        assert_eq!(Scope::parse("Video"), None);
        assert_eq!(Scope::parse(""), None);
        assert_eq!(pol(Scope::Catalog).max_bytes(50 << 20), 50 << 20);
        assert_eq!(pol(Scope::User).max_bytes(50 << 20), SMALL_MAX_BYTES);
        assert!(!pol(Scope::Catalog).public_only());
        assert!(pol(Scope::Models).public_only());
    }

    #[test]
    fn a_tab_supplied_download_address_must_be_able_to_be_public() {
        let ex = vec!["data.cached.info".to_string()];
        let ok = |u: &str| address_ok(&parse_url(u).unwrap(), &ex, false);
        for u in ["https://download.kiwix.org/zim/x.zim", "https://example.com/x.zim", "https://8.8.8.8/x", "https://data.cached.info/x"] {
            assert!(ok(u), "{u}");
        }
        for u in ["https://192.168.1.240/x.zim", "https://10.0.0.5/x", "https://127.0.0.1/x", "http://localhost:8080/x", "https://169.254.169.254/latest/meta-data", "https://100.64.0.4/x", "https://2130706433/x", "https://nas.local/x"] {
            assert!(!ok(u), "{u}");
        }
        assert!(address_ok(&parse_url("http://127.0.0.1:1/x").unwrap(), &[], true));
    }

    #[test]
    fn the_resolver_refuses_a_name_that_resolves_to_this_machine() {
        use ureq::Resolver;
        let refused = Arc::new(AtomicBool::new(false));
        let r = PublicResolver { refused: refused.clone(), exempt: vec![] };
        assert!(r.resolve("localhost:80").is_err());
        assert!(refused.load(Ordering::Relaxed));
        // an address in any spelling the system accepts
        for n in ["127.0.0.1:80", "[::1]:80", "10.0.0.1:443", "169.254.169.254:80"] {
            assert!(r.resolve(n).is_err(), "{n}");
        }
        // the catalog hosts are the one exception: a name on the exempt list is not checked
        assert!(PublicResolver { refused: Arc::new(AtomicBool::new(false)), exempt: vec!["localhost".into()] }.resolve("localhost:80").is_ok());
        assert!(PublicResolver { refused: Arc::new(AtomicBool::new(false)), exempt: vec![] }.resolve("8.8.8.8:443").is_ok());
    }
}
