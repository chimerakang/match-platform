# Adapter RPC v1

`adapter/v1/adapter.proto` is the process boundary between Match Platform Core and a
game adapter. It mirrors every operation of `MatchGameAdapter`; game-owned values are
always `OpaquePayload` bytes tagged with a negotiated codec.

Generated Go and Python client/server bindings are committed under `gen/`. Regenerate:

```sh
bash tools/generate_adapter_rpc.sh
```

Run the cross-language golden conformance suite:

```sh
bash tests/run_adapter_rpc_conformance.sh
```

Probe a running endpoint without decoding any game payload:

```sh
HERSIR_RPC_PYTHON=.venv/bin/python \
  python tools/adapter_rpc_probe.py --endpoint 127.0.0.1:50051
```

The normative versioning, ordering, retry, deadline, limit and canonical-encoding rules
are in [ADR 0005](../docs/adr/0005-adapter-rpc-v1.md).
