//! Deterministic replay, generation fencing, and the mutation semantics that
//! have historically produced user-visible bugs in this app.

mod common;

use common::{
    bounded_reducer, drive, event_from, reducer, reducer_for, text_event, unbounded_reducer,
    window_ids, CHAT, ME, PEER, T0,
};

use vibe_core::delta::apply_ops;
use vibe_core::fixtures::{self, VibeFixtureKind};
use vibe_core::secret::VibeOpaqueBlob;
use vibe_core::{
    VibeChatClass, VibeCoreEventV1, VibeDisplayStatus, VibeEventBody, VibeEventSource,
    VibeLocalStatus, VibeMessageBody, VibeMessageFlags, VibeReceiptKind, VibeTimelineAnchor,
    VibeTimelineDeltaBodyV1, VibeTimelineOpV1, VibeTimelineReducer,
};

// ---------------------------------------------------------------------------
// Determinism
// ---------------------------------------------------------------------------

#[test]
fn the_same_event_stream_produces_identical_deltas() {
    fn run() -> Vec<String> {
        let mut r = reducer();
        let mut log = Vec::new();
        for (i, event) in fixtures::conversation(CHAT, 99, 400, 1_000)
            .into_iter()
            .enumerate()
        {
            r.ingest(event);
            for delta in r.poll_deltas(1_000 + i as i64) {
                log.push(format!(
                    "{}:{}->{}:{}",
                    delta.chat_id,
                    delta.base_generation,
                    delta.generation,
                    delta
                        .ops()
                        .iter()
                        .map(VibeTimelineOpV1::kind_label)
                        .collect::<Vec<_>>()
                        .join(",")
                ));
            }
        }
        log
    }

    let a = run();
    let b = run();
    assert!(!a.is_empty());
    assert_eq!(a, b, "replay must be deterministic");
}

#[test]
fn ingest_order_does_not_change_the_reduction() {
    let events: Vec<(&str, i64)> = vec![
        ("m3", T0 + 300),
        ("m1", T0 + 100),
        ("m2", T0 + 200),
        ("m4", T0 + 400),
    ];

    let mut forward = reducer();
    drive(
        &mut forward,
        events
            .iter()
            .map(|(id, ts)| text_event(id, *ts, PEER, "x"))
            .collect(),
        10_000,
    );

    let mut reverse = reducer();
    drive(
        &mut reverse,
        events
            .iter()
            .rev()
            .map(|(id, ts)| text_event(id, *ts, PEER, "x"))
            .collect(),
        10_000,
    );

    assert_eq!(window_ids(&forward), ["m1", "m2", "m3", "m4"]);
    assert_eq!(window_ids(&forward), window_ids(&reverse));
}

#[test]
fn re_ingesting_the_same_frame_emits_nothing() {
    let mut r = reducer();
    r.ingest(text_event("m1", T0 + 100, PEER, "hello"));
    let first = r.flush(1_000);
    assert_eq!(first.len(), 1);
    let generation = r.generation(CHAT).unwrap();

    for _ in 0..20 {
        r.ingest(text_event("m1", T0 + 100, PEER, "hello"));
    }
    let replay = r.flush(2_000);
    assert!(replay.is_empty(), "idempotent replay must emit no delta");
    assert_eq!(
        r.generation(CHAT).unwrap(),
        generation,
        "generation must not move on a no-op"
    );
}

// ---------------------------------------------------------------------------
// Generation fencing
// ---------------------------------------------------------------------------

#[test]
fn generations_are_contiguous_and_a_gap_recovers_through_reset() {
    let mut r = reducer();
    let mut consumer_generation = 0u64;
    let mut consumer_window = Vec::new();

    for i in 0..40 {
        r.ingest(text_event(&format!("m{i:03}"), T0 + i, PEER, "x"));
        for delta in r.flush(T0 + 2_000 + i) {
            assert_eq!(
                delta.base_generation, consumer_generation,
                "a well-behaved consumer never sees a gap"
            );
            match &delta.body {
                VibeTimelineDeltaBodyV1::Ops(ops) => {
                    apply_ops(&mut consumer_window, ops).expect("ops apply");
                }
                VibeTimelineDeltaBodyV1::Reset(w) => {
                    consumer_window = w.messages.clone();
                }
            }
            consumer_generation = delta.generation;
        }
    }
    assert_eq!(consumer_window.len(), 40);

    // Now simulate a consumer that missed a delta: it must not guess.
    let stale_generation = consumer_generation - 1;
    let reset = r.resync(CHAT).expect("resync");
    assert!(reset.is_reset());
    assert!(
        reset.accepts_consumer_generation(stale_generation),
        "a reset is a full replacement and must recover any stale consumer"
    );
    assert_ne!(reset.base_generation, stale_generation.wrapping_sub(1));
    let VibeTimelineDeltaBodyV1::Reset(window) = &reset.body else {
        panic!("resync must produce a reset");
    };
    assert_eq!(window.messages.len(), 40);
    assert_eq!(window.generation, reset.generation);
    assert_eq!(r.counters().resets_emitted, 1);
}

#[test]
fn a_reset_window_is_a_full_replacement_the_consumer_can_adopt_blind() {
    let mut r = bounded_reducer();
    drive(
        &mut r,
        (0..500)
            .map(|i| text_event(&format!("m{i:04}"), T0 + i, PEER, "x"))
            .collect(),
        9_000,
    );
    let reset = r.resync(CHAT).unwrap();
    let VibeTimelineDeltaBodyV1::Reset(window) = &reset.body else {
        panic!("expected reset");
    };
    // Bounded even though the store holds 500.
    assert!(window.messages.len() <= 300);
    assert_eq!(window.bounds.total_known, 500);
    assert!(window.bounds.has_more_before);
}

// ---------------------------------------------------------------------------
// The flush barrier (C1)
// ---------------------------------------------------------------------------

#[test]
fn stream_frames_coalesce_to_one_delta_per_frame_interval() {
    let mut r = reducer();
    // 20 bridge frames inside a single 8 ms display frame.
    for i in 0..20 {
        let ack = r.ingest(event_from(
            VibeEventSource::BridgeMirror,
            &format!("stream-{i}"),
            T0,
            PEER,
            "chunk",
        ));
        assert!(
            !ack.barrier_reached,
            "a stream frame inside the interval must not force a barrier"
        );
    }
    // Still inside the interval: nothing is due.
    assert!(r.poll_deltas(T0 + 5).is_empty());
    // Past the interval: exactly one delta carrying all of it.
    let deltas = r.poll_deltas(T0 + 9);
    assert_eq!(deltas.len(), 1);
    assert!(deltas[0].ops().len() >= 20);
}

#[test]
fn a_non_stream_event_is_an_immediate_barrier() {
    let mut r = reducer();
    r.ingest(event_from(
        VibeEventSource::BridgeMirror,
        "stream-1",
        T0,
        PEER,
        "chunk",
    ));
    let ack = r.ingest(text_event("m1", T0 + 1, PEER, "real message"));
    assert!(ack.barrier_reached);
    let deltas = r.poll_deltas(T0 + 1);
    assert_eq!(
        deltas.len(),
        1,
        "the barrier flushes the coalesced stream too"
    );
}

#[test]
fn an_explicit_flush_event_is_a_barrier() {
    let mut r = reducer();
    r.ingest(event_from(
        VibeEventSource::BridgeMirror,
        "stream-1",
        T0,
        PEER,
        "chunk",
    ));
    let ack = r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0,
        VibeEventSource::BridgeMirror,
        VibeEventBody::Flush,
    ));
    assert!(ack.barrier_reached);
    assert_eq!(r.poll_deltas(T0).len(), 1);
}

// ---------------------------------------------------------------------------
// Duplicates
// ---------------------------------------------------------------------------

#[test]
fn a_duplicate_storm_collapses_to_one_row() {
    let mut r = reducer();
    drive(&mut r, fixtures::duplicate_storm(CHAT, 50, T0), 5_000);
    let ids = window_ids(&r);
    assert_eq!(
        ids,
        ["server-1"],
        "50 copies plus a bridge mirror must render one bubble"
    );
}

#[test]
fn a_suppressed_mirror_does_not_resurrect_on_re_ingest() {
    let mut r = reducer();
    drive(&mut r, fixtures::duplicate_storm(CHAT, 4, T0), 5_000);
    assert_eq!(window_ids(&r), ["server-1"]);

    for _ in 0..5 {
        r.ingest(event_from(
            VibeEventSource::BridgeMirror,
            "bridge-1",
            T0 + 500,
            ME,
            "Continue",
        ));
    }
    r.flush(6_000);
    assert_eq!(window_ids(&r), ["server-1"]);
}

// ---------------------------------------------------------------------------
// Tombstones, edits, races
// ---------------------------------------------------------------------------

#[test]
fn a_tombstoned_message_never_comes_back() {
    let mut r = reducer();
    r.ingest(text_event("m1", T0 + 100, PEER, "gone soon"));
    r.ingest(text_event("m2", T0 + 200, PEER, "stays"));
    r.flush(1_000);

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        1_100,
        VibeEventSource::ChatTopic,
        VibeEventBody::Delete {
            message_id: "m1".into(),
            for_everyone: true,
            tombstone_ms: 1_100,
        },
    ));
    let deltas = r.flush(1_100);
    assert_eq!(deltas.len(), 1);
    assert!(matches!(
        deltas[0].ops()[0],
        VibeTimelineOpV1::Remove { index: 0, .. }
    ));

    // Re-delivery from every source must stay dead.
    for source in [
        VibeEventSource::ChatTopic,
        VibeEventSource::HistoryPage,
        VibeEventSource::StoreRestore,
        VibeEventSource::UserTopic,
    ] {
        r.ingest(event_from(source, "m1", T0 + 100, PEER, "gone soon"));
    }
    r.flush(2_000);
    assert_eq!(window_ids(&r), ["m2"]);
}

#[test]
fn an_older_edit_replayed_after_a_newer_one_is_dropped() {
    let mut r = reducer();
    r.ingest(text_event("m1", T0 + 100, PEER, "v1"));
    r.flush(1_000);

    let edit = |text: &str, at: i64| {
        VibeCoreEventV1::new(
            CHAT,
            at,
            VibeEventSource::ChatTopic,
            VibeEventBody::Edit {
                message_id: "m1".into(),
                body: VibeMessageBody::text(text),
                edited_at_ms: at,
            },
        )
    };

    r.ingest(edit("v3", 3_000));
    r.flush(3_000);
    r.ingest(edit("v2", 2_000));
    let late = r.flush(3_500);
    assert!(late.is_empty(), "a stale edit must produce no delta");
    assert_eq!(r.current_window(CHAT).unwrap().messages[0].body.text, "v3");
}

#[test]
fn an_edit_arriving_before_its_frame_matches_frame_then_edit() {
    fn run(edit_first: bool) -> vibe_core::VibeMessageSnapshotV1 {
        let mut r = reducer();
        let frame = text_event("m1", T0 + 100, PEER, "v1");
        let edit = VibeCoreEventV1::new(
            CHAT,
            T0 + 200,
            VibeEventSource::ChatTopic,
            VibeEventBody::Edit {
                message_id: "m1".into(),
                body: VibeMessageBody::text("v2"),
                edited_at_ms: T0 + 200,
            },
        );
        if edit_first {
            r.ingest(edit);
            r.ingest(frame);
        } else {
            r.ingest(frame);
            r.ingest(edit);
        }
        r.flush(T0 + 300);
        r.current_window(CHAT).unwrap().messages[0].clone()
    }

    let before = run(true);
    let after = run(false);
    assert_eq!(before, after);
    assert_eq!(before.body.text, "v2");
    assert_eq!(before.edit.unwrap().edited_at_ms, T0 + 200);
}

#[test]
fn upload_progress_arriving_before_its_frame_is_applied() {
    let mut r = reducer();
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 50,
        VibeEventSource::Local,
        VibeEventBody::UploadProgress {
            message_id: "m1".into(),
            fraction: Some(0.625),
        },
    ));
    r.ingest(text_event("m1", T0 + 100, ME, "uploading"));
    r.flush(T0 + 200);

    assert_eq!(
        r.current_window(CHAT).unwrap().messages[0].delivery.upload,
        Some(0.625)
    );
    assert_eq!(r.state_metrics(CHAT).unwrap().pending_uploads, 0);
}

#[test]
fn same_id_raw_frame_conflicts_converge_independent_of_arrival_order() {
    fn run(first: &str, second: &str) -> vibe_core::VibeMessageSnapshotV1 {
        let mut r = reducer();
        r.ingest(event_from(
            VibeEventSource::ChatTopic,
            "m1",
            T0 + 100,
            PEER,
            first,
        ));
        r.ingest(event_from(
            VibeEventSource::ChatTopic,
            "m1",
            T0 + 100,
            PEER,
            second,
        ));
        r.flush(T0 + 200);
        r.current_window(CHAT).unwrap().messages[0].clone()
    }

    assert_eq!(run("alpha", "omega"), run("omega", "alpha"));
}

#[test]
fn authoritative_live_frame_beats_store_restore_regardless_of_arrival_order() {
    fn run(live_first: bool) -> String {
        let mut r = reducer();
        let live = event_from(VibeEventSource::ChatTopic, "m1", T0 + 100, PEER, "live");
        let stored = event_from(VibeEventSource::StoreRestore, "m1", T0 + 100, PEER, "stale");
        if live_first {
            r.ingest(live);
            r.ingest(stored);
        } else {
            r.ingest(stored);
            r.ingest(live);
        }
        r.flush(T0 + 200);
        r.current_window(CHAT).unwrap().messages[0]
            .body
            .text
            .clone()
    }

    assert_eq!(run(true), "live");
    assert_eq!(run(false), "live");
}

#[test]
fn mutation_buffers_are_strictly_bounded() {
    let mut r = reducer();
    for i in 0..=vibe_core::reducer::MAX_PENDING_MUTATIONS {
        r.ingest(VibeCoreEventV1::new(
            CHAT,
            T0 + i as i64,
            VibeEventSource::ChatTopic,
            VibeEventBody::Edit {
                message_id: format!("missing-{i:04}"),
                body: VibeMessageBody::text("redacted"),
                edited_at_ms: T0 + i as i64,
            },
        ));
    }

    let metrics = r.state_metrics(CHAT).unwrap();
    assert_eq!(
        metrics.pending_edits,
        vibe_core::reducer::MAX_PENDING_MUTATIONS
    );
    assert_eq!(r.counters().pending_mutations_evicted, 1);
}

#[test]
fn delete_wins_over_a_racing_edit() {
    let mut r = reducer();
    r.ingest(text_event("m1", T0 + 100, PEER, "v1"));
    r.flush(1_000);

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        2_000,
        VibeEventSource::ChatTopic,
        VibeEventBody::Delete {
            message_id: "m1".into(),
            for_everyone: true,
            tombstone_ms: 2_000,
        },
    ));
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        2_001,
        VibeEventSource::ChatTopic,
        VibeEventBody::Edit {
            message_id: "m1".into(),
            body: VibeMessageBody::text("edited after delete"),
            edited_at_ms: 2_001,
        },
    ));
    r.flush(2_500);
    assert!(window_ids(&r).is_empty());
    assert_eq!(
        r.state_metrics(CHAT).unwrap().pending_edits,
        0,
        "a tombstone must absorb later mutations instead of retaining them"
    );
}

#[test]
fn clear_before_removes_history_and_blocks_late_re_ingest() {
    let mut r = reducer();
    drive(
        &mut r,
        (0..10)
            .map(|i| text_event(&format!("m{i}"), T0 + 100 * i, PEER, "x"))
            .collect(),
        1_000,
    );
    assert_eq!(window_ids(&r).len(), 10);

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        1_500,
        VibeEventSource::ChatTopic,
        VibeEventBody::ChatCleared {
            before_ts_ms: Some(T0 + 500),
        },
    ));
    r.flush(1_500);
    assert_eq!(window_ids(&r), ["m5", "m6", "m7", "m8", "m9"]);

    // A history page replaying the cleared range must not resurrect it.
    r.ingest(event_from(
        VibeEventSource::HistoryPage,
        "m0",
        T0,
        PEER,
        "x",
    ));
    r.flush(2_000);
    assert_eq!(window_ids(&r), ["m5", "m6", "m7", "m8", "m9"]);
}

// ---------------------------------------------------------------------------
// Id healing
// ---------------------------------------------------------------------------

#[test]
fn an_optimistic_id_heals_in_place_and_keeps_its_slot() {
    let mut r = reducer();
    r.ingest(text_event("m-before", T0 + 900, PEER, "before"));
    r.ingest(event_from(
        VibeEventSource::Optimistic,
        "local-1",
        T0 + 1_000,
        ME,
        "sending",
    ));
    r.flush(1_000);
    assert_eq!(window_ids(&r), ["m-before", "local-1"]);

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        1_100,
        VibeEventSource::ChatTopic,
        VibeEventBody::IdHealed {
            client_message_id: "local-1".into(),
            canonical_message_id: "server-1".into(),
        },
    ));
    let deltas = r.flush(1_100);
    assert_eq!(deltas.len(), 1);
    assert!(deltas[0].ops().iter().any(
        |op| matches!(op, VibeTimelineOpV1::RemapIdentity { previous_message_id, message, .. }
            if previous_message_id == "local-1" && message.message_id == "server-1")
    ));
    assert!(deltas[0].ops().iter().all(|op| !matches!(
        op,
        VibeTimelineOpV1::Remove { .. } | VibeTimelineOpV1::Insert { .. }
    )));

    let window = r.current_window(CHAT).unwrap();
    let healed = window.messages.iter().find(|m| m.message_id == "server-1");
    let healed = healed.expect("healed row present");
    assert_eq!(healed.client_message_id.as_deref(), Some("local-1"));
    assert_eq!(healed.ts_ms, T0 + 1_000, "the settle slot is preserved");
    assert_eq!(window_ids(&r), ["m-before", "server-1"]);
}

#[test]
fn an_anchor_on_a_retired_id_still_resolves() {
    let mut r = reducer();
    r.ingest(event_from(
        VibeEventSource::Optimistic,
        "local-1",
        T0 + 1_000,
        ME,
        "sending",
    ));
    r.flush(1_000);
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        1_100,
        VibeEventSource::ChatTopic,
        VibeEventBody::IdHealed {
            client_message_id: "local-1".into(),
            canonical_message_id: "server-1".into(),
        },
    ));
    r.flush(1_100);

    let window = r
        .window(
            CHAT,
            VibeTimelineAnchor::at_message("local-1", T0 + 1_000),
            1_200,
        )
        .unwrap()
        .window;
    assert_eq!(
        window.anchor_resolution,
        vibe_core::VibeAnchorResolution::ClientIdAlias
    );
}

#[test]
fn healing_onto_an_already_present_server_row_drops_the_optimistic_twin() {
    let mut r = reducer();
    r.ingest(event_from(
        VibeEventSource::Optimistic,
        "local-1",
        T0 + 1_000,
        ME,
        "hi",
    ));
    r.ingest(text_event("server-1", T0 + 1_050, ME, "hi"));
    r.flush(1_000);
    assert_eq!(window_ids(&r).len(), 2);

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        1_100,
        VibeEventSource::ChatTopic,
        VibeEventBody::IdHealed {
            client_message_id: "local-1".into(),
            canonical_message_id: "server-1".into(),
        },
    ));
    let deltas = r.flush(1_100);
    assert!(deltas
        .iter()
        .flat_map(vibe_core::VibeTimelineDeltaV1::ops)
        .all(|op| !matches!(op, VibeTimelineOpV1::RemapIdentity { .. })));
    assert_eq!(window_ids(&r), ["server-1"]);
    assert_eq!(
        r.current_window(CHAT).unwrap().messages[0]
            .client_message_id
            .as_deref(),
        Some("local-1")
    );
}

// ---------------------------------------------------------------------------
// Receipts across devices
// ---------------------------------------------------------------------------

#[test]
fn a_second_device_of_the_sender_does_not_tick_the_senders_own_message() {
    let mut r = VibeTimelineReducer::new(common::config());
    r.set_chat_profile(
        CHAT,
        vibe_core::VibeChatProfile {
            class: VibeChatClass::GroupOrChannel,
            other_member_count: 2,
            ..vibe_core::VibeChatProfile::default()
        },
    );
    r.ingest(text_event("m1", T0 + 100, ME, "mine"));
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        200,
        VibeEventSource::UserTopic,
        VibeEventBody::LocalStatus {
            message_id: "m1".into(),
            status: VibeLocalStatus::Sent,
            allow_downgrade: false,
        },
    ));
    r.flush(1_000);

    // My own other device reads it.
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        300,
        VibeEventSource::UserTopic,
        VibeEventBody::Receipt {
            message_id: "m1".into(),
            reader_user_id: ME.into(),
            kind: VibeReceiptKind::Read,
            at_ms: 300,
        },
    ));
    r.flush(1_100);
    assert_eq!(
        r.current_window(CHAT).unwrap().messages[0].delivery.display,
        VibeDisplayStatus::Sent
    );

    // Both real members read it.
    for reader in ["a", "b"] {
        r.ingest(VibeCoreEventV1::new(
            CHAT,
            400,
            VibeEventSource::ChatTopic,
            VibeEventBody::Receipt {
                message_id: "m1".into(),
                reader_user_id: reader.into(),
                kind: VibeReceiptKind::Read,
                at_ms: 400,
            },
        ));
    }
    r.flush(1_200);
    assert_eq!(
        r.current_window(CHAT).unwrap().messages[0].delivery.display,
        VibeDisplayStatus::Read
    );
}

#[test]
fn the_read_cursor_drives_unread_and_is_monotone() {
    let mut r = reducer();
    drive(
        &mut r,
        (0..10)
            .map(|i| text_event(&format!("m{i}"), T0 + 100 + i, PEER, "x"))
            .collect(),
        1_000,
    );
    assert_eq!(r.current_window(CHAT).unwrap().unread.count, 10);

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        1_100,
        VibeEventSource::UserTopic,
        VibeEventBody::ReadCursor {
            up_to_ts_ms: T0 + 104,
            up_to_message_id: "m4".into(),
        },
    ));
    let deltas = r.flush(1_100);
    assert_eq!(deltas.len(), 1, "unread-only state must be emitted");
    assert!(deltas[0].ops().is_empty());
    assert_eq!(deltas[0].unread.count, 5);
    let unread = r.current_window(CHAT).unwrap().unread;
    assert_eq!(unread.count, 5);
    assert_eq!(unread.first_unread_id.as_deref(), Some("m5"));

    // A reconnect replaying an older cursor must not un-read anything.
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        1_200,
        VibeEventSource::UserTopic,
        VibeEventBody::ReadCursor {
            up_to_ts_ms: T0 + 100,
            up_to_message_id: "m0".into(),
        },
    ));
    r.flush(1_200);
    assert_eq!(r.current_window(CHAT).unwrap().unread.count, 5);
}

// ---------------------------------------------------------------------------
// Saved Messages
// ---------------------------------------------------------------------------

#[test]
fn saved_messages_uses_the_original_id_and_does_not_duplicate_on_restore() {
    let mut r = reducer_for(VibeChatClass::SavedMessages);
    let frame = |ts: i64| {
        format!(
            r#"{{"id":"copy-{ts}","original_message_id":"origin-1","chat_id":"{CHAT}","sender_id":"{ME}","timestamp":{ts},"encrypted_content":"{{\"text\":\"note to self\"}}"}}"#
        )
        .into_bytes()
    };

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 100,
        VibeEventSource::SavedMessages,
        VibeEventBody::RawFrame {
            json: frame(T0 + 100),
        },
    ));
    // The same logical row arrives again from the restore path under a new copy id.
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 100,
        VibeEventSource::StoreRestore,
        VibeEventBody::RawFrame {
            json: frame(T0 + 100),
        },
    ));
    r.flush(1_000);

    assert_eq!(
        window_ids(&r),
        ["origin-1"],
        "the dual-id row must not mint a second generation"
    );
}

// ---------------------------------------------------------------------------
// Agents
// ---------------------------------------------------------------------------

#[test]
fn agent_sealed_payloads_round_trip_without_being_opened() {
    let mut r = reducer_for(VibeChatClass::AgentDirectMessage);
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 100,
        VibeEventSource::BridgeMirror,
        VibeEventBody::RawFrame {
            json: fixtures::frame(
                CHAT,
                "bridge-1",
                T0 + 100,
                "claude",
                VibeFixtureKind::AgentTurn,
                "done",
            ),
        },
    ));
    r.flush(1_000);

    let sealed = VibeOpaqueBlob::new(b"arte1.aaa.bbb.ccc".to_vec());
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 200,
        VibeEventSource::BridgeMirror,
        VibeEventBody::OpaqueAgent {
            message_id: "bridge-1".into(),
            kind: "claude".into(),
            sealed,
        },
    ));
    r.flush(1_100);

    let window = r.current_window(CHAT).unwrap();
    let agent = window.messages[0].agent.as_ref().unwrap();
    assert_eq!(
        agent.sealed.as_ref().unwrap().as_bytes(),
        b"arte1.aaa.bbb.ccc"
    );
    assert_eq!(r.counters().decrypt_failures, 0);
}

#[test]
fn sealed_agent_payload_arriving_before_its_frame_is_applied_opaquely() {
    let mut r = reducer_for(VibeChatClass::AgentDirectMessage);
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 50,
        VibeEventSource::BridgeMirror,
        VibeEventBody::OpaqueAgent {
            message_id: "bridge-1".into(),
            kind: "claude".into(),
            sealed: VibeOpaqueBlob::new(b"arte1.before.frame.tag".to_vec()),
        },
    ));
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 100,
        VibeEventSource::BridgeMirror,
        VibeEventBody::RawFrame {
            json: fixtures::frame(
                CHAT,
                "bridge-1",
                T0 + 100,
                "claude",
                VibeFixtureKind::AgentTurn,
                "done",
            ),
        },
    ));
    r.flush(T0 + 200);

    let message = &r.current_window(CHAT).unwrap().messages[0];
    assert_eq!(
        message
            .agent
            .as_ref()
            .and_then(|agent| agent.sealed.as_ref())
            .unwrap()
            .as_bytes(),
        b"arte1.before.frame.tag"
    );
    assert_eq!(r.state_metrics(CHAT).unwrap().pending_agents, 0);
}

#[test]
fn agent_dms_are_never_persistable_and_transient_ids_are_filtered() {
    let mut agent = reducer_for(VibeChatClass::AgentDirectMessage);
    agent.ingest(text_event("m1", T0 + 100, PEER, "x"));
    agent.flush(1_000);
    assert!(
        agent.persistable_messages(CHAT).is_empty(),
        "agent DMs are volatile-per-session"
    );

    let mut dm = reducer();
    dm.ingest(text_event("server-1", T0 + 100, PEER, "x"));
    dm.ingest(event_from(
        VibeEventSource::BridgeMirror,
        "stream-1",
        T0 + 200,
        PEER,
        "chunk",
    ));
    dm.flush(1_000);
    let persistable: Vec<&str> = dm
        .persistable_messages(CHAT)
        .iter()
        .map(|m| m.message_id.as_str())
        .collect();
    assert_eq!(persistable, ["server-1"]);
}

#[test]
fn an_orphaned_streaming_turn_settles_instead_of_shimmering_forever() {
    let mut r = reducer_for(VibeChatClass::AgentDirectMessage);
    let json = br#"{"id":"agent-1","chat_id":"chat-1","sender_id":"claude","timestamp":0,"isAgentMessage":true,"agentUserId":"CLAUDE","isStreaming":true,"plainContent":"half a reply"}"#.to_vec();
    r.ingest(VibeCoreEventV1::new(
        CHAT,
        0,
        VibeEventSource::HistoryPage,
        VibeEventBody::RawFrame { json },
    ));
    r.flush(0);
    assert!(r.current_window(CHAT).unwrap().messages[0]
        .flags
        .contains(VibeMessageFlags::STREAMING));

    // Four minutes later with no live row: the run is an orphan.
    r.set_chat_profile(
        CHAT,
        vibe_core::VibeChatProfile {
            class: VibeChatClass::AgentDirectMessage,
            muted: true,
            ..vibe_core::VibeChatProfile::default()
        },
    );
    r.flush(4 * 60 * 1_000);
    assert!(!r.current_window(CHAT).unwrap().messages[0]
        .flags
        .contains(VibeMessageFlags::STREAMING));
    assert_eq!(r.counters().stale_streams_settled, 1);
}

#[test]
fn a_terminal_agent_frame_retires_the_live_row_marker() {
    let mut r = reducer_for(VibeChatClass::AgentDirectMessage);
    let streaming = br#"{"id":"agent-1","chat_id":"chat-1","sender_id":"claude","timestamp":1785000000000,"isAgentMessage":true,"agentUserId":"CLAUDE","isStreaming":true,"plainContent":"half"}"#.to_vec();
    let terminal = br#"{"id":"agent-1","chat_id":"chat-1","sender_id":"claude","timestamp":1785000000000,"isAgentMessage":true,"agentUserId":"CLAUDE","isStreaming":false,"plainContent":"done"}"#.to_vec();

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0,
        VibeEventSource::BridgeMirror,
        VibeEventBody::RawFrame { json: streaming },
    ));
    r.flush(T0);
    assert_eq!(r.state_metrics(CHAT).unwrap().live_rows, 1);

    r.ingest(VibeCoreEventV1::new(
        CHAT,
        T0 + 1,
        VibeEventSource::ChatTopic,
        VibeEventBody::RawFrame { json: terminal },
    ));
    r.flush(T0 + 1);
    assert_eq!(r.state_metrics(CHAT).unwrap().live_rows, 0);
    assert!(!r.current_window(CHAT).unwrap().messages[0]
        .flags
        .contains(VibeMessageFlags::STREAMING));
}

// ---------------------------------------------------------------------------
// Windowing
// ---------------------------------------------------------------------------

/// What "unbounded" means, for the callers that ask for it: the window is the store,
/// `page_before` reports no movement, and a new arrival extends the same window rather
/// than sliding it. Not the shipping default — see `VibeWindowPolicy::default`.
#[test]
fn an_unbounded_reducer_mounts_the_whole_conversation_and_never_pages() {
    let mut r = unbounded_reducer();
    drive(
        &mut r,
        (0..1_000)
            .map(|i| text_event(&format!("m{i:04}"), T0 + i, PEER, "x"))
            .collect(),
        9_000,
    );
    let window = r.current_window(CHAT).unwrap();
    assert_eq!(window.messages.len(), 1_000);
    assert_eq!(window.messages.first().unwrap().message_id, "m0000");
    assert_eq!(window.messages.last().unwrap().message_id, "m0999");
    assert!(!window.bounds.has_more_before);
    assert!(!window.bounds.has_more_after);

    // Nothing left to page to, in either direction.
    assert!(r.page_before(CHAT, 9_100).unwrap().is_none());
    assert!(r.page_after(CHAT, 9_200).unwrap().is_none());

    // A new message extends the window; it does not push the oldest one out.
    drive(&mut r, vec![text_event("m1000", T0 + 1_000, PEER, "x")], 9_300);
    let grown = r.current_window(CHAT).unwrap();
    assert_eq!(grown.messages.len(), 1_001);
    assert_eq!(grown.messages.first().unwrap().message_id, "m0000");
    assert_eq!(grown.messages.last().unwrap().message_id, "m1000");
}

#[test]
fn scroll_back_prepends_and_never_deletes() {
    let mut r = bounded_reducer();
    drive(
        &mut r,
        (0..1_000)
            .map(|i| text_event(&format!("m{i:04}"), T0 + i, PEER, "x"))
            .collect(),
        9_000,
    );
    assert_eq!(r.current_window(CHAT).unwrap().messages.len(), 200);

    let mut saw_evict_tail = false;
    for _ in 0..6 {
        if let Some(delta) = r.page_before(CHAT, 9_100).unwrap() {
            assert!(
                delta
                    .ops()
                    .iter()
                    .all(|op| !matches!(op, VibeTimelineOpV1::Remove { .. })),
                "a scroll-back must never emit a delete"
            );
            saw_evict_tail |= delta
                .ops()
                .iter()
                .any(|op| matches!(op, VibeTimelineOpV1::EvictTail { .. }));
            assert!(delta.bounds.window_len <= 300);
        }
    }
    assert!(
        saw_evict_tail,
        "paging past the ceiling must evict the tail"
    );
}

#[test]
fn jump_to_message_then_return_to_the_bottom() {
    let mut r = bounded_reducer();
    drive(
        &mut r,
        (0..2_000)
            .map(|i| text_event(&format!("m{i:04}"), T0 + i, PEER, "x"))
            .collect(),
        9_000,
    );

    let before_jump_generation = r.generation(CHAT).unwrap();
    let jump = r
        .window(
            CHAT,
            VibeTimelineAnchor::at_message("m0500", T0 + 500),
            9_100,
        )
        .unwrap();
    let jump_delta = jump
        .delta
        .as_ref()
        .expect("moving the committed window must return its delta");
    assert_eq!(jump_delta.base_generation, before_jump_generation);
    assert_eq!(jump_delta.generation, jump.window.generation);
    let window = jump.window;
    assert_eq!(
        window.anchor_resolution,
        vibe_core::VibeAnchorResolution::ExactId
    );
    assert!(window.messages.iter().any(|m| m.message_id == "m0500"));
    assert!(window.messages.len() <= 300);

    let back_result = r.window(CHAT, VibeTimelineAnchor::bottom(), 9_200).unwrap();
    let back_delta = back_result
        .delta
        .as_ref()
        .expect("returning to the bottom must return its delta");
    assert_eq!(back_delta.base_generation, window.generation);
    assert_eq!(back_delta.generation, back_result.window.generation);
    let back = back_result.window;
    assert_eq!(back.messages.last().unwrap().message_id, "m1999");
    assert!(!back.bounds.has_more_after);
}

#[test]
fn a_store_change_outside_the_window_emits_bounds_without_row_ops() {
    let mut r = bounded_reducer();
    drive(
        &mut r,
        (0..1_000)
            .map(|i| text_event(&format!("m{i:04}"), T0 + i, PEER, "x"))
            .collect(),
        T0 + 2_000,
    );
    let anchored = r
        .window(
            CHAT,
            VibeTimelineAnchor::at_message("m0500", T0 + 500),
            T0 + 2_100,
        )
        .unwrap();
    assert!(anchored.delta.is_some());
    let before = anchored.window;

    r.ingest(text_event("m-before-all", T0 - 1, PEER, "outside"));
    let deltas = r.flush(T0 + 2_200);
    assert_eq!(deltas.len(), 1);
    assert!(
        deltas[0].ops().is_empty(),
        "rows outside the mounted window must not cause fake list mutations"
    );
    assert_eq!(deltas[0].bounds.total_known, before.bounds.total_known + 1);
    assert_eq!(deltas[0].generation, before.generation + 1);
}
