//! `vibe_core_ffi` — the UniFFI boundary for [`vibe_core`].
//!
//! # The one structural idea
//!
//! **There is no synchronous read API.** Not "there is one but please don't call
//! it" — there is nothing to call. The reducer lives *inside* a worker thread and
//! is never shared behind a lock, so a UI thread physically cannot block on it.
//!
//! That is the point. The shipped Swift engine has the opposite shape and pays
//! for it: `ChatEngine.syncOnQueue` called from a UI getter stalls the main
//! thread ~77 ms, and the engine prints `[ChatEngine][MAIN-THREAD-HANG]` when it
//! happens. Every migrated path retires that class of bug by construction.
//!
//! Callers submit commands; results arrive on a [`VibeDeltaSink`] the platform
//! supplies. One FFI call per *commit* — never per cell, never per message. Any
//! design where `cellForItemAt` reaches across this boundary is wrong and must
//! fail review.
//!
//! # The lock rule, and why it is satisfied for free
//!
//! The standing FFI foot-gun is "never hold the core lock across a callback into
//! platform code". Here there is no lock to hold: the reducer is owned by the
//! worker thread, and the sink is invoked from that thread between commands, not
//! during one. A sink callback that re-enters and submits another command simply
//! enqueues it — the queue is the only shared object, and it is never held across
//! the callback. `reentrant_sink_callback_does_not_deadlock` proves it.
//!
//! # Panics degrade, they do not abort
//!
//! The release profile sets `panic = "unwind"` deliberately. Entry points and the
//! worker loop wrap in `catch_unwind`, converting a panic into
//! [`VibeFfiError::Internal`]. A core panic must degrade to "this chat falls back
//! to the Swift path", never take down the host app.
//!
//! # The store is a second object, and it *is* synchronous
//!
//! [`store::VibeStoreHandle`] wraps SQLite, and its reads block the calling
//! thread — there is no worker thread behind it. That is not a relaxation of the
//! rule above: the rule protects the *reducer*, whose purity is what makes
//! replay and the soak tests mean anything, and the store is deliberately not
//! part of it. The reducer still never opens a file.
//!
//! The obligation moves to the caller instead: **the store must be called from a
//! background queue.** Swapping a stall on `ChatEngine.syncOnQueue` for a stall
//! on a SQLite read would be no progress at all, so the Swift wrapper refuses
//! main-thread calls loudly rather than serving them.
//!
//! # What this crate never does
//!
//! Custody a private key, perform RSA, touch the network, or open an agent
//! runtime payload.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{mpsc, Arc, Mutex};

use crate::unwrap::VibeForeignKeyUnwrapper;
use vibe_core::reducer::{VibeCoreConfig, VibeTimelineReducer};
use vibe_core::types::{
    VibeCoreEventV1, VibeEventBody, VibeEventSource, VibeTimelineAnchor, VibeTimelineDeltaV1,
};
use vibe_core::VibeCoreError;

pub mod group;
pub mod seal;
pub mod secure;
pub mod store;
pub mod types;
pub mod unwrap;

pub use seal::{VibeFfiSealedBody, VibeStoreSealerHandle, VIBE_STORE_KEY_LEN};
pub use store::{
    VibeFfiBackfillProgress, VibeFfiChatLoadState, VibeFfiStoreCursor, VibeFfiStoredRow,
    VibeLegacyStoreHandle, VibeStoreHandle,
};
pub use types::{
    VibeFfiDelta, VibeFfiDisplayStatus, VibeFfiMessage, VibeFfiMessageKind, VibeFfiOp,
    VibeFfiSource, VibeFfiWindow,
};
pub use unwrap::{VibeFfiKeyRequest, VibeFfiKeyUnwrapper};

uniffi::setup_scaffolding!();

/// Errors crossing the boundary.
///
/// `vibe_core::VibeCoreError::Internal` carries a `&'static str`; UniFFI needs
/// owned data, so it is flattened here. The detail is a fixed shape from the
/// core's own vocabulary — never a message body, a key, an id, or attacker-
/// influenced input echoed back.
#[derive(Debug, uniffi::Error)]
pub enum VibeFfiError {
    /// A frame was dropped. Counted, never fatal.
    Malformed { detail: String },
    /// A window or anchor query named a chat the reducer has never seen.
    UnknownChat,
    /// The handle has been shut down; the worker is gone.
    ShutDown,
    /// The worker thread stopped accepting commands.
    WorkerUnavailable,
    /// Invariant violation, or a caught panic. The platform must disable the
    /// core for this chat and fall back to Swift.
    Internal { detail: String },
    /// A store operation failed. `detail` comes from `VibeStoreError`, which is
    /// shape-only by construction — never a path, SQL text, id, or payload.
    Store { detail: String },
}

impl std::fmt::Display for VibeFfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Malformed { detail } => write!(f, "malformed: {detail}"),
            Self::UnknownChat => f.write_str("unknown chat"),
            Self::ShutDown => f.write_str("handle shut down"),
            Self::WorkerUnavailable => f.write_str("worker unavailable"),
            Self::Internal { detail } => write!(f, "internal: {detail}"),
            Self::Store { detail } => write!(f, "store: {detail}"),
        }
    }
}

impl std::error::Error for VibeFfiError {}

impl From<VibeCoreError> for VibeFfiError {
    fn from(value: VibeCoreError) -> Self {
        match value {
            VibeCoreError::UnknownChat => Self::UnknownChat,
            VibeCoreError::Internal { detail } => Self::Internal {
                detail: detail.to_string(),
            },
            other => Self::Malformed {
                detail: other.to_string(),
            },
        }
    }
}

/// Runs `body`, converting a panic into [`VibeFfiError::Internal`].
///
/// `AssertUnwindSafe` is sound here because every caller either owns its
/// arguments outright or touches only the command channel, which is a plain
/// `Sender` with no invariant a panic could tear.
fn guarded<T>(
    what: &'static str,
    body: impl FnOnce() -> Result<T, VibeFfiError>,
) -> Result<T, VibeFfiError> {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(result) => result,
        Err(_) => Err(VibeFfiError::Internal {
            detail: format!("panic in {what}"),
        }),
    }
}

/// Core → platform dispatch.
///
/// Implemented on the platform side. Invoked from the worker thread, never with
/// any core state held. Implementations must be cheap and must not block: the
/// worker is single-threaded, so a slow sink is backpressure on every chat.
#[uniffi::export(with_foreign)]
pub trait VibeDeltaSink: Send + Sync {
    /// One ordered delta is ready.
    fn on_delta(&self, delta: VibeFfiDelta);
    /// A window query completed.
    fn on_window(&self, window: VibeFfiWindow);
    /// Something failed asynchronously. Never fatal on its own.
    fn on_error(&self, message: String);
}

/// Construction-time settings.
#[derive(Clone, Debug, uniffi::Record)]
pub struct VibeFfiConfig {
    pub own_user_id: String,
    /// Stream coalescing budget. One display frame at 120 Hz is ~8 ms.
    pub flush_frame_interval_ms: i64,
}

impl Default for VibeFfiConfig {
    fn default() -> Self {
        Self {
            own_user_id: String::new(),
            flush_frame_interval_ms: 8,
        }
    }
}

/// A queued unit of work.
///
/// Every variant owns its data: nothing borrowed crosses onto the worker thread,
/// so a caller cannot free something the worker is still reading.
enum VibeCoreCommand {
    IngestFrame {
        chat_id: String,
        json: Vec<u8>,
        source: VibeFfiSource,
        received_at_ms: i64,
    },
    IngestFrames {
        chat_id: String,
        json_array: Vec<u8>,
        source: VibeFfiSource,
        received_at_ms: i64,
    },
    Flush {
        now_ms: i64,
    },
    /// A local or remote deletion. Not a frame — there is no server payload for a
    /// row that no longer exists, so it cannot ride `IngestFrame`.
    DeleteMessage {
        chat_id: String,
        message_id: String,
        for_everyone: bool,
        tombstone_ms: i64,
    },
    /// Wipe the transcript for a chat (Clear Chat). Same reason as `DeleteMessage`:
    /// there is no message frame for a bulk clear, so it cannot ride `IngestFrame`.
    /// `before_ts_ms = None` clears everything; `Some(ts)` keeps rows at/after `ts`.
    ClearChat {
        chat_id: String,
        before_ts_ms: Option<i64>,
        cleared_at_ms: i64,
    },
    RequestWindow {
        chat_id: String,
        now_ms: i64,
    },
    /// Publish the current window **without** moving the anchor or the cursor.
    RefreshWindow {
        chat_id: String,
        now_ms: i64,
    },
    PageBefore {
        chat_id: String,
        now_ms: i64,
    },
    PageAfter {
        chat_id: String,
        now_ms: i64,
    },
    Resync {
        chat_id: String,
    },
    /// Flush and quiesce. iOS calls this on `didEnterBackground`.
    Suspend,
    Shutdown,
}

/// The FFI object. Owns one worker thread and the command queue.
#[derive(uniffi::Object)]
pub struct VibeCoreHandle {
    tx: Mutex<Option<Sender<VibeCoreCommand>>>,
    join: Mutex<Option<std::thread::JoinHandle<()>>>,
    shut_down: AtomicBool,
}

#[uniffi::export]
impl VibeCoreHandle {
    /// Spawns the worker and returns immediately.
    ///
    /// `unwrapper` is the platform's private-key custody. Passing `None` leaves
    /// the core's deny-all default installed, which means **every hybrid envelope
    /// canonicalizes to `DECRYPTION_FAILED`** — correct for a diagnostic surface
    /// that only exercises ordering, and wrong for anything a user reads. A
    /// production caller passes one.
    #[uniffi::constructor]
    pub fn new(
        config: VibeFfiConfig,
        sink: Arc<dyn VibeDeltaSink>,
        unwrapper: Option<Arc<dyn VibeFfiKeyUnwrapper>>,
    ) -> Arc<Self> {
        let (tx, rx) = mpsc::channel();
        let core_config = VibeCoreConfig {
            own_user_id: config.own_user_id,
            flush_frame_interval_ms: config.flush_frame_interval_ms,
            unwrapper: match unwrapper {
                Some(foreign) => Arc::new(VibeForeignKeyUnwrapper::new(foreign)),
                None => Arc::new(vibe_core::VibeDenyAllKeyUnwrapper),
            },
            ..VibeCoreConfig::default()
        };
        let join = std::thread::Builder::new()
            .name("vibe-core-worker".to_string())
            .spawn(move || worker_loop(&rx, core_config, &sink))
            .expect("spawning the core worker thread");

        Arc::new(Self {
            tx: Mutex::new(Some(tx)),
            join: Mutex::new(Some(join)),
            shut_down: AtomicBool::new(false),
        })
    }

    pub fn ingest_frame(
        &self,
        chat_id: String,
        json: Vec<u8>,
        source: VibeFfiSource,
        received_at_ms: i64,
    ) -> Result<(), VibeFfiError> {
        guarded("ingest_frame", || {
            self.submit(VibeCoreCommand::IngestFrame {
                chat_id,
                json,
                source,
                received_at_ms,
            })
        })
    }

    pub fn ingest_frames(
        &self,
        chat_id: String,
        json_array: Vec<u8>,
        source: VibeFfiSource,
        received_at_ms: i64,
    ) -> Result<(), VibeFfiError> {
        guarded("ingest_frames", || {
            self.submit(VibeCoreCommand::IngestFrames {
                chat_id,
                json_array,
                source,
                received_at_ms,
            })
        })
    }

    pub fn flush(&self, now_ms: i64) -> Result<(), VibeFfiError> {
        guarded("flush", || self.submit(VibeCoreCommand::Flush { now_ms }))
    }

    /// Tells the core a message is gone.
    ///
    /// Deletion cannot arrive as a frame: the server sends an id and a scope, not a
    /// message, so `ingest_frame` has nothing to canonicalize. Without this the core
    /// keeps the row in its store and re-publishes it in the next window — which is
    /// exactly the "deleted cell comes back to the list" seen on device once the core
    /// became the list's content authority.
    pub fn delete_message(
        &self,
        chat_id: String,
        message_id: String,
        for_everyone: bool,
        tombstone_ms: i64,
    ) -> Result<(), VibeFfiError> {
        guarded("delete_message", || {
            self.submit(VibeCoreCommand::DeleteMessage {
                chat_id,
                message_id,
                for_everyone,
                tombstone_ms,
            })
        })
    }

    /// Clears the chat transcript in the reducer (and publishes an empty/truncated window).
    ///
    /// Same class of event as [`Self::delete_message`]: the server soft-clears with
    /// `messages_cleared_at` / participant delete and never sends one frame per row.
    /// Without this, the engine drops every row, the core's next window puts them
    /// back, and Clear Chat looks broken once the list is core-authoritative.
    ///
    /// `before_ts_ms = None` wipes everything. `Some(ts)` keeps messages at/after `ts`
    /// (Telegram-style "clear before now").
    pub fn clear_chat(
        &self,
        chat_id: String,
        before_ts_ms: Option<i64>,
        cleared_at_ms: i64,
    ) -> Result<(), VibeFfiError> {
        guarded("clear_chat", || {
            self.submit(VibeCoreCommand::ClearChat {
                chat_id,
                before_ts_ms,
                cleared_at_ms,
            })
        })
    }

    /// Re-anchors to the bottom and publishes the window. Chat open, not steady state.
    ///
    /// This **resets the scroll-back cursor**, which is correct when a reader arrives
    /// at a conversation and wrong on every subsequent tick. Steady-state readers want
    /// [`Self::refresh_window`].
    pub fn request_window(&self, chat_id: String, now_ms: i64) -> Result<(), VibeFfiError> {
        guarded("request_window", || {
            self.submit(VibeCoreCommand::RequestWindow { chat_id, now_ms })
        })
    }

    /// Publishes the window the consumer should be showing, leaving the cursor alone.
    pub fn refresh_window(&self, chat_id: String, now_ms: i64) -> Result<(), VibeFfiError> {
        guarded("refresh_window", || {
            self.submit(VibeCoreCommand::RefreshWindow { chat_id, now_ms })
        })
    }

    pub fn page_before(&self, chat_id: String, now_ms: i64) -> Result<(), VibeFfiError> {
        guarded("page_before", || {
            self.submit(VibeCoreCommand::PageBefore { chat_id, now_ms })
        })
    }

    pub fn page_after(&self, chat_id: String, now_ms: i64) -> Result<(), VibeFfiError> {
        guarded("page_after", || {
            self.submit(VibeCoreCommand::PageAfter { chat_id, now_ms })
        })
    }

    pub fn resync(&self, chat_id: String) -> Result<(), VibeFfiError> {
        guarded("resync", || {
            self.submit(VibeCoreCommand::Resync { chat_id })
        })
    }

    /// Flush and quiesce without tearing the worker down.
    pub fn suspend(&self) -> Result<(), VibeFfiError> {
        guarded("suspend", || self.submit(VibeCoreCommand::Suspend))
    }

    /// Stops the worker and joins it.
    ///
    /// Idempotent: calling it twice is not an error, because a platform tearing
    /// down under memory pressure should not have to track whether it already
    /// did. Dropping the `Sender` is what ends the loop even if the `Shutdown`
    /// command is never observed.
    pub fn shutdown(&self) {
        if self.shut_down.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Ok(mut guard) = self.tx.lock() {
            if let Some(tx) = guard.as_ref() {
                let _ = tx.send(VibeCoreCommand::Shutdown);
            }
            guard.take();
        }
        let handle = self.join.lock().ok().and_then(|mut g| g.take());
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }

    pub fn is_shut_down(&self) -> bool {
        self.shut_down.load(Ordering::SeqCst)
    }
}

impl VibeCoreHandle {
    /// Enqueues without blocking on the worker.
    ///
    /// The `tx` mutex is held only long enough to clone out of an `Option`; it is
    /// never held across a send into the core or a callback into platform code.
    /// That is what makes a re-entrant sink callback safe rather than a deadlock.
    fn submit(&self, command: VibeCoreCommand) -> Result<(), VibeFfiError> {
        if self.shut_down.load(Ordering::SeqCst) {
            return Err(VibeFfiError::ShutDown);
        }
        let sender = {
            let guard = self.tx.lock().map_err(|_| VibeFfiError::Internal {
                detail: "tx poisoned".to_string(),
            })?;
            guard.as_ref().cloned().ok_or(VibeFfiError::ShutDown)?
        };
        sender
            .send(command)
            .map_err(|_| VibeFfiError::WorkerUnavailable)
    }
}

impl Drop for VibeCoreHandle {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// The worker loop. Owns the reducer outright — never shared, never locked,
/// never observable from another thread.
fn worker_loop(
    rx: &Receiver<VibeCoreCommand>,
    config: VibeCoreConfig,
    sink: &Arc<dyn VibeDeltaSink>,
) {
    let mut reducer = VibeTimelineReducer::new(config);

    while let Ok(command) = rx.recv() {
        if matches!(command, VibeCoreCommand::Shutdown) {
            break;
        }
        // Per-command `catch_unwind`: one poisoned frame must not kill the
        // worker and strand every other chat. The panic is reported through the
        // sink and the loop continues.
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            run_command(&mut reducer, command, sink);
        }));
        if outcome.is_err() {
            sink.on_error("panic in core worker".to_string());
        }
    }
}

fn run_command(
    reducer: &mut VibeTimelineReducer,
    command: VibeCoreCommand,
    sink: &Arc<dyn VibeDeltaSink>,
) {
    match command {
        VibeCoreCommand::IngestFrame {
            chat_id,
            json,
            source,
            received_at_ms,
        } => {
            reducer.ingest(VibeCoreEventV1::new(
                chat_id,
                received_at_ms,
                source.into(),
                VibeEventBody::RawFrame { json },
            ));
            let deltas = reducer.poll_deltas(received_at_ms);
            emit(reducer, &deltas, sink);
        }
        VibeCoreCommand::IngestFrames {
            chat_id,
            json_array,
            source,
            received_at_ms,
        } => {
            reducer.ingest(VibeCoreEventV1::new(
                chat_id,
                received_at_ms,
                source.into(),
                VibeEventBody::RawFrames { json_array },
            ));
            let deltas = reducer.poll_deltas(received_at_ms);
            emit(reducer, &deltas, sink);
        }
        VibeCoreCommand::Flush { now_ms } => {
            let deltas = reducer.flush(now_ms);
            emit(reducer, &deltas, sink);
        }
        VibeCoreCommand::DeleteMessage {
            chat_id,
            message_id,
            for_everyone,
            tombstone_ms,
        } => {
            reducer.ingest(VibeCoreEventV1::new(
                chat_id,
                tombstone_ms,
                VibeEventSource::Local,
                VibeEventBody::Delete {
                    message_id,
                    for_everyone,
                    tombstone_ms,
                },
            ));
            let deltas = reducer.poll_deltas(tombstone_ms);
            emit(reducer, &deltas, sink);
        }
        VibeCoreCommand::ClearChat {
            chat_id,
            before_ts_ms,
            cleared_at_ms,
        } => {
            reducer.ingest(VibeCoreEventV1::new(
                chat_id,
                cleared_at_ms,
                VibeEventSource::Local,
                VibeEventBody::ChatCleared { before_ts_ms },
            ));
            let deltas = reducer.poll_deltas(cleared_at_ms);
            emit(reducer, &deltas, sink);
        }
        VibeCoreCommand::RequestWindow { chat_id, now_ms } => {
            match reducer.window(&chat_id, VibeTimelineAnchor::bottom(), now_ms) {
                Ok(result) => {
                    if let Some(delta) = result.delta.as_ref() {
                        sink.on_delta(VibeFfiDelta::from(delta));
                    }
                    sink.on_window(VibeFfiWindow::from(&result.window));
                }
                Err(e) => sink.on_error(VibeFfiError::from(e).to_string()),
            }
        }
        VibeCoreCommand::RefreshWindow { chat_id, now_ms } => {
            let deltas = reducer.flush(now_ms);
            let already_published = deltas.iter().any(|d| d.chat_id == chat_id);
            emit(reducer, &deltas, sink);
            // The caller asked for the window it should be showing, so silence is not
            // an acceptable answer for "nothing changed" — a reader that missed one
            // publish would stay wrong forever. But the flush above may have just
            // published this chat, and a second identical window is one more full row
            // rebuild on the platform side for no new information.
            if !already_published {
                match reducer.current_window(&chat_id) {
                    Ok(window) => sink.on_window(VibeFfiWindow::from(&window)),
                    Err(e) => sink.on_error(VibeFfiError::from(e).to_string()),
                }
            }
        }
        VibeCoreCommand::PageBefore { chat_id, now_ms } => {
            match reducer.page_before(&chat_id, now_ms) {
                Ok(Some(delta)) => {
                    sink.on_delta(VibeFfiDelta::from(&delta));
                    publish_window(reducer, &chat_id, sink);
                }
                Ok(None) => {}
                Err(e) => sink.on_error(VibeFfiError::from(e).to_string()),
            }
        }
        VibeCoreCommand::PageAfter { chat_id, now_ms } => {
            match reducer.page_after(&chat_id, now_ms) {
                Ok(Some(delta)) => {
                    sink.on_delta(VibeFfiDelta::from(&delta));
                    publish_window(reducer, &chat_id, sink);
                }
                Ok(None) => {}
                Err(e) => sink.on_error(VibeFfiError::from(e).to_string()),
            }
        }
        VibeCoreCommand::Resync { chat_id } => match reducer.resync(&chat_id) {
            Ok(delta) => {
                sink.on_delta(VibeFfiDelta::from(&delta));
                publish_window(reducer, &chat_id, sink);
            }
            Err(e) => sink.on_error(VibeFfiError::from(e).to_string()),
        },
        VibeCoreCommand::Suspend => {
            // A flush barrier so nothing pending is lost if the process is
            // suspended or killed before the next command arrives.
            let deltas = reducer.flush(i64::MAX);
            emit(reducer, &deltas, sink);
        }
        VibeCoreCommand::Shutdown => {}
    }
}

/// Publishes deltas **and** the window each one landed in.
///
/// A delta is a geometry instruction; the window is the row payload. The platform
/// renders from the window, so a delta that never becomes a window is a change the
/// screen never sees — a delete that leaves the row on screen, a page that never
/// widens the transcript. Before this, the only publisher of a window was
/// `request_window`, which **resets the anchor and the cursor**: the list polled it
/// on every engine reconcile, and every poll threw away whatever `page_before` had
/// just done. Device run 2026-08-04: six consecutive scroll-back pages, `engine=480`,
/// core stuck at `rows=200` on the newest messages, top of the list unreachable.
fn emit(
    reducer: &VibeTimelineReducer,
    deltas: &[VibeTimelineDeltaV1],
    sink: &Arc<dyn VibeDeltaSink>,
) {
    for delta in deltas {
        sink.on_delta(VibeFfiDelta::from(delta));
    }
    // One window per chat, however many deltas it produced: the window is a
    // snapshot of the settled state, so publishing it twice sends the same bytes
    // and one full row payload per chat is the whole budget worth spending here.
    let mut published: Vec<&str> = Vec::with_capacity(deltas.len());
    for delta in deltas {
        if published.contains(&delta.chat_id.as_str()) {
            continue;
        }
        published.push(delta.chat_id.as_str());
        publish_window(reducer, &delta.chat_id, sink);
    }
}

fn publish_window(reducer: &VibeTimelineReducer, chat_id: &str, sink: &Arc<dyn VibeDeltaSink>) {
    if let Ok(window) = reducer.current_window(chat_id) {
        sink.on_window(VibeFfiWindow::from(&window));
    }
}
