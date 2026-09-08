# Research: future-proof content-contract patterns

**Date:** July 2026  
**Question:** How do mature wire contracts let providers ship *new feature types* so old app versions degrade gracefully (never crash, never render nothing) without redesigning the protocol?  
**Audience:** Vibe messenger (iOS-first) AI-provider render contract.

Claims marked **`[unverified]`** are inferences or ecosystem folklore not confirmed in a primary spec page during this research pass.

---

## 1. A2A (Agent2Agent) protocol

**Primary:** https://a2a-protocol.org/latest/specification/ (latest released v1.0.0; also https://a2a-protocol.org/v1.0.0/specification)

### Mechanism

A2A’s content model is deliberately small and open-ended:

| Concept | Role |
|--------|------|
| **Message** | One turn of communication (`role` + `parts[]`). Not for final task outputs. |
| **Part** | Atomic content unit: exactly one of `text` \| `raw` \| `url` \| `data`, plus optional `mediaType`, `filename`, `metadata`. |
| **Artifact** | Task *output* built from `parts[]` (documents, images, structured data). |
| **Task** | Stateful work unit with lifecycle (working → completed/failed/…); history + artifacts. |
| **Agent Card** | Discovery document: identity, `defaultInputModes` / `defaultOutputModes` (MIME types), skills, capabilities, extensions. |
| **Extension** | URI-identified optional protocol surface; can be `required: true\|false`. |

**Capability / modality negotiation**

- Agent Card advertises default (and per-skill) **media types** for I/O.
- On send, client may pass `acceptedOutputModes: string[]` so the agent **should** tailor response parts.
- Optional features (streaming, push notifications, extended card) are capability flags; using an unsupported operation returns a typed error (`UnsupportedOperationError`, `PushNotificationNotSupportedError`, …).
- Protocol version via service parameter `A2A-Version` → `VersionNotSupportedError` if unsupported.
- Client opts into extensions via binding-specific headers, e.g. `A2A-Extensions: uri1,uri2`.

**Unknown content / extensions**

- Core **Part** is not an open enum of UI widgets—it is text / file / structured JSON. Novelty rides on:
  1. **mediaType** on parts (content-type open set), and  
  2. **Extensions** keyed by URI on messages/artifacts + metadata maps.
- If the client requests an extension version the agent doesn’t support, the agent **SHOULD ignore** that extension and proceed **unless** it is marked `required` on the Agent Card (then error). Agents must **not** silently fall back to a previous extension version.
- Required extension without client declaration → `ExtensionSupportRequiredError`.

**Version negotiation**

- Proto-first evolution with deprecation lifecycle: rename → keep old name deprecated until next major.
- Breaking shape change in v1.0: removed inline `"kind": "text|file|data"` discriminators in favor of protobuf-style **oneof member names** (`text` / `raw`+`url` / `data`). That is a **hard client break** if parsers assumed `kind`—mitigated only by `protocolVersion` on interfaces and dual-format transition advice.

### Wire examples

**Agent Card (capability + extension discovery):**

```json
{
  "name": "Research Assistant Agent",
  "description": "AI agent for academic research and fact-checking",
  "version": "1.0.0",
  "supportedInterfaces": [
    {
      "url": "https://research-agent.example.com/a2a/v1",
      "protocolBinding": "HTTP+JSON",
      "protocolVersion": "1.0"
    }
  ],
  "capabilities": {
    "streaming": true,
    "pushNotifications": false,
    "extendedAgentCard": true,
    "extensions": [
      {
        "uri": "https://standards.org/extensions/citations/v1",
        "description": "Citation formatting and source verification",
        "required": false
      }
    ]
  },
  "defaultInputModes": ["text/plain"],
  "defaultOutputModes": ["text/plain", "application/json"],
  "skills": [
    {
      "id": "academic-research",
      "name": "Academic Research Assistant",
      "description": "Research with citations",
      "tags": ["research", "citations"],
      "inputModes": ["text/plain"],
      "outputModes": ["text/plain", "application/json"]
    }
  ]
}
```

**Message with parts (v1.0 oneof shape):**

```json
{
  "messageId": "msg-01",
  "role": "ROLE_AGENT",
  "parts": [
    { "text": "Global temperatures have risen by 1.1°C since pre-industrial times." },
    {
      "data": {
        "series": [{ "year": 2023, "anomalyC": 1.1 }]
      },
      "mediaType": "application/json"
    },
    {
      "url": "https://cdn.example.com/chart.png",
      "filename": "chart.png",
      "mediaType": "image/png"
    }
  ],
  "extensions": ["https://standards.org/extensions/citations/v1"],
  "metadata": {
    "https://standards.org/extensions/citations/v1": {
      "sources": [
        {
          "title": "Global Temperature Anomalies - 2023 Report",
          "url": "https://climate.gov/reports/2023-temperature"
        }
      ]
    }
  }
}
```

**Client declaring accepted output modes:**

```json
{
  "message": {
    "messageId": "msg-02",
    "role": "ROLE_USER",
    "parts": [{ "text": "Summarize the paper" }]
  },
  "configuration": {
    "acceptedOutputModes": ["text/plain", "image/png"]
  }
}
```

### What breaks vs degrades

| Situation | Behavior |
|-----------|----------|
| Client ignores optional extension metadata | **Degrades** — still sees base text/file/data parts |
| Client lacks required extension | **Hard fail** — `ExtensionSupportRequiredError` |
| Unsupported media type on request | **Hard fail** — `ContentTypeNotSupportedError` |
| Server emits only exotic `mediaType` client can’t render | **Soft degrade only if client implements generic fallback** — A2A does **not** mandate per-part `fallbackText` in core Part |
| Protocol major reshape (`kind` → oneof) | **Breaks** old clients that cannot dual-parse |

### Lessons for Vibe

- Keep the **core part vocabulary tiny** (text / binary / URL / structured data); put UI novelty in **typed media + extensions**, not infinite native block enums.
- **Discovery document** (Agent Card analog) + **client-declared accept set** (`acceptedOutputModes` / render set) is the right place for negotiation.
- Mark extensions **optional by default**; reserve `required` for rare must-understand cases.
- Prefer **URI-versioned extensions** over silently mutating meaning of old URIs.
- Caveat: A2A alone does **not** guarantee “never render nothing” for unknown rich payloads—you must add **fallback text** yourself.

---

## 2. MCP (Model Context Protocol)

**Primary (stable content model):** https://modelcontextprotocol.io/specification/2025-06-18  
**Lifecycle / versioning:** https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle  
**Tools / content:** https://modelcontextprotocol.io/specification/2025-06-18/server/tools  
**MCP Apps extension:** https://modelcontextprotocol.io/docs/extensions/apps  
**2026-07-28 RC (evolution):** https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/

### Mechanism

**Primitives**

| Primitive | Meaning |
|-----------|---------|
| **Tools** | Model-invoked functions; JSON Schema I/O |
| **Resources** | Read-only context blobs (URI + mime) |
| **Prompts** | Templated user/LLM workflows |
| **Content blocks** | Discriminated by `type`: `text`, `image`, `audio`, `resource_link`, `resource` (embedded) |
| **structuredContent** | Parallel machine-readable JSON result (2025+) |
| **Capabilities** | Negotiated at `initialize` (tools/resources/prompts, sampling, elicitation, …) |

**Content / degradation pattern**

- Tool results return **`content[]`** (unstructured, multi-type) **and optionally** `structuredContent`.
- Spec guidance: if you return structured content, **also** return serialized JSON in a **TextContent** block for backward compatibility.
- Content types are an **open discriminator** (`type` string). Unknown types: hosts that treat the array as a list of known renderers **must ignore unknowns** if they follow must-ignore JSON discipline—**spec does not always spell “MUST ignore unknown content types” in one place** `[unverified for absolute MUST wording]`; practical SDKs skip unknown blocks and keep text.

**Versioning (2025 era)**

- Client proposes `protocolVersion` (date string, e.g. `2025-06-18`).
- Server echoes same if supported, else offers another version it supports; client disconnects if it cannot speak that version.
- HTTP: `MCP-Protocol-Version` header on subsequent requests.
- Capabilities are **feature maps**, not a single monolithic version for UI.

**2026-07-28 RC direction (as of this research)**

- **Stateless core**: remove session/`initialize` handshake; version + client info travel per-request; `server/discover` for capabilities.
- **Extensions first-class**: reverse-DNS IDs, negotiated via `extensions` capability map, version independently of core (SEP-2133).
- **MCP Apps** (SEP-1865) as official extension: server-declared UI resources.
- **Feature lifecycle**: Active → Deprecated → Removed with **≥12 months** between deprecation and earliest removal.
- Breaking changes still happen for foundational reworks; future evolution intended to be additive via extensions.

**UI embedding (MCP Apps / mcp-ui / Apps SDK relationship)**

| Layer | Role |
|-------|------|
| **MCP core** | Tools/resources; text + structured results |
| **MCP Apps** | Open extension: tool declares `_meta.ui.resourceUri` → host loads `ui://…` HTML resource into **sandboxed iframe**; bridge is JSON-RPC over `postMessage` (`ui/*`, plus `tools/call`) |
| **mcp-ui / App Bridge** | Host-side libraries to embed and police apps (https://mcpui.dev / ext-apps App Bridge) |
| **OpenAI Apps SDK** | Product implementation that **helped shape** MCP Apps; still supports `window.openai` + `_meta["openai/outputTemplate"]` as aliases |

Hosts that do **not** implement MCP Apps simply never mount the iframe; they still receive ordinary tool `content` / text—**if the server always dual-publishes text**.

### Wire examples

**Capability negotiation (2025-06-18 initialize):**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "roots": { "listChanged": true },
      "sampling": {},
      "elicitation": {}
    },
    "clientInfo": { "name": "Vibe", "version": "1.4.0" }
  }
}
```

**Tool result: dual text + structured (forward compatible):**

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"temperature\": 22.5, \"conditions\": \"Partly cloudy\", \"humidity\": 65}"
      }
    ],
    "structuredContent": {
      "temperature": 22.5,
      "conditions": "Partly cloudy",
      "humidity": 65
    }
  }
}
```

**Unknown content type (illustrative — client should skip + keep text):**

```json
{
  "content": [
    { "type": "text", "text": "Your itinerary is ready." },
    {
      "type": "vibe.calendar_event",
      "data": { "start": "2026-08-01T09:00:00Z", "title": "Kickoff" }
    }
  ]
}
```

**MCP Apps tool metadata + dual content:**

```json
{
  "name": "render_dice_widget",
  "description": "Render dice UI after roll_dice",
  "_meta": {
    "ui": { "resourceUri": "ui://widget/dice.html" },
    "openai/outputTemplate": "ui://widget/dice.html"
  }
}
```

```json
{
  "structuredContent": { "sides": 6, "value": 4 },
  "content": [
    { "type": "text", "text": "Showing a 6-sided roll: 4." }
  ]
}
```

**UI bridge notification (host → iframe):**

```json
{
  "jsonrpc": "2.0",
  "method": "ui/notifications/tool-result",
  "params": {
    "content": [{ "type": "text", "text": "Rolled 4." }],
    "structuredContent": { "sides": 6, "value": 4 }
  }
}
```

### What breaks vs degrades

| Situation | Behavior |
|-----------|----------|
| Host without MCP Apps | **Degrades** to text/structured if server dual-writes |
| Host with Apps, old widget cache | Prefetch/cache of static UI resources; tool result still text |
| Unknown content `type` | **Degrades** if client skips unknown; **blank gap** if client only looped known types and ignored text |
| Protocol version mismatch | **Hard disconnect** (by design) |
| 2026 stateless migration | **Breaks** session-based clients; intended as rare foundational break |

### Lessons for Vibe

- **Always dual-publish**: rich/structured + human-readable text.
- **Capability negotiation** for optional surfaces (apps, sampling, …).
- Push experimental UI into **extensions**, not core version bumps.
- Sandboxed HTML widgets = unbounded UI without growing native part enums—**but** requires host support; text remains the universal baseline.
- Deprecation windows beat silent breaking changes for ecosystem trust.

---

## 3. OpenAI Apps SDK (ChatGPT apps)

**Primary:** https://developers.openai.com/apps-sdk  
**UI build:** https://developers.openai.com/apps-sdk/build/chatgpt-ui  
**MCP Apps compatibility:** https://developers.openai.com/apps-sdk/mcp-apps-in-chatgpt  
**Announcement (MCP-based, open):** https://openai.com/index/introducing-apps-in-chatgpt/

### Mechanism

Architecture:

1. **MCP server** exposes tools + UI resources (`ui://…` HTML bundles, often inlined).
2. **Model** calls tools; server returns `structuredContent` (+ text `content`).
3. **Host (ChatGPT)** maps tool → UI template via `_meta.ui.resourceUri` (standard) or `_meta["openai/outputTemplate"]` (alias).
4. **Widget** runs in **iframe sandbox** (docs describe multi-layer isolation; CSP via `_meta.ui.csp`).
5. **Data flow** is event-driven, not “props on load only”:
   - Host pushes tool I/O via MCP Apps bridge (`ui/notifications/tool-result`, etc.) and/or `window.openai` + `openai:set_globals`.
   - Widget can `tools/call` / `window.openai.callTool`, `ui/message`, `ui/update-model-context`.
6. **Feature detection**: ChatGPT-only APIs (`requestModal`, `uploadFile`, checkout, …) are **optional extensions**—feature-detect and degrade.

**Recommended decoupling**

- **Data tools**: no UI template; return chainable `structuredContent` + text.
- **Render tools**: attach template; receive final, model-filtered data.

This prevents remount storms and lets the model refine data before UI.

### Wire examples

**Render tool result (server → host):**

```json
{
  "structuredContent": {
    "listings": [
      { "id": "L1", "title": "Mission loft", "price": 4200 }
    ]
  },
  "content": [
    {
      "type": "text",
      "text": "Found 1 listing matching your filters."
    }
  ]
}
```

**Host → widget (bridge):**

```json
{
  "jsonrpc": "2.0",
  "method": "ui/notifications/tool-result",
  "params": {
    "content": [{ "type": "text", "text": "Found 1 listing matching your filters." }],
    "structuredContent": {
      "listings": [{ "id": "L1", "title": "Mission loft", "price": 4200 }]
    }
  }
}
```

**Widget → host follow-up:**

```json
{
  "jsonrpc": "2.0",
  "method": "ui/message",
  "params": {
    "role": "user",
    "content": [
      { "type": "text", "text": "Draft a tasting itinerary for my picks." }
    ]
  }
}
```

**Feature-detect extension (host optional):**

```javascript
const openai = typeof window !== "undefined" ? window.openai : undefined;
if (openai?.requestModal) {
  await openai.requestModal({ template: "ui://widget/checkout.html" });
} else {
  // Fallback: send a message or open external link policy path
}
```

### What breaks vs degrades

| Situation | Behavior |
|-----------|----------|
| Host without Apps/UI | Text `content` remains; structured may still feed model |
| Missing ChatGPT extension API | **Degrades** if app feature-detects |
| Widget load failure / CSP block | Risk of **empty iframe** unless host shows text companion `[unverified exact ChatGPT chrome fallback UI]` |
| Tool approval delayed | Widget must treat missing initial toolInput as normal state |

### Lessons for Vibe

- Separate **data plane** and **render plane**.
- Treat host bridge APIs as **capability-detected**, not assumed.
- Always keep **model- and human-visible text** beside any widget.
- Prefer open **MCP Apps** keys for portability; vendor keys as aliases.
- Sandbox + CSP is non-negotiable for third-party UI in a messenger.

---

## 4. Slack Block Kit

**Primary:** https://docs.slack.dev/reference/block-kit/blocks  
**Message payloads:** https://docs.slack.dev/messaging  
**Legacy attachments fallback:** https://docs.slack.dev/legacy/legacy-messaging/legacy-secondary-message-attachments

### Mechanism

- Messages are a JSON payload with optional **`blocks[]`** (rich layout) and required-recommended top-level **`text`**.
- Official payload rules: when using blocks, **`text` is the fallback string for notifications and clients that don’t show blocks**. It is “highly recommended” even when not strictly enforced with blocks.
- Blocks are typed (`type: "section" | "image" | "actions" | …`). New block types ship over time; old clients historically **skip unknown block types** and still show top-level `text` / known blocks `[unverified for every historical client build; pattern is industry standard and matches Slack’s documented text-as-fallback role]`.
- Legacy **attachments** required `fallback` or `text` for clients that don’t show formatted attachments (IRC, mobile notifications)—explicit **accessibility / legacy surface** field.
- Rollout strategy: **additive block types + always-present plain text**, not a global protocol redesign.

### Wire examples

**Modern message (blocks + fallback text):**

```json
{
  "channel": "C123",
  "text": "Deploy finished: api@1.4.2 is live in production.",
  "blocks": [
    {
      "type": "header",
      "text": { "type": "plain_text", "text": "Deploy finished" }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*api@1.4.2* is live in *production*."
      }
    },
    {
      "type": "actions",
      "elements": [
        {
          "type": "button",
          "text": { "type": "plain_text", "text": "Open runbook" },
          "url": "https://runbooks.example.com/deploy"
        }
      ]
    }
  ]
}
```

**Hypothetical future block + safe companion:**

```json
{
  "text": "Poll: Which release train? Options: Train A, Train B.",
  "blocks": [
    {
      "type": "section",
      "text": { "type": "mrkdwn", "text": "Which release train?" }
    },
    {
      "type": "rich_poll",
      "poll_id": "p-9",
      "options": ["Train A", "Train B"]
    }
  ]
}
```

Old client: skips `rich_poll`, still shows `text` + section.  
New client: renders interactive poll.

**Legacy attachment fallback:**

```json
{
  "attachments": [
    {
      "fallback": "Build #412 succeeded on main",
      "text": "Build #412 succeeded on `main`",
      "color": "good"
    }
  ]
}
```

### What breaks vs degrades

| Situation | Behavior |
|-----------|----------|
| Unknown block `type` | **Degrades** — skip block, keep message text |
| Missing top-level `text` with blocks | **Degrades poorly** — notifications/older surfaces may be empty or generic |
| Interactive element unsupported | Button/action may not appear; text still readable |
| Entirely new surface without text | **Fails product requirement** “never render nothing” |

### Lessons for Vibe

- **Envelope-level fallback text is mandatory**, not optional polish.
- Additive **typed blocks** + must-ignore unknown types is proven at messenger scale.
- Don’t rely on rich layout alone for notifications, watch complications, or offline previews.

---

## 5. Telegram Bot API

**Primary:** https://core.telegram.org/bots/api  
**Changelog pattern:** continuous additive fields/classes (e.g. Bot API 10.x Rich Messages, June–July 2026)

### Mechanism

Telegram’s Bot API is a long-running case study in **additive JSON evolution**:

- Objects grow new **optional fields** and new **optional Update keys**.
- Docs: “**Optional** fields may be not returned when irrelevant.”
- New capabilities arrive as **new methods** (`sendRichMessage`, `sendLivePhoto`, …) and **new nested types**, not by removing old `sendMessage`.
- Clients (user apps and bot libraries) that deserialize with **ignore-unknown-fields** continue working when Telegram adds fields.
- **User clients** shipped by Telegram are upgraded centrally; third-party clients / bots that pin old schemas still receive new fields safely if they ignore unknowns.
- Recent **Rich Messages** introduce block-structured content (`RichBlock*`, `InputRichBlock*`) **alongside** classic text + entities—classic paths remain.

**Unknown entity/keyboard types**

- Bot authors send only types their target clients understand for critical UX; Telegram’s own clients implement progressive rendering.
- For bots *receiving* updates: new `Update` optional fields appear; bots that only handle `message` ignore `chat_boost`, `guest_message`, etc. until coded.
- **`allowed_updates`** is client-side filter (bot declares interest)—related to capability subscription, not content fallback.

### Wire examples

**Classic message (stable for years):**

```json
{
  "ok": true,
  "result": {
    "message_id": 421,
    "date": 1784300000,
    "chat": { "id": 123, "type": "private", "first_name": "Ada" },
    "text": "Hello *world*",
    "entities": [
      { "offset": 6, "length": 5, "type": "bold" }
    ]
  }
}
```

**Additive evolution: new optional field on same Message object (illustrative of 2026 rich path):**

```json
{
  "message_id": 422,
  "date": 1784300100,
  "chat": { "id": 123, "type": "private" },
  "text": "Summary of your trip",
  "rich_message": {
    "blocks": [
      {
        "type": "paragraph",
        "rich_text": [{ "type": "plain", "text": "Summary of your trip" }]
      },
      {
        "type": "table",
        "rows": [[{ "text": "Day 1" }, { "text": "Lisbon" }]]
      }
    ]
  }
}
```

Old bot library: ignores `rich_message`, still processes `text`.  
Old user client without rich renderer: shows `text` / simplified form **[client behavior details may vary; Telegram’s product goal is progressive enhancement]** `[unverified for every platform client]`.

**New Update kind (bot can opt out via allowed_updates):**

```json
{
  "update_id": 9001,
  "guest_message": {
    "message_id": 1,
    "text": "Hi guest bot",
    "guest_query_id": "gq-1"
  }
}
```

### What breaks vs degrades

| Situation | Behavior |
|-----------|----------|
| New optional field on known object | **Degrades** if ignore-unknown |
| New required field without versioning | Would **break** — Telegram largely avoids this |
| New exclusive message mode without text twin | Risk of empty old UI |
| Removing/renaming fields | Rare; changelog uses “remain temporarily available” deprecations for some fields |

### Lessons for Vibe

- **Additive optional fields forever** is the cheapest compatibility story.
- Keep a **classic text path** when introducing rich blocks.
- Client parsers: **must-ignore unknown fields and unknown nested type discriminators**.
- Prefer new methods / new optional branches over mutating semantics of old fields.

---

## 6. General protocol patterns (and failures)

### 6.1 Envelope versioning vs per-part versioning

| Approach | Pros | Cons |
|----------|------|------|
| **Envelope / protocol version** (MCP date, A2A `A2A-Version`, HTTP API major) | Clear handshake; can change global semantics | Bump is coarse; old clients often **disconnect** rather than degrade |
| **Per-part / per-extension version** (URI `…/v1`, content `type` + schema version, mediaType) | Additive growth; mixed ages in one message | Harder global invariants; needs ignore rules |
| **Hybrid (recommended)** | Core envelope stable; features as parts/extensions | Slightly more design work |

Evidence: MCP keeps a protocol version **and** content-type discriminators **and** (2026) independent extension IDs. A2A versions the protocol **and** URI-versions extensions.

### 6.2 Must-ignore vs must-understand

| Rule | Meaning | Classic home |
|------|---------|----------------|
| **Must-ignore** | Unknown fields/parts skipped; processing continues | JSON APIs, Telegram optional fields, Slack unknown blocks + text fallback, HTTP headers |
| **Must-understand** | Unknown critical extension → hard error | SOAP `mustUnderstand`, A2A `AgentExtension.required`, TLS extensions critical bit |

**Design rule of thumb:** default **must-ignore** for render parts; use **must-understand** only when continuing would be unsafe (auth, billing, legal).

References:

- SOAP mustUnderstand: https://www.w3.org/TR/soap12-part1/
- Protocol extension design: https://datatracker.ietf.org/doc/rfc6709/
- MCP draft versioning/extensions discussion: https://modelcontextprotocol.io/specification/draft/basic/versioning

### 6.3 Capability negotiation

Patterns that work:

1. **Discovery document** (Agent Card, `tools/list`, `server/discover`) advertises what the *provider* can do.
2. **Client render/accept set** (`acceptedOutputModes`, MCP client capabilities, bot `allowed_updates`) advertises what the *host* can do.
3. Intersection drives payload shaping **before** send when possible; after send, must-ignore + fallback still required for offline/old clients that never renegotiate.

### 6.4 Fallback-text-per-part and feature flags in discovery

- **Slack / MCP dual content:** human text is always present next to rich structure.
- **Per-part fallback** is stronger for multi-widget messages (each unknown widget still shows something).
- **Feature flags in discovery** (capabilities, extensions, skill modes) let new clients opt in without forcing old clients to parse new shapes—if the server **respects** the client’s declared set.

### 6.5 Failures (why things go wrong)

| Failure mode | Why it fails | Example pattern |
|--------------|--------------|-----------------|
| **Enum exhaustiveness in clients** | `switch(type)` without default → crash or empty | Strict codegen without “unknown” case |
| **Rich-only payloads** | New block with no text twin | Blocks without Slack `text` |
| **Silent semantic change** | Same field name, new meaning | Extension URI reuse without version bump (A2A forbids auto-fallback across extension versions) |
| **Required everything** | must-understand overuse | Required extensions for cosmetic UI |
| **Monolithic version gate** | Any new feature forces protocol major | Clients disconnect instead of skipping |
| **Kind-discriminator renames** | Breaking reshape of all parts | A2A v1.0 `kind` removal—correct long-term, painful without dual-read window |
| **Sessionful assumptions** | Horizontal scale + sticky state | MCP pre-2026 sessions (addressed by stateless RC) |
| **No discovery** | Client learns features only by failing | Trial-and-error tool calls |

`[unverified]` product anecdotes (specific broken third-party Slack/Telegram clients) are omitted; the table above is mechanism-level.

---

## Design rules for Vibe

Numbered rules for the AI-provider **wire contract** that renders inside Vibe (iOS-first). Each rule is justified by evidence above.

1. **Every renderable part MUST carry `fallbackText` (non-empty for user-visible parts).**  
   Slack’s top-level `text` and legacy attachment `fallback`, plus MCP’s dual text+structured rule, exist so limited surfaces never go blank. Vibe old builds and push notifications need the same.

2. **Unknown `part.kind` / content type: MUST-IGNORE the rich payload and MUST render `fallbackText` (or a message-level fallback).**  
   Never crash; never show an empty bubble. Telegram/Slack longevity comes from ignore-unknown + residual text.

3. **Keep a tiny core part vocabulary; put novelty in open discriminators + media types + extension metadata—not infinite first-class native enums in v1.**  
   A2A’s text/file/data (+ mediaType) and MCP’s small content `type` set scale better than redesigning the protocol for each widget.

4. **Negotiate capabilities from a discovery document against a client-declared render set.**  
   Agent Card modes / `acceptedOutputModes` (A2A), MCP capabilities, Apps feature-detect. Server SHOULD prefer shapes in the intersection when online; offline history still needs rule 1–2.

5. **Extensions and experimental UI are opt-in and optional by default (`required: false`).**  
   A2A only hard-fails on `required` extensions; OpenAI Apps treats host APIs as feature-detected. Cosmetic AI widgets must never be must-understand.

6. **Dual-publish: structured/widget data AND human text on every tool/provider result.**  
   MCP tools SHOULD return TextContent alongside `structuredContent`; Apps SDK examples always include text. Old Vibe versions read text only.

7. **Prefer per-part / per-extension versioning (URI or `schemaVersion`) over envelope majors for new feature types.**  
   Envelope versions (MCP date, A2A version) for transport/security breaks; feature growth via additive parts (Telegram, Slack blocks, A2A extension URIs).

8. **Breaking renames of discriminators require a dual-read window and explicit protocol version—not silent cutover.**  
   A2A’s `kind` → oneof migration shows how painful undocumented reshape is; plan deprecation ≥ one major or a time window (MCP’s ≥12 month deprecation policy is a good default).

9. **If supporting HTML/JS widgets (MCP Apps-style), sandbox them (iframe + CSP) and always show fallback text if the sandbox fails to load.**  
   MCP Apps and ChatGPT Apps document sandbox + bridge; empty iframe without text violates the product bar.

10. **Separate data tools from render tools when the model chooses UI.**  
    OpenAI Apps SDK decoupling pattern: fetch/compute without template; render tool attaches UI. Avoid remounting widgets and avoid baking presentation into every tool.

11. **Message envelope stays additive JSON: new fields optional; clients ignore unknown fields; servers never remove fields without a deprecation epoch.**  
    Telegram’s multi-year Bot API and RFC 6709 extension advice. Codegen must emit “unknown preserve/ignore” paths on iOS.

12. **Use must-understand only for safety-critical semantics (auth, payments, destructive actions)—never for richer chrome.**  
    SOAP/A2A `required` patterns; overusing them turns progressive enhancement into hard outages for old app versions.

---

## Quick comparison matrix

| System | Novelty channel | Fallback | Negotiation | Unknown handling |
|--------|-----------------|----------|-------------|------------------|
| **A2A** | mediaType + URI extensions | Implicit (text parts); no mandated per-part fallback | Agent Card + `acceptedOutputModes` + extension headers | Ignore optional extensions; error if required |
| **MCP** | content `type`, structuredContent, Apps UI resources | Text dual-write | protocolVersion + capabilities (+ 2026 extensions map) | Skip unknown types in practice; version mismatch disconnects |
| **Apps SDK** | UI resource + structuredContent | Text content | Host feature-detect + MCP | Degrade extensions; text remains |
| **Slack** | block `type` | Message `text` / attachment `fallback` | App scopes (not per-block) | Skip unknown blocks; use text |
| **Telegram** | new optional fields/types/methods | Classic `text` beside rich | `allowed_updates` (receive filter) | Ignore unknown fields |

---

## Sources (verified URLs)

- A2A specification: https://a2a-protocol.org/latest/specification/
- MCP 2025-06-18: https://modelcontextprotocol.io/specification/2025-06-18
- MCP lifecycle: https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle
- MCP tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- MCP Apps: https://modelcontextprotocol.io/docs/extensions/apps
- MCP 2026-07-28 RC: https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- OpenAI Apps SDK: https://developers.openai.com/apps-sdk
- ChatGPT UI / bridge: https://developers.openai.com/apps-sdk/build/chatgpt-ui
- MCP Apps in ChatGPT: https://developers.openai.com/apps-sdk/mcp-apps-in-chatgpt
- Apps in ChatGPT announcement: https://openai.com/index/introducing-apps-in-chatgpt/
- Slack messaging payloads: https://docs.slack.dev/messaging
- Slack Block Kit: https://docs.slack.dev/reference/block-kit/blocks
- Slack legacy attachments: https://docs.slack.dev/legacy/legacy-messaging/legacy-secondary-message-attachments
- Telegram Bot API: https://core.telegram.org/bots/api
- RFC 6709 (protocol extensions): https://datatracker.ietf.org/doc/rfc6709/
- SOAP mustUnderstand: https://www.w3.org/TR/soap12-part1/

---

*Research only. No product code changes. Unverified items are marked for follow-up against client source or internal Slack/Telegram client behavior notes if legal/product requires stronger guarantees.*
