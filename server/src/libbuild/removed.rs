//! Removed: where a file goes when Cache does not keep it (an exact copy, a worse copy of a book already there, an older copy that
//! was replaced). Files wait here 30 days, listed with the reason, and can be put back; then they are deleted. The manifest is
//! `build/removed/manifest.json`, the files are `build/removed/files/<id>.pdf`.

use super::{dropdir, err, lock, BuildService};
use crate::library::{now_rfc3339, random_hex, ApiErr};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// How long a removed file is kept.
pub const KEEP_SECS: u64 = 30 * 24 * 3600;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RemovedEntry {
    pub id: String,
    /// The file's name as the person knows it.
    pub file: String,
    pub original_path: String,
    pub reason: String,
    pub date: String,
    pub epoch: u64,
    pub size: u64,
    #[serde(default)]
    pub library_id: String,
    /// Where it came from: `drop` (the drop folder), `upload`, or `source` (a device copy of a book).
    pub kind: String,
}

pub(crate) fn load(data: &Path) -> Vec<RemovedEntry> {
    std::fs::read_to_string(data.join("build/removed/manifest.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

impl BuildService {
    fn removed_files(&self) -> PathBuf {
        self.data.join("build/removed/files")
    }

    fn save_removed(&self, list: &[RemovedEntry]) {
        if let Err(e) = super::write_json(&self.data.join("build/removed/manifest.json"), &list) {
            eprintln!("cache-server: writing the Removed manifest: {e}");
        }
    }

    /// Move `src` into Removed with the reason. The id of the entry.
    pub(crate) fn to_removed(&self, src: &Path, file: &str, reason: &str, kind: &str, library_id: &str) -> Result<String, String> {
        let dir = self.removed_files();
        std::fs::create_dir_all(&dir).map_err(|e| format!("making the Removed folder: {e}"))?;
        let id = random_hex();
        let dest = dir.join(format!("{id}.pdf"));
        let size = std::fs::metadata(src).map(|m| m.len()).unwrap_or(0);
        if std::fs::rename(src, &dest).is_err() {
            std::fs::copy(src, &dest).map_err(|e| format!("moving the file to Removed: {e}"))?;
            let _ = std::fs::remove_file(src);
        }
        let entry = RemovedEntry {
            id: id.clone(),
            file: file.to_string(),
            original_path: src.to_string_lossy().into_owned(),
            reason: reason.to_string(),
            date: now_rfc3339(),
            epoch: super::epoch(),
            size,
            library_id: library_id.to_string(),
            kind: kind.to_string(),
        };
        let mut list = lock(&self.removed);
        list.push(entry);
        self.save_removed(&list);
        Ok(id)
    }

    /// `GET /api/build/removed`: newest first.
    pub fn removed_view(&self) -> Value {
        let list = lock(&self.removed);
        let items: Vec<Value> = list
            .iter()
            .rev()
            .map(|e| {
                json!({
                    "id": e.id, "file": e.file, "original_path": e.original_path, "reason": e.reason, "date": e.date, "size": e.size,
                    "library_id": e.library_id, "kind": e.kind, "delete_after": e.epoch + KEEP_SECS,
                })
            })
            .collect();
        json!({"keep_days": 30, "count": items.len(), "items": items})
    }

    /// `POST /api/build/removed/{id}/restore`: the file goes back into the drop folder's `ingest/`, where it is looked at again
    /// like any new file.
    pub fn restore_removed(&self, id: &str) -> Result<Value, ApiErr> {
        let entry = {
            let list = lock(&self.removed);
            list.iter().find(|e| e.id == id).cloned().ok_or_else(|| err(404, "not_found", "no such removed file"))?
        };
        let src = self.removed_files().join(format!("{}.pdf", entry.id));
        if !src.is_file() {
            return Err(err(409, "gone", "That file is no longer in Removed."));
        }
        let ingest = PathBuf::from(self.drop_folder()).join("ingest");
        let name = if entry.file.to_lowercase().ends_with(".pdf") { entry.file.clone() } else { format!("{}.pdf", entry.file) };
        let put = dropdir::move_unique(&src, &ingest, &name).map_err(|e| err(500, "server_error", format!("Could not put the file back: {e}")))?;
        {
            let mut list = lock(&self.removed);
            list.retain(|e| e.id != id);
            self.save_removed(&list);
        }
        self.poke_drop();
        Ok(json!({"restored": true, "id": id, "file": put, "folder": ingest.to_string_lossy()}))
    }

    /// `DELETE /api/build/removed/{id}` (or all of them when `id` is empty): delete for good.
    pub fn delete_removed(&self, id: &str) -> Result<Value, ApiErr> {
        let mut list = lock(&self.removed);
        if !id.is_empty() && !list.iter().any(|e| e.id == id) {
            return Err(err(404, "not_found", "no such removed file"));
        }
        let (gone, keep): (Vec<RemovedEntry>, Vec<RemovedEntry>) = list.drain(..).partition(|e| id.is_empty() || e.id == id);
        for e in &gone {
            let _ = std::fs::remove_file(self.removed_files().join(format!("{}.pdf", e.id)));
        }
        *list = keep;
        self.save_removed(&list);
        Ok(json!({"deleted": gone.len()}))
    }

    /// Delete what has waited 30 days. Called at start-up and once a day. The number deleted.
    pub fn purge_removed(&self, now_epoch: u64) -> usize {
        let mut list = lock(&self.removed);
        let (old, keep): (Vec<RemovedEntry>, Vec<RemovedEntry>) = list.drain(..).partition(|e| now_epoch.saturating_sub(e.epoch) >= KEEP_SECS);
        for e in &old {
            let _ = std::fs::remove_file(self.removed_files().join(format!("{}.pdf", e.id)));
        }
        *list = keep;
        if !old.is_empty() {
            self.save_removed(&list);
        }
        // a file nothing lists (a crash between the move and the manifest) is kept as it is: it costs only disk and is visible
        old.len()
    }
}
