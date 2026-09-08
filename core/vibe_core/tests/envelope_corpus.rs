//! Malformed-input corpus.
//!
//! Every parser in this crate reads attacker-influenced bytes. The contract is:
//! **never panic, never allocate unboundedly, never produce a message that looks
//! like it decrypted, and never echo the input into an error.**
//!
//! These are also the seed corpora for `cargo-fuzz` targets. The crate is
//! fuzz-ready in the practical sense: `parse_hybrid`, `parse_agent_sealed`,
//! `canonicalize_frame` and `parse_stream2_header` are pure functions of
//! `&[u8]`/`&str` with no global state, no I/O, and explicit size ceilings.

mod common;

use vibe_core::canonical::{canonicalize_frame, canonicalize_frames, VibeCanonicalContext};
use vibe_core::crypto::{VibeDenyAllAead, VibeDenyAllKeyUnwrapper};
use vibe_core::envelope::{
    classify, parse_agent_sealed, parse_hybrid, VibeEnvelopeFormat, MAX_ENVELOPE_BYTES,
};
use vibe_core::fixtures::{malformed_envelope_corpus, malformed_frame_corpus};
use vibe_core::media::{parse_stream2_header, split_gcm1, validate_media_bytes, VibeMediaClass};
use vibe_core::VibeMessageFlags;

fn ctx<'a>(
    aead: &'a VibeDenyAllAead,
    unwrapper: &'a VibeDenyAllKeyUnwrapper,
) -> VibeCanonicalContext<'a> {
    VibeCanonicalContext {
        chat_id: "chat-1",
        own_user_id: "me",
        is_saved_messages: false,
        aead,
        unwrapper,
    }
}

#[test]
fn no_malformed_envelope_parses_as_a_valid_one() {
    for raw in malformed_envelope_corpus() {
        let classified = classify(&raw);
        let parsed = parse_hybrid(&raw);
        match classified {
            VibeEnvelopeFormat::HybridV1 => {
                // Classified as hybrid means it has iv+c+k; strict parse may
                // still reject it on lengths or version, and that is fine — but
                // if it parses, it must round-trip.
                if let Ok(env) = parsed {
                    let reparsed = parse_hybrid(&env.to_json())
                        .expect("a parsed envelope must re-parse from its own output");
                    assert_eq!(env, reparsed);
                }
            }
            _ => assert!(
                parsed.is_err(),
                "non-hybrid input must not strict-parse: {raw:?}"
            ),
        }
    }
}

#[test]
fn envelope_errors_never_echo_the_input() {
    let secret_marker = "SUPERSECRETMARKER";
    let raw = format!(r#"{{"iv":"{secret_marker}","c":"{secret_marker}","k":"{secret_marker}"}}"#);
    let err = parse_hybrid(&raw).unwrap_err();
    let rendered = format!("{err} {err:?}");
    assert!(
        !rendered.contains(secret_marker),
        "error leaked input: {rendered}"
    );
}

#[test]
fn oversized_input_is_refused_by_length_not_by_parsing() {
    let huge = "{".to_string() + &"a".repeat(MAX_ENVELOPE_BYTES + 16);
    let err = parse_hybrid(&huge).unwrap_err();
    assert!(format!("{err}").contains("too large"));
}

#[test]
fn agent_blob_shapes_are_rejected_without_decryption() {
    for raw in malformed_envelope_corpus() {
        if raw.starts_with("arte1.") {
            // Either it is a well-formed shape or it is None. Never a panic and
            // never an attempt to open it.
            let _ = parse_agent_sealed(&raw);
        }
    }
    assert!(parse_agent_sealed("arte1.").is_none());
    assert!(parse_agent_sealed("arte1.a.b").is_none());
    assert!(parse_agent_sealed("not-arte1").is_none());
}

#[test]
fn malformed_frames_are_dropped_and_counted_never_fatal() {
    let aead = VibeDenyAllAead;
    let unwrapper = VibeDenyAllKeyUnwrapper;
    let ctx = ctx(&aead, &unwrapper);

    for frame in malformed_frame_corpus() {
        // A single-frame call may report the reason; it must never panic.
        let _ = canonicalize_frame(&frame, &ctx);
    }

    // The same corpus inside one page: the page still delivers whatever is
    // usable, and every failure is counted rather than thrown.
    let joined: Vec<String> = malformed_frame_corpus()
        .into_iter()
        .filter_map(|f| String::from_utf8(f).ok())
        .filter(|f| !f.is_empty())
        .collect();
    let page = format!(
        "[{},{}]",
        joined.join(","),
        r#"{"id":"good","timestamp":1}"#
    );
    let out = canonicalize_frames(page.as_bytes(), &ctx).unwrap();
    assert!(out.messages.iter().any(|m| m.message_id == "good"));
    assert!(!out.dropped.is_empty());
}

#[test]
fn every_malformed_envelope_inside_a_frame_flags_rather_than_renders() {
    let aead = VibeDenyAllAead;
    let unwrapper = VibeDenyAllKeyUnwrapper;
    let ctx = ctx(&aead, &unwrapper);

    for raw in malformed_envelope_corpus() {
        let escaped = raw.replace('\\', "\\\\").replace('"', "\\\"");
        let frame = format!(r#"{{"id":"m1","timestamp":1,"encrypted_content":"{escaped}"}}"#);
        let Ok(out) = canonicalize_frame(frame.as_bytes(), &ctx) else {
            continue;
        };
        for message in &out.messages {
            // Whatever happened, the row must not claim to carry opened content
            // it never opened.
            if message.flags.contains(VibeMessageFlags::DECRYPTION_FAILED) {
                assert!(
                    message.body.text.is_empty(),
                    "a failed decrypt must not render a body"
                );
            }
        }
    }
}

#[test]
fn media_parsers_reject_junk_without_panicking() {
    let corpus: Vec<Vec<u8>> = vec![
        vec![],
        vec![0u8; 1],
        vec![0u8; 11],
        vec![0u8; 27],
        b"vmed2".to_vec(),
        b"vmed2\x01".to_vec(),
        b"vmed3\x01".to_vec(),
        {
            let mut v = b"vmed2\x01".to_vec();
            v.extend_from_slice(&[0u8; 16]);
            v.extend_from_slice(&u32::MAX.to_le_bytes());
            v
        },
        br#"{"error":"not media"}"#.to_vec(),
    ];

    for bytes in corpus {
        let _ = split_gcm1(&bytes);
        let _ = parse_stream2_header(&bytes);
        for class in [
            VibeMediaClass::Jpeg,
            VibeMediaClass::M4a,
            VibeMediaClass::Pdf,
            VibeMediaClass::Unknown,
        ] {
            let _ = validate_media_bytes(class, &bytes);
        }
    }
}

#[test]
fn plaintext_group_payloads_are_never_mistaken_for_envelopes() {
    // Everything a group actually sends over `encrypted_content`.
    for raw in [
        r#"{"text":"hello"}"#,
        r#"{"text":"hello","caption":null}"#,
        r#"{"text":"{\"iv\":\"x\"}"}"#,
        r#"{"iv_but_not_really":"x"}"#,
    ] {
        assert_eq!(
            classify(raw),
            VibeEnvelopeFormat::PlaintextPayloadJson,
            "{raw} must not be treated as an envelope"
        );
        assert!(parse_hybrid(raw).is_err());
    }
}
