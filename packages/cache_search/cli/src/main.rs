fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    // A panic anywhere in the CLI itself (the core's calls already turn panics into errors) prints its text as a
    // JSON error on stderr and exits non-zero, in addition to the default panic message.
    let code = match std::panic::catch_unwind(|| cache_search_cli::commands::main_with(argv)) {
        Ok(c) => c,
        Err(p) => {
            let msg = p
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| p.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".into());
            cache_search_cli::commands::report_error(&cache_search_cli::engine::ApiError::new("internal", format!("panic: {msg}")));
            101
        }
    };
    std::process::exit(code);
}
