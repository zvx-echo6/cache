//! A place's `about` and `wikipedia` keys (docs/TOOLS.md, spec S14). `about` is the pack's `about` column exactly as the
//! data build stored it (`places_pack about`: the summary's opening text, at most 400 characters, cut at a sentence end);
//! the core never cuts or segments it. A pack or tile built before that column has no `about` for any place.

/// The `about` key's value: the stored text as it is; None when there is none or it is empty.
pub fn about_of(stored: Option<&str>) -> Option<String> {
    stored.filter(|t| !t.is_empty()).map(str::to_string)
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
        assert_eq!(about_of(Some(s)).as_deref(), Some(s));
        assert_eq!(about_of(Some("")), None);
        assert_eq!(about_of(None), None);
    }

    #[test]
    fn wikipedia_title_is_exact_and_never_empty() {
        assert_eq!(wikipedia_of(Some("Shoshone Falls")), Some("Shoshone Falls".into()));
        assert_eq!(wikipedia_of(Some("")), None);
        assert_eq!(wikipedia_of(None), None);
    }
}
