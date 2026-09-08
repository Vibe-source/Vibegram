//! Acceptance tests for [`vibe_secure::VibeSecureProvider`] — the property
//! this crate did not have until this file: MLS group state that survives a
//! process exit.
//!
//! Test 2 is the one that matters. Every other test here (and every test in
//! `round_trip.rs`) would pass just as well against
//! `openmls_rust_crypto::OpenMlsRustCrypto::default()`, whose storage is a
//! `HashMap` that dies with the process. Only test 2 actually drops every
//! Rust value involved, reopens fresh ones from the same paths, and proves a
//! message sealed in the old process opens in the "new" one — the one thing
//! an in-memory provider cannot do.

use openmls::prelude::tls_codec::{DeserializeBytes as _, Serialize as _};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use vibe_secure::{
    VibeDeviceIdentity, VibeSecureError, VibeSecureProvider, VibeSecureSession,
    VIBE_SECURE_CIPHERSUITE,
};

// ---------------------------------------------------------------------------
// 1. File-backed providers are otherwise ordinary providers: establish a
//    group, seal, open — all through the crate's normal public API.
// ---------------------------------------------------------------------------

#[test]
fn two_members_establish_a_group_on_file_backed_providers_and_a_message_seals_and_opens() {
    let dir = tempfile::tempdir().expect("tempdir");
    let alice_path = dir.path().join("alice.sqlite3");
    let bob_path = dir.path().join("bob.sqlite3");

    let alice_provider =
        VibeSecureProvider::open(alice_path.to_str().expect("utf8 path")).expect("alice opens");
    let bob_provider =
        VibeSecureProvider::open(bob_path.to_str().expect("utf8 path")).expect("bob opens");

    let alice_identity =
        VibeDeviceIdentity::generate("alice-device-1", &alice_provider).expect("alice identity");
    let bob_identity =
        VibeDeviceIdentity::generate("bob-device-1", &bob_provider).expect("bob identity");

    let mut alice_session =
        VibeSecureSession::create(&alice_identity, &alice_provider).expect("alice creates group");
    let bob_key_package = bob_identity
        .key_package(&bob_provider)
        .expect("bob publishes a key package");

    let commit_output = alice_session
        .add_members(&alice_identity, &[bob_key_package], &alice_provider)
        .expect("alice adds bob");
    let ratchet_tree = alice_session.export_ratchet_tree();

    let mut bob_session = VibeSecureSession::join_from_welcome(
        &commit_output.welcome,
        Some(&ratchet_tree),
        &bob_provider,
    )
    .expect("bob joins from the welcome");

    let sealed = alice_session
        .seal(&alice_identity, b"hello bob, from file-backed alice", &alice_provider)
        .expect("alice seals");
    let opened = bob_session.open(&sealed, &bob_provider).expect("bob opens");
    assert_eq!(opened, b"hello bob, from file-backed alice");
}

// ---------------------------------------------------------------------------
// 2. The real test: drop everything, reopen from the same paths, reload the
//    group, open a message sealed before the drop.
//
// This drives `openmls::prelude::MlsGroup` directly rather than through
// `VibeSecureSession`, for one reason: `VibeSecureSession` has no "reload
// from storage" constructor today (only `create` and `join_from_welcome`),
// and this slice's owned files do not include `session.rs`. Reload is a
// property of the *provider* — `MlsGroup::load` is OpenMLS's own primitive
// for it — so exercising it directly against `VibeSecureProvider` proves
// exactly the property this slice exists for, without reaching past the
// files this run owns.
// ---------------------------------------------------------------------------

/// Builds a device identity the same way [`VibeDeviceIdentity::generate`]
/// does internally (signing key generated and stored in `provider`, wrapped
/// in a `BasicCredential`). Inlined here, rather than reusing
/// `VibeDeviceIdentity`, only because this test needs the raw
/// `SignatureKeyPair` and `CredentialWithKey` to drive `MlsGroup` directly —
/// `VibeDeviceIdentity` does not expose either.
fn raw_identity(
    device_id: &[u8],
    provider: &VibeSecureProvider,
) -> (SignatureKeyPair, CredentialWithKey) {
    let credential = BasicCredential::new(device_id.to_vec());
    let signer = SignatureKeyPair::new(VIBE_SECURE_CIPHERSUITE.signature_algorithm())
        .expect("signature key generates");
    signer.store(provider.storage()).expect("signer stores");
    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: signer.public().into(),
    };
    (signer, credential_with_key)
}

/// Deserializes a TLS-serialized `MlsMessageOut` (as produced by
/// `tls_serialize_detached`) back into a `ProtocolMessage` ready for
/// `MlsGroup::process_message`. Mirrors exactly what `session.rs`'s `open`
/// does to an unwrapped `vmls1.` envelope.
fn into_protocol_message(bytes: &[u8]) -> ProtocolMessage {
    MlsMessageIn::tls_deserialize_exact_bytes(bytes)
        .expect("deserialize sealed message")
        .try_into_protocol_message()
        .expect("message converts into a protocol message")
}

#[test]
fn a_message_sealed_before_the_drop_opens_after_reopening_from_the_same_paths() {
    let dir = tempfile::tempdir().expect("tempdir");
    let alice_path = dir
        .path()
        .join("alice.sqlite3")
        .to_str()
        .expect("utf8 path")
        .to_string();
    let bob_path = dir
        .path()
        .join("bob.sqlite3")
        .to_str()
        .expect("utf8 path")
        .to_string();

    // --- Establish the group and seal one message, then let everything drop.
    let (alice_group_id, bob_group_id, bob_public_key, sealed_by_alice) = {
        let alice_provider = VibeSecureProvider::open(&alice_path).expect("alice opens");
        let bob_provider = VibeSecureProvider::open(&bob_path).expect("bob opens");

        let (alice_signer, alice_cred) = raw_identity(b"alice-device-1", &alice_provider);
        let (bob_signer, bob_cred) = raw_identity(b"bob-device-1", &bob_provider);
        let bob_public_key = bob_signer.public().to_vec();

        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(VIBE_SECURE_CIPHERSUITE)
            .build();
        let mut alice_group = MlsGroup::new(&alice_provider, &alice_signer, &config, alice_cred)
            .expect("alice creates the group");

        let bob_kp_bundle = KeyPackage::builder()
            .build(VIBE_SECURE_CIPHERSUITE, &bob_provider, &bob_signer, bob_cred)
            .expect("bob's key package builds");

        let (_commit, welcome, _group_info) = alice_group
            .add_members(
                &alice_provider,
                &alice_signer,
                &[bob_kp_bundle.key_package().clone()],
            )
            .expect("alice adds bob");
        alice_group
            .merge_pending_commit(&alice_provider)
            .expect("alice merges her own commit");

        let welcome_bytes = welcome
            .tls_serialize_detached()
            .expect("serialize welcome");
        let welcome_msg = MlsMessageIn::tls_deserialize_exact_bytes(&welcome_bytes)
            .expect("deserialize welcome");
        let MlsMessageBodyIn::Welcome(welcome_in) = welcome_msg.extract() else {
            panic!("welcome message body was not a Welcome");
        };

        let ratchet_tree_bytes = alice_group
            .export_ratchet_tree()
            .tls_serialize_detached()
            .expect("serialize ratchet tree");
        let ratchet_tree_in = RatchetTreeIn::tls_deserialize_exact_bytes(&ratchet_tree_bytes)
            .expect("deserialize ratchet tree");

        let bob_group = StagedWelcome::new_from_welcome(
            &bob_provider,
            &MlsGroupJoinConfig::default(),
            welcome_in,
            Some(ratchet_tree_in),
        )
        .expect("bob stages the welcome")
        .into_group(&bob_provider)
        .expect("bob joins the group");

        assert_eq!(
            alice_group.group_id(),
            bob_group.group_id(),
            "both members agree on the group id"
        );

        // Sealed *before* the drop below — the message the reopened,
        // reloaded provider must still be able to open.
        let sealed_by_alice = alice_group
            .create_message(&alice_provider, &alice_signer, b"sealed before the drop")
            .expect("alice seals")
            .tls_serialize_detached()
            .expect("serialize the sealed application message");

        (
            alice_group.group_id().clone(),
            bob_group.group_id().clone(),
            bob_public_key,
            sealed_by_alice,
        )
    };
    // `alice_provider`, `bob_provider`, `alice_group`, and `bob_group` all
    // went out of scope above and were dropped — their SQLite connections
    // closed, nothing survives in this process's memory. This is the
    // "app relaunches" step the whole slice exists for.

    // Reopen from the *same paths*. Fresh `Connection`s, fresh migration
    // checks — nothing here is carried over from the block above.
    let alice_provider = VibeSecureProvider::open(&alice_path).expect("alice reopens");
    let bob_provider = VibeSecureProvider::open(&bob_path).expect("bob reopens");

    // Reload. A fresh `OpenMlsRustCrypto::default()` could not pass this:
    // its `MemoryStorage` would be an empty map and `MlsGroup::load` would
    // return `Ok(None)`. Here `storage()` is backed by the SQLite file just
    // reopened above, so the persisted group comes back.
    let mut bob_group = MlsGroup::load(bob_provider.storage(), &bob_group_id)
        .expect("load does not error")
        .expect("bob's group state persisted across the drop");

    let processed = bob_group
        .process_message(&bob_provider, into_protocol_message(&sealed_by_alice))
        .expect("bob opens the pre-drop message after reload");
    let ProcessedMessageContent::ApplicationMessage(app) = processed.into_content() else {
        panic!("expected an application message");
    };
    assert_eq!(app.into_bytes(), b"sealed before the drop");

    // One step further: the reloaded state is a live, continuing ratchet,
    // not a frozen replay of what was on disk. Bob (reloaded) seals a *new*
    // message; alice (also reloaded) opens it.
    let mut alice_group = MlsGroup::load(alice_provider.storage(), &alice_group_id)
        .expect("load does not error")
        .expect("alice's group state persisted across the drop");
    let bob_signer = SignatureKeyPair::read(
        bob_provider.storage(),
        &bob_public_key,
        VIBE_SECURE_CIPHERSUITE.signature_algorithm(),
    )
    .expect("bob's signing key persisted across the drop");

    let sealed_by_bob_after_reload = bob_group
        .create_message(&bob_provider, &bob_signer, b"sealed after reload")
        .expect("bob seals after reload")
        .tls_serialize_detached()
        .expect("serialize");

    let processed_by_alice = alice_group
        .process_message(
            &alice_provider,
            into_protocol_message(&sealed_by_bob_after_reload),
        )
        .expect("alice opens bob's post-reload message");
    let ProcessedMessageContent::ApplicationMessage(app) = processed_by_alice.into_content()
    else {
        panic!("expected an application message");
    };
    assert_eq!(app.into_bytes(), b"sealed after reload");
}

// ---------------------------------------------------------------------------
// 3. A path that cannot be created (missing parent directory) returns
//    `VibeSecureError::Storage`, never a panic.
// ---------------------------------------------------------------------------

#[test]
fn opening_an_uncreatable_path_returns_storage_error_not_a_panic() {
    let dir = tempfile::tempdir().expect("tempdir");
    // SQLite creates the leaf file but never intermediate directories, so a
    // missing parent reliably fails the open rather than silently creating
    // the tree.
    let bad_path = dir
        .path()
        .join("no-such-parent-dir")
        .join("nested")
        .join("db.sqlite3");

    let result = VibeSecureProvider::open(bad_path.to_str().expect("utf8 path"));
    assert!(
        matches!(result, Err(VibeSecureError::Storage)),
        "an uncreatable path must return Storage, not succeed or panic"
    );
}

// ---------------------------------------------------------------------------
// 4. `format!("{err} {err:?}")` for `VibeSecureError::Storage` contains no
//    path and no key material.
// ---------------------------------------------------------------------------

#[test]
fn storage_error_display_and_debug_carry_no_path_or_key_material() {
    let dir = tempfile::tempdir().expect("tempdir");
    let bad_dir_name = "no-such-parent-dir-xyz";
    let bad_path = dir.path().join(bad_dir_name).join("db.sqlite3");
    let bad_path_str = bad_path.to_str().expect("utf8 path").to_string();

    let err = match VibeSecureProvider::open(&bad_path_str) {
        Err(e) => e,
        Ok(_) => panic!("expected the open to fail"),
    };

    let rendered = format!("{err} {err:?}");
    assert!(
        !rendered.contains(&bad_path_str),
        "rendered error must not contain the path: {rendered}"
    );
    assert!(
        !rendered.contains(bad_dir_name),
        "rendered error must not contain any path fragment: {rendered}"
    );
    assert!(!rendered.contains('/'), "rendered error must not contain a path separator");
    assert!(!rendered.contains('\\'), "rendered error must not contain a path separator");
    let lower = rendered.to_lowercase();
    assert!(!lower.contains("select"), "rendered error must not contain SQL text");
    assert!(!lower.contains("sqlite"), "rendered error must not name the storage engine");
}
