//! The folders the server keeps its data in. The sources the core opens come from `<data>/sources.json` (see `helper`).

use std::io;
use std::path::Path;

/// Create the folders the server keeps its data in.
pub fn make_folders(data: &Path) -> io::Result<()> {
    for d in ["zims", "libraries", "index"] {
        std::fs::create_dir_all(data.join(d))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    #[test]
    fn folders_are_made() {
        let d = TempDir::new("cfg");
        make_folders(&d.0).unwrap();
        make_folders(&d.0).unwrap();
        for f in ["zims", "libraries", "index"] {
            assert!(d.0.join(f).is_dir());
        }
    }
}
