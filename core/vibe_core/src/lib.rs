//! `vibe_core` — deterministic, host-only timeline core.
//!
//! **This crate is not linked into any application.** It has no FFI layer, no
//! SQLite, no network, and no platform dependency. It exists so the parts of the
//! Vibe message pipeline that are currently implemented three times — once in
//! Swift, once in Kotlin, once in TypeScript — can be implemented once, and so
//! that the ordering and dedup reduction that has no test coverage today can be
//! fuzzed and property-tested on a laptop before a single production line moves.
//!
//! # What this crate does
//!
//! * [`envelope`] — strict, versioned parse/serialize of the hybrid
//!   `encrypted_content` format, plus honest classification of the other three
//!   shapes that field carries in production.
//! * [`crypto`] — an AEAD *boundary*. No primitive is implemented here; the only
//!   algorithm is RustCrypto AES-256-GCM behind a trait, with a deny-by-default
//!   provider so a build can have no algorithm at all.
//! * [`canonical`] — raw server frame to [`types::VibeMessageSnapshotV1`],
//!   including the field-alias resolution the Swift engine does by hand.
//! * [`order`], [`dedup`], [`receipts`] — the deterministic reduction.
//! * [`window`], [`delta`] — bounded window queries and typed ordered deltas.
//! * [`reducer`] — the per-chat state machine: generation fencing, idempotent
//!   replay, tombstones, edits, read cursor, clear-before, id healing, and the
//!   flush barrier.
//! * [`media`] — media envelope classification, cache identity, and byte
//!   validation. Never media bytes in a snapshot.
//! * [`fixtures`] — synthetic, deterministic corpora. **No production plaintext
//!   is committed to this repository.**
//!
//! # What this crate does not do, ever
//!
//! * RSA, private-key custody, or key wrapping. See [`crypto::VibeKeyUnwrapper`].
//! * Networking, file I/O, or SQLite.
//! * UI, layout, or text measurement.
//! * Opening agent runtime payloads. They are
//!   [`secret::VibeOpaqueBlob`] and stay that way.
//!
//! # Reading order
//!
//! [`types`] first — it is the contract. Then [`reducer`], which is the only
//! stateful thing in the crate. Everything else is a pure function it calls.

pub mod canonical;
pub mod crypto;
pub mod dedup;
pub mod delta;
pub mod envelope;
pub mod error;
pub mod fixtures;
pub mod group;
pub mod hash;
pub mod media;
pub mod order;
pub mod receipts;
pub mod reducer;
pub mod secret;
pub mod store_seal;
pub mod types;
pub mod window;

pub use crypto::{
    VibeAeadProvider, VibeDenyAllAead, VibeDenyAllKeyUnwrapper, VibeKeyUnwrapper,
    VibeWrappedKeyRequest,
};
pub use error::{VibeCanonicalError, VibeCoreError, VibeCryptoError, VibeEnvelopeError};
pub use group::{
    VibeGroupEnvelope, VibeGroupEpoch, VibeGroupError, VibeGroupKeyring, VibeGroupSealAuthorization,
};
pub use reducer::{
    VibeChatProfile, VibeCoreConfig, VibeCoreCounters, VibeIngestAck, VibeReducerStateMetrics,
    VibeTimelineReducer,
};
pub use secret::{VibeOpaqueBlob, VibeSecretKey};
pub use store_seal::{VibeSealedBody, VibeStoreSealError, VibeStoreSealer};
pub use types::{
    VibeAnchorPin, VibeAnchorResolution, VibeAsyncTimelineGate, VibeAuthorRef, VibeChangeMask,
    VibeChatClass, VibeCoreEventV1, VibeDeliveryState, VibeDeltaCause, VibeDisplayStatus,
    VibeEditState, VibeEventBody, VibeEventSource, VibeLocalStatus, VibeMessageBody,
    VibeMessageFlags, VibeMessageKind, VibeMessageSnapshotV1, VibeOrderKey, VibeReceiptKind,
    VibeTimelineAnchor, VibeTimelineDeltaBodyV1, VibeTimelineDeltaV1, VibeTimelineOpV1,
    VibeTimelineWindowResultV1, VibeTimelineWindowV1, VibeUnreadState, VibeWindowBounds,
};
pub use window::VibeWindowPolicy;

/// Crate version, surfaced so a shadow-mode comparison can record which build
/// produced a mismatch.
pub const VIBE_CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
