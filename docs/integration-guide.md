# Integrating a game with Match Platform V3

This is the end-to-end guide for putting a new authoritative-multiplayer game on
Match Platform. It walks the two integration surfaces — the **server-side game
adapter** and the **client protocol** — and points at
[`games/neon-shooter`](../games/neon-shooter) as a complete, tested worked example
you can copy from.

If you only need the frozen contract details, read
[`platform/match_platform_v3.gd`](../platform/match_platform_v3.gd) (envelope +
validator) and [`platform/match_game_adapter.gd`](../platform/match_game_adapter.gd)
(the adapter surface). This guide is the "how the pieces fit" layer above them.

## The boundary

The platform core is **game-agnostic**. It owns transport framing, the V3
envelope, identity/version/codec negotiation, sessions, slot reservations,
replication baselines, delivery classes and the fixed-tick scheduler. It never
inspects a `payload`.

Your game owns everything behind an **adapter**: slot policy, command validation,
the simulation, deterministic hashing, checkpoint/delta/event construction,
replay and the terminal result. The core hands the adapter opaque blobs and asks
it to validate/build them. No game vocabulary (seat names, entity kinds, command
names) may appear in `platform/` — that boundary is enforced by
`tests/platform_core_test.gd`.

```
client ⇄ [ your host: WebSocket ⇄ V3 envelope ⇄ platform core ⇄ your adapter ]
                                   └────────── game rules live here ──────────┘
```

## Two ways to lay out your game

1. **Downstream repo + submodule** (the reusable-platform path): pin this repo as
   a git submodule, preload from `res://match-platform/platform/...`, keep your
   game in your own repo. See [migration-and-rollback.md](./migration-and-rollback.md).
2. **First-party `games/<name>/` directory** (monorepo path): your game lives in
   this repo beside the platform, preloading `res://platform/...`. `neon-shooter`
   uses this layout. The platform core still stays game-clean; only `games/` holds
   game code.

Either way the code below is identical apart from the preload prefix.

## Server side: implement a `MatchGameAdapter`

Extend the abstract base and override the full surface. Every payload you accept
or produce is opaque to the core — shape it however your game likes.

| method | responsibility |
| --- | --- |
| `package_descriptor()` | identity the registry gates on: `game_id`, `adapter_version`, `content_versions`, `content_hashes`, `codec_ids`, `tick_rate`, `slot_policy` |
| `slot_descriptors()` | roles/slots (participant vs observer, fillable) |
| `validate_match_config()` / `create_match(config, seed)` | make a deterministic match from a validated config + required seed |
| `validate_join(role, requested_slot, auth)` | accept a join, return an opaque slot |
| `validate_command(slot, payload)` / `apply_command(slot, payload)` | pure game validation, then enqueue the mutation |
| `advance(ticks)` | run exactly `ticks` fixed steps — determinism is your job |
| `state_hash()` | deterministic hash of full state at the current tick |
| `build_checkpoint(codec)` / `build_delta(from_ack_tick, codec)` | full and incremental replication payloads |
| `drain_events(codec)` | pending events, **each tagged with its reliability class** (see below) |
| `terminal_result()` / `export_replay()` / `recover_match(payload)` | end-of-match result, replay bytes, in-process recovery |

Determinism is the one hard rule: two adapters fed the same `seed` and the same
command sequence must return identical `state_hash()` at identical ticks. Use tick
counters and a seeded RNG carried inside your state — never wall-clock or an
un-seeded RNG. neon-shooter's adapter shows this (it ports a Node server that used
`Date.now()` + `Math.random()` to tick counters + a seeded `RandomNumberGenerator`
stored in the checkpoint).

Worked example:
[`games/neon-shooter/adapters/neon_shooter_adapter.gd`](../games/neon-shooter/adapters/neon_shooter_adapter.gd).

### Reliability classes

The core delivers by class; the adapter only *declares* each event's class in the
`reliability` field it returns from `drain_events`:

- `reliable` — control/commands, must arrive, applied exactly-once;
- `replaceable` — latest authoritative state supersedes older copies (`state`);
- `droppable` — transient FX, safe to lose, never authoritative.

The invariant to design for: **dropping every `droppable` message for a whole
match must leave the winner, the state hash and the replay identical** — because
the authoritative result already rides `state`/`checkpoint`. In neon-shooter,
`damage`/`kill` visuals are droppable while terrain edits and phase changes are
reliable.

## Codec

A codec groups outbound messages by reliability and frames them; the core routes
by class and never looks inside. The minimal shape is three methods —
`delivery_groups(messages)`, `encode_batches_for(messages, protocol)` and a static
`decode(bytes)`. Copy
[`games/neon-shooter/adapters/neon_shooter_codec.gd`](../games/neon-shooter/adapters/neon_shooter_codec.gd)
(a JSON codec) or the reference
[`adapters/reference/counter_json_codec.gd`](../adapters/reference/counter_json_codec.gd).

## Standing up a host / lobby

The platform ships the runtime pieces; you wire them to a transport:

- `PlatformAdapterRegistry` — `register(adapter)`, then `welcome_for(hello)` /
  `resolve_hello(hello)` for the identity gate.
- `PlatformSessionRegistry` — per-peer resume token, rate-limit bucket, command
  sequence, seat placement.
- `PlatformSlotBook` — claim / release / resume / spectator seats.
- `PlatformReplicationRing` — per-peer baselines for checkpoint vs delta + resync.
- `PlatformDeliveryQueue` — frames messages through your codec, emits
  `target_frame(peer, bytes, reliability)`.
- `PlatformTickScheduler` — converts real `delta` into fixed ticks.

The per-tick server loop is: apply queued commands → `adapter.advance(1)` →
`ring.record(checkpoint)` → per peer, `build_delta(baseline)` as a `state`
envelope + `drain_events` as `event` envelopes → `delivery.flush_targets()`.

Worked examples:
[`games/neon-shooter/server/shooter_lobby.gd`](../games/neon-shooter/server/shooter_lobby.gd)
(transport-agnostic multi-arena lobby + rotation) and
[`games/neon-shooter/server/server_main.gd`](../games/neon-shooter/server/server_main.gd)
(a thin WebSocket shell). Because the lobby is transport-agnostic, the same code
is driven by sockets in production and by fake peers in
[`games/neon-shooter/tests/shooter_lobby_test.gd`](../games/neon-shooter/tests/shooter_lobby_test.gd).

## Client side: speak the V3 envelope

The client handshake is four message types out and four in (plus `reject`):

```
client → server                     server → client
  hello   (identity + codecs)   →     welcome  (selected protocol/codec, tick_rate)
  join    (match_selector,role) →     checkpoint (full opaque state)
  command (seq, expected_tick,  →     state      (replaceable delta)
           codec_id, payload)         event      (reliable/replaceable/droppable)
                                      reject     (structured code)
```

1. On connect send `hello` with `protocol_versions`, `game_id`, `game_version`,
   `content_hash`, `codecs`. A mismatch is refused **before seating** with a
   structured `reject` code (`unknown_game`, `content_hash_mismatch`, …).
2. On `welcome`, send `join` with an opaque `match_selector`, a `role` and an
   `auth_context`.
3. Apply `checkpoint` as your full state; apply `state` as a latest-wins delta;
   apply `event` payloads by their declared class. **De-duplicate** reliable
   events by id and droppable batches by tick so a resync/reconnect never replays
   a UI effect.
4. Send `command` envelopes with a monotonic `seq` and `expected_tick`; the core
   rate-limits and sequence-checks them before your adapter sees them.

Because the platform envelope carries no game seat concept, relay the assigned
slot to the client yourself (neon-shooter sends a reliable `seat` game event right
after join). Worked example:
[`games/neon-shooter/client/net_client_v3.gd`](../games/neon-shooter/client/net_client_v3.gd),
which keeps client-side prediction/reconciliation against the same shared
simulation the server runs.

### Non-Godot / legacy clients

If your client speaks a different wire protocol, put a translator at the edge
instead of changing the core — see
[custom-protocol-gateway.md](./custom-protocol-gateway.md) and `rpc/gateway`. The
core still validates the V3 envelope and treats the payload as opaque bytes.

## Verify

Run the platform's own conformance plus your game's:

```sh
bash tests/run_godot_conformance.sh                      # platform core + reference adapter
bash games/neon-shooter/tests/run_conformance.sh         # adapter + lobby (worked example)
bash games/neon-shooter/tests/run_e2e_v3.sh              # live server + client over WebSocket
```

Mirror those three levels for your game: an adapter/lobby conformance test driven
through the real platform registries, and a live end-to-end over your transport.
