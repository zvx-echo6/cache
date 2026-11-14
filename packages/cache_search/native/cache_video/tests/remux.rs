//! A saved HLS video (fragmented MP4) is rewritten as a plain MP4 every player can seek: Android's read the first fragment's
//! index as the whole file and played a 1:59 video as "0:04 / 0:04".

mod common;

use cache_video::remux::{is_fragmented, remux, remux_in_place};
use common::{fragmented_mp4, top_kinds as kinds, FMP4_DELTA as DELTA, FMP4_FRAGMENTS as FRAGMENTS, FMP4_PER_FRAGMENT as PER_FRAGMENT};
use mp4_atom::{Decode, Moov, StszSamples};
use std::path::{Path, PathBuf};

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("cache-remux-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn fragmented(path: &Path) -> Vec<Vec<u8>> {
    let (bytes, samples) = fragmented_mp4();
    std::fs::write(path, bytes).unwrap();
    samples
}

#[test]
fn a_fragmented_video_becomes_one_moov_and_one_mdat_with_its_whole_duration_and_every_sample_where_the_tables_say() {
    let d = tmp("whole");
    let src = d.join("video.mp4");
    let samples = fragmented(&src);
    assert!(is_fragmented(&src).unwrap());
    let dst = d.join("out.mp4");
    let r = remux(&src, &dst).unwrap();
    assert_eq!(r.samples, samples.len());
    assert_eq!(r.fragments, FRAGMENTS as usize);
    assert_eq!(r.duration_ms, (FRAGMENTS * PER_FRAGMENT * DELTA) as u64);

    let b = std::fs::read(&dst).unwrap();
    let names: Vec<String> = kinds(&b).into_iter().map(|k| k.0).collect();
    assert_eq!(names, ["ftyp", "moov", "mdat"], "no moof and no sidx left");
    assert!(!is_fragmented(&dst).unwrap());
    let (_, moov_at, moov_len) = kinds(&b).into_iter().find(|k| k.0 == "moov").unwrap();
    let moov = Moov::decode(&mut &b[moov_at..moov_at + moov_len]).unwrap();
    assert!(moov.mvex.is_none());
    let total = (FRAGMENTS * PER_FRAGMENT * DELTA) as u64;
    assert_eq!(moov.mvhd.duration, total, "the movie knows its length (it was 0)");
    let trak = &moov.trak[0];
    assert_eq!(trak.mdia.mdhd.duration, total);
    assert_eq!(trak.tkhd.duration, total);
    let stbl = &trak.mdia.minf.stbl;
    assert_eq!(stbl.stts.entries.len(), 1);
    assert_eq!((stbl.stts.entries[0].sample_count, stbl.stts.entries[0].sample_delta), (FRAGMENTS * PER_FRAGMENT, DELTA));
    assert_eq!(stbl.stss.as_ref().unwrap().entries, (0..FRAGMENTS).map(|f| f * PER_FRAGMENT + 1).collect::<Vec<_>>(), "the sync samples");
    let sizes = match &stbl.stsz.samples {
        StszSamples::Different { sizes } => sizes.clone(),
        StszSamples::Identical { count, size } => vec![*size; *count as usize],
    };
    assert_eq!(sizes, samples.iter().map(|s| s.len() as u32).collect::<Vec<_>>());
    // every sample's bytes, found through the chunk offsets and the sample-to-chunk table, are the original's
    let offsets = stbl.stco.as_ref().unwrap().entries.clone();
    assert_eq!(offsets.len(), FRAGMENTS as usize, "one chunk per fragment");
    assert!(stbl.stsc.entries.iter().all(|e| e.samples_per_chunk == PER_FRAGMENT));
    let mut i = 0usize;
    for &o in &offsets {
        let mut at = o as usize;
        for _ in 0..PER_FRAGMENT {
            assert_eq!(&b[at..at + sizes[i] as usize], samples[i].as_slice(), "sample {i}");
            at += sizes[i] as usize;
            i += 1;
        }
    }
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn in_place_it_needs_room_for_a_second_copy_and_leaves_the_original_otherwise() {
    let d = tmp("inplace");
    let v = d.join("video.mp4");
    fragmented(&v);
    let before = std::fs::read(&v).unwrap();
    // not enough room: nothing changes
    assert_eq!(remux_in_place(&v, before.len() as u64, 1).unwrap(), None);
    assert_eq!(std::fs::read(&v).unwrap(), before);
    assert!(!d.join(".video.remux").exists());
    // with room: the video is the remuxed one, and nothing is left beside it
    let done = remux_in_place(&v, u64::MAX, 0).unwrap().expect("remuxed");
    assert_eq!(done.fragments, FRAGMENTS as usize);
    assert!(!is_fragmented(&v).unwrap());
    assert!(!d.join(".video.remux").exists());
    // a second time: already plain, nothing to do
    assert_eq!(remux_in_place(&v, u64::MAX, 0).unwrap(), None);
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn a_damaged_fragment_leaves_the_original_and_no_half_copy() {
    let d = tmp("damaged");
    let v = d.join("video.mp4");
    fragmented(&v);
    let mut b = std::fs::read(&v).unwrap();
    // cut the file inside the last mdat: its samples run past the end
    b.truncate(b.len() - 10);
    std::fs::write(&v, &b).unwrap();
    assert!(remux_in_place(&v, u64::MAX, 0).is_err());
    assert_eq!(std::fs::read(&v).unwrap(), b, "the original is untouched");
    assert!(!d.join(".video.remux").exists(), "no half copy");
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn saved_hls_videos_from_before_are_rewritten_once_one_at_a_time_and_their_manifests_say_so() {
    let d = tmp("repair");
    let root = d.join("downloads").join("tube.example");
    let hls = root.join("11111111-1111-4111-8111-111111111111");
    let web = root.join("22222222-2222-4222-8222-222222222222");
    std::fs::create_dir_all(&hls).unwrap();
    std::fs::create_dir_all(&web).unwrap();
    let samples = fragmented(&hls.join("video.mp4"));
    std::fs::write(hls.join("manifest.json"), r#"{"source":"hls","file":"video.mp4","size":1,"sha256":"old"}"#).unwrap();
    std::fs::write(web.join("video.mp4"), b"not an mp4 at all").unwrap();
    std::fs::write(web.join("manifest.json"), r#"{"source":"web","file":"video.mp4"}"#).unwrap();
    let video = cache_video::Video::new(&cache_video::VideoCfg { dir: d.to_string_lossy().into_owned() });
    let seen = std::cell::RefCell::new(vec![]);
    let r = cache_video::remux::repair_saved(&video, &|a, b| seen.borrow_mut().push((a, b)), &|| false).unwrap();
    assert_eq!(r, cache_video::remux::Repaired { remuxed: 1, no_room: 0, failed: 0 });
    assert_eq!(seen.borrow().last(), Some(&(1, 1)), "one video to look at");
    let saved = std::fs::read(hls.join("video.mp4")).unwrap();
    assert_eq!(kinds(&saved).into_iter().map(|k| k.0).collect::<Vec<_>>(), ["ftyp", "moov", "mdat"]);
    assert!(saved.windows(samples.concat().len()).any(|w| w == samples.concat().as_slice()));
    let m: serde_json::Value = serde_json::from_slice(&std::fs::read(hls.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(m["remuxed"], true);
    assert_eq!(m["size"].as_u64().unwrap(), saved.len() as u64);
    assert_eq!(m["sha256"].as_str().unwrap(), common::sha_hex(&saved));
    assert_eq!(std::fs::read(web.join("video.mp4")).unwrap(), b"not an mp4 at all", "a web video is left alone");
    // the next pass has nothing to do
    let again = cache_video::remux::repair_saved(&video, &|_, _| {}, &|| false).unwrap();
    assert_eq!(again, cache_video::remux::Repaired::default());
    let _ = std::fs::remove_dir_all(&d);
}
