//! The tile route: `GET /api/tiles/layers/<id>/<z>/<x>/<y>[.ext]` and `GET /api/tiles/layers/<id>/tilejson.json`.
//!
//! The core's layer engine runs a tile server inside the helper process, bound to 127.0.0.1 on a random port (cache_layers
//! `server.rs`). The map in the browser cannot reach that port, so this route forwards the request to it and returns the answer
//! unchanged: status (200, 204, 503 with `Retry-After`, ...), body, `Content-Type`, `X-Cache-Status`, `Retry-After`.
//!
//! Sign-in: the route sits under `/api/`, so it takes the same session cookie as every other call (checked in `http::route`
//! before this code runs). MapLibre fetches tiles with same-origin requests, which carry the cookie, so no extra token is
//! needed (the `/zim/` route has one only because its frame is sandboxed and has no origin).
//!
//! Where the port comes from: the helper's own `layers` op with `server` (the same call the browser makes), which starts the tile
//! server once and says where it is; asking again returns the same port and changes nothing else (no `online` option is sent).
//! The port is kept in the [`Helper`] and asked for again once if a connection to it fails (after a helper restart).
//!
//! Only `layers/...` is forwarded, and only the characters of a layer id and a tile path (letters, digits, `.`, `_`, `-`, `/`), so
//! nothing else on the tile server, and no other address, can be reached through here. The query string is dropped (the tile
//! server ignores it).

use crate::helper::Helper;
use crate::http::Reply;
use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

/// The largest answer taken from the tile server, in bytes.
const MAX_TILE_BYTES: u64 = 32 << 20;

/// The tile server's path for `rest` (what follows `/api/tiles/`), or None when it is not a layers path of the safe shape.
pub fn upstream_path(rest: &str) -> Option<String> {
    if rest.len() > 256 || !rest.starts_with("layers/") {
        return None;
    }
    let ok = rest.split('/').all(|seg| {
        !seg.is_empty() && seg != "." && seg != ".." && seg.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    });
    ok.then(|| format!("/{rest}"))
}

enum Upstream {
    Answer(Reply),
    /// The connection to the tile server failed (nothing is listening there).
    Gone,
}

fn fetch(port: u16, path: &str) -> Upstream {
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(3))
        .timeout_read(Duration::from_secs(60))
        .build();
    let resp = match agent.get(&format!("http://127.0.0.1:{port}{path}")).call() {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r,
        Err(_) => return Upstream::Gone,
    };
    let status = resp.status();
    let mut headers: Vec<(&'static str, String)> = Vec::new();
    for (name, key) in [("content-type", "Content-Type"), ("x-cache-status", "X-Cache-Status"), ("retry-after", "Retry-After")] {
        if let Some(v) = resp.header(name) {
            headers.push((key, v.to_string()));
        }
    }
    let mut body = Vec::new();
    if resp.into_reader().take(MAX_TILE_BYTES).read_to_end(&mut body).is_err() {
        return Upstream::Gone;
    }
    Upstream::Answer(Reply { status, headers, body, stream: None })
}

/// `GET|HEAD /api/tiles/<rest>`; the caller has checked the session.
pub async fn tiles(helper: Option<Arc<Helper>>, method: &str, rest: &str) -> Reply {
    if method != "GET" && method != "HEAD" {
        return Reply::empty(405);
    }
    let Some(path) = upstream_path(rest) else { return Reply::error(404, "not_found", "no such tile address") };
    let Some(helper) = helper else { return Reply::error(503, "core_unavailable", "the core is not available: no helper") };
    for fresh in [false, true] {
        let port = match helper.tile_port(fresh).await {
            Ok(p) => p,
            Err(e) => return Reply::error(503, "core_unavailable", e),
        };
        let p = path.clone();
        match tokio::task::spawn_blocking(move || fetch(port, &p)).await {
            Ok(Upstream::Answer(mut r)) => {
                if method == "HEAD" {
                    r.body.clear();
                }
                return r;
            }
            Ok(Upstream::Gone) => continue,
            Err(_) => return Reply::empty(500),
        }
    }
    Reply::error(502, "tile_server_unreachable", "the tile server did not answer")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_layer_paths_of_the_safe_shape_pass() {
        assert_eq!(upstream_path("layers/base/3/4/5").as_deref(), Some("/layers/base/3/4/5"));
        assert_eq!(upstream_path("layers/base/3/4/5.pbf").as_deref(), Some("/layers/base/3/4/5.pbf"));
        assert_eq!(upstream_path("layers/base/tilejson.json").as_deref(), Some("/layers/base/tilejson.json"));
        for bad in ["", "health", "layers", "layers/", "layers//1", "layers/../x", "layers/a/./b", "layers/a b/1", "layers/a?x=1", "layers/a%2e%2e/1", "other/a/1", "layers/\u{e9}/1", "layers/a\\b"] {
            assert_eq!(upstream_path(bad), None, "{bad:?}");
        }
        assert_eq!(upstream_path(&format!("layers/{}", "a".repeat(300))), None);
    }
}
