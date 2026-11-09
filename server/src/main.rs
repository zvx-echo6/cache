//! `cache`: `serve` runs the server, `set-password` sets (or resets) the one password and puts sign-in back to
//! password only, `keys` lists or removes registered keys.

use cache_server::auth::{Auth, AuthFile, Sessions, StoredPassword};
use cache_server::helper::{Helper, HelperConfig};
use cache_server::http::{serve_connection, App};
use cache_server::library::Library;
use cache_server::{config, tls, VERSION};
use std::io::{BufRead, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const USAGE: &str = "usage:
  cache serve --data <dir> --web <dir> [--listen 0.0.0.0:8443] [--no-tls] [--public-origin https://host[:port]] [--helper <exe>] [--core-lib <lib>] [--embed-lib <lib>] [--valhalla-shim <lib>]
      (--helper defaults to <this program's folder>/helper/cache-core-helper, --core-lib to <folder>/lib/libcache_search.so,
       --embed-lib (the cache_llama library that embeds text) to <folder>/lib/libcache_llama.so,
       --valhalla-shim (the road router) to libvalhalla_shim.so next to the core library;
       --public-origin, or public_origin in <dir>/config.json, is the address people use, for security keys: it needs a host name)
  cache set-password --data <dir> [--sign-out-all]
      (reads the password from standard input; a running server uses it at once; --sign-out-all also signs every browser out;
       it also puts sign-in back to password only and keeps the registered keys)
  cache keys --data <dir> --list
  cache keys --data <dir> --remove <id>
      (lists the registered security keys and key files, or removes one; a running server follows at once)
  cache --version";

struct Args {
    values: Vec<(String, String)>,
    flags: Vec<String>,
}

impl Args {
    /// `--name value` or `--name=value` for the names in `valued`, bare `--name` for the names in `boolean`.
    fn parse(argv: &[String], valued: &[&str], boolean: &[&str]) -> Result<Args, String> {
        let (mut values, mut flags) = (vec![], vec![]);
        let mut it = argv.iter();
        while let Some(a) = it.next() {
            let Some(name) = a.strip_prefix("--") else { return Err(format!("unexpected argument {a:?}")) };
            let (name, inline) = match name.split_once('=') {
                Some((n, v)) => (n, Some(v.to_string())),
                None => (name, None),
            };
            if boolean.contains(&name) && inline.is_none() {
                flags.push(name.to_string());
            } else if valued.contains(&name) {
                let v = match inline {
                    Some(v) => v,
                    None => it.next().cloned().ok_or(format!("--{name} needs a value"))?,
                };
                values.push((name.to_string(), v));
            } else {
                return Err(format!("unknown option --{name}"));
            }
        }
        Ok(Args { values, flags })
    }

    fn get(&self, name: &str) -> Option<&str> {
        self.values.iter().rev().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    fn req(&self, name: &str) -> Result<&str, String> {
        self.get(name).ok_or(format!("--{name} is required"))
    }

    fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|f| f == name)
    }
}

/// One line from standard input. On a terminal the typed characters are not shown (Unix; elsewhere they are).
fn read_password() -> std::io::Result<String> {
    #[cfg(unix)]
    {
        // SAFETY: plain libc terminal calls on file descriptor 0 with a zeroed termios that tcgetattr fills in.
        unsafe {
            if libc::isatty(0) == 1 {
                let mut saved: libc::termios = std::mem::zeroed();
                if libc::tcgetattr(0, &mut saved) == 0 {
                    eprint!("Password: ");
                    let mut quiet = saved;
                    quiet.c_lflag &= !libc::ECHO;
                    libc::tcsetattr(0, libc::TCSANOW, &quiet);
                    let line = read_line();
                    libc::tcsetattr(0, libc::TCSANOW, &saved);
                    eprintln!();
                    return line;
                }
            }
        }
    }
    read_line()
}

fn read_line() -> std::io::Result<String> {
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    Ok(line.trim_end_matches(['\r', '\n']).to_string())
}

fn set_password(argv: &[String]) -> Result<(), String> {
    let a = Args::parse(argv, &["data"], &["sign-out-all"])?;
    let data = Path::new(a.req("data")?);
    let password = read_password().map_err(|e| format!("reading the password: {e}"))?;
    let stored = StoredPassword::new(&password).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(data).map_err(|e| format!("{}: {e}", data.display()))?;
    let path = data.join("auth.json");
    // the keys stay; the sign-in setting goes back to password only, so a lost key never locks anyone out
    let mut file = AuthFile::load(&path).map_err(|e| format!("reading auth.json: {e}"))?.unwrap_or_default();
    file.reset_with_password(stored);
    file.save(&path).map_err(|e| format!("writing auth.json: {e}"))?;
    if a.flag("sign-out-all") {
        Sessions::clear_file(&data.join("sessions.json")).map_err(|e| format!("clearing sessions.json: {e}"))?;
        eprintln!("password set; sign-in is password only; every browser has been signed out");
    } else {
        eprintln!("password set; sign-in is password only; a running server uses it from the next sign-in");
    }
    Ok(())
}

fn keys(argv: &[String]) -> Result<(), String> {
    let a = Args::parse(argv, &["data", "remove"], &["list"])?;
    let data = Path::new(a.req("data")?);
    let path = data.join("auth.json");
    let mut file = AuthFile::load(&path).map_err(|e| format!("reading auth.json: {e}"))?.unwrap_or_default();
    let when = |t: Option<u64>| t.map_or("never".to_string(), |t| format!("{t}"));
    if let Some(id) = a.get("remove") {
        let (before_sk, before_kf) = (file.security_keys.len(), file.key_files.len());
        file.security_keys.retain(|k| k.id != id);
        file.key_files.retain(|k| k.id != id);
        if file.security_keys.len() + file.key_files.len() == before_sk + before_kf {
            return Err(format!("no key with id {id}"));
        }
        // taking the last key away must not leave a setting that needs one
        if file.mode.needs_key() && file.security_keys.is_empty() && file.key_files.is_empty() {
            file.mode = cache_server::auth::Mode::Password;
            file.start_with_password = false;
            eprintln!("that was the last key: sign-in is back to password only");
        }
        file.save(&path).map_err(|e| format!("writing auth.json: {e}"))?;
        eprintln!("removed {id}; a running server follows at once");
        return Ok(());
    }
    if !a.flag("list") {
        return Err("--list or --remove <id> is required".into());
    }
    println!("sign-in: {}{}", file.mode.as_str(), if file.start_with_password { " (start with the password box)" } else { "" });
    for k in &file.security_keys {
        println!("security-key  {}  {}  added {}  last used {}", k.id, k.name, k.added, when(k.last_used));
    }
    for k in &file.key_files {
        println!("key-file      {}  {}  made {}  last used {}", k.id, k.name, k.added, when(k.last_used));
    }
    if file.security_keys.is_empty() && file.key_files.is_empty() {
        println!("no keys registered");
    }
    Ok(())
}

fn serve(argv: &[String]) -> Result<(), String> {
    let a = Args::parse(argv, &["data", "web", "listen", "helper", "core-lib", "embed-lib", "valhalla-shim", "public-origin"], &["no-tls"])?;
    let data = PathBuf::from(a.req("data")?);
    let web = PathBuf::from(a.req("web")?);
    let listen: SocketAddr = a.get("listen").unwrap_or("0.0.0.0:8443").parse().map_err(|e| format!("--listen: {e}"))?;
    let use_tls = !a.flag("no-tls");
    eprintln!("cache {VERSION} starting");

    config::make_folders(&data).map_err(|e| format!("{}: {e}", data.display()))?;
    let tls_config = if use_tls {
        tls::ensure_cert(&data).map_err(|e| format!("certificate: {e}"))?;
        Some(tokio_rustls::TlsAcceptor::from(tls::server_config(&data).map_err(|e| format!("certificate: {e}"))?))
    } else {
        None
    };
    let origin = config::public_origin(&data, a.get("public-origin"))?;
    let webauthn = cache_server::keys::build_webauthn(origin.as_deref())?;
    match (&origin, &webauthn) {
        (_, Some(_)) => eprintln!("security keys are on for {}", origin.as_deref().unwrap_or("")),
        (None, None) => eprintln!("security keys are off: set --public-origin https://your-host-name to turn them on"),
        _ => {}
    }
    let auth = Auth::load(&data, use_tls).map_err(|e| format!("auth.json: {e}"))?.with_webauthn(webauthn);
    if !auth.has_password() {
        eprintln!("no password is set: nobody can sign in. Run: cache set-password --data {}", data.display());
    }

    let install_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_default();
    let (helper_name, lib_name) = if cfg!(windows) { ("cache-core-helper.exe", "cache_search.dll") } else { ("cache-core-helper", "libcache_search.so") };
    let helper_exe = a.get("helper").map(PathBuf::from).unwrap_or_else(|| install_dir.join("helper").join(helper_name));
    let embed_lib_name = if cfg!(windows) { "cache_llama.dll" } else { "libcache_llama.so" };
    let embed_lib = a.get("embed-lib").map(PathBuf::from).unwrap_or_else(|| install_dir.join("lib").join(embed_lib_name));
    let core_lib = a.get("core-lib").map(PathBuf::from).unwrap_or_else(|| install_dir.join("lib").join(lib_name));
    let mut helper_cfg = HelperConfig::new(helper_exe, core_lib, data.join("sources.json"));
    if let Some(shim) = a.get("valhalla-shim") {
        helper_cfg.shim = PathBuf::from(shim);
    }
    helper_cfg.app_dirs = Some((data.join("app").join("support"), data.join("app").join("docs")));

    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async move {
        let helper = Helper::start(helper_cfg).await;
        let library = Library::new(data.clone(), Some(helper.clone()));
        // The text embedder (bge-m3): the model is fetched on first need; a loaded model is let go when idle.
        let llm = cache_server::llm::LlmService::new(data.clone(), embed_lib.clone(), cache_server::embed::ModelSpec::bge_m3().file_name);
        let embed = cache_server::embed::EmbedService::new(data.clone(), embed_lib);
        let reaper = embed.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(15));
            loop {
                tick.tick().await;
                reaper.reap_idle(cache_server::embed::IDLE);
            }
        });
        // The library builder: books from PDFs, one at a time, and the drop folder. Its threads keep going with no browser open.
        let build = cache_server::libbuild::BuildService::new(data.clone(), library.clone(), Arc::new(embed.clone()), Default::default());
        build.start();
        let app = Arc::new(App { auth: Arc::new(auth), helper: Some(helper.clone()), web, library, embed, llm, build });
        let listener = tokio::net::TcpListener::bind(listen).await.map_err(|e| format!("binding {listen}: {e}"))?;
        let scheme = if use_tls { "https" } else { "http" };
        eprintln!("listening on {scheme}://{listen}/");
        let stop = shutdown();
        tokio::pin!(stop);
        loop {
            tokio::select! {
                _ = &mut stop => break,
                accepted = listener.accept() => {
                    let Ok((tcp, _)) = accepted else { continue };
                    let (app, acceptor) = (app.clone(), tls_config.clone());
                    tokio::spawn(async move {
                        match acceptor {
                            Some(t) => match t.accept(tcp).await {
                                Ok(s) => serve_connection(app, s).await,
                                Err(e) => eprintln!("TLS handshake failed: {e}"),
                            },
                            None => serve_connection(app, tcp).await,
                        }
                    });
                }
            }
        }
        // stopped on purpose: a book in the middle of being built is not counted as having crashed the service
        app.build.shutdown();
        helper.shutdown().await;
        Ok::<(), String>(())
    })
}

/// Resolves when the process is asked to stop (Ctrl-C, or SIGTERM from systemd).
async fn shutdown() {
    #[cfg(unix)]
    {
        let mut term = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(t) => t,
            Err(_) => return std::future::pending().await,
        };
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let result = match argv.first().map(String::as_str) {
        Some("--version" | "-V" | "version") => {
            println!("cache {VERSION}");
            return;
        }
        // Hidden: the server re-runs itself as this to read one PDF, so a PDF that crashes MuPDF takes down only this process.
        Some("extract-pdf") => std::process::exit(cache_builder::isolate::child_main()),
        // Hidden: the helper runs this on each PDF inside a ZIM to index it headless (builder/src/pdf_text.rs).
        Some("pdf-text") => std::process::exit(cache_builder::pdf_text::child_main(&argv[1..])),
        Some("serve") => serve(&argv[1..]),
        Some("set-password") => set_password(&argv[1..]),
        Some("keys") => keys(&argv[1..]),
        _ => Err("a command is required".to_string()),
    };
    if let Err(m) = result {
        let _ = writeln!(std::io::stderr(), "cache: {m}\n{USAGE}");
        std::process::exit(1);
    }
}
