# MLS ordered commit fan-out

Design only. Do not implement from this file until the membership gate and
KeyPackage claim cap (N000035, N000038) are deployed. Pointer from
`docs/secure-core-architecture.md` §4.

## Why a 3rd member breaks the group today

A DM is a two-member MLS group created empty, then `add_members` once. The
committer merges locally; the joiner takes the Welcome. No already-present
member exists, so the Commit bytes are discarded on purpose
(`VibeSecureEstablishment.establishDirectMessage`). That path works.

Any later `add_members` (a 3rd person, or a 3-person group created as one
commit against several KeyPackages *after* two members already share a
session) produces a Commit that **existing members must process** to advance
their epoch. Today:

1. `VibeSecureSession::add_members` returns `{commit, welcome}` and merges
   only on the committer.
2. iOS posts the Welcome (`POST /mls/welcomes`) and drops `commit.commit`.
3. `VibeSecureSession::open` matches only `ApplicationMessage`; Commit /
   Proposal hit `_ => Err(Open)`.
4. FFI exports `create` / `join_from_welcome` / `add_members` / `seal` /
   `open` — nothing applies an incoming Commit.

Existing members stay at epoch N. The committer and the joiner live at N+1.
Every later application message fails to open on one side or the other, and
the group cannot recover: there is no catch-up path.

This is not a decrypt bug. It is a missing delivery service.

## What RFC 9420 requires of us

The Delivery Service must give each group a **total order of Commits**. Two
members must never merge different Commits at the same epoch. Phoenix PubSub
and the chat-message table do not provide that: they are at-least-once and
unordered under reconnect.

Application messages can ride the existing chat channel (`vmls1.` envelopes).
Handshake messages cannot: `process_message` mutates the ratchet, is
order-sensitive, and must not be replayed (N000037 — the Swift unwrapper is
batched by message id and retry-tolerant, the wrong shape).

## Contract

### Server is the epoch authority

One row per MLS-eligible chat:

```
mls_group_state(chat_id PK, epoch integer not null default 0)
```

`epoch` is the last Commit the server accepted. Creation of the group (first
Welcome) does not bump it — OpenMLS starts at epoch 0 and the first
`add_members` on an empty group has no existing members to notify. The first
Commit that must be fanned out is the one that adds a member to an
already-non-empty group; that Commit's post-merge epoch is what we store.

### Commits are not chat messages

New table, same shape as `mls_welcomes`:

```
mls_commits(
  id uuid PK,
  chat_id text not null,
  sender_user_id uuid not null,
  epoch integer not null,          -- epoch AFTER this commit
  commit bytea not null,
  inserted_at
)
unique (chat_id, epoch)
```

No FK to `chats.id` is required to match welcomes, but `authorize` must use
`Chat.is_participant?` the same way `post_welcome` does (404 not 403).

### HTTP

`POST /mls/commits` — authenticated participant.

Body: `{chatId, epoch, commit}` (base64). `epoch` is the committer's
post-merge epoch.

Server, in one transaction:

1. Membership check (sender is a participant). Refuse `:not_allowed`.
2. `SELECT … FOR UPDATE` the `mls_group_state` row (create at epoch 0 if
   missing).
3. Accept iff `params.epoch == state.epoch + 1`. Otherwise `{:error,
   {:stale, state.epoch}}` → HTTP 409 `{currentEpoch}`.
4. Insert `mls_commits`, set `state.epoch = params.epoch`.
5. Fan out `mls_commit` on each participant's user topic (not the chat
   topic, not a renderable message). Payload: `{chatId, epoch, id}`. Bytes
   stay on the REST row so a reconnect does not replay a handshake through
   the unwrapper.

`GET /mls/commits?chatId=&afterEpoch=` — participant only. Returns commits
with `epoch > afterEpoch` in ascending epoch order. Catch-up after 409 or
after a device missed the live event.

`commit` blobs cap at the same 256 KiB as a Welcome.

### Client / FFI (not in this deploy)

New `VibeSecureSession::apply_commit(bytes)`:

- `MlsMessageIn` → `process_message`
- match `ProcessedMessageContent::StagedCommitMessage`
- `merge_staged_commit`
- return the new epoch (no plaintext)

Do **not** fold this into `open`. Application decrypt and handshake merge
are different callers and different retry rules.

iOS, only when the group already has members besides the committer:

1. `POST /mls/commits` with the Commit **before** sealing application
   messages at the new epoch.
2. On 409: `GET` missing commits, `apply_commit` in order, retry the add
   (OpenMLS will want a fresh proposal on the current epoch).
3. On live `mls_commit`: fetch bytes, `apply_commit` if `epoch == local+1`;
   if `epoch > local+1`, catch-up GET; if `epoch <= local`, ignore (replay).

`establishDirectMessage` stays Welcome-only. `establishGroup` that adds
every peer in the first commit against an empty group is also Welcome-only
for those joiners; the Commit is needed the moment a *second* add happens
on that same session, and for any member who was already in the group
before this commit.

### What this does not cover

- Proposals as a separate fan-out (commit-or-nothing is enough; we do not
  expose `propose_add` yet).
- Member removal / key update (same Commit pipe once `apply_commit` exists).
- Channels (epoch-key scheme, not MLS — architecture §4).
- The Swift unwrapper contract (N000037). Handshake traffic must never
  enter it.

## Implementation order, when coding starts

1. Migration + `Vibe.Mls.post_commit/2` + controller + tests (membership,
   stale epoch, blob cap, participant-only GET).
2. FFI `apply_commit` + a `vibe_secure` test: A creates, adds B (welcome),
   adds C, B applies A's commit, A and B open C-era application messages.
3. iOS: post Commit when existing members > 0; apply incoming. Stay out of
   `ios/ChatModule/ChatListView*` / `ChatInputBar` unless the send path
   itself must wait on commit ACK.

Until step 3, keep groups that grow past their founding add on the hybrid
envelope. Do not silently seal `vmls1.` that existing members cannot open.
