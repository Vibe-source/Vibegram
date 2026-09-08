//! `vibe_secure` — MLS (RFC 9420) session layer over OpenMLS.
//!
//! # Why this crate exists
//!
//! Vibe today mints a fresh AES-256 key per message and wraps it under one
//! **static** RSA-2048 key per account. Fresh keys, but an escrowed history:
//! that one RSA key opens every message ever sent, forever, if it is ever
//! compromised. MLS derives message keys from a ratcheting key schedule and
//! deletes them after use, and re-seeds the schedule on every membership
//! change — so a past compromise cannot read history, and a session heals
//! itself going forward. See `docs/secure-core-architecture.md` §§1–3 for the
//! full comparison against hand-rolling the Signal double ratchet (rejected:
//! AGPL) and for why OpenMLS specifically (audited, MIT).
//!
//! **A DM is a two-member group.** This crate does not have a separate 1:1
//! path — [`VibeSecureSession::create`] plus one [`VibeSecureSession::add_members`]
//! call *is* starting a DM. That is what finally lets Vibe's group and 1:1
//! encryption be one protocol instead of two, and what makes multi-device
//! native: each device is simply another leaf in the tree, rather than a
//! wrapped copy of one account key living on the server.
//!
//! # What this crate does not do
//!
//! No wire I/O, no server calls, no Swift/FFI, and — deliberately — no
//! dependency on `vibe_core`. `vibe_core` stays pure and deterministic so its
//! ordering/dedup reduction is fuzzable on a laptop; an MLS state machine
//! needs persistence, randomness, and monotonic epoch state, and merging the
//! two would cost `vibe_core` that property for no benefit. The two meet only
//! at `vibe_core_ffi`, exactly as `vibe_core_store` does today. See
//! `docs/secure-core-architecture.md` §4.
//!
//! # Encapsulation
//!
//! Every public function here takes and returns `&[u8]` / `Vec<u8>` / `&str`
//! / `String`, never an OpenMLS type. That is not incidental tidiness: it
//! means a version bump of the underlying MLS implementation is contained
//! entirely inside this crate, and it means nothing upstream can be tempted
//! to reach past this API and call OpenMLS directly with a half-validated
//! value.
//!
//! # A debug-only landmine in the pinned OpenMLS, and how it is defused
//!
//! `openmls-0.8.1/src/framing/private_message_in.rs:136`, in
//! `PrivateMessageIn::decrypt`, has `debug_assert!(false, "Ciphertext
//! decryption failed")` on the AEAD-failure path — reached whenever a
//! ciphertext fails to authenticate, which any attacker-flipped byte in a
//! `vmls1.` envelope does deliberately. `debug_assertions` is on by default
//! for `dev` and `test` profiles, so an unguarded call panics there instead
//! of returning the `Err` it was about to construct; the assertion compiles
//! out entirely under `--release`, where the function already returns
//! cleanly. This was found empirically, by a corrupted-envelope test
//! panicking under plain `cargo test`.
//!
//! [`session::VibeSecureSession`] does not rely on every caller remembering
//! to build with `--release`: every call that processes bytes from outside
//! this device is wrapped in `catch_unwind`, converting a panic (this one, or
//! an equivalent future one, upstream or otherwise) into the ordinary
//! [`VibeSecureError`] it was standing in for. This mirrors the pattern
//! `vibe_core_ffi` already uses at its entry points — see that crate's "Panics
//! degrade, they do not abort" — applied one layer earlier, since this crate
//! is the one actually parsing peer-supplied ciphertext. Without it, a
//! `debug_assertions` build of this crate — a local debug session, a CI
//! profile that forgets `--release`, anything short of a genuine release
//! artifact — could be remotely crashed by any peer able to send one
//! malformed `vmls1.` message. Production ships `--release` either way; this
//! closes the gap for everything that is not that.

#![forbid(unsafe_code)]

mod envelope;
mod error;
mod identity;
mod padding;
mod provider;
mod session;
mod trust;

pub use envelope::{VIBE_MLS_MAX_CIPHERTEXT, VIBE_MLS_SEALED_PREFIX};
pub use error::VibeSecureError;
pub use identity::{VibeDeviceIdentity, VibeKeyPackageBundle};
pub use padding::{VibePaddingError, VIBE_PAD_BUCKETS};
pub use provider::VibeSecureProvider;
pub use session::{VibeCommitOutput, VibeMlsEnvelopeHeader, VibeSecureSession};
pub use trust::{
    inspect_key_package, vibe_safety_code_hex, vibe_safety_number, VibeKeyPackageIdentity,
    VIBE_SAFETY_CODE_HEX_CHARS, VIBE_SAFETY_NUMBER_DIGITS,
};

/// The one ciphersuite this build speaks: X25519 for key agreement, AES-128-GCM
/// for the AEAD, SHA-256 for the key schedule's hash, Ed25519 for signatures.
///
/// A single fixed ciphersuite, not a negotiated list, on purpose: MLS lets
/// peers negotiate, but a negotiated choice is only as strong as a client's
/// willingness to refuse a downgrade, and refusing a downgrade is exactly as
/// simple as never offering one. `docs/secure-core-architecture.md` §3 tracks
/// the post-quantum hybrid ciphersuite as the reason this will eventually
/// become a small, explicit set rather than growing ad hoc.
pub const VIBE_SECURE_CIPHERSUITE: openmls::prelude::Ciphersuite =
    openmls::prelude::Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
