//! Total order and settle-slot adoption.
//!
//! The comparator is `(ts_ms ASC, message_id ASC)` — exactly the shipped Swift
//! comparator. It is stable across launches, which is the only property that
//! actually matters for a transcript.
//!
//! # One deliberate divergence, named
//!
//! The Swift merge prepends rows that have **no id** to the front of the
//! transcript. This crate rejects an id-less frame at canonicalization instead
//! (`VibeCanonicalError::MissingMessageId`) and counts it. An id-less row cannot
//! be deduped, tombstoned, anchored, receipted, or persisted, so admitting one
//! creates a row that no later event can ever address. Parity tests must expect
//! this difference; it is the only intentional ordering divergence in the crate.

use std::collections::HashMap;

use crate::types::{VibeMessageSnapshotV1, VibeOrderKey};

/// Sorts in place by the canonical total order.
pub fn sort_total_order(messages: &mut [VibeMessageSnapshotV1]) {
    messages.sort_by(|a, b| {
        a.ts_ms
            .cmp(&b.ts_ms)
            .then_with(|| a.message_id.cmp(&b.message_id))
    });
}

/// Assigns the dense window index to each message.
///
/// `order_seq` is derived from position, never the other way round, and is
/// excluded from `content_hash` so a scroll does not mark every row changed.
pub fn assign_order_seq(messages: &mut [VibeMessageSnapshotV1], start: u64) {
    for (i, m) in messages.iter_mut().enumerate() {
        m.order_seq = start + i as u64;
    }
}

/// Settle-slot overrides.
///
/// When an optimistic row is replaced by its settled server row, the settled row
/// adopts the *live* row's slot timestamp so the bubble does not jump to a new
/// position in the transcript. In the Swift engine this is
/// `rowAdoptingSettleSlotTs`. Modelling it explicitly matters for the delta: a
/// row that only changed position must be emitted as
/// [`crate::types::VibeTimelineOpV1::Move`], never as `Remove` + `Insert`, or
/// the renderer re-animates a bubble that merely settled.
#[derive(Clone, Debug, Default)]
pub struct VibeSettleSlots {
    slots: HashMap<String, i64>,
}

impl VibeSettleSlots {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records the slot a message should keep. First writer wins: the *original*
    /// optimistic position is the one the user is looking at.
    pub fn record(&mut self, message_id: &str, ts_ms: i64) {
        self.slots.entry(message_id.to_string()).or_insert(ts_ms);
    }

    pub fn get(&self, message_id: &str) -> Option<i64> {
        self.slots.get(message_id).copied()
    }

    /// Carries a slot across an optimistic → server id heal.
    pub fn realias(&mut self, from_id: &str, to_id: &str) {
        if let Some(ts) = self.slots.remove(from_id) {
            self.slots.entry(to_id.to_string()).or_insert(ts);
        }
    }

    pub fn forget(&mut self, message_id: &str) {
        self.slots.remove(message_id);
    }

    /// Rewrites `ts_ms` to the adopted slot, if one exists.
    pub fn apply(&self, message: &mut VibeMessageSnapshotV1) {
        if let Some(ts) = self.get(&message.message_id) {
            message.ts_ms = ts;
        }
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }
}

/// Binary search for the insertion point of `key` in an ascending slice.
pub fn insertion_index(messages: &[VibeMessageSnapshotV1], key: &VibeOrderKey) -> usize {
    messages
        .binary_search_by(|m| {
            m.ts_ms
                .cmp(&key.ts_ms)
                .then_with(|| m.message_id.as_str().cmp(key.message_id.as_str()))
        })
        .unwrap_or_else(|i| i)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(id: &str, ts: i64) -> VibeMessageSnapshotV1 {
        VibeMessageSnapshotV1::text_message("c", id, ts, "u", false, "x")
    }

    #[test]
    fn sorts_by_timestamp_then_id() {
        let mut v = vec![msg("b", 2), msg("a", 2), msg("z", 1)];
        sort_total_order(&mut v);
        let ids: Vec<&str> = v.iter().map(|m| m.message_id.as_str()).collect();
        assert_eq!(ids, ["z", "a", "b"]);
    }

    #[test]
    fn sort_is_stable_under_input_permutation() {
        let mut a = vec![msg("m1", 5), msg("m2", 5), msg("m3", 4)];
        let mut b = vec![msg("m3", 4), msg("m2", 5), msg("m1", 5)];
        sort_total_order(&mut a);
        sort_total_order(&mut b);
        assert_eq!(a, b);
    }

    #[test]
    fn settle_slot_keeps_the_first_recorded_position() {
        let mut slots = VibeSettleSlots::new();
        slots.record("m1", 100);
        slots.record("m1", 900);
        let mut m = msg("m1", 900);
        slots.apply(&mut m);
        assert_eq!(m.ts_ms, 100);
    }

    #[test]
    fn settle_slot_survives_id_healing() {
        let mut slots = VibeSettleSlots::new();
        slots.record("local-1", 100);
        slots.realias("local-1", "server-1");
        let mut m = msg("server-1", 900);
        slots.apply(&mut m);
        assert_eq!(m.ts_ms, 100);
        assert_eq!(slots.get("local-1"), None);
    }

    #[test]
    fn insertion_index_finds_ordered_slot() {
        let v = vec![msg("a", 1), msg("c", 3), msg("e", 5)];
        assert_eq!(insertion_index(&v, &VibeOrderKey::new(0, "z")), 0);
        assert_eq!(insertion_index(&v, &VibeOrderKey::new(2, "b")), 1);
        assert_eq!(insertion_index(&v, &VibeOrderKey::new(9, "z")), 3);
        assert_eq!(insertion_index(&v, &VibeOrderKey::new(3, "c")), 1);
    }
}
