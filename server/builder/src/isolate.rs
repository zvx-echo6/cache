//! Reading a PDF in a child process. MuPDF is C code, and a few damaged PDFs crash it (a segmentation fault, which no Rust code can
//! catch). In the server that would take the whole service down, and after the restart the queue would pick the same file again.
//! So the program re-runs itself with a hidden `extract-pdf` command, and that child does the one risky step (MuPDF's extraction)
//! with the same [`extract_pdf`](crate::extract::extract_pdf) code. The parent keeps layout, chunking, embedding and writing.
//!
//! The PDF goes to the child in a temporary file and the extraction comes back in another (`Extracted::to_wire`), named by the
//! environment, so nothing the child prints (MuPDF warnings, a test harness) can get mixed into the result. A child that crashes, runs
//! past its time or exits with anything but a clean result fails extraction of this one PDF; the parent is never touched.\n//! Compression is optional: its timeout keeps the original PDF, which still has to pass extraction.
//!
//! On Linux the child also gets an address-space limit (RLIMIT_AS), so a PDF that makes MuPDF ask for runaway memory fails alone.

use crate::compress::{compress_pdf, Compression, CompressionOutcome};
use crate::error::{Error, Result};
use crate::extract::{extract_pdf, Extracted};
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Why a book fails when its PDF crashed the reader or made it exit abnormally.
pub const CRASH_MSG: &str = "Cache couldn't read this PDF; it may be damaged.";
/// Why a book fails when the reader ran out of time.
pub const TIMEOUT_MSG: &str = "Cache couldn't read this PDF in time; it may be damaged or too large.";

/// The exit status of a child that read the PDF but reports an ordinary error (its text is in the error file).
const EXIT_ERROR: i32 = 2;

const ENV_IN: &str = "CACHE_EXTRACT_IN";
const ENV_OUT: &str = "CACHE_EXTRACT_OUT";
const ENV_MEM: &str = "CACHE_EXTRACT_MEM";
/// Test-only: makes the child misbehave ("segv", "abort", "hang", "exit"). Set by the parent from [`ChildExtractor::fault`] only.
/// What the child does: unset or `extract` (read the PDF), `compress` (see [`crate::compress`]; `CACHE_EXTRACT_ARG` is the
/// [`Compression`] as JSON and the result is the outcome and the new PDF).
const ENV_JOB: &str = "CACHE_EXTRACT_JOB";
const ENV_ARG: &str = "CACHE_EXTRACT_ARG";
const ENV_FAULT: &str = "CACHE_EXTRACT_FAULT";

/// A timed-out optional compression step is different from an unreadable PDF.
enum JobOutput {
    Complete(Vec<u8>),
    TimedOut,
}

/// How to run the reading child and what it may use.
#[derive(Clone, Debug)]
pub struct ChildExtractor {
    /// The program to run (this program) and the arguments that make it call [`child_main`] (`["extract-pdf"]`).
    pub exe: PathBuf,
    pub args: Vec<OsString>,
    /// Extra environment for the child (a test harness needs to be told to act as the child).
    pub env: Vec<(OsString, OsString)>,
    /// Where the temporary files go.
    pub tmp_dir: PathBuf,
    /// Overrides [`ChildExtractor::timeout_for`].
    pub timeout: Option<Duration>,
    /// Overrides [`ChildExtractor::memory_for`], in bytes.
    pub memory: Option<u64>,
    /// Test-only fault for the child.
    pub fault: Option<String>,
}

impl ChildExtractor {
    /// This program re-run as `extract-pdf`.
    pub fn current_exe(tmp_dir: PathBuf) -> ChildExtractor {
        let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from(std::env::args().next().unwrap_or_default()));
        ChildExtractor { exe, args: vec!["extract-pdf".into()], env: vec![], tmp_dir, timeout: None, memory: None, fault: None }
    }

    /// Generous: 2 minutes plus 15 seconds per MB, at most an hour. (MuPDF reads a 5 MB PDF in a second or two.)
    pub fn timeout_for(&self, size: usize) -> Duration {
        self.timeout.unwrap_or_else(|| Duration::from_secs((120u64.saturating_add(15u64.saturating_mul(size as u64 >> 20))).min(3600)))
    }

    /// Address space for the child: 2 GiB plus 64 times the PDF's size, at most 8 GiB.
    pub fn memory_for(&self, size: usize) -> u64 {
        self.memory.unwrap_or_else(|| ((2u64 << 30).saturating_add(64u64.saturating_mul(size as u64))).min(8u64 << 30))
    }

    /// [`extract_pdf`] in a child process. An ordinary error (encrypted, cannot be opened) comes back with the same text as in-process.
    pub fn extract(&self, pdf: &[u8]) -> Result<Extracted> {
        match self.run_job("extract", "", pdf)? {
            JobOutput::Complete(bytes) => Extracted::from_wire(&bytes).map_err(|_| Error::new(CRASH_MSG)),
            JobOutput::TimedOut => Err(Error::new(TIMEOUT_MSG)),
        }
    }

    /// [`compress_pdf`] in a child process, with the same time and memory limits as reading. A timeout keeps the original PDF
    /// unchanged so ingestion can continue; extraction still has to succeed. Crashes and other child failures remain errors.
    pub fn compress(&self, pdf: &[u8], c: &Compression) -> Result<(Vec<u8>, CompressionOutcome)> {
        let arg = serde_json::to_string(c).map_err(|e| Error::ctx("compression settings", e))?;
        match self.run_job("compress", &arg, pdf)? {
            JobOutput::Complete(bytes) => decode_compressed(&bytes).ok_or_else(|| Error::new(CRASH_MSG)),
            JobOutput::TimedOut => Ok((pdf.to_vec(), crate::compress::kept_outcome(c, pdf.len(), "timed out", None))),
        }
    }

    /// Run `job` in the child on `pdf`; the bytes it wrote on success.
    fn run_job(&self, job: &str, arg: &str, pdf: &[u8]) -> Result<JobOutput> {
        static N: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
        let dir = self.tmp_dir.join(format!("extract-{}-{}-{nanos}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        std::fs::create_dir_all(&dir).map_err(|e| Error::ctx("making a work folder for reading the PDF", e))?;
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(dir.clone());
        let (input, output) = (dir.join("in.pdf"), dir.join("out.bin"));
        std::fs::write(&input, pdf).map_err(|e| Error::ctx("saving the PDF to read it", e))?;
        let mut cmd = Command::new(&self.exe);
        cmd.args(&self.args).envs(self.env.iter().map(|(k, v)| (k, v))).env(ENV_IN, &input).env(ENV_OUT, &output).env(ENV_MEM, self.memory_for(pdf.len()).to_string()).env(ENV_JOB, job).env(ENV_ARG, arg);
        match &self.fault {
            Some(f) => cmd.env(ENV_FAULT, f),
            None => cmd.env_remove(ENV_FAULT),
        };
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        let mut child = cmd.spawn().map_err(|e| Error::ctx("starting the PDF reader", e))?;
        let deadline = Instant::now() + self.timeout_for(pdf.len());
        let status = loop {
            match child.try_wait() {
                Ok(Some(s)) => break s,
                Ok(None) if Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Ok(JobOutput::TimedOut);
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(10)),
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(Error::new(CRASH_MSG));
                }
            }
        };
        if status.success() {
            return std::fs::read(&output).map(JobOutput::Complete).map_err(|_| Error::new(CRASH_MSG));
        }
        if status.code() == Some(EXIT_ERROR) {
            if let Ok(m) = std::fs::read_to_string(dir.join("out.err")) {
                if !m.trim().is_empty() {
                    return Err(Error::new(m.trim()));
                }
            }
        }
        Err(Error::new(CRASH_MSG))
    }
}

/// The hidden `extract-pdf` command: read the PDF named by the environment, write the extraction beside it, and return the exit code.
/// Nothing here may be called by anything but a parent that set the environment.
pub fn child_main() -> i32 {
    let (Some(input), Some(output)) = (std::env::var_os(ENV_IN), std::env::var_os(ENV_OUT)) else {
        eprintln!("extract-pdf is run by Cache itself, not by hand");
        return 64;
    };
    let output = PathBuf::from(output);
    #[cfg(unix)]
    {
        if let Some(bytes) = std::env::var(ENV_MEM).ok().and_then(|v| v.parse::<u64>().ok()) {
            let lim = libc::rlimit { rlim_cur: bytes as libc::rlim_t, rlim_max: bytes as libc::rlim_t };
            // SAFETY: setrlimit with a fully initialized struct.
            unsafe {
                libc::setrlimit(libc::RLIMIT_AS, &lim);
            }
        }
    }
    if let Ok(f) = std::env::var(ENV_FAULT) {
        match f.as_str() {
            #[cfg(unix)]
            // SAFETY: raising a signal on ourselves; this is the crash being imitated.
            "segv" => unsafe {
                libc::signal(libc::SIGSEGV, libc::SIG_DFL);
                libc::raise(libc::SIGSEGV);
            },
            "abort" => std::process::abort(),
            "hang" => loop {
                std::thread::sleep(Duration::from_secs(3600));
            },
            "exit" => return 1,
            _ => {}
        }
    }
    let job = std::env::var(ENV_JOB).unwrap_or_default();
    let result = std::fs::read(&input).map_err(|e| Error::ctx("reading the PDF", e)).and_then(|b| match job.as_str() {
        "compress" => {
            let c: Compression = std::env::var(ENV_ARG).ok().and_then(|a| serde_json::from_str(&a).ok()).ok_or_else(|| Error::new("compression settings missing"))?;
            let (pdf, outcome) = compress_pdf(&b, &c);
            Ok(encode_compressed(&pdf, &outcome))
        }
        _ => extract_pdf(&b).map(|e| e.to_wire()),
    });
    match result {
        Ok(ext) => {
            let tmp = output.with_extension("tmp");
            if std::fs::write(&tmp, ext).and_then(|_| std::fs::rename(&tmp, &output)).is_err() {
                return 1;
            }
            0
        }
        Err(e) => {
            let _ = std::fs::write(output.with_file_name("out.err"), e.0);
            EXIT_ERROR
        }
    }
}

/// The child's answer to a compress job: the outcome as JSON (length first, 4 bytes little-endian), then the PDF.
fn encode_compressed(pdf: &[u8], o: &CompressionOutcome) -> Vec<u8> {
    let j = serde_json::to_vec(o).unwrap_or_default();
    let mut out = Vec::with_capacity(4 + j.len() + pdf.len());
    out.extend_from_slice(&(j.len() as u32).to_le_bytes());
    out.extend_from_slice(&j);
    out.extend_from_slice(pdf);
    out
}

fn decode_compressed(b: &[u8]) -> Option<(Vec<u8>, CompressionOutcome)> {
    let n = u32::from_le_bytes(b.get(..4)?.try_into().ok()?) as usize;
    let outcome: CompressionOutcome = serde_json::from_slice(b.get(4..4 + n)?).ok()?;
    Some((b[4 + n..].to_vec(), outcome))
}
