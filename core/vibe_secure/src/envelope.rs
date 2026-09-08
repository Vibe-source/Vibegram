//! The wire string that rides `encrypted_content` for MLS-sealed messages.
//!
//! ```text
//! vmls1.<base64-standard of the TLS-serialized MLS message>
//! ```
//!
//! Prefix-detected, exactly like `vgrp2.` (`vibe_core::group`) and `arte1.`
//! elsewhere in this workspace: a deployed client that meets an unrecognised
//! prefix renders it as literal text — visibly wrong, obviously "update your
//! app" — rather than guessing. `vibe_core::envelope` detects this same
//! prefix as `VibeEnvelopeFormat::MlsV2`; that module only recognises the
//! shape, this one owns it.
//!
//! This module is a pure byte↔string codec. It knows nothing about what the
//! bytes mean — [`crate::session`] is the only caller, and it is the one that
//! knows they are a TLS-serialized `MlsMessageOut`/`MlsMessageIn`.

use base64::engine::general_purpose::STANDARD as B64;
use base64::{decoded_len_estimate, Engine as _};

use crate::error::VibeSecureError;

/// Prefix of the MLS envelope. Recognised by prefix, like `vgrp2.` and `arte1.`.
pub const VIBE_MLS_SEALED_PREFIX: &str = "vmls1.";

/// Largest MLS ciphertext this module will buffer, in bytes, on either side
/// of the codec.
///
/// On decode this is checked against [`decoded_len_estimate`] of the
/// *encoded* body — an O(1) arithmetic bound, no allocation — before
/// `base64` ever allocates a decode buffer. A hostile peer cannot make a
/// client allocate without bound just by declaring a long string.
pub const VIBE_MLS_MAX_CIPHERTEXT: usize = 1 << 20;

/// Wraps a TLS-serialized MLS message as the `vmls1.` envelope string.
pub(crate) fn wrap(message_bytes: &[u8]) -> Result<String, VibeSecureError> {
    if message_bytes.len() > VIBE_MLS_MAX_CIPHERTEXT {
        return Err(VibeSecureError::CiphertextTooLarge {
            limit: VIBE_MLS_MAX_CIPHERTEXT,
            actual: message_bytes.len(),
        });
    }
    Ok(format!(
        "{VIBE_MLS_SEALED_PREFIX}{}",
        B64.encode(message_bytes)
    ))
}

/// Unwraps a `vmls1.` envelope string back to the TLS-serialized message
/// bytes it carries.
///
/// Total over arbitrary input: every malformed shape returns an error, and
/// none of them panic. The prefix is required — a bare base64 string, with no
/// `vmls1.` in front, is [`VibeSecureError::MalformedEnvelope`], not "assume
/// the sealed format and try anyway".
pub(crate) fn unwrap(envelope: &str) -> Result<Vec<u8>, VibeSecureError> {
    let body = envelope
        .strip_prefix(VIBE_MLS_SEALED_PREFIX)
        .ok_or(VibeSecureError::MalformedEnvelope)?;

    // Reject on the encoded length before any decode buffer is allocated.
    let estimate = decoded_len_estimate(body.len());
    if estimate > VIBE_MLS_MAX_CIPHERTEXT {
        return Err(VibeSecureError::CiphertextTooLarge {
            limit: VIBE_MLS_MAX_CIPHERTEXT,
            actual: estimate,
        });
    }

    B64.decode(body)
        .map_err(|_| VibeSecureError::MalformedEnvelope)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_arbitrary_bytes() {
        let original = b"hello mls".to_vec();
        let wrapped = wrap(&original).expect("wraps");
        assert!(wrapped.starts_with(VIBE_MLS_SEALED_PREFIX));
        let unwrapped = unwrap(&wrapped).expect("unwraps");
        assert_eq!(unwrapped, original);
    }

    #[test]
    fn a_bare_base64_string_without_the_prefix_is_malformed() {
        let bare = B64.encode(b"no prefix here");
        assert_eq!(unwrap(&bare), Err(VibeSecureError::MalformedEnvelope));
    }

    #[test]
    fn oversized_input_is_rejected_before_decoding() {
        let huge = "A".repeat(VIBE_MLS_MAX_CIPHERTEXT * 2);
        let envelope = format!("{VIBE_MLS_SEALED_PREFIX}{huge}");
        assert!(matches!(
            unwrap(&envelope),
            Err(VibeSecureError::CiphertextTooLarge { .. })
        ));
    }

    #[test]
    fn malformed_input_never_panics() {
        for raw in [
            "",
            "vmls1.",
            "vmls1.###",
            "plain text",
            "arte1.abc",
            "vgrp2.a.b.c",
        ] {
            let _ = unwrap(raw);
        }
    }
}
