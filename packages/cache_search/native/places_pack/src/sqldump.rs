//! Reads a MediaWiki SQL dump (`INSERT INTO `table` VALUES (...),(...);` lines) without a database. Column names come
//! from the dump's own CREATE TABLE statement, so the code looks fields up by name and not by position.

use std::io::BufRead;

/// One field of a row as it sits in the dump: the raw bytes, and whether it was a quoted string.
#[derive(Clone, Copy)]
pub struct Field<'a> {
    pub raw: &'a [u8],
    pub quoted: bool,
}

impl Field<'_> {
    pub fn i64(&self) -> Option<i64> {
        std::str::from_utf8(self.raw).ok()?.parse().ok()
    }
    pub fn f64(&self) -> Option<f64> {
        std::str::from_utf8(self.raw).ok()?.parse().ok()
    }
    /// The string with MySQL escapes resolved. NULL is None.
    pub fn string(&self) -> Option<String> {
        if !self.quoted {
            return if self.raw == b"NULL" { None } else { Some(String::from_utf8_lossy(self.raw).into_owned()) };
        }
        let mut out = Vec::with_capacity(self.raw.len());
        let mut i = 0;
        while i < self.raw.len() {
            let b = self.raw[i];
            if b == b'\\' && i + 1 < self.raw.len() {
                i += 1;
                out.push(match self.raw[i] {
                    b'n' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    b'0' => 0,
                    b'b' => 8,
                    b'Z' => 26,
                    c => c,
                });
            } else {
                out.push(b);
            }
            i += 1;
        }
        Some(String::from_utf8_lossy(&out).into_owned())
    }
    pub fn is(&self, s: &str) -> bool {
        self.quoted && !self.raw.contains(&b'\\') && self.raw == s.as_bytes()
    }
}

pub struct Dump<R: BufRead> {
    reader: R,
    table_prefix: Vec<u8>,
    pending: Vec<u8>,
    pub columns: Vec<String>,
}

impl<R: BufRead> Dump<R> {
    /// Reads up to the first INSERT of `table`, collecting its column names.
    pub fn open(mut reader: R, table: &str) -> Result<Dump<R>, String> {
        let prefix = format!("INSERT INTO `{table}` VALUES").into_bytes();
        let create = format!("CREATE TABLE `{table}`");
        let (mut columns, mut in_create) = (Vec::new(), false);
        let mut line = Vec::new();
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line).map_err(|e| e.to_string())? == 0 {
                return Err(format!("dump has no rows for table {table}"));
            }
            if line.starts_with(&prefix) {
                break;
            }
            let text = String::from_utf8_lossy(&line);
            if text.starts_with(&create) {
                in_create = true;
            } else if in_create {
                let t = text.trim_start();
                if let Some(rest) = t.strip_prefix('`') {
                    if let Some(end) = rest.find('`') {
                        columns.push(rest[..end].to_string());
                    }
                } else if t.starts_with(')') {
                    in_create = false;
                }
            }
        }
        if columns.is_empty() {
            return Err(format!("dump has no CREATE TABLE for {table}"));
        }
        Ok(Dump { reader, table_prefix: prefix, pending: line, columns })
    }

    pub fn col(&self, name: &str) -> Result<usize, String> {
        self.columns.iter().position(|c| c == name).ok_or_else(|| format!("dump column {name} is missing (have {:?})", self.columns))
    }

    /// Calls `f` for every row.
    pub fn for_each(&mut self, mut f: impl FnMut(&[Field])) -> Result<(), String> {
        let mut line = std::mem::take(&mut self.pending);
        let mut in_insert = false;
        loop {
            if line.starts_with(&self.table_prefix) {
                // Either `VALUES (row),(row);` on one line, or `VALUES` and then one row per line.
                in_insert = true;
                let rest = &line[self.table_prefix.len()..];
                let rest = rest.strip_prefix(b" ").unwrap_or(rest);
                if rest.first() == Some(&b'(') {
                    parse_line(rest, &mut f)?;
                }
            } else if in_insert && line.first() == Some(&b'(') {
                parse_line(&line, &mut f)?;
            }
            if in_insert && (line.ends_with(b";\n") || line.ends_with(b";\r\n") || line.ends_with(b";")) {
                in_insert = false;
            }
            line.clear();
            if self.reader.read_until(b'\n', &mut line).map_err(|e| e.to_string())? == 0 {
                return Ok(());
            }
        }
    }
}

fn parse_line(s: &[u8], f: &mut impl FnMut(&[Field])) -> Result<(), String> {
    let mut i = 0;
    let mut row: Vec<Field> = Vec::with_capacity(16);
    loop {
        if s.get(i) != Some(&b'(') {
            return Err("sql dump: expected a row".into());
        }
        i += 1;
        loop {
            if s.get(i) == Some(&b'\'') {
                let start = i + 1;
                i = start;
                while i < s.len() && s[i] != b'\'' {
                    i += if s[i] == b'\\' { 2 } else { 1 };
                }
                row.push(Field { raw: s.get(start..i).ok_or("sql dump: unterminated string")?, quoted: true });
                i += 1;
            } else {
                let start = i;
                while i < s.len() && s[i] != b',' && s[i] != b')' {
                    i += 1;
                }
                row.push(Field { raw: &s[start..i], quoted: false });
            }
            match s.get(i) {
                Some(b',') => i += 1,
                Some(b')') => {
                    i += 1;
                    break;
                }
                _ => return Err("sql dump: malformed row".into()),
            }
        }
        f(&row);
        row.clear();
        match s.get(i) {
            Some(b',') if s.get(i + 1) == Some(&b'(') => i += 1,
            _ => return Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "-- dump\nCREATE TABLE `geo_tags` (\n  `gt_id` int(10) unsigned NOT NULL,\n  `gt_page_id` int(10) unsigned NOT NULL,\n  `gt_name` varchar(255) DEFAULT NULL,\n  PRIMARY KEY (`gt_id`)\n) ENGINE=InnoDB;\nINSERT INTO `geo_tags` VALUES (1,10,'Burley, Idaho'),(2,11,NULL),(3,12,'it\\'s a \\\\ \"x\", (y)');\nINSERT INTO `geo_tags` VALUES (4,13,'z');\nINSERT INTO `geo_tags` VALUES\n(5,14,'a'),\n(6,15,NULL);\nINSERT INTO `other` VALUES (9,9,'no');\n";

    #[test]
    fn rows_and_columns() {
        let mut d = Dump::open(SAMPLE.as_bytes(), "geo_tags").unwrap();
        assert_eq!(d.columns, ["gt_id", "gt_page_id", "gt_name"]);
        assert_eq!(d.col("gt_name").unwrap(), 2);
        let mut rows = Vec::new();
        d.for_each(|f| rows.push((f[0].i64().unwrap(), f[1].i64().unwrap(), f[2].string()))).unwrap();
        assert_eq!(
            rows,
            vec![
                (1, 10, Some("Burley, Idaho".to_string())),
                (2, 11, None),
                (3, 12, Some("it's a \\ \"x\", (y)".to_string())),
                (4, 13, Some("z".to_string())),
                (5, 14, Some("a".to_string())),
                (6, 15, None)
            ]
        );
    }

    #[test]
    fn missing_table() {
        assert!(Dump::open(SAMPLE.as_bytes(), "other").is_err());
    }
}
