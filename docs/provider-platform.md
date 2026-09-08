# Provider Agent Platform

Architecture for third-party AI providers that plug their assistants into Vibe as
first-class chat participants.

## Positioning

Vibe is an **E2E-encrypted, AI-first messenger** that welcomes provider AI assistants.
In 2026, major consumer messaging platforms restricted general-purpose AI bots.
Providers still need a messaging surface for their products; Vibe offers one on **open
standards** (A2A-compatible agent card, secret-authed public ingress, normalized
runtime payloads) without becoming the model vendor.

## Principle

**Vibe is the secure surface and transport; intelligence plugs in.**

Same philosophy as the [team architecture](team-architecture.md): keep hardened
identity, encryption, delivery, and rendering in the product; do not re-implement
provider cognition inside Vibe. A provider agent is a participant with a card, an
invoke path, and a payload contract — not a second chat stack.

## Components

All of these exist in the tree. Prefer citing and extending them over inventing
parallel surfaces.

### Agent accounts

| Piece | Location |
|---|---|
| Agent user flag | `users.is_agent` (agent identity in chat membership) |
| Agent schema | `Vibe.Agent` — `server/lib/vibe/schemas/agent.ex` |
| Context / lifecycle | `Vibe.Agents` — `server/lib/vibe/agents.ex` |

Schema highlights (stable concepts): `display_name`, `persona`, `avatar_url`,
`status` (`draft` \| `published` \| `disabled` \| `archived`), `enabled_tools`,
`output_modes` (`text` \| `media` \| `voice`), `event_types_enabled`,
`autonomy_mode`, `webhook_secret_hash` / `secret_hint`, `agent_user` → user row with
username as public identifier.

Only **published** agents are invokable or card-discoverable.

### A2A-compatible Agent Card

| Piece | Location |
|---|---|
| Builder | `Vibe.AgentCard` — `server/lib/vibe/agent_card.ex` |
| HTTP | `card/2` on `VibeWeb.AgentsController` |
| Routes | `GET /api/agents/:identifier/card` · `GET /.well-known/agent-card/:identifier` |

Public, rate-limited, **published only** (else `404` `{ "error": "not_found" }`).
No secrets, prompts, budgets, or owner ids in the card.

Top-level shape (A2A-compatible profile):

```json
{
  "protocolVersion": "0.3.0",
  "kind": "vibe.agent-card",
  "identifier": "<agent_user.username>",
  "name": "<display_name>",
  "description": "<persona or welcome_message>",
  "url": "<base>/api/agents/<identifier>/invoke",
  "eventsUrl": "<base>/api/agents/<identifier>/events",
  "provider": { "organization": "<owner display name>", "url": null },
  "version": "1",
  "capabilities": {
    "streaming": false,
    "pushNotifications": true,
    "events": ["<event_types_enabled>"]
  },
  "defaultInputModes": ["text"],
  "defaultOutputModes": ["<output_modes>"],
  "securitySchemes": { },
  "skills": [{ "id": "<tool>", "name": "<tool>", "description": "", "tags": [] }],
  "status": "published"
}
```

`securitySchemes` must match the real invoke/events auth (header secret), not a
fictional OAuth profile.

### Public ingress

| Endpoint | Action | Auth |
|---|---|---|
| `POST /api/agents/:identifier/invoke` | `AgentsController.invoke/2` | `x-vibe-agent-secret` |
| `POST /api/agents/:identifier/events` | `AgentsController.ingest_event/2` | `x-vibe-agent-secret` or `x-vibe-integration-secret` |

Implementation: `server/lib/vibe_web/controllers/agents_controller.ex`, runtime in
`Vibe.AI.StandaloneAgent` / event runtime. Secret compare is hash-based
(`Agents.verify_secret/2` and peers). Failed secret → `401`; unpublished →
unavailable; chat not attached when required → `403`.

### Normalized payload contract

Providers and local agent CLIs converge on the same **agent-turn payload** the phone
already renders: runtime cards, tool steps, thinking, approvals, subagents.

Authoritative shapes: [`docs/agent-payload-shapes.md`](agent-payload-shapes.md).

Pipeline: producer → bridge/server normalize → `agent-stream` / result → iOS native
agent views. The payload contract is the product moat for third-party intelligence:
teach it once; every provider looks native.

### Web docs (providers)

Routed under `/docs/providers` (web SPA):

| Route | Role |
|---|---|
| `/docs/providers` | overview |
| `/docs/providers/quickstart` | first invoke |
| `/docs/providers/payloads` | payload contract for providers |
| `/docs/providers/security` | secrets, consent, limits |

Implementation lives with the existing agent docs system
(`client/src/pages/AgentDocs*.tsx`, shared helpers in `agentDocsShared.ts`) plus
provider-specific pages. Owner product docs: this file + payload shapes.

## Security model

| Control | Behavior |
|---|---|
| **Per-chat participation consent** | An agent acts in a chat only when attached / allowed for that destination; invoke with an unattached chat fails closed. |
| **Human ↔ human E2E** | Untouched. Provider traffic does not weaken pairwise encryption for human participants. |
| **Secrets** | Stored as hashes (+ encrypted material for callback signing where needed). Plaintext secret is **one-time reveal** on create/rotate; only `secret_hint` remains. Rotation via owner API (`rotate_secret`). |
| **Autonomy / approval modes** | `autonomy_mode` on the agent (`draft_first`, `manual`, `safe_auto`, `approval_required`, `full_auto`) plus approval tasks for gated actions. |
| **Public-scope rate limits** | Card, invoke, and events sit behind public rate limiting so anonymous or secret-bearing traffic cannot abuse the edge. |
| **Card hygiene** | No secrets, prompts, budgets, or owner identifiers on the public card. |

Local coding agents on the Mac use the bridge permission layer (destructive-command
blocklist). Provider agents use secret auth + chat attachment + autonomy rules. Both
sit on the same messenger security surface.

## Roadmap (short)

0. **Isolated ingress (2026-08)** — provider traffic moves to `agents.<host>/v1/*` on the
   isolated agent runtime; the core keeps `/api/agents/:identifier/*` as aliases. Same auth,
   same payloads, plus `Idempotency-Key` and `GET /v1/tasks/:id`. See
   [agent-platform-v1.md](agent-platform-v1.md) §3.5.
1. **Streaming task lifecycle** — card `capabilities.streaming` and progressive
   agent-turn frames for long provider runs.
2. **Provider verification badges** — trust signal for known provider organizations
   on the card and in chat chrome.
3. **Provider directory** — discoverable published agents beyond well-known URLs.
4. **MCP tool bridging** — optional bridge so provider skills map cleanly to tools
   the runtime already understands.

## Related docs

- [Team architecture](team-architecture.md) — how multi-agent coding runs on the Mac
- [Agent payload shapes](agent-payload-shapes.md) — wire contract iOS renders natively
- [Security](security.md) — product-wide encryption and auth principles
