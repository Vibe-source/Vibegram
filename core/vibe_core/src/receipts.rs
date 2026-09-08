//! Receipts, local send status, and the read cursor.
//!
//! The shipped engine collapses receipts to one value per message
//! (`receiptIndex[chatId][messageId] = "delivered" | "read"`). That is correct
//! by accident for a 1:1 DM and wrong for a group: any single member reading
//! marks the message read for everyone, and a second device belonging to the
//! *reader* can mark read on the pair's behalf.
//!
//! This module keeps the per-reader lattice instead. Two behaviours are
//! preserved verbatim because changing them would be a silent product change:
//!
//! * the status ranking, including the quirk that **`Failed` cannot downgrade a
//!   `Sent`** (a retry that errors must not un-send a delivered message);
//! * the presence heuristic that upgrades `Sent` to `Delivered` while the peer
//!   is online.
//!
//! The group rule (`Read` only when *every* other member has read) **is** a
//! behaviour change, and therefore ships only when the rollout gate is on for
//! [`crate::types::VibeChatClass::GroupOrChannel`].

use std::collections::BTreeMap;
use std::collections::HashMap;

use crate::types::{VibeDisplayStatus, VibeLocalStatus, VibeReceiptKind};

/// How a message's checkmarks are derived.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeReceiptPolicy {
    /// One peer. `peer_online` carries the presence heuristic.
    DirectMessage { peer_online: bool },
    /// `other_member_count` excludes the author. `Read` requires all of them.
    Group { other_member_count: u32 },
    /// Sealed to self: there is no reader but me, so a sent message is read.
    SavedMessages,
}

/// Per-message receipt lattice.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VibeReceiptState {
    /// Monotone per reader. `BTreeMap` so iteration order is deterministic and
    /// two devices replaying the same receipts converge byte-for-byte.
    per_reader: BTreeMap<String, (VibeReceiptKind, i64)>,
    local: Option<VibeLocalStatus>,
}

impl VibeReceiptState {
    /// Applies a receipt. Monotone in both kind and time: an out-of-order replay
    /// of an older `Delivered` never un-reads a message.
    ///
    /// Returns true when something actually changed.
    pub fn apply_receipt(&mut self, reader: &str, kind: VibeReceiptKind, at_ms: i64) -> bool {
        match self.per_reader.get(reader) {
            Some((existing, existing_at)) if *existing >= kind && *existing_at >= at_ms => false,
            Some((existing, existing_at)) => {
                let next_kind = (*existing).max(kind);
                let next_at = (*existing_at).max(at_ms);
                let changed = next_kind != *existing || next_at != *existing_at;
                self.per_reader
                    .insert(reader.to_string(), (next_kind, next_at));
                changed
            }
            None => {
                self.per_reader.insert(reader.to_string(), (kind, at_ms));
                true
            }
        }
    }

    /// Applies a local send-lifecycle status.
    pub fn apply_local(&mut self, status: VibeLocalStatus, allow_downgrade: bool) -> bool {
        let next = match self.local {
            Some(current) => current.join(status, allow_downgrade),
            None => status,
        };
        if self.local == Some(next) {
            return false;
        }
        self.local = Some(next);
        true
    }

    pub fn local(&self) -> Option<VibeLocalStatus> {
        self.local
    }

    pub fn reader_count(&self, kind: VibeReceiptKind) -> u32 {
        self.per_reader.values().filter(|(k, _)| *k >= kind).count() as u32
    }

    /// Derives what the checkmarks render.
    ///
    /// `own_user_id` is excluded from the reader set: a second device of the
    /// *sender* acknowledging its own message must never advance the sender's
    /// own checkmarks. It advances the read cursor and nothing else.
    pub fn display(
        &self,
        policy: VibeReceiptPolicy,
        own_user_id: &str,
        author_is_me: bool,
    ) -> VibeDisplayStatus {
        let base = local_to_display(self.local.unwrap_or(VibeLocalStatus::Sent));
        if !author_is_me {
            // Incoming messages have no checkmark column.
            return base;
        }

        let readers: Vec<(&VibeReceiptKind, &i64)> = self
            .per_reader
            .iter()
            // Case-insensitive: the platform upper-cases the configured id and the
            // server lower-cases receipt readers, so a byte-exact compare would
            // count our own read receipt as a peer's and mark our messages read.
            .filter(|(reader, _)| !reader.as_str().eq_ignore_ascii_case(own_user_id))
            .map(|(_, (kind, at))| (kind, at))
            .collect();

        let from_receipts = match policy {
            VibeReceiptPolicy::SavedMessages => Some(VibeDisplayStatus::Read),
            VibeReceiptPolicy::DirectMessage { peer_online } => {
                let best = readers.iter().map(|(k, _)| **k).max();
                match best {
                    Some(VibeReceiptKind::Read) => Some(VibeDisplayStatus::Read),
                    Some(VibeReceiptKind::Delivered) => Some(VibeDisplayStatus::Delivered),
                    // Presence heuristic, carried over from the shipped client.
                    None if peer_online && base >= VibeDisplayStatus::Sent => {
                        Some(VibeDisplayStatus::Delivered)
                    }
                    None => None,
                }
            }
            VibeReceiptPolicy::Group { other_member_count } => {
                if other_member_count == 0 {
                    None
                } else {
                    let read = readers
                        .iter()
                        .filter(|(k, _)| **k == VibeReceiptKind::Read)
                        .count() as u32;
                    let delivered = readers.len() as u32;
                    if read >= other_member_count {
                        Some(VibeDisplayStatus::Read)
                    } else if delivered > 0 {
                        Some(VibeDisplayStatus::Delivered)
                    } else {
                        None
                    }
                }
            }
        };

        match from_receipts {
            Some(from) => base.max(from),
            None => base,
        }
    }
}

fn local_to_display(status: VibeLocalStatus) -> VibeDisplayStatus {
    match status {
        VibeLocalStatus::Pending => VibeDisplayStatus::Pending,
        VibeLocalStatus::Sending => VibeDisplayStatus::Sending,
        VibeLocalStatus::Failed => VibeDisplayStatus::Failed,
        VibeLocalStatus::Sent => VibeDisplayStatus::Sent,
        VibeLocalStatus::Delivered => VibeDisplayStatus::Delivered,
        VibeLocalStatus::Read => VibeDisplayStatus::Read,
    }
}

/// Per-chat receipt ledger.
#[derive(Clone, Debug, Default)]
pub struct VibeReceiptLedger {
    by_message: HashMap<String, VibeReceiptState>,
    /// Per **user**, not per device, and monotone. Two devices of the same user
    /// fighting over this is how unread counts oscillate across reconnects.
    read_cursor: Option<VibeReadCursor>,
}

/// A monotone read high-water mark.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VibeReadCursor {
    pub up_to_ts_ms: i64,
    pub up_to_message_id: String,
}

impl VibeReceiptLedger {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn apply_receipt(
        &mut self,
        message_id: &str,
        reader: &str,
        kind: VibeReceiptKind,
        at_ms: i64,
    ) -> bool {
        self.by_message
            .entry(message_id.to_string())
            .or_default()
            .apply_receipt(reader, kind, at_ms)
    }

    pub fn apply_local(
        &mut self,
        message_id: &str,
        status: VibeLocalStatus,
        allow_downgrade: bool,
    ) -> bool {
        self.by_message
            .entry(message_id.to_string())
            .or_default()
            .apply_local(status, allow_downgrade)
    }

    /// Advances the read cursor. Monotone by `(ts, id)`; an older cursor from a
    /// reconnect is ignored.
    pub fn advance_read_cursor(&mut self, up_to_ts_ms: i64, up_to_message_id: &str) -> bool {
        let next = VibeReadCursor {
            up_to_ts_ms,
            up_to_message_id: up_to_message_id.to_string(),
        };
        match &self.read_cursor {
            Some(current)
                if (current.up_to_ts_ms, current.up_to_message_id.as_str())
                    >= (next.up_to_ts_ms, next.up_to_message_id.as_str()) =>
            {
                false
            }
            _ => {
                self.read_cursor = Some(next);
                true
            }
        }
    }

    pub fn read_cursor(&self) -> Option<&VibeReadCursor> {
        self.read_cursor.as_ref()
    }

    pub fn state(&self, message_id: &str) -> Option<&VibeReceiptState> {
        self.by_message.get(message_id)
    }

    /// Carries receipt state across an optimistic → server id heal.
    pub fn realias(&mut self, from_id: &str, to_id: &str) {
        if let Some(state) = self.by_message.remove(from_id) {
            let merged = self.by_message.entry(to_id.to_string()).or_default();
            for (reader, (kind, at)) in state.per_reader {
                merged.apply_receipt(&reader, kind, at);
            }
            if let Some(local) = state.local {
                merged.apply_local(local, false);
            }
        }
    }

    pub fn forget(&mut self, message_id: &str) {
        self.by_message.remove(message_id);
    }

    pub fn len(&self) -> usize {
        self.by_message.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_message.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: &str = "me";

    #[test]
    fn receipt_lattice_is_monotone_under_replay() {
        let mut s = VibeReceiptState::default();
        assert!(s.apply_receipt("peer", VibeReceiptKind::Read, 200));
        // Older delivered replayed after a read must not downgrade.
        assert!(!s.apply_receipt("peer", VibeReceiptKind::Delivered, 100));
        assert_eq!(
            s.display(
                VibeReceiptPolicy::DirectMessage { peer_online: false },
                ME,
                true
            ),
            VibeDisplayStatus::Read
        );
    }

    #[test]
    fn failure_cannot_downgrade_a_sent_message() {
        let mut s = VibeReceiptState::default();
        s.apply_local(VibeLocalStatus::Sent, false);
        s.apply_local(VibeLocalStatus::Failed, false);
        assert_eq!(s.local(), Some(VibeLocalStatus::Sent));
    }

    #[test]
    fn peer_online_upgrades_sent_to_delivered() {
        let mut s = VibeReceiptState::default();
        s.apply_local(VibeLocalStatus::Sent, false);
        assert_eq!(
            s.display(
                VibeReceiptPolicy::DirectMessage { peer_online: true },
                ME,
                true
            ),
            VibeDisplayStatus::Delivered
        );
        assert_eq!(
            s.display(
                VibeReceiptPolicy::DirectMessage { peer_online: false },
                ME,
                true
            ),
            VibeDisplayStatus::Sent
        );
    }

    #[test]
    fn presence_heuristic_never_upgrades_an_unsent_message() {
        let mut s = VibeReceiptState::default();
        s.apply_local(VibeLocalStatus::Sending, false);
        assert_eq!(
            s.display(
                VibeReceiptPolicy::DirectMessage { peer_online: true },
                ME,
                true
            ),
            VibeDisplayStatus::Sending
        );
    }

    #[test]
    fn group_read_requires_every_other_member() {
        let mut s = VibeReceiptState::default();
        s.apply_local(VibeLocalStatus::Sent, false);
        let policy = VibeReceiptPolicy::Group {
            other_member_count: 3,
        };

        s.apply_receipt("a", VibeReceiptKind::Read, 1);
        assert_eq!(s.display(policy, ME, true), VibeDisplayStatus::Delivered);
        s.apply_receipt("b", VibeReceiptKind::Read, 2);
        assert_eq!(s.display(policy, ME, true), VibeDisplayStatus::Delivered);
        s.apply_receipt("c", VibeReceiptKind::Read, 3);
        assert_eq!(s.display(policy, ME, true), VibeDisplayStatus::Read);
    }

    #[test]
    fn own_second_device_never_advances_own_checkmarks() {
        let mut s = VibeReceiptState::default();
        s.apply_local(VibeLocalStatus::Sent, false);
        s.apply_receipt(ME, VibeReceiptKind::Read, 10);
        assert_eq!(
            s.display(
                VibeReceiptPolicy::Group {
                    other_member_count: 2
                },
                ME,
                true
            ),
            VibeDisplayStatus::Sent
        );
        assert_eq!(
            s.display(
                VibeReceiptPolicy::DirectMessage { peer_online: false },
                ME,
                true
            ),
            VibeDisplayStatus::Sent
        );
    }

    #[test]
    fn saved_messages_is_read_on_arrival() {
        let mut s = VibeReceiptState::default();
        s.apply_local(VibeLocalStatus::Sent, false);
        assert_eq!(
            s.display(VibeReceiptPolicy::SavedMessages, ME, true),
            VibeDisplayStatus::Read
        );
    }

    #[test]
    fn read_cursor_is_monotone() {
        let mut l = VibeReceiptLedger::new();
        assert!(l.advance_read_cursor(100, "m5"));
        assert!(!l.advance_read_cursor(50, "m2"));
        assert!(l.advance_read_cursor(200, "m9"));
        assert_eq!(l.read_cursor().unwrap().up_to_message_id, "m9");
    }

    #[test]
    fn healing_an_id_carries_the_receipts_over() {
        let mut l = VibeReceiptLedger::new();
        l.apply_local("local-1", VibeLocalStatus::Sending, false);
        l.apply_receipt("local-1", "peer", VibeReceiptKind::Delivered, 10);
        l.realias("local-1", "server-1");
        assert!(l.state("local-1").is_none());
        let s = l.state("server-1").unwrap();
        assert_eq!(s.reader_count(VibeReceiptKind::Delivered), 1);
    }
}
