# Deploy pipeline

How a change reaches production, and what an agent may do without a human.

## Shape

```
PR ──► ci.yml ──────────────────────────► review ──► merge to main
        server · agent-runtime · gateway
        images · scripts   (core, lint: advisory)

main ──► deploy-vps.yml
          ci.yml (again, on the merge commit)
            └─ green ──► rsync tree to /opt/vibe
                         deploy.sh
                           tag :previous ──► build ──► migrate ──► up
                           readiness gate ──┬─ pass ──► done
                                            └─ fail ──► rollback :previous, exit 1
                         agent-ops.sh health
                         public smoke test (VIBE_PUBLIC_HEALTH_URL)
```

Three gates, in order: tests before merge, tests again before deploy, readiness
after deploy. The third one rolls back by itself.

## What runs where

**CI runs on GitHub.** Tests, formatting, clippy, and a Dockerfile build. The
image build in CI is throwaway — it exists to catch a broken Dockerfile before
it reaches a box that is serving traffic.

**The build that ships runs on the VPS.** `deploy.sh` builds there because the
box has no registry credentials and the compose file references local tags. See
[Phase 2](#phase-2-immutable-artifacts) for why this should change.

**Nothing pulls.** GitHub pushes over SSH. Port 22 is the only inbound port the
firewall allows, and it is rate-limited.

## Rollback

`deploy.sh` tags the live images `:previous` before it builds anything. If the
readiness gate fails, it retags and recreates `core` and `agent-runtime` and
exits non-zero. The data tier is never touched.

Manual, from a laptop:

```bash
ssh vibe-vps '/opt/vibe/deploy/scripts/deploy.sh --rollback <sha>'
```

Or `workflow_dispatch` on **Deploy to VPS** with `rollback_sha`. That path skips
CI on purpose — an emergency must not be blocked by a red suite.

Every build is tagged with its short sha, so `podman images vibe-core` is the
list of what you can roll back to.

## Migrations

**Rollback restores code, not schema.** `deploy.sh --rollback` retags images; it
does not run down-migrations. So every migration must be safe for the *previous*
release to run against — expand and contract, never rename in place:

1. Ship the additive migration and the code that tolerates both shapes.
2. Ship the code that uses only the new shape.
3. Ship the migration that drops the old shape.

Three deploys, not one. A migration that breaks step 1 makes rollback impossible
and turns a bad deploy into an outage.

## What an agent may do

Without asking:

- open a PR, push to a branch, run CI
- run `agent-ops.sh status | health | logs | audit` against production
- read `/run/vibe/env/*.env` **by name only** (`grep -oE '^[A-Z_0-9]+='` — drop the
  digits and every `R2_*` name silently vanishes from the answer)

With the human in the loop:

- merging to `main` (this deploys)
- `workflow_dispatch` rollback
- anything that writes a secret, DNS, or the firewall
- schema migrations that are not additive

Never:

- read or print a secret value, or the origin address
- put a secret in argv — `apply-env.sh` reads stdin for this reason
- `git push --force` to `main`, or commit to `main` directly

## Secrets

Nothing about deployment reads a secret from the repo. Production secrets are
sealed on the box with the systemd host key (`deploy/env/*.env.cred`) and exist
in plaintext only in tmpfs at `/run/vibe/env`. See `deploy/scripts/seal-env.sh`.

To change one:

```bash
agix secret run --only NAME -- sh -c \
  'printf "NAME=%s\n" "$NAME" | ssh vibe-vps "sudo /opt/vibe/deploy/scripts/apply-env.sh core.env"'
```

Then recreate the service — `podman restart` does **not** re-read `env_file`.

GitHub needs four secrets for the deploy job: `VPS_HOST`, `VPS_USER`,
`VPS_SSH_KEY`, `VPS_HOST_KEY`. The host key is pinned rather than scanned, so a
swapped host fails the deploy instead of being trusted silently.

## What is advisory, and why

Two jobs are `continue-on-error` because the tree is red *before* this pipeline
existed. Neither is a place to report a new defect — fix the cause, then make the
job blocking.

**`core` (vibe_core tests).** Five tests still assert the bounded window default
that was retired on purpose:

```
window::tests::policy_enforces_the_frozen_envelope
window::tests::bounds_report_more_in_both_directions
window::tests::jump_to_message_centres_the_window
window::tests::paging_before_then_after_re_arms_tail_following
window::tests::paging_before_walks_a_large_store_to_its_first_message
```

`VibeWindowPolicy::default()` is now unbounded — `window.rs:445` documents the
replacement — but `window.rs:433` still expects `(150, 300, 200)`. The bounded
envelope is still reachable via `try_new`, so these want rewriting against that,
not deleting.

**`lint`.** `agent-runtime/lib/vibe_agents/llm/loop.ex` is unformatted, and
`cargo fmt` and `clippy` have not been run over `core` in a while. `server/` has
no `.formatter.exs` at all, so it is not format-checked.

## Phase 2: immutable artifacts

The current pipeline builds on the production box. That is the one part of this
design that a larger team would not accept, for three reasons: the build
competes with the running stack for RAM and CPU on a 4 GB box, the artifact that
ships is not the artifact CI tested, and rollback depends on images that happen
to still be in the local store.

The fix is to push to GHCR from CI and have compose reference `image:` by digest
instead of building. It touches all ten services in `compose.yml` plus a
registry credential on the box, so it is deliberately not bundled with the
tunnel migration.

## Related

- `deploy/scripts/deploy.sh` — build, migrate, readiness gate, rollback
- `deploy/scripts/agent-ops.sh` — the read verbs agents use against production
- `deploy/scripts/tunnel-install.sh` — cloudflared, ingress, firewall
- [docs/run-on-device.md](run-on-device.md) — the iOS side, unrelated to this
