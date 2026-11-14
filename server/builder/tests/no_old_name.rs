// The owner's rule: the old library name is not used in Cache.
// This test keeps it out of the whole repository.
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

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

// Used only when git cannot be run.
const SKIP_DIRS: &[&str] = &[
    ".git", "target", "build", ".dart_tool", "node_modules", "third_party", "Pods", ".gradle",
];

// Paths (relative to the repository root) that are not scanned.
fn skipped(rel: &Path) -> bool {
    // Renamed in a following change.
    rel.starts_with("packages/cache_search")
        || rel.components().any(|c| c.as_os_str() == "third_party")
}

// Every file git tracks, relative to the root; None if git cannot be run.
fn tracked_files(root: &Path) -> Option<Vec<PathBuf>> {
    let out = Command::new("git").arg("ls-files").arg("-z").current_dir(root).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(
        out.stdout
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .filter_map(|s| std::str::from_utf8(s).ok())
            .map(PathBuf::from)
            .collect(),
    )
}

// Fallback: every file under the root, relative to it.
fn walk(root: &Path, dir: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().map_or(false, |n| SKIP_DIRS.iter().any(|s| n == *s)) {
                continue;
            }
            walk(root, &path, files);
        } else if let Ok(rel) = path.strip_prefix(root) {
            files.push(rel.to_path_buf());
        }
    }
}

#[test]
fn old_library_name_is_not_used() {
    let needle = ["re", "con"].concat();
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let files = tracked_files(&root).unwrap_or_else(|| {
        let mut all = Vec::new();
        walk(&root, &root, &mut all);
        all
    });
    let mut hits = Vec::new();
    for rel in files.iter().filter(|r| !skipped(r)) {
        let Ok(bytes) = fs::read(root.join(rel)) else { continue };
        let Ok(text) = String::from_utf8(bytes) else { continue };
        for (i, line) in text.lines().enumerate() {
            if line_matches(line, &needle) {
                hits.push(format!("{}:{}", rel.display(), i + 1));
            }
        }
    }
    assert!(hits.is_empty(), "old name found at:\n{}", hits.join("\n"));
}
