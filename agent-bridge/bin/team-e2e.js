#!/usr/bin/env node
/**
 * team-e2e — fire a REAL @team message into a Vibe group from the Mac and
 * monitor the dispatch, so team routing can be tested here instead of from
 * the phone.
 *
 * It connects to the production server as the human user (login_token pulled
 * live from the database via `railway variables` → DATABASE_URL; nothing is
 * written to disk), joins the chat, sends one "message" push shaped like the
 * phone's, then prints every agent-stream / agent-team-worker / message frame
 * until --watch seconds pass.
 *
 * Usage:
 *   node agent-bridge/bin/team-e2e.js --text "@team call all agents and say hi" \
 *        [--chat ccd43b50-2e1] [--watch 90] [--work-mode allow_edits] [--dry-run]
 *
 * NOTE: this consumes real provider turns and the sent message is visible in
 * the group on every device. Keep test prompts one-liners.
 */
"use strict";

const { execFileSync } = require("child_process");
const crypto = require("crypto");
const path = require("path");
const WebSocket = require("ws");

const SERVER = process.env.VIBE_TEST_SERVER || "wss://api.vibegram.io";
const SERVER_DIR = path.resolve(__dirname, "../../server");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const hasFlag = (name) => process.argv.includes(`--${name}`);

const TEXT = arg("text", null);
const CHAT_ID = arg("chat", "ccd43b50-2e1");
const WATCH_S = Number(arg("watch", "90"));
const WORK_MODE = arg("work-mode", "allow_edits"); // mirror the phone's setting; chat teamRole must override it
const REPO_ID = arg("repo", "RhmXHAcFXkzi2FpU"); // Vibe repo (bridge-advertised id)

if (!TEXT) {
  console.error('usage: team-e2e.js --text "@team …" [--chat id] [--watch 90] [--dry-run]');
  process.exit(2);
}

function fetchToken() {
  const vars = JSON.parse(
    execFileSync("railway", ["variables", "--json"], { cwd: SERVER_DIR, encoding: "utf8" })
  );
  const dbUrl = vars.DATABASE_URL;
  if (!dbUrl) throw new Error("DATABASE_URL not in railway variables");
  const row = execFileSync(
    "psql",
    [dbUrl, "-tAc",
      "select login_token from users where id='cfac3a0d-c764-473c-9940-33fca418834a'"],
    { encoding: "utf8" }
  ).trim();
  if (!row) throw new Error("login_token not found");
  return row;
}

const messageId = crypto.randomUUID();
console.log(`[e2e] chat=${CHAT_ID} messageId=${messageId}`);
console.log(`[e2e] text: ${TEXT}`);
if (hasFlag("dry-run")) {
  console.log("[e2e] dry-run: not connecting");
  process.exit(0);
}

// Token rides the query string: the endpoint's connect_info is [:x_headers],
// which only forwards x-* headers, so an `authorization: Bearer` header never
// reaches UserSocket.connect/3. And vsn MUST be exactly "2.0.0" — Phoenix
// rejects any other value with a bare 403 before connect/3 ever runs.
const token = fetchToken();
const ws = new WebSocket(
  `${SERVER}/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(token)}`
);

let ref = 0;
const nextRef = () => String(++ref);
const topic = `chat:${CHAT_ID}`;
let joinRef = null;

function push(event, payload, jr) {
  const r = nextRef();
  ws.send(JSON.stringify([jr || joinRef, r, topic, event, payload]));
  return r;
}

const t0 = Date.now();
const ts = () => `+${((Date.now() - t0) / 1000).toFixed(1)}s`;

ws.on("open", () => {
  console.log(`[e2e] ${ts()} socket open, joining ${topic}`);
  joinRef = nextRef();
  ws.send(JSON.stringify([joinRef, joinRef, topic, "phx_join", {}]));
});

// Phoenix needs heartbeats or the server drops us after ~60s.
const heartbeat = setInterval(() => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}]));
  }
}, 25000);

let sendRef = null;

function summarizeStream(p) {
  const nodes = Array.isArray(p.progressNodes) ? p.progressNodes.length : 0;
  const text = typeof p.text === "string" && p.text.trim() ? ` text=${JSON.stringify(p.text.trim().slice(0, 110))}` : "";
  const status = Array.isArray(p.teamWorkersStatus)
    ? ` workersStatus=[${p.teamWorkersStatus.map((w) => `${w.worker || w.handle}:${w.status}`).join(",")}]`
    : "";
  return (
    `agent=${p.agentUsername || p.agentName} status=${p.status} task=${p.taskId || "?"}` +
    ` teamMode=${p.teamMode || "-"} teamRole=${p.teamRole || "-"} run=${(p.teamRunId || "-").slice(0, 8)}` +
    ` suppress=${p.suppressVisible === true} nodes=${nodes}${status}${text}`
  );
}

ws.on("message", (raw) => {
  let frame;
  try {
    frame = JSON.parse(raw.toString());
  } catch {
    return;
  }
  const [jr, r, top, event, payload] = frame;

  if (event === "phx_reply" && r === joinRef) {
    if (payload.status === "ok") {
      console.log(`[e2e] ${ts()} joined; sending message`);
      sendRef = push("message", {
        id: messageId,
        type: "text",
        timestamp: Date.now(),
        text: TEXT,
        agentText: TEXT,
        // encrypted_content is a required column — without it the user message
        // silently fails persistence and the agent reply then FK-crashes on
        // reply_to_id. This harness can't produce real E2E ciphertext, so the
        // bubble body won't decrypt on devices; textPreview carries the intent.
        encryptedContent: `e2e-harness:${TEXT}`,
        metadata: {
          agentBridgeRepoId: REPO_ID,
          agentBridgeWorkMode: WORK_MODE,
          textPreview: TEXT,
        },
      });
    } else {
      console.error(`[e2e] join failed:`, JSON.stringify(payload));
      process.exit(1);
    }
    return;
  }
  if (event === "phx_reply" && r === sendRef) {
    console.log(`[e2e] ${ts()} send ack: ${payload.status}`);
    return;
  }
  if (event === "agent-stream") {
    console.log(`[e2e] ${ts()} STREAM  ${summarizeStream(payload)}`);
    return;
  }
  if (event === "agent-team-worker") {
    console.log(
      `[e2e] ${ts()} WORKER  ${payload.teamWorker} status=${payload.status} label=${JSON.stringify(payload.lastLabel || "")}`
    );
    return;
  }
  if (event === "agent-activity") {
    console.log(`[e2e] ${ts()} ACT     ${payload.label || payload.text || JSON.stringify(payload).slice(0, 100)}`);
    return;
  }
  if (event === "message") {
    const from = payload.senderUsername || payload.agentUsername || payload.fromId || payload.from_id;
    const body = typeof payload.text === "string" ? payload.text : payload.textPreview || "";
    if (payload.id === messageId) return; // our own echo
    console.log(
      `[e2e] ${ts()} MESSAGE from=${from} type=${payload.type} text=${JSON.stringify(String(body).slice(0, 160))}`
    );
    return;
  }
});

ws.on("close", (code) => {
  console.log(`[e2e] ${ts()} socket closed (${code})`);
  process.exit(0);
});
ws.on("error", (err) => {
  console.error(`[e2e] socket error:`, err.message);
  process.exit(1);
});

setTimeout(() => {
  console.log(`[e2e] ${ts()} watch window over`);
  clearInterval(heartbeat);
  ws.close();
  setTimeout(() => process.exit(0), 500);
}, WATCH_S * 1000);
