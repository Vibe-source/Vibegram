#!/usr/bin/env node
/**
 * voice-probe — live end-to-end probe for vibe.voice.v1 (docs/agent-voice-v1.md):
 * mints a voice session via vibe-core, joins vibe-agent-runtime's voice channel over
 * the Phoenix v2 wire, streams a WAV as PCM16 audio.chunk frames, and records every
 * inbound frame (transcripts, agent audio, tool/approval frames) into a summary JSON.
 *
 * Usage:
 *   node voice-probe.js --core http://127.0.0.1:4000 --token <bearer> \
 *        --agent <agentId> --chat <chatId> --wav q.wav \
 *        [--text "typed question"] [--runtime-ws ws://...] [--seconds 40] [--out dir]
 *
 * Node built-ins + the repo-root `ws` package only.
 */
"use strict";

const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");
const WebSocket = require("ws");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}
function usage() {
  console.error(
    "usage: node voice-probe.js --core URL --token <bearer> --agent <agentId> --chat <chatId> " +
      '--wav q.wav [--text "typed question"] [--runtime-ws ws://...] [--seconds 40] [--out dir]'
  );
}

const OPTS = {
  core: arg("core", null),
  token: arg("token", null),
  agent: arg("agent", null),
  chat: arg("chat", null),
  wav: arg("wav", null),
  text: arg("text", null),
  runtimeWs: arg("runtime-ws", null),
  seconds: (() => {
    const n = Number(arg("seconds", "40"));
    return Number.isFinite(n) && n > 0 ? n : 40;
  })(),
  out: arg("out", "."),
};

for (const key of ["core", "token", "agent", "chat", "wav"]) {
  if (!OPTS[key]) {
    usage();
    process.exit(2);
  }
}

// Never log a full bearer/voice token — only its length and last 4 chars.
function redact(s) {
  if (!s) return "(empty)";
  return `${s.length} chars, ...${s.slice(-4)}`;
}

// Walks the RIFF chunks (afconvert adds FLLR/LIST padding before `data`), returns the PCM.
function readAndValidateWav(wavPath) {
  const buf = fs.readFileSync(wavPath);
  if (buf.length < 12 || buf.toString("ascii", 0, 4) !== "RIFF" || buf.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error(`${wavPath} is not a RIFF/WAVE file`);
  }
  let fmt = null;
  let data = null;
  let offset = 12;
  while (offset + 8 <= buf.length) {
    const id = buf.toString("ascii", offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    const start = offset + 8;
    if (id === "fmt ") {
      fmt = {
        format: buf.readUInt16LE(start),
        numChannels: buf.readUInt16LE(start + 2),
        sampleRate: buf.readUInt32LE(start + 4),
        bitsPerSample: buf.readUInt16LE(start + 14),
      };
    } else if (id === "data") {
      data = buf.slice(start, Math.min(start + size, buf.length));
      break;
    }
    offset = start + size + (size % 2); // chunks are word-aligned
  }
  if (!fmt || !data) throw new Error(`${wavPath}: missing fmt/data chunk`);
  if (fmt.format !== 1 || fmt.sampleRate !== 24000 || fmt.numChannels !== 1 || fmt.bitsPerSample !== 16) {
    throw new Error(
      `${wavPath} must be 24000 Hz / 1 channel / 16-bit PCM, got ` +
        `format=${fmt.format} ${fmt.sampleRate} Hz / ${fmt.numChannels} ch / ${fmt.bitsPerSample} bit`
    );
  }
  return data;
}

function wavHeader(dataLength, sampleRate, numChannels, bitsPerSample) {
  const byteRate = sampleRate * numChannels * (bitsPerSample / 8);
  const blockAlign = numChannels * (bitsPerSample / 8);
  const buf = Buffer.alloc(44);
  buf.write("RIFF", 0, "ascii");
  buf.writeUInt32LE(36 + dataLength, 4);
  buf.write("WAVE", 8, "ascii");
  buf.write("fmt ", 12, "ascii");
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(numChannels, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(byteRate, 28);
  buf.writeUInt16LE(blockAlign, 32);
  buf.writeUInt16LE(bitsPerSample, 34);
  buf.write("data", 36, "ascii");
  buf.writeUInt32LE(dataLength, 40);
  return buf;
}

function httpPostJson(urlStr, headers, bodyObj) {
  return new Promise((resolve, reject) => {
    let url;
    try {
      url = new URL(urlStr);
    } catch (err) {
      reject(err);
      return;
    }
    const mod = url.protocol === "https:" ? https : http;
    const body = JSON.stringify(bodyObj);
    const req = mod.request(
      url,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
          ...headers,
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          let parsed;
          try {
            parsed = raw ? JSON.parse(raw) : {};
          } catch {
            parsed = { raw };
          }
          resolve({ status: res.statusCode, body: parsed });
        });
      }
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

// `ws_url` from Sessions.create/1 already ends in /websocket; this stays correct
// whether --runtime-ws repeats that suffix or points at the bare socket path.
function buildSocketUrl(wsUrl, token) {
  let base = wsUrl.replace(/\/+$/, "");
  if (!base.endsWith("/websocket")) base += "/websocket";
  return `${base}?vsn=2.0.0&token=${encodeURIComponent(token)}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const pcm = readAndValidateWav(OPTS.wav);
  console.log(`[voice-probe] wav ok: ${OPTS.wav} (${pcm.length} PCM bytes, 24000 Hz / 1 ch / 16-bit)`);
  console.log(`[voice-probe] bearer token: ${redact(OPTS.token)}`);

  fs.mkdirSync(OPTS.out, { recursive: true });

  const core = OPTS.core.replace(/\/+$/, "");
  const mintUrl = `${core}/api/agents/${encodeURIComponent(OPTS.agent)}/voice/sessions`;
  const mint = await httpPostJson(mintUrl, { authorization: `Bearer ${OPTS.token}` }, { chatId: OPTS.chat });

  if (mint.status < 200 || mint.status >= 300) {
    console.error(`[voice-probe] session mint failed: HTTP ${mint.status} ${JSON.stringify(mint.body)}`);
    process.exit(1);
  }

  const session = mint.body; // {session_id, ws_url, token, expires_at} — snake_case, docs/agent-voice-v1.md §2
  if (!session.session_id || !session.ws_url || !session.token) {
    console.error(`[voice-probe] session response missing fields: ${JSON.stringify(Object.keys(session))}`);
    process.exit(1);
  }

  console.log(
    `[voice-probe] session_id=${session.session_id} ws_url=${session.ws_url} ` +
      `voice token: ${redact(session.token)} expires_at=${session.expires_at}`
  );

  const socketUrl = buildSocketUrl(OPTS.runtimeWs || session.ws_url, session.token);
  const topic = `voice:${session.session_id}`;

  const t0 = Date.now();
  const elapsed = () => ((Date.now() - t0) / 1000).toFixed(2);
  const log = (...parts) => console.log(`[+${elapsed()}s]`, ...parts);

  let ref = 0;
  const nextRef = () => String(++ref);
  let joinRef = null;
  const ws = new WebSocket(socketUrl);

  function push(event, payload) {
    const r = nextRef();
    try {
      ws.send(JSON.stringify([joinRef, r, topic, event, payload]));
    } catch (err) {
      log("send failed", event, err.message); // e.g. hangup racing a socket that just errored
    }
    return r;
  }

  // --- summary state ---
  let readyMs = null;
  let firstAgentAudioMs = null;
  let userTranscriptFinal = "";
  let userTranscriptLast = "";
  let agentTranscriptFinal = "";
  let agentTranscriptLast = "";
  let agentAudioBytes = 0;
  const agentAudioChunks = [];
  const frameCounts = {};
  const errors = [];

  let streamCancelled = false;
  let finished = false;
  let heartbeatTimer = null;
  let secondsTimer = null;

  function writeAgentAudioIfAny() {
    if (agentAudioChunks.length === 0) {
      log("no agent audio received; skipping wav write");
      return null;
    }
    const outPath = path.join(OPTS.out, `agent-${t0}.wav`);
    const pcmOut = Buffer.concat(agentAudioChunks);
    fs.writeFileSync(outPath, Buffer.concat([wavHeader(pcmOut.length, 24000, 1, 16), pcmOut]));
    log(`wrote agent audio: ${outPath} (${pcmOut.length} PCM bytes)`);
    return outPath;
  }

  function finish(reason) {
    if (finished) return;
    finished = true;
    log(`finishing: ${reason}`);
    streamCancelled = true;
    if (secondsTimer) clearTimeout(secondsTimer);
    if (heartbeatTimer) clearInterval(heartbeatTimer);

    const closeAndSummarize = () => {
      try {
        ws.close();
      } catch {
        // already closed
      }
      writeAgentAudioIfAny();

      const userTranscript = userTranscriptFinal.trim() || userTranscriptLast.trim();
      const agentTranscript = agentTranscriptFinal.trim() || agentTranscriptLast.trim();
      const summary = {
        sessionId: session.session_id,
        readyMs,
        firstAgentAudioMs,
        userTranscript,
        agentTranscript,
        agentAudioSeconds: Number((agentAudioBytes / (24000 * 2)).toFixed(3)),
        frames: frameCounts,
        errors,
      };
      console.log(JSON.stringify(summary, null, 2));
      process.exit(agentAudioBytes > 0 || agentTranscript !== "" ? 0 : 1);
    };

    if (ws.readyState === WebSocket.OPEN && joinRef !== null) {
      push("hangup", {});
      setTimeout(closeAndSummarize, 300);
    } else {
      closeAndSummarize();
    }
  }

  async function streamAudio() {
    const SLICE_BYTES = 4800; // 100ms @ 24000Hz/16-bit/mono
    let seq = 0;
    for (let offset = 0; offset < pcm.length; offset += SLICE_BYTES) {
      if (streamCancelled) return;
      let slice = pcm.slice(offset, offset + SLICE_BYTES);
      if (slice.length % 2 === 1) slice = slice.slice(0, -1); // stay on sample boundaries, §8
      seq += 1;
      push("audio.chunk", { seq, codec: "pcm16le", sampleRate: 24000, dataBase64: slice.toString("base64") });
      await sleep(100);
    }
    if (streamCancelled) return;
    push("audio.end", {});
    log("sent audio.end");
    if (OPTS.text) {
      push("text.message", { text: OPTS.text });
      log(`sent text.message: ${JSON.stringify(OPTS.text)}`);
    }
  }

  ws.on("open", () => {
    log("socket open, joining", topic);
    joinRef = nextRef();
    ws.send(JSON.stringify([joinRef, joinRef, topic, "phx_join", {}]));
    heartbeatTimer = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}]));
    }, 25000);
    secondsTimer = setTimeout(() => finish("seconds elapsed"), OPTS.seconds * 1000);
  });

  ws.on("message", (raw) => {
    let frame;
    try {
      frame = JSON.parse(raw.toString());
    } catch {
      return;
    }
    const [, r, , event, payload] = frame;

    if (event === "phx_reply" && r === joinRef) {
      if (payload.status === "ok") {
        log("joined", topic);
      } else {
        const reason = payload.response && payload.response.reason;
        errors.push({ code: "join_failed", message: reason || JSON.stringify(payload) });
        log("join failed:", reason || JSON.stringify(payload));
        finish("join failed");
      }
      return;
    }
    if (event === "phx_reply") return; // no other replies expected (handle_in returns :noreply)

    frameCounts[event] = (frameCounts[event] || 0) + 1;

    switch (event) {
      case "session.ready":
        readyMs = Date.now() - t0;
        log("session.ready", JSON.stringify(payload));
        streamAudio();
        break;

      case "audio.chunk": {
        const decoded = Buffer.from(payload.dataBase64 || "", "base64");
        if (firstAgentAudioMs === null) firstAgentAudioMs = Date.now() - t0;
        agentAudioBytes += decoded.length;
        agentAudioChunks.push(decoded);
        log("audio.chunk", `seq=${payload.seq}`, `bytes=${decoded.length}`);
        break;
      }

      case "transcript.user":
        userTranscriptLast = payload.text || "";
        if (payload.final) userTranscriptFinal += (userTranscriptFinal ? " " : "") + (payload.text || "");
        log("transcript.user", `final=${payload.final}`, JSON.stringify(payload.text));
        break;

      case "transcript.agent":
        agentTranscriptLast = payload.text || "";
        if (payload.final) agentTranscriptFinal += (agentTranscriptFinal ? " " : "") + (payload.text || "");
        log("transcript.agent", `final=${payload.final}`, JSON.stringify(payload.text));
        break;

      case "tool.progress":
        log("tool.progress", `tool=${payload.tool}`, `status=${payload.status}`);
        break;

      case "approval.requested":
        log("approval.requested", JSON.stringify(payload));
        log("AUTO-APPROVING decisionId=" + payload.decisionId);
        push("decision", { decisionId: payload.decisionId, outcome: "approve" });
        break;

      case "session.ended":
        log("session.ended", JSON.stringify(payload));
        finish("session.ended:" + (payload && payload.reason));
        break;

      case "error":
        errors.push(payload);
        log("error", JSON.stringify(payload));
        break;

      default:
        log(event, JSON.stringify(payload).slice(0, 300));
    }
  });

  ws.on("close", (code) => {
    log("socket closed", code);
    finish("socket closed " + code);
  });

  ws.on("error", (err) => {
    errors.push({ code: "socket_error", message: err.message });
    log("socket error", err.message);
    finish("socket error");
  });
}

main().catch((err) => {
  console.error(`[voice-probe] ${err.message}`);
  process.exit(1);
});
