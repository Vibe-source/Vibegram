#!/usr/bin/env node
"use strict";
// Vibe PreToolUse hook — decides how Claude Code gets approval for tools.
// Behaviour is driven by ~/.vibe/agent-config.toml (approval_mode):
//   "local"  -> pure pass-through: approve/answer on THIS device only (no phone).
//   "mobile" -> safe/allow-listed run w/o asking; blockers -> phone and remain
//               pending until answered; if the bridge is down it falls back locally.
//   "auto"   -> same as "mobile" (Codex-like: safe auto, blockers -> phone).
//   "both"   -> safe/allow-listed run w/o asking; blockers show on BOTH the desk and
//               the phone at once (first responder wins) when this is a real terminal
//               session; a headless/IDE session (no /dev/tty) just prompts locally so
//               the agent never blocks on the phone.
//   "full"   -> allow everything EXCEPT the always-blocked dangerous list.
// The always-blocked dangerous list is enforced in every mode except "local".
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const tty = require("tty");
const HOME = os.homedir();
const VDIR = path.join(HOME, ".vibe");
const SOCK = path.join(VDIR, "ask.sock");
const CONFIG_PATH = path.join(VDIR, "agent-config.toml");
// Zero means wait for an explicit phone decision. This hook is the blocking side of
// a mobile approval, so a local timer must not silently convert it back to a desktop
// prompt while the phone is backgrounded or reconnecting.
const ROUTE_TIMEOUT_MS = Number(process.env.VIBE_APPROVAL_TIMEOUT_MS || 0);

// ---------- tiny TOML subset reader (key = value / ["a","b"] / true|false) ----
function parseToml(text) {
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("#") || t.startsWith("[")) continue;
    const eq = t.indexOf("=");
    if (eq < 0) continue;
    const key = t.slice(0, eq).trim();
    let val = t.slice(eq + 1).trim();
    if (val.startsWith("[")) {
      const inner = val.replace(/^\[/, "").replace(/\][^\]]*$/, "");
      out[key] = inner.split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
    } else if (val === "true" || val === "false") {
      out[key] = val === "true";
    } else {
      out[key] = val.replace(/\s+#.*$/, "").trim().replace(/^["']|["']$/g, "");
    }
  }
  return out;
}
function readConfig() {
  const cfg = { approval_mode: "local", auto_allow: [], deny: [] };
  try { Object.assign(cfg, parseToml(fs.readFileSync(CONFIG_PATH, "utf8"))); } catch (_) {}
  if (!Array.isArray(cfg.auto_allow)) cfg.auto_allow = [];
  if (!Array.isArray(cfg.deny)) cfg.deny = [];
  return cfg;
}

// ---------- always-blocked (destructive) — never auto, denied even in full ----
const DANGEROUS = [
  /\brm\s+-\w*[rf]/, /\bsudo\b/, /\bgit\s+push\b/, /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\b/, /\bmkfs\b/, /\bdd\s+if=/, /:\s*\(\s*\)\s*\{/, /\bshutdown\b/,
  /\breboot\b/, /\bkillall\b/, /\bchmod\s+-R\s+777\b/, />\s*\/dev\/sd/,
  /--force\b.*\bpush\b|\bpush\b.*--force\b/, /\bnpm\s+publish\b/,
  /\bcurl\b[^\n]*\|\s*(sh|bash|zsh)\b/, /\bwget\b[^\n]*\|\s*(sh|bash|zsh)\b/,
];
function isDangerous(cmd) { return DANGEROUS.some((re) => re.test(cmd)); }

// ---------- built-in safe Bash allow-list (read / search / inspect / build) ---
// Read-only, non-mutating commands that never need a human. Evaluated PER PIPELINE
// SEGMENT so "grep foo | head", "cat f | sort | uniq -c", "find . | wc -l" all pass.
const SAFE_BASH = [
  /^(ls|pwd|cat|bat|head|tail|less|more|wc|file|stat|du|df|tree|basename|dirname|realpath|readlink)\b/,
  /^(grep|egrep|fgrep|rg|ag|ack|find|fd|which|type|whereis|locate|mdfind)\b/,
  /^(echo|printf|true|false|date|whoami|hostname|uname|env|sw_vers|sleep|id|groups|uptime|arch|yes)\b/,
  /^(sed|awk|cut|sort|uniq|tr|nl|column|comm|join|paste|rev|fold|fmt|tac|xxd|od|strings|hexdump|base64)\b/,
  /^(jq|yq|xmllint|plutil\s+-(p|lint))\b/,
  /^(diff|cmp|colordiff)\b/,
  /^(ps|top\s+-l|lsof|pgrep|vm_stat|sysctl\s+-[na])\b/,
  /^git\s+(status|diff|log|show|branch|remote|blame|rev-parse|rev-list|describe|ls-files|ls-tree|cat-file|shortlog|reflog|stash\s+list|tag(\s+-l|\s+--list)?|for-each-ref|show-ref|show-branch|name-rev|merge-base|count-objects|config\s+--(get|list)|whatchanged|grep)\b/,
  /^(node|npm|npx|yarn|pnpm|bun)\s+(--version|-v|list|ls|why|outdated|view|info|run\s+lint|run\s+test|test)\b/,
  /^(python3?|pip3?|ruby|gem|cargo|go|rustc|java|javac|kotlin|clang|gcc|deno)\s+(--version|-v|version|--help|-h)\b/,
  /^(cargo|go)\s+(check|vet|fmt\s+--check|clippy)\b/,
  // syntax-check only (parses, never executes/writes) — safe on any file.
  /^node\s+(--check|-c)\b/,
  /^python3?\s+(-m\s+py_compile|-m\s+compileall\s+-q)\b/,
  /^(ruby|perl)\s+-c\b/,
  /^php\s+-l\b/,
  /^(xcodebuild|swift|swiftc)\b[^\n]*\bbuild\b/,                    // building is free
  /^xcodebuild\s+(-list|-showsdks|-showBuildSettings|-version)\b/,
  /^xcrun\s+(simctl|xctrace|devicectl)\s+(list|help)\b/,           // querying devices is free
  /^xcrun\s+(--find|--sdk|--show-sdk-path|--version)\b/,
  /^xcrun\s+devicectl\s+device\s+install\b/,                       // copying the build to the
    // phone is free (no side effect on the running app); LAUNCHING it still asks —
    // see "xcrun devicectl device process ..." which is intentionally NOT matched here.
  /^(cd|pushd|popd)\b/,                                             // navigation only
  // building / compiling / running the project's own build+test scripts is free —
  // it only produces artifacts under the repo (never installs deps or touches git).
  /^make\s+.*\b(build|test|check|lint|all)\b/,                     // bare "make" (default target) still asks
  /^(cargo)\s+(build|test|run)\b/,
  /^go\s+(build|test|run)\b/,
  /^(tsc|webpack|vite|rollup|esbuild|parcel)\b/,
  /^(gradle|gradlew|\.\/gradlew)\s+(build|test|assemble|check)\b/,
  /^mvn\b[^\n]*\b(compile|test|package|verify)\b/,
  /^(node|npm|npx|yarn|pnpm|bun)\s+(run\s+)?(build|dev|start|test|typecheck|type-check|lint)\b/,
  /^swift\s+test\b/,
  // read-only network fetch — no upload, no piping into a shell (those are still
  // caught by MUTATING / DANGEROUS below).
  /^curl\b/, /^wget\b/, /^http(ie)?\b/,
];
// Filesystem-mutating COMMANDS — matched only when they're the command WORD being run
// (start of the segment, after leading VAR= assignments are stripped), NOT anywhere in
// the line. Anchoring matters: a bare /\bln\b/ would wrongly fire on `grep -ln`, /\bcp\b/
// on a `cp` search term, /\btee\b/ on `grep tee`, etc. As the child of a runner
// (xargs/command/…) they're still caught, because the recursive check re-anchors on the
// child command.
const MUTATING_CMD = /^(mv|cp|rm|mkdir|rmdir|touch|ln|chmod|chown|chgrp|unlink|install|tee|truncate|dd|shred)\b/;
// Mutations recognised by a fuller pattern (subcommand, flag, or redirect) — specific
// enough to test anywhere in the segment without false-positiving on an argument.
const MUTATING_ANY = [
  /\bsed\b[^|;&]*\s-i\b/, /\bperl\b[^|;&]*\s-i\b/,
  /\bgit\s+(add|commit|checkout|reset|rebase|merge|pull|fetch|clone|apply|am|mv|rm|restore|switch|cherry-pick|revert|push|clean|init|tag\s+(?!-l|--list))\b/,
  /\b(npm|yarn|pnpm|bun)\s+(install|i|ci|add|remove|uninstall|update|upgrade|link|publish)\b/,
  /\bpip3?\s+(install|uninstall)\b/, /\b(gem|cargo|go)\s+(install|publish)\b/,
  /\bdefaults\s+write\b/, /\blaunchctl\b/, /\bkill(all)?\b/, /\bpkill\b/,
  />{1,2}(?!\s*\/dev\/null)(?!&)/, // output redirect that writes to a file (not fd-dup like 2>&1)
  /\bcurl\b[^|;&\n]*(-o\b|--output\b|-O\b|--remote-name\b|-X\s*(POST|PUT|PATCH|DELETE)|--upload-file)/i,
  /\bwget\b[^|;&\n]*(-O\b|--output-document\b)/i,
  /\bfind\b[^|;&\n]*\s-(delete|exec|execdir|fprint|fprintf|fls|ok|okdir)\b/, // find that runs/deletes
];

// Mask quoted regions (keep length) so a pipe/`&&` INSIDE quotes — e.g. grep -E 'a|b'
// — is not mistaken for a pipeline separator.
function maskQuotes(s) {
  let out = "", q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { out += (c === q ? c : "X"); if (c === q) q = null; }
    else if (c === '"' || c === "'" || c === "`") { q = c; out += c; }
    else out += c;
  }
  return out;
}
// Recursively walks `s` from index `i`, matching real shell quoting: single quotes are
// fully literal; double quotes may contain $(...) — which starts a FRESH, independent
// quote-tracking context (so a nested "..." inside a substitution does NOT prematurely
// close an outer double quote it happens to sit inside) and respect backslash-escapes
// (\" \\ etc, so an escaped quote doesn't end the string early); backtick spans are
// opaque; $(...)/<(...) nest to any depth. Calls `onChar(idx, ch)` for every character
// that is genuinely TOP-LEVEL (not inside any quote/substitution) and `onSub(start,end)`
// for every top-level $(...) span's inner [start,end) range. When `inParen`, returns the
// index of the matching unquoted ")"; otherwise returns s.length.
function walk(s, i, inParen, onChar, onSub) {
  while (i < s.length) {
    const c = s[i];
    if (inParen && c === ")") return i;
    if (c === "'") {
      i++; while (i < s.length && s[i] !== "'") i++;
      if (i < s.length) i++;
      continue;
    }
    if (c === '"') {
      i++;
      while (i < s.length && s[i] !== '"') {
        if (s[i] === "\\" && i + 1 < s.length) { i += 2; continue; }
        if (s[i] === "$" && s[i + 1] === "(") {
          const innerStart = i + 2;
          const innerEnd = walk(s, innerStart, true, null, null);
          if (onSub) onSub(innerStart, innerEnd);
          i = innerEnd + 1;
          continue;
        }
        i++;
      }
      if (i < s.length) i++;
      continue;
    }
    if (c === "`") {
      i++; while (i < s.length && s[i] !== "`") i++;
      if (i < s.length) i++;
      continue;
    }
    if ((c === "$" || c === "<") && s[i + 1] === "(") {
      const innerStart = i + 2;
      const innerEnd = walk(s, innerStart, true, null, null);
      if (c === "$" && onSub) onSub(innerStart, innerEnd);
      i = innerEnd + 1;
      continue;
    }
    if (onChar) onChar(i, c);
    i++;
  }
  return i;
}
// Mask every character that is inside a quote or a $(...)/<(...) span, so only
// TOP-LEVEL pipeline separators survive for splitSegments to find.
function maskGroups(s) {
  const keep = new Array(s.length).fill(false);
  walk(s, 0, false, (idx) => { keep[idx] = true; }, null);
  let out = "";
  for (let i = 0; i < s.length; i++) out += keep[i] ? s[i] : "X";
  return out;
}
// Raw inner text of every top-level $(...) command substitution in `s` (one written
// literally inside single quotes is skipped — bash doesn't expand it there).
function extractSubstitutions(s) {
  const out = [];
  walk(s, 0, false, null, (start, end) => out.push(s.slice(start, end)));
  return out;
}
// Replace every top-level $(...) span (delimiters included) with a neutral placeholder
// so the surrounding command can be pattern-matched normally; the substitution's own
// safety was already checked (recursively) by the caller before this is used.
function stripSubstitutions(s) {
  const cuts = [];
  walk(s, 0, false, null, (start, end) => cuts.push([start - 2, end + 1]));
  if (!cuts.length) return s;
  let out = "", pos = 0;
  for (const [a, b] of cuts) { out += s.slice(pos, a) + "SUBOK"; pos = b; }
  out += s.slice(pos);
  return out;
}
function splitSegments(cmd) {
  // Join backslash-newline line continuations FIRST — a multi-line command written
  // for readability (xcodebuild with one flag per line, "\" at end-of-line) is one
  // logical command, not several piped/sequential ones.
  const joined = cmd.replace(/\\\r?\n[ \t]*/g, " ");
  const masked = maskGroups(joined); // hide separators inside quotes AND $(...)/<(...)
  const re = /\|\||&&|;|\||\n/g;
  const segs = []; let start = 0, m;
  while ((m = re.exec(masked))) { segs.push(joined.slice(start, m.index)); start = m.index + m[0].length; }
  segs.push(joined.slice(start));
  return segs.map((x) => x.trim()).filter((x) => x.length);
}
// A segment that's ONLY one or more "VAR=value" assignments (nothing left to run) has
// no side effect on its own — e.g. `f=$(...)` or `x=5`. An assignment PREFIXING a real
// command (`NODE_ENV=production npm run build`) is not this — it falls through to the
// normal prefix-stripped SAFE_BASH check below.
const PURE_ASSIGNMENT = /^(?:export\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s*)+$/;
function stripLeadingAssignments(s) {
  return s.replace(/^(?:export\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+/, "");
}
// Command PREFIXES that just run ANOTHER command — the real safety is the child, not the
// wrapper word. Return the child command string ("" if the wrapper runs nothing on its
// own, e.g. bare `env`/`xargs`), or null if `s` isn't one of these wrappers.
//   xargs [opts] CHILD...          (`find | xargs grep` safe; `find | xargs rm` not)
//   command|builtin|nohup|time CHILD
//   nice [-n N] CHILD  ·  stdbuf -oL CHILD  ·  env [-i][-u N][VAR=v]... CHILD
const XARGS_OPT_WITH_ARG = /^(-n|-P|-L|-s|-I|-J|-E|-e|-d|-a|--max-args|--max-procs|--max-lines|--replace|--delimiter|--arg-file|--eof)$/;
function runnerChild(s) {
  const sp = s.indexOf(" ");
  const head = sp < 0 ? s : s.slice(0, sp);
  const rest = sp < 0 ? "" : s.slice(sp + 1).trim();
  switch (head) {
    case "xargs": {
      const toks = s.split(/\s+/);
      let i = 1;
      while (i < toks.length) {
        const t = toks[i];
        if (t === "--") { i++; break; }
        if (t.startsWith("--") && t.includes("=")) { i++; continue; } // --replace=R
        if (XARGS_OPT_WITH_ARG.test(t)) { i += 2; continue; }         // option consumes next token
        if (t.startsWith("-")) { i++; continue; }                     // bundled no-arg flag(s)
        break;                                                        // first non-flag token = child
      }
      return toks.slice(i).join(" ");
    }
    case "command": case "builtin": case "nohup": case "time":
      return rest.replace(/^-[pvV]\s+/, ""); // e.g. `command -p grep ...`
    case "nice":
      return rest.replace(/^(-n\s+\S+\s+|-\d+\s+)/, "");
    case "stdbuf":
      return rest.replace(/^(-\S+\s+)*/, "");
    case "env":
      return rest.replace(/^(-i\s+|-[uS]\s+\S+\s+|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*/, "");
    default:
      return null;
  }
}
function segmentIsSafe(seg, cfg, depth) {
  if (!seg) return true;
  if ((depth || 0) > 8) return false; // guard against pathological nesting
  if (/`|<\(/.test(maskQuotes(seg))) return false; // backticks / process-substitution: stay conservative
  const subs = extractSubstitutions(seg);
  for (const inner of subs) {
    if (!bashIsAutoSafe(inner, cfg, (depth || 0) + 1)) return false; // substituted command must itself be safe
  }
  const outer = subs.length ? stripSubstitutions(seg) : seg;
  const maskedOuter = maskQuotes(outer);
  if (MUTATING_ANY.some((re) => re.test(maskedOuter))) return false;
  if (PURE_ASSIGNMENT.test(outer.trim())) return true; // e.g. f=$(...) with nothing else to run
  const stripped = stripLeadingAssignments(outer).trim();
  // Prefix-runner (xargs/command/env/…): safety is determined by the CHILD command.
  const child = runnerChild(stripped);
  if (child !== null) {
    if (child === "") return true;                       // bare wrapper (env/xargs alone) is read-only
    return bashIsAutoSafe(child, cfg, (depth || 0) + 1); // safe iff the child command is safe
  }
  // A filesystem-mutating command WORD (rm/cp/mv/ln/tee/…) at the command position.
  if (MUTATING_CMD.test(stripped)) return false;
  if (SAFE_BASH.some((re) => re.test(stripped))) return true;
  for (const p of cfg.auto_allow) { if (p && seg.includes(p)) return true; }
  return false;
}
function bashIsAutoSafe(cmd, cfg, depth) {
  // user auto_allow substrings may match the whole command (e.g. "xcrun simctl ...")
  for (const p of cfg.auto_allow) { if (p && cmd.includes(p)) return true; }
  const segs = splitSegments(cmd);
  return segs.length > 0 && segs.every((seg) => segmentIsSafe(seg, cfg, depth));
}

// ---------- output helpers ----------------------------------------------------
function emit(decision, reason, updatedInput) {
  const hso = { hookEventName: "PreToolUse", permissionDecision: decision };
  if (reason) hso.permissionDecisionReason = reason;
  if (updatedInput) hso.updatedInput = updatedInput;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: hso }));
  process.exit(0);
}
function passthrough() { process.exit(0); } // no output -> Claude's normal permission flow

function jobLabel(toolName, input) {
  if (toolName === "Bash") return "run  " + String(input.command || "").replace(/\s+/g, " ").slice(0, 200);
  if (toolName === "Edit" || toolName === "Write" || toolName === "MultiEdit" || toolName === "NotebookEdit")
    return toolName + "  " + (input.file_path || input.notebook_path || "");
  return toolName;
}

// ---------- open the controlling terminal, if this is a real tty session ------
function openTty() {
  try {
    const fd = fs.openSync("/dev/tty", "r+");
    if (!tty.isatty(fd)) { try { fs.closeSync(fd); } catch (_) {} return -1; }
    return fd;
  } catch (_) { return -1; }
}

// ---------- phone-only routing (mobile/auto modes, or "both" without a tty) ----
function routeToPhone(job, timeoutMs) {
  let done = false;
  const finish = (fn) => { if (!done) { done = true; fn(); } };
  const effectiveTimeout = timeoutMs == null ? ROUTE_TIMEOUT_MS : timeoutMs;
  const timer = effectiveTimeout > 0
    ? setTimeout(() => finish(() => emit("ask", "Vibe: no response from your phone — approve here.")), effectiveTimeout)
    : null;
  if (timer && timer.unref) timer.unref();
  let buf = "";
  const conn = net.createConnection(SOCK, () => {
    conn.write(JSON.stringify({ type: "command", cwd: job.cwd, source: "hook", sessionId: job.sessionId || "", tool_name: job.toolName, input: job.input }) + "\n");
  });
  conn.setEncoding("utf8");
  conn.on("data", (d) => {
    buf += d; const nl = buf.indexOf("\n"); if (nl < 0) return;
    let parsed = null; try { parsed = JSON.parse(buf.slice(0, nl)); } catch (_) {}
    try { conn.end(); } catch (_) {}
    if (timer) clearTimeout(timer);
    const ans = (parsed && parsed.answer) || {};
    const decision = String(ans.decision || ans.action || "").toLowerCase();
    if (decision === "approve" || decision === "allow") finish(() => emit("allow", ans.message || "Approved from phone.", ans.updatedInput));
    else if (decision === "deny" || decision === "skip") finish(() => emit("deny", ans.message || (decision === "skip" ? "Skipped from your phone." : "Denied from your phone.")));
    else finish(() => emit("ask", "Vibe: no clear decision — approve here."));
  });
  conn.on("error", () => { if (timer) clearTimeout(timer); finish(() => emit("ask", "Vibe bridge unreachable — approve here.")); });
  conn.on("close", () => { if (timer) clearTimeout(timer); finish(() => emit("ask", "Vibe: connection closed — approve here.")); });
}

// ---------- BOTH: race the desk (/dev/tty keypress) and the phone -------------
// First responder wins. If the phone is unreachable we keep waiting on the desk;
// if there's no tty at all the caller uses routeToPhone / a local prompt instead.
function raceDeskAndPhone(job, ttyFd) {
  let done = false;
  let ttyIn = null, conn = null;
  const cleanup = () => {
    try { if (ttyIn) { ttyIn.setRawMode(false); ttyIn.pause(); ttyIn.destroy(); } } catch (_) {}
    try { fs.closeSync(ttyFd); } catch (_) {}
    try { if (conn) conn.destroy(); } catch (_) {}
  };
  const finish = (decision, reason, updatedInput) => {
    if (done) return; done = true;
    if (decision === "allow" || decision === "deny") {
      try { fs.writeSync(ttyFd, `\r\n\x1b[36m[Vibe]\x1b[0m ${decision === "allow" ? "approved" : "denied"}\r\n`); } catch (_) {}
    }
    cleanup();
    emit(decision, reason, updatedInput);
  };

  // desk side
  try { fs.writeSync(ttyFd, `\r\n\x1b[36m[Vibe]\x1b[0m approve  ${job.label}\r\n  \x1b[32my\x1b[0m = allow   \x1b[31mn\x1b[0m = deny   (or answer on your phone)\r\n`); } catch (_) {}
  try {
    ttyIn = new tty.ReadStream(ttyFd);
    ttyIn.setRawMode(true);
    ttyIn.setEncoding("utf8");
    ttyIn.on("data", (s) => {
      const ch = String(s).toLowerCase();
      if (ch.indexOf("y") >= 0) finish("allow", "Approved at the desk.");
      else if (ch.indexOf("n") >= 0) finish("deny", "Denied at the desk.");
      else if (ch === "\x03" || ch === "\x1b") finish("deny", "Cancelled at the desk.");
    });
    ttyIn.on("error", () => {});
  } catch (_) {}

  // phone side
  let buf = "";
  conn = net.createConnection(SOCK, () => {
    conn.write(JSON.stringify({ type: "command", cwd: job.cwd, source: "hook-both", sessionId: job.sessionId || "", tool_name: job.toolName, input: job.input }) + "\n");
  });
  conn.setEncoding("utf8");
  conn.on("data", (d) => {
    buf += d; const nl = buf.indexOf("\n"); if (nl < 0) return;
    let parsed = null; try { parsed = JSON.parse(buf.slice(0, nl)); } catch (_) {}
    const ans = (parsed && parsed.answer) || {};
    const decision = String(ans.decision || ans.action || "").toLowerCase();
    if (decision === "approve" || decision === "allow") finish("allow", ans.message || "Approved from phone.", ans.updatedInput);
    else if (decision === "deny" || decision === "skip") finish("deny", ans.message || (decision === "skip" ? "Skipped from your phone." : "Denied from your phone."));
  });
  // phone gone: don't give up — the desk can still answer.
  conn.on("error", () => {});
  conn.on("close", () => {});

  if (ROUTE_TIMEOUT_MS > 0) {
    const timer = setTimeout(() => finish("ask", "Vibe: no response — approve here."), ROUTE_TIMEOUT_MS);
    if (timer.unref) timer.unref();
  }
}

// ---------- main --------------------------------------------------------------
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  let ev = null; try { ev = JSON.parse(raw); } catch (_) {}
  if (!ev) return passthrough();

  // Bridge-spawned runs already gate via --permission-prompt-tool; don't double up.
  if (process.env.VIBE_ASK_CHAT) return passthrough();

  const cfg = readConfig();
  const mode = String(cfg.approval_mode || "local").toLowerCase();
  const toolName = ev.tool_name || "";
  const input = ev.tool_input || {};
  const cwd = ev.cwd || process.cwd();
  const cmd = toolName === "Bash" ? String(input.command || "") : "";

  // 1) LOCAL: approve/answer on this device only. Pure pass-through.
  if (mode === "local") return passthrough();

  // 2) Always-blocked destructive commands (denied even in full access).
  if (cmd && isDangerous(cmd)) {
    return emit("deny", "Vibe: this command is on the always-blocked list (destructive) — not allowed even in full access.");
  }
  if (cmd && cfg.deny.some((p) => p && cmd.includes(p))) {
    return emit("deny", "Vibe: this command matches your configured deny list.");
  }

  // 3) AskUserQuestion: only force the phone (deny native + redirect to the MCP tool)
  //    in "mobile" mode. In auto/both/full the desk is present, so let Claude's native
  //    in-app question render HERE — don't shove every question to the phone.
  if (toolName === "AskUserQuestion") {
    if (mode !== "mobile") return passthrough(); // native question at the desk
    const probe = net.createConnection(SOCK, () => {
      try { probe.end(); } catch (_) {}
      emit("deny", "Use the mcp__vibeask__ask_user tool instead — it delivers your question to the user's phone and returns their answer. Do not use AskUserQuestion here.");
    });
    probe.on("error", () => passthrough());
    return;
  }

  // 4) auto-allow: read-only tools + safe/allow-listed Bash run without asking.
  const readOnly = ["Read", "Glob", "Grep", "NotebookRead", "TodoWrite"].includes(toolName);
  const isEdit = ["Edit", "Write", "MultiEdit", "NotebookEdit"].includes(toolName);
  if (readOnly || isEdit || (toolName === "Bash" && bashIsAutoSafe(cmd, cfg))) {
    return emit("allow", "Vibe auto-approved (safe / allow-listed).");
  }

  // 5) full access: allow everything else (dangerous already denied above).
  if (mode === "full") return emit("allow", "Vibe full-access.");

  // 6) blockers need a human.
  const job = { toolName, input, cwd, sessionId: ev.session_id, label: jobLabel(toolName, input) };
  if (mode === "both") {
    const ttyFd = openTty();
    if (ttyFd >= 0) return raceDeskAndPhone(job, ttyFd); // desk + phone, first wins
    // headless (IDE): a hook can't race Claude's native prompt (returning "ask" ends the
    // hook), so give the phone a short window, then fall back to the native in-app ask.
    return routeToPhone(job, 0);
  }
  // mobile / auto -> phone with local fallback.
  return routeToPhone(job);
});
