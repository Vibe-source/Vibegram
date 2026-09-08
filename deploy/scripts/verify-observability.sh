#!/bin/bash
# Proves the monitoring path is real: datasources reachable, dashboard loaded,
# alert rules provisioned, every Prometheus target up, logs arriving in Loki.
# Runs ON the VPS. Exits non-zero if anything is missing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GF=http://127.0.0.1:3000
PROM=http://127.0.0.1:9090
fails=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
head2() { printf '\n\033[1m%s\033[0m\n' "$*"; }

pw="$(grep -m1 '^GF_SECURITY_ADMIN_PASSWORD=' "${REPO_ROOT}/deploy/env/monitoring.env" | cut -d= -f2-)"
gf() { curl -sS -u "admin:${pw}" "${GF}$1"; }

head2 "GRAFANA"
ds="$(gf /api/datasources)"
for name in Prometheus Loki; do
  case "$ds" in *"\"name\":\"${name}\""*) pass "datasource ${name}" ;;
                *) fail "datasource ${name} missing" ;; esac
done

case "$(gf '/api/dashboards/uid/vibe-overview')" in
  *'"title":"Vibe — overview"'*) pass "dashboard vibe-overview loaded" ;;
  *) fail "dashboard vibe-overview not provisioned" ;;
esac

rules="$(gf /api/v1/provisioning/alert-rules | tr ',' '\n' | grep -c '"title"')"
if [ "${rules:-0}" -ge 8 ]; then pass "alert rules provisioned (${rules})"
else fail "only ${rules:-0} alert rules provisioned (expected 8+)"; fi

case "$(gf /api/v1/provisioning/contact-points)" in
  *'"name":"vibe-email"'*) pass "contact point vibe-email" ;;
  *) fail "contact point vibe-email missing" ;;
esac

head2 "PROMETHEUS TARGETS"
targets="$(curl -sS "${PROM}/api/v1/targets?state=active")"
for job in core agent-runtime node valkey; do
  block="$(printf '%s' "$targets" | tr '{' '\n' | grep "\"job\":\"${job}\"")"
  if [ -z "$block" ]; then fail "job ${job}: not configured"
  elif printf '%s' "$targets" | tr '}' '\n' | grep -q "\"job\":\"${job}\".*\"health\":\"up\"" ||
       printf '%s' "$targets" | grep -q "\"job\":\"${job}\"[^!]*\"up\""; then pass "job ${job}: up"
  else fail "job ${job}: down"; fi
done

head2 "APPLICATION METRICS"
core_metrics="$(podman exec deploy_core_1 wget -qO- http://127.0.0.1:9568/metrics 2>/dev/null)"
for m in phoenix_endpoint_stop_duration_milliseconds vibe_repo_query_total_time_milliseconds \
         vm_memory_total; do
  case "$core_metrics" in *"$m"*) pass "exports ${m}" ;;
                          *) fail "missing ${m}" ;; esac
done

# Counters only reach /metrics after their first event, so registration is the
# real check; an emitted value just means traffic has already exercised it.
registered="$(podman exec deploy_core_1 /app/bin/vibe rpc \
  'Vibe.Telemetry.Metrics.metrics() |> Enum.map_join(" ", &Enum.join(&1.name, ".")) |> IO.puts()' \
  2>/dev/null)"
for pair in 'vibe.cache.token.count|vibe_cache_token_count' \
            'vibe.rate_limit.blocked.count|vibe_rate_limit_blocked_count'; do
  ev="${pair%%|*}"; prom="${pair##*|}"
  if ! printf '%s' "$registered" | grep -qF "$ev"; then
    fail "counter ${prom} not registered in Vibe.Telemetry.Metrics"
  elif printf '%s' "$core_metrics" | grep -qF "$prom"; then
    pass "counter ${prom} registered and emitting"
  else
    pass "counter ${prom} registered (no event yet)"
  fi
done

head2 "LOGS"
labels="$(podman exec deploy_loki_1 wget -qO- \
  'http://localhost:3100/loki/api/v1/label/container/values' 2>/dev/null)"
for c in deploy_core_1 deploy_postgres_1 deploy_caddy_1; do
  case "$labels" in *"$c"*) pass "loki has ${c}" ;;
                    *) fail "loki has no logs for ${c}" ;; esac
done

printf '\n\033[1mresult:\033[0m %s fail\n' "$fails"
[ "$fails" -eq 0 ]
