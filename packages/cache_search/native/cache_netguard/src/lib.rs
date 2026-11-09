//! The public-address guard: one rule for which addresses an outbound HTTP client may connect to.
//!
//! The rule ([`is_public`]) refuses everything that is not on the public internet: private and loopback, link-local (cloud
//! metadata is 169.254.169.254), shared 100.64/10 (Tailscale, carrier NAT), unspecified, multicast, documentation and reserved
//! ranges, and the IPv6 forms that carry an IPv4 address (`::ffff:a.b.c.d`, `::ffff:0:a.b.c.d`, `64:ff9b::/96`, `64:ff9b:1::/48`,
//! 6to4, Teredo). It is applied by [`PublicResolver`], a `ureq` resolver, so it is checked on the addresses a name resolves to
//! at connect time. A redirect is a new connect, so one resolver covers every redirect hop, a name that rebinds between lookups,
//! and every odd spelling of 127.0.0.1 (`0x7f.1`, `2130706433`), because the system turns the spelling into an address first.
//!
//! Two users:
//! * The Linux server: its own `/api/fetch` and download paths use [`PublicResolver`] directly (server/src/fetch_scope.rs), and
//!   it sets [`ENV_VAR`] in the Dart helper's environment, which installs the guard for the core crates there.
//! * The core crates (cache_video, cache_live, cache_layers, cache_regions) build their clients through [`guarded`]. It adds
//!   the guard only when it is installed ([`install`] or the environment variable), so on a phone, which never sets it, the
//!   builder is returned untouched and the client is exactly what it was. The model's web read and web search (cache_search)
//!   use [`always`]: what the model reads is public by definition, on every platform.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

/// The environment variable that installs the guard: `public`. Only the Linux server's helper gets it.
pub const ENV_VAR: &str = "CACHE_NET_GUARD";

/// The value of [`ENV_VAR`] that installs the guard.
pub const ENV_VALUE: &str = "public";

static INSTALLED: AtomicBool = AtomicBool::new(false);
static ENV_ON: OnceLock<bool> = OnceLock::new();

/// Install the guard for this process (the environment variable does the same, read once).
pub fn install() {
    INSTALLED.store(true, Ordering::Relaxed);
}

/// Whether the guard is installed: [`install`] was called, or [`ENV_VAR`] is `public`.
pub fn installed() -> bool {
    INSTALLED.load(Ordering::Relaxed) || *ENV_ON.get_or_init(|| std::env::var(ENV_VAR).map(|v| v == ENV_VALUE).unwrap_or(false))
}

/// `b` with the guard when it is installed; `b` unchanged otherwise (the phone path).
pub fn guarded(b: ureq::AgentBuilder) -> ureq::AgentBuilder {
    if installed() {
        always(b)
    } else {
        b
    }
}

/// `b` with the guard, installed or not.
pub fn always(b: ureq::AgentBuilder) -> ureq::AgentBuilder {
    b.resolver(PublicResolver::new(Arc::new(AtomicBool::new(false)), Vec::new()))
}

thread_local! {
    static LOOPBACK_HERE: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}
static LOOPBACK_ALL: AtomicBool = AtomicBool::new(false);

/// Tests only: while the returned value lives, loopback addresses (127/8, ::1) are reachable from this thread, so a test can
/// stand a local server up and still see everything else (a redirect to a LAN or metadata address) refused.
#[doc(hidden)]
pub fn loopback_here_for_tests() -> LoopbackScope {
    LOOPBACK_HERE.with(|c| c.set(c.get() + 1));
    LoopbackScope(())
}

/// See [`loopback_here_for_tests`].
#[doc(hidden)]
pub struct LoopbackScope(());

impl Drop for LoopbackScope {
    fn drop(&mut self) {
        LOOPBACK_HERE.with(|c| c.set(c.get().saturating_sub(1)));
    }
}

/// Tests only: loopback is reachable from every thread of this process from now on (for a client that works on its own thread).
#[doc(hidden)]
pub fn loopback_everywhere_for_tests() {
    LOOPBACK_ALL.store(true, Ordering::Relaxed);
}

fn loopback_allowed(ip: IpAddr) -> bool {
    ip.is_loopback() && (LOOPBACK_ALL.load(Ordering::Relaxed) || LOOPBACK_HERE.with(|c| c.get()) > 0)
}

/// Looks a name up like the system does and refuses it when any address it gives is not public. It is the connect-time check:
/// the connection can only go to an address that was checked.
#[derive(Debug)]
pub struct PublicResolver {
    /// Set when an address was refused, so the caller can say "not allowed" and not "unreachable".
    pub refused: Arc<AtomicBool>,
    /// Host names that are looked up without the check: the server's catalog hosts.
    pub exempt: Vec<String>,
    /// The owner's allow-list (named hosts or networks, for example a home PeerTube). Reserved: the owner has not decided it, so
    /// nothing fills it and nothing reads it yet.
    pub allow: Vec<String>,
}

impl PublicResolver {
    pub fn new(refused: Arc<AtomicBool>, exempt: Vec<String>) -> PublicResolver {
        PublicResolver { refused, exempt, allow: Vec::new() }
    }
}

impl ureq::Resolver for PublicResolver {
    fn resolve(&self, netloc: &str) -> io::Result<Vec<SocketAddr>> {
        let addrs: Vec<SocketAddr> = netloc.to_socket_addrs()?.collect();
        let host = netloc.rsplit_once(':').map_or(netloc, |(h, _)| h).to_ascii_lowercase();
        if self.exempt.iter().any(|h| h.eq_ignore_ascii_case(&host)) && !addrs.is_empty() {
            return Ok(addrs);
        }
        if addrs.is_empty() || addrs.iter().any(|a| !is_public(a.ip()) && !loopback_allowed(a.ip())) {
            self.refused.store(true, Ordering::Relaxed);
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "that address is not on the public internet"));
        }
        Ok(addrs)
    }
}

/// Whether an address is on the public internet. Everything that is private, loopback, link-local (cloud metadata is 169.254.169.254),
/// shared (100.64/10 is Tailscale and carrier NAT), unspecified, multicast, documentation or reserved is not.
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => is_public_v4(a),
        IpAddr::V6(a) => is_public_v6(a),
    }
}

pub fn is_public_v4(a: Ipv4Addr) -> bool {
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

pub fn is_public_v6(a: Ipv6Addr) -> bool {
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

#[cfg(test)]
mod tests {
    use super::*;
    use ureq::Resolver;

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
    fn the_resolver_refuses_a_name_that_resolves_to_this_machine() {
        let refused = Arc::new(AtomicBool::new(false));
        let r = PublicResolver::new(refused.clone(), vec![]);
        assert!(r.resolve("localhost:80").is_err());
        assert!(refused.load(Ordering::Relaxed));
        // an address in any spelling the system accepts, hex and decimal included
        for n in ["127.0.0.1:80", "[::1]:80", "10.0.0.1:443", "169.254.169.254:80", "192.168.1.240:80", "100.64.0.4:80", "0x7f.1:80", "2130706433:80", "[::ffff:127.0.0.1]:80"] {
            assert!(r.resolve(n).is_err(), "{n}");
        }
        // an exempt name is not checked; a public address passes
        assert!(PublicResolver::new(Arc::new(AtomicBool::new(false)), vec!["localhost".into()]).resolve("localhost:80").is_ok());
        assert!(PublicResolver::new(Arc::new(AtomicBool::new(false)), vec![]).resolve("8.8.8.8:443").is_ok());
    }

    #[test]
    fn the_test_loopback_allowance_opens_loopback_and_nothing_else() {
        let r = PublicResolver::new(Arc::new(AtomicBool::new(false)), vec![]);
        assert!(r.resolve("127.0.0.1:80").is_err());
        {
            let _scope = loopback_here_for_tests();
            assert!(r.resolve("127.0.0.1:80").is_ok());
            for n in ["10.0.0.1:80", "169.254.169.254:80", "192.168.1.240:80", "100.64.0.4:80"] {
                assert!(r.resolve(n).is_err(), "{n}");
            }
        }
        assert!(r.resolve("127.0.0.1:80").is_err());
    }

    #[test]
    fn guarded_adds_the_guard_only_when_installed_and_always_adds_it() {
        // nothing in this test process installs it, and the variable is not set
        assert!(!installed());
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", l.local_addr().unwrap());
        l.set_nonblocking(true).unwrap();
        // not installed: the builder is untouched, so the request reaches the listener (and then fails reading: nobody answers)
        let _ = guarded(ureq::AgentBuilder::new()).timeout(std::time::Duration::from_millis(300)).build().get(&url).call();
        assert!(l.accept().is_ok(), "an unguarded client must reach a local listener");
        // always: refused before any connection
        let e = always(ureq::AgentBuilder::new()).build().get(&url).call().unwrap_err();
        assert!(matches!(e, ureq::Error::Transport(ref t) if t.kind() == ureq::ErrorKind::Dns), "{e}");
        assert!(l.accept().is_err(), "a guarded client must not connect");
    }
}
