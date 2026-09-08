# Team architecture

Single authoritative spec for how `@team` runs. Stable home (no version suffix).

## The one idea

**The team lead is a full agent CLI.** The bridge spawns one lead process (Claude Code)
per team run, preloaded with [`agent-bridge/instructions/team-lead.md`](../agent-bridge/instructions/team-lead.md)
and a permission profile. That lead diagnoses, plans, spawns worker CLIs
(codex / grok / agy) as **background subprocesses on the Mac**, reviews diffs,
integrates, and verifies.

Orchestration is a **guide**, not a second harness in bridge or server code.

## Why agent-native

Earlier team work re-implemented the agent harness in bridge/server: classification,
worker lifecycle, monitors, admission queues. That custom layer was the source of the
team feature's reliability bugs — silent solo runs, lost `run_task` broadcasts,
ETS state wiped on redeploy, monitors that could not see what the lead already knew.

**Orchestration-as-guide** upgrades by editing a document. The lead inherits every
native CLI capability for free:

- background tasks with auto-wake
- task tracking and subagent surfacing
- streaming payloads on the already-hardened single-agent pipeline

One lead = **one stream**. The iOS team cell binds to that stream's task and subagent
nodes. Workers are children of the lead, not separate phone-visible runs.

## What the cloud and bridge still own

Unchanged responsibilities — do not re-implement these in the lead prompt:

| Concern | Owner |
|---|---|
| Phone ↔ cloud ↔ Mac transport | bridge + channels |
| Chat identity and message routing | server |
| Runtime E2E encryption | clients + crypto layer |
| Push notifications | server |
| Thin admission gate (one team run per repo at a time) | bridge / server |
| Destructive-command blocklist | bridge hooks + permission layer |

**Prompts are not controls.** Safety is enforced at the bridge/hook layer. The lead
guide and worker briefs state norms; the permission system blocks `rm -rf`, force-push,
deploy, and similar regardless of what a model asks for.

## Cost model

| Spend | Buys |
|---|---|
| **Lead tokens** | Diagnose + Distill — the part that must be smart |
| **Worker tokens** | Patches — the commodity |

**The patch is a commodity. The task is the product.** One correct mental model,
distributed as precise briefs, beats N workers each re-reading the codebase and
diverging.

**Simple requests skip the lead.** The bridge dispatches a single worker CLI directly
when the work does not need multi-agent coordination. `@team` is for work that benefits
from disjoint parallel slices under one architect.

## The loop (what the lead does)

Field-proven on real runs (see `.vibe/team/appearance-0716-board.md`,
`.vibe/team/settings-0716-1424-board.md`):

1. **Diagnose** — read the real code; find the real problem (root cause, not the
   symptom in the user message).
2. **Distill** — write per-worker briefs that **carry the understanding**. Each brief
   is self-contained: objective, root cause, mechanism, exact files, do-not-touch,
   frozen names, acceptance.
3. **Board** — create `.vibe/team/<run>-board.md` **before** dispatch: frozen contracts
   (exact type/field/route names), ownership table (one owner per file), hard rules.
4. **Dispatch** — launch worker CLIs as background subprocesses with disjoint file
   ownership and auto-edit permissions.
5. **Diff-review against baseline** — never trust a worker's handoff text. Compare the
   actual diff to the brief and the pre-dispatch snapshot.
6. **Integrate** — wire shared surfaces the workers were forbidden to touch
   (router, App entry, host views).
7. **Verify once** — one build/compile/test pass at the end. Workers do not build or
   launch.

## Board protocol

The board is the durable coordination artifact. State lives on disk under the lead's
process, not in ephemeral ETS.

```
.vibe/team/<run-id>-board.md
```

Required sections before dispatch:

- **Frozen contract** — exact names everyone codes against (types, fields, routes,
  JSON keys). This is the payload barrier; consumers code to the names, not to
  another worker's unfinished code.
- **Ownership table** — one owner per file; integrator owns wiring.
- **Hard rules** — edit only owned files; no commit/push/build/launch; additive only;
  code against frozen names.
- **Dispatch status** — brief path + status per worker.

Workers append **handoffs** under their section when done. The lead updates the board
after review with what shipped vs. deferred.

## Worker routing

| Worker | Use for | Never for |
|---|---|---|
| **agy** | UI / low-risk / mechanical only | auth, security, payments, migrations, shared server logic |
| **grok** | production UI slices + docs | (verify like any worker) |
| **codex** | production server, security-sensitive, multi-file Elixir | — |

**agy over-reports success.** Always diff-verify and build-verify its slice. Match
model to blast radius first, then to cost. Escalate the hardest reasoning to the
strongest available model (lead role, not a weak worker).

Every worker brief forbids calling the Fable advisor — the lead/reviewer **is** the
advisor.

## Worker CLI forms

Exact current forms (lead fills `<repo>`, effort, brief path):

```bash
# codex
codex exec --json \
  -c sandbox_mode="workspace-write" \
  -c approval_policy="never" \
  -c model_reasoning_effort="<e>" \
  --cd <repo> \
  --skip-git-repo-check \
  "<prompt>"

# grok
~/.grok/bin/grok \
  --prompt-file <brief> \
  --always-approve \
  --max-turns 80 \
  --output-format plain \
  --cwd <repo>

# agy — UI/low-risk briefs only
~/.local/bin/agy \
  -p "Read and execute the brief at <brief path>. Work from <repo>." \
  --mode accept-edits \
  --dangerously-skip-permissions \
  --print-timeout 30m
```

## Reliability properties

- **Local dispatch cannot silently go solo.** A failed worker launch is a failed shell
  command the lead sees immediately.
- **Diagnosis survives as files.** Briefs and the board outlive a redeploy; the lead
  resumes as reviewer, not as a second expensive re-plan.
- **Retry cap = 1**, then escalate to the lead **with the failed diff** — never a
  blind re-run.
- **Out-of-spec guard.** Diff review catches file-scope drift before integrate.

## Migration

| Path | Status |
|---|---|
| **Agent-native** (lead CLI + guide + local worker subprocesses) | **target** |
| Legacy `classify` / multi-spawn / `TeamRunMonitor` / `team_spawn` fan-out | **deprecated** — kept behind config until the agent-native path is proven, then deleted |

Do not extend the legacy path. New team behavior lands in the lead operating guide
and the thin admission/transport layer only.

## Phone surface

One team cell, one stream, tap-through for worker detail. Under-hood workers do not
create separate list bubbles. Progress (diagnose phase included) renders on the lead
cell so the run does not look stalled while the architect reads.

Wire shapes for agent streams and team frames: [`docs/agent-payload-shapes.md`](agent-payload-shapes.md).
Lead operating instructions: [`agent-bridge/instructions/team-lead.md`](../agent-bridge/instructions/team-lead.md).
