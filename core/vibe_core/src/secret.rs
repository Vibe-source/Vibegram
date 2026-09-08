//! Secret and plaintext containers.
//!
//! Rules enforced here, and asserted by `tests/no_leakage.rs`:
//!
//! * key material and decrypted bytes never implement [`std::fmt::Debug`];
//! * they never implement `serde::Serialize`/`Deserialize`;
//! * they zeroize on drop;
//! * they are never rendered into an error, a log line, or a panic message.
//!
//! Honest limit: this is only true *inside this crate*. Once a body crosses into
//! Swift/Kotlin/JS it becomes a platform `String` and this crate makes no claim
//! about its lifetime there. See `docs/production-timeline-core-refactor.md`
//! § "Non-claims".

use zeroize::{Zeroize, ZeroizeOnDrop};

/// Byte length of every symmetric key this crate accepts. Typed so a 16-byte or
/// 64-byte key is a compile-time impossibility rather than a runtime check.
pub const VIBE_KEY_LEN: usize = 32;

/// Byte length of every AEAD nonce this crate accepts.
pub const VIBE_NONCE_LEN: usize = 12;

/// Byte length of the AES-GCM authentication tag.
pub const VIBE_TAG_LEN: usize = 16;

/// A 32-byte symmetric key.
///
/// Deliberately has no `Debug`, no `Display`, no `Clone`, and no serde impls.
/// Construct it from bytes, use it, drop it.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct VibeSecretKey {
    bytes: [u8; VIBE_KEY_LEN],
}

impl VibeSecretKey {
    /// Wraps an exact-size key.
    pub fn from_bytes(bytes: [u8; VIBE_KEY_LEN]) -> Self {
        Self { bytes }
    }

    /// Wraps a slice, rejecting any length other than [`VIBE_KEY_LEN`].
    ///
    /// The error carries the *expected* and *actual* length only — never the
    /// bytes.
    pub fn from_slice(slice: &[u8]) -> Result<Self, VibeSecretLenError> {
        if slice.len() != VIBE_KEY_LEN {
            return Err(VibeSecretLenError {
                expected: VIBE_KEY_LEN,
                actual: slice.len(),
            });
        }
        let mut bytes = [0u8; VIBE_KEY_LEN];
        bytes.copy_from_slice(slice);
        Ok(Self { bytes })
    }

    /// Crate-internal access for the AEAD provider. Unused — and therefore
    /// genuinely dead — in a build with no algorithm compiled in, which is the
    /// point of the deny-by-default configuration.
    #[cfg_attr(not(feature = "aead-aes-gcm"), allow(dead_code))]
    pub(crate) fn expose(&self) -> &[u8; VIBE_KEY_LEN] {
        &self.bytes
    }
}

/// A 96-bit AEAD nonce.
///
/// Nonces are public values, so this type *is* `Debug`/`Clone`. Uniqueness per
/// key is the caller's obligation at the low-level provider boundary;
/// [`VibeNonce::random`] is the only construction the high-level codecs use for
/// sealing, and the 96-bit random-nonce
/// birthday bound (~2^32 seals per key) is documented in the production doc.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeNonce {
    bytes: [u8; VIBE_NONCE_LEN],
}

impl VibeNonce {
    pub fn from_bytes(bytes: [u8; VIBE_NONCE_LEN]) -> Self {
        Self { bytes }
    }

    pub fn from_slice(slice: &[u8]) -> Result<Self, VibeSecretLenError> {
        if slice.len() != VIBE_NONCE_LEN {
            return Err(VibeSecretLenError {
                expected: VIBE_NONCE_LEN,
                actual: slice.len(),
            });
        }
        let mut bytes = [0u8; VIBE_NONCE_LEN];
        bytes.copy_from_slice(slice);
        Ok(Self { bytes })
    }

    pub fn as_bytes(&self) -> &[u8; VIBE_NONCE_LEN] {
        &self.bytes
    }

    /// Fresh 96-bit nonce from the operating-system CSPRNG.
    ///
    pub fn random() -> Result<Self, crate::error::VibeCryptoError> {
        let mut bytes = [0u8; VIBE_NONCE_LEN];
        getrandom::fill(&mut bytes)
            .map_err(|_| crate::error::VibeCryptoError::RandomnessUnavailable)?;
        Ok(Self { bytes })
    }
}

/// Decrypted bytes. No `Debug`, no serde, zeroized on drop.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct VibePlaintext {
    bytes: Vec<u8>,
}

impl VibePlaintext {
    pub fn new(bytes: Vec<u8>) -> Self {
        Self { bytes }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }
}

/// Ciphertext that this crate never opens: agent runtime blobs (`arte1`) sealed
/// under a pairing key that only the phone holds.
///
/// Carried through the pipeline and handed back to the platform verbatim. Its
/// `Debug` prints a length and nothing else, so it can appear inside a snapshot
/// that *is* debuggable.
#[derive(Clone, PartialEq, Eq)]
pub struct VibeOpaqueBlob {
    bytes: Vec<u8>,
}

impl VibeOpaqueBlob {
    pub fn new(bytes: Vec<u8>) -> Self {
        Self { bytes }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    /// Opaque change token used only to decide whether the consumer must receive
    /// a replacement. It is never logged or used as a security primitive.
    ///
    /// Re-sealing may produce a conservative extra update. That is preferable to
    /// suppressing a real runtime change merely because two ciphertexts happen
    /// to have the same length.
    pub(crate) fn change_token(&self) -> u64 {
        crate::hash::fnv1a64(&self.bytes)
    }
}

impl std::fmt::Debug for VibeOpaqueBlob {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "VibeOpaqueBlob({} bytes, sealed)", self.bytes.len())
    }
}

/// Length mismatch on a typed secret. Carries lengths, never content.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeSecretLenError {
    pub expected: usize,
    pub actual: usize,
}

impl std::fmt::Display for VibeSecretLenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "expected {} bytes, got {} bytes",
            self.expected, self.actual
        )
    }
}

impl std::error::Error for VibeSecretLenError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_rejects_wrong_length_without_echoing_bytes() {
        // Unwrapping the Ok side is impossible here: `VibeSecretKey` has no
        // `Debug`, which is exactly the property under test.
        let Err(err) = VibeSecretKey::from_slice(&[0xAB; 16]) else {
            panic!("a 16-byte key must be rejected");
        };
        assert_eq!(err.expected, 32);
        assert_eq!(err.actual, 16);
        assert!(!format!("{err}").contains("ab"));
    }

    #[test]
    fn opaque_blob_debug_is_length_only() {
        let blob = VibeOpaqueBlob::new(b"arte1.super-secret".to_vec());
        let rendered = format!("{blob:?}");
        assert!(rendered.contains("18 bytes"));
        assert!(!rendered.contains("secret"));
    }

    #[test]
    fn opaque_change_token_detects_equal_length_changes() {
        let a = VibeOpaqueBlob::new(vec![1, 2, 3, 4]);
        let b = VibeOpaqueBlob::new(vec![9, 9, 9, 9]);
        assert_ne!(a.change_token(), b.change_token());
    }
}
