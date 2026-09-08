//! FFI boundary for [`vibe_secure`], the MLS session layer.
//!
//! # Status: linked and callable, deliberately not yet wired into messaging
//!
//! This module exists so the MLS crate is compiled into the XCFramework and
//! reachable from Swift. It is **not** yet on the send/receive path, and it must
//! not be put there until two things exist that do not exist today:
//!
//! * **Server-side KeyPackage distribution.** A device cannot be added to a
//!   group until its KeyPackage can be published and fetched. Until then
//!   [`VibeSecureIdentityHandle::key_package`] produces bytes with nowhere to go.
//! * **Persistent group state.** The provider here is
//!   `OpenMlsRustCrypto::default()`, which keeps ratchet state **in memory
//!   only**. A session created through this API does not survive app restart, so
//!   sealing real user messages under it would lose history at the next launch.
//!   The durable answer is OpenMLS's `StorageProvider` implemented over
//!   `vibe_core_store`'s sealed SQLite — see docs/secure-core-architecture.md §4.
//!
//! Both limitations are stated here rather than in a ticket because this is the
//! file someone will reach for when they want to "just start using MLS".
//!
//! # Threading
//!
//! `VibeSecureSession`'s methods take `&mut self`; a uniffi object is shared as
//! `Arc<Self>` and its methods take `&self`. The session is therefore behind a
//! `Mutex`. A poisoned lock is reported as [`VibeFfiError::Internal`] rather than
//! unwrapped — the crate's whole posture is that a panic degrades, never aborts.

use std::sync::{Arc, Mutex};

use vibe_secure::{
    VibeDeviceIdentity, VibeKeyPackageBundle, VibeSecureError, VibeSecureProvider,
    VibeSecureSession,
};

use crate::VibeFfiError;

/// Maps a `vibe_secure` error to the FFI error type.
///
/// Every variant collapses to `Internal` with the crate's own opaque `Display`,
/// which is already free of key material and plaintext by construction. The one
/// that is *not* interchangeable is `SessionPoisoned`: it means the session must
/// be discarded rather than retried, so it keeps a distinguishable message.
fn map_err(error: &VibeSecureError) -> VibeFfiError {
    VibeFfiError::Internal {
        detail: format!("secure: {error}"),
    }
}

/// One device's MLS identity, plus the provider that holds its key material.
///
/// The provider is owned here and never handed out. A session built from this
/// identity must use the *same* provider — the signature keypair was stored in
/// it at generation — which is why [`VibeSecureSessionHandle`] holds an `Arc` of
/// this handle rather than taking a provider of its own.
/// One device's MLS identity and its persistent store.
///
/// The provider is behind a `Mutex` because it owns a `rusqlite::Connection`,
/// which is `Send` but **not** `Sync` — a uniffi object must be both, so access
/// has to be serialized. That is not merely a type-system workaround: a SQLite
/// connection genuinely cannot be used concurrently, and MLS operations mutate
/// ratchet state that must not interleave anyway.
///
/// **Lock order is session-then-provider, everywhere.** Constructors take only
/// the provider. Nothing takes them in the other order, which is what keeps this
/// deadlock-free.
#[derive(uniffi::Object)]
pub struct VibeSecureIdentityHandle {
    provider: Mutex<VibeSecureProvider>,
    identity: VibeDeviceIdentity,
}

impl VibeSecureIdentityHandle {
    fn with_provider<T>(
        &self,
        f: impl FnOnce(&VibeSecureProvider) -> Result<T, VibeSecureError>,
    ) -> Result<T, VibeFfiError> {
        let guard = self.provider.lock().map_err(|_| VibeFfiError::Internal {
            detail: "secure: provider lock poisoned".to_owned(),
        })?;
        f(&guard).map_err(|e| map_err(&e))
    }
}

#[uniffi::export]
impl VibeSecureIdentityHandle {
    /// Generates a device identity backed by the MLS store at `db_path`.
    ///
    /// `device_id` is carried in the MLS credential and is what a safety-number
    /// UI will eventually hash, so it must be stable for the lifetime of the
    /// install — not a per-launch UUID.
    ///
    /// The store is SQLite on disk, so ratchet state survives relaunch. That is
    /// what makes [`VibeSecureSessionHandle::load`] able to return a session at
    /// all, and it is the difference between MLS being usable and being a demo.
    ///
    /// **Platforms must not call this on launch — use [`Self::load_or_generate`].**
    /// A stable `device_id` is not a stable identity; see that constructor.
    #[uniffi::constructor]
    pub fn generate(device_id: String, db_path: String) -> Result<Arc<Self>, VibeFfiError> {
        let provider = VibeSecureProvider::open(&db_path).map_err(|e| map_err(&e))?;
        let identity =
            VibeDeviceIdentity::generate(&device_id, &provider).map_err(|e| map_err(&e))?;
        Ok(Arc::new(Self {
            provider: Mutex::new(provider),
            identity,
        }))
    }

    /// Reopens this device's existing identity, or generates one if
    /// `signature_public_key` is absent or no longer resolves.
    ///
    /// **This is the launch constructor.** `signature_public_key` is what
    /// [`Self::signature_key`] returned last time; the platform persists it and
    /// hands it back. Only the public half crosses — the private key never
    /// leaves the store at `db_path`.
    ///
    /// [`Self::generate`] mints a fresh signing key on every call, and a device
    /// that does that on every launch reloads its groups fine and seals fine
    /// while becoming permanently unreadable to every peer: an application
    /// message is verified against the signing key recorded in the sender's leaf
    /// node, and a new key is not that one. Two devices in the same group, each
    /// unable to open the other, both looking healthy from the inside — that is
    /// the shape this constructor exists to prevent.
    ///
    /// The caller must store [`Self::signature_key`] after **every** call, not
    /// only the first: a restore-from-backup brings the platform's stored
    /// pointer back without the (backup-excluded) key store, so the pointer goes
    /// stale, this falls back to generating, and the stale value has to be
    /// overwritten or the next launch repeats the whole failure.
    #[uniffi::constructor]
    pub fn load_or_generate(
        device_id: String,
        db_path: String,
        signature_public_key: Option<Vec<u8>>,
    ) -> Result<Arc<Self>, VibeFfiError> {
        let provider = VibeSecureProvider::open(&db_path).map_err(|e| map_err(&e))?;
        let identity = VibeDeviceIdentity::load_or_generate(
            &device_id,
            signature_public_key.as_deref(),
            &provider,
        )
        .map_err(|e| map_err(&e))?;
        Ok(Arc::new(Self {
            provider: Mutex::new(provider),
            identity,
        }))
    }

    pub fn device_id(&self) -> String {
        self.identity.device_id().to_string()
    }

    /// Serialized KeyPackage, for publication so a peer can add this device.
    ///
    /// **Single-use.** MLS consumes a KeyPackage's one-time init key when it
    /// adds a member, so every call must produce a fresh one and a published
    /// package must never be handed out twice — the server enforces that with an
    /// atomic claim.
    pub fn key_package(&self) -> Result<Vec<u8>, VibeFfiError> {
        self.with_provider(|provider| {
            self.identity
                .key_package(provider)
                .map(|bundle| bundle.as_bytes().to_vec())
        })
    }

    /// This device's public signature key — our half of a safety number, and
    /// the value peers pin for us.
    pub fn signature_key(&self) -> Vec<u8> {
        self.identity.signature_key()
    }

    /// Reads the identity out of a peer's KeyPackage, validating it first.
    ///
    /// Call this **before** `add_members`. The bytes come from the server,
    /// which is not trusted: an `Ok` here means the KeyPackage is well-formed,
    /// uses the expected ciphersuite, and is self-consistently signed — it does
    /// *not* mean the key belongs to the person you asked for. Comparing
    /// `signatureKey` against what was pinned on first contact is what turns
    /// substitution from an anytime attack into a first-contact-only one, and
    /// the safety number is what closes even that.
    pub fn inspect_key_package(
        &self,
        key_package: Vec<u8>,
    ) -> Result<VibeFfiKeyPackageIdentity, VibeFfiError> {
        self.with_provider(|provider| {
            vibe_secure::inspect_key_package(&key_package, provider).map(|identity| {
                VibeFfiKeyPackageIdentity {
                    credential_identity: identity.credential_identity,
                    signature_key: identity.signature_key,
                }
            })
        })
    }

    /// Reloads a persisted group, or `None` if this store has never held one.
    ///
    /// `None` is an ordinary answer — a fresh install, or a chat never
    /// established — and the caller establishes instead of treating it as an
    /// error. This is the call that makes a relaunch continue an existing
    /// conversation rather than silently starting a new group whose messages
    /// nobody can read.
    ///
    /// This hangs off the identity rather than being a `VibeSecureSession`
    /// constructor because uniffi requires a constructor to return `Self` or
    /// `Arc<Self>` — it cannot express "maybe a session". Expressing the
    /// absent case as an error instead would be worse: a fresh install would
    /// then throw on every chat it has never established, and the caller would
    /// have to tell that apart from a genuine store failure.
    pub fn load_session(
        self: Arc<Self>,
        group_id: Vec<u8>,
    ) -> Result<Option<Arc<VibeSecureSessionHandle>>, VibeFfiError> {
        let loaded = self.with_provider(|provider| VibeSecureSession::load(&group_id, provider))?;
        Ok(loaded.map(|session| {
            Arc::new(VibeSecureSessionHandle {
                identity: self.clone(),
                inner: Mutex::new(session),
            })
        }))
    }
}

/// Who a KeyPackage claims to be, and the key that claim is bound to.
///
/// `signatureKey` is what the platform pins. `credentialIdentity` is the device
/// id the peer chose and is **not** an authorization input — anyone can put any
/// string in a BasicCredential; it is for display only.
#[derive(Clone, Debug, uniffi::Record)]
pub struct VibeFfiKeyPackageIdentity {
    pub credential_identity: Vec<u8>,
    pub signature_key: Vec<u8>,
}

/// The safety number two people compare out of band to prove nobody is in the
/// middle.
///
/// Order-independent: both sides pass their own key and the peer's in whatever
/// order they have them and get the same digits, because neither can know who
/// is "first" during a phone call. Pure function of two public keys — see
/// `vibe_secure::trust`.
#[uniffi::export]
pub fn vibe_safety_number(key_a: Vec<u8>, key_b: Vec<u8>) -> String {
    vibe_secure::vibe_safety_number(&key_a, &key_b)
}

/// The same safety number as a hex key block — 64 chars, ungrouped. Same slow
/// hash and same ordering as the digits, so the two never disagree.
#[uniffi::export]
pub fn vibe_safety_code_hex(key_a: Vec<u8>, key_b: Vec<u8>) -> String {
    vibe_secure::vibe_safety_code_hex(&key_a, &key_b)
}

/// Group id from a `vmls1.` header, without opening the ciphertext.
#[uniffi::export]
pub fn vibe_mls_group_id_from_envelope(envelope: String) -> Result<Vec<u8>, VibeFfiError> {
    VibeSecureSession::group_id_from_envelope(&envelope).map_err(|e| map_err(&e))
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct VibeFfiMlsEnvelopeHeader {
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub content: String,
}

/// Cleartext `vmls1.` header: group id, epoch, content type. Does not open the message.
#[uniffi::export]
pub fn vibe_mls_envelope_header(envelope: String) -> Result<VibeFfiMlsEnvelopeHeader, VibeFfiError> {
    let header =
        VibeSecureSession::envelope_header(&envelope).map_err(|e| map_err(&e))?;
    Ok(VibeFfiMlsEnvelopeHeader {
        group_id: header.group_id,
        epoch: header.epoch,
        content: header.content.to_string(),
    })
}

/// The two messages an `add_members` commit produces.
///
/// `commit` goes to existing members; `welcome` goes to the joiner, who also
/// needs the group's ratchet tree. They are separate because they have different
/// audiences — sending a Welcome to the existing group would be a bug, not a
/// harmless extra.
#[derive(Clone, Debug, uniffi::Record)]
pub struct VibeFfiCommitOutput {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}

/// One MLS group session. A 1:1 DM is a two-member group; there is no separate
/// pairwise path, by design.
#[derive(uniffi::Object)]
pub struct VibeSecureSessionHandle {
    identity: Arc<VibeSecureIdentityHandle>,
    inner: Mutex<VibeSecureSession>,
}

impl VibeSecureSessionHandle {
    /// Runs `f` under the session lock, converting a poisoned lock into an
    /// error instead of panicking.
    fn with<T>(
        &self,
        f: impl FnOnce(
            &mut VibeSecureSession,
            &VibeSecureProvider,
            &VibeDeviceIdentity,
        ) -> Result<T, VibeSecureError>,
    ) -> Result<T, VibeFfiError> {
        // Session first, then provider — the one order used everywhere. See the
        // note on `VibeSecureIdentityHandle`.
        let mut session = self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "secure: session lock poisoned".to_owned(),
        })?;
        let provider = self
            .identity
            .provider
            .lock()
            .map_err(|_| VibeFfiError::Internal {
                detail: "secure: provider lock poisoned".to_owned(),
            })?;
        f(&mut session, &provider, &self.identity.identity).map_err(|e| map_err(&e))
    }
}

#[uniffi::export]
impl VibeSecureSessionHandle {
    /// Creates a new group with this device as its only member.
    #[uniffi::constructor]
    pub fn create(identity: Arc<VibeSecureIdentityHandle>) -> Result<Arc<Self>, VibeFfiError> {
        let session = identity
            .with_provider(|provider| VibeSecureSession::create(&identity.identity, provider))?;
        Ok(Arc::new(Self {
            identity,
            inner: Mutex::new(session),
        }))
    }

    /// The group's id — the handle the platform stores against its chat id.
    pub fn group_id(&self) -> Result<Vec<u8>, VibeFfiError> {
        let guard = self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "secure: session lock poisoned".to_owned(),
        })?;
        Ok(guard.group_id())
    }

    pub fn epoch(&self) -> Result<u64, VibeFfiError> {
        let guard = self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "secure: session lock poisoned".to_owned(),
        })?;
        Ok(guard.epoch())
    }

    pub fn has_pending_commit(&self) -> Result<bool, VibeFfiError> {
        let guard = self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "secure: session lock poisoned".to_owned(),
        })?;
        Ok(guard.has_pending_commit())
    }

    /// Every other member's signature key, so a joiner can pin the identity that
    /// is actually in the group instead of one the server offers separately.
    pub fn peer_signature_keys(&self) -> Result<Vec<Vec<u8>>, VibeFfiError> {
        let guard = self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "secure: session lock poisoned".to_owned(),
        })?;
        Ok(guard.peer_signature_keys())
    }

    /// Joins a group from a Welcome produced by another member's `add_members`.
    #[uniffi::constructor]
    pub fn join_from_welcome(
        identity: Arc<VibeSecureIdentityHandle>,
        welcome: Vec<u8>,
        ratchet_tree: Option<Vec<u8>>,
    ) -> Result<Arc<Self>, VibeFfiError> {
        let session = identity.with_provider(|provider| {
            VibeSecureSession::join_from_welcome(&welcome, ratchet_tree.as_deref(), provider)
        })?;
        Ok(Arc::new(Self {
            identity,
            inner: Mutex::new(session),
        }))
    }

    /// Adds devices to the group from their published KeyPackages.
    ///
    /// The bytes are attacker-controlled — a hostile server can serve any
    /// KeyPackage it likes — so they are validated inside `vibe_secure` under
    /// its panic guard, not here. Until identity pinning lands (Phase 1), a
    /// substituted KeyPackage is exactly the MITM this cannot yet detect.
    pub fn add_members(
        &self,
        key_packages: Vec<Vec<u8>>,
    ) -> Result<VibeFfiCommitOutput, VibeFfiError> {
        let bundles: Vec<VibeKeyPackageBundle> = key_packages
            .into_iter()
            .map(VibeKeyPackageBundle::from_bytes)
            .collect();
        self.with(|session, provider, identity| {
            session
                .add_members(identity, &bundles, provider)
                .map(|out| VibeFfiCommitOutput {
                    commit: out.commit,
                    welcome: out.welcome,
                })
        })
    }

    /// Seals `plaintext` as a `vmls1.` envelope string.
    pub fn seal(&self, plaintext: Vec<u8>) -> Result<String, VibeFfiError> {
        self.with(|session, provider, identity| session.seal(identity, &plaintext, provider))
    }

    /// Opens a `vmls1.` envelope.
    ///
    /// Every ordinary failure — wrong session, tampered ciphertext, malformed
    /// envelope — is indistinguishable by design. A `SessionPoisoned` detail is
    /// the one case the caller must treat differently: discard the session
    /// rather than retry.
    pub fn open(&self, envelope: String) -> Result<Vec<u8>, VibeFfiError> {
        self.with(|session, provider, _identity| session.open(&envelope, provider))
    }

    /// The group's ratchet tree, which a joiner needs alongside a Welcome.
    pub fn export_ratchet_tree(&self) -> Result<Vec<u8>, VibeFfiError> {
        let guard = self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "secure: session lock poisoned".to_owned(),
        })?;
        Ok(guard.export_ratchet_tree())
    }
}
