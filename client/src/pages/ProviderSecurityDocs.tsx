import { useNavigate } from 'react-router-dom';
import DocsShell from '../components/docs/DocsShell';
import {
    DocSection,
    DocH2,
    DocH3,
    DocP,
    DocCallout,
    DocParamTable,
    DocList,
    DocCompareTable,
} from '../components/docs/DocComponents';
import { providerDocsTabs } from './ProviderDocs';
import './ProviderDocs.css';

const sections = [
    { id: 'principles', label: 'Principles' },
    { id: 'chat-scope', label: 'Chat scope' },
    { id: 'e2e', label: 'Human E2E' },
    { id: 'secrets', label: 'Secrets' },
    { id: 'ingress', label: 'Public ingress' },
    { id: 'autonomy', label: 'Autonomy & consent' },
    { id: 'card', label: 'Public card' },
    { id: 'claims', label: 'What we claim' },
];

export default function ProviderSecurityDocs() {
    const navigate = useNavigate();

    return (
        <DocsShell
            sidebarLabel="Providers"
            eyebrow="Providers"
            title="Security model"
            intro="How Vibe scopes agents, stores secrets, rate-limits public ingress, and gates autonomous actions — stated only where the codebase enforces it."
            tabs={providerDocsTabs}
            sections={sections}
        >
            <DocSection id="principles">
                <DocH2>Security principles</DocH2>
                <DocList items={[
                    <><strong>Least chat access</strong> — an agent’s shadow user only participates in chats where it was explicitly added.</>,
                    <><strong>Human E2E preserved</strong> — agent participation does not unwrap or re-key human↔human end-to-end messaging for non-agent members.</>,
                    <><strong>Secrets are credentials</strong> — hashed at rest for verify; one-time plaintext on create/rotate; public surfaces never include them.</>,
                    <><strong>Public ingress is rate-limited</strong> — invoke/events sit on a dedicated public-agent limiter, separate from user API buckets.</>,
                    <><strong>Autonomy is configurable</strong> — event posting and high-risk paths can require owner approval depending on <code>autonomy_mode</code>.</>,
                ]} />
                <DocCallout type="note">
                    This page describes server and product behavior as implemented. It is not a compliance
                    certification or a privacy policy. Product legal copy belongs in your own terms and the
                    Vibe privacy surfaces. Message body structure (parts, mandatory text lanes, extension
                    kinds) is documented under{' '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/payloads')}>
                        Payloads
                    </button>
                    .
                </DocCallout>
            </DocSection>

            <DocSection id="chat-scope">
                <DocH2>Agents only see chats they join</DocH2>
                <DocP>
                    Each agent has an <code>agent_user_id</code> (shadow user). Chat APIs and invoke delivery
                    check participation via the same participant model as human members. When{' '}
                    <code>responseMode</code> is <code>send</code>, the server requires{' '}
                    <code>Chat.is_participant?(vibe_chat_id, agent.agent_user_id)</code>; otherwise it returns{' '}
                    <code>403 Agent not attached to target chat</code>. Event delivery into a destination chat
                    uses the same attachment check.
                </DocP>
                <DocP>
                    Archiving an agent deletes its participant rows and clears <code>callback_url</code>, which
                    stops new chat membership and outbound delivery configuration for that agent.
                </DocP>
                <DocCallout type="tip">
                    Operators should add the agent only to the DMs or groups that need it. There is no
                    cross-chat “read all of the owner’s history” path in the standalone agent ingress.
                </DocCallout>
            </DocSection>

            <DocSection id="e2e">
                <DocH2>Human↔human E2E is untouched</DocH2>
                <DocP>
                    Vibe’s messaging cryptography for human participants is independent of the agent HTTP
                    ingress. Adding an agent to a chat makes that agent a participant for messages it is
                    allowed to send or receive in that thread; it does not grant the provider API the ability
                    to decrypt arbitrary other chats or other users’ keys.
                </DocP>
                <DocP>
                    Bridge-mediated interactive flows (for example ask/plan payloads) can be sealed for the
                    paired runtime — opaque to intermediaries that lack the pairing key. Provider HTTP
                    invoke/events use secret auth over TLS to the API, not the human E2E channel.
                </DocP>
            </DocSection>

            <DocSection id="secrets">
                <DocH2>Secret storage, reveal, and rotation</DocH2>
                <DocH3>Generation</DocH3>
                <DocP>
                    On create (and on rotate), the server generates{' '}
                    <code>vas_</code> + URL-safe random bytes. It stores:
                </DocP>
                <DocList items={[
                    <><code>webhook_secret_hash</code> — SHA-256 hex of the plaintext (constant-time compare on verify)</>,
                    <><code>webhook_secret_encrypted</code> — AES-GCM sealed copy used for callback signing material</>,
                    <><code>secret_hint</code> — last six characters for owner UI recognition</>,
                ]} />
                <DocH3>One-time reveal</DocH3>
                <DocP>
                    <code>POST /api/agents</code> and <code>POST /api/agents/:id/secret/rotate</code> return the
                    plaintext <code>secret</code> once in the JSON body. Subsequent agent payloads expose{' '}
                    <code>secretHint</code> only. Owner <code>GET /api/agents/:id/secret</code> can recover the
                    signing secret from the encrypted field when present — still owner-authenticated, never
                    public.
                </DocP>
                <DocH3>Rotation</DocH3>
                <DocP>
                    Rotation rewrites hash, encrypted material, and hint. The previous secret fails{' '}
                    <code>Agents.verify_secret/2</code> immediately. Integrations can have their own secrets
                    (header <code>X-Vibe-Integration-Secret</code> on events) with the same hash pattern.
                </DocP>
                <DocCallout type="danger">
                    Never put agent secrets in mobile clients, Agent Cards, or frontend bundles. Only your
                    server-side workers should hold <code>X-Vibe-Agent-Secret</code>.
                </DocCallout>
            </DocSection>

            <DocSection id="ingress">
                <DocH2>Public ingress and rate limits</DocH2>
                <DocP>
                    Routes <code>POST /api/agents/:identifier/invoke</code> and{' '}
                    <code>POST /api/agents/:identifier/events</code> use the{' '}
                    <code>:public_agent_rate_limited</code> pipeline. The rate limiter type{' '}
                    <code>public_agent</code> defaults to <strong>600 requests per 60 seconds</strong> per
                    bucket/identifier (ETS in-memory; resets on node restart). Exceeding the limit returns{' '}
                    <code>429</code> with <code>retry_after</code>.
                </DocP>
                <DocCompareTable
                    columns={['Check', 'Failure']}
                    rows={[
                        ['Agent resolves by identifier', '404 `Agent not found`'],
                        ['`status == "published"`', '403 `Agent unavailable`'],
                        ['Secret verifies (SHA-256 compare)', '401 `Invalid secret`'],
                        ['Send/events chat attachment', '403 `Agent not attached to target chat`'],
                        ['Events destination present', '422 `Missing destination chat`'],
                        ['Events `eventType` present', '422 `eventType is required`'],
                        ['Invoke `message` present', '422 (missing message path)'],
                    ]}
                />
                <DocP>
                    Callback target URLs are validated through the server’s safe-URL checks before delivery
                    events are stored. Delivery workers sign outbound bodies with the agent secret.
                </DocP>
            </DocSection>

            <DocSection id="autonomy">
                <DocH2>Consent and autonomy modes</DocH2>
                <DocP>
                    Users consent to an agent’s presence by adding it to a chat (participant model). Separately,{' '}
                    <code>autonomy_mode</code> on the agent (and optionally per integration) gates how
                    automatically the event runtime may post or act:
                </DocP>
                <DocParamTable params={[
                    { name: 'safe_auto', type: 'default', required: false, desc: 'Auto for low-risk paths; high-risk (e.g. runbook risk) can require approval.' },
                    { name: 'full_auto', type: '', required: false, desc: 'Posts without approval gates — only for fully trusted sources.' },
                    { name: 'approval_required', type: '', required: false, desc: 'Creates ApprovalTasks; owner approves/rejects before execution.' },
                    { name: 'draft_first', type: '', required: false, desc: 'Drafts for the owner; promote when ready.' },
                    { name: 'manual', type: '', required: false, desc: 'Logs only — no posts, no approval tasks.' },
                ]} />
                <DocP>
                    Owners approve or reject via{' '}
                    <code>POST /api/agents/:id/approval_tasks/:task_id/approve</code> and{' '}
                    <code>.../reject</code> (authenticated owner). Interactive bridge asks (plan / ask-user)
                    are additional human gates on paired local agent runs — separate from the HTTP event
                    autonomy_mode, but part of the same product story: the human stays in control when the
                    mode demands it.
                </DocP>
            </DocSection>

            <DocSection id="card">
                <DocH2>Public Agent Card surface</DocH2>
                <DocP>
                    <code>GET /api/agents/:identifier/card</code> is intentionally public for discovery of
                    published agents. The frozen contract forbids secrets, system prompts, budgets, and owner
                    identifiers on the card. Non-published agents return 404 <code>not_found</code> so draft
                    experiments are not enumerable by status probing of secret fields (they simply do not
                    resolve).
                </DocP>
            </DocSection>

            <DocSection id="claims">
                <DocH2>What we state — and what we do not</DocH2>
                <DocP>
                    Providers often need accurate security language for reviews. Align marketing claims with
                    code:
                </DocP>
                <DocList items={[
                    <>
                        <strong>We enforce</strong> participant-scoped agent access, hashed agent secrets with
                        rotation, published-only public ingress, public-agent rate limiting, safe callback URL
                        checks, and autonomy/approval controls for event-driven actions.
                    </>,
                    <>
                        <strong>We do not assert here</strong> that user message content is never used to train
                        third-party foundation models. Standalone agents may call configured model providers
                        (including your own) using the agent’s prompt and the message context you send — your
                        data-processing agreement with that model host is separate. Vibe’s server code does not
                        implement a “no training” legal guarantee as an enforceable runtime flag in the agent
                        ingress path.
                    </>,
                    <>
                        <strong>Retention &amp; logs</strong> — invocations, events, and delivery attempts are
                        persisted for owner operations (deliveries, threads, debugging). Treat them as
                        operational data under your retention policy, not as ephemeral-only transport.
                    </>,
                ]} />
                <DocCallout type="warning">
                    If you need a contractual non-training commitment, put it in your customer terms and your
                    model-provider agreements. Do not copy unverified “we never train on your data” language
                    from this page into compliance docs.
                </DocCallout>
                <DocP>
                    Related:{' '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/quickstart')}>
                        Quickstart
                    </button>
                    {' · '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/agents')}>
                        Standalone agents
                    </button>
                    {' · '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers')}>
                        Provider overview
                    </button>
                </DocP>
            </DocSection>
        </DocsShell>
    );
}
