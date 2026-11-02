//! Upstream work for the tile server, kept apart from the threads that answer the map.
//!
//! The server's worker threads answer everything that local storage can answer at once. A request that needs the
//! source is handed to the lane of its layer: at most the layer's `max_parallel` fetches run at a time (each on its
//! own short-lived thread), the rest wait in a short queue, newest first (the map has moved on from old requests),
//! and a request that waited longer than the upstream timeout is answered as a miss. Several requests for the same
//! tile share one fetch. A slow layer can therefore fill only its own lane: the worker threads and every other
//! layer carry on.

use crate::core::{Inner, TileOut};
use crate::error::Error;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// What a request is answered with (cloned for every request that shared the fetch).
#[derive(Clone)]
pub enum Outcome {
    Tile(TileOut),
    Json(Value),
    Err(Error),
}

pub type Reply = Box<dyn FnOnce(Outcome) + Send>;

/// `z` is `TILEJSON` for a TileJSON document.
pub type Key = (String, u8, u32, u32);
pub const TILEJSON: u8 = 255;

/// Requests waiting in a lane beyond the ones running; the oldest are answered as misses past this.
const MAX_QUEUE: usize = 64;

#[derive(Default)]
struct Lane {
    running: usize,
    queue: VecDeque<(Key, Instant)>,
}

#[derive(Default)]
struct State {
    lanes: HashMap<String, Lane>,
    /// Every request waiting for a fetch that is queued or running, by what it asks for.
    waiting: HashMap<Key, Vec<Reply>>,
}

pub struct Sched {
    inner: Arc<Inner>,
    base_url: String,
    state: Mutex<State>,
}

impl Sched {
    pub fn new(inner: Arc<Inner>, base_url: String) -> Arc<Sched> {
        Arc::new(Sched { inner, base_url, state: Mutex::new(State::default()) })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Queue a fetch (or join the one already queued or running for `key`); `reply` is called once, from another thread.
    pub fn submit(self: &Arc<Self>, key: Key, cap: usize, reply: Reply) {
        let mut dropped: Vec<Reply> = Vec::new();
        let mut spawn: Option<String> = None;
        {
            let mut st = self.lock();
            if let Some(w) = st.waiting.get_mut(&key) {
                w.push(reply);
                return;
            }
            st.waiting.insert(key.clone(), vec![reply]);
            let lane_name = key.0.clone();
            let lane = st.lanes.entry(lane_name.clone()).or_default();
            lane.queue.push_back((key, Instant::now()));
            if lane.running < cap.max(1) {
                lane.running += 1;
                spawn = Some(lane_name);
            } else if lane.queue.len() > MAX_QUEUE {
                if let Some((old, _)) = lane.queue.pop_front() {
                    dropped = st.waiting.remove(&old).unwrap_or_default();
                }
            }
        }
        for r in dropped {
            r(Outcome::Tile(TileOut::Miss));
        }
        if let Some(name) = spawn {
            let me = self.clone();
            let n2 = name.clone();
            if std::thread::Builder::new().name("cs-upstream".into()).spawn(move || me.work(&n2)).is_err() {
                // no thread to be had: answer what is queued in this lane as a miss rather than leave it hanging
                self.give_up(&name);
            }
        }
    }

    fn give_up(&self, lane: &str) {
        let mut all: Vec<Reply> = Vec::new();
        {
            let mut st = self.lock();
            let keys: Vec<Key> = match st.lanes.get_mut(lane) {
                Some(l) => {
                    l.running = l.running.saturating_sub(1);
                    l.queue.drain(..).map(|(k, _)| k).collect()
                }
                None => Vec::new(),
            };
            for k in keys {
                all.extend(st.waiting.remove(&k).unwrap_or_default());
            }
        }
        for r in all {
            r(Outcome::Tile(TileOut::Miss));
        }
    }

    /// One worker of a lane: takes the newest queued job until the lane's queue is empty.
    fn work(&self, lane: &str) {
        loop {
            let next = {
                let mut st = self.lock();
                let l = st.lanes.entry(lane.to_string()).or_default();
                let j = l.queue.pop_back();
                if j.is_none() {
                    l.running = l.running.saturating_sub(1);
                }
                j
            };
            let Some((key, queued_at)) = next else { return };
            let outcome = if queued_at.elapsed() > crate::http::upstream_timeout() {
                // the map stopped waiting long ago
                Outcome::Tile(TileOut::Miss)
            } else {
                self.run(&key)
            };
            let replies = self.lock().waiting.remove(&key).unwrap_or_default();
            for r in replies {
                r(outcome.clone());
            }
        }
    }

    fn run(&self, key: &Key) -> Outcome {
        let (id, z, x, y) = (key.0.as_str(), key.1, key.2, key.3);
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if z == TILEJSON {
                self.inner.tilejson_upstream(id, &self.base_url).map(Outcome::Json)
            } else {
                self.inner.tile_upstream(id, z, x, y).map(Outcome::Tile)
            }
        }));
        match r {
            Ok(Ok(o)) => o,
            Ok(Err(e)) => Outcome::Err(e),
            Err(_) => Outcome::Err(Error::internal("the tile fetch panicked")),
        }
    }
}
