//! FFI boundary for [`vibe_core::group`], the epoch-key layer that covers what
//! MLS cannot.
//!
//! # Why there are two encryption layers and not one
//!
//! MLS ([`crate::secure`]) is the right answer for DMs and ordinary groups, and
//! it is what those use. It cannot cover two cases:
//!
//! * **Channels.** A member joining an MLS group cannot read anything sent
//!   before they joined — that is a deliberate MLS property (forward secrecy),
//!   and it is precisely wrong for a broadcast channel, where the entire point
//!   is that someone who subscribes today can read the backlog.
//! * **Groups past the member cap.** Adding N members to an MLS group is an
//!   O(N) tree operation with an O(N) Welcome fan-out, and the cap exists
//!   because past it the join cost stops being acceptable on a phone.
//!
//! Epoch keys handle both: history is readable by anyone *given* the older
//! epoch key ([`VibeGroupKeyringHandle::backfill_epoch`]), and adding a member
//! costs one key delivery rather than a tree operation.
//!
//! The two layers never overlap. A chat is MLS **or** epoch-keyed, decided by
//! kind and size, and the envelope prefix (`vmls1.` vs `vgrp2.`) says which so a
//! reader never has to guess.
//!
//! # What this boundary deliberately does not do
//!
//! **It does not distribute keys.** Minting is [`vibe_group_mint_epoch_key`],
//! and what happens to those 32 bytes next is the platform's problem — they ride
//! the per-member channel that already exists and already works. Putting
//! distribution here would mean putting network and identity into a crate whose
//! entire value is that it is pure and testable.
//!
//! **It does not decide who is allowed to read.** [`VibeGroupKeyringHandle::seal`]
//! demands a membership count and a capability count and refuses unless they
//! match, because turning group encryption on for a group where one member's
//! client does not understand `vgrp2.` does not weaken that member — it silently
//! removes them from the conversation, which is worse and is not recoverable
//! after the fact.
//!
//! # Threading
//!
//! One keyring per group, behind a `Mutex`, for the same reason the MLS session
//! is: installs mutate and must not interleave. A poisoned lock is reported
//! rather than unwrapped — this crate degrades, it never aborts the host app.

use std::sync::Mutex;

use vibe_core::crypto::default_aead_provider;
use vibe_core::group::{
    is_group_envelope, mint_epoch_key, open_group, parse_group_envelope, seal_group,
    VibeGroupEpoch, VibeGroupKeyring, VibeGroupSealAuthorization, VIBE_GROUP_EPOCH_RETENTION,
};
use vibe_core::secret::VibeSecretKey;

use crate::VibeFfiError;

/// Number of epoch keys one keyring retains, exposed so the platform can size
/// its own persistence to match rather than guessing.
#[uniffi::export]
pub fn vibe_group_epoch_retention() -> u32 {
    VIBE_GROUP_EPOCH_RETENTION as u32
}

/// True when `raw` is a group envelope this layer can open.
///
/// A cheap prefix test so the message pipeline can route without allocating or
/// parsing — the same shape as the `vmls1.` check next door.
#[uniffi::export]
pub fn vibe_group_is_envelope(raw: String) -> bool {
    is_group_envelope(&raw)
}

/// The epoch a group envelope names, or `None` when it is not parseable.
///
/// Exists so a client holding the *wrong* keys can tell the platform exactly
/// which epoch to go fetch, instead of the platform having to re-request
/// everything or the row staying unreadable forever. Reads the header only; it
/// never touches the ciphertext and never needs a key.
#[uniffi::export]
pub fn vibe_group_envelope_epoch(raw: String) -> Option<u32> {
    parse_group_envelope(&raw).ok().map(|e| e.epoch.0)
}

/// Mints a fresh epoch key from the OS CSPRNG.
///
/// Returns raw key material — the **one** place in this boundary that does, and
/// only because the device minting an epoch is the device that must hand it to
/// every member. The caller's obligation is to deliver it over an already
/// end-to-end-encrypted channel and to persist it somewhere only this device can
/// read. Everything after that point is write-only: the keyring takes keys and
/// never gives them back.
#[uniffi::export]
pub fn vibe_group_mint_epoch_key() -> Result<Vec<u8>, VibeFfiError> {
    mint_epoch_key()
        .map(|bytes| bytes.to_vec())
        .map_err(|e| VibeFfiError::Internal {
            detail: format!("group: {e}"),
        })
}

/// The epoch keys this device holds for one group.
///
/// Bound to a single `group_id` at construction and never retargeted: the group
/// id is authenticated data on every seal, so a keyring pointed at the wrong
/// group does not silently decrypt the wrong thing — it fails, which is correct
/// but is a failure that need never happen.
#[derive(uniffi::Object)]
pub struct VibeGroupKeyringHandle {
    group_id: String,
    keyring: Mutex<VibeGroupKeyring>,
}

#[uniffi::export]
impl VibeGroupKeyringHandle {
    /// A keyring for `group_id`, holding nothing yet.
    #[uniffi::constructor]
    pub fn new(group_id: String) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            group_id,
            keyring: Mutex::new(VibeGroupKeyring::new()),
        })
    }

    /// Installs the key for a **strictly newer** epoch.
    ///
    /// Refusing an equal or older epoch is the anti-rollback rule: without it a
    /// replayed membership frame could walk a group back onto a key a removed
    /// member still holds, and removal would mean nothing.
    pub fn install_epoch(&self, epoch: u32, key: Vec<u8>) -> Result<(), VibeFfiError> {
        let secret = Self::secret_from(key)?;
        self.locked()?
            .install_epoch(VibeGroupEpoch(epoch), secret)
            .map_err(map_group_err)
    }

    /// Installs a key for an epoch **older** than the newest held, so history
    /// handed to a new member becomes readable.
    ///
    /// Named separately from [`Self::install_epoch`] on purpose. This is the one
    /// operation that legitimately moves backwards, so it cannot be reached by a
    /// frame that merely looks like a rotation.
    pub fn backfill_epoch(&self, epoch: u32, key: Vec<u8>) -> Result<(), VibeFfiError> {
        let secret = Self::secret_from(key)?;
        self.locked()?
            .backfill_historical_epoch(VibeGroupEpoch(epoch), secret)
            .map_err(map_group_err)
    }

    /// The highest epoch held, or `None` when this device has no key for the
    /// group at all — which is the signal to go ask for one before sending.
    pub fn newest_epoch(&self) -> Result<Option<u32>, VibeFfiError> {
        Ok(self.locked()?.newest_epoch().map(|e| e.0))
    }

    pub fn has_epoch(&self, epoch: u32) -> Result<bool, VibeFfiError> {
        Ok(self.locked()?.has_epoch(VibeGroupEpoch(epoch)))
    }

    pub fn epoch_count(&self) -> Result<u32, VibeFfiError> {
        Ok(self.locked()?.len() as u32)
    }

    /// Seals under the newest held epoch, but only if every member can read it.
    ///
    /// `total_members` and `capable_members` are passed rather than inferred
    /// because this layer cannot see the roster. They are checked by
    /// `VibeGroupSealAuthorization`, which has no constructor that skips the
    /// check — so "seal only when everyone can read" is enforced by the type
    /// system rather than by remembering to write an `if` at each call site.
    ///
    /// A group with zero known members is refused rather than treated as
    /// vacuously fine: an empty roster is far more likely to be a failed fetch
    /// than a real empty group, and encrypting to nobody is not a safe default.
    pub fn seal(
        &self,
        total_members: u32,
        capable_members: u32,
        plaintext: Vec<u8>,
    ) -> Result<String, VibeFfiError> {
        let keyring = self.locked()?;
        let epoch = keyring.newest_epoch().ok_or(VibeFfiError::Internal {
            detail: "group: no epoch key held".to_string(),
        })?;
        let authorization =
            VibeGroupSealAuthorization::all_members_capable(epoch, total_members, capable_members)
                .ok_or(VibeFfiError::Internal {
                    detail: "group: not every member can read this format".to_string(),
                })?;
        seal_group(
            default_aead_provider().as_ref(),
            &keyring,
            &self.group_id,
            authorization,
            &plaintext,
        )
        .map_err(map_group_err)
    }

    /// Opens an envelope under whichever epoch it names.
    ///
    /// Fails — rather than returning empty — when the epoch key is absent, so
    /// the caller can tell "I need epoch 3" apart from "this message is empty",
    /// and show the row as undecryptable instead of as a blank bubble.
    pub fn open(&self, envelope: String) -> Result<Vec<u8>, VibeFfiError> {
        let keyring = self.locked()?;
        open_group(
            default_aead_provider().as_ref(),
            &keyring,
            &self.group_id,
            &envelope,
        )
        .map(|plaintext| plaintext.as_bytes().to_vec())
        .map_err(map_group_err)
    }
}

impl VibeGroupKeyringHandle {
    fn locked(&self) -> Result<std::sync::MutexGuard<'_, VibeGroupKeyring>, VibeFfiError> {
        self.keyring.lock().map_err(|_| VibeFfiError::Internal {
            detail: "group: keyring lock poisoned".to_string(),
        })
    }

    /// Rejects any key that is not exactly [`VIBE_KEY_LEN`].
    ///
    /// The length is reported, the bytes never are.
    fn secret_from(key: Vec<u8>) -> Result<VibeSecretKey, VibeFfiError> {
        VibeSecretKey::from_slice(&key).map_err(|e| VibeFfiError::Internal {
            detail: format!("group: {e}"),
        })
    }
}

/// Maps a group error to the FFI error type.
///
/// Every variant collapses to `Internal` carrying the core's own `Display`,
/// which is free of key material, group ids and ciphertext by construction —
/// including, deliberately, the distinction between a wrong key and a tampered
/// ciphertext.
fn map_group_err(error: vibe_core::group::VibeGroupError) -> VibeFfiError {
    VibeFfiError::Internal {
        detail: format!("group: {error}"),
    }
}
