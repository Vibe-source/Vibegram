//! Who a KeyPackage actually belongs to, and how two people check that they
//! agree.
//!
//! # The gap this closes
//!
//! Establishment claims a peer's KeyPackage *from the server*. Nothing in MLS
//! makes the server honest: it can serve a KeyPackage it minted itself, sit in
//! the middle of the group, and neither side would notice. Every message would
//! still be genuinely encrypted — to the attacker.
//!
//! Two mechanisms fix that, and both need the same primitive: reading the
//! identity out of a KeyPackage *before* trusting it.
//!
//! * **Pinning (automatic).** Remember the signature key seen the first time,
//!   and refuse to establish if it ever changes. This makes substitution a
//!   one-shot attack that must land on first contact, rather than something
//!   the server can do at any moment.
//! * **Safety numbers (manual).** Derive a short string from both parties'
//!   identity keys. Two people who read it aloud and find it matching know
//!   there is nobody in between. This is what defeats first-contact
//!   substitution, which pinning alone cannot.
//!
//! # Why the safety number lives here
//!
//! It is a pure function of two public keys, so it belongs where it can be
//! tested exhaustively rather than in two platform implementations that must
//! agree forever. Both sides compute the same digits from the same pair, and
//! **order must not matter** — Alice and Bob see the same number without
//! agreeing who is "first". That is the property the tests pin down.

use openmls::prelude::tls_codec::DeserializeBytes as _;
use openmls::prelude::*;
use sha2::{Digest, Sha256};

use crate::error::VibeSecureError;
use crate::VIBE_SECURE_CIPHERSUITE;

/// How many digits a safety number carries.
///
/// 60 decimal digits ≈ 199 bits, matching the scale Signal settled on. The
/// number is compared by a human reading it aloud, so the real limit is
/// patience, not entropy: far past ~60 nobody finishes the comparison, and an
/// abandoned comparison protects nothing.
pub const VIBE_SAFETY_NUMBER_DIGITS: usize = 60;

/// How many hex chars the key block carries: 32 bytes, 16 from each side.
pub const VIBE_SAFETY_CODE_HEX_CHARS: usize = 64;

/// How many iterations of hashing go into each side's half.
///
/// Deliberately slow in the same spirit as Signal's 5200 rounds: it costs a
/// user nothing to compute once, but makes brute-forcing a key whose safety
/// number *collides* with a target's expensive, which is the only attack that
/// matters against a number humans compare by eye.
const SAFETY_NUMBER_ITERATIONS: usize = 5200;

/// The identity carried by a KeyPackage: who it claims to be, and the key that
/// claim is bound to.
///
/// `signature_key` is the thing worth pinning. `credential_identity` is the
/// device id the peer chose and is **not** trustworthy on its own — anyone can
/// put any string in a BasicCredential. It is useful for display and for
/// noticing a peer's device changed, never as an authorization decision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VibeKeyPackageIdentity {
    pub credential_identity: Vec<u8>,
    pub signature_key: Vec<u8>,
}

/// Reads the identity out of a serialized KeyPackage, validating it first.
///
/// The bytes are attacker-controlled — a hostile server can serve anything —
/// so this validates before believing any field, and reports one opaque error
/// for every way that can fail. A caller that gets `Ok` knows the KeyPackage is
/// well-formed, uses the expected ciphersuite, and is self-consistently signed;
/// it does **not** know the key belongs to the person it asked for. That is
/// what pinning and safety numbers are for.
pub fn inspect_key_package(
    bytes: &[u8],
    provider: &impl OpenMlsProvider,
) -> Result<VibeKeyPackageIdentity, VibeSecureError> {
    let key_package_in =
        KeyPackageIn::tls_deserialize_exact_bytes(bytes).map_err(|_| VibeSecureError::MemberAdd)?;

    let key_package = crate::session::catch_untrusted(VibeSecureError::MemberAdd, || {
        key_package_in.validate(provider.crypto(), ProtocolVersion::Mls10)
    })?
    .map_err(|_| VibeSecureError::MemberAdd)?;

    if key_package.ciphersuite() != VIBE_SECURE_CIPHERSUITE {
        return Err(VibeSecureError::UnsupportedCiphersuite);
    }

    let credential = key_package.leaf_node().credential();
    let credential_identity = match BasicCredential::try_from(credential.clone()) {
        Ok(basic) => basic.identity().to_vec(),
        Err(_) => return Err(VibeSecureError::MemberAdd),
    };

    Ok(VibeKeyPackageIdentity {
        credential_identity,
        signature_key: key_package.leaf_node().signature_key().as_slice().to_vec(),
    })
}

/// The safety number two devices compare out of band.
///
/// Order-independent: the two keys are sorted before hashing, so both sides
/// compute the same digits without agreeing who goes first. Returns
/// [`VIBE_SAFETY_NUMBER_DIGITS`] decimal digits with no grouping — how to chunk
/// them for display is the platform's business.
pub fn vibe_safety_number(key_a: &[u8], key_b: &[u8]) -> String {
    let (first, second) = sorted(key_a, key_b);

    let mut digits = String::with_capacity(VIBE_SAFETY_NUMBER_DIGITS);
    digits.push_str(&fingerprint(first, VIBE_SAFETY_NUMBER_DIGITS / 2));
    digits.push_str(&fingerprint(second, VIBE_SAFETY_NUMBER_DIGITS / 2));
    digits
}

/// The same fingerprint rendered as hex, for screens that show a key block
/// rather than digits. Same slow hash, same ordering — one truth, two shapes.
pub fn vibe_safety_code_hex(key_a: &[u8], key_b: &[u8]) -> String {
    let (first, second) = sorted(key_a, key_b);
    let mut out = String::with_capacity(VIBE_SAFETY_CODE_HEX_CHARS);
    for key in [first, second] {
        for byte in iterated_hash(key).iter().take(VIBE_SAFETY_CODE_HEX_CHARS / 4) {
            out.push_str(&format!("{byte:02x}"));
        }
    }
    out
}

/// Order-independent pairing: neither side can know who is "first".
fn sorted<'a>(key_a: &'a [u8], key_b: &'a [u8]) -> (&'a [u8], &'a [u8]) {
    if key_a <= key_b {
        (key_a, key_b)
    } else {
        (key_b, key_a)
    }
}

/// The slow hash both renderings share, so hex and digits describe one key.
fn iterated_hash(key: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    // Domain separation: this hash must never collide with any other use of
    // SHA-256 over the same key elsewhere in the system.
    hasher.update(b"vibe/safety-number/v1");
    hasher.update(key);
    let mut hash = hasher.finalize().to_vec();

    for _ in 0..SAFETY_NUMBER_ITERATIONS {
        let mut hasher = Sha256::new();
        hasher.update(&hash);
        hasher.update(key);
        hash = hasher.finalize().to_vec();
    }
    hash
}

/// One party's half of the safety number: iterated hashing, then the leading
/// bytes rendered as decimal groups.
fn fingerprint(key: &[u8], digits: usize) -> String {
    let hash = iterated_hash(key);

    // Each 5-digit group comes from 40 bits, taken modulo 100_000. The bias
    // from 2^40 not dividing 100_000 is under one part in 10^7 — irrelevant
    // against a hash preimage, and the alternative (rejection sampling) would
    // make the output length non-deterministic.
    let mut out = String::with_capacity(digits);
    let mut offset = 0;
    while out.len() < digits {
        let mut chunk: u64 = 0;
        for i in 0..5 {
            chunk = (chunk << 8) | u64::from(hash[(offset + i) % hash.len()]);
        }
        offset += 5;
        out.push_str(&format!("{:05}", chunk % 100_000));
    }
    out.truncate(digits);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(byte: u8) -> Vec<u8> {
        vec![byte; 32]
    }

    #[test]
    fn both_sides_compute_the_same_number_regardless_of_order() {
        // The whole mechanism rests on this: two people comparing by voice
        // have no way to agree who is "first", so a number that depended on
        // order would mismatch for honest pairs and teach users to ignore it.
        let a = key(1);
        let b = key(2);
        assert_eq!(vibe_safety_number(&a, &b), vibe_safety_number(&b, &a));
    }

    #[test]
    fn a_different_peer_gives_a_different_number() {
        let mine = key(1);
        assert_ne!(
            vibe_safety_number(&mine, &key(2)),
            vibe_safety_number(&mine, &key(3))
        );
    }

    #[test]
    fn one_flipped_bit_changes_the_number() {
        // A substituted key that produced a *similar* number would be the
        // worst outcome: users compare the first few digits and stop.
        let mine = key(1);
        let mut tampered = key(2);
        tampered[31] ^= 0x01;
        assert_ne!(
            vibe_safety_number(&mine, &key(2)),
            vibe_safety_number(&mine, &tampered)
        );
    }

    #[test]
    fn the_number_is_the_advertised_length_and_all_digits() {
        let number = vibe_safety_number(&key(7), &key(9));
        assert_eq!(number.len(), VIBE_SAFETY_NUMBER_DIGITS);
        assert!(number.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn it_is_stable_across_calls() {
        // Recomputed on every screen open; a number that drifted would look
        // exactly like an attack.
        let a = key(4);
        let b = key(8);
        assert_eq!(vibe_safety_number(&a, &b), vibe_safety_number(&a, &b));
    }

    #[test]
    fn the_hex_code_is_order_independent_and_the_advertised_length() {
        let a = key(1);
        let b = key(2);
        let code = vibe_safety_code_hex(&a, &b);
        assert_eq!(code, vibe_safety_code_hex(&b, &a));
        assert_eq!(code.len(), VIBE_SAFETY_CODE_HEX_CHARS);
        assert!(code
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_ne!(code, vibe_safety_code_hex(&a, &key(3)));
    }

    #[test]
    fn identical_keys_still_produce_a_number() {
        // Degenerate but reachable — a user comparing a chat with themselves
        // (their own second device) must not hit a panic.
        let a = key(5);
        assert_eq!(vibe_safety_number(&a, &a).len(), VIBE_SAFETY_NUMBER_DIGITS);
    }

    #[test]
    fn an_empty_key_does_not_panic() {
        assert_eq!(vibe_safety_number(&[], &key(1)).len(), VIBE_SAFETY_NUMBER_DIGITS);
    }
}
