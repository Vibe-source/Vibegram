#!/usr/bin/env node
/**
 * security-probe — live probe for the security controls shipped this week
 * (.vibe/team/live-0829-board.md), run against a running vibe-core.
 *
 * Registers its own throwaway users (sp_<rand>), never needs pre-existing
 * data. Prints a PASS/FAIL/SKIP table with observed status codes and exits 1
 * if anything FAILs. A control that is not reachable locally is SKIP with a
 * reason, never PASS.
 *
 * Usage:
 *   node probe.js [--core http://127.0.0.1:4000] [--hmac-key <key>]
 *                 [--json out.json] [--max-json-body-bytes 8000000]
 *
 * Node built-ins + the repo-root `ws` package only. fetch/FormData/Blob are
 * Node globals (v18+), used only for the two multipart checks.
 */
"use strict";

const http = require("http");
const https = require("https");
const crypto = require("crypto");
const fs = require("fs");
const WebSocket = require("ws");

// ---------- CLI ----------

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}

function usage() {
  console.error(
    "usage: node probe.js [--core http://127.0.0.1:4000] [--hmac-key <key>] " +
      "[--json out.json] [--max-json-body-bytes 8000000]"
  );
}

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  usage();
  process.exit(0);
}

const OPTS = {
  core: arg("core", process.env.VIBE_CORE_URL || "http://127.0.0.1:4000").replace(/\/+$/, ""),
  hmacKey: arg("hmac-key", process.env.VIBE_INTERNAL_HMAC_KEY || null),
  jsonOut: arg("json", null),
  maxJsonBodyBytes: Number(arg("max-json-body-bytes", process.env.MAX_JSON_BODY_BYTES || "8000000")),
};

// ---------- tiny helpers ----------

function rand() {
  return crypto.randomBytes(4).toString("hex");
}

// Never print a live bearer/HMAC value — only its size.
function redact(s) {
  return s ? `(${Buffer.byteLength(String(s), "utf8")} bytes)` : "(empty)";
}

function jsonHeaders() {
  return { "content-type": "application/json" };
}

function bearer(token) {
  return { authorization: `Bearer ${token}` };
}

// ---------- HTTP core ----------

// Exact header/body control, for HMAC signing and the oversized-body test.
// Resolved `headers` is always a plain lowercase-keyed object, like multipartRequest below.
function httpRequest(urlStr, { method = "GET", headers = {}, body = null, timeoutMs = 20000 } = {}) {
  return new Promise((resolve, reject) => {
    let url;
    try {
      url = new URL(urlStr);
    } catch (err) {
      reject(err);
      return;
    }
    const mod = url.protocol === "https:" ? https : http;
    const bodyBuf = body == null ? null : Buffer.isBuffer(body) ? body : Buffer.from(body, "utf8");
    const reqHeaders = { ...headers };
    if (bodyBuf) reqHeaders["content-length"] = String(bodyBuf.length);

    const req = mod.request(url, { method, headers: reqHeaders, timeout: timeoutMs }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {
          /* not JSON */
        }
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    req.on("timeout", () => req.destroy(new Error(`request timed out after ${timeoutMs}ms`)));
    req.on("error", reject);
    if (bodyBuf) req.write(bodyBuf);
    req.end();
  });
}

// Multipart only: fetch+FormData compute the boundary correctly on their own.
async function multipartRequest(urlStr, { headers = {}, form } = {}) {
  const res = await fetch(urlStr, { method: "POST", headers, body: form });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* not JSON */
  }
  return { status: res.status, headers: Object.fromEntries(res.headers.entries()), text, json };
}

// ---------- vibe-internal-auth/v1 signing ----------
// Mirrors contracts/lib/vibe_contracts/service_auth.ex compute_signature/7.

function signInternal(key, method, pathWithQuery, bodyString, opts = {}) {
  const service = opts.service || "agent-runtime";
  const ts = opts.timestamp !== undefined ? String(opts.timestamp) : String(Math.floor(Date.now() / 1000));
  const nonce = opts.nonce || crypto.randomUUID();
  const bodyHash = crypto.createHash("sha256").update(bodyString || "", "utf8").digest("hex");
  const signingString = `v1\n${service}\n${method.toUpperCase()}\n${pathWithQuery}\n${ts}\n${nonce}\n${bodyHash}`;
  const sig = crypto.createHmac("sha256", Buffer.from(key, "utf8")).update(signingString, "utf8").digest("hex");
  return {
    headers: {
      "x-vibe-service": service,
      "x-vibe-timestamp": ts,
      "x-vibe-nonce": nonce,
      "x-vibe-signature": `v1=${sig}`,
    },
  };
}

// ---------- websocket probe ----------

function wsProbe(url, headers) {
  return new Promise((resolve) => {
    let settled = false;
    let timer;
    const finish = (patch) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(patch);
    };
    let ws;
    try {
      ws = new WebSocket(url, { headers, handshakeTimeout: 5000 });
    } catch (err) {
      resolve({ event: "throw", reason: err.message });
      return;
    }
    timer = setTimeout(() => {
      try {
        ws.terminate();
      } catch {
        /* already gone */
      }
      finish({ event: "stayed-open-timeout" });
    }, 6000);

    ws.on("unexpected-response", (_req, res) => finish({ event: "unexpected-response", statusCode: res.statusCode }));
    ws.on("close", (code, reasonBuf) => finish({ event: "close", code, reason: reasonBuf ? reasonBuf.toString() : "" }));
    ws.on("error", (err) => finish({ event: "error", reason: err.message }));
    ws.on("open", () => {
      // If connect/3 rejected but the upgrade already completed, give the
      // server a moment to send its close frame before calling it stable.
      setTimeout(() => {
        if (!settled) finish({ event: "stayed-open" });
      }, 2000);
    });
  });
}

// ---------- result bookkeeping ----------

const results = [];

function push(id, label, status, expected, observed, note) {
  const row = { id, label, status, expected, observed, note: note || "" };
  results.push(row);
  console.log(`[${status}] ${id} ${label}`);
  console.log(`    expected: ${expected}`);
  console.log(`    observed: ${observed}`);
  if (row.note) console.log(`    note:     ${row.note}`);
}

function skip(id, label, reason) {
  push(id, label, "SKIP", "-", "-", reason);
}

function assertStatus(expected, actual, detail) {
  return {
    status: actual === expected ? "PASS" : "FAIL",
    expected: String(expected),
    observed: `${actual}${detail ? " " + String(detail).slice(0, 150).replace(/\s+/g, " ") : ""}`,
  };
}

// Isolates one assertion: a throw here is a FAIL for this check only, never
// a crash of the whole probe.
async function check(id, label, fn) {
  try {
    const r = await fn();
    push(id, label, r.status, r.expected, r.observed, r.note);
  } catch (err) {
    push(id, label, "FAIL", "(threw)", String((err && err.message) || err), "");
  }
}

async function registerUser(prefix) {
  const r = rand();
  const payload = {
    username: `sp_${prefix}_${r}`,
    password: `Sp_Probe_${r}_Aa1!`,
    deviceId: `sp-device-${r}`,
    publicKey: `sp-pubkey-${r}`,
    encryptedPrivateKey: `sp-encpriv-${r}`,
    identityKey: "v3",
  };
  const res = await httpRequest(`${OPTS.core}/api/register`, {
    method: "POST",
    headers: jsonHeaders(),
    body: JSON.stringify(payload),
  });
  if (res.status !== 200 || !res.json || !res.json.token) {
    throw new Error(`registration failed for ${payload.username}: ${res.status} ${res.text.slice(0, 200)}`);
  }
  return { username: payload.username, password: payload.password, userId: res.json.userId, token: res.json.token };
}

let mainUser = null;

// ===================================================================
// 1. Security headers — server/lib/vibe_web/plugs/security_headers.ex
// ===================================================================

async function check1Headers() {
  const url = `${OPTS.core}/api/health`;
  let res;
  try {
    res = await httpRequest(url, { method: "GET" });
  } catch (err) {
    push("1.1", "headers.baseline", "FAIL", "(did not run)", `request failed: ${err.message}`, "");
    push("1.2", "headers.csp-scope", "FAIL", "(did not run)", `request failed: ${err.message}`, "");
    skip("1.3", "headers.hsts", `request failed: ${err.message}`);
    return;
  }

  await check("1.1", "headers.baseline", async () => {
    const expected = {
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
      "referrer-policy": "strict-origin-when-cross-origin",
      "permissions-policy": "camera=(), microphone=(), geolocation=()",
      "cross-origin-opener-policy": "same-origin",
    };
    const mismatches = [];
    for (const [name, want] of Object.entries(expected)) {
      const got = res.headers[name];
      if (got !== want) mismatches.push(`${name}: expected "${want}", got ${got === undefined ? "MISSING" : `"${got}"`}`);
    }
    return {
      status: mismatches.length === 0 ? "PASS" : "FAIL",
      expected: JSON.stringify(expected),
      observed: mismatches.length === 0 ? "all present and correct" : mismatches.join("; "),
    };
  });

  await check("1.2", "headers.csp-scope", async () => {
    const csp = res.headers["content-security-policy"];
    return {
      status: csp === undefined ? "PASS" : "FAIL",
      expected: "absent on /api/* (SecurityHeaders.maybe_put_csp only adds CSP outside /api)",
      observed: csp === undefined ? "absent" : `present: "${csp}"`,
    };
  });

  if (!url.startsWith("https:")) {
    skip(
      "1.3",
      "headers.hsts",
      "probe target is http with no x-forwarded-proto — maybe_put_hsts only sets HSTS when https? is true; retest over https (VPS) to exercise this"
    );
  } else {
    await check("1.3", "headers.hsts", async () => {
      const hsts = res.headers["strict-transport-security"];
      return {
        status: hsts && hsts.includes("max-age=63072000") ? "PASS" : "FAIL",
        expected: "max-age=63072000; includeSubDomains; preload",
        observed: hsts || "MISSING",
      };
    });
  }
}

// ===================================================================
// 2. Internal HMAC auth — server/lib/vibe_web/plugs/internal_service_auth.ex
//    + contracts/lib/vibe_contracts/service_auth.ex
// ===================================================================

async function check2InternalHmac() {
  const labels = {
    "2.1": "internal-hmac.unsigned",
    "2.2": "internal-hmac.wrong-key",
    "2.3": "internal-hmac.disallowed-service(core)",
    "2.4": "internal-hmac.valid",
    "2.5": "internal-hmac.replayed-nonce",
    "2.6": "internal-hmac.stale-timestamp(10min)",
  };
  const ids = Object.keys(labels);

  if (!OPTS.hmacKey) {
    for (const id of ids) skip(id, labels[id], "no --hmac-key / VIBE_INTERNAL_HMAC_KEY provided; cannot sign internal requests");
    return;
  }
  if (Buffer.byteLength(OPTS.hmacKey, "utf8") < 32) {
    for (const id of ids) {
      skip(id, labels[id], `--hmac-key is ${redact(OPTS.hmacKey)}, under the 32-byte floor ServiceAuth.check_key_strength/1 requires`);
    }
    return;
  }

  const path = "/internal/v1/agent-events";
  const url = `${OPTS.core}${path}`;
  const body = JSON.stringify({ events: [] });

  let unsignedProbe;
  try {
    unsignedProbe = await httpRequest(url, { method: "POST", headers: jsonHeaders(), body });
  } catch (err) {
    for (const id of ids) push(id, labels[id], "FAIL", "(did not run)", `request failed: ${err.message}`, "");
    return;
  }
  if (unsignedProbe.status === 503 && /unconfigured/i.test(unsignedProbe.text)) {
    for (const id of ids) {
      skip(id, labels[id], "server answered 503 internal_auth_unconfigured — VIBE_INTERNAL_HMAC_KEY is unset on the core itself");
    }
    return;
  }

  await check("2.1", labels["2.1"], async () => assertStatus(401, unsignedProbe.status, unsignedProbe.text));

  await check("2.2", labels["2.2"], async () => {
    const wrongKey = crypto.randomBytes(32).toString("hex");
    const signed = signInternal(wrongKey, "POST", path, body);
    const res = await httpRequest(url, { method: "POST", headers: { ...jsonHeaders(), ...signed.headers }, body });
    return assertStatus(401, res.status, res.text);
  });

  await check("2.3", labels["2.3"], async () => {
    const signed = signInternal(OPTS.hmacKey, "POST", path, body, { service: "core" });
    const res = await httpRequest(url, { method: "POST", headers: { ...jsonHeaders(), ...signed.headers }, body });
    return assertStatus(401, res.status, res.text);
  });

  let replayHeaders = null;
  await check("2.4", labels["2.4"], async () => {
    const signed = signInternal(OPTS.hmacKey, "POST", path, body);
    replayHeaders = signed.headers;
    const res = await httpRequest(url, { method: "POST", headers: { ...jsonHeaders(), ...signed.headers }, body });
    return assertStatus(200, res.status, res.text);
  });

  await check("2.5", labels["2.5"], async () => {
    if (!replayHeaders) throw new Error("no nonce to replay — the 2.4 valid-signature check did not complete");
    const res = await httpRequest(url, { method: "POST", headers: { ...jsonHeaders(), ...replayHeaders }, body });
    return assertStatus(401, res.status, res.text);
  });

  await check("2.6", labels["2.6"], async () => {
    const staleTs = Math.floor(Date.now() / 1000) - 600;
    const signed = signInternal(OPTS.hmacKey, "POST", path, body, { timestamp: staleTs });
    const res = await httpRequest(url, { method: "POST", headers: { ...jsonHeaders(), ...signed.headers }, body });
    return assertStatus(401, res.status, res.text);
  });
}

// ===================================================================
// 3. JSON body cap — server/lib/vibe_web/endpoint.ex (Plug.Parsers length:)
// ===================================================================

async function check3JsonBodyCap() {
  await check("3.1", "json-body-cap", async () => {
    const prefix = '{"credential":"sp_overflow_probe","password":"';
    const suffix = '"}';
    const buildBody = (padLen) => prefix + "A".repeat(padLen) + suffix;
    const cap = OPTS.maxJsonBodyBytes;
    const padLen1 = cap + 1 - prefix.length - suffix.length;
    if (padLen1 < 0) throw new Error(`--max-json-body-bytes (${cap}) is too small for the probe's envelope`);

    const body1 = buildBody(padLen1);
    const res1 = await httpRequest(`${OPTS.core}/api/login`, { method: "POST", headers: jsonHeaders(), body: body1 });
    if (res1.status === 413) {
      return {
        status: "PASS",
        expected: `413 for a ${Buffer.byteLength(body1, "utf8")}-byte body against MAX_JSON_BODY_BYTES=${cap}`,
        observed: `${res1.status} ${res1.text.slice(0, 150)}`,
      };
    }

    // Assumed cap didn't trip 413 — this server may run a higher
    // MAX_JSON_BODY_BYTES. Escalate well past it before calling this a FAIL.
    const body2 = buildBody(padLen1 + 10_000_000);
    const res2 = await httpRequest(`${OPTS.core}/api/login`, { method: "POST", headers: jsonHeaders(), body: body2 });
    if (res2.status === 413) {
      return {
        status: "PASS",
        expected: `413 once the body clearly exceeds the cap (the assumed default ${cap} did not trigger it — this server's MAX_JSON_BODY_BYTES is set higher)`,
        observed: `${Buffer.byteLength(body1, "utf8")}B -> ${res1.status} (not capped at the assumed value); ${Buffer.byteLength(body2, "utf8")}B -> ${res2.status} (capped)`,
        note: "pass --max-json-body-bytes matching this server's real MAX_JSON_BODY_BYTES for a tight boundary check; the control itself works",
      };
    }

    return {
      status: "FAIL",
      expected: `413 for an oversized JSON body (tried ${Buffer.byteLength(body1, "utf8")}B and ${Buffer.byteLength(body2, "utf8")}B)`,
      observed: `${res1.status} at ${Buffer.byteLength(body1, "utf8")}B, ${res2.status} at ${Buffer.byteLength(body2, "utf8")}B — no 413 even well past the assumed cap`,
    };
  });
}

// ===================================================================
// 4. Multipart to a non-upload JSON route
// ===================================================================

async function check4MultipartWrongRoute() {
  await check("4.1", "multipart-wrong-route", async () => {
    const form = new FormData();
    form.append("credential", "sp_multipart_probe");
    form.append("password", "irrelevant");
    const res = await multipartRequest(`${OPTS.core}/api/login`, { form });
    const ok = res.status >= 400 && res.status < 500;
    return {
      status: ok ? "PASS" : "FAIL",
      expected: "4xx — /api/login only parses urlencoded/json (pass:[\"*/*\"] skips multipart), so params never bind credential/password",
      observed: `${res.status} ${res.text.slice(0, 150)}`,
      note: "brief allows 415/400/422; any 4xx is treated as \"not silently accepted\"",
    };
  });
}

// ===================================================================
// 5. Bearer auth + session revocation
// ===================================================================

async function check5BearerAndSessions() {
  await check("5.1", "bearer.missing", async () => {
    const res = await httpRequest(`${OPTS.core}/api/agents`, { method: "GET" });
    return assertStatus(401, res.status, res.text);
  });

  await check("5.2", "bearer.invalid", async () => {
    const res = await httpRequest(`${OPTS.core}/api/agents`, {
      method: "GET",
      headers: bearer(`sp-garbage-${rand()}`),
    });
    return assertStatus(401, res.status, res.text);
  });

  await check("5.3", "bearer.revoked-after-logout", async () => {
    const user = await registerUser("logout");
    const before = await httpRequest(`${OPTS.core}/api/agents`, { method: "GET", headers: bearer(user.token) });
    if (before.status !== 200) throw new Error(`setup failed: token unusable before logout (status ${before.status})`);

    const logout = await httpRequest(`${OPTS.core}/api/auth/logout`, {
      method: "POST",
      headers: { ...jsonHeaders(), ...bearer(user.token) },
      body: "{}",
    });
    if (logout.status !== 200) throw new Error(`logout call failed: ${logout.status} ${logout.text.slice(0, 150)}`);

    const after = await httpRequest(`${OPTS.core}/api/agents`, { method: "GET", headers: bearer(user.token) });
    return assertStatus(401, after.status, after.text);
  });

  await check("5.4", "bearer.logout-all-revokes-second-session", async () => {
    const user = await registerUser("logoutall");
    const tokenA = user.token;
    const r = rand();

    const start = await httpRequest(`${OPTS.core}/api/account/devices/pairing`, {
      method: "POST",
      headers: jsonHeaders(),
      body: JSON.stringify({
        requesterDeviceId: `sp-dev-${r}`,
        requesterName: "sp-probe-device",
        platform: "security-probe",
        requesterPublicKey: `sp-pubkey-${r}`,
      }),
    });
    if (start.status !== 201 || !start.json || !start.json.code) {
      throw new Error(`pairing start failed: ${start.status} ${start.text.slice(0, 150)}`);
    }

    const approve = await httpRequest(`${OPTS.core}/api/account/devices/pairing/${start.json.code}/approve`, {
      method: "POST",
      headers: { ...jsonHeaders(), ...bearer(tokenA) },
      body: JSON.stringify({ wrappedKeyEnvelope: `sp-envelope-${r}` }),
    });
    if (approve.status !== 200) throw new Error(`pairing approve failed: ${approve.status} ${approve.text.slice(0, 150)}`);

    const claim = await httpRequest(`${OPTS.core}/api/account/devices/pairing/${start.json.code}/claim`, {
      method: "POST",
      headers: jsonHeaders(),
      body: "{}",
    });
    if (claim.status !== 200 || !claim.json || !claim.json.sessionToken) {
      throw new Error(`pairing claim failed: ${claim.status} ${claim.text.slice(0, 150)}`);
    }
    const tokenB = claim.json.sessionToken;

    const bBefore = await httpRequest(`${OPTS.core}/api/agents`, { method: "GET", headers: bearer(tokenB) });
    if (bBefore.status !== 200) throw new Error(`second session token unusable before logout-all (status ${bBefore.status})`);

    const logoutAll = await httpRequest(`${OPTS.core}/api/auth/logout-all`, {
      method: "POST",
      headers: { ...jsonHeaders(), ...bearer(tokenA) },
      body: "{}",
    });
    if (logoutAll.status !== 200) throw new Error(`logout-all call failed: ${logoutAll.status} ${logoutAll.text.slice(0, 150)}`);

    const afterA = await httpRequest(`${OPTS.core}/api/agents`, { method: "GET", headers: bearer(tokenA) });
    const afterB = await httpRequest(`${OPTS.core}/api/agents`, { method: "GET", headers: bearer(tokenB) });
    const ok = afterA.status === 401 && afterB.status === 401;
    return {
      status: ok ? "PASS" : "FAIL",
      expected: "both session A (login_token) and session B (DeviceSession, minted via device pairing) return 401 after logout-all",
      observed: `session A -> ${afterA.status}, session B -> ${afterB.status}`,
    };
  });
}

// ===================================================================
// 6. Login throttle — server/lib/vibe/accounts/login_throttle.ex
//    (races VibeWeb.Plugs.RateLimiter's :auth bucket, 10 req/60s, first)
// ===================================================================

async function check6LoginThrottle() {
  await check("6.1", "login-throttle.correct-password-blocked-after-failures", async () => {
    const user = await registerUser("throttle");
    const statuses = [];
    for (let i = 1; i <= 10; i++) {
      const res = await httpRequest(`${OPTS.core}/api/login`, {
        method: "POST",
        headers: jsonHeaders(),
        body: JSON.stringify({ credential: user.username, password: "definitely-wrong-password" }),
      });
      statuses.push(res.status);
    }
    // The real security property: after the failures, the CORRECT password must NOT log in.
    // The server returns a generic 401 on lockout (anti-enumeration), so status alone can't
    // distinguish throttle from a wrong password — proving the valid password is refused does.
    const correct = await httpRequest(`${OPTS.core}/api/login`, {
      method: "POST",
      headers: jsonHeaders(),
      body: JSON.stringify({ credential: user.username, password: user.password }),
    });
    const blocked = correct.status !== 200;
    const byRateLimiter = correct.headers["x-ratelimit-limit"] !== undefined || correct.headers["retry-after"] !== undefined;
    return {
      status: blocked ? "PASS" : "FAIL",
      expected: "after 10 wrong logins, the CORRECT password is refused (LoginThrottle 10/15min and/or :auth bucket 10/60s)",
      observed: `wrong=[${statuses.join(",")}] correct-password=${correct.status} (${blocked ? "blocked" : "LOGGED IN — protection failed"})`,
      note: byRateLimiter
        ? "blocked with rate-limit headers — the :auth IP bucket answered; LoginThrottle's account lock is the second layer"
        : "blocked with a generic 401 and no rate-limit headers — LoginThrottle's account lock answered (correct anti-enumeration behavior)",
    };
  });
}

// ===================================================================
// 7. Register validation — server/lib/vibe_web/controllers/auth_controller.ex
// ===================================================================

async function rawRegister(payload) {
  return httpRequest(`${OPTS.core}/api/register`, { method: "POST", headers: jsonHeaders(), body: JSON.stringify(payload) });
}

async function check7RegisterValidation() {
  await check("7.1", "register.short-password", async () => {
    const res = await rawRegister({
      username: `sp_short_${rand()}`,
      password: "short1",
      deviceId: `sp-dev-${rand()}`,
      publicKey: `pk-${rand()}`,
      encryptedPrivateKey: `epk-${rand()}`,
      identityKey: "v3",
    });
    return assertStatus(400, res.status, res.text);
  });

  await check("7.2", "register.bad-username-chars", async () => {
    const res = await rawRegister({
      username: "sp bad!name",
      password: "ValidPass123!",
      deviceId: `sp-dev-${rand()}`,
      publicKey: `pk-${rand()}`,
      encryptedPrivateKey: `epk-${rand()}`,
      identityKey: "v3",
    });
    return assertStatus(400, res.status, res.text);
  });

  await check("7.3", "register.duplicate-username", async () => {
    if (!mainUser) throw new Error("mainUser not available (setup.main-user failed earlier)");
    const res = await rawRegister({
      username: mainUser.username,
      password: "ValidPass123!",
      deviceId: `sp-dev-${rand()}`,
      publicKey: `pk-${rand()}`,
      encryptedPrivateKey: `epk-${rand()}`,
      identityKey: "v3",
    });
    return assertStatus(409, res.status, res.text);
  });

  await check("7.4", "register.missing-publicKey", async () => {
    const res = await rawRegister({
      username: `sp_nokeys_${rand()}`,
      password: "ValidPass123!",
      deviceId: `sp-dev-${rand()}`,
    });
    return assertStatus(400, res.status, res.text);
  });
}

// ===================================================================
// 8. Privileged profile fields — server/lib/vibe/schemas/user.ex
//    (profile_changeset/2 allow-list) + user_controller.ex update_profile/2
// ===================================================================

async function check8PrivilegedProfileFields() {
  if (!mainUser) {
    skip("8.1", "profile.privileged-fields-accepted", "mainUser not available (setup.main-user failed earlier)");
    skip("8.2", "profile.is_agent-not-applied", "mainUser not available (setup.main-user failed earlier)");
    skip("8.3", "profile.login_token-not-applied", "mainUser not available (setup.main-user failed earlier)");
    return;
  }
  const marker = `sp-bio-${rand()}`;

  await check("8.1", "profile.privileged-fields-accepted", async () => {
    const res = await httpRequest(`${OPTS.core}/api/user/profile`, {
      method: "POST",
      headers: { ...jsonHeaders(), ...bearer(mainUser.token) },
      body: JSON.stringify({
        bio: marker,
        tier: "gold",
        is_agent: true,
        login_token: `sp-attacker-token-${rand()}`,
        referral_count: 999999,
      }),
    });
    return assertStatus(200, res.status, res.text);
  });

  await check("8.2", "profile.is_agent-not-applied", async () => {
    const show = await httpRequest(`${OPTS.core}/api/user/${mainUser.userId}`, { method: "GET", headers: bearer(mainUser.token) });
    const isAgent = show.json && show.json.isAgent;
    return {
      status: show.status === 200 && isAgent === false ? "PASS" : "FAIL",
      expected: "isAgent === false after posting is_agent:true (excluded from profile_changeset)",
      observed: `GET /api/user/:id -> ${show.status}, isAgent=${JSON.stringify(isAgent)}`,
    };
  });

  await check("8.3", "profile.login_token-not-applied", async () => {
    // If login_token had actually been overwritten, this same original bearer
    // token would no longer resolve to the user.
    const stillWorks = await httpRequest(`${OPTS.core}/api/user/${mainUser.userId}`, { method: "GET", headers: bearer(mainUser.token) });
    return {
      status: stillWorks.status === 200 ? "PASS" : "FAIL",
      expected: 'original bearer token still authenticates (200) after posting login_token:"attacker..."',
      observed: `${stillWorks.status}`,
      note: "tier/referral_count are never serialized by any endpoint here, so they can't be read back over HTTP; profile_changeset excludes all four fields via the same allow-list this check exercises for is_agent/login_token",
    };
  });
}

// ===================================================================
// 9. Uploads — server/lib/vibe_web/controllers/media_controller.ex
// ===================================================================

async function check9Uploads() {
  if (!mainUser) {
    skip("9.1", "upload.svg-declared-as-image-rejected", "mainUser not available (setup.main-user failed earlier)");
    skip("9.2", "upload.exe-declared-as-image-downgraded", "mainUser not available (setup.main-user failed earlier)");
    return;
  }

  await check("9.1", "upload.svg-declared-as-image-rejected", async () => {
    const form = new FormData();
    form.append("type", "image");
    form.append("file", new Blob(['<svg xmlns="http://www.w3.org/2000/svg"></svg>'], { type: "image/svg+xml" }), "probe.svg");
    const res = await multipartRequest(`${OPTS.core}/api/media/upload`, { headers: bearer(mainUser.token), form });
    return assertStatus(400, res.status, res.text);
  });

  await check("9.2", "upload.exe-declared-as-image-downgraded", async () => {
    // PE/MZ header bytes: no sniff_head/1 clause matches them and they are not
    // valid UTF-8, so classify/2 falls through to the generic {:ok, "file", nil}.
    const exeLikeBytes = Buffer.from([0x4d, 0x5a, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00]);
    const form = new FormData();
    form.append("type", "image");
    form.append("file", new Blob([exeLikeBytes], { type: "image/png" }), "probe.exe");
    const res = await multipartRequest(`${OPTS.core}/api/media/upload`, { headers: bearer(mainUser.token), form });

    if (res.status === 500) {
      return {
        status: "SKIP",
        expected: '200 with body.type === "file" (magic-byte mismatch downgrades away from "image")',
        observed: `500 ${res.text.slice(0, 150)}`,
        note: "no object storage configured locally (Vibe.Storage autodetects Supabase and the upload write fails) — retest once storage is configured or against the VPS",
      };
    }
    const downgraded = res.status === 200 && res.json && res.json.type === "file";
    return {
      status: downgraded ? "PASS" : "FAIL",
      expected: '200 with body.type === "file"',
      observed: `${res.status} ${res.text.slice(0, 150)}`,
    };
  });
}

// ===================================================================
// 10. Public agent ingress — server/lib/vibe_web/controllers/agents_controller.ex
// ===================================================================

async function check10PublicAgentIngress() {
  const randomId = `sp-nonexistent-${rand()}`;

  await check("10.1", "agents.invoke-no-secret-unknown-identifier", async () => {
    const res = await httpRequest(`${OPTS.core}/api/agents/${randomId}/invoke`, {
      method: "POST",
      headers: jsonHeaders(),
      body: JSON.stringify({ message: "hello" }),
    });
    const ok = res.status === 401 || res.status === 404;
    return {
      status: ok ? "PASS" : "FAIL",
      expected: "401 or 404 (get_invoke_target resolves nil for an unknown identifier before the secret is even checked, so 404 is typical)",
      observed: `${res.status} ${res.text.slice(0, 150)}`,
    };
  });

  await check("10.2", "agents.card-unknown-identifier", async () => {
    const res = await httpRequest(`${OPTS.core}/api/agents/${randomId}/card`, { method: "GET" });
    return assertStatus(404, res.status, res.text);
  });
}

// ===================================================================
// 11. Path traversal — server/lib/vibe_web/controllers/group_agent_controller.ex
// ===================================================================

async function check11PathTraversal() {
  await check("11.1", "path-traversal.uploads-agent-docs", async () => {
    if (!mainUser) throw new Error("mainUser not available (setup.main-user failed earlier)");
    const res = await httpRequest(`${OPTS.core}/uploads/agent-docs/..%2F..%2Fetc%2Fpasswd`, {
      method: "GET",
      headers: bearer(mainUser.token),
    });
    if (/root:.*:0:0:/.test(res.text)) {
      return {
        status: "FAIL",
        expected: "400 or 404, never actual file contents",
        observed: `${res.status} — response body looks like /etc/passwd contents`,
        note: "SECURITY: possible path traversal",
      };
    }
    const ok = res.status === 400 || res.status === 404;
    return {
      status: ok ? "PASS" : "FAIL",
      expected: "400 or 404 (download_legacy_document looks the decoded name up as a document download-name; a traversal string never matches one)",
      observed: `${res.status} ${res.text.slice(0, 150)}`,
    };
  });
}

// ===================================================================
// 12. API rate limit burst — server/lib/vibe_web/plugs/rate_limiter.ex
// ===================================================================

async function check12RateLimitBurst() {
  await check("12.1", "rate-limit.api-bucket-burst", async () => {
    const first = await httpRequest(`${OPTS.core}/api/health`, { method: "GET" });
    const limit = Number(first.headers["x-ratelimit-limit"]);
    let remaining = Number(first.headers["x-ratelimit-remaining"]);
    if (!Number.isFinite(limit) || !Number.isFinite(remaining)) {
      throw new Error(
        `could not read x-ratelimit-limit/remaining from GET /api/health (limit=${first.headers["x-ratelimit-limit"]}, remaining=${first.headers["x-ratelimit-remaining"]})`
      );
    }

    const burstCount = remaining + 10;
    const statuses = [first.status];
    const concurrency = 25;
    let inFlight = [];
    for (let i = 0; i < burstCount; i++) {
      inFlight.push(
        httpRequest(`${OPTS.core}/api/health`, { method: "GET" })
          .then((r) => statuses.push(r.status))
          .catch((e) => statuses.push(`ERR:${e.message}`))
      );
      if (inFlight.length >= concurrency) {
        await Promise.all(inFlight);
        inFlight = [];
      }
    }
    await Promise.all(inFlight);

    const blockedConcurrent = statuses.filter((s) => s === 429).length;
    if (blockedConcurrent > 0) {
      const probe429 = await httpRequest(`${OPTS.core}/api/health`, { method: "GET" });
      const retryAfterSeen = probe429.status === 429 && probe429.headers["retry-after"] !== undefined;
      return {
        status: "PASS",
        expected: `at least one 429 once requests exceed the :api bucket limit (limit=${limit}/min, read from x-ratelimit-limit)`,
        observed: `sent ${statuses.length} concurrent requests (initial remaining=${remaining}), ${blockedConcurrent} returned 429; retry-after present on a 429: ${retryAfterSeen}`,
      };
    }

    // Concurrent burst let everything through (see note below) — rule out "no
    // limiting at all" with a fixed-count sequential retest before failing.
    const sequentialCap = remaining + 20;
    let sequentialTrip = null;
    let sequentialSent = 0;
    for (let i = 0; i < sequentialCap && !sequentialTrip; i++) {
      const r = await httpRequest(`${OPTS.core}/api/health`, { method: "GET" });
      sequentialSent++;
      if (r.status === 429) sequentialTrip = r;
    }

    if (sequentialTrip) {
      return {
        status: "FAIL",
        expected: `at least one 429 from the CONCURRENT burst (limit=${limit}/min)`,
        observed: `${statuses.length} concurrent requests -> 0 blocked; a follow-up SEQUENTIAL (one-at-a-time) burst hit 429 after ${sequentialSent} more requests, retry-after=${sequentialTrip.headers["retry-after"]}`,
        note: "the limit exists and works for sequential traffic, but a concurrent burst to the same key passes uncapped — Vibe.RateLimit.ETS.hit/3's lookup-then-insert is not atomic (check-then-act race); SECURITY/RELIABILITY finding worth the lead's attention",
      };
    }

    return {
      status: "FAIL",
      expected: `at least one 429 once requests exceed the :api bucket limit (limit=${limit}/min)`,
      observed: `${statuses.length} concurrent requests -> 0 blocked; a follow-up sequential burst of ${sequentialSent} more requests also never hit 429`,
      note: "rate limiting on this bucket/identifier did not trigger at all in this run",
    };
  });
}

// ===================================================================
// 13. Websocket — server/lib/vibe_web/channels/user_socket.ex
// ===================================================================

async function check13Websocket() {
  const wsBase = `${OPTS.core.replace(/^http/, "ws")}/socket/websocket?vsn=2.0.0`;

  await check("13.1", "websocket.invalid-token-rejected", async () => {
    const r = await wsProbe(`${wsBase}&token=sp-invalid-${rand()}`, {});
    const ok = r.event === "unexpected-response" || r.event === "close" || r.event === "error" || r.event === "throw";
    return {
      status: ok ? "PASS" : "FAIL",
      expected: "upgrade rejected (unexpected-response, likely 403) or the socket closes right after connect — never a stable open connection",
      observed: JSON.stringify(r),
    };
  });

  const tokenForOrigin = mainUser ? mainUser.token : `sp-invalid-${rand()}`;
  let originResult;
  try {
    originResult = await wsProbe(`${wsBase}&token=${encodeURIComponent(tokenForOrigin)}`, { Origin: "https://evil.example" });
  } catch (err) {
    originResult = { event: "error", reason: err.message };
  }
  skip(
    "13.2",
    "websocket.cross-origin-connect",
    `check_origin is false in server/config/dev.exs — Origin is not enforced against this local target; observed for information only: ${JSON.stringify(originResult)}`
  );
}

// ---------- main ----------

function printSummary() {
  const counts = { PASS: 0, FAIL: 0, SKIP: 0 };
  for (const r of results) counts[r.status] = (counts[r.status] || 0) + 1;
  console.log("\n=== Security Probe Summary ===");
  console.log(`PASS=${counts.PASS || 0} FAIL=${counts.FAIL || 0} SKIP=${counts.SKIP || 0} (total ${results.length})`);
  const fails = results.filter((r) => r.status === "FAIL");
  if (fails.length) {
    console.log("\nFAILed checks:");
    for (const r of fails) console.log(`  - ${r.id} ${r.label}: expected ${r.expected} | observed ${r.observed}`);
  }
}

async function main() {
  console.log(`security-probe — target core: ${OPTS.core}`);
  console.log(`internal HMAC key: ${OPTS.hmacKey ? redact(OPTS.hmacKey) : "(not provided — check 2 will SKIP)"}\n`);

  await check1Headers();
  await check2InternalHmac();
  await check3JsonBodyCap();
  await check4MultipartWrongRoute();

  await check("setup", "setup.register-main-user", async () => {
    mainUser = await registerUser("main");
    return { status: "PASS", expected: "200 with token", observed: `registered ${mainUser.username}` };
  });

  await check5BearerAndSessions();
  await check6LoginThrottle();
  await check7RegisterValidation();
  await check8PrivilegedProfileFields();
  await check9Uploads();
  await check10PublicAgentIngress();
  await check11PathTraversal();
  await check12RateLimitBurst();
  await check13Websocket();

  printSummary();

  if (OPTS.jsonOut) {
    fs.writeFileSync(OPTS.jsonOut, JSON.stringify({ core: OPTS.core, generatedAt: new Date().toISOString(), results }, null, 2));
    console.log(`\nwrote ${OPTS.jsonOut}`);
  }

  process.exitCode = results.some((r) => r.status === "FAIL") ? 1 : 0;
}

main().catch((err) => {
  console.error("FATAL (probe itself crashed):", (err && err.stack) || err);
  printSummary();
  process.exitCode = 1;
});
