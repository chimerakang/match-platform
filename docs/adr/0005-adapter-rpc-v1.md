# ADR 0005 — Adapter RPC v1 process contract

- Status: Accepted
- Issue: #272
- Parent: #271

## Decision

`hersir.adapter.rpc.v1.AdapterService` is the language-neutral boundary between Match
Platform Core and an independently deployed game adapter. The schema lives at
`rpc/adapter/v1/adapter.proto`; generated Go and Python client/server targets and the
shared golden corpus are committed with it.

RPC v1 mirrors the full `MatchGameAdapter` ownership surface: descriptor and slot
policy; create/recover; join; command validation/application; fixed-tick advance;
checkpoint/delta/events; terminal result; deterministic hash/replay; metrics; health.
All game-owned values remain opaque codec-tagged bytes. The platform may bound and
route those bytes but must not inspect them.

## Independent version axes

These identifiers are deliberately not aliases:

| Axis | Owner | Compatibility rule |
|---|---|---|
| Adapter RPC protocol `{major, minor}` | This ADR/schema | Major mismatch is rejected; peers select the greatest common minor of one major. |
| Client Protocol V3 | Match Platform client boundary | Negotiated with clients; never inferred from RPC v1. |
| `adapter_version` | Adapter package | Opaque package identity reported by the descriptor. |
| content version/hash | Game package | Exact pre-seat match identity; never rewritten by RPC. |
| `codec_id` | Game adapter | Defines only opaque payload bytes, not RPC framing. |

Adding fields or RPCs is a backward-compatible minor change. Removing/retyping fields,
changing field numbers, status meanings, ownership, or mutation semantics requires RPC
v2 in a new protobuf package. Unknown fields are preserved by normal protobuf relays
where the language runtime supports it; logic must ignore unknown fields. An endpoint
must return `STATUS_UNSUPPORTED_PROTOCOL` before dispatch when the requested major is
unknown.

## Identity, ordering and time

Every match-scoped call carries:

`(match_id, adapter_instance_id, adapter_epoch, request_id, expected_tick, deadline_unix_ms)`.

- `adapter_instance_id` identifies one running adapter process. `adapter_epoch`
  increases whenever that instance loses its request-deduplication or match state.
- `request_id` is positive and strictly monotonic within the identity tuple. Servers
  cache the response of every mutation for the configured deduplication window.
  Repeating the same id and byte-identical request returns the cached response;
  reusing an id with different bytes returns `STATUS_OUT_OF_ORDER`.
- `expected_tick` is the caller's last authoritative tick. A call whose required
  state does not match it returns `STATUS_OUT_OF_ORDER` without mutation.
- `deadline_unix_ms` is an absolute UTC Unix millisecond deadline. Zero is invalid.
  An expired request is rejected before dispatch with `STATUS_DEADLINE_EXCEEDED`.
  Transport cancellation before dispatch returns `STATUS_CANCELLED`. Once a mutation
  begins, cancellation cannot assert rollback: if the cached result cannot be
  recovered, the outcome is `STATUS_UNKNOWN_OUTCOME` and the caller must reconcile
  through state hash/checkpoint before retrying.
- A stale process identity returns `STATUS_STALE_EPOCH`; it is never silently rebound
  to a new instance.

## Retry classification

Read-only calls (`Negotiate`, descriptor, terminal result, hash, replay, checkpoint,
delta, metrics and health) are retry-safe with a fresh monotonically increasing id.
Validation calls are read-only but their result is advisory; `ApplyCommand` remains
the mutation authority.

`CreateMatch`, `RecoverMatch`, `ApplyCommand`, `Advance` and `DrainEvents` mutate or
consume state. They may be retried only with the identical request and the same
request id/instance/epoch so server deduplication returns the original response.
After `STATUS_UNKNOWN_OUTCOME`, `STATUS_STALE_EPOCH`, or deduplication-window expiry,
the caller must reconcile instead of blind retry. `ApplyCommand` enqueues only;
`Advance` is the sole clock mutation, preserving the existing ownership split.

`retryable=true` is permitted only for a same-id retry that cannot double-apply.
`STATUS_ADAPTER_REJECTED`, invalid input, incompatible protocol, stale epoch,
out-of-order and payload-too-large are not retryable.

## Status mapping

Application outcomes use `ResponseMeta.code`. Transport status remains reserved for a
connection or framing failure:

- malformed/bad bounds → `STATUS_INVALID_ARGUMENT` or `STATUS_PAYLOAD_TOO_LARGE`;
- adapter-owned refusal → `STATUS_ADAPTER_REJECTED` with opaque-free diagnostic text;
- missing match → `STATUS_NOT_FOUND`; duplicate create → `STATUS_ALREADY_EXISTS`;
- ordering/identity → `STATUS_OUT_OF_ORDER` / `STATUS_STALE_EPOCH`;
- capacity/transient process state → `STATUS_RESOURCE_EXHAUSTED` /
  `STATUS_UNAVAILABLE`;
- deadline/cancellation ambiguity → the three explicit outcomes above;
- uncaught adapter failure → `STATUS_INTERNAL`, never a game-specific code.

Every response echoes `request_id`, current instance/epoch and observed tick, including
rejections. Platform telemetry may label those identities and status codes but must
not label or log opaque payload contents.

## Canonical encoding and limits

- Protobuf binary wire format is the RPC control encoding. The golden corpus uses
  deterministic serialization. Producers emit fields in field-number order, use
  minimal varints, preserve repeated order, and do not depend on unknown-field order.
- No protobuf `map` appears in v1. Metrics and capabilities are ordered repeated
  entries. Implementations sort them lexicographically before emitting. Duplicate
  metric or capability names are invalid.
- Strings are valid UTF-8. Identifiers are non-empty NFC strings, at most 128 UTF-8
  bytes. Hash strings are lowercase hexadecimal. Floating metrics must be finite.
- `OpaquePayload.value` is never canonicalized by the platform. Its bytes are
  interpreted only by its exact `codec_id`.
- Negotiated `Limits` apply to uncompressed protobuf messages and each opaque payload.
  Defaults are 1 MiB request, 16 MiB response, 8 MiB opaque payload, 600 advance ticks
  and 4096 events per drain. Exceeding a limit is rejected before adapter dispatch.
- Compression is a transport concern and cannot bypass uncompressed limits. A server
  must not return a partial checkpoint, delta, replay or event.

## Conformance

`rpc/conformance/fixtures/adapter_rpc_v1_golden.json` contains canonical frames with
field assertions. Python and Go tests deserialize and deterministically reserialize
the same bytes, verify the service exposes client and server bindings, and reject an
unknown major before payload dispatch. The runner treats payloads as bytes only:

```sh
bash tests/run_adapter_rpc_conformance.sh
```

This validates the process contract without Godot or Hersir game vocabulary. It does
not start a production transport; the endpoint runner introduced by the process
runtime may reuse the same corpus without inspecting game payloads.

## Consequences

RPC v1 does not itself move an adapter out of process. #273 introduces the
`AdapterRuntime` seam and in-process parity; #274 implements the supervised process
runtime; #275 implements its durable journal, checkpoint and fresh-epoch recovery
coordinator; #276 supplies and validates the non-Godot counter reference remote
adapter. Client V3 and legacy v1/v2 bytes remain untouched.
