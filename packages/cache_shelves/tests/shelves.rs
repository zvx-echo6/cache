//! Tests of the Bookshelves log: events, the writer, resolution, the import and the view.

use cache_shelves::events::{valid_relpath, FolderMode};
use cache_shelves::import::import_own;
use cache_shelves::library::{copies_path, copy_key, load_library, read_copies, LibraryInput, LibraryRef, PackFacts, SameInfo, Seed, SuggestedDiv, SuggestedShelf};
use cache_shelves::resolve::{resolve, TitleFrom};
use cache_shelves::store::{parse_log, read_logs, LogWriter};
use cache_shelves::view::{build_view, view_bytes, view_value};
use cache_shelves::{ops, By, Event, How, Kind, Resolved};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

// ---------------------------------------------------------------------------------------------------------------- helpers

struct Tmp(PathBuf);

impl Tmp {
    fn new(tag: &str) -> Tmp {
        static N: AtomicUsize = AtomicUsize::new(0);
        let p = std::env::temp_dir().join(format!("cache_shelves_test_{}_{}_{}", std::process::id(), tag, N.fetch_add(1, Ordering::SeqCst)));
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn ev(at: u64, dev: &str, kind: Kind) -> Event {
    Event::new(at, dev, kind)
}
fn s(x: &str) -> String {
    x.to_string()
}
fn place(copy: &str, div: &str) -> Kind {
    Kind::Place { copy: s(copy), div: s(div), by: By::Auto }
}
fn assign(copy: &str, div: &str, seq: u32) -> Kind {
    Kind::Assign { copy: s(copy), div: s(div), seq }
}
fn retire(copy: &str, div: &str, seq: u32) -> Kind {
    Kind::Retire { copy: s(copy), div: s(div), seq }
}
fn same(copy: &str, with: &str, by: By, score: Option<f64>) -> Kind {
    Kind::Same { copy: s(copy), with: s(with), by, how: if by == By::User { How::User } else { How::Text }, score }
}
fn notsame(copy: &str, with: &str, by: By) -> Kind {
    Kind::NotSame { copy: s(copy), with: s(with), by }
}
fn title(copy: &str, t: &str) -> Kind {
    Kind::Title { copy: s(copy), title: s(t) }
}

fn pf(copy: &str, doc: &str, title: &str, text_pages: u32) -> PackFacts {
    PackFacts {
        copy: s(copy),
        doc_id: s(doc),
        version: 1,
        title: s(title),
        suggested: None,
        blake3: None,
        original_blake3: None,
        source_blake3: None,
        fields: Default::default(),
        same: Some(SameInfo { minhash: vec![], mean_vector: vec![], text_pages, pages: text_pages, ppi: Some(150), source_size: 1000, words: None }),
    }
}

fn lib(id: &str, copies: Vec<PackFacts>) -> LibraryInput {
    LibraryInput { library_id: s(id), dir: PathBuf::new(), copies, seed: Seed::default(), unreadable: 0 }
}

/// Three copies A, B and C in one library "L", doc ids a, b, c, equal quality (so the lowest key reads).
fn abc() -> Vec<LibraryInput> {
    vec![lib("L", vec![pf("A", "a", "Book A", 10), pf("B", "b", "Book B", 10), pf("C", "c", "Book C", 10)])]
}

fn call(r: &Resolved, copy: &str) -> Option<String> {
    r.book_of(copy).and_then(|b| b.call.as_ref()).map(|c| c.text.clone())
}
fn own(r: &Resolved, copy: &str) -> Option<String> {
    r.book_of(copy).and_then(|b| b.copies.iter().find(|c| c.copy == copy)).and_then(|c| c.own_call.as_ref()).map(|c| c.text.clone())
}
fn same_book(r: &Resolved, a: &str, b: &str) -> bool {
    r.book_of(a).map(|x| &x.id) == r.book_of(b).map(|x| &x.id) && r.book_of(a).is_some()
}

// ---------------------------------------------------------------------------------------------------------------- events

#[test]
fn lines_round_trip_and_have_the_documented_shape() {
    let all = [
        ev(1793600000000, "phone-7", place("A", "210")).with_loc("recon/wm"),
        ev(1793600000001, "phone-7", assign("A", "210", 1)),
        ev(1793600000002, "phone-7", same("B", "A", By::Auto, Some(0.921875))),
        ev(1793600000003, "phone-7", notsame("B", "A", By::User)),
        ev(1793600000004, "phone-7", Kind::Prefer { copy: s("B") }),
        ev(1793600000005, "phone-7", Kind::Unsort { copy: s("A"), by: By::User }),
        ev(1793600000006, "phone-7", retire("A", "210", 1)),
        ev(1793600000007, "phone-7", title("A", "Well \"Water\" Handbook")),
        ev(1793600000008, "phone-7", Kind::Remove { copy: s("A") }),
        ev(1793600000009, "phone-7", Kind::Restore { copy: s("A") }),
        ev(1793600000010, "phone-7", Kind::Folder { folder_id: s("books"), label: s("Books"), mode: FolderMode::Keep }),
        ev(1793600000011, "phone-7", Kind::Locate { copy: s("A"), folder_id: s("books"), relpath: s("Firearms/Gun.pdf"), version: Some(2), source_blake3: Some("a".repeat(64)) }),
        ev(1793600000012, "phone-7", Kind::Unlocate { copy: s("A"), folder_id: s("books"), relpath: s("Old.pdf") }),
        ev(1793600000013, "phone-7", same("C", "A", By::User, None)),
    ];
    for e in &all {
        assert_eq!(Event::from_line(&e.to_line()).as_ref(), Some(e), "{}", e.to_line());
    }
    assert_eq!(all[0].to_line(), r#"{"v":1,"at":1793600000000,"dev":"phone-7","ev":"place","copy":"A","div":"210","by":"auto","loc":"recon/wm"}"#);
    assert_eq!(all[1].to_line(), r#"{"v":1,"at":1793600000001,"dev":"phone-7","ev":"assign","copy":"A","div":"210","seq":1}"#);
    assert_eq!(all[2].to_line(), r#"{"v":1,"at":1793600000002,"dev":"phone-7","ev":"same","copy":"B","with":"A","by":"auto","how":"text","score":0.921875}"#);
    assert_eq!(all[3].to_line(), r#"{"v":1,"at":1793600000003,"dev":"phone-7","ev":"notsame","copy":"B","with":"A","by":"user"}"#);
    assert_eq!(all[4].to_line(), r#"{"v":1,"at":1793600000004,"dev":"phone-7","ev":"prefer","copy":"B"}"#);
    assert_eq!(all[13].to_line(), r#"{"v":1,"at":1793600000013,"dev":"phone-7","ev":"same","copy":"C","with":"A","by":"user","how":"user"}"#);
}

#[test]
fn lines_a_reader_does_not_take_are_skipped_and_unknown_keys_ignored() {
    assert!(Event::from_line("").is_none());
    assert!(Event::from_line(r#"{"v":2,"at":1,"dev":"d","ev":"remove","copy":"x"}"#).is_none());
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"explode","copy":"x"}"#).is_none());
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"place","copy":"x","div":"210","by":"robot"}"#).is_none());
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"assign","copy":"x","div":"210"}"#).is_none());
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"remove","doc":"x"}"#).is_none(), "doc is the old key");
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"same","copy":"x","with":"x","by":"auto","how":"text"}"#).is_none(), "a copy is not linked with itself");
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"same","copy":"x","with":"y","by":"auto","how":"magic"}"#).is_none());
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"remove","copy":"x","note":"later"}"#).is_some());
    // the old library logs have no same, notsame or prefer
    assert!(Event::from_legacy_line(r#"{"v":1,"at":1,"dev":"d","ev":"prefer","doc":"x"}"#).is_none());
    assert_eq!(Event::from_legacy_line(r#"{"v":1,"at":1,"dev":"d","ev":"remove","doc":"x"}"#).unwrap().kind, Kind::Remove { copy: s("x") });
    assert!(valid_relpath("a/b.pdf") && !valid_relpath("../a") && !valid_relpath("/a") && !valid_relpath("a\\b") && !valid_relpath("c:/a") && !valid_relpath("a//b"));
}

#[test]
fn a_torn_last_line_is_skipped_counted_and_the_next_append_does_not_glue_to_it() {
    let a = ev(1, "d1", place("x", "210")).to_line();
    let b = ev(2, "d1", assign("x", "210", 1)).to_line();
    let torn = &b[..b.len() - 9];
    let (events, skipped) = parse_log(&format!("{a}\n{torn}"));
    assert_eq!((events.len(), skipped), (1, 1));
    let tmp = Tmp::new("torn");
    let dir = tmp.path().join("log");
    let w = LogWriter::open(&dir, "d1").unwrap();
    std::fs::write(w.path(), format!("{a}\n{torn}")).unwrap();
    w.append(&[ev(3, "d1", Kind::Remove { copy: s("x") })]).unwrap();
    let set = read_logs(&dir).unwrap();
    assert_eq!((set.events.len(), set.skipped), (2, 1));
    assert_eq!(set.events[1].kind, Kind::Remove { copy: s("x") });
    let r = resolve(&set.events, &[lib("L", vec![pf("x", "x", "X", 1)])]);
    assert!(r.book_of("x").unwrap().removed);
}

#[test]
fn append_adds_whole_lines_to_its_own_file_only_and_holds_the_clock() {
    let tmp = Tmp::new("append");
    let dir = tmp.path().join("log");
    let w = LogWriter::open(&dir, "phone-1").unwrap();
    w.append(&[ev(10, "phone-1", place("a", "210")), ev(20, "phone-1", assign("a", "210", 1))]).unwrap();
    // a clock set back is held at the last event
    let written = w.append(&[ev(5, "phone-1", Kind::Remove { copy: s("a") }), ev(6, "phone-1", Kind::Restore { copy: s("a") })]).unwrap();
    assert_eq!(written.iter().map(|e| e.at).collect::<Vec<_>>(), [20, 20]);
    let text = std::fs::read_to_string(dir.join("phone-1.jsonl")).unwrap();
    assert_eq!(text.lines().count(), 4);
    assert!(text.ends_with('\n'));
    // one writer per file
    assert!(w.append(&[ev(30, "phone-2", Kind::Remove { copy: s("a") })]).is_err());
    assert!(LogWriter::open(&dir, "../evil").is_err());
    assert!(LogWriter::open(&dir, ".hidden").is_err());
    // refused events write nothing
    let bad = ev(31, "phone-1", Kind::Locate { copy: s("a"), folder_id: s("f"), relpath: s("../x"), version: None, source_blake3: None });
    assert!(w.append(&[ev(31, "phone-1", Kind::Remove { copy: s("a") }), bad]).is_err());
    assert!(w.append(&[ev(31, "phone-1", same("a", "a", By::Auto, None))]).is_err());
    assert_eq!(std::fs::read_to_string(dir.join("phone-1.jsonl")).unwrap(), text);
    // every log in the folder is read, in file-name order; other files are ignored
    LogWriter::open(&dir, "builder-x").unwrap().append(&[ev(9, "builder-x", place("b", "320"))]).unwrap();
    std::fs::write(dir.join("notes.txt"), "not a log").unwrap();
    std::fs::write(dir.join(".phone-3.jsonl"), "{}").unwrap();
    let set = read_logs(&dir).unwrap();
    assert_eq!(set.files.iter().map(|f| f.0.as_str()).collect::<Vec<_>>(), ["builder-x.jsonl", "phone-1.jsonl"]);
    assert_eq!(set.events.len(), 5);
    assert!(read_logs(&tmp.path().join("nothing")).unwrap().events.is_empty());
}

// ------------------------------------------------------------------------------------------------------------- resolution

#[test]
fn a_book_is_shelved_numbered_moved_and_unsorted() {
    let libs = abc();
    let mut events = vec![ev(1, "d", place("A", "210")), ev(2, "d", assign("A", "210", 1))];
    let r = resolve(&events, &libs);
    assert_eq!(call(&r, "A").as_deref(), Some("CDS 210-001"));
    assert_eq!(r.book_of("A").unwrap().shelf.as_deref(), Some("210"));
    // a book nothing placed: not shelved, no number
    assert!(!r.book_of("B").unwrap().shelved && call(&r, "B").is_none());
    // a move: place, retire, assign
    events.extend([ev(3, "d", place("A", "220")), ev(4, "d", retire("A", "210", 1)), ev(5, "d", assign("A", "220", 1))]);
    let r = resolve(&events, &libs);
    assert_eq!(call(&r, "A").as_deref(), Some("CDS 220-001"));
    assert_eq!(r.retired["210"].iter().copied().collect::<Vec<_>>(), [1]);
    // 210-1 is never reused
    assert_eq!(r.next_seq("210"), 2);
    assert_eq!(r.next_seq("220"), 2);
    assert_eq!(r.next_seq("999"), 1);
    // unsorting clears the number
    events.extend([ev(6, "d", Kind::Unsort { copy: s("A"), by: By::User }), ev(7, "d", retire("A", "220", 1))]);
    let r = resolve(&events, &libs);
    let a = r.book_of("A").unwrap();
    assert!(a.shelved && a.shelf.is_none() && a.call.is_none());
    // call numbers grow past 999
    let r = resolve(&[ev(1, "d", place("A", "210")), ev(2, "d", assign("A", "210", 1000))], &libs);
    assert_eq!(call(&r, "A").as_deref(), Some("CDS 210-1000"));
}

#[test]
fn the_clash_suffix_across_devices_ranks_by_at_then_copy() {
    let libs = vec![lib("L", vec![pf("p", "p", "P", 5), pf("s", "s", "S", 5)])];
    let events = vec![
        ev(100, "phone", place("p", "210")),
        ev(101, "phone", assign("p", "210", 2)),
        ev(200, "server", place("s", "210")),
        ev(201, "server", assign("s", "210", 2)),
    ];
    let r = resolve(&events, &libs);
    assert_eq!((call(&r, "p").as_deref(), call(&r, "s").as_deref()), (Some("CDS 210-002"), Some("CDS 210-002.1")));
    assert_eq!(r.next_seq("210"), 3);
    // the same at on two devices: the copy key settles it, whatever the device names
    let tie = vec![
        ev(101, "zzz", place("p", "210")),
        ev(101, "zzz", assign("p", "210", 2)),
        ev(101, "aaa", place("s", "210")),
        ev(101, "aaa", assign("s", "210", 2)),
    ];
    let r = resolve(&tie, &libs);
    assert_eq!((call(&r, "p").as_deref(), call(&r, "s").as_deref()), (Some("CDS 210-002"), Some("CDS 210-002.1")));
    // ranks are fixed: when rank 0 moves away, rank 1 still shows .1
    let mut moved = events.clone();
    moved.extend([ev(300, "phone", place("p", "320")), ev(301, "phone", retire("p", "210", 2)), ev(302, "phone", assign("p", "320", 1))]);
    let r = resolve(&moved, &libs);
    assert_eq!((call(&r, "p").as_deref(), call(&r, "s").as_deref()), (Some("CDS 320-001"), Some("CDS 210-002.1")));
}

#[test]
fn a_merge_keeps_the_earliest_number_and_holds_the_other() {
    let libs = abc();
    let mut events = vec![
        ev(1, "d", place("A", "210")),
        ev(2, "d", assign("A", "210", 1)),
        ev(3, "d", place("B", "210")),
        ev(4, "d", assign("B", "210", 2)),
    ];
    let r = resolve(&events, &libs);
    assert!(!same_book(&r, "A", "B"));
    events.push(ev(5, "d", same("B", "A", By::Auto, Some(0.9))));
    let r = resolve(&events, &libs);
    assert!(same_book(&r, "A", "B"));
    let book = r.book_of("B").unwrap();
    assert_eq!(book.id, "A");
    assert_eq!(call(&r, "B").as_deref(), Some("CDS 210-001"));
    // the other number is held, not retired and not reusable
    assert_eq!(own(&r, "B").as_deref(), Some("CDS 210-002"));
    assert!(r.retired.is_empty());
    assert_eq!(r.next_seq("210"), 3);
    // the reading copy is the better one; the equal ones go by the lower key
    assert_eq!(book.reading, "A");
}

#[test]
fn a_split_restores_every_number() {
    let libs = abc();
    let events = vec![
        ev(1, "d", place("A", "210")),
        ev(2, "d", assign("A", "210", 1)),
        ev(3, "d", place("B", "210")),
        ev(4, "d", assign("B", "210", 2)),
        ev(5, "d", same("B", "A", By::Auto, Some(0.9))),
        ev(6, "d", notsame("B", "A", By::User)),
    ];
    let r = resolve(&events, &libs);
    assert!(!same_book(&r, "A", "B"));
    assert_eq!((call(&r, "A").as_deref(), call(&r, "B").as_deref()), (Some("CDS 210-001"), Some("CDS 210-002")));
    assert_eq!(r.next_seq("210"), 3, "no number was written or lost");
    // a person can merge them again afterwards
    let mut again = events.clone();
    again.push(ev(7, "d", same("A", "B", By::User, None)));
    assert!(same_book(&resolve(&again, &libs), "A", "B"));
}

#[test]
fn a_notsame_through_a_third_copy_cuts_the_weakest_link() {
    let libs = abc();
    let link = |ab: f64, bc: f64| {
        vec![
            ev(1, "d", same("B", "A", By::Auto, Some(ab))),
            ev(2, "d", same("C", "B", By::Auto, Some(bc))),
            ev(3, "d", notsame("C", "A", By::User)),
        ]
    };
    // A-B is the weaker link: A leaves, B and C stay together
    let r = resolve(&link(0.9, 0.95), &libs);
    assert!(!same_book(&r, "A", "C") && !same_book(&r, "A", "B") && same_book(&r, "B", "C"));
    // B-C is the weaker link: C leaves
    let r = resolve(&link(0.95, 0.9), &libs);
    assert!(!same_book(&r, "A", "C") && same_book(&r, "A", "B") && !same_book(&r, "B", "C"));
    // equal strength: the auto link goes before the user's
    let r = resolve(
        &[ev(1, "d", same("B", "A", By::User, None)), ev(2, "d", same("C", "B", By::Auto, None)), ev(3, "d", notsame("C", "A", By::User))],
        &libs,
    );
    assert!(same_book(&r, "A", "B") && !same_book(&r, "B", "C"));
    // a long chain: every path between the two is cut
    let libs4 = vec![lib("L", vec![pf("A", "a", "A", 1), pf("B", "b", "B", 1), pf("C", "c", "C", 1), pf("D", "d", "D", 1)])];
    let r = resolve(
        &[
            ev(1, "d", same("B", "A", By::Auto, Some(0.99))),
            ev(2, "d", same("C", "B", By::Auto, Some(0.98))),
            ev(3, "d", same("D", "C", By::Auto, Some(0.97))),
            ev(4, "d", same("D", "A", By::Auto, Some(0.96))),
            ev(5, "d", notsame("D", "B", By::User)),
        ],
        &libs4,
    );
    assert!(!same_book(&r, "B", "D"));
}

#[test]
fn a_users_word_beats_the_detectors_for_the_same_pair() {
    let libs = abc();
    // the user said notsame EARLIER than the detector's same: the user still wins
    let r = resolve(&[ev(5, "d", notsame("B", "A", By::User)), ev(50, "d", same("B", "A", By::Auto, Some(0.99)))], &libs);
    assert!(!same_book(&r, "A", "B"));
    // the user said same, the detector later said notsame: the user still wins
    let r = resolve(&[ev(5, "d", same("B", "A", By::User, None)), ev(50, "d", notsame("A", "B", By::Auto))], &libs);
    assert!(same_book(&r, "A", "B"));
    // between two of the same kind of author the latest wins, whichever way round the pair is written
    let r = resolve(&[ev(5, "d", notsame("B", "A", By::User)), ev(6, "d", same("A", "B", By::User, None))], &libs);
    assert!(same_book(&r, "A", "B"));
    let r = resolve(&[ev(5, "d", same("A", "B", By::User, None)), ev(6, "d", notsame("B", "A", By::User))], &libs);
    assert!(!same_book(&r, "A", "B"));
}

#[test]
fn shelf_title_removed_and_the_reading_copy() {
    let mut libs = vec![lib("L", vec![pf("A", "a", "Wilderness Medicine", 300), pf("B", "b", "Wilderness Medicine 7th ed", 312), pf("C", "c", "Other", 10)])];
    libs[0].seed.title.insert(s("b"), s("Wilderness Medicine Handbook"));
    let mut events = vec![ev(1, "d", same("B", "A", By::Auto, Some(0.9)))];
    // the reading copy: B has more text pages; the publisher's title for B is the default; A's pack title is "also known as"
    let r = resolve(&events, &libs);
    let b = r.book_of("A").unwrap();
    assert_eq!(b.reading, "B");
    assert_eq!((b.title.as_str(), b.title_from), ("Wilderness Medicine Handbook", TitleFrom::Seed));
    assert_eq!(b.aka, ["Wilderness Medicine"]);
    // without a seed title the reading copy's pack title is the title
    libs[0].seed.title.clear();
    let r = resolve(&events, &libs);
    let b = r.book_of("A").unwrap();
    assert_eq!((b.title.as_str(), b.title_from), ("Wilderness Medicine 7th ed", TitleFrom::Pack));
    // the person's title beats both, wherever it was written
    libs[0].seed.title.insert(s("b"), s("Publisher"));
    events.push(ev(2, "d", title("A", "My name for it")));
    events.push(ev(3, "d", title("B", "Latest name")));
    let r = resolve(&events, &libs);
    let b = r.book_of("A").unwrap();
    assert_eq!((b.title.as_str(), b.title_from), ("Latest name", TitleFrom::Log));
    assert_eq!(b.aka, ["Wilderness Medicine"]);
    // prefer picks the reading copy; a preferred copy that no library holds is ignored
    events.push(ev(4, "d", Kind::Prefer { copy: s("A") }));
    assert_eq!(resolve(&events, &libs).book_of("A").unwrap().reading, "A");
    events.push(ev(5, "d", Kind::Prefer { copy: s("ghost") }));
    events.push(ev(6, "d", same("ghost", "A", By::Auto, Some(0.9))));
    assert_eq!(resolve(&events, &libs).book_of("A").unwrap().reading, "B");
    // shelf: the latest place over all copies; removed: the latest remove or restore over all copies
    events.extend([ev(10, "d", place("A", "610")), ev(11, "d", place("B", "620")), ev(12, "d", Kind::Remove { copy: s("A") })]);
    let r = resolve(&events, &libs);
    let b = r.book_of("A").unwrap();
    assert_eq!((b.shelf.as_deref(), b.removed), (Some("620"), true));
    events.push(ev(13, "d", Kind::Restore { copy: s("B") }));
    assert!(!resolve(&events, &libs).book_of("A").unwrap().removed);
    // a copy no library holds is listed, but not available
    let ghost = resolve(&events, &libs).book_of("A").unwrap().copies.iter().find(|c| c.copy == "ghost").cloned().unwrap();
    assert!(!ghost.available());
    // a book with no copy in any library is not listed, but its numbers still count
    let r = resolve(&[ev(1, "d", place("zzz", "510")), ev(2, "d", assign("zzz", "510", 7))], &libs);
    assert!(r.book_of("zzz").is_none());
    assert_eq!(r.next_seq("510"), 8);
}

#[test]
fn the_suggestion_is_the_seed_place_then_the_pack() {
    let mut a = pf("A", "a", "A", 1);
    a.suggested = Some(SuggestedDiv { div: s("440"), label: s("Stone"), ..Default::default() });
    let mut l = lib("L", vec![a, pf("B", "b", "B", 1)]);
    l.seed.place.insert(s("a"), Some(s("450")));
    l.seed.place.insert(s("b"), None);
    let r = resolve(&[], &[l.clone()]);
    let sa = r.book_of("A").unwrap().suggested.clone().unwrap();
    assert_eq!((sa.div.as_str(), sa.from), ("450", "seed"));
    assert!(r.book_of("B").unwrap().suggested.is_none());
    l.seed.place.clear();
    let sa = resolve(&[], &[l]).book_of("A").unwrap().suggested.clone().unwrap();
    assert_eq!((sa.div.as_str(), sa.label.as_deref(), sa.from), ("440", Some("Stone"), "pack"));
}

#[test]
fn a_book_is_confident_only_when_the_pack_says_so_and_carries_its_top_three() {
    let shelf = |d: &str, l: &str, x: f32| SuggestedShelf { div: s(d), label: s(l), score: Some(x) };
    let top = vec![shelf("610", "Medicine", 0.41), shelf("620", "Engineering", 0.3), shelf("570", "Life sciences", 0.2)];
    let mut a = pf("A", "a", "A", 1);
    a.suggested = Some(SuggestedDiv { div: s("610"), label: s("Medicine"), filed: Some(false), suggestions: top.clone() });
    let mut b = pf("B", "b", "B", 1);
    b.suggested = Some(SuggestedDiv { div: s("610"), label: s("Medicine"), filed: Some(true), suggestions: top.clone() });
    // an old pack: a division and no flag
    let mut c = pf("C", "c", "C", 1);
    c.suggested = Some(SuggestedDiv { div: s("610"), label: s("Medicine"), ..Default::default() });
    let mut d = pf("D", "d", "D", 1);
    d.suggested = Some(SuggestedDiv { div: s("610"), label: s("Medicine"), filed: Some(false), suggestions: top.clone() });
    let mut l = lib("L", vec![a, b, c, d]);
    l.seed.place.insert(s("d"), Some(s("620"))); // the publisher placed D
    let r = resolve(&[], &[l.clone()]);
    let sg = |k: &str| r.book_of(k).unwrap().suggested.clone().unwrap();
    assert!(!sg("A").filed, "the sorter was not confident: stays in Unsorted");
    assert_eq!(sg("A").top.iter().map(|x| x.div.as_str()).collect::<Vec<_>>(), ["610", "620", "570"]);
    assert!(sg("B").filed);
    assert!(!sg("C").filed, "no flag (an old pack) is not confident");
    assert!(sg("C").top.is_empty());
    assert!(sg("D").filed && sg("D").from == "seed", "a seed place is the publisher's own filing");
    // and in the view, and through copies.jsonl
    let view = view_value(&r, &[l.clone()], &[]);
    assert_eq!(view["books"]["A"]["suggested"]["filed"], json!(false));
    assert_eq!(view["books"]["A"]["suggested"]["suggestions"][2], json!({"div": "570", "label": "Life sciences", "score": 0.2f32}));
    assert_eq!(view["books"]["C"]["suggested"]["filed"], json!(false));
    assert!(view["books"]["C"]["suggested"].get("suggestions").is_none());
    let line = l.copies[0].to_copies_line();
    assert_eq!(PackFacts::from_copies_line(&line).unwrap().suggested, l.copies[0].suggested, "the copies line keeps the flag and the three");
    let plain = l.copies[2].to_copies_line();
    assert!(!plain.contains("filed") && !plain.contains("suggestions"), "an old copy writes the bytes it always did: {plain}");
}

#[test]
fn a_header_with_filed_and_suggestions_is_read_from_the_pack() {
    let line = json!({
        "cdoc": 1, "doc_id": "wm", "doc_version": 1, "title": "T", "source": {"blake3": "stored"},
        "book": {"title": "T", "original_blake3": "O", "suggested": {"div": "610", "label": "Medicine", "source": "classifier", "second_div": "620", "filed": false,
            "suggestions": [{"div": "610", "label": "Medicine", "score": 0.41}, {"div": "620", "label": "Eng"}, {"div": "570"}]}}
    })
    .to_string();
    let f = PackFacts::from_header_line(&line).unwrap().suggested.unwrap();
    assert_eq!((f.filed, f.suggestions.len()), (Some(false), 3));
    assert_eq!((f.suggestions[1].score, f.suggestions[2].label.as_str()), (None, ""));
}

#[test]
fn linked_folder_locations_and_folders_resolve_by_stamp() {
    let libs = abc();
    let locate = |copy: &str, path: &str| Kind::Locate { copy: s(copy), folder_id: s("books"), relpath: s(path), version: None, source_blake3: None };
    let events = vec![
        ev(1, "linux", Kind::Folder { folder_id: s("books"), label: s("Books"), mode: FolderMode::Keep }),
        ev(2, "linux", Kind::Folder { folder_id: s("books"), label: s("My books"), mode: FolderMode::Both }),
        ev(3, "linux", locate("A", "old.pdf")),
        ev(4, "linux", Kind::Unlocate { copy: s("A"), folder_id: s("books"), relpath: s("old.pdf") }),
        ev(5, "linux", locate("A", "new.pdf")),
        ev(6, "linux", locate("A", "Zed/a.pdf")),
        ev(7, "mac", locate("A", "a.pdf")),
    ];
    let r = resolve(&events, &libs);
    assert_eq!(r.folders.len(), 1);
    assert_eq!((r.folders[0].label.as_str(), r.folders[0].mode), ("My books", FolderMode::Both));
    let a = &r.book_of("A").unwrap().copies[0];
    assert_eq!(a.locations.iter().map(|l| (l.dev.as_str(), l.relpath.as_str())).collect::<Vec<_>>(), [("linux", "Zed/a.pdf"), ("linux", "new.pdf"), ("mac", "a.pdf")]);
}

#[test]
fn the_view_is_the_same_bytes_for_any_read_order() {
    let mut libs = abc();
    libs.push(lib("M", vec![pf("A", "a-copy", "Book A", 10), pf("D", "d", "Book D", 4)]));
    let per_dev: Vec<Vec<Event>> = vec![
        vec![
            ev(10, "phone", place("A", "210")),
            ev(11, "phone", assign("A", "210", 1)),
            ev(12, "phone", same("B", "A", By::Auto, Some(0.9))),
            ev(12, "phone", place("B", "220")),
        ],
        vec![ev(10, "linux", place("A", "310")), ev(11, "linux", assign("C", "310", 1)), ev(11, "linux", assign("D", "310", 1)), ev(15, "linux", title("D", "Dee"))],
        vec![ev(9, "aaa", notsame("D", "C", By::Auto)), ev(13, "aaa", Kind::Remove { copy: s("C") }), ev(14, "aaa", same("D", "C", By::User, None))],
    ];
    let make = |order: &[usize], lib_order: &[usize]| -> Vec<u8> {
        let events: Vec<Event> = order.iter().flat_map(|i| per_dev[*i].clone()).collect();
        let l: Vec<LibraryInput> = lib_order.iter().map(|i| libs[*i].clone()).collect();
        view_bytes(&view_value(&resolve(&events, &l), &l, &[("x.jsonl".into(), 1)])).unwrap()
    };
    let want = make(&[0, 1, 2], &[0, 1]);
    for order in [[0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
        assert_eq!(make(&order, &[0, 1]), want, "{order:?}");
        assert_eq!(make(&order, &[1, 0]), want, "{order:?} with the libraries the other way round");
    }
    // and the same through the files: written by device, read in file-name order
    let tmp = Tmp::new("order");
    for evs in &per_dev {
        LogWriter::open(&tmp.path().join("log"), &evs[0].dev).unwrap().append(evs).unwrap();
    }
    let set = read_logs(&tmp.path().join("log")).unwrap();
    let from_files = view_bytes(&view_value(&resolve(&set.events, &libs), &libs, &[("x.jsonl".into(), 1)])).unwrap();
    assert_eq!(from_files, want);
}

// ----------------------------------------------------------------------------------------------- libraries, import, ops

fn header_line(doc: &str, original: &str, title: &str, div: &str) -> String {
    json!({
        "cdoc": 1, "doc_id": doc, "doc_version": 1, "title": title, "source": {"blake3": "stored"},
        "book": {"title": title, "original_blake3": original, "suggested": {"div": div, "label": "L", "source": "classifier"}},
        "samebook": {"minhash": [], "mean_vector": "", "text_pages": 10, "pages": 10, "ppi": 150, "source_size": 99}
    })
    .to_string()
}

/// A library folder with packs (the file content is the header line; the test's reader returns it as is) and logs.
fn make_library(root: &Path, id: &str, books: &[(&str, &str, &str)], logs: &[(&str, String)]) -> LibraryRef {
    let dir = root.join(id);
    std::fs::create_dir_all(dir.join("packs")).unwrap();
    std::fs::create_dir_all(dir.join("log")).unwrap();
    for (doc, original, title) in books {
        std::fs::write(dir.join("packs").join(format!("{doc}@1.cdoc")), header_line(doc, original, title, "210")).unwrap();
        // an older version of the same book is ignored
        std::fs::write(dir.join("packs").join(format!("{doc}@0.cdoc")), header_line(doc, "stale", "Stale", "999")).unwrap();
    }
    for (name, text) in logs {
        std::fs::write(dir.join("log").join(name), text).unwrap();
    }
    LibraryRef::new(id, &dir)
}

fn reader(p: &Path) -> Result<String, String> {
    std::fs::read_to_string(p).map_err(|e| e.to_string())
}

fn legacy(at: u64, dev: &str, ev: &str, doc: &str, rest: &str) -> String {
    format!("{{\"v\":1,\"at\":{at},\"dev\":\"{dev}\",\"ev\":\"{ev}\",\"doc\":\"{doc}\"{rest}}}\n")
}

#[test]
fn a_seed_log_is_a_suggestion_and_its_numbers_are_never_call_numbers() {
    let tmp = Tmp::new("seed");
    let seed = [
        legacy(5, "builder-pub", "place", "wm", ",\"div\":\"610\",\"by\":\"auto\""),
        legacy(5, "builder-pub", "assign", "wm", ",\"div\":\"610\",\"seq\":1"),
        legacy(6, "builder-pub", "title", "wm", ",\"title\":\"Wilderness Medicine Handbook\""),
        legacy(7, "builder-pub", "unsort", "ps", ",\"by\":\"auto\""),
    ]
    .concat();
    // an old per-device log in the same folder is not a seed
    let other = legacy(8, "phone", "place", "ps", ",\"div\":\"999\",\"by\":\"user\"");
    let lref = make_library(tmp.path(), "pub", &[("wm", "WM", "Wilderness Medicine"), ("ps", "PS", "Pocket Survival")], &[("builder-pub.jsonl", seed), ("phone.jsonl", other)]);
    let l = load_library(&lref, &reader).unwrap();
    assert_eq!(l.copies.len(), 2, "the highest version of each book");
    assert_eq!(l.seed.place.get("wm"), Some(&Some(s("610"))));
    assert_eq!(l.seed.place.get("ps"), Some(&None));
    assert_eq!(l.seed.title.get("wm").map(String::as_str), Some("Wilderness Medicine Handbook"));
    let r = resolve(&[], &[l]);
    let wm = r.book_of("WM").unwrap();
    assert!(wm.call.is_none() && !wm.shelved, "the seed's assign is not a call number");
    assert_eq!((wm.title.as_str(), wm.title_from), ("Wilderness Medicine Handbook", TitleFrom::Seed));
    assert_eq!(wm.suggested.as_ref().map(|s| s.div.as_str()), Some("610"));
    assert!(r.next.is_empty(), "the seed's numbers are not counted either");
}

#[test]
fn the_import_maps_doc_to_copy_once_and_records_it() {
    let tmp = Tmp::new("import");
    let shelves = tmp.path().join("bookshelves");
    let me = [
        legacy(1, "me", "place", "wm", ",\"div\":\"610\",\"by\":\"user\""),
        legacy(2, "me", "assign", "wm", ",\"div\":\"610\",\"seq\":3"),
        legacy(3, "me", "title", "wm", ",\"title\":\"Mine\""),
        legacy(4, "me", "place", "nopack", ",\"div\":\"610\",\"by\":\"user\""),
        "{\"v\":1,\"at\":5,\"dev\":\"me\",\"ev\":\"folder\",\"folder_id\":\"f\",\"label\":\"F\",\"mode\":\"keep\"}\n".to_string(),
        "torn".to_string(),
    ]
    .concat();
    let someone = legacy(2, "friend", "assign", "wm", ",\"div\":\"610\",\"seq\":1");
    let l1 = make_library(tmp.path(), "one", &[("wm", "WM-HASH", "WM")], &[("me.jsonl", me), ("friend.jsonl", someone.clone())]);
    let l2 = make_library(tmp.path(), "two", &[("wm-copy", "WM-HASH", "WM")], &[("me.jsonl", legacy(9, "me", "remove", "wm-copy", ""))]);
    let loaded: Vec<(LibraryRef, LibraryInput)> = [l1.clone(), l2.clone()].into_iter().map(|l| (l.clone(), load_library(&l, &reader).unwrap())).collect();
    let rep = import_own(&shelves, "me", &loaded).unwrap();
    assert_eq!(rep.events, 5);
    let by_lib = |id: &str| rep.files.iter().find(|f| f.library_id == id).unwrap().clone();
    assert_eq!((by_lib("one").events, by_lib("one").unmapped, by_lib("one").already), (4, 1, false));
    assert_eq!(by_lib("two").events, 1);

    let set = read_logs(&shelves.join("log")).unwrap();
    assert_eq!(set.files.iter().map(|f| f.0.as_str()).collect::<Vec<_>>(), ["me.jsonl"]);
    assert!(set.events.iter().all(|e| e.dev == "me"));
    let first = &set.events[0];
    assert_eq!((first.kind.copy(), first.loc.as_deref()), (Some("WM-HASH"), Some("one/wm")));
    // both libraries' copies of the book are the same copy, and the old number survives
    let libs: Vec<LibraryInput> = loaded.iter().map(|l| l.1.clone()).collect();
    let r = resolve(&set.events, &libs);
    let b = r.book_of("WM-HASH").unwrap();
    assert_eq!(b.copies.len(), 1);
    assert_eq!(b.copies[0].locs, ["one/wm", "two/wm-copy"]);
    assert_eq!((b.call.as_ref().map(|c| c.text.as_str()), b.title.as_str(), b.removed), (Some("CDS 610-003"), "Mine", true));
    assert_eq!(r.folders.len(), 1);
    // recorded
    let rec: Value = serde_json::from_slice(&std::fs::read(shelves.join(".local/migrated.json")).unwrap()).unwrap();
    // the file with an unmapped event is not recorded (it stays eligible); the fully mapped one is
    assert!(rec["files"].get("one/me.jsonl").is_none());
    assert_eq!(rec["files"]["two/me.jsonl"]["events"], json!(1));
    // a second run writes nothing new
    let again = import_own(&shelves, "me", &loaded).unwrap();
    assert_eq!(again.events, 0);
    assert!(again.files.iter().find(|f| f.library_id == "two").unwrap().already);
    assert_eq!(read_logs(&shelves.join("log")).unwrap().events.len(), 5);
}

#[test]
fn the_ops_take_and_give_json() {
    let tmp = Tmp::new("ops");
    let shelves = tmp.path().join("bookshelves");
    let lref = make_library(tmp.path(), "L", &[("wm", "WM", "Wilderness Medicine"), ("wm2", "WM2", "Wilderness Medicine, 2nd scan")], &[]);
    let dir = shelves.to_str().unwrap();
    let out = ops::append(&json!({"dir": dir, "dev": "phone-1", "events": [
        {"ev": "place", "copy": "WM", "div": "610", "by": "auto", "loc": "L/wm"},
        {"ev": "assign", "copy": "WM", "div": "610", "seq": 1},
        {"ev": "same", "copy": "WM2", "with": "WM", "by": "auto", "how": "text", "score": 0.9}
    ]}).to_string()).unwrap();
    let out: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(out["written"], json!(3));
    assert!(ops::append(&json!({"dir": dir, "dev": "phone-1", "events": [{"ev": "nonsense", "copy": "x"}]}).to_string()).is_err());
    assert!(ops::append(&json!({"dir": dir, "dev": "phone-1", "events": [{"ev": "remove", "copy": "x", "dev": "phone-2"}]}).to_string()).is_err());

    let libs = json!([{"library_id": "L", "dir": lref.dir.to_str().unwrap()}]);
    let view: Value = serde_json::from_str(&ops::resolve_view(&json!({"dir": dir, "libraries": libs}).to_string(), &reader).unwrap()).unwrap();
    assert_eq!(view["format"], json!(1));
    let book = &view["books"]["WM"];
    assert_eq!(book["call"]["text"], json!("CDS 610-001"));
    assert_eq!(book["reading"], json!("WM"));
    assert_eq!(book["copies"].as_array().unwrap().len(), 2);
    assert_eq!(view["next"]["610"], json!(2));
    assert_eq!(view["built_from"]["libraries"]["L"]["packs"], json!(2));
    // the view the crate builds is the one the op returns
    let direct = build_view(&shelves, &[lref.clone()], &reader).unwrap();
    assert_eq!(direct, view);

    let det = ops::detect(&json!({"copy": {"copy": "a", "blake3": "h"}, "against": [{"copy": "b", "blake3": "h"}, {"copy": "c", "blake3": "x"}]}).to_string(), &reader).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&det).unwrap(), json!([{"with": "b", "how": "blake3", "score": 1.0}]));

    let imp: Value = serde_json::from_str(&ops::import(&json!({"dir": dir, "dev": "phone-1", "libraries": libs}).to_string(), &reader).unwrap()).unwrap();
    assert_eq!(imp["events"], json!(0));
}

// ------------------------------------------------------------------------------------------------------------------ facts

fn facts_ev(copy: &str, author: Option<&str>, edition: Option<&str>, year: Option<u32>) -> Kind {
    Kind::Facts { copy: s(copy), fields: cache_shelves::events::FactFields { author: author.map(s), edition: edition.map(s), year } }
}

#[test]
fn a_facts_event_drops_invalid_fields_and_round_trips() {
    let line = r#"{"v":1,"at":1,"dev":"d","ev":"facts","copy":"A","author":"  Ann  ","edition":"7th edition","year":2018}"#;
    let e = Event::from_line(line).unwrap();
    assert_eq!(e.kind, facts_ev("A", Some("Ann"), Some("7th edition"), Some(2018)));
    assert_eq!(e.to_line(), r#"{"v":1,"at":1,"dev":"d","ev":"facts","copy":"A","author":"Ann","edition":"7th edition","year":2018}"#);
    let long = "x".repeat(201);
    let bad = json!({"v": 1, "at": 1, "dev": "d", "ev": "facts", "copy": "A", "author": long, "edition": "e".repeat(61), "year": 1399}).to_string();
    assert!(Event::from_line(&bad).is_none(), "nothing valid left: the event is skipped");
    let some = json!({"v": 1, "at": 1, "dev": "d", "ev": "facts", "copy": "A", "author": "", "edition": "2nd", "year": 2101}).to_string();
    assert_eq!(Event::from_line(&some).unwrap().kind, facts_ev("A", None, Some("2nd"), None));
    for y in ["\"2018\"", "2018.5", "1400.0"] {
        let l = format!(r#"{{"v":1,"at":1,"dev":"d","ev":"facts","copy":"A","edition":"x","year":{y}}}"#);
        assert_eq!(Event::from_line(&l).unwrap().kind, facts_ev("A", None, Some("x"), None), "{y}");
    }
    assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"facts","copy":"A","year":2100}"#).is_some());
    // the writer refuses what the reader would drop
    let tmp = Tmp::new("facts");
    let w = LogWriter::open(&tmp.path().join("log"), "d").unwrap();
    assert!(w.append(&[ev(1, "d", facts_ev("A", Some(&"x".repeat(201)), None, None))]).is_err());
    assert!(w.append(&[ev(1, "d", facts_ev("A", None, None, Some(1399)))]).is_err());
    assert!(w.append(&[ev(1, "d", facts_ev("A", None, None, None))]).is_err());
    w.append(&[ev(1, "d", facts_ev("A", Some("Ann"), None, Some(1400)))]).unwrap();
}

#[test]
fn facts_resolve_per_field_person_then_publisher_then_pack() {
    let mut a = pf("A", "a", "Book A", 10);
    a.fields = cache_shelves::events::FactFields { author: Some(s("Pack Author")), edition: Some(s("Pack ed")), year: Some(2000) };
    let mut l = lib("L", vec![a, pf("B", "b", "Book B", 5)]);
    let none = resolve(&[], &[l.clone()]);
    let b = none.book_of("A").unwrap();
    assert_eq!((b.author.as_deref(), b.edition.as_deref(), b.year), (Some("Pack Author"), Some("Pack ed"), Some(2000)));
    // no source at all: null
    let b = none.book_of("B").unwrap();
    assert_eq!((b.author.as_deref(), b.edition.as_deref(), b.year), (None, None, None));
    // the publisher's seed-log facts beat the pack, per field (the seed gives author and year only)
    l.seed.facts.insert(s("a"), cache_shelves::events::FactFields { author: Some(s("Seed Author")), edition: None, year: Some(2010) });
    let r = resolve(&[], &[l.clone()]);
    let b = r.book_of("A").unwrap();
    assert_eq!((b.author.as_deref(), b.edition.as_deref(), b.year), (Some("Seed Author"), Some("Pack ed"), Some(2010)));
    // the person's own facts beat both, per field, latest wins, over any copy of the book
    let mut events = vec![ev(1, "d", same("B", "A", By::Auto, Some(0.9))), ev(2, "d", facts_ev("B", Some("My Author"), None, None)), ev(3, "d", facts_ev("A", Some("Later Author"), None, Some(1999)))];
    let r = resolve(&events, &[l.clone()]);
    let b = r.book_of("A").unwrap();
    assert_eq!((b.author.as_deref(), b.edition.as_deref(), b.year), (Some("Later Author"), Some("Pack ed"), Some(1999)));
    events.push(ev(4, "d", facts_ev("B", None, Some("My ed"), None)));
    let b = resolve(&events, &[l]).book_of("A").unwrap().clone();
    assert_eq!((b.author.as_deref(), b.edition.as_deref(), b.year), (Some("Later Author"), Some("My ed"), Some(1999)));
}

#[test]
fn seed_log_facts_are_read_per_field_and_the_view_carries_them() {
    let tmp = Tmp::new("seedfacts");
    let seed = [
        legacy(5, "builder-pub", "facts", "wm", ",\"copy\":\"WM\",\"loc\":\"pub/wm\",\"author\":\"A. Writer\",\"edition\":\"7th\""),
        legacy(6, "builder-pub", "facts", "wm", ",\"author\":\"B. Writer\",\"year\":1399"),
        legacy(7, "builder-pub", "facts", "wm", ",\"year\":2018"),
    ]
    .concat();
    let lref = make_library(tmp.path(), "pub", &[("wm", "WM", "Wilderness Medicine")], &[("builder-pub.jsonl", seed)]);
    let l = load_library(&lref, &reader).unwrap();
    let f = l.seed.facts.get("wm").unwrap();
    assert_eq!((f.author.as_deref(), f.edition.as_deref(), f.year), (Some("B. Writer"), Some("7th"), Some(2018)));
    let r = resolve(&[], std::slice::from_ref(&l));
    let v = view_value(&r, &[l], &[]);
    let book = &v["books"]["WM"];
    assert_eq!((book["author"].clone(), book["edition"].clone(), book["year"].clone()), (json!("B. Writer"), json!("7th"), json!(2018)));
    // null when unknown
    let empty = view_value(&resolve(&[], &[lib("L", vec![pf("A", "a", "A", 1)])]), &[], &[]);
    assert_eq!((empty["books"]["A"]["author"].clone(), empty["books"]["A"]["year"].clone()), (Value::Null, Value::Null));
}


// -------------------------------------------------------------------------------------------------------- review fixes

#[test]
fn one_copy_claiming_a_number_twice_gets_no_suffix() {
    let libs = abc();
    let r = resolve(&[ev(50, "d", place("A", "210")), ev(100, "d", assign("A", "210", 5)), ev(200, "d", assign("A", "210", 5))], &libs);
    assert_eq!(call(&r, "A").as_deref(), Some("CDS 210-005"));
    // another copy's claim in between still ranks after A's first claim, and A is not pushed down by its own second claim
    let r = resolve(
        &[
            ev(50, "d", place("A", "210")),
            ev(100, "d", assign("A", "210", 5)),
            ev(150, "e", place("B", "210")),
            ev(150, "e", assign("B", "210", 5)),
            ev(200, "d", assign("A", "210", 5)),
        ],
        &libs,
    );
    assert_eq!((call(&r, "A").as_deref(), call(&r, "B").as_deref()), (Some("CDS 210-005"), Some("CDS 210-005.1")));
}

fn old_log_library(root: &Path, with_pack: bool, log: &str) -> (LibraryRef, LibraryInput) {
    let books: &[(&str, &str, &str)] = if with_pack { &[("wm", "WM", "WM")] } else { &[] };
    let lref = make_library(root, "one", books, &[("me.jsonl", log.to_string())]);
    let input = load_library(&lref, &reader).unwrap();
    (lref, input)
}

#[test]
fn an_old_import_does_not_override_a_newer_user_place() {
    let tmp = Tmp::new("importorder");
    let shelves = tmp.path().join("bookshelves");
    // the person already moved the book on this device, at t=500
    LogWriter::open(&shelves.join("log"), "me").unwrap().append(&[ev(500, "me", Kind::Place { copy: s("WM"), div: s("320"), by: By::User })]).unwrap();
    let old = legacy(50, "me", "place", "wm", ",\"div\":\"210\",\"by\":\"auto\"");
    let lib = old_log_library(tmp.path(), true, &old);
    import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    let set = read_logs(&shelves.join("log")).unwrap();
    assert_eq!(set.events.iter().map(|e| e.at).collect::<Vec<_>>(), [500, 50], "the imported event keeps its at");
    let r = resolve(&set.events, &[lib.1]);
    assert_eq!(r.book_of("WM").unwrap().shelf.as_deref(), Some("320"));
}

#[test]
fn re_running_an_import_after_a_failure_writes_nothing_new() {
    let tmp = Tmp::new("importcrash");
    let shelves = tmp.path().join("bookshelves");
    let log = [legacy(1, "me", "place", "wm", ",\"div\":\"210\",\"by\":\"user\""), legacy(2, "me", "assign", "wm", ",\"div\":\"210\",\"seq\":1")].concat();
    let lib = old_log_library(tmp.path(), true, &log);
    assert_eq!(import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap().events, 2);
    // the crash: the events were appended but migrated.json was not written
    std::fs::remove_file(shelves.join(".local/migrated.json")).unwrap();
    let again = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!(again.events, 0);
    assert_eq!(read_logs(&shelves.join("log")).unwrap().events.len(), 2);
    assert!(shelves.join(".local/migrated.json").exists());
}

#[test]
fn an_unmapped_event_maps_once_its_pack_appears() {
    let tmp = Tmp::new("importlate");
    let shelves = tmp.path().join("bookshelves");
    let log = [legacy(1, "me", "place", "wm", ",\"div\":\"210\",\"by\":\"user\""), legacy(2, "me", "title", "wm", ",\"title\":\"Mine\"")].concat();
    // first run: the library has no pack for wm yet
    let lib = old_log_library(tmp.path(), false, &log);
    let rep = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!((rep.events, rep.files[0].unmapped), (0, 2));
    // the pack arrives
    let lib = old_log_library(tmp.path(), true, &log);
    let rep = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!((rep.events, rep.files[0].unmapped, rep.files[0].already), (2, 0, false));
    let r = resolve(&read_logs(&shelves.join("log")).unwrap().events, &[lib.1.clone()]);
    assert_eq!(r.book_of("WM").unwrap().title, "Mine");
    // and it is now recorded and not repeated
    let rep = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!(rep.events, 0);
    assert!(rep.files[0].already);
}

#[test]
fn a_deleted_books_number_is_kept_and_never_given_out_again() {
    let tmp = Tmp::new("importgone");
    let shelves = tmp.path().join("bookshelves");
    // "gone" was shelved as 210-005, moved off 210-002 earlier, and its pack was then deleted from the library
    let log = [
        legacy(1, "me", "assign", "gone", ",\"div\":\"210\",\"seq\":2"),
        legacy(2, "me", "retire", "gone", ",\"div\":\"210\",\"seq\":2"),
        legacy(3, "me", "assign", "gone", ",\"div\":\"210\",\"seq\":5"),
        legacy(4, "me", "assign", "wm", ",\"div\":\"210\",\"seq\":1"),
    ]
    .concat();
    let lib = old_log_library(tmp.path(), true, &log);
    let rep = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!((rep.events, rep.files[0].unmapped, rep.files[0].reserved), (4, 0, 3));
    let set = read_logs(&shelves.join("log")).unwrap();
    let reserves: Vec<&Event> = set.events.iter().filter(|e| matches!(e.kind, Kind::Retire { .. })).collect();
    assert_eq!(reserves.len(), 3);
    for e in &reserves {
        assert_eq!((e.kind.copy(), e.loc.as_deref()), (Some(copy_key(None, "gone").as_str()), Some("one/gone")));
    }
    assert_eq!(reserves.iter().map(|e| e.at).collect::<Vec<_>>(), [1, 2, 3], "a reserve keeps the original at");
    // no book appears for it, and its numbers count toward next free
    let r = resolve(&set.events, std::slice::from_ref(&lib.1));
    assert_eq!(r.books.len(), 1);
    assert!(r.book_of("gone").is_none());
    assert_eq!(r.next_seq("210"), 6);
    // the file is recorded: nothing in it waits for a pack
    let rec: Value = serde_json::from_slice(&std::fs::read(shelves.join(".local/migrated.json")).unwrap()).unwrap();
    assert_eq!(rec["files"]["one/me.jsonl"]["reserved"], json!(3));
    // a second import writes nothing, also when the record is lost
    let again = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!((again.events, again.files[0].already), (0, true));
    std::fs::remove_file(shelves.join(".local/migrated.json")).unwrap();
    let again = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!((again.events, again.files[0].reserved), (0, 3));
    assert_eq!(read_logs(&shelves.join("log")).unwrap().events, set.events);
}

#[test]
fn an_unmapped_place_is_dropped_but_its_books_number_is_reserved() {
    let tmp = Tmp::new("importgoneplace");
    let shelves = tmp.path().join("bookshelves");
    let log = [legacy(1, "me", "place", "gone", ",\"div\":\"210\",\"by\":\"user\""), legacy(1, "me", "assign", "gone", ",\"div\":\"210\",\"seq\":4")].concat();
    let lib = old_log_library(tmp.path(), false, &log);
    let rep = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!((rep.events, rep.files[0].unmapped, rep.files[0].reserved), (1, 1, 1));
    let json = rep.to_json();
    assert_eq!((json["files"][0]["unmapped"].clone(), json["files"][0]["reserved"].clone()), (json!(1), json!(1)));
    let set = read_logs(&shelves.join("log")).unwrap();
    assert!(set.events.iter().all(|e| matches!(e.kind, Kind::Retire { .. })), "the place is not written");
    let r = resolve(&set.events, std::slice::from_ref(&lib.1));
    assert!(r.books.is_empty());
    assert_eq!(r.next_seq("210"), 5);
    // the file stays eligible because of the dropped place, and a second import writes nothing new
    let again = import_own(&shelves, "me", std::slice::from_ref(&lib)).unwrap();
    assert_eq!((again.events, again.files[0].already), (0, false));
    assert_eq!(read_logs(&shelves.join("log")).unwrap().events.len(), 1);
}


// ------------------------------------------------------------------------------------- copies.jsonl, the batch detect, the view file

/// Writes `<dir>/copies.jsonl` from a loaded library, the way the builder does (one line per document, sorted by doc_id).
fn write_copies(dir: &Path, input: &LibraryInput) {
    let mut text = String::new();
    for c in &input.copies {
        text.push_str(&c.to_copies_line());
        text.push('\n');
    }
    std::fs::write(dir.join("copies.jsonl"), text).unwrap();
}

#[test]
fn a_library_with_copies_and_no_packs_gives_the_same_keys_and_the_same_view_as_one_with_packs() {
    let tmp = Tmp::new("copies");
    let books = [("wm", "WM", "Wilderness Medicine"), ("ps", "PS", "Pocket Survival"), ("old", "", "Stone")];
    let with_packs = make_library(tmp.path(), "L", &books, &[]);
    let from_packs = load_library(&with_packs, &reader).unwrap();
    assert_eq!(from_packs.copies.len(), 3);
    // the book without an original hash is keyed by its doc id, the others by the original hash
    let keys: Vec<&str> = from_packs.copies.iter().map(|c| c.copy.as_str()).collect();
    assert_eq!(keys, ["old", "PS", "WM"]);
    for c in &from_packs.copies {
        assert_eq!(c.copy, copy_key(c.original_blake3.as_deref(), &c.doc_id));
    }

    // the same library with no packs at all, only the copies file
    let dir = tmp.path().join("packless");
    std::fs::create_dir_all(&dir).unwrap();
    write_copies(&dir, &from_packs);
    let packless = LibraryRef::new("L", &dir);
    assert!(!dir.join("packs").exists());
    let from_file = load_library(&packless, &reader).unwrap();
    assert_eq!(from_file.copies, from_packs.copies, "the keys, hashes, titles, quality and samebook facts come out the same");
    assert_eq!(from_file.unreadable, 0);
    let events = [ev(1, "d", place("WM", "610")), ev(2, "d", assign("WM", "610", 1))];
    let (a, b) = (resolve(&events, &[from_packs.clone()]), resolve(&events, &[from_file.clone()]));
    let bytes = |r: &Resolved, l: &LibraryInput| view_bytes(&view_value(r, std::slice::from_ref(l), &[])).unwrap();
    assert_eq!(bytes(&a, &from_packs), bytes(&b, &from_file));
    assert_eq!(b.book_of("WM").unwrap().call.as_ref().map(|c| c.text.as_str()), Some("CDS 610-001"));
    assert_eq!(b.book_of("old").map(|x| x.title.as_str()), Some("Stone"));

    // the copies file wins over packs that are there, and the file may sit in shard/ (where unpacking an archive leaves it)
    let both = tmp.path().join("both");
    std::fs::create_dir_all(both.join("shard")).unwrap();
    std::fs::create_dir_all(both.join("packs")).unwrap();
    std::fs::write(both.join("packs").join("zz@1.cdoc"), header_line("zz", "ZZ", "Only a pack", "210")).unwrap();
    write_copies(&both.join("shard"), &from_packs);
    assert_eq!(copies_path(&both), Some(both.join("shard").join("copies.jsonl")));
    let l = load_library(&LibraryRef::new("L", &both), &reader).unwrap();
    assert_eq!(l.copies, from_packs.copies);
    // and without it the packs are read
    std::fs::remove_file(both.join("shard").join("copies.jsonl")).unwrap();
    assert_eq!(copies_path(&both), None);
    assert_eq!(load_library(&LibraryRef::new("L", &both), &reader).unwrap().copies.len(), 1);

    // an unreadable line is counted and skipped; the highest version of a doc wins
    let junk = tmp.path().join("junk.jsonl");
    let (mut v1, mut v2) = (from_packs.copies[0].clone(), from_packs.copies[0].clone());
    (v1.version, v1.title) = (1, "one".into());
    (v2.version, v2.title) = (2, "two".into());
    std::fs::write(&junk, format!("{}\nnot json\n\n{}\n{{\"title\":\"no doc id\"}}\n", v2.to_copies_line(), v1.to_copies_line())).unwrap();
    let (copies, bad) = read_copies(&junk).unwrap();
    assert_eq!((copies.len(), bad, copies[0].title.as_str()), (1, 2, "two"));
}

#[test]
fn the_ops_import_and_resolve_read_copies_when_there_are_no_packs() {
    let tmp = Tmp::new("packlessops");
    let src = make_library(tmp.path(), "src", &[("wm", "WM", "Wilderness Medicine")], &[]);
    let input = load_library(&src, &reader).unwrap();
    let dir = tmp.path().join("L");
    std::fs::create_dir_all(dir.join("log")).unwrap();
    write_copies(&dir, &input);
    // an old log of this device, imported through the copies file
    std::fs::write(dir.join("log").join("me.jsonl"), legacy(1, "me", "place", "wm", ",\"div\":\"610\",\"by\":\"user\"")).unwrap();
    let shelves = tmp.path().join("bookshelves");
    let libs = json!([{"library_id": "L", "dir": dir.to_str().unwrap()}]);
    let imp: Value = serde_json::from_str(&ops::import(&json!({"dir": shelves.to_str().unwrap(), "dev": "me", "libraries": libs}).to_string(), &reader).unwrap()).unwrap();
    assert_eq!(imp["events"], json!(1));
    assert_eq!(imp["files"][0]["unmapped"], json!(0));
    let view: Value = serde_json::from_str(&ops::resolve_view(&json!({"dir": shelves.to_str().unwrap(), "libraries": libs}).to_string(), &reader).unwrap()).unwrap();
    assert_eq!(view["books"]["WM"]["title"], json!("Wilderness Medicine"));
    assert_eq!(view["books"]["WM"]["shelf"], json!("610"));
    assert_eq!(view["books"]["WM"]["suggested"]["div"], json!("210"));
    assert_eq!(view["built_from"]["libraries"]["L"]["packs"], json!(1));
}

#[test]
fn resolve_writes_the_view_atomically_and_still_returns_it() {
    let tmp = Tmp::new("viewfile");
    let shelves = tmp.path().join("bookshelves");
    let lref = make_library(tmp.path(), "L", &[("wm", "WM", "Wilderness Medicine")], &[]);
    let libs = json!([{"library_id": "L", "dir": lref.dir.to_str().unwrap()}]);
    let args = json!({"dir": shelves.to_str().unwrap(), "libraries": libs}).to_string();
    let path = shelves.join(".local").join("view.json");
    assert!(!path.exists());
    let out = ops::resolve_view(&args, &reader).unwrap();
    let returned: Value = serde_json::from_str(&out).unwrap();
    let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(written, returned, "the file is the view the call returned");
    assert_eq!(written["books"]["WM"]["title"], json!("Wilderness Medicine"));
    // temp file plus rename: nothing else is left in .local
    let left: Vec<String> = std::fs::read_dir(shelves.join(".local")).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    assert_eq!(left, ["view.json"]);
    // the same inputs give the same bytes; a change in the log is in the next file
    let first = std::fs::read(&path).unwrap();
    ops::resolve_view(&args, &reader).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), first);
    ops::append(&json!({"dir": shelves.to_str().unwrap(), "dev": "d", "events": [{"ev": "place", "copy": "WM", "div": "610", "by": "user"}]}).to_string()).unwrap();
    ops::resolve_view(&args, &reader).unwrap();
    let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(after["books"]["WM"]["shelf"], json!("610"));
    // a view that cannot be written fails the call (the folder name is taken by a file)
    let blocked = tmp.path().join("blocked");
    std::fs::create_dir_all(&blocked).unwrap();
    std::fs::write(blocked.join(".local"), "x").unwrap();
    assert!(ops::resolve_view(&json!({"dir": blocked.to_str().unwrap(), "libraries": libs}).to_string(), &reader).is_err());
}

fn minhash_like(changed: usize) -> Vec<u32> {
    (0..128u32).map(|i| if (i as usize) < changed { i + 5000 } else { i }).collect()
}

fn fp_copy(copy: &str, doc: &str, original: Option<&str>, source: &str, changed: Option<usize>, vector: Vec<f32>) -> PackFacts {
    PackFacts {
        copy: copy_key(original, doc),
        doc_id: s(doc),
        version: 1,
        title: s(copy),
        blake3: Some(original.map(s).unwrap_or_else(|| s(source))),
        original_blake3: original.map(s),
        source_blake3: Some(s(source)),
        same: changed.map(|c| SameInfo { minhash: minhash_like(c), mean_vector: vector, text_pages: 10, pages: 10, ppi: None, source_size: 1, words: None }),
        ..Default::default()
    }
}

#[test]
fn the_batch_detect_reads_the_libraries_and_equals_the_union_of_the_single_calls() {
    let tmp = Tmp::new("batch");
    let v = vec![1.0f32, 0.0];
    // library A: a book and its near copy; library B: the same file under another doc id, an unrelated book, a book with no fingerprint
    let a = vec![fp_copy("A1", "a1", Some("ORIG-A1"), "s1", Some(0), v.clone()), fp_copy("A2", "a2", Some("ORIG-A2"), "s2", Some(6), v.clone())];
    let b = vec![
        fp_copy("A1", "a1-again", Some("ORIG-A1"), "s1", Some(0), v.clone()),
        fp_copy("B3", "b3", Some("ORIG-B3"), "s3", Some(50), v.clone()),
        fp_copy("B4", "b4", None, "s1", None, vec![]),
        fp_copy("B6", "b6", None, "s1", None, vec![]),
        fp_copy("B5", "b5", Some("ORIG-B5"), "s5", Some(2), vec![0.0, 1.0]),
    ];
    let mut dirs = Vec::new();
    for (id, copies) in [("A", &a), ("B", &b)] {
        let dir = tmp.path().join(id);
        std::fs::create_dir_all(&dir).unwrap();
        let text: String = copies.iter().map(|c| format!("{}\n", c.to_copies_line())).collect();
        std::fs::write(dir.join("copies.jsonl"), text).unwrap();
        dirs.push(json!({"library_id": id, "dir": dir.to_str().unwrap()}));
    }
    let run = |extra: Value| -> Vec<Value> {
        let mut req = json!({"libraries": dirs});
        for (k, val) in extra.as_object().unwrap() {
            req[k] = val.clone();
        }
        serde_json::from_str(&ops::detect(&req.to_string(), &reader).unwrap()).unwrap()
    };
    let all = run(json!({}));
    assert!(!all.is_empty());

    // the union of single-copy calls over the visible copies (one entry per copy key)
    let mut visible: Vec<PackFacts> = Vec::new();
    for c in a.iter().chain(b.iter()) {
        if !visible.iter().any(|x| x.copy == c.copy) {
            visible.push(c.clone());
        }
    }
    let facts_json = |c: &PackFacts| {
        let f = c.detect_facts();
        json!({"copy": f.copy, "blake3": f.blake3, "minhash": f.minhash, "mean_vector": f.mean_vector})
    };
    let mut union: Vec<(String, String, String, f64)> = Vec::new();
    for c in &visible {
        let against: Vec<Value> = visible.iter().map(facts_json).collect();
        let got: Vec<Value> = serde_json::from_str(&ops::detect(&json!({"copy": facts_json(c), "against": against}).to_string(), &reader).unwrap()).unwrap();
        for m in got {
            let w = m["with"].as_str().unwrap().to_string();
            let (hi, lo) = if c.copy > w { (c.copy.clone(), w) } else { (w, c.copy.clone()) };
            if !union.iter().any(|u| u.0 == hi && u.1 == lo) {
                union.push((hi, lo, m["how"].as_str().unwrap().to_string(), m["score"].as_f64().unwrap()));
            }
        }
    }
    union.sort_by(|x, y| (&x.0, &x.1).cmp(&(&y.0, &y.1)));
    let shaped: Vec<(String, String, String, f64)> = all.iter().map(|m| (m["copy"].as_str().unwrap().into(), m["with"].as_str().unwrap().into(), m["how"].as_str().unwrap().into(), m["score"].as_f64().unwrap())).collect();
    assert_eq!(shaped, union);
    // the file seen in two libraries is one copy (no pair with itself); b4 and b6 are two keys with one source hash; B3 is an
    // edition at best and B5 has another meaning
    let text_pair = ("ORIG-A2".to_string(), "ORIG-A1".to_string(), "text".to_string(), 122.0 / 128.0);
    let hash_pair = ("b6".to_string(), "b4".to_string(), "blake3".to_string(), 1.0);
    assert_eq!(shaped, [text_pair.clone(), hash_pair.clone()]);

    // checking one copy, and skipping what is known
    let pairs = |v: &[Value]| v.iter().map(|m| (m["copy"].as_str().unwrap().to_string(), m["with"].as_str().unwrap().to_string())).collect::<Vec<_>>();
    assert_eq!(pairs(&run(json!({"copies": ["ORIG-A1"]}))), [("ORIG-A2".to_string(), "ORIG-A1".to_string())]);
    assert_eq!(pairs(&run(json!({"copies": ["b4"]}))), [("b6".to_string(), "b4".to_string())]);
    assert!(run(json!({"copies": ["ORIG-B3", "nobody"]})).is_empty());
    assert_eq!(pairs(&run(json!({"copies": ["ORIG-A1", "ORIG-A2", "b4", "b6"]}))).len(), 2, "pairs among the checked copies count once");
    assert_eq!(pairs(&run(json!({"known": ["ORIG-A1", "ORIG-A2"]}))), [("b6".to_string(), "b4".to_string())]);
    assert_eq!(pairs(&run(json!({"known": ["ORIG-A1"]}))).len(), 2, "a pair with one new copy is not skipped");
    assert!(ops::detect(&json!({"libraries": dirs, "known": "ORIG-A1"}).to_string(), &reader).is_err());
    assert!(ops::detect(&json!({"libraries": [{"dir": "x"}]}).to_string(), &reader).is_err());

    // the same through packs: a library with packs and no copies file gives the same pairs
    let packs = make_library(tmp.path(), "P", &[("p1", "ORIG-P", "P1"), ("p2", "ORIG-P", "P2")], &[]);
    let got: Vec<Value> = serde_json::from_str(&ops::detect(&json!({"libraries": [{"library_id": "P", "dir": packs.dir.to_str().unwrap()}]}).to_string(), &reader).unwrap()).unwrap();
    assert!(got.is_empty(), "two packs with one original hash are one copy");
}
