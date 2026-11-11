//! The chat functions of cache_llama (`cl_load`, `cl_info`, `cl_start`, `cl_next`, `cl_partial`, `cl_finish`, the token counts,
//! `cl_stop`, `cl_free`), loaded at run time from the same `libcache_llama.so` as the embedder. The server uses them to run the
//! model for the browser build of the app (`/api/llm/*`). Every call and buffer size mirrors the app's own session,
//! packages/cache_llama/lib/llama_session_io.dart, so a generation behaves the same here as on the phone.

use libloading::Library;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::Mutex;

/// `n_ctx` when the caller gives none (`LlamaSession.load`'s default).
pub const CHAT_DEFAULT_N_CTX: i32 = 8192;
/// `n_threads` for `cl_load`: 0 lets the native layer choose (llama_session_io.dart passes 0).
pub const CHAT_THREADS: c_int = 0;
const ERR_LEN: usize = 512;
const TOKEN_BUF: usize = 1024;
const JSON_BUF: usize = 4 * 1024 * 1024;

type LoadFn = unsafe extern "C" fn(*const c_char, c_int, c_int, *mut c_char, c_int) -> *mut c_void;
type BufFn = unsafe extern "C" fn(*mut c_void, *mut c_char, c_int) -> c_int;
type StartFn = unsafe extern "C" fn(*mut c_void, *const c_char, *mut c_char, c_int) -> c_int;
type IntFn = unsafe extern "C" fn(*mut c_void) -> c_int;
type VoidFn = unsafe extern "C" fn(*mut c_void);

struct Bufs {
    err: Vec<c_char>,
    tok: Vec<c_char>,
    json: Vec<c_char>,
}

/// One loaded chat model. One generation at a time per model (callers serialise them); only [`ChatModel::stop`] may be called
/// from another thread while one runs.
/// `cl_start` refused: its return code and the native reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartFailure {
    pub code: i32,
    pub message: String,
}

/// `cl_start` returns this when the prompt does not fit the context (the chat is full).
pub const START_CONTEXT_FULL: i32 = -3;

pub struct ChatModel {
    info: BufFn,
    start: StartFn,
    next: BufFn,
    partial: BufFn,
    finish: BufFn,
    prompt_tokens: IntFn,
    generated_tokens: IntFn,
    stop: VoidFn,
    free: VoidFn,
    handle: *mut c_void,
    bufs: Mutex<Bufs>,
    // Keeps the library mapped while the function pointers are used. Declared last: dropped after `Drop::drop` freed the handle.
    _lib: Library,
}

// SAFETY: the handle is not tied to a thread. Generation calls are made one at a time by the caller (and each also takes the
// buffer lock); `cl_stop` is documented thread-safe (an atomic flag).
unsafe impl Send for ChatModel {}
unsafe impl Sync for ChatModel {}

fn text(buf: &[c_char]) -> String {
    // SAFETY: the native side writes a NUL-terminated string into buffers that are zeroed first.
    unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
}

impl ChatModel {
    /// `cl_load(path, n_ctx, 0 threads)`, then `cl_info`. Returns the model and the `cl_info` JSON (`{}` if `cl_info` fails, as
    /// the app does). `Err` carries the native reason.
    pub fn load(lib_path: &str, model_path: &str, n_ctx: i32) -> Result<(ChatModel, String), String> {
        // SAFETY: loading a shared library runs its initialisers; the operator chose the path.
        let lib = unsafe { Library::new(lib_path) }.map_err(|e| format!("loading {lib_path}: {e}"))?;
        macro_rules! sym {
            ($t:ty, $n:literal) => {
                // SAFETY: the signature is that of cache_llama.h.
                *unsafe { lib.get::<$t>(concat!($n, "\0").as_bytes()) }.map_err(|_| format!("{lib_path} has no symbol {}", $n))?
            };
        }
        let load_fn = sym!(LoadFn, "cl_load");
        let info = sym!(BufFn, "cl_info");
        let start = sym!(StartFn, "cl_start");
        let next = sym!(BufFn, "cl_next");
        let partial = sym!(BufFn, "cl_partial");
        let finish = sym!(BufFn, "cl_finish");
        let prompt_tokens = sym!(IntFn, "cl_prompt_tokens");
        let generated_tokens = sym!(IntFn, "cl_generated_tokens");
        let stop = sym!(VoidFn, "cl_stop");
        let free = sym!(VoidFn, "cl_free");
        let cpath = CString::new(model_path).map_err(|_| "the model path contains NUL".to_string())?;
        let mut bufs = Bufs { err: vec![0; ERR_LEN], tok: vec![0; TOKEN_BUF], json: vec![0; JSON_BUF] };
        // SAFETY: cpath and err are valid for the lengths given.
        let handle = unsafe { load_fn(cpath.as_ptr(), n_ctx, CHAT_THREADS, bufs.err.as_mut_ptr(), ERR_LEN as c_int) };
        if handle.is_null() {
            return Err(text(&bufs.err));
        }
        // From here on the handle is owned by `m`, so an early return frees it.
        let m = ChatModel { info, start, next, partial, finish, prompt_tokens, generated_tokens, stop, free, handle, bufs: Mutex::new(bufs), _lib: lib };
        let info_json = m.read(|h, p, n| unsafe { (m.info)(h, p, n) }).unwrap_or_else(|| "{}".to_string());
        Ok((m, info_json))
    }

    /// Run a call that writes JSON into the shared buffer; `None` when it returns a negative length.
    fn read(&self, f: impl FnOnce(*mut c_void, *mut c_char, c_int) -> c_int) -> Option<String> {
        let mut b = self.bufs.lock().unwrap_or_else(|e| e.into_inner());
        b.json[0] = 0;
        let n = f(self.handle, b.json.as_mut_ptr(), JSON_BUF as c_int);
        if n < 0 {
            None
        } else {
            Some(text(&b.json))
        }
    }

    /// `cl_start`: `Ok(())` or the native code and reason.
    pub fn start(&self, request_json: &str) -> Result<(), StartFailure> {
        let req = CString::new(request_json).map_err(|_| StartFailure { code: -1, message: "the request contains NUL".to_string() })?;
        let mut b = self.bufs.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: req and err are valid for the lengths given.
        let rc = unsafe { (self.start)(self.handle, req.as_ptr(), b.err.as_mut_ptr(), ERR_LEN as c_int) };
        if rc != 0 {
            return Err(StartFailure { code: rc as i32, message: text(&b.err) });
        }
        Ok(())
    }

    /// `cl_next`: the byte count of the token (the text itself is not needed), `-1` when finished, `-2` on error.
    pub fn next(&self) -> i32 {
        let mut b = self.bufs.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: tok is valid for TOKEN_BUF bytes.
        unsafe { (self.next)(self.handle, b.tok.as_mut_ptr(), TOKEN_BUF as c_int) }
    }

    /// `cl_partial`: the message parsed so far as JSON, `None` when the call fails.
    pub fn partial(&self) -> Option<String> {
        self.read(|h, p, n| unsafe { (self.partial)(h, p, n) })
    }

    /// `cl_finish`: the final message as JSON, `None` when the call fails.
    pub fn finish(&self) -> Option<String> {
        self.read(|h, p, n| unsafe { (self.finish)(h, p, n) })
    }

    pub fn prompt_tokens(&self) -> i32 {
        unsafe { (self.prompt_tokens)(self.handle) }
    }

    pub fn generated_tokens(&self) -> i32 {
        unsafe { (self.generated_tokens)(self.handle) }
    }

    /// `cl_stop`: ends the running generation early (the next `next` returns -1). Thread-safe.
    pub fn stop(&self) {
        unsafe { (self.stop)(self.handle) }
    }
}

impl Drop for ChatModel {
    fn drop(&mut self) {
        unsafe { (self.free)(self.handle) };
    }
}
