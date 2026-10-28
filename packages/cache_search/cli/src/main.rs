fn main() {
    std::process::exit(cache_search_cli::commands::main_with(std::env::args().skip(1).collect()));
}
