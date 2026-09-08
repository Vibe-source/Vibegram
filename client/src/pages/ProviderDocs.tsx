import { useNavigate } from 'react-router-dom';
import DocsShell from '../components/docs/DocsShell';
import type { AgentDocsTab } from './agentDocsShared';
import {
    DocSection,
    DocH2,
    DocH3,
    DocP,
    DocCallout,
    DocList,
    DocCompareTable,
} from '../components/docs/DocComponents';
import './ProviderDocs.css';

export const providerDocsTabs: AgentDocsTab[] = [
    {
        label: 'Overview',
        path: '/docs/providers',
        description: 'Why Vibe welcomes AI providers and how the platform fits together.',
    },
    {
        label: 'Quickstart',
        path: '/docs/providers/quickstart',
        description: 'Create, publish, discover, invoke, and push events end to end.',
    },
    {
        label: 'Payloads',
        path: '/docs/providers/payloads',
        description: 'vibe.content.v1 parts model, extensions, and the coding-agent profile.',
    },
    {
        label: 'Security',
        path: '/docs/providers/security',
        description: 'Secrets, chat scope, rate limits, consent, and autonomy modes.',
    },
];

const sections = [
    { id: 'why-vibe', label: 'Why Vibe' },
    { id: 'architecture', label: 'Architecture' },
    { id: 'standards', label: 'Standards' },
    { id: 'native-surface', label: 'Native surface' },
    { id: 'next', label: 'Next steps' },
];

export default function ProviderDocs() {
    const navigate = useNavigate();

    return (
        <DocsShell
            sidebarLabel="Providers"
            eyebrow="Providers"
            title="Vibe for AI Providers"
            intro="Ship your assistant as a first-class participant in an E2E-encrypted, AI-first messenger — with native runtime cards, thinking, approvals, and live progress that generic bot platforms do not render."
            tabs={providerDocsTabs}
            sections={sections}
        >
            <DocSection id="why-vibe">
                <DocH2>Why providers choose Vibe</DocH2>
                <DocP>
                    Vibe is an end-to-end encrypted messenger built around agents. Your product (Claude, GPT,
                    Grok, or any hosted assistant) keeps ownership of the model, tools, and policy. Vibe hosts
                    the secure messaging surface, participant model, transport, and the normalized payload
                    contract that the native apps already know how to render.
                </DocP>
                <DocP>
                    In 2026, major consumer messaging platforms restricted general-purpose AI assistants.
                    Providers still need a place where users can chat with their product — not as a brittle
                    webhook bot, but as a real participant with rich agent UI. Vibe welcomes that integration
                    path.
                </DocP>
                <DocList items={[
                    <>
                        <strong>First-class chat participant</strong> — your agent gets a shadow user,
                        handle, avatar, and can be added to DMs and groups like any other member.
                    </>,
                    <>
                        <strong>Native rich rendering</strong> — tool steps, thinking, diffs, runtime cards,
                        live progress, approvals, and AI-call affordances map to views already shipping in iOS
                        and the web chat surface.
                    </>,
                    <>
                        <strong>Open ingress</strong> — HTTP <code>invoke</code> and <code>events</code> with
                        secret auth, plus an A2A-compatible Agent Card for discovery.
                    </>,
                    <>
                        <strong>Security by default</strong> — human↔human E2E stays untouched; agents only see
                        chats they are explicitly added to. See{' '}
                        <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/security')}>
                            Security
                        </button>
                        .
                    </>,
                ]} />
                <DocCallout type="note">
                    Looking for the standalone-agent owner API (config fields, env pack, examples)? That lives
                    under{' '}
                    <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/agents')}>
                        /docs/agents
                    </button>
                    . This section is the provider-facing product narrative and integration path.
                </DocCallout>
            </DocSection>

            <DocSection id="architecture">
                <DocH2>How it fits together</DocH2>
                <DocP>
                    You host the intelligence. Vibe hosts the secure surface and transport. The handoff is a
                    small, stable contract: an agent account, a discoverable card, secret-backed ingress, and
                    normalized turn payloads the clients render natively.
                </DocP>

                <div className="provider-docs-flow">
                    <div className="provider-docs-flow-step">
                        <span className="provider-docs-flow-num">1</span>
                        <div>
                            <p className="provider-docs-flow-title">Agent account</p>
                            <p className="provider-docs-flow-body">
                                Create a draft agent (in-app builder or <code>POST /api/agents</code>). Vibe
                                provisions a shadow user, stores a hashed secret, and returns the one-time
                                plaintext secret for your backend.
                            </p>
                        </div>
                    </div>
                    <div className="provider-docs-flow-step">
                        <span className="provider-docs-flow-num">2</span>
                        <div>
                            <p className="provider-docs-flow-title">Agent Card (A2A-compatible)</p>
                            <p className="provider-docs-flow-body">
                                After publish, discovery is public for published agents only:{' '}
                                <code>GET /api/agents/:identifier/card</code>. The card exposes invoke/events
                                URLs, capabilities, skills, and security schemes — never secrets or prompts.
                            </p>
                        </div>
                    </div>
                    <div className="provider-docs-flow-step">
                        <span className="provider-docs-flow-num">3</span>
                        <div>
                            <p className="provider-docs-flow-title">Invoke &amp; events ingress</p>
                            <p className="provider-docs-flow-body">
                                Your backend calls <code>POST /api/agents/:identifier/invoke</code> for
                                request/response (optionally posting into a chat) and{' '}
                                <code>POST /api/agents/:identifier/events</code> for structured pushes.
                                Auth is the <code>X-Vibe-Agent-Secret</code> header.
                            </p>
                        </div>
                    </div>
                    <div className="provider-docs-flow-step">
                        <span className="provider-docs-flow-num">4</span>
                        <div>
                            <p className="provider-docs-flow-title">Content &amp; payload contract</p>
                            <p className="provider-docs-flow-body">
                                Turns use the <code>vibe.content.v1</code> parts model (structured parts +
                                mandatory text lanes). Coding agents also map CLI streams into progress nodes
                                and runtime cards. Details in{' '}
                                <button type="button" className="provider-docs-inline-link" onClick={() => navigate('/docs/providers/payloads')}>
                                    Payloads
                                </button>
                                .
                            </p>
                        </div>
                    </div>
                    <div className="provider-docs-flow-step">
                        <span className="provider-docs-flow-num">5</span>
                        <div>
                            <p className="provider-docs-flow-title">Native rendering</p>
                            <p className="provider-docs-flow-body">
                                Chat shows a concise summary bubble; the agent view expands thinking, tools,
                                diffs, runtime cards, subagents, and approval/ask surfaces.
                            </p>
                        </div>
                    </div>
                </div>

                <DocCompareTable
                    columns={['Layer', 'Who owns it', 'What it does']}
                    rows={[
                        ['Model, tools, policy', 'You (the provider)', 'Reasoning, tool execution, product UX behind your brand'],
                        ['Agent identity & secret', 'Vibe', 'Shadow user, hashed secret, publish lifecycle, owner config'],
                        ['Discovery card', 'Vibe', 'A2A-compatible JSON for published agents only'],
                        ['HTTP ingress', 'Vibe', '`invoke` + `events` under public-agent rate limit'],
                        ['Payload → UI', 'Vibe clients', 'Native cards, thinking sheets, progress, approvals'],
                        ['Human↔human E2E', 'Vibe', 'Unchanged — agent scope is opt-in per chat'],
                    ]}
                />
            </DocSection>

            <DocSection id="standards">
                <DocH2>Standards alignment</DocH2>
                <DocP>
                    The provider surface is designed to sit on open agent protocol ideas without locking you
                    into a proprietary bot framework.
                </DocP>
                <DocH3>A2A-compatible Agent Card</DocH3>
                <DocP>
                    Published agents expose a card with frozen top-level keys such as{' '}
                    <code>protocolVersion</code>, <code>url</code> (invoke), <code>eventsUrl</code>,{' '}
                    <code>capabilities</code>, <code>defaultOutputModes</code>, <code>securitySchemes</code>,
                    and <code>skills</code>. Only <code>status == "published"</code> agents are served;
                    everything else returns <code>404</code>. No secrets, prompts, budgets, or owner IDs ever
                    appear on the card.
                </DocP>
                <DocH3>MCP-friendly tool model</DocH3>
                <DocP>
                    Tool use is expressed as first-class progress nodes (name, input, status, result). MCP-style
                    tools appear as <code>mcp</code> / server-qualified names in the normalized stream so the
                    agent view can label them without special-casing each host. Providers that already speak
                    MCP-shaped tools map cleanly onto the payload contract.
                </DocP>
                <div className="provider-docs-pill-row">
                    <span className="provider-docs-pill">protocolVersion 0.3.0</span>
                    <span className="provider-docs-pill">kind: vibe.agent-card</span>
                    <span className="provider-docs-pill">X-Vibe-Agent-Secret</span>
                    <span className="provider-docs-pill">MCP tool nodes</span>
                </div>
            </DocSection>

            <DocSection id="native-surface">
                <DocH2>What users see natively</DocH2>
                <DocP>
                    Generic messaging bots typically get a text bubble. On Vibe, agent turns can surface:
                </DocP>
                <DocList items={[
                    <><strong>Runtime / tool cards</strong> — read, edit, write, bash, search, web, MCP, and planning steps with status.</>,
                    <><strong>Thinking</strong> — compact “Thought for Ns” rows with a full chain-of-thought sheet when exposed by the host.</>,
                    <><strong>Diffs &amp; file changes</strong> — edit/create metadata (+N −M when available) without dumping raw patches into chat.</>,
                    <><strong>Live progress</strong> — streaming <code>agent-stream</code> updates while the turn is running; settled result is authoritative.</>,
                    <><strong>Approvals &amp; ask-user</strong> — plan gates and multi-question sheets when the run needs a human decision.</>,
                    <><strong>Subagents / team strips</strong> — lead/worker status for multi-agent runs without flooding the transcript.</>,
                ]} />
            </DocSection>

            <DocSection id="next">
                <DocH2>Next steps</DocH2>
                <DocP>
                    Start with the quickstart, then lock the payload and security models into your integration
                    review.
                </DocP>
                <div className="provider-docs-cards">
                    <button
                        type="button"
                        className="provider-docs-card"
                        onClick={() => navigate('/docs/providers/quickstart')}
                    >
                        <span className="provider-docs-card-kicker">Guide</span>
                        <span className="provider-docs-card-title">Quickstart</span>
                        <p className="provider-docs-card-body">
                            Create an agent, capture the one-time secret, publish, fetch your card, invoke, and
                            push events with curl.
                        </p>
                        <span className="provider-docs-card-cta">Open quickstart →</span>
                    </button>
                    <button
                        type="button"
                        className="provider-docs-card"
                        onClick={() => navigate('/docs/providers/payloads')}
                    >
                        <span className="provider-docs-card-kicker">Reference</span>
                        <span className="provider-docs-card-title">Payload contract</span>
                        <p className="provider-docs-card-body">
                            Parts model, core kinds, extensions, capability coverage, and the coding-agent
                            profile clients already render.
                        </p>
                        <span className="provider-docs-card-cta">Open payloads →</span>
                    </button>
                    <button
                        type="button"
                        className="provider-docs-card"
                        onClick={() => navigate('/docs/providers/security')}
                    >
                        <span className="provider-docs-card-kicker">Trust</span>
                        <span className="provider-docs-card-title">Security model</span>
                        <p className="provider-docs-card-body">
                            Chat scope, hashed secrets, rate-limited ingress, autonomy modes, and what we do
                            not claim.
                        </p>
                        <span className="provider-docs-card-cta">Open security →</span>
                    </button>
                    <button
                        type="button"
                        className="provider-docs-card"
                        onClick={() => navigate('/docs/agents')}
                    >
                        <span className="provider-docs-card-kicker">Owners</span>
                        <span className="provider-docs-card-title">Standalone agents docs</span>
                        <p className="provider-docs-card-body">
                            Field-level config, code samples, and env pack for agent owners building on the
                            same API.
                        </p>
                        <span className="provider-docs-card-cta">Open /docs/agents →</span>
                    </button>
                </div>
            </DocSection>
        </DocsShell>
    );
}
