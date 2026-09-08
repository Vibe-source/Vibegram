//! The private-key seam, across the FFI.
//!
//! # Why this file exists at all
//!
//! Without it the core cannot read a single message. `VibeCoreConfig::unwrapper`
//! defaults to [`vibe_core::VibeDenyAllKeyUnwrapper`], so a handle built without
//! this seam canonicalizes every hybrid envelope to
//! `VibeMessageFlags::DECRYPTION_FAILED` — correct, fail-closed, and useless.
//! This is the piece that lets `vibe_core::canonical` actually open a payload,
//! which is what makes the core the message pipeline rather than a sorter.
//!
//! # What crosses, and what never does
//!
//! The **RSA private key never crosses**. It stays in the Keychain and the
//! platform performs the unwrap. What crosses inbound is a list of *wrapped*
//! key blobs — already public, already on the wire — and what crosses back is a
//! 32-byte content key per message, or nothing.
//!
//! One call per ingest batch, never per message: a 100-row history page is 100
//! RSA private-key operations, and they happen once, off the main thread, and
//! never again for those rows because the durable store keeps the opened form.
//!
//! # Fail-closed, three ways
//!
//! A key seam must never guess. Every degenerate answer from the platform
//! becomes `None`, which renders the shipped decryption-failure state:
//!
//! 1. **A panic or an exception in the foreign callback** — caught, and the
//!    whole batch resolves to `None`. A platform bug must not take down the
//!    worker thread.
//! 2. **A length mismatch** between requests and answers — the whole batch
//!    resolves to `None`. Answers are positional; a short or long vector means
//!    the two sides disagree about which answer belongs to which message, and
//!    pairing a key to the wrong message is worse than opening nothing.
//! 3. **A wrong-length key** — that one entry resolves to `None`. Padding or
//!    truncating to 32 bytes would decrypt under something other than the key
//!    the sender used, and nothing downstream would notice.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use vibe_core::crypto::{VibeKeyUnwrapper, VibeWrappedKeyRequest};
use vibe_core::secret::VibeSecretKey;
use zeroize::Zeroize;

/// One message's wrapped-key candidates, for the platform to try in order.
///
/// `candidates` arrive in the **direction-dependent order the shipped client
/// uses**: the reserved group slot first, then sender-slot-before-recipient for
/// own messages and the reverse for peer messages. The platform must try them in
/// the order given and must not reorder them — getting that wrong changes which
/// historical messages open.
#[derive(Clone, Debug, uniffi::Record)]
pub struct VibeFfiKeyRequest {
    /// Correlation only. The platform must answer positionally, not by this id.
    pub message_id: String,
    /// RSA-OAEP-SHA256 wrapped content keys, in try-order.
    pub candidates: Vec<Vec<u8>>,
}

/// Platform-side private-key custody.
///
/// Implemented in Swift over the Keychain, in Kotlin over the Keystore. Invoked
/// from the core's worker thread with no core state held, once per ingest batch.
///
/// Implementations must return **exactly one slot per request, in order**:
/// `Some(key)` for the first candidate that unwrapped, `None` when none did.
/// They must not report *which* candidate opened — that leaks whether a message
/// was sent or received to anything watching the boundary.
#[uniffi::export(with_foreign)]
pub trait VibeFfiKeyUnwrapper: Send + Sync {
    /// Unwraps one batch. Never called per message.
    fn unwrap_aes_keys(&self, requests: Vec<VibeFfiKeyRequest>) -> Vec<Option<Vec<u8>>>;
}

/// Adapts a foreign unwrapper to the core's trait.
pub(crate) struct VibeForeignKeyUnwrapper {
    inner: Arc<dyn VibeFfiKeyUnwrapper>,
}

impl VibeForeignKeyUnwrapper {
    pub(crate) fn new(inner: Arc<dyn VibeFfiKeyUnwrapper>) -> Self {
        Self { inner }
    }
}

impl std::fmt::Debug for VibeForeignKeyUnwrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("VibeForeignKeyUnwrapper")
    }
}

/// The fail-closed answer for a whole batch.
fn all_closed(len: usize) -> Vec<Option<VibeSecretKey>> {
    (0..len).map(|_| None).collect()
}

impl VibeKeyUnwrapper for VibeForeignKeyUnwrapper {
    fn unwrap_aes_keys(&self, requests: &[VibeWrappedKeyRequest]) -> Vec<Option<VibeSecretKey>> {
        if requests.is_empty() {
            return Vec::new();
        }

        let mirrored: Vec<VibeFfiKeyRequest> = requests
            .iter()
            .map(|r| VibeFfiKeyRequest {
                message_id: r.message_id.clone(),
                candidates: r.candidates.clone(),
            })
            .collect();

        // A foreign implementation is arbitrary platform code. `AssertUnwindSafe`
        // is sound because nothing observable is left half-written by a panic
        // here: the closure owns `mirrored` outright and touches no shared state.
        let Ok(returned) = catch_unwind(AssertUnwindSafe(|| self.inner.unwrap_aes_keys(mirrored)))
        else {
            return all_closed(requests.len());
        };

        // Positional pairing is the entire contract. A disagreement about length
        // means a disagreement about which key belongs to which message.
        if returned.len() != requests.len() {
            return all_closed(requests.len());
        }

        returned
            .into_iter()
            .map(|slot| {
                let mut bytes = slot?;
                // Wrong length is refused, never padded or truncated.
                let key = VibeSecretKey::from_slice(&bytes).ok();
                // The platform handed these over as a plain byte vector. Our copy
                // is scrubbed the moment it has been moved into a zeroizing key;
                // the caller's original buffer is beyond this crate's reach.
                bytes.zeroize();
                key
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FixedUnwrapper {
        answers: Vec<Option<Vec<u8>>>,
    }

    impl VibeFfiKeyUnwrapper for FixedUnwrapper {
        fn unwrap_aes_keys(&self, _requests: Vec<VibeFfiKeyRequest>) -> Vec<Option<Vec<u8>>> {
            self.answers.clone()
        }
    }

    struct PanickingUnwrapper;

    impl VibeFfiKeyUnwrapper for PanickingUnwrapper {
        fn unwrap_aes_keys(&self, _requests: Vec<VibeFfiKeyRequest>) -> Vec<Option<Vec<u8>>> {
            panic!("platform bug");
        }
    }

    fn request(id: &str) -> VibeWrappedKeyRequest {
        VibeWrappedKeyRequest {
            message_id: id.to_string(),
            candidates: vec![vec![1, 2, 3]],
        }
    }

    #[test]
    fn well_formed_key_is_adopted() {
        let unwrapper = VibeForeignKeyUnwrapper::new(Arc::new(FixedUnwrapper {
            answers: vec![Some(vec![7u8; 32])],
        }));
        let out = unwrapper.unwrap_aes_keys(&[request("m1")]);
        assert_eq!(out.len(), 1);
        assert!(out[0].is_some());
    }

    #[test]
    fn wrong_length_key_is_refused_not_padded() {
        let unwrapper = VibeForeignKeyUnwrapper::new(Arc::new(FixedUnwrapper {
            answers: vec![Some(vec![7u8; 16])],
        }));
        let out = unwrapper.unwrap_aes_keys(&[request("m1")]);
        assert!(out[0].is_none());
    }

    #[test]
    fn length_mismatch_fails_the_whole_batch_closed() {
        let unwrapper = VibeForeignKeyUnwrapper::new(Arc::new(FixedUnwrapper {
            answers: vec![Some(vec![7u8; 32])],
        }));
        let out = unwrapper.unwrap_aes_keys(&[request("m1"), request("m2")]);
        assert_eq!(out.len(), 2);
        assert!(out.iter().all(Option::is_none));
    }

    #[test]
    fn panicking_platform_fails_closed_without_unwinding_into_the_worker() {
        let unwrapper = VibeForeignKeyUnwrapper::new(Arc::new(PanickingUnwrapper));
        let out = unwrapper.unwrap_aes_keys(&[request("m1"), request("m2")]);
        assert_eq!(out.len(), 2);
        assert!(out.iter().all(Option::is_none));
    }

    #[test]
    fn empty_batch_never_calls_the_platform() {
        let unwrapper = VibeForeignKeyUnwrapper::new(Arc::new(PanickingUnwrapper));
        assert!(unwrapper.unwrap_aes_keys(&[]).is_empty());
    }
}
