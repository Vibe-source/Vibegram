# Agent Computer v1 — the visible machine, takeover, and logged-in work

Each agent already has a container (`docs/agent-platform-v1.md` §3.6). This spec makes it
**visible**, **drivable by the owner for a moment**, and **logged in** — so a social-media
manager, an email/marketing manager or an SEO agent can do real work on real accounts.

Sibling spec, not a rewrite: everything here rides the existing sandbox gateway, run stream
and approval path. Nothing in §3 of the platform spec changes.

## 0. Decisions (frozen)

1. **The computer is browser-first, not a desktop.** Every use case named for v1 — social
   accounts, Gmail/marketing, Search Console, Firebase console — is a web app. A window
   manager, file manager and VNC stack would cost RAM and bandwidth for pixels nobody needs.
2. **Pixels are for the human; structure is for the model.** The screencast never enters the
   LLM context. The agent reasons over `browser_snapshot` (a numbered accessibility/DOM
   digest, ~0.8k tokens) instead of screenshots (~1.1k tokens *per image*, uncacheable in
   practice). This is the single largest cost lever in the whole feature — see §4.
3. **Chrome runs headed under Xvfb, and the browser chrome is drawn natively on iOS.**
   Frames come from CDP `Page.startScreencast` (viewport only). Xvfb + headed costs ~100 MB
   over headless and buys a real-browser fingerprint — headless Chromium is refused by Google
   sign-in, which would kill Search Console and Firebase on day one.
4. **We never hold the user's passwords.** Authentication happens by **handing the keyboard
   to the owner** inside the agent's own browser (§3.5). Cookies land in the agent's
   persistent profile volume; credentials never touch our DB, and we never ask a user to
   type a Google password into Vibe.
5. **Idle costs nothing, watching costs only while watched.** No viewer ⇒ no screencast ⇒
   Chrome encodes nothing. No activity ⇒ browser exits ⇒ container stops ⇒ only the volume
   remains. Live computers are admission-controlled like runs.
6. **A computer's reach is a grant, not the open web.** Per-agent domain allowlist, set by
   the owner when they connect an account. The global egress denylist stays underneath it.

## 1. What exists, and the four gaps

Built (2026-08-29): `sandbox-gateway` one container per `agent:<id>`, persistent volume
`/home/agent`, read-only rootfs, `cap-drop ALL`, egress proxy, idle reaper; `vibe-sandbox`
image with bash/python/node/chromium; `browser.js` driving **one persistent Chromium over
CDP** with `--user-data-dir=/home/agent/.vibe-browser`, so cookies already survive; tools
`computer_run` / `computer_read_file` / `computer_write_file` / `browser_open` / `browser_act`
/ `browser_screenshot`; `run.preview` → core `"agent-preview"` → iOS.

| Gap | Consequence today |
|---|---|
| One JPEG per tool call, no stream | You cannot watch; you get stills after the fact |
| No human input path into the browser | No login ⇒ no account work at all ⇒ the named use cases are impossible |
| Preview lives only on the runtime's internal API | No public route, no iOS surface beyond the inline card |
| Profile readable by the agent's own shell | A prompt-injected agent can `cat` the cookie DB into chat |

v1 closes all four.

## 2. Surfaces

**Entry points.** (a) The inline `run.preview` card in the transcript becomes tappable.
(b) A **Computer** button in the agent's chat header and on the agent profile card.
(c) A push when an agent asks for control (§3.5).

**The Computer sheet** — one surface, three tabs:

| Tab | Content | Source |
|---|---|---|
| **Screen** | Live viewport with natively drawn chrome: favicon, title, URL pill, load bar, LIVE dot. Bottom bar: `Take control` · `Pause` · `Stop`. | `computer:<agentId>` frames |
| **Terminal** | Read-only console of `computer_run` commands and their output, newest last. | existing `run.tool.*` events |
| **Files** | `/home/agent` tree, tap to preview text/images. Read-only in v1. | gateway `/tree` + `/files` |

Chrome is reconstructed on iOS rather than captured, so the URL bar, tabs and dialogs are
native controls — legible on a 6" screen, and the user never needs to hit a 12 px browser
target. Native dialogs (basic auth, file chooser, `alert`) are intercepted over CDP and
re-presented as iOS sheets.

**Not in v1:** multi-tab switching from the phone (single active tab), video/audio capture,
clipboard sync, a real desktop.

## 3. Contracts (frozen)

### 3.1 Gateway — computer sessions (`sandbox-gateway`, header `x-sandbox-token`)

Added to §3.6 of the platform spec. All routes are per sandbox id.

| Route | Body → Response |
|---|---|
| `POST /v1/sandboxes/:id/computer/session` | `{viewerId, width?, height?, fps?, quality?}` → `{sessionId, width, height, fps, wsUrl, expiresAt}` |
| `DELETE /v1/sandboxes/:id/computer/session/:sessionId` | → `{sessionId, status:"closed"}` |
| `GET /v1/sandboxes/:id/computer/state` | → `{url, title, faviconBase64?, loading, tabCount, control, awaitingDialog?}` |
| `POST /v1/sandboxes/:id/computer/control` | `{action:"grant"\|"release", holder:"user"\|"agent", ttlSeconds?}` → `{control, expiresAt}` |
| `POST /v1/sandboxes/:id/computer/input` | `{kind, x?, y?, text?, key?, deltaY?, sessionId}` → `{ok, url, title}` — **rejected `409` unless `control == "user"` and `sessionId` holds it** |
| `POST /v1/sandboxes/:id/computer/snapshot` | `{mode:"digest"\|"text"}` → `{url, title, elements:[{ref,role,name,value?,box}], text?}` |
| `POST /v1/sandboxes/:id/computer/grants` | `{domains:[…]}` → `{domains}` (replaces; empty = deny all) |
| `WS /v1/sandboxes/:id/computer/stream?session=` | binary frames, below |

**Frame (binary, WS).** `[1 byte version=1][1 byte kind][4 byte BE seq][payload]`.
`kind 0x01` = JPEG viewport frame. `kind 0x02` = JSON state delta (url/title/loading/control).
Never base64 on this path. Server drops the oldest undelivered frame per viewer — it never
queues. One frame in flight per viewer; a viewer that has not acked `seq` is skipped, not
buffered.

**Phase 1 ships pull + base64 instead**, behind these same route and event names:
`GET …/computer/frame?since=<seq>` returns `204` when nothing is newer and otherwise
captures through the existing screenshot path, one in-flight capture per sandbox so N
viewers share one; the channel carries `imageBase64`, the shape iOS already decodes for
`agent-preview`. `Page.startScreencast` and binary frames are a later optimisation that
does not change the contract. Deviation recorded in `.vibe/board-agent-computer.md`.

Session limits: `fps ≤ 8`, `width ≤ 900`, `quality ≤ 70`, hard session cap
`COMPUTER_SESSION_MAX_SECONDS` (default 900). Screencast starts on the **first** viewer and
stops `COMPUTER_SCREENCAST_GRACE_MS` (default 5000) after the **last** one detaches.

### 3.2 Runtime → core → iOS

The phone never talks to the gateway. Core route
`GET /api/agents/:id/computer/session` (authenticated; **owner only**, not every chat
participant) → runtime `POST /internal/v1/agents/:agent_id/computer/session` → gateway.
Returns `{sessionId, wsUrl, token, expiresAt, width, height, control}` where `wsUrl` points at
the **core**, which relays. Token: `Phoenix.Token`, salt `"computer-session"`, 10-minute join
window, bound to `{agentId, userId, sessionId}`.

Channel `computer:<agentId>` on the existing socket.

| Direction | Event | Payload |
|---|---|---|
| → client | `frame` | binary, §3.1 |
| → client | `state` | `{url, title, loading, control, holder, expiresAt, tabCount}` |
| → client | `dialog` | `{kind:"alert"\|"confirm"\|"prompt"\|"basic_auth"\|"file", message?, defaultText?}` |
| → client | `session_ended` | `{reason:"idle"\|"cap"\|"agent_resumed"\|"stopped"\|"error"}` |
| client → | `input` | `{kind:"click"\|"type"\|"key"\|"scroll"\|"back"\|"navigate", …}` |
| client → | `control` | `{action:"take"\|"release", ttlSeconds?}` |
| client → | `ack` | `{seq}` |

Rate limit inbound `input` at 20/s per session; excess is dropped, not queued.

The Terminal and Files tabs are plain owner-only HTTP reads on the same core prefix, not
channel traffic: `GET /api/agents/:id/computer/exec-log?since=&limit=` (the shell the agent
ran here), `GET …/computer/tree?path=&depth=` and `GET …/computer/file?path=`. All three are
read-only — there is no owner-driven exec route.

### 3.3 Tools (agent-facing)

Replacing pixel-first browsing with structure-first. `browser_screenshot` stays but is
demoted — the system prompt tells the agent to prefer `browser_snapshot`.

| Tool | Input → Result | Notes |
|---|---|---|
| `browser_snapshot` | `{mode?}` → `{url, title, elements:[{ref, role, name, value?}], text}` | **Default way to see a page.** `ref` is stable within a page load. ~0.8k tokens. |
| `browser_act` | `{kind, ref?\|selector?\|x,y, text?}` | `ref` from the snapshot is preferred over CSS selectors |
| `browser_open` | `{url}` | Blocked with `denied_domain` if outside the grant |
| `browser_screenshot` | — | Emits `run.preview`; for the human, not for reasoning |
| `computer_request_control` | `{reason, url}` → `{granted, note?}` | Asks the owner to take over — §3.5 |
| `computer_run` / `computer_read_file` / `computer_write_file` | unchanged | Now run as uid 1000, which **cannot read the browser profile** (§5) |

### 3.4 RunEvent additions (`vibe.agentic.v1`)

| kind | payload |
|---|---|
| `run.computer.state` | `{url, title, live:boolean}` — lets the transcript show "on instagram.com" without a screenshot |
| `run.computer.control` | `{holder:"user"\|"agent", reason?, expiresAt?}` |

Core relay: both broadcast on `chat:<chatId>` as `"agent-computer"` with the same payload plus
`chatId, runId, agentUserId`. `run.preview` → `"agent-preview"` is unchanged.

### 3.5 Control handover — the login flow

The whole feature stands on this. Two ways in.

**Owner-initiated.** Owner opens the Computer sheet → `Take control` → `control {action:"take"}`.
If a run is active, the runtime **pauses the loop at the next step boundary** (no partial tool
call is interrupted) and emits `run.computer.control {holder:"user"}`. The transcript shows
*"You're driving — the agent is waiting."* Control auto-releases after `ttlSeconds` (default
300, extendable) or on `Give back`.

**Agent-initiated.** The agent hits a sign-in wall, a 2FA prompt or a CAPTCHA and calls
`computer_request_control`. This rides the **existing** ask/approval path: `run.ask` →
`"agent-bridge-ask"` → an ask card in chat and a push:
*"Instagram is asking for a login. Take control?"* → `Take over` opens the Computer sheet with
control already granted; `Not now` returns `{granted:false}` and the agent must route around it
or stop. The run's step budget is not consumed while waiting.

```
agent ──run.ask──▶ owner ──take──▶ control=user (loop paused, TTL running)
                                        │  owner logs in, cookies land in the volume
                                        ▼
                              release / TTL ──▶ control=agent, loop resumes
```

State machine, enforced in the gateway (not the client): `agent → user` only on an explicit
grant; `user → agent` on release, TTL expiry, or session end. `POST …/computer/input` is `409`
in any other state, so a stale phone cannot type into a running agent.

**Connect an account** is just this flow with no run attached: agent profile → `Connect
account` → pick a service → the sheet opens at that service's sign-in URL with control already
held → the owner signs in → domains are added to the grant (§3.6). One-time, per agent.

### 3.6 Domain grants

Per-agent allowlist on the `agent_computers` row (`granted_domains text[]`), enforced in the
gateway on every navigate and on renderer-initiated navigation, plus the global egress denylist
underneath. Empty grant = the agent may not browse at all. Suffix match on registrable domain;
`instagram.com` covers `www.` and `i.` but not `instagram.com.evil.tld`.

Why an allowlist and not the open denylist: this browser holds the owner's live Google and
Meta sessions. A prompt injection on any page it reads can try to walk that session somewhere
else, and the *only* reliable stop is that the destination is not reachable.

### 3.7 Storage

```
agent_computers  + granted_domains text[]  + profile_bytes bigint
                 + last_login_at timestamptz  + connected_services text[]
computer_sessions  id, agent_id, user_id, started_at, ended_at, reason,
                   frames_sent int, bytes_sent bigint, control_seconds int
```

`computer_sessions` is the cost ledger (§4) and the audit trail for "who drove this browser".

## 4. Cost model

The container is not the expensive part. **Screenshots in the model context are.**

| What | Unit cost | Note |
|---|---|---|
| 1024×768 screenshot as input | ~1,100 tokens | ×24 steps ≈ 26k tokens/run, and it invalidates nothing but caches poorly because every frame differs |
| `browser_snapshot` digest | ~800 tokens | text, diffable, sits inside the cached prefix from `agent-platform-v1.md` §4b |
| Screencast frame (720 px, q55) | ~30 KB | never enters the model |
| Live viewing at 3 fps | ~90 KB/s ≈ 5 MB/min | only while the sheet is open |

Decision 2 is worth roughly **an order of magnitude on a browsing run**. A 24-step run that
screenshots every step costs ~26k image tokens; the same run on snapshots costs ~19k text
tokens that mostly ride the cache at 0.1×. Screenshots are taken when the *human* asks, or
once at the end of a task as evidence.

**Machine cost.**

| State | RAM | Disk | Wall cost |
|---|---|---|---|
| Idle agent computer | 0 | 200–500 MB volume | volume only |
| Container up, browser closed | ~30 MB | — | negligible |
| Browser live (Xvfb + headed Chromium, 1–2 tabs) | 450–650 MB | — | the binding constraint |
| Live + one viewer | +5–10% of a core | — | JPEG encode |

On the 4 GB box (base 1.75 GB under load) that is **two** concurrent live computers, three at
a squeeze. So:

- `COMPUTER_MAX_LIVE` (default 2) with an **admission queue**, reusing the run-admission
  pattern: a third request waits with *"Your agent's computer is starting…"*, it does not fail.
- `SANDBOX_DEFAULT_MEMORY_MB` 1024 → **1536 for the computer profile**; Chromium OOM-killed
  mid-login is worse than a queue.
- Browser exits after `COMPUTER_BROWSER_IDLE_SECONDS` (default 600) with no viewer and no
  agent action; container stops at the existing `SANDBOX_IDLE_TTL_SECONDS` (1800); the volume
  is kept 30 days after last use, then archived and the row marked `status:"archived"`.
- Concurrency, not RAM per box, is what pushes to a second machine. Computers are the first
  workload that justifies one — and the first that can justify billing.

**Metering.** `computer_sessions.bytes_sent` and `control_seconds` are the ledger. Bill live
minutes, not container hours: an idle computer costs us a volume and should cost the user
nothing.

## 5. Security

The premise is dangerous on purpose: this browser is logged into the owner's real accounts.

| Threat | Control |
|---|---|
| Agent exfiltrates cookies via its own shell | Chromium runs as uid **1001** (`browser`), profile `0700`; `computer_run` runs as uid **1000** (`agent`) and cannot read it. Launch is by an in-container supervisor, never by the agent's shell. |
| Prompt injection walks the session off-site | Per-agent domain grant (§3.6), enforced server-side; global egress denylist underneath |
| Injection triggers an irreversible action | New capability class `web.write`: post, send, pay, delete, invite, publish → broker approval before the click, using the existing approval cards |
| Cross-agent session theft | One volume per `agent:<id>`, already true; grants and `connected_services` are per agent — a "social" agent never sees the SEO agent's Google session |
| Credential capture by us | We never receive them. Password fields are excluded from `browser_snapshot` values and masked in `run.preview` before the JPEG leaves the container |
| Someone else driving | Session token bound to `{agentId, userId, sessionId}`, **owner only**; input `409`s unless that session holds control; every grant written to `computer_sessions` |
| Stale control | TTL on the grant, server-enforced; disconnect releases within the grace window |

Screencast frames are **not** stored: they stream and are dropped. `run.preview` stills still
persist in the transcript, so redaction runs before the JPEG is emitted, not on the client.

## 6. Manager presets

The named roles are configuration, not code — a preset is a system prompt + tool set + a
connect checklist + a domain grant + a model.

| Preset | Tools | Connect | Grant | Model |
|---|---|---|---|---|
| Social media manager | snapshot/act/open, files, `web.write` gated | X, Instagram, LinkedIn, TikTok | those domains + their CDNs | Haiku 4.5 |
| Email & marketing manager | + `computer_run` (CSV/list work) | Gmail or the ESP console | mail host, ESP, link shortener | Sonnet 5 |
| SEO manager | snapshot/act/open, files | Google Search Console | `google.com`, `search.google.com`, the owner's own domains | Sonnet 5 |
| Ops / console | + `computer_run` | Firebase, cloud console | that console only | Sonnet 5 |

Shipped as seeded agent templates; the owner picks one, runs **Connect account** once (§3.5),
and the agent works from then on. `web.write` approvals default **on** for every preset — the
first "the bot posted that by itself" is unrecoverable.

**Model belongs in the preset, and today it is not there.** `agents.model_provider` /
`model_id` exist and `ChatAgentModelPickerView` edits them from Settings → Model, but
`ChatNewAgentView` has no model step — every agent is born on the schema default
`claude-sonnet-5` and stays there unless someone goes looking. A clicking-and-reading agent
does not need Sonnet 5 on all 24 steps; picking the model at creation is the cheapest cost
lever in this whole document. `thinkingLevel` is the same story: the registry ships
`thinkingLevels` per model and the profile contract carries the field, but no surface sets it.

## 6b. Delivered (2026-08-30) — phase 1

| Piece | State |
|---|---|
| Gateway `computer/*` routes, frame cache, control state machine, capacity 429 | built · 107 Rust tests |
| Headed Chromium under Xvfb; `state` + `input` verbs in `browser.js` | built · unverified against a live Podman |
| Runtime passthrough (204/409 preserved), `run.computer.state` from the browser tools | built · 105 tests |
| Core owner-only session route, `ComputerChannel` + poller, relay → `"agent-computer"` | built · 429 tests |
| iOS Computer sheet, computer band in the agent turn, row-height reserve in both paths | built · generic build green |
| Model choice at agent creation | built |
| `browser_snapshot`, domain grants, `web.write`, the uid split, Terminal/Files tabs | not built — phases 3–4 |

Three integration breaks were only visible across slices and are fixed: the frame poll
dropped `sessionId` so a viewer was reaped after 60 s of watching; a cold `computer/session`
404'd because it required a sandbox row that opening the sheet is supposed to create; and
registering the two new RunEvent kinds took the frozen count 16 → 18 and broke `contracts`.

**Known deviation: the sheet dials its own socket.** `ChatPhoenixClient.callbacks` is fixed
at init with no fan-out and no unknown-topic branch, so `computer:<agentId>` cannot ride the
app's existing connection without a topic-observer hook in `ChatEngine`. The extra socket
lives only while the sheet is open and `COMPUTER_MAX_LIVE` is 2, so it is bounded — but it is
a second connection per viewer, and a fan-out hook is the right fix before this scales.

**Not verified against a live Podman** — same gap as the sandbox itself in
`agent-platform-v1.md` §4b. The headed-Chromium change in particular is argued, not measured:
nothing here proves Google sign-in accepts it until it runs on the box.

## 7. Phases

1. **Watch.** Xvfb + headed Chromium in the image; `computer/session` + the pull frame path;
   core relay and `computer:<agentId>` channel; iOS Computer sheet, Screen tab; the computer
   band in the chat-list cell. Proves the frame path and the cost model. **In progress.**
2. **Drive.** Control state machine, `computer/input`, native dialogs, `Take control`,
   `computer_request_control` on the existing ask path. **Connect account** ships here — this
   is the phase that unlocks every use case. The gateway half of the state machine and the
   input route land with phase 1, since control is what `input` is gated on.
3. **Reason cheaply.** `browser_snapshot`, grants, `web.write` approval class, uid split for
   the profile, redaction. Demote `browser_screenshot` in the system prompt.
4. **Sell it.** Terminal + Files tabs, `computer_sessions` metering, admission queue, presets,
   volume archival.
5. **Later, if ever needed.** Full-desktop profile (X11 capture, window manager) for a native
   GUI app. Not before something real needs it.
