//! Group end-to-end encryption: per-epoch symmetric keys.
//!
//! # Why this exists
//!
//! Groups and channels ship **in the clear** today. `ChatEngine.swift:4510` puts
//! the payload JSON straight into `encrypted_content` when `isGroup`, and the
//! server stores that string verbatim (`chat_channel.ex:144`). There is no group
//! key anywhere in the iOS client, the web client, or the server. This module is
//! the first half of closing that gap — the deterministic, testable half that
//! belongs in one implementation rather than three.
//!
//! # The design, and why not the alternatives
//!
//! A group has a monotone sequence of [`VibeGroupEpoch`]s. Each epoch owns one
//! symmetric AES-256 key, held by exactly the members of that epoch. A message
//! is sealed under the epoch key current at send time and records its epoch, so
//! a member who joined at epoch 5 can still open epoch 3 history *if and only
//! if* they were given the epoch 3 key.
//!
//! Membership changes mint a new epoch. That is what makes removal meaningful:
//! a removed member keeps whatever epoch keys they already had — you cannot
//! un-read history they could already read — but never receives the next one,
//! so they are cryptographically excluded from everything after their removal.
//!
//! Distributing an epoch key to a member is **not this module's job**. It rides
//! the existing 1:1 hybrid envelope, which is already end-to-end encrypted and
//! already works. That is the whole reason this design is small: the hard part
//! (per-member key agreement) is a solved problem in this codebase, and groups
//! reduce to "ship one symmetric key over a channel that already works".
//!
//! Rejected, and why:
//!
//! * **Per-message RSA wrap to every member.** `encrypted_content` is a single
//!   column shared by every reader, so there is nowhere to put N per-recipient
//!   blobs without a schema change and an N-way fan-out on every send.
//! * **Sender keys (the Signal/WhatsApp model).** Strictly better — it adds
//!   forward secrecy — but it needs a per-sender ratchet, persisted ratchet
//!   state that survives reinstall, and a skipped-message key cache for
//!   out-of-order delivery. Epoch keys are a clean subset: the ratchet can be
//!   added later *inside* an epoch without changing the envelope or the stored
//!   history, because the epoch id already tells a reader which regime applies.
//! * **MLS (RFC 9420).** The right long-term answer for large groups, and far
//!   too large a dependency and migration to bundle into a rendering refactor.
//!
//! # The wire format, and why it is a new one
//!
//! ```text
//! vgrp2.<b64(epoch, 4 bytes LE)>.<b64(12-byte IV)>.<b64(ciphertext || 16-byte tag)>
//! ```
//!
//! Prefix-detected, exactly like the agent runtime's `arte1.` and the media
//! format's `vmed2`. It is deliberately **not** an overload of the hybrid
//! `{v,iv,c,k}` envelope:
//!
//! * the shipped classifier requires `iv`+`c`+`k` before it will treat a string
//!   as hybrid (`envelope::classify`), and a group envelope has no per-recipient
//!   `k` slot to offer;
//! * a deployed client that meets an unrecognised **prefix** renders it as
//!   literal text — visibly wrong, obviously "update your app". A deployed
//!   client that meets a hybrid envelope it cannot open renders base64 garbage
//!   or an empty bubble. Failing loudly is the better failure.
//!
//! The reserved `g` slot in the hybrid envelope stays exactly as it is: parsed,
//! never written. This module does not touch it.
//!
//! # Rollout is gated, and the gate is a type
//!
//! Turning group encryption on before every member's client understands it does
//! not degrade the group — it **splits** it, silently, into members who can read
//! and members who cannot. So [`seal_group`] cannot be called without a
//! [`VibeGroupSealAuthorization`], which cannot be constructed unless every
//! member is known to be capable. The gate is a compile-time visible fact rather
//! than a paragraph in a document, the same discipline `media::seal_stream2`
//! uses for the deferred `vmed2` format.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;

use crate::crypto::VibeAeadProvider;
use crate::error::VibeCryptoError;
use crate::secret::{
    VibeNonce, VibePlaintext, VibeSecretKey, VIBE_KEY_LEN, VIBE_NONCE_LEN, VIBE_TAG_LEN,
};

/// Prefix of the group envelope. Recognised by prefix, like `arte1.`.
pub const VIBE_GROUP_SEALED_PREFIX: &str = "vgrp2.";

/// Largest group ciphertext this module will buffer, in bytes.
///
/// A group message body is text and metadata; media rides the media envelope and
/// never appears here. The ceiling exists so a hostile server cannot make a
/// client allocate without bound, and it is checked *before* any allocation.
pub const VIBE_GROUP_MAX_CIPHERTEXT: usize = 1 << 20;

/// How many epoch keys a keyring retains.
///
/// Scroll-back into older history needs older epoch keys, so this cannot be 1.
/// It is bounded so a long-lived group cannot grow key material without limit;
/// a reader who scrolls past the retained window re-requests from the platform.
pub const VIBE_GROUP_EPOCH_RETENTION: usize = 64;

/// A monotone group key epoch. Epoch 0 is group creation.
///
/// Monotonicity is the security property: a replayed membership change must not
/// be able to move a group *backwards* onto a key a removed member still holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct VibeGroupEpoch(pub u32);

impl VibeGroupEpoch {
    /// The epoch a group starts at.
    pub const GENESIS: Self = Self(0);

    /// The next epoch, or `None` at saturation.
    ///
    /// Returning `None` rather than wrapping is deliberate: wrapping would take
    /// a group back to epoch 0, whose key every member who was ever removed may
    /// still hold.
    pub fn next(self) -> Option<Self> {
        self.0.checked_add(1).map(Self)
    }

    fn as_aad_bytes(self) -> [u8; 4] {
        self.0.to_le_bytes()
    }
}

/// What went wrong opening or sealing a group message.
///
/// Carries shapes, never data: no group id, no ciphertext, no key material, and
/// nothing an attacker could use to distinguish *why* a message failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeGroupError {
    /// Not a `vgrp2.` string at all.
    NotGroupEnvelope,
    /// Right prefix, wrong structure. Counted and dropped, never fatal.
    Malformed,
    /// Ciphertext beyond [`VIBE_GROUP_MAX_CIPHERTEXT`].
    TooLarge,
    /// The keyring has no key for the epoch this message names. The platform
    /// must fetch it; the row renders as `decryption_failed` until it does.
    EpochKeyMissing(VibeGroupEpoch),
    /// An epoch key was offered for an epoch at or before one already known,
    /// which is either a replay or a rollback attempt.
    EpochNotMonotone,
    /// AEAD failure. Deliberately indistinguishable between wrong key, tampered
    /// ciphertext, and truncation.
    Crypto(VibeCryptoError),
}

impl std::fmt::Display for VibeGroupError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotGroupEnvelope => f.write_str("not a group envelope"),
            Self::Malformed => f.write_str("malformed group envelope"),
            Self::TooLarge => f.write_str("group ciphertext too large"),
            Self::EpochKeyMissing(_) => f.write_str("group epoch key missing"),
            Self::EpochNotMonotone => f.write_str("group epoch not monotone"),
            Self::Crypto(e) => write!(f, "group crypto: {e}"),
        }
    }
}

impl std::error::Error for VibeGroupError {}

impl From<VibeCryptoError> for VibeGroupError {
    fn from(value: VibeCryptoError) -> Self {
        Self::Crypto(value)
    }
}

/// Proof that every member of a group can read the group format.
///
/// There is no public constructor that skips the check. Enabling group
/// encryption for a group containing one member on an older build does not
/// weaken that member's security — it removes their ability to read the group at
/// all, silently, which is worse. This type exists so that failure mode cannot
/// be reached by forgetting an `if`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeGroupSealAuthorization {
    epoch: VibeGroupEpoch,
}

impl VibeGroupSealAuthorization {
    /// Authorizes sealing only when *every* member is capable.
    ///
    /// `capable_members` must equal `total_members`, and a group with zero
    /// members is refused rather than treated as vacuously capable — an empty
    /// membership list is far more likely to be a failed fetch than a real
    /// empty group, and treating it as authorization would encrypt to nobody.
    pub fn all_members_capable(
        epoch: VibeGroupEpoch,
        total_members: u32,
        capable_members: u32,
    ) -> Option<Self> {
        if total_members == 0 || capable_members != total_members {
            return None;
        }
        Some(Self { epoch })
    }

    pub fn epoch(self) -> VibeGroupEpoch {
        self.epoch
    }
}

/// The epoch keys this device holds for one group.
///
/// Insertion is monotone-checked and retention is bounded. The keyring never
/// serializes, never implements `Debug` over its keys, and never hands a key
/// back out — callers seal and open *through* it.
#[derive(Default)]
pub struct VibeGroupKeyring {
    /// Ascending by epoch. Bounded to [`VIBE_GROUP_EPOCH_RETENTION`]; the oldest
    /// is evicted first because scroll-back reaches for recent history far more
    /// often than for the beginning of a group.
    entries: Vec<(VibeGroupEpoch, VibeSecretKey)>,
}

impl std::fmt::Debug for VibeGroupKeyring {
    /// Counts and bounds only. Printing an epoch key would defeat the module.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeGroupKeyring")
            .field("epochs", &self.entries.len())
            .field("newest", &self.newest_epoch().map(|e| e.0))
            .finish()
    }
}

impl VibeGroupKeyring {
    pub fn new() -> Self {
        Self::default()
    }

    /// Highest epoch held, or `None` when the keyring is empty.
    pub fn newest_epoch(&self) -> Option<VibeGroupEpoch> {
        self.entries.last().map(|(epoch, _)| *epoch)
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn has_epoch(&self, epoch: VibeGroupEpoch) -> bool {
        self.find(epoch).is_some()
    }

    /// Installs the key for a **new, strictly newer** epoch.
    ///
    /// Rejecting an equal or older epoch is what stops a replayed membership
    /// frame from rotating a group back onto a key a removed member still holds.
    /// Backfilling old history keys is a separate, explicitly-named operation —
    /// see [`Self::backfill_historical_epoch`].
    pub fn install_epoch(
        &mut self,
        epoch: VibeGroupEpoch,
        key: VibeSecretKey,
    ) -> Result<(), VibeGroupError> {
        if let Some(newest) = self.newest_epoch() {
            if epoch <= newest {
                return Err(VibeGroupError::EpochNotMonotone);
            }
        }
        self.entries.push((epoch, key));
        self.evict_oldest_beyond_retention();
        Ok(())
    }

    /// Installs a key for an epoch **older** than the newest known, so a member
    /// who was given back-history can open it.
    ///
    /// Separate from [`Self::install_epoch`] on purpose: this is the one path
    /// that legitimately moves backwards, so it is named, and it can never be
    /// reached by a frame that merely *looks* like a rotation. Re-installing an
    /// epoch that is already present is refused rather than silently replacing
    /// it — a second, different key for a known epoch is a protocol violation.
    pub fn backfill_historical_epoch(
        &mut self,
        epoch: VibeGroupEpoch,
        key: VibeSecretKey,
    ) -> Result<(), VibeGroupError> {
        if self.has_epoch(epoch) {
            return Err(VibeGroupError::EpochNotMonotone);
        }
        let at = self
            .entries
            .binary_search_by(|(known, _)| known.cmp(&epoch))
            .unwrap_or_else(|insert_at| insert_at);
        self.entries.insert(at, (epoch, key));
        self.evict_oldest_beyond_retention();
        Ok(())
    }

    fn find(&self, epoch: VibeGroupEpoch) -> Option<&VibeSecretKey> {
        self.entries
            .binary_search_by(|(known, _)| known.cmp(&epoch))
            .ok()
            .map(|at| &self.entries[at].1)
    }

    fn evict_oldest_beyond_retention(&mut self) {
        if self.entries.len() > VIBE_GROUP_EPOCH_RETENTION {
            let excess = self.entries.len() - VIBE_GROUP_EPOCH_RETENTION;
            self.entries.drain(..excess);
        }
    }
}

/// A parsed group envelope. Holds ciphertext only — safe to `Debug`.
#[derive(Clone, PartialEq, Eq)]
pub struct VibeGroupEnvelope {
    pub epoch: VibeGroupEpoch,
    pub nonce: VibeNonce,
    /// `ciphertext || tag`.
    pub ciphertext_and_tag: Vec<u8>,
}

impl std::fmt::Debug for VibeGroupEnvelope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VibeGroupEnvelope")
            .field("epoch", &self.epoch.0)
            .field("ciphertext_len", &self.ciphertext_and_tag.len())
            .finish()
    }
}

/// True when `raw` claims to be a group envelope.
///
/// Cheap prefix test, so `canonical` can classify without allocating.
pub fn is_group_envelope(raw: &str) -> bool {
    raw.starts_with(VIBE_GROUP_SEALED_PREFIX)
}

/// Binds a ciphertext to its group and epoch.
///
/// Without this, a ciphertext lifted out of group A at epoch 3 would open
/// unchanged in group B at epoch 7 for anyone holding both keys. The separator
/// is a byte that cannot occur in a group id, so `("ab", 1)` and `("a", …)`
/// cannot collide.
fn group_aad(group_id: &str, epoch: VibeGroupEpoch) -> Vec<u8> {
    let mut aad = Vec::with_capacity(group_id.len() + 5);
    aad.extend_from_slice(group_id.as_bytes());
    aad.push(0x1F);
    aad.extend_from_slice(&epoch.as_aad_bytes());
    aad
}

/// Parses `vgrp2.<epoch>.<iv>.<ct||tag>` without opening it.
///
/// Total over arbitrary input: every malformed shape returns an error and none
/// panics, which is what makes this a fuzz target rather than a liability.
pub fn parse_group_envelope(raw: &str) -> Result<VibeGroupEnvelope, VibeGroupError> {
    let body = raw
        .strip_prefix(VIBE_GROUP_SEALED_PREFIX)
        .ok_or(VibeGroupError::NotGroupEnvelope)?;

    let mut parts = body.split('.');
    let (Some(epoch_b64), Some(iv_b64), Some(ct_b64), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(VibeGroupError::Malformed);
    };

    let epoch_bytes = B64
        .decode(epoch_b64)
        .map_err(|_| VibeGroupError::Malformed)?;
    let epoch_raw: [u8; 4] = epoch_bytes
        .as_slice()
        .try_into()
        .map_err(|_| VibeGroupError::Malformed)?;
    let epoch = VibeGroupEpoch(u32::from_le_bytes(epoch_raw));

    let iv = B64.decode(iv_b64).map_err(|_| VibeGroupError::Malformed)?;
    if iv.len() != VIBE_NONCE_LEN {
        return Err(VibeGroupError::Malformed);
    }
    let nonce = VibeNonce::from_slice(&iv).map_err(|_| VibeGroupError::Malformed)?;

    let ciphertext_and_tag = B64.decode(ct_b64).map_err(|_| VibeGroupError::Malformed)?;
    if ciphertext_and_tag.len() < VIBE_TAG_LEN {
        return Err(VibeGroupError::Malformed);
    }
    if ciphertext_and_tag.len() > VIBE_GROUP_MAX_CIPHERTEXT {
        return Err(VibeGroupError::TooLarge);
    }

    Ok(VibeGroupEnvelope {
        epoch,
        nonce,
        ciphertext_and_tag,
    })
}

/// Opens a group envelope using whichever epoch key the keyring holds.
///
/// Returns [`VibeGroupError::EpochKeyMissing`] — carrying the epoch, so the
/// platform knows which key to fetch — rather than a generic failure, because
/// "I have never been given this key" and "this ciphertext is corrupt" call for
/// completely different responses.
pub fn open_group(
    provider: &dyn VibeAeadProvider,
    keyring: &VibeGroupKeyring,
    group_id: &str,
    raw: &str,
) -> Result<VibePlaintext, VibeGroupError> {
    let envelope = parse_group_envelope(raw)?;
    let key = keyring
        .find(envelope.epoch)
        .ok_or(VibeGroupError::EpochKeyMissing(envelope.epoch))?;
    let aad = group_aad(group_id, envelope.epoch);
    provider
        .open(key, &envelope.nonce, &aad, &envelope.ciphertext_and_tag)
        .map_err(VibeGroupError::from)
}

/// Mints a fresh epoch key from the operating-system CSPRNG.
///
/// This is the only function in the module that yields raw key material, and it
/// does so because the device opening a new epoch is the device that has to hand
/// that key to every member. Everything else here is write-only: a
/// [`VibeGroupKeyring`] takes keys and never gives them back.
///
/// It exists so key generation cannot be open-coded at a call site. An epoch key
/// drawn from a weak source is not a degraded encryption — it is no encryption,
/// and it fails *silently*: every message still seals, still opens, and is still
/// readable by anyone who can reproduce the guess. Keeping the one legitimate
/// source of key material beside the code that consumes it is what makes that
/// mistake unavailable rather than merely discouraged.
pub fn mint_epoch_key() -> Result<[u8; VIBE_KEY_LEN], VibeCryptoError> {
    let mut bytes = [0u8; VIBE_KEY_LEN];
    getrandom::fill(&mut bytes).map_err(|_| VibeCryptoError::RandomnessUnavailable)?;
    Ok(bytes)
}

/// Seals a group message under the authorized epoch's key.
///
/// Takes a [`VibeGroupSealAuthorization`] rather than a bare epoch so that
/// "every member can read this" is checked by the type system at the only place
/// it matters. A fresh random nonce per message is mandatory and is generated
/// here rather than accepted from the caller — a caller-supplied nonce is how
/// GCM nonce reuse happens, and nonce reuse under one key is catastrophic.
pub fn seal_group(
    provider: &dyn VibeAeadProvider,
    keyring: &VibeGroupKeyring,
    group_id: &str,
    authorization: VibeGroupSealAuthorization,
    plaintext: &[u8],
) -> Result<String, VibeGroupError> {
    if plaintext.len() > VIBE_GROUP_MAX_CIPHERTEXT {
        return Err(VibeGroupError::TooLarge);
    }
    let epoch = authorization.epoch();
    let key = keyring
        .find(epoch)
        .ok_or(VibeGroupError::EpochKeyMissing(epoch))?;
    let nonce = VibeNonce::random()?;
    let aad = group_aad(group_id, epoch);
    let ciphertext_and_tag = provider.seal(key, &nonce, &aad, plaintext)?;

    Ok(format!(
        "{VIBE_GROUP_SEALED_PREFIX}{}.{}.{}",
        B64.encode(epoch.as_aad_bytes()),
        B64.encode(nonce.as_bytes()),
        B64.encode(&ciphertext_and_tag)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    // Only the round-trip tests need a real provider, and those are gated on
    // the feature that supplies one.
    #[cfg(feature = "aead-aes-gcm")]
    use crate::crypto::default_aead_provider;

    fn key(seed: u8) -> VibeSecretKey {
        VibeSecretKey::from_bytes([seed; 32])
    }

    fn keyring_with(epochs: &[(u32, u8)]) -> VibeGroupKeyring {
        let mut ring = VibeGroupKeyring::new();
        for (epoch, seed) in epochs {
            ring.install_epoch(VibeGroupEpoch(*epoch), key(*seed))
                .expect("ascending epochs install");
        }
        ring
    }

    #[test]
    fn authorization_requires_every_member_to_be_capable() {
        let epoch = VibeGroupEpoch(3);
        assert!(VibeGroupSealAuthorization::all_members_capable(epoch, 5, 4).is_none());
        assert!(VibeGroupSealAuthorization::all_members_capable(epoch, 5, 5).is_some());
    }

    #[test]
    fn an_empty_membership_list_never_authorizes() {
        // A failed member fetch reads as zero members. Treating that as
        // "everyone is capable" would encrypt a group to nobody.
        assert!(
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch::GENESIS, 0, 0)
                .is_none()
        );
    }

    #[test]
    fn epochs_are_monotone_and_a_rollback_is_refused() {
        let mut ring = keyring_with(&[(0, 1), (1, 2)]);
        assert_eq!(
            ring.install_epoch(VibeGroupEpoch(1), key(9)),
            Err(VibeGroupError::EpochNotMonotone)
        );
        assert_eq!(
            ring.install_epoch(VibeGroupEpoch(0), key(9)),
            Err(VibeGroupError::EpochNotMonotone)
        );
        assert_eq!(ring.newest_epoch(), Some(VibeGroupEpoch(1)));
    }

    #[test]
    #[cfg(feature = "aead-aes-gcm")]
    fn round_trip_opens_under_the_sealing_epoch() {
        let provider = default_aead_provider();
        let ring = keyring_with(&[(0, 1), (7, 2)]);
        let auth = VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch(7), 3, 3)
            .expect("all capable");

        let sealed = seal_group(provider.as_ref(), &ring, "group-a", auth, b"hello group")
            .expect("seal succeeds");
        assert!(is_group_envelope(&sealed));

        let opened = open_group(provider.as_ref(), &ring, "group-a", &sealed).expect("opens");
        assert_eq!(opened.as_bytes(), b"hello group");
    }

    #[test]
    #[cfg(feature = "aead-aes-gcm")]
    fn a_ciphertext_cannot_be_replayed_into_another_group() {
        let provider = default_aead_provider();
        let ring = keyring_with(&[(4, 3)]);
        let auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch(4), 2, 2).unwrap();
        let sealed = seal_group(provider.as_ref(), &ring, "group-a", auth, b"secret").unwrap();

        // Same epoch, same key, different group id: the AAD must refuse it.
        let replayed = open_group(provider.as_ref(), &ring, "group-b", &sealed);
        assert!(matches!(
            replayed,
            Err(VibeGroupError::Crypto(
                VibeCryptoError::AuthenticationFailed
            ))
        ));
    }

    #[test]
    #[cfg(feature = "aead-aes-gcm")]
    fn a_ciphertext_cannot_be_replayed_into_another_epoch() {
        let provider = default_aead_provider();
        // Two epochs deliberately sharing key material, so only the AAD
        // separates them. If epoch were not bound, this would open.
        let mut ring = VibeGroupKeyring::new();
        ring.install_epoch(VibeGroupEpoch(1), key(5)).unwrap();
        ring.install_epoch(VibeGroupEpoch(2), key(5)).unwrap();

        let auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch(1), 2, 2).unwrap();
        let sealed = seal_group(provider.as_ref(), &ring, "g", auth, b"secret").unwrap();
        let forged = sealed.replace(
            &B64.encode(VibeGroupEpoch(1).as_aad_bytes()),
            &B64.encode(VibeGroupEpoch(2).as_aad_bytes()),
        );

        assert!(matches!(
            open_group(provider.as_ref(), &ring, "g", &forged),
            Err(VibeGroupError::Crypto(
                VibeCryptoError::AuthenticationFailed
            ))
        ));
    }

    #[test]
    #[cfg(feature = "aead-aes-gcm")]
    fn a_removed_member_cannot_open_the_next_epoch() {
        let provider = default_aead_provider();
        // The removed member's keyring stopped at epoch 1.
        let removed = keyring_with(&[(0, 1), (1, 2)]);
        // The group rotated to epoch 2 on their removal.
        let current = keyring_with(&[(0, 1), (1, 2), (2, 3)]);

        let auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch(2), 4, 4).unwrap();
        let sealed = seal_group(provider.as_ref(), &current, "g", auth, b"after removal").unwrap();

        // `matches!` rather than `assert_eq!`: `VibePlaintext` has no `Debug` by
        // design, so a `Result` containing it cannot be compared or printed.
        assert!(matches!(
            open_group(provider.as_ref(), &removed, "g", &sealed),
            Err(VibeGroupError::EpochKeyMissing(epoch)) if epoch == VibeGroupEpoch(2)
        ));
        // And the epoch they *did* hold still opens, because you cannot un-read
        // history someone could already read.
        let old_auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch(1), 4, 4).unwrap();
        let older = seal_group(provider.as_ref(), &current, "g", old_auth, b"before").unwrap();
        assert!(open_group(provider.as_ref(), &removed, "g", &older).is_ok());
    }

    #[test]
    #[cfg(feature = "aead-aes-gcm")]
    fn every_nonce_is_fresh() {
        let provider = default_aead_provider();
        let ring = keyring_with(&[(0, 1)]);
        let auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch::GENESIS, 2, 2).unwrap();

        let a = seal_group(provider.as_ref(), &ring, "g", auth, b"same plaintext").unwrap();
        let b = seal_group(provider.as_ref(), &ring, "g", auth, b"same plaintext").unwrap();
        assert_ne!(
            a, b,
            "identical plaintext must not produce identical output"
        );
    }

    #[test]
    fn a_minted_epoch_key_is_full_length_and_never_repeats() {
        let a = mint_epoch_key().expect("mint");
        let b = mint_epoch_key().expect("mint");

        assert_eq!(a.len(), VIBE_KEY_LEN, "an epoch key must be a full AES-256 key");
        assert_ne!(
            a, b,
            "two mints returning the same key would mean the RNG is not wired to anything"
        );
        assert_ne!(
            a,
            [0u8; VIBE_KEY_LEN],
            "an all-zero key is what a silently-failing RNG returns, and it would still seal and open"
        );
    }

    #[test]
    fn a_minted_key_actually_encrypts_under_this_module() {
        // Mint, install, round-trip. Without this the mint could return
        // well-formed bytes that the keyring rejects, and the failure would only
        // surface on a real device with a real group.
        let provider = default_aead_provider();
        let mut ring = VibeGroupKeyring::new();
        ring.install_epoch(
            VibeGroupEpoch::GENESIS,
            VibeSecretKey::from_bytes(mint_epoch_key().expect("mint")),
        )
        .expect("install");

        let auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch::GENESIS, 3, 3).unwrap();
        let sealed = seal_group(provider.as_ref(), &ring, "g", auth, b"minted").expect("seal");

        assert_eq!(
            open_group(provider.as_ref(), &ring, "g", &sealed)
                .expect("open")
                .as_bytes(),
            b"minted"
        );
    }

    #[test]
    fn backfill_admits_old_history_but_never_a_second_key_for_a_known_epoch() {
        let mut ring = keyring_with(&[(5, 1)]);
        assert!(ring
            .backfill_historical_epoch(VibeGroupEpoch(2), key(7))
            .is_ok());
        assert!(ring.has_epoch(VibeGroupEpoch(2)));
        assert_eq!(ring.newest_epoch(), Some(VibeGroupEpoch(5)));
        assert_eq!(
            ring.backfill_historical_epoch(VibeGroupEpoch(2), key(8)),
            Err(VibeGroupError::EpochNotMonotone)
        );
    }

    #[test]
    fn retention_is_bounded() {
        let mut ring = VibeGroupKeyring::new();
        for epoch in 0..(VIBE_GROUP_EPOCH_RETENTION as u32 + 25) {
            ring.install_epoch(VibeGroupEpoch(epoch), key(1)).unwrap();
        }
        assert_eq!(ring.len(), VIBE_GROUP_EPOCH_RETENTION);
        // The newest survive; the oldest are the ones evicted.
        assert!(ring.has_epoch(VibeGroupEpoch(VIBE_GROUP_EPOCH_RETENTION as u32 + 24)));
        assert!(!ring.has_epoch(VibeGroupEpoch(0)));
    }

    #[test]
    fn malformed_input_never_panics() {
        for raw in [
            "",
            "vgrp2.",
            "vgrp2..",
            "vgrp2...",
            "vgrp2.a.b.c",
            "vgrp2.####.####.####",
            "vgrp2.AAAAAA.AAAA.AAAA",   // wrong epoch width
            "vgrp2.AAAAAAA=.AAAA.AAAA", // short iv
            "arte1.a.b.c",
            "{\"iv\":\"x\"}",
            "plain text",
        ] {
            let _ = parse_group_envelope(raw);
        }
    }

    #[test]
    fn a_short_ciphertext_is_malformed_not_a_panic() {
        let short = format!(
            "{VIBE_GROUP_SEALED_PREFIX}{}.{}.{}",
            B64.encode(0u32.to_le_bytes()),
            B64.encode([0u8; VIBE_NONCE_LEN]),
            B64.encode([0u8; VIBE_TAG_LEN - 1])
        );
        assert_eq!(parse_group_envelope(&short), Err(VibeGroupError::Malformed));
    }

    #[test]
    fn the_keyring_debug_never_prints_key_material() {
        let ring = keyring_with(&[(0, 0xAB), (1, 0xCD)]);
        let rendered = format!("{ring:?}");
        assert!(rendered.contains("epochs"));
        assert!(!rendered.contains("ab") && !rendered.contains("AB"));
        assert!(!rendered.contains("cd") && !rendered.contains("CD"));
    }

    #[test]
    #[cfg(feature = "aead-aes-gcm")]
    fn a_group_envelope_is_not_mistaken_for_a_hybrid_one() {
        // The reserved `g` slot stays untouched by this module: a group message
        // must never classify as the hybrid envelope, or a deployed client
        // would try RSA candidates against it.
        let provider = default_aead_provider();
        let ring = keyring_with(&[(0, 1)]);
        let auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch::GENESIS, 2, 2).unwrap();
        let sealed = seal_group(provider.as_ref(), &ring, "g", auth, b"x").unwrap();
        assert_eq!(
            crate::envelope::classify(&sealed),
            crate::envelope::VibeEnvelopeFormat::Unrecognized
        );
    }

    #[test]
    fn a_build_with_no_aead_provider_fails_closed_rather_than_leaking() {
        // Runs in *both* feature configurations on purpose. The property that
        // matters is not "AES-GCM works" but "a build with no algorithm refuses
        // rather than emitting something plaintext-shaped". A group seal that
        // silently degraded would put a readable body on the wire under a name
        // that claims encryption.
        let provider = crate::crypto::VibeDenyAllAead;
        let ring = keyring_with(&[(0, 1)]);
        let auth =
            VibeGroupSealAuthorization::all_members_capable(VibeGroupEpoch::GENESIS, 2, 2).unwrap();

        assert!(matches!(
            seal_group(&provider, &ring, "g", auth, b"top secret"),
            Err(VibeGroupError::Crypto(VibeCryptoError::ProviderUnavailable))
        ));

        // And opening is refused the same way — never a partial or "best effort"
        // plaintext.
        let well_formed = format!(
            "{VIBE_GROUP_SEALED_PREFIX}{}.{}.{}",
            B64.encode(0u32.to_le_bytes()),
            B64.encode([7u8; VIBE_NONCE_LEN]),
            B64.encode([9u8; VIBE_TAG_LEN + 4])
        );
        assert!(matches!(
            open_group(&provider, &ring, "g", &well_formed),
            Err(VibeGroupError::Crypto(VibeCryptoError::ProviderUnavailable))
        ));
    }

    #[test]
    fn parsing_is_available_even_without_a_crypto_provider() {
        // A client that cannot *open* a group message must still be able to
        // recognise one, so it can render "you need to update" instead of
        // treating the ciphertext as message text.
        let well_formed = format!(
            "{VIBE_GROUP_SEALED_PREFIX}{}.{}.{}",
            B64.encode(42u32.to_le_bytes()),
            B64.encode([1u8; VIBE_NONCE_LEN]),
            B64.encode([2u8; VIBE_TAG_LEN + 1])
        );
        assert!(is_group_envelope(&well_formed));
        let parsed = parse_group_envelope(&well_formed).expect("parses without a provider");
        assert_eq!(parsed.epoch, VibeGroupEpoch(42));
    }
}
