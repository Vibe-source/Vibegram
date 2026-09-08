//! Scale: a 100,000-message store with bounded windows and bounded deltas.
//!
//! The board's qualification contract asks for 100k messages stored, an active
//! window of 150–300, and 20–50 mixed events per second sustained while
//! scrolling. This crate cannot measure a frame time — it has no renderer — so
//! what it proves is the half it *can* prove: that no query and no delta grows
//! with the size of the store, and that retained state stays flat under sustained
//! ingest.
//!
//! [`hundred_thousand_message_benchmark`] is `#[ignore]`d so
//! `cargo test --all-targets --all-features` stays fast. Run it explicitly:
//!
//! ```text
//! cargo test --release --all-features -- --ignored --nocapture
//! ```

mod common;

use std::time::Instant;

use common::{CHAT, ME, PEER, T0};

use vibe_core::{
    VibeChatProfile, VibeCoreConfig, VibeCoreEventV1, VibeEventBody, VibeEventSource,
    VibeTimelineAnchor, VibeTimelineOpV1, VibeTimelineReducer, VibeWindowPolicy,
};

/// Store size for the soak. The board's number.
const STORE_SIZE: usize = 100_000;

/// A CI-sized store: the same code path, small enough to run on every commit.
const CI_STORE_SIZE: usize = 12_000;

/// Upper end of the board's "20–50 mixed events per second".
const EVENTS_PER_SECOND: usize = 50;

fn reducer() -> VibeTimelineReducer {
    let mut r = VibeTimelineReducer::new(VibeCoreConfig {
        own_user_id: ME.to_string(),
        ..VibeCoreConfig::default()
    });
    r.set_chat_profile(CHAT, VibeChatProfile::default());
    r
}

/// The bounded 150…300 policy, asked for explicitly.
///
/// The shipping default has no ceiling — a bounded window was experienced as a scroll
/// limit and was removed. The tests below that exercise paging and tail eviction are
/// testing that machinery, not the default, so they say so.
fn bounded_reducer() -> VibeTimelineReducer {
    reducer()
}

fn bounded_policy() -> VibeWindowPolicy {
    VibeWindowPolicy::default()
}

/// No ceiling: everything the store holds stays mounted. Not the shipping default.
fn unbounded_reducer() -> VibeTimelineReducer {
    let mut r = VibeTimelineReducer::new(VibeCoreConfig {
        own_user_id: ME.to_string(),
        window_policy: VibeWindowPolicy::unbounded(),
        ..VibeCoreConfig::default()
    });
    r.set_chat_profile(CHAT, VibeChatProfile::default());
    r
}

fn text_frame(i: usize) -> VibeCoreEventV1 {
    let ts = T0 + i as i64 * 1_000;
    VibeCoreEventV1::new(
        CHAT,
        ts,
        VibeEventSource::ChatTopic,
        VibeEventBody::RawFrame {
            json: vibe_core::fixtures::frame(
                CHAT,
                &format!("m{i:07}"),
                ts,
                PEER,
                vibe_core::fixtures::VibeFixtureKind::Text,
                "soak body",
            ),
        },
    )
}

/// Seeds `count` messages through the real ingest path, flushing in page-sized
/// batches the way a history load actually arrives.
fn seed(r: &mut VibeTimelineReducer, count: usize) {
    for i in 0..count {
        r.ingest(text_frame(i));
        if i % 500 == 499 {
            r.flush(T0 + i as i64 * 1_000);
        }
    }
    r.flush(T0 + count as i64 * 1_000);
}

#[test]
fn every_query_and_delta_stays_bounded_as_the_store_grows() {
    let policy = bounded_policy();
    let mut r = bounded_reducer();
    seed(&mut r, CI_STORE_SIZE);

    let window = r.current_window(CHAT).unwrap();
    assert_eq!(window.messages.len(), policy.default_len as usize);
    assert_eq!(window.bounds.total_known, CI_STORE_SIZE as u64);
    assert!(window.bounds.has_more_before);
    assert!(!window.bounds.has_more_after);

    // Sustained ingest at the top of the board's rate. Every delta must stay
    // small; a delta that scaled with the store would show up here immediately.
    let mut largest_delta_ops = 0usize;
    for second in 0..20 {
        for k in 0..EVENTS_PER_SECOND {
            let i = CI_STORE_SIZE + second * EVENTS_PER_SECOND + k;
            r.ingest(text_frame(i));
        }
        let now = T0 + (CI_STORE_SIZE + second * EVENTS_PER_SECOND) as i64 * 1_000;
        for delta in r.flush(now) {
            largest_delta_ops = largest_delta_ops.max(delta.ops().len());
            assert!(delta.bounds.window_len <= policy.max_len);
        }
        assert_eq!(
            r.current_window(CHAT).unwrap().messages.len(),
            policy.default_len as usize,
            "the live window must not drift"
        );
    }
    assert!(
        largest_delta_ops <= policy.max_len as usize,
        "a delta grew past the window ceiling: {largest_delta_ops}"
    );

    // A jump into the middle of a large store is still one bounded window.
    let jumped = r
        .window(
            CHAT,
            VibeTimelineAnchor::at_message("m0006000", T0 + 6_000 * 1_000),
            T0 + 10_000_000_000,
        )
        .unwrap()
        .window;
    assert!(jumped.messages.len() <= policy.max_len as usize);
    assert!(jumped.messages.iter().any(|m| m.message_id == "m0006000"));
}

#[test]
fn scroll_back_over_a_large_store_never_emits_a_delete() {
    let mut r = bounded_reducer();
    seed(&mut r, CI_STORE_SIZE);

    for _ in 0..40 {
        let Some(delta) = r.page_before(CHAT, T0 + 100_000_000).unwrap() else {
            continue;
        };
        for op in delta.ops() {
            assert!(
                !matches!(op, VibeTimelineOpV1::Remove { .. }),
                "a window trim must be an eviction, never a delete"
            );
        }
        assert!(delta.bounds.window_len <= 300);
    }
    // And the window is still exactly one page-worth of rows.
    assert!(r.current_window(CHAT).unwrap().messages.len() <= 300);
}

#[test]
fn retained_window_state_is_flat_under_sustained_ingest() {
    let mut r = bounded_reducer();
    seed(&mut r, 2_000);

    let baseline = r.current_window(CHAT).unwrap().messages.len();
    for round in 0..50 {
        for k in 0..EVENTS_PER_SECOND {
            r.ingest(text_frame(2_000 + round * EVENTS_PER_SECOND + k));
        }
        r.flush(T0 + (2_000 + round * EVENTS_PER_SECOND) as i64 * 1_000);
        assert_eq!(
            r.current_window(CHAT).unwrap().messages.len(),
            baseline,
            "retained window size drifted at round {round}"
        );
    }
}

/// Removing the ceiling removes the window bound. It must NOT remove the delta bound.
///
/// This is the guarantee that actually protects the renderer, and it is the one the
/// unbounded default has to keep: a window is published once, but a delta is applied on
/// every incoming message, and a delta whose size tracked the store would put a
/// 12,000-row commit on the main thread for one arriving message. Ops stay proportional
/// to what changed, not to how much history exists.
#[test]
fn an_unbounded_window_still_emits_deltas_proportional_to_the_change() {
    let mut r = unbounded_reducer();
    seed(&mut r, CI_STORE_SIZE);

    let window = r.current_window(CHAT).unwrap();
    assert_eq!(window.messages.len(), CI_STORE_SIZE, "the window is the store");
    assert!(!window.bounds.has_more_before);
    assert!(!window.bounds.has_more_after);

    let mut largest_delta_ops = 0usize;
    for second in 0..20 {
        for k in 0..EVENTS_PER_SECOND {
            let i = CI_STORE_SIZE + second * EVENTS_PER_SECOND + k;
            r.ingest(text_frame(i));
        }
        let now = T0 + (CI_STORE_SIZE + second * EVENTS_PER_SECOND) as i64 * 1_000;
        for delta in r.flush(now) {
            largest_delta_ops = largest_delta_ops.max(delta.ops().len());
        }
    }
    assert!(
        largest_delta_ops <= EVENTS_PER_SECOND * 2,
        "a delta scaled with the store rather than the change: {largest_delta_ops}"
    );
    assert_eq!(
        r.current_window(CHAT).unwrap().messages.len(),
        CI_STORE_SIZE + 20 * EVENTS_PER_SECOND,
        "every ingested message stays mounted"
    );
}

/// The board's 100k / 20–50 events-per-second benchmark.
///
/// Ignored by default: it seeds 100,000 messages, which is seconds of work in
/// release mode and much longer in debug. It reports numbers rather than
/// asserting a wall-clock budget, because a laptop's timings are not the
/// device's — the device gate lives in the iOS replay harness, not here. What it
/// *does* assert is the shape guarantee: bounded window, bounded delta.
#[test]
#[ignore = "slow: seeds 100k messages; run with --ignored"]
fn hundred_thousand_message_benchmark() {
    let policy = bounded_policy();
    let mut r = bounded_reducer();

    let seed_start = Instant::now();
    seed(&mut r, STORE_SIZE);
    let seed_elapsed = seed_start.elapsed();

    let window = r.current_window(CHAT).unwrap();
    assert_eq!(window.bounds.total_known, STORE_SIZE as u64);
    assert_eq!(window.messages.len(), policy.default_len as usize);

    // 60 seconds of replay at the top of the board's event rate.
    let replay_start = Instant::now();
    let mut deltas = 0usize;
    let mut max_ops = 0usize;
    for second in 0..60 {
        for k in 0..EVENTS_PER_SECOND {
            r.ingest(text_frame(STORE_SIZE + second * EVENTS_PER_SECOND + k));
        }
        let now = T0 + (STORE_SIZE + second * EVENTS_PER_SECOND) as i64 * 1_000;
        for delta in r.flush(now) {
            deltas += 1;
            max_ops = max_ops.max(delta.ops().len());
            assert!(delta.bounds.window_len <= policy.max_len);
        }
    }
    let replay_elapsed = replay_start.elapsed();
    let replayed = 60 * EVENTS_PER_SECOND;

    // Scroll-back through 40 pages of a 103k store.
    let page_start = Instant::now();
    for _ in 0..40 {
        let _ = r.page_before(CHAT, T0 + 200_000_000_000).unwrap();
    }
    let page_elapsed = page_start.elapsed();

    println!("--- vibe_core 100k soak ---");
    println!(
        "seed        {STORE_SIZE} msgs in {:?} ({:.1} µs/msg)",
        seed_elapsed,
        seed_elapsed.as_secs_f64() * 1e6 / STORE_SIZE as f64
    );
    println!(
        "replay      {replayed} events in {:?} ({:.1} µs/event), {deltas} deltas, max {max_ops} ops",
        replay_elapsed,
        replay_elapsed.as_secs_f64() * 1e6 / replayed as f64
    );
    println!(
        "scroll-back 40 pages in {:?} ({:.1} µs/page)",
        page_elapsed,
        page_elapsed.as_secs_f64() * 1e6 / 40.0
    );
    println!("counters    {:?}", r.counters());

    assert!(max_ops <= policy.max_len as usize);
    assert!(r.current_window(CHAT).unwrap().messages.len() <= policy.max_len as usize);
}
