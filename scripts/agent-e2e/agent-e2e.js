#!/usr/bin/env node
/**
 * agent-e2e — register, create + publish an isolated agent, open its DM, send it
 * a role + task, then watch it stream/tool-use/approve/ask until it delivers.
 * Wire mechanics mirror agent-bridge/bin/team-e2e.js. Node built-ins + `ws` only.
 *
 * Usage:
 *   node agent-e2e.js [--core URL] [--task "..."] [--role "..."] [--agent-id <reuse>]
 *     [--token <reuse bearer>] [--watch 900] [--model-provider openai] [--model-id <id>]
 *     [--autonomy safe_auto] [--tools computer_run,browser_open,search_google,read_url,ask_user]
 *     [--approve approve|reject] [--answer "text used for any question"] [--out dir]
 */
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const WebSocket = require("ws");

// ── CLI args ─────────────────────────────────────────────────────────────

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}

const DEFAULT_ROLE =
  "You are the marketing lead for Vibe, an end-to-end encrypted messenger " +
  "with built-in AI agents. You have your own computer (bash, python, node, a browser).";

const DEFAULT_TASK =
  "Research how Signal and Telegram describe security on their public websites, " +
  "then write a one-page positioning brief as ~/positioning.md on your computer: " +
  "a 5-row comparison table, 3 tagline options, and a 100-word summary. When done, " +
  "send me the full brief text and show `ls -la ~/positioning.md` and `wc -w ~/positioning.md`.";

const CORE = arg("core", process.env.VIBE_CORE_URL || "http://127.0.0.1:4000").replace(/\/+$/, "");
const TASK = arg("task", DEFAULT_TASK);
const ROLE = arg("role", DEFAULT_ROLE);
const AGENT_ID_REUSE = arg("agent-id", null);
const TOKEN_REUSE = arg("token", null);
const WATCH_S = Number(arg("watch", "900"));
const MODEL_PROVIDER = arg("model-provider", null);
const MODEL_ID = arg("model-id", null);
const AUTONOMY = arg("autonomy", "safe_auto");
const TOOLS = arg("tools", "computer_run,browser_open,search_google,read_url,ask_user")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const APPROVE_ACTION = arg("approve", "approve");
const ANSWER_TEXT = arg("answer", "Use your best judgment and proceed.");
const OUT_DIR = arg("out", path.join(__dirname, "out", new Date().toISOString().replace(/[:.]/g, "-")));

// ── small helpers ────────────────────────────────────────────────────────

const t0 = Date.now();
const ts = () => `+${((Date.now() - t0) / 1000).toFixed(1)}s`;
function log(msg) {
  console.log(`[agent-e2e] ${ts()} ${msg}`);
}
// Never print a secret in full — length + last 4 chars is enough to eyeball reuse.
function mask(secret) {
  if (!secret) return "(none)";
  const s = String(secret);
  return `${s.length}chars,...${s.slice(-4)}`;
}
function mimeExt(mime) {
  if (!mime) return "jpg";
  if (mime.includes("png")) return "png";
  if (mime.includes("jpeg") || mime.includes("jpg")) return "jpg";
  return "bin";
}
function toWsUrl(coreUrl) {
  return coreUrl.replace(/^http/, "ws");
}

// ── REST helpers ─────────────────────────────────────────────────────────

async function api(method, urlPath, { token, body } = {}) {
  const headers = { "content-type": "application/json" };
  if (token) headers["authorization"] = `Bearer ${token}`;
  const res = await fetch(`${CORE}${urlPath}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, ok: res.ok, json, text };
}

async function register() {
  const rand = crypto.randomBytes(4).toString("hex");
  const username = `e2e_${rand}`;
  const password = crypto.randomBytes(12).toString("base64url");
  const body = {
    username,
    password,
    deviceId: `e2e-device-${rand}`,
    // Opaque placeholders — this harness does not do real E2E crypto (see team-e2e.js).
    publicKey: crypto.randomBytes(32).toString("base64"),
    encryptedPrivateKey: crypto.randomBytes(64).toString("base64"),
    identityKey: "v3",
  };
  const res = await api("POST", "/api/register", { body });
  if (!res.ok) throw new Error(`register failed: ${res.status} ${res.text}`);
  return { userId: res.json.userId, token: res.json.token, username: res.json.username };
}

async function createAgent(token) {
  // Agent usernames are derived from the display name and are NOT auto-deduped,
  // so a fixed name collides on a second run — suffix it to stay repeatable.
  const suffix = Math.random().toString(36).slice(2, 7);
  const body = {
    display_name: `E2E Marketer ${suffix}`,
    system_prompt: ROLE,
    enabled_tools: TOOLS,
    output_modes: ["text"],
    autonomy_mode: AUTONOMY,
  };
  if (MODEL_PROVIDER) body.model_provider = MODEL_PROVIDER;
  if (MODEL_ID) body.model_id = MODEL_ID;
  const res = await api("POST", "/api/agents", { token, body });
  if (!res.ok) throw new Error(`create agent failed: ${res.status} ${JSON.stringify(res.json || res.text)}`);
  return res.json; // {agent, secret}
}

async function updateExecutionMode(token, agentId) {
  const res = await api("PUT", `/api/agents/${agentId}`, { token, body: { execution_mode: "isolated" } });
  if (!res.ok) throw new Error(`set execution_mode failed: ${res.status} ${JSON.stringify(res.json || res.text)}`);
  return res.json;
}

async function publishAgent(token, agentId) {
  const res = await api("POST", `/api/agents/${agentId}/publish`, { token, body: {} });
  if (!res.ok) throw new Error(`publish failed: ${res.status} ${JSON.stringify(res.json || res.text)}`);
  return res.json;
}

async function getAgent(token, agentId) {
  const res = await api("GET", `/api/agents/${agentId}`, { token });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`get agent failed: ${res.status} ${JSON.stringify(res.json || res.text)}`);
  return res.json;
}

async function fetchComputerPreview(token, agentId) {
  return api("GET", `/api/agents/${agentId}/computer/preview`, { token });
}

async function claimDecision(token, actionToken) {
  return api("POST", "/api/decisions/actions", { token, body: { token: actionToken } });
}

// ── run state ────────────────────────────────────────────────────────────

const state = {
  token: null,
  agentId: null,
  agentUserId: null,
  chatId: null,
  runIds: new Set(),
  frameCounts: {},
  approvals: [],
  asks: [],
  previewCount: 0,
  deliveryCount: 0,
  terminalStatus: null,
  nodeStatus: new Map(), // progress-node id -> last printed status
  lastPrintedTextLen: 0,
  pendingDecisionMessages: new Map(), // messageId -> "message" payload
  finished: false,
  startedAt: Date.now(),
};

const TERMINAL_RUN_STATES = new Set(["completed", "failed", "cancelled"]);
const bump = (name) => (state.frameCounts[name] = (state.frameCounts[name] || 0) + 1);

let ws = null;
let TOPIC = null;
let joinRef = null;
let refCounter = 0;
const nextRef = () => String(++refCounter);
function push(event, payload) {
  const r = nextRef();
  ws.send(JSON.stringify([joinRef, r, TOPIC, event, payload]));
  return r;
}

let heartbeatTimer = null;
let graceTimer = null;
let watchTimer = null;
let previewPollTimer = null;
let reconnectUsed = false;
let sentTask = false;
let sawStreamDone = false;
let computerPreviewCount = 0;
let sendMsgRef = null;

function sendTaskMessage() {
  const id = crypto.randomUUID();
  sendMsgRef = push("message", {
    id,
    type: "text",
    timestamp: Date.now(),
    text: TASK,
    agentText: TASK,
    // No real E2E keys here (see team-e2e.js), so the bubble body won't decrypt on
    // devices — textPreview carries the intent for anyone watching live.
    encryptedContent: `e2e-harness:${TASK}`,
    metadata: { textPreview: TASK.slice(0, 160) },
  });
  log(`sent task message id=${id}`);
}

function printTextDelta(text) {
  if (typeof text !== "string" || text.length <= state.lastPrintedTextLen) return;
  const delta = text.slice(state.lastPrintedTextLen);
  state.lastPrintedTextLen = text.length;
  if (delta.trim()) log(`  text+= ${JSON.stringify(delta.slice(0, 200))}`);
}

function printProgressDiff(nodes) {
  for (const n of nodes || []) {
    if (state.nodeStatus.get(n.id) !== n.status) {
      state.nodeStatus.set(n.id, n.status);
      log(`  progress: ${n.label} [${n.status}]`);
    }
  }
}

function handleStreamFrame(payload) {
  bump("agent-stream");
  if (payload.runId) state.runIds.add(payload.runId);
  log(`STREAM status=${payload.status} run=${(payload.runId || "").slice(0, 8)}`);
  printTextDelta(payload.text);
  printProgressDiff(payload.progressNodes);

  // finish_run always emits agent-stream(done) + agent-run-state together; give the
  // paired run-state frame a short grace window so terminalStatus is the real outcome.
  if (payload.status === "done") {
    sawStreamDone = true;
    if (!state.terminalStatus) {
      clearTimeout(graceTimer);
      graceTimer = setTimeout(() => {
        if (!state.finished) finish("stream_done_grace_expired");
      }, 3000);
    }
  }
}

function handleRunStateFrame(payload) {
  bump("agent-run-state");
  if (payload.runId) state.runIds.add(payload.runId);
  log(`RUN-STATE status=${payload.status}${payload.reason ? ` reason=${payload.reason}` : ""}`);
  if (TERMINAL_RUN_STATES.has(payload.status)) {
    state.terminalStatus = payload.status;
    clearTimeout(graceTimer);
    finish("run_state_terminal");
  }
}

function waitForDecisionMessage(messageId, decisionId, timeoutMs) {
  return new Promise((resolve) => {
    const deadline = Date.now() + timeoutMs;
    (function poll() {
      const found =
        state.pendingDecisionMessages.get(messageId) ||
        [...state.pendingDecisionMessages.values()].find((m) => m.metadata && m.metadata.decisionId === decisionId);
      if (found || Date.now() > deadline) return resolve(found || null);
      setTimeout(poll, 100);
    })();
  });
}

async function handleApprovalFrame(payload) {
  bump("agent-approval");
  log(`APPROVAL decisionId=${payload.decisionId} kind=${payload.kind} title=${JSON.stringify(payload.title)}`);

  const msg = await waitForDecisionMessage(payload.messageId, payload.decisionId, 5000);
  if (!msg) {
    log(`  WARN: decision message ${payload.messageId} never arrived — cannot read action tokens`);
    state.approvals.push({ decisionId: payload.decisionId, action: null, status: "token_not_found" });
    return;
  }

  const actions = (msg.metadata && msg.metadata.service && msg.metadata.service.decision && msg.metadata.service.decision.actions) || [];
  let action = actions.find((a) => a.id === APPROVE_ACTION);
  if (!action && payload.kind === "permission") {
    // permission decisions use allow_once/allow_run/deny, not approve/reject.
    const fallback = APPROVE_ACTION === "reject" ? "deny" : "allow_once";
    action = actions.find((a) => a.id === fallback) || actions.find((a) => a.id === "allow_run");
  }
  if (!action) {
    log(`  WARN: no action matching "${APPROVE_ACTION}" among [${actions.map((a) => a.id).join(",")}]`);
    state.approvals.push({ decisionId: payload.decisionId, action: null, status: "no_matching_action" });
    return;
  }

  const res = await claimDecision(state.token, action.token);
  const status = res.ok ? "claimed" : (res.json && res.json.error) || String(res.status);
  log(`  claimed action=${action.id} -> ${status}`);
  state.approvals.push({ decisionId: payload.decisionId, action: action.id, status });
}

function handleAskFrame(payload) {
  bump("agent-bridge-ask");
  const questions = (payload.ask && payload.ask.questions) || [];
  log(`ASK requestId=${payload.requestId}`);
  for (const q of questions) log(`  Q: ${q.header ? `[${q.header}] ` : ""}${q.question}`);
  state.asks.push({ requestId: payload.requestId, questions, answer: ANSWER_TEXT });

  push("agent-bridge-ask-response", {
    requestId: payload.requestId,
    runId: payload.runId,
    decision: "answer",
    answer: ANSWER_TEXT,
  });
  log(`  answered: ${JSON.stringify(ANSWER_TEXT)}`);
}

function handlePreviewFrame(payload) {
  bump("agent-preview");
  state.previewCount++;
  const file = path.join(OUT_DIR, `preview-${state.previewCount}.${mimeExt(payload.mime)}`);
  try {
    fs.writeFileSync(file, Buffer.from(payload.imageBase64 || "", "base64"));
    log(`PREVIEW saved ${file} (${payload.label || ""} ${payload.width}x${payload.height})`);
  } catch (e) {
    log(`  WARN: failed to save preview: ${e.message}`);
  }
}

// Real deliveries are Output-typed (text/image/file/music); "system" carries
// decision prompts and "question" duplicates the agent-bridge-ask frame.
const DELIVERY_TYPES = new Set(["text", "image", "file", "music"]);

function handleMessageFrame(payload) {
  bump("message");
  if (payload.type === "system" && payload.metadata && payload.metadata.status === "pending_decision") {
    state.pendingDecisionMessages.set(payload.id, payload);
    log(`MESSAGE(pending_decision) id=${payload.id} decisionId=${payload.metadata.decisionId}`);
    return;
  }
  if (payload.fromId === state.agentUserId && DELIVERY_TYPES.has(payload.type)) {
    const text = payload.plaintext || payload.plainContent || (payload.metadata && payload.metadata.text) || "";
    state.deliveryCount++;
    log(`DELIVERY #${state.deliveryCount} type=${payload.type} len=${text.length}`);
    fs.appendFileSync(
      path.join(OUT_DIR, "deliveries.md"),
      `\n## Delivery ${state.deliveryCount} (type=${payload.type}, ${new Date().toISOString()})\n\n${text}\n`
    );
  }
}

function handleFrame(raw) {
  let frame;
  try {
    frame = JSON.parse(raw.toString());
  } catch {
    return;
  }
  const [, r, , event, payload] = frame;

  if (event === "phx_reply" && r === joinRef) {
    if (payload.status === "ok") {
      log(`joined ${TOPIC}`);
      if (!sentTask) {
        sentTask = true;
        sendTaskMessage();
      }
    } else {
      log(`JOIN FAILED: ${JSON.stringify(payload)}`);
      finish("join_failed");
    }
    return;
  }

  if (event === "phx_reply" && r === sendMsgRef) {
    if (payload.status !== "ok") log(`  WARN: task message send failed: ${JSON.stringify(payload)}`);
    return;
  }

  switch (event) {
    case "agent-stream":
      return handleStreamFrame(payload);
    case "agent-run-state":
      return handleRunStateFrame(payload);
    case "agent-approval":
      handleApprovalFrame(payload).catch((e) => log(`  approval handling error: ${e.message}`));
      return;
    case "agent-bridge-ask":
      return handleAskFrame(payload);
    case "agent-preview":
      return handlePreviewFrame(payload);
    case "message":
      return handleMessageFrame(payload);
    default:
      if (event) bump(event);
  }
}

function openSocket() {
  ws = new WebSocket(`${toWsUrl(CORE)}/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(state.token)}`);

  ws.on("open", () => {
    joinRef = nextRef();
    ws.send(JSON.stringify([joinRef, joinRef, TOPIC, "phx_join", {}]));
    clearInterval(heartbeatTimer);
    heartbeatTimer = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}]));
    }, 25000);
  });
  ws.on("message", handleFrame);
  ws.on("error", (err) => log(`socket error: ${err.message}`));
  ws.on("close", (code) => {
    clearInterval(heartbeatTimer);
    if (state.finished) return;
    if (!reconnectUsed) {
      reconnectUsed = true;
      log(`socket closed (code=${code}); reconnecting once in 1s...`);
      setTimeout(openSocket, 1000);
    } else {
      log(`socket closed (code=${code}) after the one reconnect — waiting for --watch to expire`);
    }
  });
}

function startComputerPreviewPolling() {
  previewPollTimer = setInterval(async () => {
    try {
      const res = await fetchComputerPreview(state.token, state.agentId);
      if (res.ok && res.json && res.json.imageBase64) {
        computerPreviewCount++;
        const file = path.join(OUT_DIR, `computer-${computerPreviewCount}.${mimeExt(res.json.mime)}`);
        fs.writeFileSync(file, Buffer.from(res.json.imageBase64, "base64"));
        log(`COMPUTER preview saved ${file}`);
      } else {
        log(`COMPUTER preview: status=${res.status} keys=${JSON.stringify(Object.keys(res.json || {}))}`);
      }
    } catch (e) {
      log(`COMPUTER preview poll error: ${e.message}`);
    }
  }, 20000);
}

function finish(reason) {
  if (state.finished) return;
  state.finished = true;
  clearTimeout(watchTimer);
  clearTimeout(graceTimer);
  clearInterval(heartbeatTimer);
  clearInterval(previewPollTimer);
  try {
    if (ws) ws.close();
  } catch {}

  const terminalStatus = state.terminalStatus || (sawStreamDone ? "done" : null);
  const summary = {
    agentId: state.agentId,
    chatId: state.chatId,
    runIds: [...state.runIds],
    frames: state.frameCounts,
    approvals: state.approvals,
    asks: state.asks,
    previews: state.previewCount,
    deliveries: state.deliveryCount,
    durationMs: Date.now() - state.startedAt,
    terminalStatus,
    finishReason: reason,
  };
  fs.writeFileSync(path.join(OUT_DIR, "summary.json"), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary, null, 2));

  const ok = state.deliveryCount >= 1 && (terminalStatus === "done" || terminalStatus === "completed");
  log(`exit ${ok ? 0 : 1} (deliveries=${state.deliveryCount}, terminalStatus=${terminalStatus})`);
  process.exit(ok ? 0 : 1);
}

process.on("SIGINT", () => {
  log("SIGINT received");
  finish("sigint");
});

// ── main ─────────────────────────────────────────────────────────────────

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  log(`core=${CORE} out=${OUT_DIR}`);

  let token = TOKEN_REUSE;
  if (!token) {
    const reg = await register();
    token = reg.token;
    log(`registered user=${reg.username} id=${reg.userId} token=${mask(token)}`);
  } else {
    log(`reusing provided token=${mask(token)}`);
  }

  let agent;
  if (AGENT_ID_REUSE) {
    agent = await getAgent(token, AGENT_ID_REUSE);
    if (!agent) throw new Error(`--agent-id ${AGENT_ID_REUSE} not found for this token`);
    if (agent.executionMode !== "isolated") agent = await updateExecutionMode(token, agent.id);
    if (agent.status !== "published") agent = await publishAgent(token, agent.id);
  } else {
    const created = await createAgent(token);
    log(`created agent id=${created.agent.id} username=${created.agent.username} secret=${mask(created.secret)}`);
    agent = await updateExecutionMode(token, created.agent.id);
    agent = await publishAgent(token, agent.id);
  }

  log(`agent id=${agent.id} username=${agent.username} status=${agent.status} executionMode=${agent.executionMode}`);
  log(`enabledTools (server-persisted)=${JSON.stringify(agent.enabledTools)}`);
  for (const t of ["computer_run", "browser_open"]) {
    if (TOOLS.includes(t) && !(agent.enabledTools || []).includes(t)) {
      log(`  WARN: requested tool "${t}" was NOT persisted (Vibe.AI.ToolRegistry does not list it yet) — that capability will be OFF this run`);
    }
  }

  if (!agent.defaultDestinationChatId) throw new Error("agent has no defaultDestinationChatId (owner DM was not created)");

  state.token = token;
  state.agentId = agent.id;
  state.agentUserId = agent.userId;
  state.chatId = agent.defaultDestinationChatId;
  TOPIC = `chat:${state.chatId}`;
  log(`chat id=${state.chatId}`);

  startComputerPreviewPolling();
  openSocket();
  watchTimer = setTimeout(() => finish("watch_timeout"), WATCH_S * 1000);
}

main().catch((err) => {
  const detail = err.cause && err.cause.message ? ` (${err.cause.message})` : "";
  console.error(`[agent-e2e] fatal: ${err.message}${detail}`);
  try {
    fs.mkdirSync(OUT_DIR, { recursive: true });
    fs.writeFileSync(
      path.join(OUT_DIR, "summary.json"),
      JSON.stringify({ error: `${err.message}${detail}`, durationMs: Date.now() - state.startedAt }, null, 2)
    );
  } catch {}
  process.exit(1);
});
