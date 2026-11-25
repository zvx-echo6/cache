//! The device's identity: the iroh key pair kept as `identity.key` (the 32 secret-key bytes) in the sync folder. One
//! implementation, used by the sync engine when it starts and by anything that needs the device's id without starting the
//! endpoint (Cache on Linux's book builder).

use anyhow::Result;
use iroh::SecretKey;
use std::path::Path;

/// The identity file's name in the sync folder.
pub const KEY_FILE: &str = "identity.key";

/// Loads the identity in `dir`, or makes one: a missing file, one that cannot be read, or one that is not exactly 32 bytes is
/// replaced by a new key (written through a temporary file, owner-only on Unix). Returns the key and the device's id as
/// cache_sync shows it everywhere (the EndpointId's text: lower-case letters and digits, safe as a file name).
pub fn load_or_create(dir: &Path) -> Result<(SecretKey, String)> {
    load(dir, None, true)
}

/// Red stub (to be replaced): today's behaviour whatever `keep` and `make` say.
pub fn load(dir: &Path, _keep: Option<&Path>, _make: bool) -> Result<(SecretKey, String)> {
    std::fs::create_dir_all(dir)?;
    let key_path = dir.join(KEY_FILE);
    let secret = match std::fs::read(&key_path) {
        Ok(b) if b.len() == 32 => SecretKey::from_bytes(&b.try_into().unwrap()),
        _ => {
            let k = SecretKey::generate();
            write_secret(&key_path, &k.to_bytes())?;
            k
        }
    };
    let id = secret.public().to_string();
    Ok((secret, id))
}

fn write_secret(p: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = p.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, p)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn made_once_then_the_same_key_and_id() {
        let d = tempfile::tempdir().unwrap();
        let (k1, id1) = load_or_create(d.path()).unwrap();
        let bytes = std::fs::read(d.path().join(KEY_FILE)).unwrap();
        assert_eq!(bytes.len(), 32);
        assert_eq!(bytes, k1.to_bytes());
        let (k2, id2) = load_or_create(d.path()).unwrap();
        assert_eq!(k1.to_bytes(), k2.to_bytes());
        assert_eq!(id1, id2);
        assert_eq!(id1, k1.public().to_string(), "the EndpointId's text");
        assert!(!id1.is_empty() && id1.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()), "file-name safe: {id1}");
        assert!(!d.path().join("identity.tmp").exists());
    }

    #[test]
    fn a_file_of_the_wrong_length_is_replaced_by_a_new_key() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join(KEY_FILE), [7u8; 31]).unwrap();
        let (k, id) = load_or_create(d.path()).unwrap();
        assert_eq!(std::fs::read(d.path().join(KEY_FILE)).unwrap(), k.to_bytes());
        assert_eq!(load_or_create(d.path()).unwrap().1, id);
    }

    #[test]
    fn a_missing_folder_is_made() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path().join("a/b");
        let (_, id) = load_or_create(&dir).unwrap();
        assert!(dir.join(KEY_FILE).exists());
        assert_eq!(load_or_create(&dir).unwrap().1, id);
    }
    /// Root reads a mode-000 file anyway: then the test cannot make an unreadable file and says so.
    #[cfg(unix)]
    fn unreadable(p: &Path) -> bool {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o000)).unwrap();
        if std::fs::read(p).is_ok() {
            eprintln!("running as root: a mode-000 file is still readable, test skipped");
            std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600)).unwrap();
            return false;
        }
        true
    }

    #[cfg(unix)]
    fn readable_again(p: &Path) -> Vec<u8> {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::read(p).unwrap()
    }

    #[cfg(unix)]
    #[test]
    fn a_key_that_cannot_be_read_fails_the_load_and_is_left_byte_identical() {
        let d = tempfile::tempdir().unwrap();
        let (k, _) = load_or_create(d.path()).unwrap();
        let p = d.path().join(KEY_FILE);
        if !unreadable(&p) {
            return;
        }
        let e = load_or_create(d.path()).expect_err("an unreadable key is never replaced by a new one");
        assert!(format!("{e:#}").starts_with("Can't read this device's identity"), "{e:#}");
        assert_eq!(readable_again(&p), k.to_bytes(), "the key file is untouched");
        assert!(!d.path().join("identity.tmp").exists());
    }

    #[test]
    fn a_missing_key_gives_a_new_one() {
        let d = tempfile::tempdir().unwrap();
        let (_, id1) = load_or_create(d.path()).unwrap();
        std::fs::remove_file(d.path().join(KEY_FILE)).unwrap();
        let (k2, id2) = load_or_create(d.path()).unwrap();
        assert_ne!(id1, id2, "no copy anywhere: a new device");
        assert_eq!(std::fs::read(d.path().join(KEY_FILE)).unwrap(), k2.to_bytes());
    }

    #[test]
    fn a_wrong_length_key_with_no_copy_gives_a_new_one() {
        let d = tempfile::tempdir().unwrap();
        let keep = d.path().join("keep");
        std::fs::create_dir_all(d.path().join("sync")).unwrap();
        std::fs::write(d.path().join("sync").join(KEY_FILE), [7u8; 33]).unwrap();
        let (k, _) = load(&d.path().join("sync"), Some(&keep), true).unwrap();
        assert_eq!(std::fs::read(d.path().join("sync").join(KEY_FILE)).unwrap(), k.to_bytes());
        assert_eq!(std::fs::read(keep.join(KEY_FILE)).unwrap(), k.to_bytes(), "the new key is kept in the copy too");
    }

    // ---- the second copy (`keep`, Cache on Linux: <data>/identity-keep)

    #[test]
    fn a_good_key_is_copied_to_keep_and_the_copy_is_refreshed_when_different() {
        let d = tempfile::tempdir().unwrap();
        let (sync, keep) = (d.path().join("sync"), d.path().join("identity-keep"));
        let (k, _) = load(&sync, Some(&keep), true).unwrap();
        assert_eq!(std::fs::read(keep.join(KEY_FILE)).unwrap(), k.to_bytes());
        std::fs::write(keep.join(KEY_FILE), [9u8; 32]).unwrap();
        let (k2, _) = load(&sync, Some(&keep), true).unwrap();
        assert_eq!(k2.to_bytes(), k.to_bytes(), "the main key wins");
        assert_eq!(std::fs::read(keep.join(KEY_FILE)).unwrap(), k.to_bytes(), "the copy follows it");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(keep.join(KEY_FILE)).unwrap().permissions().mode() & 0o777, 0o600);
            assert_eq!(std::fs::metadata(&keep).unwrap().permissions().mode() & 0o777, 0o700);
        }
    }

    #[test]
    fn a_missing_or_wrong_length_key_is_restored_from_the_copy() {
        let d = tempfile::tempdir().unwrap();
        let (sync, keep) = (d.path().join("sync"), d.path().join("identity-keep"));
        let (k, id) = load(&sync, Some(&keep), true).unwrap();
        std::fs::remove_file(sync.join(KEY_FILE)).unwrap();
        assert_eq!(load(&sync, Some(&keep), true).unwrap().1, id, "missing: the same device");
        assert_eq!(std::fs::read(sync.join(KEY_FILE)).unwrap(), k.to_bytes());
        std::fs::write(sync.join(KEY_FILE), [1u8; 5]).unwrap();
        assert_eq!(load(&sync, Some(&keep), true).unwrap().1, id, "wrong length: the same device");
        assert_eq!(std::fs::read(sync.join(KEY_FILE)).unwrap(), k.to_bytes());
        std::fs::remove_dir_all(&sync).unwrap();
        assert_eq!(load(&sync, Some(&keep), true).unwrap().1, id, "the whole sync folder gone: still the same device");
    }

    #[test]
    fn a_bad_copy_is_not_used_and_both_get_the_new_key() {
        let d = tempfile::tempdir().unwrap();
        let (sync, keep) = (d.path().join("sync"), d.path().join("identity-keep"));
        std::fs::create_dir_all(&keep).unwrap();
        std::fs::write(keep.join(KEY_FILE), [3u8; 12]).unwrap();
        let (k, _) = load(&sync, Some(&keep), true).unwrap();
        assert_eq!(std::fs::read(sync.join(KEY_FILE)).unwrap(), k.to_bytes());
        assert_eq!(std::fs::read(keep.join(KEY_FILE)).unwrap(), k.to_bytes());
    }

    #[cfg(unix)]
    #[test]
    fn a_missing_key_with_a_copy_that_cannot_be_read_fails_and_makes_nothing() {
        let d = tempfile::tempdir().unwrap();
        let (sync, keep) = (d.path().join("sync"), d.path().join("identity-keep"));
        let (k, _) = load(&sync, Some(&keep), true).unwrap();
        std::fs::remove_file(sync.join(KEY_FILE)).unwrap();
        if !unreadable(&keep.join(KEY_FILE)) {
            return;
        }
        let e = load(&sync, Some(&keep), true).expect_err("the copy may still hold the identity");
        assert!(format!("{e:#}").starts_with("Can't read this device's identity"), "{e:#}");
        assert!(!sync.join(KEY_FILE).exists(), "no new key was made");
        assert_eq!(readable_again(&keep.join(KEY_FILE)), k.to_bytes());
    }

    #[test]
    fn with_make_off_a_missing_key_and_no_copy_fails_and_makes_nothing() {
        let d = tempfile::tempdir().unwrap();
        let sync = d.path().join("sync");
        let e = load(&sync, None, false).expect_err("not allowed to make a new identity");
        assert!(format!("{e:#}").starts_with("Can't read this device's identity"), "{e:#}");
        assert!(!sync.join(KEY_FILE).exists());
        std::fs::write(sync.join(KEY_FILE), [7u8; 31]).unwrap();
        assert!(load(&sync, None, false).is_err(), "a wrong length is not replaced either");
        assert_eq!(std::fs::read(sync.join(KEY_FILE)).unwrap(), [7u8; 31]);
        // the copy still restores with make off
        let keep = d.path().join("identity-keep");
        std::fs::create_dir_all(&keep).unwrap();
        let k = SecretKey::generate();
        std::fs::write(keep.join(KEY_FILE), k.to_bytes()).unwrap();
        assert_eq!(load(&sync, Some(&keep), false).unwrap().1, k.public().to_string());
    }
}
