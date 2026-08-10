#!/usr/bin/env bash
# neon-shooter adapter + lobby conformance on Match Platform V3.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # match-platform repo root
godot="${GODOT:-godot}"
"$godot" --headless --path "$root" --import >/dev/null 2>&1 || true
for t in neon_adapter_platform_test shooter_lobby_test; do
  log="$(mktemp)"
  "$godot" --headless --path "$root" --script "res://games/neon-shooter/tests/${t}.gd" 2>&1 | tee "$log"
  grep -q '^PASS:' "$log"
  if grep -Eq 'SCRIPT ERROR|Parse Error' "$log"; then echo "conformance run logged a script error" >&2; exit 1; fi
done
echo "PASS: neon-shooter adapter + lobby conformance on Match Platform V3"
