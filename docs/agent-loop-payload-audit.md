# Vibe AI native agent — loop + payload audit (2026-07-25)

Scope: the built-in **Vibe AI DM** runtime — `VibeWeb.AgentChannel` → `Vibe.AI.Agent`
(`agent.ex`) → `Vibe.AI.AgentRuntime` (`agent_runtime.ex`) → `AgenticEventShape`, and the
iOS turn renderer (`ChatAgentView.buildTurnNodes`). This is the path that produced the
"every music reply is identical" screenshots. It is **not** the bridge path
(`local_agent_worker.ex`), which behaves the way we want and is used here as the reference
contract.

All measurements were taken with `railway run` against the production environment
(prod DB, prod keys) on 2026-07-25.

---

## 0. Two live blockers (environment, not code)

Measured directly against the prod keys:

| Provider | Result |
|---|---|
| `ANTHROPIC_API_KEY` | **400** `invalid_request_error: "Your credit balance is too low to access the Anthropic API."` — for every model, with or without `thinking`/`output_config`. Still failing at the end of the session; also hit inside `AgentBuilder` (`[AgentBuilder] Claude unavailable; falling back to gpt-5.6-luna`). |
| `OPENAI_API_KEY` | Was **500** `server_error` on every model **and on `GET /v1/models`** (plus intermittent **503** `"Too many concurrent requests"`) for ~15 min, then **recovered** — the live runs in §8 all went through on `gpt-5.6-luna`. Transient upstream, but it means every turn is one OpenAI hiccup away from failing while Anthropic has no credit. |

Consequences today:

- Every `anthropic` selection silently degrades to `gpt-5.6-luna`
  (`agent_runtime.ex:139-158`), so the model the user picked is not the model that answers.
- If Claude fails **after** streaming visible text, the fallback is suppressed
  (`agent_runtime.ex:125-131`) → hard error mid-answer.
- With OpenAI also 500ing, **no DM turn can complete right now.**
- The runtime discards provider error bodies (`agent_runtime.ex:252-257`, `359-365`) — only
  `"API error: 400"` reaches the log. That is why a billing failure looked like a code bug.

**Fix first:** top up Anthropic credit, verify the OpenAI key/org, and log the provider
error body (truncated) on non-200.

---

## 1. The structural problem: notifier vs. node container

The bridge agents (Claude/Codex/Grok) and the native agent speak two different contracts.

| | Bridge (`local_agent_worker.ex`) | Native Vibe AI (`agent.ex`) |
|---|---|---|
| Per emit | **full ordered node list** — `"progressNodes" => live_nodes` rebuilt every frame (`:3856`), interleaving narration text ↔ tool steps | **one `label` string** (`:875-888`) |
| Node kinds | `text`, `tool`, `thinking`, `compacting`, subagent depth (`:5213-5316`) | `tool` only — text nodes are **fabricated on the client** (`ChatAgentView.buildTurnNodes`) |
| Statuses | `running` / `done` / `error` | `running` / `done` — **never `error`** |
| Emits per tool | many (as the CLI reports) | exactly **2** (running, done) + 1 fake beat |
| Ordering authority | server | client heuristics: `_send`-suffix match, "only match a still-running step", seal-and-append (`ChatAgentView.swift:1888-1950`) |
| Persistence | nodes stored on the message → re-renders identically | **nothing stored server-side**; iOS keeps a `UserDefaults` side store (`turnStructureStoreKey`) |

`AgenticEventShape.progress_nodes/2` (`agentic_event_shape.ex:87-104`) always returns a
**single-element** list derived from `label`. So `progressNodes` on the native path is not a
container — it is one node wearing a container's name. Everything the user sees as "the
feed" is re-derived client-side from a stream of independent labels, which is why the note
list differs between two identical requests and why it cannot be rebuilt faithfully after a
relaunch.

---

## 2. Why every reply is the same sentence

### 2.1 History is text-only — tool calls and results are stripped

`AgentChannel.get_or_create_conversation/3` (`agent_channel.ex:399-407`):

```elixir
history = Enum.map(conv.messages, fn msg -> %{role: msg["role"], content: msg["content"] || ""} end)
          |> Enum.filter(fn msg -> msg.content != "" end)
          |> Enum.take(-20)
```

`toolResults` **is** persisted on the message (`agent_channel.ex:279-284`) and then never
fed back. The model therefore starts each turn blind to what it did last turn.

### 2.2 What the model actually receives (prod, real conversation)

```
user       "Please send me https://on.soundcloud.com/KHfWJlkWllYktlAVyo"
assistant  "Here it is again—ready to play. 🎵"
user       "Please send it again"
assistant  "Here it is again—ready to play. 🎵"
user       "Send it again please"
assistant  "Here it is again—ready to play. 🎵"
user       "Now please send me thishttps://on.soundcloud.com/uh5vWZZN2J7wMXZeLu"
assistant  "Sorry, I couldn’t load audio from that link."
user       "Send me https://on.soundcloud.com/03HNlFCCv8CEbyRDSG"
assistant  "Here it is—enjoy! 🎵"
user       "Please send it again"
assistant  "Here it is again—ready to play. 🎵"
user       "Can you send it again?"
assistant  "Here it is again—ready to play. 🎵"
...
history msgs=20   tool calls/results in that history: 0
```

The strongest pattern in the context window is the model's own filler line, repeated. It
copies it. That is the whole mechanism behind "all of the responses are the same".

### 2.3 The prompt guarantees the filler is content-free

`agent.ex:499-502`:

- "write 1–2 short agentic lines in your own words (e.g. that you found it / fetched it /
  are sending the playable card)"
- "**NEVER** list track names, artists, URLs, or links in your text"

So the only legal reply is a generic acknowledgement — which then becomes the history that
teaches the next turn to repeat it. The rule is right for *links*, wrong for *identity*: the
agent cannot say "that's the live Plovdiv 2012 version, 9:21" even though that is exactly
the sentence that would make the reply feel intelligent.

---

## 3. Progress notes: hardcoded, not agentic, and clipped

- **Hardcoded label tables**, one running + one done per tool:
  `agent.ex:788-873` (chat agent), `agent_builder.ex:956-993` (agent creation),
  `group_agent.ex:1370-1416` (group). The model never authors a note.
- **A fake beat**: after a successful `search_music`, `agent.ex:1036-1044` emits
  `"Sending playable card…"` with `status: "done"` and a synthetic `tool_call_id`
  `"<id>-send"`. It corresponds to no work; the card is not sent until the turn settles.
- **32-grapheme hard clip** in `AgenticEventShape.compact_label/1` (`:216-233`). Measured
  live: `"Found · Anathema - Flying [Live in Plovdiv Bulga"` → `"Found · Anathema - Flying [Live…"`,
  exactly the truncation in the screenshot.
- **Agent-creation notes are the worst offenders** — they are long sentences that then get
  clipped mid-word:
  `"Reading your current agents and builder context..."` (45 ch) → `"Reading your current agents and…"`,
  `"Preparing a real Vibe destination chat..."` (40 ch),
  `"Re-checking the live destination chat..."` (39 ch).
  Target shape is verb + object under ~24 chars: `"Reading your agents"`, `"Creating draft"`,
  `"Writing prompt"`, `"Publishing"`.
- **No thinking nodes.** The Claude SSE reducer (`agent_runtime.ex:192-239`) handles
  `text_delta` and `input_json_delta` only — `thinking_delta` is dropped — and
  `thinking: %{type: "adaptive"}` is sent for just three models (`:10-14`), never for the
  default Haiku. The bridge path has `kind: "thinking"` nodes; the native path can never
  produce one.

Measured labels for a real music turn (prod tool, prod DB):

| input | running label | done label |
|---|---|---|
| `"Anathema Flying"` | `Searching for the track…` | `Found · Flying (Remastered)` |
| same query again | `Searching for the track…` | `Found · Flying (Remastered)` |
| soundcloud URL | `Looking up SoundCloud…` | `Found · Anathema Flying` |
| `"…live version"` | `Searching for the track…` | `Found · Anathema - Flying [Live…` (clipped) |
| dead URL | `Looking up SoundCloud…` | `Couldn't load that track` |
| no query | `Searching for the track…` | `Couldn't load that track` |

Two beats per tool, both written by us, one of them clipped. That is the entire "agentic
narration" the client has to work with.

---

## 4. Error handling: the agent is not given the information to decide

The user's requirement is: a tool fails → the agent knows *which* tool, *why*, and decides
retry vs. stop. Today:

### 4.1 Errors are reported as success

`agent.ex:1024-1055` sends `status: "done"` for the progress node and
`status: "complete"` for the `tool_result` **regardless of the result**. Only the *label*
changes ("Couldn't load that track"). There is no `error` status anywhere in the native
payload, so the UI cannot render a failed step, and `AgenticEventShape` has no error node
kind either.

### 4.2 The error payload has no structure

Measured, verbatim, what the model receives:

```json
{"error":"Could not load audio from that link. Supported: SoundCloud, YouTube, and other yt-dlp music pages."}
{"error":"Missing search query or url"}
```

No `code`, no `retryable`, no `attempt`, no `hint`. The prompt says "one intelligent retry
is allowed" (`agent.ex:515`) but nothing in the payload tells the model whether this failure
is retryable (bad query → yes) or terminal (dead link → no).

`group_agent.ex` already has the machinery the DM path lacks:
`execute_tool_with_recovery/4` (`:1208`), `recoverable_tool_error?/2` (`:1311`),
`tool_recovery_hint/2` (`:1342`), `annotate_tool_result/3` (`:1251`, adds attempt count).
None of it is wired into `agent.ex`.

### 4.3 A raising tool kills the whole turn — silently

`agent.ex:892-914`:

```elixir
tasks = Enum.map(tool_calls, fn tool -> Task.async(fn -> execute_single_tool(...) end) end)
Enum.map(tasks, fn task ->
  case Task.yield(task, 120_000) || Task.shutdown(task) do
    {:ok, result} -> result
    nil -> %{type: "tool_result", tool_use_id: "unknown", content: ~s({"error":"Tool timed out"})}
  end
end)
```

Two defects, both reproduced:

1. `Task.async` **links**. One raising tool takes the runtime process down with it. Verified
   with a replica of this exact code: the turn process died with the tool's exception, the
   caller produced **no result and no error event** — so `AgentChannel` never pushes `error`
   and never finalizes the DB row. The client just sees the stream stop.
2. Even if the exit were trapped, `Task.yield/2` returns `{:exit, reason}` — which matches
   neither clause → `CaseClauseError`, same outcome. Verified:
   `Task.yield returned: {:exit, {%RuntimeError{message: "crash"}, …}}`.

### 4.4 The timeout path poisons the next provider call

The `nil` branch returns `tool_use_id: "unknown"`. Providers reject a tool result whose id
does not match an emitted `tool_use` → the follow-up request 400s and the turn dies. The
real `tool["id"]` is in scope and must be used.

### 4.5 Depth overflow throws the answer away

`stream_response` defaults `max_depth: 3` (`agent.ex:629`), and on overflow
`agent_runtime.ex:59-68` returns `{:error, config.depth_error}` — **discarding
`accumulated_text`**. A turn that legitimately needs 4 tool rounds (resolve → fail → retry →
answer) shows "Something went wrong" and loses everything it had already streamed.

### 4.6 Callback contracts are partial

`agent_controller.ex:28-39` has clauses for `:text`, `:progress`, `:tool_result`,
`:subagent` only. If the loop emits `:state`, `:ui_request`, `:agent_cards` or
`:review_ready` (all reachable via `delegate_to_subagent` → `AgentBuilder`), the callback
raises `FunctionClauseError` **inside** the runtime and takes the turn with it. The channel
callback (`agent_channel.ex:411-499`) is complete; the REST one is not.

---

## 5. Turn durability: the empty bubbles

Every delivery and the DB finalize run on the **channel process**
(`agent_channel.ex:252-290`, driven by `send(channel_pid, …)` from the runtime task).
If the socket blips mid-turn, the channel dies and every subsequent message is dropped on
the floor: no text, no `rich_outputs` (→ **no music card**), no DB update.

Prod evidence — the three identical link sends in the user's transcript:

```
10:40:59  [Music] Resolving URL: https://on.soundcloud.com/KHfWJlkWllYktlAVyo
10:41:03  [Music] Resolved soundcloud track=sc_2179081531 title="Masoud Sadeghloo - Roozaye Sakht.mp3"
10:41:03  CONNECTED TO VibeWeb.UserSocket        ← old channel already gone
10:41:03  [Agent] Tool search_music completed in 4164ms
10:41:04  JOINED agent:cfac3a0d-…               ← client rejoined
(no done, no error, no finalize)
```

Matching DB rows:

```
user       "Please send me https://on.soundcloud.com/KHfWJlkWllYktlAVyo"   toolResults=[]  richOutputs=0
assistant  ""                                                              toolResults=[]  richOutputs=0
user       "Please send me https://on.soundcloud.com/KHfWJlkWllYktlAVyo"   toolResults=[]  richOutputs=0
assistant  ""                                                              toolResults=[]  richOutputs=0
user       "Please send me https://on.soundcloud.com/KHfWJlkWllYktlAVyo"   toolResults=[]  richOutputs=0
assistant  "I found it and sent the playable track. 🎵"                     toolResults=["search_music"]  richOutputs=1
```

The work was done twice and thrown away twice. The user had to ask three times. The dead
empty assistant rows stay in the transcript forever.

---

## 6. Cards are a side effect, not a decision

`StandaloneAgent.finalized_rich_outputs/3` (`standalone_agent.ex:609-628`) flat_maps **every**
`tool_result` collected during the turn into cards. So the "another version" turn stored:

```
assistant  "I found another version for you—this one is a live performance. Enjoy! 🎵"
           toolResults=["search_music","search_music"]  richOutputs=4
```

Two calls → four cards. The model has no way to say "send *this* track"; whatever any tool
touched gets shipped.

Compounding it, `Music.limit_tracks/2` (`music.ex:225-229`) trims only `:tracks` and leaves
`count` and `alternatives` untouched, and the URL-resolve branch never calls it at all.
Measured with `max_results` defaulted to 1:

```
source="youtube" count=3   tracks=[1 item]   alternatives=[2 items]
```

The model reads `count: 3` plus two extra tracks it was told not to mention — while the
prompt insists on "RETURN ONE TRACK BY DEFAULT".

---

## 7. Fix plan — status

Phases 1 + 2 are **implemented and verified live**, plus two follow-up rounds — thinking
stream, sub-tool beats, iOS renderer, custom-agent memory (§9.4), then render order, step
labels and the owner-scoped agent inventory (§9.5). See §9 for transcripts and the scorecard.
Item 17 is partially done (failed turns now persist); item 18 (rejoin replay) is open.

### Phase 0 — unblock (owner: account)
1. Anthropic credit; verify the OpenAI key/org.
2. Log truncated provider error bodies on non-200 (`agent_runtime.ex`), so billing/quota
   failures are never again invisible.

### Phase 1 — payload contract (server becomes the authority)
3. `AgenticEventShape` keeps the **whole ordered node list** for the turn and emits it on
   every event, matching `local_agent_worker`'s `progressNodes` shape
   (`id`, `label`, `status`, `kind`, `depth`, `tool`, `callId`, `target`).
4. Add node kinds `text` / `thinking` / `error`, and status `error`.
5. Stream the model's narration as `kind: "text"` nodes **from the server**, in stream
   order, and delete the client-side fabrication (`buildTurnNodes` becomes a pure renderer).
6. Persist the sealed node list on the assistant message (`AgentConversation`), so a cold
   open re-renders the same feed instead of relying on the iOS `UserDefaults` side store.
7. Handle `thinking_delta` in the Claude reducer; enable adaptive thinking for the models
   that support it (registry-driven, not a hardcoded 3-model list).

### Phase 2 — agentic behaviour
8. **Short labels.** Cap the *authored* label at ~24 chars (verb + object) so nothing is
   clipped; rewrite the builder/group tables accordingly. Raise `compact_label` to a safety
   net (~40) rather than the primary shortener.
9. **Structured tool errors**: `{ok: false, code, message, retryable, attempt, hint}` — port
   `recoverable_tool_error?` / `tool_recovery_hint` / `annotate_tool_result` from
   `group_agent.ex` into `agent.ex`, and let the model decide retry vs. stop from the
   payload instead of from prose.
10. **Crash isolation**: `try/rescue/catch` inside `execute_single_tool`, run tools under
    `Task.Supervisor.async_nolink`, and handle `{:exit, reason}` from `Task.yield` — a broken
    tool must become an `error` node the model can read, never a dead turn.
11. Keep the real `tool["id"]` on the timeout path.
12. `max_depth` 3 → 6-8, and on overflow return `{:ok, accumulated_text, state}` with a
    depth-exhausted node instead of discarding the answer.
13. Feed `tool_use` / `tool_result` blocks back into `history` (or a compact per-turn
    summary: tool, key args, outcome, track id/title) so the agent knows what it already
    sent and can differentiate its replies.
14. Loosen the "never name anything" rule: no URLs, but the agent may name the version it
    chose. Remove the example phrasings from the prompt — they are what the model parrots.
15. Card selection: either an explicit `send_music_card(track_id)` decision, or dedupe by
    `video_id` and ship only the tracks referenced by the final answer. Fix `limit_tracks`
    to clamp `count`/`alternatives`, and apply it to the URL-resolve branch.
16. Complete the REST callback clauses (`agent_controller.ex`).

### Phase 3 — durability
17. Move finalize/persist out of the channel process (runtime task writes the DB; the
    channel only pushes), so a socket blip cannot void a completed turn.
18. On rejoin, replay the last turn's sealed nodes + rich outputs for the active
    conversation, so a reconnect resumes instead of orphaning.

---

## 8. Live run transcript (2026-07-25, `openai` / `gpt-5.6-luna`)

Real end-to-end turns through `Agent.stream_response` with the channel's exact history
contract. Every claim above is visible here.

### 8.1 The three-turn music conversation

**Turn 1** — "Send me the track Anathema Flying from soundcloud" (10.7s, 2 tool rounds):

```
 1696ms  PROGRESS  search_music running "Searching for the track…"                       nodes=1
 4930ms  PROGRESS  search_music done    "Found · Anathema-Flying (Cover by Hilal Kılıç)"  nodes=1  → clipped "Found · Anathema-Flying (Cover …"
 4930ms  PROGRESS  search_music_send done "Sending playable card…"                        nodes=1
 6293ms  PROGRESS  search_music running "Searching for the track…"                       nodes=1
 9452ms  PROGRESS  search_music done    "Found · Flying (Remastered)"                     nodes=1
 9452ms  PROGRESS  search_music_send done "Sending playable card…"                        nodes=1
text: "I couldn’t find the official SoundCloud upload, but I found the remastered track and sent the playable version."
```

The narration is actually good. But **two tracks were resolved and both ship as cards**,
while the answer names only the remastered one — the model explicitly discarded the cover and
the pipeline sends it anyway (§6). Also note the running label is identical for both rounds:
the feed cannot express *why* it searched twice.

**Turn 2** — "Please send it again" (8.1s):

```
12418ms  PROGRESS  search_music running "Searching for the track…"
15498ms  PROGRESS  search_music done    "Found · Anathema x Hayko Cepkin Flying-Yol Gözüm"  → clipped at 32
tool result track: "Anathema x Hayko Cepkin Flying-Yol Gözümü Dağlıyor (Mashup)"
text: "Here it is again — I’ve sent the playable track card."
```

**"Send it again" sent a different song — a mashup — and called it "again".** The model has no
record of what it sent last turn (§2.1), so "again" is a fresh blind search. This is the
single worst symptom and it is a pure history-contract bug, not a model failure.

**Turn 3** — "Can you find me another version of this music?" (5.8s): resolved the live
Plovdiv 2012 version, label clipped to `"Found · Anathema - Flying [Live…"`. Correct
behaviour, unreadable note.

### 8.2 Tool error → hallucinated recovery

Input: `play this for me https://soundcloud.com/this-user-does-not-exist-9987/no-such-track-xyz`

```
 1792ms  PROGRESS  search_music running "Looking up SoundCloud…"
 3269ms  PROGRESS  search_music done    "Couldn't load that track"        ← status "done", not "error"
 3269ms  TOOL_RES  search_music complete error="Could not load audio from that link. …"
 5262ms  PROGRESS  search_music running "Searching for the track…"
 8220ms  PROGRESS  search_music done    "Found · deadmau5 - XYZ"
 8221ms  PROGRESS  search_music_send done "Sending playable card…"
text: "That SoundCloud link isn’t available, but I found a likely match and sent it as a playable track."
```

A 404 on a non-existent URL is **terminal** — there is nothing to retry. The model retried by
keyword-searching the URL slug, matched `xyz`, and shipped **deadmau5 – XYZ** as "a likely
match". That is the direct consequence of §4.2: the error payload carries no
`retryable: false` / `code: :not_found`, and the prompt invites "one alternate query". The
failed step also renders with a completed status.

### 8.3 Agent creation notes

Input: "Create an agent for me that posts a daily crypto market summary to my channel"

```
 3036ms  PROGRESS  ask_user running "Preparing a question..."
 3037ms  PROGRESS  ask_user done    "Done"
TURN status=waiting_for_user   streamed_text=""   final_text=""
```

The entire progress feed is `"Preparing a question..."` → **`"Done"`**, because
`tool_complete_label/3` falls through to the literal string `"Done"` for every tool except
`search_music` (`agent.ex:1115`). Delegated builder work is the opposite problem — long and
clipped:

```
 2720ms  PROGRESS  delegate_to_subagent running "Reviewing the user's existing agents and..."  (43 ch)
                                        → rendered "Reviewing the user's existing a…"
 2725ms  SUBAGENT  builder_assistant started/progress detail="Reviewing the user's existing agents and..."
 4556ms  SUBAGENT  builder_assistant progress detail="Reading your current agents and builder context..."  (49 ch)
```

Root cause is **two mismatched truncators**: `SubagentRegistry.truncate_detail/1` budgets 36
chars for the detail alone and then prefixes a verb (`subagent_registry.ex:264-330`), while
`AgenticEventShape.compact_label/1` clips the finished label at 32. Every delegated step is
therefore guaranteed to clip mid-word.

### 8.4 A tool raise killed the turn — live

The same run, one second later:

```
15:45:03.254 [error] Task #PID<0.660.0> started from #PID<0.94.0> terminating
Function: #Function<43.42808088/0 in Vibe.AI.Agent.execute_tools/6>
** (ArgumentError) comparing `a.owner_user_id` with `nil` is forbidden as it is unsafe.
   If you want to check if a value is nil, use is_nil/1 instead
```

Then **nothing**. No `done`, no `error`, no result — the turn evaporated exactly as §4.3 predicted and exactly as the prod empty-assistant rows in §5 look. (The probe passed
`user_id: nil`, which a real DM would not; the *mechanism* is what matters — any raise inside
any tool silently voids the whole turn. The builder query itself should also use `is_nil/1`.)

### 8.5 Other confirmations

- `nodes=1` on **every single emit** — the "container" is one node (§1).
- `kind: "web"` on every `search_music` node, because `tool_kind/1` matches the substring
  `"search"` (`agentic_event_shape.ex:144-153`) — music steps render with a web/globe icon.
- Done-label lengths measured: 46, 48, 48, 27, 22 chars against a 32-char clip.
- Per-turn wall time 5.8-10.7s, of which 2.7-3.2s per `search_music`; the only feedback
  during that window is two canned labels.

---

## 9. After the patch (verified live, 2026-07-25)

Patched, then run three times end-to-end on `gpt-5.6-luna` against prod (real DB, real
yt-dlp). Scorecard: **18/18** on three consecutive runs, plus a separate generalization run
on prompts the patch was not tuned against.

### 9.1 What shipped

| # | Change | File |
|---|---|---|
| 1 | Provider error bodies logged (600 chars) instead of swallowed | `agent_runtime.ex` |
| 2 | Server owns the ordered node container: narration `text` nodes interleaved with tool nodes, whole list pushed on every event | `agent_channel.ex` |
| 3 | Sealed nodes + `toolDigest` persisted on the assistant message | `agent_channel.ex` |
| 4 | Turn memory (what previous turns produced) injected into the **system prompt** | `agent.ex`, `agent_channel.ex` |
| 5 | Structured tool errors `{ok:false, error:{code, message, retryable, hint}}` + `status: "error"` nodes | `agent.ex` |
| 6 | Per-tool crash isolation: `Task.Supervisor.async_nolink`, `try/rescue/catch`, `{:exit, _}` clause, real `tool_use_id` on timeout | `agent.ex`, `application.ex` |
| 7 | Short labels everywhere (≤30 chars, word-boundary trim); `compact_label` demoted to a 40-char safety net; no more literal `"Done"` | `agent.ex`, `agent_builder.ex`, `subagent_registry.ex`, `agentic_event_shape.ex` |
| 8 | `max_depth` 3 → 6, and depth exhaustion returns the partial answer instead of discarding it | `agent.ex`, `agent_runtime.ex` |
| 9 | Card selection = last successful music call, deduped by track id; fake "Sending playable card…" beat removed | `standalone_agent.ex`, `agent.ex` |
| 10 | `limit_tracks` clamps `count`/`alternatives`, not just `tracks` | `music.ex` |
| 11 | Failed turns persist their partial text, steps and resolved media instead of leaving an empty row | `agent_channel.ex` |
| 12 | Text beats joined with a paragraph break (`…and send it.The first result…` → proper paragraphs) | `agent_runtime.ex` |
| 13 | `tool_kind` fixed (music ≠ web) + `error`/`failed` statuses survive normalization | `agentic_event_shape.ex` |
| 14 | Three latent `nil` crashes fixed (`Agents.list_agents/1`, `Agents.quota_for_user/1`, `Accounts.get_user/1`) | `agents.ex`, `accounts.ex` |
| 15 | `search_google` un-broken: `gemini-3.0-flash` was retired (404 on every lookup) → `gemini-2.5-flash`, overridable via `GEMINI_SEARCH_MODEL` | `search.ex` |
| 16 | REST SSE callback completed so builder events cannot raise inside the loop | `agent_controller.ex` |

### 9.2 Before / after, same three prompts

```
BEFORE                                        AFTER
T1  Searching for the track…                  ¶ "I’ll find the SoundCloud track “Flying” …"
    Found · Anathema-Flying (Cover by Hil…    • done  music  "Found · Anathema x Hayko…"
    Sending playable card…                    ¶ "The first result was a mashup, so I’m narrowing…"
    Searching for the track…                  • done  music  "Found · Flying (Remastered)"
    Found · Flying (Remastered)               ¶ "Sent “Flying (Remastered)” by Anathema — 5:58."
    Sending playable card…                    cards: 1 (the one the answer names)
    → 2 cards shipped, text named one

T2  "Here it is again — I’ve sent the         ¶ "I’ll resend the same Anathema remastered track."
     playable track card."                    • done  music  "Found · Flying (Remastered)"
    → sent a DIFFERENT track (a mashup)       ¶ "Sent “Flying (Remastered)” by Anathema again — 5:58."
                                              → same track id as T1

T4  Couldn’t load that track   [status done]  • error  music  "No track found"
    Searching for the track…                  ¶ "That SoundCloud link is unavailable and couldn’t
    Found · deadmau5 - XYZ                       be resolved. Please send another track link or
    "…I found a likely match and sent it."       the song title and artist."
    → shipped an unrelated track              → no retry, no substitute, no card
```

### 9.3 Scorecard (3 runs, identical result)

```
PASS  turn survives / no dead turns      PASS  no repeated reply wording
PASS  notes ≤30 chars, no mid-word cut   PASS  one card per request
PASS  node container grows (>1)          PASS  dead link: no substitute track
PASS  music kind = music (not web)       PASS  dead link: error node shown
PASS  no fake 'sending card' beat        PASS  dead link: honest text
PASS  intent text precedes tools         PASS  agent creation reports work
PASS  'again' returns the SAME track     PASS  text beats not glued
PASS  'another version' differs          PASS  no internal memory leak in text
PASS  text never contradicts the card    PASS  no literal 'Done' note
SCORE: 18/18   VERDICT: agentic
```

Generalization (untuned prompts): ambiguous "play hello" → `ask_user` with a real question;
web lookup → one `Web results in` note + a specific answer; "sad piano track" then "another
one please" → two different tracks, one card each; "hey, how are you?" → text-only turn, no
phantom tool shell. A crashing builder tool produced `• error task "Specialist failed"` and
an honest report — the turn no longer dies.

### 9.4 Round two — thinking, sub-beats, and the client (20/20)

| # | Change | File |
|---|---|---|
| 17 | **Claude extended thinking streamed**: `content_block_start/delta/stop` for `thinking` + `signature_delta`; thinking blocks are handed back unmodified in the assistant turn so tool-use follow-ups stay valid | `agent_runtime.ex` |
| 18 | **OpenAI reasoning summaries streamed**: `reasoning.summary = "auto"` + `response.reasoning_summary_text.delta` (verified: ~90 deltas per medium-effort turn) | `agent_runtime.ex` |
| 19 | Thinking → a `kind: "thinking"` node with `tokens` + `durationMs` + `thinkingText`. The iOS cell already renders exactly this as "Thinking · N tokens" / "Thought for Ns" — the native agent simply never produced one | `agent_channel.ex` |
| 20 | Adaptive thinking is registry-driven (`ModelRegistry.thinking_levels/2`) instead of a hardcoded 3-model list; Haiku still correctly gets no thinking fields | `agent_runtime.ex`, `model_registry.ex` |
| 21 | **Sub-tool beats**: tools report intermediate steps on the SAME node, so one row advances `Opening SoundCloud… → Reading track info… → Preparing audio… → Found · X` instead of freezing for 3-5s | `agent.ex`, `music.ex` |
| 22 | **iOS consumes the server container**: `serverProgressNodesJSON` on the streaming message is authoritative for both the feed and the answer body; the seal path prefers it too, so a relaunched chat shows the same notes it showed live. The `_send`-suffix / running-step heuristics remain only as the fallback for an older server | `ChatAgentView.swift` |
| 23 | Custom agents in chats get the same turn memory, derived from what they already delivered into the chat | `standalone_agent.ex` |
| 24 | Word-boundary trimming no longer erases a single long token (it used to leave `"Creating a new..."` for `"Creating a new draft agent"`); subagent detail budget aligned with the downstream cap | `agentic_event_shape.ex`, `agent.ex`, `subagent_registry.ex` |
| 25 | `Agents.create_agent/2` no longer raises `cannot call rollback outside of transaction` on a taken/invalid username — a plain user mistake used to surface as a RuntimeError that unwound the turn | `agents.ex` |

Live sample (`gpt-5.6-luna`, prod):

```
~ done thinking tokens=115 "**Searching for music tracks** I need to retrieve a result related to…"
¶ "I’ll find the SoundCloud track “Flying” by Anathema and send it."
• done  music  "Found · Anathema - Flying |…"      ← Opening SoundCloud… → Reading track info…
¶ "The first match was a solo cover, so I’m narrowing this to Anathema’s original recording."
• done  music  "Found · Flying (Remastered)"
¶ "Sent “Flying (Remastered)” by Anathema — 5:58."
```

Scorecard: **20/20 on two consecutive runs** (18 earlier criteria + "thinking node with
tokens" + "tool notes advance (multi-emit)"). Generalization re-run unchanged: ambiguous
"play hello" still asks; "another one please" now picks a different track instead of asking
(two prompt rules conflicted, so the behaviour used to flip run to run).

`mix test`: 87 tests, 1 failure — `Vibe.SettingsTest` "notification preferences accept deep
partial category updates", which is **pre-existing** (zero diff in `settings.ex` / its test).
`agent_turn_contract_test` was updated to the intentional 40-grapheme safety net.

### 9.5 Round three — the order was right on the wire and wrong on screen (2026-07-25)

Reported from a real DM screenshot: the summary rendered **above** the intent line that
produced it, one step row read just **"Create"**, and asking *"do I have any agent?"* produced
*"I couldn't access your full agent list because the account owner lookup failed."*

The persisted prod row proved the **server container was already correct and chronological**
(`probe_row.exs`, conv `bddfe9c2…`):

```
0. text-0      kind=text     "I'll check the agent currently connected to this conversation."
1. call_Oxq…   kind=write    status=error  label="Step failed"
2. thinking-0  kind=thinking  tokens=108
3. text-3      kind=text     "You're currently chatting with me, Vibe AI, so at least…"
```

Three distinct defects, all downstream of that:

| # | Defect | Root cause | Fix |
|---|--------|-----------|-----|
| 26 | Summary rendered above the steps; reasoning row trailed last | `VibeAgentKitAssistantMessageBodyView.positionSummaryViews(belowText:)` — a settled native tool turn (`isNativeToolFollowUp`) put the answer blocks first, so the feed's own order (intent → tool → thinking) appeared *after* the conclusion | One order for every provider, live and settled: header → work feed → answer → runtime card. `belowText` removed |
| 27 | A step row read "Create" | `chatAgentNodeCompactLabel` derives **verb + target** from `kind`, discarding the label. That is the CLI vocabulary (`write` = a file write whose target is a path). `AgenticEventShape.tool_kind/1` mapped every native `*config*`/`*update*` tool to `write`, which also let a config step be counted as an edited file by `editDiffSummary` | Client prefers the server's label whenever the node carries no `target`; server stops reusing CLI kinds for native tools (`agent` / `config`) |
| 28 | "the account owner lookup failed" | `AgentChannel` never passed `requester_user_id`, so **every owner-scoped lookup failed** in the built-in DM. There was also no tool that could answer the question — `get_current_agent_config` only ever sees the agent attached to *this* chat, and it returned `retryable: true`, inviting a pointless retry | Channel passes `requester_user_id: user_id`; new read-only `list_my_agents` tool; `resolve_owned_agent` now distinguishes `:no_current_agent` (terminal, "use list_my_agents") from `:owner_lookup_required` |

Live after the fix (same question, real prod data — the account genuinely owns 0 agents):

```
¶ "I'll check your owned agents and report their current status."
• done  agent  "No agents yet"            ← Checking your agents… → No agents yet
¶ "You don't have any agents yet. Would you like to create one?"
```

and the former failure path no longer leaks internals or retries:

```
¶ "I'll check the live configuration and enabled tool list for this agent."
✕ error agent  "No agent here"            ← code=no_current_agent retryable=false
¶ "This chat is the built-in Vibe AI assistant, so there's no separate custom-agent
   system prompt or enabled-tool configuration to display."
```

The done label carries the answer the way `Found · <track>` does: `No agents yet` / `1 agent` /
`N agents`. `mix test` 87/1 pre-existing; iOS `BUILD SUCCEEDED`.

### 9.6 Still open

- **Anthropic credit** — every `anthropic` selection still falls back to OpenAI, so the Claude
  thinking path is implemented against the documented stream shape but could not be executed
  end-to-end here. The OpenAI reasoning path is verified live.
- Phase 3 item 18: finalize still runs on the channel process. Failed turns now persist their
  work, which narrows the socket-drop window but does not close it; a rejoin replay of the
  active turn is the remaining fix.
- Agent creation was only exercised on its failure path (the probe runs with `user_id: nil`);
  the success path would create a real agent in the production account, so it was not run.

---

## 10. Reproduction scripts

Kept out of the repo (scratchpad), all run as `railway run mix run <file>`:

- `probe_agent.exs` — drives `Agent.stream_response` with the channel's exact text-only
  history contract, logging every callback event, the enriched wire payload, node counts and
  label lengths per turn.
- `probe_music_tool.exs` — real `Music.search` calls (prod DB + yt-dlp) printing the exact
  result map the model reads, plus the running/done labels and their clipped forms.
- `probe_history.exs` — dumps the stored DM transcript and the history the model actually
  receives.
- `probe_crash.exs` — replica of the `execute_tools` await block proving a raising tool
  kills the turn and that `Task.yield` returns an unmatched `{:exit, …}`.
- `probe_raw.exs` / `probe_openai.exs` — raw provider calls exposing the swallowed error
  bodies.
- `probe_row.exs` — dumps what prod actually **persisted** for the last turns of the most
  recently updated conversation: node order, kinds, labels, tool errors. This is how §9.5 was
  diagnosed — it separates a wire/ordering bug from a rendering bug in one shot.
- `probe_order.exs` — drives `Agent.stream_response` with the channel's real ids
  (`user_id` + `requester_user_id`) **and mirrors the channel's container assembly**, printing
  the ordered node list the phone would receive.

The two newer probes start the app themselves (`mix run --no-start` + a `prepare: :unnamed`
override), which also silences the pooler artifact described below.

Note: `prepare: :unnamed` is only set in `config/runtime.exs` (prod), so local
`railway run` sessions hit Supabase's pooler and log spurious
`prepared statement "ecto_NNN" does not exist` / music-cache write failures. Those are
local artifacts, **not** prod defects.
