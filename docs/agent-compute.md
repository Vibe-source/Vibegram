# Agent compute — where a role worker runs, and what it needs

`@coder` cannot patch anything today. Gates 1–3 of
[agent-team-ops.md](agent-team-ops.md) pass on the box; gate 4 does not.

Measured on the VPS, 7 Sep 2026:

| where | git | node | claude | codex | writable | mounts |
| ----- | --- | ---- | ------ | ----- | -------- | ------ |
| `deploy_core_1` | no | no | no | no | no (`read_only: true`) | none |
| host (`vibe`)   | yes | no | no | no | yes | `/opt/vibe` |

So a role worker has no CLI to run and no checkout to read. It answers nothing,
and it looks from the app exactly like an agent that is simply quiet.

## Same server does not mean no CI/CD

Two different jobs that only look alike:

- **Answering in chat** needs a CLI next to `core`, in milliseconds. That is a
  sidecar on the box.
- **Changing code** needs a checkout, a toolchain, a test run and a review. That
  is GitHub Actions, and the VPS cannot do it: `core` is `read_only: true`,
  `cap_drop: ALL`, `no-new-privileges` and mounts nothing. Relaxing any of those
  trades the container's security posture for a shell.

The box builds the image but never runs the suite. CI is the only place the tests
run before something serves traffic, so it stays.

## Env, by location

### 1 · VPS — `/run/vibe/env/core.env`

Written with `apply-env.sh` over stdin, then **recreate** `core` (compose only
re-reads `env_file` on create; `podman restart` does not).

| name | value | state |
| ---- | ----- | ----- |
| `VIBE_LOCAL_AGENT_WORKERS` | `1` | set |
| `VIBE_AGENT_WORKER_ALLOWED_USERS` | comma list of user ids; **fails closed** | set (`vibegram`) |
| `VIBE_CLAUDE_COMMAND` | how `core` reaches the CLI in the sidecar | unset |
| `VIBE_CODEX_COMMAND` | same, for codex | unset |

### 2 · VPS — the team sidecar (does not exist yet)

A new service in `deploy/compose.yml` that mounts a writable workspace and the
credential directories, with `core` dispatching into it.

| name | why |
| ---- | --- |
| `ANTHROPIC_API_KEY` *or* `CLAUDE_CODE_OAUTH_TOKEN` | `@boss @monitor @coder @marketing @social @media` |
| `OPENAI_API_KEY` | `@researcher` runs codex |
| `VIBE_AGENT_WORKSPACE` | the checkout the workers read |

`team-setup.sh install` puts node and the CLIs in the host's `~/.local` (no root
— `vibe` has NOPASSWD sudo for `apply-env.sh` only). None of it is there yet.

### 3 · GitHub — repository secrets

Already present for the deploy job: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`,
`VPS_HOST_KEY`. The host key is pinned rather than scanned.

New, for an agent workflow:

| name | why |
| ---- | --- |
| `ANTHROPIC_API_KEY` *or* `CLAUDE_CODE_OAUTH_TOKEN` | the CLI in the runner |
| `OPENAI_API_KEY` | codex in the runner |

The built-in `GITHUB_TOKEN` is enough to open the PR, with
`permissions: {contents: write, pull-requests: write}` on the job. Do not add a
personal token for this.

## The split worth building

`@coder` answers in chat from the sidecar. Anything that edits a file is
dispatched to a workflow that checks out, runs the CLI, runs the tests and opens
a PR — never a push to `main`. Merging deploys, per
[deploy-pipeline.md](deploy-pipeline.md).

That keeps the read-only container read-only, puts the codebase in the one place
that already has the whole toolchain, and leaves every change reviewable.
