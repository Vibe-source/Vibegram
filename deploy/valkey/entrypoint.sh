#!/bin/sh
# requirepass comes from env (VALKEY_PASSWORD), not the static mounted conf —
# compose can't template secrets into a plain volume-mounted file.
set -eu
exec valkey-server /usr/local/etc/valkey/valkey.conf --requirepass "$VALKEY_PASSWORD"
