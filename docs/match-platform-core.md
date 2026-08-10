# Match Platform core mechanics

Reference for the game-agnostic Godot core under `platform/`. These are the
composable "books" an integrator wires around each match; **none of them reads a
`payload`**. For the big picture see [architecture.md](architecture.md); for the
adapter execution seam see [adapter-runtime-seam.md](adapter-runtime-seam.md).

Every module here is guarded by the directory scan in
`tests/platform_core_test.gd`: no game token, game identifier, or
`res://scripts|server|network/…` dependency may appear under `platform/`.

## Contract modules

| module | class | role |
| --- | --- | --- |
| `match_platform_v3.gd` | `MatchPlatformV3` | the wire envelope + a pure validator; message types, required fields, reject codes, protocol/codec negotiation, delivery classes. Never inspects `payload`. |
| `match_game_adapter.gd` | `MatchGameAdapter` | the frozen adapter surface (every method rejects until overridden). |

See [ADR 0003](adr/0003-match-platform-v3-contract.md) for the frozen contract and
[integration-guide.md](integration-guide.md) for how a game implements the adapter.

## Registry — the pre-seat gate + match factory

`platform_adapter_registry.gd` (`PlatformAdapterRegistry`) is the only place an
adapter enters the core. `register(adapter)` wraps it in an `InProcessRuntime` and
stores an **`AdapterRuntime`** (not the raw adapter); `register_runtime(runtime)`
accepts any runtime (e.g. a future out-of-process one).

| method | purpose |
| --- | --- |
| `register(adapter)` / `register_runtime(runtime)` | admit a trusted package; validates the descriptor |
| `resolve_hello(hello)` / `welcome_for(hello, capabilities={})` | the pre-seat identity/codec gate → `welcome` or a structured `reject` |
| `create_match(game_id, config, seed)` / `recover_match(game_id, checkpoint)` | the match factory (a seed is mandatory; no wall-clock) |
| `runtime_for(game_id)` / `descriptor(game_id)` / `slot_descriptors(game_id)` / `has_game` / `registered_game_ids` | lookups |

The registry reaches game data only through an `AdapterRuntimeCall` result, and
hands out **copies** of descriptors so the trusted set cannot be widened by
mutation.

## Per-peer admission — sessions

`platform_session_registry.gd` (`PlatformSessionRegistry`). One session per
connected peer, holding only platform state: a server-minted resume token, a
token-bucket rate limiter, a monotonic command sequence, and the opaque seat
placement. Constructed with `_init(commands_per_second, burst, protocol_ceiling)`.

| method | purpose |
| --- | --- |
| `open(peer_id)` / `close(peer_id)` / `has` / `session` | lifecycle |
| `token(peer_id)` / `adopt_token(peer_id, resume_token)` | resume identity (server-minted only) |
| `consume_rate_token(peer_id)` / `available_rate_tokens` | admission budget (per-peer, isolated) |
| `accept_sequence(peer_id, seq)` / `last_sequence` | strictly-increasing command ordering / dedup |
| `assign_seat(peer_id, room, role, slot)` / `clear_seat` / `slot` / `role` / `room_id` / `is_seated` | opaque seat placement (recorded, never interpreted) |
| `negotiate_protocol(peer_id, requested)` / `protocol` | wire-version clamp |

The store never learns what a `slot` means — it is whatever string the adapter's
`validate_join` returned; the core only compares it for equality.

## Seats — the slot book

`platform_slot_book.gd` (`PlatformSlotBook`), constructed with the adapter's slot
ids. Owns seat occupancy, disconnect reservations, and token-based reclaim.

| method | purpose |
| --- | --- |
| `claim(peer_id, token, preferred_slot="")` | take a free (or preferred) slot → `{ok, slot}` |
| `release(peer_id, now_tick)` | mark gone but **reserve** the seat (returns role/slot/token) |
| `vacate(slot_id)` | deliberate departure — free the seat immediately |
| `resume(token, peer_id)` | reclaim a reserved seat by token → `{ok, slot, evicted}` |
| `expire_reservations(now_tick, grace_ticks)` | free reservations older than the grace window |
| `add_spectator` / `is_spectator` / `slot_for_peer` / `connected_peer_ids` / `has_free_slot` / `occupied_count` / `connected_count` | queries |

`release` (reserve) vs `vacate` (forfeit) is the reconnect-grace vs
explicit-leave distinction.

## Rooms & waiting — room registry + match queue

`platform_room_registry.gd` (`PlatformRoomRegistry`): a *room* is one running
match. `allocate(preferred_code="")` reserves a room id + join code + deterministic
seed (monotonic, no RNG/wall-clock); `attach(room_id, code, room)` binds the
constructed match object (opaque — never called into); `close(room_id)` frees the
code and emits `room_closed`. Capacity is capped (`has_capacity`, default 4).

Join codes have two namespaces, and the asymmetry **is** the security property:

| kind | shape | who mints | lookup |
| --- | --- | --- | --- |
| public | 3–12 uppercase alphanumerics | `mint_public_code()` (collision-free) | accepted |
| reserved | `Q-` + unguessable hex | `mint_reserved_code()` (server only) | accepted, but **rejected by public validation** |

So a player can never type their way into a server-allocated room.

`platform_match_queue.gd` (`PlatformMatchQueue`): FIFO fairness when at capacity.
`enqueue(peer_id, options={})` (one entry per peer), `position(peer_id)` (1-based),
`drain(resolver)` (retries each waiter in arrival order; the resolver returns true
to remove — conflating "seated" and "gone"), `each_position(notifier)`.

## State replication — the replication ring

`platform_replication_ring.gd` (`PlatformReplicationRing`), constructed with
`(retained_ticks, cooldown_ticks)`. Decides, per peer, whether the next frame is a
full checkpoint or a delta from an acknowledged baseline, and rate-limits resync.

| method | purpose |
| --- | --- |
| `record(tick, payload)` | store a baseline (bounded window; old ticks evicted) |
| `adopt_full(peer_id, tick, now_tick)` | seed a peer's baseline on join |
| `apply_ack(peer_id, ack_tick)` | advance a peer's confirmed baseline |
| `resolve_group(peer_id, current_tick, now_tick, force_full, throttled=false)` | classify a peer: scheduled-full / full-repair / skip / delta |
| `resolve_baseline(peer_id, current_tick)` | the tick a delta should diff from |
| `request_repair(peer_id, now_tick)` | admit a resync after the cooldown |
| `advance_group(key, peer_ids, current_tick, now_tick)` | commit a delivery group's baseline move |
| `next_sequence()` / `forget_peer` / `telemetry(include_bytes=false)` | sequencing / cleanup / metrics |

## Output framing — the delivery queue

`platform_delivery_queue.gd` (`PlatformDeliveryQueue`), constructed with
`(codec, max_bytes, protocol_of: Callable)`. Groups outbound messages by delivery
class, encodes **once per wire version** through the codec, enforces the frame
ceiling (oversized frames are dropped and counted), and emits results.

| member | purpose |
| --- | --- |
| `enqueue_target(peer_id, message)` / `enqueue_broadcast(message)` | queue outbound |
| `flush_target(peer_id)` / `flush_targets()` | encode + emit |
| signal `target_frame(peer_id, bytes, reliability)` | a unicast frame is ready for the transport |
| signal `broadcast_frame(peer_ids, bytes, reliability)` | a shared frame for many peers |
| `telemetry()` | frames, drops, rejected (oversized) counts |

The core decides delivery from the message type / the event's declared
`reliability`; it never reads the payload to route.

## Timing — the tick scheduler

`platform_tick_scheduler.gd` (`PlatformTickScheduler`), constructed with
`(seconds_per_tick, tick_multiplier=1.0, accelerate_after=-1)`. `advance(delta)`
returns the number of **whole** fixed ticks to run, clamping a stalled frame to
`MAX_FRAME_SECONDS` (0.25 s) so a hitch never triggers a tick storm. Supports a
rate multiplier and deferred acceleration; `pending_seconds()` / `reset()`.

## How they compose

There is no generic loop file — the integrator composes the books. The worked
example is
[`games/neon-shooter/server/shooter_lobby.gd`](../games/neon-shooter/server/shooter_lobby.gd):

1. transport → `registry.welcome_for(hello)` (identity gate);
2. on join → `slot_book.claim` + `sessions.assign_seat` + `ring.adopt_full`, reply
   with a `checkpoint`;
3. on command → `sessions.consume_rate_token` → `accept_sequence` → resolve slot →
   adapter `validate_command` / `apply_command`;
4. each scheduler tick → adapter `advance(1)` → `ring.record(checkpoint)` →
   `build_delta` + `drain_events` → `delivery` frames → transport;
5. disconnect → `slot_book.release`/`vacate` + `sessions.close` +
   `ring.forget_peer`; reconnect → `slot_book.resume` + `sessions.adopt_token`.

Adapter calls can be made directly (as neon-shooter does today) or through the
[`PlatformRuntimeRoom` seam](adapter-runtime-seam.md), which additionally lets the
adapter run out of process.
