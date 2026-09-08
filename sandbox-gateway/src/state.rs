use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use bollard::Docker;

use crate::config::Config;
use crate::models::ExecLogEntry;
use crate::runtime::computer::Registry;

#[derive(Debug, Clone)]
pub struct SandboxEntry {
    pub owner_key: String,
    pub created_at: i64,
    pub last_used_at: i64,
    pub ttl_seconds: Option<u64>,
}

/// Ring size per sandbox.
const EXEC_LOG_CAP: usize = 60;

pub struct AppState {
    pub cfg: Config,
    pub docker: Docker,
    pub sandboxes: Mutex<HashMap<String, SandboxEntry>>,
    pub computer: Registry,
    exec_log: Mutex<HashMap<String, VecDeque<ExecLogEntry>>>,
    exec_seq: AtomicU64,
}

impl AppState {
    pub fn new(cfg: Config, docker: Docker) -> Self {
        Self {
            cfg,
            docker,
            sandboxes: Mutex::new(HashMap::new()),
            computer: Registry::new(),
            exec_log: Mutex::new(HashMap::new()),
            exec_seq: AtomicU64::new(0),
        }
    }

    pub fn touch(&self, id: &str, now: i64) {
        if let Some(entry) = self.sandboxes.lock().unwrap().get_mut(id) {
            entry.last_used_at = now;
        }
    }

    pub fn upsert(&self, id: &str, entry: SandboxEntry) {
        self.sandboxes.lock().unwrap().insert(id.to_string(), entry);
    }

    pub fn remove(&self, id: &str) {
        self.sandboxes.lock().unwrap().remove(id);
        self.exec_log.lock().unwrap().remove(id);
    }

    pub fn get(&self, id: &str) -> Option<SandboxEntry> {
        self.sandboxes.lock().unwrap().get(id).cloned()
    }

    pub fn len(&self) -> usize {
        self.sandboxes.lock().unwrap().len()
    }

    pub fn record_exec(&self, id: &str, mut entry: ExecLogEntry) -> u64 {
        let seq = self.exec_seq.fetch_add(1, Ordering::Relaxed) + 1;
        entry.seq = seq;
        let mut log = self.exec_log.lock().unwrap();
        let ring = log.entry(id.to_string()).or_default();
        if ring.len() >= EXEC_LOG_CAP {
            ring.pop_front();
        }
        ring.push_back(entry);
        seq
    }

    pub fn exec_log(&self, id: &str, since: u64, limit: usize) -> Vec<ExecLogEntry> {
        let log = self.exec_log.lock().unwrap();
        let Some(ring) = log.get(id) else {
            return Vec::new();
        };
        let newer: Vec<ExecLogEntry> = ring.iter().filter(|e| e.seq > since).cloned().collect();
        let start = newer.len().saturating_sub(limit.max(1));
        newer[start..].to_vec()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.sandboxes.lock().unwrap().contains_key(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry() -> SandboxEntry {
        SandboxEntry {
            owner_key: "agent:1".into(),
            created_at: 1,
            last_used_at: 1,
            ttl_seconds: None,
        }
    }

    #[test]
    fn upsert_get_remove_roundtrip() {
        let cfg = crate::config::test_config();
        let docker = Docker::connect_with_http_defaults().unwrap();
        let state = AppState::new(cfg, docker);
        assert_eq!(state.len(), 0);
        state.upsert("vibe-sb-abc", entry());
        assert_eq!(state.len(), 1);
        assert!(state.contains("vibe-sb-abc"));
        state.touch("vibe-sb-abc", 42);
        assert_eq!(state.get("vibe-sb-abc").unwrap().last_used_at, 42);
        state.remove("vibe-sb-abc");
        assert!(state.get("vibe-sb-abc").is_none());
    }
}
