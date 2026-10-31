//! A place's `about` and `wikipedia` keys (docs/TOOLS.md, spec S14). `about` is the pack's `about` column exactly as the
//! data build stored it (`places_pack about`: the summary's opening text, at most 400 characters, cut at a sentence end);
//! the core never cuts or segments it. A pack or tile built before that column has no `about` for any place.
//!
//! The 1.0 rule (owner, 2026-10-30; spec S14 point 1): a place has an `about` only when its stored summary, whitespace
//! collapsed, is 400 characters or less. A longer summary has no `about` in 1.0, even when a build stored a cut of it (the
//! model-judged cut is for 1.1/1.2). The check drops; it never cuts.

/// The longest summary (Unicode scalar values, whitespace collapsed) that gives a place an `about` in 1.0.
pub const MAX_CHARS: usize = 400;

fn collapsed_len(s: &str) -> usize {
    s.split_whitespace().map(|w| w.chars().count() + 1).sum::<usize>().saturating_sub(1)
}

/// The `about` key's value: the stored text as it is; None when there is none, it is empty, or the place's summary (or,
/// with no summary, the stored text itself) is over 400 characters whitespace collapsed.
pub fn about_of(stored: Option<&str>, summary: Option<&str>) -> Option<String> {
    let stored = stored.filter(|t| !t.is_empty())?;
    let basis = summary.filter(|s| !s.trim().is_empty()).unwrap_or(stored);
    if collapsed_len(basis) > MAX_CHARS || collapsed_len(stored) > MAX_CHARS {
        return None;
    }
    Some(stored.to_string())
}

/// The `wikipedia` key's value: the article title exactly as the index has it; None when it is missing or empty.
pub fn wikipedia_of(title: Option<&str>) -> Option<String> {
    title.filter(|t| !t.is_empty()).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_text_is_shown_as_it_is_and_never_empty() {
        let s = "Shoshone Falls is a waterfall on the Snake River.  It is 212 feet high.";
        assert_eq!(about_of(Some(s), Some(s)).as_deref(), Some(s));
        assert_eq!(about_of(Some(s), None).as_deref(), Some(s));
        assert_eq!(about_of(Some(""), Some(s)), None);
        assert_eq!(about_of(None, Some(s)), None);
    }

    #[test]
    fn the_400_character_rule_counts_the_collapsed_summary() {
        let at = "a".repeat(400);
        let over = "a".repeat(401);
        assert_eq!(about_of(Some(&at), Some(&at)).as_deref(), Some(at.as_str()));
        // runs of white space count as one space; ends are trimmed
        let spaced = format!("  {}   {}  ", "a".repeat(199), "b".repeat(200));
        assert_eq!(collapsed_len(&spaced), 400);
        assert!(about_of(Some("A spring."), Some(&spaced)).is_some());
        // a longer summary has no about, even with a stored cut of it
        assert_eq!(about_of(Some("A spring."), Some(&over)), None);
        // multi-byte characters count once each
        let e = "é".repeat(400);
        assert!(about_of(Some(&e), Some(&e)).is_some());
        assert_eq!(about_of(Some(&over), None), None);
    }

    #[test]
    fn wikipedia_title_is_exact_and_never_empty() {
        assert_eq!(wikipedia_of(Some("Shoshone Falls")), Some("Shoshone Falls".into()));
        assert_eq!(wikipedia_of(Some("")), None);
        assert_eq!(wikipedia_of(None), None);
    }
}
