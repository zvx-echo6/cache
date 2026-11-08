//! The PDFs inside a ZIM (entries whose mime type is application/pdf): what `cs_zim_pdfs` answers and the `zim_pdfs` job
//! makes, `{"zim_uuid","zim_name","pdfs":[{"path","title","size"}]}` sorted by path.
//!
//! Finding them means looking at every directory entry: a ZIM has no index by mime type. Build 46 did that with a full parse of
//! each entry (its path and title read and allocated) through the ZIM's whole-file mapping, on the core's one worker: 15 s at
//! every start for the 30 M entries of a full Wikipedia, with every search, read and weather call waiting behind it, and the
//! process went from about 430 MB to 2.6 GB resident, because every page of the directory it read stayed mapped (the pages are
//! the file's, but they count as the process's memory, and the chat model was then not loaded for want of free memory).
//!
//! Now:
//! - a ZIM whose mime list has no application/pdf has none, and nothing is read (a full Wikipedia has none);
//! - otherwise the pass reads only the first four bytes of each entry (mime type and namespace), through bounded mapping
//!   windows (a few MiB mapped at any time, see the zim crate's `Zim::new_windowed`), and parses only the PDFs' entries;
//! - the app runs it as a `zim_pdfs` job on a thread of its own and keeps the answer per ZIM uuid (a ZIM never changes), so it
//!   runs once per ZIM, never on the worker.

use crate::error::{Error, Result};
use serde_json::{json, Value};
use std::path::Path;
use zim::Zim;

/// The mime type ids of `z` that are PDF ("application/pdf", any parameters).
pub fn pdf_mime_ids(z: &Zim) -> Vec<u16> {
    z.mime_table
        .iter()
        .enumerate()
        .filter(|(_, m)| m.to_ascii_lowercase().starts_with("application/pdf"))
        .filter_map(|(i, _)| u16::try_from(i).ok())
        .collect()
}

/// The ZIM's uuid as the core writes it (lowercase).
pub fn uuid_of(z: &Zim) -> String {
    z.header.uuid.to_string().to_ascii_lowercase()
}

/// The metadata Name of the ZIM, else its file name without the extension.
fn name_of(z: &Zim, path: &Path) -> String {
    let meta = z
        .metadata("Name")
        .ok()
        .flatten()
        .and_then(|c| c.to_vec().ok())
        .map(|b| String::from_utf8_lossy(&b).trim().to_string())
        .filter(|s| !s.is_empty());
    meta.unwrap_or_else(|| path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default())
}

/// Opens the ZIM at `path` through bounded windows (never a whole-file mapping) for a pass over its directory.
pub fn open_windowed(path: &Path) -> Result<Zim> {
    Zim::new_windowed(path).map_err(|e| {
        let mut e = Error::from(e);
        e.message = format!("{}: {}", path.display(), e.message);
        e
    })
}

/// Lists the PDFs of the ZIM at `path`. `name` is the ZIM's name when the caller knows it (else the metadata Name). `progress`
/// gets (entries looked at, entries); `None` when `cancelled` said stop.
pub fn list_path(path: &Path, name: Option<&str>, progress: &dyn Fn(u64, u64), cancelled: &dyn Fn() -> bool) -> Result<Option<Value>> {
    let z = open_windowed(path)?;
    let name = match name {
        Some(n) => n.to_string(),
        None => name_of(&z, path),
    };
    list(&z, &name, progress, cancelled)
}

/// Lists the PDFs of `z` (see the module).
pub fn list(z: &Zim, name: &str, progress: &dyn Fn(u64, u64), cancelled: &dyn Fn() -> bool) -> Result<Option<Value>> {
    let total = u64::from(z.header.article_count);
    let ids = pdf_mime_ids(z);
    let mut pdfs: Vec<(String, String, u64)> = Vec::new();
    if !ids.is_empty() {
        // content namespaces: `C` (new scheme) and `A` (old scheme)
        let keep = |mime: u16, ns: u8| (ns == b'C' || ns == b'A') && ids.contains(&mime);
        let mut go_on = |done: u32| {
            progress(u64::from(done), total);
            !cancelled()
        };
        let Some(found) = z.scan_dirents(&keep, &mut go_on)? else { return Ok(None) };
        let mut cands: Vec<(u32, u32, String, String)> = Vec::with_capacity(found.len());
        for idx in found {
            let Ok(e) = z.get_by_url_index(idx) else { continue };
            let Some(zim::Target::Cluster(cluster, blob)) = e.target else { continue };
            let title = if e.title.is_empty() { e.url.clone() } else { e.title.clone() };
            cands.push((cluster, blob, e.url, title));
        }
        // sizes by cluster, so each cluster is read once
        cands.sort_by_key(|c| (c.0, c.1));
        let mut i = 0;
        while i < cands.len() {
            if cancelled() {
                return Ok(None);
            }
            let c0 = cands[i].0;
            let mut j = i;
            while j < cands.len() && cands[j].0 == c0 {
                j += 1;
            }
            let cluster = z.get_cluster(c0).ok();
            let guard = cluster.as_ref().and_then(|c| c.read().ok());
            for c in &cands[i..j] {
                let size = guard.as_ref().and_then(|g| g.blob(c.1).ok()).map(|b| b.len() as u64).unwrap_or(0);
                pdfs.push((c.2.clone(), c.3.clone(), size));
            }
            i = j;
        }
        pdfs.sort();
    }
    progress(total, total);
    Ok(Some(json!({
        "zim_uuid": uuid_of(z),
        "zim_name": name,
        "pdfs": pdfs.into_iter().map(|(path, title, size)| json!({"path": path, "title": title, "size": size})).collect::<Vec<_>>(),
    })))
}
