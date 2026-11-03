//! Security keys: WebAuthn sign-in and registration, on top of `auth`.
//!
//! WebAuthn binds a key to a fixed hostname (the RP ID) and an origin, so it works only when the server is told where it
//! lives (`--public-origin https://host[:port]`) and the host is a name, not an IP address. Browsers also refuse it on a
//! site whose certificate they do not trust. Without a usable origin there is no `Webauthn` and the keys are unavailable.
//!
//! The server keeps the half-finished challenges in memory only (five minutes, at most 64 of each kind): they are single
//! use, so a restart just means the page asks again.

use crate::auth::{clean_name, hex, now, random_bytes, Auth, Gate, SecurityKeyEntry, SettingsError};
use std::collections::HashMap;
use std::io;
use webauthn_rs::prelude::{
    CreationChallengeResponse, CredentialID, PublicKeyCredential, RegisterPublicKeyCredential, RequestChallengeResponse, SecurityKey, Url, Uuid, Webauthn,
    WebauthnBuilder,
};

/// How long a challenge waits for the key, in seconds.
pub const PENDING_SECS: u64 = 300;
/// The most challenges kept at once, per kind.
pub const PENDING_MAX: usize = 64;
/// There is one person, so one WebAuthn user. The handle is opaque to the keys (they are not discoverable).
const USER_ID: Uuid = Uuid::from_u128(0x6361_6368_652d_7365_7276_6572_0000_0001);

/// The WebAuthn relying party for `--public-origin`, or `None` when security keys cannot work: nothing is set, the host is
/// an IP address, or the site is plain HTTP (browsers allow WebAuthn only on HTTPS, and on `localhost`). A value that is not
/// a URL at all is an error, so a typo is not mistaken for "not set".
pub fn build_webauthn(origin: Option<&str>) -> Result<Option<Webauthn>, String> {
    let Some(raw) = origin.map(str::trim).filter(|s| !s.is_empty()) else { return Ok(None) };
    let url = Url::parse(raw).map_err(|e| format!("--public-origin {raw:?}: {e}"))?;
    let Some(host) = url.domain().map(str::to_string) else {
        eprintln!("cache: --public-origin has no host name (an IP address does not work for security keys); security keys are off");
        return Ok(None);
    };
    if url.scheme() != "https" && !(url.scheme() == "http" && host == "localhost") {
        eprintln!("cache: --public-origin is not https; security keys are off");
        return Ok(None);
    }
    // only scheme, host and port make an origin
    let mut origin = url.clone();
    origin.set_path("");
    origin.set_query(None);
    origin.set_fragment(None);
    let builder = WebauthnBuilder::new(&host, &origin).map_err(|e| format!("--public-origin {raw:?}: {e}"))?;
    // One touch signs in: the key proves it is present, it does not also have to check a PIN. (The page's other factor is
    // the password, in mode "both".)
    let wa = builder.rp_name("Cache").danger_set_user_presence_only_security_keys(true).build().map_err(|e| format!("--public-origin {raw:?}: {e}"))?;
    Ok(Some(wa))
}

/// Why a key sign-in did not happen.
#[derive(Debug)]
pub enum KeyError {
    Gate(Gate),
    /// No WebAuthn set up, or no security key registered.
    Unavailable,
    /// The key (or the challenge) was not accepted.
    Wrong,
    /// Too many challenges waiting.
    Busy,
    Io(io::Error),
}

fn new_id() -> io::Result<String> {
    Ok(hex(&random_bytes::<16>()?))
}

/// Drop what expired, then say whether there is room.
fn room<T>(map: &mut HashMap<String, T>, expiry: impl Fn(&T) -> u64) -> bool {
    let at = now();
    map.retain(|_, v| expiry(v) > at);
    map.len() < PENDING_MAX
}

impl Auth {
    /// Begin a security-key sign-in: the options for `navigator.credentials.get` and the id that goes with them.
    pub fn webauthn_start(&self, half: Option<&str>) -> Result<(String, RequestChallengeResponse), KeyError> {
        self.key_gate(half).map_err(KeyError::Gate)?;
        let wa = self.webauthn.as_ref().ok_or(KeyError::Unavailable)?;
        let keys: Vec<SecurityKey> = self.read(|f| f.security_keys.iter().map(|k| k.key.clone()).collect());
        if keys.is_empty() {
            return Err(KeyError::Unavailable);
        }
        let (options, state) = wa.start_securitykey_authentication(&keys).map_err(|_| KeyError::Unavailable)?;
        let id = new_id().map_err(KeyError::Io)?;
        let mut p = self.pending_auth.lock().unwrap_or_else(|e| e.into_inner());
        if !room(&mut *p, |v| v.1) {
            return Err(KeyError::Busy);
        }
        p.insert(id.clone(), (state, now() + PENDING_SECS));
        Ok((id, options))
    }

    /// Finish it: the browser's answer for the challenge `id`. `Ok(token)` is a new full session. A challenge can be answered
    /// once, right or wrong.
    pub fn webauthn_finish(&self, id: &str, credential: &PublicKeyCredential, half: Option<&str>) -> Result<String, KeyError> {
        self.key_gate(half).map_err(KeyError::Gate)?;
        let wa = self.webauthn.as_ref().ok_or(KeyError::Unavailable)?;
        let state = {
            let mut p = self.pending_auth.lock().unwrap_or_else(|e| e.into_inner());
            match p.remove(id) {
                Some((s, exp)) if exp > now() => s,
                _ => return Err(KeyError::Wrong),
            }
        };
        let result = wa.finish_securitykey_authentication(credential, &state).map_err(|_| KeyError::Wrong)?;
        // keep the key's counter, and note when it was used
        let known = self
            .update(|f| {
                for k in f.security_keys.iter_mut() {
                    if k.key.update_credential(&result).is_some() {
                        k.last_used = Some(now());
                        return Ok(true);
                    }
                }
                Ok(false)
            })
            .map_err(|e| match e {
                SettingsError::Io(e) => KeyError::Io(e),
                _ => KeyError::Wrong,
            })?;
        if !known {
            return Err(KeyError::Wrong);
        }
        self.reset_failures();
        self.consume_half(half);
        self.new_session().map_err(KeyError::Io)
    }

    /// Begin registering a security key (settings page; a signed-in person).
    pub fn register_start(&self, name: &str) -> Result<(String, CreationChallengeResponse), SettingsError> {
        let name = clean_name(name)?;
        let wa = self.webauthn.as_ref().ok_or(SettingsError::NoWebauthn)?;
        let existing: Vec<CredentialID> = self.read(|f| f.security_keys.iter().map(|k| k.key.cred_id().clone()).collect());
        let exclude = if existing.is_empty() { None } else { Some(existing) };
        let (options, state) =
            wa.start_securitykey_registration(USER_ID, "cache", "Cache", exclude, None, None).map_err(|_| SettingsError::Invalid("The key could not be started."))?;
        let id = new_id().map_err(SettingsError::Io)?;
        let mut p = self.pending_reg.lock().unwrap_or_else(|e| e.into_inner());
        if !room(&mut *p, |v| v.2) {
            return Err(SettingsError::Invalid("Try again in a minute."));
        }
        p.insert(id.clone(), (state, name, now() + PENDING_SECS));
        Ok((id, options))
    }

    /// Finish registering: the browser's answer for the challenge `id`.
    pub fn register_finish(&self, id: &str, credential: &RegisterPublicKeyCredential) -> Result<(), SettingsError> {
        let wa = self.webauthn.as_ref().ok_or(SettingsError::NoWebauthn)?;
        let (state, name) = {
            let mut p = self.pending_reg.lock().unwrap_or_else(|e| e.into_inner());
            match p.remove(id) {
                Some((s, n, exp)) if exp > now() => (s, n),
                _ => return Err(SettingsError::Invalid("The key took too long. Try again.")),
            }
        };
        let key = wa.finish_securitykey_registration(credential, &state).map_err(|_| SettingsError::Invalid("The key was not accepted."))?;
        let entry_id = new_id().map_err(SettingsError::Io)?;
        self.update(|f| {
            if f.security_keys.iter().any(|k| k.key.cred_id() == key.cred_id()) {
                return Err(SettingsError::Invalid("That key is already registered."));
            }
            f.security_keys.push(SecurityKeyEntry { id: entry_id.clone(), name, added: now(), last_used: None, key });
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_origin_an_ip_or_plain_http_means_no_security_keys() {
        assert!(build_webauthn(None).unwrap().is_none());
        assert!(build_webauthn(Some("")).unwrap().is_none());
        assert!(build_webauthn(Some("https://192.0.2.10:8443")).unwrap().is_none());
        assert!(build_webauthn(Some("https://[2001:db8::1]")).unwrap().is_none());
        assert!(build_webauthn(Some("http://cache.example.com")).unwrap().is_none());
        assert!(build_webauthn(Some("not a url")).is_err());
    }

    #[test]
    fn a_hostname_gives_webauthn_for_that_origin() {
        let wa = build_webauthn(Some("https://cache.example.com:8443/some/path?x=1")).unwrap().unwrap();
        let origins: Vec<String> = wa.get_allowed_origins().iter().map(|u| u.to_string()).collect();
        assert_eq!(origins, ["https://cache.example.com:8443/"]);
        assert!(build_webauthn(Some("http://localhost:8443")).unwrap().is_some(), "localhost is allowed over http");
    }
}
