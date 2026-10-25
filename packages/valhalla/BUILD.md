# Valhalla 3.7.0 for Cache (Windows x64 + Android arm64)

Valhalla **3.7.0** (the version navi serves, so navi's tiles load unchanged) built as one
library plus a small C shim, `valhalla_shim`. The Rust core calls the shim over FFI.
Windows is the desktop test harness; Android arm64 is the phone build.

Valhalla sources and build outputs are **not** committed. The scripts clone the pinned tag
(`3.7.0`, with submodules) and the pinned vcpkg commit.

## Contents

| Path | What |
|---|---|
| `shim/valhalla_shim.h`, `shim/valhalla_shim.cc` | C ABI over `valhalla::tyr::actor_t`. Valhalla JSON in, Valhalla JSON out, no interpretation. |
| `test/shim_test.c` | Tiny C test program (init, route / matrix / locate, per-call timing). |
| `CMakeLists.txt`, `vcpkg.json`, `triplets/` | Top-level project: Valhalla via `add_subdirectory`, routing-only modules, vcpkg manifest. |
| `scripts/build-windows.bat`, `scripts/build-android.bat` | Build scripts (run on the Windows desktop). |
| `scripts/stubs/make.cmd` | No-op `make` for the Android cross build (see "tz leapseconds"). |
| `tz/leapseconds` | Pre-generated tz file (see below). |
| `tools/tilecut/` | Rust tile cutter (bbox subset of a tile_extract tar). |

## Route followed

Valhalla's own docs (`docs/docs/building.md`) say to build with vcpkg (`vcpkg install`, then CMake with
the vcpkg toolchain file; on Windows MSVC with the `x64-windows` triplet, vcpkg commit `0e39c10` as in its
Windows CI). Valhalla has no Android build in its docs or CI, so for Android we follow the most-used
route, the **valhalla-mobile** project (Rallista/valhalla-mobile): a small top-level CMake project that
`add_subdirectory`s Valhalla with tools, data tools, services, HTTP and Python all OFF, vcpkg manifest with a
minimal dependency list, a static `arm64-android` triplet, and the NDK toolchain chained into vcpkg
(`VCPKG_CHAINLOAD_TOOLCHAIN_FILE`). Same layout is used for Windows, so both targets build the same way.

Switches (see `CMakeLists.txt`): `ENABLE_TOOLS/DATA_TOOLS/SERVICES/HTTP/PYTHON_BINDINGS/TESTS/GEOTIFF/LZ4=OFF`.
Modules built: baldr, loki, meili, midgard, odin, sif, skadi, thor, tyr (+ proto). No mjolnir (data tools),
no prime_server, no curl.

vcpkg dependencies (`vcpkg.json`): boost headers (algorithm, foreach, format, geometry, heap, optional,
property-tree, range, tokenizer), protobuf (Valhalla links the lite runtime), zlib, pkgconf (host).
Everything else (rapidjson, date, unordered_dense, dirent, protozero) is Valhalla's vendored copy.

## Build prerequisites (Windows desktop)

- Visual Studio 2022 or Build Tools with the C++ workload (its bundled CMake and Ninja are used; no separate install).
- git.
- vcpkg cloned to `C:\src\vcpkg` at commit `0e39c10` and bootstrapped (`bootstrap-vcpkg.bat -disableMetrics`).
  Override the location with `CACHE_VCPKG`.
- Android only: NDK **28.2.13676358** (r28, the version Flutter's Android build uses) under the Android SDK
  `ndk` folder, or set `ANDROID_NDK_HOME`. Target API 24, ABI arm64-v8a, `c++_static`.

## Build

```
scripts\build-windows.bat  [workdir]      rem default C:\src\valhalla-build
scripts\build-android.bat  [workdir]
```

Outputs: `build-win\valhalla_shim.dll` (+ `valhalla_shim_test.exe`) and
`build-android\libvalhalla_shim.so` (`libvalhalla_shim.stripped.so` is the shippable copy) +
`valhalla_shim_test`. vcpkg builds its dependencies during CMake configure (first run takes roughly an hour on
the desktop because of the many Boost ports; later runs are fast).

Windows triplet is `x64-windows-static-md-rel` (static libs, release only, dynamic MSVC runtime), so the DLL
needs only the VC++ 2015-2022 redistributable. The Android `.so` is self-contained (static libc++), it needs only
`liblog`, `libm`, `libdl`, `libc`. All Valhalla and dependency symbols are hidden; only `valhalla_shim_*` is exported.

### tz leapseconds

Valhalla generates `third_party/tz/leapseconds` by running `nmake leapseconds` (Windows target) or
`make leapseconds` (anything else), which needs `awk`. The desktop has neither. `tz/leapseconds` is the output of
`make leapseconds` from the exact tz commit Valhalla pins (`dd6be6d`); the scripts copy it into the tree and
touch it, so the rule never runs (Android uses `scripts/stubs/make.cmd` because Ninja still runs that rule once on a
fresh build directory). Public-domain data; regenerate it if Valhalla's tz submodule is ever updated.

## Shim API (`shim/valhalla_shim.h`)

```
valhalla_shim_t* valhalla_shim_init(const char* config);   // config file path OR inline JSON; NULL on error
char* valhalla_shim_route (valhalla_shim_t*, const char* request_json);
char* valhalla_shim_matrix(valhalla_shim_t*, const char* request_json);   // sources_to_targets
char* valhalla_shim_locate(valhalla_shim_t*, const char* request_json);
char* valhalla_shim_trace_attributes(valhalla_shim_t*, const char* request_json);   // map-matching (surface changes)
void  valhalla_shim_string_free(char*);
void  valhalla_shim_destroy(valhalla_shim_t*);
const char* valhalla_shim_last_error(valhalla_shim_t*);    // NULL handle = last init error on this thread
int         valhalla_shim_last_error_code(valhalla_shim_t*); // Valhalla error_code of the last failure (442 no path, 171 no edges, 154 limit, ...), 0 if none
const char* valhalla_shim_version(void);
```

Responses are Valhalla's own JSON, malloc'd, freed with `valhalla_shim_string_free`. A failing call returns NULL and
`last_error` holds Valhalla's message. A handle serialises its calls with a mutex (`actor_t` is not thread-safe);
use one handle per thread for parallel requests. The actor is created with `auto_cleanup = true` so workers give
memory back after each request. The config selects the tiles: `mjolnir.tile_extract` (tar) or `mjolnir.tile_dir`.
Use a full Valhalla config (navi's `valhalla.json` works; remove the `mjolnir` paths to files you do not ship, such as
`admin`, `timezone`, `landmarks`).

Note: the costmatrix limits in navi's config (`thor.costmatrix.hierarchy_limits`, `max_iterations`) apply, so a
long matrix leg (Burley to Boise, 257 km) can come back as null while the same pair routes fine. That is Valhalla's
configured behaviour, not a shim issue.

## Test program

```
valhalla_shim_test <config.json> <route|matrix|locate|trace_attributes> <request.json> [repeats] [-q] [-o out.json]
```

## Tile cutter (`tools/tilecut`)

Cuts a bbox out of a Valhalla `tile_extract` tar and writes a smaller tar and/or a `tile_dir`. Std-only Rust, no
dependencies. Build and run (cargo is installed on the desktop):

```
cd packages\valhalla\tools\tilecut
cargo build --release
target\release\tilecut.exe valhalla_tiles.tar -118.0 41.5 -110.3 49.5 --tar tiles.tar --dir tiles
```

Tiles are picked by id from Valhalla's tiling (level 0 = 4 degrees, 1 = 1 degree, 2 = 0.25 degrees over
-180..180 / -90..90; id = row * columns + col). The tile's level and id are parsed from its path
(`2/000/818/660.gph`); every tile whose cell intersects the bbox is copied byte for byte. The source tar's
`index.bin` and tar pax headers are not carried over; Valhalla scans the subset tar's headers on load (1104 tiles,
about 10 ms). The Idaho cut (lon -118.0..-110.3, lat 41.5..49.5) is 9 + 72 + 1023 = 1104 tiles, 458,038,328 bytes
of tiles, 458,880,512 byte tar.

## Android test on a device (do not run without the go-ahead)

Files to push are staged in `C:\src\valhalla-build\android-push` (stripped `libvalhalla_shim.so`,
`valhalla_shim_test`, `tiles.tar`, `config.json`, request JSONs):

```
adb -s 39191FDJH008WZ shell mkdir -p /data/local/tmp/valhalla
adb -s 39191FDJH008WZ push C:\src\valhalla-build\android-push\. /data/local/tmp/valhalla/
adb -s 39191FDJH008WZ shell "cd /data/local/tmp/valhalla && chmod +x valhalla_shim_test && export LD_LIBRARY_PATH=. && ./valhalla_shim_test config.json route route_car.json 3 -q"
adb -s 39191FDJH008WZ shell "cd /data/local/tmp/valhalla && export LD_LIBRARY_PATH=. && ./valhalla_shim_test config.json route route_foot.json 3 -q && ./valhalla_shim_test config.json matrix matrix.json 3 -q"
adb -s 39191FDJH008WZ shell rm -rf /data/local/tmp/valhalla    # clean up afterwards
```

## Licenses

- Valhalla: MIT.
- Linked into the shim: Boost headers (Boost Software License 1.0), Protocol Buffers runtime (BSD-3-Clause),
  Abseil (Apache-2.0, a protobuf dependency), zlib (zlib license).
- Vendored by Valhalla and used by it: rapidjson (MIT), Howard Hinnant's date (MIT), IANA tz data (public domain),
  unordered_dense (MIT), dirent for Windows (MIT), protozero (BSD-2-Clause).
- Build only: vcpkg (MIT), CMake (BSD-3-Clause), Ninja (Apache-2.0).
- OSM-derived tiles carry the ODbL; attribution is the app's job.
- No LGPL or GPL code is linked.
