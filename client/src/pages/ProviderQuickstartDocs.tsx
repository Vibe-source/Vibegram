import { useNavigate } from 'react-router-dom';
import DocsShell from '../components/docs/DocsShell';
import {
    DocSection,
    DocH2,
    DocH3,
    DocP,
    DocCallout,
    DocCodeBlock,
    DocParamTable,
    DocSteps,
    DocList,
} from '../components/docs/DocComponents';
import { providerDocsTabs } from './ProviderDocs';
import './ProviderDocs.css';

const sections = [
    { id: 'overview', label: 'Overview' },
    { id: 'create', label: 'Create & secret' },
    { id: 'publish', label: 'Publish' },
    { id: 'card', label: 'Agent Card' },
    { id: 'invoke', label: 'Invoke' },
    { id: 'events', label: 'Events' },
    { id: 'callback', label: 'Callbacks' },
    { id: 'voice', label: 'Add voice' },
    { id: 'rotate', label: 'Rotate secret' },
    { id: 'checklist', label: 'Checklist' },
];

const createCurl = `# Owner auth required (Bearer user token)
curl -X POST "https://api.vibegram.io/api/agents" \\
  -H "Authorization: Bearer USER_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{
    "display_name":  "Acme Assistant",
    "username":      "acme_assistant",
    "system_prompt": "You are Acme Assistant. Be concise and accurate.",
    "persona":       "Helpful product assistant for Acme customers.",
    "output_modes":  ["text"],
    "autonomy_mode": "safe_auto",
    "callback_url":  "https://api.acme.example/vibe/callbacks",
    "enabled_tools": []
  }'

# Response (shape):
# {
#   "agent":  { "id": "...", "username": "acme_assistant", "status": "draft", ... },
#   "secret": "vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# }
# Store secret immediately — create returns it once; later you only see secretHint.`;

const publishCurl = `curl -X POST "https://api.vibegram.io/api/agents/AGENT_UUID/publish" \\
  -H "Authorization: Bearer USER_TOKEN"

# Requires non-empty system_prompt and at least one output_mode.
# Published agents accept invoke + events; username is locked.`;

const cardCurl = `# Public (no owner Bearer). Published agents only → else 404.
curl -s "https://api.vibegram.io/api/agents/acme_assistant/card"

# Frozen A2A-compatible top-level keys include:
# protocolVersion, kind, identifier, name, description, url, eventsUrl,
# provider, version, capabilities, defaultInputModes, defaultOutputModes,
# securitySchemes, skills, status
#
# url        → .../api/agents/<identifier>/invoke
# eventsUrl  → .../api/agents/<identifier>/events
# Never includes secrets, prompts, budgets, or owner ids.`;

const invokeCurl = `curl -X POST "https://api.vibegram.io/api/agents/acme_assistant/invoke" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \\
  -d '{
    "message": "Summarise open support tickets for today",
    "source": "acme_ops",
    "responseMode": "reply"
  }'

# Success:
# {
#   "success": true,
#   "invocationId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
#   "outputs": [ { "type": "text", "text": "..." } ],
#   "vibe_deliveries": []
# }`;

const invokeSendCurl = `# Post into a Vibe chat the agent already participates in
curl -X POST "https://api.vibegram.io/api/agents/acme_assistant/invoke" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \\
  -d '{
    "message": "Post the morning standup summary",
    "source": "scheduler",
    "responseMode": "send",
    "vibeChatId": "73928163c120"
  }'

# If the agent shadow user is not a participant → 403
# { "error": "Agent not attached to target chat" }`;

const eventsCurl = `curl -X POST "https://api.vibegram.io/api/agents/acme_assistant/events" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \\
  -d '{
    "eventId": "ticket_10022",
    "eventType": "ticket.updated",
    "threadKey": "ticket_10022",
    "source": "acme_crm",
    "title": "Ticket escalated",
    "text": "Ticket #10022 escalated to tier-2",
    "data": { "ticketId": 10022, "priority": "high" },
    "destinationChatId": "73928163c120"
  }'

# Auth alternatives: X-Vibe-Agent-Secret or X-Vibe-Integration-Secret
# eventType is required. destinationChatId or agent default_destination_chat_id required.`;

const rotateCurl = `# Owner auth — invalidates the previous secret immediately
curl -X POST "https://api.vibegram.io/api/agents/AGENT_UUID/secret/rotate" \\
  -H "Authorization: Bearer USER_TOKEN"

# {
#   "agent":  { ..., "secretHint": "xxxxAB" },
#   "secret": "vas_NEW_VALUE_STORE_IMMEDIATELY"
# }`;

const vibeCallEnvelopeExample = `{
  "contract": "vibe.content.v1",
  "fallbackText": "Tap Call now to talk, or keep chatting in text.",
  "parts": [
    {
      "kind": "vibe.call",
      "schemaVersion": 1,
      "text": "Start a voice call with this assistant.",
      "data": { "label": "Call now", "mode": "voice" },
      "required": false
    }
  ]
}`;

const callRequestedExample = `{
  "type": "call.requested",
  "chatId": "73928163c120",
  "agentId": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
}`;

export default function ProviderQuickstartDocs() {
    const navigate = useNavigate();

    return (
        <DocsShell
            sidebarLabel="Providers"
            eyebrow="Providers"
            title="Provider quickstart"
            intro="End-to-end path from a draft agent to live invoke and events. Paths and response fields match the server router and AgentsController — no invented fields."
            tabs={providerDocsTabs}
            sections={sections}
        >
            <DocSection id="overview">
                <DocH2>What you will build</DocH2>
                <DocP>
                    In about fifteen minutes you will create a published agent, store its one-time secret,
                    fetch the public Agent Card, call invoke, push an event, and rotate the secret. Base URL
                    in examples is <code>https://api.vibegram.io</code> — point it at your environment as
                    needed.
                </DocP>
                <DocSteps items={[
                    {
                        title: 'Create (draft) + copy secret',
                        body: 'POST /api/agents (owner Bearer). Response includes agent + secret (prefix vas_).',
                    },
                    {
                        title: 'Configure & publish',
                        body: 'Set prompt, tools, callback_url, destination chat as needed. POST /api/agents/:id/publish.',
                    },
                    {
                        title: 'Discover the card',
                        body: 'GET /api/agents/:identifier/card — public JSON for published agents only.',
                    },
                    {
                        title: 'Integrate your backend',
                        body: 'POST invoke for request/response or chat delivery; POST events for structured pushes.',
                    },
                    {
                        title: 'Operate securely',
                        body: 'Verify signed callbacks if configured; rotate secrets via POST .../secret/rotate.',
                    },
                ]} />
                <DocCallout type="tip">
                    Prefer the in-app agent builder for the first agent — it walks the same lifecycle and
                    surfaces the env pack. The REST steps below are what production backends use. Full field
                    reference:{' '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/agents/config')}>
                        /docs/agents/config
                    </button>
                    .
                </DocCallout>
            </DocSection>

            <DocSection id="create">
                <DocH2>Create an agent and capture the secret</DocH2>
                <DocP>
                    <code>POST /api/agents</code> requires an authenticated owner. On success the body is{' '}
                    <code>{'{ agent, secret }'}</code>. The plaintext secret is generated server-side as{' '}
                    <code>vas_</code> + random material, stored as a SHA-256 hash (plus an encrypted copy for
                    callback signing). Only a short <code>secretHint</code> is returned on later reads.
                </DocP>
                <DocCodeBlock lang="bash" code={createCurl} />
                <DocCallout type="warning">
                    Treat the create/rotate secret like a production API key. If you lose it, call{' '}
                    <code>POST /api/agents/:id/secret/rotate</code> — there is no plaintext recovery of the old
                    value from the hash alone.
                </DocCallout>
            </DocSection>

            <DocSection id="publish">
                <DocH2>Publish</DocH2>
                <DocP>
                    Only agents with <code>status: "published"</code> accept public invoke/events. Publish
                    requires a non-empty <code>system_prompt</code> and at least one entry in{' '}
                    <code>output_modes</code>. Draft / disabled / archived agents receive{' '}
                    <code>403 Agent unavailable</code> on ingress.
                </DocP>
                <DocCodeBlock lang="bash" code={publishCurl} />
                <DocList items={[
                    <>Attach the agent as a chat participant before using <code>responseMode: "send"</code> or chat-bound events.</>,
                    <>Optionally set <code>default_destination_chat_id</code> so events can post without a per-request chat id.</>,
                    <>Username is locked after publish — change it only while still draft.</>,
                ]} />
            </DocSection>

            <DocSection id="card">
                <DocH2>Fetch your Agent Card</DocH2>
                <DocP>
                    Discovery endpoint (public, rate-limited with the platform’s public agent pipeline once
                    wired): <code>GET /api/agents/:identifier/card</code>. Identifier may be the agent username
                    (handle) used in the card’s <code>identifier</code> field. Unpublished agents return{' '}
                    <code>{'{ "error": "not_found" }'}</code> with status 404.
                </DocP>
                <DocCodeBlock lang="bash" code={cardCurl} />
                <DocCallout type="note">
                    The card’s <code>url</code> and <code>eventsUrl</code> are the same invoke/events paths your
                    backend calls with <code>X-Vibe-Agent-Secret</code>. Integrators may also expose{' '}
                    <code>GET /.well-known/agent-card/:identifier</code> as an alternate discovery URL.
                    Advertise the parts you emit under{' '}
                    <code>capabilities.contentContract</code> — see{' '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/payloads')}>
                        Payloads → Negotiation
                    </button>
                    .
                </DocCallout>
            </DocSection>

            <DocSection id="invoke">
                <DocH2>Reply via invoke</DocH2>
                <DocP>
                    <code>POST /api/agents/:identifier/invoke</code> is secret-backed public ingress (pipeline{' '}
                    <code>public_agent_rate_limited</code>). Header:{' '}
                    <code>X-Vibe-Agent-Secret: vas_…</code>.
                </DocP>
                <DocH3>Request body</DocH3>
                <DocParamTable params={[
                    { name: 'message', type: 'string', required: true, desc: 'Prompt / user message for the agent.' },
                    { name: 'source', type: 'string', required: false, desc: 'Caller label stored on the invocation (e.g. "acme_ops").' },
                    { name: 'responseMode', type: 'string', required: false, desc: '`"reply"` (default) returns outputs in the HTTP body. `"send"` posts into a Vibe chat.' },
                    { name: 'vibeChatId', type: 'string', required: false, desc: 'Required when `responseMode` is `"send"`. Agent must be a participant.' },
                    { name: 'outputMode', type: 'string', required: false, desc: 'Override for this call: text | voice | media (must be allowed on the agent).' },
                    { name: 'replyToId', type: 'string', required: false, desc: 'Message id to thread under when delivering to chat.' },
                    { name: 'attachments', type: 'array', required: false, desc: 'e.g. `{ type: "image", url: "https://..." }` for vision context.' },
                    { name: 'requesterUserId', type: 'string', required: false, desc: 'Optional Vibe user id for tool context.' },
                    { name: 'eventId', type: 'string', required: false, desc: 'Idempotency key stored on the invocation record.' },
                ]} />
                <DocCodeBlock lang="bash" code={invokeCurl} />
                <DocH3>Send mode (chat participant)</DocH3>
                <DocCodeBlock lang="bash" code={invokeSendCurl} />
                <DocP>
                    Success body includes <code>success</code>, <code>invocationId</code>, <code>outputs</code>,
                    and <code>vibe_deliveries</code> (populated when responseMode is send). Common errors:{' '}
                    <code>401 Invalid secret</code>, <code>403 Agent unavailable</code>,{' '}
                    <code>403 Agent not attached to target chat</code>, <code>404 Agent not found</code>,{' '}
                    <code>422</code> for validation/runtime failures.
                </DocP>
            </DocSection>

            <DocSection id="events">
                <DocH2>Push events</DocH2>
                <DocP>
                    <code>POST /api/agents/:identifier/events</code> ingests a structured event. The agent
                    decides next actions from <code>autonomy_mode</code> and configuration — post to chat,
                    open an approval task, draft, or log. Auth header:{' '}
                    <code>X-Vibe-Agent-Secret</code> or <code>X-Vibe-Integration-Secret</code>.
                </DocP>
                <DocParamTable params={[
                    { name: 'eventType', type: 'string', required: true, desc: 'Dot-separated type, e.g. `ticket.updated`.' },
                    { name: 'eventId', type: 'string', required: false, desc: 'Idempotency key — safe to retry.' },
                    { name: 'threadKey', type: 'string', required: false, desc: 'Groups related events into one agent event thread.' },
                    { name: 'source', type: 'string', required: false, desc: 'Producer label (e.g. `acme_crm`).' },
                    { name: 'title', type: 'string', required: false, desc: 'Short title for inbox / bubble headers.' },
                    { name: 'text', type: 'string', required: false, desc: 'Human-readable body used as agent context.' },
                    { name: 'data', type: 'object', required: false, desc: 'Arbitrary structured payload.' },
                    { name: 'destinationChatId', type: 'string', required: false, desc: 'Override default destination chat for this event.' },
                    { name: 'occurredAt', type: 'string', required: false, desc: 'ISO-8601 when the event occurred; defaults to ingestion time.' },
                    { name: 'attachments', type: 'array', required: false, desc: '`{ type, url }` context objects.' },
                ]} />
                <DocCodeBlock lang="bash" code={eventsCurl} />
                <DocCallout type="warning">
                    Missing both <code>destinationChatId</code> and the agent’s{' '}
                    <code>default_destination_chat_id</code> yields <code>422 Missing destination chat</code>.
                    Missing <code>eventType</code> yields <code>422 eventType is required</code>.
                </DocCallout>
            </DocSection>

            <DocSection id="callback">
                <DocH2>Callbacks (outbound from Vibe)</DocH2>
                <DocP>
                    If you set <code>callback_url</code>, Vibe can enqueue signed delivery events after
                    invocations (for example <code>agent.invocation.completed</code>). Your endpoint verifies
                    <code>X-Vibe-Agent-Signature</code> and <code>X-Vibe-Agent-Signature-Timestamp</code> using
                    the agent secret. This is <strong>outbound from Vibe to you</strong> — delivery and
                    completion notifications — not a substitute for the invoke/events ingress you call into
                    Vibe.
                </DocP>
                <DocCallout type="note">
                    Signature verification examples live in{' '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/agents/examples')}>
                        /docs/agents/examples
                    </button>
                    . URLs are validated as safe external targets before enqueue.
                </DocCallout>
            </DocSection>

            <DocSection id="voice">
                <DocH2>Add voice (smallest path)</DocH2>
                <DocP>
                    Voice in v1 is deliberately the <strong>smallest possible</strong> integration — one
                    content part plus one webhook-style event — so you adopt it the same way you already
                    use callbacks and action taps. No provider WebRTC setup.
                </DocP>
                <DocSteps items={[
                    {
                        title: 'Enable voice on the agent',
                        body: 'Include "voice" in output_modes (create/update + publish). The public Agent Card then advertises capabilities.realtimeVoice = { available: true, mode: "callback" }.',
                    },
                    {
                        title: 'Send a vibe.call part',
                        body: 'When you want an in-thread Call button, deliver a vibe.content.v1 envelope that includes one vibe.call part (non-empty text lane required). Use invoke or events the same way you already post assistant content.',
                    },
                    {
                        title: 'Handle call.requested',
                        body: 'When the user taps the native call button, Vibe opens its call surface and notifies your callback / events consumer with type call.requested, chatId, and agentId.',
                    },
                ]} />
                <DocCodeBlock lang="json" code={vibeCallEnvelopeExample} />
                <DocP>Outbound notification shape (existing events/callback path):</DocP>
                <DocCodeBlock lang="json" code={callRequestedExample} />
                <DocCallout type="tip">
                    Full reference (button rendering, degrade path, roadmap session mode):{' '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/payloads#voice-calls')}>
                        Payloads → Voice &amp; calls
                    </button>
                    . Session mode with provider <code>sessionUrl</code> is <strong>not</strong> implemented —
                    do not treat it as live.
                </DocCallout>
            </DocSection>

            <DocSection id="rotate">
                <DocH2>Rotate the secret</DocH2>
                <DocP>
                    <code>POST /api/agents/:id/secret/rotate</code> (owner Bearer) generates a new{' '}
                    <code>vas_…</code> secret, updates the hash + encrypted material + hint, and returns the
                    new plaintext once. Deploy the new value before invalidating the old one in your workers —
                    after rotate, the previous secret fails verify immediately.
                </DocP>
                <DocCodeBlock lang="bash" code={rotateCurl} />
            </DocSection>

            <DocSection id="checklist">
                <DocH2>Production checklist</DocH2>
                <DocList items={[
                    <>Secret stored only in your secret manager — never in client apps or public cards.</>,
                    <>Agent published; card returns 200 for your identifier.</>,
                    <>Agent attached to every chat you target with <code>responseMode: "send"</code>.</>,
                    <>Rate limit awareness: public agent ingress allows 600 req/min per identifier bucket (in-memory ETS limiter).</>,
                    <>Autonomy mode reviewed for events — see{' '}
                        <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/security')}>
                            Security
                        </button>
                        .
                    </>,
                    <>Content contract and coding payload shapes understood — see{' '}
                        <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/payloads')}>
                            Payloads
                        </button>
                        {' '}(<code>vibe.content.v1</code> + coding-agent profile).
                    </>,
                    <>Optional voice CTA: <code>voice</code> in <code>output_modes</code>,{' '}
                        <code>vibe.call</code> part when offering a call, and a handler for{' '}
                        <code>call.requested</code> on your callback.
                    </>,
                ]} />
            </DocSection>
        </DocsShell>
    );
}
