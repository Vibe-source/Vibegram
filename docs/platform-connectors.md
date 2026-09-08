# Platform connectors (multi-integration OAuth)

**Status:** shipped foundation (2026-07-23)  
**Architecture advisor:** Fable (hybrid: user-scoped vault + per-agent grants)

## Problem

Users need agents (Vibe standalone agents, Claude, Codex, Grok) to work against
external systems — especially **GitHub PRs** — without pasting tokens into chat.
The product needs a **multi-platform scheme**, not a GitHub-only one-off, so
Excel/Slack/Linear/Calendar can land under the same tables and tools.

## What this is not

| Existing system | Role |
|---|---|
| `agent_integrations` | **Inbound** webhooks / connected-app HTTP actions per agent (`call_connected_app`) |
| Platform connectors | **User OAuth vault** + grants + server-proxied platform tools (`call_platform`) |

Do not store OAuth refresh tokens on `agent_integrations`. That model is
event-source scoped to one agent; OAuth identity is user-scoped and shared.

## Architecture (production)

```
iOS Settings → Connected Apps
      │ ASWebAuthenticationSession
      ▼
POST /api/platforms/connections/:provider/authorize
      │ signed state (user_id + provider)
      ▼
Provider OAuth (GitHub …)
      │
GET  /api/platforms/oauth/:provider/callback
      │ exchange code → encrypt tokens → upsert platform_connections
      │ default grants for bridge_agent: claude/codex/grok/agy/vibe
      ▼
vibe://platforms/oauth?status=success&…

Agent run
  list_platform_connections / call_platform
       │
       ▼
  grant resolve → decrypt token → GitHub API → audit
  (tokens never in API list payloads or prompts)
```

### Tables

- `platform_connections` — user_id, provider, external account, AES-GCM encrypted
  access/refresh tokens, scopes, status, public metadata
- `connection_grants` — connection_id + grantee (`agent` \| `bridge_agent` \| `chat`)
  + capability allowlist (empty = all provider capabilities)
- `connection_audit_events` — connect / revoke / tool_call / deny (no secrets)

### Tools

| Tool | Purpose |
|---|---|
| `list_platform_connections` | Capability names + account login for this grantee |
| `call_platform` | `{ provider, action, params, connection_id? }` server-proxied action |

GitHub actions (v1): `list_repos`, `list_pull_requests`, `get_pull_request`,
`list_pr_files`, `list_pr_comments`, `create_pr_comment`, `list_issues`,
`create_issue`, `get_repo`.

### Catalog (multi-platform)

| Provider | Status |
|---|---|
| `github` | Live OAuth + actions |
| `microsoft_excel` | Catalog stub (Graph workbooks) |
| `slack` | Catalog stub |
| `linear` | Catalog stub |
| `google_calendar` | Catalog stub |

## API

Authenticated (Bearer):

- `GET  /api/platforms/catalog`
- `GET  /api/platforms/connections`
- `GET  /api/platforms/connections/:id`
- `POST /api/platforms/connections/:provider/authorize` → `{ authorizeUrl, state }`
- `DELETE /api/platforms/connections/:id`
- `POST /api/platforms/connections/:id/grants`
- `DELETE /api/platforms/connections/:id/grants/:grant_id`
- `GET  /api/platforms/usable?granteeType=bridge_agent&granteeId=claude`
- `POST /api/platforms/tools/invoke` body `{ provider, action, params, granteeType, granteeId }`

Public (browser redirect):

- `GET /api/platforms/oauth/:provider/callback?code&state`

## Env (server)

```bash
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
# Optional overrides:
VIBE_GITHUB_REDIRECT_URI=https://api.vibegram.io/api/platforms/oauth/github/callback
VIBE_PUBLIC_BASE_URL=https://api.vibegram.io
VIBE_PLATFORM_TOKEN_ENCRYPTION_KEY=   # falls back to agent secret key / SECRET_KEY_BASE
```

GitHub OAuth App callback URL must match the redirect URI exactly.

## Clients

- **iOS:** Settings → Connected Apps (`PlatformConnectorsView` + ASWebAuthenticationSession)
- **Web:** OAuth landing falls back to `/settings/connectors?...` (wire a page later if needed)
- **Bridge agents:** prompt injection via `LocalAgentWorker.platform_connectors_guidance/2`;
  local `gh` still works with machine credentials; server proxy is `POST …/tools/invoke`

## Security invariants

1. List/show payloads never include token ciphertext or plaintext.
2. Agents see capability ids, not credentials.
3. Cross-tenant: grants resolve only for the connection owner (`user_id`).
4. Revoke nulls tokens and deletes grants.
5. Capability allowlists can only **narrow** the provider catalog.

## 2026 product rationale

| Integration | User problem |
|---|---|
| GitHub | PR review/comment/ship loop for coding agents |
| Excel / Graph | Spreadsheet as durable agent memory for ops/finance |
| Slack / Linear | Decisions and tickets live outside the chat |
| Calendar | Proactive triggers and meeting prep |

MCP/OAuth connectors are the ChatGPT/Claude market pattern; Vibe keeps the
**messenger host** as the consent + vault + audit surface, not a second model vendor.
