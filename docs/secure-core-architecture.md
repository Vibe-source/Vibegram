# Secure core architecture

Where Vibe's cryptography stands, what Signal actually does, and the protocol
we should ship. Companion to [security.md](security.md) and
[production-timeline-core-refactor.md](production-timeline-core-refactor.md).

Status: **design agreed, feasibility verified, not yet built.** The protocol and
implementation are chosen (§3) and the iOS build risk is retired with a working
spike (§3, *Spike results*). No production code has changed. `vibe_secure` is
the new sibling crate this lands in (§4).

---

## 1. What Signal actually does, and why "a new key per message" is not the point

A common summary of Signal is "it makes a new key for every message." That is
true and it is not the interesting part — **Vibe already does that.**
`chatEngineEncryptHybridMessage` mints a fresh AES-256 key for every single
message. If freshness were the property that mattered, we would already have it.

The property that matters is what the key is *derived from* and what happens to
it afterwards.

| | Vibe today | Signal |
|---|---|---|
| Message key | fresh random | derived from a chain key |
| Key delivery | wrapped under a **static** RSA-2048 key | never transmitted at all |
| After use | recoverable forever by the RSA key | **deleted**; derivation is one-way |
| Compromise the long-term key | every message ever sent, retroactively | nothing |
| Recover from compromise | never | automatically, after one round trip |

Our per-message key is fresh but it is *escrowed* — the static RSA key is a
master key to the entire history. Signal's is fresh and *unrecoverable*. That
distinction, not freshness, is the whole ballgame.

### The three ratchets

**1. Symmetric ratchet (forward secrecy).** Each direction of a conversation
holds a chain key. To send: `(message_key, chain_key') = KDF(chain_key)`, then
overwrite `chain_key` with `chain_key'` and delete `message_key` after use. The
KDF is one-way, so holding today's chain key tells you nothing about yesterday's
message keys. Seizing the phone gets the attacker nothing already sent.

**2. DH ratchet (post-compromise security).** Every time the conversation
changes direction, the replier attaches a **new ephemeral X25519 public key**.
Both sides do a DH against it and mix the result into a root key that re-seeds
the chains. So an attacker who steals all state at time T can read forward —
but only until the next reply, at which point a DH they did not observe locks
them out again. The session *heals itself*. This is the property no
static-key system can ever have.

**3. SPQR — Sparse Post Quantum Ratchet (Signal, 2025).** ML-KEM-768 run in
parallel with the DH ratchet, both feeding one KDF, so a message is protected
by elliptic-curve **and** lattice mathematics at once. ML-KEM keys are large
(1,184-byte encapsulation key, 1,088-byte ciphertext) so shipping one per
message is unaffordable; SPQR splits them into ~100-byte chunks spread across
messages with an **erasure code** — any 10 of ~13 chunks reconstruct the whole,
in any order, which also handles the out-of-order delivery a mobile network
guarantees. This is the "Triple Ratchet."

The session bootstraps with **PQXDH** (X3DH plus ML-KEM), so it is
harvest-now-decrypt-later resistant from the first message, not just after the
ratchet warms up.

### What Signal does about the two hard parts

Forward secrecy is the well-understood part. Metadata and media are where the
real engineering is, and they are the parts we specifically care about.

**Metadata**, in layers:

- **Sealed sender** — the sender's identity goes *inside* an envelope encrypted
  to the recipient's identity key. The server sees only "deliver to X." The
  right to send is proven with a *delivery token* derived from the recipient's
  profile key, not with the sender's account, so the server never needs to know
  who is asking.
- **Profile keys** — display name, avatar and bio are E2E encrypted under a key
  shared only with contacts. The server stores an opaque blob.
- **Private groups (KVAC)** — the group roster lives on the server
  **encrypted**, and members authenticate with a zero-knowledge anonymous
  credential proving "I am *some* member of this group" without revealing
  which one. The server operates a group it cannot enumerate.
- **Private contact discovery** — SGX enclaves, so uploading an address book
  does not hand it over.

**Honest limitation, which matters for our own planning:** sealed sender is
traffic-analysis-*resistant*, not traffic-analysis-proof. The server still
observes that account X received N messages at times T₁…Tₙ, plus IP addresses.
Published work (NDSS'21, Martiny et al.) recovers sender-recipient pairs
statistically over time. Metadata protection is a *cost-raising* exercise, and
should be sold to users as exactly that and nothing more.

**Media.** The attachment is encrypted with a key that is *not* the message
key, uploaded to a CDN as an opaque blob under an unguessable id, and — the
critical part — **the key and an integrity digest travel inside the E2E
message body.** The CDN stores bytes it cannot read and is never given the key.
Blobs expire after ~30–45 days. Signal historically used AES-CBC + HMAC-SHA256
here and moved to an incremental MAC so large attachments can be verified as
they stream rather than buffered whole.

---

## 2. Where Vibe stands

Full findings in the audit; the load-bearing ones:

| # | Finding | Effect |
|---|---|---|
| 1 | `pushPreview` sends **the first 160 chars of every message in cleartext** (`ChatEngine.swift:4792`) | Most messages are shorter than 160 chars. The envelope is decorative for text. |
| 2 | The account password *is* the private-key wrapping passphrase (`AuthViewController.swift:534-551`) | Server holds both halves at every login. E2E is nominal. |
| 3 | Groups and channels are plaintext (`ChatEngine.swift:4766`) | On a group-heavy product, most content. |
| 4 | `mediaKey` rides the wire in cleartext (`ChatEngine.swift:4827`); bucket is **public** | Encrypted blob + public URL + key handed to the server = no encryption. |
| 5 | Public keys come from the server, unpinned; `identity_key` is a version *string* | Server can MITM at will. Defeats everything else. |
| 6 | Static RSA-2048, never rotated | No forward secrecy, no post-compromise security. |
| 7 | No signatures | Authorship is a server assertion, not a cryptographic fact. |
| 8 | `type`, `reply_to_id`, `media_url`, `fileName`, lat/long in cleartext columns | Full behavioural profile without reading a word. |

Findings 1–4 are not cryptographic weaknesses. They are **plaintext leaks
around** an otherwise reasonable envelope, and they are cheap to fix. Fixing
6 before fixing 1 would be pouring a foundation next to the house.

The Rust core itself is the strongest asset we have: no primitive implemented
in-house, deny-by-default AEAD, zeroizing secret types, indistinguishable
failures, and an AAD-bound at-rest seal that is already live and already
resists row relocation. It is the right place to build and the discipline is
already correct.

---

## 3. The protocol decision: MLS, not Signal Protocol

Two credible options for the content layer.

**Option A — implement the Double Ratchet ourselves.** libsignal and SPQR are
both **AGPLv3**. For a proprietary app that is a hard blocker on linking, so
"use Signal" really means "reimplement Signal from the specs over RustCrypto
primitives." That is ~600 lines of ratchet plus X3DH plus session storage plus
skipped-key caching plus a PQ story we would own entirely. Every line is ours
to get right, and pairwise sessions cost O(N) per group.

**Option B — MLS (RFC 9420) via OpenMLS.** Apache-2.0/MIT, so it links.
Standardised, formally analysed, and as of 2026 no longer speculative: Google
Messages and Apple Messages shipped MLS over RCS in May 2026, GSMA RCS
Universal Profile 3.0 mandates it, and Wire, Webex and Discord run it in
production. Gives the same forward secrecy and post-compromise security via a
group key schedule, at **O(log N)** for group operations.

**Recommendation: MLS everywhere — a DM is a two-member group.**

**We ship zero lines of Signal code.** This is worth stating plainly because it
is the point: MLS is not "the Signal Protocol reimplemented to dodge a licence,"
which would be the legally grey option. It is a different, IETF-standardised
protocol that happens to provide the same two properties that make Signal worth
copying — forward secrecy and post-compromise security. No AGPL, no derivative
work argument, no patent surface.

### Which MLS implementation

| | **OpenMLS** | mls-rs (AWS Labs) |
|---|---|---|
| Licence | **MIT** | Apache-2.0 OR MIT |
| Third-party audit | **Yes** — SRLabs, funded by the Sovereign Tech Agency; 8 findings (1 High), 7 fixed in 8.1/7.3 | **No** — RFC 9420 conformance validated, no full audit |
| Storage | pluggable trait + **a SQLite provider** | pluggable |
| Crypto backend | RustCrypto or LibCrux | RustCrypto or OpenSSL |
| Maintainers | Phoenix R&D + Cryspen | AWS Labs |

**Pick OpenMLS.** Both licences are fine, so the audit decides it: shipping
unaudited cryptography and then marketing the result on privacy is the
contradiction we are trying to avoid. Two secondary reasons reinforce it —
OpenMLS ships a **SQLite storage provider**, and `vibe_core_store` is already
bundled SQLite with an AAD-bound seal, so MLS group state can persist through
the sealing we already trust; and the LibCrux backend is formally verified.

### Spike results — verified 2026-08-06, not predicted

OpenMLS lists iOS as *built but untested*, which was the one fact that could
have invalidated this whole plan. It was tested before anything else was
designed.

| Check | Result |
|---|---|
| Two-member group (our DM shape) seals + opens, round-tripped through TLS wire serialization | **passes** |
| `cargo build --release --target aarch64-apple-ios` | **clean**, 2m05s |
| `cargo build --release --target aarch64-apple-ios-sim` | **clean**, 1m59s |
| Static lib size | 32 MB unstripped per slice — *needs a real post-dead-strip measurement at integration* |
| GPL/AGPL anywhere in the graph | **none** |

Licence audit of the full 121-crate iOS dependency graph:

```
 51  MIT OR Apache-2.0        21  Apache-2.0        4  BSD-3-Clause
 28  Apache-2.0 OR MIT         7  MIT              4  MPL-2.0
```

The only copyleft is **MPL-2.0 on the four `hpke-rs` crates**, which is
*file-level* — linking into a proprietary application is unrestricted; the
obligation is only to publish modifications to those specific files. We do not
fork them, so there is no obligation. **Everything else is permissive.** This is
the licensing headache you asked to avoid, and it is measured, not assumed.

One unplanned finding: the graph already contains the whole formally verified
**`libcrux`** family (Apache-2.0), *including `libcrux-ml-kem` 0.0.8*. The
post-quantum primitive is already sitting in our build. That makes Phase 5
substantially nearer than a from-scratch PQ integration would be — it is
waiting on OpenMLS exposing a hybrid ciphersuite, not on us adopting a new
dependency.

Spike source: `scratchpad/mlsspike` (throwaway — the real crate is `vibe_secure`).

### Upstream gotcha found while building `vibe_secure` — read before shipping a debug build

`vibe_secure`'s "a corrupted envelope must error, never panic" test **fails in
debug and passes in release**. The cause is upstream, in
`openmls-0.8.1/src/framing/private_message_in.rs:136`:

```rust
.map_err(|_| {
    log::error!("  Ciphertext decryption error");
    debug_assert!(false, "Ciphertext decryption failed");   // ← fires in debug only
    MessageDecryptionError::AeadError
})?;
```

A `debug_assert!` sits on a path that fires **whenever a peer sends a corrupted
or tampered ciphertext** — i.e. on fully attacker-controlled input. In release
it compiles out and the function correctly returns `AeadError`; the crate's
whole test suite is **11/11 green under `--release`**.

The consequence is narrow but real: **a debug build of the app can be remotely
panicked by a hostile server or peer** simply by delivering a malformed `vmls1.`
message. Production ships release, so shipped users are not exposed.

**Resolution: `vibe_secure` guards it rather than relying on the build profile.**
The first instinct was to document the hazard and require `--release` testing.
That was the weaker answer, and the codebase already said so: `vibe_core_ffi`
has a section titled *"Panics degrade, they do not abort"* (`lib.rs:28-33`), the
same `catch_unwind` pattern at `unwrap.rs:115`, and `core/Cargo.toml:49` sets
`panic = "unwind"` workspace-wide with *"never abort: a core panic must degrade
to the Swift path, not kill the host."* `vibe_secure` processes peer-supplied
bytes and will sit behind that same FFI boundary, so it belongs to that same
threat model. A `catch_untrusted` helper now wraps the three call sites that
touch peer input — `open`, `join_from_welcome`, `add_members` — and the
panic-safety test passes under **both** profiles rather than release only.

**A caught panic poisons the session.** This is the part that differs from
`unwrap.rs`, and it matters. That site can justify `AssertUnwindSafe` because
"nothing observable is left half-written… the closure owns `mirrored` outright
and touches no shared state." `open` and `add_members` cannot make that claim:
they hold `&mut self.group` and mutate ratchet state. For the *known* panic
nothing has advanced yet — it fires at AEAD-open failure — but `catch_unwind` is
a blanket guard, and returning a plain retryable error after a mid-mutation
panic would invite a caller to reuse a half-advanced ratchet. That is the class
of state confusion that ends in key or nonce reuse, which is worse than the
crash being prevented. So a catch marks the session unusable instead.

Still true regardless: never ship a `debug_assertions` build, and this is worth
reporting upstream — a `debug_assert!` on attacker-controlled input is a defect
in any profile. (Precision, for anyone citing this later: unwinding out of
`extern "C"` has been a defined **abort** since Rust 1.71, not UB — but an abort
is exactly what the workspace policy above forbids.)

The reasons, in order of weight:

1. **Licensing decides it.** AGPL rules out the mature Signal implementation.
   Adopting a standard with an Apache-2.0 implementation is strictly less risk
   than hand-rolling a ratchet to dodge a licence.
2. **It removes our worst structural bug rather than working around it.** Vibe's
   DM-encrypted / group-plaintext split exists *because* the pairwise envelope
   has nowhere to put N recipients. One protocol for both deletes the split.
3. **Multi-device is native.** Each device is a leaf in the tree. Our current
   model — one RSA key per *account*, with a wrapped copy parked on the server —
   is finding #2, and it exists only because there was no other way to get a
   second device working. MLS makes the weakness unnecessary.
4. **We are group-heavy and agent-heavy.** O(log N) rekeying is the difference
   between a 500-member group working and not.
5. **Interop optionality.** If DMA/RCS interop ever matters, MLS is the language.

What we give up, honestly: OpenMLS has years, not a decade, of deployment;
MLS's PQ ciphersuites are landing later than Signal's; and MLS assumes a
delivery service that fans out **ordered** commits, which is real work against
Phoenix channels. None of these outweigh the licensing reality.

**Post-quantum:** treat the ciphersuite as a versioned field from day one and
ship the X25519 + ML-KEM-768 hybrid as soon as OpenMLS exposes it. RustCrypto's
`ml-kem` (FIPS 203) is audited and already the crate rustls uses. A messenger
launching in 2026 with no PQ story launches behind Signal, iMessage and RCS.

**Crate budget** (all permissive): `openmls` + `openmls_rust_crypto`,
`x25519-dalek`, `ed25519-dalek`, `hkdf`, `sha2`, `ml-kem`, `subtle`, `zeroize`.
The existing rule holds: **the core implements no primitive of its own.**

---

## 4. How it sits in the Rust workspace

A new sibling crate, not a change to `vibe_core`:

```
core/
  vibe_core/         pure · deterministic · no I/O · no network
  vibe_core_store/   bundled SQLite + AAD-bound at-rest seal
  vibe_secure/       NEW — MLS sessions, device identity, key schedule
  vibe_core_ffi/     uniffi · staticlib · owns every platform seam
```

**The dependency rule is the whole design: `vibe_core` and `vibe_secure` never
depend on each other.** They are siblings that meet only at `vibe_core_ffi`.

The reason is not tidiness. `vibe_core`'s entire value is that it is
deterministic, I/O-free and therefore fuzzable and property-testable on a
laptop — that is why the ordering/dedup reduction finally got test coverage.
An MLS state machine needs persistence, randomness and monotonic epoch state.
Merging the two would destroy the one property that makes the timeline core
trustworthy, and would force a re-verification of timeline behaviour on every
cryptographic change. Kept apart, each stays independently auditable.

They connect through the seam that already exists. `vibe_core::crypto` defines
`VibeAeadProvider` and `VibeKeyUnwrapper` as traits with deny-by-default
implementations, and the platform supplies the real ones. `vibe_secure` becomes
one more provider behind that same pattern — so **`vibe_core`'s `Cargo.toml`
gains no new dependency at all**, and a build with no provider installed still
fails closed to `DECRYPTION_FAILED` rather than rendering garbage.

Three concrete fits with what is already built:

- **MLS group state persists through `vibe_core_store`.** OpenMLS exposes a
  pluggable `StorageProvider`; our store is already bundled SQLite with an
  AAD-bound seal under a Keychain key. Implementing that trait over it means
  ratchet state inherits the sealing we already trust, instead of introducing a
  second, unsealed state file.
- **Signature keys never cross FFI.** Each device's Ed25519 identity key lives
  in the Keychain, exactly as the RSA key does today — the rule in
  `crypto.rs`'s header holds unchanged.
- **The envelope classifier already anticipates this.** `envelope.rs` detects
  format by positive test and enumerates `HybridV1`, `PlaintextPayloadJson`,
  `LegacyRsaDirect`, `AgentSealedArte1`. Adding `MlsV2` is using the extension
  point as designed. **`v1` history stays readable forever** — we add a
  format, we never re-encrypt the past.

### Linkage status (done) — and the two reasons it is not yet on the message path

`vibe_secure` is linked into the shipped artifact: it is a path dependency of
`vibe_core_ffi`, exposed through `vibe_core_ffi/src/secure.rs` as
`VibeSecureIdentityHandle` and `VibeSecureSessionHandle`, packaged into
`VibeCoreFFI.xcframework`, and exercised from Swift by
`VibeCoreBridge.secureSelfTestVerdict()` — which drives a real two-member group
(identity → KeyPackage → add commit → join from Welcome → seal → open → tampered
envelope refused). `vibe_core`'s manifest gained nothing, as intended.

Both original blockers are now **closed**:

1. **Persistent group state — done.** `VibeSecureProvider` wraps
   `openmls_sqlite_storage 0.2.0` (which pairs with our stable `openmls 0.8.1`
   via `openmls_traits ^0.5.0`, and with the `rusqlite 0.32` `vibe_core_store`
   already bundles). `VibeSecureSession::load(group_id, provider)` reloads a
   persisted group, and Swift remembers `chat id -> group id` so a relaunch
   continues the same conversation instead of minting a new group and orphaning
   everything sealed before the restart. Proven by a test that seals, drops every
   Rust value, reopens from the same paths and decrypts — an in-memory provider
   passes every other test and fails only that one.
2. **KeyPackage distribution — done.** `POST /api/mls/key-packages`,
   `GET /api/mls/key-packages/:user_id`, `GET .../count`. Claiming is a single
   atomic `UPDATE ... RETURNING` against an unclaimed row, because a KeyPackage
   carries a **one-time** init key and handing the same one out twice would break
   the forward secrecy this whole migration exists for. A concurrency test proves
   N parallel claims yield N distinct packages.

**A note on threading that the type system forced and is worth keeping:**
`rusqlite::Connection` is `Send` but not `Sync`, and a uniffi object must be
both, so the provider sits behind a `Mutex` and MLS operations serialize per
identity. Lock order is **session-then-provider everywhere**; nothing takes them
in the other order, which is what keeps it deadlock-free.

### Session establishment — done for DMs, not for groups

`VibeSecureEstablishment` (iOS) now does the three things that were missing:
publishes a pool of this device's KeyPackages, claims a peer's and delivers a
Welcome on first send, and drains + joins + acks Welcomes on chat join. The
Welcome rides a dedicated endpoint rather than the chat channel, so no client
can render one as a message.

**The send path fails closed.** A DM that should be end-to-end encrypted and has
no session is queued as `pending` and establishment is kicked off; it is
released only by a successful establishment. It never falls through to the
cleartext branch. This reuses the queue-and-replay path the engine already had
for a missing friend key rather than inventing a second mechanism.

Only three kinds of chat can still reach the cleartext branch, and the branch
now says so in a comment: **groups** (the real gap — see below), **agent chats**
(the agent runs server-side and must read the message to answer it, so this is
deliberate) and **saved messages** (sealed by the store layer instead).

**Groups are covered too, up to a member cap.** `GET /mls/chats/:chat_id/members`
(participants only, 404 for anyone else) supplies the membership, and
`establishGroup` claims one KeyPackage per member, adds them all in a single
commit, and posts the resulting Welcome to each. It is **all-or-nothing**: if
any member has no KeyPackage to claim, nothing is established. A member silently
left out of the group would never see the conversation again, which is a much
worse failure than the sender waiting for a retry.

`isChannel` is now carried in the send payload (`ChatListView` → `ChatEngine`),
so a channel is routed on what it *is* rather than inferred from its size.

### Channels take the other scheme, and it is not yet wired

Channels are excluded from MLS deliberately. A subscriber expects to scroll back
through everything posted before they joined, and MLS structurally cannot give
them that — a joiner starts at the current epoch and has no way to read earlier
ones. That is not a limitation to work around; it is the forward secrecy MLS is
chosen for.

`vibe_core::group` already implements the right scheme for this and is fully
tested: per-epoch AES-256 keys, where a new member *can* be handed older epoch
keys (`backfill_historical_epoch`) and so *can* read history, and where removal
mints a new epoch the departing member never receives. It scales to a broadcast
audience because a membership change costs one key, not one commit per member.

| | MLS | epoch keys |
|---|---|---|
| forward secrecy | yes | no |
| post-compromise security | yes | no |
| scales to thousands | no | yes |
| new joiner can read history | **no** | **yes, if given the keys** |

It has **no FFI export and no iOS caller**, so it does nothing today. Wiring it
is the remaining work and it is not small: FFI surface, keyring custody on
device, and epoch-key distribution to each member (which rides the existing 1:1
hybrid envelope, and can reuse the Welcome relay's shape).

**Until that lands, channels and any chat over the 256-member cap still send
plaintext to the server, and the UI must not claim otherwise.**

**Human DMs are MLS-only.** There is no fallback envelope: a DM either seals
under a confirmed MLS session or stays queued locally until the peer joins and
acknowledges the Welcome. `VibeSecureSessions.isGroupSendEnabled` is a
group-only off switch; human DMs ignore it.

**A first-contact race exists and is resolved deterministically.** Two devices
can both establish the same chat at once; each then holds a different group.
`resolveCollision` picks the lower group id, and both sides apply the same rule
to the same pair, so they converge without another round-trip. Messages sealed
under the losing group in that window are unreadable afterwards — acceptable for
a first-contact-only window, and far better than two devices talking past each
other forever.

Two things that are genuinely new work, and neither is cryptography:

1. **Ordered commit fan-out.** MLS requires the delivery service to serialize
   Commits per group. Phoenix channels do not guarantee that today. The fix is
   a per-group monotonic epoch counter server-side: reject a Commit that does
   not build on the current epoch, client re-fetches and re-proposes. Standard
   MLS delivery-service behaviour, but real Elixir work. Concrete contract:
   [`docs/mls-commit-fanout.md`](mls-commit-fanout.md). Not implemented —
   any group that adds a member after founding is permanently split today.
2. **KeyPackage distribution.** Replaces public-key fetch. Each device
   publishes KeyPackages; the server hands them out and must not be able to
   substitute them undetectably — which is what Phase 1's identity pinning and
   safety numbers are for.

---

## 5. Metadata plan

Ordered by privacy-won per unit of work. The first two are not cryptography.

**M1 — Delete the leaks (days).** `pushPreview`, `type`, `fileName`, lat/long,
and `media_url` are already duplicated *inside* the encrypted payload. Stop
sending the outer copies. Push notifications become content-free ("New
message") with the body decrypted on-device by a Notification Service
Extension — the standard iOS pattern and what Signal does. This single change
recovers more real privacy than the entire ratchet, because today the ratchet
would be protecting a payload whose text is also sitting in a cleartext column
next to it.

**M2 — Length hiding (days).** Pad plaintext to buckets (256 B / 1 KiB / 4 KiB
/ 16 KiB) inside the core before sealing. Kills "that was a one-word reply."

**M3 — Sealed sender (weeks).** Sender identity moves inside the envelope;
send-authorisation moves to a recipient-derived delivery token. Requires
rethinking socket auth, which currently stamps `from_id` from the authenticated
socket (`chat_channel.ex:2096`) — that stamp is exactly the metadata we are
trying to stop collecting, so it is a real refactor and not a flag flip.

**M4 — Encrypted group roster (weeks).** MLS does *not* hide membership from
the delivery service on its own. Either adopt KVAC-style anonymous credentials
or accept roster visibility for v1 and say so plainly.

**M5 — Private contact discovery (months).** Needs enclaves. Defer, and
reconsider whether we need phone-number-based discovery at all — the cheapest
private contact discovery is not collecting the address book.

**Say M3–M5 are not shipped until they are.** Claiming metadata protection we
do not have is the one mistake that converts a security story into a liability.

---

## 6. Media plan

1. **Move `mediaKey` inside the sealed payload only.** Delete
   `wirePayload["mediaKey"]`. One line, closes finding #4.
2. **Unguessable object ids**, decoupled from user/chat id, and drop
   `media_url` from the cleartext column — the URL goes inside the envelope.
3. **Adopt `vmed2`**, already specified in `core/vibe_core/src/media.rs` and
   deliberately left unimplemented. Segmented AEAD lets us verify and release
   media as it streams instead of buffering an entire file twice, which is the
   memory problem the module header already documents.
4. **Per-attachment keys**, not the message key, so forwarding media does not
   forward the ability to read the conversation.
5. **Server-side expiry** on blobs.

---

## 7. Phasing

**Phase 0 — Stop the bleeding. Blocks launch. ~1 week, no new cryptography.**
- M1: kill `pushPreview` and the duplicated cleartext columns
- Split the auth secret from the key-wrapping passphrase (finding #2):
  `authSecret = HKDF(recovery, "vibe/auth/v1")` to the server,
  `kek = PBKDF2(recovery, "vibe/kek/v1")` never leaves the device
- `mediaKey` out of the wire payload
- M2: length padding

Phase 0 alone converts "E2E in the marketing copy" into "E2E in fact." Until it
lands, the encryption claim is not defensible — and a false encryption claim is
a regulatory exposure, not only an engineering one.

### Phase 0 detail — the auth-secret split (implemented, run `securecore-0806`)

Finding #2 was that one string did three jobs: login `credential`, login
`password`, and the PBKDF2 passphrase wrapping `encrypted_private_key` — a copy
of which the server stores. Every login handed the server both halves.

Split by domain, so the server only ever sees one-way derivations:

```
lookupId   = HKDF-SHA256(recoverySecret, info = "vibe/lookup/v1")   → `credential`
authSecret = HKDF-SHA256(recoverySecret, info = "vibe/auth/v1")     → `password`
kek        = PBKDF2-SHA256(recoverySecret, salt = username, 600k)   → never transmitted
```

This is sound **only because the recovery secret is 24 random bytes (192 bits)**,
so brute-forcing it back through 600k PBKDF2 is infeasible. It would not hold for
a user-chosen password, which is why one must never be introduced on this path.

**The KEK derivation is deliberately unchanged**, and that is the whole safety
argument for the migration: `encrypted_private_key` never has to be re-wrapped,
so no migration step can destroy key material. The worst possible failure is a
rejected login, which is recoverable by rollback. Re-wrapping would not be.

Rollout is a fallback chain rather than a flag day: a v3 client tries the derived
credentials, and a pre-v3 account simply misses that lookup, so it retries the
legacy pair once and then calls `POST /api/upgrade-identity` (bearer-authed with
the token just issued) to rotate `password_hash` and `secure_id` onto the derived
values. After that the raw secret is never transmitted for that account again.
`secure_id` rotates in lockstep — it is the lookup handle — so the endpoint
returns the new value, which the client cannot recompute because the pepper is
server-side.

The one honest gap: a legacy account's *final* pre-upgrade login still sends the
raw secret once. There is no way around that — it is the only thing a pre-v3
record can be authenticated against.

**Phase 1 — Identity. Blocks launch. ~2 weeks.**
Real Ed25519 identity key per device in the Keychain, TOFU pinning, safety
numbers in the UI, loud warning on change, signed envelopes. Closes findings
#5 and #7. Without this the server can MITM, and every later phase is built on
keys the server chose.

**Phase 2 — MLS in the core. ~6–10 weeks.**
OpenMLS behind a `VibeSecureSession` trait in `vibe_core`, group state in the
existing AAD-bound sealed store, `v2` envelope alongside `v1` for history,
Phoenix-side ordered commit fan-out. DMs are two-member groups. Per-device
leaves — this is where multi-device stops being a hack.

**Phase 3 — Groups migrate. ~3 weeks.** Groups and channels move onto the same
MLS sessions. Retire the plaintext path and the `vgrp2.` epoch design in
`group.rs`, which was the right answer only while the pairwise envelope was the
constraint.

**Phase 4 — Metadata and media hardening.** M3, M4, `vmed2`, blob expiry.

**Phase 5 — Post-quantum.** X25519 + ML-KEM-768 hybrid ciphersuite.

**Continuous:** reproducible builds and a third-party audit before any public
claim. An unaudited protocol marketed as Signal-grade is a claim we cannot
support.

---

## 8. What to say to users

Only what is true at that moment. Concretely, after Phase 2 we can say: message
content is end-to-end encrypted with forward secrecy and post-compromise
security, using the same IETF standard shipping in RCS. We cannot say the
server is blind to who talks to whom until Phase 4, and we should not imply it.
Under-claiming and over-delivering is the only durable position in this
category, because the one thing users never forgive is discovering the promise
was thinner than it sounded.

---

## Sources

- [Signal: Signal Protocol and Post-Quantum Ratchets (SPQR)](https://signal.org/blog/spqr/)
- [signalapp/SparsePostQuantumRatchet](https://github.com/signalapp/SparsePostQuantumRatchet) (AGPLv3)
- [Signal: Sealed sender](https://signal.org/blog/sealed-sender/)
- [The Signal Private Group System (KVAC)](https://eprint.iacr.org/2019/1416.pdf)
- [Improving Signal's Sealed Sender, NDSS'21](https://www.cs.umd.edu/~kaptchuk/publications/ndss21.pdf)
- [RFC 9420 — MLS Protocol](https://datatracker.ietf.org/doc/rfc9420/)
- [RFC 9750 — MLS Architecture](https://datatracker.ietf.org/doc/rfc9750/)
- [MLS adoption trends, 2026](https://www.gopher.security/post-quantum/messaging-layer-security-adoption-trends)
- [RustCrypto ml-kem (FIPS 203)](https://crates.io/crates/ml-kem)
- [Reviewing Signal's Cryptography — attachments](https://soatok.blog/signal-crypto-review-2025-part-4/)
