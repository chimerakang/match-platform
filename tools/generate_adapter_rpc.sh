#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
proto="$root/rpc/adapter/v1/adapter.proto"
python_out="$root/rpc/gen/python"
go_out="$root/rpc/gen/go"
python_bin="${MATCH_PLATFORM_RPC_PYTHON:-python3}"

command -v protoc >/dev/null
command -v protoc-gen-go >/dev/null
command -v protoc-gen-go-grpc >/dev/null
"$python_bin" -c 'import grpc_tools.protoc' >/dev/null

mkdir -p "$python_out" "$go_out"
"$python_bin" -m grpc_tools.protoc -I "$root/rpc" \
  --python_out="$python_out" \
  --pyi_out="$python_out" \
  --grpc_python_out="$python_out" \
  "$proto"
protoc -I "$root/rpc" \
  --go_out="$go_out" --go_opt=paths=source_relative \
  --go-grpc_out="$go_out" --go-grpc_opt=paths=source_relative \
  "$proto"

echo "Generated Adapter RPC v1 bindings in rpc/gen/{python,go}."
