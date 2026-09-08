//! Property tests.
//!
//! Each property here maps to a bug class that has actually shipped in this app,
//! which is why they are properties and not examples: the failure modes were all
//! "some interleaving I did not think of".

mod common;

use std::collections::HashMap;

use proptest::prelude::*;

use vibe_core::delta::{apply_ops, diff_windows};
use vibe_core::receipts::{VibeReceiptPolicy, VibeReceiptState};
use vibe_core::window::{bounds_for, resolve_anchor, VibeWindowCursor, VibeWindowPolicy};
use vibe_core::{
    VibeAnchorResolution, VibeChatProfile, VibeCoreConfig, VibeCoreEventV1, VibeDisplayStatus,
    VibeEventBody, VibeEventSource, VibeMessageSnapshotV1, VibeReceiptKind, VibeTimelineAnchor,
    VibeTimelineReducer,
};

use common::{CHAT, ME, PEER, T0};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn snapshot(id: &str, ts: i64, text: &str) -> VibeMessageSnapshotV1 {
    VibeMessageSnapshotV1::text_message(CHAT, id, ts, PEER, false, text)
}

fn pool(n: usize) -> Vec<VibeMessageSnapshotV1> {
    (0..n)
        .map(|i| snapshot(&format!("m{i:03}"), T0 + i as i64, &format!("body {i}")))
        .collect()
}

fn reducer() -> VibeTimelineReducer {
    let mut r = VibeTimelineReducer::new(VibeCoreConfig {
        own_user_id: ME.to_string(),
        ..VibeCoreConfig::default()
    });
    r.set_chat_profile(CHAT, VibeChatProfile::default());
    r
}

fn text_frame(id: &str, ts: i64, text: &str) -> VibeCoreEventV1 {
    VibeCoreEventV1::new(
        CHAT,
        ts,
        VibeEventSource::ChatTopic,
        VibeEventBody::RawFrame {
            json: vibe_core::fixtures::frame(
                CHAT,
                id,
                ts,
                PEER,
                vibe_core::fixtures::VibeFixtureKind::Text,
                text,
            ),
        },
    )
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(96))]

    /// Ingest order must not change the reduction for distinct ids.
    ///
    /// Reconnects, history pages, and the user topic deliver the same messages in
    /// different orders constantly; if the reduction were order-sensitive the two
    /// paths would disagree about the transcript.
    #[test]
    fn reduction_is_order_independent(mut order in prop::collection::vec(0usize..40, 1..40)) {
        order.sort_unstable();
        order.dedup();
        let shuffled: Vec<usize> = order.iter().rev().copied().collect();

        let run = |seq: &[usize]| {
            let mut r = reducer();
            for i in seq {
                r.ingest(text_frame(&format!("m{i:03}"), T0 + *i as i64, "x"));
            }
            r.flush(T0 + 100_000);
            r.current_window(CHAT)
                .unwrap()
                .messages
                .iter()
                .map(|m| m.message_id.clone())
                .collect::<Vec<_>>()
        };

        prop_assert_eq!(run(&order), run(&shuffled));
    }

    /// Re-ingesting anything already applied emits no delta and does not move
    /// the generation.
    #[test]
    fn replay_is_idempotent(count in 1usize..30, repeats in 1usize..4) {
        let mut r = reducer();
        for i in 0..count {
            r.ingest(text_frame(&format!("m{i:03}"), T0 + i as i64, "x"));
        }
        r.flush(T0 + 1_000);
        let generation = r.generation(CHAT).unwrap();

        for _ in 0..repeats {
            for i in 0..count {
                r.ingest(text_frame(&format!("m{i:03}"), T0 + i as i64, "x"));
            }
            prop_assert!(r.flush(T0 + 2_000).is_empty());
        }
        prop_assert_eq!(r.generation(CHAT).unwrap(), generation);
    }

    /// No window, at any store size, ever exceeds the policy ceiling.
    #[test]
    fn windows_are_always_bounded(count in 0usize..900, pages in 0usize..12) {
        let policy = VibeWindowPolicy::default();
        let mut r = reducer();
        for i in 0..count {
            r.ingest(text_frame(&format!("m{i:04}"), T0 + i as i64, "x"));
        }
        r.flush(T0 + 100_000);
        for _ in 0..pages {
            let _ = r.page_before(CHAT, T0 + 100_001);
        }
        let window = r.current_window(CHAT).unwrap();
        prop_assert!(window.messages.len() <= policy.max_len as usize);
        prop_assert!(window.messages.len() <= count);
        prop_assert_eq!(window.bounds.window_len as usize, window.messages.len());
    }

    /// A tombstoned id never reappears, no matter how many sources replay it.
    #[test]
    fn tombstones_are_absorbing(
        victim in 0usize..20,
        replays in prop::collection::vec(0usize..4, 0..12),
    ) {
        let mut r = reducer();
        for i in 0..20 {
            r.ingest(text_frame(&format!("m{i:03}"), T0 + i as i64, "x"));
        }
        r.flush(T0 + 1_000);

        let victim_id = format!("m{victim:03}");
        r.ingest(VibeCoreEventV1::new(
            CHAT,
            T0 + 2_000,
            VibeEventSource::ChatTopic,
            VibeEventBody::Delete {
                message_id: victim_id.clone(),
                for_everyone: true,
                tombstone_ms: T0 + 2_000,
            },
        ));
        r.flush(T0 + 2_000);

        let sources = [
            VibeEventSource::ChatTopic,
            VibeEventSource::HistoryPage,
            VibeEventSource::StoreRestore,
            VibeEventSource::UserTopic,
        ];
        for pick in replays {
            let mut event = text_frame(&victim_id, T0 + victim as i64, "x");
            event.source = sources[pick];
            r.ingest(event);
        }
        r.flush(T0 + 3_000);

        let ids: Vec<String> = r
            .current_window(CHAT)
            .unwrap()
            .messages
            .iter()
            .map(|m| m.message_id.clone())
            .collect();
        prop_assert!(!ids.contains(&victim_id));
        prop_assert_eq!(ids.len(), 19);
    }

    /// `content_hash` changes if and only if a rendered field changes.
    ///
    /// The renderer's repaint decision is an integer compare against this value,
    /// so a hash that missed a field would leave stale pixels on screen and a
    /// hash that included a window artefact would repaint every row on scroll.
    #[test]
    fn content_hash_tracks_exactly_the_rendered_fields(
        seq in 0u64..1_000,
        new_text in "[a-z ]{0,24}",
    ) {
        let base = snapshot("m1", T0, "original");

        let mut positional = base.clone();
        positional.order_seq = seq;
        positional.rehash();
        prop_assert_eq!(positional.content_hash, base.content_hash);

        let mut edited = base.clone();
        edited.body.text = new_text.clone();
        edited.rehash();
        if new_text == "original" {
            prop_assert_eq!(edited.content_hash, base.content_hash);
        } else {
            prop_assert_ne!(edited.content_hash, base.content_hash);
        }

        let mut receipted = base.clone();
        receipted.delivery.display = VibeDisplayStatus::Read;
        receipted.rehash();
        prop_assert_ne!(receipted.content_hash, base.content_hash);
    }

    /// `apply(old, diff(old, new)) == new`, always.
    ///
    /// This is the whole delta contract. If it can fail for any pair of bounded
    /// windows, a consumer's list silently desyncs from the core.
    #[test]
    fn diff_then_apply_reproduces_the_target(
        old_start in 0usize..40,
        old_len in 0usize..24,
        new_start in 0usize..40,
        new_len in 0usize..24,
        edit_at in 0usize..24,
    ) {
        let all = pool(80);
        let old: Vec<VibeMessageSnapshotV1> = all
            .iter()
            .skip(old_start)
            .take(old_len)
            .cloned()
            .collect();
        let mut new: Vec<VibeMessageSnapshotV1> = all
            .iter()
            .skip(new_start)
            .take(new_len)
            .cloned()
            .collect();
        if !new.is_empty() {
            let i = edit_at % new.len();
            new[i].body.text = format!("edited {i}");
            new[i].rehash();
        }

        let in_store: Vec<String> = all.iter().map(|m| m.message_id.clone()).collect();
        let ops = diff_windows(&old, &new, &|id| in_store.iter().any(|s| s == id));
        let mut applied = old.clone();
        apply_ops(&mut applied, &ops).map_err(|e| TestCaseError::fail(e.to_string()))?;
        prop_assert_eq!(applied, new);
    }

    /// Anchor resolution always lands on a real index for a non-empty store, and
    /// reports how it got there.
    #[test]
    fn anchors_always_resolve(
        store_len in 1usize..60,
        target in 0usize..60,
        use_missing_id in any::<bool>(),
    ) {
        let messages = pool(store_len);
        let aliases: HashMap<String, String> = HashMap::new();
        let idx = target % store_len;
        let anchor = if use_missing_id {
            VibeTimelineAnchor::at_message("no-such-id", messages[idx].ts_ms)
        } else {
            VibeTimelineAnchor::at_message(&messages[idx].message_id, messages[idx].ts_ms)
        };

        let (resolved, resolution) = resolve_anchor(&messages, &aliases, &anchor, None);
        let resolved = resolved.expect("a non-empty store always resolves");
        prop_assert!(resolved < messages.len());
        prop_assert_ne!(resolution, VibeAnchorResolution::Empty);
        if !use_missing_id {
            prop_assert_eq!(resolution, VibeAnchorResolution::ExactId);
            prop_assert_eq!(resolved, idx);
        }
    }

    /// Window bounds always describe the slice they came from.
    #[test]
    fn bounds_describe_the_slice(store_len in 1usize..500, pages in 0usize..8) {
        let messages = pool(store_len);
        let policy = VibeWindowPolicy::default();
        let mut cursor = VibeWindowCursor::default().clamped(store_len, policy);
        for _ in 0..pages {
            cursor = cursor.paged_before(store_len, policy);
        }
        let bounds = bounds_for(&messages, cursor, store_len as u64);
        prop_assert_eq!(bounds.window_len as usize, cursor.len);
        prop_assert_eq!(bounds.has_more_before, cursor.start > 0);
        prop_assert_eq!(bounds.has_more_after, cursor.end() < store_len);
        prop_assert!(bounds.head_ts_ms <= bounds.tail_ts_ms);
    }

    /// The receipt lattice is monotone under any interleaving.
    #[test]
    fn receipts_never_go_backwards(
        events in prop::collection::vec((0usize..3, any::<bool>(), 0i64..1_000), 1..40),
    ) {
        let readers = ["a", "b", "c"];
        let mut state = VibeReceiptState::default();
        let policy = VibeReceiptPolicy::Group { other_member_count: 3 };
        let mut previous = state.display(policy, ME, true);

        for (reader, is_read, at) in events {
            let kind = if is_read { VibeReceiptKind::Read } else { VibeReceiptKind::Delivered };
            state.apply_receipt(readers[reader], kind, at);
            let next = state.display(policy, ME, true);
            prop_assert!(next >= previous, "receipt display went backwards");
            previous = next;
        }
    }
}
