//! Acceptance tests for `vibe_secure`, exercised entirely through the public
//! API — nothing here reaches into `openmls` beyond constructing the
//! `OpenMlsRustCrypto` provider each identity/session needs, which is exactly
//! what a real caller (`vibe_core_ffi`, eventually) will do too.

use openmls_rust_crypto::OpenMlsRustCrypto;
use vibe_secure::{
    vibe_safety_number, VibeDeviceIdentity, VibeSecureError, VibeSecureSession,
    VIBE_MLS_MAX_CIPHERTEXT, VIBE_MLS_SEALED_PREFIX,
};

fn provider() -> OpenMlsRustCrypto {
    OpenMlsRustCrypto::default()
}

fn identity(device_id: &str, provider: &OpenMlsRustCrypto) -> VibeDeviceIdentity {
    VibeDeviceIdentity::generate(device_id, provider).expect("identity generates")
}

/// Builds a two-member group (the DM shape): alice creates it, adds bob, and
/// bob joins from the resulting welcome. Returns both live sessions.
fn paired_dm(
    alice_identity: &VibeDeviceIdentity,
    alice_provider: &OpenMlsRustCrypto,
    bob_identity: &VibeDeviceIdentity,
    bob_provider: &OpenMlsRustCrypto,
) -> (VibeSecureSession, VibeSecureSession) {
    let mut alice_session =
        VibeSecureSession::create(alice_identity, alice_provider).expect("alice creates group");

    let bob_kp = bob_identity
        .key_package(bob_provider)
        .expect("bob publishes a key package");

    let commit_output = alice_session
        .add_members(alice_identity, &[bob_kp], alice_provider)
        .expect("alice adds bob");

    let bob_session = VibeSecureSession::join_from_welcome(
        &commit_output.welcome,
        Some(&alice_session.export_ratchet_tree()),
        bob_provider,
    )
    .expect("bob joins from the welcome");

    (alice_session, bob_session)
}

// 1. Two-member group (the DM shape) seals and opens through the `vmls1.` string.
#[test]
fn two_member_group_seals_and_opens_through_the_vmls1_envelope() {
    let alice_provider = provider();
    let bob_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);

    let (mut alice_session, mut bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    let sealed = alice_session
        .seal(&alice_identity, b"hello bob", &alice_provider)
        .expect("alice seals");
    assert!(sealed.starts_with(VIBE_MLS_SEALED_PREFIX));

    let opened = bob_session
        .open(&sealed, &bob_provider)
        .expect("bob opens");
    assert_eq!(opened, b"hello bob");
}

#[test]
fn group_id_from_envelope_matches_the_session_without_opening() {
    let alice_provider = provider();
    let bob_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);

    let (mut alice_session, bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    let sealed = alice_session
        .seal(&alice_identity, b"hello bob", &alice_provider)
        .expect("alice seals");
    let peeked = VibeSecureSession::group_id_from_envelope(&sealed).expect("peek");
    assert_eq!(peeked, alice_session.group_id());
    assert_eq!(peeked, bob_session.group_id());
    let header = VibeSecureSession::envelope_header(&sealed).expect("header");
    assert_eq!(header.group_id, alice_session.group_id());
    assert_eq!(header.epoch, alice_session.epoch());
    assert_eq!(header.epoch, bob_session.epoch());
    assert_eq!(header.content, "app");
}

#[test]
fn group_id_from_envelope_rejects_malformed_input() {
    assert!(VibeSecureSession::group_id_from_envelope("not-mls").is_err());
    assert!(VibeSecureSession::group_id_from_envelope("vmls1.").is_err());
    assert!(VibeSecureSession::group_id_from_envelope("vmls1.###").is_err());
}

// 2. A third member added later opens messages sent after the add.
#[test]
fn a_third_member_added_later_opens_messages_sent_after_the_add() {
    let alice_provider = provider();
    let bob_provider = provider();
    let carol_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);
    let carol_identity = identity("carol-device-1", &carol_provider);

    let (mut alice_session, _bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    let carol_kp = carol_identity
        .key_package(&carol_provider)
        .expect("carol publishes a key package");
    let add_carol = alice_session
        .add_members(&alice_identity, &[carol_kp], &alice_provider)
        .expect("alice adds carol after the group already existed");

    let mut carol_session = VibeSecureSession::join_from_welcome(
        &add_carol.welcome,
        Some(&alice_session.export_ratchet_tree()),
        &carol_provider,
    )
    .expect("carol joins from the later welcome");

    let sealed = alice_session
        .seal(&alice_identity, b"hi carol", &alice_provider)
        .expect("alice seals after the add");

    let opened = carol_session
        .open(&sealed, &carol_provider)
        .expect("carol opens a message sent after she was added");
    assert_eq!(opened, b"hi carol");
}

// 3. A removed/never-added party cannot open -- wrong session returns
//    `VibeSecureError::Open`, never a panic and never plaintext.
#[test]
fn a_never_added_party_cannot_open_wrong_session_messages() {
    let alice_provider = provider();
    let bob_provider = provider();
    let mallory_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);
    let mallory_identity = identity("mallory-device-1", &mallory_provider);

    let (mut alice_session, _bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    // Mallory has her own, entirely unrelated group. She was never invited to
    // alice+bob's, so her session holds none of its key material.
    let mut mallory_session = VibeSecureSession::create(&mallory_identity, &mallory_provider)
        .expect("mallory creates an unrelated group");

    let sealed = alice_session
        .seal(&alice_identity, b"private to bob", &alice_provider)
        .expect("alice seals to her real group");

    let result = mallory_session.open(&sealed, &mallory_provider);
    assert_eq!(result, Err(VibeSecureError::Open));
}

// 4. A corrupted envelope (flip one base64 byte) returns an error, never a panic.
//
// This is the test that found a real upstream landmine: OpenMLS 0.8.1's
// `PrivateMessageIn::decrypt` (framing/private_message_in.rs:136) has
// `debug_assert!(false, "Ciphertext decryption failed")` on exactly the path
// a flipped ciphertext byte takes. That assertion is live in `dev`/`test`
// profiles and compiled out under `--release`, so this test's pass/fail was
// previously profile-dependent -- passing under `--release`, panicking under
// plain `cargo test`. `VibeSecureSession::open` now wraps every call that
// touches peer-supplied bytes in `catch_unwind` (see the "debug-only
// landmine" section of `src/lib.rs`), so this assertion holds under both
// profiles rather than only the one CI happens to run.
#[test]
fn a_corrupted_envelope_returns_an_error_never_a_panic() {
    let alice_provider = provider();
    let bob_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);

    let (mut alice_session, mut bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    let sealed = alice_session
        .seal(&alice_identity, b"tamper with me", &alice_provider)
        .expect("alice seals");

    let mut bytes = sealed.into_bytes();
    // Flip a byte a few positions before the end: well inside the
    // ciphertext/tag, clear of the `vmls1.` prefix and any leading
    // length-prefixed header fields.
    let flip_at = bytes.len() - 5;
    bytes[flip_at] = if bytes[flip_at] == b'A' { b'B' } else { b'A' };
    let corrupted = String::from_utf8(bytes).expect("flipping a base64 byte stays utf-8");

    let result = bob_session.open(&corrupted, &bob_provider);
    assert!(result.is_err(), "a tampered envelope must never open");
}

// 5. An envelope over `VIBE_MLS_MAX_CIPHERTEXT` is rejected on length before
//    allocating.
#[test]
fn an_oversized_envelope_is_rejected_before_allocating() {
    let bob_provider = provider();
    let bob_identity = identity("bob-device-1", &bob_provider);
    // The size check runs before any group-specific logic, so any live
    // session will do -- it never gets far enough to matter which one.
    let mut bob_session =
        VibeSecureSession::create(&bob_identity, &bob_provider).expect("bob creates a group");

    let huge_body = "A".repeat(VIBE_MLS_MAX_CIPHERTEXT * 2);
    let envelope = format!("{VIBE_MLS_SEALED_PREFIX}{huge_body}");

    let result = bob_session.open(&envelope, &bob_provider);
    assert!(matches!(
        result,
        Err(VibeSecureError::CiphertextTooLarge { limit, .. }) if limit == VIBE_MLS_MAX_CIPHERTEXT
    ));
}

// 6. `format!("{err} {err:?}")` for every `VibeSecureError` contains no plaintext.
#[test]
fn no_error_rendering_leaks_plaintext_or_key_material() {
    let secret_markers = [
        "hello bob",
        "hi carol",
        "private to bob",
        "tamper with me",
        "alice-device-1",
        "bob-device-1",
        "carol-device-1",
        "mallory-device-1",
    ];

    let variants = [
        VibeSecureError::IdentityGeneration,
        VibeSecureError::KeyPackageBuild,
        VibeSecureError::GroupCreate,
        VibeSecureError::GroupJoin,
        VibeSecureError::MemberAdd,
        VibeSecureError::Seal,
        VibeSecureError::Open,
        VibeSecureError::MalformedEnvelope,
        VibeSecureError::UnsupportedCiphersuite,
        VibeSecureError::CiphertextTooLarge {
            limit: VIBE_MLS_MAX_CIPHERTEXT,
            actual: 999_999_999,
        },
    ];

    for err in variants {
        let rendered = format!("{err} {err:?}");
        for marker in secret_markers {
            assert!(
                !rendered.contains(marker),
                "error rendering leaked secret data: {rendered}"
            );
        }
    }
}

// 7. The `vmls1.` prefix is required -- a bare base64 string is `MalformedEnvelope`.
#[test]
fn the_vmls1_prefix_is_required() {
    let alice_provider = provider();
    let bob_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);

    let (mut alice_session, mut bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    let sealed = alice_session
        .seal(&alice_identity, b"needs the prefix", &alice_provider)
        .expect("alice seals");
    let bare = sealed
        .strip_prefix(VIBE_MLS_SEALED_PREFIX)
        .expect("a sealed envelope always carries the prefix")
        .to_string();

    let result = bob_session.open(&bare, &bob_provider);
    assert_eq!(result, Err(VibeSecureError::MalformedEnvelope));
}

/// A sender **cannot** open its own message, and that is correct MLS.
///
/// `create_message` produces a PrivateMessage encrypted to the group's other
/// members; OpenMLS refuses to process a message the caller authored. This is
/// pinned as a test because it is a load-bearing constraint on every platform
/// built on this crate, not a quirk: the platform re-parses `encryptedContent`
/// when the server echoes a sent message back, so anything that decrypts to
/// display **must** keep the sender's own plaintext locally instead of asking
/// this function. Vibe learned that the hard way — own messages rendered as
/// empty bubbles. See `VibeSecureSessions.rememberOwnPlaintext`.
#[test]
fn a_sender_cannot_open_its_own_message_so_platforms_must_keep_the_plaintext() {
    let alice_provider = provider();
    let bob_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);

    let (mut alice_session, mut bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    let sealed = alice_session
        .seal(&alice_identity, b"hello", &alice_provider)
        .expect("alice seals");

    assert!(
        alice_session.open(&sealed, &alice_provider).is_err(),
        "if this ever starts succeeding, the platform's own-plaintext cache can be removed"
    );
    // The peer, of course, reads it fine — the message is not corrupt.
    assert_eq!(
        bob_session.open(&sealed, &bob_provider).expect("bob opens"),
        b"hello"
    );
}

/// 11. A message opens exactly once: `process_message` ratchets the sender's
/// secret tree and drops that key, so re-parsing the same envelope fails.
#[test]
fn the_same_message_cannot_be_opened_twice() {
    let alice_provider = provider();
    let bob_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);

    let (mut alice_session, mut bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    let sealed = alice_session
        .seal(&alice_identity, b"read me once", &alice_provider)
        .expect("alice seals");

    assert_eq!(
        bob_session.open(&sealed, &bob_provider).expect("bob opens"),
        b"read me once"
    );
    assert!(
        bob_session.open(&sealed, &bob_provider).is_err(),
        "a second open must fail, or the receiver would not need a plaintext cache"
    );
}

/// 12. A joiner claims no KeyPackage, so the group tree is the only place its
/// half of the safety number can come from.
#[test]
fn both_sides_read_each_other_out_of_the_group_and_agree_on_the_safety_number() {
    let alice_provider = provider();
    let bob_provider = provider();
    let alice_identity = identity("alice-device-1", &alice_provider);
    let bob_identity = identity("bob-device-1", &bob_provider);

    let (alice_session, bob_session) = paired_dm(
        &alice_identity,
        &alice_provider,
        &bob_identity,
        &bob_provider,
    );

    assert_eq!(
        alice_session.peer_signature_keys(),
        vec![bob_identity.signature_key()],
        "the creator sees exactly the member it added"
    );
    assert_eq!(
        bob_session.peer_signature_keys(),
        vec![alice_identity.signature_key()],
        "the joiner sees exactly the creator, without ever claiming a KeyPackage"
    );

    assert_eq!(
        vibe_safety_number(
            &alice_identity.signature_key(),
            &alice_session.peer_signature_keys()[0]
        ),
        vibe_safety_number(
            &bob_identity.signature_key(),
            &bob_session.peer_signature_keys()[0]
        )
    );
}
