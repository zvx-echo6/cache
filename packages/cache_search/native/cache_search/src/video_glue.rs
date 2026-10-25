//! Videos (PeerTube) on a handle: the glue behind `cs_video_*`. The logic lives in the `cache_video` crate; this file
//! maps its errors to the core's stable codes and exports the C ABI functions documented in `include/cache_search.h`.

use crate::error::{Error, ErrorCode, Result};
use crate::ffi::{arg_str, out_string, with_handle};
use crate::handle::Handle;
use std::ffi::c_char;
use std::ptr;

pub fn video_err(e: cache_video::Error) -> Error {
    match e.space {
        Some((needed, available)) => Error::no_space(e.message, needed, available),
        None => Error::new(ErrorCode::from_str_code(e.code), e.message),
    }
}

fn video(h: &Handle) -> Result<&cache_video::Video> {
    h.video.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "videos need \"video\": {\"dir\"} in the cs_open config"))
}

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_video_instances(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.instances_json().map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_instance_add(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.instance_add(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_instance_remove(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.instance_remove(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_login(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.login(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_refresh(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.refresh(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_me(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.me(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_channels(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.channels(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_list(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.list(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_search(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.search(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_get(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.get(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live.
#[no_mangle]
pub unsafe extern "C" fn cs_video_downloads(h: *mut Handle) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.downloads_json().map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_delete(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.delete_download(arg_str(request_json, "request_json")?).map_err(video_err)?))
}

/// # Safety
/// `h` NULL or live; `request_json` NULL or NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn cs_video_resolve(h: *mut Handle, request_json: *const c_char) -> *mut c_char {
    with_handle(h, ptr::null_mut(), |h| out_string(video(h)?.resolve(arg_str(request_json, "request_json")?).map_err(video_err)?))
}
