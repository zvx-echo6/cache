//! The `cs` subcommands. Each one reads its flags, makes the core calls and prints the core's JSON.

use crate::args::Args;
use crate::embed::{Embedder, EMBED_DEFAULT_THREADS};
use crate::engine::{job_result, run_job_to_end, ApiError, Conv, Core, Engine};
use crate::server;
use serde_json::{json, Value};
use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const USAGE: &str = "\
cs: command line and HTTP wrapper over the cache_search core

  cs index-zim       --zim <path> --index-dir <dir> [--heap-mb 200]
  cs unpack-library  --snapshot <file> --dir <dir>
  cs index-library   --library <dir> --index-dir <dir> [--settings <cache-library.json>] [--heap-mb 200]
  cs library-manifest --library <dir> [--out <file>]
  cs update-library  --library <dir> --snapshot <file> --manifest <file>
  cs search          --config <sources.json> --query <text> [--k 5] [--offset 0] [--format] [--json] [EMBED] [--open-timeout 600]
  cs read            --config <sources.json> --address <addr> [--max-chars 6000] [--open-timeout 600]
  cs status          --config <sources.json> [--open-timeout 600]
  cs tool <name>     --config <sources.json> [--args '<json>'] [--now <iso8601>] [--lat <deg> --lon <deg> [--accuracy <m>]]
                     [--json] [EMBED] [--open-timeout 600]
                     (web_search needs CACHE_WEB_PROVIDER=kagi and CACHE_WEB_KEY in the environment; CACHE_WEB_BASE_URL
                     replaces Kagi's address, for runs against a local stand-in server)
  cs tool-schemas    [--config <sources.json>] [--open-timeout 600]
  cs places list     --config <sources.json>
  cs places save     --config <sources.json> --place <json {key?,name,lat,lon,label?}>
  cs places delete   --config <sources.json> --key <key>
  cs live-sources    --config <sources.json>
  cs live-fetch      --config <sources.json> --request <json {source,place,api_key?,force?,now?}>
  cs live-get        --config <sources.json> --request <json {source,place,now?}>
  cs video-instances       --config <sources.json>
  cs video-instance-add    --config <sources.json> --request <json {url}>
  cs video-instance-remove --config <sources.json> --request <json {instance,delete_downloads?}>
  cs video-login           --config <sources.json> --request <json {instance,username,password,otp?}>
  cs video-refresh         --config <sources.json> --request <json {instance,refresh_token}>
  cs video-me              --config <sources.json> --request <json {instance,token}>
  cs video-channels        --config <sources.json> --request <json {instance,search?,start?,count?,token?}>
  cs video-list            --config <sources.json> --request <json {instance,channel?,start?,count?,sort?,token?}>
  cs video-search          --config <sources.json> --request <json {instance,query,start?,count?,sort?,token?}>
  cs video-get             --config <sources.json> --request <json {instance,video,token?}>
  cs video-download        --config <sources.json> --instance <id|address> --video <uuid> [--choice lowest|highest|audio|<resolution>] [--token <access token>]
  cs video-downloads       --config <sources.json>
  cs video-delete          --config <sources.json> --request <json {instance,video}>
  cs video-resolve         --config <sources.json> --request <json {video,instance?,offset_s?,token?}>
  cs layers list|refresh --config <sources.json>
  cs layers save     --config <sources.json> --def <json | @file>        (add or edit a user definition)
  cs layers remove   --config <sources.json> --id <layer id>
  cs layers plan     --config <sources.json> --request <json {layer,bbox|polygon,minzoom?,maxzoom?,area?}>   (dry run)
  cs layers download --config <sources.json> --request <json>                    (runs the layer_download job)
  cs layers delete   --config <sources.json> --request <json {layer,area?}>
  cs layers clear-cache --config <sources.json> [--layer <id>]
  cs layers tile     --config <sources.json> --layer <id> --z <z> --x <x> --y <y> [--out <file>]
  cs layers serve    --config <sources.json> [--online true|false]       (the tile server, until stopped)
  cs serve           --config <sources.json> [--listen 127.0.0.1:8433] [--allow-non-loopback] [EMBED] [--open-timeout 600]

  EMBED: --embed-lib <libcache_llama.so> --embed-model <model.gguf> [--embed-sha256 <hex>]
         [--embed-model-id <id>] [--embed-threads 4]

sources.json is the cs_open config JSON (\"user\": {\"db_path\"} for saved places, \"live\": {\"db_path\",\"sources_dir\"} for live data;
the live_data tool is then reached with cs tool live_data; \"video\": {\"dir\"} for the PeerTube video connector). A library entry may carry \"settings_file\": \"<cache-library.json>\" in
place of \"settings\"; the file is read and passed to the core as \"settings\".
Results go to stdout as the core's JSON; errors go to stderr as {\"code\",\"message\"} with exit status 1.";

const EMBED_FLAGS: [&str; 5] = ["embed-lib", "embed-model", "embed-sha256", "embed-model-id", "embed-threads"];

fn usage_err(m: impl Into<String>) -> ApiError {
    ApiError::new("bad_json", m)
}

fn parse(argv: &[String], valued: &[&str], boolean: &[&str], with_embed: bool) -> Result<Args, ApiError> {
    let mut v: Vec<&str> = valued.to_vec();
    if with_embed {
        v.extend(EMBED_FLAGS);
    }
    Args::parse(argv, &v, boolean).map_err(usage_err)
}

/// Read sources.json (the `cs_open` config) and fill each library's `settings` from its `settings_file`, if any.
pub fn load_config(path: &str) -> Result<String, ApiError> {
    let text = std::fs::read_to_string(path).map_err(|e| ApiError::new("io", format!("reading {path}: {e}")))?;
    let mut cfg: Value = serde_json::from_str(&text).map_err(|e| usage_err(format!("{path}: {e}")))?;
    let base = Path::new(path).parent().map(Path::to_path_buf).unwrap_or_default();
    if let Some(sources) = cfg.get_mut("sources").and_then(Value::as_array_mut) {
        for s in sources {
            let Some(obj) = s.as_object_mut() else { continue };
            let Some(f) = obj.remove("settings_file") else { continue };
            let Some(f) = f.as_str() else { return Err(usage_err("settings_file must be a string")) };
            if obj.contains_key("settings") {
                return Err(usage_err("a source has both settings and settings_file"));
            }
            let p = if Path::new(f).is_absolute() { Path::new(f).to_path_buf() } else { base.join(f) };
            obj.insert("settings".into(), read_settings(&p.to_string_lossy())?);
        }
    }
    Ok(cfg.to_string())
}

fn read_settings(path: &str) -> Result<Value, ApiError> {
    let t = std::fs::read_to_string(path).map_err(|e| ApiError::new("io", format!("reading {path}: {e}")))?;
    serde_json::from_str(&t).map_err(|e| usage_err(format!("{path}: {e}")))
}

fn embedder_from(a: &Args) -> Result<Option<Embedder>, ApiError> {
    match (a.get("embed-lib"), a.get("embed-model")) {
        (None, None) => {
            for f in &EMBED_FLAGS[2..] {
                if a.get(f).is_some() {
                    return Err(usage_err(format!("--{f} needs --embed-lib and --embed-model")));
                }
            }
            Ok(None)
        }
        (Some(lib), Some(model)) => {
            let threads = a.num("embed-threads", EMBED_DEFAULT_THREADS).map_err(usage_err)?;
            Embedder::load(lib, model, a.get("embed-model-id"), a.get("embed-sha256"), threads).map(Some)
        }
        _ => Err(usage_err("--embed-lib and --embed-model go together")),
    }
}

fn open_engine(a: &Args) -> Result<Engine, ApiError> {
    let cfg = load_config(a.req("config").map_err(usage_err)?)?;
    open_engine_with(a, &cfg)
}

/// The core opened from `cfg`, with the query embedder (if any) also registered for the core's built-in `search` tool.
fn open_engine_with(a: &Args, cfg: &str) -> Result<Engine, ApiError> {
    let embedder = embedder_from(a)?.map(|e| Arc::new(Mutex::new(e)));
    let mut core = Core::open(cfg)?;
    if let Some(e) = &embedder {
        core.set_query_embedder(e.clone());
    }
    // Web search: on when both variables are set, and the app is then taken to be online.
    let env_set = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    if let (Some(provider), Some(key)) = (env_set("CACHE_WEB_PROVIDER"), env_set("CACHE_WEB_KEY")) {
        match env_set("CACHE_WEB_BASE_URL").filter(|_| provider.eq_ignore_ascii_case("kagi")) {
            // test runs only: Kagi's address replaced by a local stand-in server
            Some(base) => core.set_web_kagi_at(&base, &key, true),
            None => core.set_web(Some(&provider), Some(&key), true)?,
        }
    }
    core.wait_ready(Duration::from_secs(a.num("open-timeout", 600u64).map_err(usage_err)?))?;
    let video_dir = serde_json::from_str::<Value>(cfg).ok().and_then(|v| v["video"]["dir"].as_str().map(str::to_string));
    Ok(Engine { core, embedder, video_dir })
}

/// The current local time, ISO 8601 with offset.
fn now_local() -> String {
    chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

fn print(s: &str) {
    println!("{s}");
    let _ = std::io::stdout().flush();
}

/// Run a job to the end, printing `done/total` to stderr as it changes; prints the final progress JSON.
/// A job that does not finish `done` returns the job's error (the caller prints it to stderr and exits non-zero).
fn run_job(kind: &str, params: Value) -> Result<(), ApiError> {
    let end = run_job_to_end(kind, &params, &mut |l| eprintln!("{l}"))?;
    print(&end.progress);
    end.error.map_or(Ok(()), Err)
}

pub fn index_zim(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["zim", "index-dir", "heap-mb"], &[], false)?;
    run_job(
        "index_zim",
        json!({"zim_path": a.req("zim").map_err(usage_err)?, "index_dir": a.req("index-dir").map_err(usage_err)?,
               "heap_mb": a.num("heap-mb", 200usize).map_err(usage_err)?}),
    )
}

pub fn index_library(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["library", "index-dir", "settings", "heap-mb"], &[], false)?;
    let mut p = json!({"library_path": a.req("library").map_err(usage_err)?, "index_dir": a.req("index-dir").map_err(usage_err)?,
                       "heap_mb": a.num("heap-mb", 200usize).map_err(usage_err)?});
    if let Some(s) = a.get("settings") {
        p["settings"] = read_settings(s)?;
    }
    run_job("index_library", p)
}

/// The core's helper `library::unpack_library` (it has no C ABI function): unpack plus segments manifest.
pub fn unpack_library(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["snapshot", "dir"], &[], false)?;
    let (snap, dir) = (a.req("snapshot").map_err(usage_err)?, a.req("dir").map_err(usage_err)?);
    let n = cache_search::library::unpack_library(Path::new(snap), Path::new(dir))
        .map_err(|e| ApiError::new(e.code.as_str(), e.message))?;
    print(&json!({"dir": dir, "segments": n}).to_string());
    Ok(())
}

/// The library's snapshot manifest, the body to POST to a server's partial snapshot endpoint. Core helper
/// `libupdate::library_manifest` (no C ABI function): it loads the shard READ-WRITE, so run it only while the
/// library is closed (no handle, no running app on that folder).
pub fn library_manifest(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["library", "out"], &[], false)?;
    let lib = a.req("library").map_err(usage_err)?;
    let (json, n) = cache_search::libupdate::library_manifest(Path::new(lib))
        .map_err(|e| ApiError::new(e.code.as_str(), e.message))?;
    match a.get("out") {
        Some(out) => {
            std::fs::write(out, &json).map_err(|e| ApiError::new("io", format!("writing {out}: {e}")))?;
            print(&json!({"out": out, "segments": n}).to_string());
        }
        None => print(&json),
    }
    Ok(())
}

/// An `update_library` job: apply a partial snapshot to a closed library folder.
pub fn update_library(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["library", "snapshot", "manifest"], &[], false)?;
    run_job(
        "update_library",
        json!({"library_path": a.req("library").map_err(usage_err)?, "snapshot_path": a.req("snapshot").map_err(usage_err)?,
               "snapshot_manifest_path": a.req("manifest").map_err(usage_err)?}),
    )
}

pub fn search(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "query", "k", "offset", "open-timeout"], &["format", "json"], true)?;
    let query = a.req("query").map_err(usage_err)?.to_string();
    let options = json!({"k": a.num("k", 5u64).map_err(usage_err)?, "offset": a.num("offset", 0u64).map_err(usage_err)?});
    let mut e = open_engine(&a)?;
    let out = e.search(&query, options)?;
    if !a.flag("format") {
        print(&out);
        return Ok(());
    }
    // A fresh conversation: the numbering the app would produce for a first tool call.
    let v: Value = serde_json::from_str(&out).map_err(|e| ApiError::new("internal", e.to_string()))?;
    let mut conv = Conv::new()?;
    let formatted = conv.format(&v["results"].to_string())?;
    if a.flag("json") {
        print(&formatted);
    } else {
        let f: Value = serde_json::from_str(&formatted).map_err(|e| ApiError::new("internal", e.to_string()))?;
        print(f["tool_message"].as_str().unwrap_or(""));
    }
    Ok(())
}

pub fn read(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "address", "max-chars", "open-timeout"], &[], false)?;
    let mut e = open_engine(&a)?;
    print(&e.core.read(a.req("address").map_err(usage_err)?, a.num("max-chars", 6000i32).map_err(usage_err)?)?);
    Ok(())
}

pub fn status(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "open-timeout"], &[], false)?;
    let mut e = open_engine(&a)?;
    print(&e.core.status()?);
    Ok(())
}

/// One tool call in a fresh conversation (so `read` has no earlier result to open): prints the tool message, then
/// a line `ids <json>` with the numbers the call gave. `--json` prints the core's `{"content","ids"}` instead.
pub fn tool(argv: &[String]) -> Result<(), ApiError> {
    let Some(name) = argv.first().filter(|a| !a.starts_with("--")) else {
        return Err(usage_err("cs tool needs a tool name, e.g. cs tool search --args '{\"query\":\"...\"}'"));
    };
    let a = parse(&argv[1..], &["config", "args", "now", "lat", "lon", "accuracy", "open-timeout"], &["json"], true)?;
    let now = a.get("now").map(str::to_string).unwrap_or_else(now_local);
    let mut e = open_engine(&a)?;
    match (a.get("lat"), a.get("lon")) {
        (None, None) => {
            if a.get("accuracy").is_some() {
                return Err(usage_err("--accuracy needs --lat and --lon"));
            }
        }
        (Some(_), Some(_)) => {
            let (lat, lon) = (a.num("lat", 0f64).map_err(usage_err)?, a.num("lon", 0f64).map_err(usage_err)?);
            e.core.set_location(lat, lon, a.num("accuracy", -1f64).map_err(usage_err)?, &now)?;
        }
        _ => return Err(usage_err("--lat and --lon go together")),
    }
    let mut conv = Conv::new()?;
    let out = e.core.tool(&mut conv, name, a.get("args").unwrap_or("{}"), &now)?;
    if a.flag("json") {
        print(&out);
    } else {
        let v: Value = serde_json::from_str(&out).map_err(|e| ApiError::new("internal", e.to_string()))?;
        print(v["content"].as_str().unwrap_or(""));
        print(&format!("ids {}", v["ids"]));
        if let Some(t) = v.get("timing_ms") {
            eprintln!("timing_ms {t}");
        }
    }
    Ok(())
}

/// The function schemas of the available tools (`--config` is optional: they do not depend on the sources).
pub fn tool_schemas(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "open-timeout"], &[], false)?;
    let cfg = match a.get("config") {
        Some(p) => load_config(p)?,
        None => r#"{"sources":[]}"#.to_string(),
    };
    let mut e = open_engine_with(&a, &cfg)?;
    print(&e.core.tool_schemas()?);
    Ok(())
}

pub fn places(argv: &[String]) -> Result<(), ApiError> {
    let Some(sub) = argv.first() else { return Err(usage_err("cs places needs list, save or delete")) };
    let rest = &argv[1..];
    match sub.as_str() {
        "list" => {
            let a = parse(rest, &["config", "open-timeout"], &[], false)?;
            print(&open_engine(&a)?.core.places_list()?);
        }
        "save" => {
            let a = parse(rest, &["config", "place", "open-timeout"], &[], false)?;
            let p = a.req("place").map_err(usage_err)?.to_string();
            print(&open_engine(&a)?.core.place_save(&p)?);
        }
        "delete" => {
            let a = parse(rest, &["config", "key", "open-timeout"], &[], false)?;
            let k = a.req("key").map_err(usage_err)?.to_string();
            print(&open_engine(&a)?.core.place_delete(&k)?);
        }
        other => return Err(usage_err(format!("unknown cs places subcommand {other:?}"))),
    }
    Ok(())
}

pub fn live_sources(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "open-timeout"], &[], false)?;
    print(&open_engine(&a)?.core.live_sources()?);
    Ok(())
}

pub fn live_fetch(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "request", "open-timeout"], &[], false)?;
    let r = a.req("request").map_err(usage_err)?.to_string();
    print(&open_engine(&a)?.core.live_fetch(&r)?);
    Ok(())
}

pub fn live_get(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "request", "open-timeout"], &[], false)?;
    let r = a.req("request").map_err(usage_err)?.to_string();
    print(&open_engine(&a)?.core.live_get(&r)?);
    Ok(())
}

/// A video call with one JSON request (`--request`), or none.
fn video_call(argv: &[String], f: impl FnOnce(&mut Engine, Option<&str>) -> Result<String, ApiError>, takes_request: bool) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "request", "open-timeout"], &[], false)?;
    let req = if takes_request { Some(a.req("request").map_err(usage_err)?.to_string()) } else { None };
    if !takes_request && a.get("request").is_some() {
        return Err(usage_err("this command takes no --request"));
    }
    let mut e = open_engine(&a)?;
    print(&f(&mut e, req.as_deref())?);
    Ok(())
}

pub fn video_download(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "instance", "video", "choice", "token", "open-timeout"], &[], false)?;
    let mut p = json!({"instance": a.req("instance").map_err(usage_err)?, "video": a.req("video").map_err(usage_err)?});
    if let Some(c) = a.get("choice") {
        p["choice"] = json!(c);
    }
    if let Some(t) = a.get("token") {
        p["token"] = json!(t);
    }
    let e = open_engine(&a)?;
    print(&e.video_download(&p, &mut |l| eprintln!("{l}"))?);
    Ok(())
}

/// A JSON argument: the text itself, or `@file` to read it from a file.
fn json_arg(v: &str) -> Result<String, ApiError> {
    match v.strip_prefix('@') {
        Some(f) => std::fs::read_to_string(f).map_err(|e| ApiError::new("io", format!("reading {f}: {e}"))),
        None => Ok(v.to_string()),
    }
}

/// The JSON `cs layers tile` and `POST /layers/tile` print: what the tile is, without its bytes.
pub fn tile_summary(layer: &str, z: i32, x: i32, y: i32, mime: &str, bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let sha: String = Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect();
    json!({"layer": layer, "z": z, "x": x, "y": y, "empty": bytes.is_empty(), "mime": mime, "len": bytes.len(), "sha256": sha}).to_string()
}

pub fn layers(argv: &[String]) -> Result<(), ApiError> {
    let Some(sub) = argv.first() else { return Err(usage_err("cs layers needs list, refresh, save, remove, plan, download, delete, clear-cache, tile or serve")) };
    let rest = &argv[1..];
    match sub.as_str() {
        "list" => {
            let a = parse(rest, &["config", "open-timeout"], &[], false)?;
            print(&open_engine(&a)?.core.layers_list()?);
        }
        "refresh" => {
            let a = parse(rest, &["config", "open-timeout"], &[], false)?;
            print(&open_engine(&a)?.core.layers_refresh()?);
        }
        "save" => {
            let a = parse(rest, &["config", "def", "open-timeout"], &[], false)?;
            let d = json_arg(a.req("def").map_err(usage_err)?)?;
            print(&open_engine(&a)?.core.layers_save(&d)?);
        }
        "remove" => {
            let a = parse(rest, &["config", "id", "open-timeout"], &[], false)?;
            let id = a.req("id").map_err(usage_err)?.to_string();
            print(&open_engine(&a)?.core.layers_remove(&id)?);
        }
        "plan" => {
            let a = parse(rest, &["config", "request", "open-timeout"], &[], false)?;
            let r = json_arg(a.req("request").map_err(usage_err)?)?;
            print(&open_engine(&a)?.core.layers_plan(&r)?);
        }
        "download" => {
            let a = parse(rest, &["config", "request", "open-timeout"], &[], false)?;
            let r: Value = serde_json::from_str(&json_arg(a.req("request").map_err(usage_err)?)?).map_err(|e| usage_err(format!("request: {e}")))?;
            let mut e = open_engine(&a)?;
            let out = e.core.layers_download(&r, &mut |p| {
                let v: Value = serde_json::from_str(p).unwrap_or(Value::Null);
                eprintln!("{} {}/{} {} bytes", v["state"].as_str().unwrap_or("?"), v["done"], v["total"], v["detail"]["bytes"]);
            })?;
            print(&out);
        }
        "delete" => {
            let a = parse(rest, &["config", "request", "open-timeout"], &[], false)?;
            let r = json_arg(a.req("request").map_err(usage_err)?)?;
            print(&open_engine(&a)?.core.layers_delete(&r)?);
        }
        "clear-cache" => {
            let a = parse(rest, &["config", "layer", "open-timeout"], &[], false)?;
            print(&open_engine(&a)?.core.layers_clear_cache(a.get("layer"))?);
        }
        "tile" => {
            let a = parse(rest, &["config", "layer", "z", "x", "y", "out", "open-timeout"], &[], false)?;
            let layer = a.req("layer").map_err(usage_err)?.to_string();
            let (z, x, y): (i32, i32, i32) = (a.num("z", -1).map_err(usage_err)?, a.num("x", -1).map_err(usage_err)?, a.num("y", -1).map_err(usage_err)?);
            let (mime, bytes) = open_engine(&a)?.core.layers_tile(&layer, z, x, y)?;
            if let Some(o) = a.get("out") {
                std::fs::write(o, &bytes).map_err(|e| ApiError::new("io", format!("writing {o}: {e}")))?;
            }
            print(&tile_summary(&layer, z, x, y, &mime, &bytes));
        }
        "serve" => {
            let a = parse(rest, &["config", "online", "open-timeout"], &[], false)?;
            let opts = a.get("online").map(|v| json!({"online": v == "true"}).to_string());
            let mut e = open_engine(&a)?;
            print(&e.core.layers_server(opts.as_deref())?);
            loop {
                std::thread::sleep(Duration::from_secs(3600));
            }
        }
        other => return Err(usage_err(format!("unknown cs layers subcommand {other:?}"))),
    }
    Ok(())
}

pub fn serve(argv: &[String]) -> Result<(), ApiError> {
    let a = parse(argv, &["config", "listen", "open-timeout"], &["allow-non-loopback"], true)?;
    let listen = a.get("listen").unwrap_or("127.0.0.1:8433").to_string();
    server::check_listen(&listen, a.flag("allow-non-loopback"))?;
    let e = open_engine(&a)?;
    server::run(e, &listen)
}

/// Print an error as one JSON line on stderr. Writes with `writeln!` and ignores a failed write: `eprintln!`
/// panics when stderr cannot be written, which would turn the report itself into a second failure.
pub fn report_error(e: &ApiError) {
    let mut err = std::io::stderr().lock();
    let _ = writeln!(err, "{}", e.to_json());
    let _ = err.flush();
}

/// Dispatch. Returns the process exit status.
pub fn main_with(argv: Vec<String>) -> i32 {
    let Some(cmd) = argv.first() else {
        eprintln!("{USAGE}");
        return 2;
    };
    let rest = &argv[1..];
    let r = match cmd.as_str() {
        "index-zim" => index_zim(rest),
        "unpack-library" => unpack_library(rest),
        "index-library" => index_library(rest),
        "library-manifest" => library_manifest(rest),
        "update-library" => update_library(rest),
        "search" => search(rest),
        "read" => read(rest),
        "status" => status(rest),
        "tool" => tool(rest),
        "tool-schemas" => tool_schemas(rest),
        "places" => places(rest),
        "live-sources" => live_sources(rest),
        "live-fetch" => live_fetch(rest),
        "live-get" => live_get(rest),
        "video-instances" => video_call(rest, |e, _| e.core.video_instances(), false),
        "video-instance-add" => video_call(rest, |e, r| e.core.video_instance_add(r.unwrap()), true),
        "video-instance-remove" => video_call(rest, |e, r| e.core.video_instance_remove(r.unwrap()), true),
        "video-login" => video_call(rest, |e, r| e.core.video_login(r.unwrap()), true),
        "video-refresh" => video_call(rest, |e, r| e.core.video_refresh(r.unwrap()), true),
        "video-me" => video_call(rest, |e, r| e.core.video_me(r.unwrap()), true),
        "video-channels" => video_call(rest, |e, r| e.core.video_channels(r.unwrap()), true),
        "video-list" => video_call(rest, |e, r| e.core.video_list(r.unwrap()), true),
        "video-search" => video_call(rest, |e, r| e.core.video_search(r.unwrap()), true),
        "video-get" => video_call(rest, |e, r| e.core.video_get(r.unwrap()), true),
        "video-download" => video_download(rest),
        "video-downloads" => video_call(rest, |e, _| e.core.video_downloads(), false),
        "video-delete" => video_call(rest, |e, r| e.core.video_delete(r.unwrap()), true),
        "video-resolve" => video_call(rest, |e, r| e.core.video_resolve(r.unwrap()), true),
        "layers" => layers(rest),
        "serve" => serve(rest),
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            return 0;
        }
        other => {
            eprintln!("unknown subcommand {other:?}\n\n{USAGE}");
            return 2;
        }
    };
    match r {
        Ok(()) => 0,
        Err(e) => {
            report_error(&e);
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn done_is_ok() {
        assert!(job_result(&json!({"state": "done", "done": 3, "total": 3, "error": null})).is_ok());
    }

    #[test]
    fn a_failed_job_carries_its_code_and_message() {
        let e = job_result(&json!({"state": "failed", "done": 1, "total": 9, "error": {"code": "io", "message": "disk full"}})).unwrap_err();
        assert_eq!(e.code, "io");
        assert_eq!(e.message, "job failed: disk full");
    }

    #[test]
    fn a_panic_in_a_job_thread_is_reported_with_its_text() {
        let e = job_result(&json!({"state": "failed", "done": 0, "total": 0, "error": {"code": "internal", "message": "panic: boom"}})).unwrap_err();
        assert_eq!(e.code, "internal");
        assert!(e.message.contains("panic: boom"), "{}", e.message);
    }

    #[test]
    fn failed_or_cancelled_without_an_error_is_still_an_error() {
        let e = job_result(&json!({"state": "failed", "done": 0, "total": 0, "error": null})).unwrap_err();
        assert_eq!(e.code, "internal");
        assert!(e.message.contains("failed"), "{}", e.message);
        let e = job_result(&json!({"state": "cancelled", "done": 0, "total": 0, "error": null})).unwrap_err();
        assert_eq!(e.code, "cancelled");
        assert!(e.message.contains("cancelled"), "{}", e.message);
    }
}
