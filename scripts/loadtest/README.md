# Vibe load test harness

Measures per-connection cost, join latency, and message fan-out latency
against a locally-running core (`docs/capacity-500k.md` is the write-up).
Needs: `psql`, `oha` (both already installed) and this repo's root
`node_modules` (`ws`) — no separate `npm install` here.

Run the core first (`cd server && mix phx.server`), then from
`scripts/loadtest/`, in order:

## 1. Seed fixture data
```
node seed.js --users 5000 --group-size 5000 --prefix lt
```
Inserts N real users into Postgres with valid `login_token`s, one group chat
(first `--group-size` users), and DM chats pairing user `i` with `i+1`. Writes
`results/seed-lt.json`. Safe to re-run with the same `--prefix` (deletes the
previous generation first). `--dry-run` renders the SQL without touching the DB.

## 2. WebSocket connection storm
```
ulimit -n 65536   # raise the shell's fd limit before a big --conns
node ws-storm.js --seed results/seed-lt.json --conns 5000 --ramp 200 \
  --hold 60 --senders 5 --msg-rate 2
```
Opens `--conns` sockets (ramping at `--ramp`/sec), joins the group chat (add
`--dm` for each connection's own DM instead), holds, and has `--senders` of
them push messages at `--msg-rate` msgs/s/sender while every connection times
delivery. Add `--beam-pid <pid>` (`pgrep beam.smp`) to sample RSS before/after.
Writes `results/ws-storm-<label>.json` + `results/metrics-*.txt`.

## 3. HTTP flood
```
./http-flood.sh --seed results/seed-lt.json --rps 200 -c 50 --duration 15s
```
Runs three `oha` scenarios in order — `GET /api/health` (no DB), `GET
/api/chats/:userId` (DB path, Bearer auth), `POST /api/login` with a wrong
password (pbkdf2 CPU path). Scenario 3 mostly 429s past the first ~10
requests (the `:auth` rate bucket) — that's the finding, not a bug. Writes
`results/http-flood-*.json`.
