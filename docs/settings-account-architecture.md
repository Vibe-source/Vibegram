# Settings, accounts, and linked-device architecture

This document is the shared contract for the iOS, server, and web implementation.

## Trust model

The server never receives an unwrapped identity/private key. A new device creates a local
asymmetric wrapping key pair and submits only its public key with a short-lived pairing
request. An already-authorized device encrypts the account key bundle to that public key
and approves the request. The server holds the opaque envelope until one atomic claim,
then marks the request consumed. Expired, rejected, revoked, or already-consumed requests
cannot be claimed.

Device session bearer tokens are random high-entropy values returned only once and stored
as SHA-256 hashes. Revoking an account device revokes all sessions belonging to it. The
legacy user login token remains accepted until existing clients migrate.

## Account isolation

Every local account has an immutable local account identifier derived from server origin
and user ID. Keychain items, config, chat journal, outbound queue, decrypted-media cache,
theme, and notification preferences use that namespace. A switch follows this order:

1. Stop socket/Packet transports and cancel account-owned tasks.
2. Flush the old account's outbound and cache state.
3. Set the active account identifier and load only that namespace.
4. Recreate runtime services and fetch a fresh chat snapshot.
5. Publish one active-account change notification so root UI redraws in place.

## HTTP API

All routes are authenticated except pairing claim, which is authorized by the unguessable
pairing code plus requester proof defined by the server implementation.

- `GET /api/account/devices` returns `{devices: [{id, deviceIdentifier, name, platform,
  current, lastSeenAt, createdAt}]}`.
- `DELETE /api/account/devices/:id` returns `204` and revokes its sessions.
- `POST /api/account/devices/pairing` accepts `{deviceIdentifier, name, platform,
  requesterPublicKey}` and returns `{code, expiresAt}`.
- `POST /api/account/devices/pairing/:code/approve` accepts `{wrappedKeyEnvelope}`.
- `POST /api/account/devices/pairing/:code/claim` consumes the request and returns
  `{account, device, sessionToken, wrappedKeyEnvelope}`.
- `GET /api/account/notification-preferences` returns the canonical preference object.
- `PUT /api/account/notification-preferences` validates and replaces provided fields.

Notification category values use `{enabled: boolean, sound: string | null, preview:
boolean}`. Top-level keys are `privateChats`, `groupChats`, `channels`, `stories`,
`reactions`, `allAccounts`, `inAppSounds`, `inAppVibrate`, `inAppPreview`, and
`namesOnLockScreen`.

## Appearance model

Both clients persist `mode`, `themeId`, wallpaper kind/value, accent color, two-stop
bubble gradient, text scale, message corner scale, and animations enabled. Views consume
semantic tokens rather than hard-coded theme colors. Custom wallpaper images remain
local; portable themes store colors/gradient and a stable built-in wallpaper identifier.
