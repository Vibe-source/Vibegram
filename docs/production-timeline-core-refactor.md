# Production timeline/core refactor — source of truth

**Status:** P1 green. **P2 complete and verified on a physical device** — the
Rust core is cross-compiled, packaged as an XCFramework, linked into the app,
and builds clean for the iPhone 16 Pro Max at **+1.91 MB**. **P3 complete** —
`ChatMessageStore` seals every message body at rest through the core's sealer;
the store is no longer plaintext and the core is no longer dark. **P4 render
path landed, read authority not taken** — the adapter, the `UICollectionView`
host, and the gated `ChatListView` branch all exist and build; the branch runs
the core in **shadow only** (order comparison, renders nothing). Shadow
comparison arms itself in debug builds so divergence data accumulates from real
DMs; the render-path flag stays default-off in every configuration. Group E2E is
**specified and implemented in the core, not enabled and not wired to any
platform**.

**What the core is NOT doing yet, stated plainly:** it does not order the
production list, does not size a single row on screen, and is not fed by the
real ingest pipeline — the shadow probe re-ingests rows the engine already
built. Every row the user sees is still ordered, parsed, measured and rendered
by `ChatListView`.

**On-device evidence (2026-08-02, iPhone 16 Pro Max):** the core's reducer was
exercised through the preview surface across **503 windows / 372 messages** with
scrambled timestamps and duplicate ids — **503 ordering ok, 503 dedup ok, zero
failures**, window holding at the 200-row cap. That is the P4 entry gate for
ordering and dedup; the §9.1 render gates are still unmeasured.
**Owners:** core/crypto/FFI — claude-opus · store — grok · packaging/diagnostics
— agy · contract review, phase split, verification — integrator.
**Last verified against the working tree:** 2026-08-02.

**Gate state as of this revision** (all run locally, none on CI yet):

| Gate | Result |
|---|---|
| `cargo fmt --check` | ok |
| `clippy -D warnings`, both feature configs | ok |
| `cargo test` | **136** `--all-features`, **113** `--no-default-features` |
| `vibe_core_ffi` | clippy clean, **10** boundary tests |
| `vibe_core_store` | **33** tests |
| `cargo deny check advisories bans licenses sources` | ok (`core/deny.toml`) |
| iOS device build (Debug, arm64) | **BUILD SUCCEEDED** |
| Binary delta | **+1.91 MB** vs 2026-08-01 baseline (budget +1.5–3 MB) |

The device build is the one that matters most: it proves the static library
links, the generated Swift compiles, and the notification-extension target still
builds with its `OTHER_LDFLAGS` cleared (§3.4). It does **not** prove anything
about rendering, because nothing renders from the core yet.

This document is the standing plan for turning Vibe's message stack into
something that can serve iOS, Android and web from one implementation, without a
rewrite and without a cutover. It is not a phase note: it records what is
actually true today, what changes, in what order, behind which flag, and what
would make us stop.

Related: [`scale-readiness-group-rendering.md`](scale-readiness-group-rendering.md)
(renderer verdict), [`scale-readiness-data-layer.md`](scale-readiness-data-layer.md)
(server/DB), [`chat-pipeline-architecture-v2.md`](chat-pipeline-architecture-v2.md)
(the current delta pipeline), [`security.md`](security.md) (posture).

---

## 0. Read this first

**A Rust core does not make scrolling smoother.** Say that out loud before
anyone budgets time against it.

The measured scroll costs in this repository are:

1. an unbounded rows array for non-agent chats,
2. main-thread manual sizing,
3. per-row E2E decrypt during parse,
4. `queue.sync` from the main thread into the engine.

Every one of those is fixable in Swift, and
`scale-readiness-group-rendering.md` already reached that verdict. If the goal
is "the list feels better", the core is not the lever.

What the core actually buys is different, and still worth buying:

| Buys | Does not buy |
|---|---|
| One protocol implementation instead of three | A faster frame |
| A deterministic reduction that can be fuzzed and property-tested | A smaller app |
| A place to put ciphertext-at-rest | A shorter path to launch |
| Validated media bytes and one cache identity across platforms | Group encryption (that is its own program) |

**Smallest safe first step, already done:** a host-only crate with no FFI, no
SQLite, no network, and no production file touched. It is `core/vibe_core`.
Rollback is `rm -rf core/`.

---

## 1. Verified current architecture

Everything in this section was read out of the working tree on 2026-08-02.

### 1.1 Three implementations of one protocol

| Platform | File | Size |
|---|---|---|
| iOS | `ios/ChatModule/ChatEngine.swift` | 14,535 lines |
| Android | `android/chat-module/src/main/java/expo/modules/vibechatnative/ChatEngine.kt` | 5,160 lines |
| Web | `client/src/crypto.ts` + `client/src/components/Chat.tsx` | 304 lines + view |

They have **already diverged on a security-relevant path**: the web decryptor
accepts a legacy bare-base64 RSA-direct ciphertext (`client/src/crypto.ts`), iOS
does not (`ChatEngine.swift:9053-9066` requires `{iv,c,k}` JSON and otherwise
falls through to the plaintext parser, i.e. renders base64 as literal text). A
user with pre-hybrid history reads it on the web and sees base64 on the phone.
That bug class is structural; only a shared implementation removes it.

### 1.2 The render path

```
Home row tap
  → AppShellCoordinator.openChat(ChatRoute)
  → ChatConversationController.prepareForNavigationPush(in: nav)   // window-attached, hidden
       → setRows seed · safe-bottom prestage · layoutIfNeeded
  → nav.pushViewController(animated: true)
  → viewDidAppear → completeTranscriptPresentation()
       → apply deferred rows → refreshRowsFromEngineDelta() → setRows
       → scheduleProgressiveHeightWarmup()
```

Surface stack: `ChatConversationController` → `ChatMainView` → `ChatListView`
(`UICollectionView` + custom flow layout, 22,848 lines).

**The commit-first contract is already the shipped behaviour and is not
negotiable:** real list pixels exist *before* `pushViewController`; rows and
geometry are immutable through the transition; reconcile happens after
`viewDidAppear`. No loader, no fade, no artificial navigation delay, and no
empty list is an acceptable migration strategy.

### 1.3 Measured evidence

| Signal | Measurement | Source |
|---|---|---|
| `setRows` total | **50–80 ms** (`[MainThreadStall] setRows took 74ms mergeMs=3 parseMs=15 applyMs=54`) | device logs |
| Agent turn build | ≥8–10 ms per row; **100–500 ms** for a screenful of rich cells | `scale-readiness-group-rendering.md` |
| `ChatEngine.syncOnQueue` from a UI getter | **~77 ms** main-thread stall; the engine already prints `[ChatEngine][MAIN-THREAD-HANG]` | `ChatEngine.swift:13835` |
| Push safe-bottom correction | **~34 pt** (`[ChatOpen] safe-bottom FINAL … delta=`) | device logs |
| Plain-text height estimate error | systematically **~+16 pt**, doubled on send | grok findings |
| Live agent first chunk | estimate ~122 pt vs real ~44 pt → **34–78 pt** visible gap | `[LayoutShift]` logs |
| Voice / video-note / sticker estimates | −3 pt / ~20 pt collapses | `[CellFit]` logs |
| Rendered-row cap | **agent DMs only** (40). Groups, channels and normal DMs are **unbounded** | `ChatListView` |

Two of these are contract bugs rather than performance bugs: the height
estimates and the unbounded array. Both are addressed by the render contract in
§5 rather than by the core.

### 1.4 Ordering and dedup, today

`ChatEngine.mergedChatRowsLocked` (`ChatEngine.swift:9215-9425`) is ~210 lines
of ordering-sensitive heuristics with **no test coverage**. It carries
load-bearing constants that were each tuned against a real incident:

| Heuristic | Constant |
|---|---|
| Mirrored-prompt dedup | 48 h (`bridgeMirrorDedupWindowMs`, `ChatEngine.swift:3099`) |
| Persisted agent twin | 5 min |
| Stale streaming, history-only | 3 min |
| Stale streaming, also live | 60 min |

Porting this to a pure function with a fixture corpus was the single
highest-confidence-per-hour item in the whole plan, and it is the bulk of what
P1 delivered.

---

## 2. What improves scroll vs what improves cross-platform and security

Stated separately so neither is used to justify the other.

### Improves scroll

| Work | Owner | Needs the core? |
|---|---|---|
| Bounded 150–300 message window for **all** chat classes | renderer + core | No — Swift can do it |
| Off-main decrypt and canonicalization | engine | No |
| `VibeChangeMask`-driven reconfigure-vs-relayout | renderer + core | No, but the mask makes it data instead of convention |
| Durable natural size so settled geometry is immutable | core + renderer | No |
| Retiring `syncOnQueue`-from-main | engine | No — the core makes it structurally impossible |

### Improves cross-platform and security

| Work | Needs the core? |
|---|---|
| One envelope implementation instead of three | **Yes** |
| Fuzzable parsers over attacker-influenced bytes | **Yes** |
| Ciphertext-at-rest for the local cache | **Yes** (or a Swift-only equivalent) |
| Validated media bytes (the poisoned-cache bug class) | **Yes** |
| One media cache identity across platforms | **Yes** |
| An accurate statement of the group-plaintext posture | No — it is a documentation fix |

**Neither list changes a frame time by itself.** The scroll column is the one
that does, and most of it is achievable without Rust.

---

## 3. Current security posture — honest

`docs/security.md` carries a current-status warning as of 2026-08-02. This
section is the engineering detail behind it.

### 3.1 The wire format, as it actually is

`ChatEngine.swift:199-244` / `246-319`, mirrored in `client/src/crypto.ts`:

```
encrypted_content = JSON string:
{ "v":1,
  "iv": b64(12-byte random IV),
  "c":  b64(AES-256-GCM ciphertext || 16-byte tag),   // tag appended
  "k":  b64(RSA-2048-OAEP-SHA256(aes_key) to recipient),
  "s":  b64(RSA-2048-OAEP-SHA256(aes_key) to sender)   // optional
}
```

Key-candidate order is **direction-dependent** and must be reproduced exactly:
`g` first when present, then `s,k` for own messages and `k,s` for peer messages
(`ChatEngine.swift:268-296`).

**The `g` slot is read by every client and written by none.** It is a reserved
group-key slot. A core that started emitting `g` would be interpreted as a group
key by every deployed client. `vibe_core` parses it and never writes it, and
there is a test asserting that.

Media blobs (`ChatEngine.swift:321-353`): `12-byte IV || ciphertext || 16-byte
tag`, media key carried inside the message payload, applied to `image, gif,
voice, music, video, file, sticker`. Everything else uploads in the clear.

Saved Messages: sealed to self, `k == s == own public key`.
Agent runtime: `arte1.<b64 iv>.<b64 ct>.<b64 tag>` under a pairing key held only
on the phone.

### 3.2 Groups and channels are not end-to-end encrypted

`ChatEngine.swift:4510-4512`:

```swift
if isGroup || friendPublicKey == nil {
  encryptedContent = fullPayloadString      // plaintext JSON in `encrypted_content`
}
```

The server stores that string verbatim (`chat_channel.ex:144` binds
`encrypted_content: data["encryptedContent"]` with no at-rest wrap). There is no
group key anywhere in the server, the iOS client, or the web client.

**Correction, 2026-08-02.** An earlier revision of this document claimed the
second branch meant "a 1:1 DM also falls back to plaintext whenever
`friendPublicKey == nil`". That was read off the `||` without following the
control flow, and it is **wrong**. `friendPublicKey` is only ever `nil` because
an earlier branch deliberately set it so (`ChatEngine.swift:4042-4086`):

| Case | `friendPublicKey` | Reaches the plaintext branch? |
|---|---|---|
| Group or channel | `nil` by design | **yes** — the real gap |
| Agent-peer chat (`peerAgentId`) | `nil` by design | **yes** — server-side agent must read it |
| Saved Messages | `nil` here, but returns at `:4419` via `sendSavedMessage` | no — sealed to self, `k == s == own key` |
| Human 1:1 DM, key unresolved | never assigned | **no** — the send is queued `pending`, a key fetch is scheduled, and it returns early |

So a human 1:1 DM **never** silently downgrades to plaintext; it refuses to send
until the peer key resolves. The plaintext branch is reachable only for groups,
channels, and agent-peer chats. That is a materially smaller and better-behaved
bug than the earlier text described, and the difference matters: one is an
unfinished feature, the other would have been an active lie to the user.

Agent messages authored server-side get `agm1` AES-256-GCM at rest
(`server/lib/vibe/chat/agent_message_crypto.ex`) under a key derived from
`SECRET_KEY_BASE`. That is **server-held**: it protects a stolen database dump
or backup, and it protects nothing against the server itself, an insider, or a
compromised host. It is at-rest encryption and must never be described as
end-to-end.

Consequences for this program, and none of them are "fix it in the core":

- The core **must not** assume `encrypted_content` is an envelope. Detection
  stays exactly the shipped rule — `{` prefix, parses as a JSON object, has
  `iv`+`c`+`k` — reimplemented bit-identically
  (`vibe_core::envelope::classify`).
- The core **must not** silently start encrypting groups. Turning it on before
  every member's client understands the format does not degrade a group, it
  **splits** it into members who can read and members who cannot. See §3.6 —
  the design now exists, and the gate against exactly this is a type.
- It **is** a standing security item. Correcting the documentation is not the
  same as fixing the protocol, and the doc must not imply otherwise.

### 3.6 Group E2E — decided 2026-08-02, implemented, not enabled

**Decision: per-epoch symmetric group keys**, in `vibe_core::group`.

A group owns a monotone sequence of epochs; each epoch owns one AES-256 key held
by exactly that epoch's members. A message is sealed under the epoch current at
send and records its epoch. **Membership changes mint a new epoch** — which is
what makes removal mean anything: a removed member keeps the epoch keys they
already had (you cannot un-read history someone could already read) but never
receives the next one.

Distributing an epoch key is deliberately *not* the core's job. It rides the
existing 1:1 hybrid envelope, which is already end-to-end and already works.
That is why this design is small: per-member key agreement is already solved
here, so groups reduce to shipping one symmetric key over a working channel.

Wire format, prefix-detected exactly like `arte1.` and `vmed2`:

```
vgrp2.<b64(epoch, 4 bytes LE)>.<b64(12-byte IV)>.<b64(ciphertext || 16-byte tag)>
```

AAD binds `group_id ‖ 0x1F ‖ epoch`, so a ciphertext cannot be replayed into
another group or another epoch. Both are tested.

**It is a new format rather than an overload of the hybrid envelope**, and the
reserved `g` slot stays parsed-never-written. Two reasons: the shipped
classifier requires `iv`+`c`+`k` before it treats a string as hybrid, and a
group envelope has no per-recipient `k` to offer; and a deployed client meeting
an unknown *prefix* renders literal text — visibly "update your app" — whereas a
hybrid envelope it cannot open renders base64 garbage or an empty bubble.
Failing loudly is the better failure.

Rejected, with reasons:

| Option | Why not |
|---|---|
| Per-message RSA wrap to every member | `encrypted_content` is one column shared by every reader; N per-recipient blobs need a schema change and an N-way fan-out per send |
| Sender keys (Signal/WhatsApp) | Strictly better — adds forward secrecy — but needs a per-sender ratchet, ratchet state surviving reinstall, and a skipped-key cache. Deferred, **not precluded**: a ratchet can be added *inside* an epoch without changing the envelope or stored history, because the epoch id already says which regime applies |
| MLS (RFC 9420) | Right long-term answer for large groups; a heavyweight dependency, a wire change and a multi-week program that would swallow this refactor |

**Channels are explicitly out of scope for E2E and that is a decision, not a
gap.** A broadcast channel with thousands of subscribers cannot be meaningfully
end-to-end: any subscriber can leak, and key distribution at that fan-out is a
broadcast problem, not a crypto one. Telegram does not E2E channels either.
Channels get at-rest encryption and honest labelling.

**What is deliberately still missing.** The core half is done — keyring,
monotonicity, envelope, AAD binding, fail-closed behaviour, 16 tests. Not done,
and each is its own piece of work: epoch-key distribution over the 1:1 channel,
the server-side membership-capability signal that drives
`VibeGroupSealAuthorization`, epoch rotation on membership change, and any iOS
wiring. **No group message is encrypted by this revision.**

### 3.3 The local cache holds plaintext

`ios/ChatModule/ChatMessageStore.swift:45-50` — `messages.payload BLOB` holds
the **fully decrypted normalized row as JSON**: message text, `thumbnailBase64`,
`mediaKey`, and the original `encryptedContent` side by side
(`ChatEngine.swift:10206-10243`, `12209-12228`).

The cache is sandboxed by iOS and inherits file protection, but it is not sealed
by an application-level at-rest key. §7 fixes this for a new table without a
destructive migration; the old table keeps its contents until it is removed,
which is why the retention window in §7.4 matters.

### 3.4 Notification service extension

- The NSE compiles only `NotificationServiceExtension/` + `Shared/`
  (`ios/project.yml`), and **there is no App Group**. It cannot see the app's
  SQLite store and it never decrypts anything today — the server sends a
  plaintext preview which the NSE re-renders.
- In-extension decryption would need `group.com.vibegram.app`, a Keychain access
  group, and a **second SQLite writer**. WAL plus a 128 MB-capped, killable
  extension process is a genuine corruption risk, and `busy_timeout=2000` inside
  a 30-second extension budget is a stall risk.
- **Rule:** if the core ever enters the NSE it enters in `decrypt-only,
  no-store` mode with the store trait unimplemented. No database in the
  extension.
- `ios/project.yml` deliberately clears the inherited `OTHER_LDFLAGS` and
  bridging header for the extension target. Any core linkage must repeat that
  discipline or the extension link breaks. This has bitten the project before.

### 3.5 Background execution and data protection

- The engine gates realtime demand on `didBecomeActive`/`didEnterBackground`
  (`ChatEngine.swift:695-710`), with a comment explaining why
  `willResignActive` is the wrong signal (Control Centre and Notification Centre
  would kill the socket). The core's worker thread must follow the same signal.
- **Do not raise the DB protection class to `NSFileProtectionComplete`.** Push
  wake-ups and background refresh write while the device is locked; `Complete`
  makes those writes fail. `CompleteUntilFirstUserAuthentication` is correct and
  matches the Keychain accessibility already chosen
  (`SecureKeyStore.swift:24`). Declare it explicitly rather than inheriting it.
- The core needs a `suspend()` that flushes and closes cleanly on
  `didEnterBackground`. An interrupted WAL write is recoverable; a half-written
  backfill batch must be transactional.

---

## 4. Target architecture

### 4.1 Responsibilities

| Area | Core | Platform |
|---|---|---|
| Envelope codec, canonical JSON | ✅ | — |
| Frame → snapshot canonicalization | ✅ | — |
| Ordering, dedup, tombstones, edits, receipts, unread | ✅ | — |
| Bounded windowing, anchors, paging, deltas | ✅ | — |
| Persistence schema, sealing, retention | ✅ (behind a trait) | supplies the store impl |
| Media envelope encode/decode, cache identity, validation | ✅ | file I/O, decode, playback |
| **RSA / private-key custody** | ❌ never | ✅ Keychain / Keystore / WebCrypto |
| **Networking, TLS pinning, retry** | ❌ | ✅ |
| **UI, layout, text measurement** | ❌ | ✅ |
| **Push presentation, background scheduling** | ❌ | ✅ |
| **Agent bridge protocol semantics** | ❌ opaque bytes | ✅ |

### 4.2 Threading

The core owns **one worker thread** and a command queue. There is **no
synchronous read API.** The UI:

1. submits commands (`ingest`, `open_chat`, `page`, `set_read_cursor`, …),
2. receives `VibeTimelineDeltaV1` / `VibeTimelineWindowV1` on a platform-supplied
   dispatch handle,
3. renders **only** from its own last-committed immutable snapshot.

"UI must never query a locked engine synchronously" is therefore satisfied
structurally: there is nothing to call. That retires `syncOnQueue`-from-main for
every migrated path.

**FFI foot-gun, stated once:** never hold the core lock across a callback into
platform code. Key unwrap and dispatch callbacks are invoked with the state lock
released, from the worker thread, behind an explicit re-entrancy guard. A
callback that re-enters `ingest` is queued, not executed inline.

### 4.3 The frozen contract

Names are frozen by the board. Field-level detail is in
`core/vibe_core/src/types.rs`, which is the normative version.

| Name | Role |
|---|---|
| `VibeCoreEventV1` | the only ingress type; carries **raw frame bytes**, never a dictionary |
| `VibeMessageSnapshotV1` | the canonical message |
| `VibeTimelineDeltaV1` | the only egress mutation |
| `VibeTimelineWindowV1` | bounded query result |
| `VibeTimelineAnchor` | stable scroll identity |
| `VibeRenderItem` / `VibeRenderSnapshot` / `VibeListTransaction` / `VibeMessageListHost` | iOS render side (grok's slice) |
| `vibeAsyncTimelineV1Enabled` | rollout gate, default `false` |

Evolution rule: **new fields are appended and optional; the meaning of an
existing field never changes; a breaking change mints a `…V2` and both versions
are served during rollout.**

#### Approved contract resolutions

| # | Resolution | Where it lives |
|---|---|---|
| **C1** | A flush yields *at most one* ordered delta. Truth is never delayed past the flush barrier; a barrier is implicit at every non-stream ingest and at every explicit flush. Stream coalescing is bounded to one display-frame interval. | `reducer::VibeCoreConfig::flush_frame_interval_ms` |
| **C2** | Thumbnails and media bytes never ride a window DTO. `VibeThumbHandle` + a side-channel `VibeThumbnailBlob` for the host to persist. | `types::VibeThumbHandle`, `canonical::VibeThumbnailBlob` |
| **C3** | Anchors resolve through a chain: exact id → client-id alias → nearest-not-after → nearest-before → pin. Never a bare id. | `window::resolve_anchor` |
| **C4** | `vibeAsyncTimelineV1Enabled` stays the umbrella name and the `false` default, resolved per chat class from one stored bitmask so a class can roll back alone. | `types::VibeAsyncTimelineGate` |
| **C5** | The "no `[String: Any]`" rule applies to the **new boundary only**. `getChatRows` and the ~80 dictionary entry points stay untouched for as long as the flag can be false — that is the rollback. | policy |

C3's justification is concrete: Saved Messages carries two ids for one logical
message (`id` vs `original_message_id`) and the client deliberately prefers the
latter (`ChatEngine.swift:13521-13525`) because the other choice produced a
second id generation and duplicate cells on every cold open. An anchor holding
only a retired id resolves to nothing after a heal, and that is a visible scroll
jump.

C4's justification is the risk table:

| Class | Risk | Why |
|---|---|---|
| 1:1 DM | Low | the one fully understood path |
| Group / channel | Medium | plaintext wire (§3.2), fan-out density |
| Saved Messages | High | dual id, sealed-to-self, REST delete path |
| Agent / bridge DM | High | volatile-per-session, sealed payloads, stream/bridge/lan dedup |

Rollout order is that order. A single global boolean means the first agent-DM
regression rolls back 1:1 DMs too.

### 4.4 Deterministic reduction

- **Total order:** `ts_ms ASC, message_id ASC` — exactly today's comparator.
  Two deliberate non-changes: a server-assigned sequence would tiebreak
  same-millisecond messages better and is **not** adopted (it reorders history
  relative to the shipped client for no user benefit); id-less rows are
  **rejected** rather than prepended, because a row no later event can address
  is worse than a dropped one. That is the only intentional ordering divergence
  and it is named in `order.rs`.
- **Dedup:** four named predicates plus stale-stream settling, constants carried
  verbatim (§1.4).
- **Edits:** monotone by `edited_at_ms`. A reconnect replaying an older edit is
  dropped.
- **Deletes:** a tombstone is checked before every insert, outlives the window,
  is persisted, and is lifted only by an explicit undelete.
- **Clear-before:** a bulk tombstone that also blocks late re-ingest.
- **Settle-slot adoption:** emitted as `Move`, never `Remove`+`Insert`. That
  distinction is the difference between a smooth settle and a visible
  re-animate.
- **Receipts:** per-reader lattice, not one collapsed value. Preserved verbatim:
  the ranking quirk where **`Failed` cannot downgrade `Sent`**, and the presence
  heuristic that upgrades `Sent`→`Delivered` while the peer is online. Changed,
  and therefore gated: a group reads `Read` only when **every** other member
  has read, and a second device of the *sender* never advances the sender's own
  checkmarks.
- **Unread:** always derived, never a server-pushed integer. Server counters and
  local tombstones disagree constantly in this app.

**Two bounded scans, named honestly.** The Swift merge re-scans the whole loaded
transcript on every ingest. The core bounds two scans so the soak stays flat:
dedup and stale-stream settling look at the newest 600 messages (≥2 windows);
the unread walk stops at 999. Both diverge from the shipped behaviour only in
the extreme tail, and both are deliberate.

### 4.5 Adapters: iOS, Android, web

**UniFFI for iOS and Android; `wasm-bindgen` for web; no hand-written C ABI.**

| Option | Verdict |
|---|---|
| Hand-written stable C ABI | Rejected as the primary boundary. You end up hand-writing exactly the marshalling UniFFI generates, and hand-rolled marshalling is where memory-safety bugs live — self-defeating for a project whose stated reason for Rust is safety. Keep a *minimal* C ABI only as an escape hatch. |
| **UniFFI** | **Adopted.** One definition source, generated Swift value types (`Sendable`, no bridging header), generated Kotlin data classes, generated error enums, and a callback-interface mechanism for the key-unwrap seam. Cost: build-time codegen in the Xcode/Gradle pipeline. |
| **`wasm-bindgen`** | **Adopted for web**, as a separate thin crate over the same `vibe_core`. Do not make UniFFI produce the JS binding; the web client's threading model differs enough to deserve its own adapter. |

**The FFI rule is one call per *commit*, never per cell and never per message.**

- Per delta: 1–5 ops in normal operation. Negligible.
- Per window: 150–300 records → order 3,000 allocations. **Must not happen on
  the main thread**, regardless of cost. Window builds are rare (open,
  jump-to-message, resync).
- Per cell: **zero.** Any design where `cellForItemAt` calls into Rust is wrong
  and must fail review.

Escape hatch, only if measured: `timeline_window_bytes() -> Vec<u8>` returning a
FlatBuffer, decoded lazily. Do not build it speculatively — it doubles schema
maintenance and there is no evidence it is needed.

iOS integration shape:

- static lib for `aarch64-apple-ios` + `aarch64-apple-ios-sim`, packaged as an
  **XCFramework**, generated Swift under `ios/Sources/Core/Generated/`;
- `ios/project.yml` gains one target dependency and one `OTHER_LDFLAGS` entry,
  in the style already proven by the `libphantom_client.a` linkage
  (`ios/project.yml:13-21`) — including the extension-inheritance discipline in
  §3.4;
- binary size: budget **+1.5–3 MB** stripped, with `opt-level="z"`, LTO on, and
  no `regex`/`chrono`. `vibe_core` has five dependencies and no time-zone
  database precisely for this reason.
- **`panic = "abort"` is not acceptable** for a library embedded in the app: a
  panic would kill the host process. Use `panic = "unwind"` with a
  `catch_unwind` boundary at every FFI entry that converts a panic into
  `VibeCoreError::Internal` **and** emits telemetry. A core panic must degrade
  to "this chat falls back to the Swift path", never to a crash. The workspace
  profile already sets `panic = "unwind"` explicitly.

Android note: the existing `ChatEngine.kt` is an Expo module from the retired RN
app. Treat it as the **second differential oracle** for the port — its dedup and
ordering logic is an independent reading of the same protocol, and disagreements
between it and Swift are exactly the bugs worth finding — then retire it rather
than maintain it. Android is a future shipping consumer; it is not edited by
this program until P6.

### 4.6 Key and plaintext lifetime

| Secret | Home | Crosses FFI? |
|---|---|---|
| RSA private key (PEM) | Keychain, `AfterFirstUnlockThisDeviceOnly` | **Never** |
| Peer public keys | engine cache / server | public; may cross |
| Per-message AES key | derived at decrypt | **Yes** — 32 bytes, zeroizing, inbound only |
| Media key | inside the message payload | yes, as `key_ref` |
| Agent pairing key | Keychain | **Never** — sealed blobs stay opaque |
| Store-seal key (new, §7) | Keychain, same class | **Never** — platform seals/opens |
| Auth token | Keychain | Never |

The unwrap seam is **batched, never per message**:

```rust
pub trait VibeKeyUnwrapper: Send + Sync {
    fn unwrap_aes_keys(&self, requests: &[VibeWrappedKeyRequest]) -> Vec<Option<VibeSecretKey>>;
}
```

One call per ingest batch. A 100-message history page needs 100 RSA private-key
operations (~0.3–1 ms each on an A18) ≈ 30–100 ms — **off the main thread, once
per page, and never again**, because the durable store keeps the opened form
sealed under the store key. That is the same amortization the current code gets
by persisting plaintext; it just persists ciphertext instead.

Failure semantics are preserved exactly, including the "decrypted to an empty
string ⇒ treat as failure" rule (`ChatEngine.swift:13590`): the row gets
`decryption_failed` and the plaintext fallback, and never renders base64 as
text.

**Honest limits on zeroization.** Inside the core, AES keys and intermediate
plaintext are zeroizing, are never `String`, have no `Debug`, and have no serde
impl. But:

- **the rendered snapshot is plaintext by definition** — the user reads it. It
  is bounded by *lifetime and quantity* (150–300 messages, evicted rows
  dropped, one committed snapshot per open chat), not by zeroization;
- Swift `String` is not zeroizable, iOS may page memory, and UIKit holds text in
  label and attributed-string caches.

Zeroization buys "the key is not sitting in a freed allocation". It does not buy
"plaintext never lingers in process memory". Any security document that says
otherwise is wrong. See §10.

### 4.7 Compatibility guarantees

Non-negotiable, verified by the differential corpus:

1. Any `encrypted_content` produced by iOS, the web client, or the retired
   Android module today decrypts to a byte-identical inner payload under the
   core.
2. Any envelope the core produces decrypts under the current iOS, web and
   Android implementations — checked by round-tripping through the **existing**
   Swift/TS code, not by re-deriving the format from this document.
3. The core never emits `g`, never changes `v`, and never depends on JSON key
   order (every platform parses into a map; confirmed on both sides).
4. Legacy bare-base64 RSA-direct: the core **recognises** it (matching the web
   client) so the row is flagged rather than rendered as base64 text. Opening it
   needs a platform private-key operation over the whole ciphertext and is
   therefore a platform call, gated by the same flag.

---

## 5. Renderer contract

Owned by grok's slice; reproduced here because the core's delta shape is
designed around it.

### 5.1 Populated push

First paint is a **committed `VibeRenderSnapshot`** of the bottom (or restored)
window. Never an empty host waiting for the network, never a fade over empty
chrome, never an artificial navigation delay. This is the shipped behaviour and
the migration preserves it.

### 5.2 Bounded window

- Store: full history — not the list's problem.
- Active window: **150–300 messages, default 200** (`VibeWindowPolicy`, which
  rejects any policy outside that envelope at construction).
- Instantiated: visible + **at most two preload screens**.
- Groups and channels get the **same** cap. Today's agent-only 40 is
  insufficient and groups are unbounded.
- Measured in **messages, not rows**. Day dividers and unread separators are
  minted by the renderer; if the core emitted them too, both layers would
  insert them.

### 5.3 Immutable settled geometry

If a row is settled, not streaming, and not user-expanded, its size and layout
**never change** when media bytes, reply metadata, or theme images arrive later.
Late media updates pixels *inside* the reserved frame.

The core expresses this as data rather than convention, through
`VibeChangeMask`:

| Bit | Geometry-relevant? |
|---|---|
| `DELIVERY` (receipts, upload fraction) | no |
| `MEDIA_PIXELS` (thumbnail handle, URL, waveform) | **no** |
| `MEDIA_GEOMETRY` (natural size, duration, mime, envelope) | yes |
| `FLAGS_COSMETIC` (pinned, forwarded, view-once) | no |
| `FLAGS` (streaming, service, tombstone, agent error) | yes |
| `BODY`, `REPLY`, `EDIT`, `SERVICE`, `AGENT`, `IDENTITY`, `ORDER` | yes |

A delta therefore carries `UpdateContent` or `UpdateGeometry`, and the renderer
never has to guess.

**Natural size is a correctness field, not an optimization.** An unknown aspect
ratio resolved after decode is *the* list-shift bug. If the size is unknown the
core says `None` and the renderer reserves a frame it will not change — never
guess square and correct later.

### 5.4 Anchor preservation

| Op | Behaviour |
|---|---|
| Insert at bottom, user near bottom | grow content height; if pinned to bottom, offset += h |
| Insert above viewport (history prepend) | offset += Σh; **no visual jump**; never during an active pan |
| Insert in viewport | anchor to the nearest stable item; shift only below |
| Content edit, same height | reconfigure paint; no offset change |
| Geometry change | if above the anchor, offset += Δh; if below, no change; if it *is* the anchor, keep its screen Y |
| Delete | collapse; adjust for items above the anchor |
| Receipt / status | always content-only |
| Theme / Dynamic Type / RTL | one new snapshot, one preserve, not per-row thrash |

**`EvictHead`/`EvictTail` are separate ops from `Remove` on purpose.**
Conflating window eviction with deletion is how you get a delete animation on a
scroll-back trim. The reducer classifies by store membership, and there is a
test for it.

### 5.5 Display-link commits

Engine deltas coalesce to the next `CADisplayLink` callback, at most one
transaction per frame. During tracking, non-critical content updates are
deferred; offset-critical deletes are applied with preserve and no animation.
Targets: main-thread apply **p95 ≤ 4 ms, p99 ≤ 8 ms**.

Accessibility, Dynamic Type, RTL, selection, context menus, media playback,
keyboard anchoring, rotation, and reduced-motion behaviour are production
requirements, not follow-ups. VoiceOver order must equal visual order.

---

## 6. File graph and dependency order

Slices are disjoint by directory. No two phases touch the same file.

### P0 — iOS contracts and replay foundation · **landed, not linked**

```
ios/ChatModule/Timeline/VibeTimelineContracts.swift
ios/ChatModule/Timeline/VibeMessageListHost.swift
ios/ChatModule/Timeline/VibeTimelineFeatureFlags.swift
ios/ChatModule/Timeline/VibeListDisplayLinkCommitter.swift
ios/ChatModule/Timeline/VibeTimelineShadowComparator.swift
ios/ChatModule/Timeline/VibeTimelineReplayHarness.swift
```

Default-off flag, no wiring to `ChatMainView`/`ChatListView`. **Not yet a member
of the Xcode target** — the checked-in pbxproj lists ChatModule sources
file-by-file, so an integrator must run `xcodegen generate` (or add the group)
before these compile into the app. Parse-checked only; do not claim a product
build passed.

### P1 — host-only core · **landed**

```
core/Cargo.toml
core/Cargo.lock
core/README.md
core/vibe_core/**
docs/production-timeline-core-refactor.md      (this file)
```

`cargo test` green, no FFI, no app linkage, no behaviour change.
Rollback: delete `core/`.

### P2 — UniFFI shell, linked but dark · **partially landed**

```
core/vibe_core_store/          ✅ landed — rusqlite, READ-ONLY against `messages`
scripts/build-core-xcframework.sh  ✅ landed — unverified end to end (see below)
core/vibe_core_ffi/            ❌ NOT STARTED — uniffi, worker thread, command queue
ios/Sources/Core/VibeCoreBridge.swift              ❌ not started
ios/Sources/Core/VibeKeychainKeyUnwrapper.swift    ❌ not started
ios/project.yml                +1 dependency, +1 OTHER_LDFLAGS   [integrator-owned]
```

`vibe_core_store` is a standalone crate (empty `[workspace]` table) so it cannot
break the parent workspace before integration. It opens with
`SQLITE_OPEN_READ_ONLY` only, matches the app's `busy_timeout=2000`, orders on
the `(ts, message_id)` tuple to match `order.rs`, clamps `limit`, and keeps
payload bytes, SQL and paths out of every error. 15 tests, including
same-millisecond tie-break and bidirectional paging covering every row exactly
once. **Read-only is the safety property of the whole slice** — the app is a
live concurrent writer on that file.

`scripts/build-core-xcframework.sh` builds the three Apple targets, `lipo`s the
two simulator slices, and emits an XCFramework. It **has not been run past its
preflight check**, because `vibe_core_ffi` does not exist yet; its
`preflight()` failure path is the only part verified.

Flag false throughout. **No UI consumes any of it.**
Rollback: the flag, or removing the link.

### P3 — shadow-write and backfill

```
core/vibe_core_store/          + core_messages_v1, seal, resumable backfill
```

Still no UI consumption. Rollback: drop the table.

### P4 — gated read authority, 1:1 DM only · **render path landed, authority not taken**

```
ios/Sources/Core/VibeTimelineHost.swift        ✅ delta → VibeRenderSnapshot/Transaction
ios/ChatModule/Timeline/VibeCollectionMessageListHost.swift  ✅ UICollectionView + custom layout
ios/Sources/Core/VibeTimelineShadowProbe.swift ✅ order comparison, renders nothing
ios/Sources/Core/VibeCoreListPreview.swift     ✅ the render path on a throwaway screen
ios/ChatModule/ChatListView.swift              ✅ ONE branch at the row source (9 lines + 2 stored properties)
```

Everything else untouched. Rollback: flip the flag mid-session, no data
migration.

**The gate opens in two moves, not one.** Read authority means the list renders
what the core says, and betting on that before ever comparing the two orderings
on real conversations would risk the most visible bug this app could ship — a
user's chat in the wrong order. So the branch that landed feeds the engine's own
rows to the core and *compares*, logging divergence under the `core` category. It
returns nothing to the caller and cannot reorder, drop, or delay a row.

Read authority becomes a second flag once divergence is measured at zero across
real chats. `VibeCollectionMessageListHost` is already the thing that would be
pointed at, and it is exercised today on **Diagnostics → Core list (UIKit render
path)** — the same adapter, the same host, the same anchor preservation, aimed
somewhere a mistake costs nothing.

**Where sizing lives.** `VibeRowMeasurementCache` measures a row **once** and
freezes it; `contentUpdatedItem` reuses the frozen size and has no code path that
could re-measure. Height moves only through `UpdateGeometry`, which the core
emits only for geometry-relevant mask bits (§5.3). `VibeTimelineListLayout` is
told its geometry rather than deriving it, so unlike every self-sizing mechanism
UIKit offers it has nothing to disagree with. Both hosts count
settled-height changes; §9.1 requires that counter to be **0**.

### P5 — remaining chat classes, shadow dual-apply

Group → Saved → agent DM, each a separate gated rollout with its own soak.
Shadow dual-apply in Debug/internal builds.

### P6 — Android, then web, then `vmed2`

```
core/vibe_core_wasm/
android/.../CoreBridge.kt
```

Neither is on the critical path for the iOS scrolling goal.

**Dependency order:** P0 and P1 are independent and both are done. P2 needs P1.
P3 needs P2. P4 needs P0 + P3. P5 needs P4. P6 needs P4.

---

## 7. Persistence

### 7.1 Storage behind a trait

```rust
pub trait VibeStore: Send + Sync {
    fn upsert(&self, chat: &str, rows: &[StoredRow]) -> Result<()>;
    fn page(&self, chat: &str, before: Option<Cursor>, limit: u32) -> Result<Vec<StoredRow>>;
    fn tombstone(&self, chat: &str, ids: &[&str], at_ms: i64) -> Result<()>;
    fn prune(&self, chat: &str, keep_newest: u32) -> Result<()>;
    fn count(&self, chat: &str) -> Result<u64>;
}
```

Native: `rusqlite` with bundled SQLite, its own connection, WAL,
`busy_timeout=2000` — matching the existing pragmas. Web injects an
IndexedDB-backed implementation. That is the main reason storage is a trait
rather than hard-wired to `rusqlite`.

### 7.2 Schema — additive, sealed, no destructive migration

```sql
CREATE TABLE IF NOT EXISTS core_messages_v1(
  user_id     TEXT NOT NULL,
  chat_id     TEXT NOT NULL,
  message_id  TEXT NOT NULL,
  ts          INTEGER NOT NULL,
  order_key   BLOB NOT NULL,          -- (ts, message_id) packed, for range scans
  flags       INTEGER NOT NULL,       -- tombstone/hidden/streaming/agent, queryable
  sealed_body BLOB NOT NULL,          -- AES-256-GCM(store_key, canonical row)
  seal_nonce  BLOB NOT NULL,
  PRIMARY KEY(user_id, chat_id, message_id)
);
CREATE INDEX IF NOT EXISTS idx_core_messages_order
  ON core_messages_v1(user_id, chat_id, ts, message_id);

CREATE TABLE IF NOT EXISTS core_tombstones_v1(
  user_id TEXT NOT NULL, chat_id TEXT NOT NULL, message_id TEXT NOT NULL,
  at_ms INTEGER NOT NULL, for_everyone INTEGER NOT NULL,
  PRIMARY KEY(user_id, chat_id, message_id)
);
CREATE TABLE IF NOT EXISTS core_meta_v1(k TEXT PRIMARY KEY, v BLOB NOT NULL);
```

- `sealed_body` is AES-256-GCM under a **per-install 32-byte store key** from
  `SecRandomCopyBytes`, held in the Keychain at
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the same class and the
  same primitive already in use. **No new cryptography is invented.**
- **AAD = `user_id || chat_id || message_id`** so a row cannot be relocated.
  Note the asymmetry with the message envelope, which uses *empty* AAD for wire
  compatibility with deployed clients: the store seal is a new format with no
  deployed readers, so it binds properly.
- The platform seals and opens, or the core does with a key handed in per
  session. Either is acceptable; **the core must not persist the key.**
- SQLCipher was considered and rejected: a new native dependency, a whole-file
  re-encrypt (effectively a destructive migration under power loss), and no
  better WAL/journal protection than per-row sealing for this threat model.
- **The existing `messages` table is untouched.** Not renamed, not dropped, not
  altered. That is the rollback.

### 7.3 Rules the store write path must carry

- Transient ids (`stream-`, `lan-`, `bridge-`) are **never persisted**. Filter
  in the store write path, not the reduction (`reducer::persistable_messages`).
- **Agent DMs are volatile-per-session.** `restoreCachedHistoryRowsLocked`
  short-circuits agent DMs and purges their durable rows
  (`ChatEngine.swift:12034-12063`), backed by a persisted chat-id set so the
  decision is correct at cold launch before the provider maps populate. The core
  carries the same set and the same purge-once-per-run semantics, or a cold
  launch paints a stale agent transcript that the volatile layer then wipes —
  the exact flicker this design was reverted to avoid.
- **"Known empty" and "not loaded" are different states.** The current restore
  path has a documented poison-pill hazard where an empty array plus the
  fullyLoaded flag short-circuits every subsequent read
  (`ChatEngine.swift:12069-12080`). Store them as distinct states in
  `core_meta_v1`, never as an empty vector.

### 7.4 Migration — five stages, each independently reversible

| Stage | Core role | Swift role | Rollback |
|---|---|---|---|
| **M0** shadow-read (offline) | reads synthetic fixtures on a Mac | unchanged | delete the crate |
| **M1** shadow-read (device) | reads `messages` read-only, builds its own window, compares | authoritative | flag off / unlink |
| **M2** shadow-write | also writes `core_messages_v1` | still authoritative, still writes `messages` | drop the new table |
| **M3** read-authority (gated) | serves the window for enabled classes | still writes `messages` | flip the flag |
| **M4** write-authority | sole writer | reads legacy for backfill only | flip the flag; legacy is still current within the retention window |

- **Backfill** is incremental and idempotent: newest-first, ~500 rows per pass on
  the utility queue, resumable via a cursor in `core_meta_v1`. It re-seals from
  the existing plaintext row and, when `encryptedContent` is present, verifies
  that re-opening it produces the same canonical body — a free integrity check
  across the whole history.
- **Legacy `messages` is retained for at least two releases past M4**, then
  removed only after an export path exists. A user's history is never the thing
  that pays for a refactor.

---

## 8. Media

### 8.1 v1 (`Gcm1`) — decode-only compatibility

Today's blob is a **single AES-GCM message over the whole file**. The tag covers
everything and verifies only at the end, so producing plaintext as bytes arrive
is releasing unauthenticated plaintext. A 300 MB video therefore has three
options and only three:

1. buffer the whole ciphertext, verify, expose — current behaviour, and it loads
   the file into memory twice (`Data(contentsOf:)` + multipart body,
   `ChatEngine.swift:11723,11778`);
2. **decrypt to a temp file, verify the tag, and only then hand the URL out** —
   bounded memory, no unauthenticated exposure, one extra disk write;
3. change the format.

**Decision:** (2) for all existing blobs, with a hard size ceiling above which
the file is refused rather than OOM'd. `vibe_core::media::open_gcm1` implements
the buffer-then-verify path with that ceiling and exposes no partial-output
variant, on purpose.

### 8.2 v2 (`vmed2`) — specified, parseable, **not enabled**

```
"vmed2" || version(1) || salt(16) || segment_len(u32 LE) || segment*
segment_i = AEAD(key_i = HKDF(master, salt), nonce = prefix || i || last_flag)
```

A standard segmented-AEAD construction of the kind Tink standardised — **not a
bespoke scheme**. Detection is by prefix, so no message metadata changes and old
`Gcm1` blobs stay readable forever.

`vibe_core` implements **header parsing only**, so a client can recognise and
refuse a blob it cannot open. `seal_stream2` always returns
`Stream2SealNotEnabled`: the deferral is a compile-time visible fact rather than
a paragraph in a document. Enabling it is a P6+ program with its own rollout and
its own review. **It must not be bundled into the timeline work.**

### 8.3 Addressing and validation

- **Cache identity** is ported exactly from `VibeMediaVault.identity` /
  `chatStableRemoteMediaIdentity`: query and fragment dropped, host lowercased,
  backend music-stream URLs collapsed to `musicstream:<id>`, media key appended
  as `|k:<key>`. Getting this wrong is not cosmetic — every adopt-on-miss path
  silently misses and the user's whole media library re-downloads.
- **Byte validation** (magic number + minimum length) before a download is
  accepted. This is the single fix for the poisoned-cache class of bug: an
  84-byte JSON error page cached as an `.m4a` fails forever with
  `kAudioFileUnsupportedFileTypeError` because the cache never re-fetches.
- **Absolute paths do not survive reinstall** (container UUID changes, `Caches`
  is purged). The core stores identities, never paths.
- Media uploaded before encryption has no `mediaKey`; the `Plain` envelope
  passes it through untouched, identically to today.

---

## 9. Qualification gates and telemetry

### 9.1 Gates

Nothing is promoted past a stage until its gates pass.

| Gate | Threshold | Stage |
|---|---|---|
| `cargo fmt --check`, `clippy -D warnings`, `test --all-features` | green | every core change |
| `--no-default-features` (deny-all crypto) builds and tests | green | every core change |
| Property suite (order-independence, idempotence, tombstone absorption, diff/apply round-trip, receipt monotonicity) | green | every core change |
| Malformed-envelope + malformed-frame corpus | no panic, no false decrypt, no input echoed into an error | every core change |
| Differential vs Swift on a synthetic corpus | 0 order diffs, 0 dedup diffs, field diffs enumerated | M1 |
| `core.parity.mismatch` rate on device | 0 for the class being promoted | M1→M3 |
| Empty transcript frames, Home → chat push and reopen | **0** | P4 |
| Settled-row geometry changes (non-expand, non-stream) | **0** | P4 |
| Main-thread transaction | **p95 ≤ 4 ms, p99 ≤ 8 ms** | P4 |
| Active window size | 150–300 | P4 |
| Instantiated cells | visible + ≤ 2 screens | P4 |
| 100k store, 20–50 events/s, continuous scroll, physical iPhone 16 Pro Max at 120 Hz | sustained | P4 |
| 30-minute scroll + ingest soak | flat retained timeline/render memory | P4 |
| Accessibility: VoiceOver order = visual order, Dynamic Type, RTL, rotation, reduced motion | no regression | P4 |
| `core.panic` | **0** — any occurrence auto-disables the flag | always |

### 9.2 Fixture policy

**Every fixture in this repository is synthetic.** No production frame, no real
message body, no real key, and no captured payload is committed. A redacted
production corpus would make fuzz seeds materially better and is a **separate
decision with its own privacy review**; until that decision is made, the
synthetic corpora in `core/vibe_core/src/fixtures.rs` are the corpus.

Fuzz readiness: `envelope::parse_hybrid`, `envelope::parse_agent_sealed`,
`canonical::canonicalize_frame`, and `media::parse_stream2_header` are pure
functions of `&[u8]`/`&str` with no global state, no I/O, and explicit size
ceilings. `cargo-fuzz` targets are a P2 addition seeded from
`fixtures::malformed_envelope_corpus` and `fixtures::malformed_frame_corpus`.

### 9.3 Telemetry — redacted, counters only

| Signal | Why |
|---|---|
| `core.parity.mismatch{chat_class, field}` | the M1–M3 safety net; non-zero blocks promotion |
| `core.ingest.latency_ms` p50/p95/p99 | backpressure detection |
| `core.commit.main_ms` p95/p99 | the 4 ms / 8 ms gate |
| `core.window.len`, `core.window.rebuilds` | window thrash |
| `core.decrypt.fail{reason}` | today this is only an NSLog |
| `core.store.seal_fail`, `core.store.backfill_progress` | migration health |
| `core.panic{module}` | must be zero |
| `core.fallback{reason}` | how often the Swift path is serving |

No message content and no ids beyond a truncated hash. This slots into the
existing `VibeLog`/`VibeDebugLog` redaction discipline (`ios/Shared/VibeLog.swift`).

### 9.4 Measured today (P1, laptop, release)

| Operation | Store | Cost |
|---|---|---|
| Ingest one message | 100,000 | 8.1 µs |
| Ingest + flush at 50 events/s | 100,000 | 10.0 µs/event |
| Scroll-back one page | 100,000 | 303 µs |
| Largest delta during replay | 100,000 | 51 ops |

These are laptop numbers for the *reduction*, not device frame times. The first
run of this benchmark measured 1,666 µs per message and found a linear scan in
the ingest path; the fix (an indexed lookup) is why the number is 8.1 µs. That
is the benchmark earning its keep, and it is the reason it stays in the tree.

---

## 10. Threat model and non-claims

### 10.1 In scope

| Adversary | Mitigation |
|---|---|
| A malicious or compromised server sending hostile frames | every parser is bounded, total, fuzz-ready, and fails closed; a malformed frame is counted and dropped, never fatal |
| Ciphertext tampering | AEAD tag verification with an opaque failure that does not distinguish wrong-key from tampered from truncated |
| Row relocation in the local store | AAD binds `user_id ‖ chat_id ‖ message_id` on the store seal |
| A poisoned media cache | magic-number and minimum-length validation before a download is accepted |
| Secrets leaking into logs and crash reports | no `Debug`, no serde, no `String` for key material; errors carry shapes, not data; asserted by `tests/no_leakage.rs` |
| A core panic taking down the app | `panic = "unwind"` + `catch_unwind` at every FFI entry, degrading to the Swift path |

### 10.2 Explicit non-claims

Read this section before repeating anything from this document in a
customer-facing context.

1. **Groups and channels are not end-to-end encrypted today.** §3.6 specifies
   and implements the group half in the core, but **nothing is enabled**: no
   epoch-key distribution, no membership-capability signal, no platform wiring,
   and not one group message encrypted. Channels are excluded by decision, not
   pending. A 1:1 DM does **not** fall back to plaintext when the peer key is
   unresolved — it queues (see the correction in §3.2); an earlier revision of
   this document said otherwise and was wrong.
2. **The local message cache is not sealed today.** `vibe_core::store_seal` now
   implements the seal — AES-256-GCM under a per-install Keychain key, AAD-bound
   to `user_id ‖ 0x1F ‖ chat_id ‖ 0x1F ‖ message_id` so a row cannot be
   relocated between messages, chats, or users (11 tests, including all three
   relocation refusals and fail-closed under the deny-all provider). But **no
   iOS code calls it yet**, no store key is generated on device, and the legacy
   plaintext `messages` table is still the only thing the app reads and writes.
   Until the backfill runs and M4 completes, **every row on disk is still
   plaintext**. The capability exists; the fix has not shipped.
3. **No claim of plaintext zeroization across FFI.** Swift `String` is not
   zeroizable and UIKit caches text. See §4.6.
4. **No claim of authenticated streaming media decryption.** The v1 format
   cannot provide it; v2 is specified and deliberately not enabled.
5. **No security audit has been performed.** `vibe_core` depends on the
   RustCrypto `aes-gcm` crate and implements no primitive itself. `cargo deny`
   is now wired (`core/deny.toml`) and passes advisories, bans, licenses and
   sources — so the supply chain is *policed*, with copyleft, git sources,
   duplicate runtime crates, and any async/TLS/networking dependency refused at
   the graph. It is **still not run in CI**, and policing a dependency graph is
   not the same as a commissioned cryptographic review. Do not describe this
   code as "audited".
6. **No claim about server-side storage.** The server stores whatever the client
   sends; for groups that is plaintext.
7. **No metadata protection.** Who talks to whom, when, and how often is visible
   to the server. Nothing here changes that.
8. **Notification-extension decryption is not implemented** and, per §3.4,
   should not be until the App Group and second-writer questions are answered.
9. **P1 has not run on a device**, has not been linked into any app, and has not
   changed any live behaviour. The measurements in §9.4 are laptop numbers.

---

## 11. Operational runbook

### 11.1 Build and test

```bash
# Core (all of it host-only; nothing touches a device)
cd core
cargo fmt --all -- --check
cargo clippy --all-targets --all-features   -- -D warnings
cargo clippy --all-targets --no-default-features -- -D warnings
cargo test  --all-targets --all-features
cargo test  --all-targets --no-default-features
cargo test --release --all-features -- --ignored --nocapture   # 100k benchmark

# iOS (integrator: Timeline sources need target membership first)
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/Vibe.xcodeproj -scheme Vibe \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-000935000288801C' \
  -derivedDataPath /tmp/vibe-device-build \
  -allowProvisioningUpdates build
```

`core/target/` is build output and the repository `.gitignore` does not yet
cover it. Either add `core/target/` there or build with
`CARGO_TARGET_DIR=/tmp/vibe-core-target`.

### 11.2 Go / no-go checklist per stage

**Before P2 (linking the core):**

- [ ] `core/` gates in §11.1 all green, on CI, not just locally
- [ ] `cargo audit` / `cargo deny` wired and passing (this is the item that
      makes non-claim 10.2.5 retractable)
- [ ] binary-size delta measured and accepted (budget +1.5–3 MB)
- [ ] `panic = "unwind"` + `catch_unwind` at every FFI entry, with a test that a
      forced panic degrades to the Swift path
- [ ] the NSE target's `OTHER_LDFLAGS`/bridging-header clearing is preserved
- [ ] no core call reachable from `cellForItemAt` — verified by review

**Before P3 (shadow-write):**

- [ ] parity mismatch rate 0 for the 1:1 DM class over ≥1 week of internal use
- [ ] store key created, in the correct Keychain class, never persisted by the core
- [ ] backfill resumes correctly after `kill -9` mid-batch
- [ ] `NSFileProtectionCompleteUntilFirstUserAuthentication` declared explicitly

**Before P4 (read authority, 1:1 DM):**

- [ ] every P4 gate in §9.1 measured on the physical iPhone 16 Pro Max
- [ ] shadow comparator reports order, height and anchor parity within 0.5 pt
- [ ] the old renderer is a one-flag, mid-session rollback with no data migration
- [ ] accessibility pass signed off

**Before each class in P5:** repeat the P4 gates for that class, with its own
fixture set. Saved Messages and agent DMs ship **last**.

### 11.3 Incident response

| Symptom | Action |
|---|---|
| `core.panic` non-zero | the flag auto-disables for that chat; ship a flag-off build; the crate's `catch_unwind` boundary means this is a fallback, not a crash |
| Parity mismatch appears after promotion | flip the class's bit off; the legacy path is still complete and still writing |
| Backfill wedges | it is resumable and idempotent; clear the cursor in `core_meta_v1` and let it re-run |
| Store seal fails to open | drop `core_messages_v1`; the legacy `messages` table is still authoritative through M4 |

### 11.4 Open items for the integrator

1. `docs/security.md` has been corrected in the working tree by another owner.
   Verify its claims against §3 before it is committed; this program did not
   author that edit.
2. Fixture policy: may redacted production frames go to a private fixture repo,
   or must every fixture stay synthetic? This materially changes fuzz-corpus
   quality. Default until answered: synthetic only.
3. Binary size: is +1.5–3 MB acceptable?
4. Android: is the Expo `chat-module` a port target or only a differential
   oracle? It changes P6's shape.
5. ~~`core/target/` needs a `.gitignore` line~~ — **done**. `core/target/` and
   `core/**/target/` are both ignored; the glob matters because the standalone
   crates carry their own target dirs.
7. **Group E2E follow-through** (§3.6). The core half is done; the rest is not
   started and none of it belongs in the core: epoch-key distribution over the
   1:1 channel, the server membership-capability signal that feeds
   `VibeGroupSealAuthorization`, and rotation on membership change.
8. **`vibe_core_ffi` is unowned.** It was briefed to codex, which hit its usage
   limit on the first turn (locked out to 2026-08-07) and wrote nothing. It is
   the remaining blocker for every P2 item downstream of it, including
   validating the XCFramework script.
6. `VibeTimelineWindowV1` exists twice — an iOS mirror in
   `ios/ChatModule/Timeline/VibeTimelineContracts.swift` (ids + anchors) and the
   core definition (full snapshots + bounds + unread). They must converge on the
   core's shape when the FFI lands; until then, treat the Swift one as a
   render-side view.
