//! `cache-server`: `serve` runs the server, `set-password` sets (or resets) the one password.

use cache_search_cli::engine::Core;
use cache_server::auth::{Auth, StoredPassword};
use cache_server::http::{serve_connection, App, CoreCell};
use cache_server::{config, tls};
use std::io::{BufRead, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const USAGE: &str = "usage:
  cache-server serve --data <dir> --web <dir> [--listen 0.0.0.0:8443] [--no-tls]
  cache-server set-password --data <dir>      (reads the password from standard input)";

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
    let a = Args::parse(argv, &["data"], &[])?;
    let data = Path::new(a.req("data")?);
    let password = read_password().map_err(|e| format!("reading the password: {e}"))?;
    let stored = StoredPassword::new(&password).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(data).map_err(|e| format!("{}: {e}", data.display()))?;
    stored.save(&data.join("auth.json")).map_err(|e| format!("writing auth.json: {e}"))?;
    eprintln!("password set; restart cache-server to use it");
    Ok(())
}

fn serve(argv: &[String]) -> Result<(), String> {
    let a = Args::parse(argv, &["data", "web", "listen"], &["no-tls"])?;
    let data = PathBuf::from(a.req("data")?);
    let web = PathBuf::from(a.req("web")?);
    let listen: SocketAddr = a.get("listen").unwrap_or("0.0.0.0:8443").parse().map_err(|e| format!("--listen: {e}"))?;
    let use_tls = !a.flag("no-tls");

    config::make_folders(&data).map_err(|e| format!("{}: {e}", data.display()))?;
    let tls_config = if use_tls {
        tls::ensure_cert(&data).map_err(|e| format!("certificate: {e}"))?;
        Some(tokio_rustls::TlsAcceptor::from(tls::server_config(&data).map_err(|e| format!("certificate: {e}"))?))
    } else {
        None
    };
    let auth = Auth::load(&data, use_tls).map_err(|e| format!("auth.json: {e}"))?;
    if !auth.has_password() {
        eprintln!("no password is set: nobody can sign in. Run: cache-server set-password --data {}", data.display());
    }

    // TODO: the query embedder (hybrid search) comes later. This skeleton opens the core for keyword search only.
    let cfg = config::core_config(&data).map_err(|e| format!("reading the library folders: {e}"))?;
    let mut core = Core::open(&cfg).map_err(|e| format!("opening the core: {}", e.to_json()))?;
    core.wait_ready(Duration::from_secs(600)).map_err(|e| format!("opening the core: {}", e.to_json()))?;
    let app = Arc::new(App { auth: Arc::new(auth), core: Some(Arc::new(Mutex::new(CoreCell(core)))), web });

    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async move {
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
        Some("serve") => serve(&argv[1..]),
        Some("set-password") => set_password(&argv[1..]),
        _ => Err("a command is required".to_string()),
    };
    if let Err(m) = result {
        let _ = writeln!(std::io::stderr(), "cache-server: {m}\n{USAGE}");
        std::process::exit(1);
    }
}
