//! HTTP to the routing server: the same client as cache_layers and cache_live (blocking ureq, rustls with compiled-in roots),
//! the app User-Agent, a timeout on every request. Whether a request may be made at all is decided by the caller
//! ([`crate::Inner::may_use_network`]); nothing here runs without that check.

use std::io::Read;
use std::time::Duration;

/// The longest a published file may be (the index of a continent is a few MB, a tile a few MB).
const MAX_BODY: u64 = 256 * 1024 * 1024;

pub fn default_user_agent() -> String {
    format!("Cache/{}", env!("CARGO_PKG_VERSION"))
}

/// Why a GET gave no body.
#[derive(Debug, Clone, PartialEq)]
pub enum Fail {
    /// No answer: no connection, a name that does not resolve, a timeout. Worth trying again later; not the file's fault.
    Net(String),
    /// The server answered with something other than 200.
    Status(u16, String),
}

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Fail::Net(m) | Fail::Status(_, m) => f.write_str(m),
        }
    }
}

pub fn agent(user_agent: &str) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(8)).timeout(Duration::from_secs(60)).user_agent(user_agent).max_idle_connections_per_host(8).build()
}

/// An https address, or http to this machine (the tests' server). Anything else is never fetched.
pub fn url_ok(url: &str) -> bool {
    if url.starts_with("https://") {
        return true;
    }
    if let Some(r) = url.strip_prefix("http://") {
        let host = r.split(['/', '?', '#']).next().unwrap_or("");
        let host = host.rsplit('@').next().unwrap_or("");
        let host = if host.starts_with('[') { host.split(']').next().unwrap_or("").trim_start_matches('[') } else { host.split(':').next().unwrap_or("") };
        return host == "127.0.0.1" || host == "localhost" || host == "::1";
    }
    false
}

/// One GET with `timeout` for the whole request. One attempt: the callers decide what is tried again.
pub fn get(agent: &ureq::Agent, url: &str, timeout: Duration) -> Result<Vec<u8>, Fail> {
    if !url_ok(url) {
        return Err(Fail::Status(0, format!("{url} is not an https address")));
    }
    match agent.get(url).timeout(timeout.max(Duration::from_millis(1))).call() {
        Ok(resp) => {
            let mut body = Vec::new();
            resp.into_reader().take(MAX_BODY).read_to_end(&mut body).map_err(|e| Fail::Net(format!("reading {url}: {e}")))?;
            Ok(body)
        }
        Err(ureq::Error::Status(code, _)) => Err(Fail::Status(code, format!("HTTP {code} from {url}"))),
        Err(ureq::Error::Transport(t)) => Err(Fail::Net(format!("{:?}: {} ({url})", t.kind(), t.message().unwrap_or(&t.to_string())))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_or_this_machine() {
        assert!(url_ok("https://cache.echo6.co/routing/current.json"));
        assert!(url_ok("http://127.0.0.1:8080/current.json"));
        assert!(!url_ok("http://cache.echo6.co/routing/current.json"));
        assert!(!url_ok("file:///etc/passwd"));
    }
}
