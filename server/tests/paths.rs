//! Where Cache for Linux lives on the system: /opt/cache-app for the program, /var/lib/cache-app for the data, `cache.service`
//! (run as the person who installed it, named in a drop-in; the `cache` user is only the unit's fallback). Nothing may ever be written under /var/cache (a folder called cache reads as safe to delete), so this
//! fails if any default path in the packaging or in the program's source starts with it.

use std::path::Path;

const UNIT: &str = include_str!("../packaging/cache.service");
const INSTALL: &str = include_str!("../packaging/install.sh");

fn rust_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

#[test]
fn nothing_is_written_under_var_cache() {
    let bad = "/var/cache";
    assert!(!UNIT.contains(bad), "the service file mentions {bad}");
    assert!(!INSTALL.contains(bad), "install.sh mentions {bad}");
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    rust_files(&root.join("src"), &mut files);
    assert!(files.len() > 10, "found the source files");
    for f in files {
        let text = std::fs::read_to_string(&f).unwrap();
        assert!(!text.contains(bad), "{} mentions {bad}", f.display());
    }
    // the workflow that builds the release too
    let wf = std::fs::read_to_string(root.join("../.github/workflows/server-release.yml")).unwrap();
    assert!(!wf.contains(bad));
}

#[test]
fn the_install_uses_the_cache_app_paths_the_cache_user_and_the_cache_unit() {
    assert!(UNIT.contains("ExecStart=/opt/cache-app/current/cache serve --data /var/lib/cache-app "));
    // The release's own unit keeps `cache` as a fallback (never root); install.sh's drop-in cache.service.d/person.conf names the
    // person. The marker tells rollback a release of this model from an older one that runs as `cache`.
    assert!(UNIT.contains("StateDirectory=cache-app") && UNIT.contains("User=cache\n") && UNIT.contains("Group=cache\n"));
    assert!(UNIT.contains("\nX-Cache-RunsAs=person\n"), "the unit carries the runs-as-the-person marker");
    assert!(INSTALL.contains("OPT=/opt/cache-app\n") && INSTALL.contains("DATA=/var/lib/cache-app\n"));
    assert!(INSTALL.contains("UNIT=/etc/systemd/system/cache.service\n"));
    assert!(INSTALL.contains("useradd --system --gid cache"), "the system user is `cache`");
    // rollback and update use the same variables, so they follow the paths
    assert!(INSTALL.contains("\"$OPT/current\"") && INSTALL.contains("\"$OPT/previous\""));
    // it says plainly where the library lives
    assert!(INSTALL.contains("Your library and settings are in $DATA"));
    // no leftover of the old names
    for old in ["cache-server", "Cache Server", "/opt/cache\n", "/var/lib/cache\n"] {
        assert!(!UNIT.contains(old) && !INSTALL.contains(old), "{old:?} is still in the packaging");
    }
}

#[test]
fn the_unit_lets_cache_open_the_folders_the_person_can_open() {
    // Running as the person, their own permissions are the boundary: the home folders and any other folder they can reach are
    // open, the system's own folders (/usr, /boot, /efi, /etc) stay read-only.
    assert!(UNIT.contains("\nProtectHome=no\n") && !UNIT.contains("ProtectHome=yes"), "the home folders are reachable");
    assert!(UNIT.contains("\nProtectSystem=full\n") && !UNIT.contains("ProtectSystem=strict"), "the system folders stay read-only");
    assert!(UNIT.contains("\nNoNewPrivileges=yes\n") && UNIT.contains("\nPrivateTmp=yes\n") && UNIT.contains("\nStateDirectoryMode=0750\n"));
    assert!(UNIT.contains("\nWantedBy=multi-user.target\n"), "it starts at boot, with no login");
}
