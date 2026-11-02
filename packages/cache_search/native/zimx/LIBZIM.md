# libzim (official prebuilt) used by the `xapian` feature

The C++ shim in this folder (`zimx.cpp`) is built against Kiwix's **official prebuilt libzim**, never against a
self-built one. libzim has Xapian (statically) inside, so a ZIM's own full-text and title indexes can be searched.
The binaries are downloaded into the build directory by the fetch scripts and are **never committed**.

| Item | Value |
|---|---|
| libzim version | 9.8.2 (release build `-1`, 2026-09-11) |
| Xapian inside | 1.4.23 (the version the prebuilt reports at run time; kiwix-build pins 1.4.26) |
| Source | https://download.openzim.org/release/libzim/ |
| Windows x86_64 | `libzim_win-x86_64-9.8.2-1.zip`, md5 `6fec1bb98a7a628a2c38270414c521c1`, 15,626,882 bytes |
| Android arm64 | `libzim_android-arm64-9.8.2-1.tar.gz`, md5 `59a6b769847b77dc0ace69c3b9727445` |
| Published checksum | the `.md5` file next to each archive (no signature is published) |

URLs:

- https://download.openzim.org/release/libzim/libzim_win-x86_64-9.8.2-1.zip
- https://download.openzim.org/release/libzim/libzim_android-arm64-9.8.2-1.tar.gz

## What is in them

- Windows: `bin/zim-9.dll` (2.3 MB; Xapian, zstd and lzma are inside it), `bin/icu{dt,in,io,tu,uc}74.dll` (ICU 74; `icudt74.dll`
  is the 30.8 MB data), `lib/zim.lib` (import library), `include/zim/*.h`. Built with MSVC; it needs the Visual C++
  redistributable (MSVCP140, VCRUNTIME140) on the target.
- Android arm64: `lib/aarch64-linux-android/libzim.so` (16.2 MB unstripped, about 8.2 MB stripped), headers, and
  `share/icu/73.2/icudt73l.dat` (ICU data, 11 MB; the ICU inside `libzim.so` has no data of its own, the app sets `ICU_DATA` to the
  folder that holds the file). It needs `libc++_shared.so` from the NDK next to it. Built with cargo-ndk on 2026-10-26 (sizes and
  what to ship: DESIGN.md "Android build"); not yet run on a device.

## Fetch and build

Windows (PowerShell; `-BuildDir` is the build folder, for example `E:\cs-build`):

```
powershell -ExecutionPolicy Bypass -File native\zimx\fetch-libzim.ps1 -BuildDir E:\cs-build
set LIBZIM_DIR=E:\cs-build\libzim\win-x86_64-9.8.2-1
cargo build --release
```

Android (bash):

```
native/zimx/fetch-libzim.sh /path/to/build-dir
export LIBZIM_DIR=/path/to/build-dir/libzim/android-arm64-9.8.2-1
cargo ndk --platform 28 -t arm64-v8a build --release -p cache_search
```

On a Windows machine without bash on the path, run the script with Git for Windows: `set PATH=C:\Program Files\Git\usr\bin;%PATH%`,
then `"C:\Program Files\Git\bin\sh.exe" native/zimx/fetch-libzim.sh E:/cs-build`.

Both scripts print the `LIBZIM_DIR` to use, stop on a checksum mismatch, and reuse a verified download.
`build.rs` reads `LIBZIM_DIR`, compiles `zimx.cpp` with the `cc` crate, links `zim.lib`, and (Windows) copies `zim-9.dll` and the
ICU DLLs next to the built binaries (`target/<profile>/` and `target/<profile>/deps/`). A shipped Windows package must
carry the same DLLs next to `cs.exe` / the cache_search DLL.

Build without libzim: `cargo build --no-default-features` (Tantivy-only keyword search, as before).

## Licences

See DESIGN.md, "Licences": libzim and Xapian are GPL-2.0-or-later, ICU has its own permissive licence.

## iPhone (iOS arm64)

The iPhone build uses Kiwix's official **CoreKiwix.xcframework** instead (Kiwix's own App Store app uses it), because openZIM
publishes no iOS libzim. It is one static archive per slice with libkiwix, libzim, Xapian, ICU **including the ICU data**, zstd,
lzma and zlib inside, so there is no `ICU_DATA` step on iPhone.

| Item | Value |
|---|---|
| Version | libkiwix_xcframework 14.2.1-2 (2026-05-27); its libzim is **9.7.0** (Android and Windows use 9.8.2; the shim builds against both, it uses only API present in 9.7.0) |
| Source | https://download.kiwix.org/release/libkiwix/libkiwix_xcframework-14.2.1-2.tar.gz (60,830,289 bytes) |
| md5 | `78c0398d14228d11d2caf2c888314d04` (matches the `.md5` Kiwix publishes next to it) |
| sha256 | `14820648788dddc3df8a89ff0820af60d7efc1cfda6c83602989455263ee1561` (recorded here; Kiwix publishes no sha256) |

`native/zimx/fetch-libzim-ios.sh <build-dir>` downloads it, checks both sums and prints `LIBZIM_DIR` (the `ios-arm64` slice:
`merged.a` and `Headers/`). `packages/cache_search/ios/build-core.sh` uses it, builds the core as a static library and copies
`merged.a` to `ios/native/libCoreKiwix.a`; the pod links both into the app. Only the parts libzim needs are pulled out of
`merged.a` (the curl, microhttpd and libkiwix server code stays out).
