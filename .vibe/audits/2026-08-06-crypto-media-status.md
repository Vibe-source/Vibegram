# Crypto & media ground-truth audit — 2026-08-06

**Scope:** is Vibe's encryption and media handling intact today, and can we build
AI image/video editing on top of it? Read-only audit. Every claim below carries a
`file:line`. Where a doc and the code disagree, **the code wins** and the
disagreement is called out.

**Short version:** the *primitives* are correct and well-implemented. The
*plumbing around them* leaks. Message text in 1:1 DMs is genuinely E2E. Media is
encrypted with AES-256-GCM — and then **the media key is shipped to the server in
cleartext and persisted next to the ciphertext**, so media E2E is cosmetic. Groups
and channels are not encrypted at all. A plaintext push preview and a plaintext
caption ride every message. The local store *is* sealed at rest (docs say
otherwise; docs are stale).

For the AI-editing feature specifically: **nothing here blocks it.** Pre-send
editing in the composer sits entirely outside the envelope, on plaintext the user
just picked. The blockers are memory/main-thread, not crypto.

---

## A. Encryption — the real model today

### A.1 Key material and custody

| Key | Algorithm | Where it lives | Who can see it |
|---|---|---|---|
| User identity keypair | RSA-2048, OAEP-SHA-256 | private key in Keychain via `SecureKeyStore` (`ios/Sources/Storage/SecureKeyStore.swift:24`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) | server stores `encrypted_private_key` (password-derived AES-256-GCM) and hands it back on every login |
| Per-message content key | AES-256-GCM, 32B, fresh per message | never stored; RSA-wrapped for recipient + sender | recipient, sender |
| Per-file media key | AES-256-GCM, 32B, fresh per file | **sent to the server in cleartext** | recipient, sender, **server** |
| Local store seal key | AES-256 | Keychain `vibe.core.store` / `core_store_key_v1` (`ios/Sources/Core/VibeCoreStoreKey.swift:30-31,120`) | device only |
| Agent-runtime (`arte1`) key | AES-256-GCM, 32B | Keychain, handed over by pairing QR (`ios/Sources/App/AgentPairingService.swift:13-15,111-121`) | phone + paired Mac only |

The message primitives are in one place and are correct:

- Hybrid seal: `ios/ChatModule/ChatEngine.swift:199-244`. Fresh 32B AES key
  (`:210`), fresh 12B nonce (`:211`), `AES.GCM.seal` (`:213`), key RSA-OAEP-SHA256
  wrapped for the recipient (`:215`) and optionally for the sender (`:223-227`).
  Randomness is `SecRandomCopyBytes` with a hard throw on failure
  (`ChatEngine.swift:183-197`) — no silent fallback to a weak source.
- Open: `ChatEngine.swift:246-319`. Tries the sender blob then the recipient blob
  (`:274-288`), AES-GCM verify at `:313`.
- Media: `chatEngineEncryptMediaData` / `chatEngineDecryptMediaData`
  (`ChatEngine.swift:321-353`). Whole-file `iv ‖ ciphertext ‖ tag`.

### A.2 What the server can actually read

**1:1 human DM, text:** ciphertext only. Genuine E2E for the message body.

**Everything else:** cleartext JSON in `encrypted_content`.

```
ChatEngine.swift:4765     if isGroup || friendPublicKey == nil {
ChatEngine.swift:4766       encryptedContent = fullPayloadString      // ← plaintext JSON
```

`friendPublicKey` is nil for groups/channels (`ChatEngine.swift:4241-4243`),
`saved_messages` (`:4242`), and agent DMs (`:4244-4245`). A *normal* DM with an
unresolvable key does **not** fall through here — it is queued instead
(`ChatEngine.swift:4247-4262`), which is the correct fail-closed behaviour. The
same cleartext branch exists on the edit path
(`ChatEngine.swift:5331-5335`, comment: *"Agent-peer chats ride cleartext"*).

So: **groups, channels, Saved Messages and agent DMs are not end-to-end
encrypted.** The server reads them in full. `docs/security.md:12-14` already says
this; it is accurate.

### A.3 Three leaks that punch through the DM envelope

These are the findings that matter, because they apply *even to a properly
E2E-encrypted 1:1 DM*.

**(1) The media key is handed to the server and persisted.**

The AES key that decrypts the uploaded blob travels twice in cleartext:

```
ChatEngine.swift:4828    wirePayload["mediaKey"] = finalMediaKey      // top-level, cleartext
ChatEngine.swift:4529    nextMetadata["mediaKey"] = finalMediaKey     // → metadata
ChatEngine.swift:4874    wirePayload["metadata"] = cleaned            // metadata goes on the wire
```

Server side, `metadata` is persisted essentially whole — only sealed *agent* blobs
are dropped, and only `mediaUrl` is rewritten:

```
server/lib/vibe_web/channels/chat_channel.ex:1834-1873   message_metadata_for_persistence/2
server/lib/vibe_web/channels/chat_channel.ex:16          @inline_attachment_keys  (agent blobs only)
server/lib/vibe_web/channels/chat_channel.ex:149         metadata: message_metadata → messages.metadata
```

Meanwhile the ciphertext blob itself sits at a **public, unauthenticated** Supabase
object URL:

```
server/lib/vibe/supabase_storage.ex:231-233   "/storage/v1/object/public/#{bucket}/#{remote_path}"
server/lib/vibe_web/controllers/media_controller.ex:45-47   remote_path = "#{user_id}/#{ts}_#{rand}#{ext}"
```

**Net effect: the server holds both the ciphertext and the key.** Media
encryption today protects against a bucket-only breach (the object URL is
unguessable, 8 random bytes) and against a passive CDN observer. It does **not**
make media end-to-end encrypted. Any statement to that effect is false.

**(2) The caption and a real thumbnail of the image ride in cleartext metadata.**

```
ios/ChatModule/ChatListView.swift:20221   metadata["thumbnailBase64"] = optimisticThumb
ios/ChatModule/ChatListView.swift:20224   metadata["caption"] = effectiveText
```

Both land in `wirePayload["metadata"]` (`ChatEngine.swift:4874`) and are persisted
into `messages.metadata`. The server even logs its presence deliberately
(`chat_channel.ex:153`, `meta_thumb?=…`) and the iOS comment says the quiet part
out loud: *"Keep thumbs for durable list/profile after reopen"*
(`ChatEngine.swift:4872-4873`).

Mitigating detail: the thumbnail is genuinely tiny — 64px longest side, JPEG q0.52
(`ios/ChatModule/ChatListViewCells.swift:293-294,298-320`), a few hundred bytes.
It is a blur, not a photo. The **caption is not mitigated at all** — it is the
user's full message text, in the clear, for every media message in an E2E DM.

**(3) A 160-character plaintext preview of every message goes to the server.**

```
ChatEngine.swift:4792-4810   pushPreview = first 160 chars of text (or "Photo"/"Video"/…)
ChatEngine.swift:4821        "pushPreview": pushPreview,
```

The server reads it and forwards it to APNs as the notification body
(`server/lib/vibe_web/channels/chat_channel.ex:213-228`). The notification
extension never decrypts anything — it renders the server-supplied body
(`ios/NotificationServiceExtension/NotificationService.swift:48,385`). So the
server *and Apple* see the first 160 characters of every message. Not persisted
in `messages`, but in transit and in APNs logs.

### A.4 At rest on device — the store seal is real, the doc is stale

`docs/security.md:20-23` says the local SQLite cache is *"not sealed by an
application-level at-rest key."* **That is out of date.** Sealing shipped
2026-08-02 and is live:

- `ios/ChatModule/ChatMessageStore.swift:72` builds the sealer at open;
  `:249-271` seals every body; `:113-124` the `messages` table + `seal_nonce`
  column; `:330-377` the single shared reader.
- Cipher: AES-256-GCM with AAD bound to the row's address —
  `core/vibe_core/src/store_seal.rs:14` (`AAD = user_id ‖ 0x1F ‖ chat_id ‖ 0x1F ‖
  message_id`), `:162-167` random nonce generated core-side (`:146-149` explains
  why a caller-supplied nonce is refused). A relocated row fails closed
  (`:174,189-192`), and there is a device self-test proving it
  (`ios/Sources/Core/VibeCoreBridge.swift:269-290`).
- Key custody is careful: only `errSecItemNotFound` may mint a new key
  (`VibeCoreStoreKey.swift:59-64`) — a locked-device `errSecInteractionNotAllowed`
  is *not* treated as "no key", which is what stops a background launch from
  destroying the user's history. The DB directory is excluded from backup so the
  key and the data share a lifetime (`ChatMessageStore.swift:92-94`).

**Documented fail-open:** if the Keychain refuses a key, bodies are written
plaintext rather than lost (`ChatMessageStore.swift:249-271`, counted in
`sealSummary` at `:455`, logged at `:74-77`). That is a deliberate, logged,
counted trade — not a silent downgrade. It is the right call, but it means "the
local store is sealed" is a *usually*, not an *always*.

**Still unsealed:** the pre-SQLite `UserDefaults` history blob. Writes have
stopped and it self-migrates on read (`ChatEngine.swift:13071-13087`), but the
delete path can still rewrite a legacy blob (`ChatEngine.swift:10530-10547`), and
`UserDefaults` plists **are** included in device backups (the SQLite DB is not).
Legacy debt, small blast radius.

**Downloaded media on disk is plaintext.** `VibeMediaVault` decrypts on download
and writes the cleartext file (`ChatListView.swift:22604-22617`); the vault stores
raw bytes with no application-level seal
(`ios/ChatModule/VibeMediaVault.swift:333-348`) in Application Support, never
expiring (`:138-142`, `:26-30`). Protection is iOS Data Protection only.

### A.5 TLS vs at-rest vs E2E — say it plainly

- **TLS**: present everywhere; there is also a pinned session
  (`ChatPhoenixClient.makePinnedURLSession`, used for uploads at
  `ChatEngine.swift:12777`).
- **At-rest sealing (local)**: real, AES-256-GCM, row-bound AAD, per-install
  Keychain key. Fails open (plaintext) when the Keychain is unavailable.
- **True E2E**: **only** 1:1 human DM message *bodies*. Not groups, not channels,
  not Saved Messages, not agent DMs, not media (key is server-visible), not
  captions, not thumbnails, not push previews.

`arte1` (`AgentPairingService.swift:11-15,128-176`) is the one place the claim
holds cleanly: AES-256-GCM under a key exchanged out-of-band via pairing QR, so
the server really does only relay opaque bytes.

### A.6 Concrete gaps list

| # | Gap | Evidence | Severity |
|---|---|---|---|
| 1 | Media key persisted server-side next to the public ciphertext | `ChatEngine.swift:4828,4529,4874` + `chat_channel.ex:149,1834-1873` | **Critical** |
| 2 | Caption of every media message in cleartext metadata | `ChatListView.swift:20224` | **High** |
| 3 | Groups/channels/agent DMs entirely unencrypted | `ChatEngine.swift:4765-4766`, `5331-5335` | **High** (known, documented) |
| 4 | 160-char plaintext push preview to server + APNs | `ChatEngine.swift:4792-4821`, `chat_channel.ex:213-228` | **Medium** |
| 5 | 64px plaintext thumbnail persisted server-side | `ChatListView.swift:20221` | **Medium** |
| 6 | Server hands `encrypted_private_key` back on every login; unlock is password-derived | `auth_controller.ex:115,185` | **Medium** (design choice; means account password compromise = full history) |
| 7 | Store seal fails open to plaintext on Keychain unavailability | `ChatMessageStore.swift:249-271` | **Low** (logged, counted, deliberate) |
| 8 | Legacy `UserDefaults` history blob, unsealed and backup-included | `ChatEngine.swift:10530-10547` | **Low** |
| 9 | `docs/security.md` claims about local sealing are stale | `docs/security.md:20-23` | **Low** (doc only) |

---

## B. Media pipeline health

### B.1 The path, stage by stage

**Send**

| Stage | Owner |
|---|---|
| Pick / capture | `ChatAttachmentMenuController.sendPhoto/sendVideo` (`:960-1035`, `:1018-1035`) → plaintext temp file in `NSTemporaryDirectory()` |
| Optional edit | `ChatImageEditModule.presentEditor` (`:24-68`) / `ChatVideoEditModule.presentEditor` (`:12-28`) |
| Composer hand-off | `onSelectImage?(url.absoluteString, caption, capture)` (`ChatAttachmentMenuController.swift:1007,1046-1050`) |
| Optimistic row + micro-thumb | `ChatListView.swift:20140-20240` |
| Engine entry | `ChatEngine.sendMessage` (`:3992`) → background hop at `:4340` |
| Prepare (mesh-only re-encode) | `prepareLocalMediaUploadLocked` (`:12422-12462`) — pass-through unless `packet_mesh` |
| Encrypt | `chatEngineEncryptMediaData` (`:12727-12738`) |
| Upload | `uploadLocalMediaLocked` (`:12683-12862`), multipart, pinned session |
| Server store | `MediaController.upload` → `SupabaseStorage.upload` → public bucket |

**Receive**

| Stage | Owner |
|---|---|
| Gate | `mediaRequiresLocalDownload` — true iff a `mediaKey` exists (`ChatListView.swift:21428-21431`) |
| Download | `startRemoteMediaDownload` → `documentPreviewSession.downloadTask` (`ChatListView.swift:22189`) |
| Decrypt + persist | `persistDownloadedDocument` (`ChatListView.swift:22576-22677`) |
| Cache | `VibeMediaVault` (`ios/ChatModule/VibeMediaVault.swift`) |
| Display | `ChatListCell.configure` → `configureMediaPresentation` (`ChatListViewCells.swift:11103,13085`) |

### B.2 Is `VibeMediaVault` the single store? No — mostly.

It is the single *addressed* store, but it explicitly still accounts for six
pre-vault directories and the music player's own cache, and does not own them:

```
ios/ChatModule/VibeMediaVault.swift:150-174   externalDirectories(for:)
   chat-media-images, chat-media-video-preview, voice-cache,
   native-music-player-cache, music_cache, vibe-chat-preview-docs,
   chat-doc-page-previews, vibe-avatars — each under BOTH Caches and the durable root
```

Legacy files are adopted lazily on a miss (`:284-292`) rather than migrated. So:
**half-migrated by design**, and the music cache is permanently excluded because
its DB holds absolute paths (`:151-153`) — which is exactly the
`absolute-paths-die-on-reinstall` hazard, still live. The vault's own workaround
for that class of bug is `ChatListView.relocatedToCurrentContainer`
(`ChatListView.swift:21445-21453`).

### B.3 Thread hazards — cited

**Good news first.** The heavy crypto is *not* on main:

- Encrypt + upload run on `DispatchQueue.global(qos: .userInitiated)`
  (`ChatEngine.swift:4340-4341`).
- Decrypt on download runs on the URLSession delegate queue
  (`ChatListView.swift:22551-22562` → `persistDownloadedDocument`).
- Video-editor thumbnail strip generation is off-main
  (`ChatVideoEditViewController.swift:1379-1396`), export is
  `exportAsynchronously` (`:2270`).
- `syncOnQueue` has a real main-thread-hang watchdog that names the call site
  (`ChatEngine.swift:15061-15095`).

**The hazards that are real:**

1. **Full image decode on the main thread during cell configure.**
   `ChatListCell.configure` → `configureMediaPresentation`
   (`ChatListViewCells.swift:11103`, `:13085`) → on a cache miss calls
   `chatMediaLoadImageFromFile` (`:13588`), which does
   `Data(contentsOf:)` + `UIImage(data:)` **synchronously**
   (`ChatListViewCells.swift:483-499`). Mitigated by the in-memory
   `chatMediaImageCache` first branch (`:13583`), so it bites on cold scroll only.

2. **Video poster-frame extraction on the main thread.** Same function falls
   through to `AVAssetImageGenerator.copyCGImage` for a local video
   (`ChatListViewCells.swift:493-498`) — a synchronous decode of the first frame,
   during configure.

3. **Disk read + decode on main for cached remotes.**
   `chatMediaDiskCacheLoad` (`ChatListViewCells.swift:542-548`) plus
   `chatMediaPreviewImage`, both from configure (`ChatListViewCells.swift:13613`).

4. **Image editor flattening + JPEG encode on main.**
   `snapshotEditedImage` (`ChatImageEditViewController.swift:679-708`) renders at
   full base pixel size, then `writeJPEGToTemp` resizes and encodes
   (`:711-732`) — both called from `emit` on the send tap (`:734-740`).

5. **Store seal + SQLite write on the engine serial queue.**
   `messageStore.upsertMessages` is called from `*Locked` methods
   (`ChatEngine.swift:11747`, `:13254`), i.e. on `vibe.chat.engine`. Any main-thread
   `syncOnQueue` read queues behind it. Per-row cost is microseconds today, but it
   scales with payload size — see the variant warning in §C.3.

### B.4 Streaming? No. Everything is whole-file, in memory.

The core is honest about this and it is worth quoting because it is the design
constraint for the video feature:

```
core/vibe_core/src/media.rs:9-27
  "Today's blob is a single AES-GCM message over the whole file: iv || ciphertext || tag.
   The authentication tag covers everything and is only verifiable at the end …
   (1) buffer the whole ciphertext, verify, expose (what ships today, and it holds
   the file in memory twice)"
core/vibe_core/src/media.rs:38   MAX_WHOLE_FILE_DECRYPT_BYTES = 64 MiB
core/vibe_core/src/media.rs:48   VIBE_STREAM2_MAGIC = b"vmed2"   ← specified, NOT enabled
```

Note the core's ceiling is **specified but not enforced on the iOS path** — the
Swift media crypto (`ChatEngine.swift:321-353`) is a separate implementation and
has no size cap. The core's `media.rs` is not wired into the live media path at
all; only the store sealer and the timeline reducer are.

**Actual upload memory profile for one video** (`ChatEngine.swift:12700-12759`):

```
:12702   fileData          = Data(contentsOf:, .mappedIfSafe)   1×  (mapped)
:12729   encrypted         = seal(preparedUpload.fileData)      1×  resident (+16B tag)
:12757   body.append(uploadFileData)                            1×  resident (multipart body)
```

Plus AES-GCM faults the mapped original in. For a 1-minute 1080p clip
(~60–90 MB) that is a realistic **~180–270 MB peak**, entirely resident, on a
`.userInitiated` global queue. The server cap is 120 MB
(`server/lib/vibe_web/controllers/media_controller.ex:12`) and the Phoenix parser
cap is the same (`server/lib/vibe_web/endpoint.ex:4`), so a long video is a
plausible jetsam kill on device before the server ever refuses it.

Download is the mirror image (`ChatListView.swift:22604-22615`): mapped
ciphertext + full plaintext `Data` + disk write.

### B.5 Other things currently broken or half-done

- **Dual caches**: §B.2. Eight legacy directories still hold bytes.
- **Absolute-path assumptions**: the music cache DB stores absolute paths and is
  therefore excluded from the vault (`VibeMediaVault.swift:151-153`);
  `relocatedToCurrentContainer` (`ChatListView.swift:21445-21453`) is the band-aid.
- **`/app/uploads` on the server** is a container-local, ephemeral directory
  served unauthenticated by `Plug.Static` (`server/lib/vibe_web/endpoint.ex:56-61`).
  Anything written there dies on redeploy and is invisible to a second instance.
  The existing AI image editor writes there — see §D.
- **Stale comment**: `ChatEngine.swift:4239` says key resolution "may do
  synchronous HTTP"; `resolveFriendPublicKeyLocked` (`:9082-9091`) is cache-only.
  Harmless, but misleading.

---

## C. Feasibility for AI media editing

### C.1 What has to be decrypted, and by whom: **nothing.**

This is the important finding. The composer already hands the editors a
**plaintext local file**, before anything is encrypted, uploaded, or sealed:

```
ChatAttachmentMenuController.swift:976-981   image → temp file, plaintext
ChatAttachmentMenuController.swift:996-1015  → ChatImageEditModule.presentEditor(mediaURL: url)
ChatAttachmentMenuController.swift:1018-1035 video → PHImageManager AVAsset
ChatAttachmentMenuController.swift:1039-1061 → ChatVideoEditModule.presentEditor(asset:)
```

Both editors return a plaintext temp-file URL:

```
ChatImageEditModule.swift:10-16     ChatImageEditActionPayload { editedImageURL: URL? }
ChatVideoEditModule.swift:4-10      ChatVideoEditActionPayload  { videoURL: URL }
```

and only *then* does the file enter the pipeline via `onSelectImage?(…)`
(`ChatAttachmentMenuController.swift:1007`, `:1046-1050`) →
`ChatEngine.sendMessage` → encrypt (`ChatEngine.swift:12729`).

**The cleanest interception point is inside `ChatImageEditViewController` /
`ChatVideoEditViewController`, as another edit operation alongside PencilKit
markup.** Concretely: a new action that POSTs the current plaintext temp file to
our server, receives the edited asset, and replaces `imageView.image` /
`self.asset`. Everything downstream — sealing, upload, key generation — is
untouched.

### C.2 Is this an E2E break? No.

**Pre-send editing sits entirely outside the envelope.** The user has not sent
anything yet; the bytes are a local file they just picked. Sending them to our
server (and onward to OpenAI/Google) is a *disclosure the user is initiating*, not
a weakening of a guarantee that had already attached. It is exactly the same trust
boundary as the existing `/api/ai/edit_image` endpoint, and materially *less*
exposure than what already happens today, because — per §A.3(1) — the server can
already decrypt every piece of media that gets sent through it.

Two caveats worth stating in the UI, not in code:
1. The **original** must not be uploaded for editing unless the user asked to
   edit. Do not prefetch or "pre-warm" edits.
2. If the edit round-trip is done *post*-send (editing an already-sent message),
   that **is** a genuine break — it would require decrypting a sealed asset and
   handing it to a third party. Don't build that path first; the composer path has
   none of that problem.

### C.3 Can the architecture carry extra variants (original + edited + mask + preview)?

**On disk / in the vault: yes, cheaply.** The vault is content-addressed by
`identity(remoteURL:mediaKey:)` (`VibeMediaVault.swift:109-128`) with a per-kind
in-memory index (`:191-227`). A new variant is just a new identity; adding one
costs one dictionary entry and one file. There is even an unused `.videoPreview`
kind (`VibeMediaVault.swift:35,44`) that fits a derived-variant model.

**In the message payload: no — this is where it will fight the existing caches.**

- Anything put in `metadata` is (a) sealed into the local row, (b) sent on the
  wire, (c) persisted into `messages.metadata` **in cleartext**
  (`chat_channel.ex:149,1834-1873`), and (d) fanned out to every participant via
  the per-user mirror, which hard-caps at 16 KB and silently drops the whole
  mirror above it (`server/lib/vibe/chat.ex:55,82-85`). Inline a mask PNG as
  base64 and you break the mirror for that message *and* publish the mask to the
  server in the clear.
- The existing precedent is deliberately tiny for exactly this reason: the
  micro-thumb is 64px / q0.52 (`ChatListViewCells.swift:293-294`).
- **Rule for the feature: variants are separate uploaded blobs with their own
  `mediaKey`, referenced by id in metadata. Never inline bytes.**

**Sizing/layout:** width/height ride in metadata (`ChatListView.swift:20213-20216`)
and drive row heights. A variant whose aspect differs from the original will
produce the media-square-fallback shift already known to this codebase. **The
edited variant must carry its own width/height, and the row must not paint until
it has them.**

### C.4 Video-specific risks

1. **Memory is the blocker, not crypto.** §B.4: ~3 resident copies on upload.
   Adding an AI round-trip adds a 4th (the returned asset) and potentially a 5th
   (base64 for transport — +33%). A 1-minute clip through a naive
   base64-JSON round-trip is a jetsam kill. **Use multipart upload + a URL
   reference for the result, never base64 in JSON.**
2. **Frame extraction for region selection** must stay off-main. The existing
   pattern is right (`ChatVideoEditViewController.swift:1379-1396`: 14 frames,
   180px cap, on `.userInitiated`). The wrong pattern also exists in the codebase
   — `ChatListViewCells.swift:493-498` does `copyCGImage` on main. Copy the first.
3. **Region overlays already exist.** `ChatVideoEditViewController` has a drawing
   view and text overlays (`:1719-1720` `hasOverlayContent`), composes via
   `AVMutableVideoComposition`, and exports via `AVAssetExportSession`
   (`:2226-2270`). A mask is a render of the same overlay layer to a mono image —
   no new machinery needed.
4. **Export presets cap at 1280x720 on the attachment path**
   (`ChatAttachmentMenuController.swift:1065-1069`) but the editor picks from a
   candidate list (`ChatVideoEditViewController.swift:2160-2169`). Pin the AI path
   to a bounded preset so a 4K source cannot enter the round-trip at full size.

---

## D. Server side

### D.1 There is already an AI image-edit endpoint. It is unused and not
production-shaped.

```
server/lib/vibe_web/router.ex:287-290   pipe_through [:strict_rate_limited, :api_authenticated]
                                        post "/ai/edit_image", AIController, :edit_image
server/lib/vibe_web/controllers/ai_controller.ex:15-29
server/lib/vibe/ai/image_editor.ex:1-163
```

- **Provider:** Gemini 3 Pro Image Preview ("Nano Banana Pro"),
  `image_editor.ex:11`. Key from `System.get_env("GEMINI_API_KEY")` (`:26`) — same
  pattern as every other provider (`agent_runtime.ex:43-44`, `agent.ex:1005`,
  `tools/vision.ex:47`). Env-var only, never in the DB, never sent to clients.
  That part is fine.
- **No iOS client calls it.** Grep for `edit_image` across `ios/` and `client/`
  returns nothing. iOS never talks to any model provider directly (verified: no
  `openai.com` / `googleapis.com` / `api.anthropic.com` in `ios/`).
- **It writes results to `/app/uploads`** (`image_editor.ex:12,137-157`), which is
  ephemeral container storage served unauthenticated
  (`endpoint.ex:56-61`) — **not** the Supabase media bucket, **not** encrypted,
  **not** durable across a redeploy. Any real feature must route the result
  through `SupabaseStorage.upload` (`media_controller.ex:47`) instead.
- **SSRF is handled**: `SafeURL.validate` before fetch (`image_editor.ex:47`,
  `net/safe_url.ex:6-41`, resolves and blocks private ranges).
- **No size cap on the fetched image**: `Vision.fetch_and_encode`
  (`tools/vision.ex:141-155`) downloads the whole body and base64s it (1.33×) with
  no ceiling, and the endpoint accepts a 120 MB JSON body
  (`endpoint.ex:4`). That is a memory-DoS surface.

### D.2 Auth and rate limiting for AI calls

- Auth: `ApiAuth, required: true` (`router.ex:13-15`).
- Rate limit: `strict` = **60 requests / 60 s** per identifier
  (`server/lib/vibe_web/plugs/rate_limiter.ex:20`), ETS-backed sliding window
  (`:108-150`), env-overridable (`:182-189`). Sixty paid image-model calls a minute
  per user is far too generous for a third-party-billed endpoint — this needs its
  own much tighter bucket, plus a per-user daily quota, before it is exposed.
- There is a subscription system (`Vibe.Subscriptions`,
  `subscription_controller.ex`) that an AI-edit quota should hang off.

### D.3 Existing media-processing endpoint to build on

`POST /api/media/upload` (`router.ex:266`, `media_controller.ex:26-65`) is the one
to extend: it already authenticates, caps size, generates a non-guessable path,
and returns a durable URL. The right shape for the new feature is
`POST /api/ai/media/edit` in the same authenticated scope, accepting a multipart
upload (not a URL, not base64), calling the provider, storing the result via
`SupabaseStorage.upload`, and returning a durable URL — with its own rate-limit
bucket.

---

## E. Verdict

### Encryption status: **DEGRADED**

The primitives are right. The envelope leaks around the edges, and one leak is
severe enough that a public "your media is end-to-end encrypted" claim would be
false.

| # | Issue | Evidence | Fix direction |
|---|---|---|---|
| 1 | **Media key is persisted to the server** next to a public ciphertext blob → server can decrypt all media | `ios/ChatModule/ChatEngine.swift:4828` and `:4529` → `:4874`; `server/lib/vibe_web/channels/chat_channel.ex:149` | Strip `mediaKey` from `wirePayload` and from `wireMetadata`; it already rides inside the sealed `fullPayload` (`ChatEngine.swift:4728`). For groups, the key must ride a group-key envelope, not cleartext. Server-side, add `mediaKey`/`media_key` to a persist-strip list as a belt-and-braces. |
| 2 | **Caption of every media message in cleartext metadata** | `ios/ChatModule/ChatListView.swift:20224` | Remove `metadata["caption"]`; the caption is already inside the encrypted payload (`ChatEngine.swift:4738`). Anything reading it from metadata should read the opened body instead. |
| 3 | **Groups, channels, Saved Messages and agent DMs are plaintext** | `ios/ChatModule/ChatEngine.swift:4765-4766`, `:5331-5335` | Known, documented (`docs/security.md:12-14`). Needs a real group-key design. Until then the product copy must say "E2E in one-to-one chats", never app-wide. |

Honourable mentions, ranked below the top three: the 160-char plaintext
`pushPreview` (`ChatEngine.swift:4821`), the 64px plaintext thumbnail
(`ChatListView.swift:20221`), and the stale local-sealing claim in
`docs/security.md:20-23`.

### Media status: **HEALTHY-WITH-DEBT**

Functionally sound, well-instrumented, and the vault design is genuinely good. The
debt is memory and main-thread, and it is concentrated exactly where the video
feature will land.

| # | Issue | Evidence | Fix direction |
|---|---|---|---|
| 1 | **Whole-file, ~3 resident copies on upload** — a 1-minute video is a plausible OOM | `ios/ChatModule/ChatEngine.swift:12702,12729,12757` | Stream the multipart body from a file (`uploadTask(with:fromFile:)`) and seal to a temp file rather than to `Data`. The core already specifies the fix as `vmed2` (`core/vibe_core/src/media.rs:9-27,48`); shipping option (2) — decrypt/encrypt to a temp file — is the cheap intermediate. |
| 2 | **Image and video-frame decode on the main thread during cell configure** | `ios/ChatModule/ChatListViewCells.swift:483-499` called from `:13588`, reached from `configure` at `:11103,13085` | Hoist the file read + decode to the existing `chatMediaDiskCacheQueue` and apply on main, matching the pattern already used for document page previews at `ChatListView.swift:2320-2340`. |
| 3 | **Eight legacy media directories still hold bytes; the music cache can never join the vault** (absolute paths) | `ios/ChatModule/VibeMediaVault.swift:150-174`, `:151-153` | Finish the migration: adopt on read is already there (`:284-292`); add a one-shot background sweep and re-key the music cache by identity instead of absolute path. |

### Blocking vs non-blocking

**Blocks AI media editing — fix first:**

- **Nothing in the crypto layer.** Pre-send editing does not touch the envelope.
  Fixing gaps A/1 and A/2 is *urgent for the product's honesty*, but it is
  independent work and does not gate this feature.
- **Media/1 (whole-file memory) genuinely blocks the video feature.** Today's send
  path already peaks around 180–270 MB for a 1-minute clip. Adding a round-trip
  through a model on top of that will OOM on real devices. This must be fixed, or
  the video feature must be capped hard (duration and preset) before it ships.
- **Server: `/app/uploads` result storage** (`server/lib/vibe/ai/image_editor.ex:12,137-157`)
  must move to `SupabaseStorage` before anything user-visible depends on it —
  results currently vanish on redeploy.
- **Server: rate limiting.** 60/min on a paid provider call
  (`rate_limiter.ex:20`) needs its own bucket and a quota before exposure.
- **Design constraint, not a bug:** variants must be separate blobs referenced by
  id. Inlining a mask or an edited preview into `metadata` will blow the 16 KB
  mirror cap (`server/lib/vibe/chat.ex:55,82-85`) and publish it in cleartext.

**Pre-existing debt — fix in parallel:**

- All of §A.6 items 3–9 (group E2E, push preview, thumbnail, key-escrow-on-login,
  seal fail-open, legacy `UserDefaults` blob, stale docs).
- Media/2 (main-thread decode) and Media/3 (dual caches).
- `Vision.fetch_and_encode` unbounded download (`server/lib/vibe/ai/tools/vision.ex:141-155`).
- The stale comment at `ChatEngine.swift:4239`.

### Where docs disagree with code

- `docs/security.md:22-25` — says the iOS SQLite cache "is not sealed by an
  application-level at-rest key." **Wrong as of 2026-08-02**; sealing is live
  (`ChatMessageStore.swift:72,249-271`, `core/vibe_core/src/store_seal.rs`).
- `docs/security.md:26-30` — says media uses a whole-file AES-GCM envelope that
  must not be presented as authenticated streaming decryption. **Correct**, and
  confirmed by `core/vibe_core/src/media.rs:9-27`.
- `docs/security.md:17-20` — the group/channel plaintext statement is **correct**.
- `docs/security.md:92-95` ("All uploaded media encrypted … Key: Derived from
  user's master key") — **wrong on the key**. The media key is random per file
  (`ChatEngine.swift:322`) and is sent to the server in cleartext. It sits under
  the "Legacy target design" heading but reads as current; correct or delete it.
