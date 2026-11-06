//! Authenticated local administration for linked-folder identity adoption.
//! This first increment does not invoke the builder or rewrite existing indexes.
use super::{linked_registry::{BrowseMode, LinkedRegistry}, BuildService};
use crate::library::ApiErr;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io, path::{Path, PathBuf}, sync::Mutex};

static REGISTRY_OPS: Mutex<()> = Mutex::new(());

fn error(status: u16, message: impl Into<String>) -> ApiErr {
    ApiErr { status, code: "linked_folder", message: message.into() }
}
fn io_error(e: io::Error) -> ApiErr {
    let status = match e.kind() {
        io::ErrorKind::InvalidInput | io::ErrorKind::InvalidData => 400,
        io::ErrorKind::NotFound => 404,
        io::ErrorKind::PermissionDenied => 403,
        _ => 500,
    };
    error(status, e.to_string())
}
fn valid_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 80 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn library_path(data: &Path, id: &str) -> Result<PathBuf, ApiErr> {
    if !valid_id(id) { return Err(error(400, "invalid library id")); }
    let parent = data.join("app/docs/libraries").canonicalize().map_err(io_error)?;
    let path = parent.join(id);
    if std::fs::symlink_metadata(&path).map_err(io_error)?.file_type().is_symlink() {
        return Err(error(400, "linked-folder target cannot be a symbolic link"));
    }
    let path = path.canonicalize().map_err(io_error)?;
    if path.parent() != Some(parent.as_path()) || !path.join("cache-library.json").is_file() {
        return Err(error(404, "no installed library with that id"));
    }
    Ok(path)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Register {
    id: String,
    label: String,
    #[serde(default)]
    mode: BrowseMode,
    root: PathBuf,
    #[serde(default)]
    exclusions: Vec<PathBuf>,
}

/// Called only after HTTP session authorization, on a blocking worker.
/// Serializes local registry transactions so simultaneous tabs cannot overwrite scan state.
pub fn request(service: &BuildService, method: &str, library: &str, rest: &[String], body: &[u8]) -> Result<Value, ApiErr> {
    let _guard = REGISTRY_OPS.lock().map_err(|_| error(500, "linked-folder registry lock failed"))?;
    let target = library_path(&service.data, library)?;
    let mut registry = LinkedRegistry::open(&target.join(".local"), &target).map_err(io_error)?;
    match (method, rest) {
        ("GET", []) => Ok(json!({
            "local_config": registry.local_config(),
            "capabilities": {"reuse_existing": true, "index_new_pdfs": false, "automatic_checks": false,
                "sync_locations": false, "open_original": false},
        })),
        ("POST", []) => {
            let input: Register = serde_json::from_slice(body).map_err(|e| error(400, e.to_string()))?;
            if input.label.trim().is_empty() || input.label.len() > 200 {
                return Err(error(400, "folder label must contain 1 to 200 bytes"));
            }
            let source = input.root.canonicalize().map_err(io_error)?;
            let cache_data = service.data.canonicalize().map_err(io_error)?;
            if source.starts_with(&cache_data) || cache_data.starts_with(&source) {
                return Err(error(400, "linked originals must not overlap Cache's managed data folder"));
            }
            registry.register_root(&input.id, input.label, input.mode, &source, input.exclusions).map_err(io_error)?;
            Ok(json!({"registered": true, "local_config": registry.local_config()}))
        }
        ("POST", [action]) if action == "check" => {
            // A second check after this interval hashes newly stable files; no false success on a partial copy.
            let report = registry.scan(2_000).map_err(io_error)?;
            Ok(json!({"report": report, "indexing_new_pdfs": false}))
        }
        ("POST", [id, action]) if action == "pause" => {
            registry.pause(id).map_err(io_error)?;
            Ok(json!({"paused": true}))
        }
        ("POST", [id, action]) if action == "resume" => {
            registry.resume(id).map_err(io_error)?;
            Ok(json!({"paused": false}))
        }
        ("DELETE", [id]) => {
            registry.unlink(id).map_err(io_error)?;
            Ok(json!({"unlinked": true, "indexed_books_retained": true}))
        }
        _ => Err(error(404, "no such linked-folder operation")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn imported_library_target_needs_no_builder_metadata() {
        let d = crate::TempDir::new("linked-target");
        let lib = d.0.join("app/docs/libraries/imported");
        std::fs::create_dir_all(&lib).unwrap();
        std::fs::write(lib.join("cache-library.json"), b"{}").unwrap();
        assert_eq!(library_path(&d.0, "imported").unwrap(), lib.canonicalize().unwrap());
        assert!(library_path(&d.0, "../imported").is_err());
        assert!(!d.0.join("build").exists());
    }
    #[cfg(unix)]
    #[test]
    fn target_symlink_cannot_escape_installed_library() {
        let d = crate::TempDir::new("linked-target-symlink");
        let parent = d.0.join("app/docs/libraries");
        let outside = d.0.join("outside");
        std::fs::create_dir_all(&parent).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("cache-library.json"), b"{}").unwrap();
        std::os::unix::fs::symlink(&outside, parent.join("escape")).unwrap();
        assert!(library_path(&d.0, "escape").is_err());
    }
}
