//! The per-chat state machine.
//!
//! This is the only stateful type in the crate. Everything it calls is a pure
//! function, which is what makes replay deterministic: given the same event
//! sequence and the same injected clock, two reducers produce byte-identical
//! deltas.
//!
//! # Generation fencing
//!
//! Each chat carries a generation that strictly increases **only when a delta is
//! actually emitted**. A consumer applies a delta iff
//! `delta.base_generation == its own generation`. Any other value is a gap, and
//! the consumer recovers with [`VibeTimelineReducer::resync`], which returns a
//! [`crate::types::VibeTimelineDeltaBodyV1::Reset`] carrying a whole window. It
//! never guesses.
//!
//! Corollary: **an idempotent replay emits nothing.** Re-ingesting a frame the
//! store already holds produces an identical snapshot, an empty op list, and no
//! generation bump.
//!
//! # The flush barrier (challenge C1)
//!
//! Taken literally, "one event ingestion may yield one ordered delta" forces one
//! delta per bridge stream frame, and agent live-tail runs at 20–40 frames per
//! second. The approved amendment: *a flush yields at most one ordered delta;
//! truth is never delayed past the flush barrier; a barrier is implicit at every
//! non-stream ingest and at every explicit flush.* Stream events coalesce only up
//! to [`VibeCoreConfig::flush_frame_interval_ms`] — one display frame — and the
//! interval is measured against the injected event clock, never a real one.
//!
//! # Two bounded scans, named honestly
//!
//! The Swift merge re-scans the whole loaded transcript on every ingest. This
//! reducer bounds two scans so the 100k soak stays flat:
//!
//! * dedup and stale-stream settling scan the newest [`DEDUP_SCAN_LIMIT`]
//!   messages plus whatever just arrived — at least two full windows;
//! * the unread count walks forward from the read cursor at most
//!   [`UNREAD_COUNT_CAP`] messages.
//!
//! Both are divergences from the shipped behaviour in the extreme tail (a
//! mirrored prompt more than 600 messages back is not suppressed; an unread
//! count above 999 reports as 999) and both are deliberate.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use crate::canonical::{
    canonicalize_frame, canonicalize_frames, VibeCanonicalContext, VibeThumbnailBlob,
};
use crate::crypto::{
    default_aead_provider, VibeAeadProvider, VibeDenyAllKeyUnwrapper, VibeKeyUnwrapper,
};
use crate::dedup;
use crate::delta::diff_windows;
use crate::error::VibeCoreError;
use crate::order::VibeSettleSlots;
use crate::receipts::{VibeReceiptLedger, VibeReceiptPolicy};
use crate::types::{
    VibeAgentRef, VibeAsyncTimelineGate, VibeChatClass, VibeCoreEventV1, VibeDeltaCause,
    VibeEventBody, VibeEventSource, VibeMessageBody, VibeMessageFlags, VibeMessageSnapshotV1,
    VibeTimelineAnchor, VibeTimelineDeltaBodyV1, VibeTimelineDeltaV1, VibeTimelineWindowResultV1,
    VibeTimelineWindowV1, VibeUnreadState, VibeWindowBounds,
};
use crate::window::{self, VibeWindowCursor, VibeWindowPolicy};

/// How far back dedup and stale-stream settling look. Two windows plus slack.
pub const DEDUP_SCAN_LIMIT: usize = 600;

/// Largest unread count the reducer will walk to.
pub const UNREAD_COUNT_CAP: u32 = 999;

/// One display frame at 120 Hz. Stream events coalesce no longer than this.
pub const DEFAULT_FLUSH_FRAME_INTERVAL_MS: i64 = 8;

/// Suppressed transient/mirror ids retained to absorb immediate replays.
///
/// This is intentionally a retention cache, not permanent history. Keeping
/// every bridge id forever made a long-running agent chat's auxiliary state
/// grow without bound.
pub const MAX_SUPPRESSED_IDS: usize = 2_048;

/// Per-kind cap for mutations that arrive before their message frame.
pub const MAX_PENDING_MUTATIONS: usize = 1_024;

/// Reducer configuration.
///
/// The AEAD provider and the key unwrapper are injected. The defaults are
/// [`default_aead_provider`] and [`VibeDenyAllKeyUnwrapper`] — that is, a build
/// that has not been given a private-key seam opens nothing and flags every
/// sealed row, rather than silently rendering ciphertext.
#[derive(Clone)]
pub struct VibeCoreConfig {
    pub own_user_id: String,
    pub window_policy: VibeWindowPolicy,
    pub gate: VibeAsyncTimelineGate,
    pub flush_frame_interval_ms: i64,
    pub aead: Arc<dyn VibeAeadProvider>,
    pub unwrapper: Arc<dyn VibeKeyUnwrapper>,
}

impl std::fmt::Debug for VibeCoreConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeCoreConfig")
            .field("has_own_user_id", &!self.own_user_id.is_empty())
            .field("window_policy", &self.window_policy)
            .field("gate", &self.gate)
            .field("flush_frame_interval_ms", &self.flush_frame_interval_ms)
            .field("aead", &self.aead.label())
            .finish()
    }
}

impl Default for VibeCoreConfig {
    fn default() -> Self {
        Self {
            own_user_id: String::new(),
            window_policy: VibeWindowPolicy::default(),
            gate: VibeAsyncTimelineGate::off(),
            flush_frame_interval_ms: DEFAULT_FLUSH_FRAME_INTERVAL_MS,
            aead: default_aead_provider(),
            unwrapper: Arc::new(VibeDenyAllKeyUnwrapper),
        }
    }
}

/// Per-chat facts the reducer cannot derive from the frames themselves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeChatProfile {
    pub class: VibeChatClass,
    pub peer_online: bool,
    /// Members other than the author. Only meaningful for a group.
    pub other_member_count: u32,
    pub muted: bool,
}

impl Default for VibeChatProfile {
    fn default() -> Self {
        Self {
            class: VibeChatClass::DirectMessage,
            peer_online: false,
            other_member_count: 0,
            muted: false,
        }
    }
}

impl VibeChatProfile {
    fn receipt_policy(self) -> VibeReceiptPolicy {
        match self.class {
            VibeChatClass::DirectMessage => VibeReceiptPolicy::DirectMessage {
                peer_online: self.peer_online,
            },
            VibeChatClass::GroupOrChannel => VibeReceiptPolicy::Group {
                other_member_count: self.other_member_count,
            },
            VibeChatClass::SavedMessages => VibeReceiptPolicy::SavedMessages,
            // An agent DM has exactly one counterparty and no presence signal.
            VibeChatClass::AgentDirectMessage => {
                VibeReceiptPolicy::DirectMessage { peer_online: false }
            }
        }
    }
}

/// Redacted counters. No content, no ids.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VibeCoreCounters {
    pub events_accepted: u64,
    pub frames_dropped: u64,
    pub decrypt_failures: u64,
    pub duplicates_suppressed: u64,
    pub tombstones_applied: u64,
    pub deltas_emitted: u64,
    pub resets_emitted: u64,
    pub stream_frames_coalesced: u64,
    pub stale_streams_settled: u64,
    pub raw_frame_conflicts_resolved: u64,
    pub pending_mutations_buffered: u64,
    pub pending_mutations_evicted: u64,
}

/// Redacted per-chat state sizes used by soak tests and production diagnostics.
/// Contains counts only: no ids, bodies, URLs, ciphertext, or key material.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VibeReducerStateMetrics {
    pub stored_messages: usize,
    pub committed_window: usize,
    pub tombstones: usize,
    pub aliases: usize,
    pub suppressed: usize,
    pub live_rows: usize,
    pub pending_edits: usize,
    pub pending_uploads: usize,
    pub pending_agents: usize,
}

/// Receipt for a submitted event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeIngestAck {
    /// The core-assigned monotonic sequence. The sole replay-ordering authority.
    pub seq: u64,
    /// True when a delta for this chat is available from
    /// [`VibeTimelineReducer::poll_deltas`] right now.
    pub barrier_reached: bool,
}

#[derive(Clone)]
struct PendingEdit {
    body: VibeMessageBody,
    edited_at_ms: i64,
    seq: u64,
}

#[derive(Clone, Copy)]
struct PendingUpload {
    fraction: Option<f32>,
    seq: u64,
}

#[derive(Clone)]
struct PendingAgent {
    kind: String,
    sealed: crate::secret::VibeOpaqueBlob,
    received_at_ms: i64,
    seq: u64,
}

struct ChatState {
    profile: VibeChatProfile,
    /// Live, visible, ordered. Tombstoned and suppressed rows are removed, so
    /// window building is O(window) and never O(store).
    messages: Vec<VibeMessageSnapshotV1>,
    /// id → ts, for O(log n) positioning without scanning.
    positions: HashMap<String, i64>,
    tombstones: HashMap<String, i64>,
    cleared_before_ms: Option<i64>,
    /// Retired id → id the store actually holds.
    aliases: HashMap<String, String>,
    /// Ids suppressed by a dedup predicate. Kept so a re-ingest of the same
    /// mirror does not resurrect it.
    suppressed: HashSet<String>,
    suppressed_order: VecDeque<String>,
    /// Ids currently fed by a live bridge row. Decides the stale-stream grace.
    live_row_ids: HashSet<String>,
    /// Source authority for same-id raw-frame conflict resolution.
    frame_sources: HashMap<String, VibeEventSource>,
    pending_edits: HashMap<String, PendingEdit>,
    pending_uploads: HashMap<String, PendingUpload>,
    pending_agents: HashMap<String, PendingAgent>,
    receipts: VibeReceiptLedger,
    settle_slots: VibeSettleSlots,
    generation: u64,
    committed_window: Vec<VibeMessageSnapshotV1>,
    committed_bounds: VibeWindowBounds,
    committed_unread: VibeUnreadState,
    cursor: VibeWindowCursor,
    anchor: VibeTimelineAnchor,
    /// Last resolution result, cached so `current_window` is not O(store).
    anchor_resolution: crate::types::VibeAnchorResolution,
    dirty: bool,
    /// Set when the anchor changed and the cursor must be re-derived from it.
    /// Without this, a scroll-back page would be undone by the next ingest.
    anchor_dirty: bool,
    /// Set when the first coalescing (stream) event lands; cleared on flush.
    stream_pending_since_ms: Option<i64>,
    /// Set by any non-stream event and by an explicit flush.
    barrier_armed: bool,
    last_cause: VibeDeltaCause,
}

impl ChatState {
    fn new(profile: VibeChatProfile) -> Self {
        Self {
            profile,
            messages: Vec::new(),
            positions: HashMap::new(),
            tombstones: HashMap::new(),
            cleared_before_ms: None,
            aliases: HashMap::new(),
            suppressed: HashSet::new(),
            suppressed_order: VecDeque::new(),
            live_row_ids: HashSet::new(),
            frame_sources: HashMap::new(),
            pending_edits: HashMap::new(),
            pending_uploads: HashMap::new(),
            pending_agents: HashMap::new(),
            receipts: VibeReceiptLedger::new(),
            settle_slots: VibeSettleSlots::new(),
            generation: 0,
            committed_window: Vec::new(),
            committed_bounds: VibeWindowBounds::default(),
            committed_unread: VibeUnreadState::default(),
            cursor: VibeWindowCursor::default(),
            anchor: VibeTimelineAnchor::bottom(),
            anchor_resolution: crate::types::VibeAnchorResolution::Empty,
            dirty: false,
            anchor_dirty: true,
            stream_pending_since_ms: None,
            barrier_armed: false,
            last_cause: VibeDeltaCause::Ingest,
        }
    }
}

/// The reducer.
pub struct VibeTimelineReducer {
    config: VibeCoreConfig,
    chats: HashMap<String, ChatState>,
    next_seq: u64,
    counters: VibeCoreCounters,
    thumbnails: Vec<VibeThumbnailBlob>,
}

impl std::fmt::Debug for VibeTimelineReducer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeTimelineReducer")
            .field("chats", &self.chats.len())
            .field("next_seq", &self.next_seq)
            .field("counters", &self.counters)
            .finish()
    }
}

impl VibeTimelineReducer {
    pub fn new(config: VibeCoreConfig) -> Self {
        Self {
            config,
            chats: HashMap::new(),
            next_seq: 1,
            counters: VibeCoreCounters::default(),
            thumbnails: Vec::new(),
        }
    }

    pub fn counters(&self) -> VibeCoreCounters {
        self.counters
    }

    pub fn config(&self) -> &VibeCoreConfig {
        &self.config
    }

    /// Count-only diagnostics for memory/retention qualification.
    pub fn state_metrics(&self, chat_id: &str) -> Option<VibeReducerStateMetrics> {
        self.chats
            .get(chat_id)
            .map(|state| VibeReducerStateMetrics {
                stored_messages: state.messages.len(),
                committed_window: state.committed_window.len(),
                tombstones: state.tombstones.len(),
                aliases: state.aliases.len(),
                suppressed: state.suppressed.len(),
                live_rows: state.live_row_ids.len(),
                pending_edits: state.pending_edits.len(),
                pending_uploads: state.pending_uploads.len(),
                pending_agents: state.pending_agents.len(),
            })
    }

    /// Current generation for a chat, for a consumer that wants to check itself.
    pub fn generation(&self, chat_id: &str) -> Option<u64> {
        self.chats.get(chat_id).map(|c| c.generation)
    }

    /// Registers or updates the per-chat facts the frames do not carry.
    pub fn set_chat_profile(&mut self, chat_id: &str, profile: VibeChatProfile) {
        let state = self
            .chats
            .entry(chat_id.to_string())
            .or_insert_with(|| ChatState::new(profile));
        if state.profile != profile {
            state.profile = profile;
            state.dirty = true;
            state.barrier_armed = true;
        }
    }

    /// Thumbnail bytes lifted out of frames since the last drain. The host writes
    /// them to its media vault; they never ride a snapshot.
    pub fn take_thumbnails(&mut self) -> Vec<VibeThumbnailBlob> {
        std::mem::take(&mut self.thumbnails)
    }

    /// Rows that may be written to durable storage.
    ///
    /// Transient bridge ids are filtered here rather than at the reduction layer,
    /// and agent DMs are volatile-per-session: persisting them paints a stale
    /// transcript at cold launch that the volatile layer then wipes.
    pub fn persistable_messages(&self, chat_id: &str) -> Vec<&VibeMessageSnapshotV1> {
        let Some(state) = self.chats.get(chat_id) else {
            return Vec::new();
        };
        if state.profile.class == VibeChatClass::AgentDirectMessage {
            return Vec::new();
        }
        state
            .messages
            .iter()
            .filter(|m| !m.flags.contains(VibeMessageFlags::TRANSIENT_ID))
            .collect()
    }

    /// Submits one event.
    ///
    /// Returns immediately. The `seq` is assigned here, under the reducer's own
    /// ordering, because `received_at_ms` is not monotonic across a clock change
    /// and the server timestamp is not unique.
    pub fn ingest(&mut self, mut event: VibeCoreEventV1) -> VibeIngestAck {
        let seq = self.next_seq;
        self.next_seq += 1;
        event.seq = seq;
        self.counters.events_accepted += 1;

        let chat_id = event.chat_id.clone();
        let now_ms = event.received_at_ms;
        let is_stream = event.source.is_stream();

        if !self.chats.contains_key(&chat_id) {
            self.chats
                .insert(chat_id.clone(), ChatState::new(VibeChatProfile::default()));
        }

        self.apply_event(&chat_id, &event, now_ms);

        let state = self.chats.get_mut(&chat_id).expect("chat inserted above");
        let explicit_flush = matches!(event.body, VibeEventBody::Flush);
        if is_stream && !explicit_flush {
            if state.stream_pending_since_ms.is_none() {
                state.stream_pending_since_ms = Some(now_ms);
            }
            self.counters.stream_frames_coalesced += 1;
        } else {
            state.barrier_armed = true;
        }

        let barrier_reached = state.barrier_armed
            || state
                .stream_pending_since_ms
                .is_some_and(|since| now_ms - since >= self.config.flush_frame_interval_ms);

        VibeIngestAck {
            seq,
            barrier_reached,
        }
    }

    /// Emits deltas for every chat whose barrier has been reached.
    ///
    /// `now_ms` is injected so a replay is deterministic. Chats with no actual
    /// change emit nothing and do not bump their generation.
    pub fn poll_deltas(&mut self, now_ms: i64) -> Vec<VibeTimelineDeltaV1> {
        let interval = self.config.flush_frame_interval_ms;
        let ready: Vec<String> = self
            .chats
            .iter()
            .filter(|(_, s)| {
                s.barrier_armed
                    || s.stream_pending_since_ms
                        .is_some_and(|since| now_ms - since >= interval)
            })
            .map(|(id, _)| id.clone())
            .collect();
        self.emit_for(&ready, now_ms)
    }

    /// Explicit barrier: emits everything pending, regardless of the clock.
    pub fn flush(&mut self, now_ms: i64) -> Vec<VibeTimelineDeltaV1> {
        let all: Vec<String> = self.chats.keys().cloned().collect();
        for id in &all {
            if let Some(state) = self.chats.get_mut(id) {
                state.barrier_armed = true;
            }
        }
        self.emit_for(&all, now_ms)
    }

    fn emit_for(&mut self, chat_ids: &[String], now_ms: i64) -> Vec<VibeTimelineDeltaV1> {
        let mut out = Vec::new();
        // Deterministic emission order: two reducers fed the same events must
        // produce the same delta sequence, and HashMap iteration order is not.
        let mut ids = chat_ids.to_vec();
        ids.sort_unstable();
        ids.dedup();
        for chat_id in ids {
            if let Some(delta) = self.recompute(&chat_id, now_ms) {
                out.push(delta);
            }
        }
        out
    }

    /// Rebuilds the window for one chat and diffs it against what the consumer
    /// last saw.
    fn recompute(&mut self, chat_id: &str, now_ms: i64) -> Option<VibeTimelineDeltaV1> {
        let policy = self.config.window_policy;
        let own_user_id = self.config.own_user_id.clone();

        let mut suppressed_now = 0u64;

        let state = self.chats.get_mut(chat_id)?;
        state.barrier_armed = false;
        state.stream_pending_since_ms = None;
        if !state.dirty {
            return None;
        }
        state.dirty = false;

        // --- bounded hygiene pass ------------------------------------------
        let scan_from = state.messages.len().saturating_sub(DEDUP_SCAN_LIMIT);
        let settled_ids = {
            let live = state.live_row_ids.clone();
            let tail = &mut state.messages[scan_from..];
            dedup::terminalize_stale_streaming(tail, now_ms, &|id| live.contains(id))
        };
        for id in &settled_ids {
            state.live_row_ids.remove(id);
        }
        let settled = settled_ids.len() as u64;
        let drop_ids = {
            let tail = &state.messages[scan_from..];
            let mut ids = dedup::dedup_mirrored_prompt(tail);
            ids.extend(dedup::dedup_persisted_agent_twin(tail));
            ids.extend(dedup::drop_empty_agent_shell(tail));
            ids.extend(dedup::drop_stale_stream_row(tail));
            ids
        };
        if !drop_ids.is_empty() {
            suppressed_now = drop_ids.len() as u64;
            let mut ordered_drop_ids: Vec<String> = drop_ids.iter().cloned().collect();
            ordered_drop_ids.sort_unstable();
            for id in ordered_drop_ids {
                remember_suppressed(state, id.clone());
                state.positions.remove(&id);
                state.frame_sources.remove(&id);
                state.live_row_ids.remove(&id);
            }
            state.messages.retain(|m| !drop_ids.contains(&m.message_id));
        }
        // A live marker is meaningful only while its row still exists. This is
        // a cheap set intersection, bounded by live stream concurrency rather
        // than durable history size.
        let positions = &state.positions;
        state
            .live_row_ids
            .retain(|message_id| positions.contains_key(message_id));

        // --- window ---------------------------------------------------------
        let total = state.messages.len();
        let unread = unread_state(state, &own_user_id);
        // The cursor is re-derived from the anchor only when the anchor moved.
        // Otherwise it keeps whatever the user's scrolling put it at and is
        // merely re-clamped — a new arrival must not undo a scroll-back page.
        //
        // Resolution is skipped entirely in the steady state, because a `Message`
        // anchor resolves by scanning and that scan would otherwise be paid on
        // every single flush of a 100k-message chat.
        state.cursor = if state.anchor_dirty || state.cursor.len == 0 {
            let (index, resolution) = window::resolve_anchor(
                &state.messages,
                &state.aliases,
                &state.anchor,
                unread.first_unread_id.as_deref(),
            );
            state.anchor_dirty = false;
            state.anchor_resolution = resolution;
            match index {
                Some(i) => window::cursor_for_index(total, policy, i, resolution),
                None => VibeWindowCursor::default().clamped(0, policy),
            }
        } else {
            // A cursor stores indices, but indices before a scrolled-back
            // window are not stable: an off-screen insert/delete would shift
            // the slice and manufacture visible row mutations. Rebase to the
            // first still-mounted identity (bounded by the <=300 committed
            // window) before clamping. Explicit page movement is already the
            // requested cursor change and must not be undone here.
            if !state.cursor.follow_tail && !matches!(state.last_cause, VibeDeltaCause::Page) {
                rebase_cursor_to_committed_origin(state);
            }
            state.cursor.clamped(total, policy)
        };
        let cursor = state.cursor;

        let mut next_window: Vec<VibeMessageSnapshotV1> =
            state.messages[cursor.start..cursor.end()].to_vec();
        let policy_ref = state.profile.receipt_policy();
        for (i, m) in next_window.iter_mut().enumerate() {
            m.order_seq = (cursor.start + i) as u64;
            if let Some(receipts) = state.receipts.state(&m.message_id) {
                m.delivery.display = receipts.display(policy_ref, &own_user_id, m.author.is_me);
            }
            m.rehash();
        }

        let bounds = window::bounds_for(&state.messages, cursor, total as u64);
        // The eviction-vs-deletion distinction: a row that left the window but is
        // still in the store was trimmed, not deleted, and must not animate.
        let ops = {
            let positions = &state.positions;
            diff_windows(&state.committed_window, &next_window, &|id| {
                positions.contains_key(id)
            })
        };

        self.counters.stale_streams_settled += settled;
        self.counters.duplicates_suppressed += suppressed_now;

        let state = self.chats.get_mut(chat_id)?;
        let metadata_changed = state.committed_bounds != bounds || state.committed_unread != unread;
        if ops.is_empty() && !metadata_changed {
            // Idempotent replay: nothing changed, so nothing is emitted and the
            // generation does not move.
            state.committed_window = next_window;
            state.committed_bounds = bounds;
            state.committed_unread = unread;
            return None;
        }

        let base_generation = state.generation;
        state.generation += 1;
        state.committed_window = next_window;
        state.committed_bounds = bounds;
        state.committed_unread = unread.clone();
        let cause = std::mem::replace(&mut state.last_cause, VibeDeltaCause::Ingest);
        self.counters.deltas_emitted += 1;

        Some(VibeTimelineDeltaV1 {
            chat_id: chat_id.to_string(),
            generation: state.generation,
            base_generation,
            body: VibeTimelineDeltaBodyV1::Ops(ops),
            bounds,
            unread,
            cause,
        })
    }

    /// Bounded window query.
    pub fn window(
        &mut self,
        chat_id: &str,
        anchor: VibeTimelineAnchor,
        now_ms: i64,
    ) -> Result<VibeTimelineWindowResultV1, VibeCoreError> {
        {
            let state = self
                .chats
                .get_mut(chat_id)
                .ok_or(VibeCoreError::UnknownChat)?;
            state.anchor = anchor;
            state.cursor = VibeWindowCursor::default();
            state.anchor_dirty = true;
            state.dirty = true;
            state.barrier_armed = true;
            state.last_cause = VibeDeltaCause::Anchor;
        }
        let delta = self.recompute(chat_id, now_ms);
        let window = self.current_window(chat_id)?;
        Ok(VibeTimelineWindowResultV1 { window, delta })
    }

    /// The window the consumer should currently be showing.
    pub fn current_window(&self, chat_id: &str) -> Result<VibeTimelineWindowV1, VibeCoreError> {
        let state = self.chats.get(chat_id).ok_or(VibeCoreError::UnknownChat)?;
        Ok(VibeTimelineWindowV1 {
            chat_id: chat_id.to_string(),
            generation: state.generation,
            messages: state.committed_window.clone(),
            bounds: state.committed_bounds,
            anchor: state.anchor.clone(),
            // Cached from the last resolution rather than re-resolved: this is a
            // read API and must not become O(store).
            anchor_resolution: state.anchor_resolution,
            unread: state.committed_unread.clone(),
        })
    }

    /// Scroll-back one page. Returns a delta when the window actually moved.
    pub fn page_before(
        &mut self,
        chat_id: &str,
        now_ms: i64,
    ) -> Result<Option<VibeTimelineDeltaV1>, VibeCoreError> {
        let policy = self.config.window_policy;
        {
            let state = self
                .chats
                .get_mut(chat_id)
                .ok_or(VibeCoreError::UnknownChat)?;
            let total = state.messages.len();
            let next = state.cursor.paged_before(total, policy);
            if next == state.cursor {
                return Ok(None);
            }
            state.cursor = next;
            state.dirty = true;
            state.barrier_armed = true;
            state.last_cause = VibeDeltaCause::Page;
        }
        Ok(self.recompute(chat_id, now_ms))
    }

    /// Scroll forward one page.
    pub fn page_after(
        &mut self,
        chat_id: &str,
        now_ms: i64,
    ) -> Result<Option<VibeTimelineDeltaV1>, VibeCoreError> {
        let policy = self.config.window_policy;
        {
            let state = self
                .chats
                .get_mut(chat_id)
                .ok_or(VibeCoreError::UnknownChat)?;
            let total = state.messages.len();
            let next = state.cursor.paged_after(total, policy);
            if next == state.cursor {
                return Ok(None);
            }
            state.cursor = next;
            state.dirty = true;
            state.barrier_armed = true;
            state.last_cause = VibeDeltaCause::Page;
        }
        Ok(self.recompute(chat_id, now_ms))
    }

    /// Recovery for a consumer that saw a generation gap.
    ///
    /// Always returns a `Reset` carrying the full current window. There is no
    /// path that asks the consumer to infer anything. Reset is a full snapshot:
    /// consumers adopt it regardless of `base_generation`; see
    /// [`VibeTimelineDeltaV1::accepts_consumer_generation`].
    pub fn resync(&mut self, chat_id: &str) -> Result<VibeTimelineDeltaV1, VibeCoreError> {
        let window = self.current_window(chat_id)?;
        let state = self
            .chats
            .get_mut(chat_id)
            .ok_or(VibeCoreError::UnknownChat)?;
        let base_generation = state.generation;
        state.generation += 1;
        let bounds = window.bounds;
        let unread = window.unread.clone();
        let mut reset_window = window;
        reset_window.generation = state.generation;
        self.counters.resets_emitted += 1;
        Ok(VibeTimelineDeltaV1 {
            chat_id: chat_id.to_string(),
            generation: state.generation,
            base_generation,
            body: VibeTimelineDeltaBodyV1::Reset(Box::new(reset_window)),
            bounds,
            unread,
            cause: VibeDeltaCause::Reset,
        })
    }

    // -----------------------------------------------------------------------
    // Event application
    // -----------------------------------------------------------------------

    fn apply_event(&mut self, chat_id: &str, event: &VibeCoreEventV1, now_ms: i64) {
        match &event.body {
            VibeEventBody::Flush => {}
            VibeEventBody::RawFrame { json } => {
                let out = {
                    let ctx = self.canonical_context(chat_id);
                    canonicalize_frame(json, &ctx)
                };
                match out {
                    Ok(out) => self.absorb(chat_id, out, event),
                    Err(_) => self.counters.frames_dropped += 1,
                }
            }
            VibeEventBody::RawFrames { json_array } => {
                let out = {
                    let ctx = self.canonical_context(chat_id);
                    canonicalize_frames(json_array, &ctx)
                };
                match out {
                    Ok(out) => self.absorb(chat_id, out, event),
                    Err(_) => self.counters.frames_dropped += 1,
                }
            }
            VibeEventBody::Edit {
                message_id,
                body,
                edited_at_ms,
            } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                let target = resolve_alias(state, message_id);
                if state.tombstones.contains_key(&target)
                    || state.tombstones.contains_key(message_id)
                {
                    return;
                }
                let Some(index) = index_of(state, &target) else {
                    let evicted = remember_pending_edit(
                        state,
                        target,
                        PendingEdit {
                            body: body.clone(),
                            edited_at_ms: *edited_at_ms,
                            seq: event.seq,
                        },
                    );
                    self.counters.pending_mutations_buffered += 1;
                    self.counters.pending_mutations_evicted += u64::from(evicted);
                    return;
                };
                {
                    let m = &mut state.messages[index];
                    // Monotone: a reconnect replaying an older edit must not
                    // resurrect old text.
                    if m.edit.is_some_and(|e| e.edited_at_ms >= *edited_at_ms) {
                        return;
                    }
                    m.body = body.clone();
                    m.edit = Some(crate::types::VibeEditState {
                        edited_at_ms: *edited_at_ms,
                    });
                    m.rehash();
                    state.dirty = true;
                }
            }
            VibeEventBody::Delete {
                message_id,
                for_everyone,
                tombstone_ms,
            } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                let target = resolve_alias(state, message_id);
                state.tombstones.insert(target.clone(), *tombstone_ms);
                state.tombstones.insert(message_id.clone(), *tombstone_ms);
                let before = state.messages.len();
                state.messages.retain(|m| m.message_id != target);
                state.positions.remove(&target);
                state.frame_sources.remove(&target);
                state.live_row_ids.remove(&target);
                forget_pending(state, &target);
                forget_pending(state, message_id);
                state.receipts.forget(&target);
                state.settle_slots.forget(&target);
                if state.messages.len() != before {
                    state.dirty = true;
                    self.counters.tombstones_applied += 1;
                }
                let _ = for_everyone;
            }
            VibeEventBody::Receipt {
                message_id,
                reader_user_id,
                kind,
                at_ms,
            } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                let target = resolve_alias(state, message_id);
                if state
                    .receipts
                    .apply_receipt(&target, reader_user_id, *kind, *at_ms)
                {
                    state.dirty = true;
                }
            }
            VibeEventBody::LocalStatus {
                message_id,
                status,
                allow_downgrade,
            } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                let target = resolve_alias(state, message_id);
                if state
                    .receipts
                    .apply_local(&target, *status, *allow_downgrade)
                {
                    state.dirty = true;
                }
            }
            VibeEventBody::UploadProgress {
                message_id,
                fraction,
            } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                let target = resolve_alias(state, message_id);
                if state.tombstones.contains_key(&target)
                    || state.tombstones.contains_key(message_id)
                {
                    return;
                }
                let Some(index) = index_of(state, &target) else {
                    let evicted = remember_pending_upload(
                        state,
                        target,
                        PendingUpload {
                            fraction: *fraction,
                            seq: event.seq,
                        },
                    );
                    self.counters.pending_mutations_buffered += 1;
                    self.counters.pending_mutations_evicted += u64::from(evicted);
                    return;
                };
                {
                    let m = &mut state.messages[index];
                    if m.delivery.upload != *fraction {
                        m.delivery.upload = *fraction;
                        m.rehash();
                        state.dirty = true;
                    }
                }
            }
            VibeEventBody::ReadCursor {
                up_to_ts_ms,
                up_to_message_id,
            } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                if state
                    .receipts
                    .advance_read_cursor(*up_to_ts_ms, up_to_message_id)
                {
                    state.dirty = true;
                }
            }
            VibeEventBody::ChatCleared { before_ts_ms } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                let cutoff = before_ts_ms.unwrap_or(i64::MAX);
                let previous = state.cleared_before_ms.unwrap_or(i64::MIN);
                state.cleared_before_ms = Some(previous.max(cutoff));
                let before = state.messages.len();
                state.messages.retain(|m| m.ts_ms >= cutoff);
                state.positions.retain(|_, ts| *ts >= cutoff);
                state
                    .frame_sources
                    .retain(|message_id, _| state.positions.contains_key(message_id));
                state
                    .live_row_ids
                    .retain(|message_id| state.positions.contains_key(message_id));
                if before_ts_ms.is_none() {
                    state.pending_edits.clear();
                    state.pending_uploads.clear();
                    state.pending_agents.clear();
                }
                if state.messages.len() != before {
                    state.dirty = true;
                    self.counters.tombstones_applied += (before - state.messages.len()) as u64;
                }
            }
            VibeEventBody::OpaqueAgent {
                message_id,
                kind,
                sealed,
            } => {
                let Some(state) = self.chats.get_mut(chat_id) else {
                    return;
                };
                let target = resolve_alias(state, message_id);
                if state.tombstones.contains_key(&target)
                    || state.tombstones.contains_key(message_id)
                {
                    return;
                }
                let Some(index) = index_of(state, &target) else {
                    let evicted = remember_pending_agent(
                        state,
                        target,
                        PendingAgent {
                            kind: kind.clone(),
                            sealed: sealed.clone(),
                            received_at_ms: event.received_at_ms,
                            seq: event.seq,
                        },
                    );
                    self.counters.pending_mutations_buffered += 1;
                    self.counters.pending_mutations_evicted += u64::from(evicted);
                    return;
                };
                {
                    let m = &mut state.messages[index];
                    let agent = m.agent.get_or_insert_with(|| VibeAgentRef {
                        provider: kind.to_ascii_lowercase(),
                        task_id: None,
                        session_id: None,
                        sealed: None,
                        progress: Vec::new(),
                        is_streaming: false,
                        elapsed_ms: None,
                    });
                    agent.sealed = Some(sealed.clone());
                    m.rehash();
                    state.dirty = true;
                }
            }
            VibeEventBody::IdHealed {
                client_message_id,
                canonical_message_id,
            } => self.heal_id(chat_id, client_message_id, canonical_message_id),
        }
        let _ = now_ms;
    }

    fn canonical_context<'a>(&'a self, chat_id: &'a str) -> VibeCanonicalContext<'a> {
        let is_saved = self
            .chats
            .get(chat_id)
            .is_some_and(|s| s.profile.class == VibeChatClass::SavedMessages);
        VibeCanonicalContext {
            chat_id,
            own_user_id: &self.config.own_user_id,
            is_saved_messages: is_saved,
            aead: self.config.aead.as_ref(),
            unwrapper: self.config.unwrapper.as_ref(),
        }
    }

    fn absorb(
        &mut self,
        chat_id: &str,
        mut out: crate::canonical::VibeCanonicalOutput,
        event: &VibeCoreEventV1,
    ) {
        self.counters.frames_dropped += out.dropped.len() as u64;
        self.thumbnails.append(&mut out.thumbnails);
        let decrypt_failures = out
            .messages
            .iter()
            .filter(|m| m.flags.contains(VibeMessageFlags::DECRYPTION_FAILED))
            .count() as u64;
        self.counters.decrypt_failures += decrypt_failures;

        let Some(state) = self.chats.get_mut(chat_id) else {
            return;
        };

        let is_optimistic = matches!(event.source, crate::types::VibeEventSource::Optimistic);
        let mut touched = false;
        let mut conflicts_resolved = 0u64;

        for message in out.messages {
            // A tombstone outlives the window and is checked before every insert;
            // it is lifted only by an explicit undelete, never by a re-ingest.
            if state.tombstones.contains_key(&message.message_id) {
                continue;
            }
            if state
                .cleared_before_ms
                .is_some_and(|cutoff| message.ts_ms < cutoff)
            {
                continue;
            }
            if state.suppressed.contains(&message.message_id) {
                self.counters.duplicates_suppressed += 1;
                continue;
            }

            // Settle-slot adoption: a settled reply keeps the position the
            // optimistic bubble already occupies.
            if is_optimistic {
                state
                    .settle_slots
                    .record(&message.message_id, message.ts_ms);
            }

            // O(log n) by construction: `positions` answers membership and the
            // ordered vector is binary-searched. A linear scan here would make
            // ingest O(store), which a 100k-message chat cannot afford.
            let existing_index = index_of(state, &message.message_id);
            let existing_source = state
                .frame_sources
                .get(&message.message_id)
                .copied()
                .unwrap_or(VibeEventSource::StoreRestore);
            let (mut resolved, resolved_source) = match existing_index {
                Some(index) if state.messages[index] == message => {
                    let strongest = stronger_source(existing_source, event.source);
                    state
                        .frame_sources
                        .insert(message.message_id.clone(), strongest);
                    if event.source.is_stream()
                        && message.flags.contains(VibeMessageFlags::STREAMING)
                    {
                        state.live_row_ids.insert(message.message_id.clone());
                    }
                    continue; // idempotent replay
                }
                Some(index) => {
                    conflicts_resolved += 1;
                    if prefer_incoming_frame(
                        &state.messages[index],
                        &message,
                        existing_source,
                        event.source,
                    ) {
                        (message, event.source)
                    } else {
                        (state.messages[index].clone(), existing_source)
                    }
                }
                None => (message, event.source),
            };

            apply_pending_mutations(state, &mut resolved);
            state.settle_slots.apply(&mut resolved);
            resolved.rehash();

            if event.source.is_stream() && resolved.flags.contains(VibeMessageFlags::STREAMING) {
                state.live_row_ids.insert(resolved.message_id.clone());
            } else if !resolved.flags.contains(VibeMessageFlags::STREAMING) {
                state.live_row_ids.remove(&resolved.message_id);
            }
            state
                .frame_sources
                .insert(resolved.message_id.clone(), resolved_source);

            match existing_index {
                Some(index) => {
                    if state.messages[index] == resolved {
                        continue;
                    }
                    let moved = state.messages[index].ts_ms != resolved.ts_ms;
                    state
                        .positions
                        .insert(resolved.message_id.clone(), resolved.ts_ms);
                    if moved {
                        // The order key changed (settle-slot adoption, or a
                        // server timestamp correcting an optimistic one):
                        // re-seat the row instead of re-sorting the store.
                        state.messages.remove(index);
                        let at =
                            crate::order::insertion_index(&state.messages, &resolved.order_key());
                        state.messages.insert(at, resolved);
                    } else {
                        state.messages[index] = resolved;
                    }
                    touched = true;
                }
                None => {
                    state
                        .positions
                        .insert(resolved.message_id.clone(), resolved.ts_ms);
                    let at = crate::order::insertion_index(&state.messages, &resolved.order_key());
                    state.messages.insert(at, resolved);
                    touched = true;
                }
            }
        }

        self.counters.raw_frame_conflicts_resolved += conflicts_resolved;

        if touched {
            state.dirty = true;
            if matches!(event.source, crate::types::VibeEventSource::HistoryPage) {
                state.last_cause = VibeDeltaCause::Page;
            } else if matches!(event.source, crate::types::VibeEventSource::StoreRestore) {
                state.last_cause = VibeDeltaCause::Restore;
            }
        }
    }

    /// Optimistic → server id reconciliation.
    fn heal_id(&mut self, chat_id: &str, client_id: &str, canonical_id: &str) {
        let Some(state) = self.chats.get_mut(chat_id) else {
            return;
        };
        if client_id.is_empty() || canonical_id.is_empty() || client_id == canonical_id {
            return;
        }
        state
            .aliases
            .insert(client_id.to_string(), canonical_id.to_string());
        state.settle_slots.realias(client_id, canonical_id);
        state.receipts.realias(client_id, canonical_id);
        realias_pending(state, client_id, canonical_id);

        if state.live_row_ids.remove(client_id) {
            state.live_row_ids.insert(canonical_id.to_string());
        }
        if let Some(source) = state.frame_sources.remove(client_id) {
            let current = state.frame_sources.get(canonical_id).copied();
            state.frame_sources.insert(
                canonical_id.to_string(),
                current.map_or(source, |value| stronger_source(value, source)),
            );
        }

        let has_canonical = state.positions.contains_key(canonical_id);
        let client_pos = state
            .messages
            .iter()
            .position(|m| m.message_id == client_id);

        match (client_pos, has_canonical) {
            (Some(i), true) => {
                // The server row already landed: drop the optimistic twin.
                state.messages.remove(i);
                state.positions.remove(client_id);
                update_canonical_after_heal(state, canonical_id, client_id);
                state.dirty = true;
            }
            (Some(i), false) => {
                let mut healed = state.messages.remove(i);
                state.positions.remove(client_id);
                healed.client_message_id = Some(client_id.to_string());
                healed.message_id = canonical_id.to_string();
                state.settle_slots.apply(&mut healed);
                healed.rehash();
                state
                    .positions
                    .insert(canonical_id.to_string(), healed.ts_ms);
                let at = crate::order::insertion_index(&state.messages, &healed.order_key());
                state.messages.insert(at, healed);
                state.dirty = true;
            }
            (None, true) => {
                // The acknowledgement can arrive after a canonical frame but
                // after the optimistic twin was already deduplicated. Retain
                // the client id on the canonical row so anchors still resolve.
                update_canonical_after_heal(state, canonical_id, client_id);
            }
            (None, false) => {}
        }
    }
}

fn source_rank(source: VibeEventSource) -> u8 {
    match source {
        VibeEventSource::StoreRestore => 0,
        VibeEventSource::HistoryPage => 1,
        VibeEventSource::BridgeMirror => 2,
        VibeEventSource::SavedMessages => 3,
        VibeEventSource::Optimistic => 4,
        VibeEventSource::Local => 5,
        VibeEventSource::UserTopic => 6,
        VibeEventSource::ChatTopic => 7,
    }
}

fn stronger_source(left: VibeEventSource, right: VibeEventSource) -> VibeEventSource {
    if source_rank(right) > source_rank(left) {
        right
    } else {
        left
    }
}

/// Deterministic same-id conflict selection.
///
/// Explicit edit clocks dominate. Otherwise the more authoritative transport
/// wins; equal-authority conflicts use terminal/completeness facts and finally
/// the stable rendered-content hash. The last step is deliberately arbitrary
/// but commutative: without a server revision field there is no honest way to
/// infer which of two unedited, same-id bodies is newer, but every replay must at
/// least converge to the same one.
fn prefer_incoming_frame(
    existing: &VibeMessageSnapshotV1,
    incoming: &VibeMessageSnapshotV1,
    existing_source: VibeEventSource,
    incoming_source: VibeEventSource,
) -> bool {
    frame_revision_key(incoming, incoming_source) > frame_revision_key(existing, existing_source)
}

fn frame_revision_key(
    message: &VibeMessageSnapshotV1,
    source: VibeEventSource,
) -> (i64, u8, u8, u8, u64) {
    let edit_clock = message.edit.map_or(i64::MIN, |edit| edit.edited_at_ms);
    let terminal = u8::from(!message.flags.contains(VibeMessageFlags::STREAMING));
    let decryptable = u8::from(!message.flags.contains(VibeMessageFlags::DECRYPTION_FAILED));
    let completeness = u8::from(!message.body.is_empty())
        + u8::from(message.media.is_some())
        + u8::from(message.reply.is_some())
        + u8::from(message.agent.is_some())
        + u8::from(message.service.is_some());
    (
        edit_clock,
        source_rank(source),
        terminal + decryptable,
        completeness,
        message.content_hash,
    )
}

fn remember_suppressed(state: &mut ChatState, message_id: String) {
    if state.suppressed.insert(message_id.clone()) {
        state.suppressed_order.push_back(message_id);
    }
    while state.suppressed_order.len() > MAX_SUPPRESSED_IDS {
        if let Some(retired) = state.suppressed_order.pop_front() {
            state.suppressed.remove(&retired);
        }
    }
}

fn remember_pending_edit(state: &mut ChatState, message_id: String, edit: PendingEdit) -> bool {
    let should_replace = state.pending_edits.get(&message_id).is_none_or(|current| {
        edit.edited_at_ms > current.edited_at_ms
            || (edit.edited_at_ms == current.edited_at_ms
                && body_order_key(&edit.body) > body_order_key(&current.body))
    });
    if should_replace {
        state.pending_edits.insert(message_id, edit);
    }
    evict_oldest_pending_edit(&mut state.pending_edits)
}

fn remember_pending_upload(
    state: &mut ChatState,
    message_id: String,
    upload: PendingUpload,
) -> bool {
    if state
        .pending_uploads
        .get(&message_id)
        .is_none_or(|current| upload.seq >= current.seq)
    {
        state.pending_uploads.insert(message_id, upload);
    }
    evict_oldest_by_seq(&mut state.pending_uploads, |value| value.seq)
}

fn remember_pending_agent(state: &mut ChatState, message_id: String, agent: PendingAgent) -> bool {
    if state.pending_agents.get(&message_id).is_none_or(|current| {
        (
            agent.received_at_ms,
            agent.sealed.change_token(),
            agent.kind.as_str(),
        ) >= (
            current.received_at_ms,
            current.sealed.change_token(),
            current.kind.as_str(),
        )
    }) {
        state.pending_agents.insert(message_id, agent);
    }
    evict_oldest_by_seq(&mut state.pending_agents, |value| value.seq)
}

fn body_order_key(body: &VibeMessageBody) -> (&str, &str) {
    (&body.text, body.caption.as_deref().unwrap_or(""))
}

fn evict_oldest_pending_edit(map: &mut HashMap<String, PendingEdit>) -> bool {
    evict_oldest_by_seq(map, |value| value.seq)
}

fn evict_oldest_by_seq<T>(map: &mut HashMap<String, T>, sequence: impl Fn(&T) -> u64) -> bool {
    if map.len() <= MAX_PENDING_MUTATIONS {
        return false;
    }
    let oldest = map
        .iter()
        .min_by(|(left_id, left), (right_id, right)| {
            (sequence(left), left_id.as_str()).cmp(&(sequence(right), right_id.as_str()))
        })
        .map(|(id, _)| id.clone());
    if let Some(id) = oldest {
        map.remove(&id);
        true
    } else {
        false
    }
}

fn forget_pending(state: &mut ChatState, message_id: &str) {
    state.pending_edits.remove(message_id);
    state.pending_uploads.remove(message_id);
    state.pending_agents.remove(message_id);
}

fn apply_pending_mutations(state: &mut ChatState, message: &mut VibeMessageSnapshotV1) {
    if let Some(edit) = state.pending_edits.remove(&message.message_id) {
        let should_apply = message.edit.is_none_or(|current| {
            edit.edited_at_ms > current.edited_at_ms
                || (edit.edited_at_ms == current.edited_at_ms
                    && body_order_key(&edit.body) > body_order_key(&message.body))
        });
        if should_apply {
            message.body = edit.body;
            message.edit = Some(crate::types::VibeEditState {
                edited_at_ms: edit.edited_at_ms,
            });
        }
    }
    if let Some(upload) = state.pending_uploads.remove(&message.message_id) {
        message.delivery.upload = upload.fraction;
    }
    if let Some(pending) = state.pending_agents.remove(&message.message_id) {
        let agent = message.agent.get_or_insert_with(|| VibeAgentRef {
            provider: pending.kind.to_ascii_lowercase(),
            task_id: None,
            session_id: None,
            sealed: None,
            progress: Vec::new(),
            is_streaming: false,
            elapsed_ms: None,
        });
        agent.sealed = Some(pending.sealed);
    }
}

fn realias_pending(state: &mut ChatState, from_id: &str, to_id: &str) {
    if let Some(edit) = state.pending_edits.remove(from_id) {
        let _ = remember_pending_edit(state, to_id.to_string(), edit);
    }
    if let Some(upload) = state.pending_uploads.remove(from_id) {
        let _ = remember_pending_upload(state, to_id.to_string(), upload);
    }
    if let Some(agent) = state.pending_agents.remove(from_id) {
        let _ = remember_pending_agent(state, to_id.to_string(), agent);
    }
}

fn update_canonical_after_heal(state: &mut ChatState, canonical_id: &str, client_id: &str) {
    let Some(index) = index_of(state, canonical_id) else {
        return;
    };
    let previous = state.messages[index].clone();
    let mut canonical = state.messages.remove(index);
    if canonical.client_message_id.is_none() {
        canonical.client_message_id = Some(client_id.to_string());
    }
    apply_pending_mutations(state, &mut canonical);
    state.settle_slots.apply(&mut canonical);
    canonical.rehash();
    state
        .positions
        .insert(canonical.message_id.clone(), canonical.ts_ms);
    let at = crate::order::insertion_index(&state.messages, &canonical.order_key());
    let changed = canonical != previous || at != index;
    state.messages.insert(at, canonical);
    state.dirty |= changed;
}

/// Keeps a non-tail window attached to the same mounted identities when store
/// mutations happen before it. The search is bounded by the committed window
/// contract (<=300), and each lookup is O(log store).
fn rebase_cursor_to_committed_origin(state: &mut ChatState) {
    let origin = state
        .committed_window
        .iter()
        .enumerate()
        .find_map(|(old_offset, message)| {
            let current_id = resolve_alias(state, &message.message_id);
            index_of(state, &current_id).map(|new_index| (old_offset, new_index))
        });
    if let Some((old_offset, new_index)) = origin {
        state.cursor.start = new_index.saturating_sub(old_offset);
    }
}

/// Index of a message in the ordered store, in O(log n).
///
/// `positions` answers "is this id here, and at what timestamp"; the ordered
/// vector is then binary-searched on the total-order key. Any code path that
/// reaches for `.iter().find(...)` over `messages` is an O(store) bug waiting
/// for a large chat — the 100k benchmark caught exactly that.
fn index_of(state: &ChatState, message_id: &str) -> Option<usize> {
    let ts = *state.positions.get(message_id)?;
    state
        .messages
        .binary_search_by(|m| {
            m.ts_ms
                .cmp(&ts)
                .then_with(|| m.message_id.as_str().cmp(message_id))
        })
        .ok()
}

fn resolve_alias(state: &ChatState, message_id: &str) -> String {
    state
        .aliases
        .get(message_id)
        .cloned()
        .unwrap_or_else(|| message_id.to_string())
}

fn unread_state(state: &ChatState, own_user_id: &str) -> VibeUnreadState {
    unread_state_ref(state, own_user_id)
}

/// Unread is always derived, never a server-pushed integer: server counters and
/// local tombstones disagree constantly in this app.
fn unread_state_ref(state: &ChatState, own_user_id: &str) -> VibeUnreadState {
    let start = match state.receipts.read_cursor() {
        Some(cursor) => state.messages.partition_point(|m| {
            (m.ts_ms, m.message_id.as_str())
                <= (cursor.up_to_ts_ms, cursor.up_to_message_id.as_str())
        }),
        None => 0,
    };

    let mut count = 0u32;
    let mut first_unread_id = None;
    for m in state.messages.iter().skip(start) {
        // Case-insensitive id compare — see `canonical::resolve_is_me`. Byte-exact
        // here would count the user's own messages as unread.
        if m.author.is_me
            || (!own_user_id.is_empty() && m.author.user_id.eq_ignore_ascii_case(own_user_id))
        {
            continue;
        }
        if m.flags.contains(VibeMessageFlags::HIDDEN_FROM_TRANSCRIPT) {
            continue;
        }
        if first_unread_id.is_none() {
            first_unread_id = Some(m.message_id.clone());
        }
        count += 1;
        if count >= UNREAD_COUNT_CAP {
            break;
        }
    }

    VibeUnreadState {
        count,
        first_unread_id,
        muted: state.profile.muted,
    }
}
