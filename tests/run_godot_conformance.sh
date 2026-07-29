#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v godot >/dev/null

for test_name in platform_core_test v3_contract_test reference_game_adapter_test operations_sdk_test; do
  log_file="$(mktemp)"
  godot --headless --path "$root" --script "res://tests/${test_name}.gd" 2>&1 | tee "$log_file"
  grep -q '^PASS:' "$log_file"
  if grep -Eq 'SCRIPT ERROR|Parse Error' "$log_file"; then
    exit 1
  fi
done

echo "PASS: standalone Godot platform, reference adapter and operations conformance"
