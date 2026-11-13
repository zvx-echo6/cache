//! A small bounded pool for the independent file opens of `Handle::set_sources`: the ZIMs of a config are opened side by
//! side (a phone holds dozens, and each open reads the header, the metadata and the two index entries), the results come
//! back in the order of the items, and nothing shared is touched until every open has finished.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

/// The most threads that open at once.
pub const OPEN_THREADS_MAX: usize = 4;

/// min(cores, `OPEN_THREADS_MAX`), at least 1. `CS_OPEN_THREADS` (a number) overrides it for measuring: 1 is the serial open.
pub fn default_threads() -> usize {
    if let Some(n) = std::env::var("CS_OPEN_THREADS").ok().and_then(|v| v.trim().parse::<usize>().ok()) {
        return n.clamp(1, OPEN_THREADS_MAX);
    }
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, OPEN_THREADS_MAX)
}

/// Run `f` on every item with up to `threads` threads (never more than `OPEN_THREADS_MAX` or the number of items; the
/// calling thread is one of them) and return the results in the order of `items`. With one thread (or one item) nothing is
/// spawned and the items run in order on the calling thread.
pub fn run_pool<I: Sync, T: Send, F: Fn(&I) -> T + Sync>(items: &[I], threads: usize, f: F) -> Vec<T> {
    let n = items.len();
    let workers = threads.clamp(1, OPEN_THREADS_MAX).min(n);
    if workers <= 1 {
        return items.iter().map(&f).collect();
    }
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<T>>> = Mutex::new((0..n).map(|_| None).collect());
    let work = || loop {
        let i = next.fetch_add(1, Ordering::SeqCst);
        if i >= n {
            break;
        }
        let v = f(&items[i]);
        out.lock().unwrap_or_else(|e| e.into_inner())[i] = Some(v);
    };
    std::thread::scope(|s| {
        for k in 1..workers {
            // a thread that cannot start just leaves its share to the others (the calling thread takes items too)
            let _ = std::thread::Builder::new().name(format!("cs-open-zim-{k}")).spawn_scoped(s, &work);
        }
        work();
    });
    out.into_inner().unwrap_or_else(|e| e.into_inner()).into_iter().map(|v| v.expect("every item ran")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    #[test]
    fn results_keep_the_order_of_the_items() {
        let items: Vec<u32> = (0..40).collect();
        let out = run_pool(&items, 4, |i| {
            // later items finish first
            std::thread::sleep(Duration::from_millis(u64::from(40 - *i) / 4));
            i * 2
        });
        assert_eq!(out, (0..40).map(|i| i * 2).collect::<Vec<u32>>());
    }

    #[test]
    fn runs_concurrently_and_stays_bounded() {
        let items: Vec<u32> = (0..16).collect();
        let (now, peak) = (AtomicUsize::new(0), AtomicUsize::new(0));
        run_pool(&items, 64, |_| {
            let c = now.fetch_add(1, Ordering::SeqCst) + 1;
            peak.fetch_max(c, Ordering::SeqCst);
            std::thread::sleep(Duration::from_millis(30));
            now.fetch_sub(1, Ordering::SeqCst);
        });
        let p = peak.load(Ordering::SeqCst);
        assert!(p >= 2, "opens never overlapped (peak {p})");
        assert!(p <= OPEN_THREADS_MAX, "more than {OPEN_THREADS_MAX} at once (peak {p})");
    }

    #[test]
    fn one_thread_runs_in_order_on_the_caller() {
        let me = std::thread::current().id();
        let seen = Mutex::new(Vec::new());
        let items: Vec<u32> = (0..5).collect();
        run_pool(&items, 1, |i| {
            assert_eq!(std::thread::current().id(), me);
            seen.lock().unwrap().push(*i);
        });
        assert_eq!(*seen.lock().unwrap(), vec![0, 1, 2, 3, 4]);
        assert!(run_pool::<u32, u32, _>(&[], 4, |i| *i).is_empty());
    }
}
