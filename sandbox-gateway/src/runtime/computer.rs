//! Per-sandbox computer sessions.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use sha2::{Digest, Sha256};
use tokio::sync::Mutex as AsyncMutex;

use crate::config::Config;
use crate::error::GatewayError;
use crate::models::{
    ComputerControlResponse, ComputerFrameResponse, ComputerInputRequest, ComputerInputResponse,
    ComputerSessionRequest, ComputerSessionResponse, ComputerStateResponse, Control,
};
use crate::runtime::browser;
use crate::state::AppState;

use super::{now_ms, now_unix};

const MIN_FPS: u32 = 1;
const MAX_FPS: u32 = 8;
const MIN_WIDTH: u32 = 160;
const MAX_WIDTH: u32 = 900;
const MIN_QUALITY: u32 = 10;
const MAX_QUALITY: u32 = 70;
const DEFAULT_CONTROL_TTL_SECONDS: u64 = 300;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ComputerError {
    #[error("computer_capacity")]
    Capacity,
    #[error("session_not_found")]
    SessionNotFound,
    #[error("control_not_held")]
    ControlNotHeld,
    #[error("unknown control action: {0}")]
    UnknownAction(String),
}

impl From<ComputerError> for GatewayError {
    fn from(err: ComputerError) -> Self {
        match err {
            ComputerError::Capacity => GatewayError::TooManyRequests(err.to_string()),
            ComputerError::ControlNotHeld => GatewayError::Conflict(err.to_string()),
            other => GatewayError::BadRequest(other.to_string()),
        }
    }
}

pub fn clamp_fps(v: u32) -> u32 {
    v.clamp(MIN_FPS, MAX_FPS)
}

pub fn clamp_width(v: u32) -> u32 {
    v.clamp(MIN_WIDTH, MAX_WIDTH)
}

pub fn clamp_quality(v: u32) -> u32 {
    v.clamp(MIN_QUALITY, MAX_QUALITY)
}

#[derive(Debug, Clone)]
pub struct Session {
    pub viewer_id: String,
    pub created_at: i64,
    pub last_seen: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub seq: u64,
    pub jpeg_base64: String,
    pub mime: String,
    pub width: u32,
    pub height: u32,
    pub url: String,
    pub title: String,
    pub loading: bool,
    pub captured_at: i64,
}

/// A capture's payload before it is given a sequence number.
#[derive(Debug, Clone, Default)]
pub struct CapturedFrame {
    pub jpeg_base64: String,
    pub mime: String,
    pub width: u32,
    pub height: u32,
    pub url: String,
    pub title: String,
    pub loading: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameDecision {
    NotModified,
    Serve(Box<Frame>),
    Capture { width: u32, quality: u32 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlView {
    pub control: Control,
    pub holder: Option<String>,
    pub expires_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionView {
    pub session_id: String,
    pub fps: u32,
    pub width: u32,
    pub quality: u32,
    pub control: ControlView,
    pub expires_at: i64,
}

/// What a viewer asks for when it opens a session.
#[derive(Debug, Clone, Default)]
pub struct SessionOpts {
    pub viewer_id: String,
    pub fps: Option<u32>,
    pub width: Option<u32>,
    pub quality: Option<u32>,
}

#[derive(Debug)]
struct Entry {
    sessions: HashMap<String, Session>,
    seq: u64,
    frame: Option<Frame>,
    control: Control,
    holder: Option<String>,
    control_expires_at: Option<i64>,
    fps: u32,
    width: u32,
    quality: u32,
}

impl Entry {
    fn new(cfg: &Config) -> Self {
        Self {
            sessions: HashMap::new(),
            seq: 0,
            frame: None,
            control: Control::Agent,
            holder: None,
            control_expires_at: None,
            fps: clamp_fps(cfg.computer_default_fps),
            width: clamp_width(cfg.computer_default_width),
            quality: clamp_quality(cfg.computer_default_quality),
        }
    }

    fn give_back_to_agent(&mut self) {
        self.control = Control::Agent;
        self.holder = None;
        self.control_expires_at = None;
    }

    fn settle(&mut self, now: i64) {
        let expired = self.control_expires_at.map(|at| now >= at).unwrap_or(false);
        let orphaned = self
            .holder
            .as_ref()
            .map(|h| !self.sessions.contains_key(h))
            .unwrap_or(false);
        if self.control == Control::User && (expired || orphaned) {
            self.give_back_to_agent();
        }
    }

    fn view(&self) -> ControlView {
        ControlView {
            control: self.control,
            holder: self.holder.clone(),
            expires_at: self.control_expires_at,
        }
    }
}

#[derive(Default)]
pub struct Registry {
    entries: Mutex<HashMap<String, Entry>>,
    locks: Mutex<HashMap<String, Arc<AsyncMutex<()>>>>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open_session(
        &self,
        cfg: &Config,
        sandbox: &str,
        opts: &SessionOpts,
        now: i64,
    ) -> Result<SessionView, ComputerError> {
        let mut entries = self.entries.lock().unwrap();
        Self::sweep_locked(cfg, &mut entries, now);

        let already_live = entries
            .get(sandbox)
            .map(|e| !e.sessions.is_empty())
            .unwrap_or(false);
        let live = entries.values().filter(|e| !e.sessions.is_empty()).count();
        if !already_live && live >= cfg.computer_max_live {
            return Err(ComputerError::Capacity);
        }

        let entry = entries
            .entry(sandbox.to_string())
            .or_insert_with(|| Entry::new(cfg));
        if entry.sessions.is_empty() {
            entry.fps = clamp_fps(opts.fps.unwrap_or(cfg.computer_default_fps));
            entry.width = clamp_width(opts.width.unwrap_or(cfg.computer_default_width));
            entry.quality = clamp_quality(opts.quality.unwrap_or(cfg.computer_default_quality));
        }

        let session_id = new_session_id();
        entry.sessions.insert(
            session_id.clone(),
            Session {
                viewer_id: opts.viewer_id.clone(),
                created_at: now,
                last_seen: now,
            },
        );
        entry.settle(now);

        Ok(SessionView {
            session_id,
            fps: entry.fps,
            width: entry.width,
            quality: entry.quality,
            control: entry.view(),
            expires_at: now + cfg.computer_session_max_seconds as i64,
        })
    }

    pub fn close_session(&self, sandbox: &str, session_id: &str, now: i64) {
        let mut entries = self.entries.lock().unwrap();
        let Some(entry) = entries.get_mut(sandbox) else {
            return;
        };
        entry.sessions.remove(session_id);
        entry.settle(now);
        if entry.sessions.is_empty() {
            entries.remove(sandbox);
        }
    }

    pub fn touch(&self, sandbox: &str, session_id: Option<&str>, now: i64) {
        let mut entries = self.entries.lock().unwrap();
        let Some(entry) = entries.get_mut(sandbox) else {
            return;
        };
        match session_id {
            Some(sid) => {
                if let Some(s) = entry.sessions.get_mut(sid) {
                    s.last_seen = now;
                }
            }
            None => entry.sessions.values_mut().for_each(|s| s.last_seen = now),
        }
    }

    pub fn control(&self, sandbox: &str, now: i64) -> ControlView {
        let mut entries = self.entries.lock().unwrap();
        match entries.get_mut(sandbox) {
            Some(entry) => {
                entry.settle(now);
                entry.view()
            }
            None => ControlView {
                control: Control::Agent,
                holder: None,
                expires_at: None,
            },
        }
    }

    pub fn grant(
        &self,
        cfg: &Config,
        sandbox: &str,
        session_id: &str,
        ttl_seconds: Option<u64>,
        now: i64,
    ) -> Result<ControlView, ComputerError> {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries
            .get_mut(sandbox)
            .ok_or(ComputerError::SessionNotFound)?;
        let session = entry
            .sessions
            .get_mut(session_id)
            .ok_or(ComputerError::SessionNotFound)?;
        session.last_seen = now;

        let ttl = ttl_seconds
            .unwrap_or(DEFAULT_CONTROL_TTL_SECONDS)
            .clamp(1, cfg.computer_session_max_seconds.max(1));
        entry.control = Control::User;
        entry.holder = Some(session_id.to_string());
        entry.control_expires_at = Some(now + ttl as i64);
        Ok(entry.view())
    }

    pub fn release(
        &self,
        sandbox: &str,
        session_id: &str,
        now: i64,
    ) -> Result<ControlView, ComputerError> {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries
            .get_mut(sandbox)
            .ok_or(ComputerError::SessionNotFound)?;
        if !entry.sessions.contains_key(session_id) {
            return Err(ComputerError::SessionNotFound);
        }
        if entry.holder.as_deref() == Some(session_id) {
            entry.give_back_to_agent();
        }
        entry.settle(now);
        Ok(entry.view())
    }

    pub fn authorize_input(
        &self,
        sandbox: &str,
        session_id: &str,
        now: i64,
    ) -> Result<(), ComputerError> {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries
            .get_mut(sandbox)
            .ok_or(ComputerError::ControlNotHeld)?;
        entry.settle(now);
        if entry.control != Control::User || entry.holder.as_deref() != Some(session_id) {
            return Err(ComputerError::ControlNotHeld);
        }
        if let Some(s) = entry.sessions.get_mut(session_id) {
            s.last_seen = now;
        }
        Ok(())
    }

    pub fn decide_frame(
        &self,
        cfg: &Config,
        sandbox: &str,
        since: u64,
        now_ms: i64,
    ) -> FrameDecision {
        let entries = self.entries.lock().unwrap();
        let (fps, width, quality, frame) = match entries.get(sandbox) {
            Some(e) => (e.fps, e.width, e.quality, e.frame.clone()),
            None => (
                clamp_fps(cfg.computer_default_fps),
                clamp_width(cfg.computer_default_width),
                clamp_quality(cfg.computer_default_quality),
                None,
            ),
        };
        let interval_ms = (1000 / clamp_fps(fps)) as i64;
        match frame {
            Some(f) if now_ms.saturating_sub(f.captured_at) < interval_ms => {
                if f.seq == since {
                    FrameDecision::NotModified
                } else {
                    FrameDecision::Serve(Box::new(f))
                }
            }
            _ => FrameDecision::Capture {
                width: clamp_width(width),
                quality: clamp_quality(quality),
            },
        }
    }

    pub fn store_frame(
        &self,
        cfg: &Config,
        sandbox: &str,
        captured: CapturedFrame,
        now_ms: i64,
    ) -> Frame {
        let mut entries = self.entries.lock().unwrap();
        let entry = entries
            .entry(sandbox.to_string())
            .or_insert_with(|| Entry::new(cfg));
        entry.seq += 1;
        let frame = Frame {
            seq: entry.seq,
            jpeg_base64: captured.jpeg_base64,
            mime: captured.mime,
            width: captured.width,
            height: captured.height,
            url: captured.url,
            title: captured.title,
            loading: captured.loading,
            captured_at: now_ms,
        };
        entry.frame = Some(frame.clone());
        frame
    }

    pub fn capture_lock(&self, sandbox: &str) -> Arc<AsyncMutex<()>> {
        self.locks
            .lock()
            .unwrap()
            .entry(sandbox.to_string())
            .or_insert_with(|| Arc::new(AsyncMutex::new(())))
            .clone()
    }

    pub fn sweep(&self, cfg: &Config, now: i64) {
        let mut entries = self.entries.lock().unwrap();
        Self::sweep_locked(cfg, &mut entries, now);
        let mut locks = self.locks.lock().unwrap();
        locks.retain(|k, v| entries.contains_key(k) || Arc::strong_count(v) > 1);
    }

    fn sweep_locked(cfg: &Config, entries: &mut HashMap<String, Entry>, now: i64) {
        let max_age = cfg.computer_session_max_seconds as i64;
        let max_idle = cfg.computer_viewer_idle_seconds as i64;
        for (sandbox, entry) in entries.iter_mut() {
            entry.sessions.retain(|session_id, s| {
                let keep = now.saturating_sub(s.created_at) < max_age
                    && now.saturating_sub(s.last_seen) < max_idle;
                if !keep {
                    tracing::info!(
                        sandbox = %sandbox, session_id = %session_id, viewer = %s.viewer_id,
                        "computer: dropping expired viewer"
                    );
                }
                keep
            });
            entry.settle(now);
        }
        entries.retain(|_, e| !e.sessions.is_empty());
    }

    #[cfg(test)]
    fn live_sandboxes(&self) -> usize {
        self.entries
            .lock()
            .unwrap()
            .values()
            .filter(|e| !e.sessions.is_empty())
            .count()
    }
}

fn new_session_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let digest = Sha256::digest(format!("{nanos}:{n}").as_bytes());
    let hex: String = digest.iter().take(12).map(|b| format!("{b:02x}")).collect();
    format!("cs_{hex}")
}

pub fn session_response(view: SessionView) -> ComputerSessionResponse {
    ComputerSessionResponse {
        session_id: view.session_id,
        fps: view.fps,
        width: view.width,
        quality: view.quality,
        control: view.control.control,
        holder: view.control.holder,
        expires_at: view.expires_at,
    }
}

pub fn control_response(view: ControlView) -> ComputerControlResponse {
    ComputerControlResponse {
        control: view.control,
        holder: view.holder,
        expires_at: view.expires_at,
    }
}

pub fn open_session(
    state: &AppState,
    id: &str,
    req: &ComputerSessionRequest,
) -> Result<ComputerSessionResponse, GatewayError> {
    if !state.contains(id) {
        return Err(GatewayError::NotFound);
    }
    let opts = SessionOpts {
        viewer_id: req.viewer_id.clone(),
        fps: req.fps,
        width: req.width,
        quality: req.quality,
    };
    let now = now_unix();
    let view = state.computer.open_session(&state.cfg, id, &opts, now)?;
    state.touch(id, now);
    Ok(session_response(view))
}

pub fn close_session(state: &AppState, id: &str, session_id: &str) {
    state.computer.close_session(id, session_id, now_unix());
}

/// `Ok(None)` is the 204:
pub async fn frame(
    state: &AppState,
    id: &str,
    since: u64,
    session_id: Option<&str>,
) -> Result<Option<ComputerFrameResponse>, GatewayError> {
    state.computer.touch(id, session_id, now_unix());
    let cfg = &state.cfg;

    let decision = state.computer.decide_frame(cfg, id, since, now_ms());
    let (width, quality) = match decision {
        FrameDecision::NotModified => return Ok(None),
        FrameDecision::Serve(f) => return Ok(Some(frame_response(state, id, *f))),
        FrameDecision::Capture { width, quality } => (width, quality),
    };

    let lock = state.computer.capture_lock(id);
    let _guard = lock.lock().await;
    match state.computer.decide_frame(cfg, id, since, now_ms()) {
        FrameDecision::NotModified => return Ok(None),
        FrameDecision::Serve(f) => return Ok(Some(frame_response(state, id, *f))),
        FrameDecision::Capture { .. } => {}
    }

    let shot = browser::screenshot_quality(state, id, width, Some(quality)).await?;
    let page = browser::state(state, id).await?;
    let stored = state.computer.store_frame(
        cfg,
        id,
        CapturedFrame {
            jpeg_base64: shot.image_base64,
            mime: shot.mime,
            width: shot.width,
            height: shot.height,
            url: page.url,
            title: page.title,
            loading: page.loading,
        },
        now_ms(),
    );
    Ok(Some(frame_response(state, id, stored)))
}

fn frame_response(state: &AppState, id: &str, f: Frame) -> ComputerFrameResponse {
    ComputerFrameResponse {
        seq: f.seq,
        image_base64: f.jpeg_base64,
        mime: f.mime,
        width: f.width,
        height: f.height,
        url: f.url,
        title: f.title,
        loading: f.loading,
        control: state.computer.control(id, now_unix()).control,
        captured_at: f.captured_at,
    }
}

pub async fn page_state(
    state: &AppState,
    id: &str,
    session_id: Option<&str>,
) -> Result<ComputerStateResponse, GatewayError> {
    state.computer.touch(id, session_id, now_unix());
    let page = browser::state(state, id).await?;
    let control = state.computer.control(id, now_unix());
    Ok(ComputerStateResponse {
        url: page.url,
        title: page.title,
        loading: page.loading,
        control: control.control,
        holder: control.holder,
        expires_at: control.expires_at,
        tab_count: page.tab_count,
    })
}

pub fn control_action(
    state: &AppState,
    id: &str,
    action: &str,
    session_id: &str,
    ttl_seconds: Option<u64>,
) -> Result<ComputerControlResponse, GatewayError> {
    let now = now_unix();
    let view = match action {
        "grant" => state
            .computer
            .grant(&state.cfg, id, session_id, ttl_seconds, now)?,
        "release" => state.computer.release(id, session_id, now)?,
        other => return Err(ComputerError::UnknownAction(other.to_string()).into()),
    };
    Ok(control_response(view))
}

pub async fn input(
    state: &AppState,
    id: &str,
    req: ComputerInputRequest,
) -> Result<ComputerInputResponse, GatewayError> {
    state
        .computer
        .authorize_input(id, &req.session_id, now_unix())?;
    let result = browser::input(state, id, &req).await?;
    Ok(ComputerInputResponse {
        ok: result.ok,
        url: result.url,
        title: result.title,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::test_config;

    fn captured() -> CapturedFrame {
        CapturedFrame {
            jpeg_base64: "abc".into(),
            mime: "image/jpeg".into(),
            width: 720,
            height: 405,
            url: "https://a.example/".into(),
            title: "A".into(),
            loading: false,
        }
    }

    fn opts(viewer_id: &str) -> SessionOpts {
        SessionOpts {
            viewer_id: viewer_id.into(),
            ..Default::default()
        }
    }

    fn with_session(reg: &Registry, cfg: &Config, sandbox: &str, now: i64) -> String {
        reg.open_session(cfg, sandbox, &opts("viewer:1"), now)
            .unwrap()
            .session_id
    }

    #[test]
    fn session_defaults_come_from_config_and_clamp() {
        let mut cfg = test_config();
        cfg.computer_default_fps = 3;
        let reg = Registry::new();
        let asked = SessionOpts {
            viewer_id: "viewer:1".into(),
            fps: Some(99),
            width: Some(4000),
            quality: Some(100),
        };
        let view = reg.open_session(&cfg, "sb", &asked, 0).unwrap();
        assert_eq!(view.fps, MAX_FPS);
        assert_eq!(view.width, MAX_WIDTH);
        assert_eq!(view.quality, MAX_QUALITY);
        assert_eq!(view.control.control, Control::Agent);
        assert_eq!(view.expires_at, cfg.computer_session_max_seconds as i64);
    }

    #[test]
    fn second_viewer_joins_without_restarting_geometry() {
        let cfg = test_config();
        let reg = Registry::new();
        let low = SessionOpts {
            viewer_id: "viewer:1".into(),
            fps: Some(2),
            width: Some(300),
            quality: Some(40),
        };
        let high = SessionOpts {
            viewer_id: "viewer:2".into(),
            fps: Some(8),
            width: Some(900),
            quality: Some(70),
        };
        let first = reg.open_session(&cfg, "sb", &low, 0).unwrap();
        let second = reg.open_session(&cfg, "sb", &high, 1).unwrap();
        assert_ne!(first.session_id, second.session_id);
        assert_eq!(second.fps, 2);
        assert_eq!(second.width, 300);
        assert_eq!(second.quality, 40);
        assert_eq!(reg.live_sandboxes(), 1);
    }

    #[test]
    fn capacity_is_per_sandbox_not_per_viewer() {
        let mut cfg = test_config();
        cfg.computer_max_live = 2;
        let reg = Registry::new();
        with_session(&reg, &cfg, "sb-a", 0);
        with_session(&reg, &cfg, "sb-b", 0);
        assert!(reg.open_session(&cfg, "sb-a", &opts("viewer:2"), 0).is_ok());
        assert_eq!(
            reg.open_session(&cfg, "sb-c", &opts("viewer:3"), 0),
            Err(ComputerError::Capacity)
        );
    }

    #[test]
    fn capacity_error_maps_to_429() {
        use axum::response::IntoResponse;
        let resp: GatewayError = ComputerError::Capacity.into();
        assert_eq!(
            resp.into_response().status(),
            axum::http::StatusCode::TOO_MANY_REQUESTS
        );
    }

    #[test]
    fn capacity_frees_once_a_sandbox_goes_idle() {
        let mut cfg = test_config();
        cfg.computer_max_live = 1;
        cfg.computer_viewer_idle_seconds = 60;
        let reg = Registry::new();
        with_session(&reg, &cfg, "sb-a", 0);
        assert_eq!(
            reg.open_session(&cfg, "sb-b", &opts("viewer:2"), 10),
            Err(ComputerError::Capacity)
        );
        assert!(reg.open_session(&cfg, "sb-b", &opts("viewer:2"), 61).is_ok());
    }

    #[test]
    fn unchanged_seq_on_a_fresh_cache_is_not_modified() {
        let cfg = test_config();
        let reg = Registry::new();
        with_session(&reg, &cfg, "sb", 0);
        let f = reg.store_frame(&cfg, "sb", captured(), 1_000);
        assert_eq!(f.seq, 1);
        assert_eq!(
            reg.decide_frame(&cfg, "sb", 1, 1_100),
            FrameDecision::NotModified
        );
    }

    #[test]
    fn a_lagging_viewer_is_served_the_cache_without_capturing() {
        let cfg = test_config();
        let reg = Registry::new();
        with_session(&reg, &cfg, "sb", 0);
        reg.store_frame(&cfg, "sb", captured(), 1_000);
        match reg.decide_frame(&cfg, "sb", 0, 1_100) {
            FrameDecision::Serve(f) => assert_eq!(f.seq, 1),
            other => panic!("expected the cached frame, got {other:?}"),
        }
    }

    #[test]
    fn a_stale_cache_captures_and_the_seq_increments() {
        let mut cfg = test_config();
        cfg.computer_default_fps = 4; // 250ms between captures
        let reg = Registry::new();
        with_session(&reg, &cfg, "sb", 0);
        reg.store_frame(&cfg, "sb", captured(), 1_000);
        assert_eq!(
            reg.decide_frame(&cfg, "sb", 1, 1_400),
            FrameDecision::Capture {
                width: 720,
                quality: 55
            }
        );
        let second = reg.store_frame(&cfg, "sb", captured(), 1_400);
        assert_eq!(second.seq, 2);
        assert_eq!(
            reg.decide_frame(&cfg, "sb", 2, 1_450),
            FrameDecision::NotModified
        );
    }

    #[test]
    fn an_empty_cache_always_captures() {
        let cfg = test_config();
        let reg = Registry::new();
        assert!(matches!(
            reg.decide_frame(&cfg, "sb", 0, 0),
            FrameDecision::Capture { .. }
        ));
    }

    #[test]
    fn input_is_rejected_until_control_is_granted() {
        let cfg = test_config();
        let reg = Registry::new();
        let sid = with_session(&reg, &cfg, "sb", 0);
        assert_eq!(
            reg.authorize_input("sb", &sid, 0),
            Err(ComputerError::ControlNotHeld)
        );
        reg.grant(&cfg, "sb", &sid, Some(60), 0).unwrap();
        assert_eq!(reg.authorize_input("sb", &sid, 1), Ok(()));
    }

    #[test]
    fn control_not_held_maps_to_409() {
        use axum::response::IntoResponse;
        let resp: GatewayError = ComputerError::ControlNotHeld.into();
        assert_eq!(
            resp.into_response().status(),
            axum::http::StatusCode::CONFLICT
        );
    }

    #[test]
    fn only_the_holder_may_send_input() {
        let cfg = test_config();
        let reg = Registry::new();
        let holder = with_session(&reg, &cfg, "sb", 0);
        let other = reg
            .open_session(&cfg, "sb", &opts("viewer:2"), 0)
            .unwrap()
            .session_id;
        reg.grant(&cfg, "sb", &holder, Some(60), 0).unwrap();
        assert_eq!(
            reg.authorize_input("sb", &other, 1),
            Err(ComputerError::ControlNotHeld)
        );
    }

    #[test]
    fn control_auto_releases_at_the_ttl() {
        let cfg = test_config();
        let reg = Registry::new();
        let sid = with_session(&reg, &cfg, "sb", 0);
        let granted = reg.grant(&cfg, "sb", &sid, Some(30), 100).unwrap();
        assert_eq!(granted.control, Control::User);
        assert_eq!(granted.holder.as_deref(), Some(sid.as_str()));
        assert_eq!(granted.expires_at, Some(130));
        assert_eq!(reg.control("sb", 129).control, Control::User);

        let expired = reg.control("sb", 130);
        assert_eq!(expired.control, Control::Agent);
        assert!(expired.holder.is_none());
        assert!(expired.expires_at.is_none());
        assert_eq!(
            reg.authorize_input("sb", &sid, 130),
            Err(ComputerError::ControlNotHeld)
        );
    }

    #[test]
    fn ttl_is_clamped_to_the_session_cap() {
        let mut cfg = test_config();
        cfg.computer_session_max_seconds = 900;
        let reg = Registry::new();
        let sid = with_session(&reg, &cfg, "sb", 0);
        let view = reg.grant(&cfg, "sb", &sid, Some(99_999), 0).unwrap();
        assert_eq!(view.expires_at, Some(900));
    }

    #[test]
    fn release_returns_control_to_the_agent() {
        let cfg = test_config();
        let reg = Registry::new();
        let sid = with_session(&reg, &cfg, "sb", 0);
        reg.grant(&cfg, "sb", &sid, Some(300), 0).unwrap();
        let view = reg.release("sb", &sid, 1).unwrap();
        assert_eq!(view.control, Control::Agent);
        assert!(view.holder.is_none());
    }

    #[test]
    fn a_non_holder_release_leaves_control_alone() {
        let cfg = test_config();
        let reg = Registry::new();
        let holder = with_session(&reg, &cfg, "sb", 0);
        let other = reg
            .open_session(&cfg, "sb", &opts("viewer:2"), 0)
            .unwrap()
            .session_id;
        reg.grant(&cfg, "sb", &holder, Some(300), 0).unwrap();
        let view = reg.release("sb", &other, 1).unwrap();
        assert_eq!(view.control, Control::User);
        assert_eq!(view.holder.as_deref(), Some(holder.as_str()));
    }

    #[test]
    fn grant_for_an_unknown_session_is_rejected() {
        let cfg = test_config();
        let reg = Registry::new();
        with_session(&reg, &cfg, "sb", 0);
        assert_eq!(
            reg.grant(&cfg, "sb", "cs_nope", None, 0),
            Err(ComputerError::SessionNotFound)
        );
    }

    #[test]
    fn closing_the_holder_session_returns_control_to_the_agent() {
        let cfg = test_config();
        let reg = Registry::new();
        let holder = with_session(&reg, &cfg, "sb", 0);
        reg.open_session(&cfg, "sb", &opts("viewer:2"), 0).unwrap();
        reg.grant(&cfg, "sb", &holder, Some(300), 0).unwrap();
        reg.close_session("sb", &holder, 1);
        assert_eq!(reg.control("sb", 1).control, Control::Agent);
        assert_eq!(reg.live_sandboxes(), 1);
    }

    #[test]
    fn closing_the_last_session_drops_the_sandbox() {
        let cfg = test_config();
        let reg = Registry::new();
        let sid = with_session(&reg, &cfg, "sb", 0);
        reg.close_session("sb", &sid, 1);
        reg.close_session("sb", &sid, 1); // idempotent
        assert_eq!(reg.live_sandboxes(), 0);
    }

    #[test]
    fn sweep_drops_idle_and_over_age_viewers() {
        let mut cfg = test_config();
        cfg.computer_viewer_idle_seconds = 60;
        cfg.computer_session_max_seconds = 900;
        let reg = Registry::new();
        let idle = with_session(&reg, &cfg, "sb-idle", 0);
        let kept = with_session(&reg, &cfg, "sb-kept", 0);

        reg.touch("sb-kept", Some(&kept), 500);
        reg.sweep(&cfg, 520);
        assert_eq!(reg.live_sandboxes(), 1);
        assert_eq!(
            reg.authorize_input("sb-idle", &idle, 520),
            Err(ComputerError::ControlNotHeld)
        );

        reg.touch("sb-kept", Some(&kept), 950);
        reg.sweep(&cfg, 950);
        assert_eq!(reg.live_sandboxes(), 0);
    }

    #[test]
    fn touch_without_a_session_id_refreshes_every_viewer() {
        let mut cfg = test_config();
        cfg.computer_viewer_idle_seconds = 60;
        let reg = Registry::new();
        with_session(&reg, &cfg, "sb", 0);
        reg.open_session(&cfg, "sb", &opts("viewer:2"), 0).unwrap();
        reg.touch("sb", None, 50);
        reg.sweep(&cfg, 100);
        assert_eq!(reg.live_sandboxes(), 1);
    }

    #[test]
    fn unknown_control_action_is_a_bad_request() {
        use axum::response::IntoResponse;
        let resp: GatewayError = ComputerError::UnknownAction("take".into()).into();
        assert_eq!(
            resp.into_response().status(),
            axum::http::StatusCode::BAD_REQUEST
        );
    }

    #[test]
    fn session_ids_are_unique() {
        let a = new_session_id();
        let b = new_session_id();
        assert_ne!(a, b);
        assert!(a.starts_with("cs_"));
    }
}
