//! Length-hiding padding for message plaintext.
//!
//! AES-GCM is length-preserving: ciphertext length equals plaintext length,
//! exactly. Our server never sees the plaintext, but it sees every
//! ciphertext's byte count, and that alone is a side channel — "ok" is
//! trivially distinguishable from a three-paragraph reply without decrypting
//! anything, and message-length sequences are a well-studied fingerprinting
//! signal. This module removes the fine-grained signal by rounding every
//! plaintext up to a fixed bucket before it is sealed, so the server sees one
//! of a handful of sizes instead of the exact one.
//!
//! # Wire format
//!
//! ```text
//! padded = original_len:u32 LE || plaintext || zero_padding
//! ```
//!
//! `original_len` is the plaintext's true byte count, so [`vibe_unpad`] can
//! recover it exactly regardless of which bucket the frame landed in. The
//! trailing padding bytes are always zero; [`vibe_unpad`] never inspects their
//! value, only their count.
//!
//! # Bucket selection
//!
//! The output length is the smallest entry of [`VIBE_PAD_BUCKETS`] that is
//! `>= 4 + plaintext.len()`. Above the largest bucket, the output rounds up to
//! the next whole multiple of that bucket instead of growing the table
//! forever — an arbitrarily large payload still only leaks its length to the
//! nearest 64 KiB. `vibe_pad(&[])` still costs a full 256-byte bucket: an
//! empty message must not be identifiable by being the one message shorter
//! than everything else.
//!
//! # Threat model for `vibe_unpad`
//!
//! In this crate's own pipeline, padding is applied to plaintext *before*
//! sealing and stripped *after* opening, so by the time [`vibe_unpad`] runs
//! the AEAD tag has already authenticated the bytes. This function is written
//! as though that were not true, because a caller elsewhere in the pipeline
//! may not have that guarantee, and the check is cheap: the 4-byte length
//! prefix is treated as hostile input from a potentially malicious server. It
//! never trusts the declared length until that length has been checked
//! against the real buffer size, never panics, and never indexes out of
//! bounds.

/// Output-length buckets a padded frame rounds up to. Above the largest entry,
/// [`vibe_pad`] rounds up to the next whole multiple of it instead — see the
/// module docs.
pub const VIBE_PAD_BUCKETS: [usize; 5] = [256, 1024, 4096, 16384, 65536];

/// The largest declared bucket, and the step used above it.
const LARGEST_BUCKET: usize = VIBE_PAD_BUCKETS[VIBE_PAD_BUCKETS.len() - 1];

/// Failure to recover a plaintext from a [`vibe_pad`]-produced buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VibePaddingError {
    /// Fewer than 4 bytes: no length prefix could even be read.
    Truncated,
    /// The declared length claims more plaintext than the buffer has room for.
    DeclaredLengthTooLarge { declared: usize, actual: usize },
}

impl std::fmt::Display for VibePaddingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Truncated => f.write_str("padded buffer shorter than the 4-byte length prefix"),
            Self::DeclaredLengthTooLarge { declared, actual } => write!(
                f,
                "declared plaintext length {declared} does not fit in a {actual}-byte buffer"
            ),
        }
    }
}

impl std::error::Error for VibePaddingError {}

/// Smallest output length that can hold `needed` bytes (4-byte length prefix
/// plus plaintext): the smallest [`VIBE_PAD_BUCKETS`] entry `>= needed`, or —
/// above the largest bucket — the next whole multiple of it.
fn target_len(needed: usize) -> usize {
    match VIBE_PAD_BUCKETS
        .into_iter()
        .find(|&bucket| bucket >= needed)
    {
        Some(bucket) => bucket,
        None => needed.div_ceil(LARGEST_BUCKET) * LARGEST_BUCKET,
    }
}

/// Pads `plaintext` into a bucketed frame. See the module docs for the wire
/// format and the bucketing rule. Infallible: every input length has a
/// well-defined output length.
pub fn vibe_pad(plaintext: &[u8]) -> Vec<u8> {
    let needed = 4 + plaintext.len();
    let total = target_len(needed);
    let mut out = Vec::with_capacity(total);
    // `plaintext.len()` overflowing `u32` would mean a >4 GiB message, which
    // cannot exist as an in-memory `&[u8]` on any platform this crate targets;
    // the actual ceiling on a real payload is `envelope::MAX_ENVELOPE_BYTES`,
    // enforced above this layer, many orders of magnitude smaller.
    out.extend_from_slice(&(plaintext.len() as u32).to_le_bytes());
    out.extend_from_slice(plaintext);
    out.resize(total, 0);
    out
}

/// Recovers the original plaintext from a [`vibe_pad`] frame.
///
/// Fails closed: never panics, never indexes out of bounds, and never trusts
/// the declared length before it has been checked against `padded.len()`. See
/// the module docs — the length prefix is treated as hostile input.
pub fn vibe_unpad(padded: &[u8]) -> Result<Vec<u8>, VibePaddingError> {
    if padded.len() < 4 {
        return Err(VibePaddingError::Truncated);
    }
    let mut len_bytes = [0u8; 4];
    len_bytes.copy_from_slice(&padded[..4]);
    let declared = u32::from_le_bytes(len_bytes) as usize;

    // `checked_add` first: on a 32-bit target a hostile `declared` near
    // `u32::MAX` can overflow `usize` on its own, before it is ever compared
    // against `padded.len()`.
    let end = match 4usize.checked_add(declared) {
        Some(end) if end <= padded.len() => end,
        _ => {
            return Err(VibePaddingError::DeclaredLengthTooLarge {
                declared,
                actual: padded.len(),
            })
        }
    };
    Ok(padded[4..end].to_vec())
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    #[test]
    fn round_trips_at_and_around_bucket_boundaries() {
        for len in [0usize, 1, 255, 256, 1000, 70_000] {
            let plaintext = vec![0xABu8; len];
            let padded = vibe_pad(&plaintext);
            assert_eq!(
                vibe_unpad(&padded).unwrap(),
                plaintext,
                "round trip failed for plaintext len {len}"
            );
        }
    }

    #[test]
    fn empty_plaintext_still_fills_the_first_bucket() {
        // An empty message must not be identifiable by its length alone.
        assert_eq!(vibe_pad(&[]).len(), 256);
    }

    #[test]
    fn output_length_is_always_a_bucket_or_a_multiple_of_the_largest() {
        for len in (0..200_000usize).step_by(997) {
            let padded_len = vibe_pad(&vec![0u8; len]).len();
            let is_declared_bucket = VIBE_PAD_BUCKETS.contains(&padded_len);
            let is_multiple_of_largest = padded_len % LARGEST_BUCKET == 0;
            assert!(
                is_declared_bucket || is_multiple_of_largest,
                "padded length {padded_len} (from plaintext len {len}) is neither a bucket \
                 nor a whole multiple of {LARGEST_BUCKET}"
            );
        }
    }

    #[test]
    fn truncated_input_below_four_bytes_is_rejected() {
        for len in 0..4 {
            assert_eq!(
                vibe_unpad(&vec![0u8; len]).unwrap_err(),
                VibePaddingError::Truncated,
                "buffer of {len} bytes must be Truncated"
            );
        }
    }

    #[test]
    fn hostile_declared_length_is_rejected_without_panicking() {
        // A malicious server could set the length prefix to u32::MAX behind a
        // buffer that is nowhere near that long.
        let mut buf = u32::MAX.to_le_bytes().to_vec();
        buf.extend_from_slice(&[0u8; 16]);
        assert_eq!(
            vibe_unpad(&buf).unwrap_err(),
            VibePaddingError::DeclaredLengthTooLarge {
                declared: u32::MAX as usize,
                actual: buf.len(),
            }
        );
    }

    #[test]
    fn declared_length_is_checked_at_the_exact_boundary() {
        let plaintext = vec![7u8; 10];

        // declared length exactly matches what follows: must succeed.
        let mut exact = 10u32.to_le_bytes().to_vec();
        exact.extend_from_slice(&plaintext);
        assert_eq!(vibe_unpad(&exact).unwrap(), plaintext);

        // declared length one byte past what is available: must fail closed,
        // never read past the end of the buffer.
        let mut over = 11u32.to_le_bytes().to_vec();
        over.extend_from_slice(&plaintext);
        assert_eq!(
            vibe_unpad(&over).unwrap_err(),
            VibePaddingError::DeclaredLengthTooLarge {
                declared: 11,
                actual: over.len(),
            }
        );
    }

    proptest! {
        /// `vibe_unpad(vibe_pad(x)) == x` for any byte string, across every
        /// bucket the sampled lengths touch.
        #[test]
        fn round_trip_arbitrary_bytes(bytes in prop::collection::vec(any::<u8>(), 0..20_000)) {
            let padded = vibe_pad(&bytes);
            let recovered = vibe_unpad(&padded).unwrap();
            prop_assert_eq!(recovered, bytes);
        }

        /// However short, however the first four bytes lie about the length
        /// that follows, `vibe_unpad` must return — never panic, never index
        /// out of bounds.
        #[test]
        fn unpad_never_panics_on_arbitrary_bytes(bytes in prop::collection::vec(any::<u8>(), 0..64)) {
            let _ = vibe_unpad(&bytes);
        }
    }
}
