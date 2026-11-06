//! Compact device-local state for background linked-folder checks.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs, io,
    path::Path,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CheckJob {
    pub job_id: String,
    pub state: String,
    pub stage: Option<String>,
    pub scope: Scope,
    pub started_at: u64,
    pub finished_at: Option<u64>,
    pub last_attempt_at: u64,
    pub last_successful_at: Option<u64>,
    pub paused_for_future: bool,
    pub counts: Counts,
    pub roots: Vec<Value>,
    pub error: Option<Value>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Scope {
    pub root_id: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Counts {
    pub roots_seen: Option<usize>,
    pub files_seen: Option<usize>,
    pub files_hashed: Option<usize>,
    pub matched_unique_ids: Option<usize>,
    pub matched_locations: Option<usize>,
    pub unmatched_identity: Option<usize>,
    pub settling_file_count: Option<usize>,
    pub errors: Option<usize>,
    pub bytes_hashed: Option<u64>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct JobFile {
    pub active: Option<CheckJob>,
    pub latest: Option<CheckJob>,
    #[serde(default)]
    pub controls: BTreeMap<String, bool>,
    #[serde(default)]
    pub registered_roots: BTreeSet<String>,
    #[serde(default)]
    pub state_error: Option<Value>,
}

pub fn recover_interrupted(file: &mut JobFile, at: u64) -> bool {
    if let Some(mut job) = file.active.take() {
        job.state = "interrupted".into();
        job.stage = None;
        job.finished_at = Some(at);
        job.error = Some(serde_json::json!({
            "code": "interrupted",
            "message": "check was interrupted by restart"
        }));
        file.latest = Some(job);
        true
    } else {
        false
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScopeConflict;

pub fn attach_or_conflict(file: &JobFile, scope: &Scope) -> Result<Option<CheckJob>, ScopeConflict> {
    match &file.active {
        Some(job) if job.scope == *scope => Ok(Some(job.clone())),
        Some(_) => Err(ScopeConflict),
        None => Ok(None),
    }
}

pub fn update_control(file: &mut JobFile, root_id: &str, paused: bool) -> bool {
    if !file.registered_roots.contains(root_id) {
        return false;
    }
    file.controls.insert(root_id.to_string(), paused);
    let future = if file.active.as_ref().and_then(|job| job.scope.root_id.as_deref()) == Some(root_id) {
        paused
    } else {
        file.active.as_ref().and_then(|job| job.scope.root_id.as_ref())
            .map(|id| file.controls.get(id).copied().unwrap_or(false))
            .unwrap_or_else(|| file.controls.values().any(|value| *value))
    };
    if let Some(job) = file.active.as_mut() {
        job.paused_for_future = future;
    }
    true
}

pub fn update_control_during_active(file: &mut JobFile, root_id: &str, paused: bool) -> bool {
    if file.active.is_none() {
        return false;
    }
    update_control(file, root_id, paused)
}

pub fn unlink_controls(file: &mut JobFile, root_id: &str, last_root: bool) {
    file.controls.remove(root_id);
    file.registered_roots.remove(root_id);
    file.latest = None;
    if last_root {
        file.controls.clear();
    }
}

pub fn load(path: &Path) -> io::Result<JobFile> {
    if !path.exists() {
        return Ok(JobFile::default());
    }
    serde_json::from_slice(&fs::read(path)?).map_err(io::Error::other)
}

pub fn save(path: &Path, value: &JobFile) -> io::Result<()> {
    let bytes = serde_json::to_vec(value).map_err(io::Error::other)?;
    crate::write_private(path, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(scope: Option<&str>) -> CheckJob {
        CheckJob {
            job_id: "job-1".into(),
            state: "running".into(),
            stage: Some("checking".into()),
            scope: Scope { root_id: scope.map(str::to_owned) },
            started_at: 1,
            finished_at: None,
            last_attempt_at: 1,
            last_successful_at: None,
            paused_for_future: false,
            counts: Counts::default(),
            roots: vec![],
            error: None,
        }
    }

    #[test]
    fn compact_state_roundtrips_without_paths_or_books() {
        let state = serde_json::to_string(&job(None)).unwrap();
        assert!(state.contains("checking"));
        assert!(!state.contains("books"));
        assert!(!state.contains("/home/"));
        let restored: CheckJob = serde_json::from_str(&state).unwrap();
        assert_eq!(restored.job_id, "job-1");
    }

    #[test]
    fn duplicate_scope_attaches_but_conflicting_scope_rejects() {
        let file = JobFile { active: Some(job(Some("a"))), ..JobFile::default() };
        assert_eq!(attach_or_conflict(&file, &Scope { root_id: Some("a".into()) })
            .unwrap().unwrap().job_id, "job-1");
        assert!(attach_or_conflict(&file, &Scope { root_id: Some("b".into()) }).is_err());
    }

    #[test]
    fn interrupted_job_preserves_last_success_and_persists() {
        let mut active = job(None);
        active.last_successful_at = Some(42);
        let mut file = JobFile { active: Some(active), ..JobFile::default() };
        assert!(recover_interrupted(&mut file, 99));
        let restored: JobFile = serde_json::from_slice(&serde_json::to_vec(&file).unwrap()).unwrap();
        assert_eq!(restored.latest.as_ref().unwrap().state, "interrupted");
        assert_eq!(restored.latest.as_ref().unwrap().last_successful_at, Some(42));
        assert!(restored.active.is_none());
    }

    #[test]
    fn unlink_clears_control_and_finished_reference() {
        let mut file = JobFile { latest: Some(job(None)), ..JobFile::default() };
        file.controls.insert("root-a".into(), true);
        unlink_controls(&mut file, "root-a", true);
        assert!(file.latest.is_none());
        assert!(file.controls.is_empty());
    }

    #[test]
    fn status_and_future_pause_update_while_hash_progress_is_blocked() {
        use std::{
            sync::{atomic::{AtomicBool, Ordering}, Arc, Barrier, Mutex},
            thread,
            time::{SystemTime, UNIX_EPOCH},
        };
        let root = std::env::temp_dir().join(format!("linked-progress-{}-{}", std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir_all(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let original = vec![7u8; 2 * 1024 * 1024];
        fs::write(root.join("one.pdf"), &original).unwrap();
        let status = Arc::new(Mutex::new(JobFile {
            active: Some(job(Some("root-a"))),
            registered_roots: ["root-a".to_string()].into_iter().collect(),
            ..JobFile::default()
        }));
        let barrier = Arc::new(Barrier::new(2));
        let gate = Arc::new(AtomicBool::new(true));
        let worker_status = status.clone();
        let worker_barrier = barrier.clone();
        let worker_gate = gate.clone();
        let worker_root = root.clone();
        let worker = thread::spawn(move || super::super::linked_source::scan_linked_root_with_progress(
            &worker_root, &[], &Default::default(), 1, 0, |seen, hashed, bytes, settling, _| {
                let mut state = worker_status.lock().unwrap();
                let active = state.active.as_mut().unwrap();
                active.counts.files_seen = Some(seen);
                active.counts.files_hashed = Some(hashed);
                active.counts.bytes_hashed = Some(bytes);
                active.counts.settling_file_count = Some(settling);
                drop(state);
                if worker_gate.swap(false, Ordering::SeqCst) {
                    worker_barrier.wait();
                    worker_barrier.wait();
                }
            },
        ));
        barrier.wait();
        {
            let mut state = status.lock().unwrap();
            let active = state.active.as_ref().unwrap();
            assert_eq!(active.counts.files_seen, Some(1));
            assert_eq!(active.counts.files_hashed, Some(1));
            assert!(active.counts.bytes_hashed.unwrap() > 0);
            assert!(update_control(&mut state, "root-a", true));
            assert!(state.active.as_ref().unwrap().paused_for_future);
        }
        barrier.wait();
        let result = worker.join().unwrap();
        assert_eq!(result.candidates.len(), 1);
        assert_eq!(fs::read(root.join("one.pdf")).unwrap(), original);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn control_cannot_resurrect_an_unlinked_root() {
        let mut file = JobFile::default();
        file.registered_roots.insert("r".into());
        unlink_controls(&mut file, "r", true);
        assert!(!update_control(&mut file, "r", true));
        assert!(file.controls.is_empty());
    }

    #[test]
    fn terminal_publication_gap_rejects_control_without_mutation() {
        let mut state = JobFile::default();
        state.registered_roots.insert("r".into());
        assert!(!update_control_during_active(&mut state, "r", true));
        assert!(!state.controls.contains_key("r"));
    }

    #[test]
    fn pausing_another_root_does_not_change_scoped_jobs_pause_display() {
        let mut file = JobFile {
            active: Some(job(Some("a"))),
            registered_roots: ["a".to_string(), "b".to_string()].into_iter().collect(),
            ..JobFile::default()
        };
        assert!(update_control(&mut file, "b", true));
        assert!(!file.active.as_ref().unwrap().paused_for_future);
        assert!(update_control(&mut file, "a", true));
        assert!(file.active.as_ref().unwrap().paused_for_future);
    }

    #[test]
    fn unlink_and_pause_are_serialized_without_resurrecting_control() {
        use std::{sync::{Arc, Barrier, Mutex}, thread};
        let operation = Arc::new(Mutex::new(()));
        let state = Arc::new(Mutex::new(JobFile::default()));
        state.lock().unwrap().registered_roots.insert("r".into());
        let barrier = Arc::new(Barrier::new(2));
        let op = operation.clone();
        let st = state.clone();
        let gate = barrier.clone();
        let unlink = thread::spawn(move || {
            let _guard = op.lock().unwrap();
            gate.wait();
            unlink_controls(&mut st.lock().unwrap(), "r", true);
        });
        let op = operation.clone();
        let st = state.clone();
        let gate = barrier.clone();
        let pause = thread::spawn(move || {
            gate.wait();
            if let Ok(_guard) = op.try_lock() {
                let _ = update_control(&mut st.lock().unwrap(), "r", true);
            } else {
                let _ = update_control_during_active(&mut st.lock().unwrap(), "r", true);
            }
        });
        unlink.join().unwrap();
        pause.join().unwrap();
        let state = state.lock().unwrap();
        assert!(!state.registered_roots.contains("r"));
        assert!(!state.controls.contains_key("r"));
    }
}
