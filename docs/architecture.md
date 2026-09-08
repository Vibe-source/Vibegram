# Architecture

## System Overview

Vibe is built on a **layered architecture** with clear separation of concerns between clients, transport, business logic, and data layers.

```
┌─────────────────────────────────────────────────────────┐
│                    CLIENT LAYER                          │
├──────────────────────┬──────────────────────┬────────────┤
│   iOS (Swift)        │  Android (Kotlin)    │  Web (TS)  │
│  - Native UI         │  - Native UI         │ - React    │
│  - Local Storage     │  - Local Storage     │ - SQLite   │
│  - Call Engine       │  - Call Engine       │ - WebRTC   │
└──────────────────────┴──────────────────────┴────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              TRANSPORT & SECURITY LAYER                  │
├─────────────────────────────────────────────────────────┤
│  WebSocket (realtime) │  HTTPS (REST) │ TweetNaCl (E2EE) │
│  Message Serialization│ Auth Tokens   │ Key Exchange      │
└─────────────────────────────────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│                  API & BUSINESS LOGIC                    │
│              (Elixir/Phoenix Framework)                  │
├──────────────────┬──────────────┬──────────────────────┤
│  User Management │ Message Ops  │ Call Signaling       │
│  Auth (JWT)      │ Encryption   │ Media Upload         │
│  Profile Mgmt    │ Notifications│ Presence Tracking    │
└──────────────────┴──────────────┴──────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              DATA PERSISTENCE LAYER                      │
├──────────────────────┬──────────────────────────────────┤
│   PostgreSQL DB      │  File Storage (Encrypted)        │
│  - User Data        │  - Media Uploads                   │
│  - Chat History     │  - Backups                         │
│  - Relationships    │  - Keys & Secrets                  │
└──────────────────────┴──────────────────────────────────┘
```

## Components

### Frontend Layer

**iOS** (`/ios`)
- SwiftUI-based native app
- ChatModule for messaging
- Call engine for voice/video
- Push notification handling
- Offline message queuing

**Android** (`/android`)
- Kotlin with Jetpack Compose
- Native chat implementation
- Real-time call screens
- Firebase Cloud Messaging
- Local message storage

**Web** (`/client`)
- React 18 TypeScript SPA
- Vite for fast builds
- WebSocket support
- Local database (SQLite)

### Backend Layer

**Elixir/Phoenix** (`/server`)
- High-concurrency message broker
- Real-time WebSocket channels
- RESTful API endpoints
- Background job processing
- Encrypted storage layer
- Authentication (JWT)
- Media upload handling

### Data Layer

**PostgreSQL**
- User accounts & profiles
- Encrypted messages
- Chat history
- Relationships & blocks

**File Storage**
- Encrypted media uploads
- User backups
- Key management

## Data Flow

### Sending a Message

```
1. User A types message → Client encrypts with recipient's public key
2. Client sends encrypted message via WebSocket
3. Phoenix receives → validates user → stores encrypted blob
4. If recipient offline → message queued in Redis
5. When recipient comes online → system sends push notification
6. Recipient receives notification → fetches message
7. Client decrypts with private key → user sees plaintext
8. Server never sees unencrypted content
```

### Real-Time Updates

```
Phoenix Channel subscription
├── User A → User B (open chat)
├── System broadcasts typing indicator
├── Recipient sees "User A is typing..."
└── Message sent → instant delivery notification
```

## Security Architecture

### Encryption

- **Algorithm**: TweetNaCl Box (Curve25519 + XSalsa20 + Poly1305)
- **Key Exchange**: Elliptic curve Diffie-Hellman
- **Storage**: Keys derived from passwords using Argon2

### Authentication

- **Method**: JWT tokens with refresh rotation
- **Transport**: HTTPS/TLS for all connections
- **Session**: Redis-backed session management

### Data Protection

- **At Rest**: AES-256-GCM for encrypted storage
- **In Transit**: TLS 1.3 minimum
- **User Data**: Server cannot access plaintext messages

## Deployment Architecture

Target (2026-08, replaces Railway): one VPS running a Podman/Docker compose stack —
Caddy (TLS) → `vibe-core` (this Phoenix app) and `vibe-agent-runtime` (the isolated agent
service), Postgres behind PgBouncer, Valkey, a Rust `sandbox-gateway` that gives each agent a
sandboxed computer on an internal-only network, encrypted backups to R2.

- Service boundaries, trust boundaries and the core ↔ runtime contract: [agent-platform-v1.md](agent-platform-v1.md)
- Compose stack, host hardening, migration and restore runbooks: [vps-deployment.md](vps-deployment.md)
- What the readiness checklist still flags: [security-readiness-gap-2026-08.md](security-readiness-gap-2026-08.md)

## Scalability

- **Vertical first**: one BEAM node serves far more than the current load; PgBouncer transaction
  pooling keeps Postgres connections bounded.
- **Second node**: `CLUSTER_STRATEGY=gossip|dns` (libcluster) for PubSub/Presence,
  `RATE_LIMIT_BACKEND=valkey` for shared limits, `Vibe.Cache` invalidation over PubSub.
- **Agents**: the runtime scales independently of chat; sandboxes are capped per host
  (`SANDBOX_MAX_CONTAINERS`) and per agent (one computer each).
- **Media**: object storage (Supabase / Cloudflare R2), never the app container.

## Performance Optimization

- WebSocket connection pooling
- Message batching for bulk operations
- Database query optimization with indexes
- Client-side caching with offline support
- CDN for static assets
- Asset compression (gzip/brotli)
