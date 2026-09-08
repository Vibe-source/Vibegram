# vibe_contracts

Shared, dependency-free (besides `jason`) Elixir contracts for `server/` (core) and
`agent-runtime/`, so both apps speak the frozen `vibe.agentic.v1` / `vibe-internal-auth/v1`
wire shapes identically. Path dep: `{:vibe_contracts, path: "../contracts"}`.

- `VibeContracts.ServiceAuth` — internal HMAC request signing/verification.
- `VibeContracts.RunEvent` — the `RunEvent` stream shape and validation.
- `VibeContracts.Redact` / `VibeContracts.SafeURL` — secret scrubbing and SSRF guard.
- `VibeContracts.WebhookSignature` — provider callback signing.
- `VibeContracts.AskQuestion` / `VibeContracts.Outputs` — question and finalized-output shapes.

See `docs/agent-platform-v1.md` §3.1, §3.4, §3.5 in the main repo for the frozen spec.
