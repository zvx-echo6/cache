//! The C ABI (see `include/cache_search.h`). Every function catches panics; nothing unwinds across
//! the boundary. A NULL input is an error (`bad_json`), never a crash.
//!
//! Errors with no handle to hold them (a failed `cs_open`, a NULL handle) are kept per thread and
//! returned by `cs_last_error(NULL)`.

use crate::conv::Conversation;
use crate::error::{Error, Result};
use crate::handle::Handle;
use crate::job::Job;
use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

thread_local! {
    static THREAD_ERROR: RefCell<Option<Error>> = const { RefCell::new(None) };
}

fn set_thread_error(e: Error) {
    // try_with: never panic during thread teardown
    let _ = THREAD_ERROR.try_with(|c| *c.borrow_mut() = Some(e));
}

fn panic_error(p: Box<dyn std::any::Any + Send>) -> Error {
    let msg = p
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| p.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "panic".to_string());
    Error::internal(format!("panic: {msg}"))
}

/// Run `f`, turning a panic into an `internal` error.
fn guarded<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(p) => Err(panic_error(p)),
    }
}

/// Run `f` against a handle. On error the error is stored on the handle (or on the thread when the
/// handle is NULL) and `fail` is returned. A call clears the handle's previous error first.
fn with_handle<T>(h: *mut Handle, fail: T, f: impl FnOnce(&mut Handle) -> Result<T>) -> T {
    if h.is_null() {
        set_thread_error(Error::bad_json("null handle"));
        return fail;
    }
    // SAFETY: the caller promises `h` came from cs_open and is not used concurrently.
    let hr: &mut Handle = unsafe { &mut *h };
    hr.last_error = None;
    match guarded(|| f(hr)) {
        Ok(v) => v,
        Err(e) => {
            hr.last_error = Some(e);
            fail
        }
    }
}

fn arg_str<'a>(p: *const c_char, what: &str) -> Result<&'a str> {
    if p.is_null() {
        return Err(Error::bad_json(format!("{what} is null")));
    }
    // SAFETY: non-null, caller promises NUL-terminated.
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| Error::bad_json(format!("{what} is not valid UTF-8")))
}

fn out_string(s: String) -> Result<*mut c_char> {
    CString::new(s)
        .map(CString::into_raw)
        .map_err(|_| Error::internal("string contains NUL"))
}

#[no_mangle]
pub extern "C" fn cs_version() -> *mut c_char {
    let r = guarded(|| {
        out_string(
            serde_json::json!({
                "version": env!("CARGO_PKG_VERSION"), "index_format": crate::index::INDEX_FORMAT
            })
            .to_string(),
        )
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

/// # Safety
/// `config_json` must be NULL or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn cs_open(config_json: *const c_char) -> *mut Handle {
    let r = guarded(|| {
        let s = arg_str(config_json, "config_json")?;
        Handle::open(s)
    });
    match r {
        Ok(h) => Box::into_raw(Box::new(h)),
        Err(e) => {
            set_thread_error(e);
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `h` must be NULL or a live handle; `config_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_set_sources(h: *mut Handle, config_json: *const c_char) -> i32 {
    with_handle(h, -1, |h| {
        let s = arg_str(config_json, "config_json")?;
        h.set_sources(s)?;
        Ok(0)
    })
}

/// # Safety
/// `h` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn cs_status(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.status_json()))
}

/// Last error on the handle, or (for a NULL handle) the last handle-less error on this thread.
/// Returns NULL when there is none.
///
/// # Safety
/// `h` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn cs_last_error(h: *mut Handle) -> *mut c_char {
    let r = guarded(|| {
        let e = if h.is_null() {
            THREAD_ERROR.try_with(|c| c.borrow().clone()).ok().flatten()
        } else {
            (*h).last_error.clone()
        };
        match e {
            Some(e) => out_string(e.to_json()),
            None => Ok(ptr::null_mut()),
        }
    });
    r.unwrap_or(ptr::null_mut())
}

/// # Safety
/// `h` must be NULL or a handle from `cs_open` not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn cs_close(h: *mut Handle) {
    if h.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(h))));
}

/// # Safety
/// `h` NULL or live; `address` NULL or NUL-terminated; `mime_out` and `len_out` NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn cs_zim_get(
    h: *mut Handle,
    address: *const c_char,
    mime_out: *mut *mut c_char,
    len_out: *mut i64,
) -> *mut u8 {
    if !mime_out.is_null() {
        *mime_out = ptr::null_mut();
    }
    if !len_out.is_null() {
        *len_out = -1;
    }
    with_handle(h, ptr::null_mut(), |h| {
        if mime_out.is_null() || len_out.is_null() {
            return Err(Error::bad_json("mime_out or len_out is null"));
        }
        let addr = arg_str(address, "address")?;
        let e = h.zim_get(addr)?;
        let mime = out_string(e.mime)?;
        let len = e.bytes.len() as i64;
        let p = Box::into_raw(e.bytes.into_boxed_slice()) as *mut u8;
        *mime_out = mime;
        *len_out = len;
        Ok(p)
    })
}

/// # Safety
/// `h` NULL or live; `zim_id` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_zim_main_page(h: *mut Handle, zim_id: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| {
        let id = arg_str(zim_id, "zim_id")?;
        out_string(h.zim_main_page(id)?)
    })
}

/// # Safety
/// `h` NULL or live; `query` NULL or NUL-terminated; `options_json` NULL (defaults) or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_search(h: *mut Handle, query: *const c_char, options_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| {
        let q = arg_str(query, "query")?;
        let o = if options_json.is_null() { None } else { Some(arg_str(options_json, "options_json")?) };
        out_string(h.search(q, o)?)
    })
}

/// # Safety
/// `h` NULL or live; `address` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_read(h: *mut Handle, address: *const c_char, max_chars: i32) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| {
        let a = arg_str(address, "address")?;
        out_string(h.read(a, max_chars)?)
    })
}

/// Start a job. NULL on error (`cs_last_error(NULL)`): `bad_json`, `not_found`/`io` for an unreadable ZIM,
/// `busy` if another job is building that `index_dir` (or, for `update_library`, is using that library),
/// `unsupported` for kind `index_pack`. An `update_library` job finds the library through the process-wide
/// registry in `libreg` (no handle argument).
///
/// # Safety
/// `kind` and `params_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_job_start(kind: *const c_char, params_json: *const c_char) -> *mut Job {
    let r = guarded(|| {
        let k = arg_str(kind, "kind")?;
        let p = arg_str(params_json, "params_json")?;
        Job::start(k, p)
    });
    match r {
        Ok(j) => Box::into_raw(Box::new(j)),
        Err(e) => {
            set_thread_error(e);
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `j` NULL or a live job.
#[no_mangle]
pub unsafe extern "C" fn cs_job_progress(j: *mut Job) -> *mut c_char {
    let r = guarded(|| {
        if j.is_null() {
            return Err(Error::bad_json("null job"));
        }
        out_string((*j).progress_json())
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

/// # Safety
/// `j` NULL or a live job.
#[no_mangle]
pub unsafe extern "C" fn cs_job_cancel(j: *mut Job) -> i32 {
    let r = guarded(|| {
        if j.is_null() {
            return Err(Error::bad_json("null job"));
        }
        (*j).cancel();
        Ok(0)
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        -1
    })
}

/// Free a job. A job still running is cancelled and waited for (until its next checkpoint).
///
/// # Safety
/// `j` NULL or a job from `cs_job_start` not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn cs_job_free(j: *mut Job) {
    if j.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(j))));
}

/// Title suggestions for the address bar. NULL `options_json` means defaults.
///
/// # Safety
/// `h` NULL or live; `prefix` NULL or NUL-terminated; `options_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_suggest(h: *mut Handle, prefix: *const c_char, options_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| {
        let p = arg_str(prefix, "prefix")?;
        let o = if options_json.is_null() { None } else { Some(arg_str(options_json, "options_json")?) };
        out_string(h.suggest(p, o)?)
    })
}

#[no_mangle]
pub extern "C" fn cs_conversation_new() -> *mut Conversation {
    let r = guarded(|| Ok(Box::into_raw(Box::new(Conversation::new()))));
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

/// NULL on error; the error is in `cs_last_error(NULL)`.
///
/// # Safety
/// `c` NULL or a live conversation; `results_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_format(c: *mut Conversation, results_json: *const c_char) -> *mut c_char {
    let r = guarded(|| {
        if c.is_null() {
            return Err(Error::bad_json("null conversation"));
        }
        let s = arg_str(results_json, "results_json")?;
        out_string((*c).format(s)?)
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

/// # Safety
/// `c` NULL or a live conversation.
#[no_mangle]
pub unsafe extern "C" fn cs_conversation_ids(c: *mut Conversation) -> *mut c_char {
    let r = guarded(|| {
        if c.is_null() {
            return Err(Error::bad_json("null conversation"));
        }
        out_string((*c).ids_json())
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

/// The conversation's whole state as versioned JSON (see `Conversation::export_json`). NULL on error; the error is in
/// `cs_last_error(NULL)`.
///
/// # Safety
/// `c` NULL or a live conversation.
#[no_mangle]
pub unsafe extern "C" fn cs_conversation_export(c: *mut Conversation) -> *mut c_char {
    let r = guarded(|| {
        if c.is_null() {
            return Err(Error::bad_json("null conversation"));
        }
        out_string((*c).export_json())
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

/// A new conversation from `cs_conversation_export`'s output. NULL on error (`bad_json` for malformed JSON or an
/// inconsistent export, `unsupported` for a `format` this core does not read); the error is in `cs_last_error(NULL)`.
///
/// # Safety
/// `json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_conversation_import(json: *const c_char) -> *mut Conversation {
    let r = guarded(|| {
        let s = arg_str(json, "json")?;
        Ok(Box::into_raw(Box::new(Conversation::import_json(s)?)))
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

/// # Safety
/// `c` NULL or a conversation from `cs_conversation_new` not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn cs_conversation_free(c: *mut Conversation) {
    if c.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(c))));
}

/// # Safety
/// `h` NULL or live; `fixed_at` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_set_location(h: *mut Handle, lat: f64, lon: f64, accuracy_m: f64, fixed_at: *const c_char) -> i32 {
    with_handle(h, -1, |h| {
        let at = arg_str(fixed_at, "fixed_at")?;
        h.set_location(lat, lon, accuracy_m, at)?;
        Ok(0)
    })
}

/// # Safety
/// `h` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn cs_clear_location(h: *mut Handle) -> i32 {
    with_handle(h, -1, |h| {
        h.clear_location();
        Ok(0)
    })
}

/// Web search settings; the key is kept in memory only.
///
/// # Safety
/// `h` NULL or live; `provider` and `key` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_set_web(h: *mut Handle, provider: *const c_char, key: *const c_char, online: i32) -> i32 {
    with_handle(h, -1, |h| {
        let opt = |p: *const c_char, what: &str| if p.is_null() { Ok(None) } else { arg_str(p, what).map(Some) };
        let (provider, key) = (opt(provider, "provider")?, opt(key, "key")?);
        if online != 0 && online != 1 {
            return Err(Error::bad_json("online must be 0 or 1"));
        }
        h.web.configure_named(provider, key, online == 1)?;
        Ok(0)
    })
}

/// # Safety
/// `h` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn cs_tool_schemas(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.tool_schemas_json()))
}

/// A bad call is the tool's content, not an error: only a NULL handle or conversation, a NULL or malformed
/// argument, or an empty `now` returns NULL.
///
/// # Safety
/// `h` NULL or live; `c` NULL or a live conversation; `name`, `args_json` and `now` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_tool(
    h: *mut Handle,
    c: *mut Conversation,
    name: *const c_char,
    args_json: *const c_char,
    now: *const c_char,
) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| {
        if c.is_null() {
            return Err(Error::bad_json("null conversation"));
        }
        let name = arg_str(name, "name")?;
        let args = arg_str(args_json, "args_json")?;
        let now = arg_str(now, "now")?;
        out_string(h.call_tool(&mut *c, name, args, now)?)
    })
}

// ---- saved places and live data (logic in cache_user / cache_live; see ext.rs) ----

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_places_list(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.places_list()?))
}

/// # Safety
/// `h` NULL or live; `place_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_place_save(h: *mut Handle, place_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.place_save(arg_str(place_json, "place_json")?)?))
}

/// # Safety
/// `h` NULL or live; `key` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_place_delete(h: *mut Handle, key: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.place_delete(arg_str(key, "key")?)?))
}

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_live_sources(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.live_sources()?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_live_fetch(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.live_fetch(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_live_get(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.live_get(arg_str(request_json, "request_json")?)?))
}

/// Live fetch policy: the host's grant for network fetches, pushed as
/// `{"online":bool,"allow_metered":bool,"metered":bool,"enabled_sources":[ids]}`. NULL clears it.
///
/// # Safety
/// `h` NULL or live; `policy_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_live_set_fetch_policy(h: *mut Handle, policy_json: *const c_char) -> i32 {
    with_handle(h, -1, |h| {
        let json = if policy_json.is_null() { None } else { Some(arg_str(policy_json, "policy_json")?) };
        h.set_fetch_policy(json)?;
        Ok(0)
    })
}

/// A source's API key; kept in memory only. NULL `key_or_null` clears it.
///
/// # Safety
/// `h` NULL or live; `source_id` NULL or NUL-terminated; `key_or_null` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_live_set_key(h: *mut Handle, source_id: *const c_char, key_or_null: *const c_char) -> i32 {
    with_handle(h, -1, |h| {
        let source = arg_str(source_id, "source_id")?;
        let key = if key_or_null.is_null() { None } else { Some(arg_str(key_or_null, "key")?) };
        h.set_live_key(source, key);
        Ok(0)
    })
}

/// `cs_live_preview`: no handle (nothing is opened or stored).
///
/// # Safety
/// `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_live_preview(request_json: *const c_char) -> *mut c_char {
    let r = guarded(|| {
        let s = arg_str(request_json, "request_json")?;
        let out = cache_live::preview::preview(s).map_err(|e| Error::new(crate::error::ErrorCode::from_str_code(e.code), e.message))?;
        out_string(out)
    });
    r.unwrap_or_else(|e| {
        set_thread_error(e);
        ptr::null_mut()
    })
}

// ---- the map: search, route, guidance (logic in cache_places::map and cache_navigate::map; see ext.rs) ----

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_map_search(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.map_search(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_map_route(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.map_route(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_map_progress(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.map_progress(arg_str(request_json, "request_json")?)?))
}

// ---- videos (logic in cache_video; see ext.rs) ----

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_video_instances(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_instances()?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_instance_add(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_instance_add(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_instance_remove(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_instance_remove(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_login(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_login(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_refresh(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_refresh(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_me(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_me(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_channels(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_channels(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_list(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_list(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_search(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_search(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_get(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_get(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_video_downloads(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_downloads()?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_delete(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_delete(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_resolve(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.video_resolve(arg_str(request_json, "request_json")?)?))
}

// ---- map layers (logic in cache_layers; see ext.rs and DESIGN-LAYERS.md) ----

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_list(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.layers_list()?))
}

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_refresh(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.layers_refresh()?))
}

/// # Safety
/// `h` NULL or live; `def_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_save(h: *mut Handle, def_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.layers_save(arg_str(def_json, "def_json")?)?))
}

/// # Safety
/// `h` NULL or live; `id` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_remove(h: *mut Handle, id: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.layers_remove(arg_str(id, "id")?)?))
}

/// # Safety
/// `h` NULL or live; `options_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_server(h: *mut Handle, options_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| {
        let o = if options_json.is_null() { None } else { Some(arg_str(options_json, "options_json")?) };
        out_string(h.ext.layers_server(o)?)
    })
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_plan(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.layers_plan(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_delete(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(h.ext.layers_delete(arg_str(request_json, "request_json")?)?))
}

/// # Safety
/// `h` NULL or live; `layer` NULL (all layers) or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_clear_cache(h: *mut Handle, layer: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| {
        let l = if layer.is_null() { None } else { Some(arg_str(layer, "layer")?) };
        out_string(h.ext.layers_clear_cache(l)?)
    })
}

/// One tile through the tile server's own path. An empty tile gives a non-NULL pointer with length 0 and an empty MIME.
///
/// # Safety
/// `h` NULL or live; `layer` NULL or NUL-terminated; `mime_out` and `len_out` NULL or writable.
#[no_mangle]
pub unsafe extern "C" fn cs_layers_tile(h: *mut Handle, layer: *const c_char, z: i32, x: i32, y: i32, mime_out: *mut *mut c_char, len_out: *mut i64) -> *mut u8 {
    if !mime_out.is_null() {
        *mime_out = ptr::null_mut();
    }
    if !len_out.is_null() {
        *len_out = -1;
    }
    with_handle(h, ptr::null_mut(), |h| {
        if mime_out.is_null() || len_out.is_null() {
            return Err(Error::bad_json("mime_out or len_out is null"));
        }
        if !(0..=24).contains(&z) || x < 0 || y < 0 {
            return Err(Error::bad_json("z, x and y are out of range"));
        }
        let (bytes, mime) = match h.ext.layers_tile(arg_str(layer, "layer")?, z as u8, x as u32, y as u32)? {
            Some((b, m)) => (b, m),
            None => (Vec::new(), ""),
        };
        let mime = out_string(mime.to_string())?;
        *len_out = bytes.len() as i64;
        *mime_out = mime;
        Ok(Box::into_raw(bytes.into_boxed_slice()) as *mut u8)
    })
}

/// Sharing and sync (cache_sync): `config_json` is its `Config` (`{"dir": ..., "name": ...}`). NULL on failure, with the reason in
/// `cs_last_error(NULL)`. The engine runs on its own threads until `cs_sync_close`; it is independent of any search handle.
///
/// # Safety
/// `config_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_sync_open(config_json: *const c_char) -> *mut cache_sync::SyncEngine {
    match guarded(|| {
        let cfg: cache_sync::Config = serde_json::from_str(arg_str(config_json, "config_json")?).map_err(|e| Error::bad_json(format!("sync config: {e}")))?;
        cache_sync::SyncEngine::open(cfg).map_err(|e| Error::internal(format!("{e:#}")))
    }) {
        Ok(e) => Box::into_raw(Box::new(e)),
        Err(e) => {
            set_thread_error(e);
            ptr::null_mut()
        }
    }
}

/// One sync method (status, link_code, link, share_add, share_join, ...) with JSON args. Always a JSON string: the answer, or
/// `{"error": "..."}`. Safe to call from several threads at once.
///
/// # Safety
/// `s` NULL or from `cs_sync_open` and not closed; `method` and `args_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_sync_call(s: *mut cache_sync::SyncEngine, method: *const c_char, args_json: *const c_char) -> *mut c_char {
    let out = guarded(|| {
        if s.is_null() {
            return Err(Error::bad_json("null sync handle"));
        }
        let m = arg_str(method, "method")?;
        let args: serde_json::Value = if args_json.is_null() {
            serde_json::json!({})
        } else {
            serde_json::from_str(arg_str(args_json, "args_json")?).map_err(|e| Error::bad_json(format!("args: {e}")))?
        };
        // SAFETY: caller promises a live engine; its methods take &self and lock internally.
        let e = unsafe { &*s };
        Ok(match e.call(m, &args) {
            Ok(v) => v,
            Err(err) => serde_json::json!({"error": format!("{err:#}")}),
        })
    });
    let v = out.unwrap_or_else(|e| serde_json::json!({"error": e.message}));
    out_string(v.to_string()).unwrap_or(ptr::null_mut())
}

/// Stops the engine and frees it.
///
/// # Safety
/// `s` NULL or from `cs_sync_open`, not used again after this call.
#[no_mangle]
pub unsafe extern "C" fn cs_sync_close(s: *mut cache_sync::SyncEngine) {
    if s.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| Box::from_raw(s).close()));
}

/// # Safety
/// `s` must be NULL or a string returned by this library, not freed before.
#[no_mangle]
pub unsafe extern "C" fn cs_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(s))));
}

/// # Safety
/// `p`/`len` must be a buffer and length returned by `cs_zim_get`, not freed before.
#[no_mangle]
pub unsafe extern "C" fn cs_free_bytes(p: *mut u8, len: i64) {
    if p.is_null() || len < 0 {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(ptr::slice_from_raw_parts_mut(p, len as usize)))
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn take(p: *mut c_char) -> Option<String> {
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
        unsafe { cs_free_string(p) };
        Some(s)
    }

    #[test]
    fn version_json() {
        let v: serde_json::Value = serde_json::from_str(&take(cs_version()).unwrap()).unwrap();
        assert_eq!(v["version"], "0.1.0");
        assert_eq!(v["index_format"], 3);
        assert_eq!(v.as_object().unwrap().len(), 2, "only what the header documents: {v}");
    }

    #[test]
    fn null_inputs_do_not_crash() {
        unsafe {
            assert!(cs_open(ptr::null()).is_null());
            let e: serde_json::Value = serde_json::from_str(&take(cs_last_error(ptr::null_mut())).unwrap()).unwrap();
            assert_eq!(e["code"], "bad_json");
            assert!(cs_status(ptr::null_mut()).is_null());
            assert_eq!(cs_set_sources(ptr::null_mut(), ptr::null()), -1);
            assert!(cs_zim_main_page(ptr::null_mut(), ptr::null()).is_null());
            let (mut m, mut n): (*mut c_char, i64) = (ptr::null_mut(), 0);
            assert!(cs_zim_get(ptr::null_mut(), ptr::null(), &mut m, &mut n).is_null());
            assert_eq!(cs_set_location(ptr::null_mut(), 1.0, 2.0, 3.0, ptr::null()), -1);
            assert_eq!(cs_clear_location(ptr::null_mut()), -1);
            assert_eq!(cs_set_web(ptr::null_mut(), ptr::null(), ptr::null(), 0), -1);
            assert!(cs_tool_schemas(ptr::null_mut()).is_null());
            assert!(cs_tool(ptr::null_mut(), ptr::null_mut(), ptr::null(), ptr::null(), ptr::null()).is_null());
            assert!(cs_places_list(ptr::null_mut()).is_null());
            assert!(cs_place_save(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_place_delete(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_live_sources(ptr::null_mut()).is_null());
            assert!(cs_live_fetch(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_live_get(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_live_preview(ptr::null()).is_null());
            assert_eq!(cs_live_set_fetch_policy(ptr::null_mut(), ptr::null()), -1);
            assert_eq!(cs_live_set_key(ptr::null_mut(), ptr::null(), ptr::null()), -1);
            assert!(cs_video_instances(ptr::null_mut()).is_null());
            assert!(cs_video_instance_add(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_instance_remove(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_login(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_refresh(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_me(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_channels(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_list(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_search(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_get(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_downloads(ptr::null_mut()).is_null());
            assert!(cs_video_delete(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_video_resolve(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_layers_list(ptr::null_mut()).is_null());
            assert!(cs_layers_server(ptr::null_mut(), ptr::null()).is_null());
            assert!(cs_layers_plan(ptr::null_mut(), ptr::null()).is_null());
            cs_close(ptr::null_mut());
            cs_free_string(ptr::null_mut());
            cs_free_bytes(ptr::null_mut(), 0);
        }
    }

    #[test]
    fn handle_errors_are_reported_per_handle() {
        unsafe {
            let cfg = CString::new(r#"{"sources":[]}"#).unwrap();
            let h = cs_open(cfg.as_ptr());
            assert!(!h.is_null());
            assert!(cs_last_error(h).is_null());
            let (mut m, mut n): (*mut c_char, i64) = (ptr::null_mut(), 0);
            let a = CString::new("not an address").unwrap();
            assert!(cs_zim_get(h, a.as_ptr(), &mut m, &mut n).is_null());
            assert!(m.is_null());
            let e: serde_json::Value = serde_json::from_str(&take(cs_last_error(h)).unwrap()).unwrap();
            assert_eq!(e["code"], "bad_json");
            // a successful call clears the error
            take(cs_status(h)).unwrap();
            assert!(cs_last_error(h).is_null());
            cs_close(h);
        }
    }

    #[test]
    fn panic_becomes_internal_error() {
        let r: Result<i32> = guarded(|| panic!("boom"));
        let e = r.unwrap_err();
        assert_eq!(e.code, crate::ErrorCode::Internal);
        assert!(e.message.contains("boom"));
    }

    #[test]
    fn free_bytes_roundtrip() {
        let b: Box<[u8]> = vec![1u8, 2, 3].into_boxed_slice();
        let p = Box::into_raw(b) as *mut u8;
        unsafe { cs_free_bytes(p, 3) };
        let e: Box<[u8]> = Vec::new().into_boxed_slice();
        let p = Box::into_raw(e) as *mut u8;
        unsafe { cs_free_bytes(p, 0) };
    }
}
