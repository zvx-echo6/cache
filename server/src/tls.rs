//! The server's certificate. On first start a self-signed one is made and kept in `<data>/tls/`; replace the two files
//! with your own certificate and key (PEM) to use that instead.

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::ServerConfig;
use std::io;
use std::path::Path;
use std::sync::Arc;

/// The machine's name, if it has one we can read without asking the system for anything else.
pub fn hostname() -> Option<String> {
    let from_env = ["HOSTNAME", "COMPUTERNAME"].iter().find_map(|k| std::env::var(k).ok());
    let name = from_env.or_else(|| std::fs::read_to_string("/etc/hostname").ok())?;
    let name = name.trim().to_string();
    (!name.is_empty()).then_some(name)
}

/// The names the certificate is made for: localhost, the machine's name and 127.0.0.1.
pub fn alt_names(host: Option<&str>) -> Vec<String> {
    let mut v = vec!["localhost".to_string()];
    if let Some(h) = host {
        if !v.iter().any(|n| n == h) {
            v.push(h.to_string());
        }
    }
    v.push("127.0.0.1".to_string());
    v
}

/// Make `<data>/tls/cert.pem` and `key.pem` if either is missing. The key is readable by the owner only.
pub fn ensure_cert(data: &Path) -> io::Result<()> {
    let dir = data.join("tls");
    let (cert, key) = (dir.join("cert.pem"), dir.join("key.pem"));
    if cert.exists() && key.exists() {
        return Ok(());
    }
    std::fs::create_dir_all(&dir)?;
    let host = hostname();
    // a machine name that is not a valid certificate name must not stop the server starting
    let made = rcgen::generate_simple_self_signed(alt_names(host.as_deref())).or_else(|_| rcgen::generate_simple_self_signed(alt_names(None)));
    let made = made.map_err(|e| io::Error::other(format!("making the certificate: {e}")))?;
    crate::write_private(&key, made.signing_key.serialize_pem().as_bytes())?;
    std::fs::write(&cert, made.cert.pem())?;
    Ok(())
}

/// The rustls config for the certificate and key in `<data>/tls/`.
pub fn server_config(data: &Path) -> io::Result<Arc<ServerConfig>> {
    let dir = data.join("tls");
    let certs = CertificateDer::pem_file_iter(dir.join("cert.pem")).map_err(io::Error::other)?.collect::<Result<Vec<_>, _>>().map_err(io::Error::other)?;
    let key = PrivateKeyDer::from_pem_file(dir.join("key.pem")).map_err(io::Error::other)?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut cfg = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(io::Error::other)?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(io::Error::other)?;
    cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(cfg))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    #[test]
    fn names_include_localhost_host_and_loopback() {
        assert_eq!(alt_names(Some("box")), ["localhost", "box", "127.0.0.1"]);
        assert_eq!(alt_names(Some("localhost")), ["localhost", "127.0.0.1"]);
    }

    #[test]
    fn certificate_is_made_once_and_loads() {
        let d = TempDir::new("tls");
        ensure_cert(&d.0).unwrap();
        let key = d.0.join("tls/key.pem");
        let before = std::fs::read(&key).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&key).unwrap().permissions().mode() & 0o777, 0o600);
        }
        server_config(&d.0).unwrap();
        ensure_cert(&d.0).unwrap();
        assert_eq!(std::fs::read(&key).unwrap(), before);
    }
}
