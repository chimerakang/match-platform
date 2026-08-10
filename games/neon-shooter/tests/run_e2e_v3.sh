#!/usr/bin/env bash
# Live V3 end-to-end: boot the multi-arena server host, connect a NetClientV3.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # match-platform repo root
godot="${GODOT:-godot}"
port="${PS_PORT:-28567}"
server_log="${PS_SERVER_LOG:-/tmp/neon-v3-server.log}"
client_log="${PS_CLIENT_LOG:-/tmp/neon-v3-client.log}"
"$godot" --headless --path "$root" --import >/dev/null 2>&1 || true
PS_PORT="$port" PS_BIND=127.0.0.1 \
  "$godot" --headless --path "$root" --script res://games/neon-shooter/server/server_main.gd >"$server_log" 2>&1 &
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT
ready=0
for _i in $(seq 1 100); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 3<&-; ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "server did not start"; cat "$server_log"; exit 1; }
PS_URL="ws://127.0.0.1:$port" \
  "$godot" --headless --path "$root" --script res://games/neon-shooter/tests/e2e_v3_client.gd 2>&1 | tee "$client_log"
grep -q '^PASS:' "$client_log"
if grep -Eq 'SCRIPT ERROR|Parse Error' "$client_log"; then echo "client logged a script error"; exit 1; fi
echo "PASS: neon-shooter V3 live end-to-end"
