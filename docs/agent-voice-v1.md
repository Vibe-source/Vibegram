# Agent voice — `vibe.voice.v1`

Voice sessions for isolated agents. Part of [`agent-platform-v1.md`](agent-platform-v1.md)
§3.7/§3.9. The phone opens a WebSocket to `vibe-agent-runtime` and talks PCM16 audio
directly to a realtime speech model; tool calls made during the call go through the same
risk-classified approval path as text runs, surfaced as in-call prompts instead of chat
messages. This doc is the frozen wire contract — iOS builds its call UI against it in a
later slice.

## 1. Sequence

```
 iOS                    vibe-core                 vibe-agent-runtime              OpenAI Realtime
  │  POST /api/agents/:id/voice/sessions │                                          │
  │──────────────────────────────────────▶│                                          │
  │        (authenticated; participant or owner of :id)                             │
  │                                        │  POST /internal/v1/voice/sessions       │
  │                                        │  {agentId,userId,chatId,agentProfile}   │
  │                                        │─────────────────────────────────────────▶│ (not yet — see below)
  │                                        │◀─────────────────────────────────────────│
  │                                        │  {sessionId, wsUrl, token, expiresAt}   │
  │◀───────────────────────────────────────│                                          │
  │  {sessionId, wsUrl, token, expiresAt}  │                                          │
  │                                                                                    │
  │  WS connect wsUrl?token=<token>                                                   │
  │───────────────────────────────────────────────────────────────────────────────────▶│ VoiceSocket.connect/3
  │                                                                                    │  verifies Phoenix.Token (max_age 900s)
  │  join "voice:<sessionId>"                                                         │
  │───────────────────────────────────────────────────────────────────────────────────▶│ VoiceChannel.join/3
  │                                                                                    │  sid must match token's sid;
  │                                                                                    │  starts/attaches VibeAgents.Voice.Session
  │                                                                                    │  Session starts the provider ─────────────▶│ wss://api.openai.com/v1/realtime?model=…
  │                                                                                    │◀──────────────────────────────── session.created
  │                                                                                    │  ── session.update (instructions, tools, audio) ─▶│
  │                                                                                    │◀──────────────────────────────── session.updated
  │◀─────────────────────────────────────  "session.ready" {sessionId,model,voice,sampleRate:24000}
  │  "audio.chunk" {seq, codec, sampleRate, dataBase64} ...                          │
  │───────────────────────────────────────────────────────────────────────────────────▶│  resample→24k → input_audio_buffer.append
  │                                                                                    │◀── response.output_audio.delta / …_transcript.delta
  │◀─────────────────────────────────────  "audio.chunk" / "transcript.agent" ...     │
```

`vibe-core` never talks to OpenAI. `vibe-agent-runtime` never sees the core's database —
it only received `agentProfile` (already resolved by the core) in the session-create call.

## 2. Session creation

`VibeAgents.Voice.Sessions.create/1` takes `%{"agentId", "userId", "chatId", "agentProfile"}`
and returns `{:ok, %{session_id, ws_url, token, expires_at}}`.

- `session_id`: a fresh UUID.
- `token`: `Phoenix.Token.sign(VibeAgentsWeb.Endpoint, "voice-session", %{sid: session_id, user_id: userId, agent_id: agentId})`.
- `ws_url`: `VIBE_AGENTS_PUBLIC_URL <> "/v1/voice/socket/websocket"`. The client appends
  `?token=<token>&vsn=2.0.0` per the Phoenix socket transport convention.
- `expires_at`: now + 15 minutes — **the join deadline**, not the call length. The token's
  own `max_age` (900s) is enforced independently by `Phoenix.Token.verify/4` at connect time,
  so a stale token is rejected even if a caller ignores `expires_at`.

The session record itself (agent/user/chat ids + `agentProfile`) is kept in an ETS table
`:vibe_voice_sessions` with a 2-hour TTL — long enough to cover setup, the 30-minute call
cap, and a brief client reconnect, independent of the 15-minute join window. A background
sweep (inside `VibeAgents.Voice.Sessions`, the table's owner process) deletes expired rows;
nothing else assumes the table is small.

Core side (not built in this slice, documented for the corebridge worker): `POST
/api/agents/:id/voice/sessions`, authenticated, caller must be the chat participant or the
agent owner, resolves `agentProfile` the same way a run does, calls `POST
/internal/v1/voice/sessions` on the runtime, relays the response verbatim.

## 3. Socket and channel

- `VibeAgentsWeb.VoiceSocket` (`use Phoenix.Socket`): `channel "voice:*", VibeAgentsWeb.VoiceChannel`.
  `connect/3` reads the `token` param, verifies it with `Phoenix.Token.verify(VibeAgentsWeb.Endpoint,
  "voice-session", token, max_age: 900)`, and on success stores `sid`/`user_id`/`agent_id` in
  socket assigns. A missing, malformed, expired, or bad-signature token fails the connect —
  the client never reaches `join/3` at all.
- `VibeAgentsWeb.VoiceChannel.join("voice:" <> session_id, _payload, socket)`: rejects if
  `session_id` doesn't match the token's `sid` (a valid token for session A can never join
  session B's topic), rejects if `VibeAgents.Voice.Sessions.fetch/1` has no live record
  (expired or unknown), then starts-or-attaches a `VibeAgents.Voice.Session` GenServer for
  that id (`DynamicSupervisor.start_child(VibeAgents.Voice.Supervisor, …)`, registered as
  `{:via, Registry, {VibeAgents.Voice.Registry, session_id}}`; a rejoin on the same id
  re-binds the existing session to the new channel pid instead of starting a second
  provider connection). `join/3` itself returns bare `{:ok, socket}` — the client waits for
  the async `"session.ready"` push (below) before it starts streaming audio, because that
  push only fires once the upstream provider has confirmed its own session is configured.

## 4. `VibeAgents.Voice.Provider` behaviour

```elixir
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_audio(pid, pcm16 :: binary()) :: :ok
@callback send_text(pid, text :: String.t()) :: :ok
@callback send_image(pid, jpeg :: binary()) :: :ok
@callback commit(pid) :: :ok
@callback interrupt(pid) :: :ok
@callback tool_result(pid, call_id :: String.t(), result :: term()) :: :ok
@callback stop(pid) :: :ok
```

The provider process sends its **owner** (the pid passed as `opts[:owner]` to `start_link/1`
— always the `VibeAgents.Voice.Session` that started it) messages shaped
`{:voice_provider, event}` with:

| event | meaning |
|---|---|
| `{:ready}` | upstream session configured; safe to start sending audio |
| `{:transcript_user, text, final?}` | speech-to-text of the caller; `final?` distinguishes a live partial from the committed line |
| `{:transcript_agent, text, final?}` | the agent's own spoken text, same partial/final shape |
| `{:audio, pcm16_binary}` | one chunk of agent speech, PCM16 24 kHz mono |
| `{:tool_call, call_id, name, input}` | the model wants to call a tool; `input` is a decoded map |
| `{:error, reason}` | provider-level error (bad frame, upstream error event, socket failure) — not fatal by itself |
| `{:done}` | the provider's own connection/session has ended; the voice `Session` should end the call |

All callbacks other than `start_link/1` return `:ok` and are fire-and-forget (cast-style) —
none of them block waiting on the provider's network round trip. Ordering of the resulting
`{:voice_provider, event}` messages is preserved per-provider-process but callers must not
assume synchronous request/response pairing.

## 5. `VibeAgents.Voice.OpenAIRealtime`

Connects to `wss://api.openai.com/v1/realtime?model=<VIBE_VOICE_MODEL>` using
`Mint.WebSocket` (no `OpenAI-Beta` header needed on the GA endpoint — just `Authorization:
Bearer <OPENAI_API_KEY>`). Audio both ways is PCM16 at 24 kHz.

On connect, waits for the server's `session.created`, then sends one `session.update`:

```jsonc
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "model": "<VIBE_VOICE_MODEL>",
    "instructions": "<VibeAgents.Policy.system_prompt/2, or a local fallback>",
    "output_modalities": ["audio", "text"],
    "audio": {
      "input":  { "format": { "type": "audio/pcm", "rate": 24000 }, "turn_detection": { "type": "server_vad" } },
      "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "<VIBE_VOICE_VOICE>" }
    },
    "tools": [ /* VibeAgents.Tools.Catalog.specs/2, converted to {type:"function",name,description,parameters}; [] if unavailable */ ]
  }
}
```

`{:voice_provider, :ready}` fires only after the matching `session.updated` comes back —
this is deliberately stricter than "socket open" so a client never streams audio into an
unconfigured session. Client→provider action mapping:

| `Provider` call | Realtime client event |
|---|---|
| `send_audio/2` | `input_audio_buffer.append` (`audio`: base64 PCM16) |
| `commit/1` | `input_audio_buffer.commit` (server VAD normally commits on its own; this covers an explicit client-side end-of-turn) |
| `send_text/2` | `conversation.item.create` (`role:"user"`, `input_text`) **then** `response.create` — text has no VAD path, so it must trigger the turn itself |
| `send_image/2` | `conversation.item.create` with an `input_image` content part (`data:image/jpeg;base64,...`); does **not** trigger `response.create` — an image is context, not a turn-ender, matching the ≤1/s frame rate |
| `interrupt/1` | `response.cancel` |
| `tool_result/3` | `conversation.item.create` (`type:"function_call_output"`, `call_id`, `output`: JSON string) **then** `response.create` so the model continues |
| `stop/1` | closes the WebSocket |

Provider→owner event mapping (server events actually used; anything else is ignored):

| Realtime server event | owner message |
|---|---|
| `session.created` → (after our `session.update`) `session.updated` | `{:ready}` |
| `conversation.item.input_audio_transcription.delta` / `.completed` | `{:transcript_user, text, final?}` |
| `response.output_audio_transcript.delta` / `.done` | `{:transcript_agent, text, final?}` |
| `response.output_audio.delta` | `{:audio, Base.decode64!(delta)}` |
| `response.output_item.added` (`item.type == "function_call"`) | (buffers `call_id`/`name`, no owner message yet) |
| `response.function_call_arguments.delta` / `.done` | accumulates args text; on `.done`, JSON-decodes and emits `{:tool_call, call_id, name, input_map}` |
| `error` | `{:error, %{code:, message:}}` |
| WebSocket close / unrecoverable transport error | `{:done}` |

No reconnect/backoff in v1 — a dropped upstream connection ends the call (`{:done}` →
`Session` pushes `"session.ended" {reason:"provider_error"}`). See §9.

**Assumption flagged for verification against live traffic before this ships:** the
`session.update` shape above (nested `session.audio.input`/`session.audio.output`, and the
`response.output_audio.*` / `response.output_audio_transcript.*` event names) is the current
GA Realtime schema as of this writing, which replaced an older flat `modalities` /
`input_audio_format` / `response.audio.*` shape used in earlier previews. If OpenAI's wire
format has moved again, only `openai_realtime.ex` needs to change — nothing else in this
doc or in `VibeAgents.Voice.Session` depends on the exact JSON.

## 6. Channel frames

Base64 fields are standard (not URL-safe) base64.

**Client → server**

| event | payload |
|---|---|
| `audio.chunk` | `{seq, codec:"pcm16le", sampleRate:24000\|16000, dataBase64}` — 16 kHz is upsampled to 24 kHz with linear interpolation (`VibeAgents.Voice.Audio`) before it reaches the provider |
| `audio.end` | `{}` — end of an audio turn (maps to `Provider.commit/1`) |
| `interrupt` | `{}` — barge-in; cancels the agent's current turn |
| `text.message` | `{text}` — typed input mid-call |
| `image.frame` | `{jpegBase64}` — ≤ 300 KB, rate-limited to 1/s; over either limit the frame is dropped (oversized frames also get an `"error"` push, rate-limit overflow is silently dropped) |
| `decision` | `{decisionId, outcome, answer}` — resolves a pending `approval.requested` (§7) |
| `hangup` | `{}` — client-initiated end |

**Server → client**

| event | payload |
|---|---|
| `session.ready` | `{sessionId, model, voice, sampleRate:24000}` |
| `transcript.user` | `{text, final}` |
| `transcript.agent` | `{text, final}` |
| `audio.chunk` | `{seq, codec:"pcm16le", sampleRate:24000, dataBase64}` |
| `tool.progress` | `{label, tool, status:"running"\|"done"\|"error"}` |
| `approval.requested` | `{decisionId, title, detail, actions, expiresAt}` |
| `session.ended` | `{reason:"hangup"\|"idle"\|"max_duration"\|"provider_error"\|"error"}` |
| `error` | `{code, message}` — non-fatal; the call continues unless followed by `session.ended` |

`error.code` values used in v1: `audio_rate_limit`, `image_too_large`, `unknown_decision`,
`tool_unavailable`, `provider_error`.

## 7. Tool calls and approvals during a call

A `{:tool_call, call_id, name, input}` from the provider is authorized by
`VibeAgents.Voice.Session.authorize_tool_call/3`, which calls
`VibeAgents.Broker.authorize(%{"agent_profile" => agentProfile}, name, input)` — the same
deterministic broker text runs use ([`agent-platform-v1.md`](agent-platform-v1.md#39-capability-broker-and-hard-limits-runtime)
§3.9). A plain `%{"agent_profile" => ...}` map is all `authorize/3` needs (it never required
an `agent_runs` row — it only ever reads `agentProfile.autonomyMode`/`approvalRules`), so a
voice session calls it exactly as a text run would, no adapter needed. The call is wrapped in
`VibeAgents.Voice.SafeApply` (`Code.ensure_loaded?/1` + `function_exported?/3` + rescue), so
if the broker isn't compiled yet the session falls back to `VibeAgents.Voice.ToolRisk`, a
smaller static table matching `Broker.risk_class/2`'s by-name defaults — it can't reproduce
the broker's content heuristics on `computer_run`/`browser_act` (command/text pattern
matching for credential and external-effect risk), so under the fallback those two stay
`write_local` regardless of content. Swap-over is automatic and requires no code change once
the broker is compiled into the running release.

`authorize/3` returns one of four outcomes, mapped as:

| outcome | voice handling |
|---|---|
| `:run` | execute immediately, no approval frame (covers all `read`-class tools) |
| `{:approval, request}` | see below |
| `{:ask, questions}` | no separate ask UI in a call — `tool_result` tells the model to ask out loud; the caller's next utterance is the answer (an ordinary `transcript_user` turn, not a `decision` frame). Covers the `ask_user` tool and `:credential`-risk actions alike |
| `{:deny, reason}` | `tool_result` with `{"error":"not_permitted","reason":reason}`, no execution |

On `{:approval, request}`: `VibeAgents.Voice.Session` mints a `decisionId`, pushes
`"tool.progress" {label:name, tool:name, status:"running"}` then `"approval.requested"
{decisionId, title, detail, actions, expiresAt}` (`title`/`detail`/`actions` come from the
broker's `request` when present, a local default otherwise), and waits — no timeout enforced
server-side beyond `expiresAt` being informational to the client in v1 (a `decision` that
never arrives simply leaves that one tool call unresolved until `hangup`/idle/max-duration
ends the whole session; see §11 for the phase-2 fix). On a `decision` frame:
`approve`/`allow_once`/`allow_run` runs the tool via `VibeAgents.Tools.Executor.execute/3`
(also through `SafeApply`, because the executor is owned by the runtime worker and may not
exist yet — a missing or mismatched executor degrades to a `tool_unavailable`-shaped result,
never a crash); anything else calls `Provider.tool_result/3` with a denial payload so the
model can react in speech. Either way `"tool.progress" {status:"done"|"error"}` follows.

**Known gap:** the runtime worker's own brief describes `Tools.Executor.execute/3` as
`execute(tool_calls, state, callback)` — batch/stateful/callback-driven, "same contract as
the core's" — not the single `execute(name, input, context)` shape called above. The call
stays safe either way (`SafeApply` catches the argument mismatch and falls back), but tool
calls made during a voice session won't actually execute until `Session.execute_tool/4` is
adapted to that real shape once the executor exists and its `tool_calls`/`callback` contract
is confirmed.

## 8. Audio format

PCM16 signed little-endian, mono, 24 kHz is canonical everywhere except the client-to-server
audio path, which also accepts 16 kHz (common for phone mics) and upsamples with simple
linear interpolation in `VibeAgents.Voice.Audio.resample_16k_to_24k/1` — adequate for speech,
not spectrally clean, and out of scope to improve for v1. Each `audio.chunk` frame is
expected to carry a whole number of 16-bit samples; a stray trailing odd byte is dropped
rather than buffered across chunks, so the client should chunk on sample boundaries (it
already must, to keep `seq` meaningful).

## 9. iOS integration (later slice, documented now)

- Capture with `AVAudioEngine` at 24 kHz mono PCM16 to avoid the resample path entirely
  (16 kHz is accepted but costs quality); install a tap, base64-encode each buffer, send as
  `audio.chunk` with an incrementing `seq`.
- Playback: decode `audio.chunk.dataBase64` to PCM16 and feed an `AVAudioEngine` player node
  scheduled buffer at 24 kHz; do not wait for a full response before starting playback —
  chunks arrive incrementally and should play as they land.
- Opus is not needed in v1 — PCM16 over a private WebSocket to `agents.<host>` is fine at
  call volumes; revisit only if bandwidth becomes a constraint (see phase 2 below).
- Drive the existing call screen's mic-mute/speaker UI from `audio.end` / `interrupt`
  (barge-in: stop local playback immediately on sending `interrupt`, don't wait for the
  server's next frame — the model's in-flight audio is stale the moment the user starts
  talking).
- Render `approval.requested` as an in-call prompt (not the chat's decision message UI —
  this is a different channel and a different `decisionId` namespace than `agent-approval`
  text-run approvals), reply with `decision`.
- On `session.ended`, tear down the call UI; the `reason` distinguishes a clean hangup from
  a server-side cutoff so the UI can decide whether to offer "call again."
- Session join: call the existing agent-detail "start voice call" action → core issues
  `wsUrl`/`token` → open the socket, join `"voice:" <> sessionId`, wait for `session.ready`
  before enabling the mic.

## 10. Safety limits

| limit | value | enforcement |
|---|---|---|
| call duration | `VIBE_VOICE_MAX_SECONDS` (default 1800) | `Session` timer; on expiry, `Provider.stop/1` then `"session.ended" {reason:"max_duration"}` |
| idle | 90 s with no client audio/text/image and no provider transcript/audio | `Session` timer, reset on any inbound/outbound activity; `"session.ended" {reason:"idle"}` |
| audio in | ≤ 4 MB/min | rolling 60 s byte counter in `Session`; over-limit chunks are dropped with an `error{code:"audio_rate_limit"}` push, the call is not ended |
| image frame | ≤ 300 KB, ≤ 1/s | oversized → dropped + `error{code:"image_too_large"}`; too-frequent → silently dropped |
| join window | 15 min from `Sessions.create/1` | `Phoenix.Token` `max_age: 900` at socket connect |
| session record TTL | 2 h | ETS sweep in `VibeAgents.Voice.Sessions` |

`VIBE_AGENTS_KILL_SWITCH=1` (§3.9 of the platform spec) is not separately re-checked inside
the voice path in v1 — a kill-switch flip stops *new* `Sessions.create/1` calls only if the
core-side HTTP handler checks it before calling the runtime (corebridge's responsibility);
an in-progress call is not force-ended by this slice. Flagged as a phase-2 gap below.

## 11. Phase 2 (not built here)

- **WebRTC/SFU transport** once call volume or last-mile latency makes a plain WebSocket +
  base64 PCM16 path too slow; the frame *semantics* in §6 should survive the transport
  change, only the envelope would.
- **Provider reconnect/backoff** — a dropped upstream OpenAI connection currently ends the
  call outright; a short-lived reconnect that resumes the same `Session` (rather than
  restarting the whole voice session) would smooth over transient network blips.
- **Kill-switch enforcement mid-call** — `Session` should subscribe to the runtime-wide kill
  switch and end active calls, not just refuse new ones.
- **Pending-decision timeout** — `approval.requested.expiresAt` is informational only; a
  real timer should auto-deny (or re-prompt) an unanswered decision instead of leaving the
  tool call parked until the whole session ends.
- **Barge-in via item truncation** — `interrupt/1` currently just cancels the response;
  truncating the just-spoken conversation item (`conversation.item.truncate`) would keep the
  model's own transcript consistent with what the caller actually heard before interrupting.
- Multi-language / voice switching mid-call, and image-assisted tool calls (letting a tool
  see the last `image.frame` rather than only the model).
