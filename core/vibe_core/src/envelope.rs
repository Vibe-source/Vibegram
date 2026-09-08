//! Strict, versioned envelope codec for `encrypted_content`.
//!
//! There are three independent implementations of this format shipping today
//! (Swift, Kotlin, TypeScript) and they have already diverged: the web client
//! accepts a legacy bare-base64 RSA-direct ciphertext that iOS does not, so a
//! user with pre-hybrid history reads it on the web and sees base64 as literal
//! text on the phone. This module is the one implementation the three are meant
//! to collapse onto.
//!
//! # The wire format, as it actually is
//!
//! ```text
//! encrypted_content = JSON string:
//! { "v": 1,
//!   "iv": b64(12-byte IV),
//!   "c":  b64(AES-256-GCM ciphertext || 16-byte tag),   // tag appended
//!   "k":  b64(RSA-2048-OAEP-SHA256(aes_key) to recipient),
//!   "s":  b64(RSA-2048-OAEP-SHA256(aes_key) to sender)   // optional
//! }
//! ```
//!
//! # Two things this module refuses to do
//!
//! * **It never emits the `g` slot.** `g` is read by the shipped clients and
//!   written by none of them; it is a reserved group-key slot. A core that
//!   started emitting `g` would be interpreted as a group key by every deployed
//!   client. Claiming it is a deliberate protocol decision for a future group-key
//!   rollout, not something a codec does on its own.
//! * **It never assumes `encrypted_content` is an envelope.** Group and channel
//!   messages, and 1:1 messages sent when the peer's public key was unavailable,
//!   put the *plaintext payload JSON* in that same field. Detection is therefore
//!   a positive test, reproduced bit-for-bit from the shipped client:
//!   trimmed input starts with `{`, parses as a JSON object, and has all three of
//!   `iv`, `c`, `k`.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use serde_json::Value;

use crate::crypto::VibeAeadProvider;
use crate::error::VibeEnvelopeError;
use crate::secret::{VibeNonce, VibePlaintext, VibeSecretKey, VIBE_NONCE_LEN, VIBE_TAG_LEN};

/// The only envelope version this build accepts.
pub const VIBE_ENVELOPE_VERSION: i64 = 1;

/// Ceiling on an `encrypted_content` string. Inline `thumbnailBase64` makes real
/// payloads reach a few hundred kilobytes; 8 MiB is generous and still bounds a
/// hostile frame.
pub const MAX_ENVELOPE_BYTES: usize = 8 * 1024 * 1024;

/// Associated data for the *message* envelope: empty.
///
/// This is a compatibility constraint, not a preference. The shipped Swift, Kotlin
/// and TypeScript clients all seal message payloads with no AAD, so binding
/// anything here would make every historical message unopenable. The durable
/// store seal — a new format with no deployed readers — *does* bind AAD; see
/// `docs/production-timeline-core-refactor.md` § "Persistence".
pub const VIBE_MESSAGE_ENVELOPE_AAD: &[u8] = b"";

/// Prefix of the sealed agent runtime format. Recognised, never opened.
pub const VIBE_AGENT_SEALED_PREFIX: &str = "arte1.";

/// Prefix of an MLS application message. Recognised, never opened — see
/// [`VibeEnvelopeFormat::MlsV2`]. The payload belongs to `vibe_secure`, which
/// this crate does not depend on and cannot import.
pub const VIBE_MLS_SEALED_PREFIX: &str = "vmls1.";

/// What a raw `encrypted_content` string actually is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeEnvelopeFormat {
    /// `{v,iv,c,k,s?,g?}` — the hybrid envelope.
    HybridV1,
    /// A JSON object that is the message payload itself, in the clear. Groups,
    /// channels, and the `friendPublicKey == nil` DM fallback.
    PlaintextPayloadJson,
    /// Bare base64 of an RSA-OAEP ciphertext, no JSON wrapper. Pre-hybrid
    /// history. The web client opens these; iOS renders them as text.
    LegacyRsaDirect,
    /// `arte1.<iv>.<ct>.<tag>` — agent runtime, sealed under a pairing key this
    /// crate does not have and must never be given.
    AgentSealedArte1,
    /// `vmls1.<base64>` — an MLS application message. Recognised so it is never
    /// mistaken for plaintext payload JSON; opened by `vibe_secure`, not here.
    MlsV2,
    /// Anything else. Rendered as literal text, exactly as today.
    Unrecognized,
}

/// A parsed hybrid envelope. Holds ciphertext and *wrapped* keys — no plaintext,
/// no unwrapped key — so it is safe to `Debug`.
#[derive(Clone, PartialEq, Eq)]
pub struct VibeHybridEnvelopeV1 {
    pub version: i64,
    pub nonce: VibeNonce,
    /// `ciphertext || tag`.
    pub ciphertext_and_tag: Vec<u8>,
    /// `k` — wrapped to the recipient.
    pub key_to_recipient: Vec<u8>,
    /// `s` — wrapped to the sender. Absent on very old messages.
    pub key_to_sender: Option<Vec<u8>>,
    /// `g` — reserved group slot. Parsed if present so a future rollout is not a
    /// format change; never written by this crate.
    pub key_group: Option<Vec<u8>>,
}

impl std::fmt::Debug for VibeHybridEnvelopeV1 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeHybridEnvelopeV1")
            .field("version", &self.version)
            .field("ciphertext_len", &self.ciphertext_and_tag.len())
            .field("has_sender_slot", &self.key_to_sender.is_some())
            .field("has_group_slot", &self.key_group.is_some())
            .finish()
    }
}

/// Direction of a message, which decides the order the wrapped-key slots are
/// tried in. Reproduced from the shipped client; getting it backwards changes
/// which historical messages open.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeEnvelopeDirection {
    /// Sent by this device's user: try `s` before `k`.
    Outgoing,
    /// Received: try `k` before `s`.
    Incoming,
}

impl VibeHybridEnvelopeV1 {
    /// Wrapped-key candidates in the order the shipped client tries them:
    /// `g` always first, then direction-dependent `s`/`k`.
    pub fn key_candidates(&self, direction: VibeEnvelopeDirection) -> Vec<Vec<u8>> {
        let mut out = Vec::with_capacity(3);
        if let Some(g) = &self.key_group {
            out.push(g.clone());
        }
        match direction {
            VibeEnvelopeDirection::Outgoing => {
                if let Some(s) = &self.key_to_sender {
                    out.push(s.clone());
                }
                out.push(self.key_to_recipient.clone());
            }
            VibeEnvelopeDirection::Incoming => {
                out.push(self.key_to_recipient.clone());
                if let Some(s) = &self.key_to_sender {
                    out.push(s.clone());
                }
            }
        }
        out
    }

    /// Opens the payload with an already-unwrapped content key.
    pub fn open(
        &self,
        provider: &dyn VibeAeadProvider,
        key: &VibeSecretKey,
    ) -> Result<VibePlaintext, crate::error::VibeCryptoError> {
        provider.open(
            key,
            &self.nonce,
            VIBE_MESSAGE_ENVELOPE_AAD,
            &self.ciphertext_and_tag,
        )
    }

    /// Canonical serialization.
    ///
    /// Field order is `v, iv, c, k, s`. JSON object order is not semantically
    /// significant here (every client parses into a map, verified on both
    /// sides), but a fixed order makes the output byte-reproducible, which
    /// differential tests rely on. `g` is never written.
    pub fn to_json(&self) -> String {
        let mut out = String::with_capacity(self.ciphertext_and_tag.len() * 2 + 512);
        out.push_str("{\"v\":");
        out.push_str(&self.version.to_string());
        out.push_str(",\"iv\":\"");
        out.push_str(&B64.encode(self.nonce.as_bytes()));
        out.push_str("\",\"c\":\"");
        out.push_str(&B64.encode(&self.ciphertext_and_tag));
        out.push_str("\",\"k\":\"");
        out.push_str(&B64.encode(&self.key_to_recipient));
        out.push('"');
        if let Some(s) = &self.key_to_sender {
            out.push_str(",\"s\":\"");
            out.push_str(&B64.encode(s));
            out.push('"');
        }
        out.push('}');
        out
    }
}

/// Cheap classifier. Does not allocate a parsed envelope.
pub fn classify(raw: &str) -> VibeEnvelopeFormat {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return VibeEnvelopeFormat::Unrecognized;
    }
    if trimmed.starts_with(VIBE_AGENT_SEALED_PREFIX) {
        return if parse_agent_sealed(trimmed).is_some() {
            VibeEnvelopeFormat::AgentSealedArte1
        } else {
            VibeEnvelopeFormat::Unrecognized
        };
    }
    // Prefix-only: this crate recognises an MLS application message so it is
    // never mistaken for plaintext payload JSON, but never opens it — there is
    // no shape to validate here the way `parse_agent_sealed` validates arte1,
    // because the body belongs entirely to `vibe_secure`.
    if trimmed.starts_with(VIBE_MLS_SEALED_PREFIX) {
        return VibeEnvelopeFormat::MlsV2;
    }
    if trimmed.starts_with('{') {
        let Ok(Value::Object(map)) = serde_json::from_str::<Value>(trimmed) else {
            return VibeEnvelopeFormat::Unrecognized;
        };
        // Bit-identical to the shipped `isLikelyHybridCiphertext` rule.
        if map.contains_key("iv") && map.contains_key("c") && map.contains_key("k") {
            return VibeEnvelopeFormat::HybridV1;
        }
        return VibeEnvelopeFormat::PlaintextPayloadJson;
    }
    if looks_like_bare_base64(trimmed) {
        return VibeEnvelopeFormat::LegacyRsaDirect;
    }
    VibeEnvelopeFormat::Unrecognized
}

/// Strict parse. Every failure names a field, never a value.
pub fn parse_hybrid(raw: &str) -> Result<VibeHybridEnvelopeV1, VibeEnvelopeError> {
    if raw.len() > MAX_ENVELOPE_BYTES {
        return Err(VibeEnvelopeError::TooLarge {
            limit: MAX_ENVELOPE_BYTES,
            actual: raw.len(),
        });
    }
    let trimmed = raw.trim();
    if !trimmed.starts_with('{') {
        return Err(VibeEnvelopeError::NotAnEnvelope);
    }
    let parsed: Value = serde_json::from_str(trimmed).map_err(|_| VibeEnvelopeError::NotJson)?;
    let Value::Object(map) = parsed else {
        return Err(VibeEnvelopeError::NotAnEnvelope);
    };
    if !(map.contains_key("iv") && map.contains_key("c") && map.contains_key("k")) {
        return Err(VibeEnvelopeError::NotAnEnvelope);
    }

    // `v` absent means the original v1 shape, which predates the field.
    let version = match map.get("v") {
        None | Some(Value::Null) => VIBE_ENVELOPE_VERSION,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(i64::MIN),
        Some(_) => return Err(VibeEnvelopeError::FieldNotAString { field: "v" }),
    };
    if version != VIBE_ENVELOPE_VERSION {
        return Err(VibeEnvelopeError::UnsupportedVersion {
            found: version,
            supported: VIBE_ENVELOPE_VERSION,
        });
    }

    let iv = decode_field(&map, "iv")?;
    if iv.len() != VIBE_NONCE_LEN {
        return Err(VibeEnvelopeError::FieldWrongLength {
            field: "iv",
            expected: VIBE_NONCE_LEN,
            actual: iv.len(),
        });
    }
    let nonce = VibeNonce::from_slice(&iv).map_err(|e| VibeEnvelopeError::FieldWrongLength {
        field: "iv",
        expected: e.expected,
        actual: e.actual,
    })?;

    let ciphertext_and_tag = decode_field(&map, "c")?;
    if ciphertext_and_tag.len() < VIBE_TAG_LEN {
        return Err(VibeEnvelopeError::FieldWrongLength {
            field: "c",
            expected: VIBE_TAG_LEN,
            actual: ciphertext_and_tag.len(),
        });
    }

    let key_to_recipient = decode_field(&map, "k")?;
    if key_to_recipient.is_empty() {
        return Err(VibeEnvelopeError::FieldWrongLength {
            field: "k",
            expected: 1,
            actual: 0,
        });
    }

    let key_to_sender = decode_optional_field(&map, "s")?;
    let key_group = decode_optional_field(&map, "g")?;

    Ok(VibeHybridEnvelopeV1 {
        version,
        nonce,
        ciphertext_and_tag,
        key_to_recipient,
        key_to_sender,
        key_group,
    })
}

/// Components of an `arte1` blob. Recognised so the pipeline can carry it as
/// opaque bytes with a known shape; **never opened here**. The pairing key lives
/// only on the phone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeAgentSealedShape {
    pub iv_len: usize,
    pub ciphertext_len: usize,
    pub tag_len: usize,
}

/// Validates the shape of an `arte1.<iv>.<ct>.<tag>` string without decrypting.
pub fn parse_agent_sealed(raw: &str) -> Option<VibeAgentSealedShape> {
    if raw.len() > MAX_ENVELOPE_BYTES {
        return None;
    }
    let rest = raw.strip_prefix(VIBE_AGENT_SEALED_PREFIX)?;
    let mut parts = rest.split('.');
    let iv = B64.decode(parts.next()?).ok()?;
    let ct = B64.decode(parts.next()?).ok()?;
    let tag = B64.decode(parts.next()?).ok()?;
    if parts.next().is_some() {
        return None;
    }
    if iv.len() != VIBE_NONCE_LEN || ct.is_empty() || tag.len() != VIBE_TAG_LEN {
        return None;
    }
    Some(VibeAgentSealedShape {
        iv_len: iv.len(),
        ciphertext_len: ct.len(),
        tag_len: tag.len(),
    })
}

/// Seals a payload into a hybrid envelope.
///
/// The wrapped-key slots are supplied by the caller because wrapping is an RSA
/// public-key operation this crate does not perform. `g` cannot be supplied.
pub fn seal_hybrid(
    provider: &dyn VibeAeadProvider,
    key: &VibeSecretKey,
    plaintext: &[u8],
    key_to_recipient: Vec<u8>,
    key_to_sender: Option<Vec<u8>>,
) -> Result<VibeHybridEnvelopeV1, crate::error::VibeCryptoError> {
    let nonce = VibeNonce::random()?;
    let ciphertext_and_tag = provider.seal(key, &nonce, VIBE_MESSAGE_ENVELOPE_AAD, plaintext)?;
    Ok(VibeHybridEnvelopeV1 {
        version: VIBE_ENVELOPE_VERSION,
        nonce,
        ciphertext_and_tag,
        key_to_recipient,
        key_to_sender,
        key_group: None,
    })
}

fn decode_field(
    map: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<Vec<u8>, VibeEnvelopeError> {
    let value = map
        .get(field)
        .ok_or(VibeEnvelopeError::MissingField { field })?;
    let s = value
        .as_str()
        .ok_or(VibeEnvelopeError::FieldNotAString { field })?;
    B64.decode(s)
        .map_err(|_| VibeEnvelopeError::FieldNotBase64 { field })
}

fn decode_optional_field(
    map: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<Option<Vec<u8>>, VibeEnvelopeError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.is_empty() => Ok(None),
        Some(Value::String(s)) => B64
            .decode(s)
            .map(Some)
            .map_err(|_| VibeEnvelopeError::FieldNotBase64 { field }),
        Some(_) => Err(VibeEnvelopeError::FieldNotAString { field }),
    }
}

/// Heuristic for the legacy bare-base64 RSA-direct form.
///
/// An RSA-2048 ciphertext is 256 bytes, which is 344 base64 characters with
/// padding. Requiring that exact length (rather than "looks base64-ish") keeps
/// ordinary text — which is frequently valid base64 by accident — out of this
/// branch.
fn looks_like_bare_base64(s: &str) -> bool {
    const RSA2048_B64_LEN: usize = 344;
    if s.len() != RSA2048_B64_LEN {
        return false;
    }
    if !s
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
    {
        return false;
    }
    B64.decode(s).is_ok_and(|d| d.len() == 256)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn envelope_json(extra: &str) -> String {
        let iv = B64.encode([1u8; 12]);
        let c = B64.encode([2u8; 48]);
        let k = B64.encode([3u8; 256]);
        format!("{{\"v\":1,\"iv\":\"{iv}\",\"c\":\"{c}\",\"k\":\"{k}\"{extra}}}")
    }

    #[test]
    fn classifies_the_four_live_shapes() {
        assert_eq!(classify(&envelope_json("")), VibeEnvelopeFormat::HybridV1);
        assert_eq!(
            classify(r#"{"text":"hello group"}"#),
            VibeEnvelopeFormat::PlaintextPayloadJson
        );
        assert_eq!(
            classify(&B64.encode([9u8; 256])),
            VibeEnvelopeFormat::LegacyRsaDirect
        );
        let arte = format!(
            "arte1.{}.{}.{}",
            B64.encode([1u8; 12]),
            B64.encode([2u8; 40]),
            B64.encode([3u8; 16])
        );
        assert_eq!(classify(&arte), VibeEnvelopeFormat::AgentSealedArte1);
        assert_eq!(classify("just some text"), VibeEnvelopeFormat::Unrecognized);
        assert_eq!(classify(""), VibeEnvelopeFormat::Unrecognized);
    }

    #[test]
    fn plain_text_that_happens_to_be_base64_is_not_an_envelope() {
        // "dGVzdA==" decodes fine but is not 256 bytes.
        assert_eq!(classify("dGVzdA=="), VibeEnvelopeFormat::Unrecognized);
    }

    #[test]
    fn classifies_mls_v2_by_prefix_only() {
        // Detection is a bare prefix check — unlike arte1, there is no shape to
        // validate, so even a body far too short to be a real MLS message
        // still classifies as MlsV2.
        assert_eq!(classify("vmls1.AAAA"), VibeEnvelopeFormat::MlsV2);
        assert_eq!(
            classify("  vmls1.AAAA  "),
            VibeEnvelopeFormat::MlsV2,
            "whitespace is trimmed like every other shape"
        );
        // A prefix collision must never fall into a different arm.
        assert_ne!(classify("vmls1.AAAA"), VibeEnvelopeFormat::Unrecognized);
        assert_ne!(classify("vmls1.AAAA"), VibeEnvelopeFormat::AgentSealedArte1);
    }

    #[test]
    fn round_trips_canonically() {
        let parsed = parse_hybrid(&envelope_json("")).unwrap();
        let reparsed = parse_hybrid(&parsed.to_json()).unwrap();
        assert_eq!(parsed, reparsed);
        assert_eq!(parsed.to_json(), reparsed.to_json());
    }

    #[test]
    fn never_serializes_the_group_slot() {
        let g = B64.encode([4u8; 256]);
        let raw = envelope_json(&format!(",\"g\":\"{g}\""));
        let parsed = parse_hybrid(&raw).unwrap();
        assert!(parsed.key_group.is_some(), "g must be parsed when present");
        assert!(
            !parsed.to_json().contains("\"g\""),
            "g must never be written back out"
        );
    }

    #[test]
    fn key_candidate_order_is_direction_dependent() {
        let s = B64.encode([5u8; 256]);
        let g = B64.encode([4u8; 256]);
        let raw = envelope_json(&format!(",\"s\":\"{s}\",\"g\":\"{g}\""));
        let e = parse_hybrid(&raw).unwrap();

        let out = e.key_candidates(VibeEnvelopeDirection::Outgoing);
        assert_eq!(out[0], vec![4u8; 256]); // g first, always
        assert_eq!(out[1], vec![5u8; 256]); // then s
        assert_eq!(out[2], vec![3u8; 256]); // then k

        let inc = e.key_candidates(VibeEnvelopeDirection::Incoming);
        assert_eq!(inc[0], vec![4u8; 256]);
        assert_eq!(inc[1], vec![3u8; 256]); // k before s
        assert_eq!(inc[2], vec![5u8; 256]);
    }

    #[test]
    fn rejects_malformed_shapes_with_field_named_errors() {
        assert_eq!(
            parse_hybrid("").unwrap_err(),
            VibeEnvelopeError::NotAnEnvelope
        );
        assert_eq!(
            parse_hybrid("{not json").unwrap_err(),
            VibeEnvelopeError::NotJson
        );
        assert_eq!(
            parse_hybrid(r#"{"text":"group"}"#).unwrap_err(),
            VibeEnvelopeError::NotAnEnvelope
        );

        let iv = B64.encode([1u8; 8]); // wrong length
        let c = B64.encode([2u8; 48]);
        let k = B64.encode([3u8; 256]);
        let raw = format!("{{\"v\":1,\"iv\":\"{iv}\",\"c\":\"{c}\",\"k\":\"{k}\"}}");
        assert_eq!(
            parse_hybrid(&raw).unwrap_err(),
            VibeEnvelopeError::FieldWrongLength {
                field: "iv",
                expected: 12,
                actual: 8
            }
        );

        let raw = format!(
            "{{\"v\":2,\"iv\":\"{}\",\"c\":\"{c}\",\"k\":\"{k}\"}}",
            B64.encode([1u8; 12])
        );
        assert_eq!(
            parse_hybrid(&raw).unwrap_err(),
            VibeEnvelopeError::UnsupportedVersion {
                found: 2,
                supported: 1
            }
        );
    }

    #[test]
    fn version_field_may_be_absent() {
        let iv = B64.encode([1u8; 12]);
        let c = B64.encode([2u8; 48]);
        let k = B64.encode([3u8; 256]);
        let raw = format!("{{\"iv\":\"{iv}\",\"c\":\"{c}\",\"k\":\"{k}\"}}");
        assert_eq!(parse_hybrid(&raw).unwrap().version, 1);
    }

    #[test]
    fn agent_blob_shape_is_validated_not_opened() {
        let arte = format!(
            "arte1.{}.{}.{}",
            B64.encode([1u8; 12]),
            B64.encode([2u8; 40]),
            B64.encode([3u8; 16])
        );
        let shape = parse_agent_sealed(&arte).unwrap();
        assert_eq!(shape.iv_len, 12);
        assert_eq!(shape.ciphertext_len, 40);
        assert_eq!(shape.tag_len, 16);

        // A wrong tag length is a shape failure, not a decrypt attempt.
        let bad = format!(
            "arte1.{}.{}.{}",
            B64.encode([1u8; 12]),
            B64.encode([2u8; 40]),
            B64.encode([3u8; 8])
        );
        assert!(parse_agent_sealed(&bad).is_none());
    }

    #[cfg(feature = "aead-aes-gcm")]
    #[test]
    fn seal_then_open_round_trip() {
        use crate::crypto::VibeAesGcm256Aead;

        let provider = VibeAesGcm256Aead;
        let key = VibeSecretKey::from_bytes([11u8; 32]);
        let payload = br#"{"text":"hello","caption":null}"#;

        let sealed = seal_hybrid(
            &provider,
            &key,
            payload,
            vec![3u8; 256],
            Some(vec![5u8; 256]),
        )
        .unwrap();

        let wire = sealed.to_json();
        assert_eq!(classify(&wire), VibeEnvelopeFormat::HybridV1);

        let parsed = parse_hybrid(&wire).unwrap();
        let opened = parsed.open(&provider, &key).unwrap();
        assert_eq!(opened.as_bytes(), payload);
    }

    #[test]
    fn agent_blob_rejects_empty_ciphertext_and_oversized_input() {
        let empty = format!("arte1.{}..{}", B64.encode([1u8; 12]), B64.encode([3u8; 16]));
        assert!(parse_agent_sealed(&empty).is_none());

        let oversized = format!("arte1.{}", "A".repeat(MAX_ENVELOPE_BYTES));
        assert!(parse_agent_sealed(&oversized).is_none());
    }
}
