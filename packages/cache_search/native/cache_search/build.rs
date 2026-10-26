//! Export control for the shared library: on Linux and Android the cdylib exports only the `cs_*` C ABI
//! symbols (a linker version script), so dependencies' `#[no_mangle]` symbols stay private. Other targets
//! (macOS, Windows, wasm) use different linkers with other mechanisms and are not handled here.
//!
//! Cargo feature `xapian` (default): on Windows and Android, compile the C++ shim `../zimx` over the official prebuilt
//! libzim (its built-in Xapian full-text index) and link it; the `zimx` cfg is set when that happened. On any other
//! target the feature does nothing. The prebuilt libzim is found through the environment variable `LIBZIM_DIR`: the
//! folder `native/zimx/fetch-libzim.ps1` (Windows) or `fetch-libzim.sh` (Android) unpacks, holding `include/`, `lib/`
//! and, on Windows, `bin/` (zim-9.dll and the ICU DLLs, copied next to the built binaries).

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=cache_search.map");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-check-cfg=cfg(zimx)");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os == "linux" || os == "android" {
        let dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
        println!("cargo:rustc-cdylib-link-arg=-Wl,--version-script={dir}/cache_search.map");
        println!("cargo:rustc-cdylib-link-arg=-Wl,--exclude-libs,ALL");
    }
    if std::env::var_os("CARGO_FEATURE_XAPIAN").is_some() && (os == "windows" || os == "android") {
        build_zimx(&os);
    }
}

fn build_zimx(os: &str) {
    println!("cargo:rerun-if-env-changed=LIBZIM_DIR");
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let shim = manifest.join("..").join("zimx");
    println!("cargo:rerun-if-changed={}", shim.join("zimx.cpp").display());
    println!("cargo:rerun-if-changed={}", shim.join("zimx.h").display());
    let Some(dir) = std::env::var_os("LIBZIM_DIR").map(PathBuf::from) else {
        panic!(
            "the `xapian` feature needs the official prebuilt libzim: run native/zimx/fetch-libzim.ps1 (Windows) or \
             fetch-libzim.sh (Android), set LIBZIM_DIR to the folder it prints, or build with --no-default-features"
        );
    };
    let include = dir.join("include");
    assert!(include.join("zim").join("archive.h").is_file(), "LIBZIM_DIR={}: no include/zim/archive.h", dir.display());

    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .include(&include)
        .file(shim.join("zimx.cpp"))
        // MSVC: C++ exceptions on (the shim catches every one), and libzim's own headers' dll-interface notes off.
        .flag_if_supported("/EHsc")
        .flag_if_supported("/wd4251")
        .flag_if_supported("/wd4530")
        .compile("zimx");

    if os == "windows" {
        let lib = dir.join("lib");
        assert!(lib.join("zim.lib").is_file(), "LIBZIM_DIR={}: no lib/zim.lib", dir.display());
        println!("cargo:rustc-link-search=native={}", lib.display());
        println!("cargo:rustc-link-lib=dylib=zim");
        copy_dlls(&dir.join("bin"));
    } else {
        // Android: the official prebuilt keeps one folder per ABI under lib/. libzim.so needs libc++_shared.so from the
        // NDK next to it in the app (see DESIGN.md); not exercised by the Windows-first work.
        let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
        let triple = match arch.as_str() {
            "aarch64" => "aarch64-linux-android",
            "arm" => "arm-linux-androideabi",
            "x86_64" => "x86_64-linux-android",
            "x86" => "i686-linux-android",
            other => panic!("no libzim prebuilt for android arch {other}"),
        };
        println!("cargo:rustc-link-search=native={}", dir.join("lib").join(triple).display());
        println!("cargo:rustc-link-lib=dylib=zim");
        println!("cargo:rustc-link-lib=dylib=c++_shared");
    }
    println!("cargo:rustc-cfg=zimx");
}

/// Windows: put zim-9.dll and the ICU DLLs next to the binaries (`target/<profile>/` for cs.exe and the cdylib,
/// `target/<profile>/deps/` for the test executables), so they start without PATH changes.
fn copy_dlls(bin: &Path) {
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    // OUT_DIR = target/<profile>/build/<pkg>-<hash>/out
    let Some(profile) = out.ancestors().nth(3) else { return };
    let Ok(rd) = std::fs::read_dir(bin) else {
        panic!("LIBZIM_DIR: no bin/ folder with zim-9.dll ({})", bin.display());
    };
    for e in rd.flatten() {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()).map(|x| x.eq_ignore_ascii_case("dll")) != Some(true) {
            continue;
        }
        println!("cargo:rerun-if-changed={}", p.display());
        for dest in [profile.to_path_buf(), profile.join("deps")] {
            if std::fs::create_dir_all(&dest).is_err() {
                continue;
            }
            let to = dest.join(p.file_name().unwrap());
            let same = match (std::fs::metadata(&p), std::fs::metadata(&to)) {
                (Ok(a), Ok(b)) => a.len() == b.len(),
                _ => false,
            };
            if !same {
                if let Err(err) = std::fs::copy(&p, &to) {
                    println!("cargo:warning=could not copy {} to {}: {err}", p.display(), to.display());
                }
            }
        }
    }
}
