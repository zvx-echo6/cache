//! The C ABI (see `include/cache_search.h`). Every function catches panics; nothing unwinds across
//! the boundary. A NULL input is an error (`bad_json`), never a crash.
//!
//! Errors with no handle to hold them (a failed `cs_open`, a NULL handle) are kept per thread and
//! returned by `cs_last_error(NULL)`.

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
                "version": env!("CARGO_PKG_VERSION"), "pack_format": 1, "index_format": 1
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
/// `busy` if another job is building that `index_dir`, `unsupported` for kind `index_pack`.
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
        assert_eq!(v["pack_format"], 1);
        assert_eq!(v["index_format"], 1);
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
