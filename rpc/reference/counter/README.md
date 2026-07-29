# Counter Reference RPC Adapter (#276)

This package is a complete, deterministic Adapter RPC v1 server written in Go. It
implements the same neutral counter game as
`adapters/reference/counter_game_adapter.gd`, but runs in a separate process and
has no Godot, Hersir game, platform-core or platform-runtime dependency. Its only
Hersir-repository import is the generated, language-neutral protobuf binding.

The fixture proves that an adapter can be implemented in another language or engine
without changing Client Protocol V3 or teaching platform core any game vocabulary.
The existing client lifecycle terminates at the stable `AdapterRuntime` seam; the
process runtime forwards the opaque values over gRPC.

## Build and run

Build the standalone binary from `rpc/`:

```sh
go build -o ./bin/counter-adapter \
  ./reference/counter/cmd/counter-adapter
```

The supervised runtime normally supplies the first four variables:

```sh
HERSIR_ADAPTER_RPC_ENDPOINT=127.0.0.1:50051 \
HERSIR_ADAPTER_INSTANCE_ID=adapter-local-1 \
HERSIR_ADAPTER_EPOCH=1 \
HERSIR_PLATFORM_WORKLOAD_IDENTITY=platform-local \
./bin/counter-adapter
```

This insecure form is only for loopback development. Production uses mutual TLS by
also mounting and setting:

- `HERSIR_ADAPTER_TLS_CERT`: adapter certificate PEM
- `HERSIR_ADAPTER_TLS_KEY`: adapter private key PEM
- `HERSIR_ADAPTER_CLIENT_CA`: CA PEM used to authenticate the platform client

All three TLS paths must be supplied together. The server requires TLS 1.3 and a
verified client certificate. Build the minimal non-root container from the repository
root with:

```sh
docker build -f rpc/reference/counter/Dockerfile -t counter-adapter .
```

## Opaque codec

Every game-owned value uses `counter.json.v1`, UTF-8 JSON, and no protobuf game
fields. Object keys shown below are the canonical output order used for state hashes.

| Value | Shape |
| --- | --- |
| match config | `{"match_id":"m-1","limit":8}`; limit is 2 through 100 |
| slot | JSON string: `"slot_1"`, `"slot_2"`, or `"slot_3"` |
| command | `{"action":"ready\|increment\|finish","amount":1}` |
| state | `seed`, `step`, `limit`, `closed`, `values`, `prepared`, `completion` |
| checkpoint | `game_id`, `match_id`, `state`, `log` |
| delta | `{"replace":<state>}` |
| event | `index`, `kind`, `source`, `step`; all events are reliable |
| replay | `schema`, `game_id`, `match_id`, `seed`, `limit`, `log`, `steps`, `state_hash`, `completion` |

`state_hash` is lowercase SHA-256 of the compact state JSON. Fixed structs preserve
the same key order as Godot `JSON.stringify`, including `slot_1` through `slot_3`,
so in-process and RPC fixtures produce identical hashes, terminal results and replay
content.

## Lifecycle and recovery

The server implements all 18 Adapter RPC v1 methods:

1. negotiate protocol/capabilities, descriptor and slots;
2. validate config, create or recover a match, and validate joins;
3. validate/apply commands and advance deterministic ticks;
4. return terminal result, state hash, replay, checkpoint and delta;
5. drain reliable events, report metrics and answer health checks.

Mutation request ids are monotonic within an epoch and exact duplicate protobuf
requests return the stored response without applying twice. Instance/epoch,
deadline, match and expected-tick mismatches receive deterministic status codes.
Payload and advance limits match the values returned by `Negotiate`.

`recovery.Coordinator` fsyncs commands before dispatch, checkpoints periodically and
replays the post-checkpoint journal after `ProcessRuntime` restarts the binary with a
new epoch. Set `InitialRequestID` to the create-match request id when handing an
already-created match to the coordinator.

Run the unit, lifecycle parity and real-process kill/restart fixtures:

```sh
go test -race ./reference/counter
```

The integration test builds the binary, starts it through `ProcessRuntime`, drives
create/join/command/tick/checkpoint/delta/event/result/hash/replay, kills the child,
waits for a fresh epoch, restores the durable checkpoint and verifies the remaining
journal entry was replayed.

## Porting this adapter

To implement a third-party adapter:

1. generate server bindings from `rpc/adapter/v1/adapter.proto` for the target
   language; generated bindings are the only platform package the game needs;
2. keep game configuration, slots, commands, state, events, results and replays
   inside a named opaque codec;
3. implement all RPCs and echo `request_id`, instance id, epoch and observed tick in
   `ResponseMeta`;
4. make apply/advance deterministic and idempotent for an exact duplicate request;
5. make checkpoints self-contained and verify replay with the same canonical state
   hash;
6. read endpoint/identity/epoch from the supervisor environment and enable mutual
   TLS outside hermetic loopback tests;
7. run the RPC golden conformance suite and clone this package's lifecycle,
   parity and forced-restart fixtures for the new game.

No adapter should import `rpc/runtime`, `rpc/recovery`, Godot scripts, or platform
core. Those are platform-owned callers and deliberately appear only in this
package's black-box integration test.
