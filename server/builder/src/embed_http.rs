//! An embedder that asks a running llama.cpp `llama-server` (started with `--embeddings --pooling cls`, bge-m3 Q8_0) for the
//! vectors, so a build can use a GPU. It is a plain HTTP/1.1 client over `std::net` (the server is local, so no TLS and no
//! HTTP crate). The vectors are normalised here exactly as `cl_embed` does it (the sum of squares in f64, one f32 scale), and
//! a text longer than the model's 512 tokens is cut the way `cl_embed` cuts it (keep the first 511 tokens and the closing
//! special token), so a server vector and a phone vector for the same text agree up to the numeric precision of the device.

use crate::embed::{Embedder, DIMS};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Mutex;
use std::time::Duration;

/// The model's context, as in `cache_embed::EMBED_N_CTX`.
pub const N_CTX: usize = 512;
/// The name recorded in packs: the same as the CPU embedder's model file, so packs from either are one library.
pub const MODEL_NAME: &str = "bge-m3-Q8_0.gguf";

/// L2-normalise as `cl_embed` does: the norm accumulated in f64, the scale rounded to f32, left alone when the norm is 0.
pub fn normalize(v: &mut [f32]) {
    let norm: f64 = v.iter().map(|x| (*x as f64) * (*x as f64)).sum();
    let scale = if norm > 0.0 { (1.0 / norm.sqrt()) as f32 } else { 1.0 };
    for x in v.iter_mut() {
        *x *= scale;
    }
}

/// Cut a token list to `n_ctx` the way `cl_embed` does: keep the closing token when the vocabulary adds one.
pub fn truncate_tokens(mut tokens: Vec<i64>, n_ctx: usize, keep_last: bool) -> Vec<i64> {
    if tokens.len() > n_ctx {
        let last = *tokens.last().unwrap();
        tokens.truncate(n_ctx);
        if keep_last {
            *tokens.last_mut().unwrap() = last;
        }
    }
    tokens
}

/// Split `http://host:port/base` into (`host:port`, `/base` without a trailing slash).
pub fn parse_url(url: &str) -> Result<(String, String), String> {
    let rest = url.strip_prefix("http://").ok_or_else(|| format!("{url:?}: only http:// URLs are supported (the server is local)"))?;
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], rest[i..].trim_end_matches('/').to_string()),
        None => (rest, String::new()),
    };
    if hostport.is_empty() {
        return Err(format!("{url:?}: no host"));
    }
    let hostport = if hostport.contains(':') { hostport.to_string() } else { format!("{hostport}:80") };
    Ok((hostport, path))
}

/// Parse an HTTP/1.1 response (status line, headers, a Content-Length or chunked body) into (status, body).
pub fn parse_response(raw: &[u8]) -> Result<(u16, Vec<u8>), String> {
    let end = raw.windows(4).position(|w| w == b"\r\n\r\n").ok_or("response has no header end")?;
    let head = String::from_utf8_lossy(&raw[..end]).to_string();
    let mut lines = head.split("\r\n");
    let status: u16 = lines.next().and_then(|l| l.split(' ').nth(1)).and_then(|s| s.parse().ok()).ok_or("bad status line")?;
    let chunked = lines.any(|l| l.to_ascii_lowercase().starts_with("transfer-encoding:") && l.to_ascii_lowercase().contains("chunked"));
    let body = &raw[end + 4..];
    if !chunked {
        return Ok((status, body.to_vec()));
    }
    let mut out = Vec::new();
    let mut i = 0;
    loop {
        let nl = body[i..].windows(2).position(|w| w == b"\r\n").ok_or("bad chunk header")?;
        let size = usize::from_str_radix(String::from_utf8_lossy(&body[i..i + nl]).split(';').next().unwrap_or("").trim(), 16).map_err(|_| "bad chunk size")?;
        i += nl + 2;
        if size == 0 {
            break;
        }
        if i + size > body.len() {
            return Err("chunk cut short".into());
        }
        out.extend_from_slice(&body[i..i + size]);
        i += size + 2;
    }
    Ok((status, out))
}

pub struct HttpEmbedder {
    addr: String,
    base: String,
    name: String,
    /// The last failure, for the caller (the trait cannot return one; a failed batch returns no vectors, which the build reports).
    last_error: Mutex<Option<String>>,
}

impl HttpEmbedder {
    pub fn new(url: &str) -> Result<Self, String> {
        let (addr, base) = parse_url(url)?;
        Ok(HttpEmbedder { addr, base, name: MODEL_NAME.to_string(), last_error: Mutex::new(None) })
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().ok().and_then(|g| g.clone())
    }

    fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
        let payload = body.to_string();
        let sa = self.addr.to_socket_addrs().map_err(|e| format!("{}: {e}", self.addr))?.next().ok_or("no address")?;
        let mut s = TcpStream::connect_timeout(&sa, Duration::from_secs(10)).map_err(|e| format!("connecting to {}: {e}", self.addr))?;
        s.set_read_timeout(Some(Duration::from_secs(300))).ok();
        s.set_write_timeout(Some(Duration::from_secs(60))).ok();
        let req = format!(
            "POST {}{} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            self.base,
            path,
            self.addr,
            payload.len()
        );
        s.write_all(req.as_bytes()).and_then(|_| s.write_all(payload.as_bytes())).map_err(|e| format!("sending: {e}"))?;
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).map_err(|e| format!("reading: {e}"))?;
        let (status, body) = parse_response(&raw)?;
        let v: Value = serde_json::from_slice(&body).map_err(|e| format!("bad JSON from the server (status {status}): {e}"))?;
        Ok((status, v))
    }

    /// Vectors for `inputs` (each a string or a token array), in order, normalised.
    fn request(&self, inputs: Vec<Value>) -> Result<Vec<Vec<f32>>, (u16, String)> {
        let n = inputs.len();
        let (status, v) = self.post("/v1/embeddings", &json!({ "input": inputs, "encoding_format": "float" })).map_err(|e| (0, e))?;
        if status != 200 {
            return Err((status, format!("server answered {status}: {v}")));
        }
        let data = v["data"].as_array().ok_or((status, "no data in the answer".to_string()))?;
        if data.len() != n {
            return Err((status, format!("asked for {n} vectors, got {}", data.len())));
        }
        let mut out: Vec<Option<Vec<f32>>> = vec![None; n];
        for (pos, d) in data.iter().enumerate() {
            let idx = d["index"].as_u64().map(|i| i as usize).unwrap_or(pos);
            let emb = d["embedding"].as_array().ok_or((status, "an item has no embedding".to_string()))?;
            let mut vec: Vec<f32> = emb.iter().map(|x| x.as_f64().unwrap_or(f64::NAN) as f32).collect();
            if vec.len() != DIMS || vec.iter().any(|x| !x.is_finite()) {
                return Err((status, format!("a vector has {} values or a non-finite one; expected {DIMS}", vec.len())));
            }
            normalize(&mut vec);
            if idx >= n || out[idx].is_some() {
                return Err((status, "the answer's indexes are wrong".to_string()));
            }
            out[idx] = Some(vec);
        }
        Ok(out.into_iter().map(|o| o.unwrap()).collect())
    }

    /// One text cut to the model's context exactly as cl_embed cuts it (tokenise with the server's own vocabulary, then send tokens).
    fn embed_cut(&self, text: &str) -> Result<Vec<f32>, String> {
        let (st, t) = self.post("/tokenize", &json!({ "content": text, "add_special": true, "parse_special": false })).map_err(|e| e.to_string())?;
        if st != 200 {
            return Err(format!("tokenize answered {st}: {t}"));
        }
        let toks: Vec<i64> = t["tokens"].as_array().ok_or("no tokens")?.iter().filter_map(|x| x.as_i64()).collect();
        if toks.is_empty() {
            return Err("nothing to embed in a text".into());
        }
        // bge-m3 (XLM-R) adds a closing token, so the last one is kept.
        let toks = truncate_tokens(toks, N_CTX, true);
        let mut r = self.request(vec![json!(toks)]).map_err(|e| e.1)?;
        Ok(r.remove(0))
    }

    fn embed_inner(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let mut last = String::new();
        for attempt in 0..3 {
            match self.request(texts.iter().map(|t| json!(t)).collect()) {
                Ok(v) => return Ok(v),
                Err((400, e)) | Err((500, e)) => {
                    // Most likely a text over the context: do the batch one text at a time, cutting where needed.
                    last = e;
                    return texts.iter().map(|t| self.embed_one(t)).collect::<Result<Vec<_>, _>>().map_err(|e2| format!("{last}; then {e2}"));
                }
                Err((_, e)) => {
                    last = e;
                    std::thread::sleep(Duration::from_millis(500 * (attempt + 1)));
                }
            }
        }
        Err(last)
    }

    fn embed_one(&self, text: &str) -> Result<Vec<f32>, String> {
        match self.request(vec![json!(text)]) {
            Ok(mut v) => Ok(v.remove(0)),
            Err((400, _)) | Err((500, _)) => self.embed_cut(text),
            Err((_, e)) => Err(e),
        }
    }
}

impl Embedder for HttpEmbedder {
    fn embed_batch(&self, texts: &[String]) -> Vec<Vec<f32>> {
        match self.embed_inner(texts) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("embedder: {e}");
                if let Ok(mut g) = self.last_error.lock() {
                    *g = Some(e);
                }
                // No vectors: build_pack reports the count mismatch as the failure of this document.
                Vec::new()
            }
        }
    }
    fn name(&self) -> String {
        self.name.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalises_like_cl_embed() {
        let mut v = vec![3.0f32, 4.0];
        normalize(&mut v);
        assert!((v[0] - 0.6).abs() < 1e-7 && (v[1] - 0.8).abs() < 1e-7);
        let mut z = vec![0.0f32; 4];
        normalize(&mut z);
        assert_eq!(z, vec![0.0; 4]);
        let mut u = vec![0.1f32, -0.2, 0.7];
        normalize(&mut u);
        let n: f32 = u.iter().map(|x| x * x).sum();
        assert!((n - 1.0).abs() < 1e-6);
    }

    #[test]
    fn truncation_keeps_the_closing_token() {
        let t: Vec<i64> = (0..600).collect();
        let c = truncate_tokens(t.clone(), 512, true);
        assert_eq!(c.len(), 512);
        assert_eq!(c[510], 510);
        assert_eq!(c[511], 599);
        let c = truncate_tokens(t, 512, false);
        assert_eq!(c[511], 511);
        assert_eq!(truncate_tokens(vec![1, 2, 3], 512, true), vec![1, 2, 3]);
    }

    #[test]
    fn urls_split() {
        assert_eq!(parse_url("http://127.0.0.1:8123").unwrap(), ("127.0.0.1:8123".into(), String::new()));
        assert_eq!(parse_url("http://localhost:9/base/").unwrap(), ("localhost:9".into(), "/base".into()));
        assert_eq!(parse_url("http://host").unwrap().0, "host:80");
        assert!(parse_url("https://x:1").is_err());
    }

    #[test]
    fn responses_parse() {
        let r = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
        assert_eq!(parse_response(r).unwrap(), (200, b"{}".to_vec()));
        let c = b"HTTP/1.1 400 Bad\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n";
        assert_eq!(parse_response(c).unwrap(), (400, b"abcde".to_vec()));
        assert!(parse_response(b"garbage").is_err());
    }

    /// A one-shot fake server: answers each connection with the next canned body.
    fn serve(bodies: Vec<String>) -> String {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        std::thread::spawn(move || {
            for body in bodies {
                let (mut s, _) = l.accept().unwrap();
                // Read the whole request (headers, then Content-Length bytes) so closing does not reset the connection.
                let mut req = Vec::new();
                let mut buf = [0u8; 65536];
                loop {
                    let n = s.read(&mut buf).unwrap_or(0);
                    req.extend_from_slice(&buf[..n]);
                    if n == 0 {
                        break;
                    }
                    if let Some(h) = req.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&req[..h]).to_ascii_lowercase();
                        let len: usize = head.split("content-length:").nth(1).and_then(|r| r.split("\r\n").next()).and_then(|v| v.trim().parse().ok()).unwrap_or(0);
                        if req.len() >= h + 4 + len {
                            break;
                        }
                    }
                }
                let (code, b) = match body.strip_prefix("400:") {
                    Some(b) => (400, b.to_string()),
                    None => (200, body.clone()),
                };
                let _ = write!(s, "HTTP/1.1 {code} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{b}", b.len());
            }
        });
        format!("http://{addr}")
    }

    fn emb_json(vals: &[Vec<f32>]) -> String {
        let data: Vec<Value> = vals.iter().enumerate().map(|(i, v)| json!({"index": i, "embedding": v})).collect();
        json!({ "data": data }).to_string()
    }

    #[test]
    fn embeds_a_batch_and_normalises() {
        let mut a = vec![0.0f32; DIMS];
        a[0] = 3.0;
        a[1] = 4.0;
        let mut b = vec![0.0f32; DIMS];
        b[5] = 2.0;
        let url = serve(vec![emb_json(&[a, b])]);
        let e = HttpEmbedder::new(&url).unwrap();
        let v = e.embed_batch(&["x".to_string(), "y".to_string()]);
        assert_eq!(v.len(), 2);
        assert!((v[0][0] - 0.6).abs() < 1e-6 && (v[0][1] - 0.8).abs() < 1e-6);
        assert!((v[1][5] - 1.0).abs() < 1e-6);
        assert_eq!(e.name(), MODEL_NAME);
    }

    #[test]
    fn a_dead_server_gives_no_vectors_and_an_error() {
        let e = HttpEmbedder::new("http://127.0.0.1:1").unwrap();
        assert!(e.embed_batch(&["x".to_string()]).is_empty());
        assert!(e.last_error().is_some());
    }

    #[test]
    fn wrong_size_vectors_are_refused() {
        let url = serve(vec![emb_json(&[vec![1.0f32; 10]])]);
        let e = HttpEmbedder::new(&url).unwrap();
        assert!(e.embed_batch(&["x".to_string()]).is_empty());
    }

    #[test]
    fn an_oversize_text_is_tokenised_cut_and_resent() {
        let mut ok = vec![0.0f32; DIMS];
        ok[7] = 5.0;
        let toks: Vec<i64> = (0..600).collect();
        let url = serve(vec![
            "400:{\"error\":\"too large\"}".to_string(),
            "400:{\"error\":\"too large\"}".to_string(),
            json!({ "tokens": toks }).to_string(),
            emb_json(&[ok]),
        ]);
        let e = HttpEmbedder::new(&url).unwrap();
        let v = e.embed_batch(&["long".to_string()]);
        assert_eq!(v.len(), 1);
        assert!((v[0][7] - 1.0).abs() < 1e-6);
    }
}
