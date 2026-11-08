//! Which copy of a book is the best one (pack revision 3, `samebook`). Moved here from the builder's `samebook.rs`, which now
//! calls it.
//!
//! Every device must pick the same copy from the same facts, so the order is fixed and ends in a tie-break that cannot tie:
//!
//! 1. more pages with real text,
//! 2. more pages,
//! 3. higher ppi (sharper page images; a missing ppi ranks lowest),
//! 4. the smaller source file,
//! 5. the lower `doc_id` (compared as text, byte by byte). In the Bookshelves log the copy key stands in for the doc id.

use std::cmp::Ordering;

/// What the order looks at, for one copy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopyQuality {
    pub doc_id: String,
    pub text_pages: u32,
    pub pages: u32,
    /// `None` ranks below every number.
    pub ppi: Option<u32>,
    pub size: u64,
}

/// `Greater` when `a` is the better copy, `Less` when `b` is; never `Equal` for two different doc ids.
pub fn compare_copies(a: &CopyQuality, b: &CopyQuality) -> Ordering {
    a.text_pages
        .cmp(&b.text_pages)
        .then(a.pages.cmp(&b.pages))
        .then(a.ppi.cmp(&b.ppi)) // Option orders None below Some
        .then(b.size.cmp(&a.size)) // smaller is better
        .then(b.doc_id.cmp(&a.doc_id)) // lower doc_id is better
}

/// The index of the best copy (the same whatever order `copies` comes in); `None` when there are none.
pub fn best_copy(copies: &[CopyQuality]) -> Option<usize> {
    (0..copies.len()).max_by(|&i, &j| compare_copies(&copies[i], &copies[j]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(id: &str, t: u32, p: u32, ppi: Option<u32>, size: u64) -> CopyQuality {
        CopyQuality { doc_id: id.into(), text_pages: t, pages: p, ppi, size }
    }

    #[test]
    fn the_order_is_text_pages_pages_ppi_smaller_then_doc_id() {
        use Ordering::*;
        assert_eq!(compare_copies(&q("b", 312, 320, Some(100), 9), &q("a", 298, 400, Some(300), 1)), Greater);
        assert_eq!(compare_copies(&q("b", 300, 320, Some(100), 9), &q("a", 300, 310, Some(300), 1)), Greater);
        assert_eq!(compare_copies(&q("b", 300, 300, Some(300), 9), &q("a", 300, 300, Some(150), 1)), Greater);
        assert_eq!(compare_copies(&q("b", 300, 300, Some(150), 1), &q("a", 300, 300, None, 1)), Greater);
        assert_eq!(compare_copies(&q("b", 300, 300, Some(150), 1000), &q("a", 300, 300, Some(150), 2000)), Greater);
        assert_eq!(compare_copies(&q("a", 300, 300, Some(150), 1000), &q("b", 300, 300, Some(150), 1000)), Greater);
    }

    #[test]
    fn the_best_copy_does_not_depend_on_the_order_given() {
        let all = vec![q("c", 10, 10, None, 5), q("a", 10, 10, None, 5), q("b", 10, 10, None, 5), q("d", 9, 99, Some(600), 1)];
        for rot in 0..all.len() {
            let mut v = all.clone();
            v.rotate_left(rot);
            assert_eq!(v[best_copy(&v).unwrap()].doc_id, "a");
            v.reverse();
            assert_eq!(v[best_copy(&v).unwrap()].doc_id, "a");
        }
        assert_eq!(best_copy(&[]), None);
    }
}
