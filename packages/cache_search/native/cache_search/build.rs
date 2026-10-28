//! Export control for the shared library: on Linux and Android the cdylib exports only the `cs_*` C ABI
//! symbols (a linker version script), so dependencies' `#[no_mangle]` symbols stay private. Other targets
//! (macOS, Windows, wasm) use different linkers with other mechanisms and are not handled here.

fn main() {
    println!("cargo:rerun-if-changed=cache_search.map");
    println!("cargo:rerun-if-changed=build.rs");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os == "linux" || os == "android" {
        let dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
        println!("cargo:rustc-cdylib-link-arg=-Wl,--version-script={dir}/cache_search.map");
        println!("cargo:rustc-cdylib-link-arg=-Wl,--exclude-libs,ALL");
    }
}
