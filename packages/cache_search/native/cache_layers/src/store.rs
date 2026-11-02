//! The merged local tile store of one layer: every tile downloaded for offline use, once, in one SQLite file
//! (`<dir>/store/<layer>.sqlite`), plus the table of downloaded areas.
//!
//! Areas overlap (a city inside a county inside a state), so tiles are not kept per area: a tile is stored once, and
//! an area is a record of what was asked for (shape, zoom range, layer version). Which tiles an area needs is
//! computed from its shape, so deleting an area removes only the tiles no remaining area covers.

use crate::error::{Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use std::path::Path;
use std::sync::Mutex;

pub struct Store {
    conn: Mutex<Connection>,
}

fn lock<T>(m: &Mutex<T>) -> Result<std::sync::MutexGuard<'_, T>> {
    m.lock().map_err(|_| Error::internal("poisoned"))
}

impl Store {
    pub fn open(path: &Path, create: bool) -> Result<Store> {
        if !create && !path.is_file() {
            return Err(Error::not_found("no store"));
        }
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        let fresh = !path.is_file();
        let c = Connection::open(path)?;
        if fresh {
            // must be set before the first table: lets deletes give disk space back (incremental_vacuum)
            let _ = c.pragma_update(None, "auto_vacuum", "INCREMENTAL");
        }
        let _ = c.pragma_update(None, "journal_mode", "WAL");
        let _ = c.pragma_update(None, "synchronous", "NORMAL");
        c.busy_timeout(std::time::Duration::from_secs(30))?;
        c.execute_batch(
            "CREATE TABLE IF NOT EXISTS tiles(z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
               data BLOB NOT NULL, ver TEXT NOT NULL, PRIMARY KEY(z,x,y)) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS staging(z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
               data BLOB NOT NULL, ver TEXT NOT NULL, PRIMARY KEY(z,x,y)) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS areas(id TEXT PRIMARY KEY, state TEXT NOT NULL, meta TEXT NOT NULL);",
        )?;
        Ok(Store { conn: Mutex::new(c) })
    }

    /// The tile's bytes; `None` if not stored or stored as "the source has no tile here".
    pub fn get(&self, z: u8, x: u32, y: u32) -> Result<Option<Vec<u8>>> {
        let c = lock(&self.conn)?;
        let d: Option<Vec<u8>> = c.query_row("SELECT data FROM tiles WHERE z=?1 AND x=?2 AND y=?3", params![z, x, y], |r| r.get(0)).optional()?;
        Ok(d.filter(|d| !d.is_empty()))
    }

    /// (size in bytes, version) of a stored tile (size 0 = known to be empty at the source).
    pub fn info(&self, z: u8, x: u32, y: u32) -> Result<Option<(u64, String)>> {
        let c = lock(&self.conn)?;
        Ok(c.query_row("SELECT length(data), ver FROM tiles WHERE z=?1 AND x=?2 AND y=?3", params![z, x, y], |r| Ok((r.get::<_, i64>(0)? as u64, r.get(1)?))).optional()?)
    }

    pub fn put_batch(&self, table: Table, tiles: &[(u8, u32, u32, Vec<u8>)], ver: &str) -> Result<()> {
        let mut c = lock(&self.conn)?;
        let tx = c.transaction()?;
        {
            let mut st = tx.prepare(&format!("INSERT OR REPLACE INTO {}(z,x,y,data,ver) VALUES(?1,?2,?3,?4,?5)", table.name()))?;
            for (z, x, y, d) in tiles {
                st.execute(params![z, x, y, d, ver])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn staging_has(&self, z: u8, x: u32, y: u32, ver: &str) -> Result<bool> {
        let c = lock(&self.conn)?;
        let v: Option<String> = c.query_row("SELECT ver FROM staging WHERE z=?1 AND x=?2 AND y=?3", params![z, x, y], |r| r.get(0)).optional()?;
        Ok(v.as_deref() == Some(ver))
    }

    /// Forget staged tiles of another version than `ver`.
    pub fn staging_keep_only(&self, ver: &str) -> Result<()> {
        lock(&self.conn)?.execute("DELETE FROM staging WHERE ver<>?1", [ver])?;
        Ok(())
    }

    pub fn staging_clear(&self) -> Result<()> {
        lock(&self.conn)?.execute("DELETE FROM staging", [])?;
        Ok(())
    }

    /// Move the staged tiles into the store in one transaction, and record the area's new manifest in the same one.
    pub fn apply_staging(&self, area: &str, meta: &Value) -> Result<()> {
        let mut c = lock(&self.conn)?;
        let tx = c.transaction()?;
        tx.execute("INSERT OR REPLACE INTO tiles(z,x,y,data,ver) SELECT z,x,y,data,ver FROM staging", [])?;
        tx.execute("DELETE FROM staging", [])?;
        tx.execute("UPDATE areas SET state='complete', meta=?2 WHERE id=?1", params![area, meta.to_string()])?;
        tx.commit()?;
        Ok(())
    }

    pub fn delete_tiles(&self, ids: &[(u8, u32, u32)]) -> Result<u64> {
        let mut c = lock(&self.conn)?;
        let tx = c.transaction()?;
        let mut freed = 0u64;
        {
            let mut sel = tx.prepare("SELECT length(data) FROM tiles WHERE z=?1 AND x=?2 AND y=?3")?;
            let mut del = tx.prepare("DELETE FROM tiles WHERE z=?1 AND x=?2 AND y=?3")?;
            for (z, x, y) in ids {
                if let Some(n) = sel.query_row(params![z, x, y], |r| r.get::<_, i64>(0)).optional()? {
                    freed += n as u64;
                    del.execute(params![z, x, y])?;
                }
            }
        }
        tx.commit()?;
        Ok(freed)
    }

    /// Give freed pages back to the file system.
    pub fn compact(&self) {
        if let Ok(c) = self.conn.lock() {
            let _ = c.execute_batch("PRAGMA incremental_vacuum;");
            let _ = c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
        }
    }

    pub fn total_bytes(&self) -> u64 {
        self.conn.lock().ok().and_then(|c| c.query_row("SELECT COALESCE(SUM(length(data)),0) FROM tiles", [], |r| r.get::<_, i64>(0)).ok()).unwrap_or(0) as u64
    }

    pub fn tile_count(&self) -> u64 {
        self.conn.lock().ok().and_then(|c| c.query_row("SELECT COUNT(*) FROM tiles WHERE length(data)>0", [], |r| r.get::<_, i64>(0)).ok()).unwrap_or(0) as u64
    }

    pub fn staging_count(&self) -> u64 {
        self.conn.lock().ok().and_then(|c| c.query_row("SELECT COUNT(*) FROM staging", [], |r| r.get::<_, i64>(0)).ok()).unwrap_or(0) as u64
    }

    // ---- areas ----

    /// (id, state, manifest) of every area, newest first then by id.
    pub fn areas(&self) -> Result<Vec<(String, String, Value)>> {
        let c = lock(&self.conn)?;
        let mut st = c.prepare("SELECT id, state, meta FROM areas")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))?;
        let mut v: Vec<(String, String, Value)> = rows.filter_map(|r| r.ok()).filter_map(|(i, s, m)| serde_json::from_str(&m).ok().map(|m| (i, s, m))).collect();
        v.sort_by(|a, b| b.2["created"].as_i64().cmp(&a.2["created"].as_i64()).then(a.0.cmp(&b.0)));
        Ok(v)
    }

    pub fn area(&self, id: &str) -> Result<Option<(String, Value)>> {
        let c = lock(&self.conn)?;
        let r: Option<(String, String)> = c.query_row("SELECT state, meta FROM areas WHERE id=?1", [id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
        Ok(r.and_then(|(s, m)| serde_json::from_str(&m).ok().map(|m| (s, m))))
    }

    pub fn put_area(&self, id: &str, state: &str, meta: &Value) -> Result<()> {
        lock(&self.conn)?.execute("INSERT OR REPLACE INTO areas(id,state,meta) VALUES(?1,?2,?3)", params![id, state, meta.to_string()])?;
        Ok(())
    }

    pub fn remove_area(&self, id: &str) -> Result<()> {
        lock(&self.conn)?.execute("DELETE FROM areas WHERE id=?1", [id])?;
        Ok(())
    }

    pub fn clear_all(&self) -> Result<u64> {
        let freed = self.total_bytes();
        let c = lock(&self.conn)?;
        c.execute_batch("DELETE FROM tiles; DELETE FROM staging; DELETE FROM areas;")?;
        Ok(freed)
    }
}

#[derive(Clone, Copy)]
pub enum Table {
    Tiles,
    Staging,
}

impl Table {
    fn name(self) -> &'static str {
        match self {
            Table::Tiles => "tiles",
            Table::Staging => "staging",
        }
    }
}
