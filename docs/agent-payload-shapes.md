# Claude, Codex & Grok agent payload shapes

Authoritative reference for the real wire shapes Claude Code, Codex, and Grok
Build emit, and how they flow through the bridge → server → iOS agent view.
Claude/Codex shapes captured from live session logs on 2026-06-25
(`~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/rollout-*.jsonl`).
Grok `streaming-json` captured 2026-07-09 against Grok Build **0.2.93**.
Build and verify the parsing layer (bridge `vibe-bridge.js`, server
`LocalAgentWorker`, iOS agent views) against this — do not guess node shapes.

## Pipeline

```
claude -p --output-format stream-json --verbose   (one JSON object per line)
codex exec --json                                  (one JSON object per line)
grok -p <prompt> --output-format streaming-json    (one JSON object per line)
        │  raw stdout lines
        ▼
vibe-bridge.js  ── progress {provider, chatId, line} ──▶ server
                ── result   {provider, chatId, output, exitStatus, agentRuntime}
        │
        ▼
LocalAgentWorker.bridge_stream_update / parse_result
   extract_result/2  ⇒ { text, progress_nodes, tool_events, usage }
        │  broadcast "agent-stream" { text, progressNodes, toolEvents, status }
        ▼
iOS ChatEngine → ChatNativeAgentView / ChatAgentMessagesView  (parsed rows)
```

`agent-stream` payload (server → chat topic): `text` (running summary), `progressNodes`,
`toolEvents`, `status` ("running" | "done"). The final `result` carries the full output;
progress lines are capped (`@max_stream_lines 500`) so only the result is authoritative.

### Supervisor team runs (`@team`)

Default `@team` / `/team` uses **supervisor** mode (override with `VIBE_TEAM_MODE=sequential`):

| Field | Meaning |
|---|---|
| `teamMode` | `"supervisor"` (or legacy `"group_team"` sequential) |
| `teamRunId` | Durable run id (also `TeamRun` primary key) |
| `teamWorker` | This frame’s handle |
| `teamWorkers` | All handles in the run |
| `leadWorker` | Responsible agent (default preference: Codex → Claude → Grok → Agy) |
| `teamRole` | `"lead"` \| `"worker"` |
| `suppressVisible` | `true` for under-hood workers — **no list bubble** |
| `teamWorkersStatus` | `[{ worker, label, status, durationMs, lastLabel, … }]` for the lead cell strip |

Under-hood workers also emit `agent-team-worker` so the lead cell’s compact strip updates
without inserting a second synthetic row. iOS pins the visible cell by `teamRunId`.

---

## Claude (`stream-json`)

One object per line. Live-stream top-level `type`s:

| type | meaning | key fields |
|---|---|---|
| `system` (subtype `init`) | session start | `model`, `tools[]`, `slash_commands[]`, `mcp_servers[]`, `agents[]`, `skills[]`, `session_id`, `permissionMode`, `cwd`, `claude_code_version` |
| `assistant` | model turn | `message.content[]` (blocks below), `message.usage` |
| `user` | tool results fed back | `message.content[]` (`tool_result` blocks) or string |
| `result` | turn end | `usage`, `total_cost_usd`, `duration_ms`, `duration_api_ms`, `ttft_ms`, `num_turns`, `session_id`, `model` |

Session-log-only `type`s (persistence, NOT in live stream — ignore for rendering):
`queue-operation`, `attachment`, `file-history-snapshot`, `last-prompt`, `ai-title`, `mode`.

### Content blocks (`message.content[]`)

```jsonc
{ "type":"text", "text":"…" }
{ "type":"thinking", "thinking":"…", "signature":"…" }          // reasoning
{ "type":"image", "source":{ "type":"base64","media_type":"image/jpeg","data":"…" } }
{ "type":"tool_use", "id":"toolu_…", "name":"Read", "input":{…}, "caller":{"type":"direct"} }
{ "type":"tool_result", "tool_use_id":"toolu_…", "content":"…" | [ {…}, {image} ] }
```

`thinking.thinking` is often empty with only a `signature` (encrypted CoT) — render as a
"Thinking…" node, never show the signature.

### `tool_use.input` keys per tool (drives the verb + detail shown)

| name | input keys | render as |
|---|---|---|
| `Read` | `file_path` | Read `basename` |
| `Edit` | `file_path`, `old_string`, `new_string`, `replace_all` | Edit `basename` `+N −M` (diff old/new) |
| `Write` | `file_path`, `content` | Create `basename` (`N` lines) |
| `Bash` | `command`, `description` | Run `description` (cmd as detail) |
| `TodoWrite` | `todos[]` | Planning (todo list) |
| `WebSearch` | `query` | Search `query` |
| `WebFetch` | `url`, `prompt` | Fetch `host` |
| `Monitor` | `command`, `description`, `timeout_ms`, `persistent` | Run (watch) |
| `ToolSearch` | `query`, `max_results` | Search tools |
| `TaskStop` | `task_id` | — |
| `AskUserQuestion` | `questions[]` | Question |

`tool_result.content` is a string OR a list (text + `image` blocks). Map by `tool_use_id`.

---

## Codex (`codex exec --json`)

> **CRITICAL:** `codex exec --json` **stdout** (what the bridge captures) is the
> *thread-item streaming* format below — NOT the `event_msg`/`response_item` shape
> found in `~/.codex/sessions/**/rollout-*.jsonl`. The rollout files are the
> on-disk persistence format and are never seen by the **live stdout parser**
> (the bridge's History reader does open them explicitly). Verified 2026-06-25
> against codex-cli **0.142.0** (binary string analysis + live stdout capture).

One JSON object per line. **Envelope** events keyed by top-level `type`:

| type | fields | meaning |
|---|---|---|
| `thread.started` | `thread_id` | session start (use `thread_id` for `--resume` continuity) |
| `turn.started` | — | model turn begins |
| `item.started` | `item` | a thread item begins (status running) |
| `item.updated` | `item` | item progress update |
| `item.completed` | `item` | item finished (status done) |
| `turn.completed` | `usage` | turn done |
| `turn.failed` | `error.message` | turn failed (e.g. usage-limit) |
| `error` | `message` | top-level error (e.g. "You've hit your usage limit") |

The real work is in the **`item`** object (`event["item"]`). Discriminator is
`item_type` (fall back to `type`). Item types (from the 0.142.0 binary):

| item_type | key fields | maps to |
|---|---|---|
| `agent_message` | `text` | **summary text** (the assistant's reply) |
| `reasoning` | `text` | Thinking node |
| `command_execution` | `command` (string), `aggregated_output`, `exit_code`, `status`, `duration` | Run (Bash); `exit_code != 0` ⇒ failed |
| `file_change` | `changes[]` = `{path, kind: add\|delete\|update}`, `status` | Edit/Create (no inline diff counts in stream) |
| `mcp_tool_call` | `server`, `tool`, `arguments`, `status`, `result` | Tool |
| `web_search` | `query`, `action` | Search |
| `todo_list` | `items[]` | Planning |
| `error` | `message` | error node |

Item `status` values: `pending_init`, `in_progress`/`running`, `completed`,
`interrupted`, `errored`, `failed`, `not_found`. Final status comes from the
envelope (`item.completed` ⇒ done) combined with `item.status` and, for
`command_execution`, `exit_code`. Correlate `item.started` ↔ `item.completed`
by `item.id` (the worker merges same-id events).

Common failure surfaced to the user: top-level `{"type":"error","message":"You've
hit your usage limit…"}` followed by `turn.failed` — that's a Codex quota cap, not
a parse error. The worker maps the message to the visible result text.

### Codex app persistence (`response_item`) — History only

Captured 2026-07-13 from current Codex app rollouts. Newer app sessions persist
orchestration through a wrapper that is **not** the real user-facing action:

```jsonc
{"type":"response_item","payload":{
  "type":"custom_tool_call","name":"exec","call_id":"call_…",
  "input":"const r=await tools.exec_command({cmd:\"rg -n Demo lib\"}); text(r.output);"
}}
{"type":"response_item","payload":{
  "type":"function_call","name":"wait","call_id":"call_…",
  "arguments":"{\"cell_id\":\"121\",\"yield_time_ms\":20000}"
}}
```

For `custom_tool_call.name == "exec"`, parse the generated input **without eval**
and classify **every** nested `tools.<name>(…)` call. A single envelope can contain
`update_plan` followed by one command, a `Promise.all` with several commands, or a
mapped command array; taking only the first nested call silently drops the rest.

| nested tool | render as |
|---|---|
| `exec_command` | Run, or Read/Search when the shell classifier recognizes it |
| `apply_patch` | Edit with file and `+N −M` metadata |
| `view_image` | Read/inspect the image filename |
| `update_plan` | Planning |
| `spawn_agent` / `send_message` | Task / subagent activity |
| MCP/web/image tools | Their nested tool identity, never the outer `exec` |
| `write_stdin` | suppress (continuation of an existing command) |

Suppress a direct `function_call.name == "wait"` and its paired output for the
same reason. These continuation frames do not represent new work; showing them
creates the repeated raw `exec` / `wait` rows seen in the iOS History surface.
Direct persistence `function_call` / `custom_tool_call` records that are not
wrappers still use their own `name` and decoded arguments.

Codex IDE user messages may also be wrapped as `# Context from my IDE setup` plus
`## My request for Codex:`. History must extract the request section before applying
context filtering, strip attachment wrappers such as `<image …></image>` / `[Image #1]`,
and ignore injected `AGENTS.md` / plugin-list / bridge-startup records. The extracted
user prompt is the history title and the visible user bubble; assistant commentary is
only a fallback when a rollout has no real user prompt.

---

## Rendering contract (iOS agent view)

`ChatAgentMessagesView` already understands these row kinds — wire the parsed nodes to them:
- progress verbs: `read`, `edit`, `write`, `bash`, `search`, `web`, `task`, `todo`
- statuses: `running`, `done`/`complete`/`success`, `error`/`failed`
- row message types: `agent_progress`, `agent_progress_tree`, `agent_actions`, `agent_card`

Default chat view shows the **summary** (`agent_message` / Claude final `text`) as a bubble;
the full progress/thinking/tool/patch nodes render in the **agent view** (solid bg). Each agent
bubble in the default view gets a compact "view agent" affordance that pushes the agent view.

---

## Plan mode, approvals & ask-user (interactive round-trips)

Captured 2026-06-30 against `claude` **2.1.191** and `codex-cli` **0.142.2**.
These are the tool/permission shapes that require a phone⇄bridge round-trip
(the model pauses and waits for the human), as opposed to the fire-and-forget
progress/result stream above.

### Current state (and the plan-mode bug)

The bridge spawns Claude **one-shot, non-interactive**:
`claude -p --output-format stream-json --permission-mode <mode>` (no
`--input-format`, no `--permission-prompt-tool`). With no stdin channel there is
no way to feed an approval back, so:

- `--permission-mode plan` → Claude researches, writes a plan, calls
  `ExitPlanMode`, which **auto-denies** (no approver) and the run ends with the
  plan as text. There is no "approve → continue and edit" step today.
- `AskUserQuestion` likewise has no human to answer; in `-p` it is effectively
  unavailable / auto-resolved.

`claudePermissionMode()` maps work mode → permission mode:
`full_access→bypassPermissions`, `ask_auto→auto`, `allow_edits→acceptEdits`,
and **`ask`/`read_only`→`plan`**. Because the phone's default work mode is
`read_only` (`AgentBridgeSelectionStore.selectedWorkMode()`), **every default
send runs in `plan` permission mode** — the "always plan mode" bug. `read_only`
and `plan` are conflated; there is no distinct, explicitly-chosen plan state.

### Claude — `ExitPlanMode` (plan approval gate)

```jsonc
{ "type":"tool_use", "name":"ExitPlanMode", "input": {
    // OPTIONAL. Plan content is NOT here — Claude writes the plan to the
    // plan file named in the plan-mode system message; this tool only
    // SIGNALS "plan is ready, request approval".
    "allowedPrompts": [ { "tool":"Bash", "prompt":"run tests" } ]
} }
```

- Plan content lives in the **plan file** (modern Claude Code writes the plan to
  a file and `ExitPlanMode` reads from it — it does not pass the plan as a param).
  The bridge must surface that file's contents to the phone for review.
- Approval contract: `tool_result` for the `ExitPlanMode` id is the human's
  decision. **Approve** ⇒ session leaves plan mode (Claude proceeds, typically
  switching to `acceptEdits`/`default`); **Reject** ⇒ stays in plan, keeps refining.
- Enabling the round-trip non-interactively requires running Claude with
  `--input-format stream-json --output-format stream-json` (a persistent stdin
  channel) and either a `--permission-prompt-tool <mcp_tool>` or feeding the
  tool_result back over stdin.

### Claude — `AskUserQuestion` (ask-user sheet)

```jsonc
{ "type":"tool_use", "name":"AskUserQuestion", "input": {
    "questions": [
      { "question": "Which auth method?",   // full question text, ends with ?
        "header": "Auth method",            // ≤12-char chip label
        "multiSelect": false,               // true ⇒ checkboxes, false ⇒ single
        "options": [
          { "label": "OAuth",               // 1–5 words, shown as the choice
            "description": "Delegated via provider",
            "preview": "optional markdown — side-by-side compare (single-select only)" }
        ] } ]   // 1–4 questions, each 2–4 options; "Other" free-text is implicit
} }
```

- Result fed back as the `tool_result` for that tool_use id = the chosen option
  **label(s)** per question (plus any free-text "Other"). For `multiSelect` it is
  the set of selected labels.
- iOS render target: a **bottom sheet** — one section per question, the `header`
  as the section chip, options as single- or multi-select rows, an always-present
  "Other" text field, and (single-select) the `preview` rendered as monospace
  markdown beside the focused option.

### Codex — equivalents (constraints)

`codex exec --json` is **non-interactive**; the interactive approval items
(`exec_approval_request`, `apply_patch_approval_request`) and any ask-user prompt
exist only in the Codex **app-server/TUI** protocol and are **not emitted by
`exec`**. Approval policy is set up-front via `-c approval_policy=...`
(`untrusted`/`on-request`/`on-failure`/`never`) and resolved by policy, not by a
phone round-trip. Codex's "plan" is the `update_plan` tool / `todo_list` item —
**display-only**, no approval gate. ⇒ Plan-approval and ask-user round-trips are
**Claude-only** with the current Codex integration.

### Bridge ⇄ server ⇄ iOS event contract (round-trip) — IMPLEMENTED

Mirrors the existing `control_task`/`history_request` pairs, E2E-wrapped like
`agentRuntimeEnc` (arte1). The bodies are sealed with the pairing runtime key —
the server relays opaque blobs.

```
bridge → server → phone:   "ask_request"  { provider, chatId, taskId, requestId,
                                            kind:"plan"|"ask",
                                            askEnc /* arte1 of { kind, request:{…} } */ }
   server: AgentBridgeChannel.handle_in("ask_request") ⇒ broadcast
           "chat:<id>" "agent-bridge-ask"
   iOS:    ChatEngine frame "agent-bridge-ask" → latestAgentBridgeAsk(requestId:)
           → VibeAgentAskSheetViewController

phone  → server → bridge:  "agent-bridge-ask-response"  (ChatChannel)
   server: ChatChannel.handle_in("agent-bridge-ask-response")
           ⇒ AgentBridge.dispatch_ask_response ⇒ "bridge:<uid>" "ask_response"
   bridge: channel.on("ask_response") → resolveAsk(requestId) resolves requestAsk's Promise
           { requestId, decision:"approve"|"reject"|"answer",
             answerEnc /* arte1 of { answer:{…} } */ }
```

`request` body by kind:
- `plan`: `{ plan:String, sessionId, repoName }`. Emitted fire-and-forget by the
  bridge after a `plan`-mode run (`maybeEmitPlanApproval` → `extractPlan`). On
  **approve** the phone re-sends a normal run (workMode `allow_edits`, resuming the
  plan's session, plan text inlined) — the bridge never fabricates a turn. On
  **reject + feedback** the phone re-sends a plan-mode revise run.
- `ask`: `{ questions:[ AskUserQuestion shape ] }`. Awaited via `requestAsk`
  (timeout → auto-reject). Answer body: `{ selections:[ {header,question,selected[],other?} ] }`.

### IMPLEMENTED — the MCP `ask_user` producer (mid-run questions)

`claude -p` is non-interactive, so the built-in AskUserQuestion can't reach a
human. The bridge instead exposes its **own** MCP tool, `ask_user`, so the model
can pause mid-run and ask. Disable with `VIBE_ASK_MCP=0`.

- **Producer:** `ensureAskMcp()` (vibe-bridge.js) materializes a tiny stdio MCP
  server (`vibe-ask-mcp.js`, the `ASK_MCP_SCRIPT` template) + its `--mcp-config`
  JSON in `os.tmpdir()`, and starts a unix-socket IPC server. `buildCommand`
  (claude branch) adds `--mcp-config <file> --allowedTools mcp__vibeask__ask_user`
  (pre-allowed so the round-trip never trips a headless-unanswerable permission
  prompt). The claude spawn env carries `VIBE_ASK_SOCK / VIBE_ASK_CHAT /
  VIBE_ASK_TASK` (`askMcpEnv`), inherited by the MCP child.
- **Flow:** model calls `ask_user{questions[]}` → MCP child connects the unix
  socket → `handleAskIpcConnection` calls `requestAsk` (awaited, E2E-sealed,
  10-min timeout → auto-reject) → phone renders the paginated ask sheet
  (`VibeAgentAskSheetViewController`, one question per page) → `ask_response`
  resolves the promise → bridge writes `{answer}` back over the socket → MCP
  returns it as the tool_result and the run continues.
- **Tool schema** (`ask_user` inputSchema): `{ questions:[ { question, header
  (≤12 chars), multiSelect, options:[{label,description}] } ] }` — mirrors
  Claude's AskUserQuestion and the iOS sheet. Answer text returned to the model:
  `{ selections:[ {header,question,selected[],other?} ] }`.

Codex `exec` cannot round-trip (approvals/ask are TUI/app-server only), so this is
Claude-only.

Alternative not taken: `claude --input-format stream-json` feeding tool_result
over stdin (also enables `--permission-prompt-tool` for live per-tool `ask`
approval) — kept in reserve for the future direct-LAN per-action approval phase.



---

## Grok (`streaming-json` + session files)

Headless command (bridge):

```bash
grok -p "<prompt>" --output-format streaming-json \
  --permission-mode <mode> \
  [--session-id <uuid>]   # fresh runs — pin path for live tool tail
  [--resume <sessionId>]  # follow-ups
  [--model <id>] [--reasoning-effort low|medium|high] [--always-approve]
```

Also available: `--output-format json` (single final object) and `plain`.

### Source split (critical)

| Source | Authoritative for | Notes |
|---|---|---|
| **stdout** `streaming-json` | `thought`, `text`, `end` | Lowest latency; **no tools** |
| **`~/.grok/sessions/<enc-cwd>/<id>/updates.jsonl`** | live `tool_call` / `tool_call_update` | Bridge tails while the process runs |
| **`chat_history.jsonl`** | history detail (full turn fold) | `reasoning`, `assistant`+`tool_calls`, `tool_result`, user prompts |

Do **not** double-ingest thought from both stdout and `agent_thought_chunk` in updates — live thinking is stdout-only; history uses `reasoning` rows in chat_history.

### Live stdout NDJSON

| type | meaning | key fields |
|---|---|---|
| `thought` | reasoning token/chunk | `data` (string) |
| `text` | assistant answer chunk | `data` (string) |
| `end` | turn complete | `stopReason`, `sessionId`, `requestId` |

Example:

```json
{"type":"thought","data":"The"}
{"type":"text","data":"hi"}
{"type":"end","stopReason":"EndTurn","sessionId":"…","requestId":"…"}
```

### Bridge-injected tool lines (from updates.jsonl)

```json
{"type":"tool_use","id":"call-…","name":"read_file","input":{"target_file":"…"},"status":"running"}
{"type":"tool_result","tool_use_id":"call-…","content":"…","is_error":false,"status":"done"}
```

Grok tool names map to the same progress kinds as Claude/Codex:

| Grok tool | kind |
|---|---|
| `read_file` | `read` |
| `search_replace` | `edit` |
| `write` | `write` |
| `run_terminal_command` | `bash` |
| `grep` / `list_dir` | `search` |
| `todo_write` | `todo` |
| `web_search` / `web_fetch` / `open_page` | `web` |
| `use_tool` / `search_tool` (MCP) | `mcp` when name is `server__tool` / `mcp__server__tool` (e.g. Ask Fable) |
| `use_tool` (non-MCP) | `tool` |
| Claude `mcp__server__tool` | `mcp` — label `MCP · tool name`, duration when result ts known, result in sheet |
| Codex `mcp_tool_call` | `mcp` |

### History (`chat_history.jsonl`)

| type | role in fold |
|---|---|
| `user` (no `synthetic_reason`) | turn boundary — right-side user bubble |
| `reasoning` | `kind:thinking` node (`summary[].text` when present) |
| `assistant` | narration `text` + `tool_calls[]` → tool nodes |
| `tool_result` | join output onto tool id |
| `system` / synthetic user scaffolding | skip |

Each **user turn** folds into **one** assistant host via `foldTurnIntoHost` (Worked card + summary body), not one bubble per intermediate assistant line.

### Server mapping (`LocalAgentWorker`)

- **Segmented** node ids (critical for chronological interleave): `grok-thinking-{seg}`,
  `grok-text-{seg}`, tool ids from `tool_use.id`. A tool (or compacting) between
  narrations bumps `seg` so later text appends after tools instead of upserting the
  first text slot (the old “all tools on top, all text at bottom” bug).
- Continuous `thought` chunks upsert the current thinking segment (`detail`/`output` =
  full exposed CoT for the phone thinking sheet).
- Continuous `text` chunks upsert the current text segment (dropped when equal to
  finished summary body).
- Injected `tool_use` / `tool_result` → progress kind + status running→done
- Compacting: `auto_compact_started` / `auto_compact_completed` from `updates.jsonl` →
  `kind:compacting` node (“Compacting conversation…”)
- `vibe_thinking` ticker still drives live "Thinking · N tokens" like Claude
- `end.sessionId` / bridge-assigned `--session-id` for resume
- iOS: thinking rows are compact (“Thought for Ns”); tap opens sheet with full CoT

### Agent identity

| field | value |
|---|---|
| handle | `grok` |
| mention | `@grok` |
| agent user id | `33333333-3333-3333-3333-333333333333` |
| avatar | `https://media.vibegram.io/chat-media/agent-profiles/grok-v2.png` |

---

## Agy / Antigravity CLI (plain stdout + transcript.jsonl)

Headless command (bridge):

```bash
agy -p "<prompt>" \
  [--conversation <id>] \
  [--model "Gemini 3.1 Pro (High)"] \
  [--mode accept-edits|plan] \
  [--dangerously-skip-permissions] \
  [--print-timeout 30m]
```

Binary: `agy` (Google Antigravity CLI). Env override: `VIBE_AGY_COMMAND`.

### Source split (critical)

| Source | Authoritative for | Notes |
|---|---|---|
| **stdout** | final answer only (plain text) | No tools / no thinking |
| **`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`** | thinking, tool_calls, tool results, narration | Bridge tails while process runs |
| **`conversation_summaries.db` + `history.jsonl`** | history list metadata | title, workspace, step_count |

### Bridge synthesis

The bridge converts each transcript step into **Grok-compatible NDJSON** so the server reuses the same progress parsers:

| transcript `type` | synthetic line |
|---|---|
| `PLANNER_RESPONSE.thinking` | `{"type":"thought","data":"…"}` |
| `PLANNER_RESPONSE.content` | `{"type":"text","data":"…"}` |
| `PLANNER_RESPONSE.tool_calls[]` | `{"type":"tool_use", id, name, input}` |
| `VIEW_FILE` / `RUN_COMMAND` / `CODE_ACTION` / `GREP_SEARCH` / … DONE | `{"type":"tool_result", tool_use_id, content}` |
| process exit | `{"type":"end","stopReason":"end_turn","sessionId":…}` + plain stdout as `text` |

Tool name map: `view_file`→`read_file`, `run_command`→`run_terminal_command`, `write_to_file`→`write`, `grep_search`→`grep`, etc.

### Agent identity

| field | value |
|---|---|
| handle | `agy` |
| mention | `@agy` (alias `@antigravity`) |
| agent user id | `44444444-4444-4444-4444-444444444444` |
| avatar | `https://media.vibegram.io/chat-media/agent-profiles/agy.png` |
