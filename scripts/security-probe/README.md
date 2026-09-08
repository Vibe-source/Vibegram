# security-probe

Live probe for the security controls covered in `.vibe/team/live-0829-board.md`, run
against a running vibe-core. Registers its own throwaway users (`sp_<prefix>_<rand>`);
needs no pre-existing data. Prints a PASS/FAIL/SKIP table with observed status codes and
exits 1 if anything FAILs. A control that isn't reachable in this environment is SKIP with
a reason, never a false PASS.

## Run

```
node scripts/security-probe/probe.js [--core http://127.0.0.1:4000] [--hmac-key <key>] \
    [--json out.json] [--max-json-body-bytes 8000000]
```

- `--core` — defaults to `$VIBE_CORE_URL` or `http://127.0.0.1:4000` (frozen contract).
- `--hmac-key` — defaults to `$VIBE_INTERNAL_HMAC_KEY`. Without it, all of check 2 is SKIP
  (the probe cannot sign `vibe-internal-auth/v1` requests). Must be the same value the core
  process has for `VIBE_INTERNAL_HMAC_KEY`, ≥32 bytes.
- `--json out.json` — also writes the full result set as JSON.
- `--max-json-body-bytes` — defaults to `$MAX_JSON_BODY_BYTES` or `8000000`, matching the
  code default in `server/lib/vibe_web/endpoint.ex`. Check 3.1 self-corrects if the running
  server's actual value is higher (see below), so this only sharpens that check's first try.

Only Node built-ins plus the repo-root `ws` package (`fetch`/`FormData`/`Blob` are Node
globals, not a dependency). Verify with `node --check scripts/security-probe/probe.js`.

## What each check maps to

| ID | Check | Source |
|---|---|---|
| 1.1 | Baseline security headers on `GET /api/health` | `server/lib/vibe_web/plugs/security_headers.ex` |
| 1.2 | CSP header absent on `/api/*` (added only outside `/api`) | `security_headers.ex` `maybe_put_csp/1` |
| 1.3 | HSTS — SKIP over plain http (no TLS/x-forwarded-proto) | `security_headers.ex` `maybe_put_hsts/1` |
| 2.1 | Internal HMAC: unsigned request → 401 | `server/lib/vibe_web/plugs/internal_service_auth.ex` |
| 2.2 | Internal HMAC: wrong key → 401 | `contracts/lib/vibe_contracts/service_auth.ex` `check_signature/5` |
| 2.3 | Internal HMAC: valid sig but `x-vibe-service: core` → 401 | `internal_service_auth.ex` `@allowed_services` (only `agent-runtime`) |
| 2.4 | Internal HMAC: fully valid request → 200 | `service_auth.ex` `verify/6` |
| 2.5 | Internal HMAC: replayed nonce → 401 | `service_auth.ex` `check_nonce/2`, ETS replay cache |
| 2.6 | Internal HMAC: timestamp 10 min old → 401 | `service_auth.ex` `check_timestamp/2` (300s tolerance) |
| 3.1 | JSON body over `MAX_JSON_BODY_BYTES` → 413 | `server/lib/vibe_web/endpoint.ex` `Plug.Parsers length:` |
| 4.1 | Multipart body to a JSON-only route → 4xx | `endpoint.ex` `Plug.Parsers pass: ["*/*"]` (multipart only parsed on the upload route) |
| 5.1 | Missing bearer on `GET /api/agents` → 401 | `server/lib/vibe_web/plugs/api_auth.ex` |
| 5.2 | Invalid bearer on `GET /api/agents` → 401 | `api_auth.ex` `Accounts.get_user_by_token/1` |
| 5.3 | Token rejected after `POST /api/auth/logout` → 401 | `server/lib/vibe_web/controllers/auth_controller.ex` `logout/2`, `Accounts.revoke_login_token/1` |
| 5.4 | `POST /api/auth/logout-all` revokes a second (paired-device) session too | `auth_controller.ex` `logout_all/2`, `Accounts.revoke_all_sessions/1` |
| 6.1 | 11th wrong-password login on one username → 429/423 | `server/lib/vibe/accounts/login_throttle.ex` + `server/lib/vibe_web/plugs/rate_limiter.ex` (`:auth` bucket, 10/60s, answers first) |
| 7.1 | Register: password < 8 chars → 400 | `auth_controller.ex` `register/2` |
| 7.2 | Register: username with disallowed chars → 400 | `auth_controller.ex` `register/2` |
| 7.3 | Register: duplicate username → 409 | `auth_controller.ex` `register/2`, `Accounts.username_exists?/1` |
| 7.4 | Register: missing `publicKey`/`encryptedPrivateKey` → 400 | `auth_controller.ex` `register/2` |
| 8.1 | `POST /api/user/profile` with `tier`/`is_agent`/`login_token`/`referral_count` → 200 | `server/lib/vibe_web/controllers/user_controller.ex` `update_profile/2` |
| 8.2 | `is_agent` not applied (`isAgent` still false via `GET /api/user/:id`) | `server/lib/vibe/schemas/user.ex` `profile_changeset/2` (excludes it) |
| 8.3 | `login_token` not applied (original bearer token still works) | same allow-list; login_token overwrite would 401 our own next call if it had landed |
| 9.1 | SVG declared as image → 400 | `server/lib/vibe_web/controllers/media_controller.ex` `classify/2` (magic bytes, not the client's claim) |
| 9.2 | PE/MZ body declared as image → downgraded to `type: "file"` (SKIP on 500 = no object storage configured locally) | `media_controller.ex` `classify/2`, `sniff_head/1` |
| 10.1 | `POST /api/agents/<random>/invoke` without secret → 401/404 | `server/lib/vibe_web/controllers/agents_controller.ex` `invoke/2` |
| 10.2 | `GET /api/agents/<random>/card` → 404, never 500 | `agents_controller.ex` `card/2` |
| 11.1 | Path traversal on `GET /uploads/agent-docs/..%2F..%2Fetc%2Fpasswd` → 400/404 | `server/lib/vibe_web/controllers/group_agent_controller.ex` `download_legacy_document/2` |
| 12.1 | Burst `GET /api/health` past the `:api` bucket limit → ≥1 429 | `server/lib/vibe_web/plugs/rate_limiter.ex`, `server/lib/vibe/rate_limit/ets.ex` |
| 13.1 | Websocket connect with an invalid token → rejected/closed | `server/lib/vibe_web/channels/user_socket.ex` `connect/3` |
| 13.2 | Websocket connect with a cross-origin `Origin` header — SKIP (`check_origin: false` in dev) | `server/config/dev.exs` |

Check `12.1` runs a concurrent burst first (what the brief asks for); if that alone
produces zero 429s, it falls back to a strictly sequential burst before calling the
control missing, so a difference between "no limiting at all" and "the limiter's ETS
lookup-then-insert isn't atomic under concurrent load" is never conflated into the same
FAIL. See the live finding below.

## Live run findings (2026-08-29, against the already-running local core)

Ran twice against the local core that was up during development (not started by this
probe). 27 PASS / 2 FAIL / 3 SKIP:

- **12.1 FAILs for real.** A ~300-request concurrent burst to `GET /api/health` produced
  zero 429s even though it was well past the reported `x-ratelimit-remaining`. A follow-up
  strictly-sequential burst against the same bucket *did* hit 429 after ~26 more requests.
  `Vibe.RateLimit.ETS.hit/3` does `:ets.lookup` then `:ets.insert` as two separate steps
  (`server/lib/vibe/rate_limit/ets.ex`); concurrent callers for the same key can all read
  the same pre-update count and all pass, so a burst can exceed every configured limit.
  Sequential traffic is correctly capped. Worth the lead's attention before the load-test
  and capacity work (board goals 3–4).
- **3.1 self-corrected, not a bug.** The running core's actual `MAX_JSON_BODY_BYTES` is
  higher than the compiled default of 8,000,000 (somewhere in roughly 8,020,053–8,050,052
  bytes) — a body at `default+1` came back 401 (processed normally), not 413. The check now
  tries the assumed cap first and, if that doesn't trip 413, escalates by +10MB before
  calling it a FAIL; the control itself works correctly once the real cap is exceeded.
- **2.4 could not be fully verified.** I don't have this core's actual
  `VIBE_INTERNAL_HMAC_KEY`, so a genuinely-valid signed request wasn't observed to return
  200 — only every negative case (2.1/2.2/2.3/2.5/2.6) was live-confirmed. Re-run with the
  real key to close this out.
