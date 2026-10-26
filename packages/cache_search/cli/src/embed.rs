//! Query embedding with cache_llama's `cl_embed`, loaded at run time with `libloading`.
//!
//! Why loaded at run time and not linked: the core never links llama.cpp (DESIGN.md), and `cl_embed` lives on
//! another branch (cl-embed). The wrapper therefore opens the built `libcache_llama.so` from a path given on the
//! command line and looks up the five symbols it needs. The app calls the same C functions with the same
//! settings, so a query gets the same vector on the phone and here.

use crate::engine::ApiError;
use libloading::Library;
use sha2::{Digest, Sha256};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::Read;

// ---- Query embedding settings. THESE MUST MATCH THE APP: the app embeds queries with exactly these values
// ---- (bge-m3 Q8_0, context 512, normalised vectors, CLS pooling read from the model's metadata). If the app's
// ---- settings change, change them here in the same commit; otherwise headless runs stop matching the phone.
/// Context length passed to `cl_embed_load` (longer queries are truncated by cl_embed).
pub const EMBED_N_CTX: c_int = 512;
/// `normalize` argument of `cl_embed`: L2-normalise the vector.
pub const EMBED_NORMALIZE: c_int = 1;
/// Pooling the model must report in `cl_embed_info` (it comes from the GGUF metadata, not from this code).
pub const EMBED_POOLING: &str = "cls";
/// Default thread count (`--embed-threads`); not part of the result.
pub const EMBED_DEFAULT_THREADS: c_int = 4;
/// The decided phone model, for reference and for tests: file name and sha256 of the GGUF.
pub const DECIDED_MODEL_FILE: &str = "bge-m3-Q8_0.gguf";
pub const DECIDED_MODEL_SHA256: &str = "c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb";

type LoadFn = unsafe extern "C" fn(*const c_char, c_int, c_int, *mut c_char, c_int) -> *mut c_void;
type InfoFn = unsafe extern "C" fn(*mut c_void, *mut c_char, c_int) -> c_int;
type EmbedFn = unsafe extern "C" fn(*mut c_void, *const c_char, *mut f32, c_int, c_int) -> c_int;
type FreeFn = unsafe extern "C" fn(*mut c_void);

pub struct Embedder {
    /// The model id sent as `query_vector.model` (must equal a library's settings `embedding.model`).
    pub model_id: String,
    pub n_embd: usize,
    embed_fn: EmbedFn,
    free_fn: FreeFn,
    handle: *mut c_void,
    // Keeps the shared library mapped for as long as the function pointers above are used. Declared last so it
    // is dropped after `Drop::drop` has freed the handle.
    _lib: Library,
}

fn err(msg: impl Into<String>) -> ApiError {
    ApiError::new("internal", msg)
}

/// sha256 of a file, lower-case hex.
pub fn sha256_file(path: &str) -> Result<String, ApiError> {
    let mut f = std::fs::File::open(path).map_err(|e| ApiError::new("io", format!("opening {path}: {e}")))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf).map_err(|e| ApiError::new("io", format!("reading {path}: {e}")))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

// SAFETY: the llama context behind `handle` is used from one thread at a time (callers hold it in a Mutex); it is
// not tied to the thread that made it.
unsafe impl Send for Embedder {}

impl Embedder {
    /// Load the model. `model_id` defaults to the GGUF file name. With `expect_sha256` the file is hashed first
    /// and a mismatch is an error.
    pub fn load(
        lib_path: &str,
        model_path: &str,
        model_id: Option<&str>,
        expect_sha256: Option<&str>,
        threads: c_int,
    ) -> Result<Embedder, ApiError> {
        if let Some(want) = expect_sha256 {
            let got = sha256_file(model_path)?;
            if !got.eq_ignore_ascii_case(want.trim()) {
                return Err(err(format!("sha256 of {model_path} is {got}, expected {want}")));
            }
        }
        let model_id = match model_id {
            Some(m) => m.to_string(),
            None => std::path::Path::new(model_path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .ok_or_else(|| err(format!("cannot derive a model id from {model_path}")))?,
        };
        // SAFETY: loading a shared library runs its initialisers; the operator chose the path.
        let lib = unsafe { Library::new(lib_path) }.map_err(|e| err(format!("loading {lib_path}: {e}")))?;
        // SAFETY: the signatures are those of cache_llama.h (cl_embed_load, cl_embed_info, cl_embed, cl_embed_free).
        let (load_fn, info_fn, embed_fn, free_fn) = unsafe {
            let sym = |name: &[u8]| format!("{lib_path} has no symbol {}", String::from_utf8_lossy(name));
            (
                *lib.get::<LoadFn>(b"cl_embed_load\0").map_err(|_| err(sym(b"cl_embed_load")))?,
                *lib.get::<InfoFn>(b"cl_embed_info\0").map_err(|_| err(sym(b"cl_embed_info")))?,
                *lib.get::<EmbedFn>(b"cl_embed\0").map_err(|_| err(sym(b"cl_embed")))?,
                *lib.get::<FreeFn>(b"cl_embed_free\0").map_err(|_| err(sym(b"cl_embed_free")))?,
            )
        };
        let cpath = CString::new(model_path).map_err(|_| err("model path contains NUL"))?;
        let mut ebuf = vec![0 as c_char; 512];
        let handle = unsafe { load_fn(cpath.as_ptr(), EMBED_N_CTX, threads, ebuf.as_mut_ptr(), ebuf.len() as c_int) };
        if handle.is_null() {
            let msg = unsafe { CStr::from_ptr(ebuf.as_ptr()) }.to_string_lossy().into_owned();
            return Err(err(format!("cl_embed_load failed: {msg}")));
        }
        // From here on the handle is owned by `e`, so an early return frees it.
        let mut e = Embedder { model_id, n_embd: 0, embed_fn, free_fn, handle, _lib: lib };
        let mut ibuf = vec![0 as c_char; 2048];
        let n = unsafe { info_fn(handle, ibuf.as_mut_ptr(), ibuf.len() as c_int) };
        if n < 0 {
            return Err(err("cl_embed_info failed"));
        }
        let info = unsafe { CStr::from_ptr(ibuf.as_ptr()) }.to_string_lossy().into_owned();
        let v: serde_json::Value = serde_json::from_str(&info).map_err(|_| err(format!("cl_embed_info returned {info:?}")))?;
        let pooling = v["pooling"].as_str().unwrap_or("");
        if pooling != EMBED_POOLING {
            return Err(err(format!("model reports pooling {pooling:?}, the app uses {EMBED_POOLING:?}: not the app's model")));
        }
        if v["n_ctx"].as_i64() != Some(EMBED_N_CTX as i64) {
            return Err(err(format!("model context is {}, the app uses {EMBED_N_CTX}", v["n_ctx"])));
        }
        e.n_embd = v["n_embd"].as_u64().filter(|n| *n > 0).ok_or_else(|| err("cl_embed_info has no n_embd"))? as usize;
        Ok(e)
    }

    /// Embed exactly the text given (no prefix), normalised.
    pub fn embed(&self, text: &str) -> Result<Vec<f32>, ApiError> {
        let ctext = CString::new(text).map_err(|_| ApiError::new("bad_json", "query contains NUL"))?;
        let mut out = vec![0f32; self.n_embd];
        let n = unsafe { (self.embed_fn)(self.handle, ctext.as_ptr(), out.as_mut_ptr(), out.len() as c_int, EMBED_NORMALIZE) };
        match n {
            n if n == self.n_embd as c_int => Ok(out),
            -3 => Err(ApiError::new("bad_json", "nothing to embed in the query")),
            n => Err(err(format!("cl_embed failed with {n}"))),
        }
    }
}

impl Drop for Embedder {
    fn drop(&mut self) {
        unsafe { (self.free_fn)(self.handle) };
    }
}
