//! Android arm64 link check: cache_offroad (with the shim loader) and a direct link against libvalhalla_shim.so,
//! the way the app's native library would reference it.
use std::ffi::{c_char, c_void};
#[link(name = "valhalla_shim")]
extern "C" {
    fn valhalla_shim_init(config: *const c_char) -> *mut c_void;
    fn valhalla_shim_route(h: *mut c_void, req: *const c_char) -> *mut c_char;
    fn valhalla_shim_locate(h: *mut c_void, req: *const c_char) -> *mut c_char;
    fn valhalla_shim_trace_attributes(h: *mut c_void, req: *const c_char) -> *mut c_char;
    fn valhalla_shim_last_error_code(h: *mut c_void) -> i32;
}

#[no_mangle]
pub extern "C" fn offroad_android_check(cfg: *const c_char) -> i32 {
    unsafe {
        let h = valhalla_shim_init(cfg);
        let a = valhalla_shim_route(h, cfg);
        let b = valhalla_shim_locate(h, cfg);
        let c = valhalla_shim_trace_attributes(h, cfg);
        let _ = cache_offroad::router::auto_bbox((0.0, 0.0), (1.0, 1.0), 0.02, 2.0);
        (a.is_null() as i32) + (b.is_null() as i32) + (c.is_null() as i32) + valhalla_shim_last_error_code(h)
    }
}
