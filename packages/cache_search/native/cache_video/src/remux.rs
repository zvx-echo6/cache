//! A saved video that a PeerTube site serves as HLS arrives as one fragmented MP4: a `moov` with no samples (its duration 0, an
//! `mvex`), then `moof`+`mdat` fragments, each with its own `sidx`. Chrome plays that, but Android's player reads the first
//! `sidx` as the whole file: about 4 seconds, with nothing to seek to (a 1:59 video played as "0:04 / 0:04"). So a fragmented
//! file is rewritten as a plain progressive MP4: one `moov` with every sample in its tables, then one `mdat`, the samples' bytes
//! unchanged and in the same order.
//!
//! The new file is written beside the original and renamed over it only when it is complete; nothing is changed when there is
//! not room for a second copy or anything fails.

use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use mp4_atom::{Co64, Ctts, CttsEntry, Decode, Encode, Ftyp, Moof, Moov, Stco, Stsc, StscEntry, Stss, Stsz, StszSamples, Stts, SttsEntry};

use crate::{Error, Result};

/// One top-level box of the file: where it starts and its whole length.
#[derive(Debug, Clone, Copy)]
struct TopBox {
    kind: [u8; 4],
    start: u64,
    size: u64,
}

fn io_err(what: &str, e: impl std::fmt::Display) -> Error {
    Error::io(format!("{what}: {e}"))
}

fn mp4_err(what: &str, e: impl std::fmt::Display) -> Error {
    Error::new("damaged", format!("{what}: {e}"))
}

/// The top-level boxes, read from their headers only (an `mdat` is never read here).
fn top_boxes(f: &mut File) -> Result<Vec<TopBox>> {
    let len = f.metadata().map_err(|e| io_err("reading the video", e))?.len();
    let mut out = vec![];
    let mut pos = 0u64;
    while pos + 8 <= len {
        f.seek(SeekFrom::Start(pos)).map_err(|e| io_err("reading the video", e))?;
        let mut h = [0u8; 16];
        f.read_exact(&mut h[..8]).map_err(|e| io_err("reading the video", e))?;
        let size32 = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as u64;
        let kind = [h[4], h[5], h[6], h[7]];
        let (header, size) = match size32 {
            1 => {
                f.read_exact(&mut h[8..16]).map_err(|e| io_err("reading the video", e))?;
                (16, u64::from_be_bytes([h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]]))
            }
            0 => (8, len - pos),
            s => (8, s),
        };
        if size < header || pos + size > len {
            return Err(Error::new("damaged", format!("the video's {} box at {pos} runs past the end", String::from_utf8_lossy(&kind))));
        }
        out.push(TopBox { kind, start: pos, size });
        pos += size;
    }
    Ok(out)
}

fn read_box(f: &mut File, b: &TopBox) -> Result<Vec<u8>> {
    let mut buf = vec![0u8; b.size as usize];
    f.seek(SeekFrom::Start(b.start)).map_err(|e| io_err("reading the video", e))?;
    f.read_exact(&mut buf).map_err(|e| io_err("reading the video", e))?;
    Ok(buf)
}

/// Whether [path] is a fragmented MP4 (it has a `moof`): such a file is remuxed. A file that does not begin like an MP4 (a WebM,
/// an MP3) is not one; an MP4 whose boxes run past its end is an error.
pub fn is_fragmented(path: &Path) -> Result<bool> {
    let mut f = File::open(path).map_err(|e| io_err(&format!("opening {}", path.display()), e))?;
    let mut first = [0u8; 8];
    if f.read_exact(&mut first).is_err() || !matches!(&first[4..8], b"ftyp" | b"styp" | b"moov" | b"sidx" | b"free" | b"skip") {
        return Ok(false);
    }
    Ok(top_boxes(&mut f)?.iter().any(|b| &b.kind == b"moof"))
}

/// One sample: where its bytes are in the original file, and its timing.
#[derive(Debug, Clone, Copy)]
struct Sample {
    offset: u64,
    size: u32,
    duration: u32,
    sync: bool,
    cts: i64,
}

/// A run of samples that sit together in the original file (one `trun`): it becomes one chunk of the new file.
#[derive(Debug, Clone, Copy)]
struct Run {
    track: u32,
    desc: u32,
    first: usize,
    count: usize,
}

/// What a remux did, for the log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Remuxed {
    pub samples: usize,
    pub fragments: usize,
    pub duration_ms: u64,
}

/// `sample_is_non_sync_sample` in a sample's flags.
const NON_SYNC: u32 = 0x0001_0000;

/// Rewrites the fragmented MP4 at [src] as a progressive MP4 at [dst]. [dst] is written whole or not at all (a failure removes it).
pub fn remux(src: &Path, dst: &Path) -> Result<Remuxed> {
    let r = remux_inner(src, dst);
    if r.is_err() {
        let _ = std::fs::remove_file(dst);
    }
    r
}

fn remux_inner(src: &Path, dst: &Path) -> Result<Remuxed> {
    let mut f = File::open(src).map_err(|e| io_err(&format!("opening {}", src.display()), e))?;
    let boxes = top_boxes(&mut f)?;
    let ftyp_box = boxes.iter().find(|b| &b.kind == b"ftyp");
    let moov_box = boxes.iter().find(|b| &b.kind == b"moov").ok_or_else(|| Error::new("damaged", "the video has no moov"))?;
    let ftyp: Option<Ftyp> = match ftyp_box {
        Some(b) => Some(Ftyp::decode(&mut read_box(&mut f, b)?.as_slice()).map_err(|e| mp4_err("reading the video's ftyp", e))?),
        None => None,
    };
    let mut moov = Moov::decode(&mut read_box(&mut f, moov_box)?.as_slice()).map_err(|e| mp4_err("reading the video's moov", e))?;
    let trex = moov.mvex.as_ref().map(|m| m.trex.clone()).unwrap_or_default();

    // every sample of every track, in file order, grouped in runs
    let mut samples: Vec<Vec<Sample>> = vec![vec![]; moov.trak.len()];
    let track_index = |id: u32, moov: &Moov| moov.trak.iter().position(|t| t.tkhd.track_id == id);
    let mut runs: Vec<Run> = vec![];
    let mut fragments = 0usize;
    // the next decode time of each track (from tfdt, else where the last fragment ended)
    for b in boxes.iter().filter(|b| &b.kind == b"moof") {
        fragments += 1;
        let moof = Moof::decode(&mut read_box(&mut f, b)?.as_slice()).map_err(|e| mp4_err("reading a fragment of the video", e))?;
        for traf in &moof.traf {
            let id = traf.tfhd.track_id;
            let Some(ti) = track_index(id, &moov) else {
                return Err(Error::new("damaged", format!("a fragment names track {id}, which the video does not have")));
            };
            let tx = trex.iter().find(|t| t.track_id == id);
            let default_duration = traf.tfhd.default_sample_duration.or(tx.map(|t| t.default_sample_duration)).unwrap_or(0);
            let default_size = traf.tfhd.default_sample_size.or(tx.map(|t| t.default_sample_size)).unwrap_or(0);
            let default_flags = traf.tfhd.default_sample_flags.or(tx.map(|t| t.default_sample_flags)).unwrap_or(0);
            let desc = traf.tfhd.sample_description_index.or(tx.map(|t| t.default_sample_description_index)).unwrap_or(1).max(1);
            // the base the runs' data offsets count from: tfhd's, else the start of this moof (default-base-is-moof, and what
            // a single-track fragment without either means in practice)
            let base = traf.tfhd.base_data_offset.unwrap_or(b.start);
            let mut next = base;
            for trun in &traf.trun {
                let mut at = match trun.data_offset {
                    Some(o) => (base as i64 + o as i64) as u64,
                    None => next,
                };
                let first = samples[ti].len();
                for i in 0..trun.samples.len() {
                    let e = trun.samples.get(i).unwrap_or_default();
                    let size = e.size.unwrap_or(default_size);
                    let flags = e.flags.unwrap_or(default_flags);
                    samples[ti].push(Sample { offset: at, size, duration: e.duration.unwrap_or(default_duration), sync: flags & NON_SYNC == 0, cts: e.cts.unwrap_or(0) });
                    at += size as u64;
                }
                next = at;
                let count = samples[ti].len() - first;
                if count > 0 {
                    runs.push(Run { track: ti as u32, desc, first, count });
                }
            }
        }
    }
    if runs.is_empty() {
        return Err(Error::new("damaged", "the video has no samples in its fragments"));
    }
    let len = f.metadata().map_err(|e| io_err("reading the video", e))?.len();
    for (ti, s) in samples.iter().enumerate() {
        if let Some(bad) = s.iter().find(|x| x.offset + x.size as u64 > len) {
            return Err(Error::new("damaged", format!("track {} has a sample past the end of the file (at {})", ti + 1, bad.offset)));
        }
    }
    let data_len: u64 = runs.iter().map(|r| samples[r.track as usize][r.first..r.first + r.count].iter().map(|s| s.size as u64).sum::<u64>()).sum();

    // the sample tables, with the chunk offsets filled in once the moov's size is known
    let big = data_len + (64 << 10) > u32::MAX as u64;
    let movie_ts = moov.mvhd.timescale.max(1) as u64;
    let mut movie_duration = 0u64;
    for (ti, trak) in moov.trak.iter_mut().enumerate() {
        let s = &samples[ti];
        let stbl = &mut trak.mdia.minf.stbl;
        let mut stts: Vec<SttsEntry> = vec![];
        for x in s {
            match stts.last_mut() {
                Some(e) if e.sample_delta == x.duration => e.sample_count += 1,
                _ => stts.push(SttsEntry { sample_count: 1, sample_delta: x.duration }),
            }
        }
        stbl.stts = Stts { entries: stts };
        stbl.ctts = if s.iter().any(|x| x.cts != 0) {
            let mut c: Vec<CttsEntry> = vec![];
            for x in s {
                match c.last_mut() {
                    Some(e) if e.sample_offset == x.cts => e.sample_count += 1,
                    _ => c.push(CttsEntry { sample_count: 1, sample_offset: x.cts }),
                }
            }
            Some(Ctts { entries: c })
        } else {
            None
        };
        stbl.stss = if s.iter().all(|x| x.sync) {
            None
        } else {
            Some(Stss { entries: s.iter().enumerate().filter(|(_, x)| x.sync).map(|(i, _)| i as u32 + 1).collect() })
        };
        stbl.stsz = Stsz { samples: StszSamples::Different { sizes: s.iter().map(|x| x.size).collect() } };
        let mut stsc: Vec<StscEntry> = vec![];
        for (ci, r) in runs.iter().filter(|r| r.track as usize == ti).enumerate() {
            match stsc.last() {
                Some(e) if e.samples_per_chunk == r.count as u32 && e.sample_description_index == r.desc => {}
                _ => stsc.push(StscEntry { first_chunk: ci as u32 + 1, samples_per_chunk: r.count as u32, sample_description_index: r.desc }),
            }
        }
        stbl.stsc = Stsc { entries: stsc };
        let chunks = runs.iter().filter(|r| r.track as usize == ti).count();
        if big {
            stbl.stco = None;
            stbl.co64 = Some(Co64 { entries: vec![0; chunks] });
        } else {
            stbl.co64 = None;
            stbl.stco = Some(Stco { entries: vec![0; chunks] });
        }
        // a fragment's own sample groups and auxiliary info do not describe the new tables
        stbl.sbgp.clear();
        stbl.sgpd.clear();
        stbl.subs.clear();
        stbl.saiz.clear();
        stbl.saio.clear();
        let total: u64 = s.iter().map(|x| x.duration as u64).sum();
        trak.mdia.mdhd.duration = total;
        let media_ts = trak.mdia.mdhd.timescale.max(1) as u64;
        let in_movie = total * movie_ts / media_ts;
        trak.tkhd.duration = in_movie;
        movie_duration = movie_duration.max(in_movie);
    }
    moov.mvex = None;
    moov.mvhd.duration = movie_duration;

    let mut head: Vec<u8> = vec![];
    if let Some(ft) = &ftyp {
        ft.encode(&mut head).map_err(|e| mp4_err("writing the ftyp", e))?;
    }
    let mut probe: Vec<u8> = vec![];
    moov.encode(&mut probe).map_err(|e| mp4_err("writing the moov", e))?;
    let mdat_header: u64 = if data_len + 8 > u32::MAX as u64 { 16 } else { 8 };
    let data_start = head.len() as u64 + probe.len() as u64 + mdat_header;
    // the chunk offsets: the runs in file order, packed one after another in the mdat
    let mut offsets: Vec<Vec<u64>> = vec![vec![]; moov.trak.len()];
    let mut at = data_start;
    for r in &runs {
        offsets[r.track as usize].push(at);
        at += samples[r.track as usize][r.first..r.first + r.count].iter().map(|s| s.size as u64).sum::<u64>();
    }
    for (ti, trak) in moov.trak.iter_mut().enumerate() {
        let stbl = &mut trak.mdia.minf.stbl;
        if let Some(c) = stbl.co64.as_mut() {
            c.entries = offsets[ti].clone();
        }
        if let Some(c) = stbl.stco.as_mut() {
            c.entries = offsets[ti].iter().map(|&o| o as u32).collect();
        }
    }
    let mut moov_bytes: Vec<u8> = vec![];
    moov.encode(&mut moov_bytes).map_err(|e| mp4_err("writing the moov", e))?;
    if moov_bytes.len() != probe.len() {
        return Err(Error::new("internal", "the moov changed size when its offsets were filled in"));
    }

    let out = File::create(dst).map_err(|e| io_err(&format!("creating {}", dst.display()), e))?;
    let mut w = BufWriter::with_capacity(1 << 20, out);
    let werr = |e: std::io::Error| io_err("writing the remuxed video", e);
    w.write_all(&head).map_err(werr)?;
    w.write_all(&moov_bytes).map_err(werr)?;
    if mdat_header == 16 {
        w.write_all(&1u32.to_be_bytes()).map_err(werr)?;
        w.write_all(b"mdat").map_err(werr)?;
        w.write_all(&(data_len + 16).to_be_bytes()).map_err(werr)?;
    } else {
        w.write_all(&((data_len + 8) as u32).to_be_bytes()).map_err(werr)?;
        w.write_all(b"mdat").map_err(werr)?;
    }
    let mut r = BufReader::with_capacity(1 << 20, f);
    let mut buf = vec![0u8; 1 << 20];
    for run in &runs {
        let s = &samples[run.track as usize][run.first..run.first + run.count];
        // a run's samples are one contiguous span of the original
        let start = s[0].offset;
        let mut left: u64 = s.iter().map(|x| x.size as u64).sum();
        if s.windows(2).any(|p| p[0].offset + p[0].size as u64 != p[1].offset) {
            // not contiguous after all: copy sample by sample
            for x in s {
                copy_span(&mut r, &mut w, &mut buf, x.offset, x.size as u64)?;
            }
            continue;
        }
        r.seek(SeekFrom::Start(start)).map_err(|e| io_err("reading the video", e))?;
        while left > 0 {
            let n = (left as usize).min(buf.len());
            r.read_exact(&mut buf[..n]).map_err(|e| io_err("reading the video", e))?;
            w.write_all(&buf[..n]).map_err(werr)?;
            left -= n as u64;
        }
    }
    let file = w.into_inner().map_err(|e| io_err("writing the remuxed video", e.error()))?;
    file.sync_all().map_err(|e| io_err("writing the remuxed video", e))?;
    let duration_ms = movie_duration * 1000 / movie_ts;
    Ok(Remuxed { samples: samples.iter().map(|s| s.len()).sum(), fragments, duration_ms })
}

fn copy_span(r: &mut BufReader<File>, w: &mut BufWriter<File>, buf: &mut [u8], at: u64, len: u64) -> Result<()> {
    r.seek(SeekFrom::Start(at)).map_err(|e| io_err("reading the video", e))?;
    let mut left = len;
    while left > 0 {
        let n = (left as usize).min(buf.len());
        r.read_exact(&mut buf[..n]).map_err(|e| io_err("reading the video", e))?;
        w.write_all(&buf[..n]).map_err(|e| io_err("writing the remuxed video", e))?;
        left -= n as u64;
    }
    Ok(())
}

/// The temporary name a remux writes to, beside the video (hidden: the sync skips it).
pub fn remux_path(video: &Path) -> PathBuf {
    video.with_file_name(".video.remux")
}

/// Remuxes the fragmented video at [video] in place: a second copy is written beside it when there is room ([free] bytes, with
/// [margin] kept), then renamed over it. Ok(None) when the file is not fragmented or there is not room (the original is
/// left as it is); Err when the remux failed (the original is left as it is too).
pub fn remux_in_place(video: &Path, free: u64, margin: u64) -> Result<Option<Remuxed>> {
    if !is_fragmented(video)? {
        return Ok(None);
    }
    let size = std::fs::metadata(video).map_err(|e| io_err("reading the video", e))?.len();
    if size.saturating_add(margin) > free {
        return Ok(None);
    }
    let tmp = remux_path(video);
    let done = remux(video, &tmp)?;
    std::fs::rename(&tmp, video).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        io_err("renaming the remuxed video", e)
    })?;
    Ok(Some(done))
}

/// What a pass over the saved videos did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Repaired {
    pub remuxed: usize,
    /// Not rewritten for want of room for a second copy (tried again at the next pass).
    pub no_room: usize,
    pub failed: usize,
}

/// Saved HLS videos from before saved videos were rewritten as plain MP4 (on the device, or synced from one): each is rewritten
/// once, one at a time, and its manifest then says so, with the file's new size and sha256. Run on a job's thread after start,
/// never in the way of other calls; [cancel] is looked at between videos. A video that cannot be rewritten stays as it is, with
/// one line in the log.
pub fn repair_saved(video: &crate::Video, progress: &dyn Fn(u64, u64), cancel: &dyn Fn() -> bool) -> Result<Repaired> {
    let root = video.downloads_root();
    let mut todo: Vec<(PathBuf, serde_json::Value)> = vec![];
    for inst in std::fs::read_dir(&root).into_iter().flatten().flatten() {
        for one in std::fs::read_dir(inst.path()).into_iter().flatten().flatten() {
            let dir = one.path();
            let Ok(text) = std::fs::read_to_string(dir.join("manifest.json")) else { continue };
            let Ok(m) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
            if m["source"].as_str().is_some_and(|s| s.starts_with("hls")) && m["remuxed"] != true {
                todo.push((dir, m));
            }
        }
    }
    let mut done = Repaired::default();
    let total = todo.len() as u64;
    progress(0, total);
    for (i, (dir, mut m)) in todo.into_iter().enumerate() {
        if cancel() {
            break;
        }
        let Some(file) = m["file"].as_str().map(|f| dir.join(f)) else { continue };
        let free = crate::dl::available_bytes(&dir).unwrap_or(0);
        match remux_in_place(&file, free, crate::dl::MARGIN) {
            Ok(Some(_)) => {
                let size = std::fs::metadata(&file).map(|x| x.len()).unwrap_or(0);
                match crate::dl::sha256_file(&file) {
                    Ok(sha) => {
                        m["size"] = size.into();
                        m["sha256"] = sha.into();
                        m["remuxed"] = true.into();
                        crate::store::write_atomic(&dir.join("manifest.json"), m.to_string().as_bytes())?;
                        done.remuxed += 1;
                    }
                    Err(e) => {
                        eprintln!("cache_video: {} was rewritten as a plain MP4 but could not be read back: {}", dir.display(), e.message);
                        done.failed += 1;
                    }
                }
            }
            Ok(None) => {
                // plain already (a file that never was fragmented), or no room for a second copy: told apart for the count
                if is_fragmented(&file).unwrap_or(false) {
                    done.no_room += 1;
                }
            }
            Err(e) => {
                eprintln!("cache_video: {} kept as it is; it could not be rewritten as a plain MP4: {}", dir.display(), e.message);
                done.failed += 1;
            }
        }
        progress(i as u64 + 1, total);
    }
    Ok(done)
}
