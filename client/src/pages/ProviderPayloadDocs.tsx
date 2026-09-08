import { useNavigate } from 'react-router-dom';
import DocsShell from '../components/docs/DocsShell';
import {
    DocSection,
    DocH2,
    DocH3,
    DocP,
    DocCallout,
    DocCodeBlock,
    DocCompareTable,
    DocList,
} from '../components/docs/DocComponents';
import { providerDocsTabs } from './ProviderDocs';
import './ProviderDocs.css';

const sections = [
    { id: 'two-lane', label: 'Two-lane principle' },
    { id: 'envelope', label: 'Envelope' },
    { id: 'part-frame', label: 'Part frame' },
    { id: 'core-kinds', label: 'Core kinds' },
    { id: 'extensions', label: 'Extensions' },
    { id: 'voice-calls', label: 'Voice & calls' },
    { id: 'negotiation', label: 'Negotiation' },
    { id: 'coverage', label: 'Capability coverage' },
    { id: 'coding-profile', label: 'Coding-agent profile' },
    { id: 'deeper', label: 'Deeper study' },
];

/* ── vibe.content.v1 (frozen board contract) ─────────────────────────── */

const envelopeExample = `{
  "contract": "vibe.content.v1",
  "parts": [ <Part>, ... ],
  "fallbackText": "<whole-message plain text — REQUIRED>"
}`;

const partFrameExample = `{
  "kind": "<core kind or namespaced ext kind>",
  "schemaVersion": 1,
  "text": "<human-readable text lane for THIS part — REQUIRED, non-empty for user-visible parts>",
  "data": { },
  "mediaType": "<RFC mime, media kinds only>",
  "url": "<sealed blob ref via existing media pipeline, media kinds only>",
  "required": false,
  "ext": { "<reverse-dns-namespace>": { } }
}`;

const textPartExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Disk pressure on db-2 is the highest-priority open alert.",
  "parts": [
    {
      "kind": "text",
      "schemaVersion": 1,
      "text": "Disk pressure on **db-2** is the highest-priority open alert.",
      "data": { "format": "markdown" },
      "required": false
    }
  ]
}`;

const mediaPartExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Here is the dashboard snapshot for the last hour. CPU peaked at 92% around 14:02 UTC.",
  "parts": [
    {
      "kind": "media",
      "schemaVersion": 1,
      "text": "Dashboard snapshot — last hour (CPU peaked at 92% around 14:02 UTC)",
      "mediaType": "image/png",
      "url": "vibe-media://blobs/7f3a9c2e-dashboard.png",
      "data": {
        "caption": "Ops dashboard — last 60 minutes",
        "dimensions": { "width": 1200, "height": 675 },
        "fileName": "dashboard-last-hour.png",
        "sizeBytes": 184320
      },
      "required": false
    },
    {
      "kind": "text",
      "schemaVersion": 1,
      "text": "CPU peaked at 92% around 14:02 UTC. I can open the full runbook if you want next steps.",
      "data": { "format": "plain" },
      "required": false
    }
  ]
}`;

const cardPartExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Acme Pro plan — $49/mo. Includes priority support and 10 seats.",
  "parts": [
    {
      "kind": "card",
      "schemaVersion": 1,
      "text": "Acme Pro plan — $49/mo. Includes priority support and 10 seats.",
      "data": {
        "title": "Acme Pro",
        "subtitle": "$49 / month",
        "imageUrl": "https://cdn.acme.example/plans/pro.png",
        "link": "https://acme.example/pricing/pro",
        "fields": [
          { "label": "Seats", "value": "10" },
          { "label": "Support", "value": "Priority" }
        ]
      },
      "required": false
    }
  ]
}`;

const actionsPartExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Approve the deploy to production, or request changes.",
  "parts": [
    {
      "kind": "text",
      "schemaVersion": 1,
      "text": "Staging looks green. Ready to deploy release **v2.14.0** to production?",
      "data": { "format": "markdown" },
      "required": false
    },
    {
      "kind": "actions",
      "schemaVersion": 1,
      "text": "Choose: Approve deploy, Request changes, or Cancel.",
      "data": {
        "items": [
          { "id": "approve_deploy", "label": "Approve deploy", "style": "primary", "kind": "button" },
          { "id": "request_changes", "label": "Request changes", "style": "secondary", "kind": "button" },
          { "id": "cancel", "label": "Cancel", "style": "danger", "kind": "button" }
        ]
      },
      "required": false
    }
  ]
}`;

const statusPartExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Searching open alerts… (about 40% complete)",
  "parts": [
    {
      "kind": "status",
      "schemaVersion": 1,
      "text": "Searching open alerts… (about 40% complete)",
      "data": {
        "state": "tool_running",
        "label": "Search open alerts",
        "progress": 0.4
      },
      "required": false
    }
  ]
}`;

const citationsPartExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Three sources report elevated disk usage on db-2 overnight. See the links below for details.",
  "parts": [
    {
      "kind": "text",
      "schemaVersion": 1,
      "text": "Three sources report elevated disk usage on **db-2** overnight.",
      "data": { "format": "markdown" },
      "required": false
    },
    {
      "kind": "citations",
      "schemaVersion": 1,
      "text": "Sources: Ops runbook §4, PagerDuty incident PD-4412, Grafana disk panel.",
      "data": {
        "items": [
          {
            "title": "Ops runbook — disk pressure",
            "url": "https://runbooks.acme.example/disk-pressure",
            "snippet": "When free space drops below 15%, page on-call and scale storage."
          },
          {
            "title": "PagerDuty PD-4412",
            "url": "https://acme.pagerduty.com/incidents/PD-4412",
            "snippet": "Triggered 02:14 UTC — disk free 11% on db-2."
          },
          {
            "title": "Grafana — db-2 disk",
            "url": "https://grafana.acme.example/d/db2-disk",
            "snippet": "Used bytes trending up since 22:00 UTC."
          }
        ]
      },
      "required": false
    }
  ]
}`;

const errorPartExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "I can't help with that request. It asks for credentials that would let someone impersonate another user.",
  "parts": [
    {
      "kind": "error",
      "schemaVersion": 1,
      "text": "I can't help with that request. It asks for credentials that would let someone impersonate another user.",
      "data": {
        "code": "refusal",
        "message": "Request declined: credential exfiltration / impersonation.",
        "retryable": false
      },
      "required": false
    }
  ]
}`;

const widgetExtExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Interactive playlist widget: Chill Focus — 12 tracks. Open in Spotify if the widget is unavailable.",
  "parts": [
    {
      "kind": "com.spotify.playlist_widget",
      "schemaVersion": 1,
      "text": "Chill Focus — 12 tracks. Open in Spotify if the widget is unavailable.",
      "required": false,
      "data": {
        "playlistId": "37i9dQZF1DX4sWSpwq3LiO",
        "title": "Chill Focus",
        "trackCount": 12
      },
      "ext": {
        "com.spotify": {
          "template": "playlist_embed_v2",
          "theme": "dark"
        }
      }
    }
  ]
}`;

const contentContractCardSnippet = `{
  "capabilities": {
    "streaming": true,
    "pushNotifications": false,
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
        "com.spotify.playlist_widget",
        "com.acme.checkout_card"
      ]
    }
  }
}`;

const vibeCallPartExample = `{
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
}`;

const callRequestedCallbackExample = `{
  "type": "call.requested",
  "chatId": "73928163c120",
  "agentId": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
}`;

/* ── Coding-agent profile (existing specialized surface) ─────────────── */

const agentStreamExample = `{
  "text": "Checking open alerts and drafting a summary…",
  "progressNodes": [
    {
      "id": "tool-1",
      "kind": "search",
      "label": "Search open alerts",
      "status": "running"
    }
  ],
  "toolEvents": [],
  "status": "running"
}`;

const settledResultExample = `{
  "text": "There are 3 open alerts. Highest priority is disk pressure on db-2.",
  "progressNodes": [
    {
      "id": "think-1",
      "kind": "thinking",
      "label": "Thought for 2s",
      "status": "done"
    },
    {
      "id": "tool-1",
      "kind": "search",
      "label": "Search open alerts",
      "status": "done",
      "detail": "query=status:open"
    },
    {
      "id": "tool-2",
      "kind": "read",
      "label": "Read alert-db-2.json",
      "status": "done"
    }
  ],
  "toolEvents": [],
  "status": "done"
}`;

const claudeBlocks = `// Claude stream-json content blocks (provider / bridge side)
{ "type": "text", "text": "…" }
{ "type": "thinking", "thinking": "…", "signature": "…" }
{ "type": "tool_use", "id": "toolu_…", "name": "Read", "input": { "file_path": "…" } }
{ "type": "tool_result", "tool_use_id": "toolu_…", "content": "…" }`;

const grokLines = `// Grok streaming-json (stdout) + bridge-injected tools
{"type":"thought","data":"…"}
{"type":"text","data":"…"}
{"type":"tool_use","id":"call-…","name":"read_file","input":{"target_file":"…"},"status":"running"}
{"type":"tool_result","tool_use_id":"call-…","content":"…","is_error":false,"status":"done"}
{"type":"end","stopReason":"EndTurn","sessionId":"…"}`;

const codexItems = `// Codex exec --json thread items (inside item.started / item.completed)
{ "item_type": "agent_message", "text": "…" }
{ "item_type": "reasoning", "text": "…" }
{ "item_type": "command_execution", "command": "…", "exit_code": 0, "status": "completed" }
{ "item_type": "file_change", "changes": [{ "path": "a.ts", "kind": "update" }], "status": "completed" }
{ "item_type": "mcp_tool_call", "server": "…", "tool": "…", "status": "completed" }`;

export default function ProviderPayloadDocs() {
    const navigate = useNavigate();

    return (
        <DocsShell
            sidebarLabel="Providers"
            eyebrow="Providers"
            title="Payload contract"
            intro="The vibe.content.v1 parts model — structured content for rich rendering, mandatory text lanes so nothing ever renders blank, and extensions so new provider surfaces ship without waiting on a Vibe app update."
            tabs={providerDocsTabs}
            sections={sections}
        >
            <DocSection id="two-lane">
                <DocH2>Two-lane principle</DocH2>
                <DocP>
                    Every assistant turn in Vibe rides two lanes at once. The <strong>structured lane</strong>{' '}
                    is a list of typed parts — text, media, cards, actions, status, citations, errors, and
                    namespaced extensions. The <strong>text lane</strong> is mandatory on every part and on
                    the envelope as <code>fallbackText</code>. Clients that understand a part render it
                    richly; clients that do not fall back to the text and never show a blank bubble.
                </DocP>
                <DocList items={[
                    <><strong>Structured parts</strong> — drive native cards, media, buttons, progress, and future widgets.</>,
                    <><strong>Mandatory text</strong> — every part and the envelope carry human-readable copy. Dual-publish is not optional.</>,
                    <><strong>Ship features without app lag</strong> — new provider surfaces land as extension kinds (or declared capabilities). Old clients ignore unknown kinds and keep the text lane.</>,
                ]} />
                <DocCallout type="note">
                    The content envelope rides inside the existing invoke / events message body as{' '}
                    <code>content</code>. Server validation rejects missing text lanes and malformed frames,
                    never unknown <code>kind</code> values — that is the extension point.
                </DocCallout>
            </DocSection>

            <DocSection id="envelope">
                <DocH2>Envelope</DocH2>
                <DocP>
                    Versioned content is a single object: contract id, ordered parts, and a whole-message
                    plain-text fallback. Clients always have something to show even if every part is unknown.
                </DocP>
                <DocCodeBlock lang="json" code={envelopeExample} />
                <DocList items={[
                    <><code>contract</code> — must be <code>&quot;vibe.content.v1&quot;</code> for this generation. Major bumps only for transport or security breaks.</>,
                    <><code>parts</code> — ordered list of part objects (may be empty only when <code>fallbackText</code> alone is enough, but prefer at least one part).</>,
                    <><code>fallbackText</code> — required, non-empty plain text for the entire turn.</>,
                ]} />
            </DocSection>

            <DocSection id="part-frame">
                <DocH2>Part frame</DocH2>
                <DocP>
                    All kinds — core and extension — share the same frame. Novelty rides in{' '}
                    <code>kind</code>, <code>data</code>, <code>mediaType</code>, and <code>ext</code>, not in
                    a new top-level shape.
                </DocP>
                <DocCodeBlock lang="json" code={partFrameExample} />
                <DocCompareTable
                    columns={['Field', 'Rules']}
                    rows={[
                        ['`kind`', 'Core name (`text`, `media`, …) or reverse-dns extension (`com.openai.widget`)'],
                        ['`schemaVersion`', 'Per-part integer; additive evolution within a major contract'],
                        ['`text`', 'Required non-empty for user-visible parts — the per-part fallback lane'],
                        ['`data`', 'Kind-specific structured payload'],
                        ['`mediaType` / `url`', 'Media kinds only — RFC MIME + sealed blob ref via the media pipeline'],
                        ['`required`', 'Default `false`. `true` only for safety-critical semantics (auth, payment, destructive)'],
                        ['`ext`', 'Optional reverse-dns bag for vendor-specific fields without forking the frame'],
                    ]}
                />
                <DocCallout type="tip">
                    Clients <strong>must ignore</strong> unknown <code>kind</code> values and unknown fields,
                    then render the part&apos;s <code>text</code> (and envelope <code>fallbackText</code>).
                    Never blank, never crash.
                </DocCallout>
            </DocSection>

            <DocSection id="core-kinds">
                <DocH2>Core kinds (v1)</DocH2>
                <DocP>
                    The core set is intentionally small. Rich novelty (widgets, canvas, commerce frames,
                    computer-use) ships as extensions. Below: one realistic example per core kind.
                </DocP>

                <DocH3>text</DocH3>
                <DocP>
                    Primary narration. <code>data.format</code> is <code>&quot;plain&quot;</code> or{' '}
                    <code>&quot;markdown&quot;</code>.
                </DocP>
                <DocCodeBlock lang="json" code={textPartExample} />

                <DocH3>media</DocH3>
                <DocP>
                    Images, audio, video, and files via <code>mediaType</code> + <code>url</code>. Optional{' '}
                    <code>data</code> fields: <code>caption</code>, <code>dimensions</code>,{' '}
                    <code>durationMs</code>, <code>fileName</code>, <code>sizeBytes</code>. Example: assistant
                    sends an image with a caption and a short follow-up.
                </DocP>
                <DocCodeBlock lang="json" code={mediaPartExample} />

                <DocH3>card</DocH3>
                <DocP>
                    Linkable rich summary: title, subtitle, image, link, and label/value fields.
                </DocP>
                <DocCodeBlock lang="json" code={cardPartExample} />

                <DocH3>actions</DocH3>
                <DocP>
                    Buttons and selects. User taps POST back to the provider on the existing events path as{' '}
                    <code>{'{ type: "action", actionId, messageId }'}</code>.
                </DocP>
                <DocCodeBlock lang="json" code={actionsPartExample} />

                <DocH3>status</DocH3>
                <DocP>
                    Progress for thinking, tools, and generation.{' '}
                    <code>data.state</code> is one of <code>thinking</code>, <code>tool_running</code>,{' '}
                    <code>generating</code>, <code>done</code>, <code>error</code>; optional{' '}
                    <code>label</code> and <code>progress</code> (0–1).
                </DocP>
                <DocCodeBlock lang="json" code={statusPartExample} />

                <DocH3>citations</DocH3>
                <DocP>
                    Source list for grounded answers: title, url, and snippet per item.
                </DocP>
                <DocCodeBlock lang="json" code={citationsPartExample} />

                <DocH3>error</DocH3>
                <DocP>
                    Structured failure outcomes. <code>data.code</code> is one of <code>refusal</code>,{' '}
                    <code>quota</code>, <code>tool_failed</code>, <code>internal</code>, with{' '}
                    <code>message</code> and <code>retryable</code>. Example: a safety refusal.
                </DocP>
                <DocCodeBlock lang="json" code={errorPartExample} />
            </DocSection>

            <DocSection id="extensions">
                <DocH2>Extensions</DocH2>
                <DocP>
                    Anything beyond the core table — ChatGPT-style widgets, canvas/artifacts, commerce
                    checkout cards, computer-use frames — uses a <strong>reverse-dns kind</strong> and the
                    same mandatory <code>text</code> lane. Host-registered kinds (for example{' '}
                    <code>vibe.call</code>) follow the same frame; see{' '}
                    <a href="#voice-calls">Voice &amp; calls</a> for the v1 call CTA.
                </DocP>
                <DocH3>Kind naming</DocH3>
                <DocList items={[
                    <>Use reverse-dns under your brand: <code>com.openai.widget</code>, <code>com.anthropic.artifact</code>, <code>com.acme.checkout_card</code>.</>,
                    <>Host-registered kinds (published by Vibe) use the <code>vibe.*</code> namespace — today: <code>vibe.call</code>.</>,
                    <>Put vendor-only fields in <code>ext.&lt;namespace&gt;</code> so core clients can ignore them safely.</>,
                    <>Declare extension kinds on the agent card under <code>capabilities.contentContract.ext</code> so hosts can negotiate.</>,
                ]} />
                <DocH3><code>required</code> semantics</DocH3>
                <DocP>
                    Default is <code>false</code>. Set <code>required: true</code>{' '}
                    <strong>only</strong> for safety-critical semantics — authentication handoffs, payment
                    confirmation, destructive actions. A client that cannot render a required part shows a
                    clear “needs a newer app” state, not silence. Optional extensions always degrade to the
                    text lane.
                </DocP>
                <DocH3>Worked example: playlist widget</DocH3>
                <DocP>
                    Unknown kind to older clients → they show the text. Newer clients with a Spotify widget
                    renderer use <code>data</code> + <code>ext</code>.
                </DocP>
                <DocCodeBlock lang="json" code={widgetExtExample} />
            </DocSection>

            <DocSection id="voice-calls">
                <DocH2>Voice &amp; calls</DocH2>
                <DocP>
                    v1 voice is the <strong>smallest possible</strong> integration: declare voice on the agent,
                    send one registered part, receive one webhook-style event when the user taps Call. No
                    provider-side WebRTC stack — media stays on Vibe’s call surface.
                </DocP>
                <DocList items={[
                    <><strong>Declare</strong> — include <code>&quot;voice&quot;</code> in agent <code>output_modes</code>. The public card publishes <code>capabilities.realtimeVoice = {'{ available: true, mode: "callback" }'}</code> (available is derived from that list).</>,
                    <><strong>Send</strong> — one <code>vibe.call</code> part inside a normal <code>vibe.content.v1</code> envelope (mandatory non-empty <code>text</code> lane).</>,
                    <><strong>Receive</strong> — handle <code>call.requested</code> on the existing events / callback path.</>,
                ]} />
                <DocH3>Registered part: <code>vibe.call</code></DocH3>
                <DocP>
                    Host-registered extension (listed under <code>contentContract.ext</code>).{' '}
                    <code>data.label</code> is the button caption; <code>data.mode</code> is{' '}
                    <code>&quot;voice&quot;</code> for the audio CTA.
                </DocP>
                <DocCodeBlock lang="json" code={vibeCallPartExample} />
                <DocH3>Native button + tap flow</DocH3>
                <DocP>
                    Clients that implement the parts renderer show Vibe’s <strong>native call button</strong> in
                    the message. On tap, Vibe opens its call surface and notifies your backend via the existing
                    events/callback path:
                </DocP>
                <DocCodeBlock lang="json" code={callRequestedCallbackExample} />
                <DocP>
                    Same class of outbound notification as action taps (<code>type: &quot;action&quot;</code>). Older
                    clients that do not know <code>vibe.call</code> render the part’s <code>text</code> lane
                    (and envelope <code>fallbackText</code>) — never a blank bubble.
                </DocP>
                <DocCallout type="note">
                    Full duplex provider sessions (<code>realtimeVoice.mode: &quot;session&quot;</code> with a
                    provider <code>sessionUrl</code> for WebRTC/WS negotiation) are <strong>roadmap only</strong> —
                    not implemented. Do not document or emit session mode as live. Spec:{' '}
                    <code>docs/provider-content-contract.md</code> § Voice and calls.
                </DocCallout>
            </DocSection>

            <DocSection id="negotiation">
                <DocH2>Negotiation</DocH2>
                <DocP>
                    Providers advertise what they speak on the public Agent Card under{' '}
                    <code>capabilities.contentContract</code> (and sibling flags such as{' '}
                    <code>realtimeVoice</code>). The server may down-convert to the client’s render set;
                    unknown extensions never hard-fail unless marked <code>required</code>.
                </DocP>
                <DocCodeBlock lang="json" code={contentContractCardSnippet} />
                <DocList items={[
                    <><code>version</code> — content-contract major version (1 for <code>vibe.content.v1</code>).</>,
                    <><code>parts</code> — core kinds this agent emits.</>,
                    <><code>ext</code> — host-registered and reverse-dns kinds the agent may emit (includes <code>vibe.call</code> when voice CTAs are used).</>,
                    <><code>realtimeVoice</code> — sibling object <code>{'{ available, mode: "callback" }'}</code> when <code>output_modes</code> includes <code>voice</code> (see Voice &amp; calls).</>,
                ]} />
                <DocP>
                    Card discovery, publish lifecycle, and the rest of the A2A-compatible surface are covered
                    in the quickstart:{' '}
                    <button
                        type="button"
                        className="provider-docs-inline-link"
                        onClick={() => navigate('/docs/providers/quickstart')}
                    >
                        Agent Card section
                    </button>
                    {' '}(<code>/docs/providers/quickstart#card</code>).
                </DocP>
                <DocCallout type="note">
                    Server validation returns <code>422</code> with{' '}
                    <code>{'{ "error": "invalid_content", "detail": … }'}</code> only for missing/empty text
                    lanes, unknown <code>contract</code> id, or a malformed part frame — never for an unknown{' '}
                    <code>kind</code>.
                </DocCallout>
            </DocSection>

            <DocSection id="coverage">
                <DocH2>Capability coverage</DocH2>
                <DocP>
                    How major assistant surfaces map onto the contract. Condensed from the research union
                    checklist — not exhaustive. The authoritative mapping and rules live in the repo spec{' '}
                    <code>docs/provider-content-contract.md</code>.
                </DocP>
                <DocCompareTable
                    columns={['Surface', 'How it ships in Vibe']}
                    rows={[
                        ['Streaming text / markdown', 'Core `text` parts; stream updates over existing agent/chat channels'],
                        ['Images, files, audio out', 'Core `media` (`mediaType` + `url` + caption metadata)'],
                        ['Product / link cards', 'Core `card`'],
                        ['Buttons, selects, forms', 'Core `actions` (+ events path for taps)'],
                        ['Typing / tool progress', 'Core `status` (`thinking` | `tool_running` | `generating` | …)'],
                        ['Citations / source links', 'Core `citations`'],
                        ['Refusal / quota / tool failure', 'Core `error`'],
                        ['Widgets / Apps SDK UI', 'Extension parts (`com.*.widget`, …) + mandatory text'],
                        ['Canvas / Artifacts pane', 'Extension parts + optional side-pane capability flag'],
                        ['Commerce / checkout handoff', 'Extension parts; `required: true` only for payment-critical steps'],
                        ['Computer-use / browser agent', 'Extension parts for frames/steps; long job + takeover as session UX'],
                        ['Realtime voice / call CTA', 'Card `realtimeVoice` (`mode: "callback"`) + registered `vibe.call` part → `call.requested`; session mode = roadmap'],
                        ['Coding tools / diffs / thinking', 'Coding-agent profile (below) — specialized progress model today'],
                    ]}
                />
                <DocCallout type="tip">
                    Additive evolution: a new capability is a declared name and optional part or extension.
                    Envelope <code>contract</code> major-bumps only for transport or security breaks.
                </DocCallout>
            </DocSection>

            <DocSection id="coding-profile">
                <DocH2>Coding-agent profile</DocH2>
                <DocP>
                    The shapes below remain fully valid for coding-agent surfaces (Claude Code, Codex, Grok
                    CLI, and the local bridge). In the parts model they are the{' '}
                    <strong>specialized coding profile</strong>: tool steps, thinking rows, diffs, and runtime
                    cards map onto progress UI that already ships in iOS and web. As <code>vibe.content.v1</code>{' '}
                    lands end-to-end, those turns can also be dual-published as parts (for example{' '}
                    <code>status</code> + <code>text</code> + media/file attachments) without dropping the
                    native agent view.
                </DocP>

                <DocH3>From provider stream to native UI</DocH3>
                <DocP>
                    Provider CLIs and hosted runtimes emit host-specific NDJSON or event streams. Vibe’s bridge
                    and server map those into a common progress model. Clients do not need a different renderer
                    per vendor.
                </DocP>
                <DocCodeBlock
                    lang="text"
                    code={`provider stream (Claude / Codex / Grok / …)
        │
        ▼
bridge  ── progress { provider, chatId, line }
        ── result   { provider, chatId, output, exitStatus, agentRuntime }
        │
        ▼
server LocalAgentWorker
   extract → { text, progress_nodes, tool_events, usage }
        │
        ▼
chat topic "agent-stream"
   { text, progressNodes, toolEvents, status: "running" | "done" }
        │
        ▼
iOS / web agent views  (summary bubble + full agent surface)`}
                />
                <DocCallout type="note">
                    Progress lines are capped server-side (stream buffer limit). The final <code>result</code>{' '}
                    is authoritative for the settled turn; live frames are for progressive UI only.
                </DocCallout>

                <DocH3>Streaming vs settled</DocH3>
                <DocCompareTable
                    columns={['Phase', 'status', 'What clients should do']}
                    rows={[
                        ['Live', '`running`', 'Upsert progress nodes by id; show running summary `text`; keep the agent cell active'],
                        ['Settled', '`done`', 'Replace with final extract from `result`; drop ephemeral-only noise; freeze the card'],
                        ['Failed host', 'error path', 'Surface host error text (e.g. quota messages) as the visible result, not a parse failure'],
                    ]}
                />
                <DocP>
                    While running, continuous thought/text chunks <strong>upsert</strong> the current segment
                    id. Tool calls between narrations bump segment ids so later text appears after tools
                    chronologically — not all tools on top and all text at the bottom.
                </DocP>

                <DocH3>Node kinds the agent view understands</DocH3>
                <div className="provider-docs-kind-grid">
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">text</p>
                        <p className="provider-docs-kind-desc">
                            Assistant narration / final answer. Default chat bubble shows the summary; full
                            segments live in the agent view.
                        </p>
                    </div>
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">thinking</p>
                        <p className="provider-docs-kind-desc">
                            Reasoning. Compact “Thought for Ns” row; detail may open a sheet. Never display
                            encrypted signatures as user-visible text.
                        </p>
                    </div>
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">read / edit / write</p>
                        <p className="provider-docs-kind-desc">
                            File tools. Edit/create may show +N −M when diffs are available; paths as basenames.
                        </p>
                    </div>
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">bash / search / web</p>
                        <p className="provider-docs-kind-desc">
                            Shell, repo search, and web fetch/search. Status running → done/failed with optional
                            detail.
                        </p>
                    </div>
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">todo / task</p>
                        <p className="provider-docs-kind-desc">
                            Planning lists and delegated task / subagent activity.
                        </p>
                    </div>
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">mcp / tool</p>
                        <p className="provider-docs-kind-desc">
                            MCP or generic tool calls. Labels prefer server · tool name when the name is
                            qualified.
                        </p>
                    </div>
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">compacting</p>
                        <p className="provider-docs-kind-desc">
                            Host context compaction (“Compacting conversation…”). Transient progress node.
                        </p>
                    </div>
                    <div className="provider-docs-kind">
                        <p className="provider-docs-kind-name">agent_card / progress tree</p>
                        <p className="provider-docs-kind-desc">
                            Composite runtime cards and trees for multi-step turns — the moat vs plain text bots.
                        </p>
                    </div>
                </div>

                <DocH3>Tool steps</DocH3>
                <DocP>
                    Tools are the unit of progress. Correlate start and finish by tool id (
                    <code>tool_use.id</code> ↔ <code>tool_result.tool_use_id</code>, or Codex{' '}
                    <code>item.id</code>).
                </DocP>
                <DocCompareTable
                    columns={['Host tool', 'Progress kind', 'Render hint']}
                    rows={[
                        ['Read / read_file / view_file', 'read', 'Read `basename`'],
                        ['Edit / search_replace / apply_patch', 'edit', 'Edit `basename` +N −M when known'],
                        ['Write / write_to_file', 'write', 'Create `basename` (N lines)'],
                        ['Bash / run_terminal_command / exec_command', 'bash', 'Run description or command'],
                        ['WebSearch / web_search / WebFetch', 'web', 'Search query or Fetch host'],
                        ['TodoWrite / todo_list / update_plan', 'todo', 'Planning list'],
                        ['mcp__server__tool / mcp_tool_call', 'mcp', 'MCP · tool name'],
                        ['Task / spawn_agent', 'task', 'Subagent activity'],
                    ]}
                />

                <DocH3>Diffs and runtime cards</DocH3>
                <DocP>
                    File edits should not dump full patches into the main chat bubble. The agent view shows a
                    runtime card: path, verb, optional line counts, and expandable detail. Codex{' '}
                    <code>file_change</code> items carry <code>changes[]</code> with{' '}
                    <code>kind: add | delete | update</code>. Claude <code>Edit</code> supplies{' '}
                    <code>old_string</code> / <code>new_string</code> for +N −M estimation.
                </DocP>
                <DocCallout type="tip">
                    Default chat remains scannable: one summary bubble plus a “view agent” affordance into the
                    solid-background agent surface where cards live.
                </DocCallout>

                <DocH3>Subagents and team runs</DocH3>
                <DocP>
                    Supervisor-style team runs attach metadata such as <code>teamRunId</code>,{' '}
                    <code>teamRole</code> (<code>lead</code> | <code>worker</code>),{' '}
                    <code>teamWorkersStatus</code>, and <code>suppressVisible</code> for under-hood workers.
                    Under-hood workers update a compact strip on the lead cell instead of inserting extra
                    transcript rows. Providers building multi-agent products should keep a single visible host
                    bubble per user-facing turn when possible.
                </DocP>

                <DocH3>JSON examples (coding profile)</DocH3>
                <DocH3>Live agent-stream frame</DocH3>
                <DocCodeBlock lang="json" code={agentStreamExample} />
                <DocH3>Settled turn (conceptual client model)</DocH3>
                <DocCodeBlock lang="json" code={settledResultExample} />
                <DocH3>Host wire shapes (bridge input)</DocH3>
                <DocCodeBlock lang="javascript" code={claudeBlocks} />
                <DocCodeBlock lang="javascript" code={grokLines} />
                <DocCodeBlock lang="javascript" code={codexItems} />
            </DocSection>

            <DocSection id="deeper">
                <DocH2>Deeper study</DocH2>
                <DocP>
                    This page is the provider-facing web reference for content and coding payloads. Normative
                    rules and the full capability map live in the repository:
                </DocP>
                <DocList items={[
                    <><code>docs/provider-content-contract.md</code> — authoritative <code>vibe.content.v1</code> spec</>,
                    <><code>docs/agent-payload-shapes.md</code> — coding-agent pipeline and host tables</>,
                    <>
                        End-to-end HTTP walkthrough at{' '}
                        <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/quickstart')}>
                            /docs/providers/quickstart
                        </button>
                    </>,
                    <>
                        Owner HTTP API examples at{' '}
                        <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/agents')}>
                            /docs/agents
                        </button>
                    </>,
                ]} />
                <DocCallout type="warning">
                    Do not invent core kinds or coding node shapes for a new host. Prefer an extension kind
                    with a mandatory text lane, declare it on the card, and extend renderers against the repo
                    specs — the same process used for Claude, Codex, and Grok coding streams.
                </DocCallout>
            </DocSection>
        </DocsShell>
    );
}
