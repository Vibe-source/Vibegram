# Board — Agent Computer v1, phase 1 "Watch" + the input path

Spec: `docs/agent-computer-v1.md`. Platform spec: `docs/agent-platform-v1.md` §3.6.
Everything below is **frozen**. Do not rename a route, field or event. Do not invent one.

## Deliberate deviation from the spec, phase 1

The spec describes a CDP `Page.startScreencast` push feed and binary channel frames.
**Phase 1 ships pull + base64 instead**, behind the same contract:

- The gateway captures a screenshot on demand and caches it per sandbox with a sequence
  number, so N viewers share one capture. `Page.startScreencast` is a later optimisation
  behind the *same* `/computer/frame` route.
- Channel frames carry `imageBase64`, exactly like the existing `agent-preview`, because
  iOS already decodes that shape. Binary is a later upgrade behind the same event name.

Everything else in the spec holds — viewer-gated capture, control state machine in the
gateway, owner-only access.

## Frozen contract

### Gateway (`sandbox-gateway`, header `x-sandbox-token`)

```
POST   /v1/sandboxes/:id/computer/session
       {viewerId, fps?, width?, quality?}
    -> {sessionId, fps, width, quality, control, holder, expiresAt}

DELETE /v1/sandboxes/:id/computer/session/:sessionId
    -> {sessionId, status:"closed"}

GET    /v1/sandboxes/:id/computer/frame?since=<seq>
    -> 200 {seq, imageBase64, mime, width, height, url, title, loading, control, capturedAt}
    -> 204 (no body) when nothing newer than `since`

GET    /v1/sandboxes/:id/computer/state
    -> {url, title, loading, control, holder, expiresAt, tabCount}

POST   /v1/sandboxes/:id/computer/control
       {action:"grant"|"release", sessionId, ttlSeconds?}
    -> {control, holder, expiresAt}

POST   /v1/sandboxes/:id/computer/input
       {sessionId, kind:"click"|"type"|"key"|"scroll"|"back"|"navigate",
        x?, y?, text?, key?, deltaY?, url?}
    -> {ok, url, title}
    -> 409 {"error":"control_not_held"} unless control=="user" AND that sessionId holds it
```

`control` is `"agent"` or `"user"`. `holder` is the sessionId holding control, or null.

### Runtime (`/internal/v1`, InternalServiceAuth)

Straight passthrough to the gateway for the agent's own sandbox. 204 passes through as 204.

```
POST   /internal/v1/agents/:agent_id/computer/session
DELETE /internal/v1/agents/:agent_id/computer/session/:session_id
GET    /internal/v1/agents/:agent_id/computer/frame?since=
GET    /internal/v1/agents/:agent_id/computer/state
POST   /internal/v1/agents/:agent_id/computer/control
POST   /internal/v1/agents/:agent_id/computer/input
```

### Core HTTP (authenticated, **owner only** — not every chat participant)

```
POST   /api/agents/:id/computer/session
    -> {sessionId, topic:"computer:<agentId>", fps, width, control, holder, expiresAt}
DELETE /api/agents/:id/computer/session/:session_id
```

### Core channel `computer:<agentId>` (`VibeWeb.ComputerChannel` on `UserSocket`)

Join is owner-only and carries `%{"sessionId" => …}`. The channel owns one poller.

| Direction | Event | Payload |
|---|---|---|
| → client | `frame` | `{seq, imageBase64, mime, width, height, url, title, loading, control, ts}` |
| → client | `state` | `{url, title, loading, control, holder, expiresAt}` |
| → client | `session_ended` | `{reason:"idle"\|"cap"\|"stopped"\|"error"}` |
| client → | `input` | `{kind, x?, y?, text?, key?, deltaY?, url?}` |
| client → | `control` | `{action:"take"\|"release", ttlSeconds?}` |

Inbound `input` is rate-limited to 20/s per session; excess is dropped, never queued.

Clarified during the build, after W3 found the board underspecified them:

- Join params are `{sessionId, fps?}` — the channel polls at `1000/fps` and had no other
  way to learn the rate. Server clamps 1–10, defaults 3, and echoes `fps` in the join reply,
  which is authoritative.
- `take` → `grant` is mapped by the channel. The client never sends `grant`.
- `input` is fire-and-forget: every `frame` carries the current `control`, so a client that
  lost control self-corrects within one tick instead of round-tripping.
- `state` merges `url/title/loading` from the last frame, since the gateway's control reply
  carries only `{control, holder, expiresAt}`.
- `session_ended` reasons are exactly `idle | cap | stopped | error`. The spec's
  `agent_resumed` is not in phase 1.
- Spec §3.2 describes `GET` + a `Phoenix.Token` join gate; the board's `POST` + owner-only
  re-check on join is what shipped. The channel re-authorizes on join, so no join token.

### RunEvent additions (`vibe.agentic.v1`)

| kind | payload |
|---|---|
| `run.computer.state` | `{url, title, live}` |
| `run.computer.control` | `{holder, reason?, expiresAt?}` |

Core relay broadcasts both on `chat:<chatId>` as **`"agent-computer"`**:
`{chatId, runId, agentUserId, url, title, live, holder, ts}`.

## Owners — one file, one worker. Never edit a file you do not own.

| Worker | Owns |
|---|---|
| **W1 gateway** | `sandbox-gateway/**`, `deploy/sandbox/**`, `deploy/env/sandbox-gateway.env.example` |
| **W2 runtime** | `agent-runtime/lib/vibe_agents/sandbox*.ex`, `.../sandbox/**`, `.../tools/browser.ex`, `.../vibe_agents_web/**`, `agent-runtime/test/**`, `contracts/lib/vibe_contracts/run_event.ex` |
| **W3 core** | `server/lib/vibe/agent_gateway.ex`, `server/lib/vibe/agent_relay.ex`, `server/lib/vibe_web/controllers/agents_controller.ex`, `server/lib/vibe_web/router.ex`, `server/lib/vibe_web/channels/user_socket.ex`, NEW `server/lib/vibe_web/channels/computer_channel.ex`, `server/test/**` |
| **W4 iOS sheet** | NEW `ios/ChatModule/VibeAgentComputerViewController.swift`, NEW `ios/ChatModule/VibeAgentComputerSession.swift`, `ios/ChatModule/VibeAgentComputerPreviewViewController.swift`, `ios/ChatModule/VibeAgentConversationView.swift` |
| **W5 iOS cell** | `ios/ChatModule/ChatEngine.swift`, `ios/ChatModule/ChatListViewCells.swift`, `ios/ChatModule/ChatAgentStreamingText.swift`, `ios/ChatModule/ChatListView.swift`, `docs/row-height-formulas.md` |
| **W6 iOS model** | `ios/ChatModule/ChatAgentConfigViews.swift`, `ios/ChatModule/ChatAgentsMainView.swift` |

**Off limits to everyone**: `ios/ChatModule/ChatProfileMainView.swift`,
`ios/ChatModule/ChatMainProfileContentNodes.swift`, `ios/Sources/Core/VibeSecure*.swift` —
another session is live in those.

## Rules

- The worktree is already dirty with unrelated work. **Edit surgically; never rewrite a
  whole shared file.** Read before you edit.
- No commits. No pushes. No `git checkout`/`reset`. No launching the app.
- Comments: **2 lines maximum**, ever. No multi-paragraph doc blocks. See `CLAUDE.md`.
- Run your own suite before reporting. Report what actually ran, including failures.
- If a contract above is wrong, say so and stop — do not silently pick another shape.
