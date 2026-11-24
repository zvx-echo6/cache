//! The file store as the sync engine uses it: [`cache_store`]'s blocking calls behind async ones, shaped after the iroh-blobs calls
//! they replace (step 6a), so each call site changed one for one.

use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use cache_store::{ExportMode, Hash, ImportMode, Status, Store};

#[derive(Clone)]
pub struct Blobs(Store);

impl Blobs {
    pub fn new(s: Store) -> Blobs {
        Blobs(s)
    }

    /// The store itself, for the iroh bridge and the move.
    pub fn raw(&self) -> &Store {
        &self.0
    }

    async fn run<T: Send + 'static>(&self, f: impl FnOnce(&Store) -> cache_store::Result<T> + Send + 'static) -> Result<T> {
        let s = self.0.clone();
        Ok(tokio::task::spawn_blocking(move || f(&s)).await.map_err(|e| anyhow!("{e}"))??)
    }

    /// The whole file is readable now.
    pub async fn is_complete(&self, hash: Hash) -> bool {
        self.run(move |s| s.status(&hash)).await.map(|st| matches!(st, Status::Complete { .. })).unwrap_or(false)
    }

    pub async fn set_tag(&self, name: &[u8], hash: Hash) -> Result<()> {
        let name = name.to_vec();
        self.run(move |s| s.set_tag(&name, &hash)).await
    }

    pub async fn delete_tag(&self, name: &[u8]) -> Result<bool> {
        let name = name.to_vec();
        self.run(move |s| s.delete_tag(&name)).await
    }

    /// The names of the tags that start with `prefix`.
    pub async fn tag_names(&self, prefix: &[u8]) -> Result<Vec<Vec<u8>>> {
        let prefix = prefix.to_vec();
        Ok(self.run(move |s| s.tags_with_prefix(&prefix)).await?.into_iter().map(|(n, _)| n).collect())
    }

    /// Records the file at `path` in place and tags it, in one step.
    pub async fn add_path_ref_tagged(&self, path: PathBuf, tag: &[u8]) -> Result<Hash> {
        let tag = tag.to_vec();
        self.run(move |s| s.add_path_tagged(&path, ImportMode::Reference, &tag).map(|a| a.hash)).await
    }

    /// Copies the file at `path` into the store. The hash is held against garbage collection until the returned value is dropped.
    pub async fn add_path_copy_held(&self, path: &Path) -> Result<cache_store::Added> {
        let path = path.to_path_buf();
        self.run(move |s| s.add_path(&path, ImportMode::Copy)).await
    }

    /// Writes the file at `target`; the store's own copy moves out to it when it can (it then keeps the file there).
    pub async fn export_move(&self, hash: Hash, target: PathBuf) -> Result<u64> {
        self.run(move |s| s.export(&hash, &target, ExportMode::Move).map(|e| e.size)).await
    }

    pub async fn get_bytes(&self, hash: Hash) -> Result<Vec<u8>> {
        self.run(move |s| s.get_bytes(&hash)).await
    }

    pub async fn shutdown(&self) -> Result<()> {
        self.run(|s| s.shutdown()).await
    }
}
