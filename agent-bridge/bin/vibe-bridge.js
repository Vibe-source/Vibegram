#!/usr/bin/env node
"use strict";

/**
 * Vibe agent bridge daemon.
 *
 * Runs on the user's OWN computer. Pairs to a Vibe account with a one-time code,
 * then connects (outbound only) to the Vibe server and waits for `run_task`
 * events. For each task it runs `claude` / `codex` / `grok` / `agy` locally and streams the raw
 * output back — the Vibe server parses it and posts the result into the chat.
 *
 * Usage:
 *   npx @vibegram/agent-bridge --code <PAIRING_CODE> --server https://your-vibe-server
 *   # subsequent runs (token cached in ~/.vibe/bridge.json):
 *   npx @vibegram/agent-bridge --server https://your-vibe-server
 *
 * Safety: defaults to safe-auto execution; plan/read-only/full-access are explicit
 * task modes. Escalate explicitly via the env vars below.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const readline = require("readline");
const net = require("net");
const { spawn, execFileSync, spawnSync } = require("child_process");
const agySupport = require("./agy-support");

let WebSocket, Phoenix;
try {
  WebSocket = require("ws");
  Phoenix = require("phoenix");
} catch (err) {
  console.error(
    "[vibe-bridge] Missing dependencies. Run `npm install` in the agent-bridge folder (needs `ws` and `phoenix`)."
  );
  process.exit(1);
}

// ── Config / args ───────────────────────────────────────────────────

const CONFIG_DIR = path.join(os.homedir(), ".vibe");
const CONFIG_FILE = path.join(CONFIG_DIR, "bridge.json");
// Exclusive lock so only ONE bridge daemon holds the socket for a machine.
// Dual bridges both receive run_task and post duplicate agent replies (e.g. two Grok bubbles).
const SINGLETON_LOCK_FILE = path.join(CONFIG_DIR, "bridge.singleton.lock");
const SINGLETON_PID_FILE = path.join(CONFIG_DIR, "bridge.pid");
// Liveness stamp: the running bridge writes {pid, ts, active} here every few seconds so a
// NEWLY-started bridge can tell a healthy, BUSY daemon (mid team-run) from a dead/idle one.
// Killing a busy bridge takes its child worker CLIs (claude/grok/codex) down with it
// (exit 143/130) — the "team gets cut down mid-flight" bug. A new bridge yields to a busy
// holder and only replaces an idle/stale one (so relaunching for new code still works).
const SINGLETON_HEARTBEAT_FILE = path.join(CONFIG_DIR, "bridge.heartbeat.json");
const SINGLETON_HEARTBEAT_MS = 5000;
const SINGLETON_HEARTBEAT_STALE_MS = 30000;
const MAX_PROGRESS_LINES = 400; // safety cap on streamed events per task
const MAX_LINE_BYTES = 8 * 1024;
// During long silent stretches (Opus extended thinking emits the whole reasoning
// block as ONE stream-json event at the end, so the CLI can go 30–60s with zero
// output) the phone's live feed would otherwise freeze. Re-push a lightweight
// keepalive on this cadence so the server re-broadcasts the current snapshot —
// a phone that missed a broadcast during a 1006/1012 drop re-syncs, and the live
// turn never looks stalled. Carries no feed node (the server parser ignores it).
const KEEPALIVE_MS = 10 * 1000;
// ws-level (RFC 6455 control-frame) ping cadence used to detect a half-open TCP socket —
// see attachSocketLivenessPing. This is deliberately independent of the application-level
// "heartbeat" push/reply below: a raw ping/pong round-trips at the OS socket layer without
// waiting on the Phoenix channel join state, so it catches a zombie connection well before
// the app heartbeat's 2-miss threshold would.
//
// TUNING (2026-07-11): Cloudflare/edge still delays pongs. Logs showed miss#1 → 1006 →
// reconnect ~3s in a loop, which batched progress frames (recv→push 7–15s). Raw ws-ping
// terminate was self-inflicting flaps; it is now OBSERVE-ONLY. Application heartbeat
// (channel push "heartbeat") is the sole reconnect authority, with a higher miss budget.
const WS_PING_INTERVAL_MS = 20 * 1000;
const WS_PING_MAX_MISSES = 4; // log-only past this; never terminate from ws ping alone
const APP_HEARTBEAT_INTERVAL_MS = 30 * 1000;
const APP_HEARTBEAT_PUSH_TIMEOUT_MS = 15 * 1000;
const APP_HEARTBEAT_MAX_MISSES = 3; // ~90s of silence before force reconnect
const MAX_DIFF_BYTES = 90 * 1024;
const MAX_DIFF_FILES = 24;
const MAX_UNTRACKED_FILE_BYTES = 220 * 1024;
const BRIDGE_INSTRUCTION_DIR = path.join(".vibe", "instructions");
const BRIDGE_INSTRUCTION_FILES = {
  "AGENTS.md": `# Vibe Agent Operating Guide

These rules apply to AI agents working through Vibe, including Claude and Codex.

## Role

- Act like a senior engineer working in a real production codebase.
- Inspect the existing code before proposing or editing.
- Prefer the repository's existing architecture, naming, and UI patterns.
- Keep changes scoped to the user's request.
- Do not perform unrelated refactors or cleanup.

## Local Bridge Workflow

- The selected project lives on the user's computer, not on the phone.
- Treat the mobile app as the control surface for prompts, command approvals, progress, files, diffs, and results.
- Surface useful runtime details: commands, files touched, patches, blockers, verification, and remaining risk.
- If a command needs approval, explain the exact command, why it is needed, and the risk.

## Claude and Codex Teamwork

- When a task includes both Claude and Codex, work as one team.
- Do not duplicate another agent's likely work.
- If the user assigns work by name, follow that assignment exactly.
- If work is not assigned, choose a non-overlapping slice and state what you took.
- Read teammate notes before continuing.
- Use .vibe/team/<team_run_id>.md as the shared handoff file when repo writes are allowed.
- Keep handoff edits additive under your own section with ownership, findings, files changed, blockers, and next steps.

## Browser, Chrome, and Agent Browser Work

- When the user mentions Chrome, browser testing, screenshots, clicking UI, or Agent Browser, use the browser automation tools/CLI available on this computer instead of guessing.
- Prefer the repo's existing dev-server/test scripts, then verify with browser automation: open the page, inspect visible UI, check console/runtime errors, click the important controls, and capture screenshots when useful.
- Report the URL, what was verified, and any browser/tool blocker in the final result.

## Terminal, Files, and Approvals

These runs are headless. Nobody is sitting at a terminal to answer a permission prompt,
so a command that needs approval does not pause and wait — it fails. Work inside the
rules below and you will never be blocked.

- Read and edit through your file tools, never through the shell. Open a file with the
  file-read tool; change it with the edit tool. Do NOT use cat, sed, awk, or echo
  redirects to read or rewrite source.
- Never create scratch or helper files. Do not write a script, a path dump, a directory
  listing, or a notes file to work out where something lives — use the search/glob tools
  and read the file directly. A temp file in the repo is a defect, not a workflow.
- When a tool and a shell command would both work, use the tool.

Runs without approval — use these freely:
ls, cat, head, tail, wc, file, stat, pwd, which, echo, tree, du, diff, realpath,
basename, dirname, sed -n; grep, rg, find; git status, git diff, git log, git show,
git branch, git ls-files, git blame, git rev-parse, git remote -v; npm run
build/test/lint/typecheck, npm test, npm ci, npm install, yarn/pnpm build/test, mix test,
mix compile, mix format, mix deps.get, xcodebuild, xcrun, swift build, swift test,
swiftformat, pytest, cargo build/test, make.

Denied — these fail and cannot be approved from inside a run:
git push, git reset, git checkout, git clean, rm -rf, sudo, chmod -R, chown -R, killall,
security, defaults write, and any publish or deploy command.

- NEVER push or deploy. Shipping is the user's decision, not a verification step. Do not
  put "commit and push" or "deploy" in a plan, a handoff, or a task list. If your work is
  complete and would normally be pushed, stop and say so in your result.
- If you genuinely need a denied command, report it as a blocker with the exact command
  and why you need it. Do not attempt a workaround.

## Safety

- Start with read-only inspection when the risk is unclear.
- Do not delete files, reset git state, force push, rotate secrets, or run destructive commands unless the user explicitly approves.
- Never expose secrets, tokens, private keys, or local credentials.
- Do not overwrite user work. Check the current diff before touching files that may already be edited.

## Implementation Standard

- Make the smallest complete change that solves the real problem.
- Prefer structured payloads over flattened text when the app needs to render tools, commands, patches, or runtime state.
- For iOS work, keep UI behavior consistent with the existing SwiftUI/UIKit patterns.
- For server work, preserve auth boundaries, group ownership, and per-user bridge routing.
- For bridge work, keep repo selection, work mode, provider, command status, and task metadata visible.

## New-Project Build Standard

Applies ONLY when the user asks to create a new product, site, app, or service from
scratch (or the selected repo is empty). For maintenance work in an existing codebase,
the Implementation Standard above wins and this section does not apply.

- Plan the architecture BEFORE writing code: pages/routes, components, backend API
  endpoints, database schema and migrations, data flow, styling system, and how the
  project builds/deploys. Record the plan in the team handoff file when in a team run.
- Production grade means: every planned page/route implemented with real content and
  working navigation; backend endpoints wired to real handlers and the database when the
  project needs data; responsive and accessible UI; SEO/meta where it is a website; and
  the project build passing (npm run build or the stack's equivalent). Run tests if the
  project has them.
- No placeholder stubs, no TODO screens, no single-page demo for a multi-page request.
- Finish your entire assigned file list. If you cannot, list exactly what is missing and
  why in the handoff — never silently stop early.

## Premium UI/UX Production Standard (websites & app frontends)

The default "AI-generated" look is unacceptable. When the task is a website, landing
page, marketing site, dashboard, or any user-facing frontend, the result must read as a
hand-crafted, premium product (think Linear, Vercel, Stripe, OpenAI, Anthropic,
ElevenLabs) — NOT a template. For any UI/frontend/website slice, READ
\`.vibe/instructions/skills/premium-web-ui.md\` before writing components and follow it.

Non-negotiables:
- No generic scaffold: never ship the "big centered hero + three equal feature cards +
  generic footer" template. Design an intentional layout with a clear focal hierarchy,
  purposeful asymmetry, and real sections that serve the product's actual story.
- Real content and copy: no lorem ipsum, no "Feature one / Feature two", no dead
  buttons. Every nav item, link, and CTA resolves to a real destination.
- A signature visual element: at least one crafted moment — a WebGL/shader/canvas hero,
  a Spline or three.js/R3F scene, an animated gradient/grain field, or a bespoke SVG
  system — so the page has a point of view. Use GSAP + ScrollTrigger for motion; keep it
  tasteful and 60fps. Honor prefers-reduced-motion.
- Design tokens and rhythm: define a type scale, spacing scale, color system (with dark
  mode), and radius/shadow tokens up front and use them everywhere — no arbitrary
  per-component pixel values.
- Header and footer must earn their place: real navigation and a real footer (site map,
  legal, social), never a lone "© 2026" line.
- Responsive and accessible: mobile-first, correct 320px→ultrawide; semantic HTML,
  visible keyboard focus, alt text, AA contrast.
- Performance: optimized/lazy images, subset/preloaded fonts, no layout shift, GPU-
  friendly motion.

Team routing: the model strongest at UI (Gemini/Agy, then Grok) owns the visual
components and page layout — WITH an exact file list — while a runtime-strong model
(Codex/Claude) owns architecture, data, and integration. The lead attaches this standard
to every UI-owning worker's focus.

## Supervisor Team Runs (lead duties)

When you are the LEAD of a team run whose task is real build work:

1. Classify first: trivial chat gets a short direct answer and no teammates.
2. For a new-project build, write the architecture plan (pages, backend, database,
   components) to the handoff file before spawning anyone.
3. Turn the plan into a task table: one row per teammate, each row an explicit,
   disjoint list of file paths to implement. No two workers may own the same file.
   Shared files (package.json, lockfiles, root layout/nav, DB schema) belong to the
   lead only — integrate teammate work there yourself.
4. Consult the available advisor (Fable; Sol as fallback) on the split when the task is
   complex. Best-effort: if the advisor is unavailable, proceed with your own split.
5. Spawn ALL teammates for build work, and give each an exact file-scoped focus.
   Vague focuses like "UI polish" or "review risks" are not acceptable for build
   tasks — name the files/pages. Gemini/Agy in particular must always receive a
   precise file list, or it drifts off-task.
6. After teammates finish, verify against the plan: every planned page/endpoint/schema
   exists, the build passes, and nothing is a stub. Respawn workers with a gap-focused
   task list if anything is missing. Iterate until the plan is fully implemented.
7. Only then write the final user summary.

## Done Criteria

- State what changed.
- State what was tested.
- State whether the result was source-verified, build-verified, bridge-verified, mobile-verified, or live-verified.
- Call out any remaining risk or manual validation that is still needed.
`,
  "CLAUDE.md": `# Claude Instructions

Follow AGENTS.md first. These additions are specific to Claude.

- Use planning and code review strengths to identify risks, architecture boundaries, and missing verification.
- In a team BUILD run you are a builder first: implement your assigned backend/frontend file list completely (see New-Project Build Standard in AGENTS.md); review and risk notes come after your slice is done.
- When paired with Codex, avoid doing the same implementation slice unless the user asks for a second opinion.
- Write concise handoff notes in .vibe/team/<team_run_id>.md so Codex can continue without rereading everything.
- If the task is not safe to edit yet, explain the blocker and the exact inspection or approval needed.
- If the user mentions Agent Browser, Chrome, or browser automation, use the local browser automation path when available and report if Claude cannot access it in this session.
`,
  "CODEX.md": `# Codex Instructions

Follow AGENTS.md first. These additions are specific to Codex.

- Use implementation and verification strengths to make focused patches and run the relevant checks.
- As team lead, follow "Supervisor Team Runs (lead duties)" in AGENTS.md: architecture plan → advisor-checked per-worker file-scoped task table → spawn all teammates → verify build and completeness → iterate on gaps.
- When paired with Claude, read Claude's handoff before editing and take the next non-overlapping implementation slice.
- Keep command output and patch summaries structured enough for Vibe to render progress, files changed, and verification.
- If a command or edit is risky, stop and ask for explicit approval through Vibe.
`,
  "skills/premium-web-ui.md": `# Skill: Premium Web UI/UX Production

Purpose: build websites and app frontends that read as hand-crafted, premium products —
the caliber of Linear, Vercel, Stripe, OpenAI, Anthropic, ElevenLabs — and never as an
AI-generated template. Read this before writing any UI/frontend/website slice; AGENTS.md
"Premium UI/UX Production Standard" is the summary, this is the working reference.

## 1. Kill the "AI look" (the most common failure)

These are instant tells that a page was generated, not designed. Do not ship them:

- The scaffold: full-width centered hero headline + subhead + two buttons, then a row of
  three identical feature cards, then a thin generic footer. This is the #1 tell. Replace
  with an intentional composition: a distinct hero treatment, sections of varying rhythm
  and width, editorial asymmetry, and a real narrative order (problem -> product ->
  proof -> deeper capability -> call to action).
- Placeholder everything: lorem ipsum, "Feature one/two/three", emoji-as-icon, dead
  "#" links, buttons that do nothing. Write real product copy and wire every control.
- Flat sameness: one font size for everything, even 16px gray text, evenly spaced boxes,
  no depth, no motion. Premium pages have a strong type scale, deliberate whitespace, and
  a few crafted moments of depth and movement.
- Default component-library skins left untouched (raw Bootstrap/MUI). Theme them into a
  bespoke system with your own tokens.

## 2. Design system first (tokens before components)

Define these once, use them everywhere. No arbitrary per-component pixel values.

- Type scale: a modular scale (e.g. 1.25 ratio) with 5-7 steps; one display face for
  headings, one clean face for body; set tracking/leading intentionally on large type.
- Spacing scale: 4px base (4/8/12/16/24/32/48/64/96/128); layout rhythm comes from it.
- Color system: a real palette with semantic tokens (bg, surface, text, muted, accent,
  border) and a full dark mode. Prefer OKLCH for consistent perceived brightness.
- Radius + shadow + border tokens; elevation as a small ladder, not random blurs.
- Motion tokens: standard durations (120/200/320/500ms) and easings (a signature ease).

Implement as CSS custom properties or a Tailwind theme; expose dark mode via
prefers-color-scheme AND a manual toggle.

## 3. A signature visual element (give the page a point of view)

At least one crafted, memorable moment. Pick what fits the brand; do not overdo it:

- WebGL / shaders: a GLSL fragment-shader gradient/grain/aurora hero, or a three.js /
  React Three Fiber scene (particles, displaced mesh, product model). Lazy-load it,
  cap DPR, pause when offscreen, and always ship a static fallback.
- Spline: fastest path to a premium interactive 3D hero — embed a Spline scene and drive
  camera/state on scroll. Good when you want 3D without hand-writing shaders.
- Canvas 2D / SVG: animated line systems, morphing blobs, generative patterns — cheaper
  than WebGL and often enough.
- Motion: GSAP is the standard. Use ScrollTrigger for scroll-linked reveals, pinning,
  and scrubbed sequences; SplitText for headline reveals; Flip for layout transitions.

GSAP patterns (register once, respect reduced motion):

    import gsap from "gsap";
    import { ScrollTrigger } from "gsap/ScrollTrigger";
    gsap.registerPlugin(ScrollTrigger);

    // Reveal-on-scroll (batched, performant)
    ScrollTrigger.batch("[data-reveal]", {
      start: "top 85%",
      onEnter: (els) =>
        gsap.to(els, { y: 0, opacity: 1, duration: 0.6, stagger: 0.08,
          ease: "power3.out", overwrite: true }),
    });

    // Pinned, scrubbed section
    gsap.timeline({ scrollTrigger: {
      trigger: ".panel", start: "top top", end: "+=1200", scrub: true, pin: true }})
      .from(".panel__art", { scale: 1.15, opacity: 0 })
      .from(".panel__copy", { y: 40, opacity: 0 }, "<0.1");

Wrap all of it so it no-ops under prefers-reduced-motion:

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!reduce) { /* run animations */ }

## 4. Layout and composition

- Establish a real grid (12-col or a custom track grid); vary section widths — full-bleed,
  contained, and narrow reading measure (~65ch for prose).
- Strong focal hierarchy per section: one clear primary element, supporting elements
  subordinate. Use scale, weight, and color, not just position.
- Generous, uneven whitespace. Align to the spacing scale.
- Real header: logo, primary nav, secondary action, mobile menu that actually works and
  traps focus. Real footer: grouped site map, legal, social, newsletter — earn the space.

## 5. Component architecture

- Componentize by real UI unit; keep components pure and prop-driven; colocate styles.
- No magic values — read tokens. One source of truth for spacing/color/type.
- Server components / static generation where the framework supports it (Next.js App
  Router, Astro, SvelteKit); ship minimal client JS; hydrate only the interactive islands.
- Accessibility is part of "done": semantic landmarks, labelled controls, visible focus
  rings, alt text, AA contrast, keyboard paths for every interaction.

## 6. Content and copy

- Write concrete, confident product copy — what it is, who it's for, why it's better.
- Real names, real numbers, real testimonials-shaped content (clearly illustrative if the
  product is new). Never dead filler.
- Every CTA states a real next step and links to a real route.

## 7. Performance budget

- Images: modern formats, correct sizes, lazy below the fold, no CLS (set dimensions).
- Fonts: subset, preload the display face, font-display: swap.
- WebGL/3D: dynamic-import, cap devicePixelRatio (<= 2), pause rAF when tab/section
  hidden, dispose on unmount, static poster fallback.
- Target: fast LCP, no long tasks from animation, smooth 60fps scroll.

## 8. Recommended stack

- Framework: Next.js (App Router) or Astro for content sites; SvelteKit is great too.
- Styling: Tailwind with a bespoke theme, or CSS Modules + custom properties.
- Motion: GSAP (+ ScrollTrigger, SplitText, Flip). Framer Motion for React micro-interactions.
- 3D: React Three Fiber + drei, or Spline for authored scenes; raw three.js for custom shaders.
- Smooth scroll: Lenis (modern) over heavier libs.

## 9. Deeper skill packs (optional, for richer patterns)

These GitHub Agent-Skill packs encode best-practice patterns for the tools above and can
be installed into a Claude Code environment for auto-activation. Reference them for
correct APIs; you do not need them to satisfy this standard:

- greensock/gsap-skills — official GSAP skills (core, timeline, ScrollTrigger, plugins).
- freshtechbro/claudedesignskills — Three.js/WebGL, R3F, Spline, Rive, Lenis/Locomotive.
- dgreenheck/webgpu-claude-skill — WebGPU + three.js TSL shaders.

## Definition of done for a UI slice

Intentional layout (not the scaffold) · design tokens used throughout · at least one
signature crafted moment · real copy and wired links · responsive 320px→wide · a11y pass
· dark mode · performance budget met · build passes.
`,
};

// Embedded team-lead guide (generated from agent-bridge/instructions/team-lead.md —
// edit THAT file, then re-run the embed one-liner in that file's header note).
const TEAM_LEAD_GUIDE_FALLBACK = "# Team lead operating guide\n\nYou are the **team lead**: architect and integrator for one `@team` run on the user's\nmachine. Workers are **CLI subprocesses you spawn**, not separate phone-driven\nsessions. The bridge preloaded this guide; treat it as binding. In group `@team`\nruns the server routes the LEAD role to claude by default — if you are reading this\nas the lead, you are usually the claude CLI.\n\n## Role\n\n- You own diagnosis, planning, dispatch, diff review, integration, and final verify.\n- Workers own only the files you assign them. They do not commit, push, build, or\n  launch.\n- You are the only process that should touch shared wiring (routers, app entry,\n  host views, migrations) unless you explicitly assign a slice.\n- You are the advisor. Workers must not call Fable or any external advisor MCP.\n\n## The loop\n\nDo this in order. Do not skip review.\n\n### 1. Diagnose\n\nRead `.vibe/memory.md` (shared team memory) first if it exists — it records what\nprevious runs shipped, which contracts are frozen product-wide, and the traps they\nhit. Then read the **real** code. Grep and open the implicated files. Find the\n**root cause** or the real product shape — not only the wording of the user message.\nTargeted reads beat exhaustive crawls; publish a best-current plan if you hit a hard\nceiling.\n\n### 2. Distill\n\n**The task is the product. The patch is a commodity.**\n\nWrite one brief per worker that **carries your understanding**. A worker should need\nnothing but its brief + its files. Each brief includes:\n\n- objective and acceptance checks\n- root cause / mechanism (why this change)\n- exact owned files (disjoint)\n- do-not-touch list\n- frozen contract names (types, fields, routes, JSON keys)\n- hard rules (below)\n- **forbid Fable / advisor tools**\n\nSave briefs under `.vibe/team/<run-id>-task-<worker>.md` — the run id **must** be in\nthe filename: the bridge sweeps `.vibe/team/*<run-id>*` after the run settles.\n\n### 3. Board (before any worker starts)\n\nCreate `.vibe/team/<run-id>-board.md` **before dispatch**. Minimum sections:\n\n1. **Goal** — one short paragraph\n2. **Frozen contract** — exact names everyone codes against\n3. **Ownership table** — one owner per file; you as integrator for wiring\n4. **Hard rules** — the worker rules below\n5. **Dispatch status** — brief path + status\n6. **Handoff** — empty section workers append to\n\nEvidence of boards that worked:\n`.vibe/team/appearance-0716-board.md`, `.vibe/team/settings-0716-1424-board.md`.\n\n### 4. Snapshot baselines\n\nBefore launch, note the pre-change state of every target file (git status / content\nsnapshot). You will review **diffs against this baseline**, not handoff prose.\n\n### 5. Dispatch\n\nLaunch workers as **background subprocesses** with disjoint ownership and auto-edit\npermissions. Wait on process exit (shell-level — cheap). Re-engage only when a\nworker finishes or fails to start.\n\n### 6. Diff-review (mandatory)\n\n**Never trust a worker's handoff text.**\n\nFor each worker:\n\n1. Read the actual diff vs baseline.\n2. Check: owned files only? frozen names? additive? acceptance met?\n3. Check **integration semantics, not just the diff text**: how does the new code\n   interact with the *running* system — existing connections, channels, caches,\n   subscriptions, lifecycles? (Real miss: a worker joined a Phoenix topic the app\n   already held; the duplicate join closed the live channel and the open chat went\n   silent. The diff alone looked clean.)\n4. Fix contract/scope violations yourself or re-dispatch once with the failed diff\n   attached. Cap retries at one blind re-run, then you finish the slice.\n\nagy **over-reports success**. Always treat its handoff as unverified until the diff\nand a build prove otherwise.\n\n### 7. Integrate\n\nWire shared surfaces workers were forbidden to touch. Keep public APIs stable.\n\n### 8. Verify once\n\nOne compile/build/test pass at the end (platform-appropriate: `mix compile`, web\nbuild, `xcodebuild`, etc.). Workers do not build or launch the app. Fix failures;\ndo not ship a broken tree.\n\n### 9. Complete\n\n- Update the board: status, what shipped, what deferred, open risks.\n- **Append one entry to `.vibe/memory.md`** (shared team memory — see that section)\n  so future runs know what this run shipped and learned.\n- Write a short settled summary for the user (shipped vs deferred).\n- Do **not** `git push` or deploy unless the user explicitly ordered it for this run.\n- **Clean up the run's working files.** The board and briefs under\n  `.vibe/team/<run>*` are scratch, not documentation: after the settled summary,\n  move anything durably valuable into real docs (or the final summary), then delete\n  this run's board and brief files. Do not leave dead run files accumulating.\n\n## Worker rules (put these in every brief)\n\n- Edit **only** owned files. Do not touch another worker's files, or integrator-owned\n  wiring, unless the brief says so.\n- Do **not** `git commit`, `push`, `checkout`, `reset`, or `stash`.\n- Do **not** run full product builds or launch apps (integrator verifies once).\n- **Additive only** — do not rename or remove existing public names.\n- Code against the **frozen contract names** exactly.\n- Do **not** call Fable / advisor tools; the lead is the reviewer.\n- No secrets or real keys in code or examples (placeholders only).\n\n## Routing\n\n| Worker | Assign | Never assign |\n|---|---|---|\n| **agy** | UI / low-risk / mechanical | auth, security, payments, migrations, shared server logic |\n| **grok** | production UI + documentation | — (still diff-verify) |\n| **codex** | production server, security-sensitive, multi-file Elixir | — |\n| **claude** | last resort only, when codex is rate-limited/unavailable | anything codex can take — the claude CLI burns the user's paid Claude usage |\n\nEscalate the hardest reasoning to the strongest model available **on the lead** (or\na single high-capability worker for one critical slice). Do not put high blast-radius\nwork on agy to save cost.\n\n## Shared team memory\n\n`.vibe/memory.md` at the repo root is the append-only journal every run reads and\nwrites — it is how all agents know what has already been done. The bridge points\nevery task at it and seeds it when missing.\n\n- **Read it during diagnosis.** It is prior-run ground truth: shipped features,\n  product-wide frozen contracts, traps other runs already paid for.\n- **Append exactly one entry at completion** (before deleting scratch), newest last:\n\n  ```markdown\n  ## <YYYY-MM-DD> · <run-id> · <one-line goal>\n  - Shipped: <files / contracts / behavior>\n  - Learned: <traps, platform semantics, review misses — the things a diff can't show>\n  - Open: <deferred items, known risks>\n  ```\n\n- Keep entries ≤ 10 lines. Never rewrite or delete existing entries. If the file\n  exceeds ~400 lines, fold the oldest entries into real docs first, then trim them.\n\n## Live worker status (VIBE_TEAM_STATUS)\n\nEvery time you **spawn**, run, or finish a worker subprocess, print **one status marker\nline to your own stdout** (not into a file). The bridge relays these lines; the server\nturns them into the live per-worker board the user sees on the phone (avatar + a live\nelapsed clock, \"Calling… · 0m 07s\" → \"editing X · 4m 12s\" → \"done · 4m 30s\"). No marker\n= a silent cell for the whole run.\n\nPrint the `spawn` line **immediately before you launch the CLI** — it stamps the\nworker's start so the phone's clock ticks from the real call moment, not from the first\ntool event:\n\n```\nVIBE_TEAM_STATUS {\"worker\":\"grok\",\"state\":\"spawn\",\"label\":\"call grok — premium UI polish\"}\nVIBE_TEAM_STATUS {\"worker\":\"grok\",\"state\":\"running\",\"label\":\"web: chat header\"}\nVIBE_TEAM_STATUS {\"worker\":\"grok\",\"state\":\"done\",\"label\":\"header + 3 files\"}\n```\n\nUse `\"state\":\"failed\"` when a worker errors or times out.\n\n**Rules:**\n\n- Exact prefix `VIBE_TEAM_STATUS ` (trailing space) + single-line valid JSON\n- One line per transition (spawn → `spawn`; working → `running`; exit → `done`/`failed`)\n- Print `spawn` right before the CLI launches; `running` once it is doing real work\n- `worker` = CLI handle: `codex` / `grok` / `agy` / `claude`\n- `label` ≤ 60 chars (what the slice is doing / what it shipped)\n\n## Safety\n\n- Destructive commands are blocked by the **bridge permission layer**, not by prompt\n  discipline alone. Still: never instruct workers to force-push, reset hard, or\n  deploy.\n- Never `git push` / production deploy as lead unless the user explicitly asked in\n  this run.\n- Never bake project-external product vocabulary into Vibe core types or public APIs.\n- Prefer existing architecture, names, and UI patterns.\n\n## Worker CLI forms\n\nUse these exact forms (fill repo path, effort, brief content):\n\n### codex\n\n```bash\ncodex exec --json \\\n  -c sandbox_mode=\"workspace-write\" \\\n  -c approval_policy=\"never\" \\\n  -c model_reasoning_effort=\"<e>\" \\\n  --cd <repo> \\\n  --skip-git-repo-check \\\n  \"<prompt>\"\n```\n\nPrefer putting the full brief in the prompt (or a file the prompt tells codex to\nread). Effort: `low` / `medium` / `high` by risk.\n\n### grok\n\n```bash\n~/.grok/bin/grok \\\n  --prompt-file <brief> \\\n  --always-approve \\\n  --max-turns 80 \\\n  --output-format plain \\\n  --cwd <repo>\n```\n\nTwo verified headless failure modes — both exit 0 with **no files written**:\n`--permission-mode acceptEdits` is silently ignored headless (grok narrates the write\nbut drops the tool call), so `--always-approve` is required; and the default\n`--max-turns` is low enough that workers get cut off after recon, so always pass it\nexplicitly. If a grok run exits without a diff, probe first: ask it to write one\ntrivial file and check the file exists — trust the filesystem, not the narration or\nexit code.\n\n### agy\n\n```bash\n~/.local/bin/agy -p \"Read and execute the brief at <brief path>. Work from <repo>.\" \\\n  --mode accept-edits \\\n  --dangerously-skip-permissions \\\n  --print-timeout 30m\n```\n\nUI / low-risk briefs only (see Routing). Same ownership and no-commit/no-build rules\nas other workers. Run it with the repo as working directory.\n\n## Simple work\n\nIf the request does not need multi-agent coordination, do not force a team. A single\nworker (or you alone) is correct. The bridge may also dispatch simple work without\nspawning a lead — respect that when you are not on a team run.\n\n## Completion checklist\n\n- [ ] Board exists with frozen contract + ownership before dispatch\n- [ ] Every worker brief has disjoint files + hard rules + no-Fable\n- [ ] Every worker diff reviewed against baseline\n- [ ] Integrator wiring done\n- [ ] One verify pass green (or failures fixed)\n- [ ] Board updated; settled summary written\n- [ ] One entry appended to `.vibe/memory.md` (shipped / learned / open)\n- [ ] Run's board + brief files cleaned up (durable learnings moved to docs first)\n- [ ] VIBE_TEAM_STATUS printed for every worker spawn/start/finish\n- [ ] No unauthorized push/deploy\n";

// Agent-native team orchestration: the team-lead operating guide is EMBEDDED below
// (TEAM_LEAD_GUIDE_FALLBACK) so every bridge install ships the team feature — no
// machine-local files required. The repo copy (agent-bridge/instructions/team-lead.md)
// is the editable source of truth and overrides the embedded copy when present;
// regenerate the embed after editing it (see scripts note beside the constant).
try {
  const teamLeadGuidePath = path.join(__dirname, "..", "instructions", "team-lead.md");
  BRIDGE_INSTRUCTION_FILES["team-lead.md"] = fs.existsSync(teamLeadGuidePath)
    ? fs.readFileSync(teamLeadGuidePath, "utf8")
    : TEAM_LEAD_GUIDE_FALLBACK;
} catch (_) {
  BRIDGE_INSTRUCTION_FILES["team-lead.md"] = TEAM_LEAD_GUIDE_FALLBACK;
}

// Seed for the per-repo shared agent memory (.vibe/memory.md): an append-only
// journal every run reads before diagnosing and appends to when it settles, so
// all agents working a repo know what has already been done.
const TEAM_MEMORY_SEED = `# Shared agent memory (append-only journal)

One entry per settled run, newest last — what shipped, what was learned, what's open:

    ## <YYYY-MM-DD> · <run-id> · <one-line goal>
    - Shipped: …
    - Learned: …
    - Open: …

Read this before diagnosing. Append when you finish real work. Never rewrite or
delete existing entries. Keep entries ≤ 10 lines; when the file exceeds ~400 lines,
fold the oldest entries into real docs and trim them.
`;

// ~/.vibe/agent-config.toml → team_orchestration = "agent_native" switches @team runs
// to the agent-native lead (the lead CLI spawns worker CLIs itself, per
// docs/team-architecture.md); anything else keeps the legacy server-side fan-out.
// Read per call so config edits apply without a bridge restart.
function agentNativeTeamOrchestration() {
  try {
    const cfg = fs.readFileSync(path.join(os.homedir(), ".vibe", "agent-config.toml"), "utf8");
    const m = cfg.match(/^\s*team_orchestration\s*=\s*"([^"]+)"/m);
    return !!m && m[1].trim().toLowerCase() === "agent_native";
  } catch (_) {
    return false;
  }
}

function isTeamLeadTask(task) {
  if (!task) return false;
  if (!(task.teamRunId || task.team_run_id)) return false;
  const role = String(task.teamRole || task.team_role || "").toLowerCase();
  if (role && role !== "lead") return false;
  const mode = task.teamMode || task.team_mode;
  if (mode && mode !== "supervisor" && mode !== "group_supervisor") return false;
  return true;
}

function parseArgs(argv) {
  const out = { repos: [], repoRoots: [] };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--code") out.code = argv[++i];
    else if (a === "--server") out.server = argv[++i];
    else if (a === "--cwd") out.cwd = argv[++i];
    else if (a === "--repo") out.repos.push(argv[++i]);
    else if (a === "--repo-root") out.repoRoots.push(argv[++i]);
    else if (a === "--label") out.label = argv[++i];
    else if (a === "--logout") out.logout = true;
    else if (a === "--pair" || a === "--reconnect") out.pair = true;
    else if (a === "--pick") out.pick = true;
    else if (a === "--no-pick") out.noPick = true;
    else if (a === "--all") out.all = true;
    else if (a === "--install" || a === "--service") out.install = true;
    else if (a === "--uninstall") out.uninstall = true;
    else if (a === "--status") out.status = true;
    else if (a === "--foreground") out.foreground = true;
    else if (a === "--self-test") out.selfTest = true;
    else if (a === "--self-test-revert") out.selfTestRevert = true;
    else if (a === "--self-test-sequence") out.selfTestSequence = true;
    else if (a === "--provider") out.provider = argv[++i];
    else if (a === "--prompt") out.prompt = argv[++i];
    else if (a === "--rk") out.rk = argv[++i];
    else if (a === "--show-key") out.showKey = true;
    else if (a === "--work-mode") out.workMode = argv[++i];
    else if (a === "--service-run") out.serviceRun = true;
    else if (a === "-h" || a === "--help") out.help = true;
  }
  return out;
}

const ARGS = parseArgs(process.argv);
let ACTIVE_COMPUTER_ID = null;
let ACTIVE_COMPUTER_LABEL = null;

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  } catch (_) {
    return {};
  }
}

function saveConfig(obj) {
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(obj, null, 2), { mode: 0o600 });
}

function adoptComputerIdentity(identity, persist = false) {
  if (!identity || typeof identity !== "object") return;
  const computerId = String(identity.computerId || identity.computer_id || "").trim();
  const computerLabel = String(identity.computerLabel || identity.deviceLabel || identity.device_label || "").trim();
  if (computerId) ACTIVE_COMPUTER_ID = computerId;
  if (computerLabel) ACTIVE_COMPUTER_LABEL = computerLabel;
  if (!persist || !computerId) return;
  const config = loadConfig();
  if (config.computer_id === computerId && (!computerLabel || config.device_label === computerLabel)) return;
  config.computer_id = computerId;
  if (computerLabel) config.device_label = computerLabel;
  saveConfig(config);
}

function payloadTargetsThisComputer(payload, eventName) {
  const target = String((payload && (payload.computerId || payload.computer_id)) || "").trim();
  if (!target) return true; // Backwards-compatible server or LAN request.
  if (ACTIVE_COMPUTER_ID && target === ACTIVE_COMPUTER_ID) return true;
  console.log(
    `[vibe-bridge] ignored ${eventName || "request"} for computer=${target}; this computer=${ACTIVE_COMPUTER_ID || "unknown"}`
  );
  return false;
}

function computerFields() {
  return {
    ...(ACTIVE_COMPUTER_ID ? { computerId: ACTIVE_COMPUTER_ID } : {}),
    ...(ACTIVE_COMPUTER_LABEL ? { computerLabel: ACTIVE_COMPUTER_LABEL } : {}),
  };
}

// ── End-to-end runtime encryption (zero-knowledge server) ────────────
// The runtime payload (diffs, patches, file paths, command output) is the
// user's real source code. The Vibe server must never be able to read it. The
// bridge encrypts it with a 32-byte key (AES-256-GCM) shared ONLY with the
// phone, over the pairing QR — a phone↔desktop visual channel the server never
// sees. The server stores/relays the opaque ciphertext and cannot decrypt it.
// Matches the iOS reader: "arte1.<ivB64url>.<ctB64url>.<tagB64url>".
let RUNTIME_KEY_B64 = null;
const RUNTIME_BLOB_PREFIX = "arte1";

function isValidRuntimeKeyB64(b64) {
  try {
    return Buffer.from(String(b64 || ""), "base64").length === 32;
  } catch (_) {
    return false;
  }
}

// Establish the per-pairing runtime key. Priority: explicit --rk handed over by
// the phone's pairing QR, then the cached key, otherwise generate a fresh one.
function ensureRuntimeKey(config) {
  if (ARGS.rk && isValidRuntimeKeyB64(ARGS.rk)) {
    config.runtime_key = Buffer.from(ARGS.rk, "base64").toString("base64");
  }
  if (!isValidRuntimeKeyB64(config.runtime_key)) {
    config.runtime_key = crypto.randomBytes(32).toString("base64");
  }
  RUNTIME_KEY_B64 = config.runtime_key;
  return RUNTIME_KEY_B64;
}

function runtimeKeyQRPayload() {
  return `vibegram-rk:${RUNTIME_KEY_B64}`;
}

function encryptRuntimeBlob(obj) {
  if (!RUNTIME_KEY_B64) return null;
  try {
    const key = Buffer.from(RUNTIME_KEY_B64, "base64");
    if (key.length !== 32) return null;
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
    const pt = Buffer.from(JSON.stringify(obj), "utf8");
    const ct = Buffer.concat([cipher.update(pt), cipher.final()]);
    const tag = cipher.getAuthTag();
    const b = (buf) => buf.toString("base64url");
    return [RUNTIME_BLOB_PREFIX, b(iv), b(ct), b(tag)].join(".");
  } catch (err) {
    console.error("[vibe-bridge] runtime encrypt failed:", err.message);
    return null;
  }
}

// Decrypt an `arte1.<iv>.<ct>.<tag>` blob the phone sealed with the shared pairing
// key (e.g. an image attachment). Returns the parsed object, or null when there's no
// key, the envelope is malformed, or authentication fails.
function decryptRuntimeBlob(blob) {
  if (!RUNTIME_KEY_B64 || typeof blob !== "string") return null;
  const parts = blob.split(".");
  if (parts.length !== 4 || parts[0] !== RUNTIME_BLOB_PREFIX) return null;
  try {
    const key = Buffer.from(RUNTIME_KEY_B64, "base64");
    if (key.length !== 32) return null;
    const iv = Buffer.from(parts[1], "base64url");
    const ct = Buffer.from(parts[2], "base64url");
    const tag = Buffer.from(parts[3], "base64url");
    const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAuthTag(tag);
    const pt = Buffer.concat([decipher.update(ct), decipher.final()]);
    return JSON.parse(pt.toString("utf8"));
  } catch (err) {
    console.error("[vibe-bridge] attachment decrypt failed:", err.message);
    return null;
  }
}

// What to attach to a `result` push for the runtime payload. When a key is
// present we send ONLY the encrypted blob (plus a non-sensitive `canRevert`
// boolean the server/self-test need); the server never receives the plaintext
// diff. With no key we still send no plaintext — the card just stays hidden
// until the phone syncs the key.
function runtimeResultField(agentRuntime) {
  const canRevert = !!(agentRuntime && agentRuntime.controls && agentRuntime.controls.canRevert);
  const enc = encryptRuntimeBlob(agentRuntime);
  return enc ? { agentRuntimeEnc: enc, canRevert } : { canRevert };
}

function normalizeServer(url) {
  if (!url) return url;
  return url.replace(/\/+$/, "");
}

function splitEnvList(value) {
  return String(value || "")
    .split(/[,\n;]/)
    .map((part) => part.trim())
    .filter(Boolean);
}

function expandHome(value) {
  const raw = String(value || "").trim();
  if (!raw) return null;
  if (raw === "~") return os.homedir();
  if (raw.startsWith("~/")) return path.join(os.homedir(), raw.slice(2));
  return raw;
}

function realDir(value) {
  const expanded = expandHome(value);
  if (!expanded) return null;
  try {
    const resolved = fs.realpathSync(path.resolve(expanded));
    if (fs.statSync(resolved).isDirectory()) return resolved;
  } catch (_) {}
  return null;
}

function findGitRoot(dir) {
  let current = realDir(dir);
  while (current) {
    if (fs.existsSync(path.join(current, ".git"))) return current;
    const parent = path.dirname(current);
    if (!parent || parent === current) break;
    current = parent;
  }
  return realDir(dir);
}

function repoIdFor(cwd) {
  return crypto.createHash("sha256").update(cwd).digest("base64url").slice(0, 16);
}

function repoNameFor(cwd) {
  if (cwd === os.homedir()) return "~";
  return path.basename(cwd) || cwd;
}

function addRepository(map, dir, source) {
  const root = findGitRoot(dir);
  if (!root || map.has(root)) return;
  map.set(root, {
    id: repoIdFor(root),
    name: repoNameFor(root),
    path: root,
    cwd: root,
    source,
    git: fs.existsSync(path.join(root, ".git")),
  });
}

function bridgeInstructionRelativeFiles(provider, task) {
  const files = [path.join(BRIDGE_INSTRUCTION_DIR, "AGENTS.md")];
  // Agent-native team runs: the lead also loads the team-lead operating guide.
  if (task && isTeamLeadTask(task) && agentNativeTeamOrchestration()) {
    files.push(path.join(BRIDGE_INSTRUCTION_DIR, "team-lead.md"));
  }
  if (provider === "claude") files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CLAUDE.md"));
  else if (provider === "codex") files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CODEX.md"));
  else if (provider === "grok") files.push(path.join(BRIDGE_INSTRUCTION_DIR, "AGENTS.md"));
  else if (provider === "agy") files.push(path.join(BRIDGE_INSTRUCTION_DIR, "AGENTS.md"));
  else {
    files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CLAUDE.md"));
    files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CODEX.md"));
  }
  return files;
}

function ensureBridgeInstructionFiles(repo) {
  const root = repo && (repo.cwd || repo.path);
  if (!root) return [];

  const dir = path.join(root, BRIDGE_INSTRUCTION_DIR);
  const written = [];

  try {
    fs.mkdirSync(dir, { recursive: true });
    ensureBridgeInstructionGitExclude(root);

    for (const [name, content] of Object.entries(BRIDGE_INSTRUCTION_FILES)) {
      const absolutePath = path.join(dir, name);
      // `name` may carry a subpath (e.g. "skills/premium-web-ui.md") — ensure its parent.
      fs.mkdirSync(path.dirname(absolutePath), { recursive: true });
      if (!fs.existsSync(absolutePath) || fs.readFileSync(absolutePath, "utf8") !== content) {
        fs.writeFileSync(absolutePath, content, "utf8");
      }
      written.push({
        name,
        path: path.join(BRIDGE_INSTRUCTION_DIR, name),
        absolutePath,
      });
    }

    // Shared team memory: seed once, never overwrite — runs append entries to it
    // (see team-lead.md "Shared team memory"). Git-excluded like instructions.
    const memoryPath = path.join(root, ".vibe", "memory.md");
    if (!fs.existsSync(memoryPath)) {
      fs.writeFileSync(memoryPath, TEAM_MEMORY_SEED, "utf8");
    }
    ensureVibeGitExclude(root, ".vibe/memory.md");

    repo.instructionFiles = written;
    repo.instructionsReady = true;
    return written;
  } catch (err) {
    repo.instructionFiles = written;
    repo.instructionsReady = false;
    repo.instructionsError = err && err.message ? err.message : String(err);
    console.error(`[vibe-bridge] could not write instruction files for ${root}: ${repo.instructionsError}`);
    return written;
  }
}

function ensureVibeGitExclude(root, marker) {
  const gitDir = path.join(root, ".git");
  try {
    if (!fs.existsSync(gitDir) || !fs.statSync(gitDir).isDirectory()) return;
    const excludePath = path.join(gitDir, "info", "exclude");
    fs.mkdirSync(path.dirname(excludePath), { recursive: true });
    const current = fs.existsSync(excludePath) ? fs.readFileSync(excludePath, "utf8") : "";
    if (!current.split(/\r?\n/).some((line) => line.trim() === marker)) {
      fs.appendFileSync(excludePath, `${current.endsWith("\n") || current.length === 0 ? "" : "\n"}${marker}\n`);
    }
  } catch (_) {}
}

function ensureBridgeInstructionGitExclude(root) {
  ensureVibeGitExclude(root, ".vibe/instructions/");
}

function ensureBridgeInstructionsForRepositories(repositories) {
  for (const repo of repositories || []) ensureBridgeInstructionFiles(repo);
}

// The heavy "read AGENTS.md/CLAUDE.md + use the team handoff file" preamble is only
// appropriate for real engineering / team work — injecting it on every casual DM
// message made the agent eagerly go read the repo + team files for a plain "hi".
// Gate it: inject only for team runs or when the user explicitly @mentions an
// agent/team. A plain DM message gets just the user's prompt.
function taskWantsBridgeInstructions(task, prompt) {
  if (task) {
    // A `chat` team role is a conversation turn: read-only by construction and
    // told by the server prompt to never narrate instruction files. Prepending
    // "read and follow .vibe/instructions/AGENTS.md" here contradicted that
    // (agents replied "I'm reading AGENTS.md…") and wasted tokens on turns that
    // cannot act anyway.
    const teamRole = String(task.teamRole || task.team_role || "").toLowerCase();
    if (teamRole === "chat") return false;
    if (task.teamMode || task.team_mode || task.teamRunId || task.team_run_id) return true;
    if (Array.isArray(task.teamWorkers) && task.teamWorkers.length) return true;
    if (Array.isArray(task.teamWorker) && task.teamWorker.length) return true;
  }
  return /(^|\s)@(codex|claude|grok|agy|antigravity|team|vibe)\b/i.test(String(prompt || ""));
}

function taskPromptWithBridgeInstructions(provider, prompt, repo, task) {
  const cleaned = stripReservedMention(prompt, provider);
  const ready = ensureBridgeInstructionFiles(repo);
  const readyNames = new Set(ready.map((file) => file.path));
  const fileLines = bridgeInstructionRelativeFiles(provider, task)
    .map((file) => `- ${file}${readyNames.has(file) ? "" : " (write failed; follow inline rules instead)"}`)
    .join("\n");
  const memoryRoot = repo && (repo.cwd || repo.path);
  const memoryLine =
    memoryRoot && fs.existsSync(path.join(memoryRoot, ".vibe", "memory.md"))
      ? `\n- ${path.join(".vibe", "memory.md")} (shared memory: what previous runs shipped and learned — read it before diagnosing; append one settled entry when you finish real work)`
      : "";

  return `Vibe bridge startup prepared these instruction files for this project:
${fileLines}${memoryLine}

Before acting, read and follow those files when available. If they are unavailable, follow the same rules from the Vibe bridge prompt: inspect first, keep changes scoped, avoid duplicate teammate work, ask before risky commands, report files changed, verification, blockers, and remaining risk.

User task:
${cleaned}`;
}

// Top-level folders that are never code projects — skip them so a scan of the
// home folder reaches real repos instead of filling up on system junk.
const SKIP_DIRS = new Set([
  "Library",
  "Applications",
  "Music",
  "Movies",
  "Pictures",
  "Downloads",
  "Public",
  "node_modules",
  ".Trash",
]);

function scanRepoRoot(root, map) {
  const start = realDir(root);
  if (!start) return;
  const queue = [{ dir: start, depth: 0 }];
  const seen = new Set();
  while (queue.length && map.size < 80) {
    const { dir, depth } = queue.shift();
    if (seen.has(dir)) continue;
    seen.add(dir);
    if (fs.existsSync(path.join(dir, ".git"))) {
      addRepository(map, dir, "repo-root");
      continue;
    }
    if (depth >= 2) continue;
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      if (SKIP_DIRS.has(entry.name)) continue;
      queue.push({ dir: path.join(dir, entry.name), depth: depth + 1 });
    }
  }
}

// Common places people keep code — scanned (depth-limited) when the user runs an
// interactive pick and hasn't named repos explicitly.
function defaultDiscoveryRoots() {
  const home = os.homedir();
  return [
    process.cwd(),
    path.join(home, "Desktop"),
    path.join(home, "Developer"),
    path.join(home, "Projects"),
    path.join(home, "projects"),
    path.join(home, "Code"),
    path.join(home, "code"),
    path.join(home, "src"),
    path.join(home, "git"),
    path.join(home, "repos"),
    home,
  ].filter((dir) => realDir(dir));
}

function hasExplicitRepositorySelection() {
  return !!(
    ARGS.repos.length ||
    ARGS.repoRoots.length ||
    ARGS.cwd ||
    splitEnvList(process.env.VIBE_BRIDGE_REPOS).length ||
    splitEnvList(process.env.VIBE_BRIDGE_REPO_ROOTS).length
  );
}

function buildRepositories(extraRepos = []) {
  const map = new Map();

  // Repos the user picked interactively (or had cached) come first so they are
  // always advertised even if the daemon is launched from elsewhere.
  for (const repo of extraRepos) {
    addRepository(map, repo, "picked");
  }

  for (const repo of [
    ...ARGS.repos,
    ...splitEnvList(process.env.VIBE_BRIDGE_REPOS),
  ]) {
    addRepository(map, repo, "explicit");
  }

  for (const root of [
    ...ARGS.repoRoots,
    ...splitEnvList(process.env.VIBE_BRIDGE_REPO_ROOTS),
  ]) {
    scanRepoRoot(root, map);
  }

  // The current working tree is a sensible fallback only when nothing else was
  // chosen — otherwise we'd silently re-add e.g. the folder the daemon ran from.
  if (map.size === 0 && !hasExplicitRepositorySelection()) {
    const defaultCwd = realDir(ARGS.cwd || process.cwd()) || process.cwd();
    addRepository(map, defaultCwd, "cwd");
  }

  return Array.from(map.values()).sort((a, b) => a.name.localeCompare(b.name));
}

// ── Pairing ─────────────────────────────────────────────────────────

async function redeemPairing(server, code, label) {
  const res = await fetch(`${server}/api/agent-bridge/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairing_code: code, device_label: label || os.hostname() }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`pairing failed (${res.status}): ${body}`);
  }
  return res.json(); // { bridge_token, user_id }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function startPairRequest(server, label) {
  const res = await fetch(`${server}/api/agent-bridge/request`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_label: label || os.hostname() }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`could not start pairing (${res.status}): ${body}`);
  }
  return res.json(); // { request_id, device_secret, expires_in }
}

async function claimPairToken(server, requestId, deviceSecret) {
  const res = await fetch(`${server}/api/agent-bridge/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ request_id: requestId, device_secret: deviceSecret }),
  });
  if (res.status === 202) return null; // still pending — phone hasn't scanned yet
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`claim failed (${res.status}): ${body}`);
  }
  return res.json(); // { bridge_token, user_id }
}

function renderQR(payload) {
  try {
    require("qrcode-terminal").generate(payload, { small: true });
  } catch (_) {
    console.log("(Tip: `npm i qrcode-terminal` in this folder for a scannable QR.)");
  }
  console.log(`\n  manual code: ${payload}\n`);
}

// Desktop-shows-QR / phone-scans pairing (WhatsApp-Web style). The daemon holds
// a private device_secret; the QR only carries the public request_id, so anyone
// who merely sees the QR cannot claim the token.
async function scanToPair(server, label) {
  const { request_id, device_secret, expires_in } = await startPairRequest(server, label);
  console.log(
    "\n[vibe-bridge] In Vibe on your phone: open Claude or Codex → Connect → Scan, then scan this:\n"
  );
  // The QR carries the public request_id plus the end-to-end runtime key in the
  // fragment. The key never reaches the server (the phone authorizes by
  // request_id only); it travels phone-ward purely over this scanned QR.
  renderQR(`vibegram-pair:${request_id}#${RUNTIME_KEY_B64 || ""}`);
  console.log(`[vibe-bridge] Waiting for your phone to authorize (expires in ${expires_in}s)…`);

  const deadline = Date.now() + expires_in * 1000;
  while (Date.now() < deadline) {
    await sleep(2500);
    const result = await claimPairToken(server, request_id, device_secret);
    if (result && result.bridge_token) {
      process.stdout.write("\n[vibe-bridge] Auth is done — waiting for your computer...\n");
      return result;
    }
    process.stdout.write(".");
  }
  throw new Error("pairing timed out — re-run to get a fresh code");
}

// ── Running claude / codex ──────────────────────────────────────────

const sessionByChat = new Map(); // chatId -> claude session_id
// taskKey -> { child, provider, chatId, taskId, startedAt, frameSeq, lastAckedSeq, frameLog, lastProgress }
const runningTasks = new Map();

// Admission control (docs/team-architecture-v2.md §4 review amendments): one Mac
// executes every CLI run, and a team burst (lead + workers + a second group run)
// must queue instead of fork-bombing the machine. Queued tasks emit a periodic
// progress frame so the server-side run watchdog reads them as alive ("queued"),
// never as stalled — its stall timer only applies to genuinely running slices.
const MAX_CONCURRENT_CLI_TASKS = Math.max(
  1,
  Number(process.env.VIBE_MAX_CONCURRENT_TASKS || 6) || 6
);
const pendingTaskQueue = [];
let pendingTaskTimer = null;

function enqueuePendingTask(channel, task) {
  // Re-entry marker: the dedupe reservation was already taken on first delivery,
  // so the requeued pass must skip both the duplicate guard and admission.
  task.__requeued = true;
  pendingTaskQueue.push({ channel, task, queuedAt: Date.now() });
  console.log(
    `[vibe-bridge] task queued (${runningTasks.size} active, ${pendingTaskQueue.length} waiting) ` +
      `provider=${task.provider} task=${taskIdFor(task)}`
  );
  pushQueuedTaskHeartbeat({ channel, task });
  if (!pendingTaskTimer) {
    pendingTaskTimer = setInterval(() => {
      for (const entry of pendingTaskQueue) pushQueuedTaskHeartbeat(entry);
      drainPendingTasks();
    }, 45 * 1000);
  }
}

function pushQueuedTaskHeartbeat(entry) {
  const { channel, task } = entry;
  try {
    channel.push("progress", {
      ...computerFields(),
      ...teamFieldsForTask(task),
      provider: task.provider,
      chatId: task.chatId,
      taskId: taskIdFor(task),
      // Tagged so the server watchdog tracks queue age separately instead of
      // treating these frames as normal liveness forever (wedged-queue guard).
      queuedHeartbeat: true,
      line: JSON.stringify({
        type: "text",
        data: `Queued — waiting for a free agent slot (${runningTasks.size} running)`,
      }),
    });
  } catch (_) {}
}

function drainPendingTasks() {
  // Count released-but-not-yet-registered tasks against the cap: runningTasks
  // isn't populated until after the pre-run git snapshot, so a naive loop on
  // runningTasks.size alone would release the whole queue at once.
  let slots = MAX_CONCURRENT_CLI_TASKS - runningTasks.size;
  while (pendingTaskQueue.length && slots > 0) {
    slots--;
    const entry = pendingTaskQueue.shift();
    Promise.resolve(runTask(entry.channel, entry.task)).catch((err) =>
      console.warn("[vibe-bridge] queued task failed to start:", err && err.message)
    );
  }
  if (!pendingTaskQueue.length && pendingTaskTimer) {
    clearInterval(pendingTaskTimer);
    pendingTaskTimer = null;
  }
}
const finishedTasks = new Map(); // taskKey -> { provider, chatId, taskId, repo, runtime, finishedAt, resultPayload }
// Duplicate-delivery guard. The SAME run_task can reach runTask() more than once —
// it arrives on both the cloud channel and the LAN transport, and reconnect-recovery
// re-delivers tasks that completed while the socket was down (code 1006/1012). Because
// `runningTasks` isn't populated until AFTER the pre-run git snapshot (~300ms), two
// near-simultaneous deliveries both slip past it and spawn the CLI twice → duplicate
// "Worked" cards + corrupted before/after diff attribution. This map reserves the taskId
// SYNCHRONOUSLY at the very top of runTask (before any await), keyed by taskKey, and keeps
// the reservation for RUN_TASK_DEDUP_TTL_MS so a post-completion re-delivery is dropped too.
// A taskId maps 1:1 to a single sent message, so it never legitimately runs twice (a real
// re-run / edit carries a fresh taskId) — deduping on it is safe.
const recentRunTaskKeys = new Map(); // taskKey -> lastSeenMs
const RUN_TASK_DEDUP_TTL_MS = Number(process.env.VIBE_RUN_TASK_DEDUP_TTL_MS || 30 * 60 * 1000);
// Last structured subscription/rate-limit snapshot per provider (Codex primary/secondary
// windows from token_count events; Claude is still fetched live via OAuth). Used by
// buildUsageReport so the phone's usage banner works for every agent, not only Claude.
const lastRateLimitsByProvider = new Map(); // provider -> { at, buckets: [{label, utilization, resetsAt}] }
// Cap on unacked progress frames retained per running task for replay-on-reconnect.
// The server's own live-card reconstruction only ever looks at its last @max_stream_lines
// (160) lines, so keeping more than that here can never recover anything the server would
// actually use — 400 just gives headroom above that before the oldest unacked frame is
// dropped. In the steady (connected) state this stays near-empty: every push is pruned as
// soon as its ack arrives (see ackProgressFrame), so it only backs up during a real outage.
const MAX_PROGRESS_FRAME_LOG = 400;
// Resilience state for surviving a dropped socket (code=1006 idle/proxy, 1012 server
// restart) WITHOUT losing a turn. `socketDownSince` is the epoch ms of the drop (null
// while connected); on rejoin we re-deliver any result that completed during the outage
// (its one-shot push was lost) and re-establish history watches so the phone re-syncs
// instead of showing a stale "connected" / needing an app restart.
let socketDownSince = null;
const historyWatchSpecs = new Map(); // chatId -> { provider, sessionId, echo } (survives reconnect)
const noCurrentSessionLogAtByChat = new Map(); // chatId -> last log ms (throttle idle spam)

const modelBySession = new Map(); // provider:chatId -> model selected from mobile
const advisorBySession = new Map(); // provider:chatId -> advisor selected from mobile
const lastRuntimeBySession = new Map(); // provider:chatId -> last completed runtime payload
const capabilitiesByProvider = new Map(); // provider -> latest tools/slash/MCP metadata

const BRIDGE_COMMANDS = [
  "/commands",
  "/help",
  "/usage",
  "/skills",
  "/model [name|default]",
  "/advisor [fable|opus|off]",
  "/compact",
  "/status",
  "/doctor",
];

// Slash-command catalogs surfaced in the phone `/` palette and described by /help and
// /commands. `kind` records how the bridge handles each when sent from the phone:
//   bridge  — the bridge synthesizes real output locally (no agent turn, no token cost).
//   task    — passes through to the CLI and runs as a normal agent turn. PROVEN for
//             Claude: `claude -p` parses slash commands; skills/workflows/built-ins run,
//             and an interactive-only one returns a $0 "isn't available in this
//             environment" notice (so passthrough is safe).
//   option  — sets a run option for the NEXT send (model / effort / plan mode).
//   desktop — interactive-only in the terminal / desktop app. Codex slash commands are
//             ALL TUI-only: `codex exec` treats "/foo" as literal prompt text (verified),
//             so they cannot run headless from the phone — listed for discovery + handled
//             by the bridge where an equivalent exists.
// The authoritative live Claude list comes from each run's stream-json `init.slash_commands`
// (see providerMetadataFromOutput); these defaults seed the palette before the first run.
const CLAUDE_SLASH_INFO = [
  { name: "code-review", desc: "Review the current diff for bugs and cleanups", kind: "task" },
  { name: "simplify", desc: "Cleanup-only review; apply simplifications", kind: "task" },
  { name: "security-review", desc: "Scan pending changes for security issues", kind: "task" },
  { name: "review", desc: "Review a GitHub pull request", kind: "task" },
  { name: "batch", desc: "Split a large change into parallel units", kind: "task" },
  { name: "deep-research", desc: "Fan out web research into a cited report", kind: "task" },
  { name: "claude-api", desc: "Load Claude API reference for this project", kind: "task" },
  { name: "debug", desc: "Troubleshoot using the session debug log", kind: "task" },
  { name: "run", desc: "Launch and drive your app to see a change work", kind: "task" },
  { name: "verify", desc: "Build, run, and observe to confirm a change", kind: "task" },
  { name: "loop", desc: "Run a prompt repeatedly across iterations", kind: "task" },
  { name: "schedule", desc: "Create or run a scheduled cloud routine", kind: "task" },
  { name: "team-onboarding", desc: "Generate a team onboarding guide", kind: "task" },
  { name: "fewer-permission-prompts", desc: "Add a read-only allowlist to settings", kind: "task" },
  { name: "init", desc: "Generate a CLAUDE.md project guide", kind: "task" },
  { name: "insights", desc: "Analyze your recent Claude Code sessions", kind: "task" },
  { name: "goal", desc: "Keep working across turns until a goal is met", kind: "task" },
  { name: "context", desc: "Show context-window usage", kind: "task" },
  { name: "config", desc: "View or set a setting (key=value)", kind: "task" },
  { name: "skills", desc: "Browse and use skills", kind: "bridge" },
  { name: "clear", desc: "Start a fresh conversation (new task)", kind: "task" },
  { name: "compact", desc: "Summarize this conversation to free context", kind: "bridge" },
  { name: "usage", desc: "Plan limits + this chat's token/cost usage", kind: "bridge" },
  { name: "usage-credits", desc: "Configure extra usage credits", kind: "task" },
  { name: "status", desc: "Account, model, and remaining usage", kind: "bridge" },
  { name: "doctor", desc: "Diagnose the Claude Code install", kind: "bridge" },
  { name: "model", desc: "Show or switch the model", kind: "bridge" },
  { name: "advisor", desc: "Show or switch the advisor model", kind: "bridge" },
  { name: "plan", desc: "Plan mode: research & propose, don't edit", kind: "option" },
  { name: "help", desc: "List bridge, slash, and CLI commands", kind: "bridge" },
];

const CODEX_SLASH_INFO = [
  { name: "review", desc: "Ask Codex to review your working tree", kind: "desktop" },
  { name: "plan", desc: "Plan mode: research & propose, don't edit", kind: "option" },
  { name: "model", desc: "Show or switch the model", kind: "bridge" },
  { name: "approvals", desc: "Set what Codex can do without asking", kind: "desktop" },
  { name: "status", desc: "Account, model, and remaining usage", kind: "bridge" },
  { name: "usage", desc: "View account token usage", kind: "bridge" },
  { name: "diff", desc: "Show the working-tree git diff", kind: "desktop" },
  { name: "compact", desc: "Summarize the conversation to free tokens", kind: "bridge" },
  { name: "new", desc: "Start a new conversation", kind: "desktop" },
  { name: "clear", desc: "Clear and start a fresh chat", kind: "desktop" },
  { name: "init", desc: "Generate an AGENTS.md scaffold", kind: "desktop" },
  { name: "skills", desc: "Browse and use skills", kind: "desktop" },
  { name: "agent", desc: "Switch the active agent thread", kind: "desktop" },
  { name: "apps", desc: "Browse connectors and insert them", kind: "desktop" },
  { name: "plugins", desc: "Browse installed and discoverable plugins", kind: "desktop" },
  { name: "mcp", desc: "List configured MCP tools", kind: "desktop" },
  { name: "mention", desc: "Attach a file to the conversation", kind: "desktop" },
  { name: "fork", desc: "Fork the conversation into a new thread", kind: "desktop" },
  { name: "resume", desc: "Resume a saved conversation", kind: "desktop" },
  { name: "memories", desc: "Configure memory use and generation", kind: "desktop" },
  { name: "goal", desc: "Set or view a task goal", kind: "desktop" },
  { name: "fast", desc: "Toggle the Fast service tier", kind: "option" },
  { name: "personality", desc: "Choose a response communication style", kind: "desktop" },
  { name: "doctor", desc: "Diagnose the Codex install", kind: "bridge" },
  { name: "logout", desc: "Sign out of Codex", kind: "desktop" },
  { name: "help", desc: "List bridge, slash, and CLI commands", kind: "bridge" },
];

// Wire catalog sent to the phone palette: every command except the /help & /commands
// meta entries. Includes run-option (/plan, /fast) and bridge-answered ones so the
// palette is complete; iOS dedupes them against its built-in defaults.
const slashNamesFromInfo = (info) => info.filter((c) => c.name !== "help" && c.name !== "commands").map((c) => c.name);

const DEFAULT_CLAUDE_SLASH_COMMANDS = slashNamesFromInfo(CLAUDE_SLASH_INFO);
const DEFAULT_CODEX_SLASH_COMMANDS = slashNamesFromInfo(CODEX_SLASH_INFO);

// Terminal subcommands visible on this computer (display-only in /commands and /help).
const DEFAULT_CLAUDE_CLI_COMMANDS = [
  "agents",
  "config",
  "doctor",
  "mcp",
  "plugin",
  "update",
  "login",
  "logout",
];

const DEFAULT_CODEX_CLI_COMMANDS = [
  "exec",
  "review",
  "login",
  "logout",
  "mcp",
  "plugin",
  "doctor",
  "apply",
  "resume",
  "fork",
  "cloud",
  "sandbox",
  "update",
];

// name -> one-line description for the bridge-rendered /help and /commands text.
const CLAUDE_COMMAND_DESC = Object.fromEntries(CLAUDE_SLASH_INFO.map((c) => [c.name, c.desc]));
const CODEX_COMMAND_DESC = Object.fromEntries(CODEX_SLASH_INFO.map((c) => [c.name, c.desc]));
const CLAUDE_DESKTOP_ONLY = new Set(CLAUDE_SLASH_INFO.filter((c) => c.kind === "desktop").map((c) => c.name));
const CODEX_DESKTOP_ONLY = new Set(CODEX_SLASH_INFO.filter((c) => c.kind === "desktop").map((c) => c.name));

function stripReservedMention(prompt, provider) {
  return String(prompt || "")
    .replace(/(^|\s)@(codex|claude|grok|agy|antigravity)\b/ig, " ")
    .trim();
}

// Normalise the per-task permission level chosen on the phone into one mode.
// Accepts a range of aliases so older clients / env overrides keep working.
//   plan        — research & propose a plan, request approval before editing
//   ask         — live per-action approval routed to the phone
//   read_only   — analyse & propose, never change files
//   ask_auto    — safe automatic execution for noninteractive mobile runs (DEFAULT)
//   allow_edits — auto-approve edits + sandboxed command execution
//   full_access — no sandbox, run anything
//
// IMPORTANT: an UNSET mode now defaults to `ask_auto`, not `read_only`. The old
// read_only default silently mapped to claude `--permission-mode plan`, so every
// message ran propose-only ("always plan mode" bug). Plan is now an explicit,
// deliberately-chosen mode (see `plan` below) surfaced with a badge on the phone.
function workModeFor(task) {
  // HARD RULE, not overridable by the phone's work-mode setting: a `chat` turn is
  // the user TALKING, not commissioning work, so it runs with writes stripped
  // (codex → `read-only` sandbox; claude → Edit/Write/MultiEdit/NotebookEdit/Bash
  // disallowed). This is a control, not a request: prompt wording already proved
  // worthless — a worker asked "can you see this image?" read AGENTS.md, patched
  // page.tsx/globals.css and ran a full build. Enforcement lives HERE.
  const teamRole = task && (task.teamRole || task.team_role);
  if (String(teamRole || "").toLowerCase() === "chat") return "read_only";

  const raw = String(
    (task && (task.workMode || task.agentBridgeWorkMode || task.mode)) || "ask_auto"
  )
    .trim()
    .toLowerCase();
  if (
    ["full_access", "full", "danger", "danger-full-access", "bypass", "bypasspermissions"].includes(
      raw
    )
  ) {
    return "full_access";
  }
  if (["ask_auto", "ask-auto", "askauto", "auto_ask", "auto-ask"].includes(raw)) {
    return "ask_auto";
  }
  if (
    ["allow_edits", "auto", "edit", "edits", "write", "workspace-write", "accept_edits"].includes(
      raw
    )
  ) {
    return "allow_edits";
  }
  // Plan is explicit and distinct from read_only: it runs in claude plan
  // permission mode AND drives the plan-file → approval round-trip.
  if (["plan", "plan_mode", "plan-mode", "planmode"].includes(raw)) {
    return "plan";
  }
  if (["ask", "approve", "live", "prompt"].includes(raw)) {
    return "ask";
  }
  if (["read_only", "read-only", "readonly", "read", "propose"].includes(raw)) {
    return "read_only";
  }
  // Unknown / unset → safe-auto default.
  return "ask_auto";
}

// Resume is now EXPLICIT and per-message. The phone attaches a session/thread id
// only when the user picks "continue a session" in the input bar; absent that, every
// run starts a FRESH session (new task per message). The bridge no longer
// auto-resumes by chatId. `sessionByChat` is still captured below for /compact and
// result reporting, but it does NOT drive --resume anymore.
function resumeIdFor(task) {
  if (!task) return null;
  const raw =
    task.resumeSessionId ||
    task.agentBridgeResumeSessionId ||
    task.resumeThreadId ||
    task.agentBridgeResumeThreadId ||
    null;
  const trimmed = raw == null ? "" : String(raw).trim();
  return trimmed || null;
}

function claudePermissionMode(task) {
  if (process.env.VIBE_CLAUDE_PERMISSION_MODE) return process.env.VIBE_CLAUDE_PERMISSION_MODE;
  switch (workModeFor(task)) {
    case "full_access":
      return "bypassPermissions";
    case "ask_auto":
      return "auto";
    case "allow_edits":
      return "acceptEdits";
    case "plan":
      // Explicit plan mode: research & propose, then request approval via the
      // plan-file → ExitPlanMode round-trip (see runClaudeStreaming / askHub).
      return "plan";
    case "ask":
      // Live per-action approval routed to the phone via the permission-prompt
      // tool; manual mode can still call allowed MCP tools, unlike plan mode.
      return "manual";
    default:
      // read_only — inspect/propose only. Plan mode blocks MCP tools entirely, so
      // use manual mode and deny write/shell tools in claudeDisallowedTools().
      return "manual";
  }
}

function codexSandbox(task) {
  if (process.env.VIBE_CODEX_SANDBOX) return process.env.VIBE_CODEX_SANDBOX;
  switch (workModeFor(task)) {
    case "full_access":
      return "danger-full-access";
    case "ask_auto":
      return "workspace-write";
    case "allow_edits":
      return "workspace-write";
    default:
      return "read-only";
  }
}

function codexApprovalPolicy(task) {
  if (process.env.VIBE_CODEX_APPROVAL_POLICY) return process.env.VIBE_CODEX_APPROVAL_POLICY;
  switch (workModeFor(task)) {
    case "full_access":
    case "ask_auto":
    case "allow_edits":
      return "never";
    case "ask":
      return "on-request";
    default:
      return "untrusted";
  }
}

function agyPermissionMode(task) {
  // Agy uses --mode / --dangerously-skip-permissions (see agy-support.agyWorkModeFlags).
  return workModeFor(task);
}

function grokPermissionMode(task) {
  if (process.env.VIBE_GROK_PERMISSION_MODE) return process.env.VIBE_GROK_PERMISSION_MODE;
  switch (workModeFor(task)) {
    case "full_access":
      return "bypassPermissions";
    case "ask_auto":
      return "auto";
    case "allow_edits":
      return "acceptEdits";
    case "plan":
      return "plan";
    case "read_only":
      // Grok has no separate read-only sandbox; plan mode is its hard no-writes
      // gate. Without this case a `read_only` task (e.g. team role `chat`) fell
      // to "default" and Grok could still edit files.
      return "plan";
    case "ask":
      // No phone permission-prompt tool for Grok yet — default mode.
      return "default";
    default:
      return "default";
  }
}


const DEFAULT_CLAUDE_MOBILE_DISALLOWED_TOOLS = [
  "Bash(git push*)",
  "Bash(git checkout*)",
  "Bash(git reset*)",
  "Bash(git clean*)",
  "Bash(rm -rf*)",
  "Bash(rm -r*)",
  "Bash(sudo *)",
  "Bash(chmod -R*)",
  "Bash(chown -R*)",
  "Bash(security *)",
  "Bash(defaults write*)",
  "Bash(killall *)",
];

function claudeDisallowedTools(task) {
  const override = splitEnvList(process.env.VIBE_CLAUDE_DISALLOWED_TOOLS);
  // Full access means the user explicitly asked for bypass behavior. All other
  // mobile modes keep destructive commands on the ask/block side while Claude's
  // own `auto` classifier can run low-risk inspection/build commands.
  const base = override.length
    ? [...override]
    : workModeFor(task) === "full_access"
      ? []
      : [...DEFAULT_CLAUDE_MOBILE_DISALLOWED_TOOLS];
  if (!override.length && workModeFor(task) === "read_only") {
    for (const tool of ["Bash", "Edit", "MultiEdit", "Write", "NotebookEdit"]) {
      if (!base.includes(tool)) base.push(tool);
    }
  }
  // CRITICAL: the NATIVE AskUserQuestion tool has no answer channel in a bridge run
  // (no local TTY), so if the model calls it the run blocks FOREVER and nothing ever
  // reaches the phone. Disable it whenever our MCP ask is on so the model is forced
  // to use `mcp__vibeask__ask_user`, which relays to mobile and IS answerable.
  if (ASK_MCP_ENABLED && !base.includes("AskUserQuestion")) base.push("AskUserQuestion");
  return base;
}

// Commands a worker may run without an approval round-trip. A bridge run is
// headless: there is no TTY to answer a permission prompt, so anything NOT
// pre-approved here is effectively dead in `acceptEdits`/`auto` mode — which is
// why Claude workers kept stalling on tests and greps while Grok (auto) and
// Codex (sandbox, approval_policy=never) ran clean.
//
// The list is deliberately inspection + verification only. Nothing that mutates
// git history, escalates privilege, publishes, or deploys belongs here; those
// stay denied by DEFAULT_CLAUDE_MOBILE_DISALLOWED_TOOLS (deny wins over allow).
const SAFE_BASH_ALLOWLIST = [
  // Inspect
  "Bash(ls *)", "Bash(cat *)", "Bash(head *)", "Bash(tail *)", "Bash(wc *)",
  "Bash(file *)", "Bash(stat *)", "Bash(pwd)", "Bash(which *)", "Bash(echo *)",
  "Bash(tree *)", "Bash(du *)", "Bash(diff *)", "Bash(realpath *)",
  "Bash(basename *)", "Bash(dirname *)", "Bash(sed -n *)",
  // Search
  "Bash(grep *)", "Bash(rg *)", "Bash(find *)",
  // Git — read-only subcommands only (push/reset/checkout/clean stay denied)
  "Bash(git status*)", "Bash(git diff*)", "Bash(git log*)", "Bash(git show*)",
  "Bash(git branch*)", "Bash(git ls-files*)", "Bash(git blame*)",
  "Bash(git rev-parse*)", "Bash(git remote -v)",
  // Verify: build / test / lint / format
  "Bash(npm run build*)", "Bash(npm run test*)", "Bash(npm run lint*)",
  "Bash(npm run typecheck*)", "Bash(npm test*)", "Bash(npm ci)", "Bash(npm install*)",
  "Bash(yarn build*)", "Bash(yarn test*)", "Bash(pnpm build*)", "Bash(pnpm test*)",
  "Bash(mix test*)", "Bash(mix compile*)", "Bash(mix format*)", "Bash(mix deps.get)",
  "Bash(xcodebuild *)", "Bash(xcrun *)", "Bash(swift build*)", "Bash(swift test*)",
  "Bash(swiftformat *)", "Bash(pytest*)", "Bash(cargo build*)", "Bash(cargo test*)",
  "Bash(make *)", "Bash(node --check *)",
];

// Core file tools. Reading and editing must go through these, never through the
// terminal — see the "Terminal, Files, and Approvals" rules in AGENTS.md.
const SAFE_FILE_TOOLS = ["Read", "Edit", "MultiEdit", "Write", "Glob", "Grep", "LS", "TodoWrite"];

function claudeAllowedTools(task) {
  const mode = workModeFor(task);
  // read_only/plan deny Bash+writes outright; pre-approving them here would be
  // at best redundant and at worst a hole in the chat-turn write-strip.
  if (mode === "read_only" || mode === "plan") return [];
  const allowed = [...SAFE_BASH_ALLOWLIST, ...SAFE_FILE_TOOLS];
  if (mode === "ask") {
    // Live-approval mode still routes the interesting stuff to the phone; the
    // allow-list only spares the user an Approve sheet for `ls`.
    return allowed.filter((t) => !SAFE_FILE_TOOLS.includes(t));
  }
  return allowed;
}

function appendToolListArg(args, flag, values) {
  const list = compactStringList(values || [], 80);
  if (!list.length) return;
  args.push(flag, list.join(","));
}

function normalizeModel(provider, value) {
  const raw = value == null ? "" : String(value).trim();
  if (!raw) return null;
  const normalized = raw.toLowerCase().replace(/_/g, "-");
  if (provider === "claude") {
    // Production: pass exact Anthropic model ids through unchanged so picker
    // selections (claude-fable-5, tomorrow's alpha, …) reach `claude --model`.
    if (normalized.startsWith("claude-")) return raw;
    // Legacy short aliases still accepted from older phone builds / env defaults.
    if (normalized === "fable" || normalized.includes("fable")) return "claude-fable-5";
    if (normalized === "haiku" || normalized.includes("haiku-4-5")) return "claude-haiku-4-5-20251001";
    if (normalized === "sonnet" || (normalized.includes("sonnet-5") && !normalized.includes("sonnet-4"))) {
      return "claude-sonnet-5";
    }
    if (normalized === "opus" || normalized.includes("opus-4-8")) return "claude-opus-4-8";
    if (normalized.includes("sonnet")) return "claude-sonnet-5";
    if (normalized.includes("opus")) return "claude-opus-4-8";
    return raw;
  }
  if (provider === "codex" || provider === "gpt") {
    // The installed headless Codex CLI cannot execute the 5.6 family yet. It
    // returns a terminal 400 instead of falling back, which left mobile turns
    // with a failed tool card and no answer. Keep the mobile bridge on the
    // newest model this CLI accepts until its binary is updated.
    if (normalized === "gpt-5.6-sol" || normalized === "gpt-5-6-sol" || normalized === "gpt-5.6" || normalized === "gpt-5-6") {
      return "gpt-5.5";
    }
    if (normalized === "gpt-5.3-codex" || normalized === "gpt-5-3-codex") return "gpt-5.5";
    return raw;
  }
  // Grok / Agy: exact CLI selector strings (Agy effort is part of the name).
  return raw;
}

// ── Live model catalog (per provider) ────────────────────────────────
// Phone model pickers used to ship hardcoded lists that went stale (missing
// Claude Fable 5, old Codex ids, etc.). The bridge discovers models from the
// provider CLI / API on this machine and advertises them in bridge status so
// iOS/web refresh without an app release.
let providerModelsCache = { at: 0, models: null };
const PROVIDER_MODELS_TTL_MS = 5 * 60 * 1000;

// Seed catalogs are LAST RESORT only (offline / discovery failure). Live
// discovery is the production source of truth so new models (e.g. Fable 5,
// tomorrow's "alpha") appear without an app release.
const CLAUDE_EFFORTS_DEFAULT = ["low", "medium", "high", "xhigh", "max"];
const CODEX_EFFORTS_DEFAULT = ["low", "medium", "high", "xhigh"];
const GROK_EFFORTS_DEFAULT = ["low", "medium", "high"];

function fallbackProviderModels() {
  return {
    claude: [
      {
        id: "claude-haiku-4-5-20251001",
        title: "Claude Haiku 4.5",
        subtitle: "Seed fallback",
        isDefault: false,
        efforts: [],
        defaultEffort: null,
        source: "seed",
      },
      {
        id: "claude-sonnet-5",
        title: "Claude Sonnet 5",
        subtitle: "Seed fallback",
        isDefault: true,
        efforts: CLAUDE_EFFORTS_DEFAULT.slice(),
        defaultEffort: "high",
        source: "seed",
      },
      {
        id: "claude-opus-4-8",
        title: "Claude Opus 4.8",
        subtitle: "Seed fallback",
        isDefault: false,
        efforts: CLAUDE_EFFORTS_DEFAULT.slice(),
        defaultEffort: "high",
        source: "seed",
      },
      {
        id: "claude-fable-5",
        title: "Claude Fable 5",
        subtitle: "Seed fallback",
        isDefault: false,
        efforts: CLAUDE_EFFORTS_DEFAULT.slice(),
        defaultEffort: "high",
        source: "seed",
      },
    ],
    codex: [
      { id: "gpt-5.5", title: "GPT-5.5", subtitle: "Compatible with this Codex CLI", isDefault: true, efforts: CODEX_EFFORTS_DEFAULT.slice(), defaultEffort: "medium", source: "seed" },
      { id: "gpt-5.5-pro", title: "GPT-5.5 Pro", subtitle: "Seed fallback", isDefault: false, efforts: CODEX_EFFORTS_DEFAULT.slice(), defaultEffort: "high", source: "seed" },
      { id: "gpt-5.4", title: "GPT-5.4", subtitle: "Seed fallback", isDefault: false, efforts: CODEX_EFFORTS_DEFAULT.slice(), defaultEffort: "medium", source: "seed" },
      { id: "gpt-5.2", title: "GPT-5.2", subtitle: "Seed fallback", isDefault: false, efforts: CODEX_EFFORTS_DEFAULT.slice(), defaultEffort: "medium", source: "seed" },
      { id: "gpt-5", title: "GPT-5", subtitle: "Seed fallback", isDefault: false, efforts: CODEX_EFFORTS_DEFAULT.slice(), defaultEffort: "medium", source: "seed" },
    ],
    grok: [
      { id: "grok-4.5", title: "Grok 4.5", subtitle: "Seed fallback", isDefault: true, efforts: GROK_EFFORTS_DEFAULT.slice(), defaultEffort: "medium", source: "seed" },
      { id: "grok-composer-2.5-fast", title: "Composer 2.5 Fast", subtitle: "Seed fallback", isDefault: false, efforts: GROK_EFFORTS_DEFAULT.slice(), defaultEffort: "low", source: "seed" },
    ],
    agy: [
      // Agy bakes effort into the model label (High/Medium/Low); do not split.
      { id: "Gemini 3.1 Pro (High)", title: "Gemini 3.1 Pro (High)", subtitle: "Seed fallback", isDefault: true, efforts: [], defaultEffort: null, source: "seed" },
      { id: "Gemini 3.1 Pro (Low)", title: "Gemini 3.1 Pro (Low)", subtitle: "Seed fallback", isDefault: false, efforts: [], defaultEffort: null, source: "seed" },
      { id: "Gemini 3.5 Flash (High)", title: "Gemini 3.5 Flash (High)", subtitle: "Seed fallback", isDefault: false, efforts: [], defaultEffort: null, source: "seed" },
      { id: "Gemini 3.5 Flash (Medium)", title: "Gemini 3.5 Flash (Medium)", subtitle: "Seed fallback", isDefault: false, efforts: [], defaultEffort: null, source: "seed" },
      { id: "Gemini 3.5 Flash (Low)", title: "Gemini 3.5 Flash (Low)", subtitle: "Seed fallback", isDefault: false, efforts: [], defaultEffort: null, source: "seed" },
      { id: "Claude Sonnet 4.6 (Thinking)", title: "Claude Sonnet 4.6 (Thinking)", subtitle: "Seed fallback", isDefault: false, efforts: [], defaultEffort: null, source: "seed" },
      { id: "Claude Opus 4.6 (Thinking)", title: "Claude Opus 4.6 (Thinking)", subtitle: "Seed fallback", isDefault: false, efforts: [], defaultEffort: null, source: "seed" },
      { id: "GPT-OSS 120B (Medium)", title: "GPT-OSS 120B (Medium)", subtitle: "Seed fallback", isDefault: false, efforts: [], defaultEffort: null, source: "seed" },
    ],
  };
}

function effortLevelsFromClaudeCapabilities(caps) {
  const effort = caps && caps.effort;
  if (!effort || effort.supported === false) return [];
  const order = ["low", "medium", "high", "xhigh", "max"];
  const out = [];
  for (const key of order) {
    const row = effort[key];
    if (row && row.supported === true) out.push(key);
  }
  // If API only says effort.supported without per-level flags, expose full ladder.
  if (!out.length && effort.supported === true) return CLAUDE_EFFORTS_DEFAULT.slice();
  return out;
}

async function fetchClaudeModelsLive() {
  let token = null;
  try {
    const raw = execFileSync(
      "security",
      ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }
    );
    const parsed = JSON.parse(raw);
    token = parsed && parsed.claudeAiOauth && parsed.claudeAiOauth.accessToken;
  } catch (_) {
    token = null;
  }
  if (!token) return null;
  try {
    // Anthropic Models API — production source of truth (id + display_name + effort caps).
    // https://platform.claude.com/docs/en/api/models/list
    const res = await fetch("https://api.anthropic.com/v1/models?limit=1000", {
      headers: {
        Authorization: "Bearer " + token,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20",
      },
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const rows = Array.isArray(data && data.data) ? data.data : [];
    if (!rows.length) return null;
    // Newest first (API already roughly newest-first). Pass EVERY model through —
    // filtering would hide tomorrow's "alpha" the same way hardcoding did.
    return rows
      .map((m, i) => {
        const apiId = String((m && m.id) || "").trim();
        if (!apiId) return null;
        const title = String((m && m.display_name) || apiId).trim() || apiId;
        const efforts = effortLevelsFromClaudeCapabilities(m && m.capabilities);
        const isSonnet5 = apiId === "claude-sonnet-5" || /^claude-sonnet-5($|-)/.test(apiId);
        return {
          // EXACT provider id for --model / run_task — never invent short aliases here.
          id: apiId,
          title,
          subtitle: null,
          isDefault: isSonnet5 || (i === 0 && !rows.some((x) => String(x.id || "") === "claude-sonnet-5")),
          apiId,
          efforts,
          defaultEffort: efforts.includes("high")
            ? "high"
            : efforts.includes("medium")
              ? "medium"
              : efforts[0] || null,
          source: "live",
        };
      })
      .filter(Boolean);
  } catch (_) {
    return null;
  }
}

function fetchGrokModelsLive() {
  try {
    const out = execFileSync(process.env.VIBE_GROK_COMMAND || "grok", ["models"], {
      encoding: "utf8",
      timeout: 10000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const lines = String(out || "").split("\n");
    const models = [];
    let defaultId = null;
    for (const line of lines) {
      const star = line.match(/^\s*\*\s+(\S+)/);
      const dash = line.match(/^\s*-\s+(\S+)/);
      const m = star || dash;
      if (!m) continue;
      const id = m[1];
      if (star) defaultId = id;
      models.push({
        id,
        title: id,
        subtitle: star ? "Default" : null,
        isDefault: !!star,
        efforts: GROK_EFFORTS_DEFAULT.slice(),
        defaultEffort: "medium",
        source: "live",
      });
    }
    if (defaultId) {
      for (const m of models) m.isDefault = m.id === defaultId;
    }
    return models.length ? models : null;
  } catch (_) {
    return null;
  }
}

function fetchAgyModelsLive() {
  try {
    // `agy models` prints the exact selector strings the CLI accepts (effort is
    // part of the label: "Gemini 3.1 Pro (High)"). Keep id === full line.
    const out = execFileSync(process.env.VIBE_AGY_COMMAND || "agy", ["models"], {
      encoding: "utf8",
      timeout: 10000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const models = String(out || "")
      .split("\n")
      .map((l) => l.trim())
      .filter(Boolean)
      .map((id, i) => ({
        id,
        title: id,
        subtitle: null,
        isDefault: i === 0 || /3\.1 Pro \(High\)/i.test(id),
        // Effort is baked into the model name — do not expose a separate ladder.
        efforts: [],
        defaultEffort: null,
        source: "live",
      }));
    if (models.length) {
      const pref = models.find((m) => /3\.1 Pro \(High\)/i.test(m.id));
      if (pref) {
        for (const m of models) m.isDefault = m.id === pref.id;
      }
    }
    return models.length ? models : null;
  } catch (_) {
    return null;
  }
}

function fetchCodexModelsLive() {
  // No stable headless `codex models` yet. Prefer config.toml model + family seed;
  // always surface the machine's configured model first so local defaults win.
  const fallback = fallbackProviderModels().codex.map((row) => ({ ...row }));
  try {
    const cfgPath = path.join(os.homedir(), ".codex", "config.toml");
    if (!fs.existsSync(cfgPath)) return fallback;
    const text = fs.readFileSync(cfgPath, "utf8");
    const m = text.match(/^\s*model\s*=\s*"([^"]+)"/m);
    const effortMatch = text.match(/^\s*model_reasoning_effort\s*=\s*"([^"]+)"/m);
    const defaultEffort = (effortMatch && effortMatch[1].trim()) || "medium";
    if (!m) return fallback;
    const configured = m[1].trim();
    const current = normalizeModel("codex", configured);
    if (!current) return fallback;
    const list = fallback.slice();
    for (const row of list) {
      row.efforts = CODEX_EFFORTS_DEFAULT.slice();
      row.defaultEffort = defaultEffort;
      row.source = "live";
    }
    if (!list.some((x) => x.id === current)) {
      list.unshift({
        id: current,
        title: current,
        subtitle: "From Codex config",
        isDefault: true,
        efforts: CODEX_EFFORTS_DEFAULT.slice(),
        defaultEffort,
        source: "live",
      });
      for (let i = 1; i < list.length; i++) list[i].isDefault = false;
    } else {
      for (const row of list) row.isDefault = row.id === current;
    }
    return list;
  } catch (_) {
    return fallback;
  }
}

function preferLiveOrLastGood(live, seed, lastGood) {
  if (live && live.length) return live;
  if (lastGood && lastGood.length) {
    return lastGood.map((row) => ({ ...row, source: row.source === "live" ? "cache" : row.source || "cache" }));
  }
  return seed;
}

async function discoverProviderModels(force) {
  if (
    !force &&
    providerModelsCache.models &&
    Date.now() - providerModelsCache.at < PROVIDER_MODELS_TTL_MS
  ) {
    return providerModelsCache.models;
  }
  const base = fallbackProviderModels();
  const prev = (providerModelsCache && providerModelsCache.models) || null;
  try {
    const [claude, grok, agy] = await Promise.all([
      fetchClaudeModelsLive(),
      Promise.resolve(fetchGrokModelsLive()),
      Promise.resolve(fetchAgyModelsLive()),
    ]);
    const models = {
      claude: preferLiveOrLastGood(claude, base.claude, prev && prev.claude),
      codex: preferLiveOrLastGood(fetchCodexModelsLive(), base.codex, prev && prev.codex),
      grok: preferLiveOrLastGood(grok, base.grok, prev && prev.grok),
      agy: preferLiveOrLastGood(agy, base.agy, prev && prev.agy),
    };
    providerModelsCache = { at: Date.now(), models };
    return models;
  } catch (_) {
    const models = {
      claude: preferLiveOrLastGood(null, base.claude, prev && prev.claude),
      codex: preferLiveOrLastGood(null, base.codex, prev && prev.codex),
      grok: preferLiveOrLastGood(null, base.grok, prev && prev.grok),
      agy: preferLiveOrLastGood(null, base.agy, prev && prev.agy),
    };
    providerModelsCache = { at: Date.now(), models };
    return models;
  }
}

function normalizeAdvisor(provider, value) {
  // Claude CLI native advisors; Sol is a Fable-fallback alias (see advisorFor).
  if (provider !== "claude" && provider !== "codex") return null;
  const raw = value == null ? "" : String(value).trim();
  if (!raw) return null;
  const normalized = raw.toLowerCase().replace(/_/g, "-");
  if (["off", "none", "no", "false", "0", "default", "reset"].includes(normalized)) return null;
  if (normalized.includes("fable")) return "fable";
  if (normalized.includes("sol") || normalized.includes("gpt")) return "sol";
  if (normalized.includes("opus")) return "opus";
  if (normalized.includes("sonnet")) return "sonnet";
  // Gemini UI-only advisor is handled post-run for FE diffs (not a CLI --advisor flag).
  if (normalized.includes("gemini") || normalized === "agy-ui") return null;
  if (provider === "claude") return raw;
  return null;
}

function modelFor(provider, chatId, task) {
  const requested = task && (task.model || task.agentModel || task.agentBridgeModel);
  if (requested && String(requested).trim()) return normalizeModel(provider, requested);
  const stored = modelBySession.get(sessionKey(provider, chatId));
  if (stored && String(stored).trim()) return normalizeModel(provider, stored);
  const envModel =
    provider === "claude"
      ? process.env.VIBE_CLAUDE_MODEL
      : provider === "codex"
        ? process.env.VIBE_CODEX_MODEL
        : provider === "grok"
          ? process.env.VIBE_GROK_MODEL
          : provider === "agy"
            ? process.env.VIBE_AGY_MODEL
            : null;
  return envModel && String(envModel).trim() ? normalizeModel(provider, envModel) : null;
}

function advisorFor(provider, chatId, task) {
  // Team runs: Claude always prefers Fable; Sol is fallback when Fable is off/failed.
  const teamMode = task && (task.teamMode || task.team_mode);
  const isTeam =
    teamMode === "supervisor" ||
    teamMode === "group_supervisor" ||
    !!(task && (task.teamRunId || task.team_run_id));

  if (provider === "claude") {
    const requested = task && (task.advisor || task.agentAdvisor || task.agentBridgeAdvisor);
    if (requested != null && String(requested).trim()) {
      const norm = normalizeAdvisor(provider, requested);
      if (norm === "sol") return solAdvisorAvailable() ? null /* post-run sol */ : null;
      return norm;
    }
    const stored = advisorBySession.get(sessionKey(provider, chatId));
    if (stored != null && String(stored).trim()) {
      return normalizeAdvisor(provider, stored);
    }
    const envAdvisor = process.env.VIBE_CLAUDE_ADVISOR || process.env.VIBE_CLAUDE_ADVISOR_MODEL;
    if (envAdvisor && String(envAdvisor).trim()) {
      return normalizeAdvisor(provider, envAdvisor);
    }
    // Default for team / complex: Fable.
    if (isTeam || process.env.VIBE_FABLE_ALWAYS === "1") return "fable";
    return "fable";
  }
  return null;
}

// The GPT (Sol) fallback advisor now defaults to codex/GPT-5.6-Sol, so it is
// available out of the box (no VIBE_SOL_COMMAND needed) whenever the codex CLI is
// present. An explicit VIBE_SOL_COMMAND still overrides.
function solAdvisorAvailable() {
  return true;
}

function solAdvisorCommand() {
  return (
    process.env.VIBE_SOL_COMMAND ||
    process.env.VIBE_SOL_ADVISOR_COMMAND ||
    process.env.VIBE_GPT_ADVISOR_COMMAND ||
    null
  );
}

// Run GPT-5.6-Sol (via codex exec) as an advise-only pass and return its text.
// Parses codex --json (item.completed / agent_message). Returns "" on failure.
function runSolCodexAdvice(prompt, cwd) {
  try {
    const cmd = process.env.VIBE_CODEX_COMMAND || "codex";
    const model = process.env.VIBE_ADVISOR_CODEX_MODEL || "gpt-5.6-sol";
    const effort = process.env.VIBE_ADVISOR_CODEX_EFFORT || "xhigh";
    const result = spawnSync(
      cmd,
      ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check",
       "-m", model, "-c", `model_reasoning_effort="${effort}"`, prompt],
      { cwd, encoding: "utf8", timeout: 180000, env: process.env }
    );
    let answer = "";
    for (const ln of String(result.stdout || "").split("\n")) {
      const t = ln.trim();
      if (!t) continue;
      let obj = null;
      try { obj = JSON.parse(t); } catch (_) { continue; }
      const item = obj && obj.item ? obj.item : null;
      if (item && (item.type === "agent_message" || item.type === "assistant_message") &&
          typeof item.text === "string" && item.text.trim()) {
        answer = item.text.trim();
      }
    }
    return answer;
  } catch (_) {
    return "";
  }
}

/** Frontend/JSX/UI paths that should trigger Gemini (Agy) UI-only advice. */
function looksLikeFrontendDiff(agentRuntime) {
  const files =
    (agentRuntime &&
      agentRuntime.diff &&
      Array.isArray(agentRuntime.diff.files) &&
      agentRuntime.diff.files) ||
    [];
  const paths = files
    .map((f) => String((f && (f.path || f.name)) || "").toLowerCase())
    .filter(Boolean);
  const patch = String((agentRuntime && agentRuntime.diff && agentRuntime.diff.patch) || "");
  const joined = paths.join("\n") + "\n" + patch.slice(0, 8000);
  return (
    /\.(jsx|tsx|vue|svelte|css|scss|swiftui)\b/i.test(joined) ||
    /\b(return\s*\(|className=|style=\{\{|View\s*\{|SwiftUI)\b/.test(joined) ||
    /ios\/.*\.swift/i.test(joined)
  );
}

/**
 * After a worker finishes FE/UI work, run a short Gemini/Agy advise-only pass into the
 * handoff file. Never posts a chat bubble (advise-only, no tools preferred).
 */
async function maybeRunGeminiUiAdvisor(task, agentRuntime, outputText) {
  try {
    if (!looksLikeFrontendDiff(agentRuntime) && !/\.(jsx|tsx)\b/i.test(String(outputText || ""))) {
      return null;
    }
    const teamRunId = task.teamRunId || task.team_run_id;
    if (!teamRunId) return null;
    const cwd = (task.cwd || task.project || process.cwd()).toString();
    const handoff = path.join(cwd, ".vibe", "team", `${String(teamRunId).replace(/[^A-Za-z0-9_.-]+/g, "-")}.md`);
    const prompt =
      "You are a UI-only advisor (Gemini). Review the frontend/JSX/SwiftUI changes described " +
      "below. Advise on layout, accessibility, and visual polish only. Do not edit files. " +
      "Write a short bullet list under ## Gemini UI review.\n\n" +
      String(outputText || "").slice(0, 6000);
    const agyCmd = process.env.VIBE_AGY_COMMAND || "agy";
    const result = spawnSync(agyCmd, ["-p", prompt, "--dangerously-skip-permissions"], {
      cwd,
      encoding: "utf8",
      timeout: 120000,
      env: process.env,
    });
    const advice = String(result.stdout || result.stderr || "").trim().slice(0, 4000);
    if (!advice) return null;
    try {
      const fs = require("fs");
      fs.mkdirSync(path.dirname(handoff), { recursive: true });
      fs.appendFileSync(
        handoff,
        `\n\n## Gemini UI review (${new Date().toISOString()})\n${advice}\n`,
        "utf8"
      );
    } catch (_) {}
    return advice;
  } catch (err) {
    console.warn("[vibe-bridge] gemini UI advisor failed:", err && err.message);
    return null;
  }
}

/** Fable unavailable → optional Sol (GPT) advise-only pass into handoff. */
async function maybeRunSolAdvisorFallback(task, reason, contextText) {
  const cmd = solAdvisorCommand();
  try {
    const teamRunId = task.teamRunId || task.team_run_id;
    const cwd = (task.cwd || task.project || process.cwd()).toString();
    const handoff = teamRunId
      ? path.join(cwd, ".vibe", "team", `${String(teamRunId).replace(/[^A-Za-z0-9_.-]+/g, "-")}.md`)
      : null;
    const prompt =
      "You are Sol (GPT-5.6-Sol), fallback advisor after Fable failed. Brief advice only; no file edits.\n" +
      `Reason Fable unavailable: ${reason || "unknown"}\n\n` +
      String(contextText || "").slice(0, 5000);
    let advice = "";
    if (cmd) {
      // Explicit override command (plain stdout).
      const parts = cmd.split(/\s+/).filter(Boolean);
      const result = spawnSync(parts[0], [...parts.slice(1), prompt], {
        cwd,
        encoding: "utf8",
        timeout: 180000,
        env: process.env,
      });
      advice = String(result.stdout || result.stderr || "").trim().slice(0, 4000);
    } else {
      // Default: GPT-5.6-Sol via codex.
      advice = runSolCodexAdvice(prompt, cwd).slice(0, 4000);
    }
    if (advice) {
      console.log(`[vibe-bridge] Sol (GPT-5.6-Sol) advisor pass complete (${reason || "fable-unavailable"}).`);
    } else {
      console.log(`[vibe-bridge] Sol advisor returned nothing (${reason || "fable-unavailable"}); continuing.`);
    }
    if (handoff && advice) {
      try {
        const fs = require("fs");
        fs.mkdirSync(path.dirname(handoff), { recursive: true });
        fs.appendFileSync(
          handoff,
          `\n\n## Sol advisor fallback (${new Date().toISOString()})\n${advice}\n`,
          "utf8"
        );
      } catch (_) {}
    }
    return advice;
  } catch (err) {
    console.warn("[vibe-bridge] Sol advisor failed:", err && err.message);
    return null;
  }
}

function maybeDetectTeamSpawn(channel, task, line) {
  if (!task || !channel) return;
  const teamRunId = task.teamRunId || task.team_run_id;
  const role = task.teamRole || task.team_role;
  const teamMode = task.teamMode || task.team_mode;
  if (!teamRunId) return;
  // Agent-native orchestration: the lead spawns worker CLIs itself (see
  // .vibe/instructions/team-lead.md). Suppress the legacy server-side fan-out so
  // workers are never spawned twice for one run.
  if (agentNativeTeamOrchestration()) return;
  if (teamMode && teamMode !== "supervisor" && teamMode !== "group_supervisor") return;
  if (role && role !== "lead") return;
  const text = String(line || "");
  if (!/VIBE_TEAM_SPAWN\s*:/i.test(text)) return;
  const m = text.match(/VIBE_TEAM_SPAWN\s*:\s*([^\n\r]+)/i);
  if (!m) return;
  const workers = m[1]
    .split(/[,;\s]+/)
    .map((s) => s.trim().toLowerCase())
    .filter((s) => ["claude", "codex", "grok", "agy", "antigravity"].includes(s))
    .map((s) => (s === "antigravity" ? "agy" : s));
  if (!workers.length) return;
  const focus = {};
  const fm = text.match(/VIBE_TEAM_FOCUS\s*:\s*([^\n\r]+)/i);
  if (fm) {
    fm[1].split(/[;|]/).forEach((part) => {
      const [h, ...rest] = part.split("=");
      if (h && rest.length) focus[h.trim().toLowerCase()] = rest.join("=").trim();
    });
  }
  try {
    channel.push("team_spawn", {
      chatId: task.chatId || task.chat_id,
      teamRunId,
      workers,
      focusByHandle: focus,
      requesterUserId: task.requesterUserId || task.requester_user_id,
      leadWorker: task.leadWorker || task.lead_worker,
    });
    console.log(
      `[vibe-bridge] team_spawn run=${teamRunId} workers=${workers.join(",")} chat=${task.chatId}`
    );
  } catch (err) {
    console.warn("[vibe-bridge] team_spawn push failed:", err && err.message);
  }
}

function intelligenceFor(task) {
  const raw = String(
    (task && (task.intelligence || task.agentBridgeIntelligence || task.thinkingMode)) || "low"
  )
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (["extra_high", "xhigh", "extra", "max"].includes(raw)) return "extra_high";
  if (["high"].includes(raw)) return "high";
  if (["medium", "med", "standard"].includes(raw)) return "medium";
  return "low";
}

function speedFor(task) {
  const raw = String((task && (task.speed || task.agentBridgeSpeed || task.speedMode)) || "standard")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (["fast", "quick", "low_latency"].includes(raw)) return "fast";
  if (["careful", "thorough", "deep", "slow"].includes(raw)) return "careful";
  return "standard";
}

function requestedReasoningEffortFor(task) {
  const raw =
    task &&
    (task.reasoningEffort ||
      task.agentBridgeReasoningEffort ||
      task.effort ||
      task.agentBridgeEffort);
  if (!raw) return null;
  const normalized = String(raw).trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (["xhigh", "extra_high", "max"].includes(normalized)) return "xhigh";
  if (["high", "medium", "low"].includes(normalized)) return normalized;
  return null;
}

function reasoningEffortFor(provider, task) {
  const requested = requestedReasoningEffortFor(task);
  const ladder = provider === "claude" ? ["low", "medium", "high", "xhigh"] : ["low", "medium", "high"];
  if (requested) {
    if (ladder.includes(requested)) return requested;
    if (requested === "xhigh") return "high";
  }

  const intelligence = intelligenceFor(task);
  const speed = speedFor(task);
  const base =
    intelligence === "extra_high"
      ? provider === "claude"
        ? "xhigh"
        : "high"
      : intelligence;
  const baseIndex = Math.max(0, ladder.indexOf(base));
  const offset = speed === "fast" ? -1 : speed === "careful" ? 1 : 0;
  return ladder[Math.min(Math.max(baseIndex + offset, 0), ladder.length - 1)];
}

function buildCommand(provider, prompt, chatId, task) {
  const cleaned = stripReservedMention(prompt, provider);
  const model = modelFor(provider, chatId, task);
  const advisor = advisorFor(provider, chatId, task);
  if (provider === "claude") {
    const mode = claudePermissionMode(task);
    const effort = reasoningEffortFor(provider, task);
    // `--include-partial-messages` makes the CLI stream `thinking_delta` events as the
    // model reasons (the persisted JSONL only stores the block once complete), so the DM
    // can show a live-ticking "Thinking · N tokens" counter. The raw deltas are NOT
    // forwarded (they'd flood the server's whole-buffer reparse) — onChunk coalesces them
    // into a throttled `vibe_thinking` progress line (see thinkingState below).
    const args = ["-p", "--output-format", "stream-json", "--include-partial-messages", "--permission-mode", mode, "--effort", effort];
    appendToolListArg(args, "--disallowedTools", claudeDisallowedTools(task));
    // Pre-approve the safe inspection/verification commands. Without this a headless
    // run in acceptEdits mode has no way to answer a Bash permission prompt, so every
    // test/build/grep the task needs to verify itself silently dies.
    const allowedTools = claudeAllowedTools(task);
    if (ASK_MCP_ENABLED && askMcpConfigPath) {
      // Expose the ask_user + approve_command MCP tools and pre-allow them so the
      // mid-run question and command-approval round-trips never themselves trip a
      // (headless-unanswerable) permission prompt.
      allowedTools.push(ASK_TOOL_NAME, APPROVE_TOOL_NAME);
      if (FABLE_MCP_ENABLED) allowedTools.push(FABLE_TOOL_NAME);
      args.push("--mcp-config", askMcpConfigPath);
      // Live "ask" mode: route every other tool's permission request to the phone
      // via the approve_command permission-prompt tool (Approve/Skip/Deny sheet).
      if (workModeFor(task) === "ask") {
        args.push("--permission-prompt-tool", APPROVE_TOOL_NAME);
      }
    }
    appendToolListArg(args, "--allowedTools", allowedTools);
    const resumeId = resumeIdFor(task);
    if (resumeId) args.push("--resume", resumeId);
    args.push("--verbose");
    if (model) args.push("--model", model);
    // Fable is the primary Claude advisor; Sol is not a Claude --advisor flag.
    if (advisor && advisor !== "sol") args.push("--advisor", advisor);
    args.push("--", cleaned);
    return { cmd: process.env.VIBE_CLAUDE_COMMAND || "claude", args };
  }
  if (provider === "codex") {
    const sandbox = codexSandbox(task);
    const approvalPolicy = codexApprovalPolicy(task);
    const resumeId = resumeIdFor(task);
    const reasoning = reasoningEffortFor(provider, task);
    // `codex exec resume <thread-id>` continues a prior thread; a bare `codex exec`
    // starts fresh. The `resume` subcommand REJECTS the exec-only flags
    // `--sandbox`/`--model`/`--skip-git-repo-check` (its usage is
    // `codex exec resume --json <SESSION_ID> [PROMPT]`), so passing them on resume
    // failed with `error: unexpected argument '--sandbox'` (exit 2). Run config is
    // therefore passed via `-c` overrides, which are global options accepted on both
    // `codex exec` and `codex exec resume`. Options precede the positional
    // SESSION_ID/PROMPT so clap doesn't mistake them for positionals.
    const args = ["exec"];
    if (resumeId) args.push("resume");
    args.push("--json");
    args.push("-c", `sandbox_mode="${sandbox}"`);
    args.push("-c", `approval_policy="${approvalPolicy}"`);
    if (model) args.push("-c", `model="${model}"`);
    args.push("-c", `model_reasoning_effort="${reasoning}"`);
    if (!resumeId) {
      // Fresh runs only: --skip-git-repo-check is an exec-only flag the `resume`
      // subcommand rejects. We deliberately do NOT pass --ephemeral: an ephemeral
      // run persists NO rollout to disk, so a later `codex exec resume <thread>`
      // fails with "thread/resume failed: no rollout found for thread id … (-32600)".
      // That broke every Codex follow-up and history-resume (the adopt/resume flow
      // resumes the prior thread). Persisting the rollout is what makes resume work.
      args.push("--skip-git-repo-check");
    }
    if (resumeId) args.push(resumeId);
    args.push(cleaned);
    return { cmd: process.env.VIBE_CODEX_COMMAND || "codex", args };
  }

  if (provider === "grok") {
    const mode = grokPermissionMode(task);
    const effort = reasoningEffortFor(provider, task);
    const resumeId = resumeIdFor(task);
    // Headless: `grok -p <prompt> --output-format streaming-json`
    // emits thought/text/end NDJSON only — tools live in session updates.jsonl.
    // Fresh runs pin a session UUID so the bridge can tail tools live (see
    // startGrokUpdatesTail). Resume keeps the existing id via --resume.
    const assignedSessionId = resumeId || crypto.randomUUID();
    const args = ["-p", cleaned, "--output-format", "streaming-json", "--permission-mode", mode];
    if (effort) args.push("--reasoning-effort", effort);
    if (resumeId) {
      args.push("--resume", resumeId);
    } else {
      args.push("--session-id", assignedSessionId);
    }
    if (model) args.push("--model", model);
    if (mode === "bypassPermissions" || mode === "auto" || workModeFor(task) === "full_access") {
      args.push("--always-approve");
    }
    return {
      cmd: process.env.VIBE_GROK_COMMAND || "grok",
      args,
      sessionId: assignedSessionId,
    };
  }

  if (provider === "agy") {
    // Antigravity CLI (`agy`): plain stdout final answer; tools/thinking in
    // ~/.gemini/antigravity-cli/brain/<id>/…/transcript.jsonl (see agy-support).
    const resumeId = resumeIdFor(task);
    const args = agySupport.buildAgyArgs({
      prompt: cleaned,
      resumeId,
      model,
      workMode: workModeFor(task),
    });
    return {
      cmd: process.env.VIBE_AGY_COMMAND || "agy",
      args,
      sessionId: resumeId || null,
    };
  }
  return null;
}

// Assigned in main() once repos are resolved (possibly via an interactive pick).
let ADVERTISED_REPOSITORIES = [];
let DEFAULT_CWD = realDir(ARGS.cwd || process.cwd()) || process.cwd();

function repositoryById(id) {
  if (!id) return null;
  return ADVERTISED_REPOSITORIES.find((repo) => repo.id === id) || null;
}

function repositoryByPath(value) {
  const real = realDir(value);
  if (!real) return null;
  return ADVERTISED_REPOSITORIES.find((repo) => repo.cwd === real || repo.path === real) || null;
}

function defaultRepository() {
  return (
    repositoryByPath(DEFAULT_CWD) ||
    ADVERTISED_REPOSITORIES[0] || {
      id: repoIdFor(DEFAULT_CWD),
      name: repoNameFor(DEFAULT_CWD),
      path: DEFAULT_CWD,
      cwd: DEFAULT_CWD,
      source: "cwd",
      git: fs.existsSync(path.join(DEFAULT_CWD, ".git")),
    }
  );
}

function resolveTaskRepository(task) {
  const requestedId = task.repoId || task.repositoryId || task.agentBridgeRepoId;
  const requestedPath =
    task.cwd || task.repoPath || task.repositoryPath || task.agentBridgeCwd || task.agentBridgeRepoPath;

  if (requestedId) {
    const repo = repositoryById(String(requestedId));
    if (repo) return { ok: true, repo };
    return { ok: false, reason: "unknown repository id" };
  }

  if (requestedPath) {
    const repo = repositoryByPath(String(requestedPath));
    if (repo) return { ok: true, repo };
    return { ok: false, reason: "repository path is not allowed" };
  }

  return { ok: true, repo: defaultRepository() };
}

function taskIdFor(task) {
  const raw =
    task &&
    (task.taskId ||
      task.agentTaskId ||
      task.messageId ||
      task.replyToId ||
      task.id ||
      `${task.provider || "agent"}:${task.chatId || "chat"}:${Date.now()}`);
  return String(raw || crypto.randomUUID());
}

function taskKey(provider, chatId, taskId) {
  return `${provider || "agent"}:${chatId || "chat"}:${taskId || "-"}`;
}

// Push one progress frame for a running task, stamped with a per-task monotonic
// `sequence`. The frame is appended to the task's frame log and only pruned once the
// server acks it (see ackProgressFrame) — so if the socket drops before the ack lands,
// the frame is still sitting in the log for recoverAfterReconnect to replay. This is what
// makes reconnect repair a GAP in the middle of a run, not just resend the latest frame.
function pushProgressFrame(channel, key, payload) {
  const entry = runningTasks.get(key);
  const seq = entry ? ++entry.frameSeq : (payload.sequence ?? 0);
  const framed = {
    ...payload,
    sequence: seq,
    ...(ACTIVE_COMPUTER_ID ? { computerId: ACTIVE_COMPUTER_ID } : {}),
    ...(ACTIVE_COMPUTER_LABEL ? { computerLabel: ACTIVE_COMPUTER_LABEL } : {}),
  };
  if (entry) {
    entry.lastProgress = framed;
    entry.frameLog.push(framed);
    if (entry.frameLog.length > MAX_PROGRESS_FRAME_LOG) entry.frameLog.shift();
  }
  try {
    channel.push("progress", framed).receive("ok", () => ackProgressFrame(key, seq));
  } catch (_) {}
  // Mirror to any authenticated LAN clients so a co-located phone gets frames even when
  // the cloud socket is flapping. Cloud remains the ack source of truth for frameLog prune.
  fanoutLanEvent("progress", framed);
  return framed;
}

/** Fire-and-forget fanout to every authenticated LAN phone socket. */
function fanoutLanEvent(type, payload, excludedSocket) {
  if (!lanClients || lanClients.size === 0) return;
  const raw = JSON.stringify({ type, payload: payload == null ? {} : payload });
  for (const sock of lanClients) {
    try {
      if (excludedSocket && sock === excludedSocket) continue;
      if (sock.readyState === WebSocket.OPEN) sock.send(raw);
    } catch (_) {}
  }
}

// Server → bridge ack for a delivered progress frame. Prunes every frame up through
// `seq` from the log since the server has now folded it into its accumulated transcript —
// replaying it again later would duplicate that line in the live card.
function ackProgressFrame(key, seq) {
  const entry = runningTasks.get(key);
  if (!entry) return;
  if (seq > entry.lastAckedSeq) entry.lastAckedSeq = seq;
  while (entry.frameLog.length && entry.frameLog[0].sequence <= entry.lastAckedSeq) {
    entry.frameLog.shift();
  }
}

function sessionKey(provider, chatId) {
  return `${provider || "agent"}:${chatId || "chat"}`;
}

function taskLookupCandidates(provider, chatId, taskId, records) {
  const candidates = [];
  if (provider && chatId && taskId) candidates.push(taskKey(provider, chatId, taskId));
  if (provider && chatId) {
    for (const key of records.keys()) {
      if (key.startsWith(`${provider}:${chatId}:`)) candidates.push(key);
    }
  }
  return candidates;
}

function rememberFinishedTask(key, record) {
  finishedTasks.set(key, record);
  while (finishedTasks.size > 120) {
    const oldest = finishedTasks.keys().next().value;
    if (!oldest) break;
    finishedTasks.delete(oldest);
  }
}

// Synchronous duplicate-delivery guard for run_task. Returns true (→ caller should DROP the
// run) if this exact task was already seen within the TTL; otherwise records it and returns
// false. Called at the very top of runTask() before any await/spawn so a second delivery in a
// later tick sees the reservation even though `runningTasks` isn't set until after the git
// snapshot. See recentRunTaskKeys for why deduping on taskId is safe.
function isDuplicateRunTask(provider, chatId, taskId) {
  const key = taskKey(provider, chatId, taskId);
  const now = Date.now();
  // Opportunistic prune of expired reservations (keeps the map from growing unbounded).
  if (recentRunTaskKeys.size > 256) {
    for (const [k, ts] of recentRunTaskKeys) {
      if (now - ts > RUN_TASK_DEDUP_TTL_MS) recentRunTaskKeys.delete(k);
    }
  }
  const prev = recentRunTaskKeys.get(key);
  recentRunTaskKeys.set(key, now);
  return prev != null && now - prev < RUN_TASK_DEDUP_TTL_MS;
}

// Undo a reservation made by isDuplicateRunTask when the run never actually started
// (repo refused, unknown provider, spawn threw). Without this, a legit server
// re-delivery of the same task after a transient failure would be dropped for the
// whole TTL and the task would be silently lost.
function releaseRunTaskReservation(provider, chatId, taskId) {
  recentRunTaskKeys.delete(taskKey(provider, chatId, taskId));
}

function rememberRuntime(provider, chatId, runtime) {
  if (!provider || !chatId || !runtime) return;
  lastRuntimeBySession.set(sessionKey(provider, chatId), runtime);
  if (
    runtime.availableTools ||
    runtime.slashCommands ||
    runtime.mcpServers ||
    runtime.providerCommands
  ) {
    capabilitiesByProvider.set(provider, {
      availableTools: runtime.availableTools || [],
      slashCommands: runtime.slashCommands || [],
      mcpServers: runtime.mcpServers || [],
      providerCommands: runtime.providerCommands || [],
      cliCommands: runtime.cliCommands || [],
    });
  }
}

/** True when a CLI/error string is a subscription / rate-limit hit (not a code failure). */
function isUsageLimitText(text) {
  if (!text || typeof text !== "string") return false;
  const t = text.toLowerCase();
  return (
    /you'?ve hit your (usage|session) limit/.test(t) ||
    /hit your (usage|session) limit/.test(t) ||
    /usage limit/.test(t) ||
    /session limit/.test(t) ||
    /rate limit/.test(t) ||
    /quota (exceeded|exhausted)/.test(t) ||
    /reached your .*limit/.test(t) ||
    /out of (usage|credits|quota)/.test(t)
  );
}

/**
 * Capture Codex (and similar) rate_limits snapshots from stream lines into
 * lastRateLimitsByProvider. Codex token_count events carry:
 *   primary:  { used_percent, window_minutes: 300, resets_at (unix) }
 *   secondary:{ used_percent, window_minutes: 10080, resets_at }
 */
function captureRateLimitsFromLine(provider, line) {
  if (!provider || !line || typeof line !== "string") return;
  if (!line.includes("rate_limits") && !line.includes("used_percent")) return;
  let obj;
  try {
    obj = JSON.parse(line);
  } catch {
    return;
  }
  // Codex exec/stdout shapes: top-level rate_limits, payload.rate_limits, or
  // event_msg wrapper with payload.rate_limits.
  const rl =
    (obj && obj.rate_limits) ||
    (obj && obj.payload && obj.payload.rate_limits) ||
    (obj && obj.type === "token_count" && obj.rate_limits) ||
    null;
  if (!rl || typeof rl !== "object") return;

  const buckets = [];
  const addWindow = (label, win) => {
    if (!win || typeof win !== "object") return;
    const util = Number(win.used_percent ?? win.utilization ?? win.usedPercent);
    if (!Number.isFinite(util)) return;
    let resetsAt = null;
    const rawReset = win.resets_at ?? win.resetsAt ?? win.reset_at;
    if (typeof rawReset === "number" && Number.isFinite(rawReset)) {
      // Unix seconds → ISO
      resetsAt = new Date(rawReset * 1000).toISOString();
    } else if (typeof rawReset === "string" && rawReset) {
      resetsAt = rawReset;
    } else if (typeof win.resets_in_seconds === "number") {
      resetsAt = new Date(Date.now() + win.resets_in_seconds * 1000).toISOString();
    }
    // Label from the CLI's ACTUAL window, never a hardcoded assumption. Codex can
    // change or drop a window (e.g. it removed the 5-hour session) — if it stops
    // reporting `primary`, addWindow returns early above and no bucket is emitted, so
    // the phone never shows a window the CLI no longer enforces. The passed `label` is
    // only a last resort when the CLI omits window_minutes entirely.
    const minutes = Number(win.window_minutes ?? win.windowMinutes);
    let resolvedLabel;
    if (Number.isFinite(minutes) && minutes > 0) {
      if (minutes === 300) resolvedLabel = "5-hour limit";
      else if (minutes === 10080) resolvedLabel = "Weekly limit";
      else if (minutes % 1440 === 0) resolvedLabel = `${minutes / 1440}-day limit`;
      else if (minutes % 60 === 0) resolvedLabel = `${minutes / 60}-hour limit`;
      else resolvedLabel = `${minutes}-min limit`;
    } else {
      resolvedLabel = label || "Usage";
    }
    buckets.push({
      label: resolvedLabel,
      utilization: Math.round(util),
      resetsAt,
    });
  };

  // Pass null so the label is derived from each window's REAL window_minutes — see
  // addWindow. Do not assume primary=5h / secondary=weekly; the CLI is the source of
  // truth for which windows exist and how long they are.
  addWindow(null, rl.primary);
  addWindow(null, rl.secondary);
  // Some shapes nest under limit windows array
  if (Array.isArray(rl.windows)) {
    for (const w of rl.windows) addWindow(null, w);
  }
  if (buckets.length === 0) return;
  lastRateLimitsByProvider.set(provider, { at: Date.now(), buckets });
}

/** Parse a free-text limit message for a rough resetsAt ISO (e.g. "resets in 3h 12m"). */
function parseResetHintFromText(text) {
  if (!text || typeof text !== "string") return null;
  const m = text.match(/resets?\s+(?:in\s+)?(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?/i);
  if (!m) return null;
  const d = Number(m[1] || 0);
  const h = Number(m[2] || 0);
  const min = Number(m[3] || 0);
  if (!d && !h && !min) return null;
  return new Date(Date.now() + ((d * 24 + h) * 60 + min) * 60 * 1000).toISOString();
}

/**
 * When a run fails with a usage/session limit, remember a 100% bucket so the phone
 * can show the usage banner even without a live rate_limits snapshot.
 */
function rememberUsageLimitHit(provider, message) {
  if (!provider || !isUsageLimitText(message)) return false;
  const existing = lastRateLimitsByProvider.get(provider);
  const resetsAt = parseResetHintFromText(message);
  const buckets =
    existing && Array.isArray(existing.buckets) && existing.buckets.length
      ? existing.buckets.map((b) => ({
          ...b,
          utilization: Math.max(100, Number(b.utilization) || 0),
          resetsAt: b.resetsAt || resetsAt,
        }))
      // No real window was ever reported — emit a GENERIC limit marker, not a fake
      // "5-hour" window the CLI never sent. resetsAt stays whatever the limit text
      // actually parsed (may be null); we never invent a reset time.
      : [{ label: "Usage limit", utilization: 100, resetsAt }];
  lastRateLimitsByProvider.set(provider, { at: Date.now(), buckets, hit: true, message: String(message || "").slice(0, 400) });
  return true;
}

function runGit(cwd, args, maxBytes = MAX_DIFF_BYTES) {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      timeout: 10_000,
      maxBuffer: maxBytes + 4096,
      stdio: ["ignore", "pipe", "ignore"],
    }).slice(0, maxBytes);
  } catch (_) {
    return "";
  }
}

function parseNameStatus(text) {
  const statuses = new Map();
  for (const line of String(text || "").split("\n")) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    const status = parts[0] || "";
    const file = parts[parts.length - 1] || "";
    if (file) statuses.set(file, status);
  }
  return statuses;
}

function parseNumstat(text, statuses) {
  const files = [];
  let added = 0;
  let removed = 0;
  for (const line of String(text || "").split("\n")) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    if (parts.length < 3) continue;
    const add = parseInt(parts[0], 10);
    const del = parseInt(parts[1], 10);
    const file = parts.slice(2).join("\t");
    const additions = Number.isFinite(add) ? add : 0;
    const deletions = Number.isFinite(del) ? del : 0;
    added += additions;
    removed += deletions;
    files.push({
      path: file,
      name: path.basename(file),
      status: statuses.get(file) || "M",
      additions,
      deletions,
    });
  }
  return { files, added, removed };
}

function untrackedFiles(cwd, existingPaths) {
  const output = runGit(cwd, ["ls-files", "--others", "--exclude-standard"], 64 * 1024);
  const files = [];
  for (const file of output.split("\n").map((line) => line.trim()).filter(Boolean)) {
    if (existingPaths.has(file)) continue;
    const absolute = path.join(cwd, file);
    let additions = 0;
    try {
      const stat = fs.statSync(absolute);
      if (stat.isFile() && stat.size <= MAX_UNTRACKED_FILE_BYTES) {
        const content = fs.readFileSync(absolute, "utf8");
        additions = content.trimEnd() ? content.trimEnd().split("\n").length : 0;
      }
    } catch (_) {
      additions = 0;
    }
    files.push({
      path: file,
      name: path.basename(file),
      status: "A?",
      additions,
      deletions: 0,
    });
  }
  return files;
}

function diffFilePath(file) {
  return String(file || "").replace(/[\r\n]/g, "");
}

function untrackedPatch(cwd, files, maxBytes) {
  const chunks = [];
  let used = 0;
  let truncated = false;

  for (const file of files) {
    if (used >= maxBytes) {
      truncated = true;
      break;
    }

    const relativePath = diffFilePath(file.path);
    if (!relativePath) continue;

    const absolute = path.join(cwd, relativePath);
    let content;
    try {
      const stat = fs.statSync(absolute);
      if (!stat.isFile() || stat.size > MAX_UNTRACKED_FILE_BYTES) continue;
      const raw = fs.readFileSync(absolute);
      if (raw.includes(0)) continue;
      content = raw.toString("utf8");
    } catch (_) {
      continue;
    }

    const normalized = content.endsWith("\n") ? content.slice(0, -1) : content;
    const lines = normalized.length ? normalized.split("\n") : [];
    const header =
      `diff --git a/${relativePath} b/${relativePath}\n` +
      "new file mode 100644\n" +
      "index 0000000..0000000\n" +
      "--- /dev/null\n" +
      `+++ b/${relativePath}\n` +
      `@@ -0,0 +1,${lines.length} @@\n`;
    const body = lines.map((line) => `+${line}`).join("\n") + (lines.length ? "\n" : "");
    const chunk = header + body;
    const remaining = maxBytes - used;

    if (chunk.length > remaining) {
      chunks.push(chunk.slice(0, remaining));
      used = maxBytes;
      truncated = true;
      break;
    }

    chunks.push(chunk);
    used += chunk.length;
  }

  return { patch: chunks.join(""), truncated };
}

function gitSnapshot(cwd) {
  const inside = runGit(cwd, ["rev-parse", "--is-inside-work-tree"], 128).trim() === "true";
  if (!inside) return { git: false, dirty: false, files: [], additions: 0, deletions: 0, patch: "" };

  const statusText = runGit(cwd, ["status", "--porcelain=v1"], 64 * 1024);
  const statuses = parseNameStatus(runGit(cwd, ["diff", "--name-status", "HEAD", "--"], 64 * 1024));
  const parsed = parseNumstat(runGit(cwd, ["diff", "--numstat", "HEAD", "--"], 64 * 1024), statuses);
  const existingPaths = new Set(parsed.files.map((file) => file.path));
  const untracked = untrackedFiles(cwd, existingPaths);
  const files = [...parsed.files, ...untracked]
    .sort((a, b) => (b.additions + b.deletions) - (a.additions + a.deletions))
    .slice(0, MAX_DIFF_FILES);
  const additions = files.reduce((sum, file) => sum + (file.additions || 0), 0);
  const deletions = files.reduce((sum, file) => sum + (file.deletions || 0), 0);
  const trackedPatch = runGit(
    cwd,
    ["diff", "--no-ext-diff", "--unified=80", "HEAD", "--"],
    MAX_DIFF_BYTES
  );
  const remainingPatchBytes = Math.max(0, MAX_DIFF_BYTES - trackedPatch.length);
  const newFilePatch = untrackedPatch(
    cwd,
    files.filter((file) => file.status === "A?"),
    remainingPatchBytes
  );
  const patch = trackedPatch + newFilePatch.patch;

  return {
    git: true,
    dirty: statusText.trim().length > 0,
    statusCount: statusText.split("\n").filter((line) => line.trim()).length,
    files,
    additions,
    deletions,
    patch,
    patchTruncated: patch.length >= MAX_DIFF_BYTES || newFilePatch.truncated,
  };
}

function compactCommand(cmd, args) {
  return [cmd, ...(args || [])].join(" ").replace(/\s+/g, " ").slice(0, 1200);
}

function decodedOutputEvents(output) {
  const events = [];
  for (const line of String(output || "").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || !trimmed.startsWith("{") && !trimmed.startsWith("[")) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (Array.isArray(parsed)) {
        for (const item of parsed) {
          if (item && typeof item === "object") events.push(item);
        }
      } else if (parsed && typeof parsed === "object") {
        events.push(parsed);
      }
    } catch (_) {}
  }
  return events;
}

// Some provider CLIs can exit 0 after emitting a terminal failure frame. In
// particular Grok has returned `{type:"end", stopReason:"Cancelled"}` on a
// timed-out turn. Treating that as success advances the team to the next owner
// with a missing handoff. Normalize those semantic failures before constructing
// the final bridge result.
function providerTerminalFailure(provider, output) {
  const events = decodedOutputEvents(output);
  const normalizedProvider = String(provider || "").trim().toLowerCase();
  let codexCompleted = false;
  let codexItemError = null;

  for (const event of events) {
    const type = String(event.type || event.event || "").trim().toLowerCase();
    const subtype = String(event.subtype || "").trim().toLowerCase();
    const stopReason = String(
      event.stopReason || event.stop_reason || event.terminal_reason || ""
    ).trim().toLowerCase();
    const status = String(event.status || "").trim().toLowerCase();

    if (normalizedProvider === "codex" && type === "turn.completed") {
      codexCompleted = true;
    }
    if (
      normalizedProvider === "codex" &&
      type === "item.completed" &&
      event.item &&
      String(event.item.type || "").toLowerCase() === "error"
    ) {
      codexItemError = String(event.item.message || "codex_item_error");
    }

    if ([stopReason, status].some((value) =>
      ["cancel", "cancelled", "canceled", "stopped", "timed_out", "timeout"].includes(value)
    )) {
      return { failed: true, canceled: true, reason: stopReason || status };
    }

    if (
      type === "turn.failed" ||
      type === "turn_failed" ||
      type === "fatal" ||
      (type === "result" && (event.is_error === true || ["error", "failed"].includes(subtype)))
    ) {
      return { failed: true, canceled: false, reason: subtype || type };
    }

    // Provider-level error frames are terminal. Tool-result errors are nested
    // under other event types and remain ordinary agent observations.
    if (type === "error" && normalizedProvider !== "claude") {
      return { failed: true, canceled: false, reason: "provider_error" };
    }
  }

  if (normalizedProvider === "codex" && !codexCompleted && codexItemError) {
    return { failed: true, canceled: false, reason: codexItemError };
  }

  return null;
}

function compactStringList(value, limit = 40) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => String(item || "").trim())
    .filter(Boolean)
    .filter((item, index, arr) => arr.indexOf(item) === index)
    .slice(0, limit);
}

function compactMcpServers(value) {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item) => item && typeof item === "object")
    .map((server) => ({
      name: String(server.name || "").trim(),
      status: String(server.status || "").trim(),
    }))
    .filter((server) => server.name)
    .slice(0, 20);
}

function numberValue(...values) {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim()) {
      const parsed = Number(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return undefined;
}

function compactUsage(raw, event) {
  if (!raw || typeof raw !== "object") return null;
  const usage = {
    inputTokens: numberValue(raw.input_tokens, raw.inputTokens),
    cachedInputTokens: numberValue(raw.cached_input_tokens, raw.cache_read_input_tokens, raw.cachedInputTokens, raw.cacheReadInputTokens),
    cacheCreationInputTokens: numberValue(raw.cache_creation_input_tokens, raw.cacheCreationInputTokens),
    outputTokens: numberValue(raw.output_tokens, raw.outputTokens),
    reasoningOutputTokens: numberValue(raw.reasoning_output_tokens, raw.reasoningOutputTokens),
    totalCostUsd: numberValue(raw.total_cost_usd, raw.costUSD, raw.costUsd, event && event.total_cost_usd),
    durationMs: numberValue(event && event.duration_ms),
    durationApiMs: numberValue(event && event.duration_api_ms),
    ttftMs: numberValue(event && event.ttft_ms),
    ttftStreamMs: numberValue(event && event.ttft_stream_ms),
    numTurns: numberValue(event && event.num_turns),
  };
  for (const key of Object.keys(usage)) {
    if (usage[key] === undefined) delete usage[key];
  }
  return Object.keys(usage).length ? usage : null;
}

function providerCommandCatalog(provider, metadata = {}) {
  return {
    bridge: BRIDGE_COMMANDS,
    slash: provider === "claude"
      ? compactStringList(metadata.slashCommands || DEFAULT_CLAUDE_SLASH_COMMANDS, 80)
      : compactStringList(metadata.slashCommands || DEFAULT_CODEX_SLASH_COMMANDS, 80),
    cli: provider === "claude"
      ? compactStringList(metadata.cliCommands || DEFAULT_CLAUDE_CLI_COMMANDS, 80)
      : compactStringList(metadata.cliCommands || DEFAULT_CODEX_CLI_COMMANDS, 80),
  };
}

function providerMetadataFromOutput(provider, output, task, chatId) {
  const events = decodedOutputEvents(output);
  const metadata = {};
  if (provider === "claude") {
    const init = events.find((event) => event && event.type === "system" && event.subtype === "init") ||
      events.find((event) => Array.isArray(event.tools) || Array.isArray(event.slash_commands));
    const resultEvents = events.filter((event) => event && event.type === "result");
    const result = resultEvents[resultEvents.length - 1] || null;
    const assistantEvents = events.filter((event) => event && event.message && event.message.usage);
    const assistant = assistantEvents[assistantEvents.length - 1] || null;
    metadata.model = (result && result.model) || (init && init.model) || modelFor(provider, chatId, task);
    metadata.advisor = advisorFor(provider, chatId, task);
    metadata.permissionMode = init && init.permissionMode;
    metadata.sessionId = (result && result.session_id) || (init && init.session_id);
    metadata.cliVersion = init && init.claude_code_version;
    metadata.availableTools = compactStringList((init && init.tools) || [], 80);
    metadata.slashCommands = compactStringList((init && init.slash_commands) || DEFAULT_CLAUDE_SLASH_COMMANDS, 80);
    metadata.cliCommands = DEFAULT_CLAUDE_CLI_COMMANDS;
    metadata.mcpServers = compactMcpServers(init && init.mcp_servers);
    metadata.agents = compactStringList((init && init.agents) || [], 40);
    metadata.skills = compactStringList((init && init.skills) || [], 40);
    metadata.usage = compactUsage((result && result.usage) || (assistant && assistant.message && assistant.message.usage), result || assistant);
  } else if (provider === "codex") {
    const thread = events.find((event) => event && event.type === "thread.started");
    const turnEvents = events.filter((event) => event && event.type === "turn.completed");
    const turn = turnEvents[turnEvents.length - 1] || null;
    metadata.model = modelFor(provider, chatId, task);
    metadata.threadId = thread && thread.thread_id;
    metadata.cliVersion = "codex-cli";
    metadata.availableTools = [];
    metadata.slashCommands = DEFAULT_CODEX_SLASH_COMMANDS;
    metadata.cliCommands = DEFAULT_CODEX_CLI_COMMANDS;
    metadata.mcpServers = [];
    metadata.usage = compactUsage(turn && turn.usage, turn);
  }

  const catalog = providerCommandCatalog(provider, metadata);
  metadata.providerCommands = catalog.bridge;
  metadata.slashCommands = catalog.slash;
  metadata.cliCommands = catalog.cli;
  return metadata;
}

// Bridge-intercepted slash commands answered locally (real data, no agent turn).
const BRIDGE_INTERCEPT_COMMANDS = [
  "commands",
  "help",
  "usage",
  "skills",
  "model",
  "advisor",
  "compact",
  "status",
  "doctor",
];

function parseBridgeCommand(prompt, provider) {
  const text = String(prompt || "").trim();
  if (!text.startsWith("/")) return null;
  const firstLine = text.split(/\r?\n/, 1)[0].trim();
  const match = firstLine.match(/^\/([a-z][a-z0-9_-]*)(?:\s+(.*))?$/i);
  if (!match) return null;
  const name = match[1].toLowerCase();
  const base = { name, args: (match[2] || "").trim(), raw: firstLine };
  if (BRIDGE_INTERCEPT_COMMANDS.includes(name)) return base;
  // Codex slash commands are TUI-only — `codex exec` would treat "/foo" as literal
  // prompt text and waste a turn. Intercept its known desktop-only commands and answer
  // with a helpful note instead of spawning. (Claude DOES parse slash commands headless,
  // so anything else falls through to the CLI on purpose for Claude.)
  if (provider === "codex" && CODEX_DESKTOP_ONLY.has(name)) {
    return { ...base, desktopOnly: true };
  }
  return null;
}

function formatUsage(runtime) {
  const usage = runtime && runtime.usage;
  if (!usage) return "No usage has been recorded for this chat yet. Run one agent task first.";
  const parts = [];
  if (usage.inputTokens != null) parts.push(`input ${usage.inputTokens}`);
  if (usage.cachedInputTokens != null) parts.push(`cached ${usage.cachedInputTokens}`);
  if (usage.outputTokens != null) parts.push(`output ${usage.outputTokens}`);
  if (usage.reasoningOutputTokens != null) parts.push(`reasoning ${usage.reasoningOutputTokens}`);
  if (usage.totalCostUsd != null) parts.push(`cost $${Number(usage.totalCostUsd).toFixed(4)}`);
  if (usage.ttftMs != null) parts.push(`ttft ${(Number(usage.ttftMs) / 1000).toFixed(1)}s`);
  if (usage.durationMs != null) parts.push(`duration ${(Number(usage.durationMs) / 1000).toFixed(1)}s`);
  return parts.length ? parts.join(" · ") : "Usage was present, but did not include token totals.";
}

function formatCommands(provider) {
  const caps = capabilitiesByProvider.get(provider) || {};
  const catalog = providerCommandCatalog(provider, caps);
  const title =
    provider === "claude"
      ? "Claude"
      : provider === "codex"
        ? "Codex"
        : provider === "grok"
          ? "Grok"
          : provider === "agy"
            ? "Agy"
            : provider;
  const descOf = provider === "claude" ? CLAUDE_COMMAND_DESC : CODEX_COMMAND_DESC;
  const desktopOnly = provider === "claude" ? CLAUDE_DESKTOP_ONLY : CODEX_DESKTOP_ONLY;
  const slashLine = (cmd) => {
    const desc = descOf[cmd];
    const flag = desktopOnly.has(cmd) ? " (desktop only)" : "";
    return desc ? `- /${cmd} — ${desc}${flag}` : `- /${cmd}${flag}`;
  };
  const lines = [
    "Bridge commands (answered right here, no agent run):",
    ...catalog.bridge.map((cmd) => `- ${cmd}`),
    "",
  ];
  const slashToShow = catalog.slash.filter((cmd) => !BRIDGE_INTERCEPT_COMMANDS.includes(cmd));
  if (slashToShow.length) {
    lines.push(`${title} slash commands — type / in the message box:`);
    lines.push(...slashToShow.map(slashLine));
    if (provider === "claude") {
      lines.push("Sending one runs it as an agent turn; interactive-only ones reply that they need the desktop.");
    } else {
      lines.push("Codex slash commands run in the desktop/terminal app; from the phone the bridge answers the ones it can.");
    }
    lines.push("");
  }
  if (catalog.cli.length) {
    lines.push(`${title} terminal subcommands on this computer:`);
    lines.push(...catalog.cli.map((cmd) => `- ${title.toLowerCase()} ${cmd}`));
  }
  return lines.join("\n").trim();
}

function formatSkills(provider) {
  const caps = capabilitiesByProvider.get(provider) || {};
  const title =
    provider === "claude"
      ? "Claude"
      : provider === "codex"
        ? "Codex"
        : provider === "grok"
          ? "Grok"
          : provider === "agy"
            ? "Agy"
            : provider;
  const sections = [];
  const addList = (label, values) => {
    const list = compactStringList(values || [], 80);
    if (!list.length) return;
    sections.push(`${label}:\n${list.map((item) => `- ${item}`).join("\n")}`);
  };
  addList("Skills", caps.skills);
  addList("Agents", caps.agents);
  addList("Tools", caps.availableTools);
  const mcp = Array.isArray(caps.mcpServers) ? caps.mcpServers : [];
  if (mcp.length) {
    sections.push(
      "MCP servers:\n" +
        mcp
          .map((server) => {
            const name = server && server.name ? String(server.name) : "";
            const status = server && server.status ? String(server.status) : "";
            return name ? `- ${name}${status ? ` (${status})` : ""}` : null;
          })
          .filter(Boolean)
          .join("\n")
    );
  }
  if (sections.length) return `${title} capabilities\n\n${sections.join("\n\n")}`;
  return [
    `${title} capabilities`,
    "No skills, agents, MCP servers, or tool list has been reported for this chat yet.",
    "Run one agent task first so the bridge can capture the provider init metadata.",
  ].join("\n");
}

// Run a short, read-only provider subcommand and capture its output. Used to make
// /status and /doctor reflect what the REAL CLI reports (account, health) instead
// of a locally-synthesized placeholder. Bounded time + output; never throws.
function runCliCapture(cmd, args, timeoutMs = 12000) {
  try {
    const out = execFileSync(cmd, args, {
      encoding: "utf8",
      timeout: timeoutMs,
      maxBuffer: 256 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return String(out || "").trim();
  } catch (err) {
    const partial = String((err && (err.stdout || err.stderr)) || "").trim();
    return partial || null;
  }
}

// REAL Claude conversation compaction. The interactive `/compact` summarizes the
// running conversation and continues in a fresh, compacted session. Headless
// `claude -p "/compact" --resume <sid> --output-format json` does the same thing and
// returns a single JSON envelope carrying the new `session_id` + the summary in
// `result`. We run it, capture the new session id (so the next resume continues the
// compacted thread), and hand back the summary text. Bounded + never throws.
async function runClaudeCompact(cwd, sessionId) {
  const cmd = process.env.VIBE_CLAUDE_COMMAND || "claude";
  const args = ["-p", "/compact", "--resume", sessionId, "--output-format", "json"];
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(cmd, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      resolve({ ok: false, error: `Could not start ${cmd}: ${err.message}` });
      return;
    }
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      try { child.kill("SIGTERM"); } catch (_) {}
    }, 120000);
    child.stdout.on("data", (d) => { if (out.length < 512 * 1024) out += d.toString(); });
    child.stderr.on("data", (d) => { if (err.length < 64 * 1024) err += d.toString(); });
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ ok: false, error: e.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      let parsed = null;
      try { parsed = JSON.parse(out.trim()); } catch (_) {}
      if (parsed && (parsed.subtype === "success" || parsed.result != null)) {
        resolve({
          ok: true,
          newSessionId: parsed.session_id || null,
          summary: String(parsed.result || "").trim(),
        });
        return;
      }
      resolve({
        ok: false,
        error: (err.trim() || out.trim() || `claude exited ${code}`).slice(0, 400),
      });
    });
  });
}

// Real account/login status from the provider CLI. Codex exposes `codex login
// status`; Claude has no headless account command, so we return null and let the
// caller fall back to the model/usage context it already has.
function providerAccountStatus(provider) {
  if (provider === "codex") {
    return runCliCapture("codex", ["login", "status"], 8000) || "Codex login status unavailable.";
  }
  return null;
}

// REAL Claude subscription usage. The interactive `/usage` view fetches this from
// `GET /api/oauth/usage` (the CLI's `fetchUtilization`) using the same OAuth token
// the `claude` CLI stores in the macOS Keychain. We read that token and call the
// endpoint ourselves so the phone's /usage shows the actual 5-hour + 7-day limits
// (utilization % + reset time), not a locally-synthesized placeholder. Cached
// briefly so repeated taps don't hammer the endpoint. Returns null on any failure
// (no token / expired / offline) — callers fall back to per-run token counts.
let claudeUtilCache = { at: 0, data: null };
async function fetchClaudeUtilization() {
  if (claudeUtilCache.data && Date.now() - claudeUtilCache.at < 45000) return claudeUtilCache.data;
  let token = null;
  try {
    const raw = execFileSync(
      "security",
      ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }
    );
    const parsed = JSON.parse(raw);
    token = parsed && parsed.claudeAiOauth && parsed.claudeAiOauth.accessToken;
  } catch (_) {
    token = null;
  }
  if (!token) return null;
  try {
    const res = await fetch("https://api.anthropic.com/api/oauth/usage", {
      headers: { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    claudeUtilCache = { at: Date.now(), data };
    return data;
  } catch (_) {
    return null;
  }
}

function fmtResetIn(iso) {
  const t = Date.parse(iso || "");
  if (!Number.isFinite(t)) return "";
  const ms = t - Date.now();
  if (ms <= 0) return "resetting now";
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  if (h >= 24) return `resets in ${Math.floor(h / 24)}d ${h % 24}h`;
  if (h >= 1) return `resets in ${h}h ${m}m`;
  return `resets in ${m}m`;
}

// ── Grok (xAI) subscription usage ────────────────────────────────────
// Live: GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
// with Bearer from ~/.grok/auth.json (same token the CLI uses). Fallback:
// parse the latest "billing: fetched credits config" line from
// ~/.grok/logs/unified.jsonl. Returns { buckets, tier } or null.
let grokUtilCache = { at: 0, data: null };
async function fetchGrokUtilization() {
  if (grokUtilCache.data && Date.now() - grokUtilCache.at < 45000) return grokUtilCache.data;
  let token = null;
  try {
    const raw = fs.readFileSync(path.join(os.homedir(), ".grok", "auth.json"), "utf8");
    const parsed = JSON.parse(raw);
    const entry = parsed && typeof parsed === "object" ? Object.values(parsed)[0] : null;
    token = entry && (entry.key || entry.access_token || entry.accessToken);
  } catch (_) {
    token = null;
  }
  if (token) {
    try {
      const res = await fetch("https://cli-chat-proxy.grok.com/v1/billing?format=credits", {
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
          "User-Agent": "GrokBuild/0.2.93",
          "x-grok-client-version": "0.2.93",
        },
        signal: AbortSignal.timeout(10000),
      });
      if (res.ok) {
        const data = await res.json();
        const cfg = (data && data.config) || data || {};
        const buckets = grokConfigToBuckets(cfg);
        if (buckets.length) {
          const out = {
            buckets,
            tier: (data && data.ctx && data.ctx.subscriptionTier) || null,
          };
          // subscriptionTier is on log lines; API may put it elsewhere
          if (data && data.subscriptionTier) out.tier = data.subscriptionTier;
          grokUtilCache = { at: Date.now(), data: out };
          lastRateLimitsByProvider.set("grok", { at: Date.now(), buckets });
          return out;
        }
      }
    } catch (_) {
      /* fall through to log parse */
    }
  }
  const disk = fetchGrokUtilizationFromLog();
  if (disk) {
    grokUtilCache = { at: Date.now(), data: disk };
    lastRateLimitsByProvider.set("grok", { at: Date.now(), buckets: disk.buckets });
    return disk;
  }
  return null;
}

function grokConfigToBuckets(cfg) {
  if (!cfg || typeof cfg !== "object") return [];
  const buckets = [];
  const period = cfg.currentPeriod || {};
  const resetsAt = period.end || cfg.billingPeriodEnd || null;
  const periodType = String(period.type || "").toUpperCase();
  let periodLabel = "7-day (weekly)";
  if (periodType.includes("MONTH")) periodLabel = "Monthly";
  else if (periodType.includes("DAY") && !periodType.includes("WEEK")) periodLabel = "Daily";
  else if (periodType.includes("HOUR") || periodType.includes("5H")) periodLabel = "5-hour session";

  const pct = Number(cfg.creditUsagePercent);
  if (Number.isFinite(pct)) {
    buckets.push({
      label: periodLabel,
      utilization: Math.round(pct),
      resetsAt: typeof resetsAt === "string" ? resetsAt : null,
    });
  }
  // Per-product breakdown when present (e.g. GrokBuild vs Api).
  if (Array.isArray(cfg.productUsage)) {
    for (const p of cfg.productUsage) {
      if (!p || typeof p !== "object") continue;
      const name = String(p.product || "").trim();
      const up = Number(p.usagePercent);
      if (!name || !Number.isFinite(up)) continue;
      // Skip if same as overall weekly already pushed.
      if (name.toLowerCase() === "grokbuild" && buckets.length) continue;
      buckets.push({
        label: `${name} usage`,
        utilization: Math.round(up),
        resetsAt: typeof resetsAt === "string" ? resetsAt : null,
      });
    }
  }
  return buckets;
}

function fetchGrokUtilizationFromLog() {
  try {
    const logPath = path.join(os.homedir(), ".grok", "logs", "unified.jsonl");
    if (!fs.existsSync(logPath)) return null;
    const st = fs.statSync(logPath);
    const size = Math.min(st.size, 512 * 1024);
    const fd = fs.openSync(logPath, "r");
    const buf = Buffer.alloc(size);
    fs.readSync(fd, buf, 0, size, Math.max(0, st.size - size));
    fs.closeSync(fd);
    const lines = buf.toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line || !line.includes("creditUsagePercent")) continue;
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      const cfg =
        (obj && obj.ctx && obj.ctx.config) ||
        (obj && obj.config) ||
        null;
      if (!cfg) continue;
      const buckets = grokConfigToBuckets(cfg);
      if (!buckets.length) continue;
      return {
        buckets,
        tier: (obj.ctx && obj.ctx.subscriptionTier) || null,
      };
    }
  } catch (_) {
    /* */
  }
  return null;
}

// ── Agy / Antigravity (Google Cloud Code) quota ──────────────────────
// Live: POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
// with the consumer OAuth token from macOS Keychain service "gemini" /
// account "antigravity" (go-keyring-base64 JSON). Summary groups expose
// "Five Hour Limit" + "Weekly Limit" with remainingFraction + resetTime.
let agyUtilCache = { at: 0, data: null };
async function fetchAgyUtilization() {
  if (agyUtilCache.data && Date.now() - agyUtilCache.at < 45000) return agyUtilCache.data;
  const token = readAgyAccessToken();
  if (!token) return null;
  try {
    const res = await fetch(
      "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          Accept: "application/json",
          "User-Agent": "antigravity",
        },
        body: "{}",
        signal: AbortSignal.timeout(12000),
      }
    );
    if (!res.ok) return null;
    const data = await res.json();
    const buckets = agySummaryToBuckets(data);
    if (!buckets.length) return null;
    const out = { buckets };
    agyUtilCache = { at: Date.now(), data: out };
    lastRateLimitsByProvider.set("agy", { at: Date.now(), buckets });
    return out;
  } catch (_) {
    return null;
  }
}

function readAgyAccessToken() {
  // 1) Keychain (preferred — live CLI session token)
  try {
    const raw = execFileSync(
      "security",
      ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
      { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }
    ).trim();
    let jsonStr = raw;
    if (raw.startsWith("go-keyring-base64:")) {
      jsonStr = Buffer.from(raw.slice("go-keyring-base64:".length), "base64").toString("utf8");
    }
    const parsed = JSON.parse(jsonStr);
    const tok = (parsed && parsed.token) || parsed || {};
    if (tok.access_token) return tok.access_token;
  } catch (_) {
    /* */
  }
  // 2) ~/.gemini/oauth_creds.json fallback
  try {
    const raw = fs.readFileSync(path.join(os.homedir(), ".gemini", "oauth_creds.json"), "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && parsed.access_token) return parsed.access_token;
  } catch (_) {
    /* */
  }
  return null;
}

function agySummaryToBuckets(data) {
  if (!data || typeof data !== "object") return [];
  const buckets = [];
  const seen = new Set();
  const push = (label, remainingFraction, resetTime) => {
    const rem = Number(remainingFraction);
    if (!Number.isFinite(rem)) return;
    const util = Math.round(Math.max(0, Math.min(100, (1 - rem) * 100)));
    const key = `${label}|${resetTime || ""}`;
    if (seen.has(key)) return;
    seen.add(key);
    buckets.push({
      label,
      utilization: util,
      resetsAt: typeof resetTime === "string" && resetTime ? resetTime : null,
    });
  };

  // Preferred: grouped summary (Gemini Models / 3p models with 5h + weekly).
  const groups = Array.isArray(data.groups) ? data.groups : [];
  for (const g of groups) {
    const groupName = String((g && g.displayName) || "").trim();
    const list = (g && Array.isArray(g.buckets) && g.buckets) || [];
    for (const b of list) {
      if (!b || typeof b !== "object") continue;
      const display = String(b.displayName || b.bucketId || "").trim();
      const window = String(b.window || "").toLowerCase();
      let label = display || "Usage";
      if (window === "5h" || /five.?hour|5.?hour/i.test(display)) {
        label = groupName ? `${groupName} · 5-hour` : "5-hour session";
      } else if (window === "weekly" || /week/i.test(display)) {
        label = groupName ? `${groupName} · weekly` : "7-day (weekly)";
      } else if (groupName) {
        label = `${groupName} · ${display || window || "limit"}`;
      }
      push(label, b.remainingFraction ?? b.remaining_fraction, b.resetTime || b.reset_time);
    }
  }

  // Fallback: flat buckets from retrieveUserQuota (per-model).
  if (!buckets.length && Array.isArray(data.buckets)) {
    for (const b of data.buckets) {
      if (!b || typeof b !== "object") continue;
      const model = String(b.modelId || b.model_id || "").trim() || "model";
      push(model, b.remainingFraction ?? b.remaining_fraction, b.resetTime || b.reset_time);
    }
  }
  return buckets;
}

// Read the latest Codex rate_limits snapshot from on-disk session logs under
// ~/.codex/sessions (and archived_sessions). Codex has no headless OAuth usage
// endpoint like Claude; windows are written into every token_count event.
// Returns { buckets: [...] } or null. Never throws.
function fetchCodexUtilizationFromDisk() {
  try {
    // Session files outlive the CLI process and even the subscription shape that wrote
    // them. They are useful as a short handoff cache, not as current account authority.
    const maxSnapshotAgeMs = 30 * 60 * 1000;
    const now = Date.now();
    const home = process.env.HOME || process.env.USERPROFILE || "";
    const roots = [
      path.join(home, ".codex", "sessions"),
      path.join(home, ".codex", "archived_sessions"),
    ];
    const files = [];
    const walk = (dir, depth) => {
      if (depth > 6) return;
      let entries;
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const ent of entries) {
        const full = path.join(dir, ent.name);
        if (ent.isDirectory()) walk(full, depth + 1);
        else if (ent.isFile() && ent.name.endsWith(".jsonl")) {
          try {
            files.push({ full, mtime: fs.statSync(full).mtimeMs });
          } catch {
            /* */
          }
        }
      }
    };
    for (const root of roots) walk(root, 0);
    // Sort by mtime first — directory walk order is not chronological.
    files.sort((a, b) => b.mtime - a.mtime);
    const newest = files
      .filter((file) => now - file.mtime <= maxSnapshotAgeMs)
      .slice(0, 20);
    // Walk newest → oldest; first rate_limits wins.
    for (const { full } of newest) {
      let text;
      try {
        // Tail-read last ~256KB — rate_limits appear on every token_count near the end.
        const st = fs.statSync(full);
        const fd = fs.openSync(full, "r");
        const size = Math.min(st.size, 256 * 1024);
        const buf = Buffer.alloc(size);
        fs.readSync(fd, buf, 0, size, Math.max(0, st.size - size));
        fs.closeSync(fd);
        text = buf.toString("utf8");
      } catch {
        continue;
      }
      const lines = text.split("\n");
      for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i];
        if (!line || !line.includes("rate_limits") || !line.includes("used_percent")) continue;
        let obj;
        try {
          obj = JSON.parse(line);
        } catch {
          continue;
        }
        const eventTimestamp = Date.parse(
          String((obj && (obj.timestamp || obj.created_at || obj.createdAt)) || "")
        );
        if (Number.isFinite(eventTimestamp) && now - eventTimestamp > maxSnapshotAgeMs) {
          continue;
        }
        const rl =
          (obj && obj.rate_limits) ||
          (obj && obj.payload && obj.payload.rate_limits) ||
          null;
        if (!rl || typeof rl !== "object") continue;
        const buckets = [];
        const add = (label, win) => {
          if (!win || typeof win !== "object") return;
          const util = Number(win.used_percent ?? win.utilization ?? win.usedPercent);
          if (!Number.isFinite(util)) return;
          let resetsAt = null;
          const raw = win.resets_at ?? win.resetsAt;
          if (typeof raw === "number" && Number.isFinite(raw)) {
            resetsAt = new Date(raw * 1000).toISOString();
          } else if (typeof raw === "string" && raw) {
            resetsAt = raw;
          }
          buckets.push({
            label,
            utilization: Math.round(util),
            resetsAt,
            windowMinutes: Number(win.window_minutes ?? win.windowMinutes) || null,
          });
        };
        const windowLabel = (win) => {
          const minutes = Number(win && (win.window_minutes ?? win.windowMinutes));
          if (!Number.isFinite(minutes) || minutes <= 0) return "Usage";
          if (minutes === 300) return "5-hour limit";
          if (minutes === 10080) return "Weekly limit";
          if (minutes % 1440 === 0) return `${minutes / 1440}-day limit`;
          if (minutes % 60 === 0) return `${minutes / 60}-hour limit`;
          return `${minutes}-min limit`;
        };
        // A missing primary/secondary window emits nothing. Never infer a 5-hour
        // window merely because one side of the historical pair is absent.
        add(windowLabel(rl.primary), rl.primary);
        add(windowLabel(rl.secondary), rl.secondary);
        if (buckets.length) {
          lastRateLimitsByProvider.set("codex", { at: Date.now(), buckets });
          return { buckets, planType: rl.plan_type || rl.planType || null };
        }
      }
    }
  } catch (_) {
    /* never throw */
  }
  return null;
}

function formatClaudeUtilization(util) {
  if (!util || typeof util !== "object") return null;
  const lines = [];
  const bucket = (label, b) => {
    if (!b || typeof b !== "object" || b.utilization == null) return;
    const reset = fmtResetIn(b.resets_at);
    lines.push(`${label}: ${Math.round(Number(b.utilization))}% used${reset ? ` · ${reset}` : ""}`);
  };
  bucket("5-hour session", util.five_hour);
  bucket("7-day (all models)", util.seven_day);
  bucket("7-day Opus", util.seven_day_opus);
  bucket("7-day Sonnet", util.seven_day_sonnet);
  return lines.length ? lines.join("\n") : null;
}

async function bridgeCommandOutput(provider, chatId, task, repo, command) {
  const key = sessionKey(provider, chatId);
  const currentModel = modelFor(provider, chatId, task);
  const currentAdvisor = advisorFor(provider, chatId, task);
  const lastRuntime = lastRuntimeBySession.get(key);
  const providerTitle =
    provider === "claude"
      ? "Claude"
      : provider === "codex"
        ? "Codex"
        : provider === "grok"
          ? "Grok"
          : provider === "agy"
            ? "Agy"
            : provider;
  if (command.desktopOnly) {
    const desc = (provider === "claude" ? CLAUDE_COMMAND_DESC : CODEX_COMMAND_DESC)[command.name];
    return [
      `/${command.name}${desc ? ` — ${desc}` : ""}`,
      `This is an interactive ${providerTitle} command that runs in the desktop/terminal app, so it can't run headless from the phone.`,
      "Send it from the Codex app on your computer, or just describe what you want and I'll do it as a normal request.",
    ].join("\n");
  }
  switch (command.name) {
    case "commands":
    case "help":
      return formatCommands(provider);
    case "skills":
      return formatSkills(provider);
    case "usage": {
      const lines = [`${providerTitle} usage`];
      if (provider === "claude") {
        const util = formatClaudeUtilization(await fetchClaudeUtilization());
        if (util) {
          lines.push("Subscription limits:");
          lines.push(util);
          lines.push("");
        } else {
          lines.push("(Subscription limits unavailable — sign in to Claude on this computer.)");
          lines.push("");
        }
      } else if (provider === "codex" || provider === "grok" || provider === "agy") {
        // Reuse structured report so /usage text matches the phone sheet.
        const structured = await buildUsageReport(provider, chatId, { chatId, provider });
        if (structured.buckets && structured.buckets.length) {
          lines.push("Subscription limits:");
          for (const b of structured.buckets) {
            const reset = b.resetsAt ? fmtResetIn(b.resetsAt) : "";
            lines.push(
              `${b.label}: ${Math.round(Number(b.utilization) || 0)}% used${reset ? ` · ${reset}` : ""}`
            );
          }
          lines.push("");
        }
      } else {
        const cached = lastRateLimitsByProvider.get(provider);
        if (cached && Array.isArray(cached.buckets) && cached.buckets.length) {
          lines.push("Subscription limits:");
          for (const b of cached.buckets) {
            const reset = b.resetsAt ? fmtResetIn(b.resetsAt) : "";
            lines.push(
              `${b.label}: ${Math.round(Number(b.utilization) || 0)}% used${reset ? ` · ${reset}` : ""}`
            );
          }
          lines.push("");
        }
      }
      lines.push("This chat (last run):");
      lines.push(formatUsage(lastRuntime));
      lines.push(currentModel ? `Model: ${currentModel}` : "Model: provider default");
      if (provider === "claude") lines.push(`Advisor: ${currentAdvisor || "off"}`);
      return lines.join("\n");
    }
    case "model": {
      const next = command.args.trim();
      if (!next) return `Current ${provider} model: ${currentModel || "provider default"}`;
      if (["default", "reset", "auto"].includes(next.toLowerCase())) {
        modelBySession.delete(key);
        return `${provider} model reset to provider default for this chat.`;
      }
      const normalizedModel = normalizeModel(provider, next);
      modelBySession.set(key, normalizedModel);
      return `${provider} model set to ${normalizedModel} for this chat.`;
    }
    case "advisor": {
      if (provider !== "claude") return "Advisor mode is only available for Claude.";
      const next = command.args.trim();
      if (!next) return `Current Claude advisor: ${currentAdvisor || "off"}`;
      if (["default", "reset", "off", "none", "disable", "disabled"].includes(next.toLowerCase())) {
        advisorBySession.delete(key);
        return "Claude advisor disabled for this chat.";
      }
      const normalizedAdvisor = normalizeAdvisor(provider, next);
      if (!normalizedAdvisor) {
        advisorBySession.delete(key);
        return "Claude advisor disabled for this chat.";
      }
      advisorBySession.set(key, normalizedAdvisor);
      return `Claude advisor set to ${normalizedAdvisor} for this chat.`;
    }
    case "compact": {
      if (provider === "codex") {
        // `codex exec` can't run /compact (TUI-only). Be honest about it and drop any
        // captured thread so the next run starts clean.
        sessionByChat.delete(chatId);
        return [
          "Codex can't compact headless — /compact is an interactive command in the Codex app/terminal.",
          "The bridge cleared this chat's resume thread, so the next Codex run starts fresh.",
        ].join("\n");
      }
      if (provider === "grok") {
        // Grok auto-compacts itself; manual /compact is a TUI slash. Point the user
        // at the live compacting nodes when auto_compact_* fires in updates.jsonl.
        return [
          "Grok auto-compacts when the context window fills (you'll see “Compacting conversation…” in the feed).",
          "For a manual compact, use `/compact` in the Grok terminal/TUI for this session.",
        ].join("\n");
      }
      // Claude: run the REAL compaction against the last captured session, then point
      // this chat's resume at the new, compacted session so follow-ups continue it.
      const sid = sessionByChat.get(chatId) || resumeIdFor(task);
      if (!sid) {
        return "Nothing to compact yet — run a Claude task in this chat first, then /compact summarizes it.";
      }
      const cwd = repo.cwd || repo.path || DEFAULT_CWD;
      const res = await runClaudeCompact(cwd, sid);
      if (!res.ok) {
        return `Couldn't compact this conversation: ${res.error || "unknown error"}`;
      }
      if (res.newSessionId) sessionByChat.set(chatId, res.newSessionId);
      return [
        "Conversation compacted. The next Claude request continues from the summarized session.",
        res.summary ? `\n${res.summary}` : "",
      ].join("").trim();
    }
    case "doctor": {
      const doctorCmd =
        provider === "codex"
          ? "codex"
          : provider === "grok"
            ? (process.env.VIBE_GROK_COMMAND || "grok")
            : provider === "agy"
              ? (process.env.VIBE_AGY_COMMAND || "agy")
              : (process.env.VIBE_CLAUDE_COMMAND || "claude");
      const doctorArgs =
        provider === "grok" || provider === "agy" ? ["--version"] : ["doctor"];
      const out = runCliCapture(doctorCmd, doctorArgs, 25000);
      return out || `${providerTitle} doctor produced no output.`;
    }
    case "status": {
      // What the user actually wants from /status: their ACCOUNT + remaining usage,
      // not the bridge connection. Lead with the real login/subscription status and
      // (for Claude) the live 5h/7d limits, then the run context.
      const lines = [`${providerTitle} status`];
      const account = providerAccountStatus(provider);
      if (account) lines.push(account);
      if (provider === "claude") {
        const util = formatClaudeUtilization(await fetchClaudeUtilization());
        if (util) lines.push(util);
      }
      lines.push(`model: ${currentModel || "provider default"}`);
      if (provider === "claude") lines.push(`advisor: ${currentAdvisor || "off"}`);
      lines.push(`usage (last run): ${formatUsage(lastRuntime)}`);
      lines.push(`repo: ${repo.name} · mode: ${workModeFor(task)}`);
      return lines.join("\n");
    }
    default:
      return null;
  }
}

async function runBridgeCommand(channel, task, repo, beforeGit, command) {
  const { provider, chatId, replyToId, requesterUserId } = task;
  const taskId = taskIdFor(task || {});
  const startedAt = Date.now();
  // While Claude /compact runs (can take tens of seconds), show compacting in the
  // live feed so the phone doesn't look frozen or jump empty.
  if (command && command.name === "compact" && provider === "claude") {
    try {
      channel.push("progress", {
        ...computerFields(),
        provider,
        chatId,
        taskId,
        sequence: 0,
        sentAtMs: Date.now(),
        replyToId,
        repoId: repo.id,
        repoName: repo.name,
        cwd: repo.cwd || repo.path,
        workMode: workModeFor(task),
        stage: "compacting",
        line: JSON.stringify({
          type: "auto_compact_started",
          id: "claude-compacting",
          status: "running",
        }),
      });
    } catch (_) {}
  }
  const output = await bridgeCommandOutput(provider, chatId, task, repo, command);
  if (output == null) return false;
  const lastRuntime = lastRuntimeBySession.get(sessionKey(provider, chatId));

  channel.push("progress", {
    ...computerFields(),
    provider,
    chatId,
    taskId,
    sequence: 1,
    sentAtMs: Date.now(),
    replyToId,
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    model: modelFor(provider, chatId, task) || null,
    advisor: advisorFor(provider, chatId, task) || null,
    stage: "bridge_command",
    command: command.raw,
    line: JSON.stringify({
      type: "vibe_bridge_command",
      provider,
      taskId,
      command: command.raw,
      model: modelFor(provider, chatId, task) || null,
      advisor: advisorFor(provider, chatId, task) || null,
    }),
  });

  const durationMs = Date.now() - startedAt;
  const afterGit = gitSnapshot(repo.cwd || repo.path || DEFAULT_CWD);
  const built = { cmd: "vibe-bridge", args: [command.raw] };
  const agentRuntime = runtimePayload({
    provider,
    task,
    taskId,
    repo,
    built,
    exitStatus: 0,
    durationMs,
    before: beforeGit,
    after: afterGit,
    canceled: false,
    output: "",
  });
  if ((command.name === "usage" || command.name === "status") && lastRuntime && lastRuntime.usage) {
    agentRuntime.usage = lastRuntime.usage;
  }
  agentRuntime.providerCommands = providerCommandCatalog(
    provider,
    capabilitiesByProvider.get(provider) || {}
  ).bridge;
  rememberRuntime(provider, chatId, agentRuntime);
  channel.push("result", {
    ...computerFields(),
    provider,
    chatId,
    taskId,
    output,
    exitStatus: 0,
    durationMs,
    replyToId,
    requesterUserId,
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    ...teamFieldsForTask(task),
    ...runtimeResultField(agentRuntime),
  });
  return true;
}

// The runtime card should reflect what THIS run changed, not the user's
// pre-existing uncommitted work. `after` is the full `git diff HEAD`, which
// includes files that were already dirty before the agent ran. Subtract every
// file that is unchanged since the pre-run snapshot so a no-op turn (e.g. a
// plain "Hi" that edits nothing) yields an EMPTY diff — which iOS renders as no
// files-changed card at all (parseAgentRuntimeSummary returns nil on 0 files).
function runAttributedDiff(cwd, before, after) {
  if (!after || !after.git) return after;
  // Clean repo before the run → everything in `after` is the agent's doing.
  if (!before || !before.dirty) return after;
  const beforeByPath = new Map();
  for (const f of before.files || []) beforeByPath.set(f.path, f);
  const files = (after.files || []).filter((f) => {
    const prev = beforeByPath.get(f.path);
    if (!prev) return true; // path first touched during this run
    return (
      (prev.additions || 0) !== (f.additions || 0) ||
      (prev.deletions || 0) !== (f.deletions || 0) ||
      (prev.status || "") !== (f.status || "")
    );
  });
  // Nothing pre-existing overlapped → keep the original (incl. its full patch).
  if (files.length === (after.files || []).length) return after;
  const additions = files.reduce((s, f) => s + (f.additions || 0), 0);
  const deletions = files.reduce((s, f) => s + (f.deletions || 0), 0);
  // Re-scope the patch to the attributed paths so the diff viewer matches the
  // card. Empty when the run changed nothing.
  let patch = "";
  let patchTruncated = false;
  if (files.length) {
    const tracked = files.filter((f) => f.status !== "A?").map((f) => f.path);
    const trackedPatch = tracked.length
      ? runGit(cwd, ["diff", "--no-ext-diff", "--unified=80", "HEAD", "--", ...tracked], MAX_DIFF_BYTES)
      : "";
    const newFiles = files.filter((f) => f.status === "A?");
    const remaining = Math.max(0, MAX_DIFF_BYTES - trackedPatch.length);
    const np = untrackedPatch(cwd, newFiles, remaining);
    patch = trackedPatch + np.patch;
    patchTruncated = patch.length >= MAX_DIFF_BYTES || np.truncated;
  }
  return { ...after, files, additions, deletions, patch, patchTruncated };
}

// True if this run's raw output stream contains any tool event that could modify
// files (edit / write / shell). Used to reject a diff card built purely from the
// repo's PRE-EXISTING dirty state: on a dirty repo a turn that ran no file-modifying
// work (e.g. a plain "Hi") must not be credited with the user's own in-progress edits
// (or a concurrent agent's). Covers Claude tool_use names, Codex thread items, and the
// Grok/Agy synthetic (mapped) tool names.
function runMayHaveModifiedFiles(provider, output) {
  const s = String(output || "");
  if (!s) return false;
  // Claude tool_use blocks (nested in assistant message.content).
  if (/"name"\s*:\s*"(Edit|Write|MultiEdit|NotebookEdit|Bash)"/.test(s)) return true;
  // Codex thread items.
  if (/"item_type"\s*:\s*"(file_change|command_execution)"/.test(s)) return true;
  // Grok / Agy synthetic + raw tool names (mapped by grokActionDetail / mapAgyToolName).
  if (
    /"name"\s*:\s*"(search_replace|write|write_to_file|create_file|run_terminal_command|run_command|replace_file_content|multi_replace_file_content|edit|apply_patch)"/i.test(
      s
    )
  ) {
    return true;
  }
  return false;
}

function runtimePayload({
  provider,
  task,
  taskId,
  repo,
  built,
  exitStatus,
  durationMs,
  before,
  after,
  canceled,
  output,
}) {
  const attributed = runAttributedDiff(repo.cwd || repo.path, before, after);
  let fileSummary =
    attributed && attributed.git ? attributed : { files: [], additions: 0, deletions: 0, patch: "" };
  // Ambient-diff guard: if the repo was ALREADY dirty and this run emitted no
  // file-modifying tool event, the git delta is the user's own in-progress work (or a
  // concurrent agent's), not this turn's — drop it so a no-edit turn shows no diff card.
  // Only fires in the dirty-before path, so a real edit on a clean repo is never hidden.
  if (
    before &&
    before.dirty &&
    fileSummary.files &&
    fileSummary.files.length &&
    !runMayHaveModifiedFiles(provider, output)
  ) {
    fileSummary = { files: [], additions: 0, deletions: 0, patch: "" };
  }
  const metadata = providerMetadataFromOutput(provider, output || "", task, task && task.chatId);
  const payload = {
    taskId,
    provider,
    status: canceled ? "stopped" : exitStatus === 0 ? "done" : "failed",
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    ...teamFieldsForTask(task),
    durationMs,
    dirtyBefore: !!(before && before.dirty),
    dirtyBeforeCount: (before && before.statusCount) || 0,
    exitStatus,
    command: {
      executable: built.cmd,
      args: built.args,
      display: compactCommand(built.cmd, built.args),
    },
    diff: {
      git: !!(after && after.git),
      filesChanged: fileSummary.files.length,
      additions: fileSummary.additions || 0,
      deletions: fileSummary.deletions || 0,
      files: fileSummary.files || [],
      patch: fileSummary.patch || "",
      patchTruncated: !!fileSummary.patchTruncated,
    },
    controls: {
      canCancel: false,
      canRevert: !!(
        after &&
        after.git &&
        before &&
        !before.dirty &&
        fileSummary.files &&
        fileSummary.files.length > 0
      ),
    },
  };

  const resolvedPayloadModel = metadata.model || modelFor(provider, task && task.chatId, task);
  const resolvedPayloadAdvisor = metadata.advisor || advisorFor(provider, task && task.chatId, task);
  if (resolvedPayloadModel) payload.model = resolvedPayloadModel;
  if (resolvedPayloadAdvisor) payload.advisor = resolvedPayloadAdvisor;
  payload.intelligence = intelligenceFor(task);
  payload.speed = speedFor(task);
  payload.reasoningEffort = reasoningEffortFor(provider, task);
  if (metadata.permissionMode) payload.permissionMode = metadata.permissionMode;
  if (metadata.sessionId) payload.sessionId = metadata.sessionId;
  if (metadata.threadId) payload.threadId = metadata.threadId;
  if (metadata.cliVersion) payload.cliVersion = metadata.cliVersion;
  if (metadata.usage) payload.usage = metadata.usage;
  if (metadata.availableTools && metadata.availableTools.length) payload.availableTools = metadata.availableTools;
  if (metadata.slashCommands && metadata.slashCommands.length) payload.slashCommands = metadata.slashCommands;
  if (metadata.cliCommands && metadata.cliCommands.length) payload.cliCommands = metadata.cliCommands;
  if (metadata.providerCommands && metadata.providerCommands.length) payload.providerCommands = metadata.providerCommands;
  if (metadata.mcpServers && metadata.mcpServers.length) payload.mcpServers = metadata.mcpServers;
  if (metadata.agents && metadata.agents.length) payload.agents = metadata.agents;
  if (metadata.skills && metadata.skills.length) payload.skills = metadata.skills;
  return payload;
}

function safeRepoPath(cwd, relativePath) {
  const clean = diffFilePath(relativePath);
  if (!clean || path.isAbsolute(clean)) return null;
  const base = path.resolve(cwd);
  const absolute = path.resolve(base, clean);
  if (absolute === base || !absolute.startsWith(base + path.sep)) return null;
  return absolute;
}

function restoreTrackedFiles(cwd, files) {
  if (!files.length) return;
  const args = ["restore", "--staged", "--worktree", "--", ...files];
  try {
    execFileSync("git", args, { cwd, stdio: "ignore", timeout: 10_000 });
  } catch (_) {
    execFileSync("git", ["checkout", "--", ...files], { cwd, stdio: "ignore", timeout: 10_000 });
  }
}

function revertFinishedTask(channel, payload) {
  const provider = payload.provider || payload.agentWorkerProvider || payload.agentBridgeProvider;
  const chatId = payload.chatId || payload.chat_id;
  const taskId = payload.taskId || payload.agentTaskId || payload.messageId;
  const candidates = taskLookupCandidates(provider, chatId, taskId, finishedTasks);
  const key = candidates.find((candidate) => finishedTasks.has(candidate));
  const record = key && finishedTasks.get(key);

  if (!record) {
    channel.push("control_result", { ok: false, reason: "task_not_found", action: "revert", provider, chatId, taskId });
    return;
  }

  const runtime = record.runtime || {};
  if (!runtime.controls || runtime.controls.canRevert !== true) {
    channel.push("control_result", {
      ok: false,
      reason: runtime.dirtyBefore ? "repo_was_dirty_before_task" : "task_not_revertible",
      action: "revert",
      provider: record.provider,
      chatId: record.chatId,
      taskId: record.taskId,
    });
    return;
  }

  const cwd = record.repo.cwd || record.repo.path;
  const files = (runtime.diff && Array.isArray(runtime.diff.files) ? runtime.diff.files : []).filter(
    (file) => file && file.path
  );
  const tracked = files
    .filter((file) => file.status !== "A?")
    .map((file) => diffFilePath(file.path))
    .filter(Boolean);
  const untracked = files.filter((file) => file.status === "A?");

  try {
    restoreTrackedFiles(cwd, tracked);
    for (const file of untracked) {
      const absolute = safeRepoPath(cwd, file.path);
      if (absolute) fs.rmSync(absolute, { recursive: true, force: true });
    }
    const after = gitSnapshot(cwd);
    finishedTasks.delete(key);
    channel.push("control_result", {
      ok: true,
      action: "revert",
      provider: record.provider,
      chatId: record.chatId,
      taskId: record.taskId,
      repoId: record.repo.id,
      repoName: record.repo.name,
      cwd,
      diffAfter: {
        filesChanged: after.files.length,
        additions: after.additions || 0,
        deletions: after.deletions || 0,
      },
    });
  } catch (err) {
    channel.push("control_result", {
      ok: false,
      reason: err.message || "revert_failed",
      action: "revert",
      provider: record.provider,
      chatId: record.chatId,
      taskId: record.taskId,
    });
  }
}

function bridgeStatusPayload() {
  // Kick a background refresh when cache is empty/stale so the next status push
  // carries live provider catalogs (Claude API / grok models / agy models).
  if (
    !providerModelsCache.models ||
    Date.now() - providerModelsCache.at > PROVIDER_MODELS_TTL_MS
  ) {
    discoverProviderModels(false).catch(() => {});
  }
  refreshExternalProviderActivity().catch(() => {});
  const models = providerModelsCache.models || fallbackProviderModels();
  return {
    computerId: ACTIVE_COMPUTER_ID,
    deviceLabel: ARGS.label || os.hostname(),
    cwd: DEFAULT_CWD,
    repositories: ADVERTISED_REPOSITORIES,
    runningTasks: runningTaskSummaries(),
    // Live model pickers for the phone (refreshed from provider CLIs/APIs).
    models,
    modelsUpdatedAt: providerModelsCache.at || null,
    permissions: {
      claude: {
        permissionMode: process.env.VIBE_CLAUDE_PERMISSION_MODE || "per-task",
        command: process.env.VIBE_CLAUDE_COMMAND || "claude",
        model: process.env.VIBE_CLAUDE_MODEL || "settings/default",
        advisor: process.env.VIBE_CLAUDE_ADVISOR || process.env.VIBE_CLAUDE_ADVISOR_MODEL || "settings/default",
	      },
	      codex: {
	        sandbox: process.env.VIBE_CODEX_SANDBOX || "per-task",
	        approvalPolicy: process.env.VIBE_CODEX_APPROVAL_POLICY || "per-task",
	        command: process.env.VIBE_CODEX_COMMAND || "codex",
	      },
      grok: {
        permissionMode: process.env.VIBE_GROK_PERMISSION_MODE || "per-task",
        command: process.env.VIBE_GROK_COMMAND || "grok",
        model: process.env.VIBE_GROK_MODEL || "settings/default",
      },
      agy: {
        permissionMode: process.env.VIBE_AGY_PERMISSION_MODE || "per-task",
        command: process.env.VIBE_AGY_COMMAND || "agy",
        model: process.env.VIBE_AGY_MODEL || "settings/default",
      },
      workModes: ["ask", "ask_auto", "read_only", "allow_edits", "full_access"],
    },
  };
}

function runningTaskSummaries() {
  const now = Date.now();
  const bridgeTasks = Array.from(runningTasks.values()).map((entry) => ({
    provider: entry.provider,
    chatId: entry.chatId,
    taskId: entry.taskId,
    sessionId: entry.sessionId || null,
    topic: (entry.provider === "codex" ? codexFallbackTitle(entry.prompt) : cleanTopicCandidate(entry.prompt))
      || clip(`${entry.provider || "Agent"} task`, 80),
    repoId: entry.repo && entry.repo.id,
    repoName: entry.repo && entry.repo.name,
    project: entry.repo && (entry.repo.cwd || entry.repo.path),
    projectName: entry.repo && entry.repo.name,
    cwd: entry.cwd,
    workMode: entry.workMode,
    model: entry.model || null,
    advisor: entry.advisor || null,
    intelligence: entry.intelligence || null,
    speed: entry.speed || null,
    reasoningEffort: entry.reasoningEffort || null,
    startedAt: new Date(entry.startedAt).toISOString(),
    durationMs: Math.max(0, now - (entry.startedAt || now)),
    command: entry.command,
    pendingCommand: entry.command,
    teamMode: entry.teamMode || null,
    teamRunId: entry.teamRunId || null,
    teamWorker: entry.teamWorker || null,
    teamWorkers: Array.isArray(entry.teamWorkers) ? entry.teamWorkers : [],
  }));
  const bridgeSessionIds = new Set(bridgeTasks.map((task) => task.sessionId).filter(Boolean));
  return bridgeTasks.concat(
    externalProviderActivity.filter((task) => !bridgeSessionIds.has(task.sessionId))
  );
}

// Desktop / IDE sessions do not enter `runningTasks` because the bridge did not
// spawn them. Expose each provider's newest live local session as provider-scoped
// activity so Home reflects Claude/Grok/Agy as well as Codex.
const EXTERNAL_PROVIDER_STATUS_TTL_MS = 3_000;
let externalProviderActivity = [];
let externalProviderActivityAt = 0;
let externalProviderActivityRefresh = null;

async function refreshExternalProviderActivity() {
  const now = Date.now();
  if (externalProviderActivityRefresh || now - externalProviderActivityAt < EXTERNAL_PROVIDER_STATUS_TTL_MS) {
    return externalProviderActivityRefresh;
  }
  externalProviderActivityRefresh = (async () => {
    const previous = JSON.stringify(externalProviderActivity);
    const catalogs = await Promise.all([
      listClaude(1),
      listCodex(1),
      listGrok(1),
      listAgy(1),
    ]);
    externalProviderActivity = catalogs.flatMap((sessions) => {
      const session = sessions.find((item) => item && item.live);
      if (!session) return [];
      const provider = String(session.provider || "").trim().toLowerCase();
      if (!provider) return [];
      return [{
          provider,
          // Desktop/IDE activity is not owned by any mobile DM. Keep it provider-
          // wide so a stale prior chat id cannot hide the provider's Home state.
          chatId: "",
          taskId: `desktop:${provider}:${session.id}`,
          sessionId: session.id,
          topic: session.topic || `${provider} task`,
          project: session.project || "",
          projectName: session.projectName || "",
          cwd: session.project || "",
          startedAt: session.updatedAt || new Date().toISOString(),
          source: "desktop",
        }];
    });
    externalProviderActivityAt = Date.now();
    if (previous !== JSON.stringify(externalProviderActivity)) {
      const active = externalProviderActivity.map((task) => task.provider).join(",") || "none";
      console.log(`[vibe-bridge][home-live] active providers=${active}`);
    }
    // The status push that initiated this async scan necessarily used the old
    // cache. Publish the completed snapshot immediately so the server/phone do
    // not wait for the next 30-second heartbeat.
    if (previous !== JSON.stringify(externalProviderActivity)) {
      const payload = bridgeStatusPayload();
      if (activeChannel && activeChannel.state === "joined") {
        activeChannel.push("status", payload);
      }
      // A chat page stops Home's REST poll. Keep every authenticated phone current
      // directly as provider desktop/CLI activity starts or ends.
      fanoutLanEvent("bridge_status", payload);
    }
  })().catch((err) => {
    console.warn(`[vibe-bridge][home-live] provider scan failed: ${err && err.message ? err.message : err}`);
    throw err;
  });
  try {
    await externalProviderActivityRefresh;
  } finally {
    externalProviderActivityRefresh = null;
  }
}

function teamFieldsForTask(task) {
  if (!task || typeof task !== "object") {
    return {
      teamMode: null,
      teamRunId: null,
      teamWorker: null,
      teamWorkers: [],
      leadWorker: null,
      teamRole: null,
      suppressVisible: false,
    };
  }
  return {
    teamMode: task.teamMode || task.team_mode || null,
    teamRunId: task.teamRunId || task.team_run_id || null,
    teamWorker: task.teamWorker || task.team_worker || null,
    teamWorkers: Array.isArray(task.teamWorkers)
      ? task.teamWorkers
      : Array.isArray(task.team_workers)
        ? task.team_workers
        : [],
    leadWorker: task.leadWorker || task.lead_worker || null,
    teamRole: task.teamRole || task.team_role || null,
    suppressVisible:
      task.suppressVisible === true ||
      task.suppress_visible === true ||
      task.teamRole === "worker" ||
      task.team_role === "worker",
  };
}

function pushBridgeStatus(channel, forceModels) {
  if (channel.state !== "joined") return;
  // Ensure models are populated before the first status after connect when possible.
  // forceModels=true on connect so the phone sees a fresh provider catalog immediately.
  discoverProviderModels(!!forceModels)
    .then((models) => {
      try {
        const counts = Object.fromEntries(
          Object.entries(models || {}).map(([k, v]) => [k, Array.isArray(v) ? v.length : 0])
        );
        console.log(`[vibe-bridge] provider models ready ${JSON.stringify(counts)}`);
      } catch (_) {}
    })
    .catch(() => {})
    .finally(() => {
      if (channel.state !== "joined") return;
      const payload = bridgeStatusPayload();
      channel.push("status", payload);
      // Status is task authority, not a Home-only decoration. Mirror every start,
      // session-id discovery, and finish to LAN immediately. When `channel` itself is
      // the requesting LAN transport, exclude that one socket because channel.push
      // already delivered it there; other phones still receive the same snapshot.
      fanoutLanEvent("bridge_status", payload, channel._lanSocket || null);
    });
}

// ── Interactive repo pick ───────────────────────────────────────────

function promptLine(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer);
    });
  });
}

function chooseFolderWithSystemPicker() {
  if (process.platform !== "darwin") return null;
  try {
    return execFileSync(
      "osascript",
      ["-e", 'POSIX path of (choose folder with prompt "Select a project folder for Vibe Bridge")'],
      { encoding: "utf8" }
    ).trim();
  } catch (_) {
    return null;
  }
}

function discoverRepositories() {
  const map = new Map();
  for (const root of defaultDiscoveryRoots()) scanRepoRoot(root, map);
  addRepository(map, process.cwd(), "cwd");
  return Array.from(map.values()).sort((a, b) => a.name.localeCompare(b.name));
}

// Ask which project(s) @claude / @codex should work on. Returns an array of
// absolute paths (the user's choice), or null if they cancelled. Only called
// when stdin is a TTY.
async function pickRepositoriesInteractively() {
  const found = discoverRepositories();
  if (!found.length) {
    console.log("\n[vibe-bridge] No git repositories found near your home folder.");
    const custom = (
      await promptLine("  Enter a project path to link (blank = current folder): ")
    ).trim();
    return [custom || process.cwd()];
  }

  console.log("\n[vibe-bridge] Choose project(s) for @claude / @codex:\n");
  found.forEach((r, i) => {
    console.log(`  ${String(i + 1).padStart(2)}. ${r.name}   ${r.path}`);
  });
  console.log("\n  A. All discovered repos");
  console.log(`  C. Current folder   ${process.cwd()}`);
  console.log("  P. Enter a project path");
  if (process.platform === "darwin") console.log("  F. Select a folder");
  console.log("\n  Enter a number, numbers like 1,3, or one of the options above. Blank = the first repo.");
  const answer = (await promptLine("  Selection: ")).trim();

  if (!answer) return [found[0].path];
  const lower = answer.toLowerCase();
  if (lower === "a" || lower === "all") return found.map((r) => r.path);
  if (lower === "c" || lower === "current") return [process.cwd()];
  if (lower === "p" || lower === "path") {
    const custom = (await promptLine("  Project path: ")).trim();
    return [custom || found[0].path];
  }
  if (lower === "f" || lower === "file" || lower === "folder" || lower === "select") {
    const selected = chooseFolderWithSystemPicker();
    if (selected) return [selected];
    const custom = (await promptLine("  Project path: ")).trim();
    return [custom || found[0].path];
  }
  if (answer.startsWith("~") || answer.startsWith("/") || answer.startsWith(".")) {
    return [answer];
  }
  const picks = answer
    .split(/[,\s]+/)
    .map((s) => parseInt(s, 10))
    .filter((n) => Number.isInteger(n) && n >= 1 && n <= found.length);
  if (!picks.length) return [found[0].path];
  return picks.map((n) => found[n - 1].path);
}

// Resolve which repos to advertise. Honors explicit flags/env first; otherwise
// reuses the cached pick, and prompts interactively the first time (or on
// `--pick`). Persists the chosen paths so later launches (incl. the background
// service) reuse them without asking.
async function resolveRepositories(config, persist) {
  const explicit = hasExplicitRepositorySelection();

  let picked = !explicit && Array.isArray(config.repos) ? config.repos.slice() : [];

  const interactive = process.stdin.isTTY && !ARGS.serviceRun && !ARGS.noPick;
  const shouldPrompt = interactive && (ARGS.pick || ARGS.all || (!explicit && picked.length === 0));

  if (shouldPrompt) {
    if (ARGS.all) {
      picked = discoverRepositories().map((r) => r.path);
    } else {
      const chosen = await pickRepositoriesInteractively();
      if (chosen && chosen.length) picked = chosen;
    }
    config.repos = picked;
    if (persist) persist();
  }

  ADVERTISED_REPOSITORIES = buildRepositories(picked);
  if (explicit && ADVERTISED_REPOSITORIES.length === 0) {
    throw new Error("No valid repositories matched --repo/--cwd/--repo-root. Refusing to fall back to the current folder.");
  }
  ensureBridgeInstructionsForRepositories(ADVERTISED_REPOSITORIES);
  DEFAULT_CWD =
    (ADVERTISED_REPOSITORIES[0] && ADVERTISED_REPOSITORIES[0].cwd) ||
    realDir(ARGS.cwd || process.cwd()) ||
    process.cwd();
}

// ── Background service (macOS launchd) ──────────────────────────────

const SERVICE_LABEL = "io.vibegram.agent-bridge";
const SERVICE_LOG = path.join(CONFIG_DIR, "bridge.log");

function servicePlistPath() {
  return path.join(os.homedir(), "Library", "LaunchAgents", `${SERVICE_LABEL}.plist`);
}

function escapeXml(value) {
  return String(value).replace(/[<>&'"]/g, (c) => {
    return { "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" }[c];
  });
}

function installService(server, config) {
  if (process.platform !== "darwin") {
    console.log(
      "[vibe-bridge] --install supports macOS (launchd) right now.\n" +
        "  On Linux, run as a user systemd unit or `nohup vibegram-bridge --server " +
        server +
        " >> ~/.vibe/bridge.log 2>&1 &`."
    );
    return;
  }
  if (!config.bridge_token || !config.user_id) {
    console.log(
      "[vibe-bridge] Pair first, then install the background service:\n" +
        "  1) vibegram-bridge --server " +
        server +
        "   (scan the QR in the app)\n" +
        "  2) vibegram-bridge --install"
    );
    return;
  }

  fs.mkdirSync(path.dirname(servicePlistPath()), { recursive: true });
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });

  const args = [process.execPath, __filename, "--server", server, "--service-run"];
  const claudeModel = process.env.VIBE_CLAUDE_MODEL || "sonnet";
  const claudeAdvisor =
    process.env.VIBE_CLAUDE_ADVISOR || process.env.VIBE_CLAUDE_ADVISOR_MODEL || "fable";
  const xml =
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    '<plist version="1.0">\n' +
    "<dict>\n" +
    `  <key>Label</key><string>${SERVICE_LABEL}</string>\n` +
    "  <key>ProgramArguments</key>\n  <array>\n" +
    args.map((a) => `    <string>${escapeXml(a)}</string>`).join("\n") +
    "\n  </array>\n" +
    "  <key>RunAtLoad</key><true/>\n" +
    "  <key>KeepAlive</key><true/>\n" +
    "  <key>ThrottleInterval</key><integer>10</integer>\n" +
    `  <key>StandardOutPath</key><string>${escapeXml(SERVICE_LOG)}</string>\n` +
    `  <key>StandardErrorPath</key><string>${escapeXml(SERVICE_LOG)}</string>\n` +
    `  <key>WorkingDirectory</key><string>${escapeXml(os.homedir())}</string>\n` +
    "  <key>EnvironmentVariables</key>\n  <dict>\n" +
    `    <key>PATH</key><string>${escapeXml(
      process.env.PATH || "/usr/local/bin:/usr/bin:/bin"
    )}</string>\n` +
    `    <key>VIBE_CLAUDE_MODEL</key><string>${escapeXml(claudeModel)}</string>\n` +
    `    <key>VIBE_CLAUDE_ADVISOR</key><string>${escapeXml(claudeAdvisor)}</string>\n` +
    "  </dict>\n" +
    "</dict>\n</plist>\n";

  fs.writeFileSync(servicePlistPath(), xml);
  try {
    execFileSync("launchctl", ["unload", servicePlistPath()], { stdio: "ignore" });
  } catch (_) {}
  execFileSync("launchctl", ["load", servicePlistPath()]);

  console.log(
    "\n✅ [vibe-bridge] Background service installed.\n" +
      "  • Runs at login and reconnects automatically — no terminal needed.\n" +
      "  • Restarts itself if it crashes.\n" +
      `  • Logs: ${SERVICE_LOG}\n` +
      "  • Stop & remove: vibegram-bridge --uninstall\n"
  );
}

function shouldUseBackgroundByDefault() {
  if (ARGS.serviceRun || ARGS.foreground) return false;
  if (ARGS.selfTest || ARGS.selfTestRevert || ARGS.selfTestSequence) return false;
  if (ARGS.uninstall || ARGS.status || ARGS.logout) return false;
  return process.platform === "darwin";
}

function uninstallService() {
  if (process.platform !== "darwin") {
    console.log("[vibe-bridge] Nothing to uninstall (launchd is macOS-only).");
    return;
  }
  try {
    execFileSync("launchctl", ["unload", servicePlistPath()], { stdio: "ignore" });
  } catch (_) {}
  try {
    fs.unlinkSync(servicePlistPath());
  } catch (_) {}
  console.log("[vibe-bridge] Background service stopped and removed.");
}

function serviceStatus() {
  if (process.platform !== "darwin") {
    console.log("[vibe-bridge] Service status is macOS-only.");
    return;
  }
  const installed = fs.existsSync(servicePlistPath());
  console.log(`[vibe-bridge] background service: ${installed ? "installed" : "not installed"}`);
  if (installed) {
    try {
      const out = execFileSync("launchctl", ["list"], { encoding: "utf8" });
      const line = out.split("\n").find((l) => l.includes(SERVICE_LABEL));
      console.log(`  launchctl: ${line ? line.trim() : "loaded? (re-run with sudo if unsure)"}`);
    } catch (_) {}
    console.log(`  logs: ${SERVICE_LOG}`);
  }
}

function captureSessionId(line) {
  try {
    const ev = JSON.parse(line);
    if (!ev || typeof ev !== "object") return null;
    if (typeof ev.session_id === "string") return ev.session_id;
    // Grok streaming-json / json use camelCase sessionId on the end frame.
    if (typeof ev.sessionId === "string") return ev.sessionId;
    // `codex exec --json` announces the durable history id on its first event:
    //   {"type":"thread.started","thread_id":"..."}
    // Without this, the running task has no sessionId and iOS cannot merge it with
    // the matching history row (so it renders a second prompt-derived row with a
    // synthetic message count instead).
    if (ev.type === "thread.started" && typeof ev.thread_id === "string") {
      return ev.thread_id;
    }
  } catch (_) {}
  return null;
}

function looksToolish(line) {
  // Cheap filter so we only forward lines that may carry tool activity.
  return (
    line.includes("tool_use") ||
    line.includes("tool_result") ||
    line.includes("tool_call") ||
    line.includes('"command"') ||
    line.includes('"response_item"') ||
    line.includes("function_call") ||
    line.includes("custom_tool_call") ||
    line.includes("function_call_output") ||
    line.includes("custom_tool_call_output") ||
    line.includes("command_execution") ||
    line.includes("file_change") ||
    line.includes("mcp_tool_call") ||
    line.includes("todo_list") ||
    line.includes("apply_patch") ||
    line.includes('"tool"')
  );
}

// Forward a line live only when it is a recognized assistant/tool event, so the
// server can stream a live bubble (not just the final batch). Do not match on
// arbitrary JSON text: Claude's bootstrap record contains a large tools/catalog
// payload, and forwarding it makes the phone parse/render metadata as a live turn.
function streamable(line) {
  // `--include-partial-messages` emits per-token `stream_event` deltas (text_delta,
  // message_start, …) that would otherwise match on "text"/"assistant" below and flood
  // the server's whole-buffer reparse. They carry no new complete content (the completed
  // assistant message follows), and the one signal we DO want from them — thinking token
  // growth — is coalesced separately into the throttled vibe_thinking line (trackThinking).
  if (line.includes("stream_event")) return false;
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return false;
  }
  if (!event || typeof event !== "object") return false;

  const type = typeof event.type === "string" ? event.type.toLowerCase() : "";
  if (
    [
      "assistant", // Claude completed assistant message (text and tool_use blocks)
      "text", // Grok/Agy streamed answer chunk
      "thought", // Grok/Agy reasoning chunk
      "end", // Grok terminal marker
      "agent_message", // Codex agent text
      "tool_use",
      "tool_result",
      "tool_call",
      "tool_call_update",
      "command_execution",
      "file_change",
      "mcp_tool_call",
      "todo_list",
      "apply_patch",
      "response_item",
      "item",
    ].includes(type)
  ) {
    return true;
  }

  // Codex emits `item.started` / `item.completed` records and nests the actual
  // tool or assistant payload under `item`. These are real turn updates, unlike
  // CLI system/init records that merely enumerate capabilities.
  return type.startsWith("item.") && event.item && typeof event.item === "object";
}

// Decrypt the phone's sealed image attachments and write them under the repo's
// .vibe/attachments/ so the agent can Read them by path. Returns [{ path, name }].
// Files are git-excluded and cleaned up when the task finishes.
function materializeAttachments(task, cwd) {
  const blobs = Array.isArray(task.attachmentsEnc)
    ? task.attachmentsEnc
    : Array.isArray(task.agentBridgeAttachmentsEnc)
      ? task.agentBridgeAttachmentsEnc
      : [];
  if (!blobs.length) return [];
  const dir = path.join(cwd, ".vibe", "attachments");
  try {
    fs.mkdirSync(dir, { recursive: true });
    ensureVibeGitExclude(cwd, ".vibe/attachments/");
  } catch (_) {
    return [];
  }
  const written = [];
  for (const blob of blobs) {
    const obj = decryptRuntimeBlob(blob);
    if (!obj || typeof obj.dataB64 !== "string") continue;
    const ext = obj.mime === "image/png" ? "png" : "jpg";
    const filename = `${Date.now()}-${crypto.randomBytes(4).toString("hex")}.${ext}`;
    const absolutePath = path.join(dir, filename);
    try {
      fs.writeFileSync(absolutePath, Buffer.from(obj.dataB64, "base64"), { mode: 0o600 });
      written.push({
        path: absolutePath,
        name: typeof obj.name === "string" && obj.name ? obj.name : filename,
      });
    } catch (_) {}
  }
  return written;
}

async function runTask(channel, task) {
  const recvAt = Date.now();
  const { provider, chatId, prompt, replyToId, requesterUserId } = task;
  const taskId = taskIdFor(task || {});
  console.log(
    `[vibe-bridge] run_task received provider=${provider} chat=${chatId} ` +
      `task=${taskId} ` +
      `repoId=${task.repoId || task.agentBridgeRepoId || "-"} ` +
      `workMode=${task.workMode || task.agentBridgeWorkMode || "-"} promptLen=${(prompt || "").length}`
  );

  // Drop duplicate deliveries of the same task (cloud+LAN double-send, reconnect
  // re-delivery) BEFORE the git snapshot / spawn, so we never run the CLI twice.
  // A requeued admission-gate task already holds its reservation — let it through.
  if (!task.__requeued && isDuplicateRunTask(provider, chatId, taskId)) {
    console.log(
      `[vibe-bridge] run_task DUPLICATE dropped provider=${provider} chat=${chatId} task=${taskId}`
    );
    return;
  }

  // Admission gate: over the CLI concurrency cap this task waits its turn with
  // periodic queued heartbeats instead of spawning another process.
  if (!task.__requeued && runningTasks.size >= MAX_CONCURRENT_CLI_TASKS) {
    enqueuePendingTask(channel, task);
    return;
  }

  const repoResult = resolveTaskRepository(task || {});
  if (!repoResult.ok) {
    releaseRunTaskReservation(provider, chatId, taskId);
    channel.push("error", {
      ...computerFields(),
      ...teamFieldsForTask(task),
      provider,
      chatId,
      taskId,
      message: `Refused to run ${provider}: ${repoResult.reason}. Add it with --repo or VIBE_BRIDGE_REPOS on your computer.`,
      replyToId,
    });
    return;
  }

  const repo = repoResult.repo;
  const cwd = repo.cwd || repo.path || DEFAULT_CWD;
  if (provider === "claude") ensureAskMcp(channel);
  // Remember which mobile chat owns this repo/provider so an INTERACTIVE claude
  // session in the same repo can route its ask/command approvals to this chat.
  rememberAgentChat(provider, chatId, cwd);
  console.log(`[vibe-bridge] run ${provider} chat=${chatId} task=${taskId} cwd=${cwd}`);

  const startedAt = Date.now();
  const beforeGit = gitSnapshot(cwd);
  console.log(
    `[vibe-bridge] latency gitSnapshot(before)=${Date.now() - startedAt}ms ` +
      `chat=${chatId} task=${taskId} cwd=${cwd}`
  );
  const bridgeCommand = parseBridgeCommand(prompt, provider);
  if (bridgeCommand && (await runBridgeCommand(channel, task, repo, beforeGit, bridgeCommand))) {
    return;
  }
  // Materialize any phone-sent image attachments to disk and point the agent at
  // them. Done after the slash-command check so commands aren't affected.
  const attachments = materializeAttachments(task, cwd);
  let effectivePrompt = prompt;
  if (attachments.length) {
    const lines = attachments.map((a) => `- ${a.path}`).join("\n");
    effectivePrompt =
      `The user attached ${attachments.length} image file(s) to this message. ` +
      `Use your file Read tool to view ${attachments.length === 1 ? "it" : "them"}:\n${lines}\n\n${prompt}`;
  }
  const promptForCli = taskWantsBridgeInstructions(task, prompt)
    ? taskPromptWithBridgeInstructions(provider, effectivePrompt, repo, task)
    : effectivePrompt;
  const built = buildCommand(provider, promptForCli, chatId, task);
  if (!built) {
    releaseRunTaskReservation(provider, chatId, taskId);
    channel.push("error", {
      ...computerFields(),
      ...teamFieldsForTask(task),
      provider,
      chatId,
      taskId,
      message: `Unknown provider: ${provider}`,
    });
    return;
  }
  // Resume diagnostics: whether this run resumes a prior session/thread and, if so,
  // which id — the key signal for "history send started a new chat" bugs.
  {
    const rid = resumeIdFor(task);
    const resumeFlag = provider === "codex"
      ? built.args.includes("resume")
      : provider === "agy"
        ? built.args.includes("--conversation")
        : built.args.includes("--resume");
    console.log(
      `[vibe-bridge] resume ${provider} chat=${chatId} task=${taskId} ` +
        `resumeId=${rid || "(none/fresh)"} resumeInArgs=${resumeFlag}`
    );
  }

  let child;
  try {
    child = spawn(built.cmd, built.args, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...askMcpEnv(provider, chatId, taskId) },
    });
  } catch (err) {
    releaseRunTaskReservation(provider, chatId, taskId);
    channel.push("error", {
      ...computerFields(),
      ...teamFieldsForTask(task),
      provider,
      chatId,
      taskId,
      message: `Could not start ${built.cmd}: ${err.message}`,
      replyToId,
    });
    return;
  }
  const spawnAt = Date.now();
  console.log(
    `[vibe-bridge] latency recv→spawn=${spawnAt - recvAt}ms ` +
      `chat=${chatId} task=${taskId} cmd=${built.cmd}`
  );

  const key = taskKey(provider, chatId, taskId);
  // Prefer an explicit resume id; for Grok also honor the UUID we assigned at spawn
  // so history watch + updates.jsonl tail can bind before the end frame.
  const initialSessionId = resumeIdFor(task) || built.sessionId || null;
  if (initialSessionId) sessionByChat.set(chatId, initialSessionId);
  runningTasks.set(key, {
    child,
    provider,
    chatId,
    taskId,
    sessionId: initialSessionId,
    prompt,
    repo,
    cwd,
    workMode: workModeFor(task),
    model: modelFor(provider, chatId, task),
    advisor: advisorFor(provider, chatId, task),
    intelligence: intelligenceFor(task),
    speed: speedFor(task),
    reasoningEffort: reasoningEffortFor(provider, task),
    command: compactCommand(built.cmd, built.args),
    ...teamFieldsForTask(task),
    startedAt,
    frameSeq: 0,
    lastAckedSeq: -1,
    frameLog: [],
    lastProgress: null,
  });
  writeBridgeHeartbeat();
  pushBridgeStatus(channel);
  pushProgressFrame(channel, key, {
    provider,
    chatId,
    taskId,
    replyToId,
    repoId: repo.id,
    repoName: repo.name,
    cwd,
    workMode: workModeFor(task),
    model: modelFor(provider, chatId, task) || null,
    advisor: advisorFor(provider, chatId, task) || null,
    intelligence: intelligenceFor(task),
    speed: speedFor(task),
    reasoningEffort: reasoningEffortFor(provider, task),
    ...teamFieldsForTask(task),
    stage: "started",
    command: compactCommand(built.cmd, built.args),
    line: JSON.stringify({
      type: "vibe_bridge_started",
      provider,
      taskId,
      repoId: repo.id,
      repoName: repo.name,
      cwd,
      workMode: workModeFor(task),
      model: modelFor(provider, chatId, task) || null,
      advisor: advisorFor(provider, chatId, task) || null,
      intelligence: intelligenceFor(task),
      speed: speedFor(task),
      reasoningEffort: reasoningEffortFor(provider, task),
      command: compactCommand(built.cmd, built.args),
      ...teamFieldsForTask(task),
    }),
  });
  let output = "";
  let lineBuf = "";
  let progressCount = 1;
  let canceled = false;
  let firstOutputLogged = false;
  let lastChunkAt = Date.now();
  let keepaliveTimer = null;
  let lastProgressLogAt = 0;
  let progressFlushTimer = null;
  const pendingProgressLines = [];
  const flushProgressLines = () => {
    if (progressFlushTimer) {
      clearTimeout(progressFlushTimer);
      progressFlushTimer = null;
    }
    if (pendingProgressLines.length === 0) return;
    const lines = pendingProgressLines.splice(0, pendingProgressLines.length);
    pushProgressFrame(channel, key, {
      provider,
      chatId,
      taskId,
      sentAtMs: Date.now(),
      replyToId,
      repoId: repo.id,
      repoName: repo.name,
      cwd,
      workMode: workModeFor(task),
      model: modelFor(provider, chatId, task) || null,
      advisor: advisorFor(provider, chatId, task) || null,
      line: lines.join("\n"),
    });
  };
  const enqueueProgressLine = (line) => {
    pendingProgressLines.push(line);
    if (!progressFlushTimer) {
      progressFlushTimer = setTimeout(flushProgressLines, 75);
    }
  };
  // Live "Thinking · N tokens" counter. `--include-partial-messages` streams reasoning as
  // `thinking_delta` events; we accumulate the current block's chars and push a THROTTLED
  // synthetic `vibe_thinking` progress line (never the raw deltas — that would flood the
  // server's whole-buffer reparse). Token estimate ≈ chars/4 (mirrors the desktop's live
  // estimate; the settled count comes from the history transcript's usage once done).
  const thinkingState = { chars: 0, active: false, lastEmitAt: 0, lastTokens: -1 };
  const emitThinking = (force) => {
    if (progressCount >= MAX_PROGRESS_LINES) return;
    const tokens = Math.max(1, Math.round(thinkingState.chars / 4));
    const now = Date.now();
    if (!force && (now - thinkingState.lastEmitAt < 350 || tokens === thinkingState.lastTokens)) {
      return;
    }
    thinkingState.lastEmitAt = now;
    thinkingState.lastTokens = tokens;
    progressCount++;
    enqueueProgressLine(
      JSON.stringify({ type: "vibe_thinking", tokens, active: thinkingState.active })
    );
  };
  // Fold one raw stream-json line into the thinking counter. Returns quietly for any line
  // that isn't a partial thinking event. Gated on a cheap substring test so we only
  // JSON.parse the (few) partial-message lines.
  const trackThinking = (line) => {
    // Claude: partial stream_event thinking_delta.
    if (line.includes("stream_event")) {
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        return;
      }
      const inner = obj && obj.type === "stream_event" ? obj.event : null;
      if (!inner || typeof inner.type !== "string") return;
      if (inner.type === "content_block_start" && inner.content_block && inner.content_block.type === "thinking") {
        thinkingState.chars = 0;
        thinkingState.active = true;
      } else if (inner.type === "content_block_delta" && inner.delta && inner.delta.type === "thinking_delta") {
        thinkingState.chars += String(inner.delta.thinking || "").length;
        thinkingState.active = true;
        emitThinking(false);
      } else if (inner.type === "content_block_stop" && thinkingState.active) {
        thinkingState.active = false;
        emitThinking(true);
      } else if (inner.type === "message_stop") {
        thinkingState.active = false;
      }
      return;
    }
    // Grok/Agy: thought chunks — coalesce into the same vibe_thinking ticker.
    if ((provider === "grok" || provider === "agy") && line.includes('"thought"')) {
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        return;
      }
      if (obj && obj.type === "thought" && typeof obj.data === "string") {
        thinkingState.chars += obj.data.length;
        thinkingState.active = true;
        emitThinking(false);
      } else if (obj && (obj.type === "text" || obj.type === "end" || obj.type === "tool_use")) {
        if (thinkingState.active) {
          thinkingState.active = false;
          emitThinking(true);
        }
      }
    }
  };

  const onChunk = (buf) => {
    const text = buf.toString();
    lastChunkAt = Date.now();
    if (!firstOutputLogged) {
      firstOutputLogged = true;
      const now = Date.now();
      console.log(
        `[vibe-bridge] latency first-output spawn→first=${now - spawnAt}ms ` +
          `recv→first=${now - recvAt}ms chat=${chatId} task=${taskId}`
      );
    }
    output += text;
    lineBuf += text;
    let idx;
    while ((idx = lineBuf.indexOf("\n")) >= 0) {
      const line = lineBuf.slice(0, idx).replace(/\r$/, "");
      lineBuf = lineBuf.slice(idx + 1);
      if (!line) continue;
      // Coalesce partial thinking deltas into a throttled live token counter (does not
      // itself forward the raw partial line — see streamable()).
      trackThinking(line);
      try {
        captureRateLimitsFromLine(provider, line);
      } catch (_) {}
      const sid = captureSessionId(line);
      if (sid) {
        // Fork detection: if the run REPORTS a session id different from the one we
        // asked it to resume, the CLI forked a new session (the reply then lands
        // under an id the phone's history filter doesn't recognize → "new chat").
        const askedResume = resumeIdFor(task);
        if (askedResume && sid !== askedResume && sessionByChat.get(chatId) !== sid) {
          console.log(
            `[vibe-bridge] session FORK ${provider} chat=${chatId} ` +
              `resumeAsked=${askedResume} reported=${sid}`
          );
        }
        sessionByChat.set(chatId, sid);
        const entry = runningTasks.get(key);
        if (entry && entry.sessionId !== sid) {
          entry.sessionId = sid;
          console.log(
            `[vibe-bridge][history-link] provider=${provider} chat=${chatId} ` +
              `task=${taskId} session=${sid}`
          );
          // Publish the newly learned session id immediately. The phone can now
          // overlay running state onto the real history row instead of inventing a
          // separate `running:<taskId>` row until the next heartbeat.
          pushBridgeStatus(channel);
        }
      }
      // Lead-driven team spawn (also detected server-side from progress lines).
      try {
        maybeDetectTeamSpawn(channel, task, line);
      } catch (_) {}
      // Fable advisor failure signals → Sol fallback (async, non-blocking).
      if (
        /advisor.*(unavailable|failed|error)|fable.*(unavailable|failed|error|rate.?limit)/i.test(
          line
        )
      ) {
        maybeRunSolAdvisorFallback(task, line.slice(0, 200), output.slice(-3000)).catch(() => {});
      }
      if (progressCount < MAX_PROGRESS_LINES && line.length <= MAX_LINE_BYTES && streamable(line)) {
        progressCount++;
        const now = Date.now();
        if (progressCount <= 4 || progressCount % 10 === 0 || now - lastProgressLogAt > 5000) {
          lastProgressLogAt = now;
          console.log(
            `[vibe-bridge] latency progress#${progressCount} recv→push=${now - recvAt}ms ` +
              `spawn→push=${now - spawnAt}ms bytes=${output.length} chat=${chatId} task=${taskId}`
          );
        }
        enqueueProgressLine(line);
      }
    }
  };

  child.stdout.on("data", onChunk);
  child.stderr.on("data", onChunk);

  // Grok tools are NOT in streaming-json stdout — they land in the session's
  // updates.jsonl. With a pinned --session-id we can tail that file live and
  // inject Claude-compatible tool_use/tool_result lines into the same progress
  // buffer the server reparses (so progressNodes grow like Claude/Codex).
  // Agy: stdout is plain final text; tools/thinking live in transcript.jsonl.
  let grokTail = null;
  let agyTail = null;
  const injectSynthetic = (line) => {
    if (!line || canceled) return;
    lastChunkAt = Date.now();
    const bare = line.endsWith("\n") ? line.slice(0, -1) : line;
    output += bare + "\n";
    // Reuse Grok thought ticker for Agy transcript thought injections.
    if (provider === "agy" || provider === "grok") {
      try {
        trackThinking(bare);
      } catch {
        /* */
      }
    }
    if (progressCount >= MAX_PROGRESS_LINES) return;
    if (bare.length > MAX_LINE_BYTES) return;
    progressCount++;
    enqueueProgressLine(bare);
  };
  if (provider === "grok" && initialSessionId) {
    grokTail = startGrokUpdatesTail({
      cwd,
      sessionId: initialSessionId,
      onLine: injectSynthetic,
    });
    const entry = runningTasks.get(key);
    if (entry) entry.grokTail = grokTail;
  }
  if (provider === "agy") {
    agyTail = agySupport.startAgyTranscriptTail({
      cwd,
      sessionId: initialSessionId || null,
      startedAtMs: startedAt,
      onLine: injectSynthetic,
      onSessionId: (sid) => {
        if (!sid) return;
        sessionByChat.set(chatId, sid);
        const entry = runningTasks.get(key);
        if (entry) entry.sessionId = sid;
      },
    });
    const entry = runningTasks.get(key);
    if (entry) entry.agyTail = agyTail;
  }

  // Keepalive: while the CLI is mid-run but silent (long thinking / a quiet
  // tool), re-push the current snapshot so the phone's live turn never appears
  // frozen and a phone that missed a broadcast during a socket drop re-syncs.
  // Skipped when output is actively flowing (a real chunk arrived this window).
  keepaliveTimer = setInterval(() => {
    if (canceled) return;
    if (Date.now() - lastChunkAt < KEEPALIVE_MS) return;
    const idleMs = Date.now() - spawnAt;
    pushProgressFrame(channel, key, {
      provider,
      chatId,
      taskId,
      replyToId,
      repoId: repo.id,
      repoName: repo.name,
      cwd,
      workMode: workModeFor(task),
      model: modelFor(provider, chatId, task) || null,
      advisor: advisorFor(provider, chatId, task) || null,
      stage: "keepalive",
      sentAtMs: Date.now(),
      line: JSON.stringify({ type: "vibe_bridge_keepalive", provider, taskId, elapsedMs: idleMs }),
    });
  }, KEEPALIVE_MS);

  child.on("error", (err) => {
    channel.push("error", {
      ...computerFields(),
      ...teamFieldsForTask(task),
      provider,
      chatId,
      taskId,
      message: `${built.cmd} failed: ${err.message}`,
      replyToId,
    });
  });

  child.on("close", (code) => {
    if (keepaliveTimer) {
      clearInterval(keepaliveTimer);
      keepaliveTimer = null;
    }
    // Final drain of Grok updates.jsonl / Agy transcript so the last tool
    // update isn't lost when stdout's end frame races the file flush.
    try {
      if (grokTail && typeof grokTail.stop === "function") grokTail.stop();
    } catch (_) {}
    try {
      if (agyTail && typeof agyTail.stop === "function") agyTail.stop();
    } catch (_) {}
    // Deliver any coalesced burst before the final result. The server processes
    // channel pushes in order, so the phone sees the last live state first.
    flushProgressLines();
    // Agy print mode only prints the final answer as plain text — fold it into
    // a text NDJSON event so the server extract path matches Grok.
    if (provider === "agy" && output && !output.includes('"type":"text"') && !output.includes('"type": "text"')) {
      const plain = String(output)
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith("{"))
        .join("\n")
        .trim();
      if (plain) {
        const textLine = JSON.stringify({ type: "text", data: plain });
        output += (output.endsWith("\n") ? "" : "\n") + textLine + "\n";
        const sid = sessionByChat.get(chatId) || (agyTail && agyTail.sessionId) || null;
        if (sid) {
          output += JSON.stringify({ type: "end", stopReason: "end_turn", sessionId: sid }) + "\n";
        }
      }
    }
    runningTasks.delete(key);
    writeBridgeHeartbeat();
    pushBridgeStatus(channel);
    // A slot just freed — admit the next queued task (if any) right away.
    drainPendingTasks();
    // The run is done — re-push this chat's transcript so the live "running" flag on
    // the last turn clears and the phone collapses it into the "Worked" card.
    refireHistoryWatch(chatId);
    // The agent has finished reading them — don't leave image attachments in the repo.
    for (const attachment of attachments) {
      try {
        fs.unlinkSync(attachment.path);
      } catch (_) {}
    }
    const durationMs = Date.now() - startedAt;
    const terminalFailure = providerTerminalFailure(provider, output);
    canceled =
      canceled ||
      child.signalCode === "SIGTERM" ||
      child.signalCode === "SIGKILL" ||
      !!(terminalFailure && terminalFailure.canceled);
    const afterGit = gitSnapshot(cwd);
    let exitStatus = code == null ? (canceled ? 130 : 1) : code;
    if (exitStatus === 0 && terminalFailure && terminalFailure.failed) {
      exitStatus = terminalFailure.canceled ? 130 : 1;
    }
    console.log(
      `[vibe-bridge] done ${provider} chat=${chatId} task=${taskId} exit=${exitStatus} ${durationMs}ms`
    );
    // Detect subscription/rate-limit failures so the phone can show a usage banner
    // instead of inserting a "demo model" / limit bubble that shifts the list.
    try {
      const failReason =
        (terminalFailure && terminalFailure.reason) ||
        (exitStatus !== 0 ? String(output || "").slice(-800) : "");
      if (failReason && rememberUsageLimitHit(provider, failReason)) {
        console.log(`[vibe-bridge] usage limit hit provider=${provider} chat=${chatId}`);
      } else if (exitStatus !== 0 && isUsageLimitText(output)) {
        rememberUsageLimitHit(provider, output);
      }
    } catch (_) {}
    const agentRuntime = runtimePayload({
      provider,
      task,
      taskId,
      repo,
      built,
      exitStatus,
      durationMs,
      before: beforeGit,
      after: afterGit,
      canceled,
      output,
    });
    // Flag the result so the server/iOS can route limit failures to the banner
    // without inserting a transcript row.
    if (isUsageLimitText(output) || (terminalFailure && isUsageLimitText(terminalFailure.reason))) {
      agentRuntime.usageLimitHit = true;
      const cached = lastRateLimitsByProvider.get(provider);
      if (cached && cached.message) agentRuntime.usageLimitMessage = cached.message;
    }
    // Team scratch sweep (safety net): boards/briefs under .vibe/team/ are
    // temporary by contract and carry the run id in their filenames. The lead is
    // told to clean them up; sweep here so forgotten files never accumulate.
    // Success only — a failed run keeps its board for debugging.
    if (exitStatus === 0 && !canceled && isTeamLeadTask(task)) {
      try {
        const runBase = String(taskId || "").split(":")[0];
        const teamDir = path.join(cwd, ".vibe", "team");
        if (runBase && fs.existsSync(teamDir)) {
          for (const name of fs.readdirSync(teamDir)) {
            if (name.includes(runBase)) {
              fs.unlinkSync(path.join(teamDir, name));
              console.log(`[vibe-bridge] team scratch swept ${name} task=${taskId}`);
            }
          }
        }
      } catch (_) {}
    }
    // Team FE/UI work → Gemini (Agy) advise-only review into handoff (best-effort).
    if (exitStatus === 0 && !canceled && (task.teamRunId || task.team_run_id)) {
      try {
        maybeRunGeminiUiAdvisor(task, agentRuntime, output);
      } catch (_) {}
    }
    const resultPayload = {
      ...computerFields(),
      provider,
      chatId,
      taskId,
      output,
      exitStatus,
      durationMs,
      replyToId,
      requesterUserId,
      repoId: repo.id,
      repoName: repo.name,
      cwd,
      workMode: workModeFor(task),
      ...teamFieldsForTask(task),
      ...runtimeResultField(agentRuntime),
      ...liveAgentActionsField(provider, output),
    };
    if (agentRuntime.usageLimitHit) {
      resultPayload.usageLimitHit = true;
      if (agentRuntime.usageLimitMessage) {
        resultPayload.usageLimitMessage = agentRuntime.usageLimitMessage;
      }
    }
    rememberFinishedTask(key, {
      provider,
      chatId,
      taskId,
      repo,
      runtime: agentRuntime,
      finishedAt: Date.now(),
      // Kept so a result that lands while the socket is down can be re-pushed on
      // reconnect (see the rejoin recovery in connect()).
      resultPayload,
    });
    rememberRuntime(provider, chatId, agentRuntime);
    channel.push("result", resultPayload);
    fanoutLanEvent("result", resultPayload);
    // Plan mode: the model proposed but made no edits. Surface the plan to the
    // phone for approval (the phone re-sends an "implement" run on approve).
    try {
      maybeEmitPlanApproval(channel, {
        provider,
        task,
        chatId,
        taskId,
        replyToId,
        repo,
        output,
        exitStatus,
      });
    } catch (err) {
      console.error(`[vibe-bridge] plan approval emit failed: ${(err && err.message) || err}`);
    }
  });

  return {
    taskId,
    cancel() {
      canceled = true;
      if (keepaliveTimer) {
        clearInterval(keepaliveTimer);
        keepaliveTimer = null;
      }
      try {
        child.kill("SIGTERM");
        setTimeout(() => {
          if (!child.killed) child.kill("SIGKILL");
        }, 2500).unref?.();
      } catch (_) {}
    },
  };
}

// ── Session history (Claude Code + Codex local conversation stores) ──────
//
// The phone (via the server) can ask the connected computer for the agent's
// own past conversations so they render in the Claude/Codex profile. We read
// the CLIs' local session logs read-only:
//   Claude → ~/.claude/projects/<encoded-cwd>/<session>.jsonl  (ai-title + msgs)
//   Codex  → ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl       (session_meta + msgs)
// `list` returns lightweight topic summaries; `detail` returns the transcript.

const HISTORY_LIST_LIMIT = 40;
const HISTORY_MSG_LIMIT = 600;

function clip(value, n) {
  if (typeof value !== "string") return "";
  const s = value.replace(/\s+/g, " ").trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

// Length-cap a string WITHOUT destroying its line structure. clip() collapses
// every whitespace run (incl. "\n") to a single space — correct for one-line
// labels (bash command, topic title) but it flattens markdown answers, narration
// prose, and terminal output into a single paragraph. clipText preserves newlines
// and intra-line indentation (diffs, code, JSON), only trimming trailing spaces
// per line and capping runaway blank-line runs, then applies the length cap.
function clipText(value, n) {
  if (typeof value !== "string") return "";
  const s = value
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{4,}/g, "\n\n\n")
    .trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

// A user message that is purely machine/IDE/environment scaffolding — never a topic.
function isContextMessage(text) {
  if (typeof text !== "string") return true;
  const head = text.slice(0, 400);
  return (
    /^\s*<(environment_context|user_instructions|INSTRUCTIONS|permissions|ide_opened_file|ide_selection|local-command-caveat|command-name|system-reminder|turn_aborted|turn_context|user_action)/i.test(head) ||
    /^\s*#\s*Context from my IDE/i.test(head) ||
    /^\s*#?\s*AGENTS\.md instructions/i.test(head) ||
    /^\s*Here is a list of plugins that are available but not installed/i.test(head) ||
    /^\s*Vibe bridge startup prepared these instruction files for this project/i.test(head) ||
    /^\s*The following is the Codex agent history/i.test(head) ||
    /^\s*The user interrupted the previous turn/i.test(head) ||
    /## Active (file|selection)/i.test(head)
  );
}

function cleanTopicCandidate(text) {
  if (typeof text !== "string" || isContextMessage(text)) return null;
  let t = text.replace(
    /<(environment_context|user_instructions|INSTRUCTIONS|permissions|system-reminder|local-command-caveat|command-name|command-message|command-args|ide_opened_file|ide_selection)[\s\S]*?<\/\1>/gi,
    " "
  );
  t = t.replace(/^\s*(<[^>]+>\s*)+/, " ");
  for (const raw of t.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("<")) continue;
    if (/AGENTS\.md|caveat:/i.test(line)) continue;
    if (/^#{1,4}\s*(context from|active file|attached|open tabs?|cursor|selection|agents|environment|instructions)/i.test(line)) continue;
    if (/^(active file|cwd|shell|repo|branch)\s*:/i.test(line)) continue;
    if (/^(continue|cont|resume|keep going|go on|ok|okay|yes)$/i.test(line)) continue;
    return clip(line, 80);
  }
  return null;
}

// Strip machine-injected wrapper blocks from a message for readable display.
function cleanMessageText(text) {
  if (typeof text !== "string") return "";
  let t = text.replace(
    /<(environment_context|user_instructions|INSTRUCTIONS|permissions|system-reminder|local-command-caveat|command-name|command-message|command-args|ide_opened_file|ide_selection)[\s\S]*?<\/\1>/gi,
    " "
  );
  // Codex app attachments are persisted as an XML-like wrapper followed by the
  // user's actual text (`[Image #1] …`). Remove only the wrapper/marker; the prompt
  // after it is the real conversational turn and must remain visible in History.
  t = t.replace(/<image\b[^>]*>[\s\S]*?<\/image>/gi, " ");
  t = t.replace(/<\/?[a-z][^>]*>/gi, " ");
  t = t.replace(/^(?:\s*\[Image #\d+\]\s*)+/i, "");
  return t.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
}

// Vibe work/group prompts wrap the actual human message in operating rules and
// shared-agent context. Codex persists that whole wrapper as its user turn. Recover
// the terminal message section so History can show the user's bubble and use it as
// a title candidate instead of showing/hiding the injected prompt.
function extractVibeUserPrompt(text) {
  if (typeof text !== "string") return null;
  let body = text;
  let wrapped = false;

  if (/^\s*Vibe bridge startup prepared these instruction files for this project/i.test(body)) {
    const taskMarker = /(?:^|\n)User task:\s*(?:\n|$)/i.exec(body);
    if (!taskMarker) return null;
    body = body.slice(taskMarker.index + taskMarker[0].length);
    wrapped = true;
  }

  // These are the terminal labels emitted by LocalAgentWorker. Use the last one:
  // shared-memory examples can themselves contain an older "Request:"/"Message:".
  const terminalMarkers = [
    /(?:^|\n)Message:\s*(?:\n|$)/gi,
    /(?:^|\n)Request:\s*(?:\n|$)/gi,
    /(?:^|\n)Latest team request:\s*(?:\n|$)/gi,
    /(?:^|\n)Latest request for you(?:\s*\([^\n)]*\))?:\s*(?:\n|$)/gi,
    /(?:^|\n)Latest message for you(?:\s*\([^\n)]*\))?:\s*(?:\n|$)/gi,
  ];
  let terminal = null;
  for (const pattern of terminalMarkers) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(body)) !== null) {
      const end = match.index + match[0].length;
      if (!terminal || end > terminal.end) terminal = { end };
      if (match[0].length === 0) pattern.lastIndex += 1;
    }
  }
  if (terminal) {
    body = body.slice(terminal.end);
    wrapped = true;
  }

  if (!wrapped) return null;

  // Attachment materialization is transport context, not part of the chat text.
  body = body.replace(
    /^\s*The user attached \d+ image file\(s\) to this message\.[\s\S]*?\n\s*\n/i,
    ""
  );
  return body.trim();
}

// Users often paste Xcode / device logs after a short request. Cut at the first
// tool/build/log boundary so History bubbles and titles keep the human prose.
function stripCodexPastePollution(text) {
  if (typeof text !== "string" || !text) return text;
  const markers = [
    /\s+ExecuteExternalTool\b/,
    /\n\s*Command line invocation:/i,
    /\n\s*SwiftDriver\b/,
    /\n\s*CompileSwift\b/,
    /\n\s*Ld\s+\//,
    /\n\s*note:\s+/i,
    // Mid-line path dumps after a short human sentence (no newline before the path).
    /\s+-\s*sdk\s+\/Applications\/Xcode\.app\//i,
    /\s+\/Applications\/Xcode\.app\//,
    /\s+\/tmp\/vibe-device-build\//,
    /\n\s*\/Applications\/Xcode\.app\//,
    /\n\s*\/tmp\/vibe-device-build\//,
    /\n\s*\[(?:ChatEngine|AgentBridgeHistory|AvatarPin|MediaDrop|MainThreadStall|VibeAgentKitStreamingText)\]/,
    /\n\s*\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+\w+\[\d+/,
    // Pasted `xcodebuild` argv clusters: " -project ios/… -scheme …"
    /\s+-project\s+\S+\.xcodeproj\b/i,
    /\s+-destination\s+['"]?platform=iOS/i,
    /\s+-derivedDataPath\s+\/tmp\//i,
    /\n```/,
  ];
  let cut = text.length;
  for (const re of markers) {
    const match = re.exec(text);
    // Keep a minimum human lead-in so a real request that mentions "error:" mid-sentence
    // is not wiped when a later log dump lands.
    if (match && match.index >= 12 && match.index < cut) cut = match.index;
  }
  const trimmed = text.slice(0, cut).trim();
  return trimmed.length >= 8 ? trimmed : text.trim();
}

// Codex IDE integrations wrap a genuine prompt in a context preamble:
//   # Context from my IDE setup:
//   …
//   ## My request for Codex:
//   <actual prompt>
// Treating the whole record as context erased every user bubble. Extract the request
// section first; context-only/AGENTS records remain suppressed.
function codexUserMessageText(text) {
  if (typeof text !== "string") return "";
  let raw = extractVibeUserPrompt(text) ?? text;
  const marker = /^##\s*My request for Codex:\s*$/im.exec(raw);
  if (marker) raw = raw.slice(marker.index + marker[0].length);
  else if (isContextMessage(raw)) return "";
  return stripCodexPastePollution(cleanMessageText(raw));
}

function normalizeCodexTitleKey(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .replace(/[.…]+$/g, "")
    .trim()
    .toLowerCase();
}

// Ungenerated Codex titles are the first prompt (or a truncated/prefix copy of it).
// Real Codex-generated names are short, title-like, and diverge from the prompt body.
function isRawCodexTitleCandidate(title, firstMessage) {
  const raw = String(title || "").trim();
  if (!raw) return true;
  if (/^vibe bridge startup\b/i.test(raw)) return true;
  if (/^you are codex\b/i.test(raw)) return true;
  if (/^#\s*agents\.md\b/i.test(raw)) return true;
  if (/\n/.test(raw) && raw.length > 48) return true;
  if (raw.length > 90) return true;
  if (/ExecuteExternalTool|xcodebuild|SwiftDriver|\/tmp\/vibe-device-build/i.test(raw)) return true;

  const titleKey = normalizeCodexTitleKey(raw);
  const firstKey = normalizeCodexTitleKey(firstMessage);
  if (!titleKey) return true;
  if (firstKey) {
    if (titleKey === firstKey) return true;
    // Prefix match with a length/ellipsis guard so a real short name like
    // "Fix login" is kept even when the prompt starts with those words.
    const looksTruncated = /[….]{1,3}$/.test(String(title || "").trim()) || /[a-z0-9]$/i.test(raw) && raw.length >= 40;
    if (
      firstKey.startsWith(titleKey) &&
      titleKey.length >= 24 &&
      (looksTruncated || titleKey.length >= 36 || firstKey.length > titleKey.length + 12)
    ) {
      return true;
    }
  }
  return false;
}

// Codex CLI/exec sessions often have no generated thread_name. Keep canonical
// names when present, but distill a short chat-sized label from the recovered
// human task rather than leaking the raw first prompt (or "Codex session").
function codexFallbackTitle(text, role = "user") {
  let value = role === "user" ? codexUserMessageText(text) : cleanMessageText(text);
  if (!value || isContextMessage(value)) return null;

  const greetingFallback = value
    .replace(/^(?:\s*\[Image #\d+\]\s*)+/i, "")
    .replace(/^\s*@codex\b[\s,:-]*/i, "")
    .trim();
  value = value
    .replace(/^(?:\s*\[Image #\d+\]\s*)+/i, "")
    .replace(/^\s*@codex\b[\s,:-]*/i, "")
    .trim();
  if (role === "assistant") {
    value = value
      .replace(/^\s*(?:yes|sure|okay)\b[\s,!.-]*/i, "")
      .replace(/^\s*i\s+see\s+/i, "")
      .replace(/^\s*(?:the\s+)?image\s+(?:is|shows|contains)\s+/i, "")
      .trim();
    // Setup/progress narration is not a chat name. Keep scanning until Codex
    // describes the task/result itself (important for image-only Vibe turns).
    if (/^(?:i(?:'|’)m|i(?:'|’)ll|i am)\s+(?:first\s+)?(?:read|check|inspect|trace|open|look|start|use|ask)\b/i.test(value)) {
      return null;
    }
    if (/^(?:the\s+)?(?:repo|repository|project)\s+(?:is|has|looks)\b/i.test(value)) return null;
    if (/(?:duplicated|overlapping)/i.test(value) && /(?:reply|message|chat)\s+bubble/i.test(value)) {
      return "Fix duplicated reply bubble";
    }
  }
  if (!value) {
    const greeting = clip(greetingFallback.replace(/[.!?,\s]+$/g, "").trim(), 24);
    return greeting ? greeting.charAt(0).toUpperCase() + greeting.slice(1) : null;
  }

  // Cut at the earliest blank line / fence / log line so paste dumps never become the name.
  const blank = value.search(/\n\s*\n/);
  if (blank > 12) value = value.slice(0, blank);
  const fence = value.indexOf("```");
  if (fence > 12) value = value.slice(0, fence);
  const logLine = value.search(
    /\n\s*(?:xcodebuild\b|ExecuteExternalTool\b|error:|warning:|\bat\s+\S)/i
  );
  if (logLine > 12) value = value.slice(0, logLine);
  if (value.trim().length < 8) value = greetingFallback || value;

  // Prefer the first actual prose line over markdown headings/file pointers.
  const lines = value.split("\n").map((line) => line.trim()).filter(Boolean);
  value = lines.find((line) =>
    !line.startsWith("<") &&
    !/^#{1,6}\s/.test(line) &&
    !/^(?:[-*]\s*)?\/[^\s]+$/.test(line) &&
    !/^(?:xcodebuild|ExecuteExternalTool|error:|warning:)\b/i.test(line)
  ) || lines[0] || "";
  value = value.replace(/^[-*]\s+/, "").replace(/^["'`]+|["'`]+$/g, "").trim();

  // Strip conversational filler repeatedly, then normalize common intents into labels.
  for (let i = 0; i < 3; i++) {
    const next = value
      .replace(/^\s*(?:hey|hi|hello)\b[\s,!.-]*/i, "")
      .replace(/^(?:please\s+)?(?:can|could|would)\s+you\s+/i, "")
      .replace(/^i\s+(?:want|need|would like)\s+(?:you\s+)?to\s+/i, "")
      .replace(/^take\s+a\s+look\s+at\s+/i, "")
      .replace(/^(?:please\s+)?(?:check|check out|look at|review)\s+/i, "")
      .replace(/^there\s+(?:is|are)(?:\s+an?)?(?:\s+another)?\s+(?:issue|problem|bug)s?(?:\s+(?:with|in|for|that))?\s+/i, "Fix ")
      .replace(/^(?:(?:the|another|other)\s+)?(?:issue|problem|bug)\s+(?:is|with|that)\s+/i, "Fix ")
      .replace(/^look\s+at\s+/i, "")
      .replace(/^i(?:'|’)m\s+/i, "")
      .replace(/^i(?:'|’)ll\s+/i, "")
      .trim();
    if (next === value) break;
    value = next;
  }

  // A frequent bridge debugging prompt has enough misspelling/noise that merely
  // clipping it is still not a useful name; retain its semantic core.
  if (/codex/i.test(value) && /pa+y?laod|payload/i.test(value) && /exec|command|raw|parse|node/i.test(value)) {
    return "Fix Codex payload and command rendering";
  }
  if (/codex/i.test(value) && /(?:history|chat).{0,24}title|title.{0,24}(?:history|chat|name|row)|shows\s+raw/i.test(value)) {
    return "Fix Codex history titles";
  }
  if (/\bios\b/i.test(value) && /list/i.test(value) && /(?:latency|delay|empty|push|open)/i.test(value)) {
    return "Fix chat list open latency";
  }

  // First sentence, then a tight word/character cap at a word boundary (no ellipsis).
  const sentence = value.match(/^(.{4,}?)(?:[.!?](?:\s|$)|$)/);
  if (sentence && sentence[1]) value = sentence[1];
  value = value.replace(/\s+/g, " ").replace(/[,:;\s-]+$/g, "").trim();
  if (!value) return null;
  const words = value.split(" ").filter(Boolean);
  if (words.length > 7) value = words.slice(0, 7).join(" ");
  if (value.length > 42) {
    const clipped = value.slice(0, 42);
    const boundary = clipped.lastIndexOf(" ");
    value = (boundary >= 16 ? clipped.slice(0, boundary) : clipped).trim();
  }
  value = value.replace(/[,:;\s-]+$/g, "").trim();
  return value ? value.charAt(0).toUpperCase() + value.slice(1) : null;
}

function isWeakCodexTitle(value) {
  const title = String(value || "")
    .replace(/^[\s.…—\-–]+/, "")
    .replace(/[.!?…—\-–]+$/g, "")
    .trim()
    .toLowerCase();
  return (
    !title ||
    title === "codex session" ||
    title === "untitled" ||
    // Assistant self-intro is not a conversation name.
    /^(?:i(?:'|’)?m\s+)?codex(?:\s+here)?$/.test(title) ||
    /^(?:hi[, ]+)?i(?:'|’)?m\s+codex\b/.test(title) ||
    /^(?:see|view|check|review|look at)\s+(?:this|these)(?:\s+(?:image|images|photo|photos|screenshot|screenshots))?$/.test(title) ||
    /^(?:here (?:is|are)|this is)\s+(?:the\s+)?(?:image|images|photo|photos|screenshot|screenshots)$/.test(title) ||
    /^(?:image|images|photo|photos|screenshot|screenshots)$/.test(title) ||
    // Still a raw prompt fragment rather than a conversation name.
    title.length > 48 ||
    /^(?:take a look|call (?:the |all )?agents|guys |again|yep|continue)\b/.test(title)
  );
}

function resolveCodexTopic(stored, userTopic, assistantTopic) {
  if (stored && !isWeakCodexTitle(stored) && !isRawCodexTitleCandidate(stored)) return stored;
  const storedDistilled = stored ? codexFallbackTitle(stored) : null;
  const user = userTopic && !isWeakCodexTitle(userTopic) ? userTopic : null;
  const fromStored = storedDistilled && !isWeakCodexTitle(storedDistilled) ? storedDistilled : null;
  const assistant = assistantTopic && !isWeakCodexTitle(assistantTopic) ? assistantTopic : null;
  return user || fromStored || assistant || userTopic || storedDistilled || assistantTopic || "Codex session";
}

// Skip ephemeral scratch/test working dirs so the list shows real work.
function isEphemeralProject(p) {
  // Match /tmp, /private/tmp, and any nested path under them (with or without trailing slash).
  return /(^|\/)(private\/)?tmp(\/|$)/.test(p) || /vibe-(bridge|agent)-/.test(p) || /self-test/.test(p);
}

function decodeClaudeProject(name) {
  return String(name || "").replace(/-/g, "/");
}

async function readJsonl(file, onEvent, maxBytes) {
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  let bytes = 0;
  try {
    for await (const line of rl) {
      if (line.trim()) {
        let ev = null;
        try { ev = JSON.parse(line); } catch { ev = null; }
        if (ev && onEvent(ev) === false) break;
      }
      // Optional head cap: stop once we've streamed maxBytes (roster head-scans pass
      // this so an unbounded 700 MB rollout can't be read whole just for a topic).
      // Counted AFTER the line is processed so a record straddling the cap is still
      // seen. Streaming reads yield to the event loop between chunks, so unlike the
      // old fs.readSync head-scan this never blocks the WebSocket heartbeat.
      if (maxBytes) { bytes += Buffer.byteLength(line) + 1; if (bytes >= maxBytes) break; }
    }
  } finally {
    rl.close();
  }
}

// — Claude —
async function claudeSummary(file) {
  let topic = null, firstUser = null, lastTs = null, messages = 0, model = null;
  await readJsonl(file, (ev) => {
    const t = ev.type;
    if (t === "ai-title" && ev.aiTitle) topic = ev.aiTitle;
    else if (t === "user" || t === "assistant") {
      messages++;
      if (ev.timestamp) lastTs = ev.timestamp;
      if (
        t === "assistant" &&
        ev.message &&
        ev.message.model &&
        String(ev.message.model) !== "<synthetic>"
      ) {
        model = String(ev.message.model);
      }
      if (t === "user" && !firstUser) {
        const c = ev.message && ev.message.content;
        if (typeof c === "string") {
          const clean = cleanTopicCandidate(c);
          if (clean) firstUser = clean;
        }
      }
    }
  });
  return { topic: topic || firstUser || "Untitled", lastTs, messages, model };
}

function claudeSessionFiles() {
  const root = path.join(os.homedir(), ".claude", "projects");
  const out = [];
  if (!fs.existsSync(root)) return out;
  for (const proj of fs.readdirSync(root)) {
    const projPath = decodeClaudeProject(proj);
    if (isEphemeralProject(projPath)) continue;
    const projDir = path.join(root, proj);
    let entries;
    try { entries = fs.readdirSync(projDir); } catch { continue; }
    for (const f of entries) {
      if (!f.endsWith(".jsonl")) continue;
      const full = path.join(projDir, f);
      let st;
      try { st = fs.statSync(full); } catch { continue; }
      out.push({ id: f.replace(/\.jsonl$/, ""), file: full, project: projPath, mtime: st.mtimeMs, size: st.size });
    }
  }
  return out;
}

// ── History runtime reconstruction ──────────────────────────────────
// Browsing a past session must show the same "N files changed +X −Y" card the
// live run produces — including sessions you ran directly on your computer
// (not from the phone). The live path diffs the working tree; history can't
// (the tree has moved on, or the run happened elsewhere), so we rebuild the
// card from the transcript's own edit operations: Claude `tool_use`
// (Edit/MultiEdit/Write/NotebookEdit) and Codex `apply_patch` envelopes. The
// output is the exact `diff` shape runtimePayload() emits, so the iOS card
// renders unchanged, and it is sealed via runtimeResultField() → the server
// only ever sees ciphertext.
const MAX_RUNTIME_FILES = 80;

function countTextLines(value) {
  const s = value == null ? "" : String(value);
  if (s === "") return 0;
  const trimmed = s.replace(/\n+$/, "");
  return trimmed === "" ? 1 : trimmed.split("\n").length;
}

function newRuntimeAccumulator() {
  return { byPath: new Map(), order: [], additions: 0, deletions: 0, patch: "", patchTruncated: false };
}

function accumulateRuntimeFile(acc, filePath, status, additions, deletions, patchBlock) {
  const clean = diffFilePath(filePath);
  if (!clean) return;
  let entry = acc.byPath.get(clean);
  if (!entry) {
    entry = { path: clean, name: path.basename(clean), status, additions: 0, deletions: 0 };
    acc.byPath.set(clean, entry);
    acc.order.push(clean);
  } else if (entry.status !== status && entry.status !== "A" && entry.status !== "A?") {
    entry.status = status === "D" ? "D" : "M";
  }
  entry.additions += additions;
  entry.deletions += deletions;
  acc.additions += additions;
  acc.deletions += deletions;
  if (patchBlock && !acc.patchTruncated) {
    if (acc.patch.length + patchBlock.length > MAX_DIFF_BYTES) acc.patchTruncated = true;
    else acc.patch += patchBlock;
  }
}

// Build a git-style unified block from a before/after string pair.
function unifiedDiffBlock(filePath, oldStr, newStr, status) {
  const rel = diffFilePath(filePath);
  if (!rel) return "";
  const oldLines = oldStr == null || oldStr === "" ? [] : String(oldStr).replace(/\n$/, "").split("\n");
  const newLines = newStr == null || newStr === "" ? [] : String(newStr).replace(/\n$/, "").split("\n");
  const header =
    `diff --git a/${rel} b/${rel}\n` +
    (status === "A"
      ? `new file mode 100644\n--- /dev/null\n+++ b/${rel}\n`
      : `--- a/${rel}\n+++ b/${rel}\n`) +
    `@@ -${oldLines.length ? "1," + oldLines.length : "0,0"} +${newLines.length ? "1," + newLines.length : "0,0"} @@\n`;
  const body =
    (oldLines.length ? oldLines.map((l) => "-" + l).join("\n") + "\n" : "") +
    (newLines.length ? newLines.map((l) => "+" + l).join("\n") + "\n" : "");
  return header + body;
}

// Claude assistant content blocks → accumulate file edits.
function collectClaudeEdits(acc, content) {
  if (!Array.isArray(content)) return;
  for (const b of content) {
    if (!b || b.type !== "tool_use") continue;
    const inp = b.input || {};
    if (b.name === "Edit") {
      const oldS = inp.old_string || "";
      const newS = inp.new_string || "";
      accumulateRuntimeFile(acc, inp.file_path, "M", countTextLines(newS), countTextLines(oldS), unifiedDiffBlock(inp.file_path, oldS, newS, "M"));
    } else if (b.name === "MultiEdit" && Array.isArray(inp.edits)) {
      for (const e of inp.edits) {
        const oldS = (e && e.old_string) || "";
        const newS = (e && e.new_string) || "";
        accumulateRuntimeFile(acc, inp.file_path, "M", countTextLines(newS), countTextLines(oldS), unifiedDiffBlock(inp.file_path, oldS, newS, "M"));
      }
    } else if (b.name === "Write") {
      const body = inp.content || "";
      accumulateRuntimeFile(acc, inp.file_path, "A", countTextLines(body), 0, unifiedDiffBlock(inp.file_path, "", body, "A"));
    } else if (b.name === "NotebookEdit") {
      const target = inp.notebook_path || inp.file_path;
      const oldS = inp.old_source || "";
      const newS = inp.new_source || "";
      accumulateRuntimeFile(acc, target, "M", countTextLines(newS), countTextLines(oldS), unifiedDiffBlock(target, oldS, newS, "M"));
    }
  }
}

// Codex `apply_patch` envelope → accumulate file edits. Codex emits these as a
// `custom_tool_call` (sometimes `function_call`) whose `input` is the classic
// `*** Begin Patch / *** Add|Update|Delete File:` text.
function collectCodexEdits(acc, payload) {
  for (const p of codexUnwrapActionPayloads(payload)) {
    const isPatch =
      (p.type === "custom_tool_call" || p.type === "function_call") && /apply_patch/i.test(p.name || "");
    if (!isPatch) continue;
    const input = codexPatchTextFromPayload(p);
    if (!input) continue;
    for (const f of parseApplyPatchEnvelope(input)) {
      accumulateRuntimeFile(acc, f.path, f.status, f.additions, f.deletions, f.patchBlock);
    }
  }
}

function parseApplyPatchEnvelope(input) {
  const lines = String(input).split("\n");
  const files = [];
  let cur = null;
  const flush = () => {
    if (cur) files.push(cur);
    cur = null;
  };
  for (const line of lines) {
    const mAdd = line.match(/^\*\*\* Add File: (.+)$/);
    const mUpd = line.match(/^\*\*\* Update File: (.+)$/);
    const mDel = line.match(/^\*\*\* Delete File: (.+)$/);
    if (mAdd || mUpd || mDel) {
      flush();
      cur = { path: (mAdd || mUpd || mDel)[1].trim(), status: mAdd ? "A" : mDel ? "D" : "M", additions: 0, deletions: 0, body: [] };
      continue;
    }
    if (/^\*\*\* /.test(line)) continue; // Begin Patch / End Patch / Move to: …
    if (!cur) continue;
    cur.body.push(line);
    if (line.startsWith("+") && !line.startsWith("+++")) cur.additions++;
    else if (line.startsWith("-") && !line.startsWith("---")) cur.deletions++;
  }
  flush();
  return files.map((f) => {
    const rel = diffFilePath(f.path);
    const head =
      `diff --git a/${rel} b/${rel}\n` +
      (f.status === "A"
        ? `new file mode 100644\n--- /dev/null\n+++ b/${rel}\n`
        : f.status === "D"
          ? `deleted file mode 100644\n--- a/${rel}\n+++ /dev/null\n`
          : `--- a/${rel}\n+++ b/${rel}\n`);
    const body = f.body.join("\n");
    return {
      path: rel,
      status: f.status,
      additions: f.additions,
      deletions: f.deletions,
      patchBlock: head + (body ? body + (body.endsWith("\n") ? "" : "\n") : ""),
    };
  });
}

// Elapsed time of a turn from its first (user prompt) to last (assistant) event
// timestamp. Returns undefined when either timestamp is missing/unparseable.
function turnDurationMs(startTs, endTs) {
  if (!startTs || !endTs) return undefined;
  const a = Date.parse(startTs);
  const b = Date.parse(endTs);
  if (Number.isNaN(a) || Number.isNaN(b) || b < a) return undefined;
  return b - a;
}

function buildHistoryRuntime(provider, acc, durationMs) {
  if (!acc.order.length) return null;
  const files = acc.order.map((p) => acc.byPath.get(p));
  return {
    provider,
    status: "done",
    workMode: "history",
    // Per-turn elapsed time reconstructed from the transcript timestamps so the
    // phone's "Worked for Xs · N steps" line reads the same on history as live.
    ...(typeof durationMs === "number" && durationMs > 0 ? { durationMs } : {}),
    diff: {
      git: false,
      filesChanged: files.length,
      additions: acc.additions,
      deletions: acc.deletions,
      files,
      patch: acc.patch,
      patchTruncated: acc.patchTruncated,
    },
    controls: { canCancel: false, canRevert: false },
  };
}

// Seal ONE turn's reconstructed runtime onto a specific message, so each turn
// shows the patch IT applied — inline, where it happened (matching the Codex
// app) — instead of one consolidated card dumped at the end of the session.
function sealHistoryRuntime(provider, message, acc, durationMs) {
  const runtime = buildHistoryRuntime(provider, acc, durationMs);
  if (!runtime) return false;
  const field = runtimeResultField(runtime);
  if (!field || !field.agentRuntimeEnc) return false; // no key → never send plaintext
  Object.assign(message, field);
  return true;
}

function windowHistoryMessages(messages, limit, before) {
  const cap = Math.max(1, Math.min(Number(limit) || HISTORY_MSG_LIMIT, HISTORY_MSG_LIMIT));
  const cursor = String(before || "").trim();
  let end = messages.length;
  if (cursor) {
    const index = messages.findIndex((m) => String((m && (m.uid || m.id)) || "") === cursor);
    if (index >= 0) end = index;
  }
  const start = Math.max(0, end - cap);
  const window = messages.slice(start, end);
  return {
    messages: window,
    truncated: start > 0 || end < messages.length,
    hasMoreBefore: start > 0,
    nextBefore: window.length ? String(window[0].uid || window[0].id || "") : null,
    windowStart: start,
    windowEnd: end,
    totalMessages: messages.length,
  };
}

// A real user prompt (not a tool_result/tool-output envelope) opens a new turn.
function messageHasUserText(m) {
  if (!m) return false;
  if (typeof m.content === "string") return m.content.trim().length > 0;
  if (Array.isArray(m.content)) {
    return m.content.some((b) => b && b.type === "text" && String(b.text || "").trim().length > 0);
  }
  return false;
}

const CLAUDE_BACKGROUND_TERMINAL_STATUSES = new Set([
  "completed", "complete", "done", "success", "failed", "failure", "error",
  "cancelled", "canceled", "interrupted", "stopped", "killed",
]);

// Claude Code reports an async Bash lifecycle in two different records: the
// tool_result carries `backgroundTaskId`, then a task-notification XML envelope
// announces completion. Keep that lifecycle separate from model turn boundaries:
// a synthetic task notification is not a new user prompt, while a pending task
// remains live even if the assistant has already emitted `end_turn`.
function claudeTaskNotification(event) {
  if (!event || typeof event !== "object") return null;
  const candidates = [
    event.content,
    event.message && event.message.content,
    event.attachment && event.attachment.prompt,
  ];
  const raw = candidates.find((value) => typeof value === "string" && /<task-notification>/i.test(value));
  if (!raw) return null;
  const idMatch = raw.match(/<task-id>\s*([^<]+?)\s*<\/task-id>/i);
  const statusMatch = raw.match(/<status>\s*([^<]+?)\s*<\/status>/i);
  const id = idMatch ? String(idMatch[1]).trim() : "";
  const status = statusMatch ? String(statusMatch[1]).trim().toLowerCase() : "";
  return id ? { id, status } : null;
}

function updateClaudeBackgroundTasks(activeTaskIds, event) {
  if (!(activeTaskIds instanceof Set) || !event || typeof event !== "object") return false;
  const backgroundTaskId = String(
    (event.toolUseResult && event.toolUseResult.backgroundTaskId) || ""
  ).trim();
  if (backgroundTaskId) activeTaskIds.add(backgroundTaskId);

  const notification = claudeTaskNotification(event);
  if (!notification) return false;
  if (
    event.operation === "remove"
    || CLAUDE_BACKGROUND_TERMINAL_STATUSES.has(notification.status)
  ) {
    activeTaskIds.delete(notification.id);
  } else {
    activeTaskIds.add(notification.id);
  }
  return true;
}

// A session is "live" when its transcript file is actively being appended to (a
// turn is in flight) — detected by a recent mtime — OR when it matches a task the
// bridge itself spawned and is still running. This lets the phone show a live badge
// in history (and open it as a live stream) for sessions started EITHER by the
// bridge OR directly in the user's own desktop terminal (which never enter the
// `runningTasks` Map, so mtime-freshness is the only signal we have for those).
const LIVE_SESSION_WINDOW_MS = Number(process.env.VIBE_HISTORY_LIVE_WINDOW_MS || 15_000);
// How long a STRUCTURALLY unfinished Claude turn (last assistant stop_reason is
// tool_use/absent, i.e. a tool is executing or the model is thinking) stays flagged
// live after the transcript's last write. Thinking blocks and long tools (builds)
// write NOTHING for minutes, so the 15s mtime window alone flips `running` off
// mid-turn — the phone then blanks the working cell until the next write ("list
// jumps to empty" during thinking). stop_reason=end_turn settles instantly, so this
// generous cap only ever lingers after a mid-turn crash/kill.
const DETAIL_MIDTURN_STALE_MS = Number(process.env.VIBE_DETAIL_MIDTURN_STALE_MS || 15 * 60_000);
// Grok is chatty during tools (updates.jsonl ticks often). Using Claude's 15-minute
// mid-turn window left finished Grok turns marked running for up to 15 minutes after
// the last write — phone stuck on "Thinking…" with an empty/suppressed body until a
// full chat reopen. Quiet for ~30s ⇒ settled; turn_completed seals immediately.
const GROK_DETAIL_MIDTURN_STALE_MS = Number(
  process.env.VIBE_GROK_DETAIL_MIDTURN_STALE_MS || 30_000
);
// Upper bound on how far a roster summary streams into a rollout before giving up on
// finding a topic. With streaming early-exit (codexSummaryFromHead) a session with a
// normal-sized preamble stops in the first few KB; this cap only bites resumed sessions
// that bury their first real prompt under a giant history dump (they degrade to the
// generic "Codex session" title — the session still opens and its detail still loads).
// Was 8 MB read SYNCHRONOUSLY per file, which blocked the event loop for seconds across
// a 40-file list — a primary cause of the socket drops + list-retry storm. Now async +
// cached, so this is a one-time bound; raise via env for full topic parity at 8 MB.
const CODEX_SUMMARY_HEAD_BYTES = Number(process.env.VIBE_CODEX_SUMMARY_HEAD_BYTES || 4 * 1024 * 1024);
// Model/effort are emitted on `turn_context`, including when a resumed session
// changes model. Read a bounded tail for roster rows so we see the latest context
// without turning a 40-row list into 40 full rollout scans. The result is stored in
// historySummaryCache alongside the head summary and invalidated only when the file
// grows.
const CODEX_METADATA_TAIL_BYTES = Number(
  process.env.VIBE_CODEX_METADATA_TAIL_BYTES || 1024 * 1024
);

// Per-file roster-summary cache. Session/rollout files only ever APPEND, and every
// field the list surfaces (topic, meta, first-message count) is derived from the file
// HEAD, so a cached summary stays valid as long as the file's byte size is unchanged.
// This is what collapses the phone's list-retry storm: dozens of identical `list`
// requests re-use one scan per file, and an unchanged old session costs a single stat()
// on re-list instead of a multi-MB read. A live/growing session changes size every
// append → cache miss → recompute, which is exactly what we want.
const historySummaryCache = new Map(); // file path -> { size, summary }
const MAX_HISTORY_SUMMARY_CACHE = 240;

function getCachedSummary(file, size) {
  const hit = historySummaryCache.get(file);
  return hit && hit.size === size ? hit.summary : null;
}
function setCachedSummary(file, size, summary) {
  historySummaryCache.set(file, { size, summary });
  if (historySummaryCache.size > MAX_HISTORY_SUMMARY_CACHE) {
    const oldest = historySummaryCache.keys().next().value;
    if (oldest !== undefined) historySummaryCache.delete(oldest);
  }
}

async function codexMetadataFromTail(file, size) {
  const fileSize = Math.max(
    0,
    Number(size) || await fs.promises.stat(file).then((stat) => stat.size).catch(() => 0)
  );
  const length = Math.min(fileSize, CODEX_METADATA_TAIL_BYTES);
  if (!length) return {};
  let handle;
  try {
    handle = await fs.promises.open(file, "r");
    const buffer = Buffer.allocUnsafe(length);
    const position = Math.max(0, fileSize - length);
    const { bytesRead } = await handle.read(buffer, 0, length, position);
    let body = buffer.subarray(0, bytesRead).toString("utf8");
    if (position > 0) body = body.slice(Math.max(0, body.indexOf("\n") + 1));
    let model = null;
    let reasoningEffort = null;
    for (const line of body.split("\n")) {
      if (!line) continue;
      let event;
      try { event = JSON.parse(line); } catch { continue; }
      if (!event || event.type !== "turn_context" || !event.payload) continue;
      if (event.payload.model && String(event.payload.model).trim()) {
        model = String(event.payload.model).trim();
      }
      if (event.payload.effort && String(event.payload.effort).trim()) {
        reasoningEffort = String(event.payload.effort).trim();
      }
    }
    return {
      ...(model ? { model } : {}),
      ...(reasoningEffort ? { reasoningEffort } : {}),
    };
  } catch {
    return {};
  } finally {
    if (handle) await handle.close().catch(() => {});
  }
}

function runningSessionIdSet(provider) {
  const set = new Set();
  const want = String(provider || "").trim().toLowerCase();
  for (const entry of runningTasks.values()) {
    if (want && entry.provider && String(entry.provider).toLowerCase() !== want) continue;
    if (entry.sessionId) set.add(entry.sessionId);
  }
  // Desktop/IDE sessions are discovered outside `runningTasks`; include them so
  // their History row receives the same live-state and accurate-count treatment.
  for (const entry of externalProviderActivity) {
    if (want && entry.provider && String(entry.provider).toLowerCase() !== want) continue;
    if (entry.sessionId) set.add(entry.sessionId);
  }
  return set;
}

// A history row and its bridge task share the durable provider session id. Prefer
// the newest matching task if reconnect/re-delivery briefly leaves more than one
// entry, and expose only values the live task actually knows.
function runningSessionMetadata(provider, sessionId) {
  if (!sessionId) return {};
  const want = String(provider || "").trim().toLowerCase();
  let match = null;
  for (const entry of runningTasks.values()) {
    if (!entry || entry.sessionId !== sessionId) continue;
    if (want && String(entry.provider || "").toLowerCase() !== want) continue;
    if (!match || Number(entry.startedAt || 0) > Number(match.startedAt || 0)) match = entry;
  }
  if (!match) return {};
  const metadata = {};
  if (match.model) metadata.model = match.model;
  if (match.reasoningEffort) metadata.reasoningEffort = match.reasoningEffort;
  return metadata;
}

function sessionIsLive(mtime, id, runningIds) {
  if (id && runningIds && runningIds.has(id)) return true;
  return mtime != null && Date.now() - mtime < LIVE_SESSION_WINDOW_MS;
}

// Codex emits explicit turn boundaries. Use them instead of treating a quiet
// transcript as an idle session: reasoning and long-running commands can produce
// no file writes for minutes while the turn is still active.
const CODEX_LIVE_TAIL_BYTES = Number(process.env.VIBE_CODEX_LIVE_TAIL_BYTES || 1024 * 1024);
async function codexOpenTurnState(file, size) {
  const length = Math.min(Math.max(0, Number(size) || 0), CODEX_LIVE_TAIL_BYTES);
  if (!length) return null;
  let handle;
  try {
    handle = await fs.promises.open(file, "r");
    const buffer = Buffer.allocUnsafe(length);
    const position = Math.max(0, Number(size) - length);
    const { bytesRead } = await handle.read(buffer, 0, length, position);
    let text = buffer.subarray(0, bytesRead).toString("utf8");
    // A bounded tail may begin in the middle of a JSONL record.
    if (position > 0) text = text.slice(Math.max(0, text.indexOf("\n") + 1));
    let state = null;
    for (const line of text.split("\n")) {
      if (!line) continue;
      let event;
      try { event = JSON.parse(line); } catch { continue; }
      if (!event || event.type !== "event_msg" || !event.payload) continue;
      const type = event.payload.type;
      if (type === "task_started") state = true;
      else if (type === "task_complete" || type === "turn_aborted") state = false;
    }
    return state;
  } catch {
    return null;
  } finally {
    if (handle) await handle.close().catch(() => {});
  }
}

// Claude's last real user message opens a turn; tool_use keeps it open and
// end_turn closes it. Synthetic CLI notices are not model-turn boundaries.
async function claudeOpenTurnState(file, size) {
  const length = Math.min(Math.max(0, Number(size) || 0), CODEX_LIVE_TAIL_BYTES);
  if (!length) return null;
  let handle;
  try {
    handle = await fs.promises.open(file, "r");
    const buffer = Buffer.allocUnsafe(length);
    const position = Math.max(0, Number(size) - length);
    const { bytesRead } = await handle.read(buffer, 0, length, position);
    let text = buffer.subarray(0, bytesRead).toString("utf8");
    if (position > 0) text = text.slice(Math.max(0, text.indexOf("\n") + 1));
    let state = null;
    const activeBackgroundTasks = new Set();
    for (const line of text.split("\n")) {
      if (!line) continue;
      let event;
      try { event = JSON.parse(line); } catch { continue; }
      const isTaskNotification = updateClaudeBackgroundTasks(activeBackgroundTasks, event);
      if (isTaskNotification) continue;
      if (!event || (event.type !== "user" && event.type !== "assistant")) continue;
      const message = event.message || {};
      if (event.type === "user") {
        if (!event.isMeta && messageHasUserText(message)) state = true;
        continue;
      }
      if (String(message.model || "") === "<synthetic>") continue;
      const stop = String(message.stop_reason || "").toLowerCase();
      state = stop === "end_turn" ? false : true;
    }
    return activeBackgroundTasks.size > 0 ? true : state;
  } catch {
    return null;
  } finally {
    if (handle) await handle.close().catch(() => {});
  }
}

async function listClaude(limit) {
  const files = claudeSessionFiles().sort((a, b) => b.mtime - a.mtime).slice(0, limit);
  const runningIds = runningSessionIdSet("claude");
  const results = [];
  for (const s of files) {
    let sum = getCachedSummary(s.file, s.size);
    if (!sum) { sum = await claudeSummary(s.file); setCachedSummary(s.file, s.size, sum); }
    if (sum.messages === 0) continue;
    const explicitTurnState = await claudeOpenTurnState(s.file, s.size);
    const live = runningIds.has(s.id)
      || (explicitTurnState == null
        ? sessionIsLive(s.mtime, s.id, runningIds)
        : explicitTurnState);
    const liveMetadata = runningSessionMetadata("claude", s.id);
    results.push({
      provider: "claude",
      id: s.id,
      topic: sum.topic,
      project: s.project,
      projectName: path.basename(s.project),
      updatedAt: sum.lastTs || new Date(s.mtime).toISOString(),
      messageCount: sum.messages,
      live,
      ...(liveMetadata.model || sum.model ? { model: liveMetadata.model || sum.model } : {}),
      ...(liveMetadata.reasoningEffort ? { reasoningEffort: liveMetadata.reasoningEffort } : {}),
    });
  }
  return results;
}

// Human-readable one-liners for tool actions, so a session watched live shows
// what the agent is DOING (running a command, editing a file) in-line — not
// just its text and a summary card. Applied to the trailing in-progress turn.
function safeBase(x) {
  try { return path.basename(String(x || "")); } catch (_) { return String(x || ""); }
}
function claudeActionLine(b) {
  const inp = b.input || {};
  switch (b.name) {
    case "Bash": {
      const cmd = String(inp.command || "").replace(/\s+/g, " ").trim();
      return cmd ? "⚡ $ " + clip(cmd, 160) : "⚡ Bash";
    }
    case "Edit":
    case "MultiEdit": return "✏️ Edit " + safeBase(inp.file_path);
    case "Write": return "📝 Write " + safeBase(inp.file_path);
    case "NotebookEdit": return "✏️ Edit " + safeBase(inp.notebook_path || inp.file_path);
    case "Read": return "📖 Read " + safeBase(inp.file_path);
    case "Grep": return "🔎 Grep " + clip(String(inp.pattern || ""), 80);
    case "Glob": return "🔎 Glob " + clip(String(inp.pattern || ""), 80);
    case "TodoWrite": return "✅ Updated todos";
    case "Task": return "🤖 " + clip(String(inp.description || "subagent"), 80);
    case "WebFetch": return "🌐 " + clip(String(inp.url || ""), 80);
    case "WebSearch": return "🌐 Search " + clip(String(inp.query || ""), 80);
    default: return "🔧 " + (b.name || "tool");
  }
}
function codexActionLine(p) {
  const name = String(p.name || "");
  if (/apply_patch/i.test(name)) {
    const input = typeof p.input === "string" ? p.input : typeof p.arguments === "string" ? p.arguments : "";
    const files = parseApplyPatchEnvelope(input).map((f) => safeBase(f.path));
    return "✏️ Edit " + (files.length ? clip(files.join(", "), 120) : "files");
  }
  if (isCodexShellToolName(name)) {
    const cmd = codexCommandFromPayload(p);
    return cmd ? "⚡ $ " + clip(cmd, 160) : "⚡ shell";
  }
  return "🔧 " + (name || "tool");
}

// ── Structured tool detail (E2E-encrypted) ──────────────────────────
// The one-line action label above stays plaintext (it is already in the known
// Tier-2 gap: command strings + prose reach the server). The SENSITIVE detail —
// command OUTPUT, todo contents, diff counts, search hits — rides a per-message
// `agentActionEnc` blob encrypted with the SAME arte1 key as the diff card, so
// the server stays zero-knowledge. The phone joins detail→entry by `uid` and
// renders a rich inline card (collapsible command+output, todo list, …).
// `read` is included so the file slice Claude read rides the encrypted blob and
// powers the read row's "expand to full file" layer (line range still shows in the
// plaintext preview via the node's start/end).
const OUTPUT_KINDS = new Set(["bash", "search", "task", "web", "tool", "mcp", "read"]);
const MAX_ACTION_OUTPUT = 4000;

// Claude: mcp__server__tool · Grok use_tool: vibeask__ask_fable · Codex: server+tool fields.
function parseMcpToolRef(nameOrId) {
  const raw = String(nameOrId || "").trim();
  if (!raw) return null;
  let m = raw.match(/^mcp__(.+?)__(.+)$/i);
  if (m) return { server: m[1], tool: m[2], raw };
  // Grok MCP tools often omit the mcp__ prefix: vibeask__ask_fable
  m = raw.match(/^([a-z][a-z0-9_-]*)__([a-z0-9_-]+)$/i);
  if (m) return { server: m[1], tool: m[2], raw };
  return null;
}

// User-facing MCP tool labels. Wire ids stay ask_fable / ask_user / …;
// the phone should never show the internal Fable product name.
function prettyMcpToolLabel(tool) {
  const raw = String(tool || "").replace(/_/g, " ").trim();
  if (!raw) return "";
  if (/^ask\s+fable$/i.test(raw) || /^fable$/i.test(raw)) return "ask advisor";
  return raw;
}

function mcpActionDetail(name, input) {
  const inp = input && typeof input === "object" ? input : {};
  const fromName = parseMcpToolRef(name);
  const fromInput = parseMcpToolRef(inp.tool_name || inp.toolName || inp.name);
  const p = fromName || fromInput;
  if (!p) return null;
  const prettyTool = prettyMcpToolLabel(p.tool);
  return {
    kind: "mcp",
    name: p.raw,
    server: p.server,
    tool: p.tool,
    // Compact target for the phone: "vibeask · ask advisor"
    target: p.server + " · " + prettyTool,
    // Question / query rides encrypted output path when result arrives; keep a
    // short prompt preview on the action for the sheet header.
    prompt: clip(String(inp.question || inp.query || inp.prompt || ""), 200),
  };
}
// Per-edit unified-diff cap (rides the encrypted blob for the edit row's patch layer).
const MAX_NODE_PATCH = 6000;

function toolResultText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => (typeof b === "string" ? b : b && typeof b.text === "string" ? b.text : ""))
      .filter(Boolean)
      .join("\n");
  }
  if (typeof content === "object" && typeof content.text === "string") return content.text;
  return "";
}

function claudeActionDetail(b) {
  const inp = b.input || {};
  switch (b.name) {
    case "Bash":
      return { kind: "bash", command: String(inp.command || ""), description: inp.description ? String(inp.description) : "" };
    case "Edit":
      return { kind: "edit", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path), additions: countTextLines(inp.new_string), deletions: countTextLines(inp.old_string), patch: clipText(unifiedDiffBlock(inp.file_path, inp.old_string || "", inp.new_string || "", "M"), MAX_NODE_PATCH) };
    case "MultiEdit": {
      let add = 0, del = 0, patch = "";
      if (Array.isArray(inp.edits)) for (const e of inp.edits) {
        const oldS = (e && e.old_string) || "", newS = (e && e.new_string) || "";
        add += countTextLines(newS); del += countTextLines(oldS);
        patch += unifiedDiffBlock(inp.file_path, oldS, newS, "M");
      }
      return { kind: "edit", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path), additions: add, deletions: del, patch: clipText(patch, MAX_NODE_PATCH) };
    }
    case "Write":
      return { kind: "write", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path), additions: countTextLines(inp.content), patch: clipText(unifiedDiffBlock(inp.file_path, "", inp.content || "", "A"), MAX_NODE_PATCH) };
    case "NotebookEdit":
      return { kind: "edit", path: diffFilePath(inp.notebook_path || inp.file_path), name: safeBase(inp.notebook_path || inp.file_path), additions: countTextLines(inp.new_source), deletions: countTextLines(inp.old_source), patch: clipText(unifiedDiffBlock(inp.notebook_path || inp.file_path, inp.old_source || "", inp.new_source || "", "M"), MAX_NODE_PATCH) };
    case "Read": {
      // Carry the line range Claude requested so the row preview reads "Read foo.swift (12–48)";
      // the file slice itself rides the encrypted blob (read ∈ OUTPUT_KINDS) for the expand layer.
      const d = { kind: "read", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path) };
      const offset = Number(inp.offset), limit = Number(inp.limit);
      if (Number.isFinite(offset) && offset > 0) {
        d.start = offset;
        if (Number.isFinite(limit) && limit > 0) d.end = offset + limit - 1;
      } else if (Number.isFinite(limit) && limit > 0) {
        d.start = 1; d.end = limit;
      }
      return d;
    }
    case "Grep":
      return { kind: "search", tool: "grep", pattern: String(inp.pattern || ""), path: inp.path ? String(inp.path) : "", glob: inp.glob ? String(inp.glob) : "" };
    case "Glob":
      return { kind: "search", tool: "glob", pattern: String(inp.pattern || ""), path: inp.path ? String(inp.path) : "" };
    case "TodoWrite":
      return { kind: "todo", todos: Array.isArray(inp.todos) ? inp.todos.map((t) => ({ content: String((t && t.content) || ""), status: String((t && t.status) || ""), activeForm: String((t && t.activeForm) || "") })) : [] };
    case "Task":
      return { kind: "task", description: String(inp.description || ""), subagent: String(inp.subagent_type || "") };
    case "WebFetch":
      return { kind: "web", url: String(inp.url || ""), prompt: clip(String(inp.prompt || ""), 200) };
    case "WebSearch":
      return { kind: "web", query: String(inp.query || "") };
    default: {
      const mcp = mcpActionDetail(b.name, inp);
      if (mcp) return mcp;
      return { kind: "tool", name: String(b.name || "tool") };
    }
  }
}

// Codex only has a raw shell, so a bare `rg …` / `sed -n …` / `cat …` would render
// as low-level "Run <shell>" noise — unlike Claude, whose high-level Read/Grep tools
// map to clean "Read foo.swift" / "Search pattern" rows. Classify the command's lead
// program into the SAME read/search progress kinds so a Codex turn's feed reads like
// Claude's. Anything we don't recognize stays a plain "Run <command>" (kind "bash").
const CODEX_READ_CMDS = new Set(["cat", "head", "tail", "less", "more", "bat", "nl", "sed"]);
const CODEX_SEARCH_CMDS = new Set(["rg", "grep", "egrep", "fgrep", "ag", "ack", "ripgrep"]);

// Minimal shell tokenizer: splits on unquoted whitespace and strips one layer of
// single/double quotes (so `rg -n "A|B" path` → ["rg","-n","A|B","path"]).
function codexShellTokens(command) {
  const tokens = [];
  let cur = "";
  let quote = null;
  let started = false;
  for (const c of String(command || "")) {
    if (quote) {
      if (c === quote) quote = null;
      else cur += c;
    } else if (c === '"' || c === "'") {
      quote = c;
      started = true;
    } else if (c === " " || c === "\t") {
      if (started) tokens.push(cur);
      cur = "";
      started = false;
    } else {
      cur += c;
      started = true;
    }
  }
  if (started) tokens.push(cur);
  return tokens;
}

// Last positional (non-flag, non-numeric-range) argument → the file a read touches.
function codexLastPathArg(args) {
  for (let i = args.length - 1; i >= 0; i--) {
    const a = args[i];
    if (!a || a.startsWith("-")) continue;
    if (/^\d+(,\d+)?[a-z]?$/i.test(a)) continue; // skip sed ranges like 1,220p
    return a;
  }
  return "";
}

// First positional argument → the pattern a grep/rg searches for (respect `-e PAT`).
function codexSearchPattern(args) {
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-e" || a === "--regexp" || a === "--regex") return args[i + 1] || "";
    if (a && !a.startsWith("-")) return a;
  }
  return "";
}

// Turn a raw Codex shell command into a friendly progress detail (read/search),
// falling back to a plain "Run <command>" (kind "bash") when unrecognized.
function codexShellDetail(rawCmd) {
  const command = String(rawCmd || "").replace(/\s+/g, " ").trim();
  const bash = { kind: "bash", command, description: "" };
  if (!command) return bash;

  // Unwrap a `bash -lc '<inner>'` / `sh -c "<inner>"` wrapper (and strip the inner
  // command's surrounding quotes), then classify the first pipeline segment
  // (`rg … | head` is still a search).
  let work = command;
  const wrap = work.match(/^(?:\/\S+\/)?(?:bash|sh|zsh)\s+-[a-z]*c\s+(.+)$/i);
  if (wrap) {
    work = wrap[1].trim();
    const q = work[0];
    if ((q === '"' || q === "'") && work[work.length - 1] === q) work = work.slice(1, -1).trim();
  }
  const firstSeg = work.split(/\s*(?:&&|\|\||[|;])\s*/)[0] || work;

  let tokens = codexShellTokens(firstSeg);
  while (tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[0])) tokens = tokens.slice(1);
  while (tokens.length && (tokens[0] === "sudo" || tokens[0] === "command")) tokens = tokens.slice(1);
  if (!tokens.length) return bash;

  const prog = String(tokens[0]).split("/").pop().toLowerCase();
  const args = tokens.slice(1);

  if (CODEX_READ_CMDS.has(prog)) {
    // sed is a "read" only in its common `-n 'A,Bp'` print form; an editing sed
    // (e.g. `sed -i …`) stays a plain command.
    if (prog === "sed") {
      const range = args.find((a) => /^\d+,\d+p?$/.test(a));
      if (!args.includes("-n") && !range) return bash;
    }
    const file = codexLastPathArg(args);
    if (!file) return bash;
    const detail = { kind: "read", name: safeBase(file), path: file };
    const range = prog === "sed" ? args.find((a) => /^\d+,\d+p?$/.test(a)) : null;
    const m = range && range.match(/^(\d+),(\d+)/);
    if (m) {
      detail.start = Number(m[1]);
      detail.end = Number(m[2]);
    }
    return detail;
  }

  if (CODEX_SEARCH_CMDS.has(prog)) {
    const pattern = codexSearchPattern(args);
    if (!pattern) return bash;
    return { kind: "search", pattern };
  }

  return bash;
}

function codexDecodedActionInput(p) {
  if (!p || typeof p !== "object") return {};
  const value = p.arguments != null ? p.arguments : p.input;
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  if (typeof value !== "string") return {};
  try {
    const decoded = JSON.parse(value);
    return decoded && typeof decoded === "object" && !Array.isArray(decoded) ? decoded : {};
  } catch (_) {
    return {};
  }
}

function codexPlanTodos(input) {
  const raw = input && (input.todos || input.plan || input.items);
  if (!Array.isArray(raw)) return [];
  return raw.map((item) => ({
    content: String((item && (item.content || item.step)) || ""),
    status: String((item && item.status) || "pending"),
    activeForm: String((item && item.activeForm) || ""),
  })).filter((item) => item.content.trim());
}

function codexActionDetailSingle(p) {
  if (!p) return null;
  const name = String(p.name || "");
  if (/apply_patch/i.test(name)) {
    const input = codexPatchTextFromPayload(p);
    const files = parseApplyPatchEnvelope(input);
    return {
      kind: "edit",
      name: files.map((f) => safeBase(f.path)).join(", "),
      path: files[0] ? files[0].path : "",
      additions: files.reduce((s, f) => s + (f.additions || 0), 0),
      deletions: files.reduce((s, f) => s + (f.deletions || 0), 0),
      files: files.length,
    };
  }
  if (isCodexShellToolName(name)) {
    return codexShellDetail(codexCommandFromPayload(p));
  }
  if (/^(?:view_image|open_image)$/i.test(name)) {
    const input = codexDecodedActionInput(p);
    const imagePath = String(input.path || input.file_path || "");
    return { kind: "read", name: safeBase(imagePath), path: imagePath };
  }
  if (/^(?:update_plan|todo_write|todowrite)$/i.test(name)) {
    return { kind: "todo", todos: codexPlanTodos(codexDecodedActionInput(p)) };
  }
  if (/^(?:spawn_agent|spawn_subagent|delegate_to_subagent)$/i.test(name)) {
    const input = codexDecodedActionInput(p);
    const taskName = String(input.task_name || input.name || input.subagent_type || "subagent");
    return {
      kind: "task",
      description: taskName,
      subagent: taskName,
    };
  }
  if (/^(?:send_message|followup_task)$/i.test(name)) {
    const input = codexDecodedActionInput(p);
    const target = String(input.target || input.task_name || "subagent").replace(/^\/root\//, "");
    return { kind: "task", description: `Message ${target}`, subagent: target };
  }
  // Named MCP tools first (Claude-style `mcp__vibeask__ask_fable`, nested
  // `tools.mcp__vibeask__ask_fable(...)`, or Grok `vibeask__ask_fable`). Do NOT
  // re-wrap an already-qualified name with a default server ("mcp") — that used
  // to produce `mcp__mcp__ask_fable` and drop the real server.
  const namedMcp = mcpActionDetail(name, p.arguments || p.input || {});
  if (namedMcp) return namedMcp;
  // Codex stream item_type `mcp_tool_call` carries discrete server + tool fields.
  const itemType = String(p.item_type || p.type || p.kind || "").toLowerCase();
  if (itemType === "mcp_tool_call") {
    const server = String(p.server || p.mcp_server || "").trim() || "mcp";
    const tool = String(p.tool || p.name || "tool").replace(/^mcp__/i, "");
    const mcp = mcpActionDetail(
      "mcp__" + server + "__" + tool.replace(/^.*__/, ""),
      p.arguments || p.input || {}
    );
    if (mcp) return mcp;
  }
  return { kind: "tool", name: name || "tool" };
}

function codexActionDetails(payload) {
  return codexUnwrapActionPayloads(payload)
    .map(codexActionDetailSingle)
    .filter(Boolean);
}

function codexActionDetail(payload) {
  return codexActionDetails(payload)[0] || null;
}

function isCodexShellToolName(name) {
  return ["exec", "shell", "local_shell", "container.exec", "exec_command", "bash", "run_command"].includes(String(name || ""));
}

// Current Codex app persistence records orchestration calls as an outer
// `custom_tool_call {name:"exec", input:"...tools.exec_command(...)..."}`. The
// operation users care about is the nested tool, not the transport wrapper. Parse
// that small, generated subset without eval/Function so an on-disk transcript can
// never execute code while being opened from History.
const CODEX_EXEC_OUTPUT_HELPERS = new Set([
  "text",
  "image",
  "generatedImage",
  "store",
  "load",
  "notify",
  "yield_control",
]);
const CODEX_CONTINUATION_TOOLS = new Set(["wait", "write_stdin", "wait_agent", "list_agents"]);

function decodeCodexJsStringLiteral(source, start) {
  const quote = source[start];
  if (quote !== '"' && quote !== "'" && quote !== "`") return null;
  let value = "";
  for (let i = start + 1; i < source.length; i++) {
    const ch = source[i];
    if (ch === quote) return { value, end: i + 1 };
    if (ch !== "\\") {
      value += ch;
      continue;
    }
    if (i + 1 >= source.length) return null;
    const next = source[++i];
    switch (next) {
      case "n": value += "\n"; break;
      case "r": value += "\r"; break;
      case "t": value += "\t"; break;
      case "b": value += "\b"; break;
      case "f": value += "\f"; break;
      case "v": value += "\v"; break;
      case "0": value += "\0"; break;
      case "x": {
        const hex = source.slice(i + 1, i + 3);
        if (/^[0-9a-f]{2}$/i.test(hex)) {
          value += String.fromCharCode(parseInt(hex, 16));
          i += 2;
        } else value += next;
        break;
      }
      case "u": {
        const hex = source.slice(i + 1, i + 5);
        if (/^[0-9a-f]{4}$/i.test(hex)) {
          value += String.fromCharCode(parseInt(hex, 16));
          i += 4;
        } else value += next;
        break;
      }
      case "\n": break;
      case "\r":
        if (source[i + 1] === "\n") i += 1;
        break;
      default: value += next;
    }
  }
  return null;
}

function codexJsStringLiterals(source) {
  const values = [];
  const text = String(source || "");
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== '"' && text[i] !== "'" && text[i] !== "`") continue;
    const decoded = decodeCodexJsStringLiteral(text, i);
    if (!decoded) continue;
    values.push(decoded.value);
    i = decoded.end - 1;
  }
  return values;
}

function codexJsPropertyString(source, key) {
  const escaped = String(key).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp("(?:\\b" + escaped + "\\b|[\\\"']" + escaped + "[\\\"'])\\s*:\\s*").exec(String(source || ""));
  if (!match) return "";
  const start = match.index + match[0].length;
  const decoded = decodeCodexJsStringLiteral(String(source || ""), start);
  return decoded ? decoded.value : "";
}

function codexJsPropertyStrings(source, key) {
  const values = [];
  const text = String(source || "");
  const escaped = String(key).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp("(?:\\b" + escaped + "\\b|[\\\"']" + escaped + "[\\\"'])\\s*:\\s*", "g");
  let match;
  while ((match = re.exec(text))) {
    const decoded = decodeCodexJsStringLiteral(text, match.index + match[0].length);
    if (decoded) {
      values.push(decoded.value);
      re.lastIndex = decoded.end;
    }
  }
  return values;
}

// Find generated `tools.<name>(…)` calls without evaluating persisted source. The
// scanner skips string literals and balances parentheses so Promise.all/multi-call
// envelopes can produce one native node per real operation.
function codexNestedToolCalls(source) {
  const calls = [];
  const text = String(source || "");
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '"' || text[i] === "'" || text[i] === "`") {
      const decoded = decodeCodexJsStringLiteral(text, i);
      if (decoded) i = decoded.end - 1;
      continue;
    }
    const match = /^tools\.([A-Za-z0-9_]+)\s*\(/.exec(text.slice(i));
    if (!match) continue;
    const name = match[1];
    const open = i + match[0].lastIndexOf("(");
    let depth = 0;
    let end = text.length;
    for (let j = open; j < text.length; j++) {
      if (text[j] === '"' || text[j] === "'" || text[j] === "`") {
        const decoded = decodeCodexJsStringLiteral(text, j);
        if (decoded) {
          j = decoded.end - 1;
          continue;
        }
      }
      if (text[j] === "(") depth++;
      else if (text[j] === ")" && --depth === 0) {
        end = j;
        break;
      }
    }
    calls.push({ name, source: text.slice(open + 1, end) });
    i = end;
  }
  return calls;
}

function codexPatchTextFromPayload(p) {
  const raw =
    typeof p.input === "string"
      ? p.input
      : typeof p.arguments === "string"
        ? p.arguments
        : p.input && typeof p.input.patch === "string"
          ? p.input.patch
          : "";
  const trimmed = raw.trimStart();
  if (trimmed.startsWith("*** Begin Patch") && raw.includes("*** End Patch")) return raw;
  return codexJsStringLiterals(raw).find(
    (value) => value.includes("*** Begin Patch") && value.includes("*** End Patch")
  ) || "";
}

function codexPlanInputFromSource(source) {
  const steps = codexJsPropertyStrings(source, "step");
  const statuses = codexJsPropertyStrings(source, "status");
  return {
    todos: steps.map((step, index) => ({
      content: step,
      status: statuses[index] || "pending",
      activeForm: "",
    })),
  };
}

function codexJsAssignedArrayStrings(source, variable) {
  const text = String(source || "");
  const escaped = String(variable).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp("\\b(?:const|let|var)\\s+" + escaped + "\\s*=\\s*\\[").exec(text);
  if (!match) return [];
  const open = match.index + match[0].lastIndexOf("[");
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '"' || text[i] === "'" || text[i] === "`") {
      const decoded = decodeCodexJsStringLiteral(text, i);
      if (decoded) {
        i = decoded.end - 1;
        continue;
      }
    }
    if (text[i] === "[") depth++;
    else if (text[i] === "]" && --depth === 0) {
      return codexJsStringLiterals(text.slice(open + 1, i));
    }
  }
  return [];
}

function codexMappedExecInputs(source) {
  const values = codexJsAssignedArrayStrings(source, "cmds");
  if (!values.length) return [];
  const paired = /\.map\s*\(\s*(?:async\s*)?\(\s*\[\s*cmd\s*,\s*workdir\s*\]/.test(source);
  if (paired) {
    const inputs = [];
    for (let i = 0; i + 1 < values.length; i += 2) {
      inputs.push({ command: values[i], workdir: values[i + 1] });
    }
    return inputs;
  }
  return values.map((command) => ({ command }));
}

function codexNestedToolInput(name, source, payload) {
  if (name === "exec_command") {
    return {
      command: codexJsPropertyString(source, "cmd") || codexJsPropertyString(source, "command"),
      workdir: codexJsPropertyString(source, "workdir"),
    };
  }
  if (name === "apply_patch") return codexPatchTextFromPayload(payload);
  if (name === "view_image") return { path: codexJsPropertyString(source, "path") };
  if (name === "web__run") return { query: codexJsPropertyString(source, "q") };
  if (name === "update_plan") return codexPlanInputFromSource(source);
  // Nested MCP: tools.mcp__vibeask__ask_fable({ question: "…" }) or tools.vibeask__ask_fable(…)
  if (/^mcp__/i.test(name) || /^[a-z][a-z0-9_-]*__[a-z0-9_-]+$/i.test(name)) {
    const question =
      codexJsPropertyString(source, "question") ||
      codexJsPropertyString(source, "query") ||
      codexJsPropertyString(source, "prompt");
    return question ? { question } : {};
  }
  return {};
}

function codexUnwrapActionPayloads(payload) {
  if (!payload || typeof payload !== "object") return payload ? [payload] : [];
  const outerName = String(payload.name || payload.tool || "");
  if (CODEX_CONTINUATION_TOOLS.has(outerName)) return [];
  if (outerName !== "exec") return [payload];

  const source =
    typeof payload.input === "string"
      ? payload.input
      : typeof payload.arguments === "string"
        ? payload.arguments
        : "";
  const calls = codexNestedToolCalls(source).filter(
    (call) => !CODEX_EXEC_OUTPUT_HELPERS.has(call.name) && !CODEX_CONTINUATION_TOOLS.has(call.name)
  );
  if (!calls.length) {
    const direct = codexDecodedActionInput(payload);
    return direct.command || direct.cmd ? [payload] : [];
  }
  return calls.flatMap((call) => {
    const input = codexNestedToolInput(call.name, call.source, payload);
    if (call.name === "exec_command" && !input.command) {
      const mapped = codexMappedExecInputs(source);
      if (mapped.length) {
        return mapped.map((mappedInput) => Object.assign({}, payload, {
          name: call.name,
          input: mappedInput,
          arguments: undefined,
        }));
      }
      return [];
    }
    return [Object.assign({}, payload, {
      name: call.name,
      input,
      arguments: undefined,
    })];
  });
}

function codexUnwrapActionPayload(payload) {
  return codexUnwrapActionPayloads(payload)[0] || null;
}

function codexCommandFromPayload(p) {
  let args = {};
  try {
    if (typeof p.arguments === "string") args = JSON.parse(p.arguments) || {};
    else if (typeof p.input === "string") args = JSON.parse(p.input) || {};
    else if (p.arguments && typeof p.arguments === "object") args = p.arguments;
    else if (p.input && typeof p.input === "object") args = p.input;
  } catch (_) {}
  let cmd = args.command || args.cmd;
  if (Array.isArray(cmd)) cmd = cmd.join(" ");
  return String(cmd || "").replace(/\s+/g, " ").trim();
}

// Codex emits the command/MCP result as a separate `function_call_output` /
// `custom_tool_call_output`. Current app persistence stores `output` as an
// ARRAY of `{type:"input_text", text:"…"}` blocks (not a plain string). Older
// shapes used a JSON-wrapped string or stdout/stderr fields. Pull readable text
// from every known shape so Ask Fable / Read / shell results are not empty on iOS.
function codexOutputText(output) {
  if (output == null) return "";
  // Array of content blocks — the common Codex app shape for tool results.
  if (Array.isArray(output)) return toolResultText(output);
  if (typeof output === "string") {
    try {
      const o = JSON.parse(output);
      if (Array.isArray(o)) return toolResultText(o);
      if (o && typeof o.output === "string") return o.output;
      if (o && Array.isArray(o.output)) return toolResultText(o.output);
      if (o && typeof o.aggregated_output === "string") return o.aggregated_output;
      if (o && (typeof o.stdout === "string" || typeof o.stderr === "string")) {
        return [o.stdout, o.stderr].filter(Boolean).join("\n");
      }
      if (o && typeof o.content === "string") return o.content;
      if (o && Array.isArray(o.content)) return toolResultText(o.content);
      if (o && typeof o.text === "string") return o.text;
      if (o && typeof o.result === "string") return o.result;
    } catch (_) {}
    return output;
  }
  if (typeof output === "object") {
    if (typeof output.output === "string") return output.output;
    if (Array.isArray(output.output)) return toolResultText(output.output);
    if (typeof output.aggregated_output === "string") return output.aggregated_output;
    if (typeof output.stdout === "string" || typeof output.stderr === "string") {
      return [output.stdout, output.stderr].filter(Boolean).join("\n");
    }
    if (typeof output.text === "string") return output.text;
    if (typeof output.result === "string") return output.result;
    if (Array.isArray(output.content)) return toolResultText(output.content);
    return toolResultText(output.content);
  }
  return "";
}

function parsedJsonlEvents(output) {
  return String(output || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      try {
        const parsed = JSON.parse(line);
        if (Array.isArray(parsed)) return parsed.filter((item) => item && typeof item === "object");
        if (parsed && typeof parsed === "object") return [parsed];
      } catch (_) {}
      return [];
    });
}

function eventContentBlocks(event) {
  const content =
    event && event.message && Array.isArray(event.message.content)
      ? event.message.content
      : event && Array.isArray(event.content)
        ? event.content
        : null;
  return Array.isArray(content) ? content.filter((block) => block && typeof block === "object") : [];
}

function actionListFromMaps(order, detailByUid, resultByUid) {
  const seen = new Set();
  const actions = [];
  for (const uid of order) {
    if (!uid || seen.has(uid)) continue;
    seen.add(uid);
    const detail = detailByUid.get(uid);
    if (!detail) continue;
    if (OUTPUT_KINDS.has(detail.kind)) {
      const result = resultByUid.get(uid);
      if (result && result.output) {
        detail.output = result.output;
        detail.isError = !!result.isError;
      }
    }
    actions.push(Object.assign({ id: String(uid) }, detail));
  }
  return actions.slice(-60);
}

function liveAgentActionsField(provider, output) {
  let actions = [];
  if (provider === "codex") actions = liveCodexActions(output);
  else if (provider === "claude") actions = liveClaudeActions(output);
  else if (provider === "grok" || provider === "agy") actions = liveGrokActions(output);
  if (!actions.length) return {};
  const enc = encryptRuntimeBlob({ actions });
  return enc ? { agentActionsEnc: enc } : {};
}

// Grok stdout is only thought/text/end; the bridge also injects tool_use /
// tool_result lines from the session updates.jsonl tail. Parse those (plus any
// Claude-shaped content blocks) into the same action list shape as Claude.
function liveGrokActions(output) {
  const detailByUid = new Map();
  const resultByUid = new Map();
  const order = [];
  for (const event of parsedJsonlEvents(output)) {
    if (!event || typeof event !== "object") continue;
    const type = String(event.type || "").toLowerCase();
    if (type === "tool_use") {
      const id = event.id || event.toolCallId || `grok-tool-${order.length}`;
      order.push(id);
      detailByUid.set(id, grokActionDetail(event.name || event.tool || "tool", event.input || event.rawInput || {}));
      continue;
    }
    if (type === "tool_result") {
      const id = event.tool_use_id || event.toolCallId || event.id;
      if (id) {
        resultByUid.set(id, {
          output: clipText(toolResultText(event.content || event.output || event.result), MAX_ACTION_OUTPUT),
          isError: !!(event.is_error || event.isError || String(event.status || "").toLowerCase() === "error"),
        });
      }
      continue;
    }
    for (const block of eventContentBlocks(event)) {
      if (block.type === "tool_use") {
        const id = block.id || `grok-tool-${order.length}`;
        order.push(id);
        detailByUid.set(id, grokActionDetail(block.name, block.input || {}));
      } else if (block.type === "tool_result") {
        const id = block.tool_use_id || block.id;
        if (id) {
          resultByUid.set(id, {
            output: clipText(toolResultText(block.content || block.text || block.result), MAX_ACTION_OUTPUT),
            isError: !!block.is_error,
          });
        }
      }
    }
  }
  return actionListFromMaps(order, detailByUid, resultByUid);
}

// Map Grok Build tool names → the same progress-node kinds Claude/Codex use so
// the phone renders Read / Edit / Run / Search rows instead of opaque "tool".
function grokActionDetail(name, rawInput) {
  let input = rawInput;
  if (typeof rawInput === "string") {
    try {
      input = JSON.parse(rawInput);
    } catch {
      input = {};
    }
  }
  if (!input || typeof input !== "object") input = {};
  const n = String(name || "").trim();
  const lower = n.toLowerCase();

  if (lower === "run_terminal_command" || lower === "bash" || lower === "shell") {
    return {
      kind: "bash",
      command: String(input.command || input.cmd || ""),
      description: input.description ? String(input.description) : "",
    };
  }
  if (lower === "read_file" || lower === "read") {
    const fp = input.target_file || input.file_path || input.path || "";
    const d = { kind: "read", path: diffFilePath(fp), name: safeBase(fp) };
    const offset = Number(input.offset);
    const limit = Number(input.limit);
    if (Number.isFinite(offset) && offset > 0) {
      d.start = offset;
      if (Number.isFinite(limit) && limit > 0) d.end = offset + limit - 1;
    }
    return d;
  }
  if (lower === "search_replace" || lower === "edit" || lower === "str_replace") {
    const fp = input.file_path || input.path || "";
    return {
      kind: "edit",
      path: diffFilePath(fp),
      name: safeBase(fp),
      additions: countTextLines(input.new_string || input.new_str || ""),
      deletions: countTextLines(input.old_string || input.old_str || ""),
      patch: clipText(
        unifiedDiffBlock(fp, input.old_string || input.old_str || "", input.new_string || input.new_str || "", "M"),
        MAX_NODE_PATCH
      ),
    };
  }
  if (lower === "write" || lower === "write_file") {
    const fp = input.file_path || input.path || "";
    return {
      kind: "write",
      path: diffFilePath(fp),
      name: safeBase(fp),
      additions: countTextLines(input.content || ""),
      patch: clipText(unifiedDiffBlock(fp, "", input.content || "", "A"), MAX_NODE_PATCH),
    };
  }
  if (lower === "grep" || lower === "search") {
    return {
      kind: "search",
      tool: "grep",
      pattern: String(input.pattern || input.query || ""),
      path: input.path ? String(input.path) : "",
      glob: input.glob ? String(input.glob) : "",
    };
  }
  if (lower === "list_dir" || lower === "glob" || lower === "list_dir_tree") {
    return {
      kind: "search",
      tool: lower === "glob" ? "glob" : "list",
      pattern: String(input.target_directory || input.pattern || input.path || ""),
      path: input.target_directory ? String(input.target_directory) : "",
    };
  }
  if (lower === "todo_write" || lower === "todowrite") {
    const todos = Array.isArray(input.todos)
      ? input.todos.map((t) => ({
          content: String((t && t.content) || ""),
          status: String((t && t.status) || ""),
          activeForm: String((t && t.activeForm) || ""),
        }))
      : [];
    return { kind: "todo", todos };
  }
  if (lower === "web_search" || lower === "websearch") {
    return { kind: "web", query: String(input.query || "") };
  }
  if (lower === "web_fetch" || lower === "webfetch" || lower === "open_page") {
    return { kind: "web", url: String(input.url || ""), prompt: clip(String(input.prompt || ""), 200) };
  }
  if (lower === "use_tool" || lower === "search_tool") {
    const mcp = mcpActionDetail(n, input);
    if (mcp) return mcp;
    const toolName = String(input.tool_name || input.toolName || input.name || n || "tool");
    return { kind: "tool", name: toolName, target: toolName };
  }
  if (lower === "get_command_or_subagent_output" || lower === "spawn_subagent") {
    return { kind: "task", description: String(input.description || n) };
  }
  return { kind: "tool", name: n || "tool" };
}

function grokSessionDir(cwd, sessionId) {
  return path.join(os.homedir(), ".grok", "sessions", encodeURIComponent(String(cwd || "")), String(sessionId || ""));
}

// Extract plain text from a Grok updates.jsonl tool_call_update content block.
function grokUpdateContentText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((block) => {
        if (!block) return "";
        if (typeof block === "string") return block;
        if (block.type === "content" && block.content) {
          if (typeof block.content === "string") return block.content;
          if (block.content.type === "text" && typeof block.content.text === "string") return block.content.text;
          if (typeof block.content.text === "string") return block.content.text;
        }
        if (block.type === "text" && typeof block.text === "string") return block.text;
        if (typeof block.text === "string") return block.text;
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  if (typeof content === "object") {
    if (typeof content.text === "string") return content.text;
    if (content.content) return grokUpdateContentText(content.content);
  }
  return "";
}

// Convert one updates.jsonl record into synthetic NDJSON lines the server understands.
// Source split (Fable): tools + compacting from this file; thought/text stay on stdout.
function grokUpdateRecordToSyntheticLines(rec) {
  if (!rec || typeof rec !== "object") return [];
  const u = (rec.params && rec.params.update) || rec.update || rec;
  if (!u || typeof u !== "object") return [];
  const kind = String(u.sessionUpdate || u.type || "");
  const out = [];
  if (kind === "tool_call") {
    const id = u.toolCallId || u.tool_call_id || u.id;
    if (!id) return out;
    const meta = (u._meta && (u._meta["x.ai/tool"] || u._meta.xAiTool)) || {};
    const name = meta.name || u.title || "tool";
    let input = u.rawInput != null ? u.rawInput : u.input || {};
    if (typeof input === "string") {
      try {
        input = JSON.parse(input);
      } catch {
        input = { raw: input };
      }
    }
    out.push(JSON.stringify({ type: "tool_use", id, name, input, status: "running" }));
    return out;
  }
  if (kind === "tool_call_update") {
    const id = u.toolCallId || u.tool_call_id || u.id;
    if (!id) return out;
    const status = String(u.status || "").toLowerCase();
    // Mid-flight title/status updates: re-assert tool_use so the label can refresh.
    if (status && status !== "completed" && status !== "failed" && status !== "error" && status !== "cancelled") {
      const meta = (u._meta && (u._meta["x.ai/tool"] || u._meta.xAiTool)) || {};
      const name = meta.name || u.title || "tool";
      let input = u.rawInput != null ? u.rawInput : u.input || {};
      if (typeof input === "string") {
        try {
          input = JSON.parse(input);
        } catch {
          input = { raw: input };
        }
      }
      out.push(JSON.stringify({ type: "tool_use", id, name, input, status: "running" }));
      return out;
    }
    if (status === "completed" || status === "failed" || status === "error" || status === "cancelled") {
      const content = grokUpdateContentText(u.content);
      out.push(
        JSON.stringify({
          type: "tool_result",
          tool_use_id: id,
          content: clipText(content, MAX_ACTION_OUTPUT),
          is_error: status !== "completed",
          status: status === "completed" ? "done" : "error",
        })
      );
    }
    return out;
  }
  // Auto-compact mid-session — phone shows "Compacting conversation…" instead of empty jump.
  if (kind === "auto_compact_started" || kind === "compaction_checkpoint") {
    out.push(
      JSON.stringify({
        type: "auto_compact_started",
        id: "grok-compacting",
        status: "running",
      })
    );
    return out;
  }
  if (kind === "auto_compact_completed") {
    out.push(
      JSON.stringify({
        type: "auto_compact_completed",
        id: "grok-compacting",
        status: "done",
        tokens_before: u.tokens_before != null ? u.tokens_before : u.tokensBefore,
        tokens_after: u.tokens_after != null ? u.tokens_after : u.tokensAfter,
      })
    );
    return out;
  }
  return out;
}

// Tail ~/.grok/sessions/<cwd>/<sessionId>/updates.jsonl while a Grok run is live.
function startGrokUpdatesTail({ cwd, sessionId, onLine }) {
  const dir = grokSessionDir(cwd, sessionId);
  const file = path.join(dir, "updates.jsonl");
  let offset = 0;
  let partial = "";
  let stopped = false;
  let timer = null;
  const seenSynthetic = new Set();

  const drain = () => {
    if (stopped && !fs.existsSync(file)) return;
    try {
      if (!fs.existsSync(file)) return;
      const st = fs.statSync(file);
      if (st.size < offset) {
        // File was truncated/rotated — rescan from start.
        offset = 0;
        partial = "";
      }
      if (st.size === offset) return;
      const fd = fs.openSync(file, "r");
      const len = st.size - offset;
      const buf = Buffer.alloc(Math.min(len, 4 * 1024 * 1024));
      const n = fs.readSync(fd, buf, 0, buf.length, offset);
      fs.closeSync(fd);
      offset += n;
      partial += buf.slice(0, n).toString("utf8");
      let idx;
      while ((idx = partial.indexOf("\n")) >= 0) {
        const line = partial.slice(0, idx);
        partial = partial.slice(idx + 1);
        if (!line.trim()) continue;
        let rec = null;
        try {
          rec = JSON.parse(line);
        } catch {
          continue;
        }
        for (const syn of grokUpdateRecordToSyntheticLines(rec)) {
          // Dedupe identical synthetic lines so repeated updates don't flood.
          const sig = syn.length > 240 ? syn.slice(0, 240) : syn;
          if (seenSynthetic.has(sig)) continue;
          seenSynthetic.add(sig);
          if (seenSynthetic.size > 4000) {
            // Bound memory on very long runs.
            const first = seenSynthetic.values().next().value;
            seenSynthetic.delete(first);
          }
          try {
            onLine(syn);
          } catch (_) {}
        }
      }
    } catch (_) {}
  };

  timer = setInterval(drain, 300);
  // Kick once immediately in case the file already has content.
  drain();
  return {
    file,
    dir,
    stop() {
      if (stopped) return;
      stopped = true;
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
      // One last drain after end so trailing tool_call_update isn't lost.
      drain();
    },
  };
}

function liveClaudeActions(output) {
  const detailByUid = new Map();
  const resultByUid = new Map();
  const order = [];
  for (const event of parsedJsonlEvents(output)) {
    // Live stream-json tags every subagent event with the parent Task's tool_use id;
    // carry it onto the child detail so the node lands at depth 1 / parentId.
    const parentToolUseId =
      typeof event.parent_tool_use_id === "string" && event.parent_tool_use_id
        ? event.parent_tool_use_id
        : "";
    for (const block of eventContentBlocks(event)) {
      if (block.type === "tool_use") {
        const id = block.id || `claude-tool-${order.length}`;
        order.push(id);
        const det = claudeActionDetail(block);
        if (parentToolUseId) det.parentId = parentToolUseId;
        detailByUid.set(id, det);
      } else if (block.type === "tool_result") {
        const id = block.tool_use_id || block.id;
        if (id) {
          resultByUid.set(id, {
            output: clipText(toolResultText(block.content || block.text || block.result), MAX_ACTION_OUTPUT),
            isError: !!block.is_error,
          });
        }
      }
    }
  }
  return actionListFromMaps(order, detailByUid, resultByUid);
}

function codexLiveItem(event) {
  if (!event || typeof event !== "object") return null;
  if (event.item && typeof event.item === "object") return event.item;
  if (event.type === "response_item" && event.payload && typeof event.payload === "object") return event.payload;
  if (event.payload && typeof event.payload === "object" && (event.payload.type || event.payload.item_type)) return event.payload;
  return null;
}

function codexLiveItemType(item) {
  return item && String(item.item_type || item.type || "").trim();
}

function codexLiveNodeId(event, item, index) {
  return (
    (item && (item.call_id || item.id)) ||
    (event && event.id) ||
    `codex-tool-${index}`
  );
}

function codexCommandExecutionDetail(item) {
  let cmd = item.command || item.cmd;
  if (Array.isArray(cmd)) cmd = cmd.join(" ");
  if (!cmd && item.input && typeof item.input === "object") cmd = item.input.command || item.input.cmd;
  return codexShellDetail(cmd);
}

function liveCodexActions(output) {
  const detailByUid = new Map();
  const resultByUid = new Map();
  const callIdToUid = new Map();
  const order = [];
  parsedJsonlEvents(output).forEach((event, index) => {
    const item = codexLiveItem(event);
    if (!item) return;
    const type = codexLiveItemType(item);
    if (!type || ["agent_message", "reasoning", "message"].includes(type)) return;

    if (type === "function_call_output" || type === "custom_tool_call_output") {
      const uid = item.call_id ? callIdToUid.get(item.call_id) || item.call_id : codexLiveNodeId(event, item, index);
      if (uid) {
        resultByUid.set(uid, {
          output: clipText(codexOutputText(item.output || item.result || item.content), MAX_ACTION_OUTPUT),
          isError: !!item.is_error,
        });
      }
      return;
    }

    const uid = codexLiveNodeId(event, item, index);
    if (item.call_id) callIdToUid.set(item.call_id, uid);

    if (type === "command_execution") {
      detailByUid.set(uid, codexCommandExecutionDetail(item));
      order.push(uid);
      const outputText = codexOutputText(item.aggregated_output || item.stdout || item.stderr || item.output);
      if (outputText) {
        resultByUid.set(uid, {
          output: clipText(outputText, MAX_ACTION_OUTPUT),
          isError: typeof item.exit_code === "number" && item.exit_code !== 0,
        });
      }
      return;
    }

    // Stream `mcp_tool_call` items (server+tool fields) — not only nested exec wrappers.
    if (type === "mcp_tool_call") {
      const detail = codexActionDetailSingle(item);
      if (detail) {
        detailByUid.set(uid, detail);
        order.push(uid);
        const outputText = codexOutputText(item.result || item.output || item.content);
        if (outputText) {
          resultByUid.set(uid, {
            output: clipText(outputText, MAX_ACTION_OUTPUT),
            isError: !!item.is_error || String(item.status || "").toLowerCase().includes("error"),
          });
        }
      }
      return;
    }

    if (type === "function_call" || type === "custom_tool_call") {
      const details = codexActionDetails(item);
      const actionUids = [];
      details.forEach((detail, detailIndex) => {
        const actionUid = details.length > 1 ? `${uid}:${detailIndex}` : uid;
        detailByUid.set(actionUid, detail);
        order.push(actionUid);
        actionUids.push(actionUid);
      });
      if (item.call_id && actionUids.length) {
        // A combined outer exec result cannot be split safely by action. Attach it
        // once to the first native node rather than duplicating it across siblings.
        callIdToUid.set(item.call_id, actionUids[0]);
      }
      return;
    }

    if (type === "file_change") {
      const paths = Array.isArray(item.changes)
        ? item.changes.map((change) => change && (change.path || change.file_path)).filter(Boolean)
        : [item.path || item.file_path].filter(Boolean);
      detailByUid.set(uid, { kind: "edit", name: paths.map(safeBase).join(", "), path: paths[0] || "" });
      order.push(uid);
      return;
    }

    if (type === "todo_list") {
      const rawTodos = item.items || item.todos || [];
      detailByUid.set(uid, {
        kind: "todo",
        todos: Array.isArray(rawTodos) ? rawTodos.map((t) => ({
          content: String((t && t.content) || ""),
          status: String((t && t.status) || ""),
          activeForm: String((t && t.activeForm) || "")
        })) : []
      });
      order.push(uid);
    }
  });
  return actionListFromMaps(order, detailByUid, resultByUid);
}

// Seal a structured tool detail onto its action message. Never sends plaintext:
// with no runtime key the rich card simply stays hidden (the label still shows).
function sealActionDetail(message, detail) {
  if (!detail) return false;
  const enc = encryptRuntimeBlob(detail);
  if (!enc) return false;
  message.agentActionEnc = enc;
  return true;
}

// ── Tool actions → native progress nodes (no emoji) ─────────────────
// The phone renders an assistant turn natively: a compact shimmer line that
// expands to a tool sheet (Read/Edit/Run …), then the prose, then the diff card.
// To feed that path we attach each turn's tool actions to its assistant message
// as `progressNodes` (plaintext labels — already in the Tier-2 gap) plus an
// E2E-encrypted `agentActionsEnc` carrying the SENSITIVE detail (command OUTPUT,
// todo contents, search hits). The node label is recomputed app-side from
// kind/target/added/removed; we still ship a clean (emoji-free) fallback label.
function actionNodeTarget(kind, d) {
  switch (kind) {
    case "bash": return clip(String(d.command || "").replace(/\s+/g, " ").trim(), 72);
    case "edit":
    case "write":
    case "read": return d.name || "";
    case "search": return clip(String(d.pattern || ""), 72);
    case "web": return d.url || d.query || "";
    case "task": return clip(String(d.description || ""), 72);
    case "mcp":
      return d.target || (d.server && d.tool ? d.server + " · " + String(d.tool).replace(/_/g, " ") : "") || d.name || "";
    default: return d.target || "";
  }
}
function cleanNodeLabel(kind, target, d) {
  switch (kind) {
    case "bash": return target ? "Run " + target : "Run command";
    case "edit": return "Edit " + (target || "file");
    case "write": return "Create " + (target || "file");
    case "read": return "Read " + (target || "file");
    case "search": return (d.tool ? d.tool : "Search") + (target ? " " + target : "");
    case "web": return "Fetch" + (target ? " " + target : "");
    case "task": return "Task" + (target ? " " + target : "");
    case "todo": return "Planning";
    case "thinking": return "Thinking";
    case "mcp": {
      // "MCP · ask advisor" — stable base (duration is appended client-side at settle).
      const tool = d.tool ? prettyMcpToolLabel(d.tool) : "";
      if (tool) return "MCP · " + tool;
      if (target) {
        // Rewrite any residual "ask fable" in a prebuilt target string.
        return "MCP · " + String(target).replace(/\bask\s+fable\b/gi, "ask advisor");
      }
      return "MCP tool";
    }
    default: return d.name || "Tool";
  }
}
function actionNode(detail, uid, status) {
  const d = detail || {};
  const kind = d.kind || "tool";
  const target = actionNodeTarget(kind, d);
  // A subagent (Task tool) child carries the parent Task's tool_use id → depth 1
  // so the phone groups it under the Task instead of flattening it into the feed.
  const parentId = d.parentId ? String(d.parentId) : "";
  const node = {
    id: String(uid || ""),
    label: cleanNodeLabel(kind, target, d),
    kind,
    status: status || "done",
    depth: parentId ? 1 : 0,
  };
  if (parentId) node.parentId = parentId;
  // The parent Task node advertises the subagent flavor (e.g. "explore") so the
  // phone can render "🤖 Subagent · explore" and open its read-only view.
  if (kind === "task" && d.subagent) node.subagentType = String(d.subagent);
  if (target) node.target = target;
  if (typeof d.additions === "number" && d.additions > 0) node.added = d.additions;
  if (typeof d.deletions === "number" && d.deletions > 0) node.removed = d.deletions;
  // Read line range — plaintext (line numbers aren't sensitive) so the row preview can
  // show "Read foo.swift (12–48)" without needing the decrypted blob.
  if (typeof d.start === "number" && d.start > 0) node.start = d.start;
  if (typeof d.end === "number" && d.end > 0) node.end = d.end;
  // Thinking metrics (plaintext, not sensitive): reasoning token count + how long
  // the turn spent thinking, so the phone renders "Thinking · N tokens" / "Thought
  // for Ns" like the desktop CLI.
  if (typeof d.tokens === "number" && d.tokens > 0) node.tokens = d.tokens;
  if (typeof d.durationMs === "number" && d.durationMs > 0) node.durationMs = d.durationMs;
  // Grok exposes full CoT — ride it on the node so the phone can open a thinking
  // sheet without waiting for encrypted agentActionsEnc (live path has no seal yet).
  if (kind === "thinking") {
    const cot = d.output || d.detail || d.text;
    if (typeof cot === "string" && cot.trim()) {
      node.detail = clipText(cot.trim(), MAX_ACTION_OUTPUT);
      node.output = node.detail;
    }
  }
  // MCP / bash / read / search results: also mirror a clipped plaintext body onto
  // the node so History/live sheets still show output when agentActionsEnc is
  // missing (or decrypt fails on a peer device). Full body still rides the blob.
  if (OUTPUT_KINDS.has(kind) && typeof d.output === "string" && d.output.trim()) {
    const body = clipText(d.output.trim(), kind === "mcp" ? 4000 : 1400);
    if (!node.detail) node.detail = body;
    if (!node.output) node.output = body;
  }
  return node;
}
// Build a turn's progress nodes + sealed detail array and attach them to the
// turn's host message (its final assistant text, or a synthetic empty assistant
// message when the turn produced only tool calls). Output/contents are joined
// from `resultByUid` and ride ONLY the encrypted blob.
function attachTurnActions(messages, host, uids, detailByUid, resultByUid) {
  const nodes = [];
  const actions = [];
  for (const uid of uids) {
    const det = detailByUid.get(uid);
    if (!det) continue;
    if (OUTPUT_KINDS.has(det.kind)) {
      const r = resultByUid.get(uid);
      if (r) { det.output = r.output; det.isError = r.isError; }
    }
    nodes.push(actionNode(det, uid, det.isError ? "error" : "done"));
    actions.push(Object.assign({ id: String(uid) }, det));
  }
  if (!nodes.length) return;
  let target = host;
  if (!target) {
    target = { role: "assistant", text: "", uid: "actions-" + String(uids[0] || nodes.length) };
    messages.push(target);
  }
  // Cap to keep a single turn's feed bounded on pathological sessions.
  target.progressNodes = nodes.slice(-60);
  const enc = encryptRuntimeBlob({ actions: actions.slice(-60) });
  if (enc) target.agentActionsEnc = enc;
}

// Fold ONE user-turn into a SINGLE assistant "host" message. The turn's LAST
// assistant text becomes the host's visible summary (rendered OUTSIDE the card);
// every earlier assistant text plus all tool actions become interleaved progress
// nodes (rendered INSIDE the "Worked for Xs" card) in chronological order — so a
// turn reads as one collapsed card + one summary, never a pile of separate text
// bubbles with a stray "Worked" card wedged between them (the bug this fixes).
// `turnItems` is the ordered list captured during the turn:
//   { type:"text", text, uid, ts }  |  { type:"tool", uid, ts }
// Returns the host (already pushed onto `messages`) or null if the turn was empty.
function foldTurnIntoHost(messages, turnItems, detailByUid, resultByUid, turnReasoning, hostFallbackUid, thinkingMeta, interrupted) {
  // The LAST non-empty text is the answer — but ONLY if the turn actually ENDS on
  // it. If any tool action runs AFTER the last text, that text is interim narration
  // ("I'll look at X" → then does X), not a closing answer. Mid-run the newest
  // narration is always the "last text" while the tools it introduces are still
  // arriving, so treating it as the summary yanked it out of the feed and
  // markMessageRunning re-appended it at the BOTTOM — the phone showed
  // [tools…, text] instead of [text, tools…], "healing" only once the next text
  // arrived. Keeping interim narration inline (host.text left empty) makes the live
  // feed read chronologically. The finished turn (answer genuinely last) is unchanged.
  // EXCEPT when the turn was INTERRUPTED (a stop sealed it mid-tool): its closing
  // answer will never come, so an empty body would blank the bubble and bury
  // everything the user already watched inside the collapsed card. Promote the last
  // narration to the body — keep what already arrived visible.
  let lastTextIndex = -1;
  for (let i = 0; i < turnItems.length; i++) {
    if (turnItems[i].type === "text" && String(turnItems[i].text || "").trim()) lastTextIndex = i;
  }
  let toolAfterLastText = false;
  for (let i = lastTextIndex + 1; i < turnItems.length; i++) {
    if (turnItems[i].type === "tool") { toolAfterLastText = true; break; }
  }
  const summary = (lastTextIndex >= 0 && (!toolAfterLastText || interrupted)) ? turnItems[lastTextIndex] : null;

  const nodes = [];
  const actions = [];
  // ONE "Thinking" node leads the turn's feed (reasoning text rides the encrypted
  // blob; the label stays the generic, leak-free "Thinking"). Emit it whenever the
  // turn actually THOUGHT — Claude Code persists thinking with empty text (signature
  // only), so keying on reasoning-text alone hid the node entirely. thinkingMeta
  // carries the reasoning token count + how long the turn spent thinking so the row
  // renders "Thinking · N tokens" / "Thought for Ns" like the desktop CLI.
  const reasoning = String(turnReasoning || "").trim();
  const meta = thinkingMeta || {};
  // When the caller captured per-step {type:"think"} items (claudeDetail), each one
  // renders at its real chronological position below — the coalesced top node would
  // double-count the same reasoning, so it only fires for callers that still
  // aggregate (codexDetail).
  const hasInterleavedThinking = turnItems.some((it) => it && it.type === "think");
  if ((reasoning || meta.had) && !hasInterleavedThinking) {
    const tid = "think-host";
    const det = { kind: "thinking" };
    if (reasoning) det.output = clipText(reasoning, MAX_ACTION_OUTPUT);
    if (typeof meta.tokens === "number" && meta.tokens > 0) det.tokens = meta.tokens;
    if (typeof meta.durationMs === "number" && meta.durationMs > 0) det.durationMs = meta.durationMs;
    nodes.push(actionNode(det, tid, "done"));
    actions.push(Object.assign({ id: tid }, det));
  }
  let textSeq = 0;
  for (let i = 0; i < turnItems.length; i++) {
    if (summary && i === lastTextIndex) continue;   // the answer rides OUTSIDE the card
    const it = turnItems[i];
    if (it.type === "think") {
      // Per-step thinking → an in-card node at its real chronological position,
      // matching the desktop CLI's interleaved "Thought for Ns" rows (the phone
      // formats label+durationMs+tokens; reasoning text rides the encrypted blob).
      const det = { kind: "thinking" };
      if (it.text) det.output = clipText(String(it.text), MAX_ACTION_OUTPUT);
      if (typeof it.tokens === "number" && it.tokens > 0) det.tokens = it.tokens;
      if (typeof it.durationMs === "number" && it.durationMs > 0) det.durationMs = it.durationMs;
      const tid = it.uid ? "think-" + String(it.uid) : "think-" + i;
      nodes.push(actionNode(det, tid, "done"));
      actions.push(Object.assign({ id: tid }, det));
      continue;
    }
    if (it.type === "text") {
      // Interior narration → an in-card text node (phone renders it as prose,
      // interleaved with the tool rows, via VibeAgentKitMessageCell).
      const t = String(it.text || "").trim();
      if (!t) continue;
      nodes.push({
        id: it.uid ? "txt-" + String(it.uid) : "txt-" + textSeq++,
        label: clipText(t, 4000),
        kind: "text",
        status: "done",
        depth: 0,
      });
      continue;
    }
    const det = detailByUid.get(it.uid);
    if (!det) continue;
    if (OUTPUT_KINDS.has(det.kind)) {
      const r = resultByUid.get(it.uid);
      if (r) {
        det.output = r.output;
        det.isError = r.isError;
        // Tool wall time: tool_use ts → tool_result ts (MCP Ask Fable can be minutes).
        if (it.ts && r.ts) {
          const dt = Date.parse(r.ts) - Date.parse(it.ts);
          if (Number.isFinite(dt) && dt > 0 && dt < 30 * 60 * 1000) det.durationMs = dt;
        }
      }
    }
    // NOTE: a result-less trailing tool on the LIVE turn is flagged "running" by
    // markMessageRunning (not here) — status set at fold time would also poison
    // FINISHED sessions whose last tool never got a result (cancelled runs).
    nodes.push(actionNode(det, it.uid, det.isError ? "error" : "done"));
    actions.push(Object.assign({ id: String(it.uid) }, det));
  }

  if (!summary && !nodes.length) return null;

  // Key the host by the turn's FIRST event uid — stable across live-tail re-pushes.
  // (The "last text" changes as a turn streams, so keying by the summary would make
  // the row id jump mid-run and leave a stale bubble; the first event is fixed once
  // the turn opens, so the phone upserts the same row cleanly as the turn grows.)
  const hostUid =
    (turnItems[0] && turnItems[0].uid) ||
    (summary && summary.uid) ||
    hostFallbackUid ||
    ("turn-" + messages.length);
  const host = {
    role: "assistant",
    text: summary ? clipText(String(summary.text || "").trim(), 4000) : "",
    ts: (summary && summary.ts) || (turnItems.length && turnItems[turnItems.length - 1].ts) || null,
    uid: hostUid,
  };
  // Does the turn end awaiting a tool verdict? If the LAST tool item has no result
  // yet, that tool is still executing and the live running mark belongs on its
  // node. Otherwise the model is BETWEEN steps (reading the result / reasoning /
  // streaming) — markMessageRunning uses this to put a "Thinking" node at the live
  // edge instead of re-flagging the finished last tool (the stale "Reading…" header).
  let trailingToolPending = false;
  for (let i = turnItems.length - 1; i >= 0; i--) {
    if (turnItems[i].type !== "tool") continue;
    trailingToolPending = !resultByUid.has(turnItems[i].uid);
    break;
  }
  host.trailingToolPending = trailingToolPending;
  if (nodes.length) {
    host.progressNodes = nodes.slice(-60);
    const enc = encryptRuntimeBlob({ actions: actions.slice(-60) });
    if (enc) host.agentActionsEnc = enc;
  }
  // Empty turn (no body, no tool/text nodes) — never push a glass shell. Thinking-
  // only presence without tools is also dropped (no paint without substance).
  const hasBody = String(host.text || "").trim().length > 0;
  const hasPaint =
    hasBody ||
    (Array.isArray(host.progressNodes) &&
      host.progressNodes.some((n) => {
        if (!n) return false;
        const k = String(n.kind || "").toLowerCase();
        return k !== "thinking" && k !== "";
      }));
  if (!hasPaint) return null;
  messages.push(host);
  return host;
}

/** Grok history hosts: force settled tool/thinking status so the phone's
 * canShowCompletedWork can render a solid Worked card (Grok stop_reason is often null). */
function settleGrokHistoryHost(host) {
  if (!host || typeof host !== "object") return host;
  host.running = false;
  host.trailingToolPending = false;
  if (Array.isArray(host.progressNodes)) {
    for (const n of host.progressNodes) {
      if (!n || typeof n !== "object") continue;
      const st = String(n.status || "").toLowerCase();
      if (!st || st === "running" || st === "streaming" || st === "pending" || st === "active") {
        n.status = "done";
      }
    }
  }
  return host;
}

function grokStableTurnUid(sessionId, turnIndex, userText) {
  const prefix = String(userText || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 48);
  // FNV-1a 32-bit over session+index+prefix — stable across re-ingest/window slides.
  let h = 0x811c9dc5;
  const s = `${sessionId || ""}|${turnIndex}|${prefix}`;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return `grok-turn-${(h >>> 0).toString(16)}`;
}

async function claudeDetail(id, limit, before) {
  const match = claudeSessionFiles().find((s) => s.id === id);
  if (!match) return null;
  const messages = [];
  let pending = newRuntimeAccumulator();
  let topic = null;
  let model = null;
  const activeBackgroundTasks = new Set();
  // Claude Code re-appends prior messages (same `uuid`) into the JSONL every time a
  // session is resumed/compacted, so a long session contains the SAME message many
  // times over. Replaying those duplicates produced garbled "corpse" history and
  // repeated diff cards — dedupe by uuid so each message (and its edits) counts once.
  const seen = new Set();
  // Turn tracking: each user-text message starts a new turn. The turn's assistant
  // prose AND tool actions are captured IN ORDER, then folded into ONE host
  // message at flush (foldTurnIntoHost): the last text = the summary (outside the
  // card), every earlier text + all tools = interleaved progress nodes (inside the
  // "Worked" card). One compact, expandable turn — never a pile of text bubbles.
  let turnItems = [];      // ordered [{type:"text",text,uid,ts}|{type:"tool",uid,ts}]
  let turnReasoning = "";  // stays empty here — Claude thinking is interleaved per-step (type:"think" items)
  // stop_reason of the LAST assistant entry in the file (see the assistant branch).
  let lastStopReason = null;
  // Turn timespan (user prompt → last assistant event) → "Worked for Xs".
  let turnStartTs = null;
  let turnEndTs = null;
  // Thinking metrics for the turn's ONE "Thinking" node: whether it thought at all
  // (Claude persists empty-text thinking → presence, not text, is the signal), the
  // reasoning token total, and a best-effort thinking duration (gap from the prior
  // event to the thinking message — the wall-clock the model spent producing it).
  let turnThinking = { had: false, tokens: 0, durationMs: 0 };
  let lastEventTs = null;
  // Structured tool detail join: uid → {kind, command, …} and
  // tool_use_id → {output, isError}.
  const actionDetailByUid = new Map();
  const resultByUid = new Map();
  // One card per user-turn: fold the turn's prose + tool feed into ONE host
  // message, then seal the edits/diff card onto it.
  const flushTurn = (interrupted) => {
    const host = foldTurnIntoHost(messages, turnItems, actionDetailByUid, resultByUid, turnReasoning, null, turnThinking, interrupted);
    if (host && pending.order.length) {
      sealHistoryRuntime("claude", host, pending, turnDurationMs(turnStartTs, turnEndTs));
    }
    pending = newRuntimeAccumulator();
    turnItems = [];
    turnReasoning = "";
    turnStartTs = null;
    turnEndTs = null;
    turnThinking = { had: false, tokens: 0, durationMs: 0 };
  };
  await readJsonl(match.file, (ev) => {
    if (ev.type === "ai-title" && ev.aiTitle) topic = ev.aiTitle;
    const isTaskNotification = updateClaudeBackgroundTasks(activeBackgroundTasks, ev);
    if (isTaskNotification) return;
    if (ev.type !== "user" && ev.type !== "assistant") return;
    const m = ev.message || {};
    if (ev.type === "assistant" && m.model && String(m.model) !== "<synthetic>") {
      model = String(m.model);
    }
    if (ev.uuid) { if (seen.has(ev.uuid)) return; seen.add(ev.uuid); }
    // /compact summaries are injected as user messages — render them as a
    // mid-chat divider (kind:"summary"), never a user bubble or a turn boundary.
    if (ev.type === "user" && ev.isCompactSummary) {
      let st = "";
      if (typeof m.content === "string") st = m.content;
      else if (Array.isArray(m.content)) st = m.content.filter((b) => b && b.type === "text").map((b) => b.text).join("\n").trim();
      st = cleanMessageText(st);
      if (st) messages.push({ role: "system", kind: "summary", text: clipText(st, 4000), ts: ev.timestamp, uid: ev.uuid });
      return;
    }
    // Capture tool results (bash stdout, …) to join onto their action entry.
    // These are user-type events carrying a tool_result block and no user text.
    if (ev.type === "user" && Array.isArray(m.content)) {
      for (const b of m.content) {
        if (b && b.type === "tool_result" && b.tool_use_id) {
          resultByUid.set(b.tool_use_id, {
            output: clipText(toolResultText(b.content), MAX_ACTION_OUTPUT),
            isError: !!b.is_error,
            ts: ev.timestamp || null,
          });
        }
      }
    }
    // Skip Claude Code's own meta annotations (local-command output, IDE
    // open/selection, caveats) — not conversation; they render as junk bubbles.
    if (ev.type === "user" && ev.isMeta) return;
    let rawText = "";
    if (typeof m.content === "string") rawText = m.content;
    else if (Array.isArray(m.content)) {
      rawText = m.content.filter((b) => b && b.type === "text").map((b) => b.text).join("\n").trim();
    }
    // Claude Code records a local slash-command invocation (/compact, /clear, …) as a
    // user event wrapping <command-name>/<local-command-stdout> chrome. It's UI, not
    // conversation — drop it BEFORE the turn-boundary flush so it neither seals a turn
    // nor leaks a junk "Compacted" user bubble next to the real summary divider. The
    // compaction SUMMARY itself is handled above (isCompactSummary → kind:"summary").
    if (ev.type === "user" && /<command-name>|<command-message>|<local-command-stdout>/i.test(rawText)) {
      return;
    }
    // Claude Code writes SYNTHETIC assistant frames (message.model === "<synthetic>")
    // as CLI chrome: "No response requested." after a rate-limit resume, "You've hit
    // your session limit · resets 1am", API-error notices. They are not agent output.
    // Ingesting them painted phantom "No response requested." bubbles/card bodies and
    // stretched turnEndTs across the idle gap to the next resume (the
    // "Worked for 11h56m" card). Keep an informative one (limit/error) as an in-card
    // narration line; drop the no-op filler; never let either advance turn timing,
    // stop_reason, or the diff accumulator.
    if (ev.type === "assistant" && String(m.model || "") === "<synthetic>") {
      const st = cleanMessageText(rawText);
      if (st && !/^no response requested\.?$/i.test(st)) {
        turnItems.push({ type: "text", text: st, uid: ev.uuid, ts: ev.timestamp });
      }
      return;
    }
    if (ev.type === "user" && messageHasUserText(m)) {
      // A stop writes "[Request interrupted by user…]" as the next user message.
      // The turn it closes ended mid-tool and will never get its answer text —
      // flag the flush so the fold promotes the last narration to the visible
      // body instead of sealing an empty-bodied bubble.
      flushTurn(/^\s*\[request interrupted/i.test(rawText)); // seal prior turn's card + action feed
      turnStartTs = ev.timestamp || null;   // new turn opens at this prompt
    }
    if (ev.type === "assistant") {
      collectClaudeEdits(pending, m.content);
      if (ev.timestamp) turnEndTs = ev.timestamp;   // extend turn end to last assistant event
      // The turn's structural state: end_turn = genuinely finished; tool_use/null =
      // a tool is executing or the model is still thinking. markDetailLiveTurn uses
      // this so `running` survives long write gaps (thinking, builds) without making
      // finished turns linger.
      lastStopReason = typeof m.stop_reason === "string" ? m.stop_reason : null;
    }
    let text = cleanMessageText(rawText);
    if (ev.type === "user") {
      // User prompts stay their own right-side bubble (each one is a turn boundary).
      if (text) messages.push({ role: "user", text: clipText(text, 4000), ts: ev.timestamp, uid: ev.uuid });
    } else if (ev.type === "assistant") {
      // Fold this assistant event into the current turn IN ORDER: its reasoning
      // first (the thinking that produced this step), then its prose (an interior
      // text becomes an in-card narration node; the turn's LAST text becomes the
      // summary), then its tool calls — so the card reads chronologically.
      if (Array.isArray(m.content) && m.content.some((b) => b && b.type === "thinking")) {
        // Each thinking message becomes its OWN ordered turn item so the fold
        // renders interleaved "Thought for Ns" rows at their real positions like
        // the desktop CLI (the old single coalesced top node hid WHERE the turn
        // thought — "the cell only shows thinking at top"). Presence, not text, is
        // the signal (Claude Code usually persists thinking with EMPTY text — only
        // the signature). tokens ≈ this message's output tokens; duration = gap
        // from the IMMEDIATELY-preceding event (`lastEventTs` advances on EVERY
        // event incl. tool_results — see below — so the preceding tool's execution
        // time is excluded from the thinking duration).
        const think = m.content
          .filter((b) => b && b.type === "thinking" && b.thinking)
          .map((b) => String(b.thinking))
          .join("\n\n")
          .trim();
        const outTok = Number(m.usage && (m.usage.output_tokens || m.usage.reasoning_output_tokens)) || 0;
        let thoughtMs = 0;
        if (ev.timestamp && lastEventTs) {
          const dt = Date.parse(ev.timestamp) - Date.parse(lastEventTs);
          if (dt > 0 && dt < 600000) thoughtMs = dt;
        }
        turnItems.push({
          type: "think", uid: ev.uuid, ts: ev.timestamp,
          text: think, tokens: outTok, durationMs: thoughtMs,
        });
      }
      if (text) turnItems.push({ type: "text", text, uid: ev.uuid, ts: ev.timestamp });
      if (Array.isArray(m.content)) {
        // Subagent (sidechain) events carry the parent Task's tool_use id; tag the
        // child detail so it groups under the Task (depth 1) like the live path.
        const parentToolUseId =
          (typeof ev.parent_tool_use_id === "string" && ev.parent_tool_use_id) ||
          (typeof m.parent_tool_use_id === "string" && m.parent_tool_use_id) ||
          "";
        for (const b of m.content) {
          if (b && b.type === "tool_use") {
            turnItems.push({ type: "tool", uid: b.id, ts: ev.timestamp });
            const det = claudeActionDetail(b);
            if (parentToolUseId) det.parentId = parentToolUseId;
            actionDetailByUid.set(b.id, det);
          }
        }
      }
    }
    // Advance the "previous event" marker for EVERY event (user prompt, tool_result,
    // and assistant alike — mirrors the Codex path) so the next thinking step measures
    // ONLY its own gap. Because tool_result user events bump this too, the tool's own
    // execution time is excluded from the following thinking node's duration.
    if (ev.timestamp) lastEventTs = ev.timestamp;
  });
  flushTurn();
  if (activeBackgroundTasks.size > 0) lastStopReason = "background_task";
  // Keep the most RECENT `limit` messages (the tail), not the oldest — a long
  // session must show what's happening NOW, not its opening turns (this was the
  // "messages are too old" bug: reading stopped at `limit` from the top). The
  // per-turn cards + action feeds were sealed onto the message objects above, so
  // they ride along with whatever survives the trim. Stable `uid`s (not array
  // position) key the app-side upsert, so a sliding window re-pushes cleanly.
  const topicText = topic || (messages[0] && clip(messages[0].text, 80)) || "Untitled";
  // Flag a windowed tail so the app only runs aggressive stale-row cleanup when it
  // received the WHOLE session — otherwise "absent" just means "older than the
  // window", and deleting those would erase valid scrollback.
  const window = windowHistoryMessages(messages, limit, before);
  const liveMetadata = runningSessionMetadata("claude", id);
  return {
    provider: "claude",
    id,
    topic: topicText,
    project: match.project,
    projectName: path.basename(match.project),
    truncated: window.truncated,
    hasMoreBefore: window.hasMoreBefore,
    nextBefore: window.nextBefore,
    windowStart: window.windowStart,
    windowEnd: window.windowEnd,
    totalMessages: window.totalMessages,
    messages: window.messages,
    lastStopReason,
    ...(liveMetadata.model || model ? { model: liveMetadata.model || model } : {}),
    ...(liveMetadata.reasoningEffort ? { reasoningEffort: liveMetadata.reasoningEffort } : {}),
  };
}

// — Codex —
function codexText(content) {
  if (!Array.isArray(content)) return "";
  return content
    .filter((b) => b && (b.type === "input_text" || b.type === "output_text") && b.text)
    .map((b) => b.text)
    .join("\n")
    .trim();
}

function codexIdFromSessionFileName(name) {
  const m = String(name || "").match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i);
  return m ? m[1] : "";
}

function codexSessionFiles() {
  const root = path.join(os.homedir(), ".codex", "sessions");
  const out = [];
  if (!fs.existsSync(root)) return out;
  (function walk(dir) {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.name.startsWith("rollout-") && e.name.endsWith(".jsonl")) {
        let st;
        try { st = fs.statSync(full); } catch { continue; }
        out.push({ id: codexIdFromSessionFileName(e.name), file: full, name: e.name, mtime: st.mtimeMs, size: st.size });
      }
    }
  })(root);
  return out;
}

// Codex keeps the user-visible conversation name outside the rollout JSONL.
// `session_index.jsonl` holds generated/renamed thread names, while newer Codex
// builds also mirror titles in state_5.sqlite. The transcript's first message is
// only a fallback; it is not the title shown by Codex itself.
const codexStoredTitleCache = { at: 0, signature: "", titles: new Map() };

function codexStoredTitles() {
  const now = Date.now();
  if (now - codexStoredTitleCache.at < 2_000) return codexStoredTitleCache.titles;

  const codexDir = path.join(os.homedir(), ".codex");
  const indexFile = path.join(codexDir, "session_index.jsonl");
  const stateCandidates = [
    path.join(codexDir, "state_5.sqlite"),
    path.join(codexDir, "sqlite", "state_5.sqlite"),
  ];
  const stateFile = stateCandidates.find((candidate) => fs.existsSync(candidate));
  const signature = [indexFile, stateFile]
    .filter(Boolean)
    .map((file) => {
      try {
        const stat = fs.statSync(file);
        return `${file}:${stat.size}:${stat.mtimeMs}`;
      } catch {
        return `${file}:missing`;
      }
    })
    .join("|");
  if (signature === codexStoredTitleCache.signature) {
    codexStoredTitleCache.at = now;
    return codexStoredTitleCache.titles;
  }

  const titles = new Map();
  // State DB is a useful fallback for recent Codex versions. Keep this optional:
  // the bridge also runs on machines where the sqlite3 CLI is unavailable.
  if (stateFile) {
    const sqliteCandidates = process.platform === "darwin"
      ? ["/usr/bin/sqlite3", "sqlite3"]
      : ["sqlite3"];
    for (const sqlite of sqliteCandidates) {
      try {
        const raw = execFileSync(
          sqlite,
          [
            "-readonly",
            "-json",
            stateFile,
            "select id, title, first_user_message from threads where archived = 0;",
          ],
          { encoding: "utf8", timeout: 2_000, maxBuffer: 4 * 1024 * 1024 }
        );
        const rows = JSON.parse(raw || "[]");
        for (const row of Array.isArray(rows) ? rows : []) {
          const id = row && typeof row.id === "string" ? row.id : "";
          const rawTitle = String((row && row.title) || "").trim();
          const firstMessage = String((row && row.first_user_message) || "").trim();
          // Before Codex generates a title it stores the entire first prompt
          // (or a truncated prefix) in `threads.title`. Those are not conversation
          // names — only accept titles that clearly diverge from the first message.
          if (!id || !rawTitle || isRawCodexTitleCandidate(rawTitle, firstMessage)) continue;
          const title = cleanTopicCandidate(rawTitle);
          if (title && !isWeakCodexTitle(title)) titles.set(id, title);
        }
        break;
      } catch (_) {
        // Fall through to the portable JSONL index.
      }
    }
  }

  // The index is the authoritative source for generated/explicit thread names;
  // apply it last so it overrides a stale or first-message-shaped DB title.
  try {
    const lines = fs.readFileSync(indexFile, "utf8").split("\n");
    for (const line of lines) {
      if (!line.trim()) continue;
      let row;
      try { row = JSON.parse(line); } catch { continue; }
      const id = row && typeof row.id === "string" ? row.id : "";
      const rawName = String((row && row.thread_name) || "").trim();
      // session_index is the generated/renamed name; still reject anything that
      // looks like a leftover first-prompt dump.
      if (!id || !rawName || isRawCodexTitleCandidate(rawName)) continue;
      const title = cleanTopicCandidate(rawName);
      if (title && !isWeakCodexTitle(title)) titles.set(id, title);
    }
  } catch (_) {}

  codexStoredTitleCache.at = now;
  codexStoredTitleCache.signature = signature;
  codexStoredTitleCache.titles = titles;
  return titles;
}

// Lightweight roster summary: stream just far enough to recover session_meta + the
// first couple of real messages, then stop. Early-exits the instant we have a topic and
// ≥2 messages; otherwise stops at CODEX_SUMMARY_HEAD_BYTES. Replaces the old
// fs.readSync(8 MB)-per-file scan that blocked the event loop for seconds across a
// 40-file list (starving the WebSocket heartbeat) — this streams async so the socket
// stays alive, and stops after a few KB for the common case.
async function codexSummaryFromHead(file, size) {
  let meta = null, topic = null, assistantTopic = null, messages = 0, userTurns = 0;
  await readJsonl(file, (ev) => {
    if (ev.type === "session_meta") { meta = ev.payload || meta || {}; return; }
    if (ev.type !== "response_item" || !ev.payload) return;
    if (ev.payload.type !== "message") return;
    const role = ev.payload.role;
    if (role !== "user" && role !== "assistant") return;
    const raw = codexText(ev.payload.content);
    const text = role === "user" ? codexUserMessageText(raw) : cleanMessageText(raw);
    if (role === "assistant" && isContextMessage(raw)) return;
    if (!text) return;
    messages++;
    if (role === "user" && !topic) {
      userTurns++;
      const clean = codexFallbackTitle(text, "user");
      if (clean) topic = clean;
    } else if (role === "user") {
      userTurns++;
    } else if (role === "assistant" && !assistantTopic) {
      const clean = codexFallbackTitle(text, "assistant");
      if (clean) assistantTopic = clean;
    }
    if (topic && !isWeakCodexTitle(topic) && messages >= 2) return false;
    if (topic && isWeakCodexTitle(topic) && assistantTopic) return false;
  }, CODEX_SUMMARY_HEAD_BYTES);
  const sessionMetadata = await codexMetadataFromTail(file, size);
  const resolvedTopic = resolveCodexTopic(null, topic, assistantTopic);
  const renderedMessages = userTurns > 0 ? userTurns * 2 : messages;
  return { meta, topic: resolvedTopic, lastTs: null, messages, renderedMessages, ...sessionMetadata };
}

async function codexSummary(file, opts = {}) {
  if (opts.fast) return codexSummaryFromHead(file, opts.size);
  let meta = null, topic = null, assistantTopic = null, lastTs = null, messages = 0, userTurns = 0;
  let model = null, reasoningEffort = null;
  await readJsonl(file, (ev) => {
    if (ev.type === "session_meta") {
      meta = ev.payload || {};
    } else if (ev.type === "turn_context" && ev.payload) {
      if (ev.payload.model && String(ev.payload.model).trim()) {
        model = String(ev.payload.model).trim();
      }
      if (ev.payload.effort && String(ev.payload.effort).trim()) {
        reasoningEffort = String(ev.payload.effort).trim();
      }
    } else if (ev.type === "response_item" && ev.payload && ev.payload.type === "message") {
      const role = ev.payload.role;
      if (role !== "user" && role !== "assistant") return;
      const raw = codexText(ev.payload.content);
      const text = role === "user" ? codexUserMessageText(raw) : cleanMessageText(raw);
      if (role === "assistant" && isContextMessage(raw)) return;
      if (!text) return;
      messages++;
      if (ev.timestamp) lastTs = ev.timestamp;
      if (role === "user" && !topic) {
        userTurns++;
        const clean = codexFallbackTitle(text, "user");
        if (clean) topic = clean;
      } else if (role === "user") {
        userTurns++;
      } else if (role === "assistant" && !assistantTopic) {
        const clean = codexFallbackTitle(text, "assistant");
        if (clean) assistantTopic = clean;
      }
    }
  });
  const resolvedTopic = resolveCodexTopic(null, topic, assistantTopic);
  const renderedMessages = userTurns > 0 ? userTurns * 2 : messages;
  return { meta, topic: resolvedTopic, lastTs, messages, renderedMessages, model, reasoningEffort };
}

async function listCodex(limit) {
  const files = codexSessionFiles().sort((a, b) => b.mtime - a.mtime).slice(0, limit);
  const runningIds = runningSessionIdSet("codex");
  const storedTitles = codexStoredTitles();
  const results = [];
  for (const f of files) {
    let sum = getCachedSummary(f.file, f.size);
    if (!sum) { sum = await codexSummary(f.file, { fast: true, size: f.size }); setCachedSummary(f.file, f.size, sum); }
    if (sum.messages === 0) continue;
    const project = (sum.meta && sum.meta.cwd) || "";
    if (isEphemeralProject(project)) continue;
    const id = (sum.meta && sum.meta.id) || f.id || f.name;
    // Fast head scans are enough for dormant rows. The one active session must
    // show its real bubble count, so scan that transcript fully (typically <200ms)
    // without making History wait on every large archived rollout.
    if (runningIds.has(id)) {
      sum = await codexSummary(f.file);
      setCachedSummary(f.file, f.size, sum);
    }
    const explicitTurnState = await codexOpenTurnState(f.file, f.size);
    const live = runningIds.has(id)
      || (explicitTurnState == null
        ? sessionIsLive(f.mtime, id, runningIds)
        : explicitTurnState);
    const liveMetadata = runningSessionMetadata("codex", id);
    results.push({
      provider: "codex",
      id,
      topic: resolveCodexTopic(storedTitles.get(id), sum.topic, null),
      project,
      projectName: project ? path.basename(project) : "",
      updatedAt: new Date(f.mtime).toISOString(),
      messageCount: Math.max(1, sum.renderedMessages || sum.messages || 0),
      live,
      ...(liveMetadata.model || sum.model ? { model: liveMetadata.model || sum.model } : {}),
      ...(liveMetadata.reasoningEffort || sum.reasoningEffort
        ? { reasoningEffort: liveMetadata.reasoningEffort || sum.reasoningEffort }
        : {}),
    });
  }
  return results;
}

async function codexDetail(id, limit, before) {
  // The session id is embedded in the rollout filename; fall back to meta.id.
  const files = codexSessionFiles();
  let match = files.find((f) => f.id === id || f.name.includes(id));
  if (!match) {
    for (const f of files) {
      const sum = await codexSummary(f.file, { fast: true });
      if (sum.meta && sum.meta.id === id) { match = f; break; }
    }
  }
  if (!match) return null;
  const messages = [];
  let fallbackTopic = null;
  let assistantFallbackTopic = null;
  let pending = newRuntimeAccumulator();
  let project = "";
  let model = null;
  let reasoningEffort = null;
  // Same guard as Claude: skip any response_item we've already processed (by id) so a
  // resumed/re-emitted rollout never replays a message or its apply_patch twice.
  const seen = new Set();
  // Per-turn prose+action collection, folded into ONE host message (see claudeDetail).
  let turnItems = [];      // ordered [{type:"text",text,uid,ts}|{type:"tool",uid,ts}]
  let turnReasoning = "";  // accumulated reasoning for the current turn → ONE node
  // Turn timespan (user prompt → last assistant message) → "Worked for Xs".
  let turnStartTs = null;
  let turnEndTs = null;
  // Thinking metrics for the turn's ONE "Thinking" node (see claudeDetail).
  let turnThinking = { had: false, tokens: 0, durationMs: 0 };
  let lastEventTs = null;
  // Structured tool detail join. Codex references a call by `call_id` in the
  // separate output item, while the action entry is keyed by the message uid —
  // so callIdToUid bridges output → entry.
  const actionDetailByUid = new Map();
  const resultByUid = new Map();
  const callIdToUid = new Map();
  let eventSeq = 0;
  const flushTurn = (interrupted) => {
    const host = foldTurnIntoHost(messages, turnItems, actionDetailByUid, resultByUid, turnReasoning, null, turnThinking, interrupted);
    if (host && pending.order.length) {
      sealHistoryRuntime("codex", host, pending, turnDurationMs(turnStartTs, turnEndTs));
    }
    pending = newRuntimeAccumulator();
    turnItems = [];
    turnReasoning = "";
    turnStartTs = null;
    turnEndTs = null;
    turnThinking = { had: false, tokens: 0, durationMs: 0 };
  };
  await readJsonl(match.file, (ev) => {
    if (ev.type === "session_meta" && ev.payload) project = ev.payload.cwd || "";
    if (ev.type === "turn_context" && ev.payload) {
      if (ev.payload.model && String(ev.payload.model).trim()) {
        model = String(ev.payload.model).trim();
      }
      if (ev.payload.effort && String(ev.payload.effort).trim()) {
        reasoningEffort = String(ev.payload.effort).trim();
      }
      return;
    }
    if (ev.type !== "response_item" || !ev.payload) return;
    const p = ev.payload;
    const dkey = p.id || ev.id || `codex-${eventSeq}`;
    eventSeq += 1;
    if (dkey) { if (seen.has(dkey)) return; seen.add(dkey); }
    collectCodexEdits(pending, p); // apply_patch items accumulate into the turn
    if (p.type === "message" && (p.role === "user" || p.role === "assistant")) {
      const raw = codexText(p.content);
      const text = p.role === "user" ? codexUserMessageText(raw) : cleanMessageText(raw);
      if (p.role === "user" && !fallbackTopic) {
        fallbackTopic = codexFallbackTitle(text, "user");
      } else if (p.role === "assistant" && !assistantFallbackTopic && !isContextMessage(raw)) {
        assistantFallbackTopic = codexFallbackTitle(text, "assistant");
      }
      if (p.role === "user" && text) {
        flushTurn();                // seal prior turn's card + action feed
        turnStartTs = ev.timestamp || null;   // new turn opens at this prompt
      } else if (p.role === "assistant" && ev.timestamp) {
        turnEndTs = ev.timestamp;             // extend turn end to last assistant message
      }
      if (text && (p.role === "user" || !isContextMessage(raw))) {
        if (p.role === "user") {
          // User prompts stay their own right-side bubble (turn boundary).
          messages.push({ role: "user", text: clipText(text, 4000), ts: ev.timestamp, uid: dkey });
        } else {
          // Assistant prose folds into the current turn IN ORDER (last text = summary).
          turnItems.push({ type: "text", text, uid: dkey, ts: ev.timestamp });
        }
      }
    } else if (p.type === "reasoning") {
      // Codex emits a reasoning item before nearly every tool call; aggregate the
      // whole turn's reasoning into ONE "Thinking" node (at flushTurn) so the feed
      // isn't flooded. Reasoning rides the encrypted blob (codex's own
      // `encrypted_content` is opaque to us; `summary` text is the readable gist).
      const think = (Array.isArray(p.summary)
        ? p.summary.map((s) => (s && s.text ? String(s.text) : "")).filter(Boolean).join("\n")
        : "").trim();
      if (think) turnReasoning += (turnReasoning ? "\n\n" : "") + think;
      // Presence + best-effort duration for the turn's Thinking node (Codex reasoning
      // items rarely carry per-item token counts, so tokens usually stay 0 → the row
      // shows "Thinking" / "Thought for Ns" without a token suffix).
      turnThinking.had = true;
      if (ev.timestamp && lastEventTs) {
        const dt = Date.parse(ev.timestamp) - Date.parse(lastEventTs);
        if (dt > 0 && dt < 600000) turnThinking.durationMs += dt;
      }
    } else if (p.type === "function_call" || p.type === "custom_tool_call") {
      // Collect the tool call for the current turn IN ORDER (output joins via call_id).
      const details = codexActionDetails(p);
      const actionUids = [];
      details.forEach((detail, detailIndex) => {
        const actionUid = details.length > 1 ? `${dkey}:${detailIndex}` : dkey;
        turnItems.push({ type: "tool", uid: actionUid, ts: ev.timestamp });
        actionDetailByUid.set(actionUid, detail);
        actionUids.push(actionUid);
      });
      if (p.call_id && actionUids.length) {
        callIdToUid.set(p.call_id, actionUids[0]);
      }
    } else if (p.type === "function_call_output" || p.type === "custom_tool_call_output") {
      const uid = p.call_id ? callIdToUid.get(p.call_id) : null;
      if (uid) resultByUid.set(uid, { output: clipText(codexOutputText(p.output), MAX_ACTION_OUTPUT), isError: false });
    }
    // Advance the "previous event" marker so the next reasoning step measures its gap.
    if (ev.timestamp) lastEventTs = ev.timestamp;
  });
  flushTurn();
  // Topic from the FULL set (the opening message), then keep the most recent
  // `limit` messages — see claudeDetail for rationale (tail, not head; stable uid).
  const topic = resolveCodexTopic(
    codexStoredTitles().get(id),
    fallbackTopic,
    assistantFallbackTopic
  );
  const window = windowHistoryMessages(messages, limit, before);
  const liveMetadata = runningSessionMetadata("codex", id);
  return {
    provider: "codex",
    id,
    topic,
    project,
    projectName: project ? path.basename(project) : "",
    truncated: window.truncated,
    hasMoreBefore: window.hasMoreBefore,
    nextBefore: window.nextBefore,
    windowStart: window.windowStart,
    windowEnd: window.windowEnd,
    totalMessages: window.totalMessages,
    messages: window.messages,
    ...(liveMetadata.model || model ? { model: liveMetadata.model || model } : {}),
    ...(liveMetadata.reasoningEffort || reasoningEffort
      ? { reasoningEffort: liveMetadata.reasoningEffort || reasoningEffort }
      : {}),
  };
}

async function readHistory({ provider, mode, sessionId, limit, before }) {
  const p = String(provider || "").trim().toLowerCase();
  const wantDetail = String(mode || "").toLowerCase() === "detail" || !!sessionId;
  if (wantDetail) {
    const cap = limit || HISTORY_MSG_LIMIT;
    if (p === "codex") return { mode: "detail", session: await codexDetail(sessionId, cap, before) };
    if (p === "grok") return { mode: "detail", session: await grokDetail(sessionId, cap, before) };
    if (p === "agy") return { mode: "detail", session: await agyDetail(sessionId, cap, before) };
    return { mode: "detail", session: await claudeDetail(sessionId, cap, before) };
  }
  const cap = limit || HISTORY_LIST_LIMIT;
  if (p === "codex") return { mode: "list", sessions: await listCodex(cap) };
  if (p === "grok") return { mode: "list", sessions: await listGrok(cap) };
  if (p === "agy") return { mode: "list", sessions: await listAgy(cap) };
  return { mode: "list", sessions: await listClaude(cap) };
}

// Grok Build sessions live under ~/.grok/sessions/<url-encoded-cwd>/<sessionId>/.
// List/detail read summary.json + chat_history.jsonl so the phone History panel
// matches Claude/Codex. Live run_task still streams separately.
function grokSessionsRoot() {
  return path.join(os.homedir(), ".grok", "sessions");
}

/** Freshest Grok session id for current-session adopt (desktop or bridge-spawned). */
function latestGrokSessionIdForChat() {
  const files = grokSessionFiles().sort((a, b) => b.mtime - a.mtime);
  if (!files.length) return null;
  const defaultCwd = realDir(DEFAULT_CWD) || DEFAULT_CWD;
  const preferred = files.find((f) => {
    const proj = realDir(f.project) || f.project;
    return proj === defaultCwd || String(f.project || "") === String(DEFAULT_CWD || "");
  });
  // Prefer a session still being written (live desktop run).
  const live = files.find((f) => Date.now() - f.mtime < LIVE_SESSION_WINDOW_MS * 4);
  return (live && live.id) || (preferred && preferred.id) || files[0].id;
}

function grokSessionFiles() {
  const root = grokSessionsRoot();
  const out = [];
  if (!fs.existsSync(root)) return out;
  let cwdDirs;
  try { cwdDirs = fs.readdirSync(root, { withFileTypes: true }); } catch { return out; }
  for (const cwdDir of cwdDirs) {
    if (!cwdDir.isDirectory()) continue;
    if (cwdDir.name === "session_search.sqlite" || cwdDir.name.startsWith(".")) continue;
    const cwdPath = (() => {
      try { return decodeURIComponent(cwdDir.name); } catch { return cwdDir.name; }
    })();
    if (isEphemeralProject(cwdPath)) continue;
    const absCwd = path.join(root, cwdDir.name);
    let sessions;
    try { sessions = fs.readdirSync(absCwd, { withFileTypes: true }); } catch { continue; }
    for (const sess of sessions) {
      if (!sess.isDirectory()) continue;
      const sessionDir = path.join(absCwd, sess.name);
      const histFile = path.join(sessionDir, "chat_history.jsonl");
      const summaryFile = path.join(sessionDir, "summary.json");
      let st;
      try { st = fs.statSync(histFile); } catch { continue; }
      out.push({
        id: sess.name,
        file: histFile,
        summaryFile,
        project: cwdPath,
        mtime: st.mtimeMs,
        size: st.size,
      });
    }
  }
  return out;
}

function grokSummaryFromFiles(entry) {
  let topic = null;
  let lastTs = null;
  let messages = 0;
  let firstUser = null;
  try {
    if (entry.summaryFile && fs.existsSync(entry.summaryFile)) {
      const raw = JSON.parse(fs.readFileSync(entry.summaryFile, "utf8"));
      topic = raw.generated_title || raw.session_summary || null;
      lastTs = raw.updated_at || raw.last_active_at || raw.created_at || null;
      messages = Number(raw.num_chat_messages || raw.num_messages || 0) || 0;
    }
  } catch (_) {}
  // Fall back to a quick history head scan for topic when summary is missing.
  if (!topic || !messages) {
    try {
      const fd = fs.openSync(entry.file, "r");
      const buf = Buffer.alloc(Math.min(entry.size || 64000, 64000));
      const n = fs.readSync(fd, buf, 0, buf.length, 0);
      fs.closeSync(fd);
      const text = buf.slice(0, n).toString("utf8");
      for (const line of text.split("\n")) {
        if (!line.trim()) continue;
        let ev = null;
        try { ev = JSON.parse(line); } catch { continue; }
        if (!ev || typeof ev !== "object") continue;
        if (ev.type === "user") {
          messages = Math.max(messages, 1);
          const body = grokHistoryContentText(ev.content);
          if (!firstUser) {
            const clean = cleanTopicCandidate(body);
            if (clean) firstUser = clean;
          }
        } else if (ev.type === "assistant") {
          messages = Math.max(messages, 1);
        }
      }
    } catch (_) {}
  }
  return {
    topic: topic || firstUser || "Grok session",
    lastTs,
    messages: messages || 1,
  };
}

function grokHistoryContentText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (!b) return "";
        if (typeof b === "string") return b;
        if (b.type === "text" && typeof b.text === "string") return b.text;
        if (typeof b.text === "string") return b.text;
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  if (content && typeof content === "object" && typeof content.text === "string") {
    return content.text;
  }
  return "";
}

async function listAgy(limit) {
  const files = agySupport
    .agySessionFiles()
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, limit || HISTORY_LIST_LIMIT);
  const runningIds = runningSessionIdSet("agy");
  const results = [];
  for (const s of files) {
    const { steps } = agySupport.loadTranscriptSteps(s.id);
    const userSteps = steps.filter((st) => st && st.type === "USER_INPUT");
    if (!userSteps.length && !(s.messages > 0)) continue;
    let topic = s.topic || null;
    if (!topic && userSteps[0]) {
      topic = cleanTopicCandidate(agySupport.extractUserRequest(userSteps[0].content));
    }
    results.push({
      provider: "agy",
      id: s.id,
      topic: topic || "Agy session",
      project: s.project || "",
      projectName: path.basename(s.project || "") || "Computer",
      updatedAt: s.lastTs || new Date(s.mtime).toISOString(),
      messageCount: s.messages || userSteps.length || 1,
      live: sessionIsLive(s.mtime, s.id, runningIds),
    });
  }
  return results;
}

async function agyDetail(sessionId, limit, before) {
  const match = agySupport.agySessionFiles().find((s) => s.id === sessionId);
  if (!match) return null;
  const { steps } = agySupport.loadTranscriptSteps(sessionId);
  const messages = [];
  let topic = match.topic || null;
  let idx = 0;
  let turnItems = [];
  let turnReasoning = "";
  let turnThinking = { had: false, tokens: 0, durationMs: 0 };
  let turnStartTs = null;
  let turnEndTs = null;
  const actionDetailByUid = new Map();
  const resultByUid = new Map();
  const toolCtx = { pendingTools: new Map(), pendingByName: new Map() };

  const flushTurn = (interrupted) => {
    foldTurnIntoHost(
      messages,
      turnItems,
      actionDetailByUid,
      resultByUid,
      turnReasoning,
      null,
      turnThinking,
      interrupted
    );
    turnItems = [];
    turnReasoning = "";
    turnThinking = { had: false, tokens: 0, durationMs: 0 };
    turnStartTs = null;
    turnEndTs = null;
  };

  for (const step of steps) {
    if (!step || typeof step !== "object") continue;
    const type = String(step.type || "");
    const ts = step.created_at || null;

    if (type === "USER_INPUT") {
      const text = agySupport.extractUserRequest(step.content);
      if (!text) continue;
      flushTurn(false);
      turnStartTs = ts;
      if (!topic) {
        const clean = cleanTopicCandidate(text);
        if (clean) topic = clean;
      }
      messages.push({
        role: "user",
        text: clipText(text, 4000),
        ts,
        uid: `agy-user-${step.step_index != null ? step.step_index : idx++}`,
      });
      continue;
    }

    // Skip system scaffolding
    if (
      type === "CONVERSATION_HISTORY" ||
      type === "EPHEMERAL_MESSAGE" ||
      type === "CHECKPOINT" ||
      type === "SYSTEM_MESSAGE"
    ) {
      continue;
    }

    if (type === "PLANNER_RESPONSE") {
      if (ts) turnEndTs = ts;
      if (typeof step.thinking === "string" && step.thinking.trim()) {
        const think = cleanMessageText(step.thinking).trim();
        turnThinking.had = true;
        const tokens = Math.max(1, Math.round(think.length / 4));
        turnThinking.tokens += tokens;
        turnItems.push({
          type: "think",
          text: think,
          uid: `agy-think-${step.step_index != null ? step.step_index : idx++}`,
          ts,
          tokens,
        });
        turnReasoning = turnReasoning ? turnReasoning + "\n" + think : think;
      }
      if (typeof step.content === "string" && step.content.trim()) {
        turnItems.push({
          type: "text",
          text: cleanMessageText(step.content).trim(),
          uid: `agy-text-${step.step_index != null ? step.step_index : idx++}`,
          ts,
        });
      }
      const calls = Array.isArray(step.tool_calls) ? step.tool_calls : [];
      calls.forEach((tc, i) => {
        if (!tc || typeof tc !== "object") return;
        const rawName = tc.name || "tool";
        const id = `agy-${step.step_index != null ? step.step_index : idx}-${rawName}-${i}`;
        const list = toolCtx.pendingByName.get(rawName) || [];
        list.push(id);
        toolCtx.pendingByName.set(rawName, list);
        const mapped = agySupport.mapAgyToolName(rawName);
        const input = agySupport.mapAgyToolInput(rawName, tc.args || {});
        actionDetailByUid.set(id, grokActionDetail(mapped, input));
        turnItems.push({ type: "tool", uid: id, ts });
      });
      continue;
    }

    // Tool result steps — attach output to pending tool ids
    const resultTypes = {
      VIEW_FILE: "view_file",
      RUN_COMMAND: "run_command",
      CODE_ACTION: "write_to_file",
      GREP_SEARCH: "grep_search",
      MCP_TOOL: "mcp_tool",
      ERROR_MESSAGE: "tool",
    };
    if (resultTypes[type] || type === "GENERIC") {
      const mapped = resultTypes[type] || "tool";
      let id = null;
      const candidates = [mapped, agySupport.mapAgyToolName(mapped), "view_file", "run_command", "write_to_file", "grep_search"];
      for (const c of candidates) {
        const q = toolCtx.pendingByName.get(c);
        if (q && q.length) {
          id = q.shift();
          break;
        }
      }
      if (!id) continue;
      const isError = type === "ERROR_MESSAGE" || String(step.status || "").toUpperCase() === "ERROR";
      resultByUid.set(id, {
        output: clipText(String(step.content || step.error || ""), MAX_ACTION_OUTPUT),
        isError,
      });
    }
  }
  flushTurn(false);

  // Windowing
  const cap = limit || HISTORY_MSG_LIMIT;
  let end = messages.length;
  let start = Math.max(0, end - cap);
  if (before) {
    const bi = messages.findIndex((m) => String(m.uid) === String(before));
    if (bi > 0) end = bi;
    start = Math.max(0, end - cap);
  }
  const window = messages.slice(start, end);
  const live =
    match && Date.now() - (match.mtime || 0) < agySupport.AGY_DETAIL_MIDTURN_STALE_MS;

  return {
    id: sessionId,
    provider: "agy",
    topic: topic || "Agy session",
    project: match.project || "",
    projectName: path.basename(match.project || "") || "Computer",
    cwd: match.project || "",
    messages: window,
    lastStopReason: live ? null : "end_turn",
    truncated: start > 0 || end < messages.length,
    hasMoreBefore: start > 0,
    nextBefore: window.length ? String(window[0].uid || "") : null,
    windowStart: start,
    windowEnd: end,
    totalMessages: messages.length,
  };
}

async function listGrok(limit) {
  const files = grokSessionFiles().sort((a, b) => b.mtime - a.mtime).slice(0, limit || HISTORY_LIST_LIMIT);
  const runningIds = runningSessionIdSet("grok");
  const results = [];
  for (const s of files) {
    let sum = getCachedSummary(s.file, s.size);
    if (!sum) {
      sum = grokSummaryFromFiles(s);
      setCachedSummary(s.file, s.size, sum);
    }
    if (sum.messages === 0) continue;
    const turnState = grokUpdatesTurnState(s);
    const hasStructuralState = !!turnState.lastKind;
    const structurallyLive = hasStructuralState
      && !turnState.completedAfterActivity
      && grokSessionIsLive(s, DETAIL_MIDTURN_STALE_MS);
    const live = runningIds.has(s.id)
      || (hasStructuralState
        ? structurallyLive
        : sessionIsLive(s.mtime, s.id, runningIds));
    results.push({
      provider: "grok",
      id: s.id,
      topic: sum.topic,
      project: s.project,
      projectName: path.basename(s.project || "") || "Computer",
      updatedAt: sum.lastTs || new Date(s.mtime).toISOString(),
      messageCount: sum.messages,
      live,
    });
  }
  return results;
}

// True when a chat_history user row is a real human prompt (not scaffolding).
function grokIsRealUserPrompt(ev, body) {
  if (!body) return false;
  if (ev && ev.synthetic_reason) return false;
  const text = String(body).trim();
  if (!text) return false;
  if (/^<user_info>|^<system-reminder>|^system-reminder/i.test(text)) return false;
  if (/^This session is being continued from a previous conversation/i.test(text)) return false;
  return true;
}

function grokReasoningSummaryText(ev) {
  if (!ev || typeof ev !== "object") return "";
  const summary = ev.summary;
  if (Array.isArray(summary)) {
    return summary
      .map((b) => {
        if (!b) return "";
        if (typeof b === "string") return b;
        if (b.type === "summary_text" && typeof b.text === "string") return b.text;
        if (typeof b.text === "string") return b.text;
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  if (typeof summary === "string") return summary;
  if (typeof ev.content === "string") return ev.content;
  return grokHistoryContentText(ev.content);
}

// History detail: fold each user turn into ONE assistant host (Worked card) with
// interleaved thinking / tool / narration nodes — same contract as claudeDetail.
// Source of truth is chat_history.jsonl (reasoning + assistant.tool_calls + tool_result).
async function grokDetail(sessionId, limit, before) {
  const match = grokSessionFiles().find((s) => s.id === sessionId);
  if (!match) return null;
  const messages = [];
  let topic = null;
  let idx = 0;
  try {
    if (fs.existsSync(match.summaryFile)) {
      const raw = JSON.parse(fs.readFileSync(match.summaryFile, "utf8"));
      topic = raw.generated_title || raw.session_summary || null;
    }
  } catch (_) {}

  let turnItems = [];
  let turnReasoning = "";
  let turnThinking = { had: false, tokens: 0, durationMs: 0 };
  let turnStartTs = null;
  let turnEndTs = null;
  let lastStopReason = null;
  let userTurnIndex = 0;
  let currentUserText = "";
  const actionDetailByUid = new Map();
  const resultByUid = new Map();
  let pending = newRuntimeAccumulator();

  const flushTurn = (interrupted) => {
    // Grok has no assistant uuids — host uid must NOT be window-relative or re-ingest
    // mints duplicate bridge-… rows (stacked empty Worked glass cards on the phone).
    const hostUid = currentUserText
      ? grokStableTurnUid(sessionId, userTurnIndex, currentUserText)
      : null;
    // Structurally finalized history turns: promote last narration even when tools
    // trailed it (Grok often ends mid-tool sequence then settles without stop_reason).
    const host = foldTurnIntoHost(
      messages,
      turnItems,
      actionDetailByUid,
      resultByUid,
      turnReasoning,
      hostUid,
      turnThinking,
      interrupted || true // history flush is always structural finalize
    );
    if (host) {
      settleGrokHistoryHost(host);
      // Override uid after fold if fold used first-item uid.
      if (hostUid) host.uid = hostUid;
      if (pending.order.length) {
        sealHistoryRuntime("grok", host, pending, turnDurationMs(turnStartTs, turnEndTs));
      }
    }
    pending = newRuntimeAccumulator();
    // Tool maps must not leak across user turns — same tool-call ids are rare but
    // residual detail/result joins poisoned later hosts (prior-turn tools on new cell).
    actionDetailByUid.clear();
    resultByUid.clear();
    turnItems = [];
    turnReasoning = "";
    turnThinking = { had: false, tokens: 0, durationMs: 0 };
    turnStartTs = null;
    turnEndTs = null;
    currentUserText = "";
  };

  await readJsonl(match.file, (ev) => {
    if (!ev || typeof ev !== "object") return;
    const type = String(ev.type || "").toLowerCase();

    if (type === "system") return;

    if (type === "user") {
      const body = cleanMessageText(grokHistoryContentText(ev.content));
      const queryMatch = body.match(/<user_query>\s*([\s\S]*?)\s*<\/user_query>/i);
      const text = (queryMatch ? queryMatch[1] : body).trim();
      if (!grokIsRealUserPrompt(ev, text)) return;
      flushTurn(false);
      userTurnIndex += 1;
      currentUserText = text;
      turnStartTs = ev.timestamp || ev.ts || null;
      if (!topic) {
        const clean = cleanTopicCandidate(text);
        if (clean) topic = clean;
      }
      messages.push({
        role: "user",
        text: clipText(text, 4000),
        ts: ev.timestamp || ev.ts || null,
        uid: ev.id || ev.uuid || `grok-user-${userTurnIndex}`,
      });
      return;
    }

    if (type === "reasoning") {
      const think = cleanMessageText(grokReasoningSummaryText(ev)).trim();
      if (!think) {
        // Encrypted CoT only — still surface a Thinking node (presence, not text).
        turnThinking.had = true;
        turnItems.push({
          type: "think",
          text: "",
          uid: ev.id || `grok-think-${idx++}`,
          ts: ev.timestamp || ev.ts || null,
          tokens: 0,
        });
        return;
      }
      turnThinking.had = true;
      const tokens = Math.max(1, Math.round(think.length / 4));
      turnThinking.tokens += tokens;
      turnItems.push({
        type: "think",
        text: think,
        uid: ev.id || `grok-think-${idx++}`,
        ts: ev.timestamp || ev.ts || null,
        tokens,
      });
      // Keep aggregate reasoning text for the host meta path (encrypted blob).
      turnReasoning = turnReasoning ? turnReasoning + "\n" + think : think;
      return;
    }

    if (type === "tool_result") {
      const id = ev.tool_call_id || ev.toolCallId || ev.id;
      if (!id) return;
      resultByUid.set(id, {
        output: clipText(toolResultText(ev.content), MAX_ACTION_OUTPUT),
        isError: !!(ev.is_error || ev.isError),
      });
      return;
    }

    if (type === "assistant") {
      const ts = ev.timestamp || ev.ts || null;
      if (ts) turnEndTs = ts;
      lastStopReason = typeof ev.stop_reason === "string" ? ev.stop_reason : lastStopReason;

      const text = cleanMessageText(grokHistoryContentText(ev.content)).trim();
      if (text) {
        turnItems.push({
          type: "text",
          text,
          uid: ev.id || ev.uuid || `grok-asst-${idx++}`,
          ts,
        });
      }

      const toolCalls = Array.isArray(ev.tool_calls) ? ev.tool_calls : [];
      for (const tc of toolCalls) {
        if (!tc || typeof tc !== "object") continue;
        const id = tc.id || `grok-tool-${idx++}`;
        let args = tc.arguments != null ? tc.arguments : tc.input;
        if (typeof args === "string") {
          try {
            args = JSON.parse(args);
          } catch {
            args = {};
          }
        }
        const det = grokActionDetail(tc.name || tc.function?.name || "tool", args || {});
        actionDetailByUid.set(id, det);
        turnItems.push({ type: "tool", uid: id, ts });
        // Seal file edits into the runtime/diff card when possible.
        if (det.kind === "edit" || det.kind === "write") {
          try {
            collectClaudeEdits(pending, [
              {
                type: det.kind === "write" ? "tool_use" : "tool_use",
                name: det.kind === "write" ? "Write" : "Edit",
                id,
                input: {
                  file_path: det.path || det.name,
                  old_string: args && args.old_string,
                  new_string: args && args.new_string,
                  content: args && args.content,
                },
              },
            ]);
          } catch (_) {}
        }
      }
    }
  });

  flushTurn(false);

  // Live desktop runs write tools/thinking to updates.jsonl BEFORE chat_history
  // catches up. Overlay those onto the trailing assistant host so the phone feed
  // ticks (Read/Edit/Run/Thinking) while the turn is still open.
  mergeGrokLiveUpdatesIntoMessages(match, messages);

  // Optional before-cursor windowing (same contract as Claude/Codex).
  const cap = Math.max(1, Number(limit) || HISTORY_MSG_LIMIT);
  let start = 0;
  let end = messages.length;
  if (before) {
    const bi = messages.findIndex((m) => String(m.uid || "") === String(before));
    if (bi > 0) end = bi;
  }
  start = Math.max(0, end - cap);
  const window = messages.slice(start, end);

  // Grok has no Claude-style stop_reason. NEVER default to "end_turn" while the
  // session is still being written — that made markDetailLiveTurn always settle
  // and the phone never showed live thinking/tool ticks for desktop Grok runs.
  // Order: explicit turn_completed (authoritative) → short quiet window → else live.
  const inferredStop = (() => {
    if (lastStopReason) return lastStopReason;
    const turnState = grokUpdatesTurnState(match);
    // Event-driven seal: turn_completed after the last live activity → done now,
    // including bridge restart after the event was already written to disk.
    if (turnState.completedAfterActivity) return "end_turn";
    const live = grokSessionIsLive(match, GROK_DETAIL_MIDTURN_STALE_MS);
    // Quiet past the Grok mid-turn window → settled (stale trailingToolPending too).
    if (!live) return "end_turn";
    const last = messages.length ? messages[messages.length - 1] : null;
    if (last && last.trailingToolPending) return "tool_use";
    if (turnState.lastKind === "turn_completed") return "end_turn";
    // File still hot → mid-turn (thinking / tools).
    return null;
  })();

  return {
    id: sessionId,
    provider: "grok",
    topic: topic || "Grok session",
    project: match.project,
    projectName: path.basename(match.project || "") || "Computer",
    cwd: match.project,
    messages: window,
    lastStopReason: inferredStop,
    truncated: start > 0 || end < messages.length,
    hasMoreBefore: start > 0,
    nextBefore: window.length ? String(window[0].uid || "") : null,
    windowStart: start,
    windowEnd: end,
    totalMessages: messages.length,
  };
}

/** True when chat_history or updates.jsonl was written within the live window. */
function grokSessionIsLive(match, windowMs) {
  if (!match || !match.file) return false;
  const win = windowMs || LIVE_SESSION_WINDOW_MS;
  const now = Date.now();
  try {
    if (now - fs.statSync(match.file).mtimeMs < win) return true;
  } catch (_) {}
  try {
    const updates = path.join(path.dirname(match.file), "updates.jsonl");
    if (fs.existsSync(updates) && now - fs.statSync(updates).mtimeMs < win) return true;
  } catch (_) {}
  try {
    const events = path.join(path.dirname(match.file), "events.jsonl");
    if (fs.existsSync(events) && now - fs.statSync(events).mtimeMs < win) return true;
  } catch (_) {}
  return false;
}

/**
 * Scan the tail of updates.jsonl for turn-boundary events.
 * completedAfterActivity: the last boundary-ish event is turn_completed (no newer
 * tool/thought/message activity after it) — seal even if mtime is still "fresh"
 * from the turn_completed write itself or a trailing recap.
 */
function grokUpdatesTurnState(match) {
  const empty = { lastKind: "", completedAfterActivity: false };
  if (!match || !match.file) return empty;
  const updatesFile = path.join(path.dirname(match.file), "updates.jsonl");
  if (!fs.existsSync(updatesFile)) return empty;
  let text = "";
  try {
    const st = fs.statSync(updatesFile);
    const maxBytes = Math.min(st.size, 96 * 1024);
    const fd = fs.openSync(updatesFile, "r");
    const buf = Buffer.alloc(maxBytes);
    const n = fs.readSync(fd, buf, 0, maxBytes, Math.max(0, st.size - maxBytes));
    fs.closeSync(fd);
    text = buf.slice(0, n).toString("utf8");
  } catch (_) {
    return empty;
  }
  // Activity that means a turn is still (or again) in flight.
  const liveKinds = new Set([
    "tool_call",
    "tool_call_update",
    "agent_thought_chunk",
    "agent_message_chunk",
    "user_message_chunk",
    "turn_started",
  ]);
  let lastKind = "";
  let lastLiveOrComplete = "";
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let rec = null;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    const u = (rec && rec.params && rec.params.update) || (rec && rec.update) || null;
    if (!u || typeof u !== "object") continue;
    const kind = String(u.sessionUpdate || "");
    if (!kind) continue;
    lastKind = kind;
    if (liveKinds.has(kind) || kind === "turn_completed") lastLiveOrComplete = kind;
  }
  return {
    lastKind,
    completedAfterActivity: lastLiveOrComplete === "turn_completed",
  };
}

/** Provider-scoped mid-turn quiet window (Claude long silence vs Grok chatty tools). */
function detailMidturnWindowMs(provider) {
  const p = String(provider || "").trim().toLowerCase();
  if (p === "grok") return GROK_DETAIL_MIDTURN_STALE_MS;
  if (p === "agy") return agySupport.AGY_DETAIL_MIDTURN_STALE_MS;
  if (p === "claude") return DETAIL_MIDTURN_STALE_MS;
  return LIVE_SESSION_WINDOW_MS;
}

/**
 * Keep only updates belonging to the CURRENT turn.
 * Cut after the last turn_completed / turn_started / user_message_chunk so a
 * multi-MB updates.jsonl tail cannot re-inject prior-turn text/tools into the
 * trailing host (phone showed previous "Verdict" + current answer in one cell).
 */
function sliceGrokUpdatesLinesToCurrentTurn(lines) {
  let cut = 0;
  let sawTurnStart = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line || !line.trim()) continue;
    let rec = null;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    const u = (rec && rec.params && rec.params.update) || (rec && rec.update) || null;
    if (!u || typeof u !== "object") continue;
    const kind = String(u.sessionUpdate || "");
    if (kind === "turn_completed") {
      cut = i + 1;
      sawTurnStart = false;
    } else if (kind === "turn_started" || kind === "user_message_chunk") {
      cut = i;
      sawTurnStart = true;
    }
  }
  // sawTurnStart: the retained slice's own beginning is a real turn boundary we
  // actually saw, not just wherever our 768KB tail-read happened to start. Callers
  // use this to decide whether the live edge may fully own this turn's narration
  // (slice provably complete) or must defer to already-folded history (slice may be
  // missing earlier content the tail-read cut off) — see mergeGrokLiveUpdatesIntoMessages.
  return { lines: lines.slice(cut), sawTurnStart };
}

/**
 * Collapse only *adjacent trailing* text nodes (same continuous stream), never
 * text that is separated by tools/thinking. The old "keep only last text anywhere"
 * policy forced [tools…, finalText] and broke Grok chronological interleave.
 */
function collapseLiveTextNodes(nodes) {
  if (!Array.isArray(nodes) || nodes.length < 2) return nodes || [];
  const out = [];
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i];
    if (!n) continue;
    const kind = String(n.kind || "").toLowerCase();
    const prev = out.length ? out[out.length - 1] : null;
    const prevKind = prev ? String(prev.kind || "").toLowerCase() : "";
    // Merge consecutive text nodes (growing stream chunks with different ids).
    if (kind === "text" && prevKind === "text") {
      const label = String(n.label || n.detail || "").trim();
      const prevLabel = String(prev.label || prev.detail || "").trim();
      if (label && label.length >= prevLabel.length) {
        out[out.length - 1] = Object.assign({}, prev, n, {
          label: n.label || prev.label,
          detail: n.detail || prev.detail,
        });
      }
      continue;
    }
    out.push(n);
  }
  return out;
}

/**
 * Fold recent updates.jsonl tool/thinking/message chunks into the trailing
 * assistant host. Source split: chat_history is authoritative when settled;
 * updates are the live edge for desktop Grok tool ticks — CURRENT TURN ONLY.
 */
function mergeGrokLiveUpdatesIntoMessages(match, messages) {
  if (!match || !Array.isArray(messages) || !messages.length) return;
  if (!grokSessionIsLive(match, LIVE_SESSION_WINDOW_MS * 6)) return;
  const updatesFile = path.join(path.dirname(match.file), "updates.jsonl");
  if (!fs.existsSync(updatesFile)) return;

  let last = messages[messages.length - 1];
  // Fresh user prompt, no assistant yet — seed a running host so tools can attach.
  if (last && last.role === "user") {
    last = {
      role: "assistant",
      text: "",
      uid: `grok-live-${match.id || "host"}`,
      ts: new Date().toISOString(),
      running: true,
      progressNodes: [],
      trailingToolPending: false,
    };
    messages.push(last);
  }
  if (!last || last.role !== "assistant") return;

  // Tail the last ~768KB of updates (full file can be multi-MB).
  let text = "";
  try {
    const st = fs.statSync(updatesFile);
    const maxBytes = Math.min(st.size, 768 * 1024);
    const fd = fs.openSync(updatesFile, "r");
    const buf = Buffer.alloc(maxBytes);
    const start = Math.max(0, st.size - maxBytes);
    const n = fs.readSync(fd, buf, 0, maxBytes, start);
    fs.closeSync(fd);
    text = buf.slice(0, n).toString("utf8");
  } catch (_) {
    return;
  }

  const { lines: turnLines, sawTurnStart } = sliceGrokUpdatesLinesToCurrentTurn(text.split("\n"));
  if (!turnLines.length) return;

  const nodesById = new Map();
  // Seed prior history-folded nodes (tools + thinking + interim text segments).
  // Segmented live ids (grok-text-live-N) replace legacy single-slot live blobs.
  // When the live slice is provably COMPLETE for this turn (sawTurnStart), the walk
  // below regenerates narration/thinking for the whole open turn from scratch under
  // grok-text-live-N / grok-thinking-live-N ids — seeding the history-folded
  // txt-*/think-* copies too would paint the SAME content twice under different ids
  // (the duplicate/"jumping" narration bug). Tool nodes always seed either way: their
  // id is the model's real tool_call id, shared by both paths, so a later tool_call /
  // tool_call_update just overwrites the same entry in place, never duplicates it.
  if (Array.isArray(last.progressNodes)) {
    for (const n of last.progressNodes) {
      if (!n || !n.id) continue;
      const id = String(n.id);
      if (id === "grok-text-live" || id === "grok-thinking-live") continue;
      const nodeKind = String(n.kind || "");
      if (sawTurnStart && (nodeKind === "text" || nodeKind === "thinking")) continue;
      nodesById.set(id, n);
    }
  }
  let thoughtAcc = "";
  let textAcc = "";
  let seg = 0;
  // If seeded nodes already exist, start after the highest live segment.
  for (const id of nodesById.keys()) {
    const m = String(id).match(/^grok-(?:text|thinking)-live-(\d+)$/);
    if (m) seg = Math.max(seg, parseInt(m[1], 10));
  }
  let needNewSeg = false;
  let order = Array.from(nodesById.keys());
  const ensureOrder = (id) => {
    if (!order.includes(id)) order.push(id);
  };
  const bumpSegAfterTool = () => {
    needNewSeg = true;
    thoughtAcc = "";
    textAcc = "";
  };
  const ensureSegForPhase = (phase) => {
    // phase: "thought" | "text"
    if (needNewSeg) {
      seg += 1;
      needNewSeg = false;
      thoughtAcc = "";
      textAcc = "";
    } else if (phase === "thought" && textAcc.trim()) {
      // Thought after open text without a tool — seal text, new segment.
      textAcc = "";
      seg += 1;
    }
  };
  let sawTurnCompleted = false;
  let compactingId = null;

  for (const line of turnLines) {
    if (!line.trim()) continue;
    let rec = null;
    try {
      rec = JSON.parse(line);
    } catch {
      continue;
    }
    const u = (rec && rec.params && rec.params.update) || (rec && rec.update) || null;
    if (!u || typeof u !== "object") continue;
    const kind = String(u.sessionUpdate || "");

    // Grok auto-compact (and manual compact) — show live in header/cell, not blank jump.
    if (kind === "auto_compact_started" || kind === "compaction_checkpoint") {
      compactingId = compactingId || `grok-compacting-${seg}`;
      nodesById.set(compactingId, {
        id: compactingId,
        label: "Compacting conversation…",
        kind: "compacting",
        status: "running",
        depth: 0,
      });
      ensureOrder(compactingId);
      last.running = true;
      continue;
    }
    if (kind === "auto_compact_completed") {
      const id = compactingId || `grok-compacting-${seg}`;
      const before = u.tokens_before != null ? u.tokens_before : u.tokensBefore;
      const after = u.tokens_after != null ? u.tokens_after : u.tokensAfter;
      let label = "Compacted conversation";
      if (typeof before === "number" && typeof after === "number") {
        label = `Compacted context · ${before} → ${after} tokens`;
      }
      nodesById.set(id, {
        id,
        label,
        kind: "compacting",
        status: "done",
        depth: 0,
      });
      ensureOrder(id);
      compactingId = null;
      bumpSegAfterTool();
      continue;
    }

    if (kind === "agent_thought_chunk") {
      const chunk =
        (u.content && (u.content.text || (typeof u.content === "string" ? u.content : ""))) || "";
      if (chunk) {
        ensureSegForPhase("thought");
        thoughtAcc += chunk;
        // Only paint a live node once the slice provably covers the whole open turn
        // (sawTurnStart) — otherwise history already owns this turn's thinking nodes
        // and a live copy under a different id would duplicate them (see seeding above).
        if (sawTurnStart) {
          const id = `grok-thinking-live-${seg}`;
          const tokens = Math.max(1, Math.round(thoughtAcc.length / 4));
          const detail = clipText(thoughtAcc, 8000);
          nodesById.set(id, {
            id,
            label: "Thinking",
            kind: "thinking",
            status: "streaming",
            depth: 0,
            tokens,
            detail,
            // History fold puts CoT on encrypted actions; live path rides plaintext detail.
            output: detail,
          });
          ensureOrder(id);
        }
      }
      continue;
    }

    if (kind === "agent_message_chunk") {
      const chunk =
        (u.content && (u.content.text || (typeof u.content === "string" ? u.content : ""))) || "";
      if (chunk) {
        ensureSegForPhase("text");
        // Smart join: avoid "issue.This" when chunks are sentence-sized.
        if (textAcc && chunk) {
          const a = textAcc[textAcc.length - 1];
          const b = chunk[0];
          if (/\S/.test(a) && /\S/.test(b) && !/[(\[{/-]/.test(b) && !/[.,;:!?)\]}]/.test(b)) {
            if (/[.!?:]$/.test(textAcc) && /[A-Z]/.test(b)) textAcc += "\n\n";
            else if (!/\s$/.test(textAcc) && !/^\s/.test(chunk)) textAcc += " ";
          }
        }
        textAcc += chunk;
        // Live: keep body empty and ride text as a feed node (phone suppresses body mid-run).
        last.text = "";
        // Only paint a live node once the slice provably covers the whole open turn
        // (sawTurnStart) — otherwise history already owns this turn's narration and a
        // live copy under a different id would duplicate it (see seeding above).
        if (sawTurnStart) {
          const id = `grok-text-live-${seg}`;
          nodesById.set(id, {
            id,
            label: clipText(textAcc, 4000),
            kind: "text",
            status: "streaming",
            depth: 0,
            detail: clipText(textAcc, 4000),
          });
          ensureOrder(id);
        }
      }
      continue;
    }

    if (kind === "tool_call") {
      const id = String(u.toolCallId || u.tool_call_id || u.id || "");
      if (!id) continue;
      const meta = (u._meta && (u._meta["x.ai/tool"] || u._meta.xAiTool)) || {};
      const name = meta.name || u.title || "tool";
      let input = u.rawInput != null ? u.rawInput : u.input || {};
      if (typeof input === "string") {
        try {
          input = JSON.parse(input);
        } catch {
          input = { raw: input };
        }
      }
      const det = grokActionDetail(name, input || {});
      const node = actionNode(det, id, "running");
      // Wall-clock start for duration (MCP Ask Fable can run minutes).
      node._startedAtMs =
        Number(rec.timestamp) > 1e12
          ? Number(rec.timestamp)
          : Number(rec.timestamp) > 0
            ? Number(rec.timestamp) * 1000
            : Date.now();
      nodesById.set(id, node);
      ensureOrder(id);
      bumpSegAfterTool();
      continue;
    }

    if (kind === "tool_call_update") {
      const id = String(u.toolCallId || u.tool_call_id || u.id || "");
      if (!id) continue;
      const status = String(u.status || "").toLowerCase();
      const existing = nodesById.get(id);
      if (status === "completed" || status === "failed" || status === "error" || status === "cancelled") {
        if (existing) {
          existing.status = status === "completed" ? "done" : "error";
          const endMs =
            Number(rec.timestamp) > 1e12
              ? Number(rec.timestamp)
              : Number(rec.timestamp) > 0
                ? Number(rec.timestamp) * 1000
                : Date.now();
          if (existing._startedAtMs && endMs > existing._startedAtMs) {
            const dt = endMs - existing._startedAtMs;
            if (dt > 0 && dt < 30 * 60 * 1000) existing.durationMs = dt;
          }
          // Attach tool result text for MCP/generic tools (sheet body).
          const content = grokUpdateContentText(u.content);
          if (content && (existing.kind === "mcp" || existing.kind === "tool")) {
            existing.detail = clipText(content, 4000);
            existing.output = existing.detail;
          }
        } else {
          const meta = (u._meta && (u._meta["x.ai/tool"] || u._meta.xAiTool)) || {};
          const name = meta.name || u.title || "tool";
          let input = u.rawInput != null ? u.rawInput : u.input || {};
          if (typeof input === "string") {
            try {
              input = JSON.parse(input);
            } catch {
              input = {};
            }
          }
          const det = grokActionDetail(name, input || {});
          nodesById.set(id, actionNode(det, id, status === "completed" ? "done" : "error"));
          ensureOrder(id);
          bumpSegAfterTool();
        }
      } else if (!existing) {
        const meta = (u._meta && (u._meta["x.ai/tool"] || u._meta.xAiTool)) || {};
        const name = meta.name || u.title || "tool";
        let input = u.rawInput != null ? u.rawInput : u.input || {};
        if (typeof input === "string") {
          try {
            input = JSON.parse(input);
          } catch {
            input = {};
          }
        }
        const det = grokActionDetail(name, input || {});
        nodesById.set(id, actionNode(det, id, "running"));
        ensureOrder(id);
        bumpSegAfterTool();
      }
      continue;
    }

    if (kind === "turn_completed") {
      sawTurnCompleted = true;
      // Settle live edge markers.
      for (const n of nodesById.values()) {
        if (n && (n.status === "streaming" || n.status === "running")) {
          if (n.kind === "thinking" || n.kind === "text" || n.kind === "compacting") n.status = "done";
          else if (String(n.status || "") === "running") n.status = "done";
        }
      }
      last.running = false;
      last.trailingToolPending = false;
      // Promote ONLY the last text segment into the message body (final answer);
      // keep earlier text segments interleaved with tools inside the Worked card.
      if (textAcc.trim()) {
        last.text = clipText(textAcc.trim(), 4000);
        const lastTextId = `grok-text-live-${seg}`;
        nodesById.delete(lastTextId);
        order = order.filter((id) => id !== lastTextId);
      }
    }
  }

  let nodes = order.map((id) => nodesById.get(id)).filter(Boolean);
  // Adjacent text-only merge; never collapse text across tools.
  nodes = collapseLiveTextNodes(nodes);
  // Strip private timing fields before shipping to the phone.
  nodes = nodes.map((n) => {
    if (!n || n._startedAtMs == null) return n;
    const { _startedAtMs, ...rest } = n;
    return rest;
  });
  nodes = nodes.slice(-60);
  if (nodes.length || sawTurnCompleted) {
    // Stop-loss: never replace a rich live host with an empty settled payload.
    const prevNodes = Array.isArray(last.progressNodes) ? last.progressNodes : [];
    const prevBody = String(last.text || "").trim();
    const nextBody = String(last.text || "").trim();
    const prevHas =
      prevBody.length > 0 ||
      prevNodes.some((n) => n && (n.kind === "text" || n.kind === "thinking" || (n.label && n.label.length > 2)));
    const nextHas =
      nextBody.length > 0 ||
      nodes.some((n) => n && (n.kind === "text" || n.kind === "thinking" || n.kind === "compacting" || (n.label && n.label.length > 2)));
    if (sawTurnCompleted && prevHas && !nextHas) {
      // Keep prior content; just clear running flags on existing nodes.
      for (const n of prevNodes) {
        if (n && (n.status === "streaming" || n.status === "running")) {
          if (n.kind === "thinking" || n.kind === "text" || n.kind === "compacting") n.status = "done";
          else if (String(n.status || "") === "running") n.status = "done";
        }
      }
      last.progressNodes = prevNodes;
      if (!String(last.text || "").trim()) {
        const lastText = [...prevNodes].reverse().find((n) => n && n.kind === "text");
        if (lastText && lastText.label) last.text = String(lastText.label);
      }
      last.running = false;
      last.trailingToolPending = false;
      return;
    }
    last.progressNodes = nodes;
    // Pending tool = still live (unless turn_completed already cleared it).
    if (last.running !== false) {
      last.trailingToolPending = nodes.some(
        (n) =>
          n &&
          n.kind !== "text" &&
          n.kind !== "thinking" &&
          n.kind !== "compacting" &&
          String(n.status || "") === "running"
      );
    }
  }
}

// ── Live transcript tail (directly-run sessions) ─────────────────────
// A `claude`/`codex` session the user started in their OWN terminal is never
// spawned by us via run_task, so it has no live stream — we only read it on
// demand. While the phone is viewing such a session we WATCH its JSONL and
// re-push the transcript as it grows, so the app upserts new turns live.
// Keyed by chatId, capped, polled via watchFile (robust to appends), and torn
// down on disconnect. Re-pushes reuse the ORIGINAL requestId so the app's
// existing ingest upserts in place — no server change needed.
const MAX_HISTORY_WATCHERS = 8;
// Coalesce rapid transcript/updates appends before re-read. Grok updates.jsonl
// ticks very often during tools — 200ms caused full history re-pushes every
// couple hundred ms and phone layout thrash. 450ms still feels live.
const HISTORY_WATCH_DEBOUNCE_MS = 450;
const historyWatchers = new Map(); // chatId -> watcher record

function sessionFilePath(provider, sessionId) {
  if (!sessionId) return null;
  const p = String(provider || "").trim().toLowerCase();
  const files =
    p === "codex" ? codexSessionFiles()
    : p === "grok" ? grokSessionFiles()
    : p === "agy" ? agySupport.agySessionFiles()
    : claudeSessionFiles();
  const match = files.find((s) => s.id === sessionId || (p === "codex" && s.name && s.name.includes(sessionId)));
  return match ? match.file : null;
}

// True while any run_task is in flight for this chat — used to flag the live turn.
function isChatTaskRunning(chatId) {
  for (const entry of runningTasks.values()) {
    if (entry && entry.chatId === chatId) return true;
  }
  return false;
}

function runningTaskForChat(chatId) {
  for (const entry of runningTasks.values()) {
    if (entry && entry.chatId === chatId) return entry;
  }
  return null;
}

// True when the session's transcript file was appended to within the live window —
// the signal that a turn is in flight for a session the bridge did NOT spawn (a
// run the user started directly in their own desktop terminal).
function sessionFileIsLive(provider, sessionId, windowMs) {
  const p = String(provider || "").trim().toLowerCase();
  const win = windowMs || LIVE_SESSION_WINDOW_MS;
  // Grok: tools/thinking often land in updates.jsonl / events.jsonl while
  // chat_history is quiet for long stretches — check all three.
  if (p === "grok") {
    const match = grokSessionFiles().find((s) => s.id === sessionId);
    return match ? grokSessionIsLive(match, win) : false;
  }
  if (p === "agy") {
    const match = agySupport.agySessionFiles().find((s) => s.id === sessionId);
    if (!match) return false;
    try {
      return Date.now() - (match.mtime || 0) < win;
    } catch {
      return false;
    }
  }
  const file = sessionFilePath(provider, sessionId);
  if (!file) return false;
  try {
    return Date.now() - fs.statSync(file).mtimeMs < win;
  } catch (_) {
    return false;
  }
}

// Flag the trailing turn of a live session's detail payload as "working" so the
// phone renders the live state (shimmer + action feed) instead of collapsing to a
// finalized "Worked · N steps" card. Live = a bridge task is running for this chat
// OR the transcript file is still growing (desktop-terminal run). Returns true if
// the turn was marked.
// The trailing "[Request interrupted by user…]" user message a stop leaves in the
// transcript. A session ending on it is SETTLED — nothing more is coming until the
// next real prompt — even though the last assistant stop_reason still reads
// mid-turn (tool_use/null), so the structural check alone would keep it "running"
// for the whole mid-turn window (phantom Thinking after every stop).
function isInterruptMarkerMessage(m) {
  return !!m && m.role === "user" && /^\s*\[request interrupted/i.test(String(m.text || ""));
}

function markDetailLiveTurn(result, provider, sessionId, chatId) {
  if (!result || result.mode !== "detail") return false;
  const msgs = result.session && result.session.messages;
  if (!Array.isArray(msgs)) return false;
  const runningEntry = runningTaskForChat(chatId);
  const spawnedRunning = !!runningEntry;
  // A bridge-owned task is live before Claude has persisted either the mirrored user
  // prompt or its first assistant block. Surface that pre-token thinking phase now;
  // otherwise STOP/header state only appears after the first streamed text/tool node.
  if (!msgs.length) {
    const placeholder = runningPlaceholderMessage(runningEntry);
    if (!placeholder) return false;
    msgs.push(placeholder);
    return true;
  }
  if (isInterruptMarkerMessage(msgs[msgs.length - 1])) return false; // stopped → settled
  // Structural turn state (Claude only): the transcript's last assistant entry says
  // whether the turn truly ended (end_turn / stop_sequence) or is mid-flight
  // (tool_use, or null while an entry is being written). mtime alone can't tell a
  // finished turn from one silently thinking or running a long build — both write
  // nothing for minutes — which is why the 15s window blanked live cells mid-turn.
  const stop = String((result.session && result.session.lastStopReason) || "").toLowerCase();
  const structurallyDone = stop === "end_turn" || stop === "stop_sequence";
  // Claude: long thinking / tool gaps write nothing for minutes → wide window.
  // Grok: tools tick updates.jsonl often → short window (see GROK_DETAIL_MIDTURN_STALE_MS).
  // Codex: plain freshness window.
  const midturnWindowMs = detailMidturnWindowMs(provider);
  const last0 = msgs[msgs.length - 1];
  // A fresh user prompt with no assistant reply yet = the model is thinking before
  // its first token — the phone otherwise shows nothing "live" until the first
  // entry lands. Synthesize a running thinking turn so the chat goes live at send.
  if (last0 && last0.role === "user"
      && (spawnedRunning || sessionFileIsLive(provider, sessionId, midturnWindowMs))) {
    const placeholder = runningPlaceholderMessage(runningEntry) || {
      role: "assistant",
      text: "",
      uid: `running-mirror-${sessionId}`,
      ts: new Date().toISOString(),
      running: true,
      progressNodes: [
        { id: `running-mirror-${sessionId}`, label: "Thinking", kind: "thinking", status: "running", depth: 0 },
      ],
    };
    msgs.push(placeholder);
    return true;
  }
  if (!spawnedRunning) {
    if (structurallyDone) return false;
    // Mid-turn by structure: stay live through long write gaps (thinking, builds)
    // up to the stale cap; a mid-turn crash/kill is the only thing that lingers.
    if (!sessionFileIsLive(provider, sessionId, midturnWindowMs)) return false;
  }
  const last = msgs[msgs.length - 1];
  if (last && last.role === "assistant") {
    markMessageRunning(last);
    // NOTE: we deliberately do NOT fold the turn's narration "text" nodes out of
    // progressNodes into message.text here. The phone SUPPRESSES the message body
    // while a turn is live, so moving prose into the body made live turns render
    // "commands only" (no narration). Keeping the text nodes inside progressNodes
    // lets the live feed interleave them with the tool steps (Read → text → Edit),
    // matching the agent-stream live path and the finished "Worked" card.
    return true;
  }
  return false;
}

function markMessageRunning(message) {
  if (!message || typeof message !== "object") return message;
  message.running = true;
  let nodes = Array.isArray(message.progressNodes) ? message.progressNodes : [];
  // Only merge *adjacent* text streams — never drop text that sits between tools
  // (Grok chronological interleave depends on multi-segment text nodes).
  nodes = collapseLiveTextNodes(nodes);
  // The phone SUPPRESSES the message body while a turn is live, and foldTurnIntoHost
  // routes the turn's LAST text into that body (it's the "summary"). Mid-run the
  // newest narration IS the last text, so it vanished from the live feed entirely
  // (textNodes=0 while bodyLen>0). Move the body into a trailing text node while
  // running; keep earlier interim text nodes that sit between tools.
  const body = String(message.text || "").trim();
  if (body) {
    const liveTailId = "live-tail-" + String(message.uid || "0");
    // Remove only a previous live-tail placeholder — not every kind:text node.
    nodes = nodes.filter((n) => !n || String(n.id || "") !== liveTailId);
    // If the last node is already this body text, just ensure status; else append.
    const last = nodes.length ? nodes[nodes.length - 1] : null;
    const lastIsSameText =
      last &&
      String(last.kind || "").toLowerCase() === "text" &&
      String(last.label || "").trim() === body;
    if (!lastIsSameText) {
      nodes = nodes.concat([{
        id: liveTailId,
        label: clipText(body, 4000),
        kind: "text",
        status: "done",
        depth: 0,
      }]);
    }
    message.text = "";
    message.progressNodes = nodes;
  } else {
    message.progressNodes = nodes;
  }
  // The live edge must mirror what is actually happening NOW. If the trailing tool
  // is still executing (no result yet), the running mark belongs on its node — the
  // header reads "Read foo.swift" while the Read truly runs. But once that tool's
  // result has landed (or the turn has no pending tool), the model is between
  // steps — reading output / reasoning / composing — so append a running
  // "Thinking" edge node instead: re-flagging the finished last tool left the
  // header stuck on "Reading…" while the desktop showed "Thinking · N tokens".
  if (message.trailingToolPending) {
    for (let i = nodes.length - 1; i >= 0; i--) {
      const node = nodes[i];
      if (!node || typeof node !== "object") continue;
      const kind = String(node.kind || "").trim().toLowerCase();
      if (kind === "text" || kind === "thinking") continue;
      const status = String(node.status || "").trim().toLowerCase();
      if (["failed", "error", "cancelled", "canceled", "stopped"].includes(status)) continue;
      node.status = "running";
      break;
    }
    return message;
  }
  const edgeId = "live-think-" + String(message.uid || "0");
  if (!nodes.length || String(nodes[nodes.length - 1].id || "") !== edgeId) {
    nodes = nodes.concat([{ id: edgeId, label: "Thinking", kind: "thinking", status: "running", depth: 0 }]);
    message.progressNodes = nodes;
  }
  return message;
}

function runningPlaceholderMessage(entry) {
  if (!entry || !entry.taskId) return null;
  const providerTitle =
    entry.provider === "claude"
      ? "Claude"
      : entry.provider === "codex"
        ? "Codex"
        : entry.provider === "grok"
          ? "Grok"
          : entry.provider === "agy"
            ? "Agy"
            : "Agent";
  const target = entry.repo && entry.repo.name ? entry.repo.name : "";
  return {
    role: "assistant",
    text: "",
    uid: `running-${entry.taskId}`,
    ts: new Date(entry.startedAt || Date.now()).toISOString(),
    running: true,
    progressNodes: [
      {
        // kind MUST NOT be "task": the phone reserves task-kind nodes for real
        // Claude Task-tool subagents and renders them as a spinning "Subagent"
        // row (the label is never shown) — this placeholder painted phantom
        // "Subagent" cells while a run was merely pending. "thinking" renders
        // the normal working shimmer.
        id: `running-${entry.taskId}`,
        label: `${providerTitle} is working`,
        kind: "thinking",
        status: "running",
        depth: 0,
        ...(target ? { target } : {}),
      },
    ],
  };
}

// Force the chat's history watcher to re-read + re-push even if the transcript text
// is unchanged (used when a run finishes so the live "running" flag flips to done).
function refireHistoryWatch(chatId) {
  const rec = historyWatchers.get(chatId);
  if (!rec) return;
  rec.lastSig = "";
  if (rec.schedule) rec.schedule();
}

function stopHistoryWatch(chatId) {
  const rec = historyWatchers.get(chatId);
  if (!rec) return;
  try { if (rec.watcher) rec.watcher.close(); } catch (_) {}
  if (Array.isArray(rec.extraWatchers)) {
    for (const w of rec.extraWatchers) {
      try { if (w) w.close(); } catch (_) {}
    }
  }
  try { if (rec.listener) fs.unwatchFile(rec.file, rec.listener); } catch (_) {}
  if (Array.isArray(rec.listeners)) {
    for (const entry of rec.listeners) {
      try { if (entry && entry.file && entry.fn) fs.unwatchFile(entry.file, entry.fn); } catch (_) {}
    }
  }
  try { if (rec.debounce) clearTimeout(rec.debounce); } catch (_) {}
  try { if (rec.settle) clearTimeout(rec.settle); } catch (_) {}
  try { if (rec.missingPoll) clearInterval(rec.missingPoll); } catch (_) {}
  historyWatchers.delete(chatId);
}

function stopAllHistoryWatches() {
  for (const chatId of Array.from(historyWatchers.keys())) stopHistoryWatch(chatId);
}

function startHistoryWatch(channel, { chatId, provider, sessionId, echo, limit }) {
  const file = sessionFilePath(provider, sessionId);
  if (!chatId || !sessionId || !file) return;
  // Remember the spec so the watch can be re-armed after a reconnect (the socket drop
  // calls stopAllHistoryWatches, which would otherwise leave the phone stuck on a stale
  // transcript until a full app restart).
  historyWatchSpecs.set(chatId, { provider, sessionId, echo, limit });
  while (historyWatchSpecs.size > MAX_HISTORY_WATCHERS) {
    const oldest = historyWatchSpecs.keys().next().value;
    if (oldest === chatId || !oldest) break;
    historyWatchSpecs.delete(oldest);
  }
  stopHistoryWatch(chatId); // replace any prior watch for this chat
  if (historyWatchers.size >= MAX_HISTORY_WATCHERS) {
    const oldest = historyWatchers.keys().next().value;
    if (oldest) stopHistoryWatch(oldest);
  }
  // Grok desktop: tool_call ticks land in updates.jsonl (and phase_changed in
  // events.jsonl) while chat_history is quiet — watch those too so live tool rows
  // re-push without waiting for the next history append.
  const extraWatchFiles = [];
  if (String(provider || "").toLowerCase() === "grok") {
    const dir = path.dirname(file);
    for (const name of ["updates.jsonl", "events.jsonl"]) {
      const p = path.join(dir, name);
      if (fs.existsSync(p)) extraWatchFiles.push(p);
    }
  }
  if (String(provider || "").toLowerCase() === "agy") {
    // Prefer full transcript when present (same content, sometimes written first).
    const full = agySupport.agyTranscriptFullPath(sessionId);
    if (full && fs.existsSync(full) && full !== file) extraWatchFiles.push(full);
  }
  const rec = {
    file,
    extraWatchFiles,
    watcher: null,
    listener: null,
    listeners: [],
    debounce: null,
    lastSig: "",
    busy: false,
    again: false,
    schedule: null,
  };
  const fire = () => {
    if (channel.state !== "joined") return;
    if (rec.busy) { rec.again = true; return; } // re-read once the in-flight read finishes
    rec.busy = true;
    readHistory({ provider, mode: "detail", sessionId, limit })
      .then((result) => {
        const msgs = (result && result.session && result.session.messages) || [];
        const runningEntry = runningTaskForChat(chatId);
        // Live = a bridge task is running for this chat OR the transcript file is
        // still being appended to (a run the user started in their OWN terminal,
        // which never enters runningTasks). Either way the LAST turn is in flight —
        // flag it so the phone renders the live "working" state (shimmer + feed)
        // instead of collapsing to a "Worked · N steps" card. For bridge tasks the
        // flag clears on close (refireHistoryWatch); for desktop runs a settle timer
        // below re-fires once the file goes quiet so the final card seals.
        // Structural override (Claude): stop_reason=end_turn settles NOW even if the
        // file was just written; tool_use/null keeps the turn live through long write
        // gaps (thinking, builds) up to the mid-turn cap — the bare 15s mtime window
        // flipped `running` off during those gaps and blanked the phone's live cell.
        // Codex has no stop_reason and keeps the plain freshness window.
        const stop = String((result && result.session && result.session.lastStopReason) || "").toLowerCase();
        const structurallyDone = stop === "end_turn" || stop === "stop_sequence";
        const midturnWindowMs = detailMidturnWindowMs(provider);
        let last = msgs.length ? msgs[msgs.length - 1] : null;
        // A trailing interrupt marker means the user STOPPED the turn: settle now.
        // stop_reason still reads mid-turn after a stop, so without this the session
        // would stay "running" for the whole mid-turn window.
        const stoppedByUser = isInterruptMarkerMessage(last);
        const liveByFile = structurallyDone || stoppedByUser
          ? false
          : sessionFileIsLive(provider, sessionId, midturnWindowMs);
        let running = !!runningEntry || liveByFile;
        if (running && last && last.role === "assistant") {
          markMessageRunning(last);
          // Keep narration "text" nodes inside progressNodes (see markDetailLiveTurn):
          // the phone interleaves them with the tool steps in the live feed. Folding
          // them into message.text hid them, because the live body is suppressed.
        } else if (runningEntry) {
          const placeholder = runningPlaceholderMessage(runningEntry);
          if (placeholder) {
            msgs.push(placeholder);
            last = placeholder;
          }
        } else if (last && last.role === "user" && !stoppedByUser
            && sessionFileIsLive(provider, sessionId, midturnWindowMs)) {
          // Fresh user prompt, no assistant entry yet: the model is thinking before
          // its first token. Synthesize a running thinking turn so the phone goes
          // live at send instead of at the first streamed text. (Not after a stop —
          // the interrupt marker is a user message too, but nothing is coming.)
          const placeholder = {
            role: "assistant",
            text: "",
            uid: `running-mirror-${sessionId}`,
            ts: new Date().toISOString(),
            running: true,
            progressNodes: [
              { id: `running-mirror-${sessionId}`, label: "Thinking", kind: "thinking", status: "running", depth: 0 },
            ],
          };
          msgs.push(placeholder);
          last = placeholder;
          running = true;
        } else if (last && last.role === "assistant") {
          // Settled: clear any leftover running flag from a prior live overlay so the
          // phone's ingest never re-asserts Thinking from a stale host.
          last.running = false;
        }
        // The live feed grows by appending progress NODES (a new Read/Edit/Run step or
        // an interior narration "text" node) as well as by the trailing summary text
        // growing. Fold the node count into the dedup signature so each new step
        // re-pushes — keying on text length alone left the feed frozen between the
        // narration paragraphs that bracket a burst of tool calls.
        // Node LABEL length rides the sig too: while live, the trailing narration
        // grows inside a text node's label (markMessageRunning moves the body there),
        // so text-length + node-count alone would freeze the feed mid-paragraph.
        const nodeSig = (m) =>
          Array.isArray(m && m.progressNodes)
            ? m.progressNodes.length + "." +
              m.progressNodes.reduce((a, n) => a + String((n && n.label) || "").length + (String((n && n.status) || "") === "running" ? 1 : 0), 0)
            : "0";
        const sig =
          msgs.length + ":" +
          (last
            ? (last.uid || "") + ":" + String(last.text || "").length +
              ":" + nodeSig(last)
            : 0) +
          ":" + (running ? "run" : "done");
        if (sig !== rec.lastSig) {
          rec.lastSig = sig;
          channel.push("history_result", { ok: true, ...echo, ...result });
        }
        // Desktop-terminal runs have no close event to seal the final card. Re-check
        // on the SAME mid-turn window the live flag uses (Grok ~30s, not the 15s
        // LIVE window that never flipped liveByFile off under the old 15-min check).
        // Reschedule until sealed so a premature quiet blip self-heals on the next tick.
        if (rec.settle) { clearTimeout(rec.settle); rec.settle = null; }
        if (running && !runningEntry && channel.state === "joined") {
          const settleIn = Math.min(midturnWindowMs, LIVE_SESSION_WINDOW_MS) + 1500;
          rec.settle = setTimeout(() => { rec.settle = null; fire(); }, settleIn);
        }
      })
      .catch(() => {})
      .finally(() => {
        rec.busy = false;
        if (rec.again) { rec.again = false; schedule(); }
      });
  };
  const schedule = () => {
    if (rec.debounce) return;
    rec.debounce = setTimeout(() => { rec.debounce = null; fire(); }, HISTORY_WATCH_DEBOUNCE_MS);
  };
  rec.schedule = schedule;
  rec.extraWatchers = [];
  rec.listeners = [];
  const armWatch = (targetFile, isPrimary) => {
    if (!targetFile) return;
    try {
      // Event-based: fires within ms of appends (transcript OR Grok updates.jsonl).
      const w = fs.watch(targetFile, { persistent: true }, () => schedule());
      if (isPrimary) rec.watcher = w;
      else rec.extraWatchers.push(w);
    } catch (_) {
      // Fallback to polling if fs.watch is unavailable on this filesystem.
      const fn = () => schedule();
      try {
        fs.watchFile(targetFile, { interval: 400 }, fn);
        if (isPrimary) rec.listener = fn;
        else rec.listeners.push({ file: targetFile, fn });
      } catch (__) {}
    }
  };
  armWatch(file, true);
  for (const extra of extraWatchFiles) armWatch(extra, false);
  // Grok: updates.jsonl may not exist at watch start — poll until it appears, then arm.
  if (String(provider || "").toLowerCase() === "grok") {
    const dir = path.dirname(file);
    const pollMissing = setInterval(() => {
      if (!historyWatchers.has(chatId)) {
        clearInterval(pollMissing);
        return;
      }
      for (const name of ["updates.jsonl", "events.jsonl"]) {
        const p = path.join(dir, name);
        if (!fs.existsSync(p)) continue;
        if (rec.extraWatchFiles.includes(p)) continue;
        rec.extraWatchFiles.push(p);
        armWatch(p, false);
        schedule();
      }
    }, 1000);
    if (pollMissing.unref) pollMissing.unref();
    rec.missingPoll = pollMissing;
  }
  historyWatchers.set(chatId, rec);
  schedule(); // catch anything appended between the initial read and now
}

// Home/chat rebinds can briefly issue the same History-list request several times per
// render pass. Keep the wire contract (each caller still receives its own requestId),
// but avoid rescanning every provider's on-disk session roster for an identical list.
const HISTORY_LIST_CACHE_MS = Number(process.env.VIBE_HISTORY_LIST_CACHE_MS || 750);
const historyListCache = new Map();

function historyListCacheKey(provider, chatId, limit) {
  return [String(provider || "").toLowerCase(), String(chatId || ""), String(limit || "")].join("|");
}

function clonedHistoryListResult(result) {
  return {
    ...result,
    sessions: Array.isArray(result && result.sessions) ? result.sessions.map((session) => ({ ...session })) : [],
  };
}

function handleHistoryRequest(channel, payload) {
  const provider = payload.provider || payload.agentBridgeProvider || "claude";
  const mode = payload.mode;
  const requestId = payload.requestId || payload.request_id || crypto.randomUUID();
  const chatId = payload.chatId || payload.chat_id || null;
  const sessionId = payload.sessionId || payload.session_id || null;
  const before = payload.before || payload.beforeCursor || payload.before_cursor || null;
  const echo = {
    requestId,
    provider,
    chatId,
    requesterUserId: payload.requesterUserId || payload.requester_user_id || null,
    ...(before ? { before } : {}),
  };
  const start = Date.now();
  const want = String(mode || "").toLowerCase() === "detail" || !!sessionId ? "detail" : "list";
  const listCacheKey = want === "list" && !before
    ? historyListCacheKey(provider, chatId, payload.limit)
    : null;
  if (listCacheKey) {
    const cached = historyListCache.get(listCacheKey);
    if (cached && Date.now() - cached.at < HISTORY_LIST_CACHE_MS) {
      const result = clonedHistoryListResult(cached.result);
      console.log(
        `[vibe-bridge][history] cache provider=${provider} mode=list chat=${chatId || "-"} ` +
          `requestId=${requestId} age=${Date.now() - cached.at}ms count=${result.sessions.length}`
      );
      channel.push("history_result", { ok: true, ...echo, ...result });
      return;
    }
  }
  // "Current session" request: detail for a chat without naming a session. Opening a
  // Claude/Codex DM mid-run must land directly in the running conversation, but the
  // phone doesn't know the session id yet (it only learns it from stream frames that
  // may be minutes apart). Resolve it here: the running task's session, else the last
  // session this chat's stream reported. No session → answer ok:false and the phone
  // just stays on the fresh surface.
  let effectiveSessionId = sessionId;
  if (want === "detail" && !effectiveSessionId && chatId) {
    const running = runningTaskForChat(chatId);
    effectiveSessionId = (running && running.sessionId) || sessionByChat.get(chatId) || null;
    // Grok desktop sessions often run outside phone-spawned run_task, so sessionByChat
    // stays empty. Fall back to the freshest non-ephemeral Grok session (preferring the
    // default repo cwd) so opening the Grok DM mid-run can live-tail thinking/tools.
    if (!effectiveSessionId && String(provider || "").toLowerCase() === "grok") {
      effectiveSessionId = latestGrokSessionIdForChat();
      if (effectiveSessionId) {
        sessionByChat.set(chatId, effectiveSessionId);
        console.log(
          `[vibe-bridge][history] current-session grok fallback chat=${chatId} → ${effectiveSessionId}`
        );
      }
    }
    if (!effectiveSessionId && String(provider || "").toLowerCase() === "agy") {
      const files = agySupport.agySessionFiles().sort((a, b) => b.mtime - a.mtime);
      const defCwd = DEFAULT_CWD;
      const prefer = files.find((s) => {
        if (!s.project) return false;
        try {
          return fs.realpathSync(s.project) === fs.realpathSync(defCwd);
        } catch {
          return s.project === defCwd;
        }
      });
      effectiveSessionId = (prefer || files[0] || {}).id || null;
      if (effectiveSessionId) {
        sessionByChat.set(chatId, effectiveSessionId);
        console.log(
          `[vibe-bridge][history] current-session agy fallback chat=${chatId} → ${effectiveSessionId}`
        );
      }
    }
    if (!effectiveSessionId) {
      // Hard throttle idle current-session polls (phone can re-ask every ~1.5s).
      // Still answer the first; suppress wire + log for 45s so the phone stops thrashing.
      const idleKey = String(chatId);
      const nowIdle = Date.now();
      const lastIdle = noCurrentSessionLogAtByChat.get(idleKey) || 0;
      if (nowIdle - lastIdle < 45000 && lastIdle > 0) {
        // Quiet drop — phone already got no_current_session recently.
        return;
      }
      noCurrentSessionLogAtByChat.set(idleKey, nowIdle);
      console.log(
        `[vibe-bridge][history] current-session request chat=${chatId} → no session, requestId=${requestId}`
      );
      channel.push("history_result", { ok: false, ...echo, mode: want, message: "no_current_session" });
      return;
    }
  }
  console.log(
    `[vibe-bridge][history] request provider=${provider} mode=${want} chat=${chatId || "-"} ` +
      `session=${effectiveSessionId || "-"} before=${before || "-"} requestId=${requestId}`
  );

  readHistory({ provider, mode, sessionId: effectiveSessionId, limit: payload.limit, before })
    .then((result) => {
      if (listCacheKey && result && result.mode === "list") {
        historyListCache.set(listCacheKey, {
          at: Date.now(),
          result: clonedHistoryListResult(result),
        });
      }
      const count =
        result && result.mode === "detail"
          ? (((result.session || {}).messages || []).length)
          : (((result || {}).sessions || []).length);
      console.log(
        `[vibe-bridge][history] result provider=${provider} mode=${result && result.mode} ` +
          `chat=${chatId || "-"} requestId=${requestId} ms=${Date.now() - start} count=${count}`
      );
      // Mark the trailing turn live on the FIRST detail push too (not just on watch
      // re-fires) so opening a live session lands directly in the working state with
      // no flash of the sealed "Worked · N steps" card.
      if (!before) markDetailLiveTurn(result, provider, effectiveSessionId, chatId);
      // Badge the session(s) blocked on a still-pending ask/command so the History
      // list shows a "waiting for approval" marker (the phone renders it from
      // `pendingAskKind`). Only genuinely-pending asks count (live blocked promise).
      if (result && result.mode === "list" && Array.isArray(result.sessions)) {
        for (const rec of pendingAsksByChat.values()) {
          if (!pendingAsks.has(rec.requestId)) continue;
          if (!rec.sessionId) continue;
          for (const s of result.sessions) {
            if (s && s.id === rec.sessionId) s.pendingAskKind = rec.kind || "ask";
          }
        }
      }
      channel.push("history_result", { ok: true, ...echo, ...result });
      // The phone opened a specific session → keep it live by tailing the
      // transcript and re-pushing as it grows.
      if (!before && chatId && effectiveSessionId && result.mode === "detail") {
        startHistoryWatch(channel, { chatId, provider, sessionId: effectiveSessionId, echo, limit: payload.limit });
      }
      // Opening the chat is also our chance to re-surface any ask/command the run
      // is still blocked on but the phone never saw (missed the live broadcast, or
      // the server's short-lived replay buffer already expired).
      if (chatId) reemitPendingAskForChat(channel, chatId);
    })
    .catch((err) => {
      console.log(
        `[vibe-bridge][history] failed provider=${provider} mode=${want} chat=${chatId || "-"} ` +
          `requestId=${requestId} ms=${Date.now() - start} error=${err && err.message ? err.message : "history_failed"}`
      );
      channel.push("history_result", { ok: false, ...echo, mode: want, message: err && err.message ? err.message : "history_failed" });
    });
}

// ── File open (full file contents, on demand) ───────────────────────
// The phone can open a file the agent touched. We read it ONLY when it lives
// inside a linked repository (never an arbitrary path), cap the size, and seal
// the bytes with the runtime key so the server relays an opaque blob — the
// user's source code never reaches the server in the clear.
const MAX_FILE_BYTES = 2 * 1024 * 1024;

function fileWithinLinkedRepo(absPath) {
  const dir = realDir(path.dirname(absPath));
  if (!dir) return null;
  const full = path.join(dir, path.basename(absPath));
  const inside = ADVERTISED_REPOSITORIES.some((repo) => {
    const root = realDir(repo.cwd || repo.path);
    return root && (full === root || full.startsWith(root + path.sep));
  });
  return inside ? full : null;
}

function handleFileRequest(channel, payload) {
  const requestId = payload.requestId || payload.request_id || crypto.randomUUID();
  const chatId = payload.chatId || payload.chat_id || null;
  const provider = payload.provider || payload.agentBridgeProvider || "claude";
  const rawPath = String(payload.path || payload.file || payload.filePath || "").trim();
  const echo = { requestId, chatId, provider, path: rawPath };
  try {
    if (!rawPath) throw new Error("missing path");
    const absPath = path.resolve(expandHome(rawPath) || rawPath);
    const safePath = fileWithinLinkedRepo(absPath);
    if (!safePath) throw new Error("that file is outside your linked repositories");
    const stat = fs.statSync(safePath);
    if (!stat.isFile()) throw new Error("not a file");
    let truncated = false;
    let content;
    if (stat.size > MAX_FILE_BYTES) {
      const fd = fs.openSync(safePath, "r");
      const buf = Buffer.alloc(MAX_FILE_BYTES);
      const read = fs.readSync(fd, buf, 0, MAX_FILE_BYTES, 0);
      fs.closeSync(fd);
      content = buf.slice(0, read).toString("utf8");
      truncated = true;
    } else {
      content = fs.readFileSync(safePath, "utf8");
    }
    const enc = encryptRuntimeBlob({
      path: safePath,
      name: path.basename(safePath),
      content,
      truncated,
      size: stat.size,
    });
    if (!enc) throw new Error("encryption key not ready — sync it from the bridge (--show-key)");
    channel.push("file_result", { ok: true, ...echo, agentFileEnc: enc, truncated, size: stat.size });
  } catch (err) {
    channel.push("file_result", { ok: false, ...echo, message: (err && err.message) || "file_failed" });
  }
}

// Structured usage snapshot for the phone's inline Usage panel. Same data /usage
// prints as text, but as machine-readable buckets so iOS can draw progress bars:
// Claude subscription limits (5h + 7-day, from the OAuth utilization endpoint),
// Codex primary/secondary windows (from live token_count rate_limits), plus
// this chat's last-run token/cost. Never throws; missing pieces are just omitted.
async function buildUsageReport(provider, chatId, task) {
  const currentModel = modelFor(provider, chatId, task);
  const report = {
    provider,
    model: currentModel || null,
    advisor: advisorFor(provider, chatId, task) || null,
    buckets: [],
    chat: null,
    limitHit: false,
    limitMessage: null,
  };
  if (provider === "claude") {
    const util = await fetchClaudeUtilization();
    if (util && typeof util === "object") {
      const add = (label, b) => {
        if (b && typeof b === "object" && b.utilization != null) {
          report.buckets.push({
            label,
            utilization: Math.round(Number(b.utilization)),
            resetsAt: b.resets_at || null,
          });
        }
      };
      add("5-hour session", util.five_hour);
      add("7-day (weekly)", util.seven_day);
      add("7-day Opus", util.seven_day_opus);
      add("7-day Sonnet", util.seven_day_sonnet);
    }
  } else if (provider === "codex") {
    // Prefer a live stream cache; otherwise scan recent Codex session logs so
    // the phone sheet works even before a Vibe-spawned run this process.
    let cached = lastRateLimitsByProvider.get("codex");
    if (cached && Date.now() - (cached.at || 0) > 30 * 60 * 1000) {
      lastRateLimitsByProvider.delete("codex");
      cached = null;
    }
    if (!cached || !Array.isArray(cached.buckets) || !cached.buckets.length) {
      const disk = fetchCodexUtilizationFromDisk();
      if (disk && disk.buckets && disk.buckets.length) {
        cached = { at: Date.now(), buckets: disk.buckets };
      }
    }
    if (cached && Array.isArray(cached.buckets)) {
      for (const b of cached.buckets) {
        if (!b || !b.label) continue;
        report.buckets.push({
          label: b.label,
          utilization: Math.round(Number(b.utilization) || 0),
          resetsAt: b.resetsAt || null,
        });
      }
      // Sticky `hit` from an earlier rate-limit event must not survive forever —
      // only surface it while utilization is still at/near the ceiling, or the
      // event is very recent (< 3 min). Otherwise the phone banner freezes on
      // "Rate limit hit" after the window has recovered.
      if (cached.hit) {
        const maxUtil = Math.max(
          0,
          ...cached.buckets.map((b) => Number(b && b.utilization) || 0)
        );
        const ageMs = Date.now() - (cached.at || 0);
        if (maxUtil >= 95 || ageMs < 3 * 60 * 1000) {
          report.limitHit = true;
          report.limitMessage = cached.message || null;
        } else {
          // Clear sticky hit so subsequent /usage replies are honest.
          lastRateLimitsByProvider.set("codex", {
            at: cached.at,
            buckets: cached.buckets,
            hit: false,
          });
        }
      }
    }
  } else if (provider === "grok") {
    const util = await fetchGrokUtilization();
    if (util && Array.isArray(util.buckets)) {
      for (const b of util.buckets) {
        if (!b || !b.label) continue;
        report.buckets.push({
          label: b.label,
          utilization: Math.round(Number(b.utilization) || 0),
          resetsAt: b.resetsAt || null,
        });
      }
      if (util.tier) report.model = report.model || util.tier;
    }
  } else if (provider === "agy") {
    const util = await fetchAgyUtilization();
    if (util && Array.isArray(util.buckets)) {
      for (const b of util.buckets) {
        if (!b || !b.label) continue;
        report.buckets.push({
          label: b.label,
          utilization: Math.round(Number(b.utilization) || 0),
          resetsAt: b.resetsAt || null,
        });
      }
    }
  } else {
    // Unknown provider — stream / limit-hit cache only.
    const cached = lastRateLimitsByProvider.get(provider);
    if (cached && Array.isArray(cached.buckets) && cached.buckets.length) {
      for (const b of cached.buckets) {
        if (!b || !b.label) continue;
        report.buckets.push({
          label: b.label,
          utilization: Math.round(Number(b.utilization) || 0),
          resetsAt: b.resetsAt || null,
        });
      }
      if (cached.hit) {
        const maxUtil = Math.max(
          0,
          ...(Array.isArray(cached.buckets)
            ? cached.buckets.map((b) => Number(b && b.utilization) || 0)
            : [0])
        );
        const ageMs = Date.now() - (cached.at || 0);
        if (maxUtil >= 95 || ageMs < 3 * 60 * 1000) {
          report.limitHit = true;
          report.limitMessage = cached.message || null;
        } else {
          lastRateLimitsByProvider.set(provider, {
            at: cached.at,
            buckets: cached.buckets,
            hit: false,
          });
        }
      }
    }
  }
  const usage = (lastRuntimeBySession.get(sessionKey(provider, chatId)) || {}).usage;
  if (usage && typeof usage === "object") {
    report.chat = {
      inputTokens: usage.inputTokens ?? null,
      cachedInputTokens: usage.cachedInputTokens ?? null,
      outputTokens: usage.outputTokens ?? null,
      totalCostUsd: usage.totalCostUsd ?? null,
    };
  }
  return report;
}

async function handleUsageRequest(channel, payload) {
  const requestId = payload.requestId || payload.request_id || crypto.randomUUID();
  const chatId = payload.chatId || payload.chat_id || null;
  const provider = payload.provider || payload.agentBridgeProvider || "claude";
  const echo = { requestId, chatId, provider };
  try {
    const report = await buildUsageReport(provider, chatId, { chatId, provider });
    channel.push("usage_result", { ok: true, ...echo, report });
  } catch (err) {
    channel.push("usage_result", { ok: false, ...echo, message: (err && err.message) || "usage_failed" });
  }
}

function controlTask(channel, payload) {
  const provider = payload.provider || payload.agentWorkerProvider || payload.agentBridgeProvider;
  const chatId = payload.chatId || payload.chat_id;
  const taskId = payload.taskId || payload.agentTaskId || payload.messageId;
  const teamRunId = payload.teamRunId || payload.team_run_id || null;
  const action = String(payload.action || payload.type || "").trim().toLowerCase();
  if (action === "revert") {
    revertFinishedTask(channel, payload);
    return;
  }
  if (action !== "cancel" && action !== "stop") {
    channel.push("control_result", { ok: false, reason: "unsupported_action", action, provider, chatId, taskId });
    return;
  }

  // Whole-team cancel: kill every running task for this teamRunId (lead + workers).
  if (teamRunId) {
    let killed = 0;
    for (const [key, entry] of runningTasks.entries()) {
      if (!entry) continue;
      const entryRun = entry.teamRunId || entry.team_run_id;
      const entryChat = entry.chatId || entry.chat_id;
      if (entryRun !== teamRunId) continue;
      if (chatId && entryChat && entryChat !== chatId) continue;
      try {
        entry.child.kill("SIGTERM");
        setTimeout(() => {
          try {
            if (!entry.child.killed) entry.child.kill("SIGKILL");
          } catch (_) {}
        }, 2500).unref?.();
        killed += 1;
      } catch (_) {}
    }
    channel.push("control_result", {
      ok: killed > 0,
      action,
      teamRunId,
      chatId,
      killed,
      reason: killed > 0 ? undefined : "task_not_running",
    });
    return;
  }

  const candidates = taskLookupCandidates(provider, chatId, taskId, runningTasks);
  const key = candidates.find((candidate) => runningTasks.has(candidate));
  const entry = key && runningTasks.get(key);
  if (!entry) {
    channel.push("control_result", { ok: false, reason: "task_not_running", action, provider, chatId, taskId });
    return;
  }

  try {
    // If this task is a team lead, also cancel siblings sharing teamRunId.
    const entryTeamRun = entry.teamRunId || entry.team_run_id;
    if (entryTeamRun) {
      for (const [, sibling] of runningTasks.entries()) {
        if (!sibling) continue;
        if ((sibling.teamRunId || sibling.team_run_id) !== entryTeamRun) continue;
        try {
          sibling.child.kill("SIGTERM");
          setTimeout(() => {
            try {
              if (!sibling.child.killed) sibling.child.kill("SIGKILL");
            } catch (_) {}
          }, 2500).unref?.();
        } catch (_) {}
      }
    } else {
      entry.child.kill("SIGTERM");
      setTimeout(() => {
        if (!entry.child.killed) entry.child.kill("SIGKILL");
      }, 2500).unref?.();
    }
    channel.push("control_result", {
      ok: true,
      action,
      provider: entry.provider,
      chatId: entry.chatId,
      taskId: entry.taskId,
      teamRunId: entryTeamRun || null,
    });
  } catch (err) {
    channel.push("control_result", {
      ok: false,
      reason: err.message || "cancel_failed",
      action,
      provider: entry.provider,
      chatId: entry.chatId,
      taskId: entry.taskId,
    });
  }
}

// ── Ask / approval round-trip (the phone is the approver) ───────────────
//
// Two distinct flows share one wire event pair (`ask_request` ⇄ `ask_response`):
//
//   • PLAN approval — when a plan-mode run finishes, the model has PROPOSED but
//     not edited. The bridge fire-and-forgets an `ask_request{kind:"plan"}` with
//     the sealed plan. The phone renders an approval sheet; on approve it sends a
//     NORMAL run_task that resumes the session with edits enabled ("implement the
//     plan"), so message creation rides the proven send path — the bridge never
//     fabricates a turn. No awaited response needed for this flow.
//
//   • ASK-USER — a mid-run question the agent raises through the bridge's MCP
//     `ask_user` tool (opt-in, VIBE_ASK_MCP=1). That call BLOCKS until the phone
//     answers, so it uses `requestAsk` below, which returns a Promise resolved by
//     the matching `ask_response`. An unanswered ask auto-rejects after a timeout
//     so a run can never hang forever.
//
// The request/answer bodies are E2E-sealed with the pairing runtime key (arte1),
// exactly like the diff card — the server relays an opaque blob it cannot read.
const pendingAsks = new Map(); // requestId -> { resolve, timer, chatId }
// chatId -> the latest genuinely-pending ask for that chat (so it can be RE-EMITTED
// when the phone opens/reopens the chat from history — the server's ETS replay only
// covers a 10-min TTL and only fires on a fresh chan join, so a phone that opens a
// long-lived waiting chat, or after that TTL, otherwise never sees the outstanding
// ask/command). Sourced from the bridge's real blocked-promise state, so re-emitting
// the SAME requestId still resolves the live `requestAsk` promise when answered.
const pendingAsksByChat = new Map(); // chatId -> { requestId, provider, taskId, replyToId, kind, body }
let askSeq = 0;
// Mobile is the control surface for bridge runs. A request must remain pending until
// the user answers or the originating process explicitly cancels it; timing it out
// breaks the run while the phone is backgrounded or briefly offline. Set a positive
// VIBE_ASK_TIMEOUT_MS only when an installation deliberately wants legacy expiry.
const ASK_TIMEOUT_MS = Number(process.env.VIBE_ASK_TIMEOUT_MS || 0);

function newAskId(chatId) {
  askSeq += 1;
  return `ask-${chatId}-${Date.now()}-${askSeq}`;
}

function pushAskRequest(channel, { provider, chatId, taskId, replyToId, requestId, kind, body, sessionId, resumedFromSessionId, expiresAtMs }) {
  // sessionId scopes the ask to the CONVERSATION that raised it: one shared DM chatId
  // hosts every session, so chatId+provider alone can't tell the phone WHICH page owns
  // the approval. expiresAtMs lets the phone auto-dismiss a sheet whose ask has timed
  // out bridge-side (the timeout auto-rejects; a stale sheet would answer a dead ask).
  const base = {
    provider,
    chatId,
    taskId,
    replyToId,
    requestId,
    kind,
    ...(ACTIVE_COMPUTER_ID ? { computerId: ACTIVE_COMPUTER_ID } : {}),
  };
  if (sessionId) base.sessionId = sessionId;
  if (resumedFromSessionId) base.resumedFromSessionId = resumedFromSessionId;
  if (expiresAtMs) base.expiresAtMs = expiresAtMs;
  const askEnc = encryptRuntimeBlob({ kind, request: body });
  // Seal when a key exists; otherwise send plaintext (the phone can't decrypt
  // without the key anyway, and a keyless pairing has no confidentiality to lose).
  const wire = askEnc ? { ...base, askEnc } : { ...base, request: body };
  console.log(
    `[vibe-bridge][ask] push topic=${channel && channel.topic} state=${channel && channel.state} ` +
      `requestId=${requestId} kind=${kind} chat=${chatId} sealed=${!!askEnc} ` +
      `bodyKeys=${body ? Object.keys(body).join(",") : "none"}`
  );
  try {
    const push = channel.push("ask_request", wire);
    if (push && typeof push.receive === "function") {
      push
        .receive("ok", () => console.log(`[vibe-bridge][ask] server ACK requestId=${requestId}`))
        .receive("error", (e) =>
          console.log(`[vibe-bridge][ask] server ERROR requestId=${requestId} ${JSON.stringify(e)}`)
        )
        .receive("timeout", () =>
          console.log(`[vibe-bridge][ask] server TIMEOUT requestId=${requestId}`)
        );
    }
  } catch (e) {
    console.log(`[vibe-bridge][ask] push THREW requestId=${requestId} ${e && e.message}`);
  }
}

// Awaited ask (MCP ask_user). Resolves { decision, answer } from `ask_response`.
// `register`, if given, is called synchronously with { requestId, cancel } so the
// caller can dismiss the still-pending phone sheet if its own side resolves first
// (e.g. the desktop PreToolUse hook answered at the desk, or the hook timed out and
// disconnected). Cancelling both drops the blocked promise AND tells the phone to
// close the stale sheet.
function requestAsk(channel, { provider, chatId, taskId, replyToId, kind, body }, register) {
  const requestId = newAskId(chatId);
  // Resolve WHICH conversation (CLI session) raised this ask — rides the wire so the
  // phone can scope the sheet to the owning conversation page (one shared DM chatId
  // hosts every session, so chatId alone can't name the conversation). Prefer the EXACT
  // task by its taskId: a shared chatId can host two concurrent runs, and
  // runningTaskForChat picks the FIRST match by chatId — which may be the wrong run.
  const exactKey =
    provider && chatId && taskId ? taskKey(provider, chatId, taskId) : null;
  const running =
    (exactKey && runningTasks.get(exactKey)) ||
    (chatId ? runningTaskForChat(chatId) : null);
  // Only borrow the chat's last-known session when there is NO running task. A fresh run
  // whose session id isn't captured yet must NOT inherit the previous conversation's id —
  // that mis-scopes its approval onto the old thread's page (the "approval landed in the
  // wrong chat" bug). Sending null there is correct: the phone fails open to the surface
  // that actually started the run.
  const sessionId =
    (running && running.sessionId) ||
    (running ? null : chatId ? sessionByChat.get(chatId) : null) ||
    null;
  // A resumed run mints a NEW session id, but the phone's page still identifies the
  // conversation by the id it resumed FROM — send both so the page can claim its ask.
  const resumedFromSessionId = running ? resumeIdFor(running.task || running) : null;
  const expiresAtMs = ASK_TIMEOUT_MS > 0 ? Date.now() + ASK_TIMEOUT_MS : null;
  const promise = new Promise((resolve) => {
    const timer = ASK_TIMEOUT_MS > 0
      ? setTimeout(() => {
          if (pendingAsks.delete(requestId)) {
            clearPendingAskForChat(chatId, requestId);
            console.log(`[vibe-bridge] ask ${requestId} timed out → auto-reject`);
            pushAskCancel(activeChannel || channel, chatId, requestId, "timeout");
            resolve({ decision: "reject", answer: null, timedOut: true });
          }
        }, ASK_TIMEOUT_MS)
      : null;
    timer?.unref?.();
    pendingAsks.set(requestId, { resolve, timer, chatId });
    // Remember it per-chat so opening this chat from history re-surfaces the ask.
    if (chatId) {
      pendingAsksByChat.set(chatId, { requestId, provider, taskId, replyToId, kind, body, sessionId, resumedFromSessionId, expiresAtMs });
    }
    pushAskRequest(channel, { provider, chatId, taskId, replyToId, requestId, kind, body, sessionId, resumedFromSessionId, expiresAtMs });
    console.log(`[vibe-bridge] ask_request ${requestId} kind=${kind} chat=${chatId} session=${sessionId || "-"}`);
  });
  if (typeof register === "function") {
    register({ requestId, cancel: (reason) => cancelAsk(channel, chatId, requestId, reason) });
  }
  return promise;
}

// Tell the phone to close a still-outstanding ask/command sheet — the request was
// resolved somewhere else (desk keypress, hook timeout/disconnect) so the sheet is
// now stale. No-op once the ask has already been answered or timed out.
function pushAskCancel(channel, chatId, requestId, reason) {
  try {
    channel.push("ask_cancel", {
      chatId,
      requestId,
      reason: reason || "resolved_elsewhere",
      ...(ACTIVE_COMPUTER_ID ? { computerId: ACTIVE_COMPUTER_ID } : {}),
    });
    console.log(`[vibe-bridge][ask] push ask_cancel requestId=${requestId} chat=${chatId} reason=${reason || "resolved_elsewhere"}`);
  } catch (e) {
    console.log(`[vibe-bridge][ask] ask_cancel push THREW requestId=${requestId} ${e && e.message}`);
  }
}

function cancelAsk(channel, chatId, requestId, reason) {
  const entry = pendingAsks.get(requestId);
  if (!entry) return false; // already answered / timed out — nothing to dismiss
  pendingAsks.delete(requestId);
  clearPendingAskForChat(chatId, requestId);
  clearTimeout(entry.timer);
  if (channel) pushAskCancel(channel, chatId, requestId, reason);
  entry.resolve({ decision: "cancel", answer: null, cancelled: true });
  return true;
}

// Drop the per-chat buffered ask once it's answered/timed out — but only if it still
// points at THIS requestId (a newer outstanding ask on the same chat must survive).
function clearPendingAskForChat(chatId, requestId) {
  if (!chatId) return;
  const rec = pendingAsksByChat.get(chatId);
  if (rec && rec.requestId === requestId) pendingAsksByChat.delete(chatId);
}

// Re-push any genuinely-pending ask/command for a chat the phone just opened from
// history. Reuses the SAME requestId + body, so the live blocked `requestAsk` promise
// resolves normally when the phone answers. No-op when nothing is outstanding.
// Debounced: history list+detail + watch ticks used to re-push the same sheet on
// every request (layout flash + “ask spam” while the user browses Grok History).
const lastAskReemitAtByChat = new Map();
const ASK_REEMIT_MIN_MS = Number(process.env.VIBE_ASK_REEMIT_MIN_MS || 8000);
function reemitPendingAskForChat(channel, chatId) {
  if (!chatId) return;
  const rec = pendingAsksByChat.get(chatId);
  if (!rec) return;
  // Only re-emit while the promise is actually still blocked (guards against a race
  // where it resolved between lookups).
  if (!pendingAsks.has(rec.requestId)) {
    pendingAsksByChat.delete(chatId);
    return;
  }
  const now = Date.now();
  const last = lastAskReemitAtByChat.get(chatId) || 0;
  if (now - last < ASK_REEMIT_MIN_MS) {
    return;
  }
  lastAskReemitAtByChat.set(chatId, now);
  console.log(`[vibe-bridge][ask] re-emit pending ask on history open requestId=${rec.requestId} kind=${rec.kind} chat=${chatId}`);
  pushAskRequest(channel, { ...rec, chatId, requestId: rec.requestId });
}

// phone → server → bridge: an answer to an awaited ask.
function resolveAsk(payload) {
  const requestId = payload && (payload.requestId || payload.request_id);
  if (!requestId) return;
  const entry = pendingAsks.get(requestId);
  if (!entry) return;
  pendingAsks.delete(requestId);
  clearPendingAskForChat(entry.chatId, requestId);
  clearTimeout(entry.timer);
  const decision = String(payload.decision || payload.action || "answer").trim().toLowerCase();
  let answer = null;
  const enc = payload.answerEnc || payload.answer_enc;
  if (enc) {
    const dec = decryptRuntimeBlob(enc);
    if (dec) answer = dec.answer !== undefined ? dec.answer : dec;
  } else if (payload.answer !== undefined) {
    answer = payload.answer;
  }
  console.log(`[vibe-bridge] ask_response ${requestId} decision=${decision}`);
  entry.resolve({ decision, answer });
}

// Extract the proposed plan from a finished claude plan-mode run. Prefer the
// ExitPlanMode tool input (older clients carry the plan there); otherwise fall
// back to the final assistant text, which in plan mode IS the printed plan.
// (Modern claude writes the plan to a plan file too, but in `-p` plan mode the
// plan is always echoed in the output, so we don't need to read the file.)
function extractPlan(output) {
  if (!output) return null;
  let planFromExit = null;
  let lastText = null;
  for (const raw of String(output).split("\n")) {
    const line = raw.trim();
    if (!line || line[0] !== "{") continue;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch (_) {
      continue;
    }
    const msg = ev && ev.message;
    const blocks = msg && Array.isArray(msg.content) ? msg.content : null;
    if (!blocks) continue;
    for (const b of blocks) {
      if (!b) continue;
      if (b.type === "tool_use" && b.name === "ExitPlanMode" && b.input) {
        const p = b.input.plan;
        if (typeof p === "string" && p.trim()) planFromExit = p.trim();
      }
      if (b.type === "text" && typeof b.text === "string" && b.text.trim()) {
        lastText = b.text.trim();
      }
    }
  }
  return planFromExit || lastText || null;
}

// Fire-and-forget plan-approval prompt to the phone after a plan-mode run.
function maybeEmitPlanApproval(channel, { provider, task, chatId, taskId, replyToId, repo, output, exitStatus }) {
  if (provider !== "claude") return; // codex exec has no plan-approval round-trip
  if (workModeFor(task) !== "plan") return;
  if (exitStatus !== 0) return;
  const plan = extractPlan(output);
  if (!plan) return;
  const requestId = newAskId(chatId);
  const planSessionId = sessionByChat.get(chatId) || resumeIdFor(task) || null;
  pushAskRequest(channel, {
    provider,
    chatId,
    taskId,
    replyToId,
    requestId,
    kind: "plan",
    // sessionId also rides top-level so the phone can scope the plan sheet to the
    // conversation page that owns it (same shared-chatId problem as ask/command).
    sessionId: planSessionId,
    body: { plan, sessionId: planSessionId, repoName: repo && repo.name },
  });
  console.log(`[vibe-bridge] ask_request(plan) ${requestId} chat=${chatId} planLen=${plan.length}`);
}

// ── MCP ask_user producer (mid-run questions) ───────────────────────
//
// `claude -p` is non-interactive, so the built-in AskUserQuestion tool can't
// round-trip to a human. Instead we expose our OWN MCP tool, `ask_user`, via
// `--mcp-config`. When the model calls it the run BLOCKS (MCP tool calls are
// synchronous from claude's view) while we relay the question to the phone and
// wait for the answer:
//
//   claude → mcp(ask_user) → unix socket → bridge.requestAsk → phone sheet
//          ← tool_result   ← unix socket ← bridge ← ask_response ← phone
//
// The MCP server is a tiny stdio child of `claude`; it inherits VIBE_ASK_SOCK /
// VIBE_ASK_CHAT / VIBE_ASK_TASK from the claude spawn env so it knows which
// chat/task the question belongs to. Disable with VIBE_ASK_MCP=0.
const ASK_MCP_ENABLED = process.env.VIBE_ASK_MCP !== "0";
const ASK_TOOL_NAME = "mcp__vibeask__ask_user";
const FABLE_MCP_ENABLED = process.env.VIBE_FABLE_MCP !== "0";
const FABLE_TOOL_NAME = "mcp__vibeask__ask_fable";
// Claude `--permission-prompt-tool`: in live "ask" mode every tool Claude wants to
// use that needs approval is routed here, round-tripped to the phone, and the
// user's Approve/Skip/Deny maps to the permission tool's allow/deny contract.
const APPROVE_TOOL_NAME = "mcp__vibeask__approve_command";
let activeChannel = null;
let askMcpConfigPath = null;
let askIpcSockPath = null;
let askIpcServer = null;

// One question payload the model can raise. `questions[]` mirrors the iOS sheet
// (and Claude's own AskUserQuestion): each carries a short header chip, a flag for
// multi-select, and labelled options.
const ASK_MCP_SCRIPT = `#!/usr/bin/env node
"use strict";
const net = require("net");
const os = require("os");
const path = require("path");
const readline = require("readline");
const { spawn } = require("child_process");
// Bridge-spawned runs get VIBE_ASK_SOCK (+ VIBE_ASK_CHAT) in their env. A STANDALONE
// (interactive desktop) claude session has neither, so fall back to the bridge's
// stable socket and identify by cwd — the bridge routes the ask to the matching
// mobile chat. This is what lets an interactive session's question reach the phone.
const SOCK = process.env.VIBE_ASK_SOCK || path.join(os.homedir(), ".vibe", "ask.sock");
const CHAT = process.env.VIBE_ASK_CHAT || "";
const TASK = process.env.VIBE_ASK_TASK || "";
const CWD = process.cwd();
const SOURCE = CHAT ? "bridge" : "interactive";
const ADVISOR_ENABLED = process.env.VIBE_FABLE_MCP !== "0";
const ADVISOR_MODEL = normalizeAdvisorModel(process.env.VIBE_FABLE_MODEL || process.env.VIBE_CLAUDE_ADVISOR || process.env.VIBE_CLAUDE_ADVISOR_MODEL || "fable");
const ADVISOR_TIMEOUT_MS = Math.max(10000, Number(process.env.VIBE_FABLE_MCP_TIMEOUT_MS || 240000) || 240000);
// Keep advisor prompts lean by default — large dumps burn Fable tokens without
// better advice. Override with VIBE_FABLE_MCP_CONTEXT_CHARS when you truly need more.
const ADVISOR_CONTEXT_CHARS = Math.max(4000, Number(process.env.VIBE_FABLE_MCP_CONTEXT_CHARS || 24000) || 24000);
let proto = "2024-11-05";
function send(msg) { process.stdout.write(JSON.stringify(msg) + "\\n"); }
function result(id, res) { send({ jsonrpc: "2.0", id, result: res }); }
function normalizeAdvisorModel(value) {
  const raw = value == null ? "" : String(value).trim();
  if (!raw) return "fable";
  const normalized = raw.toLowerCase().replace(/_/g, "-");
  if (normalized.includes("fable")) return "fable";
  if (normalized.includes("opus")) return "opus";
  if (normalized.includes("sonnet")) return "sonnet";
  return raw;
}
function compactText(value, limit) {
  let text = "";
  if (value == null) text = "";
  else if (typeof value === "string") text = value;
  else {
    try { text = JSON.stringify(value, null, 2); } catch (_) { text = String(value); }
  }
  if (!limit || text.length <= limit) return text;
  const head = Math.floor(limit * 0.65);
  const tail = Math.max(0, limit - head - 80);
  return text.slice(0, head) + "\\n\\n[...truncated for advisor context...]\\n\\n" + text.slice(text.length - tail);
}
const TOOL = {
  name: "ask_user",
  description:
    "Ask the user one or more clarifying questions and wait for their answer. Use this " +
    "whenever you need a decision, preference, or missing detail before continuing. The user " +
    "sees a sheet on their phone (one question per page) and their selections are returned. " +
    "Each question has a short 'header' chip (<=12 chars), a 'multiSelect' flag, and labelled 'options'.",
  inputSchema: {
    type: "object",
    properties: {
      questions: {
        type: "array",
        description: "One or more questions to ask.",
        items: {
          type: "object",
          properties: {
            question: { type: "string", description: "The full question text." },
            header: { type: "string", description: "Short label (<=12 chars) for the question chip." },
            multiSelect: { type: "boolean", description: "Allow selecting multiple options." },
            options: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  label: { type: "string" },
                  description: { type: "string" }
                },
                required: ["label"]
              }
            }
          },
          required: ["question", "options"]
        }
      }
    },
    required: ["questions"]
  }
};
const ADVISOR_TOOL = {
  // Wire id stays ask_fable (agents / MCP already call this). UI labels use "Ask Advisor".
  name: "ask_fable",
  description:
    "Ask Advisor for explicit second-opinion advice during the current run. Pass the concrete " +
    "question plus relevant context, snippets, diffs, constraints, and current assumptions. " +
    "Use this when the built-in advisor is unavailable or when you need a deliberate critique. " +
    "Advisor returns advice only; the calling model remains responsible for implementation and verification.",
  inputSchema: {
    type: "object",
    properties: {
      question: { type: "string", description: "The exact advice question for the advisor." },
      context: { type: "string", description: "Relevant run context, findings, errors, and assumptions." },
      diff: { type: "string", description: "Optional patch or git diff to review." },
      constraints: {
        type: "array",
        description: "Important constraints the advisor must respect.",
        items: { type: "string" }
      },
      files: {
        type: "array",
        description: "Relevant file snippets to include.",
        items: {
          type: "object",
          properties: {
            path: { type: "string" },
            content: { type: "string" },
            note: { type: "string" }
          }
        }
      }
    },
    required: ["question"]
  }
};
const APPROVE_TOOL = {
  name: "approve_command",
  description:
    "Permission-prompt handler. The runtime calls this before a tool that needs approval; " +
    "it relays the pending action to the user's phone and returns their decision.",
  inputSchema: {
    type: "object",
    properties: {
      tool_name: { type: "string", description: "The tool awaiting approval." },
      input: { type: "object", description: "The tool's proposed input." }
    },
    required: ["tool_name", "input"]
  }
};
function approveBridge(args) {
  return new Promise((resolve) => {
    const input = (args && args.input) || {};
    const allow = (updatedInput) => resolve({ behavior: "allow", updatedInput: updatedInput || input });
    const deny = (message) => resolve({ behavior: "deny", message: message || "The user did not approve this action." });
    if (!SOCK) { deny("Command approval is unavailable (no bridge socket)."); return; }
    let buf = "";
    let done = false;
    const finish = (fn, v) => { if (!done) { done = true; fn(v); } };
    const conn = net.createConnection(SOCK, () => {
      conn.write(JSON.stringify({ type: "command", chatId: CHAT, taskId: TASK, cwd: CWD, source: SOURCE, tool_name: args && args.tool_name, input }) + "\\n");
    });
    conn.setEncoding("utf8");
    conn.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\\n");
      if (nl < 0) return;
      let parsed = null;
      try { parsed = JSON.parse(buf.slice(0, nl)); } catch (_) {}
      conn.end();
      const ans = (parsed && parsed.answer) || {};
      const decision = String(ans.decision || ans.action || "deny").toLowerCase();
      if (decision === "approve" || decision === "allow") finish(allow, ans.updatedInput);
      else finish(deny, ans.message);
    });
    conn.on("error", () => finish(deny, "Could not reach the user for approval."));
    conn.on("close", () => finish(deny, "The user did not respond to the approval request."));
  });
}
function askBridge(questions) {
  return new Promise((resolve) => {
    if (!SOCK) { resolve({ error: "ask_user is unavailable (no bridge socket)." }); return; }
    let buf = "";
    let done = false;
    const finish = (val) => { if (!done) { done = true; resolve(val); } };
    const conn = net.createConnection(SOCK, () => {
      conn.write(JSON.stringify({ chatId: CHAT, taskId: TASK, cwd: CWD, source: SOURCE, questions }) + "\\n");
    });
    conn.setEncoding("utf8");
    conn.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\\n");
      if (nl < 0) return;
      let parsed = null;
      try { parsed = JSON.parse(buf.slice(0, nl)); } catch (_) {}
      conn.end();
      finish(parsed && parsed.answer != null ? parsed.answer : { error: "No answer." });
    });
    conn.on("error", () => finish({ error: "Could not reach the user." }));
    conn.on("close", () => finish({ error: "The user did not answer." }));
  });
}
function buildAdvisorPrompt(args) {
  args = args || {};
  const question = compactText(args.question || "", 2000).trim();
  if (!question) return null;
  // Budget the prompt: question + short system rules + remaining for context/files/diff.
  const budget = ADVISOR_CONTEXT_CHARS;
  const maxFiles = 6;
  const maxConstraints = 8;
  const contextBudget = Math.max(1500, Math.floor(budget * 0.35));
  const filesBudget = Math.max(2000, Math.floor(budget * 0.40));
  const diffBudget = Math.max(1500, Math.floor(budget * 0.20));
  const parts = [
    "You are Fable, a second-opinion adviser to an executor agent mid-run.",
    "No tools. No task rewrite. Keep the reply SHORT (aim <= 400 words).",
    "Use these headings only: Assessment / Risks / Next steps / Verification.",
    "Prefer concrete steps over theory. Skip fluff.",
    "Question:\\n" + question
  ];
  if (args.context) parts.push("Current context:\\n" + compactText(args.context, contextBudget));
  if (Array.isArray(args.constraints) && args.constraints.length) {
    parts.push(
      "Constraints:\\n" +
        args.constraints
          .slice(0, maxConstraints)
          .map((c) => "- " + compactText(c, 400))
          .join("\\n")
    );
  }
  if (Array.isArray(args.files) && args.files.length) {
    const fileCount = Math.min(args.files.length, maxFiles);
    const perFile = Math.max(800, Math.floor(filesBudget / fileCount));
    const snippets = args.files.slice(0, maxFiles).map((file, index) => {
      const label = compactText(file && (file.path || file.name) || ("snippet-" + (index + 1)), 200);
      const note = file && file.note ? "\\nNote: " + compactText(file.note, 300) : "";
      const body = compactText(file && (file.content || file.text || ""), perFile);
      return "File: " + label + note + "\\n" + body;
    }).join("\\n\\n---\\n\\n");
    parts.push("File snippets:\\n" + snippets);
  }
  if (args.diff) parts.push("Diff or proposed patch:\\n" + compactText(args.diff, diffBudget));
  return compactText(parts.join("\\n\\n"), budget);
}
// Advisor fallback chain: try Fable first, then fall back when Fable is
// rate-limited / usage-limited / unavailable so ask_fable still returns real
// advice instead of a hard "unavailable". Order: Fable -> Opus -> GPT (codex).
// Sonnet is deliberately NOT in the chain. Override with
// VIBE_FABLE_FALLBACK_MODELS (comma-separated; "gpt"/"codex" routes to codex).
function advisorChain() {
  const primary = ADVISOR_MODEL || "fable";
  const envFallback = (process.env.VIBE_FABLE_FALLBACK_MODELS || "").trim();
  let names;
  if (envFallback) {
    names = [primary].concat(envFallback.split(","));
  } else if (primary === "opus") {
    names = ["opus", "gpt"];
  } else {
    names = ["fable", "opus", "gpt"];
  }
  const seen = {};
  const out = [];
  for (const n of names) {
    const trimmed = String(n || "").trim();
    if (!trimmed) continue;
    const norm = /gpt|codex/i.test(trimmed) ? "gpt" : normalizeAdvisorModel(trimmed);
    if (norm && norm !== "sonnet" && !seen[norm]) {
      seen[norm] = 1;
      out.push(norm);
    }
  }
  return out.length ? out : ["opus"];
}
function runAdvisorClaude(prompt, model) {
  return new Promise((resolve) => {
    const cmd = process.env.VIBE_CLAUDE_COMMAND || "claude";
    // Both Fable and Opus advise WITH thinking: --effort raises reasoning depth.
    const effort = process.env.VIBE_ADVISOR_CLAUDE_EFFORT || "high";
    const args = [
      "-p",
      prompt,
      "--model",
      model,
      "--effort",
      effort,
      "--output-format",
      "json",
      "--permission-mode",
      "plan",
      "--tools",
      "",
      "--strict-mcp-config",
      "--mcp-config",
      "{\\"mcpServers\\":{}}",
      "--setting-sources",
      "user"
    ];
    let stdout = "";
    let stderr = "";
    let done = false;
    const finish = (res) => {
      if (done) return;
      done = true;
      resolve(res);
    };
    const child = spawn(cmd, args, {
      cwd: CWD,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        VIBE_ASK_MCP: "0",
        VIBE_FABLE_MCP: "0",
        VIBE_CLAUDE_ADVISOR: "",
        VIBE_CLAUDE_ADVISOR_MODEL: ""
      }
    });
    // A slow model is not helped by trying another one; only fast failures
    // (rate-limit / auth / non-zero exit) cascade to the next model.
    const timer = setTimeout(() => {
      try { child.kill("SIGTERM"); } catch (_) {}
      finish({ ok: false, retriable: false, text: "Advisor (" + model + ") unavailable: timed out." });
    }, ADVISOR_TIMEOUT_MS);
    if (timer.unref) timer.unref();
    child.stdout.on("data", (d) => { stdout += d.toString("utf8"); });
    child.stderr.on("data", (d) => { stderr += d.toString("utf8"); });
    child.on("error", (err) => {
      clearTimeout(timer);
      finish({ ok: false, retriable: true, text: "Advisor (" + model + ") unavailable: " + (err && err.message ? err.message : "spawn failed") });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (done) return;
      const raw = stdout.trim();
      let parsed = null;
      try { parsed = raw ? JSON.parse(raw.split("\\n").pop()) : null; } catch (_) {}
      const text = parsed && typeof parsed.result === "string" ? parsed.result.trim() : raw;
      if (code === 0 && text) finish({ ok: true, retriable: false, text: text });
      else finish({ ok: false, retriable: true, text: "Advisor (" + model + ") unavailable: " + compactText((stderr || raw || ("claude exited " + code)).trim(), 2000) });
    });
  });
}
// GPT advisor via the codex CLI (used when the claude-based models are exhausted).
function runAdvisorCodex(prompt) {
  return new Promise((resolve) => {
    const cmd = process.env.VIBE_CODEX_COMMAND || "codex";
    // GPT advisor = GPT-5.6-Sol thinking hard (xhigh; the model also supports
    // max/ultra). Override with VIBE_ADVISOR_CODEX_MODEL / VIBE_ADVISOR_CODEX_EFFORT.
    const gptModel = process.env.VIBE_ADVISOR_CODEX_MODEL || "gpt-5.6-sol";
    const effort = process.env.VIBE_ADVISOR_CODEX_EFFORT || "xhigh";
    const args = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "-m", gptModel, "-c", 'model_reasoning_effort="' + effort + '"', prompt];
    let stdout = "";
    let stderr = "";
    let done = false;
    const finish = (res) => {
      if (done) return;
      done = true;
      resolve(res);
    };
    const child = spawn(cmd, args, {
      cwd: CWD,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, VIBE_ASK_MCP: "0", VIBE_FABLE_MCP: "0" }
    });
    const timer = setTimeout(() => {
      try { child.kill("SIGTERM"); } catch (_) {}
      finish({ ok: false, retriable: false, text: "Advisor (gpt) unavailable: timed out." });
    }, ADVISOR_TIMEOUT_MS);
    if (timer.unref) timer.unref();
    child.stdout.on("data", (d) => { stdout += d.toString("utf8"); });
    child.stderr.on("data", (d) => { stderr += d.toString("utf8"); });
    child.on("error", (err) => {
      clearTimeout(timer);
      finish({ ok: false, retriable: true, text: "Advisor (gpt) unavailable: " + (err && err.message ? err.message : "spawn failed") });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (done) return;
      // codex emits JSONL; the final answer is the last agent_message. Shapes seen:
      //  {type:"item.completed", item:{type:"agent_message", text:"..."}}   (exec --json)
      //  {payload:{type:"task_complete", last_agent_message:"..."}}          (session-file)
      //  {type:"agent_message", text|message:"..."}
      let answer = "";
      const lines = stdout.split("\\n");
      for (const ln of lines) {
        const t = ln.trim();
        if (!t) continue;
        let obj = null;
        try { obj = JSON.parse(t); } catch (_) { continue; }
        const item = obj && obj.item ? obj.item : null;
        if (item && (item.type === "agent_message" || item.type === "assistant_message") && typeof item.text === "string" && item.text.trim()) {
          answer = item.text.trim();
          continue;
        }
        const p = obj && obj.payload ? obj.payload : obj;
        if (p && typeof p.last_agent_message === "string" && p.last_agent_message.trim()) { answer = p.last_agent_message.trim(); continue; }
        if (p && p.type === "agent_message" && typeof p.text === "string" && p.text.trim()) { answer = p.text.trim(); continue; }
        if (p && p.type === "agent_message" && typeof p.message === "string" && p.message.trim()) { answer = p.message.trim(); continue; }
      }
      if (code === 0 && answer) finish({ ok: true, retriable: false, text: answer });
      else finish({ ok: false, retriable: true, text: "Advisor (gpt) unavailable: " + compactText((stderr || ("codex exited " + code)).trim(), 2000) });
    });
  });
}
async function runAdvisor(prompt) {
  const chain = advisorChain();
  let last = "Fable advisor unavailable.";
  for (let i = 0; i < chain.length; i++) {
    const name = chain[i];
    const res = name === "gpt" ? await runAdvisorCodex(prompt) : await runAdvisorClaude(prompt, name);
    if (res && res.ok) {
      // Be transparent: if a fallback answered, say so rather than passing it
      // off as Fable.
      if (i === 0) return res.text;
      return "[advisor: " + name + " — Fable was unavailable/rate-limited]\\n\\n" + res.text;
    }
    last = res && res.text ? res.text : last;
    if (res && res.retriable === false) break;
  }
  return last;
}
async function askFable(args) {
  if (!ADVISOR_ENABLED) return "Fable advisor MCP is disabled by VIBE_FABLE_MCP=0.";
  const prompt = buildAdvisorPrompt(args);
  if (!prompt) return "Fable advisor unavailable: missing question.";
  return await runAdvisor(prompt);
}
const rl = readline.createInterface({ input: process.stdin });
rl.on("line", async (line) => {
  let msg = null;
  try { msg = JSON.parse(line); } catch (_) { return; }
  if (!msg || typeof msg !== "object") return;
  const { id, method, params } = msg;
  if (method === "initialize") {
    if (params && params.protocolVersion) proto = params.protocolVersion;
    result(id, { protocolVersion: proto, capabilities: { tools: {} }, serverInfo: { name: "vibeask", version: "1.0.0" } });
  } else if (method === "tools/list") {
    const tools = ADVISOR_ENABLED ? [TOOL, APPROVE_TOOL, ADVISOR_TOOL] : [TOOL, APPROVE_TOOL];
    result(id, { tools });
  } else if (method === "tools/call") {
    const args = (params && params.arguments) || {};
    const toolName = params && params.name;
    if (toolName === "approve_command") {
      const verdict = await approveBridge(args);
      result(id, { content: [{ type: "text", text: JSON.stringify(verdict) }] });
    } else if (toolName === "ask_fable") {
      const answer = await askFable(args);
      result(id, { content: [{ type: "text", text: answer }] });
    } else {
      const questions = Array.isArray(args.questions) ? args.questions : [];
      const answer = await askBridge(questions);
      result(id, { content: [{ type: "text", text: JSON.stringify(answer) }] });
    }
  } else if (method === "ping") {
    result(id, {});
  } else if (id !== undefined && id !== null) {
    send({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found: " + method } });
  }
});
`;

// PreToolUse hook (interactive desktop sessions): the headless-only
// `--permission-prompt-tool` can't gate an interactive `claude`, but a PreToolUse
// hook CAN — it blocks, forwards the pending command to the bridge's stable socket,
// and returns the phone's decision as a permissionDecision. FAIL-SAFE: anything but
// a clear approve/deny (bridge down, timeout, parse error) returns "ask", which
// falls back to the normal LOCAL prompt so the desktop is never worse off.
const APPROVE_HOOK_SCRIPT = `#!/usr/bin/env node
"use strict";
const net = require("net");
const os = require("os");
const path = require("path");
const SOCK = path.join(os.homedir(), ".vibe", "ask.sock");
function emit(decision, reason, updatedInput) {
  const hso = { hookEventName: "PreToolUse", permissionDecision: decision };
  if (reason) hso.permissionDecisionReason = reason;
  if (updatedInput) hso.updatedInput = updatedInput;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: hso }));
  process.exit(0);
}
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  let ev = null;
  try { ev = JSON.parse(raw); } catch (_) {}
  if (!ev) emit("ask", "Vibe: could not read tool input — approve here.");
  const toolName = ev.tool_name || "";
  const input = ev.tool_input || {};
  const cwd = ev.cwd || process.cwd();
  let done = false;
  const finish = (fn) => { if (!done) { done = true; fn(); } };
  // AskUserQuestion has no answer channel off-device. If the bridge is up, DENY it and
  // redirect the model to mcp__vibeask__ask_user (which reaches the phone). If the
  // bridge is down, DEFER so the native question still works on the local TTY.
  if (toolName === "AskUserQuestion") {
    const probe = net.createConnection(SOCK, () => {
      try { probe.end(); } catch (_) {}
      finish(() => emit("deny", "Use the mcp__vibeask__ask_user tool instead — it delivers your question to the user's phone and returns their answer. Do not use AskUserQuestion here."));
    });
    probe.on("error", () => finish(() => emit("ask", "Vibe bridge unreachable — asking here.")));
    return;
  }
  // Wait for an explicit phone decision. A local timeout silently turns a mobile
  // approval into a desktop prompt while the phone is backgrounded/reconnecting.
  const timer = null;
  let buf = "";
  const conn = net.createConnection(SOCK, () => {
    conn.write(JSON.stringify({ type: "command", cwd: cwd, source: "hook", sessionId: ev.session_id || "", tool_name: toolName, input: input }) + "\\n");
  });
  conn.setEncoding("utf8");
  conn.on("data", (d) => {
    buf += d;
    const nl = buf.indexOf("\\n");
    if (nl < 0) return;
    let parsed = null;
    try { parsed = JSON.parse(buf.slice(0, nl)); } catch (_) {}
    try { conn.end(); } catch (_) {}
    clearTimeout(timer);
    const ans = (parsed && parsed.answer) || {};
    const decision = String(ans.decision || ans.action || "").toLowerCase();
    if (decision === "approve" || decision === "allow") finish(() => emit("allow", ans.message || "Approved from phone.", ans.updatedInput));
    else if (decision === "deny" || decision === "skip") finish(() => emit("deny", ans.message || (decision === "skip" ? "Skipped from your phone." : "Denied from your phone.")));
    else finish(() => emit("ask", "Vibe: no clear decision — approve here."));
  });
  conn.on("error", () => { clearTimeout(timer); finish(() => emit("ask", "Vibe bridge unreachable — approve here.")); });
  conn.on("close", () => { clearTimeout(timer); finish(() => emit("ask", "Vibe: connection closed — approve here.")); });
});
`;
// NOTE: the embedded APPROVE_HOOK_SCRIPT above is only a FALLBACK. The authoritative,
// config-driven hook lives at agent-bridge/assets/vibe-approve-hook.js and is copied to
// ~/.vibe on every start (see ensureAskMcp). Edit the asset, not this string.

// Default approval config, written to ~/.vibe/agent-config.toml ONLY if absent (user
// edits are never overwritten). Defaults to "local" = approve on-device, no phone.
const DEFAULT_AGENT_CONFIG_TOML = `# Vibe agent config — controls how Claude Code (interactive, in this repo) asks
# you to approve tools. Edit this file and it takes effect on the next tool call.
#
# approval_mode:
#   "local"  -> DEFAULT. Approve / answer everything on THIS device only (no phone).
#   "mobile" -> Everything not auto-allowed is sent to your phone and stays pending
#               until answered; if the bridge is down it falls back locally.
#   "auto"   -> Safe / allow-listed commands run WITHOUT asking; only blockers go to
#               the phone. Closest to how Codex feels day to day.
#   "both"   -> Like "auto", but a blocker shows on the desk AND the phone at once
#               (first responder wins) in a real terminal session; a headless / IDE
#               session just prompts locally so the agent never blocks on the phone.
#   "full"   -> Allow everything EXCEPT the always-blocked dangerous commands.
#
# Always-blocked in mobile/auto/full (denied even in full): rm -rf, sudo, git push,
# git reset --hard, dd, mkfs, curl|sh, npm publish, ...
approval_mode = "local"

# team_orchestration:
#   "server"       -> DEFAULT/legacy: the server classifies @team runs and fans out
#                     separate worker tasks (VIBE_TEAM_SPAWN markers).
#   "agent_native" -> the lead agent CLI loads .vibe/instructions/team-lead.md and
#                     spawns worker CLIs itself as background subprocesses; the
#                     bridge suppresses the legacy fan-out. See docs/team-architecture.md.
team_orchestration = "server"

# Extra Bash commands to auto-allow (substring match) on top of the built-in safe list
# (ls/cat/grep/find/git status|diff|log/echo/... and any build — building is free).
auto_allow = [
  "xcrun simctl",
]

# Extra commands to always deny (substring match).
deny = []
`;

// Interactive-session routing: an interactive claude's ask/command arrives on the
// stable socket WITHOUT a chatId (it isn't a bridge run). Route it to the mobile
// chat that most recently ran this provider in this repo (cwd), else the last chat
// seen for the provider. Populated from run_task in runTask().
const lastAgentChatByCwd = new Map(); // cwd -> { chatId, provider, byProvider }
const lastAgentChatByProvider = new Map(); // provider -> chatId
const AGENT_CHATS_FILE = path.join(CONFIG_DIR, "agent-chats.json");
// Persist the repo/provider→chat map so interactive routing works IMMEDIATELY after
// a bridge restart (before any new phone run), since the phone rarely re-runs first.
function loadAgentChats() {
  try {
    const data = JSON.parse(fs.readFileSync(AGENT_CHATS_FILE, "utf8"));
    for (const [p, c] of Object.entries(data.byProvider || {})) lastAgentChatByProvider.set(p, c);
    for (const [k, v] of Object.entries(data.byCwd || {})) lastAgentChatByCwd.set(k, v);
  } catch (_) {}
}
function saveAgentChats() {
  try {
    fs.writeFileSync(
      AGENT_CHATS_FILE,
      JSON.stringify({
        byProvider: Object.fromEntries(lastAgentChatByProvider),
        byCwd: Object.fromEntries(lastAgentChatByCwd),
      })
    );
  } catch (_) {}
}
function rememberAgentChat(provider, chatId, cwd) {
  if (!chatId) return;
  if (provider) lastAgentChatByProvider.set(provider, chatId);
  const key = realDir(cwd || "") || cwd;
  if (key) {
    const existing = lastAgentChatByCwd.get(key) || {};
    const byProvider =
      existing.byProvider && typeof existing.byProvider === "object"
        ? { ...existing.byProvider }
        : {};
    if (existing.provider && existing.chatId && !byProvider[existing.provider]) {
      byProvider[existing.provider] = existing.chatId;
    }
    if (provider) byProvider[provider] = chatId;
    lastAgentChatByCwd.set(key, { chatId, provider, byProvider });
  }
  saveAgentChats();
}
function resolveInteractiveChat(cwd, provider) {
  const key = realDir(cwd || "") || cwd;
  const wantedProvider = provider ? String(provider).toLowerCase() : "";
  const cwdRecord = key && lastAgentChatByCwd.has(key) ? lastAgentChatByCwd.get(key) : null;
  if (cwdRecord && wantedProvider) {
    const byProvider =
      cwdRecord.byProvider && typeof cwdRecord.byProvider === "object"
        ? cwdRecord.byProvider
        : {};
    if (byProvider[wantedProvider]) return byProvider[wantedProvider];
    if (String(cwdRecord.provider || "").toLowerCase() === wantedProvider && cwdRecord.chatId) {
      return cwdRecord.chatId;
    }
  }
  if (wantedProvider && lastAgentChatByProvider.has(wantedProvider)) return lastAgentChatByProvider.get(wantedProvider);
  if (cwdRecord && cwdRecord.chatId) return cwdRecord.chatId;
  // Last resort: any known agent chat (single-agent DM setups share one chatId).
  const first = lastAgentChatByProvider.values().next();
  return first && !first.done ? first.value : null;
}

// Lazily materialize the MCP server script, its --mcp-config file, and the approval
// hook — all in ~/.vibe (STABLE paths, so an interactive claude session registered
// against them keeps working across bridge restarts) — and start the unix-socket IPC
// server on a stable path any claude session can reach. Idempotent.
function ensureAskMcp(channel) {
  activeChannel = channel;
  if (!ASK_MCP_ENABLED || askIpcServer) return;
  try {
    const dir = CONFIG_DIR; // ~/.vibe (already used for bridge.log/bridge.json)
    try { fs.mkdirSync(dir, { recursive: true }); } catch (_) {}
    loadAgentChats(); // restore repo→chat routing from a prior run
    const scriptPath = path.join(dir, "vibe-ask-mcp.js");
    fs.writeFileSync(scriptPath, ASK_MCP_SCRIPT, { mode: 0o700 });
    // Copy the authoritative, config-driven hook from the repo asset; fall back to the
    // embedded template only if the asset can't be read.
    let hookSrc = APPROVE_HOOK_SCRIPT;
    try { hookSrc = fs.readFileSync(path.join(__dirname, "..", "assets", "vibe-approve-hook.js"), "utf8"); } catch (_) {}
    fs.writeFileSync(path.join(dir, "vibe-approve-hook.js"), hookSrc, { mode: 0o700 });
    // Seed a local-mode config on first run; NEVER overwrite the user's edits.
    const agentCfgPath = path.join(dir, "agent-config.toml");
    if (!fs.existsSync(agentCfgPath)) { try { fs.writeFileSync(agentCfgPath, DEFAULT_AGENT_CONFIG_TOML); } catch (_) {} }
    askMcpConfigPath = path.join(dir, "vibe-ask-mcp.json");
    fs.writeFileSync(
      askMcpConfigPath,
      JSON.stringify({ mcpServers: { vibeask: { command: process.execPath, args: [scriptPath] } } })
    );
    // Stable socket (~/.vibe/ask.sock, ~38 bytes — well under macOS's ~104 sun_path
    // cap) so BOTH bridge-spawned and interactive sessions reach the same listener.
    askIpcSockPath = path.join(dir, "ask.sock");
    try { fs.unlinkSync(askIpcSockPath); } catch (_) {}
    askIpcServer = net.createServer(handleAskIpcConnection);
    askIpcServer.on("error", (e) => console.error(`[vibe-bridge] ask IPC error: ${e.message}`));
    askIpcServer.listen(askIpcSockPath, () =>
      console.log(`[vibe-bridge] ask_user MCP ready (sock=${askIpcSockPath}, hook=${path.join(dir, "vibe-approve-hook.js")})`)
    );
  } catch (e) {
    console.error(`[vibe-bridge] ask_user MCP setup failed: ${e.message}`);
    askMcpConfigPath = null;
    askIpcSockPath = null;
  }
}

// Turn a Claude permission-prompt request ({tool_name, input}) into a phone-
// friendly approval card: a short title of what's about to happen + the literal
// command / file the action targets.
function describeCommandApproval(req) {
  const tool = (req && req.tool_name) || "command";
  const input = (req && req.input) || {};
  let title;
  let command;
  switch (tool) {
    case "Bash":
      title = "Run a terminal command";
      command = input.command || "";
      break;
    case "Edit":
    case "MultiEdit":
    case "Write":
    case "NotebookEdit":
      title = `Edit a file (${tool})`;
      command = input.file_path || input.path || input.notebook_path || "";
      break;
    case "Read":
      title = "Read a file";
      command = input.file_path || input.path || "";
      break;
    default:
      title = `Use ${tool}`;
      command = typeof input === "string" ? input : JSON.stringify(input, null, 2);
  }
  return {
    toolName: tool,
    title,
    command: String(command || "").slice(0, 4000),
    description: typeof input.description === "string" ? input.description : "",
    input,
  };
}

// The MCP child connected and sent {chatId, taskId, questions} (ask) or
// {type:"command", chatId, taskId, tool_name, input} (approval). Relay to the
// phone via requestAsk and write the answer back so the tool call returns.
function handleAskIpcConnection(conn) {
  let buf = "";
  let handled = false;
  let settled = false; // true once we've written the phone's answer back to the caller
  let askHandle = null; // { requestId, cancel } for the outstanding phone sheet
  // The caller (PreToolUse hook or MCP child) disconnected. If it happened BEFORE the
  // phone answered, the request was resolved on its side (a desk keypress, or the hook
  // timed out and fell back to a local prompt) — so dismiss the now-stale phone sheet.
  conn.on("close", () => {
    if (!settled && askHandle) askHandle.cancel("caller_disconnected");
  });
  conn.setEncoding("utf8");
  conn.on("data", async (d) => {
    buf += d;
    const nl = buf.indexOf("\n");
    if (nl < 0 || handled) return;
    handled = true;
    let req = null;
    try { req = JSON.parse(buf.slice(0, nl)); } catch (_) {}
    if (!req || !activeChannel) { try { conn.end(); } catch (_) {} return; }

    // A bridge-spawned run supplies its own chatId. A standalone/interactive session
    // (MCP fallback or the PreToolUse hook) has none — route it to the mobile chat
    // that last ran this repo. If we can't (no chat ever seen), close WITHOUT an
    // answer so the caller falls back to its LOCAL prompt (hook → "ask").
    const chatId = req.chatId || resolveInteractiveChat(req.cwd, req.provider || "claude");
    if (!chatId) {
      console.log(
        `[vibe-bridge][ask] no mobile chat to route interactive ${req.type === "command" ? "command" : "ask"} ` +
          `(cwd=${req.cwd || "?"} source=${req.source || "?"}) — closing so caller falls back locally`
      );
      try { conn.end(); } catch (_) {}
      return;
    }
    if (req.source && req.source !== "bridge") {
      console.log(`[vibe-bridge][ask] interactive ${req.type === "command" ? "command" : "ask"} source=${req.source} cwd=${req.cwd || "?"} → chat=${chatId}`);
    }

    // Command approval (Claude --permission-prompt-tool OR the interactive PreToolUse
    // hook): relay the pending tool to the phone and map Approve/Skip/Deny back.
    if (req.type === "command") {
      const verdict = await requestAsk(
        activeChannel,
        {
          provider: "claude",
          chatId,
          taskId: req.taskId,
          replyToId: null,
          kind: "command",
          body: describeCommandApproval(req),
        },
        (handle) => { askHandle = handle; }
      );
      const vAns = (verdict && verdict.answer) || {};
      const decision = String((verdict && verdict.decision) || "deny").toLowerCase();
      const approved = decision === "approve" || decision === "allow";
      const answer = approved
        ? { decision: "approve", updatedInput: vAns.updatedInput || req.input || {} }
        : {
            decision: "deny",
            message:
              vAns.message ||
              (decision === "skip"
                ? "The user chose to skip this command — continue without it."
                : "The user denied this command."),
          };
      settled = true;
      try { conn.write(JSON.stringify({ answer }) + "\n"); } catch (_) {}
      try { conn.end(); } catch (_) {}
      return;
    }

    const result = await requestAsk(
      activeChannel,
      {
        provider: "claude",
        chatId,
        taskId: req.taskId,
        replyToId: null,
        kind: "ask",
        body: { questions: Array.isArray(req.questions) ? req.questions : [] },
      },
      (handle) => { askHandle = handle; }
    );
    const answer = result && result.answer != null ? result.answer : { decision: result && result.decision };
    settled = true;
    try { conn.write(JSON.stringify({ answer }) + "\n"); } catch (_) {}
    try { conn.end(); } catch (_) {}
  });
  conn.on("error", () => {});
}

// Per-task env handed to the claude spawn so the MCP child knows its chat/task.
function askMcpEnv(provider, chatId, taskId) {
  if (!ASK_MCP_ENABLED || provider !== "claude" || !askIpcSockPath) return {};
  return { VIBE_ASK_SOCK: askIpcSockPath, VIBE_ASK_CHAT: String(chatId || ""), VIBE_ASK_TASK: String(taskId || "") };
}

// ── Socket / channel ────────────────────────────────────────────────

function wsUrl(server) {
  return server.replace(/^http/, "ws") + "/agent-bridge";
}

function websocketTransportUrl(server, token) {
  const params = new URLSearchParams({ token: token || "", vsn: "2.0.0" });
  return `${wsUrl(server)}/websocket?${params.toString()}`;
}

function probeBridgeToken(server, token, timeoutMs = 6000) {
  return new Promise((resolve) => {
    if (!token) return resolve({ ok: false, statusCode: 403 });

    let done = false;
    let ws;
    const finish = (result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        if (ws && ws.readyState === WebSocket.OPEN) ws.close();
      } catch (_) {}
      resolve(result);
    };
    const timer = setTimeout(() => finish({ ok: null, reason: "timeout" }), timeoutMs);

    try {
      ws = new WebSocket(websocketTransportUrl(server, token));
      ws.on("open", () => finish({ ok: true }));
      ws.on("unexpected-response", (_request, response) =>
        finish({ ok: false, statusCode: response && response.statusCode })
      );
      ws.on("error", (error) => finish({ ok: null, reason: error && error.message }));
    } catch (error) {
      finish({ ok: null, reason: error && error.message });
    }
  });
}

// Called on every successful (re)join. On the FIRST join `socketDownSince` is null so
// this is a no-op; on a REJOIN after a drop it (1) re-delivers any result that completed
// while the socket was down — whose one-shot push was lost, leaving the phone's live
// clock ticking forever until an app restart — (2) re-arms the history watches the
// drop tore down, so the transcript re-syncs in place, and (3) replays every unacked
// progress frame for still-running tasks, in order, so a gap torn out of the middle of a
// live stream is repaired rather than leaving the phone's card stuck on stale content.
// The finishedAt >= socketDownSince window means only results that were NOT delivered
// get re-sent (no duplicates).
function recoverAfterReconnect(channel) {
  if (socketDownSince == null) return;
  const downMs = Date.now() - socketDownSince;
  let redelivered = 0;
  for (const rec of finishedTasks.values()) {
    if (rec && rec.resultPayload && rec.finishedAt >= socketDownSince) {
      try {
        channel.push("result", rec.resultPayload);
        redelivered++;
      } catch (_) {}
    }
  }
  let rewatched = 0;
  for (const [chatId, spec] of historyWatchSpecs.entries()) {
    try {
      startHistoryWatch(channel, { chatId, ...spec });
      rewatched++;
    } catch (_) {}
  }
  // Re-emit any still-blocked ask/command whose live broadcast was lost during the
  // outage (the run is still waiting on the phone; the ask never reached it).
  let reasked = 0;
  for (const chatId of pendingAsksByChat.keys()) {
    try {
      reemitPendingAskForChat(channel, chatId);
      reasked++;
    } catch (_) {}
  }
  // Re-sync STILL-RUNNING tasks: replay every frame still sitting in the task's frame log
  // (i.e. every frame the server never acked), in order — not just the last one. A drop
  // in the MIDDLE of a run loses a run of frames, not just the tail; resending only the
  // latest one (the old behavior) left that gap permanently missing from the phone's live
  // card, which is what read as a "frozen" UI. Acked frames are pruned as we go
  // (see ackProgressFrame), so a frame the server already folded into its accumulated
  // transcript is never resent — this can't duplicate steps.
  let resynced = 0;
  let framesReplayed = 0;
  for (const [runningKey, entry] of runningTasks.entries()) {
    if (!entry || !entry.frameLog || !entry.frameLog.length) continue;
    for (const framed of entry.frameLog.slice()) {
      try {
        channel
          .push("progress", { ...framed, sentAtMs: Date.now() })
          .receive("ok", () => ackProgressFrame(runningKey, framed.sequence));
        framesReplayed++;
      } catch (_) {}
    }
    resynced++;
  }
  console.log(
    `[vibe-bridge] reconnected after ${downMs}ms down — recovery: redelivered=${redelivered} result(s), rewatched=${rewatched} chat(s), resynced=${resynced} running (${framesReplayed} frame(s)), reasked=${reasked} pending`
  );
  socketDownSince = null;
}

// Single-flight reconnect: overlapping forceReconnect from heartbeat + onClose used to
// thrash the transport every ~3s (log: 50+ reconnects / short window).
let reconnectInFlight = false;
let reconnectInFlightUntil = 0;

// Hard-kill a (likely half-open) transport so Phoenix runs its normal
// reconnect+rejoin path — the same path a real network drop takes. We prefer
// ws.terminate() because on a zombie socket ws.close() waits on a close
// handshake the dead peer will never answer, leaving us deaf for minutes.
function forceReconnect(socket) {
  const now = Date.now();
  if (reconnectInFlight && now < reconnectInFlightUntil) {
    console.log("[vibe-bridge] forceReconnect skipped (already in flight)");
    return;
  }
  reconnectInFlight = true;
  reconnectInFlightUntil = now + 4000;
  try {
    if (socket.conn && typeof socket.conn.terminate === "function") {
      socket.conn.terminate();
      return;
    }
    if (socket.conn && typeof socket.conn.close === "function") {
      socket.conn.close();
      return;
    }
    socket.disconnect(() => socket.connect());
  } catch (e) {
    console.error(`[vibe-bridge] forceReconnect failed: ${(e && e.message) || e}`);
    try {
      socket.disconnect(() => socket.connect());
    } catch (_) {}
  }
}

// ws-level ping/pong OBSERVER only. Cloudflare often delays pongs; terminating on miss
// was the primary cause of the 1006 reconnect storm that batched progress frames.
// Application-level heartbeat remains the sole reconnect authority.
function attachSocketLivenessPing(conn) {
  if (!conn || typeof conn.ping !== "function") return;
  let awaitingPong = false;
  let misses = 0;
  let lastPongAt = Date.now();
  const pingTimer = setInterval(() => {
    if (conn.readyState !== WebSocket.OPEN) return;
    if (awaitingPong) {
      misses += 1;
      console.warn(
        `[vibe-bridge] ws ping timeout (#${misses}) rtt> ${WS_PING_INTERVAL_MS}ms ` +
          `lastPongAge=${Date.now() - lastPongAt}ms (observe-only; app heartbeat owns reconnect)`
      );
      if (misses > WS_PING_MAX_MISSES) {
        // Reset counter so logs stay readable; do NOT terminate.
        misses = 0;
        awaitingPong = false;
      }
    }
    awaitingPong = true;
    try {
      conn.ping();
    } catch (_) {}
  }, WS_PING_INTERVAL_MS);
  conn.on("pong", () => {
    awaitingPong = false;
    misses = 0;
    lastPongAt = Date.now();
  });
  conn.on("close", () => clearInterval(pingTimer));
}

// ── Direct-LAN transport (phase 1: discovery + authenticated channel) ───────────────
// The phone↔cloud↔Mac relay (WSS) is what makes Claude reachable from ANY network, so it
// STAYS — remote access depends on it. But when the phone and Mac share a Wi-Fi, the relay
// only adds latency and rides the flappy Cloudflare edge. This optional direct path lets a
// co-located phone reach the bridge straight over the LAN. It is fully ADDITIVE: it never
// touches the cloud socket, and any failure here is swallowed so the relay keeps working.
//
// SECURITY: a direct listening socket on the bridge is a remote-code-execution surface (the
// bridge runs Claude with the user's shell). So a connection is UNTRUSTED until it proves it
// holds the shared arte1 pairing key — the same 32-byte secret handed to the phone over the
// pairing QR, which the server never sees. The bridge sends a random nonce; the phone must
// return it sealed with the pairing key (encryptRuntimeBlob). A device on the same Wi-Fi
// WITHOUT the key cannot forge that, so it is rejected before any task routing is reachable.
// The bridge also proves ITS possession of the key in the ready frame (mutual auth).
const LAN_ENABLED = process.env.VIBE_LAN_DISABLE !== "1";
const LAN_SERVICE_TYPE = "_vibegram-bridge._tcp";
const LAN_AUTH_TIMEOUT_MS = 6000;
let lanServer = null;
let lanAdvertiseProc = null;
let lanAdvertisePort = 0;
let lanAdvertiseUser = null;
let lanAdvertiseRestartTimer = null;
let lanAdvertiseHealthTimer = null;
const lanClients = new Set();

function startLanServer(userId) {
  if (!LAN_ENABLED) {
    console.log("[vibe-bridge] LAN transport disabled (VIBE_LAN_DISABLE=1) — cloud relay only");
    return;
  }
  if (lanServer) return; // started once at boot; independent of the cloud socket's lifecycle
  if (!RUNTIME_KEY_B64) {
    console.warn("[vibe-bridge] LAN transport skipped — no pairing key established yet");
    return;
  }
  const WSServer = WebSocket && (WebSocket.Server || WebSocket.WebSocketServer);
  if (!WSServer) {
    console.warn("[vibe-bridge] LAN transport unavailable — ws server class missing");
    return;
  }
  try {
    // port 0 → OS assigns a free ephemeral port; the actual port is advertised via Bonjour
    // so there is never a fixed-port conflict. Bind all interfaces so the Mac's LAN IP works.
    lanServer = new WSServer({ host: "0.0.0.0", port: 0 });
    lanServer.on("listening", () => {
      const port = lanServer.address() && lanServer.address().port;
      console.log(`[vibe-bridge] LAN transport listening on 0.0.0.0:${port}`);
      advertiseLanService(port, userId);
    });
    lanServer.on("connection", (sock, req) => {
      try {
        handleLanConnection(sock, req, userId);
      } catch (err) {
        console.error(`[vibe-bridge] LAN connection handler error: ${(err && err.message) || err}`);
        try { sock.close(); } catch (_) {}
      }
    });
    lanServer.on("error", (err) => {
      console.error(`[vibe-bridge] LAN server error: ${(err && err.message) || err}`);
    });
  } catch (err) {
    console.error(`[vibe-bridge] failed to start LAN transport: ${(err && err.message) || err}`);
    lanServer = null;
  }
}

// A Phoenix-channel-shaped adapter over a raw authed LAN socket, so the EXISTING request
// handlers (runTask / handleHistoryRequest / …) push their replies straight to the phone
// over the LAN with zero changes. Replies ride as {type, payload}; `.state` mirrors the
// socket so a watcher's `channel.state !== "joined"` guard stops pushing to a dead LAN peer.
// `.push().receive("ok")` fulfils immediately — a direct reliable socket needs no server
// round-trip, and the progress frame-log prunes on "ok" exactly as over the cloud channel.
function makeLanTransport(sock) {
  const okApi = {
    receive(status, cb) {
      if (status === "ok") { try { cb({}); } catch (_) {} }
      return okApi;
    },
  };
  return {
    _lanSocket: sock,
    get state() {
      return sock.readyState === WebSocket.OPEN ? "joined" : "closed";
    },
    push(event, payload) {
      if (sock.readyState === WebSocket.OPEN) {
        try {
          sock.send(JSON.stringify({ type: event, payload: payload == null ? {} : payload }));
        } catch (_) {}
      }
      return okApi;
    },
    on() {}, // inbound is dispatched explicitly by handleLanConnection, not via channel.on
  };
}

function handleLanConnection(sock, req, userId) {
  const peer = (req && req.socket && req.socket.remoteAddress) || "?";
  let authed = false;
  let lanTransport = null;
  const nonce = crypto.randomBytes(24).toString("base64url");
  const send = (obj) => { try { sock.send(JSON.stringify(obj)); } catch (_) {} };
  const authTimer = setTimeout(() => {
    if (!authed) {
      console.warn(`[vibe-bridge] LAN auth timeout from ${peer} — closing`);
      try { sock.close(4401, "auth_timeout"); } catch (_) {}
    }
  }, LAN_AUTH_TIMEOUT_MS);
  // Challenge first: the client must echo this nonce back sealed with the pairing key.
  console.log(`[vibe-bridge] LAN connection from ${peer} — issuing auth challenge`);
  send({ type: "lan_challenge", nonce, bridgeUser: userId, proto: 1 });
  sock.on("message", (raw) => {
    let msg = null;
    try { msg = JSON.parse(String(raw)); } catch (_) { return; }
    if (!msg || typeof msg !== "object") return;
    if (!authed) {
      if (msg.type === "lan_auth" && typeof msg.proof === "string") {
        const opened = decryptRuntimeBlob(msg.proof);
        if (opened && opened.nonce === nonce) {
          authed = true;
          clearTimeout(authTimer);
          lanClients.add(sock);
          lanTransport = makeLanTransport(sock);
          console.log(`[vibe-bridge] LAN client authenticated from ${peer} ✓`);
          // Prove the bridge holds the key too (mutual), hand over identity, and push the
          // current bridge status (linked repos etc.) so the LAN client is immediately usable.
          send({ type: "lan_ready", proof: encryptRuntimeBlob({ nonce, role: "bridge" }), user: userId });
          try { pushBridgeStatus(lanTransport); } catch (_) {}
        } else {
          // Split the two failure modes so a post-rescan issue is diagnosable from the log:
          //  - no `opened` → the phone sealed with a DIFFERENT key (re-scan the pairing QR)
          //  - nonce mismatch → a stale/replayed challenge
          const why = !opened
            ? "proof failed to decrypt — phone key ≠ bridge key (re-scan the pairing QR)"
            : "nonce mismatch — stale/replayed challenge";
          console.warn(`[vibe-bridge] LAN auth REJECTED from ${peer} — ${why}`);
          try { sock.close(4403, "auth_failed"); } catch (_) {}
        }
      } else {
        console.warn(`[vibe-bridge] LAN pre-auth frame ignored from ${peer}: type=${msg && msg.type}`);
      }
      return;
    }
    // Authenticated LAN channel: route the SAME requests the cloud Phoenix channel serves,
    // through the exact same handlers via the transport adapter. Replies + live history/
    // progress stream straight back over the LAN. Ask emission intentionally still rides the
    // cloud channel (the phone keeps its cloud socket up for regular messaging), so approval
    // cards keep working regardless of which transport is carrying the agent stream.
    const p = (msg.payload && typeof msg.payload === "object") ? msg.payload : {};
    switch (msg.type) {
      case "lan_ping":
        send({ type: "lan_pong", ts: Date.now() });
        break;
      case "run_task":
        if (!payloadTargetsThisComputer(p, msg.type)) break;
        runTask(lanTransport, p).catch((err) =>
          console.error(`[vibe-bridge] LAN runTask error: ${(err && err.message) || err}`)
        );
        break;
      case "control_task":
        if (!payloadTargetsThisComputer(p, msg.type)) break;
        controlTask(lanTransport, p);
        break;
      case "history_request":
        if (!payloadTargetsThisComputer(p, msg.type)) break;
        handleHistoryRequest(lanTransport, p);
        break;
      case "file_request":
        if (!payloadTargetsThisComputer(p, msg.type)) break;
        handleFileRequest(lanTransport, p);
        break;
      case "usage_request":
        if (!payloadTargetsThisComputer(p, msg.type)) break;
        handleUsageRequest(lanTransport, p).catch((err) =>
          console.error(`[vibe-bridge] LAN usage_request error: ${(err && err.message) || err}`)
        );
        break;
      case "ask_response":
        if (!payloadTargetsThisComputer(p, msg.type)) break;
        resolveAsk(p);
        break;
      default:
        break;
    }
  });
  sock.on("close", () => { clearTimeout(authTimer); lanClients.delete(sock); });
  sock.on("error", () => { clearTimeout(authTimer); lanClients.delete(sock); });
}

function advertiseLanService(port, userId) {
  if (!port) return;
  lanAdvertisePort = port;
  lanAdvertiseUser = userId;
  stopLanAdvertise();
  try {
    const label = `Vibe Bridge (${os.hostname()})`;
    // macOS ships `dns-sd`, so Bonjour registration needs no npm dependency. The uid TXT
    // record lets the phone pick the bridge for THIS account when several share a network.
    const proc = spawn(
      "dns-sd",
      ["-R", label, LAN_SERVICE_TYPE, ".", String(port), `uid=${userId}`],
      { stdio: "ignore" }
    );
    lanAdvertiseProc = proc;
    proc.on("error", (err) => {
      console.warn(
        `[vibe-bridge] Bonjour advertise failed (${(err && err.message) || err}) — LAN still reachable by direct IP`
      );
    });
    // The dns-sd registration is ONLY live while this child runs. If it dies (which we
    // have seen happen silently) the service vanishes and phones get stuck "searching"
    // forever — so respawn it. Guard against a superseding advertise having replaced it.
    proc.on("exit", (code, signal) => {
      if (proc !== lanAdvertiseProc) return;
      lanAdvertiseProc = null;
      console.warn(
        `[vibe-bridge] Bonjour advertise exited (code=${code} signal=${signal || "-"}) — re-advertising`
      );
      scheduleReadvertise();
    });
    console.log(`[vibe-bridge] advertising ${LAN_SERVICE_TYPE} on port ${port} via Bonjour (pid ${proc.pid})`);
    startLanAdvertiseHealthCheck();
  } catch (err) {
    console.warn(`[vibe-bridge] Bonjour advertise error: ${(err && err.message) || err}`);
    scheduleReadvertise();
  }
}

// Debounced respawn of the Bonjour registration after its child dies.
function scheduleReadvertise() {
  if (lanAdvertiseRestartTimer) return;
  lanAdvertiseRestartTimer = setTimeout(() => {
    lanAdvertiseRestartTimer = null;
    if (!lanServer || !lanAdvertisePort || lanAdvertiseProc) return;
    advertiseLanService(lanAdvertisePort, lanAdvertiseUser);
  }, 2000);
  if (lanAdvertiseRestartTimer.unref) lanAdvertiseRestartTimer.unref();
}

// Belt-and-suspenders: even if the `exit` event is ever missed, re-assert the
// advertisement periodically so a dead registration self-heals within a minute.
function startLanAdvertiseHealthCheck() {
  if (lanAdvertiseHealthTimer) return;
  lanAdvertiseHealthTimer = setInterval(() => {
    if (!lanServer || !lanAdvertisePort) return;
    const alive = lanAdvertiseProc && lanAdvertiseProc.exitCode == null && !lanAdvertiseProc.killed;
    if (!alive) {
      console.warn("[vibe-bridge] Bonjour advertise health check found it dead — re-advertising");
      advertiseLanService(lanAdvertisePort, lanAdvertiseUser);
    }
  }, 45000);
  if (lanAdvertiseHealthTimer.unref) lanAdvertiseHealthTimer.unref();
}

function stopLanAdvertise() {
  if (lanAdvertiseProc) {
    const dying = lanAdvertiseProc;
    lanAdvertiseProc = null; // clear first so the exit handler's guard skips the respawn
    try { dying.kill(); } catch (_) {}
  }
}

function connect(server, token, userId) {
  const socket = new Phoenix.Socket(wsUrl(server), {
    params: { token },
    transport: WebSocket,
    reconnectAfterMs: (tries) => [1000, 2000, 5000, 10000][tries - 1] || 10000,
    // A tighter heartbeat keeps idle connections alive through proxy/LB idle reapers
    // (the recurring code=1006 drops) and detects a dead socket faster so the auto
    // reconnect kicks in sooner.
    heartbeatIntervalMs: 15000,
  });

  // Re-armed on every (re)connect — Phoenix opens a brand-new transport per attempt, so
  // socket.conn is a different `ws` instance each time onOpen fires.
  socket.onOpen(() => attachSocketLivenessPing(socket.conn));

  socket.onError((error) => {
    const detail =
      (error && (error.message || error.reason || error.code || error.type)) ||
      (error ? JSON.stringify(error) : "");
    console.error(`[vibe-bridge] socket error${detail ? `: ${detail}` : ""} (will retry)`);
  });
  socket.onClose((event) => {
    const detail =
      event && (event.code || event.reason)
        ? ` code=${event.code || "-"} reason=${event.reason || "-"}`
        : "";
    console.log(`[vibe-bridge] socket closed${detail} (will retry)`);
    // Mark the start of the outage (first close only) so the rejoin handler can recover
    // anything that completed while we were down.
    if (socketDownSince == null) socketDownSince = Date.now();
    stopAllHistoryWatches(); // watchers hold a now-stale channel
  });
  socket.connect();

  // Transport watchdog — the ONLY self-heal that runs when the channel is NOT joined.
  //
  // A CLEAN socket close (code=1000: LB recycle / server deploy) never triggers
  // phoenix.js auto-reconnect (it only retries abnormal closes), and the app
  // heartbeat below early-returns while channel.state !== "joined" — so a clean
  // close used to wedge the bridge cloud-dead FOREVER while the process (and LAN)
  // stayed up (observed 2026-07-15: 'socket closed code=1000' with no reconnect,
  // every dispatch → {:error, :offline}). If the transport sits closed with no
  // connection attempt for 20s+, force a fresh socket.connect(). During normal
  // phoenix backoff the state flips to "connecting" on every attempt, which
  // resets the timer — this only fires when phoenix has genuinely given up.
  let transportDownSince = null;
  setInterval(() => {
    let st = "unknown";
    try {
      st = typeof socket.connectionState === "function" ? socket.connectionState() : "unknown";
    } catch (_) {}
    if (st === "open" || st === "connecting") {
      transportDownSince = null;
      return;
    }
    if (transportDownSince == null) {
      transportDownSince = Date.now();
      return;
    }
    const downMs = Date.now() - transportDownSince;
    if (downMs >= 20000) {
      console.error(
        `[vibe-bridge] transport ${st} for ${downMs}ms with no reconnect attempt — forcing socket.connect()`
      );
      transportDownSince = null;
      try {
        socket.connect();
      } catch (e) {
        console.error(`[vibe-bridge] watchdog connect failed: ${(e && e.message) || e}`);
      }
    }
  }, 10000);

  const channel = socket.channel(`bridge:${userId}`, {});
  channel.on("bridge_identity", (payload) => {
    adoptComputerIdentity(payload || {}, true);
    console.log(
      `[vibe-bridge] identity computer=${ACTIVE_COMPUTER_ID || "unknown"} label=${ACTIVE_COMPUTER_LABEL || ARGS.label || os.hostname()}`
    );
    pushBridgeStatus(channel);
  });
  channel.on("run_task", (task) => {
    if (!payloadTargetsThisComputer(task, "run_task")) return;
    runTask(channel, task).catch((err) =>
      console.error(`[vibe-bridge] runTask error: ${(err && err.message) || err}`)
    );
  });
  channel.on("control_task", (payload) => {
    if (!payloadTargetsThisComputer(payload, "control_task")) return;
    controlTask(channel, payload || {});
  });
  channel.on("history_request", (payload) => {
    if (!payloadTargetsThisComputer(payload, "history_request")) return;
    handleHistoryRequest(channel, payload || {});
  });
  channel.on("file_request", (payload) => {
    if (!payloadTargetsThisComputer(payload, "file_request")) return;
    handleFileRequest(channel, payload || {});
  });
  channel.on("usage_request", (payload) =>
    payloadTargetsThisComputer(payload, "usage_request")
      ? handleUsageRequest(channel, payload || {}).catch((err) =>
          console.error(`[vibe-bridge] usage_request error: ${(err && err.message) || err}`)
        )
      : undefined
  );
  channel.on("ask_response", (payload) => {
    if (!payloadTargetsThisComputer(payload, "ask_response")) return;
    resolveAsk(payload || {});
  });
  ensureAskMcp(channel); // start the ask_user MCP IPC server; refresh active channel

  channel
    .join()
    .receive("ok", () => {
      console.log(`\n✅ [vibe-bridge] CONNECTED! Your computer is now online for user ${userId}.`);
      if (ADVERTISED_REPOSITORIES.length) {
        console.log("[vibe-bridge] linked repositories:");
        for (const repo of ADVERTISED_REPOSITORIES) {
          console.log(`   • ${repo.name}  ${repo.path}`);
        }
      }
      if (!ARGS.serviceRun) {
        console.log(
          "\n   Foreground mode is active for this terminal.\n" +
            "   Change projects later with:  vibegram-bridge --pick\n"
        );
      }
      reconnectInFlight = false;
      recoverAfterReconnect(channel);
      pushBridgeStatus(channel);
    })
    .receive("error", (e) => console.error("[vibe-bridge] join error:", JSON.stringify(e)));

  // Heartbeat + zombie-socket watchdog.
  //
  // Cloudflare/Railway recycle WebSocket connections constantly (the recurring
  // code=1006/1012 drops). Usually Phoenix's own socket heartbeat catches a dead
  // conn, but on a half-open TCP socket the close frame can be lost so onClose
  // never fires and the socket sits "joined" but DEAF — no run_task is ever
  // delivered and the bridge goes silent indefinitely (observed: 8+ min dead
  // while the phone got no response at all).
  //
  // APPLICATION-level liveness: sole reconnect authority (ws-ping is observe-only).
  // Higher miss budget + longer push timeout: one delayed ack through the edge must
  // NOT thrash the socket (that batch-dumped progress at 7–15s recv→push).
  let missedHeartbeats = 0;
  setInterval(() => {
    if (channel.state !== "joined") return;
    // Don't pile heartbeats while a reconnect is already in flight.
    if (reconnectInFlight && Date.now() < reconnectInFlightUntil) return;
    channel
      .push("heartbeat", {}, APP_HEARTBEAT_PUSH_TIMEOUT_MS)
      .receive("ok", () => {
        if (missedHeartbeats > 0) {
          console.log(`[vibe-bridge] heartbeat recovered after ${missedHeartbeats} miss(es)`);
        }
        missedHeartbeats = 0;
        reconnectInFlight = false;
      })
      .receive("timeout", () => {
        missedHeartbeats += 1;
        console.error(
          `[vibe-bridge] heartbeat ack timeout (#${missedHeartbeats}/${APP_HEARTBEAT_MAX_MISSES}) — socket may be a zombie`
        );
        if (missedHeartbeats >= APP_HEARTBEAT_MAX_MISSES) {
          console.error(
            "[vibe-bridge] forcing reconnect after repeated heartbeat timeouts (zombie socket)"
          );
          missedHeartbeats = 0;
          forceReconnect(socket);
        }
      });
    // Status is useful but not every tick — only when idle tasks need advertising.
    // Pushing status every 30s during heavy stream was extra channel load on a flaky edge.
    if (runningTasks.size === 0) {
      pushBridgeStatus(channel);
    }
  }, APP_HEARTBEAT_INTERVAL_MS);
}

async function runSelfTest() {
  const config = loadConfig();
  ensureRuntimeKey(config);
  await resolveRepositories(config, () => {});
  DEFAULT_CWD =
    (ADVERTISED_REPOSITORIES[0] && ADVERTISED_REPOSITORIES[0].cwd) ||
    realDir(ARGS.cwd || process.cwd()) ||
    process.cwd();

  const provider = String(ARGS.provider || "codex").trim().toLowerCase();
  const baseTask = {
    provider,
    chatId: "self-test-chat",
    replyToId: "self-test-message",
    requesterUserId: "self-test-user",
    repoId: ADVERTISED_REPOSITORIES[0] && ADVERTISED_REPOSITORIES[0].id,
    workMode: ARGS.workMode || "allow_edits",
  };

  const runSelfTestTask = (task, shouldRevert) =>
    new Promise((resolve) => {
    let awaitingRevert = false;
    const channel = {
      state: "joined",
      push(event, payload) {
        console.log(JSON.stringify({ event, payload }));
        if (
          event === "result" &&
          shouldRevert &&
          (payload.canRevert || payload.agentRuntime?.controls?.canRevert)
        ) {
          awaitingRevert = true;
          controlTask(channel, {
            action: "revert",
            provider: task.provider,
            chatId: task.chatId,
            taskId: task.taskId,
          });
          return;
        }
        if (event === "control_result" && awaitingRevert) resolve();
        if (event === "result" || event === "error") resolve();
      },
    };
    runTask(channel, task).catch((err) =>
      console.error(`[vibe-bridge] runTask error: ${(err && err.message) || err}`)
    );
    });

  if (ARGS.selfTestSequence) {
    let steps;
    try {
      steps = JSON.parse(ARGS.prompt || "[]");
    } catch (err) {
      console.error(`[vibe-bridge] --self-test-sequence expects --prompt to be a JSON array: ${err.message}`);
      process.exit(1);
    }
    if (!Array.isArray(steps) || steps.length === 0) {
      console.error("[vibe-bridge] --self-test-sequence needs at least one step.");
      process.exit(1);
    }
    for (const [index, step] of steps.entries()) {
      const stepObject = typeof step === "string" ? { prompt: step } : step || {};
      const stepProvider = String(stepObject.provider || provider).trim().toLowerCase();
      const task = {
        ...baseTask,
        provider: stepProvider,
        taskId: `self-test-task-${index + 1}`,
        prompt: stepObject.prompt || "Bridge self-test",
        workMode: stepObject.workMode || stepObject.mode || ARGS.workMode || "allow_edits",
        ...teamFieldsForTask(stepObject),
      };
      await runSelfTestTask(task, stepObject.revert === true);
    }
    return;
  }

  await runSelfTestTask(
    {
      ...baseTask,
      taskId: "self-test-task",
      prompt: ARGS.prompt || "Bridge self-test",
      ...teamFieldsForTask(ARGS),
    },
    ARGS.selfTestRevert
  );
}

// ── Singleton (one bridge process at a time) ────────────────────────

/**
 * Ensure only ONE long-lived bridge daemon runs on this machine.
 *
 * Dual bridges both join the server socket and both execute run_task, which
 * posts duplicate agent replies (e.g. two near-identical Grok bubbles). On
 * start we:
 *   1) kill every other vibe-bridge / vibegram-bridge node process
 *   2) claim ~/.vibe/bridge.pid
 *   3) re-sweep after a short settle (covers two starters racing)
 *   4) if another live pid still owns the pidfile, exit
 *
 * Management commands (--status, --install, --help, …) skip this.
 */
// Stamp {pid, ts, active} so another starter can see we're alive and how many CLI tasks
// we're running. Called on a timer AND at every task register/finish so the active count
// is never stale across the yield decision window.
function writeBridgeHeartbeat() {
  try {
    fs.writeFileSync(
      SINGLETON_HEARTBEAT_FILE,
      JSON.stringify({ pid: process.pid, ts: Date.now(), active: runningTasks.size }),
      { mode: 0o600 }
    );
  } catch (_) {}
}

let bridgeHeartbeatTimer = null;
function startBridgeHeartbeat() {
  writeBridgeHeartbeat();
  bridgeHeartbeatTimer = setInterval(writeBridgeHeartbeat, SINGLETON_HEARTBEAT_MS);
  if (bridgeHeartbeatTimer && bridgeHeartbeatTimer.unref) bridgeHeartbeatTimer.unref();
}

function readBridgeHeartbeat() {
  try {
    const o = JSON.parse(fs.readFileSync(SINGLETON_HEARTBEAT_FILE, "utf8"));
    if (o && Number.isFinite(o.pid) && Number.isFinite(o.ts)) return o;
  } catch (_) {}
  return null;
}

function ensureBridgeSingleton() {
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });

  // Never take over a bridge that is actively running work — its child worker CLIs
  // (claude/grok/codex) would die with it (exit 143/130), gutting a team run mid-flight.
  // If a healthy bridge is already up and BUSY, yield (exit) instead of killing it. An
  // idle or stale/wedged holder is still replaced, so relaunching to pick up new bridge
  // code keeps working.
  const holder = readBridgePidFile();
  if (holder && holder !== process.pid && isProcessAlive(holder)) {
    const hb = readBridgeHeartbeat();
    const fresh = hb && hb.pid === holder && Date.now() - hb.ts < SINGLETON_HEARTBEAT_STALE_MS;
    if (fresh && Number(hb.active) > 0) {
      console.log(
        `[vibe-bridge] an existing bridge is running ${hb.active} task(s) pid=${holder}; ` +
          `yielding so its workers aren't killed (exit). Use --stop/--restart to replace it.`
      );
      process.exit(0);
    }
  }

  killOtherBridgeProcesses();

  // Serialize concurrent starters via exclusive O_EXCL create of a lock stamp.
  // The winner writes the pidfile; the loser exits (after killing others so a
  // stale lock can't block forever).
  let wonLock = false;
  try {
    const fd = fs.openSync(SINGLETON_LOCK_FILE, "wx", 0o600);
    fs.writeFileSync(fd, String(process.pid) + "\n");
    fs.closeSync(fd);
    wonLock = true;
  } catch (err) {
    if (err && err.code === "EEXIST") {
      const holder = readLockFilePid(SINGLETON_LOCK_FILE);
      if (holder && holder !== process.pid && isProcessAlive(holder)) {
        // A live lock-holder that is BUSY running tasks must not be killed — yield to it
        // (same reason as the top guard; covers the near-simultaneous-start race).
        const hb = readBridgeHeartbeat();
        const busy =
          hb && hb.pid === holder &&
          Date.now() - hb.ts < SINGLETON_HEARTBEAT_STALE_MS &&
          Number(hb.active) > 0;
        if (busy) {
          console.log(
            `[vibe-bridge] lock-holder pid=${holder} is running ${hb.active} task(s); ` +
              `yielding (exit).`
          );
          process.exit(0);
        }
        // Idle/stale live holder — replace it (auto-kill duplicates), then claim.
        try {
          process.kill(holder, "SIGTERM");
          console.log(
            `[vibe-bridge] killed lock-holder bridge pid=${holder}`
          );
        } catch (_) {}
        try {
          execFileSync("sleep", ["0.2"], { stdio: "ignore" });
        } catch (_) {}
        if (isProcessAlive(holder)) {
          try {
            process.kill(holder, "SIGKILL");
          } catch (_) {}
        }
      }
      try {
        fs.unlinkSync(SINGLETON_LOCK_FILE);
      } catch (_) {}
      try {
        const fd = fs.openSync(SINGLETON_LOCK_FILE, "wx", 0o600);
        fs.writeFileSync(fd, String(process.pid) + "\n");
        fs.closeSync(fd);
        wonLock = true;
      } catch (err2) {
        // Another starter won the re-create race — yield.
        const other = readLockFilePid(SINGLETON_LOCK_FILE) || readBridgePidFile();
        console.error(
          `[vibe-bridge] another bridge is already running` +
            (other ? ` (pid ${other})` : "") +
            `; exiting`
        );
        process.exit(0);
      }
    } else {
      console.error(
        `[vibe-bridge] cannot claim singleton lock: ${(err && err.message) || err}`
      );
      process.exit(1);
    }
  }

  if (!wonLock) {
    console.error("[vibe-bridge] failed to claim singleton lock; exiting");
    process.exit(1);
  }

  try {
    fs.writeFileSync(SINGLETON_PID_FILE, String(process.pid) + "\n", {
      mode: 0o600,
    });
  } catch (_) {}

  const release = () => {
    try {
      const cur = readBridgePidFile();
      if (cur === process.pid) fs.unlinkSync(SINGLETON_PID_FILE);
    } catch (_) {}
    try {
      const lockPid = readLockFilePid(SINGLETON_LOCK_FILE);
      if (lockPid === process.pid || lockPid == null) {
        fs.unlinkSync(SINGLETON_LOCK_FILE);
      }
    } catch (_) {}
  };
  process.once("exit", release);
  process.once("SIGINT", () => {
    release();
    process.exit(130);
  });
  process.once("SIGTERM", () => {
    release();
    process.exit(143);
  });

  // Race cover: two processes can both pass pgrep before either claims the lock.
  setTimeout(() => {
    killOtherBridgeProcesses();
    try {
      fs.writeFileSync(SINGLETON_PID_FILE, String(process.pid) + "\n", {
        mode: 0o600,
      });
    } catch (_) {}
  }, 1500);

  startBridgeHeartbeat();
  console.log(`[vibe-bridge] singleton ready pid=${process.pid}`);
}

function readLockFilePid(filePath) {
  try {
    const raw = fs.readFileSync(filePath, "utf8").trim();
    const n = parseInt(raw, 10);
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch (_) {
    return null;
  }
}

function readBridgePidFile() {
  return readLockFilePid(SINGLETON_PID_FILE);
}

function isProcessAlive(pid) {
  if (!pid || pid === process.pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

function killOtherBridgeProcesses() {
  const selfPid = process.pid;
  let pids = [];
  try {
    const out = execFileSync(
      "pgrep",
      ["-f", "vibe-bridge\\.js|@vibegram/agent-bridge|vibegram-bridge"],
      { encoding: "utf8" }
    );
    pids = out
      .split(/\s+/)
      .map((s) => parseInt(s, 10))
      .filter((n) => Number.isFinite(n) && n > 0 && n !== selfPid);
  } catch (_) {
    // pgrep exit 1 = no matches
    pids = [];
  }

  const filePid = readBridgePidFile();
  if (filePid && filePid !== selfPid && !pids.includes(filePid)) {
    pids.push(filePid);
  }

  for (const pid of pids) {
    if (!isProcessAlive(pid)) continue;
    let cmdline = "";
    try {
      cmdline = execFileSync("ps", ["-p", String(pid), "-o", "command="], {
        encoding: "utf8",
      }).trim();
    } catch (_) {
      continue;
    }
    if (
      !/vibe-bridge\.js|@vibegram\/agent-bridge|vibegram-bridge/.test(cmdline)
    ) {
      continue;
    }
    try {
      process.kill(pid, "SIGTERM");
      console.log(`[vibe-bridge] killed duplicate bridge pid=${pid}`);
    } catch (err) {
      console.warn(
        `[vibe-bridge] failed to kill duplicate pid=${pid}: ${(err && err.message) || err}`
      );
    }
  }

  const deadline = Date.now() + 800;
  while (Date.now() < deadline) {
    if (!pids.some(isProcessAlive)) break;
    try {
      execFileSync("sleep", ["0.05"], { stdio: "ignore" });
    } catch (_) {
      break;
    }
  }
  for (const pid of pids) {
    if (!isProcessAlive(pid)) continue;
    try {
      process.kill(pid, "SIGKILL");
      console.log(`[vibe-bridge] force-killed duplicate bridge pid=${pid}`);
    } catch (_) {}
  }
}

// ── Main ────────────────────────────────────────────────────────────

async function main() {
  if (ARGS.help) {
    console.log(
      "Usage:\n" +
        "  vibegram-bridge --server <https://vibe-server>\n" +
        "      First run: shows a QR — scan it in the Vibe app (Claude/Codex → Connect → Scan),\n" +
        "      then asks which project(s) to link and starts the background service.\n\n" +
        "  vibegram-bridge --pick            re-choose which project(s) to link\n" +
        "  vibegram-bridge --all             link every git repo found near your home folder\n" +
        "  vibegram-bridge --foreground      run in this terminal instead of the background service\n" +
        "  vibegram-bridge --pair            show a fresh QR and replace the cached account\n" +
        "  vibegram-bridge --install         install/restart the background service\n" +
        "  vibegram-bridge --uninstall       stop & remove the background service\n" +
        "  vibegram-bridge --status          show background-service state + log path\n" +
        "  vibegram-bridge --self-test       run one local task and print bridge payload JSON\n" +
        "  vibegram-bridge --self-test-revert  also test bridge-side revert after self-test\n" +
        "  vibegram-bridge --self-test-sequence --prompt '[...]'  run JSON task list in one process\n" +
        "  vibegram-bridge --code <CODE>     manual pairing code flow\n" +
        "  vibegram-bridge --logout          remove the cached token\n\n" +
        "Non-interactive repo selection: --cwd <dir>, --repo <dir> (repeatable),\n" +
	        "     --repo-root <dir> (scans 2 levels for .git). Env: VIBE_BRIDGE_REPOS,\n" +
	        "     VIBE_BRIDGE_REPO_ROOTS, VIBE_CLAUDE_PERMISSION_MODE, VIBE_CODEX_SANDBOX,\n" +
	        "     VIBE_CODEX_APPROVAL_POLICY, VIBE_CLAUDE_MODEL, VIBE_CLAUDE_ADVISOR,\n" +
	        "     VIBE_CLAUDE_ADVISOR_MODEL, VIBE_FABLE_MCP, VIBE_FABLE_MODEL,\n" +
          "     VIBE_FABLE_MCP_CONTEXT_CHARS, VIBE_CODEX_MODEL,\n" +
	        "     VIBE_CLAUDE_COMMAND, VIBE_CODEX_COMMAND"
	  );
    return;
  }

  if (ARGS.selfTest || ARGS.selfTestRevert || ARGS.selfTestSequence) return runSelfTest();

  if (ARGS.logout) {
    try {
      fs.unlinkSync(CONFIG_FILE);
    } catch (_) {}
    console.log("[vibe-bridge] logged out (local token removed).");
    return;
  }

  const config = loadConfig();
  const persist = () => saveConfig(config);
  adoptComputerIdentity(
    { computerId: config.computer_id, computerLabel: config.device_label || ARGS.label },
    false
  );
  const server = normalizeServer(ARGS.server || config.server || "https://api.vibegram.io");
  if (!server) {
    console.error("[vibe-bridge] Missing --server <https://your-vibe-server>");
    process.exit(1);
  }
  config.server = server;

  // Establish the end-to-end runtime key before any pairing, so the pairing QR
  // can hand it to the phone (server never sees it). Generated once, cached.
  ensureRuntimeKey(config);
  persist();

  if (ARGS.showKey) {
    console.log(
      "\n[vibe-bridge] In Vibe (Claude/Codex → Connect → Sync key), scan this to view\n" +
        "encrypted agent file-changes on your phone. The server can't read it.\n"
    );
    renderQR(runtimeKeyQRPayload());
    return;
  }

  // Background-service management (no socket needed).
  if (ARGS.uninstall) return uninstallService();
  if (ARGS.status) return serviceStatus();
  if (ARGS.pair) {
    if (config.user_id) {
      console.log(`[vibe-bridge] replacing cached pairing for user ${config.user_id}...`);
    }
    const result = await scanToPair(server, ARGS.label);
    config.bridge_token = result.bridge_token;
    config.user_id = result.user_id;
    config.computer_id = result.computer_id || config.computer_id;
    adoptComputerIdentity(result, false);
    persist();
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
  }
  if (ARGS.install) {
    if (!config.bridge_token || !config.user_id) return installService(server, config);
    await resolveRepositories(config, persist);
    return installService(server, config);
  }

  if (ARGS.code) {
    console.log("[vibe-bridge] pairing…");
    const result = await redeemPairing(server, ARGS.code, ARGS.label);
    config.bridge_token = result.bridge_token;
    config.user_id = result.user_id;
    config.computer_id = result.computer_id || config.computer_id;
    adoptComputerIdentity(result, false);
    persist();
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
    if (!ARGS.rk) {
      console.log(
        "\n[vibe-bridge] To view encrypted agent file-changes on your phone, scan this in\n" +
          "Vibe (Claude/Codex → Connect → Sync key). The server can't read it.\n"
      );
      renderQR(runtimeKeyQRPayload());
    }
  }

  if (
    config.bridge_token &&
    config.user_id &&
    process.stdin.isTTY &&
    !ARGS.serviceRun &&
    !ARGS.foreground
  ) {
    const probe = await probeBridgeToken(server, config.bridge_token);
    if (probe.ok === false && probe.statusCode === 403) {
      delete config.bridge_token;
      delete config.user_id;
      persist();
      console.log("[vibe-bridge] cached pairing expired; pairing again…");
    }
  }

  if (!config.bridge_token || !config.user_id) {
    const result = await scanToPair(server, ARGS.label);
    config.bridge_token = result.bridge_token;
    config.user_id = result.user_id;
    config.computer_id = result.computer_id || config.computer_id;
    adoptComputerIdentity(result, false);
    persist();
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
  }

  persist();

  // Resolve which project(s) to expose (interactive first run, cached after).
  await resolveRepositories(config, persist);

  if (shouldUseBackgroundByDefault()) {
    return installService(server, config);
  }

  // Long-lived socket path only: kill duplicate daemons, claim exclusive ownership.
  ensureBridgeSingleton();

  // Bring up the optional direct-LAN path alongside the cloud relay. Guarded + additive:
  // if it can't bind or advertise, the cloud connection below is entirely unaffected.
  try {
    startLanServer(config.user_id);
  } catch (err) {
    console.error(`[vibe-bridge] startLanServer failed (continuing cloud-only): ${(err && err.message) || err}`);
  }

  connect(server, config.bridge_token, config.user_id);
}

// Exposed for local tests (history runtime reconstruction). Harmless at runtime.
module.exports = {
  claudeDetail,
  codexDetail,
  codexSummary,
  listCodex,
  readHistory,
  buildHistoryRuntime,
  collectClaudeEdits,
  collectCodexEdits,
  codexActionDetail,
  codexActionDetails,
  codexUnwrapActionPayload,
  codexUnwrapActionPayloads,
  codexUserMessageText,
  codexFallbackTitle,
  codexOutputText,
  extractVibeUserPrompt,
  parseApplyPatchEnvelope,
  newRuntimeAccumulator,
  ensureRuntimeKey,
  liveAgentActionsField,
  liveClaudeActions,
  liveCodexActions,
  fileWithinLinkedRepo,
  handleFileRequest,
  normalizeModel,
  runningPlaceholderMessage,
  markDetailLiveTurn,
  markMessageRunning,
  claudeOpenTurnState,
  claudeTaskNotification,
  updateClaudeBackgroundTasks,
  sessionFilePath,
  sessionFileIsLive,
  providerTerminalFailure,
};

// Only auto-run the daemon when invoked directly (so the module is requireable).
if (require.main === module) {
  main().catch((err) => {
    console.error("[vibe-bridge] fatal:", err.message);
    process.exit(1);
  });
}
