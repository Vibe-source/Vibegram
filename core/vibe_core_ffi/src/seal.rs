//! FFI surface for at-rest store sealing.
//!
//! # Who holds what
//!
//! The platform owns the **key**: it generates 32 bytes with
//! `SecRandomCopyBytes`, keeps them in the Keychain at
//! `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and hands them in once
//! per session. This crate owns the **sealing**, because the algorithm, the AAD
//! construction, and the nonce discipline are exactly the things that must not
//! be reimplemented once per platform.
//!
//! §7.2 of the refactor doc allows either side to do the sealing. Rust does it
//! here for one reason: `vibe_core::store_seal` is already written, already
//! tested against relocation and tampering, and re-deriving it in Swift, Kotlin
//! and TypeScript is how the `client/src/crypto.ts` divergence happened in the
//! first place.
//!
//! **The core never persists the key.** It lives in a `VibeSecretKey` (zeroizing,
//! no `Debug`, no serde) for as long as the handle is alive, and nowhere else.
//!
//! # Honest limit
//!
//! `open` returns plaintext as `Vec<u8>`, which becomes `Data` in Swift. Swift
//! has no zeroizing buffer and UIKit caches text, so this boundary cannot
//! promise plaintext is scrubbed from process memory — only that the *key* is.
//! Non-claim 10.2.3 says this already; do not let anyone read this module as a
//! stronger guarantee than that.

use std::sync::Arc;

use vibe_core::crypto::default_aead_provider;
use vibe_core::secret::VibeSecretKey;
use vibe_core::store_seal::{VibeStoreSealError, VibeStoreSealer};

use crate::VibeFfiError;

/// Length of the store key, in bytes. AES-256.
pub const VIBE_STORE_KEY_LEN: u32 = 32;

impl From<VibeStoreSealError> for VibeFfiError {
    fn from(value: VibeStoreSealError) -> Self {
        match value {
            // A relocated, tampered or wrong-key row is `Malformed`, not
            // `Internal`: it is a data condition the platform should count and
            // recover from by re-backfilling, not a core invariant violation
            // that should disable the core.
            VibeStoreSealError::Crypto(_) | VibeStoreSealError::Corrupt => Self::Malformed {
                detail: value.to_string(),
            },
            VibeStoreSealError::TooLarge => Self::Malformed {
                detail: "store row too large".to_string(),
            },
        }
    }
}

/// One sealed row body, as it goes into `core_messages_v1`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct VibeFfiSealedBody {
    /// `ciphertext || tag`.
    pub sealed_body: Vec<u8>,
    pub seal_nonce: Vec<u8>,
}

/// Seals and opens rows under a platform-supplied store key.
#[derive(uniffi::Object)]
pub struct VibeStoreSealerHandle {
    inner: VibeStoreSealer,
}

#[uniffi::export]
impl VibeStoreSealerHandle {
    /// Takes the store key for this session.
    ///
    /// Rejects a wrong-length key rather than padding or truncating it. Silently
    /// accepting a short key would produce a store that seals under something
    /// weaker than advertised, and nothing downstream would ever notice.
    #[uniffi::constructor]
    pub fn new(store_key: Vec<u8>) -> Result<Arc<Self>, VibeFfiError> {
        let key = VibeSecretKey::from_slice(&store_key).map_err(|_| VibeFfiError::Malformed {
            detail: format!("store key must be {VIBE_STORE_KEY_LEN} bytes"),
        })?;
        // `store_key` is dropped here. It came from Swift as a `Data`, so this
        // crate cannot guarantee that buffer is scrubbed — only that our own
        // copy now lives in a zeroizing `VibeSecretKey`.
        Ok(Arc::new(Self {
            inner: VibeStoreSealer::new(key, default_aead_provider()),
        }))
    }

    /// Seals one normalized row for the address it will be stored at.
    ///
    /// The address is not decoration: it is bound into the AAD, so the row can
    /// only ever be opened from the same `(user, chat, message)` slot.
    pub fn seal(
        &self,
        user_id: String,
        chat_id: String,
        message_id: String,
        plaintext: Vec<u8>,
    ) -> Result<VibeFfiSealedBody, VibeFfiError> {
        let sealed = self
            .inner
            .seal(&user_id, &chat_id, &message_id, &plaintext)?;
        Ok(VibeFfiSealedBody {
            sealed_body: sealed.sealed_body,
            seal_nonce: sealed.seal_nonce,
        })
    }

    /// Opens a row read from a given address.
    ///
    /// Pass the primary key the row was actually read under. If it does not
    /// match what was sealed, this fails — that is the point.
    pub fn open(
        &self,
        user_id: String,
        chat_id: String,
        message_id: String,
        sealed_body: Vec<u8>,
        seal_nonce: Vec<u8>,
    ) -> Result<Vec<u8>, VibeFfiError> {
        let plaintext =
            self.inner
                .open(&user_id, &chat_id, &message_id, &sealed_body, &seal_nonce)?;
        Ok(plaintext.as_bytes().to_vec())
    }
}

/// Lets the store's backfill loop seal rows without knowing how sealing works.
///
/// `None` means "skip this row", and a sealing failure maps to exactly that: a
/// row that cannot be sealed must never be persisted in the clear, and must not
/// abort the batch either — backfill walks thousands of legacy rows and one bad
/// payload is a data condition, not a reason to stop migrating the chat.
impl vibe_core_store::VibeRowSealer for VibeStoreSealerHandle {
    fn seal(
        &self,
        user_id: &str,
        chat_id: &str,
        message_id: &str,
        payload: &[u8],
    ) -> Option<(Vec<u8>, Vec<u8>)> {
        let sealed = self.inner.seal(user_id, chat_id, message_id, payload).ok()?;
        Some((sealed.sealed_body, sealed.seal_nonce))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> Vec<u8> {
        vec![0x5A; 32]
    }

    #[test]
    fn a_wrong_length_key_is_refused() {
        for bad in [vec![], vec![0u8; 16], vec![0u8; 31], vec![0u8; 33]] {
            assert!(VibeStoreSealerHandle::new(bad).is_err());
        }
        assert!(VibeStoreSealerHandle::new(key()).is_ok());
    }

    #[test]
    fn a_row_round_trips_across_the_boundary() {
        let h = VibeStoreSealerHandle::new(key()).unwrap();
        let sealed = h
            .seal(
                "u1".into(),
                "c1".into(),
                "m1".into(),
                b"normalized row".to_vec(),
            )
            .unwrap();
        let opened = h
            .open(
                "u1".into(),
                "c1".into(),
                "m1".into(),
                sealed.sealed_body,
                sealed.seal_nonce,
            )
            .unwrap();
        assert_eq!(opened, b"normalized row");
    }

    #[test]
    fn relocation_still_fails_through_the_ffi() {
        // The property is enforced in `vibe_core`; this proves the FFI does not
        // accidentally drop the address on the way through.
        let h = VibeStoreSealerHandle::new(key()).unwrap();
        let sealed = h
            .seal("u1".into(), "c1".into(), "m1".into(), b"secret".to_vec())
            .unwrap();
        assert!(h
            .open(
                "u1".into(),
                "c1".into(),
                "m2".into(),
                sealed.sealed_body,
                sealed.seal_nonce
            )
            .is_err());
    }
}
