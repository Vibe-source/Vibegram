# Agent team — server operations

Running the built-in team (`@boss @monitor @coder @researcher @marketing @social
@media`, plus `@claude @codex @grok @agy`) on the VPS. The roster itself and its
per-role models are in [agent-team.md](agent-team.md); this page is the box.

One script drives all of it from the Mac:

```bash
deploy/scripts/team-setup.sh            # report every gap, change nothing
deploy/scripts/team-setup.sh verify     # agent users, tiers, badges in the live DB
deploy/scripts/team-setup.sh env        # set the team env, recreate core
deploy/scripts/team-setup.sh install    # node + claude/codex into ~/.local on the box
deploy/scripts/team-setup.sh login      # run the CLI browser logins ON the box
```

`VPS_HOST` comes from the agix broker, never argv. The script never deploys — it
prints what to do and stops.

## Four gates, in order

A worker only answers when all four hold. Each one fails silently and looks
identical from the client: the agent simply does not appear, or does not reply.

**1 · The code is deployed.** `@boss` and the six role workers do not exist in
older images. The users are seeded by `ensure_agent_users/0` at boot, so they
appear with the deploy and not before — no DB write brings them early. Check with
`team-setup.sh` (it prints deployed sha against local HEAD) and deploy by merging
to `main`, per [deploy-pipeline.md](deploy-pipeline.md).

**2 · The team is switched on.** `VIBE_LOCAL_AGENT_WORKERS=1` gates `enabled?`.
Unset means the whole roster is inert.

**3 · The caller is allowed.** `VIBE_AGENT_WORKER_ALLOWED_USERS` is a comma list
of user ids, and `dispatch_allowed?` **fails closed** — unset allows nobody, not
everybody. `team-setup.sh env` resolves it from the non-agent accounts on the box
and writes both vars through `apply-env.sh` over stdin, then recreates `core`
(compose only re-reads `env_file` on create, so the recreate *is* the apply).

**4 · There is something to execute.** Role workers run `runtime: :server` and
borrow the `claude` / `codex` CLI through `executor_for/1`. No CLI on the box means
no reply.

## Why gate 4 needs a sidecar

`core` in `deploy/compose.yml` is `read_only: true`, `cap_drop: ALL`,
`no-new-privileges`, and mounts nothing. It structurally cannot spawn a CLI or
write a workspace, and relaxing any of those to fix it would be trading the
container's whole security posture for a shell.

Env, by location, and why CI stays: [agent-compute.md](agent-compute.md).

So server-side execution belongs in a **separate team container** that mounts a
workspace and the credential directories, with `core` dispatching to it. Until
that exists, `team-setup.sh install` puts node and the CLIs in the host's
`~/.local` (no root — `vibe` has NOPASSWD sudo for `apply-env.sh` only), which is
the right home for them either way, and the gap is the wiring from `core` to that
host.

The bridge path is unaffected: a paired Mac running the agent bridge already
executes locally, and gates 1–3 are all it needs.

## Signing the CLIs in

**On the box, not on the Mac.** `claude` keeps its credentials in the macOS
Keychain, so there is no file to copy across — `team-credentials.sh` can stage
`~/.codex` but never `~/.claude`. The box has outbound network (nodejs.org,
npmjs.com and api.anthropic.com all reachable), so it can run the OAuth flow
itself.

`team-setup.sh login` SSHes with `-tt` so the flow is interactive on the box:
each CLI prints a URL, you open it in your own browser, and the credentials land
in the box's `~/.claude` and `~/.codex`. It skips a CLI that is already signed in.

## Provider fallback

Vibe carries its own fallback and does not need AGIX installed on the box for it:

- `run_cli("claude", …)` retries once on `claude_fallback_model` when the output
  reads as a missing model *or* a plan usage limit — the boss's `fable → opus`.
- `monitor_reassign_worker` moves a task to another worker when one is limited.
- `Vibe.AI.AgentRuntime` and `VibeAgents.LLM.Loop` fall back Claude → OpenAI.

The memory layer is separate: AGIX memory is a Mac-side developer tool and is not
what a server worker reads.

## The gold badge

Two independent surfaces, and only `users.tier` drives either of them — the
`badges` table is not read by the client at all.

- **Home and search rows** — server `friendTier` → `peerTier` → `isGoldTier`.
  This is a *peer's* tier, so your own badge never shows here.
- **Profile page, including My Profile** — `GET /api/user/:id` sends `tier`, and
  `showsGoldTier` draws on `tier == "gold"` or a connected bridge.

An agent user with `tier: "gold"` therefore shows the badge everywhere as soon as
gate 1 passes. To check the data: `team-setup.sh verify`.

## Reading the database

`deploy/scripts/psql-ro.sh` opens a SELECT-only shell (the role holds no INSERT,
UPDATE, DELETE or DDL). It reads the password from `/run/vibe/env/postgres.env`,
which is where sealed env lives once the box is bootstrapped.
