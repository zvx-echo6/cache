//! Permission for outbound IP work, separate from whether another carrier can sync. Epochs cancel work even if a denial
//! is quickly followed by permission again before its task is polled.

use std::future::Future;
use anyhow::{anyhow, Result};
use n0_future::StreamExt;
use tokio::sync::watch;
use crate::transport::{BoxStream, FetchEvent};

const PAUSED: &str = "Paused: no network permitted for IP transfers";

#[derive(Clone, Copy)]
struct State { allowed: bool, epoch: u64 }

pub(crate) struct IpPolicy { state: watch::Sender<State> }

impl Default for IpPolicy {
    fn default() -> Self {
        let (state, _) = watch::channel(State { allowed: true, epoch: 0 });
        Self { state }
    }
}

impl IpPolicy {
    pub fn allowed(&self) -> bool { self.state.borrow().allowed }

    pub fn set(&self, allowed: bool) {
        self.state.send_modify(|s| {
            if s.allowed != allowed {
                s.allowed = allowed;
                s.epoch = s.epoch.wrapping_add(1);
            }
        });
    }

    fn current(rx: &watch::Receiver<State>, epoch: u64) -> bool {
        let state = rx.borrow();
        state.allowed && state.epoch == epoch
    }

    pub async fn run<T>(&self, work: impl Future<Output = Result<T>>) -> Result<T> {
        let mut changes = self.state.subscribe();
        let epoch = changes.borrow().epoch;
        tokio::pin!(work);
        loop {
            if !Self::current(&changes, epoch) { return Err(anyhow!(PAUSED)); }
            tokio::select! {
                biased;
                change = changes.changed() => if change.is_err() { return Err(anyhow!(PAUSED)); },
                result = &mut work => return if Self::current(&changes, epoch) { result } else { Err(anyhow!(PAUSED)) },
            }
        }
    }

    pub fn stream(&self, stream: BoxStream<FetchEvent>) -> BoxStream<FetchEvent> {
        let changes = self.state.subscribe();
        let epoch = changes.borrow().epoch;
        Box::pin(n0_future::stream::unfold((Some(stream), changes, false), move |(mut stream, mut changes, done)| async move {
            if done { return None; }
            loop {
                if !Self::current(&changes, epoch) {
                    drop(stream.take());
                    return Some((FetchEvent::Failed(PAUSED.into()), (stream, changes, true)));
                }
                let source = stream.as_mut()?;
                tokio::select! {
                    biased;
                    change = changes.changed() => if change.is_err() { return None; },
                    event = source.next() => {
                        if Self::current(&changes, epoch) {
                            return event.map(|event| (event, (stream, changes, false)));
                        }
                    }
                }
            }
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn denied_ip_work_is_never_polled() {
        let policy = IpPolicy::default();
        policy.set(false);
        let result: Result<()> = policy.run(async { panic!("IP work must not start") }).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn a_transient_denial_cancels_inflight_work_even_after_reenable() {
        let policy = IpPolicy::default();
        let work = policy.run(std::future::pending::<Result<()>>());
        tokio::pin!(work);
        assert!(std::future::poll_fn(|cx| std::task::Poll::Ready(work.as_mut().poll(cx).is_pending())).await);
        policy.set(false);
        policy.set(true);
        assert!(work.await.is_err());
        assert_eq!(policy.run(async { Ok(7) }).await.unwrap(), 7);
    }

    #[tokio::test]
    async fn a_waiting_download_wakes_and_stops_when_ip_is_denied() {
        use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
        struct PendingDownload(Arc<AtomicBool>);
        impl n0_future::Stream for PendingDownload {
            type Item = FetchEvent;
            fn poll_next(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>) -> std::task::Poll<Option<Self::Item>> {
                std::task::Poll::Pending
            }
        }
        impl Drop for PendingDownload {
            fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); }
        }
        let policy = IpPolicy::default();
        let cancelled = Arc::new(AtomicBool::new(false));
        let mut stream = policy.stream(Box::pin(PendingDownload(cancelled.clone())));
        let mut next = Box::pin(stream.next());
        assert!(std::future::poll_fn(|cx| std::task::Poll::Ready(next.as_mut().poll(cx).is_pending())).await);
        policy.set(false);
        assert!(matches!(next.await, Some(FetchEvent::Failed(_))));
        assert!(cancelled.load(Ordering::SeqCst), "the download is cancelled before the paused event is returned");
        assert!(stream.next().await.is_none());
    }
}
