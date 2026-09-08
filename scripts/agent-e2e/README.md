# agent-e2e

Drives the isolated agent like a person on the phone: register, create + publish an
isolated agent with a computer, open its owner DM, send a role + task, then watch it
stream, use tools, ask for approval, ask questions, and deliver — auto-approving and
auto-answering along the way. Node built-ins + `ws` only, same wire mechanics as
`agent-bridge/bin/team-e2e.js`. Defaults to `$VIBE_CORE_URL` or `http://127.0.0.1:4000`.

## (a) Default marketer task

```
node scripts/agent-e2e/agent-e2e.js
```

## (b) Approval scenario (external-effect approval, auto-approved)

```
node scripts/agent-e2e/agent-e2e.js --task "Research Signal vs Telegram security \
messaging in 3 bullet points, then POST the summary as JSON to https://httpbin.org/post \
and tell me what it echoed back."
```

## (c) Question scenario (agent asks first, auto-answered via --answer)

```
node scripts/agent-e2e/agent-e2e.js \
  --task "Ask me which product to focus on before you start, then write one paragraph." \
  --answer "Focus on the messenger's E2E encryption story."
```

Pass `--approve reject` to exercise the reject path; `--token`/`--agent-id` reuse an existing account/agent.

## Evidence

Lands under `--out` (default `scripts/agent-e2e/out/<timestamp>/`):

- `preview-N.<ext>` / `computer-N.<ext>` — sandbox screenshots (pushed live / polled)
- `deliveries.md` — every text/image/file/music message the agent sent back
- `summary.json` — also printed to stdout; exit 0 only if a delivery arrived and the
  run finished done/completed
