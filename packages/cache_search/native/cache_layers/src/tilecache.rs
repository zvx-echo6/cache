//! The cache of tiles viewed before: one SQLite file, size-capped, least recently used evicted first.

use crate::error::Result;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::sync::Mutex;

/// A tile the source said does not exist is remembered (as an empty row) for a day.
const EMPTY_TTL_SECS: i64 = 86_400;

pub struct TileCache {
    conn: Mutex<Connection>,
    max_bytes: u64,
    total: Mutex<u64>,
}

pub enum Cached {
    Tile(Vec<u8>),
    /// The source had no tile here when last asked.
    Empty,
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

impl TileCache {
    pub fn open(path: &Path, max_bytes: u64) -> Result<TileCache> {
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        let c = Connection::open(path)?;
        let _ = c.pragma_update(None, "journal_mode", "WAL");
        let _ = c.pragma_update(None, "synchronous", "NORMAL");
        c.busy_timeout(std::time::Duration::from_secs(5))?;
        c.execute_batch(
            "CREATE TABLE IF NOT EXISTS tiles(layer TEXT NOT NULL, z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
               data BLOB NOT NULL, size INTEGER NOT NULL, used INTEGER NOT NULL, fetched INTEGER NOT NULL,
               PRIMARY KEY(layer,z,x,y)) WITHOUT ROWID;
             CREATE INDEX IF NOT EXISTS tiles_used ON tiles(used);",
        )?;
        let total: i64 = c.query_row("SELECT COALESCE(SUM(size),0) FROM tiles", [], |r| r.get(0))?;
        Ok(TileCache { conn: Mutex::new(c), max_bytes, total: Mutex::new(total as u64) })
    }

    pub fn get(&self, layer: &str, z: u8, x: u32, y: u32) -> Result<Option<Cached>> {
        let c = self.conn.lock().map_err(|_| crate::Error::internal("poisoned"))?;
        let row: Option<(Vec<u8>, i64)> = c
            .query_row("SELECT data, fetched FROM tiles WHERE layer=?1 AND z=?2 AND x=?3 AND y=?4", params![layer, z, x, y], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?;
        let Some((data, fetched)) = row else { return Ok(None) };
        if data.is_empty() {
            if now() - fetched > EMPTY_TTL_SECS {
                return Ok(None);
            }
            return Ok(Some(Cached::Empty));
        }
        let _ = c.execute("UPDATE tiles SET used=?5 WHERE layer=?1 AND z=?2 AND x=?3 AND y=?4", params![layer, z, x, y, now()]);
        Ok(Some(Cached::Tile(data)))
    }

    pub fn put(&self, layer: &str, z: u8, x: u32, y: u32, data: &[u8]) -> Result<()> {
        let size = data.len() as i64 + 64;
        let (added, evict) = {
            let c = self.conn.lock().map_err(|_| crate::Error::internal("poisoned"))?;
            let old: Option<i64> = c.query_row("SELECT size FROM tiles WHERE layer=?1 AND z=?2 AND x=?3 AND y=?4", params![layer, z, x, y], |r| r.get(0)).optional()?;
            c.execute(
                "INSERT OR REPLACE INTO tiles(layer,z,x,y,data,size,used,fetched) VALUES(?1,?2,?3,?4,?5,?6,?7,?7)",
                params![layer, z, x, y, data, size, now()],
            )?;
            let mut t = self.total.lock().map_err(|_| crate::Error::internal("poisoned"))?;
            *t = (*t + size as u64).saturating_sub(old.unwrap_or(0) as u64);
            (*t, *t > self.max_bytes)
        };
        let _ = added;
        if evict {
            self.evict()?;
        }
        Ok(())
    }

    /// Delete the least recently used tiles until the cache is at 90% of its cap.
    fn evict(&self) -> Result<()> {
        let c = self.conn.lock().map_err(|_| crate::Error::internal("poisoned"))?;
        let mut t = self.total.lock().map_err(|_| crate::Error::internal("poisoned"))?;
        let target = self.max_bytes / 10 * 9;
        while *t > target {
            let mut stmt = c.prepare("SELECT layer,z,x,y,size FROM tiles ORDER BY used ASC LIMIT 200")?;
            let rows: Vec<(String, i64, i64, i64, i64)> = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?.collect::<std::result::Result<_, _>>()?;
            if rows.is_empty() {
                *t = 0;
                break;
            }
            for (l, z, x, y, s) in rows {
                c.execute("DELETE FROM tiles WHERE layer=?1 AND z=?2 AND x=?3 AND y=?4", params![l, z, x, y])?;
                *t = t.saturating_sub(s as u64);
                if *t <= target {
                    break;
                }
            }
        }
        Ok(())
    }

    pub fn clear(&self, layer: Option<&str>) -> Result<u64> {
        let c = self.conn.lock().map_err(|_| crate::Error::internal("poisoned"))?;
        let n = match layer {
            Some(l) => c.execute("DELETE FROM tiles WHERE layer=?1", [l])?,
            None => c.execute("DELETE FROM tiles", [])?,
        };
        let total: i64 = c.query_row("SELECT COALESCE(SUM(size),0) FROM tiles", [], |r| r.get(0))?;
        *self.total.lock().map_err(|_| crate::Error::internal("poisoned"))? = total as u64;
        Ok(n as u64)
    }

    pub fn bytes(&self) -> u64 {
        self.total.lock().map(|t| *t).unwrap_or(0)
    }

    pub fn bytes_for(&self, layer: &str) -> u64 {
        self.conn.lock().ok().and_then(|c| c.query_row("SELECT COALESCE(SUM(size),0) FROM tiles WHERE layer=?1", [layer], |r| r.get::<_, i64>(0)).ok()).unwrap_or(0) as u64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lru_eviction_keeps_recent_tiles() {
        let dir = std::env::temp_dir().join(format!("cl-tc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let c = TileCache::open(&dir.join("t.sqlite"), 10_000).unwrap();
        let blob = vec![7u8; 1000];
        for x in 0..8 {
            c.put("l", 5, x, 0, &blob).unwrap();
        }
        // make tile 0 the most recently used (used has 1 s resolution: bump it past the others)
        {
            let conn = c.conn.lock().unwrap();
            conn.execute("UPDATE tiles SET used = used - 100", []).unwrap();
            conn.execute("UPDATE tiles SET used = used + 100 WHERE x = 0", []).unwrap();
        }
        for x in 8..14 {
            c.put("l", 5, x, 0, &blob).unwrap();
        }
        assert!(c.bytes() <= 10_000, "{}", c.bytes());
        assert!(matches!(c.get("l", 5, 0, 0).unwrap(), Some(Cached::Tile(_))), "recently used tile survived");
        assert!(c.get("l", 5, 1, 0).unwrap().is_none(), "old tile evicted");
        c.put("l", 6, 0, 0, &[]).unwrap();
        assert!(matches!(c.get("l", 6, 0, 0).unwrap(), Some(Cached::Empty)));
        assert!(c.clear(Some("l")).unwrap() > 0);
        assert_eq!(c.bytes(), 0);
        drop(c);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
