//! Lookups against the small file `tools/build_catalog.py --fixture` builds (4 keys per block, so every lookup crosses block
//! boundaries). `tests/fixture.tsv` lists what a reader must find, written by the same run.

use cache_catalog::{accept_isbn_match, author_surname, normalise_title, Catalog, CatalogError, Entry, LccTable};
use std::path::PathBuf;

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests")
}

fn open() -> Catalog {
    Catalog::open(dir().join("fixture.bin")).expect("fixture opens")
}

fn year(s: &str) -> Option<u16> {
    match s.parse::<u16>().expect("year") {
        0 => None,
        y => Some(y),
    }
}

fn check(e: &Entry, lcc: &str, title: &str, author: &str, y: &str) {
    assert_eq!(e.lcc, lcc);
    assert_eq!(e.title, title);
    assert_eq!(e.author, author);
    assert_eq!(e.year, year(y));
}

#[test]
fn every_listed_key_is_found() {
    let cat = open();
    let table = LccTable::parse(include_str!("../tools/lcc_to_division.tsv"));
    let expect = std::fs::read_to_string(dir().join("fixture.tsv")).expect("fixture.tsv");
    let (mut isbns, mut titles) = (0, 0);
    for line in expect.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        let entry = match f[0] {
            "I" => {
                isbns += 1;
                let e = cat.lookup_isbn(f[1]).unwrap_or_else(|| panic!("isbn {} missing", f[1]));
                check(&e, f[2], f[3], f[4], f[5]);
                e
            }
            "T" => {
                titles += 1;
                let e = cat.lookup_book(f[1], f[2]).unwrap_or_else(|| panic!("title {} / {} missing", f[1], f[2]));
                check(&e, f[3], f[4], f[5], f[6]);
                e
            }
            other => panic!("unknown row kind {other}"),
        };
        assert_eq!(entry.division.as_deref(), table.division(&entry.lcc));
    }
    assert!(isbns >= 30 && titles >= 28, "{isbns} isbn rows, {titles} title rows");
}

#[test]
fn division_comes_from_the_embedded_table() {
    let cat = open();
    assert_eq!(cat.lookup_isbn("9780441172719").unwrap().division.as_deref(), Some("080"));
    let cpp = cat.lookup_isbn("9780321563842").unwrap();
    assert_eq!((cpp.lcc.as_str(), cpp.division.as_deref()), ("QA76", Some("760")));
    // A newer table can replace the embedded one without rebuilding the file.
    let mut cat = cat;
    cat.set_lcc_table("PS\t\t\t999\tmoved\n");
    assert_eq!(cat.lookup_isbn("9780441172719").unwrap().division.as_deref(), Some("999"));
}

#[test]
fn isbn_forms_and_misses() {
    let cat = open();
    let by13 = cat.lookup_isbn("9780441172719").unwrap();
    assert_eq!(by13.title, "Dune");
    assert_eq!(cat.lookup_isbn("0-441-17271-7"), Some(by13.clone()));
    assert_eq!(cat.lookup_isbn("978-0-441-17271-9"), Some(by13));
    // The second Dune ISBN shares the first edition's record.
    assert_eq!(cat.lookup_isbn("9780441013593").unwrap().year, Some(1965));
    assert_eq!(cat.lookup_isbn("9780000000002"), None, "valid ISBN, not in the file");
    assert_eq!(cat.lookup_isbn("9780441172718"), None, "bad check digit");
    assert_eq!(cat.lookup_isbn("9790000000001"), None);
    assert_eq!(cat.lookup_isbn("9999999999999"), None);
    assert_eq!(cat.lookup_isbn(""), None);
    // A record with no author has an ISBN key only.
    let anon = cat.lookup_isbn("9781400079988").unwrap();
    assert_eq!((anon.author.as_str(), anon.year, anon.lcc.as_str()), ("", None, "E185"));
}

#[test]
fn title_lookups() {
    let cat = open();
    let dune = cat.lookup_title(&normalise_title("Dune"), &author_surname("Herbert, Frank")).unwrap();
    assert_eq!(dune.lcc, "PS3558");
    assert_eq!(cat.lookup_book("DUNE!", "Frank Herbert"), Some(dune));
    assert_eq!(cat.lookup_book("Война и мир", "Tolstoy, Leo").unwrap().lcc, "PG3366");
    assert_eq!(cat.lookup_book("Wuthering Heights", "Emily Brontë").unwrap().year, Some(1847));
    assert_eq!(cat.lookup_book("Dune", "Nobody"), None);
    assert_eq!(cat.lookup_book("No Such Book", "Herbert"), None);
    assert_eq!(cat.lookup_book("", "Herbert"), None);
    assert_eq!(cat.lookup_book("Dune", ""), None);
}

#[test]
fn isbn_matches_are_checked_against_the_books_title() {
    let cat = open();
    let e = cat.lookup_isbn("9780441172719").unwrap();
    assert!(accept_isbn_match(&e.title, "Dune (Frank Herbert)"));
    assert!(!accept_isbn_match(&e.title, "The Great Gatsby"));
}

#[test]
fn header_fields() {
    let cat = open();
    assert_eq!(cat.attribution(), "Book data from Open Library, openlibrary.org");
    assert!(cat.licence().contains("public domain"));
    assert_eq!(cat.catalogue_date(), 20260930);
}

#[test]
fn bad_files_are_errors() {
    assert!(matches!(Catalog::open(dir().join("no-such-file.bin")), Err(CatalogError::Io(_))));
    let p = std::env::temp_dir().join(format!("cache_catalog_garbage_{}.bin", std::process::id()));
    std::fs::write(&p, b"this is not a catalogue file at all").unwrap();
    assert!(matches!(Catalog::open(&p), Err(CatalogError::Corrupt(_))));
    let mut bytes = std::fs::read(dir().join("fixture.bin")).unwrap();
    bytes[8] = 2; // a format version this reader does not know
    std::fs::write(&p, &bytes).unwrap();
    assert!(matches!(Catalog::open(&p), Err(CatalogError::Unsupported(2))));
    std::fs::remove_file(&p).unwrap();
}
