# Channel and channel-agent architecture

## Product invariants

1. A room creation response is a complete room summary. Native clients never invent
   the room type, owner role, participants, counts, timestamps, or policy after create.
2. Closing the creation modal and opening the room are separate navigation commits.
   The modal dismisses first; the root navigation controller pushes the canonical route
   from the dismiss completion. Home receives the same summary optimistically.
3. A channel agent is an existing user-owned standalone Agent, not a second copy of an
   agent prompt/tool configuration. Its shadow user is the message author.
4. Publishing into a channel does not grant human moderation authority. The participant
   role `agent_admin` is a limited publisher identity; only human `owner`/`admin` roles
   can edit the channel, manage members, links, approvals, or assignments.
5. Room policy can narrow an agent's tools/output modes but can never broaden them.
6. A private invite URL is a revocable capability. Only its digest is persisted.

## Canonical room summary

Create, list, link-join, and settings responses share these additive keys:

```json
{
  "chatId": "room-id",
  "type": "channel",
  "isGroup": true,
  "isChannel": true,
  "name": "Daily Brief",
  "description": "News selected by the channel team",
  "avatarUrl": null,
  "creatorId": "user-id",
  "role": "owner",
  "members": [],
  "memberCount": 2,
  "subscriberCount": 2,
  "createdAt": 1784740000000,
  "lastMessageAt": 1784740000000,
  "accessType": "private",
  "publicSlug": null,
  "shareLink": null,
  "joinApprovalRequired": true,
  "restrictSavingContent": true
}
```

`shareLink` is omitted from ordinary private-room summaries. It is returned when a
private invite is created or rotated, because the server cannot reconstruct a raw token
from its digest. Public links can be derived from the public slug.

An empty group/channel still has activity: its list subtitle is localized by the client
as `Group created` or `Channel created`, and its date is derived from `lastMessageAt`
(which equals `createdAt` until the first visible message).

## Links and joins

Public channels have a normalized, unique `publicSlug` and a stable `/r/:slug` URL.
Private channels create `/j/:token` invites. Invite rows contain:

- SHA-256 token digest and a non-secret display hint;
- creator, created time, optional expiry and maximum uses;
- atomic use count and revocation time.

Resolution does not imply membership. Join performs one of two server-authorized paths:

- immediate: atomically claims the invite (when applicable), creates/reactivates a
  subscriber participant, invalidates Home caches, and returns the canonical summary;
- approval: creates one pending join request and returns pending status without adding a
  participant. A human channel owner/admin later approves or rejects it.

The web landing endpoints redirect to `vibe://room-link?...`. iOS queues the link if it
arrives before login/the tab shell, then calls the authenticated join endpoint and opens
the returned room. A future Associated Domains deployment can make the same HTTPS URLs
universal links without changing the API or stored link identity.

## Agent identity and room assignment

The global `agents` row remains the source of truth for:

- identity, prompt/persona and shadow user;
- owner and lifecycle status;
- tool grants and connected-app integrations;
- output modes (text/media/voice), voice profile and budgets;
- autonomy/approval policy, event subscriptions and runbooks.

Attaching an agent to a channel creates, in one transaction:

1. an active `chat_participants` row for the shadow user with `agent_admin` role;
2. one `channel_agent_assignments` row for the channel and standalone agent.

The assignment contains room-local restrictions and delivery behavior only:

```json
{
  "status": "enabled",
  "allowedTools": ["search_google"],
  "allowedOutputModes": ["text", "media"],
  "triggerConfig": {
    "version": 1,
    "rules": [
      {"kind": "integration_event", "eventTypes": ["news.published"]},
      {"kind": "interval", "seconds": 14400, "prompt": "Prepare the next brief"}
    ]
  },
  "permissions": {
    "publish": true,
    "pinOwnPosts": false
  }
}
```

Effective tools and outputs are intersections:

```text
effective tools   = agent.enabledTools ∩ assignment.allowedTools
effective outputs = agent.outputModes  ∩ assignment.allowedOutputModes
```

An omitted allowlist means "no additional room narrowing"; an explicit empty list means
"none". The API must preserve that distinction if the product exposes both states.
Either the channel owner/admin or the agent owner can detach. Disabling/deleting the
agent disables its assignments and removes/ignores its publisher membership.

Legacy `group_agents` remains readable for old rooms but is never dual-written. This
avoids two prompts, two tool catalogs, or conflicting memories for one identity.

## Trigger model

Triggers are adapters into one invocation pipeline, not bespoke channel bots:

```text
manual admin request ─┐
integration event ────┼─> policy resolver -> standalone agent invocation -> output gate
interval/calendar ────┘                                            |
                                                                  channel
```

- Integration events use the existing per-agent integrations, inbox, runbooks and
  approval engine. They are the preferred source for "whenever new news arrives".
- Interval/calendar rules require a supervised scheduler that atomically leases due
  rules, records an idempotency key, advances `next_run_at`, and invokes the same agent
  pipeline. Scheduling should not be implemented as one in-memory timer per channel.
- Every run stores trigger identity, requester/owner context, destination, tool calls,
  outputs, cost and terminal status for audit and retry.
- Delivery re-checks the live assignment immediately before inserting a message, so a
  detach/disable that races a long agent run prevents the final publish.

## Safe custom tools

Custom tools are connected-app actions owned by the same user as the standalone agent.
They are not arbitrary database functions and never receive a repository connection.

- Integration secrets are encrypted at rest and never returned after creation except
  through explicit secret-management endpoints.
- Each action has an allowlisted name, parameter schema, static parameter restrictions,
  outbound URL policy, timeout and risk/approval level.
- Invocation resolves the agent by `(agent_id, owner_user_id)` and sends a scoped context
  containing agent, integration, requester and destination IDs.
- The room assignment can only remove custom tools/actions from the agent's global set.
- Remote responses are size/type limited and normalized into Vibe content parts before
  they can become a channel post.
- Database-backed first-party actions use service functions with normal authorization
  and row-level security; a model never receives SQL or ambient database credentials.

This shape supports news, music, analytics, commerce, moderation and future verticals
without adding channel-specific tool code or weakening tenant isolation.

## Content protection

`restrictSavingContent` is authoritative server metadata. Clients hide forward/copy/
save/export actions for protected channel messages, but client UI is not the security
boundary. Server endpoints that forward, export, save, or mint unrestricted media URLs
must also reject protected-source content. Screenshots and external cameras cannot be
fully prevented; the UI should describe the setting as content protection, not DRM.

## Delivery phases

1. Creation/list/profile/link contract, joins/approval, scoped agent assignment and
   immediate native navigation.
2. Client copy/forward suppression, server enforcement for source-marked save/forward
   operations, and a durable multi-node-safe interval scheduler.
3. Calendar triggers, richer channel audit/run history, and server-owned media export
   endpoints that can enforce protection without trusting client source metadata.
4. Associated Domains/web preview pages and richer public-channel discovery.
