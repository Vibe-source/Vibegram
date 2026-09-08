//! Typed errors.
//!
//! Governing rule, carried over from the Swift engine's behaviour: **no ingest
//! error is ever fatal to a chat.** A malformed frame is counted and dropped; a
//! decrypt failure becomes a flag on the message; an internal error disables the
//! core for that chat so the platform can fall back.
//!
//! Second rule: **no error variant may carry message content, key material, or
//! ciphertext.** Detail strings are shape descriptions ("missing field `iv`"),
//! never data. `tests/no_leakage.rs` enforces this against a corpus.

use crate::secret::VibeSecretLenError;

/// Failure of an authenticated-encryption operation.
///
/// [`VibeCryptoError::AuthenticationFailed`] is deliberately opaque: it does not
/// distinguish "wrong key" from "tampered ciphertext" from "truncated tag",
/// because that distinction is an oracle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeCryptoError {
    /// No AEAD provider is installed, or the build has none. Fails closed.
    ProviderUnavailable,
    /// Tag verification failed. No further detail is available by design.
    AuthenticationFailed,
    /// A key or nonce had the wrong length.
    BadKeyMaterial { expected: usize, actual: usize },
    /// Ciphertext shorter than the authentication tag.
    CiphertextTooShort { minimum: usize, actual: usize },
    /// The OS CSPRNG refused to produce a nonce.
    RandomnessUnavailable,
    /// Plaintext exceeded the size this crate is willing to buffer.
    InputTooLarge { limit: usize, actual: usize },
}

impl std::fmt::Display for VibeCryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ProviderUnavailable => f.write_str("aead provider unavailable"),
            Self::AuthenticationFailed => f.write_str("aead authentication failed"),
            Self::BadKeyMaterial { expected, actual } => {
                write!(
                    f,
                    "bad key material: expected {expected} bytes, got {actual}"
                )
            }
            Self::CiphertextTooShort { minimum, actual } => {
                write!(f, "ciphertext too short: minimum {minimum}, got {actual}")
            }
            Self::RandomnessUnavailable => f.write_str("system randomness unavailable"),
            Self::InputTooLarge { limit, actual } => {
                write!(f, "input too large: limit {limit}, got {actual}")
            }
        }
    }
}

impl std::error::Error for VibeCryptoError {}

impl From<VibeSecretLenError> for VibeCryptoError {
    fn from(value: VibeSecretLenError) -> Self {
        Self::BadKeyMaterial {
            expected: value.expected,
            actual: value.actual,
        }
    }
}

/// Failure to parse or serialize a versioned envelope.
///
/// Every variant names a *shape* problem. None of them can be constructed with
/// attacker-supplied bytes inside.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VibeEnvelopeError {
    /// The string is not the hybrid envelope shape at all.
    NotAnEnvelope,
    /// Well-formed JSON object, but a required field is absent.
    MissingField { field: &'static str },
    /// A required field was present with the wrong JSON type.
    FieldNotAString { field: &'static str },
    /// A base64 field did not decode.
    FieldNotBase64 { field: &'static str },
    /// A decoded field had an unusable length.
    FieldWrongLength {
        field: &'static str,
        expected: usize,
        actual: usize,
    },
    /// `v` was present and was not a version this build accepts.
    UnsupportedVersion { found: i64, supported: i64 },
    /// Input was not UTF-8.
    NotUtf8,
    /// Input was not JSON.
    NotJson,
    /// The envelope exceeded the accepted size ceiling.
    TooLarge { limit: usize, actual: usize },
}

impl std::fmt::Display for VibeEnvelopeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotAnEnvelope => f.write_str("not a hybrid envelope"),
            Self::MissingField { field } => write!(f, "missing field `{field}`"),
            Self::FieldNotAString { field } => write!(f, "field `{field}` is not a string"),
            Self::FieldNotBase64 { field } => write!(f, "field `{field}` is not base64"),
            Self::FieldWrongLength {
                field,
                expected,
                actual,
            } => write!(f, "field `{field}` has {actual} bytes, expected {expected}"),
            Self::UnsupportedVersion { found, supported } => {
                write!(
                    f,
                    "unsupported envelope version {found}, supported {supported}"
                )
            }
            Self::NotUtf8 => f.write_str("input is not utf-8"),
            Self::NotJson => f.write_str("input is not json"),
            Self::TooLarge { limit, actual } => {
                write!(f, "envelope too large: limit {limit}, got {actual}")
            }
        }
    }
}

impl std::error::Error for VibeEnvelopeError {}

/// Failure to canonicalize a raw server frame into a snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VibeCanonicalError {
    NotJson,
    /// The frame was not a JSON object (or array, for a batch).
    NotAnObject,
    /// No usable message id under any known alias.
    MissingMessageId,
    /// No usable chat id under any known alias, and none supplied by the caller.
    MissingChatId,
    /// The frame exceeded the accepted size ceiling.
    TooLarge {
        limit: usize,
        actual: usize,
    },
}

impl std::fmt::Display for VibeCanonicalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotJson => f.write_str("frame is not json"),
            Self::NotAnObject => f.write_str("frame is not a json object"),
            Self::MissingMessageId => f.write_str("frame has no message id"),
            Self::MissingChatId => f.write_str("frame has no chat id"),
            Self::TooLarge { limit, actual } => {
                write!(f, "frame too large: limit {limit}, got {actual}")
            }
        }
    }
}

impl std::error::Error for VibeCanonicalError {}

/// The single error type crossing the crate's public reducer API.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VibeCoreError {
    /// Frame dropped. Counted in [`crate::reducer::VibeCoreCounters`], never fatal.
    Malformed(VibeCanonicalError),
    /// Envelope rejected. Message renders with `decryption_failed`.
    Envelope(VibeEnvelopeError),
    /// Crypto failure. Message renders with `decryption_failed`.
    Crypto(VibeCryptoError),
    /// A window/anchor query referenced a chat the reducer has never seen.
    UnknownChat,
    /// A query was superseded and will never be delivered.
    Cancelled,
    /// Invariant violation inside the core. The platform must disable the core
    /// for this chat and fall back.
    Internal { detail: &'static str },
}

impl std::fmt::Display for VibeCoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Malformed(e) => write!(f, "malformed frame: {e}"),
            Self::Envelope(e) => write!(f, "envelope: {e}"),
            Self::Crypto(e) => write!(f, "crypto: {e}"),
            Self::UnknownChat => f.write_str("unknown chat"),
            Self::Cancelled => f.write_str("cancelled"),
            Self::Internal { detail } => write!(f, "internal: {detail}"),
        }
    }
}

impl std::error::Error for VibeCoreError {}

impl From<VibeCanonicalError> for VibeCoreError {
    fn from(value: VibeCanonicalError) -> Self {
        Self::Malformed(value)
    }
}

impl From<VibeEnvelopeError> for VibeCoreError {
    fn from(value: VibeEnvelopeError) -> Self {
        Self::Envelope(value)
    }
}

impl From<VibeCryptoError> for VibeCoreError {
    fn from(value: VibeCryptoError) -> Self {
        Self::Crypto(value)
    }
}
