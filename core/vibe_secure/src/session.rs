//! MLS group sessions.
//!
//! A DM is a two-member group — there is no separate 1:1 path here. Every
//! operation below is exactly what a group of two, three, or three thousand
//! members does; the only thing that makes a DM special is that nobody ever
//! calls [`VibeSecureSession::add_members`] a second time.
//!
//! # Commit handling, and what this crate does not yet do
//!
//! [`VibeSecureSession::add_members`] both produces the Commit/Welcome pair
//! *and* merges the commit into the caller's own group state, so the caller
//! who added a member is immediately in the new epoch. What this crate does
//! **not** yet expose is a way for the *other already-present* members to
//! process an incoming Commit and advance in step — that needs an ordered
//! delivery service (see `docs/secure-core-architecture.md` §4, "ordered
//! commit fan-out"), which is server work, not a gap in this API. A new
//! member always joins through [`VibeSecureSession::join_from_welcome`],
//! which needs no Commit at all.
//!
//! # Every call that touches bytes from outside this device is panic-caught
//!
//! OpenMLS 0.8.1 has at least one `debug_assert!` on its ciphertext-AEAD
//! failure path (`private_message_in.rs`, in `PrivateMessageIn::decrypt`) --
//! compiled out in `--release`, but live in `dev`/`test` profiles, where it
//! panics *before* the clean `Err` it was about to construct is returned.
//! Verified directly: a deliberately corrupted `vmls1.` envelope panicked
//! `open()` without a guard, under a plain `cargo test`. This crate's entire
//! job is turning untrusted network bytes into either validated data or an
//! error -- never a crash -- for a stronger reason than tidiness: an unwind
//! that crosses the eventual FFI boundary into Swift is a defined **abort**
//! (Rust has guaranteed this since 1.71, rather than leaving it undefined),
//! and `core/Cargo.toml` states the workspace rule plainly: "never abort: a
//! core panic must degrade to the Swift path, not kill the host." So every
//! call into OpenMLS that processes peer-supplied bytes is panic-guarded,
//! rather than trusting that today's dependency version (or a future one)
//! never panics on adversarial input.
//!
//! That guarding comes in two different strengths, because a caught panic is
//! not always equally safe to walk away from:
//!
//! - [`catch_untrusted`] is for a call that touches **no state that survives
//!   it** -- a constructor that has not yet produced a `Self`, or a
//!   validation step over an owned, local value. A caught panic there is
//!   exactly as safe as the `Result::Err` it stands in for, because there is
//!   nothing left half-mutated for a later call to inherit.
//! - [`VibeSecureSession::with_group`] is for a call that runs with `&mut`
//!   access to this session's live `MlsGroup` -- shared, mutable, ratcheting
//!   state that persists across calls. A caught panic there does not return
//!   the ordinary error; it poisons the session instead. See that method's
//!   doc for why a plain retryable error is the wrong shape for that case.

use openmls::prelude::tls_codec::{DeserializeBytes as _, Serialize as _};
use openmls::prelude::*;
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::envelope;
use crate::error::VibeSecureError;
use crate::identity::{VibeDeviceIdentity, VibeKeyPackageBundle};
use crate::VIBE_SECURE_CIPHERSUITE;

/// Runs `f`, converting a panic into `on_panic` instead of letting it unwind.
///
/// Sound only where a caught panic leaves nothing observable behind. Every
/// call site below either has not yet produced the `Self` it would poison, or
/// touches only an owned, local value with no shared state in reach --
/// mirroring the argument `vibe_core_ffi::unwrap` makes for its own
/// `AssertUnwindSafe`: "nothing observable is left half-written by a panic
/// here." Do not reach for this where `f` has `&mut` access to
/// [`VibeSecureSession`]'s group -- that is [`VibeSecureSession::with_group`],
/// deliberately a different function with a different failure mode.
pub(crate) fn catch_untrusted<T>(
    on_panic: VibeSecureError,
    f: impl FnOnce() -> T,
) -> Result<T, VibeSecureError> {
    catch_unwind(AssertUnwindSafe(f)).map_err(|_| on_panic)
}

/// One MLS group session, wrapping an [`MlsGroup`].
///
/// No `Debug`, no `Clone`: this holds live ratchet secrets, and the crate's
/// one deliverable is that nothing here is ever printable or duplicable by
/// accident.
pub struct VibeSecureSession {
    group: MlsGroup,
    /// Set once, never cleared. See [`Self::with_group`].
    poisoned: bool,
}

/// The two messages produced by [`VibeSecureSession::add_members`].
///
/// `commit` goes to every already-present member; `welcome` goes only to the
/// member(s) just added. Neither is meaningful without the other reaching its
/// audience, but they do not share a delivery path — the commit rides the
/// group, the welcome is addressed to the joiner(s) alone.
pub struct VibeCommitOutput {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}

/// Cleartext MLS header from a `vmls1.` envelope. Not an open — no AEAD, no secrets.
pub struct VibeMlsEnvelopeHeader {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    /// `app`, `commit`, or `proposal`.
    pub content: &'static str,
}

impl VibeSecureSession {
    /// Creates a brand-new group with `identity` as its only member.
    pub fn create(
        identity: &VibeDeviceIdentity,
        provider: &impl OpenMlsProvider,
    ) -> Result<Self, VibeSecureError> {
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(VIBE_SECURE_CIPHERSUITE)
            .build();
        let group = MlsGroup::new(
            provider,
            identity.signer(),
            &config,
            identity.credential_with_key(),
        )
        .map_err(|_| VibeSecureError::GroupCreate)?;
        Ok(Self {
            group,
            poisoned: false,
        })
    }

    /// Reloads a group previously persisted by this provider.
    ///
    /// `Ok(None)` means "no such group in this store" — a normal answer, not a
    /// failure: a fresh install, or a chat that has never been established, both
    /// land here and the caller establishes instead.
    ///
    /// This is what makes the SQLite provider actually reachable. Without it a
    /// relaunch can only ever `create` or `join_from_welcome`, so persisted
    /// ratchet state would sit on disk unused while the app minted a brand-new
    /// group — and every message sealed before the relaunch would be
    /// unreadable.
    pub fn load(
        group_id: &[u8],
        provider: &impl OpenMlsProvider,
    ) -> Result<Option<Self>, VibeSecureError> {
        let id = GroupId::from_slice(group_id);
        match MlsGroup::load(provider.storage(), &id) {
            Ok(Some(group)) => Ok(Some(Self {
                group,
                poisoned: false,
            })),
            Ok(None) => Ok(None),
            Err(_) => Err(VibeSecureError::Storage),
        }
    }

    /// Reads the MLS group id from a `vmls1.` header without opening the message.
    /// The id is in the clear on every PrivateMessage; used to rebind a dropped chat mapping.
    pub fn group_id_from_envelope(envelope: &str) -> Result<Vec<u8>, VibeSecureError> {
        Ok(Self::envelope_header(envelope)?.group_id)
    }

    /// Group id, epoch, and content type from a `vmls1.` header. Does not open the AEAD.
    pub fn envelope_header(envelope: &str) -> Result<VibeMlsEnvelopeHeader, VibeSecureError> {
        catch_untrusted(VibeSecureError::MalformedEnvelope, || {
            let bytes = envelope::unwrap(envelope)?;
            let message_in = MlsMessageIn::tls_deserialize_exact_bytes(&bytes)
                .map_err(|_| VibeSecureError::MalformedEnvelope)?;
            let protocol_message = message_in
                .try_into_protocol_message()
                .map_err(|_| VibeSecureError::MalformedEnvelope)?;
            let content = match protocol_message.content_type() {
                ContentType::Application => "app",
                ContentType::Proposal => "proposal",
                ContentType::Commit => "commit",
            };
            Ok::<VibeMlsEnvelopeHeader, VibeSecureError>(VibeMlsEnvelopeHeader {
                group_id: protocol_message.group_id().as_slice().to_vec(),
                epoch: protocol_message.epoch().as_u64(),
                content,
            })
        })?
    }

    /// The group's id, which is how it is addressed in storage.
    ///
    /// The platform persists its own `chat id -> group id` mapping; this crate
    /// deliberately holds no such table, because a chat is a product concept and
    /// this crate has no opinion about them.
    pub fn group_id(&self) -> Vec<u8> {
        self.group.group_id().as_slice().to_vec()
    }

    pub fn epoch(&self) -> u64 {
        self.group.epoch().as_u64()
    }

    pub fn has_pending_commit(&self) -> bool {
        self.group.pending_commit().is_some()
    }

    /// Signature keys of every member but this device, read from the group's own
    /// ratchet tree — the only copy a hostile server cannot substitute.
    pub fn peer_signature_keys(&self) -> Vec<Vec<u8>> {
        let me = self.group.own_leaf_index();
        self.group
            .members()
            .filter(|member| member.index != me)
            .map(|member| member.signature_key)
            .collect()
    }

    /// Joins a group from a Welcome message, as produced by
    /// [`VibeCommitOutput::welcome`].
    ///
    /// `ratchet_tree` should be [`VibeSecureSession::export_ratchet_tree`]
    /// from a current member, sent alongside the welcome out of band (the
    /// `use_ratchet_tree_extension` server-side option is not assumed). This
    /// call finds its own private key material in `provider`'s key store —
    /// it was stored there by whichever earlier call to
    /// [`VibeDeviceIdentity::key_package`] published the `KeyPackage` this
    /// welcome targets — so it takes no `identity` parameter.
    ///
    /// This is a constructor: a caught panic here never poisons anything,
    /// because there is no `Self` yet for it to poison. Either this returns a
    /// fresh, healthy session, or it returns an error and no session at all.
    pub fn join_from_welcome(
        welcome_bytes: &[u8],
        ratchet_tree: Option<&[u8]>,
        provider: &impl OpenMlsProvider,
    ) -> Result<Self, VibeSecureError> {
        let welcome_msg = MlsMessageIn::tls_deserialize_exact_bytes(welcome_bytes)
            .map_err(|_| VibeSecureError::MalformedEnvelope)?;
        let MlsMessageBodyIn::Welcome(welcome) = welcome_msg.extract() else {
            return Err(VibeSecureError::MalformedEnvelope);
        };

        let ratchet_tree_in = ratchet_tree
            .map(RatchetTreeIn::tls_deserialize_exact_bytes)
            .transpose()
            .map_err(|_| VibeSecureError::MalformedEnvelope)?;

        let group = catch_untrusted(VibeSecureError::GroupJoin, || {
            StagedWelcome::new_from_welcome(
                provider,
                &MlsGroupJoinConfig::default(),
                welcome,
                ratchet_tree_in,
            )
            .map_err(|_| VibeSecureError::GroupJoin)?
            .into_group(provider)
            .map_err(|_| VibeSecureError::GroupJoin)
        })??;

        Ok(Self {
            group,
            poisoned: false,
        })
    }

    /// Adds one or more members, publishes the resulting epoch to the caller
    /// immediately, and returns the Commit/Welcome pair to distribute.
    ///
    /// Every `key_packages` entry is parsed and its signature verified before
    /// anything is committed — a `VibeKeyPackageBundle` obtained from the
    /// server is untrusted input until this validates it. That validation
    /// touches no group state (it is a check against an owned, local
    /// `KeyPackageIn` and the provider's crypto backend), so a caught panic
    /// there is handled by [`catch_untrusted`]; committing the add runs
    /// through [`Self::with_group`] instead, because it is the step that
    /// mutates this session's live group.
    pub fn add_members(
        &mut self,
        identity: &VibeDeviceIdentity,
        key_packages: &[VibeKeyPackageBundle],
        provider: &impl OpenMlsProvider,
    ) -> Result<VibeCommitOutput, VibeSecureError> {
        let mut validated = Vec::with_capacity(key_packages.len());
        for bundle in key_packages {
            let key_package_in = KeyPackageIn::tls_deserialize_exact_bytes(bundle.as_bytes())
                .map_err(|_| VibeSecureError::MemberAdd)?;
            let key_package = catch_untrusted(VibeSecureError::MemberAdd, || {
                key_package_in.validate(provider.crypto(), ProtocolVersion::Mls10)
            })?
            .map_err(|_| VibeSecureError::MemberAdd)?;
            if key_package.ciphersuite() != VIBE_SECURE_CIPHERSUITE {
                return Err(VibeSecureError::UnsupportedCiphersuite);
            }
            validated.push(key_package);
        }

        let (commit_bytes, welcome_bytes) = self.with_group(|group| {
            let (commit, welcome, _group_info) = group
                .add_members(provider, identity.signer(), &validated)
                .map_err(|_| VibeSecureError::MemberAdd)?;

            // The committer adopts the new epoch immediately. Already-present
            // members advance when the platform's delivery service fans the
            // commit out to them (see the module doc); the newly added
            // member(s) never need it at all, because the welcome already
            // encodes the post-add state.
            group
                .merge_pending_commit(provider)
                .map_err(|_| VibeSecureError::MemberAdd)?;

            let commit_bytes = commit
                .tls_serialize_detached()
                .map_err(|_| VibeSecureError::MemberAdd)?;
            let welcome_bytes = welcome
                .tls_serialize_detached()
                .map_err(|_| VibeSecureError::MemberAdd)?;
            Ok((commit_bytes, welcome_bytes))
        })?;

        Ok(VibeCommitOutput {
            commit: commit_bytes,
            welcome: welcome_bytes,
        })
    }

    /// Seals `plaintext` for the group's current epoch as a `vmls1.` string.
    ///
    /// The plaintext is padded to a bucket boundary first. AEAD ciphertext is
    /// the same length as its input, so without this the envelope's size
    /// leaks the message's size to anyone watching the wire — enough to tell
    /// "ok" from a paragraph, and to fingerprint a forwarded file. Padding
    /// here rather than at the call site is deliberate: `open` unpads, so the
    /// two can never be wired up inconsistently by a future caller.
    pub fn seal(
        &mut self,
        identity: &VibeDeviceIdentity,
        plaintext: &[u8],
        provider: &impl OpenMlsProvider,
    ) -> Result<String, VibeSecureError> {
        let padded = crate::padding::vibe_pad(plaintext);
        let bytes = self.with_group(|group| {
            let message_out = group
                .create_message(provider, identity.signer(), &padded)
                .map_err(|_| VibeSecureError::Seal)?;
            message_out
                .tls_serialize_detached()
                .map_err(|_| VibeSecureError::Seal)
        })?;
        envelope::wrap(&bytes)
    }

    /// Opens a `vmls1.` envelope and returns the plaintext it carries.
    ///
    /// Every failure — malformed envelope, wrong session, tampered
    /// ciphertext, a party that was never a member — collapses to
    /// [`VibeSecureError::Open`], with one exception: a caught panic reports
    /// [`VibeSecureError::SessionPoisoned`] instead, because at that point
    /// `Open` (which invites "try again") would be the wrong signal. See
    /// `error.rs` for why the ordinary case has no finer-grained reason, and
    /// [`Self::with_group`] for why the panic case is deliberately different.
    pub fn open(
        &mut self,
        envelope: &str,
        provider: &impl OpenMlsProvider,
    ) -> Result<Vec<u8>, VibeSecureError> {
        let bytes = crate::envelope::unwrap(envelope)?;
        let message_in = MlsMessageIn::tls_deserialize_exact_bytes(&bytes)
            .map_err(|_| VibeSecureError::Open)?;
        let protocol_message = message_in
            .try_into_protocol_message()
            .map_err(|_| VibeSecureError::Open)?;

        // A crash between `add_members` and `merge_pending_commit` leaves the
        // committer PendingCommit at epoch N while the joiner already lives at N+1.
        if self.group.pending_commit().is_some() {
            self.with_group(|group| {
                group
                    .merge_pending_commit(provider)
                    .map_err(|_| VibeSecureError::Open)
            })?;
        }

        let processed = self.with_group(|group| {
            group
                .process_message(provider, protocol_message)
                .map_err(|_| VibeSecureError::Open)
        })?;

        match processed.into_content() {
            // Unpad here, mirroring `seal`. A malformed length prefix is
            // reported as an ordinary `Open` failure rather than its own
            // variant: the bytes only got this far because they authenticated
            // under the group key, so a bad prefix means corruption by a
            // legitimate sender, and the caller's options are identical
            // either way.
            ProcessedMessageContent::ApplicationMessage(app) => {
                crate::padding::vibe_unpad(&app.into_bytes()).map_err(|_| VibeSecureError::Open)
            }
            // A commit, proposal, or external-join proposal has no plaintext
            // to hand back through this call. Callers do not yet have a way
            // to feed those in (see the module doc), so reaching this arm
            // today means the envelope was not what `open` expects.
            _ => Err(VibeSecureError::Open),
        }
    }

    /// Serializes the current ratchet tree, to be sent alongside a welcome so
    /// the joiner can build the group's member tree without a directory
    /// service.
    ///
    /// Not gated on [`Self::poisoned`]: this only serializes already-in-memory
    /// public tree topology (no decryption, no signing, no ratchet
    /// advancement), and its signature is frozen infallible, so there is
    /// nowhere to surface `SessionPoisoned` even if it were needed. A
    /// poisoned session's exported tree is, at worst, stale, not a
    /// cryptographic hazard.
    pub fn export_ratchet_tree(&self) -> Vec<u8> {
        self.group
            .export_ratchet_tree()
            .tls_serialize_detached()
            .expect("serializing this session's own in-memory ratchet tree cannot fail")
    }

    /// Runs `f` with exclusive `&mut` access to this session's group,
    /// refusing up front if the session is already poisoned, and poisoning
    /// it if `f` panics.
    ///
    /// # Why this cannot reuse [`catch_untrusted`]'s soundness argument
    ///
    /// `catch_untrusted`'s `AssertUnwindSafe` is sound where nothing
    /// observable survives a caught panic. This method is for the opposite
    /// case on purpose: `f` runs with `&mut` access to `self.group`, which
    /// **is** shared, mutable state that outlives the call. OpenMLS's decrypt
    /// path derives -- and deletes -- a generation's ratchet key *before*
    /// attempting to use it, specifically so a skipped or failed generation
    /// cannot be replayed; that means a panic partway through a group
    /// operation can leave that deletion applied with no corresponding record
    /// of what else did or did not complete. Catching the panic and handing
    /// back the operation's ordinary, retryable error would tell a caller
    /// "that attempt failed, try again" over a group whose ratchet state this
    /// crate can no longer vouch for. Retrying a ratchet in an unproven state
    /// is exactly the class of mistake that ends in a reused key or nonce --
    /// for an AEAD cipher, a strictly worse outcome than the crash this whole
    /// mechanism exists to prevent. So a caught panic here does not return
    /// `f`'s error type at all: it poisons the session and reports
    /// [`VibeSecureError::SessionPoisoned`], and every subsequent call
    /// through this method refuses immediately, without touching the group.
    /// There is no unpoison. A poisoned session must be discarded.
    fn with_group<T>(
        &mut self,
        f: impl FnOnce(&mut MlsGroup) -> Result<T, VibeSecureError>,
    ) -> Result<T, VibeSecureError> {
        if self.poisoned {
            return Err(VibeSecureError::SessionPoisoned);
        }
        match catch_unwind(AssertUnwindSafe(|| f(&mut self.group))) {
            Ok(result) => result,
            Err(_panic) => {
                self.poisoned = true;
                Err(VibeSecureError::SessionPoisoned)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::OpenMlsRustCrypto;

    /// A caught panic latches, and every later group operation refuses.
    ///
    /// This is a **unit** test rather than one in `tests/`, for two reasons that
    /// both matter. `poisoned` and [`VibeSecureSession::with_group`] are
    /// private — the poisoning contract is internal, so only a unit test can
    /// observe it directly. And the one panic known to occur in practice
    /// (OpenMLS's `debug_assert!` at `private_message_in.rs:136`) is compiled
    /// out under `--release`, so a test that reached poisoning *through* that
    /// panic would silently stop testing anything in the profile we ship.
    /// Panicking deliberately inside `with_group` exercises the guarantee in
    /// both profiles.
    #[test]
    fn a_caught_panic_poisons_the_session_and_every_later_call_refuses() {
        let provider = OpenMlsRustCrypto::default();
        let identity = VibeDeviceIdentity::generate("alice-device-1", &provider)
            .expect("identity generates");
        let mut session = VibeSecureSession::create(&identity, &provider).expect("group creates");
        assert!(!session.poisoned, "a fresh session is not poisoned");

        // Sealed *before* poisoning, so the later `open` reaches the poison
        // check instead of bailing out earlier on envelope parsing — `open`
        // decodes the envelope before it ever touches the group.
        let envelope = session
            .seal(&identity, b"sealed while healthy", &provider)
            .expect("seal succeeds while healthy");

        let caught = session.with_group(|_group| -> Result<(), VibeSecureError> {
            panic!("simulated panic from inside the MLS implementation")
        });
        assert_eq!(caught.unwrap_err(), VibeSecureError::SessionPoisoned);
        assert!(session.poisoned, "the catch must latch, not just report");

        // The point of the latch: after a panic that may have fired mid-mutation
        // we cannot prove the ratchet is intact, so reuse has to be refused
        // outright. Returning a retryable error here would invite a caller to
        // drive a half-advanced chain, which is how key and nonce reuse happen.
        assert_eq!(
            session
                .seal(&identity, b"after the panic", &provider)
                .unwrap_err(),
            VibeSecureError::SessionPoisoned,
            "seal must refuse a poisoned session"
        );
        assert_eq!(
            session.open(&envelope, &provider).unwrap_err(),
            VibeSecureError::SessionPoisoned,
            "open must refuse a poisoned session"
        );
    }

    /// Poisoning is reported as itself, never collapsed into the generic
    /// `Open`/`Seal` errors — those invite a retry, and a retry is exactly what
    /// must not happen here.
    #[test]
    fn poisoned_is_distinguishable_from_an_ordinary_failure() {
        assert_ne!(VibeSecureError::SessionPoisoned, VibeSecureError::Open);
        assert_ne!(VibeSecureError::SessionPoisoned, VibeSecureError::Seal);
    }
}
