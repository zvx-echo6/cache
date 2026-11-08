//! Which copy of a book to keep when two files are the same book (pack revision 3, `samebook`).
//!
//! Every device must pick the same copy from the same packs, so the order is fixed and ends in a tie-break that cannot tie:
//!
//! 1. more pages with real text,
//! 2. more pages,
//! 3. higher ppi (sharper page images; a missing ppi ranks lowest),
//! 4. the smaller source file,
//! 5. the lower `doc_id` (compared as text, byte by byte).

use crate::pack::Pack;
use std::cmp::Ordering;

/// The same-book decision (thresholds and the judge) lives in `cache_shelves::same`; the build service and the Bookshelves log both use it.
pub use cache_shelves::same::{judge, Match, Tuning};

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

impl CopyQuality {
    fn to_shelves(&self) -> cache_shelves::CopyQuality {
        cache_shelves::CopyQuality { doc_id: self.doc_id.clone(), text_pages: self.text_pages, pages: self.pages, ppi: self.ppi, size: self.size }
    }

    /// The quality of a pack's copy; `None` for a pack without `samebook` (an older pack cannot be compared).
    pub fn of_pack(pack: &Pack) -> Option<CopyQuality> {
        let s = pack.header.samebook.as_ref()?;
        Some(CopyQuality { doc_id: pack.header.doc_id.clone(), text_pages: s.text_pages, pages: s.pages, ppi: s.ppi, size: s.source_size })
    }
}

/// `Greater` when `a` is the better copy, `Less` when `b` is; never `Equal` for two different doc ids. The order itself lives in
/// `cache_shelves::quality` (shared with the Bookshelves log's reading copy); this calls it.
pub fn compare_copies(a: &CopyQuality, b: &CopyQuality) -> Ordering {
    cache_shelves::compare_copies(&a.to_shelves(), &b.to_shelves())
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
        assert_eq!(compare_copies(&q("b", 300, 300, Some(150), 1), &q("a", 300, 300, None, 1)), Greater, "a missing ppi ranks lowest");
        assert_eq!(compare_copies(&q("b", 300, 300, Some(150), 1000), &q("a", 300, 300, Some(150), 2000)), Greater);
        assert_eq!(compare_copies(&q("a", 300, 300, Some(150), 1000), &q("b", 300, 300, Some(150), 1000)), Greater, "the lower doc_id wins the last tie");
    }

    #[test]
    fn the_best_copy_does_not_depend_on_the_order_given() {
        let all = vec![q("c", 10, 10, None, 5), q("a", 10, 10, None, 5), q("b", 10, 10, None, 5), q("d", 9, 99, Some(600), 1)];
        let want = "a";
        for rot in 0..all.len() {
            let mut v = all.clone();
            v.rotate_left(rot);
            assert_eq!(v[best_copy(&v).unwrap()].doc_id, want);
            v.reverse();
            assert_eq!(v[best_copy(&v).unwrap()].doc_id, want);
        }
        assert_eq!(best_copy(&[]), None);
    }
}
