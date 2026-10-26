//! [`Valhalla`] on the C shim (packages/valhalla: `valhalla_shim.dll` on Windows, `libvalhalla_shim.so` on
//! Android). The library is loaded at run time (`dlopen`/`LoadLibrary`) so cache_offroad builds and tests
//! without it; enable the `shim` cargo feature.
use crate::valhalla::*;
use libloading::Library;
use serde_json::{json, Value};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;

type InitFn = unsafe extern "C" fn(*const c_char) -> *mut c_void;
type CallFn = unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_char;
type FreeFn = unsafe extern "C" fn(*mut c_char);
type DestroyFn = unsafe extern "C" fn(*mut c_void);
type ErrFn = unsafe extern "C" fn(*mut c_void) -> *const c_char;
type CodeFn = unsafe extern "C" fn(*mut c_void) -> c_int;

pub struct ShimValhalla {
    _lib: Library,
    h: *mut c_void,
    route: CallFn,
    locate: CallFn,
    trace: CallFn,
    free: FreeFn,
    destroy: DestroyFn,
    err: ErrFn,
    code: CodeFn,
}

// The C side serialises calls on a handle with a mutex.
unsafe impl Send for ShimValhalla {}
unsafe impl Sync for ShimValhalla {}

/// Valhalla config for a local `tile_extract` tar (navi's settings, minus the files a phone does not ship).
pub fn config_for_tiles(tile_extract: &Path) -> String {
    let mut c: Value = serde_json::from_str(include_str!("valhalla_config.json")).expect("config template");
    c["mjolnir"]["tile_extract"] = Value::String(tile_extract.to_string_lossy().into_owned());
    c.to_string()
}

impl ShimValhalla {
    /// `lib_path`: the shim library; `config`: a Valhalla config (JSON text or a file path).
    pub fn load(lib_path: &Path, config: &str) -> Result<ShimValhalla, String> {
        unsafe {
            let lib = Library::new(lib_path).map_err(|e| format!("{}: {e}", lib_path.display()))?;
            macro_rules! sym {
                ($t:ty, $n:expr) => {
                    *lib.get::<$t>($n).map_err(|e| format!("symbol {}: {e}", String::from_utf8_lossy($n)))?
                };
            }
            let init: InitFn = sym!(InitFn, b"valhalla_shim_init\0");
            let route = sym!(CallFn, b"valhalla_shim_route\0");
            let locate = sym!(CallFn, b"valhalla_shim_locate\0");
            let trace = sym!(CallFn, b"valhalla_shim_trace_attributes\0");
            let free = sym!(FreeFn, b"valhalla_shim_string_free\0");
            let destroy = sym!(DestroyFn, b"valhalla_shim_destroy\0");
            let err = sym!(ErrFn, b"valhalla_shim_last_error\0");
            let code = sym!(CodeFn, b"valhalla_shim_last_error_code\0");
            let cfg = CString::new(config).map_err(|e| e.to_string())?;
            let h = init(cfg.as_ptr());
            if h.is_null() {
                let m = err(std::ptr::null_mut());
                let m = if m.is_null() { String::new() } else { CStr::from_ptr(m).to_string_lossy().into_owned() };
                return Err(format!("valhalla_shim_init failed: {m}"));
            }
            Ok(ShimValhalla { _lib: lib, h, route, locate, trace, free, destroy, err, code })
        }
    }

    fn call(&self, f: CallFn, req: &Value) -> Result<Value, ValhallaError> {
        let body = CString::new(req.to_string()).map_err(|e| ValhallaError::msg(e.to_string()))?;
        unsafe {
            let out = f(self.h, body.as_ptr());
            if out.is_null() {
                let m = (self.err)(self.h);
                let message = if m.is_null() { String::new() } else { CStr::from_ptr(m).to_string_lossy().into_owned() };
                let code = (self.code)(self.h);
                return Err(ValhallaError { code: if code == 0 { None } else { Some(code as i64) }, message, timeout: false });
            }
            let s = CStr::from_ptr(out).to_string_lossy().into_owned();
            (self.free)(out);
            serde_json::from_str(&s).map_err(|e| ValhallaError::msg(format!("bad Valhalla JSON: {e}")))
        }
    }
}

impl Drop for ShimValhalla {
    fn drop(&mut self) {
        unsafe { (self.destroy)(self.h) }
    }
}

fn s(v: &Value) -> Option<String> {
    v.as_str().map(String::from)
}

impl Valhalla for ShimValhalla {
    fn locate(&self, lat: f64, lon: f64, costing: &str) -> Option<LocateSnap> {
        let r = self.call(self.locate, &json!({"locations": [{"lat": lat, "lon": lon}], "costing": costing, "verbose": true})).ok()?;
        let edge = r.get(0)?.get("edges")?.get(0)?;
        let snap_lat = edge.get("correlated_lat").and_then(|v| v.as_f64()).unwrap_or(lat);
        let snap_lon = edge.get("correlated_lon").and_then(|v| v.as_f64()).unwrap_or(lon);
        let cls = edge.get("edge").and_then(|e| e.get("classification"));
        Some(LocateSnap {
            snap_distance_m: crate::grid::haversine_m(lat, lon, snap_lat, snap_lon),
            road_class: cls.and_then(|c| c.get("classification")).and_then(s),
            use_: cls.and_then(|c| c.get("use")).and_then(s),
        })
    }

    fn route(&self, from: (f64, f64), to: (f64, f64), costing: &str) -> Result<Trip, ValhallaError> {
        let r = self.call(
            self.route,
            &json!({"locations": [{"lat": from.0, "lon": from.1}, {"lat": to.0, "lon": to.1}], "costing": costing, "units": "km"}),
        )?;
        let trip = r.get("trip").ok_or_else(|| ValhallaError::msg("no trip in reply"))?;
        parse_trip(trip)
    }

    fn alternatives(&self, from: (f64, f64), to: (f64, f64), costing: &str, count: usize) -> Vec<Trip> {
        let Ok(r) = self.call(
            self.route,
            &json!({"locations": [{"lat": from.0, "lon": from.1}, {"lat": to.0, "lon": to.1}], "costing": costing, "units": "km", "alternates": count}),
        ) else {
            return Vec::new();
        };
        r.get("alternates")
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|alt| alt.get("trip").and_then(|t| parse_trip(t).ok())).collect())
            .unwrap_or_default()
    }

    fn trace_attributes(&self, enc: &str) -> Result<Trace, ValhallaError> {
        let r = self.call(
            self.trace,
            &json!({
                "encoded_polyline": enc, "costing": "auto",
                "filters": {"attributes": ["edge.surface", "edge.road_class", "edge.use", "edge.begin_shape_index",
                                           "edge.end_shape_index", "shape"], "action": "include"}
            }),
        )?;
        let edges = r
            .get("edges")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .map(|e| TraceEdge {
                        use_: e.get("use").and_then(s),
                        road_class: e.get("road_class").and_then(s),
                        surface: e.get("surface").and_then(s),
                        begin_shape_index: e.get("begin_shape_index").and_then(|v| v.as_i64()),
                        end_shape_index: e.get("end_shape_index").and_then(|v| v.as_i64()),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(Trace { edges, shape: r.get("shape").and_then(s) })
    }
}

/// A Valhalla `trip` object (first leg) as a [`Trip`].
fn parse_trip(trip: &Value) -> Result<Trip, ValhallaError> {
    let leg = trip.get("legs").and_then(|l| l.get(0)).ok_or_else(|| ValhallaError::msg("No route found"))?;
    let enc = leg.get("shape").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let f = |m: &Value, k: &str| m.get(k).and_then(|v| v.as_f64());
    let maneuvers = leg
        .get("maneuvers")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .map(|m| Maneuver {
                    instruction: m.get("instruction").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                    kind: m.get("type").and_then(|v| v.as_i64()).unwrap_or(0),
                    length_km: f(m, "length").unwrap_or(0.0),
                    time_s: f(m, "time").unwrap_or(0.0),
                    street_names: m.get("street_names").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(s).collect()).unwrap_or_default(),
                    begin_shape_index: m.get("begin_shape_index").and_then(|v| v.as_i64()).unwrap_or(0),
                    end_shape_index: m.get("end_shape_index").and_then(|v| v.as_i64()).unwrap_or(0),
                    bearing_after: f(m, "bearing_after"),
                    bearing_before: f(m, "bearing_before"),
                })
                .collect()
        })
        .unwrap_or_default();
    let sum = trip.get("summary");
    Ok(Trip {
        shape: decode_polyline6(&enc),
        shape_encoded: enc,
        maneuvers,
        length_km: sum.and_then(|x| f(x, "length")).unwrap_or(0.0),
        time_s: sum.and_then(|x| f(x, "time")).unwrap_or(0.0),
    })
}
