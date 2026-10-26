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
  `share/icu/73.2/icudt73l.dat` (ICU data, 11 MB). It needs `libc++_shared.so` from the NDK next to it. The Android
  build is wired in `build.rs` but has not been built or run (Windows first).

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
```

Both scripts print the `LIBZIM_DIR` to use, stop on a checksum mismatch, and reuse a verified download.
`build.rs` reads `LIBZIM_DIR`, compiles `zimx.cpp` with the `cc` crate, links `zim.lib`, and (Windows) copies `zim-9.dll` and the
ICU DLLs next to the built binaries (`target/<profile>/` and `target/<profile>/deps/`). A shipped Windows package must
carry the same DLLs next to `cs.exe` / the cache_search DLL.

Build without libzim: `cargo build --no-default-features` (Tantivy-only keyword search, as before).

## Licences

See DESIGN.md, "Licences": libzim and Xapian are GPL-2.0-or-later, ICU has its own permissive licence.
