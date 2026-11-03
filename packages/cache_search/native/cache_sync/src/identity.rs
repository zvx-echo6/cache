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
}
