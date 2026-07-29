# Custom Protocol Gateway (#277)

## Boundary

An existing game protocol integrates through a game-specific edge process:

```text
custom client ⇄ game gateway ⇄ Client Protocol V3 ⇄ Match Platform
                                                   ⇄ Adapter RPC v1 process
```

Only the gateway knows custom message names or payload meaning. Match Platform still
validates the frozen V3 envelope and treats `payload` as opaque bytes. Adapter RPC
continues to know only its generated schema. Adding another gateway means implementing
`gateway.Translator`; it requires no platform-core or RPC schema change.

`rpc/gateway` is transport-independent. The production gateway should terminate the
custom transport, authenticate at the edge, call `ClientToV3`, forward the resulting
envelope over the normal authenticated V3 endpoint, then call `ServerFromV3` for the
reply. Do not let a client choose an adapter executable or RPC endpoint.

## Reference custom protocol

`rpc/gateway/reference` uses JSON frames with vocabulary intentionally different from
V3:

| Custom client operation | V3 envelope |
| --- | --- |
| `open` | `hello` identity/version/content/codec negotiation |
| `seat` | `join`, including opaque slot, identity ticket and resume token |
| `act` | sequenced `command` with expected tick and opaque body |

Server `welcome`, `checkpoint`, `state`, `event` and `reject` become `opened`,
`snapshot`, `sync`, `notice` and `fault`. Stable error mappings are explicit; the
original V3 code remains in `v3_code` for operations and support.

The sample custom transport supports:

- `reliable`, represented as `delivery: "reliable"`;
- replaceable state/event delivery, represented as `delivery: "latest"`;
- no droppable class. A droppable V3 event is upgraded to `latest`, includes
  `downgraded_from: "droppable"` and increments `DeliveryDowngrades`.

This is a deliberate quality upgrade, not silent semantic loss.

Golden mappings live in
`rpc/gateway/reference/testdata/counter_gateway_golden.json`.

## Limits, security and observability

- Decode a single custom frame and reject unknown fields or trailing messages.
- Apply `MaxCustomBytes` before decoding and validate the translated V3 envelope
  against its 64 KiB contract limit.
- Apply per-session admission limits before forwarding. The reference SDK uses a
  deterministic one-second window with a configurable burst.
- Authenticate the client transport before accepting `seat`; map only verified
  identity/reconnect claims into V3 `auth_context`.
- Preserve the V3 match id, sequence, expected tick and codec. Never synthesize a
  game command outside the translator.
- Log message class, result code, size, latency and delivery class, never opaque
  credentials or payload contents.

`Gateway.Telemetry` reports translated client/server messages, malformed and oversized
frames, rate limiting and delivery downgrades. Production deployments should partition
these metrics by gateway package/version without putting those labels in platform
core.

## Verification and a second gateway

```sh
cd rpc
go test -race ./gateway/...
```

The suite:

- validates bidirectional golden fixtures;
- rejects malformed, unknown-field, oversized and rate-limited custom traffic;
- verifies reconnect identity and explicit delivery downgrade;
- instantiates an unrelated second translator using only the public SDK;
- builds and starts the non-Godot counter adapter as a real supervised process;
- drives open/seat/act, checkpoint/state/event, terminal result and replay through
  custom → V3 → Adapter RPC.

Clone the reference translator and fixtures for another game. Keep its vocabulary in
that gateway package and use a separate deployable entry point/configuration.
