//! Device identity: one Ed25519 signing key plus the MLS `BasicCredential`
//! that names it.
//!
//! Vibe already puts one asymmetric key per *account* in the Keychain; MLS
//! makes the identity per-*device* instead, which is what finally makes
//! multi-device native instead of "one key smuggled to a second phone." The
//! device id is deliberately the thing a future safety-number UI hashes, so
//! it is threaded through unchanged into the `BasicCredential` rather than
//! derived from key material — the credential is what a peer actually sees.

use openmls::prelude::tls_codec::Serialize as _;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;

use crate::error::VibeSecureError;
use crate::VIBE_SECURE_CIPHERSUITE;

/// One device's long-term MLS identity: a signing key held in the platform's
/// key store, plus the credential that names it inside a group.
///
/// The signing key never crosses FFI — exactly the rule `vibe_core::crypto`
/// already holds for the RSA key it replaces. This type does not implement
/// `Debug`: printing it by accident must not become possible by adding a
/// derive.
pub struct VibeDeviceIdentity {
    device_id: String,
    signer: SignatureKeyPair,
    credential_with_key: CredentialWithKey,
}

impl VibeDeviceIdentity {
    /// Generates a fresh identity for `device_id` and stores its signing key
    /// in `provider`'s key store.
    ///
    /// `device_id` should be stable for the lifetime of the install — it is
    /// what other members' safety-number UI will hash, and what a future
    /// remove-device flow names.
    ///
    /// **A platform must not call this on launch — use
    /// [`Self::load_or_generate`].** A stable `device_id` is not a stable
    /// identity: this mints a new signing key every time, and a device that
    /// does so on every launch keeps every group it is in while becoming
    /// unreadable to every peer in them.
    pub fn generate(
        device_id: &str,
        provider: &impl OpenMlsProvider,
    ) -> Result<Self, VibeSecureError> {
        let credential = BasicCredential::new(device_id.as_bytes().to_vec());
        let signer = SignatureKeyPair::new(VIBE_SECURE_CIPHERSUITE.signature_algorithm())
            .map_err(|_| VibeSecureError::IdentityGeneration)?;
        signer
            .store(provider.storage())
            .map_err(|_| VibeSecureError::IdentityGeneration)?;

        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.public().into(),
        };

        Ok(Self {
            device_id: device_id.to_string(),
            signer,
            credential_with_key,
        })
    }

    /// Reloads the identity whose public half is `signature_public_key`, or
    /// generates a fresh one when that key is absent or cannot be resolved.
    ///
    /// **This, not [`Self::generate`], is what a platform calls on launch.**
    /// The signing key is what a peer's copy of our leaf node names, and an
    /// application message is verified against that leaf — so minting a new key
    /// on relaunch leaves the group loading fine, sealing fine, and producing
    /// messages the peer can never open. The sender sees success; the receiver
    /// sees a decrypt failure it can only read as tampering. That shipped, and
    /// wedged live conversations for two days; `tests/identity_persistence.rs`
    /// pins both halves of it.
    ///
    /// Only the *public* half crosses this boundary, in either direction. The
    /// private key stays in `provider`'s key store, which is the same rule the
    /// rest of this type holds: the platform gets an address to look the
    /// identity up by, never the identity itself.
    ///
    /// Falls back to generating rather than failing when the key does not
    /// resolve. That is the restore-from-backup shape — a platform's stored
    /// pointer survives while the backup-excluded key store does not — and
    /// failing there would make MLS permanently unavailable on that install
    /// with no route back short of a reinstall. The caller must persist
    /// [`Self::signature_key`] after **every** call for the same reason: a
    /// stale pointer has to be overwritten, not just written once.
    pub fn load_or_generate(
        device_id: &str,
        signature_public_key: Option<&[u8]>,
        provider: &impl OpenMlsProvider,
    ) -> Result<Self, VibeSecureError> {
        let Some(public_key) = signature_public_key else {
            return Self::generate(device_id, provider);
        };
        let Some(signer) = SignatureKeyPair::read(
            provider.storage(),
            public_key,
            VIBE_SECURE_CIPHERSUITE.signature_algorithm(),
        ) else {
            return Self::generate(device_id, provider);
        };

        // Rebuilt from the reloaded key rather than from `public_key`, so a
        // caller that passed a truncated or otherwise mangled pointer cannot
        // produce a credential that names something the signer will not sign
        // as. `read` already keyed on the exact bytes, so these are equal
        // today — this keeps them equal by construction.
        let credential = BasicCredential::new(device_id.as_bytes().to_vec());
        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.public().into(),
        };

        Ok(Self {
            device_id: device_id.to_string(),
            signer,
            credential_with_key,
        })
    }

    /// The stable device id this identity was generated for.
    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    /// Builds a fresh `KeyPackage` for this device and returns the bytes safe
    /// to publish to the server.
    ///
    /// Each call consumes a one-time init key and mints a new one — a
    /// `KeyPackage` is meant to be used once, the same way the RSA path's
    /// "fresh key per message" was, except here it is "fresh key package per
    /// invite". [`VibeKeyPackageBundle::as_bytes`] carries **only** the public
    /// `KeyPackage`; the matching private key material stays in `provider`'s
    /// key store, which is what lets [`crate::session::VibeSecureSession::join_from_welcome`]
    /// find it later without this type ever handling it directly.
    pub fn key_package(
        &self,
        provider: &impl OpenMlsProvider,
    ) -> Result<VibeKeyPackageBundle, VibeSecureError> {
        let bundle = KeyPackage::builder()
            .build(
                VIBE_SECURE_CIPHERSUITE,
                provider,
                &self.signer,
                self.credential_with_key.clone(),
            )
            .map_err(|_| VibeSecureError::KeyPackageBuild)?;

        let bytes = bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|_| VibeSecureError::KeyPackageBuild)?;

        Ok(VibeKeyPackageBundle { bytes })
    }

    /// The signer used to author group operations on this device's behalf.
    /// Not exposed outside the crate — callers act through
    /// [`crate::session::VibeSecureSession`], never on the key directly.
    pub(crate) fn signer(&self) -> &SignatureKeyPair {
        &self.signer
    }

    /// This device's credential, cloned for handing to an OpenMLS call that
    /// consumes one by value.
    pub(crate) fn credential_with_key(&self) -> CredentialWithKey {
        self.credential_with_key.clone()
    }

    /// This device's **public** signature key.
    ///
    /// Public on purpose, unlike everything else on this type: it is one half
    /// of the safety number a user reads aloud to a peer, and the value a peer
    /// pins for us. Exposing the public half is what makes the pinning
    /// symmetric — there is nothing secret here, and the private half still
    /// never leaves `signer`.
    pub fn signature_key(&self) -> Vec<u8> {
        self.credential_with_key.signature_key.as_slice().to_vec()
    }
}

/// A serialized `KeyPackage`, safe to publish to the server.
///
/// Carries only the public half. The matching private init/encryption keys
/// this device generated alongside it live in the OpenMLS key store, never
/// here — this type crossing FFI to the server is exactly the point of it,
/// so it must never be extended with a field that shouldn't leave the device.
pub struct VibeKeyPackageBundle {
    bytes: Vec<u8>,
}

impl VibeKeyPackageBundle {
    /// Wraps KeyPackage bytes fetched from the server.
    ///
    /// Deliberately does **no** validation: these bytes are attacker-controlled
    /// (a hostile server can serve anything), and the only validation that means
    /// anything is OpenMLS's own, which runs inside
    /// [`crate::VibeSecureSession::add_members`] under its panic guard. Checking
    /// here as well would invite the caller to treat construction as proof the
    /// package is trustworthy, which it is not.
    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self { bytes }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }
}
