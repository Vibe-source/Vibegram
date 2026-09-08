# MLS: peer messages lost after opening the newest one first — 2026-09-05

Reviewer: Claude Fable 5.1 (session 4e6c430a), from two device diagnostics exports
(`.agix/pastes/0068-*` device A, user `0398CCC2…`, group creator; `.agix/pastes/0069-*`
device B, user `7D732BE4…`, joiner; group `34b693f4…`, epoch 1 on both).

## Root cause (confirmed from the logs, not a key mismatch, not the server)

On chat open, **exactly N−5 of N new peer rows** fail with
`mls peer open failed … envEpoch=1 groupEpoch=1 pending=N` and the 5 newest succeed.
A: 14 new rows → 9 failed. B: 16 new rows → 11 failed. Five is OpenMLS's default
`SenderRatchetConfiguration.out_of_order_tolerance`.

Sequence: the home list preview (`ChatEngine.homePreviewTextLocked` →
`buildHistoryRowsLocked` → `VibeSecureSessions.open`) opens the **newest** envelope of the
chat first. The receive ratchet jumps to that generation and keeps only the last 5 skipped
keys. The transcript build then opens the older rows, they fail, and the old code called
`markUnrecoverableLocked` so they were tombstoned forever ("message not available").
Clearing/deleting the chat is irrelevant except that it forces a full history refetch.

Rows already tombstoned on the two test devices are gone (keys destroyed); a resend fixes them.

## What the uncommitted patch does (verified correct)

- `core/vibe_secure/src/session.rs`: `sender_ratchet_configuration()` =
  `SenderRatchetConfiguration::new(4096, 4096)` applied in `create`, `join_from_welcome`
  **and** `load` (load re-applies via `configuration()` + `set_configuration`). Compiles on
  the pinned OpenMLS 0.8.1; all 20 existing tests pass.
- New `core/vibe_secure/tests/out_of_order.rs` (2 tests, pass): newest-first over 40 and a
  1200-message backlog read in reverse. Both fail on the default tolerance.
- `VibeSecureSessions.open`: only own rows consult/mark the unrecoverable set; a peer open
  failure is logged once and left retryable. Correct: a failure no longer proves a spent key.
- `VibeSecureSessions.sessionForEnvelopeLocked`: an envelope from an older group is opened
  with that archived session but **no longer rebinds the send session** to it. Security
  improvement — a replayed old envelope could previously downgrade which group new sends use.
- `ChatEngine.buildHistoryRowsLocked(allowMlsDecryption:)`: true at home preview (ratchet
  4096 makes newest-first safe). `seedRecentChatHistory` and `seedChatHistories` stay false.
  Own-plaintext lookup is not gated on `isMe`.
- `establishDirectMlsOnOpenLocked` on `chat_joined` (lower UUID creates the DM group on
  open), `mls_welcome_acked` frame flushes the queued first message.
- `VibeSecureEstablishment` `me > peer` branch now creates after a drain instead of
  deferring. Currently dead code: the only caller passing `myUserId` already guards
  `me < peer`. Harmless, not recursive forever (re-enters with `myUserId: nil`).

Security trade-off accepted: skipped keys are retained until 4096 later generations from
that sender, like Signal's MAX_SKIP. Device compromise could open not-yet-read backlog
ciphertext; the alternative was permanent data loss.

## Gaps closed (2026-09-05)

1. **Crash**: `isApplyingHeightCorrections` wraps `performHeightCorrections.apply`. Nested
   `reconfigureItems` from `updateVisibleMediaDownloadState(reloadCell:)` defers to the next
   turn; progressive height warmup waits on the same flag.
2. **Home preview**: `homePreviewTextLocked` now decrypts (`allowMlsDecryption: true`). Seed
   sites stay false.
3. **Video 400**: R2 returns a presigned GET URL; attaching `Authorization: Bearer` made
   S3/R2 answer 400. Downloads use `authorizationHeaderForRemoteURL`, which only auths
   `vibegram.io` hosts (same rule the voice path already had). Images with `hasMediaKey=N
   status=404` were the tombstoned rows. Stored presigns still expire in 15 minutes — a
   durable object URL is a separate follow-up.
4. **Own rows after crash**: `open(isMine:)` returns retained plaintext or nil and no
   longer tombstones. History/live/mutation paths never call `open` on own envelopes.
   Media-only JSON no longer becomes `text` (fallback only if no recognized fields).
   Live incoming does not stamp `decryptionFailed` on `isMe`. Core does not flag
   `DECRYPTION_FAILED` for own sealed-empty rows (`VibeTimelineHost.mount`).
5. **`.agix-notes/*.json`**: confirmed migrated into the `.agix` store (`agix note list`
   still serves them). Leave the JSON deletions; do not restore.
6. Separate work still in this tree (account-switch purge, media lifting, chat-profile
   menu, comment strip) — not part of this MLS note. Build once; do not launch.
