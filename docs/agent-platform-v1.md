# Agent Platform v1 — isolated runtime, providers, teams, voice

Authoritative spec. Frozen names below are what every service, client and worker
codes against. Companion docs: [`security-readiness-gap-2026-08.md`](security-readiness-gap-2026-08.md)
(what the ABR checklist says is missing), [`vps-deployment.md`](vps-deployment.md)
(compose stack + runbooks), [`agent-voice-v1.md`](agent-voice-v1.md) (voice sessions).

## 0. Decisions

| Decision | Choice | Why |
|---|---|---|
| Language | **Elixir/OTP** for the chat core *and* the new agent runtime; **Rust** for the sandbox gateway | 35K lines of working Elixir agent code + a second Elixir agent runtime already extracted in `resolo.ai/agents`; BEAM is the right shape for thousands of long-lived, supervised, streaming runs. A Go/Rust rewrite of the brain would be a year of regression for no scaling gain. Rust goes where a single static binary with a tiny attack surface matters: the process that holds the container socket. |
| Isolation unit | **Separate OTP release, separate container, separate Postgres database + role, separate secrets** | The agent runtime must not be able to read the chat core's env (DB creds, MLS material, push keys) and the core must not hold model-provider keys. A sandbox holds **no** secrets at all. |
| Orchestration | Podman (rootless) or Docker **compose** on one VPS; no Kubernetes | One box scales far with BEAM; compose is reproducible and auditable. Cluster later with libcluster + a second VPS, not with k8s. |
| Migration | **Strangler.** The embedded runtime (`Vibe.AI.*`) stays the default. Per-agent `execution_mode = "embedded" \| "isolated"` (or global `VIBE_AGENT_EXECUTION_MODE`) routes to the new service. | Nothing breaks on day one; every agent can be flipped and flipped back. |
| Model of a "bot" | Grok-Bot-shaped: a named, persistent agent with a role, its own memory, its own **computer** (sandbox), always-on runs that come back to the human only for approvals, and the ability to work in a group with other agents and hand work over. | It matches what the product already has (standalone agents, groups, channels, mentions) and what users expect in 2026. |

## 1. Topology

```
                     ┌──────────────── VPS (podman compose) ────────────────────────────┐
  phones / web ───▶  │ caddy (TLS, headers, edge rate-limit)                              │
                     │   ├─ api.<host>      ─▶ vibe-core        (Phoenix)                  │
                     │   └─ agents.<host>   ─▶ vibe-agent-runtime (Phoenix)  ── /v1/*      │
  providers ──────▶  │                                                                     │
                     │ vibe-core ◀──internal HMAC──▶ vibe-agent-runtime                     │
                     │                               │ token                               │
                     │                               ▼                                     │
                     │                        sandbox-gateway (Rust) ─ podman socket       │
                     │                               │ creates                             │
                     │                               ▼                                     │
                     │   sandbox-net (internal:true) [ vibe-sandbox × N ] ─▶ egress-proxy  │
                     │                                                                     │
                     │ postgres ─ pgbouncer     valkey     doc-renderer     backup (→ R2)  │
                     └─────────────────────────────────────────────────────────────────────┘
```

Trust boundaries (ABR §1.4) and what enforces them:

| Boundary | Enforcement |
|---|---|
| client ↔ core | bearer auth (`ApiAuth`), per-socket throttle, body limits, security headers |
| provider ↔ runtime | agent secret / API key verified through the core, public rate bucket, idempotency |
| core ↔ runtime | `vibe-internal-auth/v1` HMAC, internal network only, no public route |
| runtime ↔ sandbox | gateway token; sandbox has no keys, default-deny egress via allowlist proxy |
| model ↔ tools | **capability broker** (`VibeAgents.Broker`) — deterministic policy, budgets, approvals |
| runtime ↔ core DB | none. The runtime never sees the core database; it only sees the internal API |

## 2. Services

| Service | Dir | Owns |
|---|---|---|
| `vibe-core` | `server/` | identity, chats, MLS, media, push, **chat delivery for agents**, approval tasks, decision actions |
| `vibe-agent-runtime` | `agent-runtime/` (app `:vibe_agents`) | runs, LLM loop, tools, broker, budgets, memories, computers, provider ingress `/v1`, voice sessions |
| `sandbox-gateway` | `sandbox-gateway/` (Rust) | container lifecycle, exec, files, browser actions, screenshots, limits, reaper |
| `vibe-sandbox` image | `deploy/sandbox/` | the bot's computer: bash, python, node, chromium + `browser.js` |
| `egress-proxy` | `deploy/egress-proxy/` | allowlisted forward proxy; the only way out of `sandbox-net` |
| `contracts` | `contracts/` (app `:vibe_contracts`) | shared pure code: service auth, run-event shapes, redaction, signatures |
| infra | `deploy/` | compose, Caddy, postgres/pgbouncer/valkey config, backups, bootstrap, runbooks |

## 3. Contracts (frozen)

### 3.1 Internal service auth — `vibe-internal-auth/v1`

Every core ↔ runtime request carries:

```
x-vibe-service:   core | agent-runtime
x-vibe-timestamp: <unix seconds>
x-vibe-nonce:     <uuid v4>
x-vibe-signature: v1=<hex hmac-sha256>
```

Signing string (exact bytes, `\n` separated):

```
"v1" \n service \n METHOD \n path_with_query \n timestamp \n nonce \n sha256_hex(body)
```

Key: `VIBE_INTERNAL_HMAC_KEY` (raw string, ≥ 32 bytes, same value on both services).
Verification: constant-time compare, `|now - timestamp| ≤ 300s`, nonce unseen in the
last 600s (ETS on each service; Valkey when clustered). Implemented once in
`VibeContracts.ServiceAuth` (`sign/5`, `verify/6`, `headers/4`); used by
`VibeWeb.Plugs.InternalServiceAuth` (core) and `VibeAgentsWeb.Plugs.InternalServiceAuth`
(runtime). Internal routes are never exposed through Caddy.

### 3.2 Core → runtime (`/internal/v1/*` on the runtime)

| Route | Body → Response |
|---|---|
| `POST /internal/v1/runs` | `RunRequest` → `202 {runId, status:"queued"}` (idempotent on `idempotencyKey`) |
| `POST /internal/v1/runs/:runId/cancel` | `{reason, requestedByUserId}` → `{runId, status}` |
| `POST /internal/v1/runs/:runId/decisions` | `Decision` → `{ok:true}` (`404` unknown, `409` already decided) |
| `GET  /internal/v1/runs/:runId` | → `{run, events: [RunEvent] (tail ≤ 200)}` |
| `POST /internal/v1/agents/:agentId/computer` | `{action:"ensure"\|"destroy"}` → `{computerId, status}` |
| `GET  /internal/v1/agents/:agentId/computer/exec-log?since=&limit=` | → gateway `exec/log` verbatim |
| `GET  /internal/v1/agents/:agentId/computer/tree?path=&depth=` | → gateway `tree` verbatim |
| `GET  /internal/v1/agents/:agentId/computer/file?path=` | → gateway `files` verbatim |
| `GET  /internal/v1/agents/:agentId/computer/preview` | → `{imageBase64, mime:"image/jpeg", width, height, capturedAt}` |
| `POST /internal/v1/voice/sessions` | `{agentId, userId, chatId, agentProfile}` → `{sessionId, wsUrl, token, expiresAt}` |
| `POST /internal/v1/provider-invoke` | provider payload (see 3.5) already authenticated by core → same as `POST /runs` with `source:"provider"` |

`RunRequest`:

```jsonc
{
  "runId": "uuid (optional; server mints)",
  "idempotencyKey": "string (optional)",
  "source": "chat" | "provider" | "schedule" | "voice" | "handoff",
  "agentId": "uuid", "agentUserId": "uuid", "ownerUserId": "uuid",
  "requesterUserId": "uuid|null", "chatId": "string", "chatKind": "dm"|"group"|"channel",
  "replyToId": "string|null", "parentRunId": "uuid|null",
  "input": { "text": "…", "attachments": [ { "kind": "image"|"document"|"audio", "url": "https://…", "mime": "…", "name": "…" } ] },
  "agentProfile": {
    "displayName": "…", "username": "…", "systemPrompt": "…", "persona": "…",
    "modelProvider": "anthropic"|"openai", "modelId": "…", "thinkingLevel": "low|medium|high|xhigh|max",
    "enabledTools": ["search_google", "read_url", "computer_run", …],
    "outputModes": ["text","media","voice"],
    "autonomyMode": "draft_first"|"manual"|"safe_auto"|"approval_required"|"full_auto",
    "approvalRules": {}, "budgets": { "dailyCents": 500, "monthlyCents": 5000 },
    "adminMode": false
  },
  "context": { "history": [ { "role": "user"|"assistant", "authorName": "…", "text": "…", "ts": 0 } ], "participants": [ { "userId": "…", "name": "…", "isAgent": false } ] },
  "capabilities": { "computer": true, "browser": true, "network": "none"|"allowlist"|"open" }
}
```

`Decision`: `{ "decisionId": "uuid", "kind": "approval"|"ask"|"permission", "outcome": "approve"|"reject"|"answer"|"grant"|"deny", "answer": {…}|null, "actorUserId": "uuid", "actionId": "string|null" }`.

### 3.3 Runtime → core (`/internal/v1/*` on the core)

| Route | Body → Response |
|---|---|
| `POST /internal/v1/agent-events` | `{events:[RunEvent]}` (batch, ordered by `seq`, idempotent on `(runId, seq)`) → `{accepted: n}` |
| `POST /internal/v1/deliveries` | `{runId, agentId, chatId, replyToId, outputs:[Output]}` → `{deliveries:[{messageId,type,mediaUrl}]}` |
| `POST /internal/v1/approvals` | `ApprovalRequest` → `{taskId, messageId}` |
| `POST /internal/v1/provider-auth` | `{identifier, secret}` → `{agentProfile, agentId, agentUserId, ownerUserId, defaultChatId}` or `401` |
| `POST /internal/v1/handoffs` | `{runId, agentId, chatId, toAgentUsername, note}` → `{messageId, dispatched:true\|false}` |

`Output` is the existing finalized-output shape (`docs/agent-turn-contract.md`):
`{ "type": "text"|"image"|"file"|"music"|"question", "text": "…", "mediaUrl": null, "metadata": {…} }`.
The core persists outputs as the agent shadow user through the same path standalone
agents use today, so every existing client renders them unchanged.

`ApprovalRequest`:

```jsonc
{ "runId": "uuid", "agentId": "uuid", "chatId": "…", "decisionId": "uuid",
  "kind": "approval" | "permission",
  "title": "Send the quote to acme@example.com?", "detail": "Body preview …",
  "risk": "external_effect" | "credential" | "write_local" | "spend",
  "actions": [ { "id": "approve", "label": "Approve", "style": "primary", "confirm": null },
               { "id": "reject",  "label": "Reject",  "style": "destructive", "confirm": null } ],
  "actionMode": "single", "expiresAt": "ISO-8601" }
```

The core creates an `AgentApprovalTask` (`source: "declared"`, `requested_action.actionType:
"runtime_decision"`, `requested_action.runId`, `requested_action.decisionId`) with
`AgentDecisionAction` rows and posts the **existing decision service message** (iOS
already renders it with buttons, `ChatListView.handleServiceDecisionAction` →
`POST /api/decisions/actions`). When an action is claimed, `Vibe.AI.AgentDecisions`
forwards `{decisionId, outcome: actionId, actorUserId}` to the runtime via
`Vibe.AgentGateway.decision/3`. No new iOS work for approvals.

### 3.4 `RunEvent` — `vibe.agentic.v1` run stream

```jsonc
{ "contract": "vibe.agentic.v1", "runId": "uuid", "agentId": "uuid", "agentUserId": "uuid",
  "chatId": "…", "seq": 17, "ts": 1787990000000, "kind": "run.tool.started", "payload": {…} }
```

| kind | payload |
|---|---|
| `run.queued` / `run.started` | `{source, model}` |
| `run.text.delta` | `{text}` (append) |
| `run.thinking` | `{tokens, label}` |
| `run.progress` | `{label, status:"running"\|"done"\|"error"}` |
| `run.tool.started` | `{toolCallId, tool, label, input}` (input redacted by `VibeContracts.Redact`) |
| `run.tool.completed` | `{toolCallId, tool, label, status:"done"\|"error", summary}` |
| `run.approval.requested` | `ApprovalRequest` minus runId/agentId/chatId |
| `run.approval.resolved` | `{decisionId, outcome, actorUserId}` |
| `run.ask` | `{decisionId, questions:[AskQuestion]}` (same question shape as `ask_user`) |
| `run.permission.requested` | `{decisionId, capability, scope, reason}` |
| `run.preview` | `{imageBase64, mime:"image/jpeg", width, height, label}` (≤ 200 KB) |
| `run.handoff` | `{toAgentUsername, note, childRunId}` |
| `run.cancelled` | `{reason}` |
| `run.completed` | `{summary, usage:{inputTokens,outputTokens}, costCents}` |
| `run.failed` | `{error, code}` |

**Core relay mapping** (`Vibe.AgentRelay`) onto the frames iOS already speaks:

| RunEvent | Broadcast on `chat:<chatId>` |
|---|---|
| started / text.delta / thinking / progress / tool.* | `"agent-stream"` — same payload as `LocalAgentWorker.bridge_stream_update`: `chatId, streamId (= runId), userId, agentUserId, agentName, agentUsername, isAgent, isAgentMessage, text (accumulated), progressNodes, toolEvents, status:"running"`, plus `runId`, `runtime:"isolated"` |
| approval.requested | approval task + decision message (3.3) **and** `"agent-approval"` `{chatId, runId, decisionId, taskId, messageId, kind, title, expiresAt}` |
| ask | `"agent-bridge-ask"` with `requestId = decisionId`, `kind:"ask"`, `provider:"vibe"`, `runtime:"isolated"`, `runId`, and **plaintext** `ask: {questions}` (no `askEnc`) |
| permission.requested | same path as approval with `kind:"permission"` and actions `allow_once` / `allow_run` / `deny` |
| preview | `"agent-preview"` `{chatId, runId, agentUserId, imageBase64, mime, width, height, label, ts}` |
| completed / failed / cancelled | `"agent-stream"` with `status:"done"` (failed/cancelled add `error`/`reason`) **and** `"agent-run-state"` `{chatId, runId, status, reason}` |

Client → core (`ChatChannel`): `"agent-run-control"` `{runId, action:"cancel"}` (participant of
the run's chat and either requester or agent owner). Ask answers reuse
`"agent-bridge-ask-response"` with `{requestId, decision, answer, runId}` in plaintext when the
ask carried `runtime:"isolated"`.

### 3.5 Provider ingress v1 (public, on the runtime)

`POST /v1/agents/:identifier/invoke`, `POST /v1/agents/:identifier/events`,
`GET /v1/agents/:identifier/card`, `GET /v1/tasks/:taskId`. Auth: `x-vibe-agent-secret`
**or** `Authorization: Bearer <secret>`; the runtime never stores agent secrets — it calls
`POST /internal/v1/provider-auth` on the core. Idempotency: `Idempotency-Key` header or
`eventId` (24 h). Payload bodies are the existing `vibe.content.v1` (`docs/provider-content-contract.md`)
and `vibe.agentic.v1`. Callbacks to providers are signed `x-vibe-signature: t=<ts>,v1=<hmac>`
over `"<ts>.<body>"` with the agent's callback signing secret (`VibeContracts.WebhookSignature`).
The core's legacy `/api/agents/:identifier/*` routes stay until providers move; Caddy routes
`/v1/*` on `agents.<host>` to the runtime. Scoped API keys (`vak_…`, per-key scopes and
rotation) are phase 2 and documented in the gap analysis.

### 3.6 Sandbox gateway API (`sandbox-gateway`, header `x-sandbox-token`)

| Route | Body → Response |
|---|---|
| `POST /v1/sandboxes` | `{ownerKey:"agent:<id>", image?, cpus?, memoryMb?, pidsLimit?, network:"none"\|"proxy", ttlSeconds?}` → `{id, status, createdAt}` (returns the existing sandbox for `ownerKey`) |
| `GET /v1/sandboxes/:id` | → `{id, status, ownerKey, createdAt, lastUsedAt}` |
| `GET /v1/sandboxes/:id/exec/log?since=&limit=` | → `{entries:[{seq,cmd,cwd,exitCode,stdout,stderr,truncated,durationMs,startedAt}]}` — in-memory ring, newest last |
| `POST /v1/sandboxes/:id/exec` | `{cmd:[…], cwd?, env?:{}, timeoutMs?, maxOutputBytes?}` → `{exitCode, stdout, stderr, truncated, durationMs}` |
| `PUT /v1/sandboxes/:id/files` | `{path, contentBase64, mode?}` → `{path, bytes}` |
| `GET /v1/sandboxes/:id/files?path=` | → `{path, contentBase64, bytes}` (cap 4 MB) |
| `GET /v1/sandboxes/:id/tree?path=&depth=` | → `{entries:[{path,type,bytes}]}` |
| `POST /v1/sandboxes/:id/browser/navigate` | `{url}` → `{url, title}` |
| `POST /v1/sandboxes/:id/browser/action` | `{kind:"click"\|"type"\|"scroll"\|"key"\|"select", selector?, x?, y?, text?}` → `{ok, url, title}` |
| `GET /v1/sandboxes/:id/browser/screenshot` | → `{imageBase64, mime:"image/jpeg", width, height}` |
| `POST /v1/sandboxes/:id/stop` · `DELETE /v1/sandboxes/:id` | → `{id, status}` |
| `GET /healthz` | → `{ok:true, containers:n}` |

Container policy (non-negotiable): image from the allowlist only; `no-new-privileges`;
`cap-drop ALL`; read-only rootfs + tmpfs `/tmp` + named volume `/home/agent` per
`ownerKey`; `pids-limit`, memory and CPU limits; user `agent` (uid 1000); network
`sandbox-net` (`internal: true`) with `HTTP_PROXY`/`HTTPS_PROXY` = egress proxy;
`network:"none"` = no network at all; every container labelled `vibe.sandbox=1`;
idle containers stopped after `SANDBOX_IDLE_TTL_SECONDS`, orphans reaped on boot.
Browser actions run through `/opt/vibe/browser.js` inside the container (Playwright,
persistent profile, CDP on 127.0.0.1) so the gateway never speaks CDP itself.

Making that computer visible, drivable by the owner, and logged into real accounts is
specified separately in [`agent-computer-v1.md`](agent-computer-v1.md) — it adds routes
under `/v1/sandboxes/:id/computer/*` and changes nothing above.

### 3.7 Voice — `vibe.voice.v1`

Core: `POST /api/agents/:id/voice/sessions` (authenticated; participant or owner) →
runtime `POST /internal/v1/voice/sessions` → `{sessionId, wsUrl, token, expiresAt}`.
Runtime: socket `/v1/voice/socket`, channel `voice:<sessionId>` (Phoenix.Token, salt
`"voice-session"`, 15-min join window). Frames in [`agent-voice-v1.md`](agent-voice-v1.md).
Provider adapter behaviour `VibeAgents.Voice.Provider`; first adapter
`VibeAgents.Voice.OpenAIRealtime`. Tools inside a voice session go through the same
broker and approval path as text runs. iOS wires this into the existing call UI in a
later slice (documented, not built in v1).

### 3.8 Teams of bots inside Vibe

The messenger is the bus. Agents already coexist in groups and channels and are
dispatched by `@mention`. v1 adds:

- `handoff_to_agent` tool → `run.handoff` → core `POST /internal/v1/handoffs` posts a
  message from the source agent mentioning the target; the existing mention dispatch
  starts the target's run with `parentRunId`. Depth ≤ 4 per root run, one handoff per
  target per run, kill switch honoured. The source run ends with `run.completed
  {summary:"handed off"}`.
- Shared context = the chat itself (bounded history in `RunRequest.context`).
- Routines: the existing `ChannelAgentScheduler` and runbooks trigger runs through
  `Vibe.AgentGateway` when the agent is `isolated`.

### 3.9 Capability broker and hard limits (runtime)

`VibeAgents.Broker.authorize(run, tool_call)` is deterministic and runs **before** every
tool call:

| Risk class | Examples | `full_auto` | `safe_auto` | `approval_required` | `manual` / `draft_first` |
|---|---|---|---|---|---|
| `read` | search, read_url, read file, screenshot | run | run | run | run |
| `write_local` | write file, run command, navigate | run | run | approval | plan only |
| `external_effect` | send message outside the chat, post/publish, purchase, delete data, submit a form with money | approval unless `approvalRules.allow` lists it | approval | approval | plan only |
| `credential` | passwords, 2FA codes, CAPTCHAs | ask user | ask user | ask user | ask user |

Hard limits, all configurable by env and never raisable by a prompt:
`VIBE_AGENTS_MAX_STEPS` (24), `VIBE_AGENTS_MAX_RUN_SECONDS` (1200), max tool failures
(6), per-run token ceiling, per-agent daily/monthly cents (from `agentProfile.budgets`),
handoff depth 4, `VIBE_AGENTS_KILL_SWITCH=1` refuses new runs and cancels running ones.

### 3.10 Runtime storage (frozen table names)

`agent_runs`, `agent_run_events` (append-only, `(run_id, seq)` unique), `agent_run_decisions`,
`agent_computers`, `agent_memories`, `agent_usage_ledger`, `outbox_events` (runtime → core
delivery with retry). A waiting run persists its message list in `agent_runs.state` so it
resumes after a restart.

## 4. Environment

| Service | Variables |
|---|---|
| core | `VIBE_AGENT_RUNTIME_URL`, `VIBE_INTERNAL_HMAC_KEY`, `VIBE_AGENT_EXECUTION_MODE` (`embedded`, default), `VIBE_AI_KILL_SWITCH`, `VALKEY_URL` (optional), `CLUSTER_STRATEGY` (optional) |
| runtime | `DATABASE_URL`, `SECRET_KEY_BASE`, `PORT`, `VIBE_CORE_INTERNAL_URL`, `VIBE_INTERNAL_HMAC_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `TAVILY_API_KEY`, `SANDBOX_GATEWAY_URL`, `SANDBOX_GATEWAY_TOKEN`, `VIBE_AGENTS_PUBLIC_URL`, `VIBE_AGENTS_KILL_SWITCH`, `VIBE_AGENTS_MAX_STEPS`, `VIBE_AGENTS_MAX_RUN_SECONDS` |
| gateway | `SANDBOX_GATEWAY_TOKEN`, `CONTAINER_SOCKET`, `SANDBOX_IMAGE`, `SANDBOX_NETWORK`, `SANDBOX_EGRESS_PROXY`, `SANDBOX_MAX_CONTAINERS`, `SANDBOX_DEFAULT_MEMORY_MB`, `SANDBOX_DEFAULT_CPUS`, `SANDBOX_PIDS_LIMIT`, `SANDBOX_IDLE_TTL_SECONDS`, `SANDBOX_VOLUME_PREFIX`, `PORT` |

## 4b. Delivered state (2026-08-29) and known deviations

Built and verified in this delivery: `contracts/` (79 tests), `agent-runtime/` (69 tests, incl.
voice), `sandbox-gateway/` (70 Rust tests), core bridge + security + data batches (core suite
green, 22 new tests), iOS frames (generic build green), `deploy/` stack + runbooks.

| Item | State |
|---|---|
| `execution_mode` routing, kill switch, embedded fallback when the runtime is unreachable | done |
| Approvals / permissions via decision messages, ask sheets (plaintext), cancel, run-state, preview | done end-to-end |
| Provider ingress `/v1/agents/:identifier/invoke`, `card`, `tasks/:id` | done; `/v1/.../events` is a stub (events stay on the core's `/api/agents/:identifier/events` until phase 2) |
| Card on the runtime | proxied from the core's `GET /internal/v1/agents/:identifier/card` |
| Voice sessions | runtime side done (OpenAI Realtime adapter, broker-gated tools); iOS call UI not built |
| Team handoffs | `handoff_to_agent` → core `POST /internal/v1/handoffs` → mention dispatch |
| Sandbox computer | gateway + image + egress proxy built; untested against a live Podman (no daemon on the build machine) |
| Scoped provider API keys (`vak_…`) | not built (phase 2) |
| Anthropic prompt caching | added 2026-08-29 on both loops; see below |

### Prompt caching (2026-08-29)

Both Claude loops — `VibeAgents.LLM.Loop` (isolated) and `Vibe.AI.AgentRuntime`
(embedded) — sent `system`, `tools` and the whole transcript uncached on every
step. With `max_steps` at 24 that is the same prefix re-billed up to 24 times
per run, and it was the single largest avoidable cost in the agent path.

Three `cache_control: ephemeral` breakpoints now ride the payload: the last
tool, the system prompt, and the newest message (so each step reads the
previous step's transcript back). Anthropic allows four. Cache reads bill at
0.1× input, writes at 1.25×, and a prefix under ~1024 tokens is simply not
cached — so short one-shot runs are unaffected either way.

Off switch: `config :vibe_agents, :prompt_cache, false` (runtime) or
`config :vibe, :prompt_cache, false` (core) restores the old payload exactly.

**Not yet verified against the live API** — the production Anthropic key is out
of credit, so the two-call write-then-read check could not run. Payload shape is
covered by `agent-runtime/test/vibe_agents/llm/prompt_cache_test.exs`; confirm
`cache_read_input_tokens > 0` on a real run once the key is funded.

## 5. Migration phases

0. **This delivery** — runtime, gateway, contracts, infra, core bridge; flag off by default.
1. Flip one agent to `execution_mode = "isolated"`; verify approvals, cancel, ask, preview.
2. Route provider traffic to `agents.<host>/v1`; keep core routes as aliases.
3. Remove model keys from the core once every agent is isolated; delete `Vibe.AI.AgentRuntime`
   and the tool modules the runtime now owns.
4. Second VPS: libcluster + Valkey-backed rate limits/caches (already behind config).
