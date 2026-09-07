# The Vibe agent team

Our own agents — not customers'. They are `LocalAgentWorker` entries that run the real
Claude Code / Codex CLIs **on our server, on our subscription**. Customer agents are rows
in the `agents` table on API keys, metered and quota'd; these are neither.

| handle        | CLI    | model        | thinking | owns |
| ------------- | ------ | ------------ | -------- | ---- |
| `@boss`       | claude | fable → opus | max      | delegating, deciding priority |
| `@monitor`    | claude | haiku        | low      | security status, logging, health, incident triage |
| `@coder`      | claude | opus         | xhigh    | patching, code review, updating, launching, deploying |
| `@researcher` | codex  | —            | high     | investigation |
| `@marketing`  | claude | sonnet       | medium   | positioning, copy |
| `@social`     | claude | haiku        | low      | social posting |
| `@media`      | claude | sonnet       | medium   | media generation |

`@boss` runs on Fable — the strongest model on a Max plan. If the plan cannot reach it
(no Fable, exhausted quota, unknown alias) the run retries once on `opus`. Thinking is
per role, not global: `--effort` rides the roster, so a haiku watcher stays cheap and
the roles that decide and patch get the whole ladder. `@boss` runs at `max` because its
call sets everything downstream.

A role worker's model, fallback and level come from the roster and outrank an app pick
(`agentBridgeReasoningEffort`, `agentBridgeEfforts`) — that pick still steers `@claude`,
`@codex` and `@grok`. Only a level written on the mention beats the roster: `@coder [max]`,
`@social (low)`. The boss pins levels this way when it delegates, and no basic model can
ever take the boss seat.

`@agy` is a research helper, reachable only by naming it. It is absent from the roster,
so no broadcast or handoff reaches it and it is never the boss.

DevOps is `@monitor` + `@coder`: monitor watches and never patches, coder patches and
reports back. Models differ per role so cost tracks the job.

## Why not the agents table, and why not the bridge

`chat_channel.ex` forces `local_worker = nil` when `Agents.get_agent_by_username/1`
matches, which routes the mention to the **API-key** runtime. A role agent as an `agents`
row would therefore run on a customer key — the opposite of the point. The JS bridge is
for phone↔Mac coding sessions; role workers do not touch it. `server_runtime?/1` is what
keeps them out of the bridge branch.

## Talking to each other

An agent hands work over by `@mention`ing **one** teammate. `relay_to_teammates/5` takes
the first valid mention only and carries a hop counter capped at `@team_relay_max_hops`,
so a mutual mention can neither fan out nor loop. Every message is a real chat message
from that agent's own user, so the whole exchange is visible to the owner in Vibe.

## Privacy and authorization

Role workers **fail closed**: `dispatch_allowed?/2` requires the requester to be in
`VIBE_AGENT_WORKER_ALLOWED_USERS`, and an unset allowlist means nobody. Bridge workers
keep the old open default, so this is not a regression for `@claude`/`@codex`.
`group_controller.ex` applies the same gate to group membership, so nobody but an
allowlisted owner can add the team to a group.

This matters because `ensure_agent_users/0` makes each worker a real DM-able user. Without
the closed gate, any user could DM `@coder` and run Claude Code on our server.

## Configuration

| variable | effect |
| -------- | ------ |
| `VIBE_LOCAL_AGENT_WORKERS=1` | required; enables server-side workers at all |
| `VIBE_AGENT_WORKER_ALLOWED_USERS` | comma-separated owner ids — the team's allowlist |
| `VIBE_TEAM_WORKSPACE` | the checkout the team's CLIs run in |
| `VIBE_TEAM_CLAUDE_COMMAND` / `_CODEX_` / `_GROK_` | point the CLIs at a wrapper into separate compute |
| `VIBE_TEAM_TIMEOUT_MS` | per-run budget, default 600000 |
| `VIBE_TEAM_EXECUTOR` | run the whole team on one CLI when only that one is signed in |

The `VIBE_TEAM_*` names exist so the team's compute is configured independently of the
bridge's. Customer agents keep `VIBE_AGENT_WORKER_CWD` and `VIBE_AGENT_WORKER_TIMEOUT_MS`.

## Signing in

```
deploy/scripts/team-login.sh --check     # what is signed in
deploy/scripts/team-login.sh             # browser flow for whatever is not
deploy/scripts/team-credentials.sh       # stage them for the team container
```

Subscriptions, not API keys. Credentials stage to `~/.vibe/team-credentials`, never
into the repo.

On macOS Claude Code keeps its credentials in the Keychain, so there is no file to
stage — `claude auth login` has to be run inside the Linux container once. Codex and
Grok use files and stage normally.

## The drill

```
cd server && VIBE_LOCAL_AGENT_WORKERS=1 mix run ../deploy/scripts/team-drill.exs
```

Seeds a group with the owner + `@monitor` + `@coder`, hands monitor a fake iOS crash
report, and prints the transcript. PASS means each agent replied under its own identity
and the handoff dispatched. `VIBE_TEAM_EXECUTOR=grok` runs it on one CLI.

Note that output is parsed as the **executor**, not the handle (`parser_worker/1`) — a
worker named `monitor` matches no CLI clause, so without that swap it posts raw stream
JSON.

## Client logs

iOS `VibeLog` was local-only, so client crashes never reached the server.
`VibeLogUploader` now posts errors and faults to `POST /api/client-logs` on background
and foreground; `ClientLogController` writes them to the journal tagged `[ClientLog]`.
There is no table — they ride the pipeline that already ships `core`, so `@monitor` reads
them with the tool it already has:

```
deploy/scripts/vibe-logs.sh core -g ClientLog
```

Fields are truncated and sanitised, so a client cannot forge extra `key=value` pairs into
a log line. See [vps-logs.md](vps-logs.md).
