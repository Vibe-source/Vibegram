# Provider assistant capability surfaces (research inventory)

**Date:** 2026-07-18  
**Purpose:** Inventory of what major AI assistants can do on their own products and inside host platforms, so Vibe’s payload/capability contract does not omit a surface providers already ship.  
**Method:** Web research of primary product/docs pages and reputable secondary sources. Claims without a verifiable public source are marked `[unverified]`. This is a research memo for architecture—not a product commitment.

---

## How to read this document

| Column | Meaning |
|--------|---------|
| **Capability** | What the surface does |
| **Direction** | `in` = user → assistant; `out` = assistant → user/UI; `both` = bidirectional or interactive |
| **Interaction model** | How the human engages (stream, modal, side panel, realtime media, etc.) |
| **Host-app requirements** | What a messenger host (Vibe) would need in its client + wire contract |

---

# 1. ChatGPT (OpenAI app + Apps SDK)

Primary surfaces: ChatGPT web/iOS/Android/desktop; Apps SDK for embedded apps; agent mode (formerly Operator); advanced voice; canvas; deep research; commerce (evolving).

Sources: [Introducing apps in ChatGPT](https://openai.com/index/introducing-apps-in-chatgpt/), [Apps SDK](https://developers.openai.com/apps-sdk), [ChatGPT agent](https://openai.com/index/introducing-chatgpt-agent/), [Operator / CUA](https://openai.com/index/introducing-operator/), [Computer-Using Agent](https://openai.com/index/computer-using-agent/), [Agent help](https://help.openai.com/en/articles/11752874-chatgpt-agent), [Canvas help](https://help.openai.com/en/articles/9930697-what-is-the-canvas-feature-in-chatgpt-and-how-do-i-use-it), [Deep research](https://openai.com/index/introducing-deep-research/), [Code Interpreter API](https://developers.openai.com/api/docs/guides/tools-code-interpreter), [Instant Checkout / ACP](https://openai.com/index/buy-it-in-chatgpt/), [Merchant shopping pivot](https://chatgpt.com/merchants/).

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Streaming text chat** | both | Token/chunk stream in thread; stop/cancel | Streaming message protocol; partial update of a single message ID; cancel/abort; typing/“thinking” state |
| **Advanced Voice Mode** | both | Full-duplex realtime speech; interruptible; low latency; optional visual “speaking” UI | Realtime audio capture/playback (WebRTC or equivalent); duplex stream; barge-in; mic permission UX; background audio policy |
| **Voice + vision / camera / screen** | both | Live camera or screen share into voice session for visual Q&A | Camera/screen capture pipeline; consent; bandwidth; frame sampling into multimodal turns |
| **Vision (image input)** | in | Attach/upload photo or screenshot; multi-image | Image attachments; size limits; EXIF strip policy for E2E; vision-capable turn payloads |
| **Image generation / edit** | out (+ in ref) | Prompt → image; optional reference image transform | Image message type; progress/placeholder; download/share; safety labels |
| **File upload** | in | PDF, sheets, docs, audio, code, etc. as context | Multi-file attach; MIME/size caps; parsing status; encrypted blob storage + provider decrypt path if needed |
| **File download / export** | out | Generated files, canvas exports (PDF/MD/DOCX/code) | Downloadable attachments; open-in-app / share sheet; export formats |
| **Canvas (side workspace)** | both | Split view: chat + editable doc/code; section edit; version history; share/download | Secondary pane UI; artifact binding to conversation; collaborative edit ops; versioning; share links |
| **Code Interpreter / Data Analyst** | both | Sandboxed Python; charts/tables; iterative run | Code-execution result payload: stdout, tables, chart images, downloadable data; run-status; error fix loop UI |
| **Tables / charts / structured viz** | out | Rendered tables, plots from analysis | Rich content blocks: table, chart image/SVG; horizontal scroll; copy CSV |
| **ChatGPT Apps / widgets (Apps SDK)** | both | MCP-backed tools return structured content + UI templates/widgets inline in chat | Widget/iframe or native component runtime; tool-result → UI template mapping; OAuth/consent for apps; sandbox; app directory/discovery |
| **App invocation in natural language** | both | Model picks app/tool mid-conversation; interactive UI (maps, playlists, design tools, etc.) | Tool-call lifecycle UI; app branding; permission prompts; deep-link back to host |
| **Memory (personalization)** | both | Persistent user facts across chats; user can view/edit/forget | Memory store out-of-band from E2E chat crypto (or explicit user export); memory manage UI; clear/opt-out |
| **Connectors / connected apps** | both | OAuth to Gmail, Drive, calendar, GitHub, etc.; deep research pulls from them | Connector registry; OAuth flows; scope consent; connector status; data-use disclosure |
| **Deep Research** | both | Long-running multi-step web research → cited report (minutes) | Long-running job UX; progress; citations list; interim status; resume after app kill |
| **Agent mode (computer use / browser)** | both | Agent uses virtual browser/computer: click, type, scroll; screenshots; multi-step (5–30+ min) | Agent session UI; live/screenshot stream; take-over control; confirmation for sensitive actions; timeout; audit log of steps |
| **Shopping discovery** | out | Product cards, comparison, merchant links | Product card UI; price/merchant fields; external checkout deep links |
| **Instant Checkout / in-chat purchase** | both | Was: buy in-chat via Agentic Commerce Protocol + Stripe (Etsy/Shopify). **As of 2026:** OpenAI pivoted toward discovery + **merchant-owned checkout** rather than standalone Instant Checkout | Commerce card + secure payment handoff **or** redirect-to-merchant; payment PCI boundary; order status messages. Support both models in contract |
| **Message edit / regenerate** | both | Edit prior user msg; regenerate assistant reply; branch | Message versioning; branch tree or replace-in-place; provider re-run API |
| **Thumbs feedback** | in | 👍/👎 on assistant messages | Feedback payload to provider or local only; optional free-text |
| **Projects / workspace context** | both | Grouped chats + files + instructions | Project-scoped context IDs; file sets attached to project not single message |
| **Custom GPTs / custom assistants** | both | System prompt + tools + knowledge as a named assistant | Assistant identity cards; per-assistant capability flags; install/share |
| **Web search / citations** | out | Grounded answers with source links | Citation chips/list; open URL; source domain display |
| **Scheduled / proactive tasks** | out | Agent or reminders that fire later `[partially verified — product exists in agent narratives; exact ChatGPT Tasks surface varies by plan]` | Push notifications; proactive bot messages; schedule + cancel |
| **Group / shared chat with assistant** | both | Multi-user + GPT in one thread `[unverified for full parity across plans]` | Mention-gating; who can invoke tools; shared vs private memory |

### ChatGPT Apps SDK notes (host-critical)

- Apps are built on **MCP** (Model Context Protocol); tools return structured content + templates that the ChatGPT client renders as widgets ([Apps SDK](https://developers.openai.com/apps-sdk), [announcement](https://openai.com/index/introducing-apps-in-chatgpt/)).
- Partners demoed at launch included Spotify, Canva, Zillow, Booking.com, Figma, Coursera, Expedia, etc.—**interactive UIs inside the conversation**, not just text.
- Host implication: a **declarative UI / widget runtime** (or safe webview) is table-stakes for “ChatGPT parity,” not optional polish.

### Agent mode notes

- Operator (Jan 2025) → integrated as **ChatGPT agent mode** (Jul 2025): unified deep research + computer use ([agent post](https://openai.com/index/introducing-chatgpt-agent/), [help](https://help.openai.com/en/articles/11752874-chatgpt-agent)).
- Outputs can include **source links and screenshots**; tasks often 5–30 minutes; user can take over the browser.
- Host implication: long-running **job + live visual feed + human takeover** is a first-class interaction model, separate from “chat reply.”

### Commerce notes (2025–2026)

- Instant Checkout launched Sep 2025 with ACP + Stripe ([buy-it-in-chatgpt](https://openai.com/index/buy-it-in-chatgpt/)).
- By 2026 OpenAI **moved away from standalone Instant Checkout** toward discovery and merchant-owned checkout ([merchants page](https://chatgpt.com/merchants/), [CNBC coverage](https://www.cnbc.com/2026/03/24/openai-revamps-shopping-experience-in-chatgpt-after-instant-checkout.html)).
- Host contract should model **product discovery cards**, **checkout handoff**, and optionally **in-thread payment** (other hosts still do in-chat pay).

---

# 2. Claude (Anthropic app + host integrations)

Primary surfaces: claude.ai, Claude Desktop, Claude Code; Artifacts; MCP connectors; computer use; Claude in Slack / third-party hosts.

Sources: [Artifacts help](https://support.claude.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them), [Artifacts intro](https://www.anthropic.com/news/claude-3-5-sonnet), [Computer use](https://www.anthropic.com/news/developing-computer-use), [Computer use tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool), [Custom MCP connectors](https://support.claude.com/en/articles/11175166-getting-started-with-custom-connectors-using-remote-mcp), [Claude in Slack (Slack help / marketplace context)](https://slack.com/help/articles/33076000248851-Work-with-AI-agents-and-assistants-in-Slack).

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Streaming text** | both | Streaming assistant turns | Same as ChatGPT streaming |
| **Artifacts (side panel)** | both | Significant self-contained content in dedicated window: docs, code, HTML, SVG, React apps; iterate/version/export | Artifact pane; types: markdown, code, HTML preview, SVG, interactive React; version selector; download/copy; multi-artifact switcher |
| **In-place edit of artifacts** | both | Highlight text → “Edit with Claude”; batch multi-file edit requests | Selection-scoped edit intents; apply-to-range ops |
| **AI-powered artifacts** | both | Shared apps that call Claude for each end-user (usage on user’s plan) | Embedded mini-app runtime + per-user auth to model; usage attribution |
| **Artifact MCP integration** | both | Artifacts call MCP tools (Asana, Calendar, Slack, custom); first-use approve | Per-tool consent; connector auth; tool result into artifact UI |
| **Persistent artifact storage** | both | Personal or shared 20MB text storage per published artifact | Stateful app storage; personal vs shared; confirm shared visibility |
| **Publish / share / remix artifacts** | out | Public or org share; gallery; remix | Share URLs; access control; fork |
| **Code execution & file creation** | both | Required for modern artifacts; sandboxed code + create files | Capability toggle; sandboxed run; file outputs |
| **File upload / download** | both | Docs, data, code as context; download generated files | Same file attachment model |
| **Extended thinking / chain-of-thought display** | out | Collapsible “thinking” or reasoning steps before/with answer | Thinking block UI (expand/collapse); stream thinking separately from final; optional hide for user preference |
| **Tool use / MCP connectors** | both | Remote MCP servers; official + custom connectors | Tool-call cards; OAuth; admin allowlists (enterprise) |
| **Computer use** | both | Screenshot → plan → mouse/keyboard actions on desktop/VM | Screen stream or screenshots; action log; pause/stop; elevated consent; local agent bridge or remote desktop |
| **Desktop / mobile Dispatch-style control** | both | Control user’s machine via app (see product evolution 2025–26) | Local companion agent; OS accessibility permissions; safety kill-switch |
| **Voice** | both | Voice mode available on Claude mobile/desktop products in 2025–2026 timeframe ([product coverage](https://www.androidauthority.com/claude-ai-voice-mode-3542121/); exact feature matrix by plan `[verify at ship]`) | Same duplex audio stack as other providers |
| **Claude in Slack / workspace hosts** | both | Bot/assistant in channels; mention or DM; workspace context | Host-platform bot patterns: streaming, threads, mention-gating, rich blocks |
| **Projects / knowledge** | both | Project knowledge bases | Project-scoped RAG; file sets |
| **Thumbs / feedback** | in | Message rating | Feedback events |
| **Citations / analysis sources** | out | Links and source attribution when browsing/tools used | Citation UI |
| **Artifacts gallery sidebar** | out | Browse past artifacts outside a single chat | Global artifact library not only per-message |

### Claude-specific host implications

- **Artifacts ≈ Canvas + interactive apps**: side-panel workspace with live HTML/React is core Claude identity, not a niche feature ([Artifacts help](https://support.claude.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them)).
- **MCP is first-class** for tools and for artifact-backed apps—aligns with OpenAI Apps SDK also being MCP-based; host should treat **MCP tool + UI template** as a shared industry pattern.
- **Computer use** is API-first (screenshots + mouse/keyboard tools) and productized in desktop flows ([computer use announcement](https://www.anthropic.com/news/developing-computer-use)).

---

# 3. Gemini (Google)

Primary surfaces: Gemini app (web/Android/iOS), Gemini Live, Canvas, Gems, Workspace integrations, image/video/music gen (feature set expands by plan/region).

Sources: [Gemini Canvas](https://gemini.google/overview/canvas/), [Canvas + Audio Overview blog](https://blog.google/products-and-platforms/products/gemini/gemini-collaboration-features/), [File upload help](https://support.google.com/gemini/answer/14903178), [Gems](https://gemini.google/overview/gems/), [Gemini Live (product overview references on gemini.google)](https://gemini.google/).

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Streaming text** | both | Standard chat stream | Streaming messages |
| **Gemini Live** | both | Realtime voice conversation; camera/screen context | Duplex audio + optional camera/screen; Live session state |
| **Vision / camera** | in | Photos, live camera into Live or chat | Image + live video frames |
| **File upload & analyze** | in | Docs, sheets, photos, video, NotebookLM notebooks | Multi-modal file types including video |
| **Canvas** | both | Interactive doc/code/app/game space; prompt → prototype | Side workspace like ChatGPT/Claude |
| **Image generation / edit** | out | Native image gen in product + API models | Image messages |
| **Video / music generation** | out | Product-listed modalities on Gemini overview | Media message types; long-gen progress |
| **Audio Overview** | out | Turn files into podcast-style audio discussions | Audio attachment playback; multi-speaker audio |
| **Gems (custom assistants)** | both | Saved instructions + optional file knowledge | Custom assistant profiles + knowledge packs |
| **Deep Research** | both | Multi-step research reports `[product feature on Gemini Advanced tier — confirm plan gates]` | Long-running research job UI |
| **Google Workspace grounding** | both | Drive, Gmail, Docs context (Workspace plans) | Connector to Google account; ACL respect |
| **Extensions / tools** | both | YouTube, Maps, flights, etc. (varies over time) | Tool cards + external deep links |
| **Citations / Google Search grounding** | out | Search-grounded answers with links | Citation UI |
| **Share / export Canvas** | out | Shareable prototypes/apps | Share links; embed previews |

---

# 4. Grok (xAI) + X integration

Primary surfaces: grok.com, Grok iOS/Android apps, X (twitter.com) integration, Imagine (image/video), Voice API.

Sources: [x.ai/grok](https://x.ai/grok), [x.ai API](https://x.ai/api), [Models docs](https://docs.x.ai/developers/models), secondary feature roundups (DeepSearch, Imagine, voice).

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Streaming text / reasoning** | both | Chat with optional deep reasoning modes | Stream + optional thinking/trace UI |
| **Real-time X + web search** | both | Ground answers in live X posts and web | Search tool status; cite X posts and URLs; post embed previews |
| **DeepSearch / research agent** | both | Multi-step retrieval loop over web + X | Long-running research status; source list |
| **Image generation (Imagine)** | out | Text/ref → image | Image messages |
| **Video generation (Imagine)** | out | Text/image → short video (seconds–15s class products) | Video messages; generation progress; aspect ratio |
| **Voice mode** | both | Natural low-latency voice; multiple voices; STT/TTS API | Realtime audio; voice picker |
| **Camera mode** | in | Visual input during voice (reported mid-2025+) | Camera frames into multimodal turns |
| **Code generation** | out | Code in-thread | Code blocks + copy/run optional |
| **X platform embedding** | both | Grok as participant inside X DMs/UI for subscribers | Social-host patterns: rate limits, public vs private context, media-heavy timeline |
| **Companions / persona UI** | both | Character-style companions `[verify current shipping set]` | Persona avatars; voice personality |
| **File / image upload** | in | Multimodal inputs on app/API | Attachments |

### Grok host notes

- Differentiator is **live social graph / X firehose grounding** plus strong **image+video gen** and **voice**.
- Host contract needs **first-class media generation jobs** and **citation of social posts**, not only academic-style links.

---

# 5. Microsoft Copilot (Teams / M365)

Primary surfaces: Microsoft 365 Copilot, Copilot Chat, Teams meetings/chat, Copilot Studio agents, Graph-grounded actions.

Sources: [Copilot Studio agents](https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/agent-types), [Teams Copilot extensibility](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/teams-conversational-ai/teams-conversation-ai-overview), product feature pages for M365 Copilot.

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Chat in Teams / M365 shell** | both | Side pane, chat, or meeting context | Assistant pane + thread participation |
| **Graph / org grounding** | both | Answers from mail, files, calendar, chats (permissions-bound) | Enterprise connector + ACL-aware RAG |
| **Meeting assist** | both | Recap, notes, action items from calls | Meeting artifact messages; summaries |
| **Agents (Copilot Studio)** | both | Declarative/custom agents with tools & topics | Agent directory; tool actions; handoff |
| **Plugins / actions** | both | Call business systems (CRM, ITSM, etc.) | Action cards; confirmation; result blocks |
| **Adaptive Cards / rich UI** | out | Structured interactive cards in Teams | Card schema renderer (inputs, buttons, tables) |
| **File analysis / Office create** | both | Summarize docs; draft Word/Excel/PowerPoint | File IO; generate downloadable Office docs |
| **Image generation (Designer)** | out | Images in Copilot experiences | Image messages |
| **Voice** | both | Voice in Copilot mobile / Windows experiences | Audio I/O |
| **Streaming responses** | out | Progressive replies in chat | Stream protocol |
| **Human handoff** | both | Escalate from bot/agent to human agent (common in enterprise bots) | Transfer-to-human protocol; queue state |
| **Enterprise admin controls** | in | DLP, retention, audit | Compliance hooks (outside pure chat payload but host must allow) |

---

# 6. Host-platform precedents (bots / mini-apps)

These define what users already expect from **rich participants** inside messengers—not only from first-party AI apps.

## 6.1 Telegram Bot API + Mini Apps

Sources: [Telegram Mini Apps](https://core.telegram.org/bots/webapps), [Bot API payments / Stars](https://core.telegram.org/bots/api), Bot API feature notes.

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Reply keyboards** | out | Custom keyboard under composer | Keyboard markup payload |
| **Inline keyboards** | out | Buttons under a message (callback, URL, web_app, pay) | Inline button rows; callback queries |
| **Inline mode** | both | `@bot query` results inserted into any chat | Inline query protocol; result cards |
| **Mini Apps (Web Apps)** | both | Full web app inside Telegram client; auth; theme | In-app browser/webview; initData auth; main-button; theme vars |
| **Payments (providers + Stars)** | both | Invoices, Apple/Google Pay, Telegram Stars for digital goods | Invoice messages; payment provider; refunds; digital goods rules |
| **Subscriptions / gifts (Stars)** | both | Paid tiers inside Mini Apps | Entitlement state; paywall UI |
| **File / media send** | both | Photos, docs, voice, video notes | Full media matrix |
| **Commands / menus** | in | `/start`, bot menu button | Command registry; menu button → mini-app |
| **Proactive messages** | out | Bot messages without user prompt (subject to rules) | Push + chat write; rate limits; block |
| **Group bots + privacy mode** | both | Mention-only or all messages | Mention-gating; admin policies |
| **Webhooks / long polling** | both | Event delivery to bot backend | Delivery guarantees (E2E complicates this) |
| **Login / seamless auth** | both | Telegram identity into mini-app | Identity assertion without password |

## 6.2 Slack (Block Kit + AI apps)

Sources: [Developing agents](https://docs.slack.dev/ai/developing-agents), [Work with AI agents in Slack](https://slack.com/help/articles/33076000248851-Work-with-AI-agents-and-assistants-in-Slack), [Thinking Steps](https://slack.dev/slack-thinking-steps-ai-agents/), Block Kit agent components.

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Block Kit rich messages** | out | Sections, actions, images, tables, cards, carousels, work objects | Declarative block layout engine |
| **Interactive components** | both | Buttons, selects, modals, date pickers | Interaction callback routing |
| **Text streaming** | out | `chat.startStream` / `appendStream` / `stopStream` | Native stream API for bots |
| **Thinking Steps / status** | out | Live tool-call and reasoning steps in UI | Structured status timeline separate from final answer |
| **Task cards / plan blocks** | out | Agent plan and task progress | Plan/task UI primitives |
| **Assistant pane / split view** | both | Dedicated AI side pane with prompt chips | Assistant surface beyond channel messages |
| **Threads** | both | Reply-in-thread as unit of work | Thread IDs; agent context = thread |
| **Slash commands** | in | `/command args` | Command dispatch |
| **App Home / Messages tab** | both | DM-like surface with agent | Per-app conversation surface |
| **Mention vs channel participation** | both | Agents in channels with visibility rules | Group etiquette controls |
| **Enterprise search / context** | in | Agents read workspace context | Permissioned context APIs |

## 6.3 Discord

Sources: [Discord components reference](https://docs.discord.com/developers/components/reference), Components V2 docs/guides, slash command interaction model.

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Slash commands** | in | `/cmd` with typed options; autocomplete | Command schema + picker UX |
| **Embeds** | out | Rich cards: title, fields, image, footer | Embed renderer |
| **Components V2** | both | Containers, sections, media galleries, files, buttons, selects composed as layout | Component tree messages (not only text+embed) |
| **Buttons / select menus** | both | Interactive message components | Interaction tokens; ephemeral replies |
| **Modals** | both | Form popups from interactions | Modal presentation |
| **Ephemeral messages** | out | Only invoker sees response | Per-user visibility on messages |
| **Attachments / stickers / polls** | both | Media and native poll UX | Poll message type |
| **Voice channels** | both | Bots in voice `[AI voice agents less standardized]` | Audio channel participation |
| **Permissions / roles** | in | Role-gated commands | Capability ACL |

## 6.4 WeChat mini-programs

Sources: WeChat open platform documentation (mini program + Official Accounts); industry summaries of mini-program chat integration.

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Mini Programs** | both | Full JS app runtime inside WeChat; services, commerce, games | Embedded app runtime + identity + payments |
| **Official Account / customer service messages** | both | Template messages, menus, rich media | Broadcast + session message types |
| **Payments (WeChat Pay)** | both | In-app commerce | Payment sheet integration |
| **Template / subscription messages** | out | Proactive notifications with user opt-in | Consent-based push |
| **Rich media cards** | out | News, mini-program cards, images | Card deep-links into mini-apps |
| **Identity / phone binding** | both | Platform identity for services | Hosted auth |

---

# 7. Cross-cutting capability patterns

These recur across providers and hosts. A host messenger contract should express them once, then map providers onto them.

| Capability | Direction | Interaction model | Host-app requirements |
|------------|-----------|-------------------|------------------------|
| **Streaming text UX** | out | Token stream; stop button | Stream protocol; cancel; coalesce for E2E if needed |
| **Typing / “thinking” / tool status** | out | “Assistant is typing”, tool-running, step list | Status channel distinct from content |
| **Citations / sources** | out | Inline footnotes, chips, source panels | Citation objects: url, title, snippet, favicon |
| **Message edit** | both | Edit user prompt → rebranch | Versioned messages |
| **Regenerate / retry** | both | New sample of same turn | Alternate responses; keep/branch |
| **Threading** | both | Side conversations; agent work unit | Thread model |
| **Feedback (thumbs ± text)** | in | Quality signal | Feedback events (local and/or provider) |
| **Handoff to human** | both | Bot → human agent with context | Transfer state; transcript package |
| **Payments / commerce** | both | Invoice, checkout, refunds, subscriptions | Commerce message types + PCI boundary |
| **Notifications / proactive** | out | Reminders, completed agent jobs, digests | Push; quiet hours; user mute of bots |
| **Group participation etiquette** | both | Mention-only, reply-only, always-on | Per-chat bot policy; admin controls |
| **Safety / consent prompts** | both | Allow mic, screen, computer control, connectors, shared memory | Permission prompts with scope + revoke |
| **Long-running jobs** | both | Research/agent tasks minutes–hours | Job IDs; progress; resume; notify on complete |
| **Takeover / human-in-the-loop** | both | User takes browser/computer mid-agent | Control transfer UX |
| **Multimodal I/O matrix** | both | Text, image, audio, video, files, live AV | Unified attachment + live session types |
| **Sandbox code execution outputs** | out | Tables, charts, files, errors | Structured execution results |
| **Declarative UI / widgets** | both | Apps SDK / Block Kit / Components / Adaptive Cards | Host UI runtime or secure webview |
| **Connectors / OAuth tools** | both | External systems as tools | Connector framework + consent |
| **Memory / personalization** | both | Cross-session state | Memory API + user controls |
| **Custom assistant identities** | both | GPTs, Gems, agents, personas | Installable assistant profiles |
| **Share / export / remix** | out | Share canvas/artifact/app | Share links; fork; export formats |
| **Rate limits / plan gates** | out | Soft failures when quota hit | Quota error UX; upgrade CTAs (optional) |
| **Safety refusals / policy** | out | Structured refusal | Distinct refusal presentation |
| **Audit / compliance logs** | out | Enterprise agent action logs | Admin-visible action history |

---

# 8. Union checklist

Deduped capabilities a **host messenger provider-contract** must be able to express. Ranked for Vibe architecture priority.

## 8.1 Table-stakes (ship or you lack basic assistant parity)

| # | Capability | Why table-stakes |
|---|------------|------------------|
| 1 | **Streaming text messages** with stop/cancel | Universal assistant UX |
| 2 | **Typing / generating / tool-running status** | Users expect progress feedback |
| 3 | **Multimodal attachments in** (images, files, audio; video where feasible) | Vision + docs are default inputs |
| 4 | **Multimodal attachments out** (images, files, audio clips) | Gen + analysis outputs |
| 5 | **Code blocks + copy** | Coding use case |
| 6 | **Citations / source links** | Search-grounded answers |
| 7 | **Message regenerate + edit-and-resubmit** | Core chat affordance |
| 8 | **Thumbs up/down feedback** | Provider + product quality loop |
| 9 | **Assistant identity** (name, avatar, provider, model/capability badges) | Multi-provider participant model |
| 10 | **Per-chat / per-user consent** for tools, memory, media | Safety + E2E trust |
| 11 | **Error / refusal / quota** structured outcomes | Graceful failure |
| 12 | **Threading or reply-context** | Multi-turn clarity in groups |
| 13 | **Group mention-gating / bot policies** | Host messenger reality |
| 14 | **Link previews / basic rich cards** | Product cards, sources, apps |
| 15 | **Downloadable file results** | Code interpreter / exports |

## 8.2 Differentiator (needed to match “full” ChatGPT/Claude/Gemini surfaces)

| # | Capability | Why differentiator |
|---|------------|-------------------|
| 16 | **Side workspace / Canvas / Artifacts pane** | Writing/coding iteration is a primary product surface |
| 17 | **Interactive widgets / embedded apps** (MCP Apps SDK, Block Kit–class UI) | ChatGPT Apps + Slack agents + Telegram mini-apps |
| 18 | **Realtime duplex voice** | Advanced Voice / Gemini Live / Grok Voice |
| 19 | **Live camera / screen share into session** | Voice+vision workflows |
| 20 | **Sandboxed code execution result types** (tables, charts, artifacts) | Data analyst mode |
| 21 | **Connectors / OAuth tool framework** | Memory-of-world + work tools |
| 22 | **User-visible memory management** | Cross-chat personalization with control |
| 23 | **Long-running research/agent jobs** with progress + completion push | Deep Research / agent mode |
| 24 | **Computer-use / browser-use sessions** (screenshots, actions, takeover) | Operator / Claude computer use / agent mode |
| 25 | **Extended thinking / step timeline UI** | Claude thinking, Slack Thinking Steps, agent traces |
| 26 | **Custom assistant install** (GPT/Gem/agent profiles) | Ecosystem of specialized assistants |
| 27 | **Share / publish / remix** of canvases/artifacts/apps | Collaborative artifact economy |
| 28 | **Commerce: product cards + checkout handoff** (and optional in-chat pay) | Shopping + Telegram payments precedent |
| 29 | **Proactive notifications** for finished jobs / reminders | Agents that work while user is away |
| 30 | **Declarative interactive components** (buttons, selects, forms, modals) | Telegram/Slack/Discord parity for tool UX |
| 31 | **Secure webview / mini-app runtime** | Telegram Mini Apps / WeChat pattern for full apps |
| 32 | **Image + short video generation job UX** | Grok Imagine / Gemini media |

## 8.3 Emerging (fast-moving; contract should leave extension points)

| # | Capability | Notes |
|---|------------|-------|
| 33 | **In-thread agentic checkout / ACP-style commerce** | OpenAI piloted then pivoted; protocol still relevant for other providers/hosts |
| 34 | **Multi-agent orchestration in one thread** | Multiple providers/tools collaborating |
| 35 | **Shared multi-user artifacts with CRDT-like edits** | Team canvas |
| 36 | **Persistent mini-app storage** (Claude artifact storage model) | Stateful apps inside chat |
| 37 | **Live HTML/React apps with per-viewer model billing** | AI-powered artifacts |
| 38 | **Desktop OS control via local companion** | Beyond remote browser VM |
| 39 | **Voice clones / multi-voice personas** | Grok multi-voice; companion products |
| 40 | **Music generation / long-form audio overviews** | Gemini Audio Overview class |
| 41 | **Meeting-native assist** (live transcript + actions) | Copilot Teams class |
| 42 | **Enterprise audit trails of every agent GUI action** | Compliance |
| 43 | **Ephemeral / viewer-only messages** | Discord-style private bot replies in groups |
| 44 | **Inline query mode** (`@assistant find…` from any chat) | Telegram inline bots |
| 45 | **Subscription entitlements inside chat apps** | Telegram Stars subscriptions |
| 46 | **Human agent handoff queues** | Enterprise support bots |
| 47 | **Cross-provider memory portability** | User-owned memory export |
| 48 | **On-device / private compute tool routing** | E2E-friendly local tools |
| 49 | **Real-time collaborative agent + human co-editing** | Pair-programming with canvas |
| 50 | **Safety classifiers / consent for computer use & payments** | Standardized “sensitive action” prompts |

---

# 9. Implications for Vibe’s payload / capability contract

Architecture takeaways (research → design, not implementation):

1. **Three layers of “message,” not one**  
   - **Content stream** (text/markdown)  
   - **Status stream** (typing, tools, thinking steps)  
   - **Artifact/session stream** (canvas, computer-use, voice session, research job)  
   Hosts that only model chat bubbles will fail Canvas/Artifacts/Agent parity.

2. **UI is a first-class payload**  
   Industry converged on **MCP tools + structured UI** (OpenAI Apps SDK) and **block/component systems** (Slack, Discord, Adaptive Cards). Vibe needs a **capability-versioned UI schema** (or sandboxed webview contract) providers can target.

3. **Long-running work is normal**  
   Deep research and agent mode run for minutes. Contract needs **job lifecycle**: start, progress, partial artifacts, complete, fail, cancel, notify.

4. **Consent is part of the protocol**  
   Mic, camera, screen, computer control, connectors, shared storage, payments—all need **scoped, revocable grants** visible in UX and on the wire.

5. **E2E encryption tension (flag for design)**  
   Connectors, provider-side memory, code interpreter VMs, and computer-use VMs imply **provider-visible plaintext** for those modes. Contract should mark capabilities as `e2e_compatible | provider_processed | local_device` so the client can warn and gate.

6. **Group chat is not DM**  
   Mention-gating, ephemeral replies, who pays for tokens, whose memory applies, and who can authorize tools must be explicit.

7. **Commerce should be abstracted**  
   Support **discover → handoff** and **in-chat invoice/pay** without hard-coding Instant Checkout.

8. **Parity matrix for provider onboarding**  
   When a provider plugs in, declare supported capability flags from the union checklist (voice duplex? artifacts? computer use? widgets?). Client renders only claimed surfaces.

---

# 10. Source index (verified URLs)

| Topic | URL |
|-------|-----|
| ChatGPT Apps announcement | https://openai.com/index/introducing-apps-in-chatgpt/ |
| Apps SDK | https://developers.openai.com/apps-sdk |
| ChatGPT agent | https://openai.com/index/introducing-chatgpt-agent/ |
| Agent help | https://help.openai.com/en/articles/11752874-chatgpt-agent |
| Operator | https://openai.com/index/introducing-operator/ |
| Computer-Using Agent | https://openai.com/index/computer-using-agent/ |
| Canvas help | https://help.openai.com/en/articles/9930697-what-is-the-canvas-feature-in-chatgpt-and-how-do-i-use-it |
| Deep research | https://openai.com/index/introducing-deep-research/ |
| Code Interpreter | https://developers.openai.com/api/docs/guides/tools-code-interpreter |
| Instant Checkout / ACP | https://openai.com/index/buy-it-in-chatgpt/ |
| Shopping / merchant pivot | https://chatgpt.com/merchants/ |
| Claude Artifacts help | https://support.claude.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them |
| Claude 3.5 / Artifacts intro | https://www.anthropic.com/news/claude-3-5-sonnet |
| Claude computer use | https://www.anthropic.com/news/developing-computer-use |
| Computer use tool docs | https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool |
| Claude MCP connectors | https://support.claude.com/en/articles/11175166-getting-started-with-custom-connectors-using-remote-mcp |
| Gemini Canvas | https://gemini.google/overview/canvas/ |
| Gemini collaboration features | https://blog.google/products-and-platforms/products/gemini/gemini-collaboration-features/ |
| Gemini file upload | https://support.google.com/gemini/answer/14903178 |
| Gemini Gems | https://gemini.google/overview/gems/ |
| Grok product | https://x.ai/grok |
| xAI API | https://x.ai/api |
| xAI models | https://docs.x.ai/developers/models |
| Copilot Studio agents | https://learn.microsoft.com/en-us/microsoft-copilot-studio/guidance/agent-types |
| Teams conversational AI | https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/teams-conversational-ai/teams-conversation-ai-overview |
| Telegram Mini Apps | https://core.telegram.org/bots/webapps |
| Slack developing agents | https://docs.slack.dev/ai/developing-agents |
| Slack AI agents help | https://slack.com/help/articles/33076000248851-Work-with-AI-agents-and-assistants-in-Slack |
| Slack Thinking Steps | https://slack.dev/slack-thinking-steps-ai-agents/ |
| Discord components | https://docs.discord.com/developers/components/reference |

---

# 11. Gaps / follow-ups

- **Exact plan-gated matrices** (Free vs Plus vs Pro vs Enterprise) change frequently; re-verify before locking MVP flags.
- **Claude voice** and **desktop computer-use productization** details should be re-checked against Anthropic’s current help center at implementation time.
- **WeChat** primary docs are often Chinese-language / partner-portal gated; treat mini-program row as pattern-level, not API-complete.
- **E2E + provider tools** needs a dedicated threat model (not covered in depth here).
- **Provider API vs consumer app** gaps: some surfaces (Canvas UI, Artifacts panel chrome) exist only in first-party apps; providers may not expose equivalent APIs for third-party hosts—contract must allow **host-rendered approximations** when API returns only structured data.

---

*End of research inventory. Single deliverable file for Vibe platform architecture.*
