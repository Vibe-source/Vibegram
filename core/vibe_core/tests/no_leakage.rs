//! Nothing secret may appear in a `Debug` render, an error string, or a
//! counter.
//!
//! This suite is the executable form of the rule that plaintext and key material
//! never enter diagnostics. It is deliberately blunt: it formats things and
//! greps for markers.
//!
//! What it does **not** claim, and what the production doc repeats: once a body
//! crosses into Swift/Kotlin/JS it becomes a platform string and this crate makes
//! no statement about its lifetime there. Zeroization buys "the key is not
//! sitting in a freed allocation"; it does not buy "plaintext never lingers in
//! process memory".

mod common;

use common::{reducer, text_event, CHAT, PEER, T0};

use vibe_core::canonical::{canonicalize_frame, VibeCanonicalContext};
use vibe_core::crypto::{VibeDenyAllAead, VibeDenyAllKeyUnwrapper, VibeWrappedKeyRequest};
use vibe_core::envelope::parse_hybrid;
use vibe_core::secret::VibeOpaqueBlob;
use vibe_core::types::{
    VibeAgentProgressNode, VibeAgentRef, VibeMediaEnvelope, VibeMediaRef, VibeServiceChip,
    VibeServiceNode, VibeThumbHandle,
};
use vibe_core::{VibeCoreEventV1, VibeEventBody, VibeEventSource, VibeMessageBody};

const MARKER: &str = "NUCLEARLAUNCHCODE";

#[test]
fn message_body_debug_reports_lengths_not_content() {
    let body = VibeMessageBody {
        text: MARKER.to_string(),
        caption: Some(MARKER.to_string()),
    };
    let rendered = format!("{body:?}");
    assert!(!rendered.contains(MARKER));
    assert!(rendered.contains("17 chars"));
}

#[test]
fn a_snapshot_debug_never_prints_the_body() {
    let mut r = reducer();
    r.ingest(text_event("m1", T0, PEER, MARKER));
    r.flush(T0);
    let window = r.current_window(CHAT).unwrap();
    let rendered = format!("{window:?}");
    assert!(
        !rendered.contains(MARKER),
        "window Debug leaked a message body"
    );
}

#[test]
fn a_delta_debug_never_prints_the_body() {
    let mut r = reducer();
    r.ingest(text_event("m1", T0, PEER, MARKER));
    let deltas = r.flush(T0);
    let rendered = format!("{deltas:?}");
    assert!(!rendered.contains(MARKER), "delta Debug leaked a body");
}

#[test]
fn an_event_debug_never_prints_the_frame() {
    let event = VibeCoreEventV1::new(
        CHAT,
        T0,
        VibeEventSource::ChatTopic,
        VibeEventBody::RawFrame {
            json: format!(r#"{{"text":"{MARKER}"}}"#).into_bytes(),
        },
    );
    let rendered = format!("{event:?}");
    assert!(!rendered.contains(MARKER));
    assert!(rendered.contains("raw_frame"));
}

#[test]
fn sealed_agent_blobs_render_as_a_length() {
    let blob = VibeOpaqueBlob::new(format!("arte1.{MARKER}").into_bytes());
    let rendered = format!("{blob:?}");
    assert!(!rendered.contains(MARKER));
    assert!(rendered.contains("sealed"));
}

#[test]
fn a_wrapped_key_request_debug_shows_a_count_not_the_blobs() {
    let request = VibeWrappedKeyRequest {
        message_id: "m1".into(),
        candidates: vec![MARKER.as_bytes().to_vec(), MARKER.as_bytes().to_vec()],
    };
    let rendered = format!("{request:?}");
    assert!(!rendered.contains(MARKER));
    assert!(rendered.contains('2'));
}

#[test]
fn errors_across_the_crate_carry_shapes_not_data() {
    // Envelope
    let raw = format!(r#"{{"iv":"{MARKER}","c":"{MARKER}","k":"{MARKER}"}}"#);
    let err = parse_hybrid(&raw).unwrap_err();
    assert!(!format!("{err} {err:?}").contains(MARKER));

    // Canonicalization
    let aead = VibeDenyAllAead;
    let unwrapper = VibeDenyAllKeyUnwrapper;
    let ctx = VibeCanonicalContext {
        chat_id: "c",
        own_user_id: "me",
        is_saved_messages: false,
        aead: &aead,
        unwrapper: &unwrapper,
    };
    let frame = format!(r#"{{"text":"{MARKER}"}}"#);
    let err = canonicalize_frame(frame.as_bytes(), &ctx).unwrap_err();
    assert!(!format!("{err} {err:?}").contains(MARKER));
}

#[test]
fn counters_are_numbers_only() {
    let mut r = reducer();
    for i in 0..20 {
        r.ingest(text_event(&format!("m{i}"), T0 + i, PEER, MARKER));
    }
    r.flush(T0 + 100);
    let counters = r.counters();
    let rendered = format!("{counters:?}");
    assert!(!rendered.contains(MARKER));
    assert!(counters.events_accepted >= 20);
}

#[test]
fn the_reducer_debug_summarizes_and_does_not_dump() {
    let mut r = reducer();
    r.ingest(text_event("m1", T0, PEER, MARKER));
    r.flush(T0);
    let rendered = format!("{r:?}");
    assert!(!rendered.contains(MARKER));
    assert!(rendered.contains("chats"));
}

#[test]
fn a_thumbnail_blob_debug_is_a_length() {
    use base64::engine::general_purpose::STANDARD as B64;
    use base64::Engine as _;

    let aead = VibeDenyAllAead;
    let unwrapper = VibeDenyAllKeyUnwrapper;
    let ctx = VibeCanonicalContext {
        chat_id: "c",
        own_user_id: "me",
        is_saved_messages: false,
        aead: &aead,
        unwrapper: &unwrapper,
    };
    let thumb = B64.encode(MARKER.repeat(40).as_bytes());
    let payload = format!(
        r#"{{\"text\":\"\",\"mediaUrl\":\"https://cdn/x.jpg\",\"thumbnailBase64\":\"{thumb}\"}}"#
    );
    let frame =
        format!(r#"{{"id":"m1","timestamp":1700000000000,"encrypted_content":"{payload}"}}"#);
    let out = canonicalize_frame(frame.as_bytes(), &ctx).unwrap();
    assert_eq!(out.thumbnails.len(), 1);
    let rendered = format!("{:?}", out.thumbnails[0]);
    assert!(!rendered.contains(MARKER));
    assert!(rendered.contains("bytes"));

    // And the snapshot itself carries a handle, not the pixels.
    let media = out.messages[0].media.as_ref().unwrap();
    assert!(media.thumbnail.is_some());
    let snapshot_rendered = format!("{:?}", out.messages[0]);
    assert!(!snapshot_rendered.contains(&thumb));
}

#[test]
fn rich_snapshot_metadata_debug_is_redacted() {
    let marker = MARKER.to_string();
    let media = VibeMediaRef {
        identity: marker.clone(),
        remote_url: Some(format!("https://cdn.invalid/file?token={MARKER}")),
        file_name: Some(marker.clone()),
        mime: Some(marker.clone()),
        byte_size: Some(1_024),
        natural_size: None,
        duration_s: None,
        waveform: vec![1, 2, 3],
        thumbnail: Some(VibeThumbHandle {
            identity: marker.clone(),
            size: None,
            placeholder: Some(marker.clone()),
        }),
        envelope: VibeMediaEnvelope::Gcm1 {
            key_ref: marker.clone(),
        },
    };
    assert!(!format!("{media:?}").contains(MARKER));

    let agent = VibeAgentRef {
        provider: marker.clone(),
        task_id: Some(marker.clone()),
        session_id: Some(marker.clone()),
        sealed: Some(VibeOpaqueBlob::new(marker.as_bytes().to_vec())),
        progress: vec![VibeAgentProgressNode {
            id: marker.clone(),
            kind: marker.clone(),
            label: marker.clone(),
            detail: Some(marker.clone()),
            is_terminal: false,
        }],
        is_streaming: true,
        elapsed_ms: Some(10),
    };
    assert!(!format!("{agent:?}").contains(MARKER));

    let service = VibeServiceNode {
        kind: marker.clone(),
        title: marker.clone(),
        subtitle: Some(marker.clone()),
        chips: vec![VibeServiceChip {
            id: marker.clone(),
            label: marker.clone(),
            style: marker.clone(),
        }],
        event_thread_id: Some(marker),
        folded_count: 1,
    };
    assert!(!format!("{service:?}").contains(MARKER));
}
