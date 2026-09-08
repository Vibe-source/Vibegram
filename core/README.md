# `core/` — Vibe's cross-platform message core

A Rust workspace holding **`vibe_core`**: the deterministic, host-only timeline
core. Nothing here is linked into the iOS app, the Android app, or the web
client. There is no FFI layer, no SQLite, no network, and no platform
dependency.

Full design, migration plan, threat model and rollout gates:
[`../docs/production-timeline-core-refactor.md`](../docs/production-timeline-core-refactor.md).

---

## Why this exists

Read this before budgeting time against it.

**A Rust core does not make scrolling smoother.** The measured scroll costs in
this repository are an unbounded rows array, main-thread manual sizing, per-row
E2E decrypt during parse, and `queue.sync` from the main thread into the engine.
Every one of those is fixable in Swift. What the core actually buys:

1. **One protocol implementation instead of three.** iOS Swift
   (`ios/ChatModule/ChatEngine.swift`, 14,535 lines), Android Kotlin
   (`android/chat-module/.../ChatEngine.kt`, 5,160 lines) and web TypeScript
   (`client/src/crypto.ts`) each implement the same envelope format, and they
   have already diverged on a security-relevant path.
2. **Determinism you can fuzz and property-test.** The ordering/dedup reduction
   (`ChatEngine.mergedChatRowsLocked`) is ~210 lines of ordering-sensitive
   heuristics with no test coverage. It is ported here with a test per heuristic
   and the shipped constants carried over verbatim.
3. **A place to put ciphertext-at-rest.** The iOS SQLite cache currently stores
   the fully decrypted row as JSON.

---

## Layout

```
core/
  Cargo.toml          workspace + shared lints
  Cargo.lock          committed: this is an application dependency graph
  vibe_core/
    src/
      types.rs        the five frozen contracts and their supporting records
      reducer.rs      the only stateful type: per-chat state machine
      canonical.rs    raw server frame → VibeMessageSnapshotV1
      envelope.rs     strict versioned codec for `encrypted_content`
      crypto.rs       AEAD boundary; no primitive implemented here
      secret.rs       zeroizing, non-Debug, non-serializable secret containers
      order.rs        total order + settle-slot adoption
      dedup.rs        the four dedup predicates + stale-stream settling
      receipts.rs     per-reader receipt lattice + read cursor
      window.rs       bounded window policy + anchor resolution
      delta.rs        typed ordered deltas + a reference applier
      media.rs        media addressing, envelope classification, byte validation
      hash.rs         FNV-1a change detection (not a security primitive)
      fixtures.rs     synthetic, deterministic corpora
      error.rs        typed errors that never carry content
    tests/
      replay.rs           determinism, generations, tombstones, id healing, agents
      invariants.rs       proptest properties
      envelope_corpus.rs  malformed input
      no_leakage.rs       nothing secret in Debug/errors/counters
      soak.rs             bounded windows at scale + the 100k benchmark
```

Start with `types.rs` — it is the contract. Then `reducer.rs`. Everything else
is a pure function it calls.

---

## Commands

```bash
cd core

# Everything the brief gates on:
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test  --all-targets --all-features

# Fail-closed configuration: no algorithm compiled in at all.
cargo clippy --all-targets --no-default-features -- -D warnings
cargo test   --all-targets --no-default-features

# The 100k / 50-events-per-second benchmark (ignored by default).
cargo test --release --all-features -- --ignored --nocapture
```

`core/target/` is build output. The repository root `.gitignore` does not yet
cover it — either add `core/target/` there (an integrator-owned file) or build
with `CARGO_TARGET_DIR=/tmp/vibe-core-target`.

---

## Rules this crate holds itself to

| Rule | Where it lives |
|---|---|
| No cryptographic primitive is implemented here | `crypto.rs` — only `aes-gcm`, behind a trait |
| RSA and private-key custody stay on the platform | `crypto::VibeKeyUnwrapper` |
| Fails closed with no provider | `VibeDenyAllAead`, `VibeDenyAllKeyUnwrapper` |
| No untyped map in public egress | `types.rs`; `serde_json` never leaves `canonical.rs` |
| No media or thumbnail bytes in a snapshot | `VibeThumbHandle`, `VibeThumbnailBlob` |
| Plaintext and keys have no `Debug` and no serde | `secret.rs`, `tests/no_leakage.rs` |
| Agent `arte1` payloads are opaque, never opened | `VibeOpaqueBlob` |
| Every query and delta is bounded to 300 messages | `window.rs`, `tests/soak.rs` |
| `unsafe` is forbidden | workspace lint `unsafe_code = "forbid"` |
| Fixtures are synthetic; no production plaintext | `fixtures.rs` |

## Measured (2026-08-02, release, Apple silicon laptop)

| Operation | Store size | Cost |
|---|---|---|
| Ingest one message | 100,000 | 8.1 µs |
| Ingest + flush at 50 events/s | 100,000 | 10.0 µs/event |
| Scroll-back one page | 100,000 | 303 µs |
| Largest delta during replay | 100,000 | 51 ops |

These are laptop numbers for the *reduction*, not device frame times. The device
gate lives in the iOS replay harness, not here.
