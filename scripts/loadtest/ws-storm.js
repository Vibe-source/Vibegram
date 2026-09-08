#!/usr/bin/env node
/**
 * ws-storm.js — opens many Phoenix-channel WebSocket connections against the
 * core server, joins either the seeded group chat or each connection's own DM,
 * holds, and has a subset of connections push "message" frames while every
 * connection measures delivery latency on the resulting broadcast. Mirrors the
 * wire protocol `agent-bridge/bin/team-e2e.js` uses against production.
 *
 * Usage:
 *   node ws-storm.js --seed results/seed-lt.json --conns 2000 --ramp 200 \
 *     --hold 60 --senders 5 --msg-rate 2 [--dm] [--core-url http://127.0.0.1:4000] \
 *     [--metrics-url http://127.0.0.1:9568/metrics] [--beam-pid 12345]
 *
 * Writes results/ws-storm-<label>.json (+ a printed table) and, alongside it,
 * the raw /metrics text sampled before and after the run.
 */
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execSync, spawnSync } = require("child_process");
const WebSocket = require("ws");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}
const hasFlag = (name) => process.argv.includes(`--${name}`);

function usageError(msg) {
  console.error(msg);
  console.error(
    "usage: node ws-storm.js --seed results/seed-lt.json --conns N --ramp 200 --hold 60 --senders 5 --msg-rate 2 [--dm]"
  );
  process.exit(2);
}

const SEED_ARG = arg("seed", null);
const CONNS = parseInt(arg("conns", ""), 10);
const RAMP = parseFloat(arg("ramp", "200")); // connections opened per second
const HOLD = parseFloat(arg("hold", "60")); // seconds after ramp completes
const SENDERS = parseInt(arg("senders", "5"), 10);
const MSG_RATE = parseFloat(arg("msg-rate", "2")); // messages per second, per sender
const DM = hasFlag("dm");
const CORE_URL = (arg("core-url", process.env.VIBE_CORE_URL || "http://127.0.0.1:4000")).replace(/\/$/, "");
const METRICS_URL = arg("metrics-url", "http://127.0.0.1:9568/metrics");
const BEAM_PID_ARG = arg("beam-pid", null);

if (!SEED_ARG) usageError("missing --seed");
if (!Number.isInteger(CONNS) || CONNS < 1) usageError("--conns must be a positive integer");
if (!(RAMP > 0)) usageError("--ramp must be a positive number (connections/sec)");
if (!(HOLD >= 0)) usageError("--hold must be >= 0 (seconds)");
if (!Number.isInteger(SENDERS) || SENDERS < 0) usageError("--senders must be a non-negative integer");
if (!(MSG_RATE > 0)) usageError("--msg-rate must be a positive number (msgs/sec/sender)");
if (SENDERS > CONNS) usageError("--senders cannot exceed --conns");

let BEAM_PID = null;
if (BEAM_PID_ARG !== null) {
  if (!/^\d+$/.test(BEAM_PID_ARG)) usageError("--beam-pid must be a plain integer pid");
  BEAM_PID = BEAM_PID_ARG;
}

// ---- ulimit guard (brief: refuse to start if --conns > limit-64) ------------------

let fdLimit = null;
try {
  fdLimit = parseInt(execSync("ulimit -n").toString().trim(), 10);
} catch (e) {
  console.error(`[ws-storm] warning: could not read ulimit -n (${e.message}); proceeding without the guard.`);
}
if (fdLimit !== null && Number.isFinite(fdLimit)) {
  console.log(`[ws-storm] ulimit -n = ${fdLimit}`);
  if (CONNS > fdLimit - 64) {
    console.error(
      `[ws-storm] refusing to start: --conns ${CONNS} > ulimit-64 (${fdLimit - 64}). ` +
        `Run "ulimit -n 65536" (or higher) in this same shell, then re-run.`
    );
    process.exit(1);
  }
}

// ---- load the seed fixture ---------------------------------------------------------

function resolveExisting(p, bases) {
  if (path.isAbsolute(p) && fs.existsSync(p)) return p;
  for (const base of bases) {
    const candidate = path.resolve(base, p);
    if (fs.existsSync(candidate)) return candidate;
  }
  return path.resolve(bases[0], p);
}

const seedPath = resolveExisting(SEED_ARG, [process.cwd(), __dirname]);
let seed;
try {
  seed = JSON.parse(fs.readFileSync(seedPath, "utf8"));
} catch (e) {
  usageError(`could not read/parse seed file ${seedPath}: ${e.message}`);
}

const groupUsers = (seed.users || []).filter((u) => u.inGroup);
const dmChatIdByUserId = new Map();
for (const d of seed.dmChatIds || []) {
  for (const uid of d.users) dmChatIdByUserId.set(uid, d.chatId);
}
const dmUsers = (seed.users || []).filter((u) => dmChatIdByUserId.has(u.id));

const eligibleUsers = DM ? dmUsers : groupUsers;
if (eligibleUsers.length === 0) {
  usageError(`seed file has no ${DM ? "DM-paired" : "group"} users to connect as`);
}
if (SENDERS > eligibleUsers.length) {
  console.error(
    `[ws-storm] warning: --senders ${SENDERS} > ${eligibleUsers.length} eligible users — some senders will ` +
      `share a user id and may hit the per-user channel throttle (30 msgs/10s) sooner.`
  );
}

function pickUserForConnection(i) {
  return eligibleUsers[i % eligibleUsers.length];
}
function topicForUser(user) {
  return DM ? `chat:${dmChatIdByUserId.get(user.id)}` : `chat:${seed.groupChatId}`;
}

// ---- stats ---------------------------------------------------------------------------

const stats = {
  connectOk: 0,
  connectFailed: 0,
  joinOk: 0,
  joinFailed: 0,
  messagesSent: 0,
  messagesReceived: 0,
  joinLatencies: [],
  deliveryLatencies: [],
  errors: {},
  closes: {},
};
function bump(map, key) {
  map[key] = (map[key] || 0) + 1;
}

function percentiles(samples) {
  if (samples.length === 0) return { p50: null, p95: null, p99: null, min: null, max: null, count: 0 };
  const sorted = samples.slice().sort((a, b) => a - b);
  const pick = (p) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))];
  return { p50: pick(50), p95: pick(95), p99: pick(99), min: sorted[0], max: sorted[sorted.length - 1], count: sorted.length };
}

// ---- connection lifecycle --------------------------------------------------------------

const wsBase = CORE_URL.replace(/^http/, "ws");
const connections = [];

function openConnection(index) {
  const user = pickUserForConnection(index);
  const topic = topicForUser(user);
  const conn = {
    index,
    user,
    topic,
    ws: null,
    joinRef: null,
    ref: 0,
    joined: false,
    isSender: index < SENDERS,
    pendingSendRefs: new Set(),
    sentCount: 0,
    receivedCount: 0,
  };
  connections.push(conn);

  const url = `${wsBase}/socket/websocket?vsn=2.0.0&token=${encodeURIComponent(user.token)}`;
  let ws;
  try {
    ws = new WebSocket(url, { perMessageDeflate: false, handshakeTimeout: 15000 });
  } catch (e) {
    stats.connectFailed++;
    bump(stats.errors, "constructor_error");
    return;
  }
  conn.ws = ws;

  ws.on("open", () => {
    conn._opened = true;
    stats.connectOk++;
    conn.joinRef = String(++conn.ref);
    conn._joinSentAt = Date.now();
    ws.send(JSON.stringify([conn.joinRef, conn.joinRef, topic, "phx_join", {}]));

    conn._hbTimer = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify([null, String(++conn.ref), "phoenix", "heartbeat", {}]));
      }
    }, 25000);
  });

  ws.on("message", (raw) => {
    let frame;
    try {
      frame = JSON.parse(raw.toString());
    } catch {
      return;
    }
    const [, r, , event, payload] = frame;

    if (event === "phx_reply" && r === conn.joinRef && !conn.joined) {
      if (payload && payload.status === "ok") {
        conn.joined = true;
        const latency = Date.now() - conn._joinSentAt;
        stats.joinOk++;
        stats.joinLatencies.push(latency);
      } else {
        stats.joinFailed++;
        bump(stats.errors, "join_rejected");
      }
      return;
    }

    if (event === "phx_reply" && conn.pendingSendRefs.has(r)) {
      conn.pendingSendRefs.delete(r);
      if (!payload || payload.status !== "ok") {
        bump(stats.errors, "send_rejected");
        const reason = payload && payload.response && payload.response.reason;
        if (reason === "rate_limited") bump(stats.errors, "rate_limited");
      }
      return;
    }

    if (event === "message") {
      conn.receivedCount++;
      stats.messagesReceived++;
      const meta = payload && payload.metadata;
      if (meta && typeof meta.ltSentAt === "number") {
        stats.deliveryLatencies.push(Date.now() - meta.ltSentAt);
      }
      return;
    }
  });

  ws.on("unexpected-response", (req, res) => {
    stats.connectFailed++;
    bump(stats.errors, `http_${res.statusCode}`);
  });

  ws.on("error", (err) => {
    if (conn._opened !== true) {
      stats.connectFailed++;
    }
    bump(stats.errors, (err && err.code) || "unknown_error");
  });

  ws.on("close", (code) => {
    bump(stats.closes, String(code));
    if (conn._hbTimer) clearInterval(conn._hbTimer);
    if (conn._sendTimer) clearInterval(conn._sendTimer);
  });
}

function startSending(conn) {
  const intervalMs = 1000 / MSG_RATE;
  conn._sendTimer = setInterval(() => {
    if (!conn.ws || conn.ws.readyState !== WebSocket.OPEN || !conn.joined) return;
    const id = crypto.randomUUID();
    const now = Date.now();
    const ref = String(++conn.ref);
    conn.pendingSendRefs.add(ref);
    conn.ws.send(
      JSON.stringify([
        conn.joinRef,
        ref,
        conn.topic,
        "message",
        {
          id,
          type: "text",
          timestamp: now,
          text: `loadtest conn=${conn.index} t=${now}`,
          encryptedContent: `loadtest-harness:${id}`,
          metadata: { ltSentAt: now, ltSenderIndex: conn.index },
        },
      ])
    );
    conn.sentCount++;
    stats.messagesSent++;
  }, intervalMs);
}

// ---- metrics / rss sampling -----------------------------------------------------------

async function sampleMetrics(label) {
  try {
    const res = await fetch(METRICS_URL, { signal: AbortSignal.timeout(5000) });
    const text = await res.text();
    const file = path.join(RESULTS_DIR, `metrics-${label}.txt`);
    fs.writeFileSync(file, text, "utf8");
    return file;
  } catch (e) {
    console.error(`[ws-storm] could not sample ${METRICS_URL}: ${e.message}`);
    return null;
  }
}

function sampleRss(pid) {
  if (!pid) return null;
  const result = spawnSync("ps", ["-o", "rss=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return null;
  const rssKb = parseInt(result.stdout.trim(), 10);
  return Number.isFinite(rssKb) ? rssKb : null;
}

// ---- main run ---------------------------------------------------------------------------

const RESULTS_DIR = path.join(__dirname, "results");
fs.mkdirSync(RESULTS_DIR, { recursive: true });
const label = `${CONNS}c-${DM ? "dm" : "group"}-${Date.now()}`;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  console.log(
    `[ws-storm] conns=${CONNS} ramp=${RAMP}/s hold=${HOLD}s senders=${SENDERS} msg-rate=${MSG_RATE}/s mode=${DM ? "dm" : "group"} core=${CORE_URL}`
  );

  const metricsBeforeFile = await sampleMetrics(`before-${label}`);
  const rssBeforeKb = sampleRss(BEAM_PID);

  const startedAt = Date.now();

  // Ramp: open connections in ticks so the aggregate rate matches --ramp
  // regardless of Node's timer granularity at very high or very low rates.
  const TICK_MS = 20;
  const perTick = Math.max(1, Math.round((RAMP * TICK_MS) / 1000));
  let opened = 0;
  await new Promise((resolve) => {
    const timer = setInterval(() => {
      const toOpen = Math.min(perTick, CONNS - opened);
      for (let k = 0; k < toOpen; k++) {
        openConnection(opened);
        opened++;
      }
      if (opened >= CONNS) {
        clearInterval(timer);
        resolve();
      }
    }, TICK_MS);
  });
  const rampDoneAt = Date.now();
  console.log(`[ws-storm] ramp complete: ${opened} connections opened in ${((rampDoneAt - startedAt) / 1000).toFixed(1)}s`);

  const settleS = Math.min(2, HOLD * 0.1);
  const tailS = Math.min(3, HOLD * 0.15);
  const sendS = Math.max(0, HOLD - settleS - tailS);

  if (HOLD > 0) await sleep(settleS * 1000);

  const senders = connections.filter((c) => c.isSender);
  if (SENDERS > 0 && sendS > 0) {
    console.log(`[ws-storm] senders active: ${senders.length} for ${sendS.toFixed(1)}s`);
    for (const conn of senders) startSending(conn);
    await sleep(sendS * 1000);
    for (const conn of senders) {
      if (conn._sendTimer) clearInterval(conn._sendTimer);
    }
  }

  if (HOLD > 0) await sleep(tailS * 1000);

  const metricsAfterFile = await sampleMetrics(`after-${label}`);
  const rssAfterKb = sampleRss(BEAM_PID);
  const finishedAt = Date.now();

  for (const conn of connections) {
    if (conn._hbTimer) clearInterval(conn._hbTimer);
    if (conn._sendTimer) clearInterval(conn._sendTimer);
    try {
      if (conn.ws && (conn.ws.readyState === WebSocket.OPEN || conn.ws.readyState === WebSocket.CONNECTING)) {
        conn.ws.close();
      }
    } catch {
      /* ignore */
    }
  }
  await sleep(500);

  const joinLat = percentiles(stats.joinLatencies);
  const deliveryLat = percentiles(stats.deliveryLatencies);
  const fanOutRatio = stats.messagesSent > 0 ? stats.messagesReceived / stats.messagesSent : null;

  const report = {
    config: {
      seed: seedPath,
      conns: CONNS,
      ramp: RAMP,
      hold: HOLD,
      senders: SENDERS,
      msgRate: MSG_RATE,
      dm: DM,
      coreUrl: CORE_URL,
      metricsUrl: METRICS_URL,
      beamPid: BEAM_PID,
    },
    startedAt: new Date(startedAt).toISOString(),
    finishedAt: new Date(finishedAt).toISOString(),
    durationMs: finishedAt - startedAt,
    connects: { ok: stats.connectOk, failed: stats.connectFailed },
    joins: { ok: stats.joinOk, failed: stats.joinFailed },
    joinLatencyMs: joinLat,
    deliveryLatencyMs: deliveryLat,
    messages: { sent: stats.messagesSent, received: stats.messagesReceived, fanOutRatio },
    errors: stats.errors,
    closes: stats.closes,
    metrics: { before: metricsBeforeFile, after: metricsAfterFile },
    rss: { beforeKb: rssBeforeKb, afterKb: rssAfterKb },
  };

  const reportPath = path.join(RESULTS_DIR, `ws-storm-${label}.json`);
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n", "utf8");

  console.log("");
  console.log("=== ws-storm report ===");
  console.log(`connects        ok=${report.connects.ok} failed=${report.connects.failed}`);
  console.log(`joins           ok=${report.joins.ok} failed=${report.joins.failed}`);
  console.log(
    `join latency ms p50=${joinLat.p50} p95=${joinLat.p95} p99=${joinLat.p99} (n=${joinLat.count})`
  );
  console.log(
    `delivery lat ms p50=${deliveryLat.p50} p95=${deliveryLat.p95} p99=${deliveryLat.p99} (n=${deliveryLat.count})`
  );
  console.log(
    `messages        sent=${report.messages.sent} received=${report.messages.received} fanOutRatio=${
      fanOutRatio === null ? "n/a" : fanOutRatio.toFixed(2)
    }`
  );
  console.log(`errors by type  ${JSON.stringify(report.errors)}`);
  console.log(`socket closes   ${JSON.stringify(report.closes)}`);
  if (rssBeforeKb !== null || rssAfterKb !== null) {
    console.log(`beam rss kb     before=${rssBeforeKb} after=${rssAfterKb}`);
  }
  console.log(`metrics         before=${metricsBeforeFile} after=${metricsAfterFile}`);
  console.log(`wrote ${reportPath}`);

  process.exit(0);
}

main().catch((e) => {
  console.error(`[ws-storm] fatal: ${e.stack || e.message}`);
  process.exit(1);
});
