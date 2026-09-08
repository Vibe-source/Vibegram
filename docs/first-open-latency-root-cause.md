# First-open latency — root cause

From `vibe-diagnostics-1786187710.txt` (iPhone 13 Pro Max, iOS 26.5.2, 39 `chatopen` traces
across 20 sessions).

## The headline number is 40% constant

```
tap→content=399ms … will-appear 400ms … did-appear 1011ms … complete 1029ms … settled 1671ms
```

Three different things are being added together:

| segment | measured | ours? |
|---|---|---|
| tap → `will-appear` | 37–400ms | **yes** — the seed |
| `will-appear` → `did-appear` | **~550ms, every open** | no — see below |
| `complete` → `settled` | ~620ms | no — it is a 0.6s timer |

`will-appear → did-appear` is 544, 549, 550, 551, 554, 558, 574, 598, 611ms across 3-row,
68-row and 1103-row chats. It does not move with content, and `hang=0.00s` on most of them.
UIKit reports `transitionDuration = 350ms`. The frame pacer during that window reads
`frames=26 dropped=1 worstGapMs=25.0` — a uniform ~23ms cadence, so nothing of ours is
running inside it.

Optimising the seed can only ever touch the first row of that table. Three months of work
has been aimed at a number that is ~1.2s of which ~0.6s is a timer and ~0.55s is the OS.

**Open question, one measurement:** push an empty `UIViewController` through the same nav
and time `will-appear → did-appear`. ~550ms ⇒ it is the OS spring settling past its nominal
350ms and `did-appear` is the wrong endpoint for "felt latency". ~350ms ⇒ the parked
full-bounds transcript is degrading the transition itself.

## The arch defect: every cache that makes an open fast is in-memory

The design is right — cover the push with a raster, seed during the slide. Both caches
miss ~100% on the one open that matters.

### 1. `VibeTimelinePreparedStore` cannot survive a launch

`byChat` is an in-memory dictionary. There is no disk tier. A cold launch starts empty by
construction, so the first open of a session is a guaranteed total miss:

```
prepared=0hit/72miss width=412      ← cold open
prepared=0hit/0miss  width=0        ← warm open: not consulted at all
```

Sizing itself is fine — the disk height store carries it (`trust=66 measure=0/0ms`, 9ms).
The prepared store is not what makes cold opens slow; it is simply dead on them, and its
`0hit` line has been read as a bug to chase rather than the design.

### 2. The reopen raster cover is looked up under a key that is not yet stable

Every open probes twice. Within a single open, 48ms apart, the same file gets two different
answers:

```
77ms  raster-miss cache-miss file=N
125ms raster-miss cache-miss file=Y
```

All 8 `file=Y` results in the export are the *second* probe of a pair. The key is
`chatId|width|theme|a<appearanceDigest>|v5` and `appearance` is bootstrapped from cache in
`init` — the first probe runs before the real appearance lands, so it spells a name nothing
ever wrote. By the time the correct key exists the open has already decided `covered=N`.

The consequence is exactly the reported symptom: **the first open of a chat is never
covered; every open after it is.** Covered opens reach `will-appear` at 37–95ms, uncovered
ones at 194–400ms.

Same class of failure as the `v2`/`v4` drift already documented in `reopenSnapshotKey`, one
level up: not the version, the *timing* of the inputs.

## One cause under both — and under the theme bug

`ChatListAppearance.fallback` was a hard-coded dark palette, and `from(draft:)` resolved
`mode == "system"` to dark unconditionally. Since `appearance` is what spells
`reopenSnapshotKey`, an unresolved appearance produced a *dark* key on the first probe and
the real one on the second — the `file=N` → `file=Y` disagreement above. The same constant
is why a light-mode user saw a dark chat.

`seededDefault()` compounded it: it baked the resolved palette into the saved draft, so the
chat froze at whichever appearance was current the first time it ran.

## Fixed

- **No fallback palette.** Colour comes from the plate table (`nativePreset`) only.
  `fallback` resolves the saved plate + light/dark; `plate(themeId:isDark:)` is the single
  colour source; draft colour defaults are empty and mean "the plate decides"; a v3
  migration clears baked palettes that still match a plate.
- **Theme switches propagate.** `AppAppearanceController`/`AppThemePlateController.setOption`
  update the chat draft and invalidate the bootstrap cache.
- **Agent list follows the theme.** `ChatAgentsMainViewController.theme` was `let`, latched
  when the Agents tab was built at launch; it now re-derives on appear and trait change,
  with repaint paths on the skeleton and empty-state views.
- **Cover re-probe.** `applyResolvedAppearance` re-kicks the disk preload when the visual
  key changes while nothing is on screen yet.
- **Prepared store survives a launch.** `ChatEngine.prepareTimelinesAfterLaunch` re-measures
  the 3 prewarm chats off-main from the sealed store; measurement width is persisted so it
  can run before the first list reports one. Deliberately *not* a plaintext file on disk —
  entries hold decrypted rows, and the sealed store exists to keep those out of the
  filesystem.
- **Blur off the main thread.** `cell=18/115ms` → `cell=14/227ms` with a 0.56s hang stacked
  on `chatBlurredMicroThumbnail ← cellForItemAt`. Now returns the sharp thumb synchronously
  and blurs once off-main per key (`chatRequestMicroThumbBlur`).

## Still open

1. The 550ms push window — settle it with the empty-VC measurement before any more seed
   work. It changes the report, not the fixes.
2. Verify on device: no open should show `file=N` then `file=Y`, and the first open of a
   session should read `covered=Y` for any chat with a capture.
