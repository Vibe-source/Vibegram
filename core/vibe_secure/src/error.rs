//! Typed errors.
//!
//! Same governing rule as `vibe_core::error`: **no variant carries message
//! content, key material, ciphertext, or which member/device was involved.**
//! Detail strings are shape descriptions ("ciphertext too large"), never data.
//! `tests/round_trip.rs` checks `Display`/`Debug` of every variant against a
//! corpus of secrets that must never appear in a rendered error.
//!
//! MLS in particular makes it tempting to report *why* a message failed to
//! open — wrong epoch, unknown sender, bad signature, tampered ciphertext.
//! That temptation is refused on purpose: distinguishing those cases for a
//! caller is an oracle an attacker can use to learn about group state they
//! should not be able to probe. Every failure to open is [`VibeSecureError::Open`],
//! full stop.

/// Failure of an MLS session operation.
///
/// Deliberately coarse-grained for the same reason [`Self::Open`] never says
/// *why*: a fine-grained reason is information a caller (or an attacker
/// riding along with a caller) can use to distinguish group states from the
/// outside. The platform reacts to the variant, not to a message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VibeSecureError {
    /// Could not generate a device's signing key or credential.
    IdentityGeneration,
    /// Could not build a `KeyPackage` to publish.
    KeyPackageBuild,
    /// Could not create a new group.
    GroupCreate,
    /// Could not join a group from a Welcome message.
    GroupJoin,
    /// Could not add member(s) to a group.
    MemberAdd,
    /// Could not seal a plaintext into a group message.
    Seal,
    /// Could not open a group message. Covers every reason: wrong session,
    /// tampered ciphertext, malformed protocol message, a party that was
    /// never a member. None of those are distinguished on purpose.
    Open,
    /// Input was not a well-formed `vmls1.` envelope.
    MalformedEnvelope,
    /// A key package or group named a ciphersuite this build does not speak.
    UnsupportedCiphersuite,
    /// A ciphertext (encoded or decoded) exceeded the size this crate is
    /// willing to buffer, rejected before the corresponding allocation.
    CiphertextTooLarge { limit: usize, actual: usize },
    /// This session caught a panic while an operation held mutable access to
    /// its underlying MLS group and can no longer prove its ratchet state is
    /// intact. The session is permanently refused from this point on — see
    /// `session.rs`'s `with_group` for why retrying is not offered.
    SessionPoisoned,
    /// A [`crate::VibeSecureProvider`]'s SQLite-backed storage could not be
    /// opened or migrated. Covers a missing parent directory, a permissions
    /// failure, a corrupt file, and a failed schema migration alike — never
    /// distinguished, for the same reason [`Self::Open`] is not: the detail
    /// is never a filesystem path or SQL text, so there is nothing finer to
    /// report. A store that fails to migrate is never handed back as usable
    /// — see `provider.rs`'s `open`.
    Storage,
}

impl std::fmt::Display for VibeSecureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IdentityGeneration => f.write_str("failed to generate device identity"),
            Self::KeyPackageBuild => f.write_str("failed to build key package"),
            Self::GroupCreate => f.write_str("failed to create group"),
            Self::GroupJoin => f.write_str("failed to join group from welcome"),
            Self::MemberAdd => f.write_str("failed to add member to group"),
            Self::Seal => f.write_str("failed to seal message"),
            Self::Open => f.write_str("failed to open message"),
            Self::MalformedEnvelope => f.write_str("malformed secure envelope"),
            Self::UnsupportedCiphersuite => f.write_str("unsupported ciphersuite"),
            Self::CiphertextTooLarge { limit, actual } => {
                write!(f, "ciphertext too large: limit {limit}, got {actual}")
            }
            Self::SessionPoisoned => {
                f.write_str("session poisoned by a caught panic; discard it and start a new one")
            }
            Self::Storage => f.write_str("secure storage open or migration failed"),
        }
    }
}

impl std::error::Error for VibeSecureError {}
