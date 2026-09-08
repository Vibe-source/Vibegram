//! Acceptance tests for the device identity surviving a relaunch.
//!
//! `persistence.rs` proves the *group* state survives a process exit. It says
//! nothing about the *signing key*, and that turned out to be the gap: an
//! identity regenerated on relaunch reloads the group perfectly, seals
//! perfectly, and produces messages no peer can ever open. Both sides look
//! healthy from the inside, which is why this failed in the field for two days
//! as "the key is failing to sync" with nothing in either log but a decrypt
//! error.
//!
//! Test 1 pins the failure — it is the reason the rest of this file exists, and
//! it must keep passing even after the fix, because it describes what a *fresh*
//! key does, not what the app does. Test 2 pins the fix.

use vibe_secure::{VibeDeviceIdentity, VibeSecureProvider, VibeSecureSession};

/// Establishes a two-member group across two file-backed providers and returns
/// both live sessions, already round-tripped once so the caller starts from a
/// known-good state.
fn established_pair(
    alice_provider: &VibeSecureProvider,
    bob_provider: &VibeSecureProvider,
    alice_identity: &VibeDeviceIdentity,
    bob_identity: &VibeDeviceIdentity,
) -> (VibeSecureSession, VibeSecureSession) {
    let mut alice_session =
        VibeSecureSession::create(alice_identity, alice_provider).expect("alice creates group");
    let bob_key_package = bob_identity
        .key_package(bob_provider)
        .expect("bob publishes a key package");

    let commit = alice_session
        .add_members(alice_identity, &[bob_key_package], alice_provider)
        .expect("alice adds bob");
    let ratchet_tree = alice_session.export_ratchet_tree();

    let mut bob_session =
        VibeSecureSession::join_from_welcome(&commit.welcome, Some(&ratchet_tree), bob_provider)
            .expect("bob joins from the welcome");

    let sealed = alice_session
        .seal(alice_identity, b"first contact", alice_provider)
        .expect("alice seals");
    assert_eq!(
        bob_session.open(&sealed, bob_provider).expect("bob opens"),
        b"first contact",
        "the pair must start healthy, or the rest of this test proves nothing"
    );

    (alice_session, bob_session)
}

// ---------------------------------------------------------------------------
// 1. The failure this file exists for: a *new* signing key on the same device
//    seals happily and produces a message the peer cannot open.
//
//    This is not a bug in OpenMLS. Alice's leaf in the ratchet tree records the
//    public key she had when she joined it; an application message is signed by
//    the sender and verified against that leaf. Signing with a key the leaf
//    does not name is, from Bob's side, indistinguishable from a forgery — and
//    refusing it is correct. The bug was calling `generate` on every launch.
// ---------------------------------------------------------------------------

#[test]
fn a_regenerated_identity_seals_fine_and_the_peer_can_never_open_it() {
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

    let (mut alice_session, mut bob_session) = established_pair(
        &alice_provider,
        &bob_provider,
        &alice_identity,
        &bob_identity,
    );

    // Alice relaunches. This single line is exactly what iOS did on every cold
    // launch: same stable device id, same on-disk store, brand-new signing key.
    let alice_after_relaunch = VibeDeviceIdentity::generate("alice-device-1", &alice_provider)
        .expect("alice's identity regenerates");
    assert_ne!(
        alice_identity.signature_key(),
        alice_after_relaunch.signature_key(),
        "`generate` must mint a new key — if it did not, this test proves nothing"
    );

    // Sealing gives the sender no hint that anything is wrong. It succeeds.
    let sealed = alice_session
        .seal(&alice_after_relaunch, b"unreadable to bob", &alice_provider)
        .expect("alice still seals happily under a key her leaf does not name");

    // ...and the peer cannot open it. Ever. Not a transient failure to retry:
    // Alice's leaf will name the old key until the group is rebuilt.
    assert!(
        bob_session.open(&sealed, &bob_provider).is_err(),
        "a message signed by a key absent from the sender's leaf must not open — \
         if this ever passes, the diagnosis behind the identity-persistence fix is wrong"
    );
}

// ---------------------------------------------------------------------------
// 2. The fix: `load_or_generate` hands back the *same* key across a relaunch,
//    so the peer keeps reading.
// ---------------------------------------------------------------------------

#[test]
fn a_reloaded_identity_keeps_the_same_key_and_the_peer_keeps_reading() {
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

    let alice_provider = VibeSecureProvider::open(&alice_path).expect("alice opens");
    let bob_provider = VibeSecureProvider::open(&bob_path).expect("bob opens");

    // First launch: nothing stored yet, so this generates.
    let alice_identity =
        VibeDeviceIdentity::load_or_generate("alice-device-1", None, &alice_provider)
            .expect("alice identity");
    let bob_identity = VibeDeviceIdentity::load_or_generate("bob-device-1", None, &bob_provider)
        .expect("bob identity");
    let alice_public_key = alice_identity.signature_key();

    let (mut alice_session, mut bob_session) = established_pair(
        &alice_provider,
        &bob_provider,
        &alice_identity,
        &bob_identity,
    );
    let group_id = alice_session.group_id();

    // Alice relaunches, this time handing back the public key the platform
    // persisted for her.
    drop(alice_session);
    let alice_after_relaunch = VibeDeviceIdentity::load_or_generate(
        "alice-device-1",
        Some(&alice_public_key),
        &alice_provider,
    )
    .expect("alice's identity reloads");
    assert_eq!(
        alice_public_key,
        alice_after_relaunch.signature_key(),
        "a reloaded identity must be the same identity, not a new one"
    );

    alice_session = VibeSecureSession::load(&group_id, &alice_provider)
        .expect("load does not error")
        .expect("alice's group persisted");

    let sealed = alice_session
        .seal(&alice_after_relaunch, b"still readable", &alice_provider)
        .expect("alice seals after relaunch");
    assert_eq!(
        bob_session.open(&sealed, &bob_provider).expect("bob opens"),
        b"still readable",
        "the whole point: a relaunch must not end the conversation"
    );
}

// ---------------------------------------------------------------------------
// 3. A stored public key with no matching private half — the restore-from-
//    backup shape, where `UserDefaults` came back but the backup-excluded
//    SQLite store did not — falls back to generating rather than failing.
//
//    Failing here would be the worst outcome available: MLS would be
//    permanently unavailable on that install, with no way back short of a
//    reinstall.
// ---------------------------------------------------------------------------

#[test]
fn a_stored_key_that_is_not_in_the_store_falls_back_to_generating() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("device.sqlite3")
        .to_str()
        .expect("utf8 path")
        .to_string();
    let provider = VibeSecureProvider::open(&path).expect("opens");

    let stale_public_key = vec![0x11; 32];
    let identity =
        VibeDeviceIdentity::load_or_generate("device-1", Some(&stale_public_key), &provider)
            .expect("a stale pointer must not make MLS unavailable");

    assert_ne!(
        identity.signature_key(),
        stale_public_key,
        "the fallback must mint a real key, not adopt the pointer it could not resolve"
    );
    // And the freshly generated one is itself reloadable, so the platform
    // overwriting its stored pointer with this key recovers the install.
    let reloaded = VibeDeviceIdentity::load_or_generate(
        "device-1",
        Some(&identity.signature_key()),
        &provider,
    )
    .expect("the replacement identity reloads");
    assert_eq!(reloaded.signature_key(), identity.signature_key());
}

/// Drop the chat→group mapping and recover it from the `vmls1.` header.
#[test]
fn an_envelope_rebinding_loads_the_sqlite_group_and_opens() {
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

    let (mut alice_session, _bob_live) = established_pair(
        &alice_provider,
        &bob_provider,
        &alice_identity,
        &bob_identity,
    );
    let sealed = alice_session
        .seal(&alice_identity, b"after mapping dropped", &alice_provider)
        .expect("alice seals");

    let peeked = VibeSecureSession::group_id_from_envelope(&sealed).expect("peek");
    let mut bob_rebound = VibeSecureSession::load(&peeked, &bob_provider)
        .expect("load does not error")
        .expect("sqlite still holds the group after the mapping is gone");
    assert_eq!(
        bob_rebound
            .open(&sealed, &bob_provider)
            .expect("bob opens after rebind"),
        b"after mapping dropped"
    );
}
