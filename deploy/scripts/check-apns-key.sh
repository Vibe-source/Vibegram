#!/bin/bash
# Does this .p8 + Key ID + Team ID actually authenticate at Apple? Mints a
# provider JWT and sends one push to a dummy device token.
#   400 BadDeviceToken   = credentials good (the dummy token is the only fault)
#   403 InvalidProviderToken = the trio is wrong or the key is revoked
# Usage: deploy/scripts/check-apns-key.sh ~/Downloads/AuthKey_XXXXXXXXXX.p8
set -euo pipefail
P8="${1:?usage: check-apns-key.sh /path/to/AuthKey_XXXXXXXXXX.p8}"
[ -f "$P8" ] || { echo "no file at $P8" >&2; exit 1; }
KID="${APNS_KEY_ID:-$(basename "$P8" | sed -n 's/^AuthKey_\(.*\)\.p8$/\1/p')}"
[ -n "$KID" ] || read -r -p "Key ID (10 chars): " KID
read -r -p "Team ID (10 chars): " TEAM
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
HDR=$(printf '{"alg":"ES256","kid":"%s"}' "$KID" | b64url)
CLM=$(printf '{"iss":"%s","iat":%d}' "$TEAM" "$(date +%s)" | b64url)
SIG_DER=$(mktemp); trap 'rm -f "$SIG_DER"' EXIT
printf '%s.%s' "$HDR" "$CLM" | openssl dgst -sha256 -sign "$P8" -out "$SIG_DER"
SIG=$(python3 - "$SIG_DER" <<'PY'
import sys, base64
d = open(sys.argv[1], 'rb').read()
i = 2 if d[1] < 0x80 else 3
assert d[i] == 0x02; l = d[i+1]; r = d[i+2:i+2+l]; i = i+2+l
assert d[i] == 0x02; l = d[i+1]; s = d[i+2:i+2+l]
raw = r.lstrip(b'\x00').rjust(32, b'\x00') + s.lstrip(b'\x00').rjust(32, b'\x00')
print(base64.urlsafe_b64encode(raw).decode().rstrip('='))
PY
)
BODY=$(curl -s --http2 -w '\nhttp_status=%{http_code}' \
  -H "authorization: bearer $HDR.$CLM.$SIG" \
  -H "apns-topic: com.vibegram.app" -H "apns-push-type: alert" \
  -d '{"aps":{"alert":"probe"}}' \
  "https://api.push.apple.com/3/device/$(printf '0%.0s' {1..64})")
echo "$BODY"
case "$BODY" in
  *BadDeviceToken*) echo "=> CREDENTIALS GOOD. Store them:"
    echo "   deploy/scripts/set-missing-env.sh --from-file APPLE_VOIP_PRIVATE_KEY $P8"
    echo "   deploy/scripts/set-missing-env.sh APPLE_VOIP_KEY_ID APPLE_VOIP_TEAM_ID --restart" ;;
  *InvalidProviderToken*) echo "=> REJECTED: this .p8/Key ID/Team ID trio is wrong or the key is revoked." ;;
esac
