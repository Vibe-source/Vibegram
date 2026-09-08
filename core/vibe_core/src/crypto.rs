//! AEAD boundary.
//!
//! **No cryptographic primitive is implemented in this crate.** The only
//! algorithm implementation is [`aes_gcm`], the RustCrypto AES-256-GCM crate,
//! reached through the [`VibeAeadProvider`] trait so that:
//!
//! * a build without the `aead-aes-gcm` feature has *no* algorithm at all and
//!   fails closed through [`VibeDenyAllAead`];
//! * a platform that must use its own certified implementation (CryptoKit,
//!   Android Keystore, WebCrypto) can supply one without touching this crate.
//!
//! What stays outside this crate, permanently:
//!
//! * **RSA and all private-key custody.** The RSA-2048 private key lives in the
//!   iOS Keychain / Android Keystore / a non-extractable WebCrypto key and must
//!   never cross an FFI boundary in any form. [`VibeKeyUnwrapper`] is how the
//!   platform hands back an unwrapped content key, one batch at a time.
//! * **Agent pairing keys.** `arte1` blobs stay [`crate::secret::VibeOpaqueBlob`].
//!
//! Properties this module is responsible for, each covered by a test:
//!
//! | Property | Where |
//! |---|---|
//! | typed key/nonce sizes | [`crate::secret`] |
//! | unique random nonces for sealing | [`crate::secret::VibeNonce::random`] |
//! | associated-data binding | [`VibeAeadProvider::seal`] takes `aad` and it is not optional |
//! | zeroizing secret containers | [`crate::secret::VibeSecretKey`], [`crate::secret::VibePlaintext`] |
//! | authenticated, detail-free failure | [`crate::error::VibeCryptoError::AuthenticationFailed`] |
//! | deny-by-default | [`VibeDenyAllAead`] |

use crate::error::VibeCryptoError;
#[cfg(feature = "aead-aes-gcm")]
use crate::secret::VIBE_TAG_LEN;
use crate::secret::{VibeNonce, VibePlaintext, VibeSecretKey};

/// Largest buffer this crate will seal or open in one call (64 MiB).
///
/// Whole-file media is *not* opened through this path — see [`crate::media`] for
/// why the current media format cannot be streamed and what the bounded-memory
/// path is instead.
pub const MAX_AEAD_INPUT: usize = 64 * 1024 * 1024;

/// Authenticated encryption with associated data.
///
/// `aad` is mandatory rather than `Option`, because every call site in this
/// crate has a binding it should be committing to (chat id, message id, envelope
/// version). Passing `&[]` is possible but has to be written down.
pub trait VibeAeadProvider: Send + Sync {
    /// Returns `ciphertext || tag`.
    fn seal(
        &self,
        key: &VibeSecretKey,
        nonce: &VibeNonce,
        aad: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, VibeCryptoError>;

    /// Takes `ciphertext || tag`. Fails closed and without detail.
    fn open(
        &self,
        key: &VibeSecretKey,
        nonce: &VibeNonce,
        aad: &[u8],
        ciphertext_and_tag: &[u8],
    ) -> Result<VibePlaintext, VibeCryptoError>;

    /// Stable label for telemetry. Never a key, never a mode detail that would
    /// help an attacker.
    fn label(&self) -> &'static str;
}

/// The default provider: refuses everything.
///
/// Installed whenever the host has not explicitly chosen an implementation, and
/// the only provider that exists in a `--no-default-features` build. Every
/// message it touches renders with
/// [`crate::types::VibeMessageFlags::DECRYPTION_FAILED`] rather than as
/// plaintext-looking garbage.
#[derive(Clone, Copy, Debug, Default)]
pub struct VibeDenyAllAead;

impl VibeAeadProvider for VibeDenyAllAead {
    fn seal(
        &self,
        _key: &VibeSecretKey,
        _nonce: &VibeNonce,
        _aad: &[u8],
        _plaintext: &[u8],
    ) -> Result<Vec<u8>, VibeCryptoError> {
        Err(VibeCryptoError::ProviderUnavailable)
    }

    fn open(
        &self,
        _key: &VibeSecretKey,
        _nonce: &VibeNonce,
        _aad: &[u8],
        _ciphertext_and_tag: &[u8],
    ) -> Result<VibePlaintext, VibeCryptoError> {
        Err(VibeCryptoError::ProviderUnavailable)
    }

    fn label(&self) -> &'static str {
        "deny-all"
    }
}

/// AES-256-GCM over the RustCrypto [`aes_gcm`] crate.
///
/// Chosen because it is the same construction the shipped clients already use
/// (`AES-256-GCM`, 12-byte IV, 16-byte tag appended), so adopting it is a
/// compatibility requirement rather than a new cryptographic decision.
#[cfg(feature = "aead-aes-gcm")]
#[derive(Clone, Copy, Debug, Default)]
pub struct VibeAesGcm256Aead;

#[cfg(feature = "aead-aes-gcm")]
impl VibeAeadProvider for VibeAesGcm256Aead {
    fn seal(
        &self,
        key: &VibeSecretKey,
        nonce: &VibeNonce,
        aad: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, VibeCryptoError> {
        use aes_gcm::aead::{Aead, KeyInit, Payload};
        use aes_gcm::{Aes256Gcm, Key, Nonce};

        if plaintext.len() > MAX_AEAD_INPUT {
            return Err(VibeCryptoError::InputTooLarge {
                limit: MAX_AEAD_INPUT,
                actual: plaintext.len(),
            });
        }

        let gcm_key = Key::<Aes256Gcm>::from_slice(key.expose());
        let cipher = Aes256Gcm::new(gcm_key);
        let gcm_nonce = Nonce::from_slice(nonce.as_bytes());
        cipher
            .encrypt(
                gcm_nonce,
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .map_err(|_| VibeCryptoError::AuthenticationFailed)
    }

    fn open(
        &self,
        key: &VibeSecretKey,
        nonce: &VibeNonce,
        aad: &[u8],
        ciphertext_and_tag: &[u8],
    ) -> Result<VibePlaintext, VibeCryptoError> {
        use aes_gcm::aead::{Aead, KeyInit, Payload};
        use aes_gcm::{Aes256Gcm, Key, Nonce};

        if ciphertext_and_tag.len() < VIBE_TAG_LEN {
            return Err(VibeCryptoError::CiphertextTooShort {
                minimum: VIBE_TAG_LEN,
                actual: ciphertext_and_tag.len(),
            });
        }
        if ciphertext_and_tag.len() > MAX_AEAD_INPUT {
            return Err(VibeCryptoError::InputTooLarge {
                limit: MAX_AEAD_INPUT,
                actual: ciphertext_and_tag.len(),
            });
        }

        let gcm_key = Key::<Aes256Gcm>::from_slice(key.expose());
        let cipher = Aes256Gcm::new(gcm_key);
        let gcm_nonce = Nonce::from_slice(nonce.as_bytes());
        cipher
            .decrypt(
                gcm_nonce,
                Payload {
                    msg: ciphertext_and_tag,
                    aad,
                },
            )
            .map(VibePlaintext::new)
            // The crate's own error is already opaque; collapsing it here makes
            // that explicit and keeps "wrong key" indistinguishable from
            // "tampered" and "truncated tag".
            .map_err(|_| VibeCryptoError::AuthenticationFailed)
    }

    fn label(&self) -> &'static str {
        "aes-256-gcm"
    }
}

/// A wrapped content key the platform is asked to unwrap.
///
/// `candidates` are RSA-OAEP-SHA256 blobs in the **direction-dependent order the
/// shipped client uses**: the reserved group slot first, then
/// sender-slot-before-recipient-slot for own messages and the reverse for peer
/// messages. Reproducing that order matters: getting it wrong changes which
/// historical messages open.
pub struct VibeWrappedKeyRequest {
    pub message_id: String,
    pub candidates: Vec<Vec<u8>>,
}

impl std::fmt::Debug for VibeWrappedKeyRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeWrappedKeyRequest")
            .field("message_id", &self.message_id)
            .field("candidates", &self.candidates.len())
            .finish()
    }
}

/// The private-key seam. Implemented by the platform, **never** by this crate.
///
/// One call per ingest batch, never per message: a 100-row history page is 100
/// RSA private-key operations, and they must happen once, off the main thread,
/// and never again for the same rows.
pub trait VibeKeyUnwrapper: Send + Sync {
    /// Returns, per request and in order, the first candidate that opened, or
    /// `None`. Implementations must not report *which* candidate opened.
    fn unwrap_aes_keys(&self, requests: &[VibeWrappedKeyRequest]) -> Vec<Option<VibeSecretKey>>;
}

/// The default unwrapper: no key ever opens.
///
/// Messages fall back to [`crate::types::VibeMessageFlags::DECRYPTION_FAILED`],
/// which is the same behaviour the shipped client has when the Keychain is
/// locked.
#[derive(Clone, Copy, Debug, Default)]
pub struct VibeDenyAllKeyUnwrapper;

impl VibeKeyUnwrapper for VibeDenyAllKeyUnwrapper {
    fn unwrap_aes_keys(&self, requests: &[VibeWrappedKeyRequest]) -> Vec<Option<VibeSecretKey>> {
        requests.iter().map(|_| None).collect()
    }
}

/// The provider this build installs when the host does not choose.
///
/// With `aead-aes-gcm` on, AES-256-GCM. With it off, deny-all.
pub fn default_aead_provider() -> std::sync::Arc<dyn VibeAeadProvider> {
    #[cfg(feature = "aead-aes-gcm")]
    {
        std::sync::Arc::new(VibeAesGcm256Aead)
    }
    #[cfg(not(feature = "aead-aes-gcm"))]
    {
        std::sync::Arc::new(VibeDenyAllAead)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> VibeSecretKey {
        VibeSecretKey::from_bytes([7u8; 32])
    }

    /// `Result::unwrap_err` needs `T: Debug`, and `VibePlaintext` deliberately
    /// has none. That constraint is the feature, so tests unwrap by hand.
    // Ownership is required to move the error out; clippy cannot see that
    // through the panicking arm.
    #[allow(clippy::needless_pass_by_value)]
    fn err_of<T>(result: Result<T, VibeCryptoError>) -> VibeCryptoError {
        match result {
            Ok(_) => panic!("expected an error"),
            Err(e) => e,
        }
    }

    #[test]
    fn deny_all_fails_closed_in_both_directions() {
        let p = VibeDenyAllAead;
        let n = VibeNonce::from_bytes([0u8; 12]);
        assert_eq!(
            err_of(p.seal(&key(), &n, b"aad", b"hi")),
            VibeCryptoError::ProviderUnavailable
        );
        assert_eq!(
            err_of(p.open(&key(), &n, b"aad", &[0u8; 32])),
            VibeCryptoError::ProviderUnavailable
        );
    }

    #[test]
    fn deny_all_unwrapper_returns_none_per_request() {
        let u = VibeDenyAllKeyUnwrapper;
        let out = u.unwrap_aes_keys(&[
            VibeWrappedKeyRequest {
                message_id: "a".into(),
                candidates: vec![vec![1, 2, 3]],
            },
            VibeWrappedKeyRequest {
                message_id: "b".into(),
                candidates: vec![],
            },
        ]);
        assert_eq!(out.len(), 2);
        assert!(out.iter().all(Option::is_none));
    }

    #[cfg(feature = "aead-aes-gcm")]
    mod aes {
        use super::*;

        #[test]
        fn round_trip_with_aad() {
            let p = VibeAesGcm256Aead;
            let n = VibeNonce::from_bytes([1u8; 12]);
            let sealed = p.seal(&key(), &n, b"chat|msg", b"hello world").unwrap();
            assert_eq!(sealed.len(), b"hello world".len() + VIBE_TAG_LEN);
            let opened = p.open(&key(), &n, b"chat|msg", &sealed).unwrap();
            assert_eq!(opened.as_bytes(), b"hello world");
        }

        #[test]
        fn wrong_aad_is_rejected() {
            let p = VibeAesGcm256Aead;
            let n = VibeNonce::from_bytes([1u8; 12]);
            let sealed = p.seal(&key(), &n, b"chat-a|msg-1", b"hello").unwrap();
            let err = err_of(p.open(&key(), &n, b"chat-b|msg-1", &sealed));
            assert_eq!(err, VibeCryptoError::AuthenticationFailed);
        }

        #[test]
        fn wrong_key_and_tampered_tag_are_indistinguishable() {
            let p = VibeAesGcm256Aead;
            let n = VibeNonce::from_bytes([1u8; 12]);
            let sealed = p.seal(&key(), &n, b"aad", b"hello").unwrap();

            let other = VibeSecretKey::from_bytes([9u8; 32]);
            let wrong_key = err_of(p.open(&other, &n, b"aad", &sealed));

            let mut tampered = sealed.clone();
            let last = tampered.len() - 1;
            tampered[last] ^= 0x01;
            let bad_tag = err_of(p.open(&key(), &n, b"aad", &tampered));

            assert_eq!(wrong_key, bad_tag);
            assert_eq!(wrong_key, VibeCryptoError::AuthenticationFailed);
        }

        #[test]
        fn truncated_ciphertext_is_length_checked_not_decrypted() {
            let p = VibeAesGcm256Aead;
            let n = VibeNonce::from_bytes([1u8; 12]);
            let err = err_of(p.open(&key(), &n, b"aad", &[0u8; 4]));
            assert_eq!(
                err,
                VibeCryptoError::CiphertextTooShort {
                    minimum: 16,
                    actual: 4
                }
            );
        }

        #[test]
        fn nonces_are_unique_across_draws() {
            let mut seen = std::collections::HashSet::new();
            for _ in 0..512 {
                let n = VibeNonce::random().unwrap();
                assert!(seen.insert(*n.as_bytes()), "nonce repeated");
            }
        }

        #[test]
        fn error_display_never_carries_plaintext_or_key() {
            let p = VibeAesGcm256Aead;
            let n = VibeNonce::from_bytes([1u8; 12]);
            let sealed = p.seal(&key(), &n, b"aad", b"topsecret").unwrap();
            let err = err_of(p.open(&VibeSecretKey::from_bytes([3u8; 32]), &n, b"aad", &sealed));
            let rendered = format!("{err} {err:?}");
            assert!(!rendered.contains("topsecret"));
            assert!(!rendered.to_lowercase().contains("key material"));
        }
    }
}
