//! Raw server frame → [`VibeMessageSnapshotV1`].
//!
//! This is the port of the ~250 lines of
//! `raw["fooId"] ?? raw["foo_id"] ?? meta["fooId"]` that every platform
//! currently writes by hand. `serde_json` lives here and **nowhere else**: no
//! `Value`, no map, and no `Vec<u8>` frame escapes this module into the public
//! contract.
//!
//! # Key unwrapping is batched
//!
//! A 100-message history page needs 100 RSA private-key operations. They happen
//! in **one** [`crate::crypto::VibeKeyUnwrapper::unwrap_aes_keys`] call, off the
//! main thread, once — not once per message and never again, because the durable
//! store keeps the opened form.
//!
//! # Thumbnails never ride the snapshot
//!
//! Frames carry `thumbnailBase64` inline, 2–8 KB each. Those bytes are decoded
//! once, handed back to the host as a [`VibeThumbnailBlob`] to write into its
//! media vault, and replaced in the snapshot by a
//! [`crate::types::VibeThumbHandle`]. A 300-row window therefore never copies
//! megabytes across the boundary.

use serde_json::{Map, Value};

use crate::crypto::{VibeAeadProvider, VibeKeyUnwrapper, VibeWrappedKeyRequest};
use crate::dedup::is_transient_id;
use crate::envelope::{self, VibeEnvelopeDirection, VibeEnvelopeFormat};
use crate::error::VibeCanonicalError;
use crate::media::{self, MAX_PLACEHOLDER_LEN};
use crate::secret::VibeOpaqueBlob;
use crate::types::{
    VibeAgentProgressNode, VibeAgentRef, VibeAuthorRef, VibeDeliveryState, VibeDisplayStatus,
    VibeMediaEnvelope, VibeMediaRef, VibeMessageBody, VibeMessageFlags, VibeMessageKind,
    VibeMessageSnapshotV1, VibeReactionSummary, VibeReplyRef, VibeServiceChip, VibeServiceNode,
    VibeSize, VibeThumbHandle,
};

/// Ceiling on a single raw frame.
pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// Ceiling on one history page.
pub const MAX_BATCH_BYTES: usize = 64 * 1024 * 1024;

/// Everything canonicalization needs from the host.
pub struct VibeCanonicalContext<'a> {
    pub chat_id: &'a str,
    pub own_user_id: &'a str,
    /// Saved Messages carries two ids for one logical message and the client
    /// deliberately prefers `original_message_id`. Choosing the other one mints a
    /// second id generation and duplicate cells on every cold open.
    pub is_saved_messages: bool,
    pub aead: &'a dyn VibeAeadProvider,
    pub unwrapper: &'a dyn VibeKeyUnwrapper,
}

/// Thumbnail bytes lifted out of a frame, for the host to persist.
///
/// No `Debug` derive: these are pixels from a private conversation.
pub struct VibeThumbnailBlob {
    pub identity: String,
    pub bytes: Vec<u8>,
}

impl std::fmt::Debug for VibeThumbnailBlob {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeThumbnailBlob")
            .field("identity", &self.identity)
            .field("bytes", &self.bytes.len())
            .finish()
    }
}

/// Result of canonicalizing a frame or a batch.
#[derive(Debug, Default)]
pub struct VibeCanonicalOutput {
    pub messages: Vec<VibeMessageSnapshotV1>,
    pub thumbnails: Vec<VibeThumbnailBlob>,
    /// Frames that could not be canonicalized. Counted, never fatal.
    pub dropped: Vec<VibeCanonicalError>,
}

/// Canonicalizes one frame.
pub fn canonicalize_frame(
    json: &[u8],
    ctx: &VibeCanonicalContext<'_>,
) -> Result<VibeCanonicalOutput, VibeCanonicalError> {
    if json.len() > MAX_FRAME_BYTES {
        return Err(VibeCanonicalError::TooLarge {
            limit: MAX_FRAME_BYTES,
            actual: json.len(),
        });
    }
    let value: Value = serde_json::from_slice(json).map_err(|_| VibeCanonicalError::NotJson)?;
    let Value::Object(map) = value else {
        return Err(VibeCanonicalError::NotAnObject);
    };
    let mut out = canonicalize_maps(vec![map], ctx);
    // Single-frame callers get the reason back rather than an empty success.
    // A batch keeps its per-row failures in `dropped`, because one bad row in a
    // history page must never fail the page.
    if out.messages.is_empty() {
        if let Some(err) = out.dropped.pop() {
            return Err(err);
        }
    }
    Ok(out)
}

/// Canonicalizes a history page. One unwrap call for the whole page.
pub fn canonicalize_frames(
    json_array: &[u8],
    ctx: &VibeCanonicalContext<'_>,
) -> Result<VibeCanonicalOutput, VibeCanonicalError> {
    if json_array.len() > MAX_BATCH_BYTES {
        return Err(VibeCanonicalError::TooLarge {
            limit: MAX_BATCH_BYTES,
            actual: json_array.len(),
        });
    }
    let value: Value =
        serde_json::from_slice(json_array).map_err(|_| VibeCanonicalError::NotJson)?;
    let items = match value {
        Value::Array(items) => items,
        // A page endpoint that wraps its rows: `{ "messages": [...] }`.
        Value::Object(mut map) => {
            let inner = ["messages", "rows", "data", "items"]
                .iter()
                .find_map(|k| map.remove(*k));
            match inner {
                Some(Value::Array(items)) => items,
                _ => return Err(VibeCanonicalError::NotAnObject),
            }
        }
        _ => return Err(VibeCanonicalError::NotAnObject),
    };

    let mut maps = Vec::with_capacity(items.len());
    let mut output = VibeCanonicalOutput::default();
    for item in items {
        match item {
            Value::Object(map) => maps.push(map),
            _ => output.dropped.push(VibeCanonicalError::NotAnObject),
        }
    }
    let mut canonical = canonicalize_maps(maps, ctx);
    output.messages.append(&mut canonical.messages);
    output.thumbnails.append(&mut canonical.thumbnails);
    output.dropped.append(&mut canonical.dropped);
    Ok(output)
}

/// The two-pass body: prepare every frame, unwrap all keys in one call, then
/// build snapshots.
fn canonicalize_maps(
    maps: Vec<Map<String, Value>>,
    ctx: &VibeCanonicalContext<'_>,
) -> VibeCanonicalOutput {
    let mut output = VibeCanonicalOutput::default();
    let mut prepared: Vec<Prepared> = Vec::with_capacity(maps.len());
    let mut requests: Vec<VibeWrappedKeyRequest> = Vec::new();

    for map in maps {
        match prepare(map, ctx) {
            Ok(mut p) => {
                if let Some(candidates) = p.key_candidates.take() {
                    p.request_index = Some(requests.len());
                    requests.push(VibeWrappedKeyRequest {
                        message_id: p.message_id.clone(),
                        candidates,
                    });
                }
                prepared.push(p);
            }
            Err(e) => output.dropped.push(e),
        }
    }

    let keys = if requests.is_empty() {
        Vec::new()
    } else {
        ctx.unwrapper.unwrap_aes_keys(&requests)
    };

    for p in prepared {
        let opened = p.request_index.and_then(|i| keys.get(i)).and_then(|slot| {
            let key = slot.as_ref()?;
            let env = p.envelope.as_ref()?;
            env.open(ctx.aead, key).ok()
        });

        let (payload, decryption_failed) = match (&p.envelope, opened) {
            (Some(_), Some(plain)) => (
                serde_json::from_slice::<Value>(plain.as_bytes())
                    .ok()
                    .and_then(as_object),
                false,
            ),
            // An envelope we could not open: exactly today's behaviour — the row
            // renders with the failure flag and whatever plaintext fallback the
            // frame carried.
            (Some(_), None) => (None, true),
            (None, _) => (p.plain_payload.clone(), false),
        };

        let (snapshot, mut thumbs) = build_snapshot(&p, payload.as_ref(), decryption_failed, ctx);
        output.messages.push(snapshot);
        output.thumbnails.append(&mut thumbs);
    }

    output
}

struct Prepared {
    raw: Map<String, Value>,
    message_id: String,
    client_message_id: Option<String>,
    ts_ms: i64,
    envelope: Option<envelope::VibeHybridEnvelopeV1>,
    /// An envelope this crate recognises but cannot open: MLS, legacy RSA-direct,
    /// agent-sealed. The host opens those and projects the plaintext into the frame.
    sealed_elsewhere: bool,
    key_candidates: Option<Vec<Vec<u8>>>,
    request_index: Option<usize>,
    plain_payload: Option<Map<String, Value>>,
}

fn prepare(
    raw: Map<String, Value>,
    ctx: &VibeCanonicalContext<'_>,
) -> Result<Prepared, VibeCanonicalError> {
    let message_id = resolve_message_id(&raw, ctx.is_saved_messages)
        .ok_or(VibeCanonicalError::MissingMessageId)?;
    let chat_id = pick_str(
        &raw,
        &["chatId", "chat_id", "conversationId", "conversation_id"],
    );
    if chat_id.is_none() && ctx.chat_id.is_empty() {
        return Err(VibeCanonicalError::MissingChatId);
    }
    let ts_ms = resolve_timestamp_ms(&raw).unwrap_or(0);
    let client_message_id = pick_str(
        &raw,
        &[
            "clientMessageId",
            "client_message_id",
            "localId",
            "local_id",
            "tempId",
        ],
    );

    let is_me = resolve_is_me(&raw, ctx.own_user_id);
    let mut envelope_parsed = None;
    let mut key_candidates = None;
    let mut plain_payload = None;
    let mut sealed_elsewhere = false;

    if let Some(raw_content) = pick_str(&raw, &["encryptedContent", "encrypted_content"]) {
        match envelope::classify(&raw_content) {
            VibeEnvelopeFormat::HybridV1 => {
                if let Ok(env) = envelope::parse_hybrid(&raw_content) {
                    let direction = if is_me {
                        VibeEnvelopeDirection::Outgoing
                    } else {
                        VibeEnvelopeDirection::Incoming
                    };
                    key_candidates = Some(env.key_candidates(direction));
                    envelope_parsed = Some(env);
                }
            }
            // Groups, channels, and the `friendPublicKey == nil` DM fallback put
            // the plaintext payload in this field. The core must never assume an
            // envelope; see docs/production-timeline-core-refactor.md.
            VibeEnvelopeFormat::PlaintextPayloadJson => {
                plain_payload = serde_json::from_str::<Value>(&raw_content)
                    .ok()
                    .and_then(as_object);
            }
            // Legacy RSA-direct needs a private-key operation over the whole
            // ciphertext, which is platform-owned. Recognised so the row is
            // flagged rather than rendered as base64 text.
            // `MlsV2` groups with these: recognised so it never renders as
            // literal text, never opened here (`vibe_secure` owns that), and
            // this crate does not depend on `vibe_secure`, so there is nothing
            // more this arm could do with it.
            VibeEnvelopeFormat::LegacyRsaDirect
            | VibeEnvelopeFormat::AgentSealedArte1
            | VibeEnvelopeFormat::MlsV2
            | VibeEnvelopeFormat::Unrecognized => {
                sealed_elsewhere = true;
            }
        }
    }

    Ok(Prepared {
        raw,
        message_id,
        client_message_id,
        ts_ms,
        envelope: envelope_parsed,
        sealed_elsewhere,
        key_candidates,
        request_index: None,
        plain_payload,
    })
}

fn build_snapshot(
    p: &Prepared,
    payload: Option<&Map<String, Value>>,
    decryption_failed: bool,
    ctx: &VibeCanonicalContext<'_>,
) -> (VibeMessageSnapshotV1, Vec<VibeThumbnailBlob>) {
    let raw = &p.raw;
    let mut thumbs = Vec::new();
    let mut flags = VibeMessageFlags::NONE;

    let is_me = resolve_is_me(raw, ctx.own_user_id);
    let author_id = pick_str(
        raw,
        &[
            "senderId",
            "sender_id",
            "fromId",
            "from_id",
            "userId",
            "user_id",
            "from",
        ],
    )
    .unwrap_or_else(|| {
        if is_me {
            ctx.own_user_id.to_string()
        } else {
            String::new()
        }
    });

    // Body: the opened/plain payload wins; otherwise whatever cleartext the frame
    // carried. `decryptionFailed` with an empty body is the shipped behaviour.
    let text = payload
        .and_then(|m| pick_str(m, &["text", "body", "content"]))
        .or_else(|| pick_str(raw, &["plainContent", "text", "content", "body"]))
        .unwrap_or_default();
    let caption = payload
        .and_then(|m| pick_str(m, &["caption"]))
        .or_else(|| pick_str(raw, &["caption"]));

    // "Decrypted to an empty string" counts as a failure in the shipped client — but
    // the shipped client means the ENVELOPE opened to nothing, not that the payload's
    // `text` field is empty. `ChatEngine.swift:11399`:
    //
    //     let decryptionFailed = … hadEncryptedContent && (hybrid || mls)
    //                            && decryptedText.isEmpty
    //
    // where `decryptedText` is the whole decrypted envelope string, empty only when the
    // open produced nothing. The previous condition here transcribed that as
    // `payload.is_some() && text.is_empty()` — the `text` field *inside* a payload that
    // opened perfectly well.
    //
    // Those diverge on every legitimately text-less message: a photo without a caption,
    // a voice note, a sticker, a document. Each one decrypts to a real payload whose
    // `text` is `""`, and each one was being flagged as a decryption failure. Device
    // 2026-08-08, chat 71312111f04b: `decryptFailed=12` of 72 rows, in the one chat with
    // media — a number that is unactionable precisely because it mixes these two.
    //
    // The faithful translation is "an envelope with no usable payload behind it", which
    // also covers the case the old clause was reaching for: bytes that opened but did not
    // parse as JSON, where `decryption_failed` is false and `payload` is `None`.
    if decryption_failed || (p.envelope.is_some() && payload.is_none()) {
        flags.insert(VibeMessageFlags::DECRYPTION_FAILED);
    }

    let sealed_media = p.sealed_elsewhere || p.envelope.is_some();
    let (media, mut media_thumbs) = build_media(payload, raw, &p.message_id, sealed_media);
    thumbs.append(&mut media_thumbs);

    // An envelope this crate cannot open (MLS, legacy RSA, agent-sealed) is not a failure
    // by itself: the host opens those and projects the plaintext into the frame. It is a
    // failure only when nothing came with it — otherwise the row renders blank with no
    // flag, which is indistinguishable from a message that was genuinely empty.
    if p.sealed_elsewhere
        && text.is_empty()
        && caption.as_deref().unwrap_or("").is_empty()
        && media.is_none()
    {
        flags.insert(VibeMessageFlags::DECRYPTION_FAILED);
    }

    let agent = build_agent(raw);
    let service = build_service(raw);
    let reply = build_reply(payload, raw);

    if agent.as_ref().is_some_and(|a| a.is_streaming) {
        flags.insert(VibeMessageFlags::STREAMING);
    }
    if service.is_some() {
        flags.insert(VibeMessageFlags::SERVICE);
    }
    if pick_bool(raw, &["isPinned", "pinned"]).unwrap_or(false) {
        flags.insert(VibeMessageFlags::PINNED);
    }
    if pick_bool(raw, &["isForwarded", "forwarded"]).unwrap_or(false)
        || pick_str(raw, &["forwardedFrom", "forwarded_from"]).is_some()
    {
        flags.insert(VibeMessageFlags::FORWARDED);
    }
    if pick_bool(raw, &["viewOnce", "view_once"]).unwrap_or(false)
        || pick_i64(raw, &["mediaTtlSeconds", "media_ttl_seconds"]).is_some()
    {
        flags.insert(VibeMessageFlags::VIEW_ONCE);
    }
    if pick_bool(raw, &["eventNotification", "event_notification"]).unwrap_or(false) {
        flags.insert(VibeMessageFlags::EVENT_NOTIFICATION);
    }
    if pick_bool(raw, &["eventInboxSummary", "event_inbox_summary"]).unwrap_or(false) {
        flags.insert(VibeMessageFlags::EVENT_INBOX_SUMMARY);
    }
    if pick_bool(raw, &["hiddenFromTranscript", "hidden_from_transcript"]).unwrap_or(false) {
        flags.insert(VibeMessageFlags::HIDDEN_FROM_TRANSCRIPT);
    }
    if pick_bool(raw, &["agentError", "agent_error"]).unwrap_or(false) {
        flags.insert(VibeMessageFlags::AGENT_ERROR);
    }
    if is_transient_id(&p.message_id) {
        flags.insert(VibeMessageFlags::TRANSIENT_ID);
    }

    let kind = resolve_kind(
        raw,
        payload,
        media.as_ref(),
        agent.as_ref(),
        service.as_ref(),
    );

    let mut snapshot = VibeMessageSnapshotV1 {
        message_id: p.message_id.clone(),
        client_message_id: p.client_message_id.clone(),
        chat_id: pick_str(raw, &["chatId", "chat_id"]).unwrap_or_else(|| ctx.chat_id.to_string()),
        ts_ms: p.ts_ms,
        order_seq: 0,
        author: VibeAuthorRef {
            user_id: author_id,
            is_me,
            agent_provider: agent.as_ref().map(|a| a.provider.clone()),
        },
        kind,
        body: VibeMessageBody {
            text,
            caption: caption.filter(|c| !c.is_empty()),
        },
        reply,
        edit: pick_i64(raw, &["editedAt", "edited_at", "editedAtMs"])
            .map(|edited_at_ms| crate::types::VibeEditState { edited_at_ms }),
        delivery: VibeDeliveryState {
            display: resolve_status(raw),
            upload: pick_f64(raw, &["uploadProgress", "upload_progress"]).map(|v| v as f32),
            failed: pick_bool(raw, &["failed", "sendFailed"]).unwrap_or(false),
        },
        flags,
        media,
        agent,
        service,
        reactions: resolve_reactions(raw),
        view_count: pick_i64(raw, &["viewCount", "view_count"])
            .and_then(|value| u64::try_from(value).ok()),
        content_hash: 0,
    };
    snapshot.rehash();
    (snapshot, thumbs)
}

// ---------------------------------------------------------------------------
// Field resolution
// ---------------------------------------------------------------------------

fn resolve_message_id(raw: &Map<String, Value>, is_saved_messages: bool) -> Option<String> {
    if is_saved_messages {
        // Deliberate: preferring `id` here mints a second id generation for the
        // same logical message and duplicates every Saved Messages row on cold
        // open.
        if let Some(id) = pick_str(raw, &["originalMessageId", "original_message_id"]) {
            return Some(id);
        }
    }
    pick_str(
        raw,
        &[
            "messageId",
            "message_id",
            "id",
            "_id",
            "uuid",
            "clientMessageId",
        ],
    )
}

/// Whether this frame was authored by us.
///
/// The id comparison is **ASCII-case-insensitive**, and has to be. These are
/// RFC 4122 UUIDs, where case carries no meaning — but the platform is not
/// consistent about it: iOS `ChatEngine.currentUserIdLocked()` upper-cases the
/// configured id before handing it over, while server frames carry `senderId`
/// lower-cased. A byte-exact compare therefore answered "not me" for every
/// message the user sent.
///
/// Device run 2026-08-03: `own_user_id = "CFAC3A0D-…"`, frames carrying
/// `"cfac3a0d-…"`, and `height-audit … flipped=[status=99, isMe=99]` — 99 of 119
/// of the user's own messages re-rendered as the peer's the moment core rows took
/// over from engine rows.
fn resolve_is_me(raw: &Map<String, Value>, own_user_id: &str) -> bool {
    if let Some(v) = pick_bool(raw, &["isMe", "is_me", "isOwn", "outgoing"]) {
        return v;
    }
    if own_user_id.is_empty() {
        return false;
    }
    pick_str(
        raw,
        &[
            "senderId",
            "sender_id",
            "fromId",
            "from_id",
            "userId",
            "user_id",
            "from",
        ],
    )
    .is_some_and(|id| id.eq_ignore_ascii_case(own_user_id))
}

fn resolve_status(raw: &Map<String, Value>) -> VibeDisplayStatus {
    match pick_str(raw, &["status", "deliveryStatus", "delivery_status"])
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "pending" | "queued" => VibeDisplayStatus::Pending,
        "sending" | "uploading" => VibeDisplayStatus::Sending,
        "failed" | "error" => VibeDisplayStatus::Failed,
        "delivered" => VibeDisplayStatus::Delivered,
        "read" | "seen" => VibeDisplayStatus::Read,
        _ => VibeDisplayStatus::Sent,
    }
}

fn resolve_kind(
    raw: &Map<String, Value>,
    payload: Option<&Map<String, Value>>,
    media: Option<&VibeMediaRef>,
    agent: Option<&VibeAgentRef>,
    service: Option<&VibeServiceNode>,
) -> VibeMessageKind {
    if agent.is_some() {
        return VibeMessageKind::AgentTurn;
    }
    if service.is_some() {
        return VibeMessageKind::Service;
    }
    let declared = payload
        .and_then(|m| pick_str(m, &["type", "messageType", "message_type", "mediaType"]))
        .or_else(|| pick_str(raw, &["type", "messageType", "message_type", "mediaType"]))
        .unwrap_or_default()
        .to_ascii_lowercase();
    match declared.as_str() {
        "image" | "photo" | "gif" => return VibeMessageKind::Image,
        "video" | "videonote" | "video_note" => return VibeMessageKind::Video,
        "voice" | "audio_message" => return VibeMessageKind::Voice,
        "music" | "audio" | "track" => return VibeMessageKind::Music,
        "file" | "document" => return VibeMessageKind::File,
        "sticker" => return VibeMessageKind::Sticker,
        "location" => return VibeMessageKind::Location,
        "contact" => return VibeMessageKind::Contact,
        "service" | "system" | "notice" => return VibeMessageKind::Service,
        _ => {}
    }
    match media.and_then(|m| m.mime.as_deref()).unwrap_or("") {
        m if m.starts_with("image/") => VibeMessageKind::Image,
        m if m.starts_with("video/") => VibeMessageKind::Video,
        m if m.starts_with("audio/") => VibeMessageKind::Music,
        m if !m.is_empty() => VibeMessageKind::File,
        _ if media.is_some() => VibeMessageKind::File,
        _ => VibeMessageKind::Text,
    }
}

fn build_media(
    payload: Option<&Map<String, Value>>,
    raw: &Map<String, Value>,
    message_id: &str,
    sealed: bool,
) -> (Option<VibeMediaRef>, Vec<VibeThumbnailBlob>) {
    let source = payload.unwrap_or(raw);
    let url = pick_str(source, &["mediaUrl", "media_url", "url", "fileUrl"])
        .or_else(|| pick_str(raw, &["mediaUrl", "media_url"]));
    let media_key = pick_str(source, &["mediaKey", "media_key"])
        .or_else(|| pick_str(raw, &["mediaKey", "media_key"]));
    let Some(url) = url.filter(|u| !u.is_empty()) else {
        return (None, Vec::new());
    };
    // Sealed message with no key: the public URL is ciphertext, not playable media.
    if sealed && media_key.as_deref().map(|k| k.is_empty()).unwrap_or(true) {
        return (None, Vec::new());
    }

    let identity = media::media_identity(&url, media_key.as_deref());
    let envelope = match media_key.as_deref() {
        Some(key) if !key.is_empty() => VibeMediaEnvelope::Gcm1 {
            key_ref: key.to_string(),
        },
        _ => VibeMediaEnvelope::Plain,
    };

    let mut thumbs = Vec::new();
    let thumbnail =
        pick_str(source, &["thumbnailBase64", "thumbnail_base64", "thumb"]).and_then(|b64| {
            use base64::engine::general_purpose::STANDARD as B64;
            use base64::Engine as _;
            let bytes = B64.decode(b64.as_bytes()).ok()?;
            if bytes.is_empty() {
                return None;
            }
            let thumb_identity = format!("{identity}|thumb");
            thumbs.push(VibeThumbnailBlob {
                identity: thumb_identity.clone(),
                bytes,
            });
            Some(VibeThumbHandle {
                identity: thumb_identity,
                size: natural_size(source),
                placeholder: pick_str(source, &["blurhash", "placeholder"])
                    .filter(|p| p.len() <= MAX_PLACEHOLDER_LEN),
            })
        });

    let waveform = source
        .get("waveform")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_f64)
                // The wire carries 0..1 floats or 0..255 ints depending on the
                // sender; both collapse to a byte bucket here.
                .map(|v| if v <= 1.0 { (v * 255.0) as u8 } else { v as u8 })
                .collect::<Vec<u8>>()
        })
        .unwrap_or_default();

    let media = VibeMediaRef {
        identity,
        remote_url: Some(url),
        file_name: pick_str(source, &["fileName", "file_name", "name"]),
        mime: pick_str(source, &["mimeType", "mime_type", "mime", "contentType"]),
        byte_size: pick_i64(source, &["byteSize", "byte_size", "size", "fileSize"]),
        natural_size: natural_size(source),
        duration_s: pick_f64(source, &["duration", "durationSeconds", "duration_s"]),
        waveform,
        thumbnail,
        envelope,
    };
    debug_assert!(!message_id.is_empty());
    (Some(media), thumbs)
}

fn natural_size(source: &Map<String, Value>) -> Option<VibeSize> {
    let w = pick_i64(source, &["width", "mediaWidth", "naturalWidth"])?;
    let h = pick_i64(source, &["height", "mediaHeight", "naturalHeight"])?;
    if w <= 0 || h <= 0 {
        // Unknown aspect must stay `None`. Guessing square and correcting after
        // decode is *the* list-shift bug.
        return None;
    }
    Some(VibeSize {
        width: w as u32,
        height: h as u32,
    })
}

fn build_agent(raw: &Map<String, Value>) -> Option<VibeAgentRef> {
    let meta = raw.get("metadata").and_then(Value::as_object);
    let is_agent = pick_bool(raw, &["isAgentMessage", "is_agent_message"]).unwrap_or(false)
        || meta.is_some_and(|m| pick_bool(m, &["isAgentMessage"]).unwrap_or(false));
    if !is_agent {
        return None;
    }

    let provider = pick_str(raw, &["agentUserId", "agent_user_id", "agentProvider"])
        .or_else(|| meta.and_then(|m| pick_str(m, &["agentUserId", "agentProvider"])))
        .unwrap_or_default()
        .to_ascii_lowercase();

    let is_streaming = pick_bool(raw, &["isStreaming", "is_streaming"]).unwrap_or(false)
        || meta.is_some_and(|m| pick_bool(m, &["isStreaming"]).unwrap_or(false));

    let nodes_value = raw
        .get("progressNodes")
        .or_else(|| meta.and_then(|m| m.get("progressNodes")))
        .and_then(Value::as_array);
    let progress = nodes_value
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_object)
                .map(|n| VibeAgentProgressNode {
                    id: pick_str(n, &["id", "nodeId"]).unwrap_or_default(),
                    kind: pick_str(n, &["kind", "itemType", "type"]).unwrap_or_default(),
                    label: pick_str(n, &["label", "title"]).unwrap_or_default(),
                    detail: pick_str(n, &["detail", "messageContent", "messagePreview"]),
                    is_terminal: pick_bool(n, &["isTerminal", "terminal"]).unwrap_or(false),
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    // Sealed under a pairing key the server never sees and this crate must never
    // be given. Carried as opaque bytes and nothing else.
    let sealed = pick_str(
        raw,
        &["agentRuntimeEnc", "agentActionEnc", "agentActionsEnc"],
    )
    .or_else(|| meta.and_then(|m| pick_str(m, &["agentRuntimeEnc"])))
    .map(|s| VibeOpaqueBlob::new(s.into_bytes()));

    Some(VibeAgentRef {
        provider,
        task_id: pick_str(raw, &["taskId", "task_id"])
            .or_else(|| meta.and_then(|m| pick_str(m, &["taskId"]))),
        session_id: pick_str(raw, &["sessionId", "session_id"])
            .or_else(|| meta.and_then(|m| pick_str(m, &["sessionId"]))),
        sealed,
        progress,
        is_streaming,
        elapsed_ms: pick_i64(raw, &["elapsedMs", "elapsed_ms"])
            .or_else(|| meta.and_then(|m| pick_i64(m, &["elapsedMs"]))),
    })
}

fn build_service(raw: &Map<String, Value>) -> Option<VibeServiceNode> {
    let node = raw
        .get("serviceNode")
        .or_else(|| raw.get("service_node"))
        .and_then(Value::as_object)?;
    let chips = node
        .get("chips")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_object)
                .map(|c| VibeServiceChip {
                    id: pick_str(c, &["id", "action"]).unwrap_or_default(),
                    label: pick_str(c, &["label", "title"]).unwrap_or_default(),
                    style: pick_str(c, &["style", "kind"]).unwrap_or_default(),
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Some(VibeServiceNode {
        kind: pick_str(node, &["kind", "type"]).unwrap_or_default(),
        title: pick_str(node, &["title", "text"]).unwrap_or_default(),
        subtitle: pick_str(node, &["subtitle", "detail"]),
        chips,
        event_thread_id: pick_str(node, &["eventThreadId", "event_thread_id"]),
        folded_count: pick_i64(node, &["foldedCount", "folded_count"]).unwrap_or(0) as u32,
    })
}

fn build_reply(
    payload: Option<&Map<String, Value>>,
    raw: &Map<String, Value>,
) -> Option<VibeReplyRef> {
    let source = payload.unwrap_or(raw);
    let nested = source
        .get("replyTo")
        .or_else(|| raw.get("replyTo"))
        .and_then(Value::as_object);
    let message_id = pick_str(
        source,
        &[
            "replyToMessageId",
            "reply_to_message_id",
            "replyToId",
            "reply_to_id",
        ],
    )
    .or_else(|| nested.and_then(|n| pick_str(n, &["id", "messageId", "message_id"])))?;

    Some(VibeReplyRef {
        message_id,
        author_user_id: pick_str(source, &["replyToSenderId", "reply_to_sender_id"])
            .or_else(|| nested.and_then(|n| pick_str(n, &["senderId", "sender_id"]))),
        preview: VibeMessageBody {
            text: pick_str(source, &["replyToText", "reply_to_text"])
                .or_else(|| nested.and_then(|n| pick_str(n, &["text", "preview"])))
                .unwrap_or_default(),
            caption: None,
        },
        preview_media: nested
            .and_then(|n| pick_str(n, &["mediaUrl", "media_url"]))
            .map(|url| VibeThumbHandle {
                identity: format!("{}|thumb", media::media_identity(&url, None)),
                size: None,
                placeholder: None,
            }),
    })
}

// ---------------------------------------------------------------------------
// Alias helpers
// ---------------------------------------------------------------------------

fn as_object(value: Value) -> Option<Map<String, Value>> {
    match value {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

fn resolve_reactions(raw: &Map<String, Value>) -> Vec<VibeReactionSummary> {
    let Some(Value::Array(items)) = raw.get("reactions") else {
        return Vec::new();
    };

    items
        .iter()
        .filter_map(Value::as_object)
        .filter_map(|item| {
            let emoji = pick_str(item, &["emoji"])?;
            let count = pick_i64(item, &["count"]).and_then(|value| u64::try_from(value).ok())?;
            (count > 0).then(|| VibeReactionSummary {
                emoji,
                count,
                is_selected: pick_bool(item, &["isSelected", "is_selected"]).unwrap_or(false),
            })
        })
        .collect()
}

fn pick_str(map: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        match map.get(*key) {
            Some(Value::String(s)) if !s.is_empty() => return Some(s.clone()),
            Some(Value::Number(n)) => return Some(n.to_string()),
            _ => {}
        }
    }
    None
}

fn pick_bool(map: &Map<String, Value>, keys: &[&str]) -> Option<bool> {
    for key in keys {
        match map.get(*key) {
            Some(Value::Bool(b)) => return Some(*b),
            // The server has historically sent 0/1 and "true"/"false" here.
            Some(Value::Number(n)) => return Some(n.as_i64().unwrap_or(0) != 0),
            Some(Value::String(s)) => match s.as_str() {
                "true" | "1" | "yes" => return Some(true),
                "false" | "0" | "no" => return Some(false),
                _ => {}
            },
            _ => {}
        }
    }
    None
}

fn pick_i64(map: &Map<String, Value>, keys: &[&str]) -> Option<i64> {
    for key in keys {
        match map.get(*key) {
            Some(Value::Number(n)) => {
                if let Some(v) = n.as_i64() {
                    return Some(v);
                }
                if let Some(v) = n.as_f64() {
                    return Some(v as i64);
                }
            }
            Some(Value::String(s)) => {
                if let Ok(v) = s.parse::<i64>() {
                    return Some(v);
                }
            }
            _ => {}
        }
    }
    None
}

fn pick_f64(map: &Map<String, Value>, keys: &[&str]) -> Option<f64> {
    for key in keys {
        match map.get(*key) {
            Some(Value::Number(n)) => {
                if let Some(v) = n.as_f64() {
                    return Some(v);
                }
            }
            Some(Value::String(s)) => {
                if let Ok(v) = s.parse::<f64>() {
                    return Some(v);
                }
            }
            _ => {}
        }
    }
    None
}

/// Timestamp resolution: epoch ms, epoch seconds, or ISO-8601.
///
/// The cut-off between seconds and milliseconds is year 5138 in seconds versus
/// 1973 in milliseconds; `1e11` separates them unambiguously for any timestamp
/// this app will ever see.
fn resolve_timestamp_ms(raw: &Map<String, Value>) -> Option<i64> {
    const SECONDS_CUTOFF: i64 = 100_000_000_000;
    let keys = [
        "timestampMs",
        "timestamp_ms",
        "timestamp",
        "ts",
        "createdAt",
        "created_at",
        "insertedAt",
        "inserted_at",
        "sentAt",
        "sent_at",
    ];
    for key in keys {
        match raw.get(key) {
            Some(Value::Number(n)) => {
                let v = n.as_i64().or_else(|| n.as_f64().map(|f| f as i64))?;
                return Some(promote_seconds(v, SECONDS_CUTOFF));
            }
            Some(Value::String(s)) => {
                if let Ok(v) = s.parse::<i64>() {
                    return Some(promote_seconds(v, SECONDS_CUTOFF));
                }
                if let Some(ms) = parse_iso8601_ms(s) {
                    return Some(ms);
                }
            }
            _ => {}
        }
    }
    None
}

/// Promotes an epoch-seconds value to milliseconds, saturating rather than
/// wrapping.
///
/// `i64::MIN.abs()` overflows and `v * 1000` overflows near the extremes, and a
/// hostile frame can carry either. A nonsense timestamp must produce a nonsense
/// ordering key, never a panic.
fn promote_seconds(v: i64, cutoff: i64) -> i64 {
    if v.unsigned_abs() < cutoff.unsigned_abs() {
        v.saturating_mul(1_000)
    } else {
        v
    }
}

/// Strict ISO-8601 → epoch milliseconds.
///
/// Accepts `YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]` and a space in place of `T`.
/// Written out rather than pulling in `chrono` so the crate stays small enough to
/// embed and has no time-zone database to keep current — the wire format is
/// always UTC or an explicit offset.
pub fn parse_iso8601_ms(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> { s.get(from..to)?.parse::<i64>().ok() };
    if b[4] != b'-'
        || b[7] != b'-'
        || (b[10] != b'T' && b[10] != b' ')
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let year = num(0, 4)?;
    let month = num(5, 7)?;
    let day = num(8, 10)?;
    let hour = num(11, 13)?;
    let minute = num(14, 16)?;
    let second = num(17, 19)?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }

    let mut idx = 19;
    let mut millis = 0i64;
    if b.get(idx) == Some(&b'.') {
        let start = idx + 1;
        let mut end = start;
        while end < b.len() && b[end].is_ascii_digit() {
            end += 1;
        }
        let frac = s.get(start..end)?;
        // Normalize to exactly three digits.
        let mut digits = frac.to_string();
        digits.truncate(3);
        while digits.len() < 3 {
            digits.push('0');
        }
        millis = digits.parse::<i64>().ok()?;
        idx = end;
    }

    let mut offset_minutes = 0i64;
    match b.get(idx) {
        None | Some(b'Z' | b'z') => {}
        Some(sign @ (b'+' | b'-')) => {
            let oh = num(idx + 1, idx + 3)?;
            // Both `+05:30` and `+0530` appear in the wild.
            let om_start = if b.get(idx + 3) == Some(&b':') {
                idx + 4
            } else {
                idx + 3
            };
            let om = num(om_start, om_start + 2)?;
            let total = oh * 60 + om;
            offset_minutes = if *sign == b'-' { -total } else { total };
        }
        Some(_) => return None,
    }

    let days = days_from_civil(year, month, day);
    let secs = days * 86_400 + hour * 3_600 + minute * 60 + second - offset_minutes * 60;
    Some(secs * 1_000 + millis)
}

/// Howard Hinnant's `days_from_civil`: days since 1970-01-01, no lookup tables.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::{VibeDenyAllAead, VibeDenyAllKeyUnwrapper};

    fn ctx<'a>(
        aead: &'a dyn VibeAeadProvider,
        unwrapper: &'a dyn VibeKeyUnwrapper,
        saved: bool,
    ) -> VibeCanonicalContext<'a> {
        VibeCanonicalContext {
            chat_id: "chat-1",
            own_user_id: "me",
            is_saved_messages: saved,
            aead,
            unwrapper,
        }
    }

    /// The platform upper-cases the configured user id; the server lower-cases
    /// `senderId`. A byte-exact compare made every message the user sent render as
    /// the peer's — observed on device 2026-08-03 as 99 of 119 rows flipping.
    #[test]
    fn authorship_ignores_uuid_case() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let uppercased = VibeCanonicalContext {
            chat_id: "chat-1",
            own_user_id: "CFAC3A0D-C764-473C-9940-33FCA418834A",
            is_saved_messages: false,
            aead: &aead,
            unwrapper: &unwrap,
        };

        let mine = br#"{"id":"m1","chat_id":"chat-1","senderId":"cfac3a0d-c764-473c-9940-33fca418834a","timestamp":5,"encrypted_content":"{\"text\":\"hi\"}"}"#;
        let theirs = br#"{"id":"m2","chat_id":"chat-1","senderId":"7486c619-3d97-4067-afd6-662fb13f6dd5","timestamp":6,"encrypted_content":"{\"text\":\"hi\"}"}"#;

        let a = canonicalize_frame(mine, &uppercased).unwrap();
        let b = canonicalize_frame(theirs, &uppercased).unwrap();
        assert!(
            a.messages[0].author.is_me,
            "own message must resolve as mine"
        );
        assert!(
            !b.messages[0].author.is_me,
            "peer message must stay the peer's"
        );
    }

    #[test]
    fn resolves_field_aliases_across_naming_conventions() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let c = ctx(&aead, &unwrap, false);

        let snake = br#"{"message_id":"m1","chat_id":"chat-1","sender_id":"peer","created_at":1700000000000,"encrypted_content":"{\"text\":\"hello\"}"}"#;
        let camel = br#"{"messageId":"m1","chatId":"chat-1","senderId":"peer","timestamp":1700000000000,"encryptedContent":"{\"text\":\"hello\"}"}"#;

        let a = canonicalize_frame(snake, &c).unwrap();
        let b = canonicalize_frame(camel, &c).unwrap();
        assert_eq!(a.messages[0].content_hash, b.messages[0].content_hash);
        assert_eq!(a.messages[0].body.text, "hello");
        assert_eq!(a.messages[0].ts_ms, 1_700_000_000_000);
        assert!(!a.messages[0].author.is_me);
    }

    #[test]
    fn canonicalizes_reactions_and_view_count_as_rendered_state() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let c = ctx(&aead, &unwrap, false);
        let frame = r#"{"id":"m1","chatId":"chat-1","senderId":"peer","timestamp":1,"reactions":[{"emoji":"❤️","count":8,"isSelected":true},{"emoji":"🔥","count":2}],"viewCount":340800}"#;

        let snapshot = canonicalize_frame(frame.as_bytes(), &c)
            .unwrap()
            .messages
            .remove(0);
        assert_eq!(snapshot.reactions.len(), 2);
        assert_eq!(snapshot.reactions[0].emoji, "❤️");
        assert_eq!(snapshot.reactions[0].count, 8);
        assert!(snapshot.reactions[0].is_selected);
        assert_eq!(snapshot.view_count, Some(340_800));

        let mut changed = snapshot.clone();
        changed.reactions[0].count += 1;
        changed.rehash();
        assert_ne!(snapshot.content_hash, changed.content_hash);
    }

    #[test]
    fn a_frame_without_an_id_is_dropped_not_prepended() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let c = ctx(&aead, &unwrap, false);
        let err = canonicalize_frame(br#"{"text":"orphan"}"#, &c).unwrap_err();
        assert_eq!(err, VibeCanonicalError::MissingMessageId);

        // In a page it drops only itself; the page still delivers.
        let page =
            canonicalize_frames(br#"[{"text":"orphan"},{"id":"real","timestamp":1}]"#, &c).unwrap();
        assert_eq!(page.messages.len(), 1);
        assert_eq!(page.dropped, vec![VibeCanonicalError::MissingMessageId]);
    }

    #[test]
    fn saved_messages_prefers_the_original_id() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let frame = br#"{"id":"saved-copy-1","original_message_id":"origin-1","chat_id":"saved_messages","timestamp":10,"encrypted_content":"{\"text\":\"note\"}"}"#;

        let saved = canonicalize_frame(frame, &ctx(&aead, &unwrap, true)).unwrap();
        assert_eq!(saved.messages[0].message_id, "origin-1");

        let normal = canonicalize_frame(frame, &ctx(&aead, &unwrap, false)).unwrap();
        assert_eq!(normal.messages[0].message_id, "saved-copy-1");
    }

    #[test]
    fn group_plaintext_payload_is_read_without_an_envelope() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let frame = br#"{"id":"g1","chat_id":"group-1","sender_id":"peer","timestamp":5,"encrypted_content":"{\"text\":\"group message\",\"caption\":null}"}"#;
        let out = canonicalize_frame(frame, &ctx(&aead, &unwrap, false)).unwrap();
        assert_eq!(out.messages[0].body.text, "group message");
        assert!(!out.messages[0]
            .flags
            .contains(VibeMessageFlags::DECRYPTION_FAILED));
    }

    #[test]
    fn an_unopenable_envelope_flags_the_row_instead_of_rendering_base64() {
        use base64::engine::general_purpose::STANDARD as B64;
        use base64::Engine as _;

        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let env = format!(
            "{{\\\"v\\\":1,\\\"iv\\\":\\\"{}\\\",\\\"c\\\":\\\"{}\\\",\\\"k\\\":\\\"{}\\\"}}",
            B64.encode([1u8; 12]),
            B64.encode([2u8; 48]),
            B64.encode([3u8; 256])
        );
        let frame = format!(
            r#"{{"id":"e1","chat_id":"chat-1","sender_id":"peer","timestamp":5,"encrypted_content":"{env}"}}"#
        );
        let out = canonicalize_frame(frame.as_bytes(), &ctx(&aead, &unwrap, false)).unwrap();
        let m = &out.messages[0];
        assert!(m.flags.contains(VibeMessageFlags::DECRYPTION_FAILED));
        assert!(m.body.text.is_empty());
    }

    /// This crate cannot open MLS and never will (`vibe_secure` owns the ratchet), so
    /// the arm that recognises the format used to leave the row blank AND unflagged —
    /// a delivered message that reads as an empty bubble with nothing to explain it.
    #[test]
    fn an_mls_envelope_with_no_host_plaintext_is_flagged_not_silently_blank() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let frame = r#"{"id":"mls-1","chat_id":"chat-1","sender_id":"peer","timestamp":5,"encrypted_content":"vmls1.AAAA"}"#;
        let out = canonicalize_frame(frame.as_bytes(), &ctx(&aead, &unwrap, false)).unwrap();
        let m = &out.messages[0];
        assert!(m.flags.contains(VibeMessageFlags::DECRYPTION_FAILED));
        assert!(m.body.text.is_empty());
    }

    /// A public media URL on an unopened MLS frame is ciphertext, not Plain media.
    #[test]
    fn an_unopened_mls_media_url_is_not_plain_media() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let frame = r#"{"id":"mls-media","chat_id":"chat-1","sender_id":"peer","timestamp":5,"encrypted_content":"vmls1.AAAA","media_url":"https://media.vibegram.io/chat-media/x/photo.png"}"#;
        let out = canonicalize_frame(frame.as_bytes(), &ctx(&aead, &unwrap, false)).unwrap();
        let m = &out.messages[0];
        assert!(m.flags.contains(VibeMessageFlags::DECRYPTION_FAILED));
        assert!(m.media.is_none());
    }

    /// The host opens MLS and projects the plaintext into the frame. That row is
    /// readable, so flagging it would inflate `decryptFailed` with working messages.
    #[test]
    fn an_mls_envelope_opened_by_the_host_is_not_flagged() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let frame = r#"{"id":"mls-2","chat_id":"chat-1","sender_id":"peer","timestamp":6,"encrypted_content":"vmls1.AAAA","text":"hello"}"#;
        let out = canonicalize_frame(frame.as_bytes(), &ctx(&aead, &unwrap, false)).unwrap();
        let m = &out.messages[0];
        assert!(!m.flags.contains(VibeMessageFlags::DECRYPTION_FAILED));
        assert_eq!(m.body.text, "hello");
    }

    #[test]
    fn thumbnail_bytes_are_lifted_out_of_the_snapshot() {
        use base64::engine::general_purpose::STANDARD as B64;
        use base64::Engine as _;

        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let thumb = B64.encode(vec![0xAAu8; 3000]);
        let payload = format!(
            r#"{{\"text\":\"\",\"mediaUrl\":\"https://cdn.vibegram.io/m/1.jpg\",\"mediaKey\":\"k1\",\"thumbnailBase64\":\"{thumb}\",\"width\":1600,\"height\":900,\"mimeType\":\"image/jpeg\"}}"#
        );
        let frame = format!(
            r#"{{"id":"i1","chat_id":"chat-1","sender_id":"peer","timestamp":5,"encrypted_content":"{payload}"}}"#
        );

        let out = canonicalize_frame(frame.as_bytes(), &ctx(&aead, &unwrap, false)).unwrap();
        let m = &out.messages[0];
        let media = m.media.as_ref().unwrap();
        assert_eq!(media.identity, "cdn.vibegram.io/m/1.jpg|k:k1");
        assert_eq!(
            media.natural_size,
            Some(VibeSize {
                width: 1600,
                height: 900
            })
        );
        assert_eq!(m.kind, VibeMessageKind::Image);
        assert!(matches!(media.envelope, VibeMediaEnvelope::Gcm1 { .. }));

        // The handle is in the snapshot; the bytes came back on the side channel.
        assert_eq!(
            media.thumbnail.as_ref().unwrap().identity,
            "cdn.vibegram.io/m/1.jpg|k:k1|thumb"
        );
        assert_eq!(out.thumbnails.len(), 1);
        assert_eq!(out.thumbnails[0].bytes.len(), 3000);

        // And the snapshot itself carries no image bytes anywhere.
        let rendered = format!("{m:?}");
        assert!(
            !rendered.contains("qqqq"),
            "base64 thumbnail leaked into Debug"
        );
    }

    #[test]
    fn unknown_aspect_stays_none_rather_than_guessing_square() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let frame = br#"{"id":"i2","chat_id":"c","timestamp":5,"encrypted_content":"{\"text\":\"\",\"mediaUrl\":\"https://cdn/x.jpg\",\"width\":0,\"height\":0}"}"#;
        let out = canonicalize_frame(frame, &ctx(&aead, &unwrap, false)).unwrap();
        assert!(out.messages[0]
            .media
            .as_ref()
            .unwrap()
            .natural_size
            .is_none());
    }

    #[test]
    fn agent_sealed_payloads_stay_opaque() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let frame = br#"{"id":"bridge-1","chat_id":"c","timestamp":5,"isAgentMessage":true,"agentUserId":"CLAUDE","isStreaming":true,"agentRuntimeEnc":"arte1.AAAA.BBBB.CCCC","plainContent":"working","progressNodes":[{"id":"n1","kind":"tool","label":"Read","detail":"lib.rs"}]}"#;
        let out = canonicalize_frame(frame, &ctx(&aead, &unwrap, false)).unwrap();
        let m = &out.messages[0];
        let agent = m.agent.as_ref().unwrap();
        assert_eq!(agent.provider, "claude");
        assert!(agent.is_streaming);
        assert!(m.flags.contains(VibeMessageFlags::STREAMING));
        assert!(m.flags.contains(VibeMessageFlags::TRANSIENT_ID));
        assert_eq!(agent.progress.len(), 1);
        assert_eq!(m.kind, VibeMessageKind::AgentTurn);

        let sealed = agent.sealed.as_ref().unwrap();
        assert_eq!(sealed.as_bytes(), b"arte1.AAAA.BBBB.CCCC");
        assert!(!format!("{sealed:?}").contains("AAAA"));
    }

    #[test]
    fn a_history_page_unwraps_keys_in_one_batch() {
        use std::sync::Mutex;

        struct CountingUnwrapper {
            calls: Mutex<usize>,
            requests: Mutex<usize>,
        }
        impl VibeKeyUnwrapper for CountingUnwrapper {
            fn unwrap_aes_keys(
                &self,
                requests: &[VibeWrappedKeyRequest],
            ) -> Vec<Option<crate::secret::VibeSecretKey>> {
                *self.calls.lock().unwrap() += 1;
                *self.requests.lock().unwrap() += requests.len();
                requests.iter().map(|_| None).collect()
            }
        }

        use base64::engine::general_purpose::STANDARD as B64;
        use base64::Engine as _;
        let env = format!(
            "{{\\\"v\\\":1,\\\"iv\\\":\\\"{}\\\",\\\"c\\\":\\\"{}\\\",\\\"k\\\":\\\"{}\\\"}}",
            B64.encode([1u8; 12]),
            B64.encode([2u8; 48]),
            B64.encode([3u8; 256])
        );
        let frames: Vec<String> = (0..25)
            .map(|i| {
                format!(
                    r#"{{"id":"m{i}","chat_id":"c","timestamp":{i},"encrypted_content":"{env}"}}"#
                )
            })
            .collect();
        let page = format!("[{}]", frames.join(","));

        let aead = VibeDenyAllAead;
        let unwrap = CountingUnwrapper {
            calls: Mutex::new(0),
            requests: Mutex::new(0),
        };
        let out = canonicalize_frames(page.as_bytes(), &ctx(&aead, &unwrap, false)).unwrap();
        assert_eq!(out.messages.len(), 25);
        assert_eq!(*unwrap.calls.lock().unwrap(), 1, "one call per page");
        assert_eq!(*unwrap.requests.lock().unwrap(), 25);
    }

    #[test]
    fn a_malformed_row_inside_a_page_drops_only_itself() {
        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let page = br#"[{"id":"a","timestamp":1},"not an object",{"timestamp":2},{"id":"b","timestamp":3}]"#;
        let out = canonicalize_frames(page, &ctx(&aead, &unwrap, false)).unwrap();
        assert_eq!(out.messages.len(), 2);
        assert_eq!(out.dropped.len(), 2);
    }

    #[test]
    fn timestamps_parse_from_every_shape_the_wire_uses() {
        assert_eq!(parse_iso8601_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_iso8601_ms("2026-08-02T12:00:00Z"),
            Some(1_785_672_000_000)
        );
        assert_eq!(
            parse_iso8601_ms("2026-08-02T12:00:00.250Z"),
            Some(1_785_672_000_250)
        );
        assert_eq!(
            parse_iso8601_ms("2026-08-02T17:30:00+05:30"),
            Some(1_785_672_000_000)
        );
        assert_eq!(
            parse_iso8601_ms("2026-08-02T17:30:00+0530"),
            Some(1_785_672_000_000)
        );
        assert_eq!(
            parse_iso8601_ms("2026-08-02 12:00:00"),
            Some(1_785_672_000_000)
        );
        assert_eq!(parse_iso8601_ms("not a date"), None);
        assert_eq!(parse_iso8601_ms("2026-13-02T12:00:00Z"), None);

        let aead = VibeDenyAllAead;
        let unwrap = VibeDenyAllKeyUnwrapper;
        let c = ctx(&aead, &unwrap, false);
        // Seconds are promoted to milliseconds.
        let secs = canonicalize_frame(br#"{"id":"a","timestamp":1700000000}"#, &c).unwrap();
        assert_eq!(secs.messages[0].ts_ms, 1_700_000_000_000);
        let iso =
            canonicalize_frame(br#"{"id":"a","created_at":"2026-08-02T12:00:00Z"}"#, &c).unwrap();
        assert_eq!(iso.messages[0].ts_ms, 1_785_672_000_000);
    }

    #[cfg(feature = "aead-aes-gcm")]
    #[test]
    fn a_real_envelope_opens_through_the_batched_unwrapper() {
        use crate::crypto::VibeAesGcm256Aead;
        use crate::secret::VibeSecretKey;

        struct FixedKeyUnwrapper;
        impl VibeKeyUnwrapper for FixedKeyUnwrapper {
            fn unwrap_aes_keys(
                &self,
                requests: &[VibeWrappedKeyRequest],
            ) -> Vec<Option<VibeSecretKey>> {
                requests
                    .iter()
                    .map(|_| Some(VibeSecretKey::from_bytes([42u8; 32])))
                    .collect()
            }
        }

        let aead = VibeAesGcm256Aead;
        let sealed = envelope::seal_hybrid(
            &aead,
            &VibeSecretKey::from_bytes([42u8; 32]),
            br#"{"text":"secret hello","caption":"cap"}"#,
            vec![3u8; 256],
            None,
        )
        .unwrap();

        let wire = sealed.to_json().replace('"', "\\\"");
        let frame = format!(
            r#"{{"id":"e1","chat_id":"c","sender_id":"peer","timestamp":5,"encrypted_content":"{wire}"}}"#
        );

        let unwrapper = FixedKeyUnwrapper;
        let out = canonicalize_frame(frame.as_bytes(), &ctx(&aead, &unwrapper, false)).unwrap();
        let m = &out.messages[0];
        assert_eq!(m.body.text, "secret hello");
        assert_eq!(m.body.caption.as_deref(), Some("cap"));
        assert!(!m.flags.contains(VibeMessageFlags::DECRYPTION_FAILED));
    }

    /// A photo sent without a caption decrypts to a payload whose `text` is `""`. That
    /// is a successful decrypt of a message that simply has no words in it, and it must
    /// not carry the failure flag.
    ///
    /// This is the case the flag condition used to get wrong, by transcribing the shipped
    /// client's `decryptedText.isEmpty` (the whole envelope opened to nothing) as "the
    /// payload's `text` field is empty". It inflated every `decryptFailed=` count in a
    /// chat containing media, and would have rendered those photos as failure states the
    /// day the list reads from the core.
    #[cfg(feature = "aead-aes-gcm")]
    #[test]
    fn a_captionless_photo_is_not_a_decryption_failure() {
        use crate::crypto::VibeAesGcm256Aead;
        use crate::secret::VibeSecretKey;

        struct FixedKeyUnwrapper;
        impl VibeKeyUnwrapper for FixedKeyUnwrapper {
            fn unwrap_aes_keys(
                &self,
                requests: &[VibeWrappedKeyRequest],
            ) -> Vec<Option<VibeSecretKey>> {
                requests
                    .iter()
                    .map(|_| Some(VibeSecretKey::from_bytes([42u8; 32])))
                    .collect()
            }
        }

        let aead = VibeAesGcm256Aead;
        let sealed = envelope::seal_hybrid(
            &aead,
            &VibeSecretKey::from_bytes([42u8; 32]),
            br#"{"text":"","mediaUrl":"https://example.test/p.jpg","mediaKey":"k","type":"image"}"#,
            vec![3u8; 256],
            None,
        )
        .unwrap();

        let wire = sealed.to_json().replace('"', "\\\"");
        let frame = format!(
            r#"{{"id":"e2","chat_id":"c","sender_id":"peer","timestamp":5,"encrypted_content":"{wire}"}}"#
        );

        let out =
            canonicalize_frame(frame.as_bytes(), &ctx(&aead, &FixedKeyUnwrapper, false)).unwrap();
        let m = &out.messages[0];
        assert!(m.body.text.is_empty());
        assert!(
            !m.flags.contains(VibeMessageFlags::DECRYPTION_FAILED),
            "a captionless photo opened fine; only an envelope with no usable payload fails"
        );
    }

    /// The other half of the same contract: bytes that open but are not JSON have no
    /// usable payload, so the row IS a failure even though `decryption_failed` is false.
    /// This is the case the old `text.is_empty()` clause was reaching for, and the only
    /// one it was right about.
    #[cfg(feature = "aead-aes-gcm")]
    #[test]
    fn an_envelope_that_opens_to_non_json_is_a_decryption_failure() {
        use crate::crypto::VibeAesGcm256Aead;
        use crate::secret::VibeSecretKey;

        struct FixedKeyUnwrapper;
        impl VibeKeyUnwrapper for FixedKeyUnwrapper {
            fn unwrap_aes_keys(
                &self,
                requests: &[VibeWrappedKeyRequest],
            ) -> Vec<Option<VibeSecretKey>> {
                requests
                    .iter()
                    .map(|_| Some(VibeSecretKey::from_bytes([42u8; 32])))
                    .collect()
            }
        }

        let aead = VibeAesGcm256Aead;
        let sealed = envelope::seal_hybrid(
            &aead,
            &VibeSecretKey::from_bytes([42u8; 32]),
            b"not json at all",
            vec![3u8; 256],
            None,
        )
        .unwrap();

        let wire = sealed.to_json().replace('"', "\\\"");
        let frame = format!(
            r#"{{"id":"e3","chat_id":"c","sender_id":"peer","timestamp":5,"encrypted_content":"{wire}"}}"#
        );

        let out =
            canonicalize_frame(frame.as_bytes(), &ctx(&aead, &FixedKeyUnwrapper, false)).unwrap();
        assert!(out.messages[0]
            .flags
            .contains(VibeMessageFlags::DECRYPTION_FAILED));
    }
}
