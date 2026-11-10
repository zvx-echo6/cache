//! The two pages the server makes itself: the sign-in page (shown for every request without a session) and the keys
//! settings page. Both are single files with their CSS and script inline, so they need no other request before sign-in.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use std::sync::OnceLock;

/// The Cache logo (the app's `assets/brand/logo.png`, scaled to 240 px wide so the page stays small), inlined into the
/// sign-in page. The light and dark themes use the same picture.
static LOGO: &[u8] = include_bytes!("pages/logo.png");
const SIGNIN: &str = include_str!("pages/signin.html");
const KEYS: &str = include_str!("pages/keys.html");

/// The sign-in page.
pub fn signin_html() -> &'static str {
    static PAGE: OnceLock<String> = OnceLock::new();
    PAGE.get_or_init(|| SIGNIN.replace("{{LOGO}}", &format!("data:image/png;base64,{}", STANDARD.encode(LOGO))))
}

/// The keys settings page (served at `/settings/keys` to a signed-in person).
pub fn keys_html() -> &'static str {
    KEYS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sign_in_page_is_self_contained() {
        let p = signin_html();
        assert!(p.starts_with("<!doctype html>"));
        assert!(p.contains("data:image/png;base64,iVBOR"), "the logo is inline");
        assert!(!p.contains("{{LOGO}}"));
        // nothing is fetched from another file: the only requests are the sign-in endpoints
        for bad in ["<link", "src=\"/", "src='/", "<script src", "@import", "https://"] {
            assert!(!p.contains(bad), "{bad}");
        }
        // no visible text: every word on the page is inside a script, a style, an aria-label or the title
        assert!(p.contains("aria-live=\"assertive\"") && p.contains("aria-label=\"Password\""));
    }

    #[test]
    fn no_mock_stand_ins_remain() {
        for (name, p) in [("sign-in", signin_html()), ("keys", keys_html())] {
            for bad in ["Stand-in", "stand-in", "KEYFAIL", "URLSearchParams", "?state", "?mode", "data-theme", "mock"] {
                assert!(!p.contains(bad), "{name}: {bad}");
            }
        }
    }

    #[test]
    fn the_keys_page_has_the_plain_labels() {
        let p = keys_html();
        for label in ["Password only", "Password or key", "Password and key", "Key only", "Start with the password box", "Register a security key", "Make a key file", "Needs a hostname with a trusted certificate", "Remove"] {
            assert!(p.contains(label), "{label}");
        }
        for proposed in ["asks for your password", "Proposed", "Test sign-in"] {
            assert!(!p.contains(proposed), "{proposed}");
        }
    }
}
