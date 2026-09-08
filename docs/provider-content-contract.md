# Vibe Provider Content Contract — `vibe.content.v1`

**Audience:** engineers at OpenAI, Anthropic, xAI, and other providers who need to
render an assistant inside Vibe without lagging behind new surfaces.

**Status:** production contract (v1). Frozen names match the team board
(`.vibe/team/content-contract-0718-board.md`). Design rationale draws from
[`docs/research/research-extensible-contracts.md`](../docs/research/research-extensible-contracts.md)
and the 50-item union checklist in
[`docs/research/research-provider-surfaces.md`](../docs/research/research-provider-surfaces.md) §8.

**Related:** [Provider platform](provider-platform.md) (agent card, invoke/events),
[Agent payload shapes](agent-payload-shapes.md) (local agent CLI streams — separate
from this public content contract).

---

## 1. Overview + design rules

Vibe is a messenger host. Providers ship **content**, not a private UI stack.
`vibe.content.v1` is the versioned, part-based body that rides inside existing
invoke and events payloads as the `content` field. The core vocabulary is small on
purpose; novelty rides open `mediaType` values, reverse-DNS extension kinds, and
negotiated capabilities — not endless first-class native enums.

**Never lag** is enforced by three mechanisms working together:

1. **Dual-publish** — every user-visible part and the envelope always carry human text.
2. **Must-ignore-with-fallback** — unknown kinds/fields never crash; clients render `text`.
3. **Negotiated capabilities** — agent card advertises contract support; server MAY
   down-convert to the client’s render set.

### Frozen design rules

These six rules are normative. Validators and clients implement them verbatim.

| # | Rule | Rationale |
|---|------|-----------|
| **1** | Every part carries non-empty `text`; the envelope carries non-empty `fallbackText`. Dual-publish. | **Slack fallback** (message `text` / attachment `fallback`) and **MCP dual text + structuredContent** exist so notifications and old clients never go blank. |
| **2** | Clients MUST ignore unknown `kind` / fields and render the part’s `text` lane. Never blank, never crash. | **Telegram additive evolution** and **Slack unknown-block skip** prove ignore-unknown + residual text at messenger scale. |
| **3** | `required: true` ONLY for safety-critical semantics (auth, payment, destructive action). A client lacking support renders a **“needs newer app”** state, not silence. | **A2A required-extension** / SOAP mustUnderstand: reserve hard-fail for unsafe continuation, never for richer chrome. |
| **4** | Additive evolution: new capability = new declared name + optional part/ext. Envelope `contract` major bumps only for transport/security breaks. Per-part `schemaVersion` for feature growth. | **Telegram optional fields forever** + **MCP ≥12-month deprecation** + hybrid envelope/per-part versioning. |
| **5** | Negotiation: agent card `capabilities.contentContract = { "version": 1, "parts": [...], "ext": [...] }`; server MAY down-convert to the client’s render set; unknown ext never hard-fails unless `required`. | **A2A Agent Card + acceptedOutputModes** and **MCP capability maps** — discovery against client accept set. |
| **6** | Server validation rejects (422) only: missing/empty text lanes, unknown `contract` id, malformed part frame. It NEVER rejects unknown `kind` (that is the extension point). | Unknown kinds must **pass through** with their text lane so providers can ship ahead of host renders. |

---

## 2. Envelope + Part frame

### 2.1 Where it lives

`content` is placed on the existing provider **invoke** response body and on
**events** that deliver assistant-visible message material. Transport auth, chat
attachment, and streaming lifecycle remain as documented in
[provider-platform.md](provider-platform.md). This contract specifies only the
structured content document.

### 2.2 Envelope

```json
{
  "contract": "vibe.content.v1",
  "parts": [],
  "fallbackText": "Summary of this message for notifications and legacy clients."
}
```

| Field | Type | Required | Semantics |
|-------|------|----------|-----------|
| `contract` | string | **yes** | Must be exactly `"vibe.content.v1"` for this schema generation. Unknown values → 422. |
| `parts` | array of Part | **yes** | Ordered list of content units. May be empty only when `fallbackText` alone is meaningful (rare; prefer at least one `text` part). |
| `fallbackText` | string | **yes** | Whole-message plain text. Non-empty. Used for push notifications, watch/complication surfaces, search snippets, and any client that cannot walk `parts`. |

`fallbackText` SHOULD be a coherent summary of all parts, not a dump of every
button label. It MUST still make sense if no part is rendered richly.

### 2.3 Part frame (all kinds)

Every part shares this frame. Core kinds use simple `kind` strings; extensions use
reverse-DNS names (see §4).

```json
{
  "kind": "text",
  "schemaVersion": 1,
  "text": "Human-readable lane for this part.",
  "data": {},
  "mediaType": null,
  "url": null,
  "required": false,
  "ext": {}
}
```

| Field | Type | Required | Semantics |
|-------|------|----------|-----------|
| `kind` | string | **yes** | Core kind (`text`, `media`, `card`, `actions`, `status`, `citations`, `error`) **or** reverse-DNS extension kind (e.g. `com.openai.widget`). Unknown kinds are **not** validation errors. |
| `schemaVersion` | integer ≥ 1 | **yes** | Version of this part’s `data` / kind-specific schema. Defaults treated as `1` if omitted on read for dual-read windows; writers MUST emit it. |
| `text` | string | **yes** | Non-empty human-readable lane for **this** part. Rendered when the client does not understand `kind` or rich fields. |
| `data` | object | no | Kind-specific structured payload. Unknown keys inside `data` are ignored by clients (must-ignore). |
| `mediaType` | string \| null | no | RFC media type. Meaningful for `media` and for extensions that ship binary/structured blobs. Open set — novelty may ride here without a new core kind. |
| `url` | string \| null | no | Sealed blob reference via Vibe’s existing media pipeline (not an arbitrary hotlink unless the product media layer allows it). Media kinds only in core; extensions MAY reuse. |
| `required` | boolean | no | Default `false`. If `true`, clients that cannot render this part MUST show a **needs newer app** affordance instead of only the text lane (see §4.3). |
| `ext` | object | no | Map of reverse-DNS namespace → opaque object for vendor metadata that does not warrant a full extension `kind`. Clients ignore unknown namespaces. |

**Normative text-lane rule:** for every user-visible part, `text` MUST be non-empty
after trim. Status-only or machine-internal parts that would never appear in a
bubble still SHOULD set a short label in `text` so degrade paths stay safe.

---

## 3. Core kinds

Core kinds are stable, host-rendered primitives. Prefer them for table-stakes UX.
Put experimental or provider-branded UI in extension kinds (§4).

### 3.1 `text`

Markdown or plain body copy for the assistant turn (or a segment of it).

```json
{
  "kind": "text",
  "schemaVersion": 1,
  "text": "Global temperatures have risen by about 1.1°C since pre-industrial times.",
  "data": {
    "format": "markdown"
  },
  "required": false,
  "ext": {}
}
```

| `data` field | Type | Semantics |
|--------------|------|-----------|
| `format` | `"plain"` \| `"markdown"` | Default `"markdown"` if omitted. Plain disables emphasis parsing. |

**Vibe renders:** native text bubble; markdown subset (bold, italic, lists, links,
fenced code). Code fences get copy affordance.

**Degraded (no rich text):** show `text` as plain string (markdown source is still
readable). Envelope `fallbackText` for notifications.

---

### 3.2 `media`

Image, audio, video, or file attachment via the media pipeline.

```json
{
  "kind": "media",
  "schemaVersion": 1,
  "text": "Chart of temperature anomalies, 1880–2023 (PNG).",
  "mediaType": "image/png",
  "url": "vibe-blob://msg/abc123/chart.png",
  "data": {
    "caption": "Global temperature anomalies",
    "dimensions": { "width": 1200, "height": 800 },
    "durationMs": null,
    "fileName": "chart.png",
    "sizeBytes": 184320
  },
  "required": false,
  "ext": {}
}
```

| `data` field | Type | Semantics |
|--------------|------|-----------|
| `caption` | string | Optional overlay/caption under the media. |
| `dimensions` | `{ width, height }` | Pixels for images/video when known. |
| `durationMs` | number \| null | Audio/video duration. |
| `fileName` | string | Display name for downloads. |
| `sizeBytes` | number | Size hint for progress UI. |

**Vibe renders:** image viewer / audio player / video player / file chip with
download, using `mediaType` + `url`. Caption when present.

**Degraded:** show `text` (and optional tappable download if `url` is still
resolvable by the legacy media path). Never an empty bubble.

---

### 3.3 `card`

Rich summary card: product, source, meeting, listing, etc.

```json
{
  "kind": "card",
  "schemaVersion": 1,
  "text": "Mission loft — $4,200/mo — Open listing",
  "data": {
    "title": "Mission loft",
    "subtitle": "$4,200 / month",
    "imageUrl": "vibe-blob://msg/xyz/listing.jpg",
    "link": "https://example.com/listings/L1",
    "fields": [
      { "label": "Beds", "value": "2" },
      { "label": "Neighborhood", "value": "Mission" }
    ]
  },
  "required": false,
  "ext": {}
}
```

| `data` field | Type | Semantics |
|--------------|------|-----------|
| `title` | string | Primary heading. |
| `subtitle` | string | Secondary line (price, domain, status). |
| `imageUrl` | string | Optional hero image (blob or allowed URL). |
| `link` | string | Tap target (https or in-app deep link policy). |
| `fields` | `[{ label, value }]` | Key-value rows. |

**Vibe renders:** embed-style card with image, title, fields, open-link.

**Degraded:** single text line from `text` (title/subtitle/link folded into prose).

---

### 3.4 `actions`

Interactive controls under a message. Taps POST back to the provider on the
existing **events** path as:

```json
{
  "type": "action",
  "actionId": "<items[].id>",
  "messageId": "<host message id>"
}
```

```json
{
  "kind": "actions",
  "schemaVersion": 1,
  "text": "Choose: Approve deploy, Open runbook, or Pick train (Train A / Train B).",
  "data": {
    "items": [
      {
        "id": "approve",
        "label": "Approve deploy",
        "style": "primary",
        "kind": "button"
      },
      {
        "id": "runbook",
        "label": "Open runbook",
        "style": "default",
        "kind": "button"
      },
      {
        "id": "train",
        "label": "Pick train",
        "style": "default",
        "kind": "select",
        "options": [
          { "id": "a", "label": "Train A" },
          { "id": "b", "label": "Train B" }
        ]
      }
    ]
  },
  "required": false,
  "ext": {}
}
```

| `items[]` field | Type | Semantics |
|-----------------|------|-----------|
| `id` | string | Stable action id returned on the events callback. |
| `label` | string | Button or control label. |
| `style` | string | Presentation hint: `primary`, `default`, `danger`, … Clients map unknown styles to default. |
| `kind` | `"button"` \| `"select"` | Control type. |
| `options` | `[{ id, label }]` | Required when `kind` is `select`. |

**Vibe renders:** inline button row / select under the parent message; disabled
after one-shot if product rules require it.

**Degraded:** show `text` listing choices; user may reply in free text (provider
SHOULD accept natural-language equivalents).

---

### 3.5 `status`

Progress distinct from final answer content (thinking, tools, generation).

```json
{
  "kind": "status",
  "schemaVersion": 1,
  "text": "Searching the web for temperature records…",
  "data": {
    "state": "tool_running",
    "label": "Web search",
    "progress": 0.35
  },
  "required": false,
  "ext": {}
}
```

| `data` field | Type | Semantics |
|--------------|------|-----------|
| `state` | string | `"thinking"` \| `"tool_running"` \| `"generating"` \| `"done"` \| `"error"`. |
| `label` | string | Short UI label (tool name, step title). |
| `progress` | number 0–1 \| null | Optional determinate progress. |

**Vibe renders:** status chip / timeline row (Slack Thinking Steps–class UX),
often collapsed or replaced when a final `text`/`card` arrives with `state: "done"`.

**Degraded:** ephemeral `text` or typing indicator; may omit from permanent history
if the host only persists final content (host choice).

---

### 3.6 `citations`

Source list for grounded answers.

```json
{
  "kind": "citations",
  "schemaVersion": 1,
  "text": "Sources: Global Temperature Anomalies 2023 (climate.gov); IPCC AR6 SPM.",
  "data": {
    "items": [
      {
        "title": "Global Temperature Anomalies - 2023 Report",
        "url": "https://climate.gov/reports/2023-temperature",
        "snippet": "Global mean surface temperature anomaly of +1.1°C."
      },
      {
        "title": "IPCC AR6 Summary for Policymakers",
        "url": "https://www.ipcc.ch/report/ar6/syr/summary-for-policymakers/",
        "snippet": "Human influence has warmed the climate at a rate unprecedented in at least 2000 years."
      }
    ]
  },
  "required": false,
  "ext": {}
}
```

| `items[]` field | Type | Semantics |
|-----------------|------|-----------|
| `title` | string | Display title. |
| `url` | string | Openable source URL. |
| `snippet` | string | Optional excerpt. |

**Vibe renders:** citation chips or expandable source panel; domain display;
tap-to-open.

**Degraded:** `text` paragraph of sources (title + URL).

---

### 3.7 `error`

Structured failure: refusal, quota, tool failure, internal error.

```json
{
  "kind": "error",
  "schemaVersion": 1,
  "text": "I can't help with that request.",
  "data": {
    "code": "refusal",
    "message": "I can't help with that request.",
    "retryable": false
  },
  "required": false,
  "ext": {}
}
```

| `data` field | Type | Semantics |
|--------------|------|-----------|
| `code` | string | `"refusal"` \| `"quota"` \| `"tool_failed"` \| `"internal"`. Open for extension via unknown codes + `text`. |
| `message` | string | User-facing explanation (may match `text`). |
| `retryable` | boolean | Whether the host should offer Retry. |

**Vibe renders:** distinct error/refusal chrome; upgrade CTA optional for
`quota`; retry button when `retryable`.

**Degraded:** plain `text` (still never blank).

---

### 3.8 Multi-part example (full envelope)

```json
{
  "contract": "vibe.content.v1",
  "fallbackText": "Temperatures are up ~1.1°C since pre-industrial times. Chart attached. Sources on climate.gov and IPCC. Actions: Cite more / Explain uncertainty.",
  "parts": [
    {
      "kind": "status",
      "schemaVersion": 1,
      "text": "Research complete.",
      "data": { "state": "done", "label": "Deep research", "progress": 1.0 },
      "required": false,
      "ext": {}
    },
    {
      "kind": "text",
      "schemaVersion": 1,
      "text": "Global temperatures have risen by about **1.1°C** since pre-industrial times.",
      "data": { "format": "markdown" },
      "required": false,
      "ext": {}
    },
    {
      "kind": "media",
      "schemaVersion": 1,
      "text": "Temperature anomaly chart (PNG).",
      "mediaType": "image/png",
      "url": "vibe-blob://msg/abc/chart.png",
      "data": {
        "caption": "HadCRUT-style anomaly series",
        "fileName": "anomaly.png",
        "sizeBytes": 92000
      },
      "required": false,
      "ext": {}
    },
    {
      "kind": "citations",
      "schemaVersion": 1,
      "text": "Sources: climate.gov 2023 report; IPCC AR6 SPM.",
      "data": {
        "items": [
          {
            "title": "Global Temperature Anomalies - 2023",
            "url": "https://climate.gov/reports/2023-temperature",
            "snippet": "+1.1°C anomaly"
          }
        ]
      },
      "required": false,
      "ext": {}
    },
    {
      "kind": "actions",
      "schemaVersion": 1,
      "text": "Options: Cite more sources, or Explain uncertainty.",
      "data": {
        "items": [
          { "id": "cite_more", "label": "Cite more", "style": "default", "kind": "button" },
          { "id": "uncertainty", "label": "Explain uncertainty", "style": "default", "kind": "button" }
        ]
      },
      "required": false,
      "ext": {}
    }
  ]
}
```

---

## 4. Extension kinds

### 4.1 Namespacing

Extension `kind` values MUST be reverse-DNS, lowercase, at least two labels:

| Valid | Invalid |
|-------|---------|
| `com.openai.widget` | `widget` (collides with core namespace) |
| `com.anthropic.artifact` | `Artifact` |
| `ai.x.imagine.job` | `vibe.canvas` reserved — use `com.<vendor>.*` or future `vibe.*` only if Vibe publishes the kind |

Core kinds remain the short unnamespaced set in §3. Providers MUST NOT invent new
unnamespaced core kinds; add a reverse-DNS kind instead.

Optional metadata that does not need its own renderer MAY use part-level
`ext["com.example.ns"]` on a **core** part (must-ignore). Prefer a full extension
part when the unit should appear as its own block with its own text lane.

### 4.2 Worked example — widget with text lane

```json
{
  "contract": "vibe.content.v1",
  "fallbackText": "Dice roll: 4 on a 6-sided die. Update the app to see the interactive widget.",
  "parts": [
    {
      "kind": "com.openai.widget",
      "schemaVersion": 1,
      "text": "Showing a 6-sided roll: 4.",
      "data": {
        "template": "ui://widget/dice.html",
        "structuredContent": { "sides": 6, "value": 4 }
      },
      "required": false,
      "ext": {
        "com.openai.apps": {
          "outputTemplate": "ui://widget/dice.html"
        }
      }
    }
  ]
}
```

Hosts that implement a sandboxed widget runtime mount the template with
`structuredContent`. Hosts that do not still show **“Showing a 6-sided roll: 4.”**
from the part `text` lane (MCP Apps / dual-publish pattern).

### 4.3 `required` semantics and “needs newer app”

| `required` | Client supports kind? | Behavior |
|------------|----------------------|----------|
| `false` (default) | no | Render `text` only (and envelope `fallbackText` for non-thread surfaces). |
| `true` | no | Render a **needs newer app** state: clear copy that this message needs a newer Vibe build, plus `text` as secondary detail. Do **not** fail the whole chat thread. |
| either | yes | Render rich UI. |

Set `required: true` only when continuing with text alone would be **unsafe or
misleading** — e.g. payment confirmation, auth challenge, destructive approve.
Never mark a cosmetic map widget or chart as required.

Payment-critical commerce example:

```json
{
  "kind": "com.provider.checkout",
  "schemaVersion": 1,
  "text": "Pay $42.00 to Example Merchant for order #991. Open a newer Vibe or complete payment on the merchant site: https://merchant.example/pay/991",
  "data": {
    "amount": "42.00",
    "currency": "USD",
    "merchant": "Example Merchant",
    "orderId": "991",
    "handoffUrl": "https://merchant.example/pay/991"
  },
  "required": true,
  "ext": {}
}
```

### 4.4 What is not a content part

| Surface | Mechanism |
|---------|-----------|
| Full duplex realtime audio session | Roadmap `realtimeVoice.mode: "session"` + provider `sessionUrl` (see §5.3). **Not live.** |
| Live camera / screen into a voice session | Same future session channel; in-thread snapshots MAY use core `media`. |
| Long-running job lifecycle (research agent) | Prefer `status` parts for progress + final content parts; job ids MAY live in `ext` or events metadata. |
| Computer-use live frames | Extension kind for frames/screenshots **or** session channel; always dual-publish text/step log. |

**Voice call CTA (v1):** in-thread call buttons **are** content — the registered host
extension kind `vibe.call` (§5). Discovery is still a card capability
(`capabilities.realtimeVoice`), not a free-form session invent-your-own shape.

---

## 5. Voice and calls

v1 voice integration is deliberately **minimal**: declare voice on the agent, emit
one registered extension part, receive one webhook-style event when the user taps
“Call”. Providers adopt it the same way they already handle `actions` taps and
signed callbacks — no provider-side WebRTC stack required in v1.

### 5.1 Agent card: `capabilities.realtimeVoice`

Published agents advertise voice on the public card as a **sibling** of
`contentContract` (not nested inside it):

```json
{
  "capabilities": {
    "realtimeVoice": {
      "available": true,
      "mode": "callback"
    }
  }
}
```

| Field | Type | Semantics |
|-------|------|-----------|
| `available` | boolean | **Derived** from the agent’s configured `output_modes`: `true` when the list includes `"voice"`, else `false`. |
| `mode` | string | v1 is always `"callback"`. Full duplex session negotiation is roadmap only (`"session"` — see §5.3). |

Hosts and directories SHOULD treat a missing `realtimeVoice` object as
`{ "available": false }` (no voice CTA expectation). When `available` is `true` and
`mode` is `"callback"`, clients MAY render `vibe.call` parts as native call
buttons and deliver `call.requested` on tap (§5.2).

**Status:** card shape and derivation from `output_modes` are part of the frozen
Wave-2 contract (wired on the agent-card path with the content-contract work).
Always dual-publish a text lane on any call part so older clients never go blank.

### 5.2 Registered ext part: `vibe.call`

`vibe.call` is a **host-registered** extension kind (listed in
`Vibe.ProviderContent.capabilities()["ext"]`). It is not a reverse-DNS vendor kind;
it is the only un-namespaced voice CTA Vibe renders natively in v1.

**Part shape (exact):**

```json
{
  "kind": "vibe.call",
  "schemaVersion": 1,
  "text": "Tap to start a voice call with this assistant.",
  "data": {
    "label": "Call now",
    "mode": "voice"
  },
  "required": false
}
```

| Field | Required | Semantics |
|-------|----------|-----------|
| `kind` | **yes** | Must be exactly `"vibe.call"`. |
| `text` | **yes** | Non-empty call-to-action / degrade copy (rule 1). Older clients render this lane only. |
| `data.label` | recommended | Button label shown on the native call control (e.g. `"Call now"`). Hosts MAY fall back to a default label or to `text` if omitted. |
| `data.mode` | recommended | `"voice"` for audio call CTA. Unknown modes MUST degrade to the text lane (must-ignore). |
| `schemaVersion` | **yes** | Start at `1`. |
| `required` | no | Default `false`. Do **not** set `required: true` for a cosmetic call button — text-lane degrade is correct for older apps. |

**Full envelope example:**

```json
{
  "contract": "vibe.content.v1",
  "fallbackText": "I can talk this through live — tap Call now, or reply here in text.",
  "parts": [
    {
      "kind": "text",
      "schemaVersion": 1,
      "text": "I can talk this through live if that is easier.",
      "data": { "format": "plain" },
      "required": false
    },
    {
      "kind": "vibe.call",
      "schemaVersion": 1,
      "text": "Start a voice call with this assistant.",
      "data": {
        "label": "Call now",
        "mode": "voice"
      },
      "required": false
    }
  ]
}
```

#### Rendering (native clients)

Clients that implement the parts renderer show Vibe’s **native call button** in the
message (prominent control, label from `data.label`). The control is host chrome —
providers do not ship a custom call UI kit for v1.

#### Tap flow (callback mode)

1. User taps the call button.
2. Vibe opens its **existing call surface** (host AI-call UI).
3. Vibe notifies the provider on the **existing events / callback path** with:

```json
{
  "type": "call.requested",
  "chatId": "<vibe chat id>",
  "agentId": "<agent id>"
}
```

This is the same class of outbound notification as action taps
(`{ "type": "action", "actionId", "messageId" }`): webhook / events-path delivery
your backend already knows how to receive. The provider does **not** negotiate
media; it learns that the user asked to call and may answer, log, or start its own
side of the conversation via normal invoke/events.

#### Degraded rendering (older clients)

Clients that do not know `vibe.call` **must ignore** the unknown kind and render
the part’s `text` lane (and envelope `fallbackText` for non-thread surfaces).
Server degrade (`to_message_attrs`) also folds the part into the joined text body
so pre-parts clients still see the call-to-action as plain copy — never a blank
bubble (rules 1–2).

#### Two-line integration story

1. Put `"voice"` in the agent’s `output_modes` so the card publishes
   `realtimeVoice.available: true` with `mode: "callback"`.
2. When you want an in-thread call CTA, send one `vibe.call` part (with non-empty
   `text`) inside a normal `vibe.content.v1` envelope; handle
   `{ "type": "call.requested", "chatId", "agentId" }` on your callback / events
   consumer.

That is the entire v1 surface: **one part + one webhook event**.

### 5.3 Roadmap — `mode: "session"` (NOT implemented)

A future card shape may advertise full duplex realtime negotiation:

```json
{
  "capabilities": {
    "realtimeVoice": {
      "available": true,
      "mode": "session"
    }
  }
}
```

In that mode, providers would supply a `sessionUrl` (WebRTC or WebSocket endpoint)
for host–provider media negotiation. **This is roadmap only.** Do not emit
`mode: "session"`, do not invent `sessionUrl` fields in production traffic, and do
not document provider WebRTC setup as a live Vibe integration path until a later
board freezes and ships it. Until then, `mode` remains `"callback"` and media stays
on Vibe’s call surface.

---

## 6. Negotiation

### 6.1 Agent card field

Published agents advertise support on the public agent card under
`capabilities.contentContract` (alongside existing flags such as `streaming`,
`events`, and `realtimeVoice` — see [provider-platform.md](provider-platform.md)
and §5).

```json
{
  "capabilities": {
    "streaming": true,
    "pushNotifications": true,
    "events": ["message", "action", "call.requested"],
    "realtimeVoice": {
      "available": true,
      "mode": "callback"
    },
    "contentContract": {
      "version": 1,
      "parts": [
        "text",
        "media",
        "card",
        "actions",
        "status",
        "citations",
        "error"
      ],
      "ext": [
        "vibe.call",
        "com.openai.widget",
        "com.anthropic.artifact"
      ]
    }
  }
}
```

| Field | Meaning |
|-------|---------|
| `version` | Contract generation (`1` for `vibe.content.v1`). |
| `parts` | Core kinds the **provider** may emit and expects the host to understand. |
| `ext` | Extension kinds the provider may emit (declaration, not a hard allowlist for validation). Host-registered kinds such as `vibe.call` appear here when supported. |
| `realtimeVoice` | Sibling capability object: `{ "available": boolean, "mode": "callback" }` in v1. Derived from `output_modes` including `"voice"`. See §5. |

Server’s own descriptor is exposed via `Vibe.ProviderContent.capabilities/0` for
card builders and diagnostics.

### 6.2 Client render sets

Clients (iOS / web) maintain a **render set**: core kinds they implement +
extension kinds they implement. Online, the host SHOULD:

1. Intersect provider-declared kinds with client render set.
2. Prefer shapes in the intersection when shaping or **down-converting**.
3. Always retain dual text so offline/history clients that never renegotiated still work.

### 6.3 Server down-convert

When the server knows the destination client’s render set (or when degrading for
legacy storage), it MAY rewrite:

| Input | Down-convert |
|-------|----------------|
| Known core kinds | Pass through; optionally flatten for storage. |
| Unknown / unsupported ext | Drop rich `data`; keep `text` part or fold into message body. |
| `media` | Map to existing media attachment shape. |
| Full envelope | `to_message_attrs`: join text lanes for body; attachments from `media`; other kinds → text. |

Down-convert is how **current iOS/web render v1 content with zero client changes**
on day one: legacy clients only ever see text + attachments.

### 6.4 Failure modes

| Situation | Result |
|-----------|--------|
| Client lacks optional ext | Text lane / fallbackText |
| Client lacks `required` part | Needs newer app UI |
| Server receives unknown core-looking kind | Pass through (not 422) |
| Provider omits `contentContract` on card | Host assumes text-only dual-publish discipline still applies if envelope is sent |

---

## 6a. Streaming messages (`message.stream`)

Providers stream responses as **progressive message edits** over the existing events
ingress — no new transport, and every current client already renders it.

```json
POST /api/agents/:identifier/events
{
  "eventType": "message.stream",
  "destinationChatId": "<chat>",
  "streamId": "<provider-unique per message>",
  "seq": 3,
  "text": "<FULL accumulated text so far — never a delta>",
  "content": { "...optional vibe.content.v1 envelope on the final frame..." },
  "done": false
}
```

Rules: frames carry the **full accumulated text** (idempotent — lost or reordered
frames are harmless; `seq` <= last-seen is ignored). The first frame creates the
message with `metadata.streaming = true`; later frames edit it in place; `done: true`
finalizes, removes the streaming flag, and (when a `content` envelope is present)
validates it and attaches `metadata.content` with the envelope text lanes winning.
Send at most ~4 frames/second. A `done`-only frame for an unknown `streamId` is
treated as create-and-finalize. The agent card advertises this via
`capabilities.streaming: true`.

## 7. Coverage map

Proof that the contract can express the research union checklist
([research-provider-surfaces.md](../docs/research/research-provider-surfaces.md) §8)
without “lacking a feature.” Items map to a **kind**, **capability**, **host
mechanism**, or **extension point**.

### 7.1 Table-stakes (§8.1 items 1–15)

| # | Capability | How `vibe.content.v1` / platform expresses it |
|---|------------|-----------------------------------------------|
| 1 | Streaming text with stop/cancel | `text` parts (and progressive replace of message body) + invoke/stream lifecycle on agent card `capabilities.streaming` / events; stop is host control channel, not a content kind. |
| 2 | Typing / generating / tool-running status | Core kind `status` (`thinking`, `tool_running`, `generating`, …). |
| 3 | Multimodal attachments **in** | Host attach pipeline + invoke input modes (`defaultInputModes`); not output content — inputs stay outside this envelope or as referenced blobs. |
| 4 | Multimodal attachments **out** | Core kind `media` (`mediaType` + `url` + caption/meta). |
| 5 | Code blocks + copy | Core kind `text` with `format: "markdown"` fenced code; host copy chrome. |
| 6 | Citations / source links | Core kind `citations`. |
| 7 | Message regenerate + edit-and-resubmit | Host message versioning + re-invoke; content contract carries replacement envelopes for new samples. |
| 8 | Thumbs up/down feedback | Host feedback events (not a render part); optional future ext metadata. |
| 9 | Assistant identity | Agent card + participant chrome (name, avatar, provider); outside content parts. |
| 10 | Per-chat / per-user consent for tools, memory, media | Platform security model (attachment, autonomy, consent UX); not a content kind. |
| 11 | Error / refusal / quota structured outcomes | Core kind `error` (`refusal`, `quota`, `tool_failed`, `internal`). |
| 12 | Threading or reply-context | Host thread/reply IDs on transport; content parts nest under the reply message. |
| 13 | Group mention-gating / bot policies | Host group policy; card + chat attachment rules. |
| 14 | Link previews / basic rich cards | Core kind `card`. |
| 15 | Downloadable file results | Core kind `media` with file `mediaType` / `fileName` / `sizeBytes`. |

### 7.2 Differentiators (§8.2 items 16–32)

| # | Capability | Extension / mechanism |
|---|------------|------------------------|
| 16 | Side workspace / Canvas / Artifacts pane | Ext part (e.g. `com.openai.canvas`, `com.anthropic.artifact`) + future host pane binding; always dual-publish `text` / exportable `media`. |
| 17 | Interactive widgets / embedded apps | Ext part (`com.openai.widget`, …) + sandboxed runtime; dual text (MCP Apps pattern). |
| 18 | Realtime duplex voice | Card `capabilities.realtimeVoice` (`available` from `output_modes` ⊇ `"voice"`, v1 `mode: "callback"`) + registered ext part `vibe.call` (native call button → `call.requested` on events/callback). Full duplex `mode: "session"` + `sessionUrl` = roadmap only (§5). |
| 19 | Live camera / screen share into session | Same voice mechanism for the call CTA; live camera/screen media rides the **roadmap** session channel (`mode: "session"`). In-thread still frames MAY use core `media`. |
| 20 | Sandboxed code execution result types | `media` (charts/files) + `text` (tables/stdout) + optional ext for structured tables; `status` for run state. |
| 21 | Connectors / OAuth tool framework | Platform connector + consent; tool progress via `status`; results as core/ext parts. |
| 22 | User-visible memory management | Host settings / memory API; not content parts (optional card links). |
| 23 | Long-running research/agent jobs | `status` progress + final `text`/`citations`/`media`; job id in events metadata or `ext`. |
| 24 | Computer-use / browser-use sessions | Ext parts for step screenshots + `status` action log; takeover via host session UX; sensitive steps may use `required`. |
| 25 | Extended thinking / step timeline UI | `status` timeline and/or ext part for rich traces; collapsible host UI. |
| 26 | Custom assistant install (GPT/Gem/agent) | Agent card + directory; identity outside content. |
| 27 | Share / publish / remix of canvases/artifacts | Ext part metadata + host share links; export as `media`/`text`. |
| 28 | Commerce: product cards + checkout handoff | `card` for discovery; ext part for checkout; `required: true` when payment-critical. |
| 29 | Proactive notifications for finished jobs | Push + events delivering a full content envelope with `fallbackText`. |
| 30 | Declarative interactive components | Core `actions` for buttons/selects; ext for modals/forms beyond v1. |
| 31 | Secure webview / mini-app runtime | Ext part pointing at mini-app URL/resource + sandbox host; dual text. |
| 32 | Image + short video generation job UX | `status` while generating + final `media`; optional ext for job controls. |

### 7.3 Emerging (§8.3 items 33–50)

| # | Capability | Extension / mechanism |
|---|------------|------------------------|
| 33 | In-thread agentic checkout / ACP-style commerce | Ext part (commerce/ACP namespace) + `required` for pay-critical steps; handoff URL in `text`. |
| 34 | Multi-agent orchestration in one thread | Multiple agent participants + per-agent envelopes; host orchestration metadata. |
| 35 | Shared multi-user artifacts with CRDT-like edits | Ext part + collaborative pane session (future); text snapshots for lag clients. |
| 36 | Persistent mini-app storage | Ext part + host/provider storage grant; not core. |
| 37 | Live HTML/React apps with per-viewer model billing | Widget/artifact ext + billing outside content; dual text. |
| 38 | Desktop OS control via local companion | Capability + session channel; `status`/ext for action audit in-thread. |
| 39 | Voice clones / multi-voice personas | Same §5 voice path: `realtimeVoice` + `vibe.call` CTA; persona/voice id on agent card skills / config (`voiceProfile` and related settings), not a separate content kind. Session-mode voice params remain roadmap. |
| 40 | Music generation / long-form audio overviews | `media` with audio `mediaType`; `status` for long gen. |
| 41 | Meeting-native assist | Ext part for meeting artifacts + `text` recap; host meeting context. |
| 42 | Enterprise audit trails of agent GUI actions | Host/admin logs; optional `status`/ext audit summaries in chat. |
| 43 | Ephemeral / viewer-only messages | Transport visibility flag (host); content envelope unchanged. |
| 44 | Inline query mode (`@assistant find…`) | Host inline-query protocol; results as `card`/`text` envelopes. |
| 45 | Subscription entitlements inside chat apps | Ext part + payment `required` where needed; host entitlement state. |
| 46 | Human agent handoff queues | Ext or `status` handoff state + `text`; host queue integration. |
| 47 | Cross-provider memory portability | Memory export API (platform); not a render kind. |
| 48 | On-device / private compute tool routing | Capability flags (`e2e_compatible` / local tools) + results as normal parts. |
| 49 | Real-time collaborative agent + human co-editing | Canvas/artifact ext + session ops; snapshot `text`/`media` for history. |
| 50 | Safety classifiers / consent for computer use & payments | Host consent prompts + `required` ext/parts for sensitive confirms; `error` for refusal. |

**Count:** 50 / 50 rows. Nothing in the research union is “unrepresentable”: it is
either a core kind, a reverse-DNS ext part, a session/capability channel, or
host/platform policy outside the content document.

---

## 8. Versioning + deprecation policy

### 8.1 Envelope contract id

- Current: `vibe.content.v1`.
- **Major** `contract` string changes only for transport or security breaks that
  cannot degrade (e.g. encryption of part payloads).
- New core kinds, new optional fields, and new extension kinds do **not** bump the
  envelope major. They are additive (Telegram-style optional growth).

### 8.2 Per-part `schemaVersion`

- Each part carries `schemaVersion` (integer, start at `1`).
- Additive fields within a kind: keep the same `schemaVersion` when old clients can
  ignore new keys safely.
- Semantic breaks within a kind: increment `schemaVersion`; document dual-read
  rules for at least one deprecation window.

### 8.3 Additive rules (normative)

1. Servers and clients **ignore unknown fields** on envelope and parts.
2. Servers **never remove** a field without a published deprecation epoch.
3. New core kinds require a host release + card `parts` advertisement; until then
   providers SHOULD emit them only as reverse-DNS ext kinds or dual-publish pure text.
4. Extension kinds version independently (URI- or DNS-shaped names MAY include a
   version label, e.g. `com.example.widget.v2`, when a clean cut is needed).

### 8.4 Deprecation window

- Minimum **≥ 12 months** between deprecation announcement and earliest removal
  (MCP feature lifecycle model).
- Renames of discriminators or fields require a **dual-read** period: accept old
  and new names; emit new; document stop-emit date for the old name.
- Silent semantic change of an existing field name is forbidden (A2A lesson on
  extension URI reuse).

### 8.5 Provider guidance

Prefer shipping new surfaces as:

1. Extension kind + text lane today, then  
2. Optional promotion to core in a later minor host release, with dual support.

---

## 9. Validation

Implemented by `Vibe.ProviderContent.parse/1` (see team board). HTTP mapping for
provider ingress: **422** with body:

```json
{
  "error": "invalid_content",
  "detail": "<machine-readable reason>"
}
```

### 9.1 Reject (422)

| Case | Example `detail` |
|------|------------------|
| Missing or unknown `contract` | `unknown_contract` |
| `contract` not exactly `vibe.content.v1` | `unknown_contract` |
| Missing / empty / whitespace-only `fallbackText` | `empty_fallback_text` |
| `parts` not an array | `malformed_parts` |
| Part not an object | `malformed_part` |
| Part missing `kind` or `kind` not a string | `malformed_part_kind` |
| Part missing `text` or `text` empty/whitespace | `empty_part_text` |
| Frame types wrong in a hard way (e.g. `required` not boolean when present, `schemaVersion` not integer when present) | `malformed_part_frame` |

Validators MAY coerce mild shape issues (e.g. default `schemaVersion` to `1`,
default `required` to `false`) **only** when the board/implementation explicitly
allows normalization; after normalization, the text-lane and contract rules still
apply.

### 9.2 Pass (do not reject)

| Case | Behavior |
|------|----------|
| Unknown `kind` (including reverse-DNS never seen before) | Accept; preserve part with `text` for pass-through / down-convert. |
| Unknown keys on envelope or part | Accept; ignore or preserve as opaque. |
| Unknown `data` fields for a known kind | Accept; clients ignore. |
| Empty `data` / omitted `mediaType` / `url` on non-media | Accept. |
| `required: true` on any kind | Accept; clients enforce UX, not the content validator. |
| Extra core-looking kinds not in the v1 table | Accept as unknown kinds (pass-through). |

### 9.3 Downstream degradation (not validation)

`to_message_attrs/1` turns a normalized document into today’s message
representation:

- Concatenate / prefer text lanes for body.
- Map `media` → existing attachment records.
- Everything else → text lane contribution.
- Envelope `fallbackText` as last-resort body if parts yield nothing useful.

This path is the day-one **don’t lag** mechanism for clients that have not yet
shipped a parts renderer.

---

## 10. Quick provider checklist

1. Emit `contract: "vibe.content.v1"` with non-empty `fallbackText`.
2. Prefer core kinds for table-stakes UI; put novelty in reverse-DNS ext parts
   (or host-registered kinds such as `vibe.call`).
3. Every part: non-empty `text` + `schemaVersion`.
4. Use `required: true` only for auth / payment / destructive must-understand.
5. Declare `capabilities.contentContract` on the agent card.
6. For voice (v1 callback mode): include `"voice"` in `output_modes` (card
   publishes `realtimeVoice: { available, mode: "callback" }`); emit a `vibe.call`
   part with non-empty `text`; handle `call.requested` on your events/callback
   path. Do **not** invent provider `sessionUrl` / `mode: "session"` until that
   roadmap ships (§5.3).
7. Always dual-publish: rich structure **and** human text.

---

## 11. Document control

| Item | Value |
|------|--------|
| Contract id | `vibe.content.v1` |
| Filename | `docs/provider-content-contract.md` (stable; no dates in name) |
| Authoritative freeze | `.vibe/team/content-contract-0718-board.md` |
| Research inputs | `docs/research/research-extensible-contracts.md`, `docs/research/research-provider-surfaces.md` |
| Server module | `Vibe.ProviderContent` (`parse`, `to_message_attrs`, `capabilities`) |

When this document and the board disagree, **the board wins** until the board is
explicitly revised; then update this file to match.
