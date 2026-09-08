#!/usr/bin/env node
/**
 * seed.js — creates N throwaway users + a group chat + paired DM chats directly
 * in Postgres (bypassing /api/register, which is rate-limited and does real
 * pbkdf2 work) so ws-storm.js and http-flood.sh have real, valid login_tokens
 * to connect with.
 *
 * Usage:
 *   node seed.js --users N [--group-size G] [--prefix lt]
 *
 * Writes scripts/loadtest/results/seed-<prefix>.json:
 *   { users: [{id, username, token, inGroup}], groupChatId, dmChatIds: [{chatId, users:[id,id]}] }
 *
 * Idempotent per --prefix: deletes any chats owned by <prefix>_* users (which
 * cascades their messages + chat_participants), then deletes the <prefix>_*
 * users themselves, before inserting the fresh batch. Re-running with the same
 * --prefix always leaves exactly one clean generation behind.
 *
 * All SQL is written to a temp file and run via `psql <url> -v ON_ERROR_STOP=1
 * -f <file>` (argv array, no shell) — user-controlled values (just our own
 * generated usernames/tokens here) are never interpolated into a shell string.
 */
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}
const hasFlag = (name) => process.argv.includes(`--${name}`);
const DRY_RUN = hasFlag("dry-run");

function usageError(msg) {
  console.error(msg);
  console.error("usage: node seed.js --users N [--group-size G] [--prefix lt]");
  process.exit(2);
}

const USERS_ARG = arg("users", null);
const PREFIX = arg("prefix", "lt");
const DATABASE_URL =
  process.env.DATABASE_URL || "postgres://postgres:postgres@localhost:5432/vibe_dev";

if (USERS_ARG === null) usageError("missing --users");
const USERS = parseInt(USERS_ARG, 10);
if (!Number.isInteger(USERS) || USERS < 2) usageError("--users must be an integer >= 2");
if (!/^[a-zA-Z0-9]{1,16}$/.test(PREFIX)) {
  usageError("--prefix must be 1-16 alphanumeric characters (used in usernames and LIKE cleanup)");
}

const GROUP_SIZE_ARG = arg("group-size", null);
const GROUP_SIZE = GROUP_SIZE_ARG === null ? USERS : parseInt(GROUP_SIZE_ARG, 10);
if (!Number.isInteger(GROUP_SIZE) || GROUP_SIZE < 1 || GROUP_SIZE > USERS) {
  usageError(`--group-size must be an integer between 1 and --users (${USERS})`);
}

if (USERS > 50000) {
  console.error(`[seed] warning: seeding ${USERS} users — this can take a while and produces a large SQL file.`);
}

const RESULTS_DIR = path.join(__dirname, "results");
fs.mkdirSync(RESULTS_DIR, { recursive: true });

function sqlString(value) {
  // Single-quoted SQL literal, embedded quotes doubled. Only ever spliced into
  // the generated .sql TEXT FILE below — never into a shell command string.
  return "'" + String(value).replace(/'/g, "''") + "'";
}

function pgTimestamp(date) {
  // 'YYYY-MM-DD HH:MI:SS' — no offset, so Postgres stores it verbatim into the
  // `timestamp without time zone` columns (users/chats/chat_participants all
  // use timestamps() with no tz), matching how Ecto itself writes UTC-naive.
  return date.toISOString().slice(0, 19).replace("T", " ");
}

function chunk(array, size) {
  const out = [];
  for (let i = 0; i < array.length; i += size) out.push(array.slice(i, i + size));
  return out;
}

function pad(i) {
  return String(i).padStart(6, "0");
}

// ---- build the fixture in memory -------------------------------------------------

const now = new Date();
const nowSql = pgTimestamp(now);
const expiresSql = pgTimestamp(new Date(now.getTime() + 24 * 60 * 60 * 1000));

const users = [];
for (let i = 0; i < USERS; i++) {
  users.push({
    id: crypto.randomUUID(),
    username: `${PREFIX}_${pad(i)}`,
    token: crypto.randomUUID(),
    // Well-formed `saltHex:hashHex` so a wrong-password login attempt against
    // this user actually runs the full 600k-iteration pbkdf2 compare in
    // Vibe.Accounts.verify_password_with_info/2 (see server/lib/vibe/accounts.ex)
    // instead of failing fast on Base.decode16 — the CPU cost http-flood.sh's
    // scenario 3 is there to demonstrate. The value never has to verify true.
    passwordHash: `${crypto.randomBytes(16).toString("hex")}:${crypto.randomBytes(32).toString("hex")}`,
    inGroup: i < GROUP_SIZE,
  });
}

const groupChatId = crypto.randomUUID().replace(/-/g, "").slice(0, 12);

const dmChats = [];
for (let i = 0; i + 1 < users.length; i += 2) {
  dmChats.push({
    chatId: crypto.randomUUID().replace(/-/g, "").slice(0, 12),
    users: [users[i].id, users[i + 1].id],
    usernames: [users[i].username, users[i + 1].username],
  });
}
if (users.length % 2 === 1) {
  console.error(`[seed] note: ${users.length} is odd — last user (${users[users.length - 1].username}) has no DM pair.`);
}

// ---- render SQL --------------------------------------------------------------------

const sqlParts = [];

sqlParts.push(
  "-- Idempotent per prefix: remove any previous generation's chats (cascades",
  "-- their messages + chat_participants) and then its users.",
  `DELETE FROM chats WHERE id IN (`,
  `  SELECT DISTINCT cp.chat_id FROM chat_participants cp`,
  `  JOIN users u ON u.id = cp.user_id`,
  `  WHERE u.username LIKE ${sqlString(PREFIX + "\\_%")} ESCAPE '\\'`,
  `);`,
  `DELETE FROM users WHERE username LIKE ${sqlString(PREFIX + "\\_%")} ESCAPE '\\';`,
  ""
);

for (const batch of chunk(users, 500)) {
  const rows = batch.map((u) =>
    "(" +
      [
        sqlString(u.id),
        sqlString(u.username),
        sqlString(u.passwordHash),
        sqlString(`loadtest-pubkey-${u.username}`),
        sqlString("v3"),
        sqlString(`loadtest-device-${u.username}`),
        sqlString(u.token),
        sqlString(`loadtest-secure-${u.username}`),
        sqlString(expiresSql),
        sqlString(nowSql),
        sqlString(nowSql),
        sqlString(nowSql),
      ].join(", ") +
    ")"
  );
  sqlParts.push(
    "INSERT INTO users (id, username, password_hash, public_key, identity_key, device_id, login_token, secure_id, token_expires_at, token_issued_at, inserted_at, updated_at) VALUES",
    rows.join(",\n") + ";",
    ""
  );
}

sqlParts.push(
  "INSERT INTO chats (id, is_group, name, type, creator_id, inserted_at, updated_at) VALUES",
  `(${[
    sqlString(groupChatId),
    "true",
    sqlString(`Load Test Group (${PREFIX})`),
    sqlString("group"),
    sqlString(users[0].id),
    sqlString(nowSql),
    sqlString(nowSql),
  ].join(", ")});`,
  ""
);

for (const batch of chunk(dmChats, 500)) {
  const rows = batch.map((d) =>
    "(" +
      [sqlString(d.chatId), "false", "NULL", sqlString("dm"), "NULL", sqlString(nowSql), sqlString(nowSql)].join(", ") +
    ")"
  );
  sqlParts.push(
    "INSERT INTO chats (id, is_group, name, type, creator_id, inserted_at, updated_at) VALUES",
    rows.join(",\n") + ";",
    ""
  );
}

const groupMembers = users.filter((u) => u.inGroup);
for (const batch of chunk(groupMembers, 500)) {
  const rows = batch.map(
    (u) =>
      "(" +
        [
          sqlString(groupChatId),
          sqlString(u.id),
          sqlString(u.id === users[0].id ? "owner" : "member"),
          sqlString(nowSql),
          sqlString(nowSql),
        ].join(", ") +
      ")"
  );
  sqlParts.push(
    "INSERT INTO chat_participants (chat_id, user_id, role, inserted_at, updated_at) VALUES",
    rows.join(",\n") + ";",
    ""
  );
}

const dmParticipantRows = [];
for (const d of dmChats) {
  for (const uid of d.users) {
    dmParticipantRows.push(
      "(" +
        [sqlString(d.chatId), sqlString(uid), sqlString("member"), sqlString(nowSql), sqlString(nowSql)].join(", ") +
      ")"
    );
  }
}
for (const batch of chunk(dmParticipantRows, 500)) {
  sqlParts.push(
    "INSERT INTO chat_participants (chat_id, user_id, role, inserted_at, updated_at) VALUES",
    batch.join(",\n") + ";",
    ""
  );
}

const sqlText = sqlParts.join("\n") + "\n";

const tmpFile = path.join(os.tmpdir(), `vibe-loadtest-seed-${PREFIX}-${process.pid}.sql`);
fs.writeFileSync(tmpFile, sqlText, "utf8");

if (DRY_RUN) {
  console.log(`[seed] --dry-run: SQL written to ${tmpFile}, not executed, no results json written.`);
  process.exit(0);
}

// spawnSync with an argv array (no shell) — the SQL text file carries every
// value, so nothing here is ever interpreted by a shell.
const result = spawnSync("psql", [DATABASE_URL, "-v", "ON_ERROR_STOP=1", "-f", tmpFile], {
  stdio: "inherit",
  encoding: "utf8",
});

if (result.error || result.status !== 0) {
  console.error(`[seed] psql failed (status=${result.status}). SQL file kept at ${tmpFile} for inspection.`);
  process.exit(1);
}

fs.unlinkSync(tmpFile);

const seedOut = {
  prefix: PREFIX,
  createdAt: now.toISOString(),
  users: users.map((u) => ({ id: u.id, username: u.username, token: u.token, inGroup: u.inGroup })),
  groupChatId,
  dmChatIds: dmChats.map((d) => ({ chatId: d.chatId, users: d.users, usernames: d.usernames })),
};

const outPath = path.join(RESULTS_DIR, `seed-${PREFIX}.json`);
fs.writeFileSync(outPath, JSON.stringify(seedOut, null, 2) + "\n", "utf8");

console.log(`[seed] users: ${users.length} (group members: ${groupMembers.length}, dm pairs: ${dmChats.length})`);
console.log(`[seed] groupChatId: ${groupChatId}`);
console.log(`[seed] wrote ${outPath}`);
