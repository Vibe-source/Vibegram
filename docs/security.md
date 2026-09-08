# Security & Privacy

> **Authoritative Architecture & Design Document:** For the core cryptographic architecture, audit findings, protocol selection (MLS), crate layout, and phased migration roadmap, see [docs/secure-core-architecture.md](secure-core-architecture.md).
>
> **Current-Status & Qualification Tracking:** Production migration gates are tracked in `docs/production-timeline-core-refactor.md`. Detailed line-by-line audit findings are documented in `docs/encryption-media-status-2026-08.md`.
>
> **Server & agent hardening (2026-08-28):** the production-readiness gap analysis against the ABR
> checklist is [docs/security-readiness-gap-2026-08.md](security-readiness-gap-2026-08.md); the agent
> isolation, capability broker and sandbox model are specified in
> [docs/agent-platform-v1.md](agent-platform-v1.md). The token/session, headers, body-limit and audit
> statements below are superseded by those two documents where they differ.

---

## 1. Verified Current Implementation & Status

The following statements reflect the verified state of Vibe's shipping cryptography and security implementation (verified August 2026). They take precedence over historical target material:

- **1:1 DM Message Bodies**: A 1:1 message send with a resolved peer public key uses a fresh 256-bit AES key and 96-bit nonce with AES-256-GCM. The AES key is wrapped for the recipient (and sender, when available) using static **RSA-2048-OAEP-SHA-256**.
- **No Forward Secrecy or Post-Compromise Security**: Because message keys are delivered wrapped under a static RSA-2048 key, compromising the long-term private RSA key exposes past message history. Key derivation is not ratcheted in the legacy protocol.
- **Groups and Channels**: **Not currently end-to-end encrypted.** When sending in groups or channels (`isGroup` is true), message JSON is written directly in plaintext to `encrypted_content`.
- **Fallback / Unresolved Keys**: A 1:1 or agent path lacking a resolved peer public key falls back to sending plaintext JSON. "The server never sees plaintext" is not a product-wide claim today.
- **Known Plaintext Leaks (Fixes In Progress — Phase 0 / Run `securecore-0806`)**:
  - `pushPreview`: Historical implementation sent up to 160 characters of message text in cleartext outside the envelope. In run `securecore-0806` (Phase 0), `pushPreview` is removed on 1:1 E2E DM paths and replaced with content-free notifications (`pushKind`).
  - `mediaKey`: Media files are AES-256-GCM encrypted, but the `mediaKey` was historically transmitted in cleartext on the wire payload and inside metadata (`ios/ChatModule/ChatEngine.swift`), stored at a public Supabase URL (`server/lib/vibe/supabase_storage.ex`). Run `securecore-0806` (Phase 0) removes `mediaKey` from the outer wire payload and metadata, keeping it strictly inside the sealed envelope.
  - Auth Secret Split: Account passwords historically derived key-wrapping passphrases in a manner where the server held both credentials at login. Run `securecore-0806` (Phase 0) splits the authentication secret (`authSecret = HKDF(recovery, "vibe/auth/v1")`) from key wrapping (`kek = PBKDF2(recovery, "vibe/kek/v1")`).
  - Message Length Padding: Historical messages leaked exact length; Phase 0 introduces `vibe_pad` length bucket padding (256, 1024, 4096, 16384, 65536 bytes).
- **Local History Encryption**: The iOS SQLite history cache (`payload` BLOB) is sealed at rest using AES-256-GCM and row-bound AAD (`core/vibe_core/src/store_seal.rs`), keyed from Keychain (`VibeCoreStoreKey.swift`). If Keychain access fails, it logs and fails open to plaintext.
- **Media Format**: Existing encrypted media uses whole-file AES-256-GCM. Authentication is completed only when the final tag is verified (not authenticated streaming).

Until migration qualification gates pass and independent third-party audits complete:
- Describe E2E support per chat class, not as an app-wide guarantee.
- Do not claim zero knowledge, sealed local history, completed cryptographic audit, screenshot prevention, or regulatory compliance.
- Treat security telemetry as metadata-only (never log keys, plaintext, media keys, or notification bodies).

---

## 2. Target Architecture: Messaging Layer Security (MLS)

As detailed in [docs/secure-core-architecture.md](secure-core-architecture.md), Vibe is migrating its end-to-end encryption core from static RSA-2048-OAEP to **Messaging Layer Security (MLS, RFC 9420)** via OpenMLS (`openmls` 0.8) in a new sibling crate, `core/vibe_secure`.

### Key Architectural Decisions
- **Unified Protocol (DM as a 2-Member Group)**: 1:1 direct messages and group chats share a single protocol state machine. A 1:1 DM is treated as a two-member MLS group.
- **Ratchets**:
  - **Symmetric Ratchet (Forward Secrecy)**: Message keys are derived via one-way KDF per step and immediately deleted.
  - **DH Ratchet (Post-Compromise Security)**: Directional turns mix fresh ephemeral X25519 DH keys into the root key schedule, healing sessions automatically after compromise.
- **Envelope Format**: MLS messages use format `MlsV2`, identified by the `"vmls1."` prefix (`VIBE_MLS_SEALED_PREFIX`). Legacy `v1` message history remains readable.
- **Ciphersuite**: `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (pinned OpenMLS 0.8 dependencies).
- **Crate Separation**: `vibe_secure` is kept strictly decoupled from `vibe_core` to preserve deterministic testing of timeline logic.

### Phased Roadmap Summary

- **Phase 0 — Stop the Bleeding (In Progress / Run `securecore-0806`)**:
  - Remove `pushPreview` on 1:1 DMs (content-free push notifications).
  - Auth secret split (`authSecret` vs `kek`).
  - Strip cleartext `mediaKey` from wire.
  - Add message length padding (`vibe_pad`).
- **Phase 1 — Identity (Planned)**:
  - Per-device Ed25519 identity key in Keychain, TOFU key pinning, UI safety numbers, signed envelopes.
- **Phase 2 — MLS in Core (Planned)**:
  - OpenMLS 0.8 integration in `core/vibe_secure`, group state in sealed SQLite store (`vibe_core_store`), `vmls1.` (`MlsV2`) envelopes for 1:1 DMs.
- **Phase 3 — Groups Migration (Planned)**:
  - Migrate group chats and channels to MLS sessions; retire plaintext group path.
- **Phase 4 — Metadata & Media Hardening (Planned)**:
  - Sealed sender (M3), encrypted group roster (M4), `vmed2` segmented AEAD streaming media, server blob expiry.
- **Phase 5 — Post-Quantum Cryptography (Planned)**:
  - X25519 + ML-KEM-768 hybrid ciphersuite via `libcrux-ml-kem` / `ml-kem`.

---

## 3. Legacy Target Design (Historical Context)

> **Note:** The TweetNaCl / XSalsa20-Poly1305 description below is historical target documentation. It does not reflect either the shipping static RSA-OAEP + AES-GCM implementation or the target MLS (RFC 9420) architecture described in [docs/secure-core-architecture.md](secure-core-architecture.md).

### Message Encryption (Historical TweetNaCl Design)
- **Algorithm**: TweetNaCl Box (XSalsa20, Poly1305, Curve25519)
- **Status**: Historical specification; replaced by static RSA-2048-OAEP + AES-256-GCM today, migrating to MLS (RFC 9420) in Phase 2.

### Key Management
- **Derivation**: Account password → Argon2 / PBKDF2 (Phase 0 splits KEK from auth secret).
- **Storage**:
  - **iOS**: Keychain (hardware-backed when available)
  - **Android**: Android Keystore (hardware-backed when available)
  - **Web**: IndexedDB with encryption layer
  - **Server**: Never stores user private keys

### File Encryption
- **Current Implementation**: Whole-file AES-256-GCM. Cleartext `mediaKey` on wire payload is removed in Phase 0.
- **Target (Phase 4)**: `vmed2` segmented AEAD streaming media with per-attachment keys and unguessable URLs.

---

## Authentication

### Session Management

**JWT Tokens**:
- Access token: 15 minutes validity
- Refresh token: 7 days validity
- Automatic rotation on refresh
- Secure, HttpOnly cookies

**Flow**:
```
1. User login with email + password
2. Server verifies credentials (bcrypt + Argon2)
3. Issues JWT access + refresh tokens
4. Client stores tokens securely
5. Each request includes access token
6. Expired? Use refresh token to get new access token
7. Refresh token expired? Re-authenticate
```

### Password Security

- **Hashing**: bcrypt + Argon2 (double hashing)
- **Minimum**: 12 characters
- **Validation**: Server enforces NIST guidelines
- **Reset**: Email-based verification link (1 hour validity)
- **2FA**: Optional TOTP support

---

## Transport Security

### HTTPS/TLS

- **Minimum Version**: TLS 1.3
- **Certificates**: Let's Encrypt or CA-signed
- **HSTS**: Enabled (1 year)
- **Certificate Pinning**: Optional (iOS/Android)

### Certificate Validation

- **Client**: Verifies server certificate
- **Server**: Verifies client (optional mTLS)
- **Pinning**: Available for high-security deployments

---

## Data Protection

### Data Minimization

**Collected**:
- Email address
- Display name
- Public key
- Message timestamps

**Not Collected**:
- IP addresses (unless logging)
- Device identifiers
- Location data
- Usage analytics
- Behavioral data

### Data Retention

- **Deleted Messages**: Permanently removed from server
- **Accounts**: 30-day grace period before deletion
- **Logs**: Rotated after 30 days
- **Backups**: Encrypted, 7-day retention

### GDPR/Privacy Compliance

- ✅ Right to access data export
- ✅ Right to deletion
- ✅ Right to data portability
- ✅ Privacy policy included
- ✅ Terms of service provided

---

## Optional Privacy Features

### Tor Integration

Connect via Tor for network-level anonymity:

```bash
# Server configuration
TOR_ENABLED=true
TOR_SOCKS_PORT=9050
```

**Benefits**:
- Hide IP address
- Bypass regional blocks
- Prevent ISP monitoring
- Protect against traffic analysis

**Trade-offs**:
- Slower connection (2-3x latency)
- Some features may be limited

### Ephemeral Messages

Messages that auto-delete:
- Duration: User-configurable (5s to 24h)
- Server: Deletes after expiry
- Client: Clears from memory
- Screenshot prevention: Planned (not currently guaranteed)

---

## Code Security

### Dependencies

- **Auditing**: `npm audit`, `mix audit`
- **Updates**: Regular security patches
- **Transparency**: CHANGELOG tracks changes
- **Pinning**: Exact versions locked (no auto-update)

### Input Validation

- **Client**: Frontend validation (UX only)
- **Server**: Strict validation on all inputs
- **Sanitization**: HTML escaping, SQL parameterization
- **Rate Limiting**: Prevent brute force attacks

### Error Handling

- **Generic Messages**: Don't leak internal details
- **Logging**: Sensitive data redacted
- **Monitoring**: Security alerts on anomalies
- **Incident Response**: Clear escalation procedure

---

## Attack Prevention

| Attack | Mitigation |
|--------|-----------|
| **Brute Force** | Rate limiting + account lockout |
| **SQL Injection** | Parameterized queries + input validation |
| **XSS** | Content Security Policy + escaping |
| **CSRF** | CSRF tokens on state-changing requests |
| **Man-in-the-Middle** | HTTPS + certificate pinning optional |
| **Side-Channel** | Constant-time comparisons for auth |

---

## Deployment Security

### Server Hardening

```bash
# Minimal services running
# Firewall rules (whitelist approach)
# SSH key-based auth only
# Fail2ban for attack prevention
# SELinux or AppArmor enabled
```

### Database Security

- **Backups**: Encrypted at rest
- **Replication**: TLS between servers
- **Access Control**: Least privilege
- **Audit Logging**: All data access tracked

### Secrets Management

- **API Keys**: Rotated quarterly
- **Certificates**: Renewed before expiry
- **Passwords**: Never in code/config
- **Environment**: `.env` files never committed

---

## Security Audit

### Self-Assessment

- ✅ Code audit and ground-truth cryptographic findings documented (`docs/encryption-media-status-2026-08.md`)
- ✅ Authentication & Transport TLS configurations verified
- ✅ Core Rust primitives and AAD-bound store sealing verified
- ⚠️ Phase 0 plaintext leak remediations in progress (run `securecore-0806`)

### Third-Party Audits

No independent third-party audit has been completed yet. Independent external reviews are required prior to making public end-to-end security claims:
- [ ] Cryptography review (professional firm — planned)
- [ ] Penetration testing (planned)
- [ ] Code audit (independent auditor — planned)

### Bug Bounty

Report security issues to: security@vibegram.app

**Responsible Disclosure**:
1. Email security team
2. Allow 90 days for fix
3. Credit in announcement (if desired)
4. Bounty rewards available

---

## User Responsibilities

Users should:
- ✅ Use strong, unique passwords
- ✅ Keep devices updated
- ✅ Enable 2FA when available
- ✅ Verify contact information
- ✅ Report suspicious activity

---

## Transparency

We believe in security through transparency:
- Code is open source
- Security practices documented
- Vulnerability disclosures public (after fix)
- Annual security report published
