# Supervised Adapter Process Runtime (#274)

`rpc/runtime.ProcessRuntime` is the process-isolated implementation of the
`AdapterRuntime` boundary. It wraps every Adapter RPC v1 method, while the trusted
Godot `InProcessRuntime` remains available as the compatibility deployment.

## Ownership and lifecycle

One runtime instance owns exactly one adapter package failure domain:

```text
match platform
  └─ ProcessRuntime (package, queue, circuit, telemetry)
       ├─ child process
       └─ loopback mTLS gRPC ── AdapterService v1
```

`Start` creates a random adapter instance id, increments the epoch, starts the
configured executable, and waits until `Health` reports `SERVING`. A process exit or
failed liveness window closes the old connection and applies the bounded restart
policy. Every restart gets a new instance id and a strictly greater epoch.

Production construction accepts only an operations-verified sandbox launcher and
starts it with a clean environment. Raw adapter commands and ambient host-environment
inheritance are local-test-only. See
[`adapter-package-operations-runbook.md`](adapter-package-operations-runbook.md).

`Drain` rejects new work, waits for accepted calls up to the configured drain
deadline, closes the gRPC connection, and terminates the child. `Kill` is an explicit
operations/fault-injection hook; normal callers should use `Drain`.

## Failure and capacity rules

- `MaxConcurrent` bounds RPCs executing inside one adapter.
- `QueueCapacity` bounds callers waiting for execution. Overflow returns
  `resource_exhausted` immediately.
- Each adapter owns separate semaphores and a separate circuit breaker, so a slow or
  broken package cannot consume another package's queue.
- `CallTimeout` supplies the maximum deadline when the caller has no earlier one.
  Cancellation and deadline expiry receive distinct stable runtime codes.
- Request and response protobuf sizes are checked uncompressed. Oversized values are
  never partially delivered.
- A reply without `ResponseMeta` is `malformed_reply`.
- The runtime snapshots the process epoch before dispatch. A completion after restart,
  or metadata naming another instance/epoch, is `stale_epoch` and is never returned as
  an adapter result.
- Consecutive transport/framing failures open only that package's circuit.

Runtime failures are returned as `runtime.Error`. Error details and telemetry never
contain opaque game payloads.

## Workload identity

Production construction requires `credentials.TransportCredentials`; the adapter
endpoint must resolve to loopback. Operators should load a client certificate issued
to the platform workload and pin the adapter server name/CA in the TLS configuration.
The clean child environment receives only these platform-owned values:

- `HERSIR_ADAPTER_RPC_ENDPOINT`
- `HERSIR_ADAPTER_INSTANCE_ID`
- `HERSIR_ADAPTER_EPOCH`
- `HERSIR_PLATFORM_WORKLOAD_IDENTITY`

The endpoint is not a public client protocol and must not be published through the
game gateway. `AllowInsecureTests` is rejected unless explicitly enabled by a local
test configuration.

## Telemetry

`Telemetry()` returns a snapshot partitioned by adapter package, runtime id and current
epoch. It includes process starts/crashes/restarts, calls/failures, queue rejection,
circuit openings, in-flight/queue depth, latency totals/maxima, and operation/error
counts.

## Verification

```sh
bash tests/run_adapter_rpc_conformance.sh
```

The registered Go suite starts real child test processes and gRPC endpoints. It covers
readiness, forced kill/restart, epoch changes, deadline, malformed and oversized
replies, request limits, queue saturation, circuit isolation, stale-response
suppression, the mTLS/loopback boundary, race detection, and a 5 ms average local RPC
overhead budget.

The durable checkpoint/journal coordinator is implemented by #275 under
`rpc/recovery`; this runtime still rejects prior-epoch responses and lets that
coordinator restore a known checkpoint on the new epoch. The reference non-Godot
adapter and complete opaque codec lifecycle are implemented by #276 under
`rpc/reference/counter`, including a real-process forced-restart fixture.
