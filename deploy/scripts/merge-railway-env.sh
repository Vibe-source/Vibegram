#!/bin/bash
# Carries the old host's values into deploy/env/*.env. Reads `railway variables
# --json` on stdin so the values go Mac -> ssh -> file and are never rendered:
#
#   railway variables --json | agix secret run --only VPS_HOST -- sh -c \
#     'ssh vibe@$VPS_HOST "/opt/vibe/deploy/scripts/merge-railway-env.sh"'
#
# Run AFTER init-env.sh: anything listed here overwrites what init-env generated,
# which is how SECRET_KEY_BASE survives the move and keeps every session signed in.
# Prints names only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="${REPO_ROOT}/deploy/env"

# Deliberately NOT carried: DATABASE_URL and SUPABASE_DB_PASSWORD (the new box
# has its own Postgres), RAILWAY_*, PORT/PHX_SERVER/PHX_HOST (set per host).
python3 - "$ENV_DIR" "${1:--}" <<'PY'
import json, os, sys

env_dir, src = sys.argv[1], sys.argv[2]

CORE = [
    "SECRET_KEY_BASE",
    "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "TAVILY_API_KEY",
    "R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET",
    "R2_PUBLIC_BASE_URL", "MEDIA_CDN_BASE_URL",
    "APPLE_VOIP_APNS_ENV", "APPLE_VOIP_TEAM_ID", "APPLE_VOIP_KEY_ID",
    "APPLE_VOIP_PRIVATE_KEY", "APPLE_VOIP_TOPIC", "APPLE_BUNDLE_ID",
    "FCM_SERVER_KEY", "TURN_URL", "TURN_USERNAME", "TURN_CREDENTIAL",
    "YOUTUBE_API_KEY", "VIBE_HMAC_SECRET", "MCP_CARGO_KEY",
    "LEMON_SQUEEZY_API_KEY", "LEMON_SQUEEZY_STORE_ID", "LEMON_SQUEEZY_WEBHOOK_SECRET",
    "CORS_ORIGINS", "PHX_CHECK_ORIGIN", "PUBLIC_BASE_URL", "API_BASE_URL",
]
RUNTIME = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "TAVILY_API_KEY"]

raw = (sys.stdin.read() if src == "-" else open(src).read()).strip()
if not raw:
    sys.exit("merge-railway-env: nothing on stdin")
data = json.loads(raw)
if isinstance(data, list):  # some CLI versions emit [{name, value}, ...]
    data = {d["name"]: d.get("value", "") for d in data}


def merge(filename, names):
    path = os.path.join(env_dir, filename)
    if not os.path.exists(path):
        print(f"skip   {filename} (not created yet — run init-env.sh first)")
        return
    lines = open(path).read().splitlines(keepends=True)
    seen, set_names, missing = set(), [], []
    for name in names:
        value = data.get(name)
        if value is None or value == "":
            missing.append(name)
            continue
        replaced = False
        for i, line in enumerate(lines):
            if line.startswith(name + "="):
                lines[i] = f"{name}={value}\n"
                replaced = True
                break
        if not replaced:
            lines.append(f"{name}={value}\n")
        set_names.append(name)
        seen.add(name)
    open(path, "w").writelines(lines)
    os.chmod(path, 0o600)
    print(f"{filename}: set {len(set_names)} -> {' '.join(set_names)}")
    if missing:
        print(f"{filename}: absent on the old host -> {' '.join(missing)}")


merge("core.env", CORE)
merge("agent-runtime.env", RUNTIME)
PY

echo "done — values written, never printed"
