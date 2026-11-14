// The owner's rule: the old library name is not used in Cache.
// This test keeps it out of server/builder.
use std::fs;
use std::path::Path;

fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn line_matches(line: &str, needle: &str) -> bool {
    let lower = line.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    let mut from = 0;
    while let Some(pos) = lower[from..].find(needle) {
        let start = from + pos;
        let end = start + needle.len();
        let before_ok = start == 0 || !is_word(bytes[start - 1]);
        let after_ok = end >= bytes.len() || !bytes[end].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
        from = start + 1;
    }
    false
}

fn walk(dir: &Path, needle: &str, hits: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().map_or(false, |n| n == "target") {
                continue;
            }
            walk(&path, needle, hits);
        } else if let Ok(bytes) = fs::read(&path) {
            let Ok(text) = String::from_utf8(bytes) else { continue };
            for (i, line) in text.lines().enumerate() {
                if line_matches(line, needle) {
                    hits.push(format!("{}:{}", path.display(), i + 1));
                }
            }
        }
    }
}

#[test]
fn old_library_name_is_not_used() {
    let needle = ["re", "con"].concat();
    let mut hits = Vec::new();
    walk(Path::new(env!("CARGO_MANIFEST_DIR")), &needle, &mut hits);
    assert!(hits.is_empty(), "old name found at:\n{}", hits.join("\n"));
}
