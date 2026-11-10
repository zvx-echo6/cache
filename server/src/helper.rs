//! The Dart helper (server/helper): a child process that hosts the app's core dispatcher. The server talks to it over its
//! standard input and output, one JSON line each way (`{"id","op","args"}` in, `{"id","ok",...}` out), one request at a time.
//!
//! `Helper` starts it, waits for `{"ready":true}`, sends `open` with `{"sources": <sources.json, or null>}` (the helper builds the rest of the config on the app folders), and then serializes requests through
//! one lock. If the child dies or its pipe breaks, the request in flight fails with `Err(message)` (the route answers 503
//! `core_unavailable`) and the child is started again in the background with a backoff, with `open` sent again.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;
use tokio::time::timeout;

pub struct HelperConfig {
    /// The helper program.
    pub exe: PathBuf,
    /// The core library (`CACHE_CORE_LIB` for the helper).
    pub core_lib: PathBuf,
    /// `<data>/sources.json`: a JSON array of sources as `SearchCore.open` sends them. Missing means the helper finds the sources
    /// itself (the ZIMs and library folders under the app documents folder).
    pub sources_file: PathBuf,
    /// The app's support and documents folders on the server (`<data>/app/support`, `<data>/app/docs`), handed to the helper as
    /// `CACHE_APP_SUPPORT` and `CACHE_APP_DOCS`. The helper builds the core's whole config on them and serves `fs.*` from them.
    pub app_dirs: Option<(PathBuf, PathBuf)>,
    /// The Valhalla shim (`libvalhalla_shim.so`), handed to the helper as `CACHE_VALHALLA_SHIM`: the full path the core's road
    /// router opens (the core checks it with a plain file test, so a bare library name never routes). Default: [default_shim].
    pub shim: PathBuf,
    /// How long the helper has to print `{"ready":true}`.
    pub ready_timeout: Duration,
    /// How long `open` may take (it can index).
    pub open_timeout: Duration,
    /// Waits before the 1st, 2nd, ... restart; the last one repeats.
    pub backoff: Vec<Duration>,
    /// How long the helper has to exit after its standard input is closed, before it is killed.
    pub stop_wait: Duration,
}

impl HelperConfig {
    pub fn new(exe: PathBuf, core_lib: PathBuf, sources_file: PathBuf) -> HelperConfig {
        HelperConfig {
            exe,
            shim: default_shim(&core_lib),
            core_lib,
            sources_file,
            app_dirs: None,
            ready_timeout: Duration::from_secs(30),
            open_timeout: Duration::from_secs(600),
            backoff: [1, 2, 5, 10].map(Duration::from_secs).to_vec(),
            stop_wait: Duration::from_secs(5),
        }
    }
}

/// The shim's file name on this system.
pub const SHIM_NAME: &str = if cfg!(windows) { "valhalla_shim.dll" } else { "libvalhalla_shim.so" };

/// Where the release puts the shim: next to the core library (`<install>/lib/libvalhalla_shim.so` beside `libcache_search.so`).
pub fn default_shim(core_lib: &Path) -> PathBuf {
    core_lib.parent().map(|d| d.join(SHIM_NAME)).unwrap_or_else(|| PathBuf::from(SHIM_NAME))
}

/// The server's sources: the array in `path`, or `null` when there is no such file (the helper then scans the app folders).
pub fn read_sources(path: &Path) -> Result<Value, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Value::Null),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(v @ Value::Array(_)) => Ok(v),
        Ok(_) => Err(format!("{}: expected a JSON array of sources", path.display())),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

struct Running {
    child: Child,
    stdin: ChildStdin,
    out: Lines<BufReader<ChildStdout>>,
}

impl Running {
    /// Send one request line and read until the reply with the same id.
    async fn exchange(&mut self, id: u64, op: &str, args: Value) -> Result<Value, String> {
        let mut line = json!({"id": id, "op": op, "args": args}).to_string();
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).await.map_err(|e| format!("writing to the helper: {e}"))?;
        self.stdin.flush().await.map_err(|e| format!("writing to the helper: {e}"))?;
        loop {
            let line = match self.out.next_line().await {
                Ok(Some(l)) => l,
                Ok(None) => return Err("the helper closed its output".to_string()),
                Err(e) => return Err(format!("reading from the helper: {e}")),
            };
            match serde_json::from_str::<Value>(&line) {
                Ok(v) if v["id"] == json!(id) => return Ok(v),
                Ok(_) => eprintln!("cache: helper sent a reply for another request; ignored"),
                Err(e) => eprintln!("cache: helper sent a line that is not JSON ({e}); ignored"),
            }
        }
    }
}

struct State {
    run: Option<Running>,
    /// Failures since the last good request; picks the backoff.
    failures: usize,
    /// A restart loop is running.
    restarting: bool,
    /// Why the helper last went down, for the restart log line.
    reason: String,
}

pub struct Helper {
    cfg: HelperConfig,
    state: Mutex<State>,
    next_id: AtomicU64,
    stopping: AtomicBool,
    /// The port of the core's tile server, once asked for (see `tiles`).
    tile_port: std::sync::Mutex<Option<u16>>,
}

fn unavailable(why: impl std::fmt::Display) -> String {
    format!("the core is not available: {why}")
}

impl Helper {
    /// Start the helper. If that fails the error is logged and the restart loop keeps trying; requests get 503 meanwhile.
    pub async fn start(cfg: HelperConfig) -> Arc<Helper> {
        let h = Arc::new(Helper {
            cfg,
            state: Mutex::new(State { run: None, failures: 0, restarting: false, reason: String::new() }),
            next_id: AtomicU64::new(1),
            stopping: AtomicBool::new(false),
            tile_port: std::sync::Mutex::new(None),
        });
        let mut st = h.state.lock().await;
        match h.launch().await {
            Ok(run) => st.run = Some(run),
            Err(e) => {
                eprintln!("cache: starting the helper failed: {e}");
                st.failures = 1;
                st.reason = e;
                h.schedule_restart(&mut st);
            }
        }
        drop(st);
        h
    }

    /// The port the core's tile server listens on (127.0.0.1). Kept after the first answer; [fresh] asks the core again (the helper
    /// may have restarted, which starts a new tile server on another port). The core's `layers server` call starts the server once
    /// and returns its port; it is made here without an `online` option, so the connection setting is not touched.
    pub async fn tile_port(self: &Arc<Self>, fresh: bool) -> Result<u16, String> {
        if !fresh {
            if let Some(p) = *self.tile_port.lock().unwrap() {
                return Ok(p);
            }
        }
        let reply = self.call("layers", json!({"op": "server", "arg": null})).await?;
        if reply["ok"] != json!(true) {
            return Err(unavailable(reply["error"]["message"].as_str().unwrap_or("the layer engine did not start")));
        }
        let port = reply["result"]["port"].as_u64().and_then(|p| u16::try_from(p).ok()).filter(|p| *p != 0).ok_or_else(|| unavailable("the layer engine gave no tile port"))?;
        *self.tile_port.lock().unwrap() = Some(port);
        Ok(port)
    }

    /// Run one op. `Ok` is the helper's whole reply object (`{"id","ok",...}`); `Err` says why the core is unavailable.
    pub async fn call(self: &Arc<Self>, op: &str, args: Value) -> Result<Value, String> {
        let mut st = self.state.lock().await;
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let Some(run) = st.run.as_mut() else { return Err(unavailable("the helper is restarting")) };
        match run.exchange(id, op, args).await {
            Ok(v) => {
                st.failures = 0;
                Ok(v)
            }
            Err(e) => {
                eprintln!("cache: helper failed during {op}: {e}");
                if let Some(mut dead) = st.run.take() {
                    let _ = dead.child.start_kill();
                }
                st.failures += 1;
                st.reason = e.clone();
                self.schedule_restart(&mut st);
                Err(unavailable(e))
            }
        }
    }

    fn schedule_restart(self: &Arc<Self>, st: &mut State) {
        if st.restarting || self.stopping.load(Ordering::Relaxed) {
            return;
        }
        st.restarting = true;
        tokio::spawn(self.clone().restart_loop());
    }

    async fn restart_loop(self: Arc<Self>) {
        loop {
            let (failures, reason) = {
                let st = self.state.lock().await;
                (st.failures.max(1), st.reason.clone())
            };
            let wait = self.cfg.backoff.get(failures - 1).or(self.cfg.backoff.last()).copied().unwrap_or(Duration::from_secs(1));
            eprintln!("cache: restarting the helper in {}s (reason: {reason})", wait.as_secs_f32());
            tokio::time::sleep(wait).await;
            if self.stopping.load(Ordering::Relaxed) {
                return;
            }
            let mut st = self.state.lock().await;
            match self.launch().await {
                Ok(run) => {
                    st.run = Some(run);
                    st.restarting = false;
                    eprintln!("cache: helper restarted");
                    return;
                }
                Err(e) => {
                    st.failures += 1;
                    eprintln!("cache: restarting the helper failed: {e}");
                    st.reason = e;
                }
            }
        }
    }

    /// Spawn the child, wait for ready, send open.
    async fn launch(&self) -> Result<Running, String> {
        let sources = read_sources(&self.cfg.sources_file)?;
        let mut cmd = Command::new(&self.cfg.exe);
        cmd.env("CACHE_CORE_LIB", &self.cfg.core_lib).env("CACHE_VALHALLA_SHIM", &self.cfg.shim);
        // Installs the public-address guard in the core crates the helper hosts (cache_netguard): a tab reaches their network paths
        // through /api/core, and they must not be a way to a LAN or metadata address. Phones never set it.
        cmd.env(cache_netguard::ENV_VAR, cache_netguard::ENV_VALUE);
        if let Some((support, docs)) = &self.cfg.app_dirs {
            cmd.env("CACHE_APP_SUPPORT", support).env("CACHE_APP_DOCS", docs);
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("{}: {e}", self.cfg.exe.display()))?;
        match child.id() {
            Some(pid) => eprintln!("cache: helper started (pid {pid})"),
            None => eprintln!("cache: helper started"),
        }
        let stdin = child.stdin.take().ok_or("no standard input")?;
        let stdout = child.stdout.take().ok_or("no standard output")?;
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(l)) = lines.next_line().await {
                    eprintln!("[helper] {l}");
                }
            });
        }
        let mut run = Running { child, stdin, out: BufReader::new(stdout).lines() };
        let ready = async {
            loop {
                match run.out.next_line().await {
                    Ok(Some(l)) => {
                        if serde_json::from_str::<Value>(&l).is_ok_and(|v| v["ready"] == json!(true)) {
                            return Ok(());
                        }
                    }
                    Ok(None) => return Err("the helper exited before it was ready".to_string()),
                    Err(e) => return Err(format!("reading from the helper: {e}")),
                }
            }
        };
        match timeout(self.cfg.ready_timeout, ready).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err(format!("the helper was not ready within {}s", self.cfg.ready_timeout.as_secs())),
        }
        eprintln!("cache: helper ready");
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let reply = match timeout(self.cfg.open_timeout, run.exchange(id, "open", json!({"sources": sources}))).await {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err("opening the core took too long".to_string()),
        };
        if reply["ok"] != json!(true) {
            return Err(format!("opening the core failed: {}", reply["error"]));
        }
        // The helper builds the config and says what it opened: {"sources": N, "extras": [section names]}.
        let result = &reply["result"];
        let n = result["sources"].as_u64().or_else(|| sources.as_array().map(|a| a.len() as u64)).unwrap_or(0);
        match result["extras"].as_array() {
            Some(x) => {
                let names: Vec<&str> = x.iter().filter_map(Value::as_str).collect();
                eprintln!("cache: core opened ({n} sources; config sections: {})", names.join(", "));
            }
            None => eprintln!("cache: core opened ({n} sources)"),
        }
        Ok(run)
    }

    /// Close the helper's input and wait for it to exit, then kill it.
    pub async fn shutdown(&self) {
        self.stopping.store(true, Ordering::Relaxed);
        let Ok(mut st) = timeout(self.cfg.stop_wait, self.state.lock()).await else { return };
        if let Some(run) = st.run.take() {
            let Running { mut child, stdin, .. } = run;
            drop(stdin);
            if timeout(self.cfg.stop_wait, child.wait()).await.is_err() {
                eprintln!("cache: the helper did not stop; killing it");
                let _ = child.kill().await;
            }
            eprintln!("cache: helper stopped");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shim_is_the_full_path_next_to_the_core_library() {
        let cfg = HelperConfig::new("/opt/cache/helper/cache-core-helper".into(), "/opt/cache/lib/libcache_search.so".into(), "/d/sources.json".into());
        assert_eq!(cfg.shim, PathBuf::from(format!("/opt/cache/lib/{SHIM_NAME}")));
        assert!(cfg.shim.is_absolute());
        assert_eq!(default_shim(Path::new("lib/libcache_search.so")), PathBuf::from("lib").join(SHIM_NAME));
    }
}
