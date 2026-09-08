//! The stable public contracts.
//!
//! Frozen names from `.vibe/team/timeline-core-refactor-0802-board.md`:
//! [`VibeCoreEventV1`], [`VibeMessageSnapshotV1`], [`VibeTimelineDeltaV1`],
//! [`VibeTimelineWindowV1`], [`VibeTimelineAnchor`].
//!
//! Evolution rule: **new fields are appended and optional; the meaning of an
//! existing field never changes; a breaking change mints a `…V2` and both
//! versions are served during rollout.**
//!
//! Two hard boundary rules are structural here rather than conventional:
//!
//! 1. **No untyped map in public egress.** Nothing in this module is a
//!    `serde_json::Value`, a `HashMap<String, String>`, or a byte blob standing
//!    in for a record. `serde_json` is an implementation detail of
//!    [`crate::canonical`] and never escapes it.
//! 2. **No media or thumbnail bytes in a snapshot.** [`VibeMediaRef`] carries a
//!    [`VibeThumbHandle`] and natural-size metadata; the platform fetches the
//!    pixels. A 300-row window must not copy megabytes across the boundary.

use crate::hash::VibeContentHasher;
use crate::secret::VibeOpaqueBlob;

// ---------------------------------------------------------------------------
// Identity and order
// ---------------------------------------------------------------------------

/// Total order key: `(ts_ms, message_id)` ascending.
///
/// This is *exactly* the Swift comparator (`ChatEngine.mergedChatRowsLocked`,
/// ascending by timestamp then lexicographic id). Preserved bit-for-bit on
/// purpose: during a migration, parity beats a theoretically better key. A
/// server-assigned sequence would tiebreak same-millisecond messages better, and
/// adopting it now would reorder history relative to the shipped client for no
/// user benefit.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct VibeOrderKey {
    pub ts_ms: i64,
    pub message_id: String,
}

impl VibeOrderKey {
    pub fn new(ts_ms: i64, message_id: impl Into<String>) -> Self {
        Self {
            ts_ms,
            message_id: message_id.into(),
        }
    }
}

/// Where the viewport is pinned when an anchor's message cannot be resolved.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeAnchorPin {
    /// Live chat: stick to the newest message.
    Bottom,
    /// Scroll-back page: stick to the oldest loaded message.
    Top,
    /// Keep the named message on screen.
    Message,
    /// Land on the first unread message.
    Unread,
}

/// Stable scroll identity.
///
/// A bare id is not safe in this repository. Saved Messages carries two ids for
/// one logical message (`id` and `original_message_id`) and the client
/// deliberately prefers the latter; optimistic sends are re-keyed to a server id
/// on ack. An anchor holding only a retired id resolves to nothing after a heal,
/// which is a scroll jump.
///
/// Resolution therefore walks a chain — see
/// [`crate::window::resolve_anchor`]:
///
/// 1. exact `message_id`;
/// 2. `client_message_id` through the id-alias table;
/// 3. nearest-not-after by `(ts_ms, message_id)`, then nearest-before;
/// 4. `pin`.
#[derive(Clone, Debug, PartialEq)]
pub struct VibeTimelineAnchor {
    pub message_id: String,
    /// Pre-ack optimistic id, when the anchor was captured before the server ack.
    pub client_message_id: Option<String>,
    pub ts_ms: i64,
    /// Dense index of the anchor inside the window it was captured from.
    /// Diagnostic and tie-break only; never an ordering authority.
    pub order_seq: u64,
    /// `0.0` = row top at viewport top, `1.0` = row bottom at viewport bottom.
    pub fraction: f32,
    pub pin: VibeAnchorPin,
}

impl VibeTimelineAnchor {
    /// The anchor a live chat opens with.
    pub fn bottom() -> Self {
        Self {
            message_id: String::new(),
            client_message_id: None,
            ts_ms: i64::MAX,
            order_seq: 0,
            fraction: 1.0,
            pin: VibeAnchorPin::Bottom,
        }
    }

    /// The anchor a scroll-back page keeps.
    pub fn at_message(message_id: impl Into<String>, ts_ms: i64) -> Self {
        Self {
            message_id: message_id.into(),
            client_message_id: None,
            ts_ms,
            order_seq: 0,
            fraction: 0.0,
            pin: VibeAnchorPin::Message,
        }
    }

    /// The anchor used when opening at the unread divider.
    pub fn unread() -> Self {
        Self {
            message_id: String::new(),
            client_message_id: None,
            ts_ms: 0,
            order_seq: 0,
            fraction: 0.0,
            pin: VibeAnchorPin::Unread,
        }
    }
}

/// How an anchor was actually satisfied. Returned alongside a window so the
/// renderer can tell "I kept your row" from "I fell back to the bottom" without
/// guessing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeAnchorResolution {
    ExactId,
    ClientIdAlias,
    NearestAfter,
    NearestBefore,
    PinnedBottom,
    PinnedTop,
    PinnedUnread,
    /// Chat has no messages at all.
    Empty,
}

// ---------------------------------------------------------------------------
// Chat classification (rollout gating, C4)
// ---------------------------------------------------------------------------

/// Risk classes for the rollout gate.
///
/// `vibeAsyncTimelineV1Enabled` stays the umbrella name and stays `false` by
/// default, but it resolves per class so one class can be rolled back without
/// taking the others with it. Rollout order is the order of this enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum VibeChatClass {
    /// The one fully understood path.
    DirectMessage,
    /// Plaintext wire today (see the production doc, § "Current security posture").
    GroupOrChannel,
    /// Dual-id, sealed-to-self, REST delete path.
    SavedMessages,
    /// Volatile-per-session, sealed opaque payloads, stream/bridge/lan dedup.
    AgentDirectMessage,
}

impl VibeChatClass {
    pub const ROLLOUT_ORDER: [Self; 4] = [
        Self::DirectMessage,
        Self::GroupOrChannel,
        Self::SavedMessages,
        Self::AgentDirectMessage,
    ];

    fn bit(self) -> u8 {
        match self {
            Self::DirectMessage => 1 << 0,
            Self::GroupOrChannel => 1 << 1,
            Self::SavedMessages => 1 << 2,
            Self::AgentDirectMessage => 1 << 3,
        }
    }
}

/// The rollout gate. Umbrella name preserved, per-class eligibility inside.
///
/// `VibeAsyncTimelineGate::default()` is off for every class — the board's
/// "default `false` until qualification".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VibeAsyncTimelineGate {
    enabled_mask: u8,
}

impl VibeAsyncTimelineGate {
    /// Everything off. This is `vibeAsyncTimelineV1Enabled == false`.
    pub fn off() -> Self {
        Self { enabled_mask: 0 }
    }

    pub fn enabling(classes: &[VibeChatClass]) -> Self {
        let mut gate = Self::off();
        for c in classes {
            gate.set(*c, true);
        }
        gate
    }

    pub fn set(&mut self, class: VibeChatClass, enabled: bool) {
        if enabled {
            self.enabled_mask |= class.bit();
        } else {
            self.enabled_mask &= !class.bit();
        }
    }

    /// `vibeAsyncTimelineV1Enabled(for:)`.
    pub fn is_enabled(self, class: VibeChatClass) -> bool {
        self.enabled_mask & class.bit() != 0
    }

    /// True when at least one class is live. The umbrella boolean.
    pub fn is_enabled_anywhere(self) -> bool {
        self.enabled_mask != 0
    }

    /// Stored form. One byte, so a rollback is one write.
    pub fn raw(self) -> u8 {
        self.enabled_mask
    }

    pub fn from_raw(raw: u8) -> Self {
        Self {
            enabled_mask: raw & 0b0000_1111,
        }
    }
}

// ---------------------------------------------------------------------------
// Ingress
// ---------------------------------------------------------------------------

/// Where an event came from. Drives the flush barrier (C1) and the dedup rules.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VibeEventSource {
    HistoryPage,
    ChatTopic,
    UserTopic,
    Optimistic,
    StoreRestore,
    /// Agent bridge live-tail. The only coalescing source.
    BridgeMirror,
    SavedMessages,
    Local,
}

impl VibeEventSource {
    /// Stream sources may be coalesced up to the flush barrier. Everything else
    /// is an immediate barrier.
    pub fn is_stream(self) -> bool {
        matches!(self, Self::BridgeMirror)
    }
}

/// Receipt kind, monotone per reader (`Delivered` < `Read`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum VibeReceiptKind {
    Delivered,
    Read,
}

/// Local send lifecycle, monotone high-water.
///
/// Ranking is the Swift `strongerDisplayStatus` ranking, including its one
/// surprise: `Failed` cannot downgrade a `Sent`. That is intentional in the
/// shipped app (a retry that errors must not un-send a delivered message) and is
/// preserved here rather than "fixed".
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum VibeLocalStatus {
    Pending,
    Sending,
    Failed,
    Sent,
    Delivered,
    Read,
}

impl VibeLocalStatus {
    fn rank(self) -> u8 {
        match self {
            Self::Pending => 1,
            Self::Sending => 2,
            Self::Failed => 3,
            Self::Sent => 4,
            Self::Delivered => 5,
            Self::Read => 6,
        }
    }

    /// Monotone join. `allow_downgrade` exists for the explicit
    /// receipt-downgrade path and is the only way to move backwards.
    pub fn join(self, other: Self, allow_downgrade: bool) -> Self {
        if allow_downgrade || other.rank() > self.rank() {
            other
        } else {
            self
        }
    }
}

/// The only ingress body. `RawFrame` keeps dictionary building out of platform
/// code entirely: the platform hands over the bytes it received.
pub enum VibeEventBody {
    /// One raw server frame, exactly as received.
    RawFrame { json: Vec<u8> },
    /// A JSON array of raw server frames (a history page).
    RawFrames { json_array: Vec<u8> },
    /// An already-opened edit. Monotone by `edited_at_ms`.
    Edit {
        message_id: String,
        body: VibeMessageBody,
        edited_at_ms: i64,
    },
    Delete {
        message_id: String,
        for_everyone: bool,
        tombstone_ms: i64,
    },
    Receipt {
        message_id: String,
        reader_user_id: String,
        kind: VibeReceiptKind,
        at_ms: i64,
    },
    LocalStatus {
        message_id: String,
        status: VibeLocalStatus,
        allow_downgrade: bool,
    },
    UploadProgress {
        message_id: String,
        fraction: Option<f32>,
    },
    /// Per-user, not per-device, and monotone.
    ReadCursor {
        up_to_ts_ms: i64,
        up_to_message_id: String,
    },
    /// Bulk tombstone. `None` clears the whole chat.
    ChatCleared { before_ts_ms: Option<i64> },
    /// Sealed agent runtime payload. Stored and forwarded, never opened.
    OpaqueAgent {
        message_id: String,
        kind: String,
        sealed: VibeOpaqueBlob,
    },
    /// Optimistic id reconciliation: the server acked `client_message_id` as
    /// `canonical_message_id`.
    IdHealed {
        client_message_id: String,
        canonical_message_id: String,
    },
    /// Explicit flush barrier. Carries no data; forces pending stream deltas out.
    Flush,
}

impl VibeEventBody {
    /// Stable, content-free label. Safe for logs and for `Debug`.
    pub fn kind_label(&self) -> &'static str {
        match self {
            Self::RawFrame { .. } => "raw_frame",
            Self::RawFrames { .. } => "raw_frames",
            Self::Edit { .. } => "edit",
            Self::Delete { .. } => "delete",
            Self::Receipt { .. } => "receipt",
            Self::LocalStatus { .. } => "local_status",
            Self::UploadProgress { .. } => "upload_progress",
            Self::ReadCursor { .. } => "read_cursor",
            Self::ChatCleared { .. } => "chat_cleared",
            Self::OpaqueAgent { .. } => "opaque_agent",
            Self::IdHealed { .. } => "id_healed",
            Self::Flush => "flush",
        }
    }
}

/// Redacting `Debug`. A `RawFrame` for a group chat is *plaintext on the wire*
/// today, so the default derive would print message bodies into any log that
/// formats an event.
impl std::fmt::Debug for VibeEventBody {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "VibeEventBody::{}", self.kind_label())
    }
}

/// The only ingress type.
pub struct VibeCoreEventV1 {
    /// Assigned by the reducer at accept time. Whatever the caller puts here is
    /// overwritten. `seq` is the sole replay-ordering authority, because
    /// `received_at_ms` is not monotonic across a clock change and the server
    /// timestamp is not unique.
    pub seq: u64,
    /// Device monotonic-ish clock at accept, in milliseconds. Drives the flush
    /// barrier and nothing else. Injected rather than read from the OS so replay
    /// is deterministic.
    pub received_at_ms: i64,
    pub chat_id: String,
    pub source: VibeEventSource,
    pub body: VibeEventBody,
}

impl VibeCoreEventV1 {
    pub fn new(
        chat_id: impl Into<String>,
        received_at_ms: i64,
        source: VibeEventSource,
        body: VibeEventBody,
    ) -> Self {
        Self {
            seq: 0,
            received_at_ms,
            chat_id: chat_id.into(),
            source,
            body,
        }
    }
}

impl std::fmt::Debug for VibeCoreEventV1 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeCoreEventV1")
            .field("seq", &self.seq)
            .field("received_at_ms", &self.received_at_ms)
            .field("chat_id", &self.chat_id)
            .field("source", &self.source)
            .field("body", &self.body)
            .finish()
    }
}

// ---------------------------------------------------------------------------
// Message snapshot
// ---------------------------------------------------------------------------

/// Rendered message class.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VibeMessageKind {
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

/// Author identity. Never carries a key or a token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VibeAuthorRef {
    pub user_id: String,
    pub is_me: bool,
    /// Set for agent/bridge turns (`claude`, `codex`, `grok`, …).
    pub agent_provider: Option<String>,
}

/// Message text. **No `Debug` derive, no serde.** Rendering is the only reason
/// this leaves the crate.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct VibeMessageBody {
    pub text: String,
    pub caption: Option<String>,
}

impl VibeMessageBody {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            caption: None,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.text.is_empty() && self.caption.as_ref().is_none_or(String::is_empty)
    }
}

/// Length-only `Debug`. Asserted by `tests/no_leakage.rs`.
impl std::fmt::Debug for VibeMessageBody {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "VibeMessageBody {{ text: <{} chars>, caption: <{} chars> }}",
            self.text.chars().count(),
            self.caption.as_ref().map_or(0, |c| c.chars().count())
        )
    }
}

/// Reply-to reference. The quoted preview is a body and is redacted the same way.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VibeReplyRef {
    pub message_id: String,
    pub author_user_id: Option<String>,
    pub preview: VibeMessageBody,
    /// Set when the quoted message carries media, so the renderer can reserve a
    /// thumbnail box without fetching anything.
    pub preview_media: Option<VibeThumbHandle>,
}

/// Edit state. Monotone: an out-of-order replay of an older edit is dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeEditState {
    pub edited_at_ms: i64,
}

/// What the checkmarks render.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum VibeDisplayStatus {
    Pending,
    Sending,
    Failed,
    Sent,
    Delivered,
    Read,
}

/// Delivery column of a message.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VibeDeliveryState {
    pub display: VibeDisplayStatus,
    /// `Some(0.0..=1.0)` while an upload is in flight.
    pub upload: Option<f32>,
    pub failed: bool,
}

impl Default for VibeDeliveryState {
    fn default() -> Self {
        Self {
            display: VibeDisplayStatus::Sent,
            upload: None,
            failed: false,
        }
    }
}

/// Message flag bitset.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct VibeMessageFlags(u32);

impl VibeMessageFlags {
    pub const NONE: Self = Self(0);
    pub const PINNED: Self = Self(1 << 0);
    pub const FORWARDED: Self = Self(1 << 1);
    pub const VIEW_ONCE: Self = Self(1 << 2);
    /// Folded into a service summary; not drawn as its own row.
    pub const HIDDEN_FROM_TRANSCRIPT: Self = Self(1 << 3);
    pub const EVENT_NOTIFICATION: Self = Self(1 << 4);
    pub const EVENT_INBOX_SUMMARY: Self = Self(1 << 5);
    /// Agent turn still producing output.
    pub const STREAMING: Self = Self(1 << 6);
    pub const AGENT_ERROR: Self = Self(1 << 7);
    /// Envelope present but unopenable. Renders the plaintext fallback.
    pub const DECRYPTION_FAILED: Self = Self(1 << 8);
    pub const SERVICE: Self = Self(1 << 9);
    /// Id is transient (`stream-`, `lan-`, `bridge-`) and must never be persisted.
    pub const TRANSIENT_ID: Self = Self(1 << 10);
    /// Deleted for everyone; the row is a tombstone placeholder.
    pub const TOMBSTONE: Self = Self(1 << 11);

    /// Flags that can change a row's height when they flip.
    const GEOMETRY_RELEVANT: Self = Self(
        Self::HIDDEN_FROM_TRANSCRIPT.0
            | Self::STREAMING.0
            | Self::SERVICE.0
            | Self::TOMBSTONE.0
            | Self::AGENT_ERROR.0
            | Self::DECRYPTION_FAILED.0,
    );

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn insert(&mut self, other: Self) {
        self.0 |= other.0;
    }

    pub fn remove(&mut self, other: Self) {
        self.0 &= !other.0;
    }

    pub fn set(&mut self, other: Self, on: bool) {
        if on {
            self.insert(other);
        } else {
            self.remove(other);
        }
    }

    pub fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub fn raw(self) -> u32 {
        self.0
    }

    /// True when the difference between two flag sets can move pixels.
    pub fn differs_geometrically(self, other: Self) -> bool {
        (self.0 ^ other.0) & Self::GEOMETRY_RELEVANT.0 != 0
    }
}

/// Natural pixel size of a media asset.
///
/// This is a **correctness** field, not an optimization. An unknown aspect ratio
/// resolved after decode is the list-shift bug; "settled geometry is immutable"
/// is unachievable without it. When the size is unknown the core says `None` and
/// the renderer must reserve a frame it will not later change — never guess
/// square and correct.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct VibeSize {
    pub width: u32,
    pub height: u32,
}

/// A thumbnail *reference*. Never bytes (C2).
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct VibeThumbHandle {
    /// Vault identity; the platform resolves it to a file.
    pub identity: String,
    pub size: Option<VibeSize>,
    /// Optional low-frequency placeholder string (blurhash-style). Bounded to a
    /// few dozen bytes by [`crate::media::MAX_PLACEHOLDER_LEN`].
    pub placeholder: Option<String>,
}

impl std::fmt::Debug for VibeThumbHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeThumbHandle")
            .field("has_identity", &!self.identity.is_empty())
            .field("size", &self.size)
            .field(
                "placeholder_len",
                &self.placeholder.as_ref().map_or(0, String::len),
            )
            .finish()
    }
}

/// How the bytes behind a [`VibeMediaRef`] are protected on the wire.
#[derive(Clone, PartialEq, Eq)]
pub enum VibeMediaEnvelope {
    /// Pre-encryption upload, or a type that was never encrypted. Passes through.
    Plain,
    /// Today's format: one AES-256-GCM message over the whole file,
    /// `iv || ciphertext || tag`. **Decode-only compatibility.** The tag covers
    /// the entire file, so it cannot be safely stream-decrypted; see
    /// [`crate::media`].
    Gcm1 { key_ref: String },
    /// Specified, not enabled. A standard segmented AEAD construction for future
    /// uploads. Parsing is implemented so old clients can recognise and refuse
    /// it; sealing is not implemented in this crate.
    Stream2 { key_ref: String, segment_len: u32 },
}

impl std::fmt::Debug for VibeMediaEnvelope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Plain => f.write_str("Plain"),
            Self::Gcm1 { .. } => f.write_str("Gcm1 { key_ref: <redacted> }"),
            Self::Stream2 { segment_len, .. } => f
                .debug_struct("Stream2")
                .field("key_ref", &"<redacted>")
                .field("segment_len", segment_len)
                .finish(),
        }
    }
}

/// Media metadata. Never the pixels.
#[derive(Clone, PartialEq)]
pub struct VibeMediaRef {
    /// Stable cache identity — the only addressing key. Signed-URL churn must
    /// not change it, or every re-open re-downloads the user's library.
    pub identity: String,
    pub remote_url: Option<String>,
    pub file_name: Option<String>,
    pub mime: Option<String>,
    pub byte_size: Option<i64>,
    pub natural_size: Option<VibeSize>,
    pub duration_s: Option<f64>,
    /// 0..=255 amplitude buckets, not floats.
    pub waveform: Vec<u8>,
    pub thumbnail: Option<VibeThumbHandle>,
    pub envelope: VibeMediaEnvelope,
}

impl std::fmt::Debug for VibeMediaRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeMediaRef")
            .field("has_identity", &!self.identity.is_empty())
            .field("has_remote_url", &self.remote_url.is_some())
            .field("has_file_name", &self.file_name.is_some())
            .field("has_mime", &self.mime.is_some())
            .field("byte_size", &self.byte_size)
            .field("natural_size", &self.natural_size)
            .field("duration_s", &self.duration_s)
            .field("waveform_buckets", &self.waveform.len())
            .field("thumbnail", &self.thumbnail)
            .field("envelope", &self.envelope)
            .finish()
    }
}

/// One plaintext progress step of an agent turn (tool call, thinking beat).
///
/// Plaintext-but-non-secret narration that the bridge already sends in the
/// clear. The sealed runtime payload is [`VibeAgentRef::sealed`].
#[derive(Clone, PartialEq, Eq)]
pub struct VibeAgentProgressNode {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub detail: Option<String>,
    pub is_terminal: bool,
}

impl std::fmt::Debug for VibeAgentProgressNode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeAgentProgressNode")
            .field("has_id", &!self.id.is_empty())
            .field("kind_len", &self.kind.chars().count())
            .field("label_len", &self.label.chars().count())
            .field(
                "detail_len",
                &self
                    .detail
                    .as_ref()
                    .map_or(0, |value| value.chars().count()),
            )
            .field("is_terminal", &self.is_terminal)
            .finish()
    }
}

/// Agent turn payload.
#[derive(Clone, PartialEq)]
pub struct VibeAgentRef {
    pub provider: String,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    /// Sealed `arte1` runtime blob. Opaque: never opened, never logged, never
    /// persisted for agent DMs.
    pub sealed: Option<VibeOpaqueBlob>,
    pub progress: Vec<VibeAgentProgressNode>,
    /// The only streaming signal available, because the runtime detail is sealed.
    pub is_streaming: bool,
    /// Elapsed wall time for the "Worked for Ns" loader.
    pub elapsed_ms: Option<i64>,
}

impl std::fmt::Debug for VibeAgentRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeAgentRef")
            .field("provider_len", &self.provider.chars().count())
            .field("has_task_id", &self.task_id.is_some())
            .field("has_session_id", &self.session_id.is_some())
            .field("sealed", &self.sealed)
            .field("progress_count", &self.progress.len())
            .field("is_streaming", &self.is_streaming)
            .field("elapsed_ms", &self.elapsed_ms)
            .finish()
    }
}

/// A decision chip on a service notice.
#[derive(Clone, PartialEq, Eq)]
pub struct VibeServiceChip {
    pub id: String,
    pub label: String,
    pub style: String,
}

impl std::fmt::Debug for VibeServiceChip {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeServiceChip")
            .field("has_id", &!self.id.is_empty())
            .field("label_len", &self.label.chars().count())
            .field("style_len", &self.style.chars().count())
            .finish()
    }
}

/// Structured service notice (membership change, call, folded event summary).
#[derive(Clone, PartialEq, Eq)]
pub struct VibeServiceNode {
    pub kind: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub chips: Vec<VibeServiceChip>,
    /// Set when this node is the folded summary of `folded_count` hidden rows.
    pub event_thread_id: Option<String>,
    pub folded_count: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VibeReactionSummary {
    pub emoji: String,
    pub count: u64,
    pub is_selected: bool,
}

impl std::fmt::Debug for VibeServiceNode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeServiceNode")
            .field("kind_len", &self.kind.chars().count())
            .field("title_len", &self.title.chars().count())
            .field(
                "subtitle_len",
                &self
                    .subtitle
                    .as_ref()
                    .map_or(0, |value| value.chars().count()),
            )
            .field("chip_count", &self.chips.len())
            .field("has_event_thread_id", &self.event_thread_id.is_some())
            .field("folded_count", &self.folded_count)
            .finish()
    }
}

/// The canonical message. One shape for iOS, Android, and web.
#[derive(Clone, Debug, PartialEq)]
pub struct VibeMessageSnapshotV1 {
    pub message_id: String,
    /// Pre-ack id, retained after healing so anchors and dedup keep working.
    pub client_message_id: Option<String>,
    pub chat_id: String,
    pub ts_ms: i64,
    /// Dense index inside the window this snapshot was produced for. Derived,
    /// never a sort key.
    pub order_seq: u64,
    pub author: VibeAuthorRef,
    pub kind: VibeMessageKind,
    pub body: VibeMessageBody,
    pub reply: Option<VibeReplyRef>,
    pub edit: Option<VibeEditState>,
    pub delivery: VibeDeliveryState,
    pub flags: VibeMessageFlags,
    pub media: Option<VibeMediaRef>,
    pub agent: Option<VibeAgentRef>,
    pub service: Option<VibeServiceNode>,
    pub reactions: Vec<VibeReactionSummary>,
    pub view_count: Option<u64>,
    /// FNV-1a over the rendered fields. Recomputed by
    /// [`VibeMessageSnapshotV1::rehash`]; never trusted from ingress.
    pub content_hash: u64,
}

impl VibeMessageSnapshotV1 {
    /// Total order key.
    pub fn order_key(&self) -> VibeOrderKey {
        VibeOrderKey::new(self.ts_ms, self.message_id.clone())
    }

    /// Recomputes [`Self::content_hash`] over exactly the rendered fields.
    ///
    /// Excluded on purpose: `order_seq` (a window artefact — including it would
    /// mark every row changed on every scroll). Sealed agent bytes contribute an
    /// opaque change token so equal-length runtime updates cannot be suppressed.
    pub fn rehash(&mut self) {
        self.content_hash = self.compute_content_hash();
    }

    pub fn compute_content_hash(&self) -> u64 {
        let mut h = VibeContentHasher::new();
        h.write_str(&self.message_id);
        h.write_opt_str(self.client_message_id.as_deref());
        h.write_i64(self.ts_ms);
        h.write_str(&self.author.user_id);
        h.write_bool(self.author.is_me);
        h.write_opt_str(self.author.agent_provider.as_deref());
        h.write_u32(self.kind as u32);
        h.write_str(&self.body.text);
        h.write_opt_str(self.body.caption.as_deref());

        match &self.reply {
            Some(r) => {
                h.write_str(&r.message_id);
                h.write_opt_str(r.author_user_id.as_deref());
                h.write_str(&r.preview.text);
                h.write_opt_str(r.preview_media.as_ref().map(|t| t.identity.as_str()));
            }
            None => h.write_sep(0x1e),
        }

        h.write_i64(self.edit.map_or(0, |e| e.edited_at_ms));
        h.write_u32(self.delivery.display as u32);
        h.write_opt_f32(self.delivery.upload);
        h.write_bool(self.delivery.failed);
        h.write_u32(self.flags.raw());

        match &self.media {
            Some(m) => {
                h.write_str(&m.identity);
                h.write_opt_str(m.mime.as_deref());
                h.write_opt_str(m.file_name.as_deref());
                h.write_i64(m.byte_size.unwrap_or(-1));
                match m.natural_size {
                    Some(s) => {
                        h.write_u32(s.width);
                        h.write_u32(s.height);
                    }
                    None => h.write_sep(0x1e),
                }
                h.write_opt_f64(m.duration_s);
                h.write_u64(m.waveform.len() as u64);
                h.write_opt_str(m.thumbnail.as_ref().map(|t| t.identity.as_str()));
                h.write_str(match &m.envelope {
                    VibeMediaEnvelope::Plain => "plain",
                    VibeMediaEnvelope::Gcm1 { .. } => "gcm1",
                    VibeMediaEnvelope::Stream2 { .. } => "stream2",
                });
            }
            None => h.write_sep(0x1e),
        }

        match &self.agent {
            Some(a) => {
                h.write_str(&a.provider);
                h.write_opt_str(a.task_id.as_deref());
                h.write_opt_str(a.session_id.as_deref());
                h.write_u64(a.sealed.as_ref().map_or(0, VibeOpaqueBlob::change_token));
                h.write_bool(a.is_streaming);
                h.write_u64(a.progress.len() as u64);
                for node in &a.progress {
                    h.write_str(&node.id);
                    h.write_str(&node.kind);
                    h.write_str(&node.label);
                    h.write_opt_str(node.detail.as_deref());
                    h.write_bool(node.is_terminal);
                }
            }
            None => h.write_sep(0x1e),
        }

        match &self.service {
            Some(s) => {
                h.write_str(&s.kind);
                h.write_str(&s.title);
                h.write_opt_str(s.subtitle.as_deref());
                h.write_opt_str(s.event_thread_id.as_deref());
                h.write_u32(s.folded_count);
                for chip in &s.chips {
                    h.write_str(&chip.id);
                    h.write_str(&chip.label);
                    h.write_str(&chip.style);
                }
            }
            None => h.write_sep(0x1e),
        }

        h.write_u64(self.reactions.len() as u64);
        for reaction in &self.reactions {
            h.write_str(&reaction.emoji);
            h.write_u64(reaction.count);
            h.write_bool(reaction.is_selected);
        }
        match self.view_count {
            Some(count) => {
                h.write_bool(true);
                h.write_u64(count);
            }
            None => h.write_bool(false),
        }

        h.finish()
    }

    /// A minimal text message, for fixtures and tests.
    pub fn text_message(
        chat_id: &str,
        message_id: &str,
        ts_ms: i64,
        author: &str,
        is_me: bool,
        text: &str,
    ) -> Self {
        let mut m = Self {
            message_id: message_id.to_string(),
            client_message_id: None,
            chat_id: chat_id.to_string(),
            ts_ms,
            order_seq: 0,
            author: VibeAuthorRef {
                user_id: author.to_string(),
                is_me,
                agent_provider: None,
            },
            kind: VibeMessageKind::Text,
            body: VibeMessageBody::text(text),
            reply: None,
            edit: None,
            delivery: VibeDeliveryState::default(),
            flags: VibeMessageFlags::NONE,
            media: None,
            agent: None,
            service: None,
            reactions: Vec::new(),
            view_count: None,
            content_hash: 0,
        };
        m.rehash();
        m
    }
}

// ---------------------------------------------------------------------------
// Egress: window
// ---------------------------------------------------------------------------

/// Bounds of the active window inside the full (possibly 100k-message) store.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VibeWindowBounds {
    pub head_ts_ms: i64,
    pub tail_ts_ms: i64,
    pub has_more_before: bool,
    pub has_more_after: bool,
    /// Live (non-tombstoned, non-hidden) rows in the durable store for this chat.
    pub total_known: u64,
    pub window_len: u32,
}

/// Unread state. Always derived from the store, never a server-pushed integer:
/// server counters and local tombstones disagree constantly in this app.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VibeUnreadState {
    pub count: u32,
    pub first_unread_id: Option<String>,
    pub muted: bool,
}

/// Bounded query result. Never more than
/// [`crate::window::VibeWindowPolicy::max_len`] messages.
#[derive(Clone, Debug, PartialEq)]
pub struct VibeTimelineWindowV1 {
    pub chat_id: String,
    pub generation: u64,
    /// Ascending by [`VibeOrderKey`].
    pub messages: Vec<VibeMessageSnapshotV1>,
    pub bounds: VibeWindowBounds,
    pub anchor: VibeTimelineAnchor,
    pub anchor_resolution: VibeAnchorResolution,
    pub unread: VibeUnreadState,
}

// ---------------------------------------------------------------------------
// Egress: delta
// ---------------------------------------------------------------------------

/// What changed in an update, as a bitset.
///
/// The renderer decides *reconfigure* vs *relayout* from this. A `DELIVERY`-only
/// change can never move a pixel; that is the "settled geometry is immutable"
/// rule expressed as data instead of as a convention.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct VibeChangeMask(u32);

impl VibeChangeMask {
    pub const NONE: Self = Self(0);
    pub const BODY: Self = Self(1 << 0);
    /// Checkmarks and upload fraction. Reserved width; can never move a pixel.
    pub const DELIVERY: Self = Self(1 << 1);
    /// Media metadata that sizes the reserved frame: natural size, duration,
    /// envelope, mime.
    pub const MEDIA_GEOMETRY: Self = Self(1 << 2);
    /// Media metadata that only changes what is painted *inside* an already
    /// reserved frame: thumbnail handle, remote URL, waveform buckets. This is
    /// the "late media replaces pixels, never height" rule as a bit.
    pub const MEDIA_PIXELS: Self = Self(1 << 3);
    pub const AGENT: Self = Self(1 << 4);
    /// A flag whose flip changes layout (streaming, service, tombstone, …).
    pub const FLAGS: Self = Self(1 << 5);
    /// A flag whose flip is cosmetic (pinned, forwarded, view-once, …).
    pub const FLAGS_COSMETIC: Self = Self(1 << 6);
    pub const REPLY: Self = Self(1 << 7);
    pub const EDIT: Self = Self(1 << 8);
    pub const SERVICE: Self = Self(1 << 9);
    /// The identity itself was re-keyed (optimistic → server id).
    pub const IDENTITY: Self = Self(1 << 10);
    /// The message's order key moved — settle-slot adoption, or a server
    /// timestamp correcting an optimistic one. Geometry-relevant because bubble
    /// grouping and day separators are derived from neighbouring timestamps.
    pub const ORDER: Self = Self(1 << 11);

    /// Everything that can change a row's height.
    const GEOMETRY: Self = Self(
        Self::BODY.0
            | Self::MEDIA_GEOMETRY.0
            | Self::AGENT.0
            | Self::REPLY.0
            | Self::EDIT.0
            | Self::SERVICE.0
            | Self::FLAGS.0
            | Self::IDENTITY.0
            | Self::ORDER.0,
    );

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn insert(&mut self, other: Self) {
        self.0 |= other.0;
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub fn raw(self) -> u32 {
        self.0
    }

    /// True when the renderer must re-measure the row.
    pub fn is_geometry_relevant(self) -> bool {
        self.0 & Self::GEOMETRY.0 != 0
    }
}

/// One resolved, ordered mutation. Apply in order; no sorting required.
#[derive(Clone, Debug, PartialEq)]
pub enum VibeTimelineOpV1 {
    Insert {
        index: u32,
        message: VibeMessageSnapshotV1,
    },
    Remove {
        index: u32,
        message_id: String,
    },
    /// Re-keys one mounted row without removing or inserting it.
    ///
    /// This is the optimistic-send acknowledgement path. The full replacement
    /// snapshot is carried because the acknowledgement can also settle order,
    /// delivery, or other rendered fields. A renderer must preserve the mounted
    /// row/view identity while changing its lookup key from
    /// `previous_message_id` to `message.message_id`.
    RemapIdentity {
        index: u32,
        previous_message_id: String,
        message: VibeMessageSnapshotV1,
    },
    /// Same geometry. Reconfigure pixels only.
    UpdateContent {
        index: u32,
        message: VibeMessageSnapshotV1,
        changed: VibeChangeMask,
    },
    /// May change height. The renderer must preserve the anchor across it.
    UpdateGeometry {
        index: u32,
        message: VibeMessageSnapshotV1,
        changed: VibeChangeMask,
    },
    /// Index-only relocation. Content unchanged. Used by settle-slot adoption,
    /// where a `Remove` + `Insert` would re-animate a row that only moved.
    Move {
        from: u32,
        to: u32,
        message_id: String,
    },
    /// Window trim at the old end. **Not** a deletion; must not animate.
    EvictHead {
        count: u32,
    },
    /// Window trim at the new end. **Not** a deletion; must not animate.
    EvictTail {
        count: u32,
    },
}

impl VibeTimelineOpV1 {
    pub fn kind_label(&self) -> &'static str {
        match self {
            Self::Insert { .. } => "insert",
            Self::Remove { .. } => "remove",
            Self::RemapIdentity { .. } => "remap_identity",
            Self::UpdateContent { .. } => "update_content",
            Self::UpdateGeometry { .. } => "update_geometry",
            Self::Move { .. } => "move",
            Self::EvictHead { .. } => "evict_head",
            Self::EvictTail { .. } => "evict_tail",
        }
    }
}

/// Why a delta was produced.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeDeltaCause {
    Ingest,
    Page,
    Anchor,
    Restore,
    Reset,
    Prune,
}

/// Ops, or a full replacement.
///
/// A consumer that sees a generation gap **recovers through `Reset`, never by
/// guessing**. That is why this is an enum and not an ops vector with a "full"
/// flag: there is no representable "apply these ops to an unknown base".
#[derive(Clone, Debug, PartialEq)]
pub enum VibeTimelineDeltaBodyV1 {
    Ops(Vec<VibeTimelineOpV1>),
    Reset(Box<VibeTimelineWindowV1>),
}

/// The only egress mutation.
#[derive(Clone, Debug, PartialEq)]
pub struct VibeTimelineDeltaV1 {
    pub chat_id: String,
    /// Strictly increasing per chat. A consumer that sees
    /// `base_generation != its own generation` must discard and resync.
    pub generation: u64,
    pub base_generation: u64,
    pub body: VibeTimelineDeltaBodyV1,
    /// Bounds *after* applying the body.
    pub bounds: VibeWindowBounds,
    pub unread: VibeUnreadState,
    pub cause: VibeDeltaCause,
}

impl VibeTimelineDeltaV1 {
    pub fn ops(&self) -> &[VibeTimelineOpV1] {
        match &self.body {
            VibeTimelineDeltaBodyV1::Ops(ops) => ops,
            VibeTimelineDeltaBodyV1::Reset(_) => &[],
        }
    }

    pub fn is_reset(&self) -> bool {
        matches!(self.body, VibeTimelineDeltaBodyV1::Reset(_))
    }

    /// Whether a consumer at `generation` may adopt this delta.
    ///
    /// Ordered ops require an exact base-generation match. A Reset is a full
    /// replacement and is deliberately adopted regardless of the consumer's
    /// stale generation; applying the ordinary base check to a Reset would make
    /// recovery from a gap impossible.
    pub fn accepts_consumer_generation(&self, generation: u64) -> bool {
        self.is_reset() || self.base_generation == generation
    }
}

/// Result of an anchor/window query.
///
/// Moving the anchor can change the committed bounded window. Returning only
/// the window while silently discarding the corresponding delta advances the
/// producer generation behind an ops consumer's back. The query therefore
/// returns both artifacts atomically: snapshot consumers adopt `window`, while
/// incremental consumers apply `delta` when present.
#[derive(Clone, Debug, PartialEq)]
pub struct VibeTimelineWindowResultV1 {
    pub window: VibeTimelineWindowV1,
    pub delta: Option<VibeTimelineDeltaV1>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_defaults_off_and_rolls_back_per_class() {
        let mut gate = VibeAsyncTimelineGate::default();
        assert!(!gate.is_enabled_anywhere());
        for class in VibeChatClass::ROLLOUT_ORDER {
            assert!(!gate.is_enabled(class));
        }

        gate.set(VibeChatClass::DirectMessage, true);
        gate.set(VibeChatClass::AgentDirectMessage, true);
        assert!(gate.is_enabled(VibeChatClass::DirectMessage));
        assert!(gate.is_enabled(VibeChatClass::AgentDirectMessage));

        // An agent-DM regression must not roll back 1:1 DMs.
        gate.set(VibeChatClass::AgentDirectMessage, false);
        assert!(gate.is_enabled(VibeChatClass::DirectMessage));
        assert!(!gate.is_enabled(VibeChatClass::AgentDirectMessage));
        assert_eq!(VibeAsyncTimelineGate::from_raw(gate.raw()), gate);
    }

    #[test]
    fn local_status_is_monotone_and_failure_cannot_unsend() {
        let sent = VibeLocalStatus::Sent;
        assert_eq!(
            sent.join(VibeLocalStatus::Failed, false),
            VibeLocalStatus::Sent
        );
        assert_eq!(
            sent.join(VibeLocalStatus::Delivered, false),
            VibeLocalStatus::Delivered
        );
        // Explicit downgrade is the only backwards path.
        assert_eq!(
            sent.join(VibeLocalStatus::Failed, true),
            VibeLocalStatus::Failed
        );
    }

    #[test]
    fn content_hash_ignores_window_position() {
        let a = VibeMessageSnapshotV1::text_message("c", "m1", 10, "u", false, "hi");
        let mut b = a.clone();
        b.order_seq = 42;
        b.rehash();
        assert_eq!(a.content_hash, b.content_hash);
    }

    #[test]
    fn content_hash_tracks_rendered_fields() {
        let a = VibeMessageSnapshotV1::text_message("c", "m1", 10, "u", false, "hi");
        let mut b = a.clone();
        b.body.text = "hi there".into();
        b.rehash();
        assert_ne!(a.content_hash, b.content_hash);

        let mut c = a.clone();
        c.delivery.display = VibeDisplayStatus::Read;
        c.rehash();
        assert_ne!(a.content_hash, c.content_hash);
    }

    #[test]
    fn delivery_only_change_is_not_geometry_relevant() {
        let mut mask = VibeChangeMask::NONE;
        mask.insert(VibeChangeMask::DELIVERY);
        assert!(!mask.is_geometry_relevant());
        mask.insert(VibeChangeMask::BODY);
        assert!(mask.is_geometry_relevant());
    }

    #[test]
    fn late_media_pixels_never_imply_geometry() {
        let mut mask = VibeChangeMask::NONE;
        mask.insert(VibeChangeMask::MEDIA_PIXELS);
        mask.insert(VibeChangeMask::FLAGS_COSMETIC);
        assert!(!mask.is_geometry_relevant());
        mask.insert(VibeChangeMask::MEDIA_GEOMETRY);
        assert!(mask.is_geometry_relevant());
    }

    #[test]
    fn event_debug_never_prints_a_frame() {
        let event = VibeCoreEventV1::new(
            "chat-1",
            10,
            VibeEventSource::ChatTopic,
            VibeEventBody::RawFrame {
                json: br#"{"text":"nuclear launch codes"}"#.to_vec(),
            },
        );
        let rendered = format!("{event:?}");
        assert!(rendered.contains("raw_frame"));
        assert!(!rendered.contains("nuclear"));
    }
}
