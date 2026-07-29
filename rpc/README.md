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

## Supervised process runtime

`runtime.ProcessRuntime` implements the complete generated `AdapterServiceClient`
surface and the platform-owned `runtime.AdapterRuntime` lifecycle. It starts one
adapter process per failure domain, waits for RPC health readiness, applies bounded
concurrency and queues, enforces deadlines and uncompressed protobuf limits, and
restarts a crashed or unresponsive process with a new instance id and epoch.

Production configuration requires transport credentials and rejects non-loopback
adapter endpoints. `AllowInsecureTests` exists only for hermetic local fixtures. See
[the process runtime guide](../docs/adapter-process-runtime.md).

## Durable recovery

`recovery.Coordinator` adds a write-ahead command journal, atomic committed watermark,
versioned checkpoints, fresh-epoch replay and per-step state-hash verification around
the supervised runtime. `recovery.Store` is the provider interface and `FileStore` is
the fsync/rename-based local and CI implementation. See
[the durable recovery guide](../docs/adapter-durable-recovery.md).

## Non-Godot reference adapter

`reference/counter` is a standalone Go implementation of the counter reference game.
It depends only on generated Adapter RPC v1 bindings, implements the complete opaque
lifecycle, preserves Godot-compatible state hashes/replays, supports production mTLS
and ships with a non-root container. Its black-box fixture starts the real binary
through `ProcessRuntime`, forces a crash and verifies checkpoint plus journal
recovery. See the [third-party implementation guide](reference/counter/README.md).
