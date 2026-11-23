//! Behaviour of the store on its own: entry kinds, in-place files, tags, gc, export, crash safety, verified pieces.

use std::{
    collections::HashSet,
    fs::{self, File},
    io::{self, Read},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

use cache_store::{ChunkNum, ChunkRanges, ExportHow, ExportMode, Hash, ImportMode, Options, Status, Store, INLINE_MAX};
use tempfile::TempDir;

fn bytes(seed: u8, n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    blake3::Hasher::new().update(&[seed]).finalize_xof().fill(&mut v);
    v
}

fn open(dir: &Path) -> Store {
    Store::open(&dir.join("store"), Options::default()).unwrap()
}

fn write(dir: &Path, name: &str, data: &[u8]) -> PathBuf {
    let p = dir.join(name);
    fs::write(&p, data).unwrap();
    p
}

fn data_files(dir: &Path) -> Vec<String> {
    let mut v = Vec::new();
    for shard in fs::read_dir(dir.join("store/data")).unwrap() {
        for f in fs::read_dir(shard.unwrap().path()).unwrap() {
            v.push(f.unwrap().file_name().to_string_lossy().into_owned());
        }
    }
    v.sort();
    v
}

fn tmp_files(dir: &Path) -> usize {
    fs::read_dir(dir.join("store/tmp")).unwrap().count()
}

fn window(k: u64, chunks: u64) -> ChunkRanges {
    ChunkRanges::from(ChunkNum(k * chunks)..ChunkNum((k + 1) * chunks))
}

/// Moves a whole file between two stores in windows of `chunks` chunks, the way a fetch does.
fn transfer(from: &Store, to: &Store, hash: &Hash, size: u64, chunks: u64) {
    let mut k = 0;
    loop {
        let w = window(k, chunks);
        let piece = from.encode_ranges_to_vec(hash, &w).unwrap();
        to.import_ranges(hash, &w, &piece).unwrap();
        k += 1;
        if k * chunks * 1024 >= size {
            break;
        }
    }
}

#[test]
fn hash_text_forms() {
    let h = Hash::new(b"hello");
    assert_eq!(h.to_hex().len(), 64);
    assert_eq!(h.to_hex().parse::<Hash>().unwrap(), h);
    assert_eq!(Hash::EMPTY, Hash::new(b""));
    let b32 = data_encoding::BASE32_NOPAD.encode(h.as_bytes()).to_ascii_lowercase();
    assert_eq!(b32.parse::<Hash>().unwrap(), h);
    assert!("zz".parse::<Hash>().is_err());
    assert_eq!(h.fmt_short(), h.to_hex()[..10]);
}

#[test]
fn inline_owned_and_external() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());

    // Up to the iroh-blobs limit is inline: in the index, no data file.
    let small = bytes(1, INLINE_MAX as usize);
    let a = s.add_bytes(&small).unwrap();
    assert_eq!(s.status(&a.hash).unwrap(), Status::Complete { size: INLINE_MAX });
    assert!(data_files(d.path()).is_empty());
    assert_eq!(s.get_bytes(&a.hash).unwrap(), small);

    // One byte more is owned: a data file and an outboard.
    let big = bytes(2, INLINE_MAX as usize + 1);
    let b = s.add_bytes(&big).unwrap();
    assert_eq!(s.status(&b.hash).unwrap(), Status::Complete { size: INLINE_MAX + 1 });
    let name = b.hash.to_hex();
    assert_eq!(data_files(d.path()), vec![format!("{name}.data"), format!("{name}.obao")]);
    assert_eq!(s.get_bytes(&b.hash).unwrap(), big);
    assert!(s.owned_data_path(&b.hash).is_some());
    assert!(s.owned_data_path(&a.hash).is_none());

    // The empty file is inline.
    let e = s.add_bytes(b"").unwrap();
    assert_eq!(e.hash, Hash::EMPTY);
    assert_eq!(s.status(&e.hash).unwrap(), Status::Complete { size: 0 });
    assert!(s.get_bytes(&e.hash).unwrap().is_empty());

    // A file referenced in place: no copy in the store (only its outboard), read from where it is.
    let ext_data = bytes(3, 300_000);
    let p = write(d.path(), "mine.bin", &ext_data);
    let c = s.add_path(&p, ImportMode::Reference).unwrap();
    assert_eq!(s.status(&c.hash).unwrap(), Status::Complete { size: 300_000 });
    let names = data_files(d.path());
    assert!(names.contains(&format!("{}.obao", c.hash.to_hex())));
    assert!(!names.contains(&format!("{}.data", c.hash.to_hex())));
    assert!(s.owned_data_path(&c.hash).is_none());
    assert_eq!(s.get_bytes(&c.hash).unwrap(), ext_data);

    // A small file referenced in place is kept inline, as iroh-blobs does.
    let p2 = write(d.path(), "tiny.txt", b"tiny");
    let t = s.add_path(&p2, ImportMode::Reference).unwrap();
    fs::remove_file(&p2).unwrap();
    assert_eq!(s.get_bytes(&t.hash).unwrap(), b"tiny");

    // A copy of a file is owned and survives the original.
    let p3 = write(d.path(), "copy.bin", &bytes(4, 100_000));
    let k = s.add_path(&p3, ImportMode::Copy).unwrap();
    fs::remove_file(&p3).unwrap();
    assert_eq!(s.get_bytes(&k.hash).unwrap(), bytes(4, 100_000));
    assert_eq!(tmp_files(d.path()), 0);
}

#[test]
fn a_changed_in_place_file_is_absent_and_not_rehashed() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let data = bytes(5, 200_000);
    let p = write(d.path(), "f.bin", &data);
    let h = s.add_path(&p, ImportMode::Reference).unwrap().hash;
    let stamp = fs::metadata(&p).unwrap().modified().unwrap();
    assert!(s.has(&h).unwrap());

    // The same bytes with a new modification time: a re-hash would say Complete, the stamp check says Absent.
    File::options().write(true).open(&p).unwrap().set_modified(stamp + Duration::from_secs(5)).unwrap();
    assert_eq!(s.status(&h).unwrap(), Status::Absent);
    assert!(s.get_bytes(&h).is_err());
    assert!(s.encode_ranges_to_vec(&h, &window(0, 16)).is_err());
    assert!(s.export(&h, &d.path().join("out.bin"), ExportMode::Copy).is_err());

    // Put the stamp back and it reads again.
    File::options().write(true).open(&p).unwrap().set_modified(stamp).unwrap();
    assert!(s.has(&h).unwrap());

    // A different size is Absent too.
    let mut longer = data.clone();
    longer.push(0);
    fs::write(&p, &longer).unwrap();
    assert_eq!(s.status(&h).unwrap(), Status::Absent);

    // The scan's job: adding the file again gives its new hash, and the old one stays absent.
    let h2 = s.add_path(&p, ImportMode::Reference).unwrap().hash;
    assert_ne!(h, h2);
    assert!(s.has(&h2).unwrap());
    assert_eq!(s.status(&h).unwrap(), Status::Absent);
}

#[test]
fn bad_paths_are_refused() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let p = write(d.path(), "f.bin", &bytes(6, 100_000));
    assert!(s.add_path(&p, ImportMode::Reference).is_ok());
    assert!(s.add_path(&d.path().join("nope"), ImportMode::Copy).is_err());
    assert!(s.add_path(d.path(), ImportMode::Copy).is_err());
}

#[test]
fn tags() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let (a, b) = (Hash::new(b"a"), Hash::new(b"b"));
    s.set_tag(b"share1/x", &a).unwrap();
    s.set_tag(b"share1/y", &b).unwrap();
    s.set_tag(b"share2/x", &a).unwrap();
    s.set_tag(b"share1/x", &b).unwrap();
    assert_eq!(s.tags_with_prefix(b"share1/").unwrap(), vec![(b"share1/x".to_vec(), b), (b"share1/y".to_vec(), b)]);
    assert_eq!(s.tags_with_prefix(b"share2/").unwrap().len(), 1);
    assert_eq!(s.tags_with_prefix(b"").unwrap().len(), 3);
    assert!(s.delete_tag(b"share1/x").unwrap());
    assert!(!s.delete_tag(b"share1/x").unwrap());
    assert_eq!(s.tags_with_prefix(b"share1/").unwrap().len(), 1);
    // Tags and entries survive a reopen.
    let h = s.add_bytes(&bytes(7, 50_000)).unwrap().hash;
    s.set_tag(b"t", &h).unwrap();
    s.shutdown().unwrap();
    drop(s);
    let s = open(d.path());
    assert_eq!(s.tags_with_prefix(b"t").unwrap(), vec![(b"t".to_vec(), h)]);
    assert!(s.has(&h).unwrap());
}

#[test]
fn gc_keeps_what_is_tagged_held_or_protected_and_sweeps_the_rest() {
    let d = TempDir::new().unwrap();
    let protect: Arc<Mutex<HashSet<Hash>>> = Arc::default();
    let p2 = protect.clone();
    let s = Store::open(
        &d.path().join("store"),
        Options { protect: Some(Arc::new(move || p2.lock().unwrap().clone())), ..Options::default() },
    )
    .unwrap();

    let tagged = s.add_bytes(&bytes(10, 60_000)).unwrap().into_temp_tag();
    s.set_tag(b"keep", &tagged.hash()).unwrap();
    let kept_by_protect = s.add_bytes(&bytes(11, 60_000)).unwrap().hash;
    protect.lock().unwrap().insert(kept_by_protect);
    let held = s.add_bytes(&bytes(12, 60_000)).unwrap();
    let loose = s.add_bytes(&bytes(13, 60_000)).unwrap().hash;
    let loose_inline = s.add_bytes(&bytes(14, 100)).unwrap().hash;
    drop(tagged);

    let r = s.gc().unwrap();
    assert_eq!(r.entries, 2, "{r:?}");
    assert!(s.has(&s.tags_with_prefix(b"keep").unwrap()[0].1).unwrap());
    assert!(s.has(&kept_by_protect).unwrap());
    assert!(s.has(&held.hash).unwrap(), "a live temp tag holds its hash");
    assert_eq!(s.status(&loose).unwrap(), Status::Absent);
    assert_eq!(s.status(&loose_inline).unwrap(), Status::Absent);
    assert!(!data_files(d.path()).iter().any(|n| n.starts_with(&loose.to_hex())));

    // Dropping the hold and the protection lets the next sweep take them.
    let held_hash = held.hash;
    drop(held);
    protect.lock().unwrap().clear();
    assert_eq!(s.gc().unwrap().entries, 2);
    assert_eq!(s.status(&held_hash).unwrap(), Status::Absent);
    assert_eq!(data_files(d.path()).len(), 2, "only the tagged data and outboard are left");
}

#[test]
fn gc_of_an_external_entry_drops_the_row_and_never_the_persons_file() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let data = bytes(20, 400_000);
    let p = write(d.path(), "shared.bin", &data);
    let added = s.add_path_tagged(&p, ImportMode::Reference, b"share/shared.bin").unwrap();
    let h = added.hash;
    drop(added);

    // Tagged: kept.
    assert_eq!(s.gc().unwrap().entries, 0);
    assert!(s.has(&h).unwrap());

    // Untagged: the entry goes, the file stays exactly as it was.
    s.delete_tag(b"share/shared.bin").unwrap();
    let r = s.gc().unwrap();
    assert_eq!(r.entries, 1);
    assert_eq!(s.status(&h).unwrap(), Status::Absent);
    assert_eq!(fs::read(&p).unwrap(), data, "the person's file is untouched");
    assert!(data_files(d.path()).is_empty(), "its outboard went with the entry");

    // The same holds for a file that was moved out of the store into a shared folder.
    let own = s.add_bytes(&bytes(21, 90_000)).unwrap().hash;
    let target = d.path().join("shared/out.bin");
    assert_eq!(s.export(&own, &target, ExportMode::Move).unwrap().how, ExportHow::Moved);
    s.gc().unwrap();
    assert_eq!(s.status(&own).unwrap(), Status::Absent);
    assert_eq!(fs::read(&target).unwrap(), bytes(21, 90_000), "the moved file is the person's now");
}

#[test]
fn gc_sweeps_files_the_index_does_not_know() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let h = s.add_bytes(&bytes(22, 50_000)).unwrap();
    s.set_tag(b"t", &h.hash).unwrap();
    let stray = d.path().join("store/data").join(&h.hash.to_hex()[..2]).join(format!("{}.data", Hash::new(b"stray").to_hex()));
    fs::write(&stray, b"left by a crash").unwrap();
    let r = s.gc().unwrap();
    assert_eq!(r.entries, 0);
    assert_eq!(r.files, 1);
    assert!(!stray.exists());
    assert!(s.has(&h.hash).unwrap());
}

#[test]
fn export_copy_reflink_and_move() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let data = bytes(30, 250_000);
    let h = s.add_bytes(&data).unwrap().hash;
    let own = s.owned_data_path(&h).unwrap();

    let out = d.path().join("a/b/copy.bin");
    assert_eq!(s.export(&h, &out, ExportMode::Copy).unwrap().how, ExportHow::Copied);
    assert_eq!(fs::read(&out).unwrap(), data);
    let out2 = d.path().join("reflink.bin");
    let how = s.export(&h, &out2, ExportMode::ReflinkOrCopy).unwrap().how;
    assert!(matches!(how, ExportHow::Reflinked | ExportHow::Copied));
    assert_eq!(fs::read(&out2).unwrap(), data);
    assert!(own.exists(), "copies leave the store's file");
    // An export over an existing file replaces it whole.
    fs::write(&out, b"old").unwrap();
    s.export(&h, &out, ExportMode::Copy).unwrap();
    assert_eq!(fs::read(&out).unwrap(), data);

    // Move takes the store's own file; the entry then lives at the target and still reads.
    let moved = d.path().join("shared/moved.bin");
    let e = s.export(&h, &moved, ExportMode::Move).unwrap();
    assert_eq!(e.how, ExportHow::Moved);
    assert!(!own.exists());
    assert_eq!(fs::read(&moved).unwrap(), data);
    assert_eq!(s.status(&h).unwrap(), Status::Complete { size: 250_000 });
    assert_eq!(s.get_bytes(&h).unwrap(), data);
    assert!(s.owned_data_path(&h).is_none());
    assert!(s.encode_ranges_to_vec(&h, &window(0, 16384)).unwrap().len() > 250_000);

    // Move applies only to owned data: an in-place entry is copied and the person's file is left alone.
    let theirs = write(d.path(), "theirs.bin", &bytes(31, 120_000));
    let h2 = s.add_path(&theirs, ImportMode::Reference).unwrap().hash;
    let e = s.export(&h2, &d.path().join("shared/theirs-copy.bin"), ExportMode::Move).unwrap();
    assert_eq!(e.how, ExportHow::Copied);
    assert_eq!(fs::read(&theirs).unwrap(), bytes(31, 120_000));
    assert!(s.has(&h2).unwrap());

    // An inline entry is copied.
    let h3 = s.add_bytes(b"small").unwrap().hash;
    let e = s.export(&h3, &d.path().join("small.txt"), ExportMode::Move).unwrap();
    assert_eq!(e.how, ExportHow::Copied);
    assert_eq!(fs::read(d.path().join("small.txt")).unwrap(), b"small");

    // A missing hash fails and leaves nothing behind.
    assert!(s.export(&Hash::new(b"none"), &d.path().join("none.bin"), ExportMode::Copy).is_err());
    assert!(!d.path().join("none.bin").exists());
    let leftovers: Vec<_> = fs::read_dir(d.path()).unwrap().filter_map(|f| f.ok()).filter(|f| f.file_name().to_string_lossy().contains("cache-store")).collect();
    assert!(leftovers.is_empty());
}

/// Condition 1 of the plan review: the iroh bridge's view references the store's data files, so the store must not delete,
/// move or rewrite a file the view reads. Here the view is a set of hashes the test controls.
#[test]
fn files_an_outside_view_reads_are_never_deleted_moved_or_rewritten() {
    let d = TempDir::new().unwrap();
    let lent: Arc<Mutex<HashSet<Hash>>> = Arc::default();
    let l2 = lent.clone();
    let s = Store::open(&d.path().join("store"), Options { lent: Some(Arc::new(move || l2.lock().unwrap().clone())), ..Options::default() }).unwrap();
    let data = bytes(40, 300_000);
    let h = s.add_bytes(&data).unwrap().hash;
    let own = s.owned_data_path(&h).unwrap();
    let before = fs::read(&own).unwrap();
    let ino = file_id(&own);
    lent.lock().unwrap().insert(h);

    // gc: untagged, but lent, so kept, file untouched.
    assert_eq!(s.gc().unwrap().entries, 0);
    assert_eq!(fs::read(&own).unwrap(), before);

    // Move: refused, copied instead; the file stays where the view reads it.
    let target = d.path().join("shared/x.bin");
    assert_eq!(s.export(&h, &target, ExportMode::Move).unwrap().how, ExportHow::Copied);
    assert!(own.exists());
    assert_eq!(fs::read(&target).unwrap(), data);

    // Re-adding the same content does not rewrite the file.
    let again = write(d.path(), "again.bin", &data);
    s.add_path(&again, ImportMode::Copy).unwrap();
    assert_eq!(file_id(&own), ino, "the same file, not a replacement");
    assert_eq!(fs::read(&own).unwrap(), before);

    // When the view lets go, the same calls act: gc sweeps it, and a fresh entry can be moved.
    lent.lock().unwrap().clear();
    assert_eq!(s.gc().unwrap().entries, 1);
    assert!(!own.exists());
    let h2 = s.add_bytes(&bytes(41, 70_000)).unwrap().hash;
    assert_eq!(s.export(&h2, &d.path().join("shared/y.bin"), ExportMode::Move).unwrap().how, ExportHow::Moved);
}

#[cfg(unix)]
fn file_id(p: &Path) -> u64 {
    use std::os::unix::fs::MetadataExt;
    fs::metadata(p).unwrap().ino()
}
#[cfg(not(unix))]
fn file_id(p: &Path) -> u64 {
    fs::metadata(p).unwrap().len()
}

/// A reader that fails part way, as if the write were cut off.
struct Cut {
    left: usize,
}

impl Read for Cut {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.left == 0 {
            return Err(io::Error::other("cut off"));
        }
        let n = buf.len().min(self.left);
        buf[..n].fill(7);
        self.left -= n;
        Ok(n)
    }
}

#[test]
fn an_interrupted_import_leaves_the_old_state() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let old = bytes(50, 80_000);
    let h = s.add_bytes(&old).unwrap().hash;
    s.set_tag(b"old", &h).unwrap();
    let files_before = data_files(d.path());

    // Cut off half way: an error, no new entry, no new file, no temp file left.
    let err = s.add_reader(Cut { left: 150_000 }, 300_000);
    assert!(err.is_err());
    assert_eq!(data_files(d.path()), files_before);
    assert_eq!(tmp_files(d.path()), 0);
    assert_eq!(s.get_bytes(&h).unwrap(), old);

    let p = write(d.path(), "short.bin", &bytes(51, 90_000));
    // Failure injected after the files are renamed and before the index commit (the app killed between the two).
    s.set_fault(Some(cache_store::Fault::BeforeCommit));
    assert!(s.add_path(&p, ImportMode::Copy).is_err());
    assert!(s.add_bytes(&bytes(52, 70_000)).is_err());
    s.set_fault(None);
    let ghost = Hash::new(bytes(52, 70_000));
    assert_eq!(s.status(&ghost).unwrap(), Status::Absent, "nothing was committed");
    assert_eq!(s.get_bytes(&h).unwrap(), old, "the old entry is intact");

    // After a restart: the old state is there, the renamed-but-uncommitted files are strays, and gc sweeps them.
    s.shutdown().unwrap();
    drop(s);
    let s = open(d.path());
    assert_eq!(s.get_bytes(&h).unwrap(), old);
    assert_eq!(s.tags_with_prefix(b"old").unwrap(), vec![(b"old".to_vec(), h)]);
    assert!(data_files(d.path()).len() > files_before.len(), "the strays are on disk, not in the index");
    let r = s.gc().unwrap();
    assert_eq!(r.entries, 0);
    assert!(r.files >= 4, "{r:?}");
    assert_eq!(data_files(d.path()), files_before);
    // And the same imports work once the fault is gone.
    assert!(s.add_path(&p, ImportMode::Copy).is_ok());
    assert!(s.add_bytes(&bytes(52, 70_000)).is_ok());
}

#[test]
fn a_crash_while_completing_a_partial_file_keeps_the_partial() {
    let d = TempDir::new().unwrap();
    let src = open(&d.path().join("src"));
    let dst = open(&d.path().join("dst"));
    let data = bytes(60, 200_000);
    let h = src.add_bytes(&data).unwrap().hash;
    let tree_chunks = 200_000u64.div_ceil(1024);
    let w1 = window(0, 100);
    dst.import_ranges(&h, &w1, &src.encode_ranges_to_vec(&h, &w1).unwrap()).unwrap();

    dst.set_fault(Some(cache_store::Fault::BeforeCommit));
    let rest = ChunkRanges::from(ChunkNum(100)..ChunkNum(tree_chunks));
    let piece = src.encode_ranges_to_vec(&h, &rest).unwrap();
    assert!(dst.import_ranges(&h, &rest, &piece).is_err(), "killed between the rename and the commit");
    dst.set_fault(None);
    dst.shutdown().unwrap();
    drop(dst);

    // The index still says partial with the first window; the renamed files are gone from where the partial expects them, so
    // the entry is reported Absent (not corrupt) and is fetched again from the start.
    let dst = open(&d.path().join("dst"));
    match dst.status(&h).unwrap() {
        Status::Absent => {}
        Status::Partial { have, .. } => assert!(!have.is_superset(&ChunkRanges::from(ChunkNum(0)..ChunkNum(tree_chunks)))),
        Status::Complete { .. } => panic!("a half-committed entry must not read as complete"),
    }
    transfer(&src, &dst, &h, 200_000, 100);
    assert_eq!(dst.get_bytes(&h).unwrap(), data);
}

fn full(size: u64) -> ChunkRanges {
    ChunkRanges::from(ChunkNum(0)..ChunkNum(size.div_ceil(1024).max(1)))
}

#[test]
fn verified_pieces_move_a_file_between_stores() {
    let d = TempDir::new().unwrap();
    let src = open(&d.path().join("src"));
    let dst = open(&d.path().join("dst"));
    for (i, size) in [0usize, 1, 1024, 16 * 1024, 16 * 1024 + 1, 100_000, 1_048_576 + 777].into_iter().enumerate() {
        let data = bytes(70 + i as u8, size);
        let h = src.add_bytes(&data).unwrap().hash;
        transfer(&src, &dst, &h, size as u64, 64);
        assert_eq!(dst.status(&h).unwrap(), Status::Complete { size: size as u64 }, "size {size}");
        assert_eq!(dst.get_bytes(&h).unwrap(), data, "size {size}");
        // One window past the end is fine too.
        let all = src.encode_ranges_to_vec(&h, &full(size as u64)).unwrap();
        assert_eq!(dst.encode_ranges_to_vec(&h, &full(size as u64)).unwrap(), all, "size {size}");
    }
}

#[test]
fn a_partial_entry_records_what_it_holds_and_serves_it() {
    let d = TempDir::new().unwrap();
    let src = open(&d.path().join("src"));
    let dst = open(&d.path().join("dst"));
    let size = 1_000_000usize;
    let data = bytes(80, size);
    let h = src.add_bytes(&data).unwrap().hash;
    assert_eq!(dst.status(&h).unwrap(), Status::Absent);

    // The third window of 160 chunks first, then the first.
    let (w3, w1) = (window(2, 160), window(0, 160));
    dst.import_ranges(&h, &w3, &src.encode_ranges_to_vec(&h, &w3).unwrap()).unwrap();
    match dst.status(&h).unwrap() {
        Status::Partial { size: s, have } => {
            assert_eq!(s, size as u64);
            assert!(have.is_superset(&w3) && !have.is_superset(&w1));
        }
        other => panic!("{other:?}"),
    }
    assert!(dst.get_bytes(&h).is_err(), "a partial file is not readable");
    assert!(dst.export(&h, &d.path().join("x"), ExportMode::Copy).is_err());
    // It serves what it holds, byte for byte what the full copy serves, and refuses what it does not.
    assert_eq!(dst.encode_ranges_to_vec(&h, &w3).unwrap(), src.encode_ranges_to_vec(&h, &w3).unwrap());
    assert!(dst.encode_ranges_to_vec(&h, &w1).is_err());

    // The record survives a restart, and a fetch resumes.
    dst.shutdown().unwrap();
    drop(dst);
    let dst = open(&d.path().join("dst"));
    assert!(matches!(dst.status(&h).unwrap(), Status::Partial { .. }));
    dst.import_ranges(&h, &w1, &src.encode_ranges_to_vec(&h, &w1).unwrap()).unwrap();
    let both: ChunkRanges = w1.union(&w3);
    let rest: ChunkRanges = ChunkRanges::from(ChunkNum(0)..ChunkNum(1_000_000u64.div_ceil(1024))).difference(&both);
    dst.import_ranges(&h, &rest, &src.encode_ranges_to_vec(&h, &rest).unwrap()).unwrap();
    assert_eq!(dst.status(&h).unwrap(), Status::Complete { size: size as u64 });
    assert_eq!(dst.get_bytes(&h).unwrap(), data);
    let names = data_files(&d.path().join("dst"));
    assert_eq!(names, vec![format!("{}.data", h.to_hex()), format!("{}.obao", h.to_hex())], "the partial files became the complete ones");
}

#[test]
fn a_piece_that_does_not_verify_is_not_kept() {
    let d = TempDir::new().unwrap();
    let src = open(&d.path().join("src"));
    let dst = open(&d.path().join("dst"));
    let size = 600_000usize;
    let data = bytes(90, size);
    let h = src.add_bytes(&data).unwrap().hash;

    let w = window(0, 600);
    let mut piece = src.encode_ranges_to_vec(&h, &w).unwrap();
    // Flip a byte deep in the data: the leaves before it verify and stay, the damaged one and the rest do not.
    let at = piece.len() - 300_000;
    piece[at] ^= 1;
    let err = dst.import_ranges(&h, &w, &piece).unwrap_err();
    assert!(matches!(err, cache_store::Error::Verify(_)), "{err}");
    match dst.status(&h).unwrap() {
        Status::Partial { have, .. } => {
            assert!(!have.is_empty(), "the verified leaves before the damage are kept");
            assert!(!have.is_superset(&w), "the damaged leaf is not");
        }
        other => panic!("{other:?}"),
    }
    // The good piece then completes it, and the data is right.
    transfer(&src, &dst, &h, size as u64, 600);
    assert_eq!(dst.get_bytes(&h).unwrap(), data);

    // Wrong hash: nothing verifies, nothing is kept.
    let other = Hash::new(b"not this");
    assert!(dst.import_ranges(&other, &w, &src.encode_ranges_to_vec(&h, &w).unwrap()).is_err());
    assert!(!matches!(dst.status(&other).unwrap(), Status::Complete { .. }));
    // A size of zero is only the empty hash's.
    assert!(dst.import_ranges(&other, &w, &0u64.to_le_bytes()).is_err());
    assert!(dst.import_ranges(&Hash::EMPTY, &w, &0u64.to_le_bytes()).is_ok());
    assert!(dst.has(&Hash::EMPTY).unwrap());
    assert!(src.encode_ranges_to_vec(&Hash::new(b"unknown"), &w).is_err());
}

#[test]
fn partial_entries_that_nothing_wants_are_swept() {
    let d = TempDir::new().unwrap();
    let src = open(&d.path().join("src"));
    let dst = open(&d.path().join("dst"));
    let h = src.add_bytes(&bytes(95, 300_000)).unwrap().hash;
    let w = window(0, 64);
    dst.import_ranges(&h, &w, &src.encode_ranges_to_vec(&h, &w).unwrap()).unwrap();
    assert_eq!(data_files(&d.path().join("dst")).len(), 2);
    // Wanted (tagged): kept. Not wanted: gone, files and all.
    dst.set_tag(b"want", &h).unwrap();
    assert_eq!(dst.gc().unwrap().entries, 0);
    dst.delete_tag(b"want").unwrap();
    assert_eq!(dst.gc().unwrap().entries, 1);
    assert!(data_files(&d.path().join("dst")).is_empty());
    assert_eq!(dst.status(&h).unwrap(), Status::Absent);
}

#[test]
fn nothing_works_after_shutdown() {
    let d = TempDir::new().unwrap();
    let s = open(d.path());
    let c = s.clone();
    s.shutdown().unwrap();
    assert!(c.status(&Hash::EMPTY).is_err());
    let _ = SystemTime::now();
}
