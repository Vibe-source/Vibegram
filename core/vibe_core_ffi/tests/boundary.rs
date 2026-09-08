//! Boundary behaviour: threading, re-entrancy, panic containment, shutdown.
//!
//! These are the properties that make the FFI safe to link into a shipping app.
//! They are deliberately *not* tests of the reduction — `vibe_core`'s own suite
//! covers that. Everything here is about what happens at the seam.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;

use vibe_core_ffi::{
    VibeCoreHandle, VibeDeltaSink, VibeFfiConfig, VibeFfiDelta, VibeFfiSource, VibeFfiWindow,
};

/// How long a test waits before declaring a hang. Generous, because a deadlock
/// fails by timing out and a slow CI box must not look like one.
const WAIT: Duration = Duration::from_secs(5);

/// Counts callbacks and lets a test block until a count is reached.
#[derive(Default)]
struct CountingSink {
    deltas: AtomicUsize,
    windows: AtomicUsize,
    errors: Mutex<Vec<String>>,
    signal: (Mutex<()>, Condvar),
}

impl CountingSink {
    fn wait_until(&self, predicate: impl Fn() -> bool) -> bool {
        let deadline = std::time::Instant::now() + WAIT;
        while std::time::Instant::now() < deadline {
            if predicate() {
                return true;
            }
            let (lock, cvar) = &self.signal;
            let guard = lock.lock().unwrap();
            let _ = cvar.wait_timeout(guard, Duration::from_millis(25)).unwrap();
        }
        predicate()
    }

    fn wake(&self) {
        self.signal.1.notify_all();
    }
}

impl VibeDeltaSink for CountingSink {
    fn on_delta(&self, _delta: VibeFfiDelta) {
        self.deltas.fetch_add(1, Ordering::SeqCst);
        self.wake();
    }
    fn on_window(&self, _window: VibeFfiWindow) {
        self.windows.fetch_add(1, Ordering::SeqCst);
        self.wake();
    }
    fn on_error(&self, message: String) {
        self.errors.lock().unwrap().push(message);
        self.wake();
    }
}

fn config() -> VibeFfiConfig {
    VibeFfiConfig {
        own_user_id: "me".to_string(),
        flush_frame_interval_ms: 0,
    }
}

fn frame(message_id: &str, ts_ms: i64) -> Vec<u8> {
    format!(
        r#"{{"id":"{message_id}","chat_id":"chat-1","sender_id":"peer","timestamp":{ts_ms},"content":"hello","type":"text"}}"#
    )
    .into_bytes()
}

#[test]
fn a_handle_spawns_a_worker_and_shuts_it_down_cleanly() {
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink.clone(), None);
    assert!(!handle.is_shut_down());
    handle.shutdown();
    assert!(handle.is_shut_down());
}

#[test]
fn shutdown_is_idempotent() {
    // A platform tearing down under memory pressure should not have to track
    // whether it already shut the handle down.
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink, None);
    handle.shutdown();
    handle.shutdown();
    handle.shutdown();
    assert!(handle.is_shut_down());
}

#[test]
fn commands_after_shutdown_are_refused_rather_than_hanging() {
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink, None);
    handle.shutdown();

    // The failure mode this guards against is a caller blocking forever on a
    // dead worker. It must return, and it must return an error.
    let result = handle.ingest_frame(
        "chat-1".to_string(),
        frame("m1", 1),
        VibeFfiSource::ChatTopic,
        1,
    );
    assert!(result.is_err());
    assert!(handle.flush(2).is_err());
    assert!(handle.request_window("chat-1".to_string(), 3).is_err());
}

#[test]
fn ingest_reaches_the_sink_without_the_caller_ever_blocking_on_the_core() {
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink.clone(), None);

    for i in 0..5 {
        handle
            .ingest_frame(
                "chat-1".to_string(),
                frame(&format!("m{i}"), 1000 + i),
                VibeFfiSource::ChatTopic,
                1000 + i,
            )
            .expect("submit accepted");
    }
    handle.flush(2000).expect("flush accepted");

    assert!(
        sink.wait_until(|| sink.deltas.load(Ordering::SeqCst) > 0),
        "expected at least one delta, got {}",
        sink.deltas.load(Ordering::SeqCst)
    );
    handle.shutdown();
}

#[test]
fn a_window_request_for_an_unknown_chat_reports_an_error_and_keeps_working() {
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink.clone(), None);

    handle
        .request_window("never-seen".to_string(), 1)
        .expect("submit accepted");
    assert!(
        sink.wait_until(|| !sink.errors.lock().unwrap().is_empty()),
        "expected an async error for an unknown chat"
    );

    // The worker must still be alive: an unknown chat is a caller mistake, not a
    // fatal condition.
    handle
        .ingest_frame(
            "chat-1".to_string(),
            frame("m1", 10),
            VibeFfiSource::ChatTopic,
            10,
        )
        .expect("worker still accepting");
    handle.flush(20).expect("worker still accepting");
    assert!(sink.wait_until(|| sink.deltas.load(Ordering::SeqCst) > 0));
    handle.shutdown();
}

/// A sink that calls straight back into the handle from inside `on_delta`.
struct ReentrantSink {
    handle: OnceLock<Arc<VibeCoreHandle>>,
    reentered: AtomicBool,
    depth: AtomicUsize,
}

impl VibeDeltaSink for ReentrantSink {
    fn on_delta(&self, _delta: VibeFfiDelta) {
        // Re-enter exactly once, so the test terminates instead of recursing.
        if self.depth.fetch_add(1, Ordering::SeqCst) == 0 {
            if let Some(handle) = self.handle.get() {
                // If the boundary held a lock across this callback, this would
                // deadlock instead of enqueueing.
                let _ = handle.flush(9_999);
                self.reentered.store(true, Ordering::SeqCst);
            }
        }
    }
    fn on_window(&self, _window: VibeFfiWindow) {}
    fn on_error(&self, _message: String) {}
}

#[test]
fn reentrant_sink_callback_does_not_deadlock() {
    // The stated FFI rule is "never hold the core lock across a callback into
    // platform code". This proves it: the reducer is owned by the worker thread
    // and the command queue is never held across a sink call, so re-entering
    // from inside a callback enqueues rather than blocks.
    let sink = Arc::new(ReentrantSink {
        handle: OnceLock::new(),
        reentered: AtomicBool::new(false),
        depth: AtomicUsize::new(0),
    });
    let handle = VibeCoreHandle::new(config(), sink.clone(), None);
    sink.handle.set(handle.clone()).ok();

    handle
        .ingest_frame(
            "chat-1".to_string(),
            frame("m1", 1),
            VibeFfiSource::ChatTopic,
            1,
        )
        .expect("submit accepted");
    handle.flush(2).expect("flush accepted");

    let deadline = std::time::Instant::now() + WAIT;
    while !sink.reentered.load(Ordering::SeqCst) && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        sink.reentered.load(Ordering::SeqCst),
        "re-entrant callback never completed — the boundary deadlocked"
    );
    handle.shutdown();
}

/// A sink whose first callback panics.
struct PanickingSink {
    panicked_once: AtomicBool,
    deltas_after_panic: AtomicUsize,
    errors: AtomicUsize,
}

impl VibeDeltaSink for PanickingSink {
    fn on_delta(&self, _delta: VibeFfiDelta) {
        // `assert!` rather than `if … { panic!() }` to satisfy
        // `clippy::manual_assert`. The panic is the point of this sink.
        assert!(
            self.panicked_once.swap(true, Ordering::SeqCst),
            "deliberate test panic inside a sink callback"
        );
        self.deltas_after_panic.fetch_add(1, Ordering::SeqCst);
    }
    fn on_window(&self, _window: VibeFfiWindow) {}
    fn on_error(&self, _message: String) {
        self.errors.fetch_add(1, Ordering::SeqCst);
    }
}

#[test]
fn a_panic_in_a_callback_is_contained_and_the_worker_survives() {
    // This is the property that lets the core be linked into a shipping app at
    // all: `panic = "unwind"` plus `catch_unwind` means a panic degrades to
    // "this chat falls back to Swift", never a process abort. If the worker died
    // here, every other chat would be stranded with no error and no recovery.
    let sink = Arc::new(PanickingSink {
        panicked_once: AtomicBool::new(false),
        deltas_after_panic: AtomicUsize::new(0),
        errors: AtomicUsize::new(0),
    });
    let handle = VibeCoreHandle::new(config(), sink.clone(), None);

    handle
        .ingest_frame(
            "chat-1".to_string(),
            frame("m1", 1),
            VibeFfiSource::ChatTopic,
            1,
        )
        .expect("submit accepted");
    handle.flush(2).expect("flush accepted");

    let deadline = std::time::Instant::now() + WAIT;
    while !sink.panicked_once.load(Ordering::SeqCst) && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        sink.panicked_once.load(Ordering::SeqCst),
        "sink never panicked"
    );

    // The worker must still accept and process work afterwards.
    handle
        .ingest_frame(
            "chat-1".to_string(),
            frame("m2", 3),
            VibeFfiSource::ChatTopic,
            3,
        )
        .expect("worker survived the panic");
    handle.flush(4).expect("worker survived the panic");

    let deadline = std::time::Instant::now() + WAIT;
    while sink.deltas_after_panic.load(Ordering::SeqCst) == 0
        && std::time::Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(
        sink.deltas_after_panic.load(Ordering::SeqCst) > 0,
        "worker died on the panic instead of containing it"
    );
    handle.shutdown();
}

#[test]
fn a_queued_backlog_still_shuts_down() {
    // Shutdown must not wait for an arbitrarily long queue to drain, and must
    // not hang if the worker is mid-command.
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink, None);

    for i in 0..500 {
        let _ = handle.ingest_frame(
            "chat-1".to_string(),
            frame(&format!("m{i}"), i),
            VibeFfiSource::ChatTopic,
            i,
        );
    }
    handle.shutdown();
    assert!(handle.is_shut_down());
}

#[test]
fn suspend_flushes_without_tearing_the_worker_down() {
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink.clone(), None);

    handle
        .ingest_frame(
            "chat-1".to_string(),
            frame("m1", 1),
            VibeFfiSource::ChatTopic,
            1,
        )
        .expect("submit accepted");
    handle.suspend().expect("suspend accepted");
    assert!(sink.wait_until(|| sink.deltas.load(Ordering::SeqCst) > 0));

    // Still usable after suspend — iOS resumes into the same handle.
    assert!(!handle.is_shut_down());
    handle
        .ingest_frame(
            "chat-1".to_string(),
            frame("m2", 2),
            VibeFfiSource::ChatTopic,
            2,
        )
        .expect("usable after suspend");
    handle.shutdown();
}

#[test]
fn a_malformed_frame_is_dropped_without_killing_the_worker() {
    let sink = Arc::new(CountingSink::default());
    let handle = VibeCoreHandle::new(config(), sink.clone(), None);

    for bad in [
        b"".to_vec(),
        b"not json".to_vec(),
        b"{".to_vec(),
        b"[]".to_vec(),
        b"{\"id\":null}".to_vec(),
        vec![0xFF, 0xFE, 0x00],
    ] {
        handle
            .ingest_frame("chat-1".to_string(), bad, VibeFfiSource::ChatTopic, 1)
            .expect("submit accepted");
    }
    handle.flush(2).expect("flush accepted");

    // A good frame afterwards must still land.
    handle
        .ingest_frame(
            "chat-1".to_string(),
            frame("good", 5),
            VibeFfiSource::ChatTopic,
            5,
        )
        .expect("worker alive");
    handle.flush(6).expect("worker alive");
    assert!(sink.wait_until(|| sink.deltas.load(Ordering::SeqCst) > 0));
    handle.shutdown();
}
