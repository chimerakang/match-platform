#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="${MATCH_PLATFORM_RPC_PYTHON:-python3}"

"$python_bin" -c 'import google.protobuf, grpc' >/dev/null
command -v go >/dev/null

PYTHONPATH="$root:$root/rpc/gen/python" \
  "$python_bin" -m unittest discover \
  -s "$root/rpc/conformance/python" -p 'test_*.py'
(cd "$root/rpc" && go test ./conformance/go)
(cd "$root/rpc" && go test -race ./runtime ./recovery ./reference/counter ./gateway/... ./operations)

echo "PASS: Adapter RPC v1 conformance, runtime, recovery, gateway and package operations"
