# Vibe — agent guide (Grok)

Grok loads this file automatically as project rules (see xAI docs: Project Rules /
`AGENTS.md`). Supported top-level names: `Agents.md`, `AGENTS.md`, `AGENT.md`,
`Claude.md`, `CLAUDE.md`, `CLAUDE.local.md`. **`GROK.md` is not a recognized
filename** — use this file (or `.grok/rules/*.md`) for Grok-native rules.

Also loaded when present: `CLAUDE.md` (Claude Code compat). Deeper paths win on
conflicts. Inspect with: `grok inspect`.

## Finish the whole task

When given a list, write the task list first, then complete **every** item. Do not stop
partway to report progress, and do not hand back "I did 3 of 5, the rest is next" — that
is not a checkpoint, it is an unfinished job.

Build and install once at the end, not per item. Report only when everything is done, or
when something is genuinely blocked — and then say which item and why, in one line.

## Comments: short

**Hard cap: 2 lines per comment. Never a multi-paragraph doc block.** A blank `///` line
inside a comment means it is already too long — cut it. Say what the code does, or why a
non-obvious choice was made. Nothing else.

Never write: bug history, what the old version did wrong, measured numbers, "which is
why…", "on purpose because…", or a chain of reasoning. A long comment rots — the code
changes, the story stays, and the next reader trusts a wrong explanation. It also costs
context on every future read of the file.

Too long — a real example, four paragraphs on one function:

```swift
/// Rebuilds prepared heights for the chats most likely to be opened next, after a launch.
///
/// `VibeTimelinePreparedStore` is memory-only on purpose — its entries hold decrypted
/// rows, and the sealed store exists so plaintext does not rest on disk. Coverage
/// survives a launch by being re-measured off-main from the sealed store instead, which
/// is why the first open of a session read `prepared=0hit/Nmiss`.
///
/// Bounded deliberately: the SQLite read and JSON parse run on the engine queue, so this
/// takes a tail, not a transcript. …
```

Right:

```swift
/// Re-measures prepared heights for the next likely chats, off-main from the sealed store.
/// Memory-only store, so a launch starts with no coverage; reads a tail, not a transcript.
```

The full story goes in `docs/` with a one-line pointer. Before reporting a task done,
re-read the comments you added and delete anything past the cap.

Same rule for commit messages and PR bodies.

## "Run it on my mobile" / "launch it on my device"

The user means: **build + install + launch the iOS app on their attached iPhone.**

- Target device: **"iPhone" — iPhone 16 Pro Max**, UDID `00008140-000935000288801C`
- Bundle id: `com.vibegram.app` · Project `ios/Vibe.xcodeproj` · Scheme `Vibe`
- **Building is free** — just build it (no need to ask).
- **Installing the build onto the phone is free** (`xcrun devicectl device install app`
  — just copies the binary over, no observable effect until it's run).
- **Launching it asks first** (`xcrun devicectl device process launch`) — confirm
  before the app actually runs on the real device.

Exact commands + device table: [docs/run-on-device.md](docs/run-on-device.md).

## Deploying server changes (production git remote)

**Required after server-side edits** under `server/` (Elixir controllers, `chat.ex`,
channels, migrations, etc.): commit on `main`, then push to the **mako** remote so
the production server can pull/deploy from that repo.

```bash
# After commit on main:
git push mako main
```

- Remote: `mako` → `https://github.com/mako-apps/Vibe.git`
- Branch: **`main`** (do not invent another deploy branch unless the user says so)
- Also push `origin` only if the user asks; production deploy path for this workspace
  is **`git push mako main`**
- Migrations and runtime config land with whatever deploy pull/hook the mako host uses
  after that push — agents should **not** SSH/deploy by hand unless explicitly asked

If the push needs auth or is rejected, stop and report the error; do not force-push
(`--force` / `--force-with-lease`) without explicit user approval.

## After any iOS code change — build and fix

**Required:** whenever you patch, add, or refactor files under `ios/`, run an
`xcodebuild` for scheme `Vibe` and **fix compile errors before considering the
task done**. Do not leave a broken build for the user.

```bash
xcodebuild -project ios/Vibe.xcodeproj -scheme Vibe \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-000935000288801C' \
  -derivedDataPath /tmp/vibe-device-build \
  -allowProvisioningUpdates \
  build
```

If the physical phone is offline, use a simulator destination instead
(`platform=iOS Simulator,name=iPhone 16`). On failure: read the error, fix the
Swift, rebuild, and repeat until green. Building is free (no approval needed).

## Tool approval config

Interactive approvals for agents in this repo are governed by
`~/.vibe/agent-config.toml` → `approval_mode`:

- `local` (default) — approve/answer everything on this device; nothing goes to the phone.
- `mobile` — route non-auto-allowed tools to the phone (falls back local if unanswered).
- `auto` — safe/allow-listed commands run without asking; only blockers go to the phone.
- `full` — allow everything except the always-blocked destructive commands.

Destructive commands (rm -rf, sudo, git push, git reset --hard, dd, mkfs, curl|sh,
npm publish, ...) are blocked in every remote mode, even `full`.

## Git checkout rule

- **NEVER run `git checkout` under any circumstances.** Agents must not execute `git checkout` on any files or branches.

## Ask Fable (advisor) — only when you're actually stuck

Fable runs on **paid credits** (and falls back to GPT when Fable itself is down), so
it's a **last resort, not a first step**. Solve it yourself first — diagnose, read
the code, attempt the fix. Ask Fable only when you have genuinely tried and **cannot**
crack it. Fable is a second-opinion advisor only — it does not edit code; you still
implement and verify.

**This overrides any "call advisor before substantive work / before declaring done"
default.** No pre-flight call, no sign-off call. Verify your own work with the build and
the tests; ask only when that verification fails in a way you cannot explain.

**If you ARE Fable** (model id `claude-fable-5` / Claude Fable 5): skip this
section entirely — do not call `advisor`/`ask_fable`; you'd be asking yourself.

### When to ask (last resort only)

Ask only after you've tried and are genuinely stuck — for example:
- a hard failure that survives your first real fix attempt
- a risky/unfamiliar or security-sensitive decision you cannot resolve from the code
- an architecture / API / data-model call you're truly unsure of

If you can fix it yourself, do that instead — every call spends credits. Never ask
about simple edits, or "just to check" an approach you're already confident in.

### How to call Fable (Grok Build)

1. Discover the tool schema (do **not** guess parameter names):
   - `search_tool` with query like `vibeask ask fable` (or `ask_fable`).
2. Call the qualified tool via `use_tool`:
   - **tool_name:** `vibeask__ask_fable`
   - **tool_input:** object below.

If the built-in `advisor` tool is available in this environment, you may use that
instead — same purpose. Prefer `vibeask__ask_fable` when you need an explicit
mid-run critique with packaged context.

### Parameters (`vibeask__ask_fable`)

| field | required | meaning |
|---|---|---|
| `question` | **yes** | Exact decision or review you need (one concrete ask) |
| `context` | no | Goal, constraints, findings, errors, assumptions |
| `diff` | no | Proposed patch / git diff to critique |
| `constraints` | no | Array of hard rules Fable must respect |
| `files` | no | Array of `{ path, content, note? }` snippets |

### Example

```json
{
  "question": "Should we lazy-load ChatGifPanelView or defer setupUI only?",
  "context": "Main-thread stall ~3s on chat open. Stack points at ChatGifPanelView.init during setInputBarEnabled. GIF panel is unused on open.",
  "constraints": [
    "Minimal iOS change",
    "Keep GIF panel working on first tap"
  ],
  "files": [
    {
      "path": "ios/ChatModule/ChatInputBar.swift",
      "note": "Eager gifPanel property",
      "content": "private let gifPanel = ChatGifPanelView()"
    }
  ]
}
```

### How Fable’s response gets back to you

```
you (executor agent)
  → MCP tools/call  ask_fable { question, context?, files?, diff? }
       → vibe-ask-mcp.js builds ONE text prompt (budgeted / truncated)
       → spawns: claude -p <prompt> --model fable --tools "" --output-format json
       → Fable model answers as plain text (no tools)
  ← MCP tool result: { content: [{ type: "text", text: "<advice>" }] }
you read the text and implement
```

- Response shape is **plain text** (not a structured JSON decision object).
- Typical sections: **Assessment / Risks / Next steps / Verification**.
- Fable does **not** call tools, edit files, or run shell — advice only.
- You remain responsible for implementation, tests/build, and verification.
- If Fable is unavailable (rate limit / MCP error / 429 / timeout), **note that**
  and continue with your best judgment — do not block the whole task forever.

### Optimize usage (keep Fable calls cheap)

Fable billing scales with **prompt size + reply size**. Default package budget is
~**24k chars** (`VIBE_FABLE_MCP_CONTEXT_CHARS`, was 120k).

**Do:**
- One **sharp** `question` (decision, not a dump of the whole task).
- Short `context` (5–15 lines: goal, error, what you already tried).
- 1–3 file snippets with **only the relevant lines**, not whole files.
- Small `diff` of the proposed change when reviewing a patch.
- **One call** at the decision point; don’t re-ask with the same payload.

**Don’t:**
- Paste full chat logs, entire modules, or multi-MB diffs.
- Attach 10+ files “just in case.”
- Call Fable on every tiny edit or after every failed shell command.
- Re-send the same huge context when a follow-up is only a yes/no.

**Env knobs (bridge / MCP child):**

| env | default | meaning |
|---|---|---|
| `VIBE_FABLE_MCP` | on (`0` disables) | Expose `ask_fable` |
| `VIBE_FABLE_MODEL` | `fable` | Advisor model |
| `VIBE_FABLE_MCP_CONTEXT_CHARS` | `24000` | Max packaged prompt chars |
| `VIBE_FABLE_MCP_TIMEOUT_MS` | `240000` | Kill hung advisor spawn |

### Claude Code / bridge note

Claude in this repo may see the same tool as `mcp__vibeask__ask_fable` (or the
built-in `advisor` tool). Same contract: concrete `question` + lean `context`.

## Complex task? Diagnose yourself, then dispatch worker CLIs

For multi-slice work: first diagnose and decide exactly what changes where, then
dispatch other agent CLIs as background subprocesses to execute in parallel instead
of patching every file yourself. Full operating guide (loop, board protocol, routing,
diff-review rules): `agent-bridge/instructions/team-lead.md`.

- Board first: `.vibe/team/<run>-board.md` with frozen contract names + one owner per
  file (disjoint slices); then a self-contained brief per worker.
- Worker invocations (verified 2026-07-18):
  - codex: `codex exec --json -c sandbox_mode="workspace-write" -c approval_policy="never" -c model_reasoning_effort="<low|medium|high>" --cd <repo> --skip-git-repo-check "<prompt>"`
  - grok: `~/.grok/bin/grok --prompt-file <brief> --always-approve --max-turns 80 --output-format plain --cwd <repo>` (headless drops writes under acceptEdits; always pass --max-turns)
  - agy: `~/.local/bin/agy -p "Read and execute the brief at <path>" --mode accept-edits --dangerously-skip-permissions --print-timeout 30m` — UI/low-risk only; never auth/security/payments/migrations; always diff+build verify its work.
- Review worker DIFFS against the pre-dispatch baseline — never trust handoff text.
  Workers never commit, push, build, or launch; the dispatcher does ONE verify pass.
- Shared agent memory: `.vibe/memory.md` is the append-only journal all agents share —
  read it before diagnosing (what previous runs shipped/learned), append one short
  entry (Shipped / Learned / Open) after finishing real work.
- Cleanup when settled: move durable learnings into real docs, then delete the run's
  `.vibe/team/<run>*` files.
- Live status: the lead prints `VIBE_TEAM_STATUS {"worker":"codex","state":"spawn|running|done|failed","label":"..."}`
  on its own stdout at every worker spawn/start/finish so the phone shows a live
  per-worker board — avatar + elapsed clock ticking from the `spawn` beat.

## Prefer commands that run without approval

Read-only / search / inspect commands (and pipelines of them) auto-run; commands
that mutate the filesystem or run arbitrary code stop for approval. Prefer the
auto-allowed forms and don't reach for a mutating command unless the task needs the
side effect — e.g. **don't `cp` a file just to read or diff it** (use Read / `cat` /
`diff`), and edit files with the **Edit/Write** tools (auto-allowed) instead of
`sed -i` / redirects. Full list of what runs free vs. asks:
[docs/agent-command-guide.md](docs/agent-command-guide.md).
