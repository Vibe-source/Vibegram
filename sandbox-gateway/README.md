# sandbox-gateway

The only process allowed to touch the container runtime: creates/execs/reads/writes/screenshots
the per-agent sandbox ("the bot's computer") over a Docker-compatible socket, enforces the
hardening policy, reaps idle containers. No model keys, no chat data. Spec: `docs/agent-platform-v1.md` §2, §3.6.

## Run

```
SANDBOX_GATEWAY_TOKEN=$(openssl rand -hex 32) cargo run --release
```

Every route but `GET /healthz` requires header `x-sandbox-token: <SANDBOX_GATEWAY_TOKEN>`.

## Config (env)

`PORT` (8090) · `SANDBOX_GATEWAY_TOKEN` (required, ≥32 chars) · `CONTAINER_SOCKET`
(`unix:///run/podman/podman.sock`) · `SANDBOX_IMAGE` (`vibe-sandbox:latest`) ·
`SANDBOX_IMAGE_ALLOWLIST` (comma list, default `SANDBOX_IMAGE`) · `SANDBOX_NETWORK`
(`sandbox-net`) · `SANDBOX_EGRESS_PROXY` · `SANDBOX_MAX_CONTAINERS` (32) ·
`SANDBOX_DEFAULT_MEMORY_MB` (1024) · `SANDBOX_DEFAULT_CPUS` (1.0) · `SANDBOX_PIDS_LIMIT` (256) ·
`SANDBOX_IDLE_TTL_SECONDS` (1800) · `SANDBOX_VOLUME_PREFIX` (`vibe-sandbox-`) ·
`SANDBOX_EXEC_MAX_TIMEOUT_MS` (240000) · `SANDBOX_MAX_OUTPUT_BYTES` (1000000) ·
`SANDBOX_MAX_FILE_BYTES` (4000000) · `LOG_FORMAT` (`text`\|`json`)

## Routes

`POST|GET /v1/sandboxes` · `GET|DELETE /v1/sandboxes/:id` · `POST /v1/sandboxes/:id/exec` ·
`GET /v1/sandboxes/:id/exec/log` ·
`PUT|GET /v1/sandboxes/:id/files` · `GET /v1/sandboxes/:id/tree` ·
`POST /v1/sandboxes/:id/browser/{navigate,action}` · `GET /v1/sandboxes/:id/browser/screenshot` ·
`POST /v1/sandboxes/:id/stop` · `GET /healthz`.

## Test

```
cargo build --release && cargo test && cargo clippy --all-targets -- -D warnings
```

Unit tests cover the policy module (allowlist, naming, path/env, host-config) and request/
response serde. No live container test runs by default; guard one behind `SANDBOX_LIVE_TEST=1`.
