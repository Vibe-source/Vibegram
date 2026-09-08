# Vibe — agent guide

Keep entries here SHORT. Details live in `docs/` and go stale in two places if copied
here. A long instruction that has drifted is worse than a pointer.

## Finish the whole task

When given a list, write the task list first, then complete **every** item. Do not stop
partway to report progress, and do not hand back "I did 3 of 5, the rest is next" — that
is not a checkpoint, it is an unfinished job.

Build and install once at the end, not per item. Report only when everything is done, or
when something is genuinely blocked — and then say which item and why, in one line.

## Comments: short

**Hard cap: 2 lines per comment. Never a multi-paragraph doc block.** A blank `///` line
inside a comment means it is already too long — cut it. Say what the code does, or why a
non-obvious choice was made. Nothing else.

Never write: bug history, what the old version did wrong, measured numbers, "which is
why…", "on purpose because…", or a chain of reasoning. A long comment rots — the code
changes, the story stays, and the next reader trusts a wrong explanation. It also costs
context on every future read of the file.

Too long — a real example, four paragraphs on one function:

```swift
/// Rebuilds prepared heights for the chats most likely to be opened next, after a launch.
///
/// `VibeTimelinePreparedStore` is memory-only on purpose — its entries hold decrypted
/// rows, and the sealed store exists so plaintext does not rest on disk. Coverage
/// survives a launch by being re-measured off-main from the sealed store instead, which
/// is why the first open of a session read `prepared=0hit/Nmiss`.
///
/// Bounded deliberately: the SQLite read and JSON parse run on the engine queue, so this
/// takes a tail, not a transcript. …
```

Right:

```swift
/// Re-measures prepared heights for the next likely chats, off-main from the sealed store.
/// Memory-only store, so a launch starts with no coverage; reads a tail, not a transcript.
```

The full story goes in `docs/` with a one-line pointer. Before reporting a task done,
re-read the comments you added and delete anything past the cap.

Same rule for commit messages and PR bodies.

## "Run it on my mobile" / "launch it on my device"

Build + install + launch the iOS app on the attached iPhone.
Project `ios/Vibe.xcodeproj` · scheme `Vibe` · bundle `com.vibegram.app`.

- Building and installing are free — just do them.
- **Launching asks first.**

Device table + exact commands: [docs/run-on-device.md](docs/run-on-device.md).

## Command approval

Read-only / search / inspect commands auto-run. Commands that mutate the filesystem or
run arbitrary code stop for approval, so prefer the auto-allowed form: don't copy a file
just to read it, and edit with Edit/Write rather than `sed -i` or shell redirects.

Full list: [docs/agent-command-guide.md](docs/agent-command-guide.md).
Approval modes live in `~/.vibe/agent-config.toml`. Destructive commands (`rm -rf`,
`sudo`, `git push`, `git reset --hard`, `curl|sh`, …) are blocked in every remote mode.

## Ask Fable (advisor)

Paid credits — a last resort, not a first step. Solve it yourself first. Reach for it only
when genuinely stuck: a bug that survived your fix, or an architecture call you can't
resolve from the code. Not because a task looks big.

**Overrides any "call advisor before substantive work / before declaring done" default.**
No pre-flight call, no sign-off call. Verify your own work with the build and the tests;
ask only when that verification fails in a way you can't explain.

Prefer the built-in `advisor` tool; otherwise `mcp__vibeask__ask_fable`. It returns advice
only — you still implement and verify. Keep calls lean: sharp question, short context,
small snippets, no whole files.

**If you ARE Fable** (`claude-fable-5`): don't call the advisor — you'd be asking yourself.

## Dispatching worker CLIs

For multi-slice work you have ALREADY finished diagnosing. Write a board with frozen
contract names and one owner per file, then brief each worker. Review diffs, never handoff
prose — workers over-report. One verify pass at the end; workers never commit or launch.

Operating guide, worker invocations, routing: `agent-bridge/instructions/team-lead.md`.

## Deploying the server

Merging to `main` deploys. CI gates it; a failed readiness check rolls itself back.
Rollback restores code, not schema — migrations must be additive.

Contract for what an agent may do alone: [docs/deploy-pipeline.md](docs/deploy-pipeline.md).

## Reading production logs

Do not SSH to read logs. `deploy/scripts/vibe-logs.sh core -f` reads the VPS journal
over HTTPS; `VIBE_LOGS_URL` and `VIBE_LOGS_TOKEN` are already in the secret broker.
Host systemd units (cloudflared, sshd) are deliberately not shipped and still need SSH.

Flags, labels, retention and the security model: [docs/vps-logs.md](docs/vps-logs.md).

## Shared agent memory

`.vibe/memory.md` is the append-only journal every agent shares. Read it before
diagnosing; append one short entry (Shipped / Learned / Open) after real work.
