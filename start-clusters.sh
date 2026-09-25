#!/usr/bin/env bash
# Usage: start-clusters.sh <postgres bin dir>. Starts "prod" on 55432 and "target" on 55433.
set -euo pipefail
BIN=$1
for spec in prod:55432 target:55433; do
  name=${spec%%:*}; port=${spec##*:}
  "$BIN/initdb" -D "$RUNNER_TEMP/$name" -U postgres --auth=trust --locale=C.UTF-8 > /dev/null
  "$BIN/pg_ctl" -D "$RUNNER_TEMP/$name" -l "$RUNNER_TEMP/$name.log" \
    -o "-p $port -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp" start > /dev/null
done
echo "$BIN" >> "$GITHUB_PATH"
