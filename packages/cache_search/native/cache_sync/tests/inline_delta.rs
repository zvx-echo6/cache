//! Small files' bytes travel inline with their entries in a page of differences (design 2b, the Slow class): the page keeps its size
//! rule, and an older receiver reads the page without them.
use cache_sync::delta::{diff_page_with, inline_bytes, stamp, Change, Mirror, Page};
use cache_sync::index::{Entry, Index, Ver};
use serde::Deserialize;

fn all(_: &str, _: &Entry) -> bool {
    true
}

fn put(idx: &mut Index, path: &str, hash: &str, at: u64) {
    idx.files.insert(path.into(), Entry { hash: hash.into(), size: 1, deleted: false, ver: Ver { at, by: "A".into() }, hist: vec![], ctr: 0 });
}

#[test]
fn a_small_files_bytes_travel_with_its_entry_and_an_entry_bigger_than_the_page_goes_alone() {
    let mut s = Index::default();
    put(&mut s, "a", "h1", 10);
    put(&mut s, "b", "h2", 10);
    put(&mut s, "c", "h3", 10);
    s.files.get_mut("b").unwrap().size = 8192;
    let s = stamp(&Index::default(), &s);
    // Only "b" has bytes to send (8 KB): its change alone is bigger than a 4 KB page.
    let inline = |p: &str, _: &Entry| (p == "b").then(|| vec![7u8; 8192]);
    let p1 = diff_page_with(&s, &s.epoch, 0, None, &all, 4096, &inline);
    assert_eq!(p1.changes.iter().map(|c| c.p.as_str()).collect::<Vec<_>>(), ["a"], "a goes first and b would not fit beside it");
    assert!(p1.more && p1.changes[0].i.is_none());
    let mut m = Mirror { epoch: s.epoch.clone(), fp: "fp".into(), ..Default::default() };
    m.take(&p1);
    let p2 = diff_page_with(&s, &m.epoch, m.ctr, m.after.as_deref(), &all, 4096, &inline);
    assert_eq!(p2.changes.iter().map(|c| c.p.as_str()).collect::<Vec<_>>(), ["b"], "the 8 KB entry is a page of its own");
    assert!(p2.more);
    assert_eq!(inline_bytes(&p2.changes[0]).unwrap(), vec![7u8; 8192]);
    m.take(&p2);
    // The bytes are never part of the mirror: it holds entries only.
    assert!(m.files.values().all(|e| e.size <= 8192));
    assert!(!serde_json::to_string(&m).unwrap().contains("\"i\""));
    let p3 = diff_page_with(&s, &m.epoch, m.ctr, m.after.as_deref(), &all, 4096, &inline);
    assert_eq!(p3.changes.iter().map(|c| c.p.as_str()).collect::<Vec<_>>(), ["c"]);
    assert!(!p3.more);
}

#[test]
fn an_older_receiver_ignores_the_inline_field_and_an_older_sender_has_none() {
    let mut s = Index::default();
    put(&mut s, "a", "h1", 10);
    let s = stamp(&Index::default(), &s);
    let page = diff_page_with(&s, &s.epoch, 0, None, &all, cache_sync::delta::PAGE_BYTES, &|_, _| Some(vec![1, 2, 3]));
    let json = serde_json::to_string(&page).unwrap();
    // What an older build's Change has: no `i`. It reads the page and takes the entry.
    #[derive(Deserialize)]
    struct OldChange {
        p: String,
        c: u64,
        e: Option<Entry>,
    }
    #[derive(Deserialize)]
    struct OldPage {
        changes: Vec<OldChange>,
    }
    let old: OldPage = serde_json::from_str(&json).unwrap();
    assert_eq!((old.changes[0].p.as_str(), old.changes[0].c), ("a", 1));
    assert!(old.changes[0].e.is_some());
    // And a page without `i` reads as no inline bytes.
    let none: Page = serde_json::from_str(r#"{"counter":1,"changes":[{"p":"a","c":1}]}"#).unwrap();
    assert!(inline_bytes(&none.changes[0]).is_none());
    // Not base64: no bytes, not an error.
    let bad = Change { p: "a".into(), c: 1, e: None, i: Some("***".into()) };
    assert!(inline_bytes(&bad).is_none());
}
