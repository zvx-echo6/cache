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

## iPhone device static build (iOS 16.3+, arm64)

Run on a GitHub macOS runner with Xcode, CMake, Ninja and Rust already available:

```sh
packages/cache_search/ios/build-core.sh "$RUNNER_TEMP/libzim"
# Or routing alone:
bash packages/valhalla/scripts/build-ios.sh "$RUNNER_TEMP/valhalla" "$RUNNER_TEMP/routing-out"
```

The script checks out Valhalla commit `72f459fc5661fb906ad424be5378c4e32d9a5b3b`
(tag 3.7.0) recursively and vcpkg commit `0e39c10736341cc8135b560438229bbda3d3219a`
(the manifest baseline). Submodule commits and dependency versions come from those
pinned trees. It bootstraps vcpkg only inside the runner work directory; no desktop
packages are installed. `arm64-ios-rel` selects static Release libraries, the
iphoneos SDK and deployment target 16.3. Host protoc runs on macOS; target protobuf
is protobuf-lite. Features and dependencies match Android: no LZ4, HTTP, services,
tools or tile building. This is device-only; it does not provide a simulator slice.

CMake retains shared-library defaults for Android/Windows. iOS selects
`CACHE_VALHALLA_STATIC=ON`, builds and links the existing C ABI harness, then merges
the shim, libvalhalla and target dependency archives into `libcache_valhalla.a`.
Host libraries, full protobuf and protoc archives are excluded. The script verifies
arm64 and definitions for all ten shim functions, then links the C harness again
against the merged archive with Apple's device compiler. It never executes an
iPhone executable on the runner.

`packages/cache_search/ios/native/libcache_valhalla.a` is linked by the pod alongside
the Rust archive and CoreKiwix. Rust's linked iOS calls retain the shim. The existing
force-load of the Rust archive retains FFI entry points. No dynamic library is
loaded from app storage. Build provenance, SHA256 and symbol listing accompany
the archive as `valhalla-build.txt` and `valhalla-symbols.txt`.

The core output cache includes Rust sources/manifests, ZIM sources, all Valhalla
recipe/shim/triplet inputs and the workflow. Toolchain identity covers Xcode,
iphoneos SDK, Rust, CMake, Ninja and host architecture. Routing source/download/
dependency/build cache is separate from Kiwix's nested download directory.
Finished core caches match the exact recipe/toolchain; Cargo incremental reuse is also
partitioned by toolchain. Native caches/artifacts live on ephemeral Actions runners;
no Windows compilation or C: build outputs are created.

Dispatch `ios-testflight.yml` from `ios-routing` with `stage=all`,
`ref=ios-routing`, `upload=false` after coordinating with the lead. The app job
runs `flutter test --no-pub test/core_config_test.dart` and checks the final signed
Runner for `_valhalla_shim_init` and `_valhalla_shim_route`, in addition to existing
core/chat exports. Upload remains an explicit workflow input.

Validation at implementation: both shell scripts pass Bash syntax checks on the
desktop; whitespace diff checks pass. Device compile/link and final app checks
require the coordinated macOS run; no claim of runtime routing follows from a
link check. Host runtime smoke is deferred until that first compile is diagnosed.
The lead supplied the public single-part Idaho extract for that follow-up:
`https://github.com/zvx-echo6/cache-packs/releases/download/idaho-2026-10-25/valhalla-idaho-2026-10-25.tar.part00`,
221798400 bytes, SHA256
`41a0f5c548f904c8718cd53c90e662dc565cdf6a1a55546416d0537d959daf48`.
The planned assertion is auto routing Burley (42.536,-113.792) to Boise
(43.615,-116.202), 200-350 km with maneuvers. This is not yet a performed test.

Primary build sources read: Valhalla 3.7.0 root/src/proto CMake files and
`scripts/valhalla_build_config`; pinned vcpkg iOS toolchain and protobuf wrapper;
Microsoft's triplet-variable documentation:
https://learn.microsoft.com/en-us/vcpkg/users/triplets .

Dependency-cache bring-up: restore/save are separate. The save step uses always(),
so failed native builds preserve downloads and partial dependency/build work.
Restore prefers the exact recipe, then the same toolchain across recipes; run/attempt suffixes
allow later partial progress to supersede earlier snapshots. Finished core-output
caches and native-core artifacts remain success-only.

First Actions run 40418080382 failed before Rust: host pkgconf's Meson sanity
executable was compiled for iPhone and killed (-9). Global
IPHONEOS_DEPLOYMENT_TARGET leaked into host Apple clang. build-ios.sh now unsets
that variable before vcpkg; target triplet and explicit iOS compiler/CMake flags
still pin the iOS minimum (now 16.3). The workflow's macOS disk-helper test also unsets it for clang.
Run 40419565770 confirmed this host-tool repair and reached Valhalla compilation.

Run 40419565770 then failed during Valhalla C++ compilation: the selected Xcode
libc++ floating-point to_chars overload used by std::format/chrono is explicitly
unavailable before iOS 16.3. The routing script (CMake flags, archive link check and
provenance), target triplet, Rust core build environment, search podspec and
workflow now consistently select 16.3. The app and llama minimums are coordinated
by the lead in separate files. The original 16.0 minimum was an implementation
choice, not a user compatibility requirement. No availability diagnostic is
suppressed and no upstream formatter is patched.

Dependency-cache restore can fall back to another recipe only under the same
Xcode/SDK/compiler toolchain identity. Source commits are still checked out
explicitly; configure always runs, allowing vcpkg to recompute package ABIs for
the changed triplet and CMake to regenerate compile/link flags. Cached build work
is an input to those build tools, never accepted as finished native output.
Finished-core caches remain exact by source/build inputs (including the changed
minimum and workflow) and are saved only on success. Syntax and diff checks cover
this repair; the next lead-dispatched device build must confirm compilation.

Run 40444409902 passed all 169 Valhalla compile/CMake link steps at iOS 16.3,
archive merging, arm64 verification and all ten shim definition checks. The final
manual merged-archive link alone failed: all unresolved framework symbols were
CoreFoundation functions from date ios.mm and Abseil timezone code. That check now
adds -framework CoreFoundation, matching the existing search pod framework list.
No other unresolved framework family was reported. Rust was not reached.

Timezone resource audit (source inspection, not an iPhone runtime test):
Valhalla's src/baldr/CMakeLists.txt converts the pinned IANA continent files,
backward, etcetera and leapseconds into date_time_*.h arrays. Its tz_alt.cpp uses
init_tzdb_strings() to parse those arrays. date/tz.h defaults USE_OS_TZDB to 0;
the routing targets set HAS_REMOTE_API=0 and AUTO_DOWNLOAD=0. There is no separate
date-tz library enabled here. Thus the timezone rule data itself is embedded,
rather than read from a bundled tz database or downloaded.

Important remaining initialization risk: init_tzdb_strings() still calls
get_install(). With INSTALL undefined, iPhone expand_path() invokes
date::iOSUtils::get_tzdata_path(). The pinned date helper returns immediately if
the sandbox Library/tzdata path exists; otherwise it scans the main bundle for
tar.gz resources, assumes the first is timezone data, and attempts extraction.
It does not guard all CoreFoundation results. Embedded rules therefore do not
prove safe first-use initialization in a fresh sandbox.

The current helper's resource convention is a flat raw IANA tz-source tar.gz
(continent files, backward, etcetera, leapseconds) in the native main bundle,
extracted into Library/tzdata. Flutter assets alone are not that convention.
However, Valhalla's actual embedded parser does not consume these extracted files,
so adding a duplicate timezone archive is not established as necessary. No
resource, sandbox directory or upstream code was changed by this link repair.
Fresh-install iPhone initialization must be validated before declaring routing
operational. Avoiding the unused path initialization with a scoped INSTALL
definition or explicit app setup is Proposed — not approved.

Pinned source audit:
https://github.com/valhalla/valhalla/blob/72f459fc5661fb906ad424be5378c4e32d9a5b3b/src/baldr/tz_alt.cpp
https://github.com/HowardHinnant/date/blob/b2e917ce6ca8dc11403772f6161b8f69f808c38b/src/ios.mm

### iOS embedded-TZ initialization repair

The follow-up wrapper CMake change selects date's existing INSTALL preprocessor
option only for src/baldr/tz_alt.cpp on iOS. It uses SOURCE with
TARGET_DIRECTORY valhalla-baldr after add_subdirectory, so the property is visible
in the directory that creates that module (supported since CMake 3.18).
This is a compiler definition, not CMake's install prefix or an install step.

Verified against the pinned source: access_install() uses STRINGIZE(INSTALL)
plus the delimiter and "tzdata" when INSTALL is defined. INSTALL=. therefore
produces "./tzdata" without get_download_folder()/expand_path() and without the
iOS bundle-scan/extraction helper. init_tzdb_strings() assigns install/path but
does not read them; it still parses the generated continent/backward/etcetera/
leapsecond arrays. The build also generates the windowsZones XML header (used
on Windows). USE_OS_TZDB remains 0, HAS_REMOTE_API/AUTO_DOWNLOAD remain 0.
No upstream source or headers are patched. No timezone archive, fake empty
archive, extracted files or sandbox directory is required for this embedded path.
CoreFoundation remains linked for system timezone-name lookup and Abseil.
This supersedes the unresolved bundle-scan concern above for the configured path;
actual on-device routing still requires runtime validation.

Cheap preflight checks before another full compile:
- Assert the pinned tz_alt.cpp access_install() still has the INSTALL conditional
  and STRINGIZE(INSTALL) branch, and init_tzdb_strings() still parses
  get_tz_data_file_list(); revisit this choice if upstream behavior changes.
- After CMake configure, query the property in the owning directory:
  get_source_file_property(tz_defs "${VALHALLA_SRC}/src/baldr/tz_alt.cpp"
    TARGET_DIRECTORY valhalla-baldr COMPILE_DEFINITIONS)
  Require INSTALL=. in tz_defs for iOS, absent on Android/Windows.
- In compile_commands.json, require -DINSTALL=. on the tz_alt.cpp command only;
  confirm -DUSE_OS_TZDB=1 is absent and the existing
  -DHAS_REMOTE_API=0/-DAUTO_DOWNLOAD=0 definitions remain.
These are configure/source inspections, not a replacement for iPhone initialization
and routing tests. The separate preflight script is maintained by its own worker.

CMake scope reference:
https://cmake.org/cmake/help/v3.21/command/set_property.html

### Enforced post-configure compile-command gate

build-ios.sh explicitly enables CMAKE_EXPORT_COMPILE_COMMANDS and runs an inline
Python standard-library gate immediately after configure and before cmake --build.
It reads compile_commands.json, accepts the arguments array or shlex-parses the
command string, and resolves relative source paths against each entry's directory.
The gate requires one exact pinned-source tz_alt.cpp entry with one INSTALL=.
definition and no conflicting undefine. INSTALL on another source fails.
USE_OS_TZDB must be absent or explicitly 0 throughout. Both date implementation
commands (tz_alt.cpp and ios.mm) must keep HAS_REMOTE_API=0 and AUTO_DOWNLOAD=0
without conflicting values/undefines. Malformed or missing command data fails with
a routing compile preflight diagnostic. The shell exits before the Valhalla
compile invocation when any invariant fails. Dependency setup performed by CMake
configure precedes this gate; the gate does not claim to prevent those builds.

Wrapper CMake additionally reads tz_alt.cpp's source COMPILE_DEFINITIONS using
TARGET_DIRECTORY valhalla-baldr, requires INSTALL=. for iOS and rejects that
definition on other platforms. The generated-command gate verifies actual compiler
arguments beyond the source-property assertion. No upstream code is changed.

Validation on the desktop used ten temporary E: fixtures: valid arguments and
shell command formats; missing INSTALL; leaked INSTALL; OS TZDB enabled; networking
enabled; missing offline definition; INSTALL undefined; duplicate and missing
tz_alt.cpp commands. All expected outcomes passed without invoking a compiler.
Bash syntax and whitespace checks also pass. Actual generated commands still need
the next coordinated Mac configure. Temporary test files are removed; no native
Windows build was started. The separate preflight-ios.sh/workflow gates remain
owned by their assigned worker/lead.
