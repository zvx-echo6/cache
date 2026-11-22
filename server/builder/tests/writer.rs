//! The general library writer: the payload and settings match a shipped library, a round trip through the core, the unmapped
//! fields, old packs, the checksums and the ZIM id check. No PDFs: the documents are made up.

use cache_builder::embed::{fake_vector, DIMS};
use cache_builder::library::{
    check_library_dir, doc_payload, library_settings, valid_zim_id, write_library, LibDoc, LibraryOptions, ZimRef, DOCUMENTS_FILE, SUMS_FILE,
};
use cache_builder::pack::{pack_bytes, read_pack_bytes, Chunker, EmbeddingInfo, Header, Pack, PackPiece, Source, Tool, PACK_FORMAT};
use cache_builder::build_library;
use edge::{EdgeShardRead, ScrollRequest, WithPayloadInterface, WithVector};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

const ZIM: &str = "0b2c6a9e-41d7-4c58-9e0a-5d3f7a1c8b24";

fn piece(index: u32, text: &str, page: &str, pdf_page: Option<u32>) -> PackPiece {
    PackPiece {
        index,
        text: text.into(),
        page: page.into(),
        pdf_page,
        page_end: None,
        pdf_page_end: None,
        heading_path: vec!["Part 1".into(), "Water".into()],
        vector: fake_vector(text),
    }
}

fn doc(id: &str) -> LibDoc {
    LibDoc {
        title: format!("Title of {id}"),
        doc_id: id.into(),
        doc_version: 1,
        source_blake3: "ab".repeat(32),
        original_blake3: None,
        link: String::new(),
        author: None,
        zim: None,
        pages: Some(10),
        pieces: vec![piece(0, &format!("{id} first passage"), "iv", Some(6)), piece(1, &format!("{id} second passage"), "7", Some(9))],
        entry: None,
    }
}

fn opts() -> LibraryOptions {
    LibraryOptions { id: "writer-test".into(), title: "Writer test".into(), version: "1".into(), vector_datatype: Default::default(), archive: false, built_at: 0 }
}

fn payloads(dir: &Path) -> Vec<Map<String, Value>> {
    let shard = cache_search::library::open_shard_for_scroll(dir).unwrap();
    let mut sr = ScrollRequest::new();
    sr.limit = Some(1000);
    sr.with_payload = Some(WithPayloadInterface::Bool(true));
    sr.with_vector = WithVector::Bool(false);
    let (recs, _) = EdgeShardRead::scroll(&shard, sr).unwrap();
    recs.iter().map(|r| r.payload.as_ref().unwrap().0.clone()).collect()
}

fn by_text<'a>(all: &'a [Map<String, Value>], text: &str) -> &'a Map<String, Value> {
    all.iter().find(|p| p["text"] == json!(text)).unwrap_or_else(|| panic!("no payload with text {text:?}"))
}

fn class(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn files_below(base: &Path, dir: &Path, out: &mut Vec<String>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            files_below(base, &p, out);
        } else {
            out.push(p.strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/"));
        }
    }
}

/// The shipped guide library (app/assets/guide) is a real Cache library: unpack it, read its settings file and its payloads.
fn guide() -> (Value, Vec<Map<String, Value>>, tempfile::TempDir) {
    use std::io::Read;
    let arch = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../app/assets/guide/cache-guide.cache-library");
    let raw = std::fs::read(&arch).unwrap();
    let bytes = if raw.starts_with(&[0x1f, 0x8b]) {
        let mut v = Vec::new();
        flate2::read::GzDecoder::new(&raw[..]).read_to_end(&mut v).unwrap();
        v
    } else {
        raw
    };
    let mut settings = None;
    for e in tar::Archive::new(&bytes[..]).entries().unwrap() {
        let mut e = e.unwrap();
        if e.path().unwrap().to_string_lossy() == "cache-library.json" {
            let mut s = String::new();
            e.read_to_string(&mut s).unwrap();
            settings = Some(serde_json::from_str::<Value>(&s).unwrap());
        }
    }
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("guide");
    let req = cache_search::libadd::prepare_unpack(arch.to_str().unwrap(), target.to_str().unwrap(), None, None).unwrap();
    let outcome = cache_search::libadd::run_unpack(&req, &|_, _| {}, &|_| {}, &|| false).unwrap();
    assert!(matches!(outcome, cache_search::index::Outcome::Done));
    (settings.expect("cache-library.json at the archive root"), payloads(&target), tmp)
}

#[test]
fn settings_and_payload_fields_match_the_shipped_guide_library() {
    let (g, gp, _tmp) = guide();
    // cache-library.json: the same keys and values, apart from the library's own id, title and version
    let mine = library_settings(g["library_id"].as_str().unwrap(), g["title"].as_str().unwrap(), g["version"].as_str().unwrap());
    assert_eq!(mine, g, "the writer's cache-library.json differs from the shipped guide library's");
    // payloads: the mapped fields every entry of a Cache library has, with the same JSON types
    let mut full = doc("any");
    full.author = Some("A. Author".into());
    full.zim = Some(ZimRef { id: ZIM.into(), path: "A/some.pdf".into() });
    full.pieces[0].page_end = Some("v".into());
    full.pieces[0].pdf_page_end = Some(7);
    let mine = doc_payload(&full, 0);
    let mine = mine.as_object().unwrap();
    assert!(!gp.is_empty());
    for name in ["title", "text", "page", "source", "link", "doc_id", "doc_version"] {
        let theirs: Vec<&Value> = gp.iter().filter_map(|p| p.get(name)).collect();
        assert_eq!(theirs.len(), gp.len(), "{name} is missing from some guide entries");
        let want = class(&mine[name]);
        for v in theirs {
            // a page is a whole number or a label, as text
            // and a null is a field that is not set on that entry
            let ok = class(v) == want || class(v) == "null" || (name == "page" && matches!(class(v), "number" | "string"));
            assert!(ok, "{name}: the guide has a {} and the writer a {want}", class(v));
        }
        assert_eq!(mine["source"], json!("book"));
    }
    // no field in the shipped payloads is missing from the writer's
    let mut guide_keys: Vec<&String> = gp.iter().flat_map(|p| p.keys()).collect();
    guide_keys.sort();
    guide_keys.dedup();
    let names: Vec<&str> = guide_keys.iter().map(|k| k.as_str()).collect();
    assert_eq!(names, ["doc_id", "doc_version", "link", "page", "source", "text", "title"], "the guide library's payload fields");
    for k in &guide_keys {
        assert!(mine.contains_key(k.as_str()), "the guide payload has a field {k} the writer does not write (guide fields: {guide_keys:?})");
    }
    // the extras are not mapped by the settings file
    let mapped: Vec<&str> = g["fields"].as_object().unwrap().values().filter_map(|v| v.as_str()).collect();
    for extra in ["heading_path", "pdf_page", "pdf_page_end", "page_end", "source_blake3", "author", "zim_id", "zim_path"] {
        assert!(mine.contains_key(extra), "{extra}");
        assert!(!mapped.contains(&extra), "{extra} must stay unmapped");
    }
}

#[test]
fn round_trip_through_the_core_with_the_unmapped_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let out = tmp.path().join("lib");
    let mut a = doc("alpha");
    a.link = "https://example.org/alpha.pdf".into();
    a.author = Some("A. Author".into());
    a.zim = Some(ZimRef { id: ZIM.into(), path: "books/alpha.pdf".into() });
    a.pieces[1].page_end = Some("8".into());
    a.pieces[1].pdf_page_end = Some(10);
    let mut b = doc("beta");
    b.doc_version = 3;
    b.title = "Tabs\tand\nlines".into();
    b.pages = None;
    let r = write_library(&out, &opts(), vec![a, b]).unwrap();
    assert_eq!((r.points, r.documents), (4, 2));

    let check = check_library_dir(&out).unwrap();
    assert_eq!(check["docs"].as_u64().unwrap(), 4);
    assert_eq!(check["whole_library_only"], json!(false));
    assert_eq!(check["resolved"]["library_id"], json!("writer-test"));

    let all = payloads(&out.join("shard"));
    assert_eq!(all.len(), 4);
    let p = by_text(&all, "alpha first passage");
    assert_eq!(p["title"], json!("Title of alpha"));
    assert_eq!(p["page"], json!("iv"));
    assert_eq!(p["source"], json!("book"));
    assert_eq!(p["link"], json!("https://example.org/alpha.pdf"));
    assert_eq!((p["doc_id"].clone(), p["doc_version"].clone()), (json!("alpha"), json!(1)));
    assert_eq!(p["heading_path"], json!(["Part 1", "Water"]));
    assert_eq!(p["pdf_page"], json!(6));
    assert_eq!(p["source_blake3"], json!("ab".repeat(32)));
    assert_eq!(p["author"], json!("A. Author"));
    assert_eq!((p["zim_id"].clone(), p["zim_path"].clone()), (json!(ZIM), json!("books/alpha.pdf")));
    assert!(!p.contains_key("page_end") && !p.contains_key("pdf_page_end"));
    let q = by_text(&all, "alpha second passage");
    assert_eq!(q["page"], json!(7));
    assert_eq!((q["pdf_page"].clone(), q["page_end"].clone(), q["pdf_page_end"].clone()), (json!(9), json!(8), json!(10)));
    let z = by_text(&all, "beta first passage");
    assert_eq!(z["doc_version"], json!(3));
    for k in ["zim_id", "zim_path", "author"] {
        assert!(!z.contains_key(k), "{k}");
    }

    // the folder: settings, shard, table, checksums; no index (the device builds the keyword index)
    let mut files = Vec::new();
    files_below(&out, &out, &mut files);
    files.sort();
    // the local view is beside the library, in no list
    assert!(files.contains(&".local/docs.json".to_string()));
    files.retain(|f| !f.starts_with(".local/"));
    assert!(files.contains(&"cache-library.json".to_string()) && files.contains(&DOCUMENTS_FILE.to_string()) && files.contains(&SUMS_FILE.to_string()));
    assert!(files.iter().any(|f| f.starts_with("shard/")));
    assert!(!files.iter().any(|f| f.starts_with("index/")));
    let tsv = std::fs::read_to_string(out.join(DOCUMENTS_FILE)).unwrap();
    let ab = "ab".repeat(32);
    assert_eq!(
        tsv,
        format!("doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\nalpha\t1\tTitle of alpha\t{ab}\t2\t10\nbeta\t3\tTabs and lines\t{ab}\t2\t\n")
    );

    // SHA256SUMS lists every other file once, and the sums are right
    use sha2::{Digest, Sha256};
    let sums = std::fs::read_to_string(out.join(SUMS_FILE)).unwrap();
    let mut listed = Vec::new();
    for line in sums.lines() {
        let (hex, rel) = line.split_once("  ").unwrap();
        let h: String = Sha256::digest(std::fs::read(out.join(rel)).unwrap()).iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, h, "{rel}");
        listed.push(rel.to_string());
    }
    let mut others: Vec<String> = files.into_iter().filter(|f| f != SUMS_FILE).collect();
    others.sort();
    assert_eq!(listed, others);
}

fn pack_of(id: &str, pieces: Vec<PackPiece>) -> Pack {
    Pack {
        header: Header {
            cdoc: PACK_FORMAT,
            doc_id: id.into(),
            doc_version: 1,
            title: format!("Pack {id}"),
            source: Source { blake3: "cd".repeat(32), size: 1, file_name: "x.pdf".into(), https: Some("https://example.org/x.pdf".into()) },
            extractor: Tool { name: "mupdf".into(), version: "0".into(), layout_version: None },
            chunker: Chunker { version: 1, target_words: 200, max_words: 300 },
            embedding: EmbeddingInfo { embedder: "fake-hash-v1".into(), dims: DIMS },
            created_at: "2026-11-01T00:00:00Z".into(),
            page_count: 12,
            ocr_pages: vec![],
            text_source_ocr_pages: vec![],
            pieces: pieces.len(),
            division: None,
            book: None,
            samebook: None,
        },
        pieces,
    }
}

#[test]
fn packs_without_pdf_page_still_build_and_leave_it_out() {
    // a pack as written before pdf_page was optional carries the field; an older or foreign one may not
    let mut p = pack_of("old", vec![piece(0, "old one", "1", None), piece(1, "old two", "2", None)]);
    let bytes = pack_bytes(&p).unwrap();
    let back = read_pack_bytes(&bytes).unwrap();
    assert_eq!(back, p);
    assert!(back.pieces.iter().all(|x| x.pdf_page.is_none() && x.pdf_page_end.is_none()));
    // a piece line with no pdf_page key at all parses (that is what the writer above produced)
    {
        use std::io::Read;
        let mut text = String::new();
        flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut text).unwrap();
        assert!(!text.contains("pdf_page"), "an absent pdf_page is not written");
    }

    let tmp = tempfile::tempdir().unwrap();
    let packs = tmp.path().join("packs");
    cache_builder::pack::write_pack(&p, &packs).unwrap();
    p.header.doc_id = "new".into();
    p.pieces[0].pdf_page = Some(3);
    p.pieces[0].page_end = Some("2".into());
    p.pieces[0].pdf_page_end = Some(4);
    p.pieces[1].pdf_page = Some(5);
    cache_builder::pack::write_pack(&p, &packs).unwrap();
    let again = read_pack_bytes(&pack_bytes(&p).unwrap()).unwrap();
    assert_eq!(again.pieces[0].pdf_page_end, Some(4));

    let out = tmp.path().join("lib");
    let r = build_library(&packs, &out, &opts()).unwrap();
    assert_eq!((r.points, r.documents), (4, 2));
    let all = payloads(&out.join("shard"));
    let o = all.iter().find(|x| x["doc_id"] == json!("old") && x["text"] == json!("old one")).unwrap();
    assert!(!o.contains_key("pdf_page") && !o.contains_key("pdf_page_end"));
    assert_eq!(o["link"], json!("https://example.org/x.pdf"));
    let new0 = all.iter().find(|x| x["doc_id"] == json!("new") && x["text"] == json!("old one")).unwrap();
    assert_eq!((new0["pdf_page"].clone(), new0["page_end"].clone(), new0["pdf_page_end"].clone()), (json!(3), json!(2), json!(4)));
    assert!(!new0.contains_key("zim_id"));
    // the table gets the page count from the pack header
    let tsv = std::fs::read_to_string(out.join(DOCUMENTS_FILE)).unwrap();
    assert!(tsv.lines().skip(1).all(|l| l.ends_with("\t2\t12")), "{tsv}");
}

#[test]
fn zim_id_must_be_a_lowercase_uuid() {
    assert!(valid_zim_id(ZIM));
    for bad in [
        "0B2C6A9E-41D7-4C58-9E0A-5D3F7A1C8B24",
        "0b2c6a9e41d74c589e0a5d3f7a1c8b24",
        "0b2c6a9e-41d7-4c58-9e0a-5d3f7a1c8b2",
        "0b2c6a9e-41d7-4c58-9e0a-5d3f7a1c8b244",
        "0b2c6a9e-41d7-4c58-9e0a-5d3f7a1c8b2g",
        "{0b2c6a9e-41d7-4c58-9e0a-5d3f7a1c8b2}",
        "",
    ] {
        assert!(!valid_zim_id(bad), "{bad:?}");
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("lib");
        let mut d = doc("z");
        d.zim = Some(ZimRef { id: bad.into(), path: "a.pdf".into() });
        let e = write_library(&out, &opts(), vec![d]).unwrap_err();
        assert!(e.0.contains("zim_id"), "{e}");
        assert!(!out.exists(), "a failed write leaves nothing behind");
    }
    let tmp = tempfile::tempdir().unwrap();
    let mut d = doc("z");
    d.zim = Some(ZimRef { id: ZIM.into(), path: String::new() });
    assert!(write_library(&tmp.path().join("lib"), &opts(), vec![d]).is_err());
}

#[test]
fn bad_input_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let dup = write_library(&tmp.path().join("a"), &opts(), vec![doc("same"), doc("same")]);
    assert!(dup.unwrap_err().0.contains("twice"));
    let mut bad = doc("short");
    bad.pieces[0].vector.truncate(8);
    assert!(write_library(&tmp.path().join("b"), &opts(), vec![bad]).is_err());
    assert!(write_library(&tmp.path().join("c"), &opts(), Vec::<LibDoc>::new()).is_err());
    assert!(write_library(&tmp.path().join("d"), &opts(), vec![doc("bad id")]).is_err());
}

#[test]
fn original_identity_survives_pack_export_archive_and_core_unpack() {
    use cache_builder::source_identity::{read_source_identities, SOURCE_IDENTITIES_FILE};
    let tmp = tempfile::tempdir().unwrap();
    let mut pack = pack_of("compressed", vec![piece(0, "Existing passage", "1", Some(1))]);
    pack.header.book = Some(cache_builder::pack::BookBlock {
        title: pack.header.title.clone(), source_title: None,
        original_blake3: "ef".repeat(32), compression: None, ocr: None, suggested: None, author: None, edition: None, year: None,
    });
    let doc = LibDoc::from_pack(&read_pack_bytes(&pack_bytes(&pack).unwrap()).unwrap());
    assert_eq!(doc.original_blake3.as_deref(), Some("ef".repeat(32).as_str()));
    assert_ne!(doc.source_blake3, doc.original_blake3.clone().unwrap());
    let out = tmp.path().join("library");
    let report = write_library(&out, &LibraryOptions { archive: true, ..opts() }, vec![doc]).unwrap();
    let entries = read_source_identities(&out).unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!((&entries[0].doc_id, entries[0].version), (&"compressed".to_string(), 1));
    assert_eq!(entries[0].source_blake3, "cd".repeat(32));
    assert_eq!(entries[0].original_blake3, "ef".repeat(32));
    let sums = std::fs::read_to_string(out.join(SUMS_FILE)).unwrap();
    let expected = {
        use sha2::{Digest, Sha256};
        format!("{:x}  {SOURCE_IDENTITIES_FILE}", Sha256::digest(std::fs::read(out.join(SOURCE_IDENTITIES_FILE)).unwrap()))
    };
    assert!(sums.lines().any(|line| line == expected));
    let archive = report.archive.unwrap();
    let target = tmp.path().join("unpacked-shard");
    let req = cache_search::libadd::prepare_unpack(archive.to_str().unwrap(), target.to_str().unwrap(), None, None).unwrap();
    assert!(matches!(cache_search::libadd::run_unpack(&req, &|_, _| {}, &|_| {}, &|| false).unwrap(), cache_search::index::Outcome::Done));
    assert_eq!(read_source_identities(&target).unwrap(), entries);
    assert_eq!(std::fs::read(target.join(DOCUMENTS_FILE)).unwrap(), std::fs::read(out.join(DOCUMENTS_FILE)).unwrap());
}

/// `own` marks a library the person made on the device (Add PDF writes to it, its keyword snapshot grows by generations). A library the
/// builder makes, whether for the catalogue or on a person's own server, never says it.
#[test]
fn the_builders_library_settings_never_say_own() {
    let s = library_settings("field", "Field library", "7");
    assert!(s.get("own").is_none() && s.get("own_default").is_none(), "{s}");
}
