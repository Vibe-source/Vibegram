# Research: MCP tool-bridge for a messenger host

**Date:** 2026-07-18  
**Run:** `provider-native-0718` (grok-N4)  
**Question:** How should a messenger host (Vibe) let provider agents use tools that act on *host* context — chat threads, send message, media — via the Model Context Protocol (MCP), with consent, scopes, and safe composition with A2A?  
**Audience:** Vibe provider platform / agent runtime engineers.

Claims marked **`[unverified]`** are inferences, product UI details, or ecosystem practice not confirmed on a primary spec/docs page in this pass. Primary URLs are cited inline.

---

## 0. Problem framing for Vibe

Vibe already is a **secure messenger surface** for third-party AI providers:

| Surface | Role today | Location |
|---------|------------|----------|
| A2A-compatible agent card | Discovery: invoke URL, events URL, skills, capabilities | `docs/provider-platform.md`, `Vibe.AgentCard`, `GET /api/agents/:identifier/card` |
| Invoke | Provider → host: deliver a turn into a chat | `POST /api/agents/:identifier/invoke` · `AgentsController.invoke/2` |
| Events | Provider → host: progressive / async delivery | `POST /api/agents/:identifier/events` · `AgentsController.ingest_event/2` |
| Content contract | Structured assistant body (`vibe.content.v1`) | `docs/provider-content-contract.md` |
| Auth | Shared secret headers (not OAuth on public ingress) | `x-vibe-agent-secret` (invoke); agent or integration secret (events) |
| Consent | Per-chat attachment; fail closed if not attached | `{:error, :chat_not_attached}` → HTTP 403 |
| Autonomy | `autonomy_mode` + approval tasks | `docs/provider-platform.md` security table; `approve_task` / `reject_task` |
| Local bridge MCP | Mac coding agents use MCP tools (e.g. `ask_user`) | `docs/agent-payload-shapes.md` |

Roadmap already names **“MCP tool bridging”** as optional so provider skills map to tools the runtime understands (`docs/provider-platform.md` § Roadmap).

The missing half is **host → provider tool surface**: today providers *push* messages/events into Vibe; they cannot *pull* thread context or *act* through a standardized tool protocol with least-privilege consent. MCP is the industry standard for that tool/context contract; A2A remains the agent-to-agent / task surface Vibe already mirrors with the card + invoke/events.

**Design polarity (keep fixed):**

- **MCP** = tools, resources, prompts against *systems and data* (here: Vibe chat APIs).
- **A2A** = agents talking to agents (card, tasks, streaming artifacts).
- **Vibe content contract** = what humans *see* in the bubble (`vibe.content.v1`).
- Do not collapse these three into one mega-protocol.

---

## 1. MCP specification (2025–2026)

### 1.1 Roles and primitives

Primary overview: https://modelcontextprotocol.io/specification/2025-06-18  

MCP uses **JSON-RPC 2.0** between:

| Role | Meaning |
|------|---------|
| **Host** | LLM application that initiates connections (Claude, ChatGPT, IDE, or a provider runtime) |
| **Client** | Connector inside the host, one session per server |
| **Server** | Exposes tools / resources / prompts |

Server features:

| Primitive | Meaning | Spec |
|-----------|---------|------|
| **Tools** | Model-invoked functions; JSON Schema I/O; `tools/list`, `tools/call` | https://modelcontextprotocol.io/specification/2025-06-18/server/tools |
| **Resources** | Read-only context blobs (URI + mime); list/read/subscribe | https://modelcontextprotocol.io/specification/2025-06-18/server/resources |
| **Prompts** | Templated multi-message workflows for users/LLMs | https://modelcontextprotocol.io/specification/2025-06-18/server/prompts |

Client features (host offers to server):

| Primitive | Meaning | Spec |
|-----------|---------|------|
| **Elicitation** | Server asks host to collect structured user input mid-flow | https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation |
| **Sampling** | Server requests LLM completions from the host (deprecated direction in 2026 RC) | overview + RC blog |
| **Roots** | Server inquires filesystem/URI boundaries (deprecated in 2026 RC) | RC blog |

**Trust principles (normative in overview):**

1. User consent and control over data access and operations.  
2. Hosts obtain explicit consent before exposing user data to servers.  
3. Tools are arbitrary code paths — hosts should obtain consent before invoking tools; tool annotations are untrusted unless the server is trusted.  
4. Sampling (when used) requires explicit user approval of prompts/results.  

Source: https://modelcontextprotocol.io/specification/2025-06-18 (Security and Trust & Safety).

### 1.2 Tools wire shape

Discovery:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list",
  "params": { "cursor": "optional" }
}
```

Call:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": { "location": "New York" }
  }
}
```

Result dual-publish (text + structured) — same dual-lane idea as `vibe.content.v1`:

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"temperature\": 22.5, \"conditions\": \"Partly cloudy\"}"
      }
    ],
    "structuredContent": {
      "temperature": 22.5,
      "conditions": "Partly cloudy"
    },
    "isError": false
  }
}
```

Spec guidance: if you return `structuredContent`, also return serialized JSON in a text content block for older clients.  
Source: https://modelcontextprotocol.io/specification/2025-06-18/server/tools  

Tool annotations (read-only, destructive, open-world, etc.) **MUST** be treated as untrusted by clients unless the server is trusted.

Human-in-the-loop: hosts **SHOULD** show which tools are exposed, indicate invocations, and confirm sensitive operations.

### 1.3 Resources and prompts (brief)

- **Resources** = passive context (`resources/list`, `resources/read`, optional subscribe). Good fit for “thread snapshot”, “message blob”, “media metadata” without implying write.  
- **Prompts** = named templates with arguments → message arrays. Useful for “summarize this chat with consent” style entry points, not for side effects.  
- Novelty and UI can also ride **MCP Apps** (server-declared UI resources in sandboxed iframes) — complementary to Vibe’s `vibe.content.v1` card/actions parts, not a replacement for messenger-native render.  
  MCP Apps overview: https://modelcontextprotocol.io/docs/extensions/apps  

### 1.4 Elicitation

https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation  

Servers may send `elicitation/create` with a `message` + restricted JSON Schema (flat object of primitives). Client presents UI; user **accept** / **decline** / **cancel**.

Security:

- Servers **MUST NOT** use elicitation to request sensitive information (passwords, secrets).  
- Clients **SHOULD** show which server is asking, allow edit before send, support decline/cancel.

**Vibe mapping:** elicitation maps cleanly onto existing **approval tasks** / mid-run questions (`ask_user` on the local bridge) — not onto silent secret header auth.

### 1.5 Authorization (HTTP transports)

Stable reference used by products in 2025–2026:  
https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization  

Highlights:

| Rule | Detail |
|------|--------|
| Optional overall | Auth is OPTIONAL for MCP; when HTTP is used, SHOULD follow this OAuth profile |
| RS + AS split | MCP server = OAuth 2.1 **resource server**; separate or co-located **authorization server** |
| Discovery | Protected Resource Metadata (**RFC 9728**); AS metadata via RFC 8414 and/or OIDC discovery |
| Client registration | Prefer **Client ID Metadata Documents (CIMD)**; DCR (RFC 7591) allowed for compatibility; pre-registration OK |
| Tokens | `Authorization: Bearer <access-token>` on every HTTP request; **no** tokens in query strings |
| Resource indicators | Clients **MUST** send `resource` (RFC 8707) binding tokens to the MCP server audience |
| Scopes | `WWW-Authenticate` may advertise required `scope`; insufficient_scope → 403 + step-up |
| PKCE | Clients **MUST** implement PKCE (S256 preferred) |
| Forbidden | Token passthrough to upstream APIs; accepting tokens not issued for this RS |

OpenAI’s ChatGPT remote-MCP guidance explicitly recommends OAuth + CIMD and points at the same auth spec:  
https://developers.openai.com/api/docs/mcp  

### 1.6 Evolution: 2026-07-28 RC

https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/  

Direction (RC → final target date **2026-07-28** per blog):

| Change | Implication for a new Vibe MCP server |
|--------|--------------------------------------|
| **Stateless core** | No `initialize` session pin; version/clientInfo per request; `server/discover` for capabilities |
| **Headers** | `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` for gateway routing |
| **InputRequired** | Mid-call elicitation via `inputRequired` + `requestState` retry (no sticky SSE session required) |
| **Extensions first-class** | reverse-DNS IDs; MCP Apps + Tasks as extensions |
| **Auth hardening** | `iss` validation (RFC 9207), clearer step-up / CIMD behavior |
| **Deprecations** | Roots, sampling, logging → prefer tools/resources + OpenTelemetry |
| **Lifecycle** | ≥12 months between deprecation and removal |

**Recommendation for Vibe:** design the *semantic* tools/resources/scopes against stable concepts (tools/list, tools/call, resources/read, dual content). Prefer **Streamable HTTP** and plan for **stateless** request shapes so we are not stuck on session affinity. Support at least one shipping protocol date (e.g. `2025-11-25` or `2025-06-18`) while tracking RC finalization.

### 1.7 Security model summary (MCP)

| Layer | Control |
|-------|---------|
| Protocol trust | Consent UI, untrusted annotations, no sensitive elicitation |
| Transport auth | OAuth 2.1 + audience-bound tokens (HTTP) or env secrets (stdio) |
| Scope | Least privilege; step-up for more scopes |
| Tool execution | Host HITL for destructive/write; rate limits; input validation; audit logs |
| Confused deputy | No static-client proxy without per-client user consent; no token passthrough |

---

## 2. How Claude and ChatGPT consume MCP servers

### 2.1 Claude (Anthropic)

**Product connectors:** Claude’s connector directory and remote MCP connectors let users attach third-party tools/databases to Claude (web/desktop/mobile). Interactive connectors / **MCP Apps** render rich UI inside Claude while remaining MCP-based.  
- Connectors: https://claude.com/connectors  
- MCP Apps / interactive tools: https://claude.com/blog/interactive-tools-in-claude  
- Custom remote MCP (support article cited widely): https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp  

**API MCP connector** (Messages API, no separate MCP client process):  
https://platform.claude.com/docs/en/agents-and-tools/mcp-connector  

| Detail | Behavior |
|--------|----------|
| Beta header | `anthropic-beta: mcp-client-2025-11-20` (prior `mcp-client-2025-04-04` deprecated) |
| Servers | `mcp_servers[]` with `type: "url"`, HTTPS URL, `name`, optional `authorization_token` |
| Tool gate | `tools[]` entries of type `mcp_toolset` with allowlist/denylist/`enabled` per tool |
| Transports | Streamable HTTP and SSE; **no local STDIO** via this path |
| Scope of MCP | **Tools only** in the remote connector; prompts/resources need client-side helpers |
| Response blocks | `mcp_tool_use` / `mcp_tool_result` |

Auth model for the connector: API consumer performs OAuth (or otherwise obtains a bearer token) **outside** the Messages call, then passes `authorization_token`. That is “host holds user OAuth token; Anthropic calls the MCP server as the client.”

### 2.2 ChatGPT (OpenAI)

**Terminology:** As of **2025-12-17**, ChatGPT renamed **connectors → apps**. Data-only apps are still remote MCP servers; Apps SDK adds optional UI.  
https://developers.openai.com/api/docs/mcp  
Help: https://help.openai.com/en/articles/11487775-connectors-in-chatgpt  

| Pattern | Behavior |
|---------|----------|
| Remote MCP server | HTTPS SSE/Streamable; tools with dual `content` + `structuredContent` |
| Deep research / company knowledge | Convention tools `search` + `fetch` with citation-friendly `url` fields |
| Responses API | `tools: [{ "type": "mcp", "server_url": "...", "allowed_tools": [...], "require_approval": "never"|"..." }]` |
| User/workspace connect | Developer mode / plugins UI; OAuth to the app’s AS when configured |
| Write actions | Product requires **manual confirmation** before write actions in conversation `[product policy — verify current ChatGPT UI]` |
| Admin | Workspace controls for custom apps, security/compliance |

Risk table in OpenAI’s docs is highly relevant to a messenger: prompt injection into *readable* MCP data, over-broad tool parameters, exfiltration via write tools, and “read-only” mislabeling.  
Source: https://developers.openai.com/api/docs/mcp (Risks and safety).

### 2.3 Lessons for Vibe as *MCP server*

| Lesson | Apply to Vibe |
|--------|----------------|
| Remote HTTP only for provider agents | Expose Streamable HTTP MCP at a stable public path; no reliance on provider-local STDIO |
| Bearer/OAuth expected by big hosts | Plan OAuth (or chat-scoped capability tokens) even though current agent ingress is shared-secret |
| Tool allowlists | Advertise only tools granted for this agent×chat×consent grant |
| Dual text + structured | Same dual-publish discipline as `vibe.content.v1` and MCP tool results |
| Write confirmation | Map to Vibe `autonomy_mode` / approval tasks, not silent full_auto for side-effect tools |
| Don’t put secrets in tool schemas | Tool descriptions are model-visible and often logged |

---

## 3. A2A + MCP composition

Google’s Agent2Agent announcement positions **A2A as complementary to MCP**: MCP gives tools/context to an agent; A2A gives agents a way to collaborate on tasks.  
https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/  

Industry summary (aligned with primary A2A messaging):

| Protocol | Job |
|----------|-----|
| **MCP** | Agent ↔ tools/data (execution surface) |
| **A2A** | Agent ↔ agent (discovery, tasks, messages, artifacts) |

When composed: an A2A **remote agent** often *hosts* an MCP client (or is called by a host that holds MCP clients). The agent receives an A2A task, then calls MCP tools to do work, then returns A2A artifacts/messages.

**Vibe already is half of this:**

```
Provider agent (A2A client of Vibe)
    │  card / invoke / events  (secret auth)
    ▼
Vibe messenger host
    │  renders vibe.content.v1, chat membership, E2E for humans
    ▼
Human participants
```

**MCP bridge completes the reverse tool edge:**

```
Provider agent runtime (MCP client)
    │  tools/call  (chat-scoped token)
    ▼
Vibe MCP server  ──enforces──► consent, scopes, attachment, rate limits
    │
    ▼
Chat / media / message pipelines (same as invoke/events, not a parallel store)
```

Do **not** re-implement message delivery only inside MCP while also having events/invoke — MCP tools should **call the same runtime** (`AgentEventRuntime`, chat APIs, media pipeline) that invoke/events use.

Related research in-repo: A2A part/extension model in  
`docs/research/research-extensible-contracts.md` §1; content dual-publish lessons in §2.

---

## 4. What Vibe can compose with *today* (read-only inventory)

### 4.1 Public provider ingress (`AgentsController`)

File: `server/lib/vibe_web/controllers/agents_controller.ex`

| Endpoint | Auth | Failure modes already modeled |
|----------|------|--------------------------------|
| `GET …/card` | none (published only) | 404 hides non-published |
| `POST …/invoke` | `x-vibe-agent-secret` | 401 invalid secret; 403 unavailable / chat not attached; 422 invalid_content |
| `POST …/events` | agent secret **or** `x-vibe-integration-secret` | same + missing destination / eventType |
| Owner APIs | user session | integrations, approve/reject tasks, rotate secret |

`merge_provider_content/1` already validates `vibe.content.v1` and degrades to text/attachments for the existing pipeline.

### 4.2 Security principles to preserve

From `docs/provider-platform.md`:

1. **Per-chat participation consent** — agent acts only when attached.  
2. **Human↔human E2E untouched** by provider traffic.  
3. **Secrets hashed**; plaintext one-time reveal; rotation API.  
4. **Autonomy modes** gate side effects.  
5. **Public rate limits** on card/invoke/events.

MCP must not create a bypass around attachment or a second message path that skips `chat_not_attached`.

### 4.3 Content contract intersection

`docs/provider-content-contract.md`:

- Dual-publish text lanes (MCP already does content + structuredContent).  
- Must-ignore unknown kinds (MCP open content `type`).  
- Negotiation via agent card capabilities (MCP capability maps / server discover).  
- Actions parts today stub `onAction` on clients — a future **host action callback** is separate from MCP tools (user-tapped button vs model-called tool).

### 4.4 Local precedent: bridge MCP

`docs/agent-payload-shapes.md` documents Mac-local MCP (`ask_user`, Fable advisor). That is **stdio / unix-socket MCP for coding agents**, not the public provider bridge — but it proves Vibe already thinks in MCP tool names, consent UX, and payload rendering for tool steps.

---

## 5. Threat model (messenger-specific)

| Threat | Why messengers are special | Mitigation |
|--------|---------------------------|------------|
| **Thread exfiltration** | Full history is high-value PII | Resource tools require explicit **read** scope + UX preview of window (last N / since timestamp); never default-grant “all history” |
| **Prompt injection via history** | Other humans/agents can plant instructions | Treat tool-returned thread text as untrusted content; optional redaction; do not auto-expand grants from model requests |
| **Unsolicited send** | Spam / social engineering | `messages.send` requires **write** scope + attachment + autonomy/approval for non-safe_auto |
| **Cross-chat pivot** | Token for chat A used on chat B | Bind every token to `chat_id` (+ agent_id); enforce on every call |
| **Secret reuse as MCP auth** | Agent webhook secret is long-lived, broad | **Do not** accept raw `x-vibe-agent-secret` as sole MCP auth for read tools; mint **chat-scoped, short-lived** capability tokens (or OAuth access tokens with chat claim) |
| **Confused deputy** | Provider host calls Vibe MCP with user token | Audience-bind tokens to Vibe MCP resource; no passthrough of user session cookies |
| **Media leakage** | Images/files more sensitive than text | Separate `media.read` / `media.upload` scopes; signed blob URLs with TTL |
| **Annotation lies** | `readOnlyHint: true` on a write tool | Ignore untrusted annotations for authorization; server enforces scopes |

---

## 6. Design proposal for Vibe

### 6.1 Positioning

**Vibe runs an MCP server** that exposes **consented chat capabilities** to provider agent runtimes (MCP clients).  

Providers remain A2A participants for discovery and outbound delivery (card, invoke, events, `message.stream`). MCP is the **inbound tool/resource plane** for host context.

```
┌─────────────────────────────────────────────────────────────┐
│ Provider (OpenAI / Anthropic / xAI / indie)                 │
│  • Holds agent secret for invoke/events                     │
│  • MCP client with chat-scoped access token                 │
└───────────────┬─────────────────────────────┬───────────────┘
                │ A2A-ish HTTP                │ MCP HTTP
                │ invoke / events             │ tools/* resources/*
                ▼                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Vibe                                                        │
│  AgentsController          McpBridgeController (NEW)        │
│         │                           │                       │
│         └──────────┬────────────────┘                       │
│                    ▼                                        │
│         Chat / AgentEventRuntime / media / consent store    │
│                    │                                        │
│         iOS / web render vibe.content.v1                    │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Endpoint shapes

#### A. MCP transport (JSON-RPC over Streamable HTTP)

| Item | Proposal |
|------|----------|
| Path | `POST /api/mcp` (global) **or** `POST /api/agents/:identifier/mcp` (agent-scoped URL for simpler provider config) |
| Protocol | Streamable HTTP; advertise in agent card `capabilities.mcp = { "url", "protocolVersions": ["2025-11-25"] }` |
| Headers | `Authorization: Bearer <vibe_mcp_token>`; later also `MCP-Protocol-Version` / `Mcp-Method` for RC readiness |
| Methods (phase 1) | `initialize` or `server/discover` (per negotiated version), `tools/list`, `tools/call`, `resources/list`, `resources/read`, `ping` |
| Not in phase 1 | Sampling, roots, MCP Apps UI hosting, prompts (optional phase 2) |

**Agent-scoped URL (recommended):** providers already bind to `:identifier`; card can list:

```json
{
  "capabilities": {
    "mcp": {
      "url": "https://<host>/api/agents/<identifier>/mcp",
      "transport": "streamable-http",
      "protocolVersions": ["2025-11-25", "2025-06-18"]
    }
  }
}
```

Placeholder secrets only in examples: `vib_mcp_tok_••••` / never commit real tokens.

#### B. Consent & token minting (owner / chat UX)

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/api/chats/:chatId/agent-grants` | GET | user session | List grants for agents in chat |
| `/api/chats/:chatId/agent-grants` | POST | user session (member) | Create/update grant: scopes, retention, expiry |
| `/api/chats/:chatId/agent-grants/:grantId/revoke` | POST | user session | Immediate revoke |
| `/api/agents/:identifier/mcp/token` | POST | `x-vibe-agent-secret` **plus** proof of grant | Exchange for short-lived MCP access token |

**Token exchange body (illustrative):**

```json
{
  "chatId": "<uuid>",
  "grantId": "<uuid>",
  "scopes": ["chat.read.messages", "messages.send"]
}
```

**Token response:**

```json
{
  "accessToken": "vib_mcp_tok_••••",
  "tokenType": "Bearer",
  "expiresIn": 900,
  "scopes": ["chat.read.messages", "messages.send"],
  "chatId": "<uuid>",
  "agentId": "<uuid>",
  "resource": "https://<host>/api/agents/<identifier>/mcp"
}
```

Claims to bind in the token (JWT or server-side opaque handle): `agent_id`, `chat_id`, `scopes[]`, `grant_id`, `aud` = MCP resource URL, `exp` ≤ 15–60 minutes. Refresh = re-exchange with agent secret + still-valid grant (no long-lived refresh token required in phase 1).

#### C. OAuth profile (phase 2, Claude/ChatGPT-native)

When third-party *hosts* (not only provider backends) connect:

- Serve RFC 9728 Protected Resource Metadata at  
  `/.well-known/oauth-protected-resource/api/agents/{identifier}/mcp`
- Authorization server can be Vibe itself (user login + consent screen listing scopes and chat).
- Support CIMD for unbounded clients; PKCE; `resource` parameter.
- Align with https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization  

Phase 1 can ship **capability tokens** without full OAuth UI; phase 2 adds OAuth so Claude/ChatGPT connector directories can attach “Vibe” as a remote server *if product wants that* — separate product decision from provider-agent bridge.

### 6.3 Tool and resource catalog (v1)

Scope IDs use reverse-DNS-ish strings stable in card + grant UI.

| MCP tool name | Scope | Side effect | Maps to |
|---------------|-------|-------------|---------|
| `vibe.messages_send` | `messages.send` | **Write** | Same path as event message create / invoke message insert; support optional `content` envelope (`vibe.content.v1`) |
| `vibe.messages_stream` | `messages.send` | **Write** (progressive) | Same as board `message.stream` events (`streamId`, full accumulated `text`, `seq`, `done`) |
| `vibe.thread_read` | `chat.read.messages` | Read | Return last *N* messages (cap enforced server-side); redacted fields for other agents as policy dictates |
| `vibe.thread_search` | `chat.read.messages` | Read | Optional keyword/time window search within grant window |
| `vibe.media_upload` | `media.upload` | **Write** | Existing media pipeline → sealed blob URL |
| `vibe.media_fetch_meta` | `media.read` | Read | Metadata only; bytes via short-lived signed URL if granted |
| `vibe.chat_info` | `chat.read.meta` | Read | Title, member count, agent attachment state — no message bodies |

**Resources (read):**

| URI pattern | Scope | Content |
|-------------|-------|---------|
| `vibe://chat/{chatId}` | `chat.read.meta` | JSON chat summary |
| `vibe://chat/{chatId}/messages?limit=&before=` | `chat.read.messages` | Message page as `text/plain` or `application/json` |
| `vibe://blob/{blobId}` | `media.read` | Metadata resource; not raw bytes without signed URL |

**Tool result dual-publish example (`vibe.thread_read`):**

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"messages\":[{\"id\":\"…\",\"role\":\"user\",\"text\":\"…\"}]}"
    }
  ],
  "structuredContent": {
    "chatId": "…",
    "messages": [
      {
        "id": "…",
        "senderId": "…",
        "isAgent": false,
        "text": "…",
        "createdAt": "2026-07-18T12:00:00Z"
      }
    ],
    "truncated": false,
    "grantExpiresAt": "2026-07-18T13:00:00Z"
  }
}
```

**Send tool arguments (illustrative):**

```json
{
  "name": "vibe.messages_send",
  "arguments": {
    "chatId": "<must match token>",
    "text": "Hello from the assistant",
    "content": {
      "contract": "vibe.content.v1",
      "fallbackText": "Hello from the assistant",
      "parts": [
        {
          "kind": "text",
          "schemaVersion": 1,
          "text": "Hello from the assistant",
          "data": { "format": "markdown" }
        }
      ]
    }
  }
}
```

Server rejects mismatched `chatId` vs token claim; validates content via existing `ProviderContent.parse`; returns `isError: true` with text lane on soft failures; protocol errors for unknown tool / invalid args.

### 6.4 Consent model

#### Layers (all must pass)

1. **Agent published** — same as invoke.  
2. **Chat attachment** — agent is a participant / allowed for destination.  
3. **User grant** — explicit scopes for this agent in this chat (default: **none** for MCP read/write; outbound events alone do not imply read history).  
4. **Token scopes ⊆ grant scopes**.  
5. **Autonomy mode** — for write tools:  
   - `approval_required` / `manual` / `draft_first` → create approval task (or block) before commit  
   - `safe_auto` → allow only non-destructive, rate-limited sends  
   - `full_auto` → still rate-limited; audit log required  
6. **Rate limits** — per agent, per chat, per tool class (align with public ingress limits).

#### Consent UX (mobile-first)

| Moment | UX |
|--------|----|
| First tool need / attach | Sheet: “**{Agent}** wants to use tools in this chat” with scope checklist (Read recent messages · Send messages · Upload media) |
| Scope copy | Human language, not OAuth jargon: “Read the last 50 messages” not `chat.read.messages` |
| Preview | For read grants, show sample of what will be visible (participants, retention window) |
| Step-up | Model requests `media.upload` without grant → tool error `insufficient_scope` → host shows upgrade sheet |
| Revoke | Chat info → Agents → Grants → Revoke; kills outstanding tokens on next call |
| Audit | Optional “Tool activity” list: tool name, time, success/fail (no secret material) |

#### Grant record (server)

```json
{
  "id": "grant_…",
  "chatId": "…",
  "agentId": "…",
  "grantedByUserId": "…",
  "scopes": ["chat.read.messages", "messages.send"],
  "readWindow": { "maxMessages": 50, "maxAgeDays": 7 },
  "createdAt": "…",
  "expiresAt": "…",
  "revokedAt": null
}
```

Group chats: require **policy choice** — phase 1: any admin or any member can grant for themselves-as-approver; messages of other members only if grant says so. **`[unverified product decision]`** recommend: member who grants only authorizes reading messages *they can already see* under normal membership rules; no elevation.

#### Alignment with MCP elicitation

For mid-run step-up or extra fields (e.g. “which thread?”), prefer:

1. Vibe-native approval / in-chat consent card, **or**  
2. MCP elicitation if the *provider host* supports it — Vibe as MCP **server** typically *receives* tool calls, not elicitation; Vibe as host for local agents already has `ask_user`.

Do not put passwords/API keys in elicitation; agent secrets stay on owner rotate flow.

### 6.5 Auth binding to agent secrets

| Credential | Use | Not for |
|------------|-----|---------|
| `x-vibe-agent-secret` | invoke, events, **token exchange** | Direct `tools/call` on sensitive read/write |
| Integration secret | events only (as today) | MCP |
| MCP access token | `Authorization: Bearer` on MCP endpoint | Invoke/events (keep paths separate) |
| User session | Grant/revoke UX | Provider cloud |

Agent secret proves **who the agent is**; grant + token proves **what this chat allows right now**. Both are required to act.

### 6.6 Agent card advertisement

Extend published card (additive):

```json
{
  "capabilities": {
    "streaming": true,
    "pushNotifications": true,
    "events": ["message.stream"],
    "contentContract": { "version": 1, "parts": ["text", "media", "card", "actions", "citations", "status", "error"] },
    "mcp": {
      "url": "https://<host>/api/agents/<identifier>/mcp",
      "transport": "streamable-http",
      "protocolVersions": ["2025-11-25"],
      "scopesSupported": [
        "chat.read.meta",
        "chat.read.messages",
        "messages.send",
        "media.read",
        "media.upload"
      ],
      "tools": [
        "vibe.chat_info",
        "vibe.thread_read",
        "vibe.messages_send",
        "vibe.messages_stream",
        "vibe.media_upload",
        "vibe.media_fetch_meta"
      ]
    }
  },
  "securitySchemes": {
    "agentSecret": {
      "type": "apiKey",
      "in": "header",
      "name": "x-vibe-agent-secret"
    },
    "mcpBearer": {
      "type": "http",
      "scheme": "bearer",
      "description": "Chat-scoped MCP access token from POST …/mcp/token"
    }
  }
}
```

`securitySchemes` must match real auth (existing platform rule) — do not advertise fictional OAuth until phase 2 ships it.

### 6.7 Three-phase plan

#### Phase 1 — Capability-token MCP bridge (provider backends)

**Goal:** Provider runtimes can `thread_read` + `messages_send` under explicit chat grants.

| Work | Notes |
|------|--------|
| Grant schema + APIs | DB table, owner/member UI minimal (iOS + web or server-only admin first) |
| Token mint + validate | Opaque or JWT; 15 min TTL; bind agent+chat+scopes |
| `POST …/mcp` JSON-RPC | `tools/list`, `tools/call` for `vibe.chat_info`, `vibe.thread_read`, `vibe.messages_send` |
| Enforcement | Attachment + grant + autonomy + rate limit; reuse `ProviderContent` |
| Card fields | `capabilities.mcp` + `scopesSupported` |
| Docs | `/docs/providers` security + MCP quickstart |
| Tests | Secret alone cannot read; wrong chatId fails; revoked grant fails; seq/stream still via events if preferred |

**Out of scope:** OAuth AS, MCP Apps iframe, prompts, sampling.

**Success metric:** One external provider agent can summarize last N messages (with grant) and post a reply that appears as a normal agent message.

#### Phase 2 — Streaming tool + media + step-up + OAuth option

| Work | Notes |
|------|--------|
| `vibe.messages_stream` | Same semantics as frozen `message.stream` board contract |
| Media tools | Upload via existing pipeline; `media.read` signed URLs |
| `insufficient_scope` | Map to MCP/HTTP 403 style errors; mobile step-up sheet |
| Resources | `vibe://chat/…` read mirrors tools for hosts that prefer resources |
| OAuth AS (optional) | CIMD + PKCE + RFC 9728 for ChatGPT/Claude-style connectors |
| Elicitation parity | Approval tasks surface as structured pending state in tool results |
| Audit log | Per-call ledger for enterprise |

**Success metric:** Provider streams a long answer via MCP or events equivalently; media round-trip works; user can revoke mid-session.

#### Phase 3 — Ecosystem polish + A2A skill mapping

| Work | Notes |
|------|--------|
| Map card `skills[]` ↔ MCP tool names | Single registry (`ToolRegistry` / enabled_tools) drives both |
| MCP Apps / vibe.content bridge | Optional: actions part IDs invoke host callbacks; MCP Apps only if product wants embedded provider UI |
| Stateless RC transport | `server/discover`, `Mcp-Method` headers, `inputRequired` if we ever act as client |
| Provider directory badges | “MCP tools verified” trust signal |
| Cross-agent policy | Admin policies for workplace chats; default-deny history for new agents |

**Success metric:** Documented reference provider (OpenAPI-style) implements card + events stream + MCP tools against sandbox; security review signed off.

### 6.8 Explicit non-goals

- Replacing invoke/events with MCP-only delivery.  
- Giving MCP access to human E2E key material.  
- Auto-granting history on agent attach.  
- Trusting tool `readOnlyHint` for authorization.  
- Running provider STDIO MCP inside Vibe server.

### 6.9 Implementation sketch (modules — not owned by this research file)

| Module | Responsibility |
|--------|----------------|
| `Vibe.MCP.Server` | JSON-RPC dispatch, protocol version gate |
| `Vibe.MCP.Auth` | Token issue/verify, scope check |
| `Vibe.MCP.Tools.*` | Thin wrappers over Chat / AgentEventRuntime / media |
| `Vibe.AgentGrants` | Grant CRUD, revoke, window policy |
| `VibeWeb.McpController` | HTTP entry |
| Agent card builder | Advertise mcp block |

Integrator owns wiring; this research freezes **names and consent semantics**, not code.

### 6.10 Verification checklist (for implementers)

1. Without grant: `tools/call` → authorization error; no message side effects.  
2. With read-only grant: send tool denied; read tool respects `maxMessages`.  
3. With send grant + unattached chat: still **403 chat_not_attached**.  
4. Expired/revoked token: 401; re-exchange fails if grant revoked.  
5. `vibe.content.v1` invalid on send: soft error result, no partial privileged leak.  
6. Rate limit: burst send blocked consistently with events ingress.  
7. Card never embeds secrets or grant tokens.  
8. Human E2E chats: provider MCP cannot decrypt peer payloads it was not party to — only server-visible agent-participating content. **`[unverified exact E2E boundary for agent members — confirm against security.md before ship]`**

---

## 7. Sources

### Primary / official

- MCP 2025-06-18 overview: https://modelcontextprotocol.io/specification/2025-06-18  
- MCP tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools  
- MCP elicitation: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation  
- MCP authorization (2025-11-25): https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization  
- MCP 2026-07-28 RC blog: https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/  
- MCP Apps: https://modelcontextprotocol.io/docs/extensions/apps  
- A2A announcement (MCP complement): https://developers.googleblog.com/en/a2a-a-new-era-of-agent-interoperability/  
- A2A specification: https://a2a-protocol.org/latest/specification/  
- Claude API MCP connector: https://platform.claude.com/docs/en/agents-and-tools/mcp-connector  
- Claude connectors: https://claude.com/connectors  
- Claude MCP Apps blog: https://claude.com/blog/interactive-tools-in-claude  
- OpenAI remote MCP / ChatGPT apps: https://developers.openai.com/api/docs/mcp  
- ChatGPT apps help: https://help.openai.com/en/articles/11487775-connectors-in-chatgpt  

### In-repo

- `docs/provider-platform.md`  
- `docs/provider-content-contract.md`  
- `docs/research/research-extensible-contracts.md`  
- `docs/agent-payload-shapes.md`  
- `server/lib/vibe_web/controllers/agents_controller.ex`  
- Team board: `.vibe/team/provider-native-0718-board.md` §4  

---

## 8. Summary

MCP is the right **tool/resource** standard for letting provider agents act on Vibe host context; A2A-compatible cards and invoke/events remain the **participation and delivery** plane. Security must layer **attachment + user grant + short-lived chat-scoped tokens + autonomy**, never agent secret alone for history. Dual-publish tool results, reuse existing content validation and message pipelines, and ship in three phases: capability-token bridge → media/stream/OAuth → ecosystem skill mapping.
