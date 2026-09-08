//! FFI-shaped mirrors of the core's render-facing types.
//!
//! # Why mirrors instead of exporting the core types directly
//!
//! `vibe_core` has no FFI dependency and is not going to grow one. Deriving
//! UniFFI traits on its types would pull `uniffi` into a crate whose stated
//! property is "no FFI, no SQLite, no network", and would let the shape of the
//! Swift binding start dictating the shape of the reduction. The conversion cost
//! is one pass per *commit*, not per cell, so it does not matter.
//!
//! # Flattened where it helps, complete where it must be
//!
//! The scalar columns — identity, order, author, kind, text, flags, delivery —
//! are flattened rather than nested, which keeps the generated Swift value types
//! small and the per-window allocation count down. A 300-message window is
//! already ~3,000 allocations and must never be built on the main thread.
//!
//! Media, reply, agent and service ride as **full optional records**. They were
//! presence booleans while this boundary only served an order comparison; a
//! renderer that builds real rows needs the detail, and a boolean cannot size a
//! bubble. The booleans are retained alongside them — appended, never
//! repurposed, per the evolution rule in §4.3 of the refactor doc — so a consumer
//! that only asks "is there media" does not marshal the record to find out.
//!
//! Still deliberately absent: media and thumbnail **bytes**. A
//! [`VibeFfiThumb`] carries a vault identity and the platform resolves the
//! pixels (C2).

use vibe_core::types::{
    VibeAgentProgressNode, VibeAgentRef, VibeDisplayStatus, VibeEventSource, VibeMediaEnvelope,
    VibeMediaRef, VibeMessageKind, VibeMessageSnapshotV1, VibeReplyRef, VibeServiceChip,
    VibeServiceNode, VibeSize, VibeThumbHandle, VibeTimelineDeltaBodyV1, VibeTimelineDeltaV1,
    VibeTimelineOpV1, VibeTimelineWindowV1, VibeWindowBounds,
};

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiReaction {
    pub emoji: String,
    pub count: u64,
    pub is_selected: bool,
}

/// Which ingest source a frame arrived on. Mirrors [`VibeEventSource`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiSource {
    HistoryPage,
    ChatTopic,
    UserTopic,
    Optimistic,
    StoreRestore,
    BridgeMirror,
    SavedMessages,
    Local,
}

impl From<VibeFfiSource> for VibeEventSource {
    fn from(value: VibeFfiSource) -> Self {
        match value {
            VibeFfiSource::HistoryPage => Self::HistoryPage,
            VibeFfiSource::ChatTopic => Self::ChatTopic,
            VibeFfiSource::UserTopic => Self::UserTopic,
            VibeFfiSource::Optimistic => Self::Optimistic,
            VibeFfiSource::StoreRestore => Self::StoreRestore,
            VibeFfiSource::BridgeMirror => Self::BridgeMirror,
            VibeFfiSource::SavedMessages => Self::SavedMessages,
            VibeFfiSource::Local => Self::Local,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiMessageKind {
    Text,
    Image,
    Video,
    Voice,
    Music,
    File,
    Sticker,
    Location,
    Contact,
    Service,
    AgentTurn,
}

impl From<VibeMessageKind> for VibeFfiMessageKind {
    fn from(value: VibeMessageKind) -> Self {
        match value {
            VibeMessageKind::Text => Self::Text,
            VibeMessageKind::Image => Self::Image,
            VibeMessageKind::Video => Self::Video,
            VibeMessageKind::Voice => Self::Voice,
            VibeMessageKind::Music => Self::Music,
            VibeMessageKind::File => Self::File,
            VibeMessageKind::Sticker => Self::Sticker,
            VibeMessageKind::Location => Self::Location,
            VibeMessageKind::Contact => Self::Contact,
            VibeMessageKind::Service => Self::Service,
            VibeMessageKind::AgentTurn => Self::AgentTurn,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiDisplayStatus {
    Pending,
    Sending,
    Failed,
    Sent,
    Delivered,
    Read,
}

impl From<VibeDisplayStatus> for VibeFfiDisplayStatus {
    fn from(value: VibeDisplayStatus) -> Self {
        match value {
            VibeDisplayStatus::Pending => Self::Pending,
            VibeDisplayStatus::Sending => Self::Sending,
            VibeDisplayStatus::Failed => Self::Failed,
            VibeDisplayStatus::Sent => Self::Sent,
            VibeDisplayStatus::Delivered => Self::Delivered,
            VibeDisplayStatus::Read => Self::Read,
        }
    }
}

/// Natural pixel size of a media asset.
///
/// `None` on the owning field means **unknown**, and the renderer must reserve a
/// frame it will not later change. Guessing square and correcting after decode is
/// the list-shift bug this whole boundary exists to end.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiSize {
    pub width: u32,
    pub height: u32,
}

impl From<VibeSize> for VibeFfiSize {
    fn from(s: VibeSize) -> Self {
        Self {
            width: s.width,
            height: s.height,
        }
    }
}

/// A thumbnail reference. Never bytes — the platform resolves `identity` against
/// its media vault.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiThumb {
    pub identity: String,
    pub size: Option<VibeFfiSize>,
    pub placeholder: Option<String>,
}

impl From<&VibeThumbHandle> for VibeFfiThumb {
    fn from(t: &VibeThumbHandle) -> Self {
        Self {
            identity: t.identity.clone(),
            size: t.size.map(Into::into),
            placeholder: t.placeholder.clone(),
        }
    }
}

/// How the bytes behind a media reference are protected.
///
/// `key_ref` is the per-message media key. It crosses deliberately: the platform
/// performs the media decrypt (file I/O is not the core's job), and it cannot do
/// that without the key. This is the same key the shipped client already carries
/// inside the message payload — no new exposure.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiMediaEnvelope {
    Plain,
    Gcm1 { key_ref: String },
    Stream2 { key_ref: String, segment_len: u32 },
}

impl From<&VibeMediaEnvelope> for VibeFfiMediaEnvelope {
    fn from(e: &VibeMediaEnvelope) -> Self {
        match e {
            VibeMediaEnvelope::Plain => Self::Plain,
            VibeMediaEnvelope::Gcm1 { key_ref } => Self::Gcm1 {
                key_ref: key_ref.clone(),
            },
            VibeMediaEnvelope::Stream2 {
                key_ref,
                segment_len,
            } => Self::Stream2 {
                key_ref: key_ref.clone(),
                segment_len: *segment_len,
            },
        }
    }
}

/// Media metadata. Never the pixels.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiMedia {
    /// The only addressing key. Signed-URL churn must not change it.
    pub identity: String,
    pub remote_url: Option<String>,
    pub file_name: Option<String>,
    pub mime: Option<String>,
    pub byte_size: Option<i64>,
    /// `None` means unknown — reserve, do not guess.
    pub natural_size: Option<VibeFfiSize>,
    pub duration_s: Option<f64>,
    /// 0..=255 amplitude buckets.
    pub waveform: Vec<u8>,
    pub thumbnail: Option<VibeFfiThumb>,
    pub envelope: VibeFfiMediaEnvelope,
}

impl From<&VibeMediaRef> for VibeFfiMedia {
    fn from(m: &VibeMediaRef) -> Self {
        Self {
            identity: m.identity.clone(),
            remote_url: m.remote_url.clone(),
            file_name: m.file_name.clone(),
            mime: m.mime.clone(),
            byte_size: m.byte_size,
            natural_size: m.natural_size.map(Into::into),
            duration_s: m.duration_s,
            waveform: m.waveform.clone(),
            thumbnail: m.thumbnail.as_ref().map(Into::into),
            envelope: (&m.envelope).into(),
        }
    }
}

/// Reply-to reference, with the quoted preview.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiReply {
    pub message_id: String,
    pub author_user_id: Option<String>,
    pub preview_text: String,
    pub preview_thumb: Option<VibeFfiThumb>,
}

impl From<&VibeReplyRef> for VibeFfiReply {
    fn from(r: &VibeReplyRef) -> Self {
        Self {
            message_id: r.message_id.clone(),
            author_user_id: r.author_user_id.clone(),
            preview_text: r.preview.text.clone(),
            preview_thumb: r.preview_media.as_ref().map(Into::into),
        }
    }
}

/// One progress step of an agent turn.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiAgentNode {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub detail: Option<String>,
    pub is_terminal: bool,
}

impl From<&VibeAgentProgressNode> for VibeFfiAgentNode {
    fn from(n: &VibeAgentProgressNode) -> Self {
        Self {
            id: n.id.clone(),
            kind: n.kind.clone(),
            label: n.label.clone(),
            detail: n.detail.clone(),
            is_terminal: n.is_terminal,
        }
    }
}

/// Agent turn payload.
///
/// `sealed` is the `arte1` runtime blob. It crosses as **opaque bytes**: the core
/// never opened it and never could — the pairing key lives only on the phone.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiAgent {
    pub provider: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub sealed: Option<Vec<u8>>,
    pub progress: Vec<VibeFfiAgentNode>,
    pub is_streaming: bool,
    pub elapsed_ms: Option<i64>,
}

impl From<&VibeAgentRef> for VibeFfiAgent {
    fn from(a: &VibeAgentRef) -> Self {
        Self {
            provider: a.provider.clone(),
            task_id: a.task_id.clone(),
            session_id: a.session_id.clone(),
            sealed: a.sealed.as_ref().map(|b| b.as_bytes().to_vec()),
            progress: a.progress.iter().map(Into::into).collect(),
            is_streaming: a.is_streaming,
            elapsed_ms: a.elapsed_ms,
        }
    }
}

/// A decision chip on a service notice.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiServiceChip {
    pub id: String,
    pub label: String,
    pub style: String,
}

impl From<&VibeServiceChip> for VibeFfiServiceChip {
    fn from(c: &VibeServiceChip) -> Self {
        Self {
            id: c.id.clone(),
            label: c.label.clone(),
            style: c.style.clone(),
        }
    }
}

/// Structured service notice.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiService {
    pub kind: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub chips: Vec<VibeFfiServiceChip>,
    pub event_thread_id: Option<String>,
    pub folded_count: u32,
}

impl From<&VibeServiceNode> for VibeFfiService {
    fn from(s: &VibeServiceNode) -> Self {
        Self {
            kind: s.kind.clone(),
            title: s.title.clone(),
            subtitle: s.subtitle.clone(),
            chips: s.chips.iter().map(Into::into).collect(),
            event_thread_id: s.event_thread_id.clone(),
            folded_count: s.folded_count,
        }
    }
}

/// One row, flattened for rendering.
///
/// `struct_excessive_bools` is allowed deliberately. The lint's advice — collapse
/// them into a bitflags type — is right for internal Rust and wrong here: these
/// become named `Bool` properties in generated Swift, where `message.hasReply`
/// reads at a glance and `mask & .hasReply != 0` does not. The core already keeps
/// its own flags packed (`flags: u32` above); duplicating that packing for
/// presence bits would trade Swift-side clarity for nothing.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiMessage {
    pub message_id: String,
    /// Retained after id healing so anchors survive an optimistic-send ack.
    pub client_message_id: Option<String>,
    pub ts_ms: i64,
    /// Dense index within the window this snapshot was built for. Derived —
    /// never use it as a sort key.
    pub order_seq: u64,
    pub author_user_id: String,
    pub author_is_me: bool,
    /// Set for agent/bridge turns (`claude`, `codex`, …).
    pub author_agent_provider: Option<String>,
    pub kind: VibeFfiMessageKind,
    pub text: String,
    pub caption: Option<String>,
    /// Raw [`vibe_core::types::VibeMessageFlags`] bits. Kept as a bitmask rather
    /// than expanded to a dozen booleans so adding a flag is an additive change
    /// on both sides of the boundary.
    pub flags: u32,
    pub display_status: VibeFfiDisplayStatus,
    /// `Some(0.0..=1.0)` while an upload is in flight.
    pub upload_fraction: Option<f32>,
    pub delivery_failed: bool,
    /// FNV-1a over the rendered fields. A renderer can skip a reconfigure when
    /// this is unchanged.
    pub content_hash: u64,
    // Presence flags. Retained rather than replaced by the records below: the
    // evolution rule is append-never-repurpose, and a consumer that only needs
    // "is there media" should not pay to marshal the whole record to find out.
    pub has_media: bool,
    pub has_reply: bool,
    pub has_agent: bool,
    pub has_service: bool,
    pub is_edited: bool,
    // The detail itself. Appended once the renderer needed to build a real row
    // rather than compare orderings.
    pub media: Option<VibeFfiMedia>,
    pub reply: Option<VibeFfiReply>,
    pub agent: Option<VibeFfiAgent>,
    pub service: Option<VibeFfiService>,
    pub edited_at_ms: Option<i64>,
    pub reactions: Vec<VibeFfiReaction>,
    pub view_count: Option<u64>,
}

impl From<&VibeMessageSnapshotV1> for VibeFfiMessage {
    fn from(m: &VibeMessageSnapshotV1) -> Self {
        Self {
            message_id: m.message_id.clone(),
            client_message_id: m.client_message_id.clone(),
            ts_ms: m.ts_ms,
            order_seq: m.order_seq,
            author_user_id: m.author.user_id.clone(),
            author_is_me: m.author.is_me,
            author_agent_provider: m.author.agent_provider.clone(),
            kind: m.kind.into(),
            text: m.body.text.clone(),
            caption: m.body.caption.clone(),
            flags: m.flags.raw(),
            display_status: m.delivery.display.into(),
            upload_fraction: m.delivery.upload,
            delivery_failed: m.delivery.failed,
            content_hash: m.content_hash,
            has_media: m.media.is_some(),
            has_reply: m.reply.is_some(),
            has_agent: m.agent.is_some(),
            has_service: m.service.is_some(),
            is_edited: m.edit.is_some(),
            media: m.media.as_ref().map(Into::into),
            reply: m.reply.as_ref().map(Into::into),
            agent: m.agent.as_ref().map(Into::into),
            service: m.service.as_ref().map(Into::into),
            edited_at_ms: m.edit.map(|e| e.edited_at_ms),
            reactions: m
                .reactions
                .iter()
                .map(|reaction| VibeFfiReaction {
                    emoji: reaction.emoji.clone(),
                    count: reaction.count,
                    is_selected: reaction.is_selected,
                })
                .collect(),
            view_count: m.view_count,
        }
    }
}

/// One ordered mutation.
///
/// `EvictHead`/`EvictTail` stay distinct from `Remove` across the boundary on
/// purpose: collapsing them is how a scroll-back trim gets a delete animation.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum VibeFfiOp {
    Insert {
        index: u32,
        message: VibeFfiMessage,
    },
    Remove {
        index: u32,
        message_id: String,
    },
    RemapIdentity {
        index: u32,
        previous_message_id: String,
        message: VibeFfiMessage,
    },
    /// Same geometry — reconfigure pixels only.
    UpdateContent {
        index: u32,
        message: VibeFfiMessage,
        changed: u32,
    },
    /// May change height — the renderer must preserve the anchor across it.
    UpdateGeometry {
        index: u32,
        message: VibeFfiMessage,
        changed: u32,
    },
    /// Index-only relocation; content unchanged. Never animate as remove+insert.
    Move {
        from: u32,
        to: u32,
        message_id: String,
    },
    /// Window trim, **not** a deletion. Must not animate.
    EvictHead {
        count: u32,
    },
    EvictTail {
        count: u32,
    },
}

impl From<&VibeTimelineOpV1> for VibeFfiOp {
    fn from(op: &VibeTimelineOpV1) -> Self {
        match op {
            VibeTimelineOpV1::Insert { index, message } => Self::Insert {
                index: *index,
                message: message.into(),
            },
            VibeTimelineOpV1::Remove { index, message_id } => Self::Remove {
                index: *index,
                message_id: message_id.clone(),
            },
            VibeTimelineOpV1::RemapIdentity {
                index,
                previous_message_id,
                message,
            } => Self::RemapIdentity {
                index: *index,
                previous_message_id: previous_message_id.clone(),
                message: message.into(),
            },
            VibeTimelineOpV1::UpdateContent {
                index,
                message,
                changed,
            } => Self::UpdateContent {
                index: *index,
                message: message.into(),
                changed: changed.raw(),
            },
            VibeTimelineOpV1::UpdateGeometry {
                index,
                message,
                changed,
            } => Self::UpdateGeometry {
                index: *index,
                message: message.into(),
                changed: changed.raw(),
            },
            VibeTimelineOpV1::Move {
                from,
                to,
                message_id,
            } => Self::Move {
                from: *from,
                to: *to,
                message_id: message_id.clone(),
            },
            VibeTimelineOpV1::EvictHead { count } => Self::EvictHead { count: *count },
            VibeTimelineOpV1::EvictTail { count } => Self::EvictTail { count: *count },
        }
    }
}

/// Window bounds after applying a delta. Faithful mirror of
/// [`vibe_core::types::VibeWindowBounds`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiBounds {
    pub head_ts_ms: i64,
    pub tail_ts_ms: i64,
    pub has_more_before: bool,
    pub has_more_after: bool,
    /// Live rows in the durable store for this chat — not the window length.
    pub total_known: u64,
    pub window_len: u32,
}

impl From<VibeWindowBounds> for VibeFfiBounds {
    fn from(b: VibeWindowBounds) -> Self {
        Self {
            head_ts_ms: b.head_ts_ms,
            tail_ts_ms: b.tail_ts_ms,
            has_more_before: b.has_more_before,
            has_more_after: b.has_more_after,
            total_known: b.total_known,
            window_len: b.window_len,
        }
    }
}

/// A delta is either an ordered op list or a full-snapshot reset.
///
/// Kept as two variants rather than flattened to "ops, possibly empty": a
/// `Reset` is adopted by the consumer **regardless of generation**, and
/// collapsing it into an empty op list would silently drop that distinction and
/// leave a consumer stuck after a generation gap.
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum VibeFfiDeltaBody {
    Ops { ops: Vec<VibeFfiOp> },
    Reset { window: VibeFfiWindow },
}

/// One ordered delta. At most one per flush barrier.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiDelta {
    pub chat_id: String,
    /// The generation this delta applies *to*. A consumer holding a different
    /// generation must resync rather than apply.
    pub base_generation: u64,
    pub generation: u64,
    pub body: VibeFfiDeltaBody,
    /// Bounds *after* applying the body.
    pub bounds: VibeFfiBounds,
    pub unread_count: u32,
    pub first_unread_id: Option<String>,
}

impl From<&VibeTimelineDeltaV1> for VibeFfiDelta {
    fn from(d: &VibeTimelineDeltaV1) -> Self {
        let body = match &d.body {
            VibeTimelineDeltaBodyV1::Ops(ops) => VibeFfiDeltaBody::Ops {
                ops: ops.iter().map(VibeFfiOp::from).collect(),
            },
            VibeTimelineDeltaBodyV1::Reset(window) => VibeFfiDeltaBody::Reset {
                window: VibeFfiWindow::from(window.as_ref()),
            },
        };
        Self {
            chat_id: d.chat_id.clone(),
            base_generation: d.base_generation,
            generation: d.generation,
            body,
            bounds: d.bounds.into(),
            unread_count: d.unread.count,
            first_unread_id: d.unread.first_unread_id.clone(),
        }
    }
}

/// A bounded window query result.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct VibeFfiWindow {
    pub chat_id: String,
    pub generation: u64,
    pub messages: Vec<VibeFfiMessage>,
    pub bounds: VibeFfiBounds,
    pub unread_count: u32,
    pub first_unread_id: Option<String>,
}

impl From<&VibeTimelineWindowV1> for VibeFfiWindow {
    fn from(w: &VibeTimelineWindowV1) -> Self {
        Self {
            chat_id: w.chat_id.clone(),
            generation: w.generation,
            messages: w.messages.iter().map(VibeFfiMessage::from).collect(),
            bounds: w.bounds.into(),
            unread_count: w.unread.count,
            first_unread_id: w.unread.first_unread_id.clone(),
        }
    }
}
