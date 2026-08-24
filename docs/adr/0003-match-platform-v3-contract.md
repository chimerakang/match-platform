# ADR 0003 — Match Platform V3 contract: generic envelope, `MatchGameAdapter`, and codec/version negotiation

- **Issue:** #74 (定義通用 Match Platform envelope、Adapter contract 與 ADR), Epic #73 (V3 對戰平台)
- **Status:** Proposed (frozen-boundary design record — approve before any platform code moves)
- **Scope of this ADR:** the *contract only*. It moves no code. It does **not** rename or
  reshape `HeroTeamsLobbyServer`, `HeroTeamsNetworkArena`, `HeroTeamsWireV2`, or any existing
  v1/v2 byte. Extraction of the platform core is #75; the Hersir adapter behind this contract is
  a later slice of the same epic. Per the #73 audit, the boundary is locked here **first** so that
  extraction is a mechanical move behind a fixed surface, not a redesign.
- **Executable form:** [`platform/match_platform_v3.gd`](../../platform/match_platform_v3.gd)
  (`MatchPlatformV3`) is the envelope + validator; [`platform/match_game_adapter.gd`](../../platform/match_game_adapter.gd)
  (`MatchGameAdapter`) is the adapter surface. [`tests/fixtures/v3_envelope_fixtures.json`](../../tests/fixtures/v3_envelope_fixtures.json)
  are the reference fixtures; [`tests/v3_contract_test.gd`](../../tests/v3_contract_test.gd) is the
  contract test (80 checks). This document is their prose; where prose and the module disagree, the
  module and its test win.

---

## 1. Context

The #73 per-file audit (2026-07-19) concluded the current stack is a complete, good-quality
**Hersir-specific** authoritative WebSocket server — not yet a generic product. Every layer still
recognises Hersir rules: `network_protocol.gd:74` fixes `move/recruit/cast_skill/hire_merc`;
`network_protocol.gd:329-411` walks `heroes/economies/skills/strongholds/units/camps/outposts`;
`wire_v2.gd` hard-codes team/result/unit/map enums; `lobby_server.gd`/`network_arena.gd` bake in
`blue/red` seats, `easy/normal/hard`, PvE bot substitution, and `GameSimulation` selection.

The audit's P0 was explicit: **lock the contract before moving code.** This ADR is that P0. It
defines the frozen line between the reusable **platform core** (transport, session, slots, tick
scheduler, reconnect, sequence/rate-limit, backpressure queues, acked-baseline ring/resync,
telemetry) and the **trusted game adapter** (rules, slots, commands, state schema, codec, hash,
replay, result), and the generic wire envelope that is the only thing crossing between them.

## 2. Decisions

| # | Question | Decision |
|---|---|---|
| D1 | What crosses the core↔adapter / server↔client boundary? | Eight versioned application envelopes — `hello`, `welcome`, `join`, `command`, `state`, `checkpoint`, `event`, and structured `reject` — plus the generic transport-control extension from #79 (`transport_select`, `rtc_offer`, `rtc_answer`, `rtc_ice`, `transport_status`). Every game concept rides inside an **opaque `payload`** the core never parses. |
| D2 | Envelope version vs game version | A dedicated platform envelope version `pv = 3` (`ENVELOPE_VERSION`), **distinct** from `game_version`, `adapter_version`, `content_hash`, and `codec_id`. Bumping `pv` is a platform-wide breaking change; adding a game/codec is not. |
| D3 | What is mandatory match identity? | `game_id`, `game_version`, `content_hash`, and (post-negotiation) `codec_id` are **mandatory identity, not display data**. The registry rejects an unknown/incompatible one **before seating** (§5). |
| D4 | Who owns delivery vs payload semantics? | **Platform owns** envelope shape & byte limits, message ordering, `seq`/ack, baseline acknowledgement & resync, delivery classes, rate limits, and telemetry partitioning. **Adapter owns** payload validation, state/checkpoint/delta construction, event content, deterministic hash, replay, slot policy, and terminal result. |
| D5 | How does the core route reliability without reading payload? | The generic reliability matrix (§4) keys off the **message type**; `event` additionally carries a declared `reliability` class in-band. The core never inspects `payload` to decide delivery. |
| D6 | What is the adapter's method surface? | The frozen `MatchGameAdapter` surface in §6 — package descriptor, slot descriptors, match lifecycle, join/command validation, fixed `advance()`, terminal result, `state_hash()`, replay export, checkpoint/delta builders, event drain, metrics. |
| D7 | Compatibility with today's clients? | Hersir v1 (JSON) and v2 (`HeroTeamsWireV2` binary) remain fully supported during migration. V3 is a **new negotiated envelope**, never a silent reinterpretation of v1/v2 bytes. `HersirWireV2` becomes the first registered *codec*, not a promoted generic API. |
| D8 | What does V3.0 deliberately NOT promise? | No cross-process match restore/reconnect (needs the durable match-store adapter, deferred), no process-isolated / RPC adapter (deferred — no remote code execution), no auth-provider or admin/health API (V3.2). Reconnect token stays a session token, never product auth. |

## 3. The envelope

Every V3 message is one dictionary carrying `pv` (=3) and `t` (type). Direction is fixed:
`hello`/`join`/`command` are client→server; `welcome`/`state`/`checkpoint`/`event`/`reject` are
server→client. Fields below are all **platform** fields; none names a game concept.

```text
hello      { pv, protocol_versions, platform_version?, game_id, game_version, content_hash, codecs }
welcome    { pv, selected_protocol, platform_version?, game_id, adapter_version, selected_codec, tick_rate, capabilities }
join       { pv, match_selector, role, requested_slot?, auth_context }
command    { pv, match_id, seq, expected_tick, codec_id, payload:opaque }
state      { pv, match_id, tick, base_tick, seq, codec_id, payload:opaque }
checkpoint { pv, match_id, tick, codec_id, payload:opaque, state_hash }
event      { pv, match_id, tick, reliability, codec_id, payload:opaque }
reject     { pv, code, detail? }
```

After seating, #79 may additionally exchange platform-owned transport envelopes:
`transport_select`, `rtc_offer`, `rtc_answer`, `rtc_ice`, and `transport_status`. They carry
only `match_id`, attempt identity, transport/status, SDP, and ICE fields. They are always reliable
WSS messages and do not change the opaque application-envelope contract.

- `payload` is **opaque**: a game-specific blob (a `codec_id`-tagged binary/base64 string, or a
  bounded reference-JSON object). The core bounds it by `MAX_ENVELOPE_BYTES` (64 KiB, matching the
  v1/v2 wire ceiling) and routes it — it never deserialises or branches on its contents.
- `checkpoint` is the generic name for the v1/v2 *full snapshot* recovery anchor; `state` is the
  incremental delta diffed from `base_tick`. This preserves the #48 acked-baseline model wholesale.
- `state_hash` on a checkpoint is the adapter's deterministic full-state hash; the core carries it
  (and a short checksum on `state`) but never computes it.

## 4. Delivery classes (platform-owned)

The #49 reliability matrix, restated generically. The class is decided from the message type; the
core enforces it. `RELIABLE > REPLACEABLE > DROPPABLE`.

| Type | Class | Rationale |
|---|---|---|
| `hello`,`welcome`,`join`,`reject` | RELIABLE | negotiation/control — must arrive |
| `command` | RELIABLE | applied exactly-once |
| `checkpoint` | RELIABLE | recovery anchor — must survive loss |
| `state` | REPLACEABLE | newest authoritative delta supersedes older |
| `event` | **declared in-band** | the adapter marks pure-FX events DROPPABLE and control events RELIABLE; the core reads the `reliability` field, never the payload |

## 5. Negotiation and rejection policy

A player is seated only after identity and capability are agreed:

1. Client sends `hello { protocol_versions, game_id, game_version, content_hash, codecs }`.
2. The core negotiates the **platform protocol**: highest version common to client and server, else
   `unsupported_protocol` (`negotiate_protocol`).
3. The **registry** resolves `game_id` → registered adapter package, else `unknown_game`. It checks
   `game_version` against the descriptor's supported versions (`unsupported_game_version`) and
   `content_hash` against the supported set (`content_hash_mismatch`).
4. The core negotiates a **codec**: the first client-preferred `codec_id` the adapter also offers,
   else `unsupported_codec` (`negotiate_codec`).
5. On success the core replies `welcome { selected_protocol, adapter_version, selected_codec,
   tick_rate, capabilities }`. Only then may the client `join`; the adapter validates the join/slot
   (`slot_unavailable`) and `auth_context` (`unauthorized`).

Every refusal is a `reject` with exactly one stable **code** from the frozen set. Identity/capability
codes are checked **before seating**; per-frame codes (`payload_too_large`, `sequence_violation`,
`rate_limited`, `malformed_envelope`, `adapter_rejected`) apply after. No cross-game state or replay
is ever accepted: identity is validated before a match is joined.

```text
malformed_envelope · unsupported_protocol · unknown_game · unsupported_game_version
content_hash_mismatch · unsupported_codec · unknown_match · slot_unavailable
unauthorized · payload_too_large · sequence_violation · rate_limited · adapter_rejected
```

An adapter maps its own validation failures onto `adapter_rejected` plus free-form `detail`; the
core never invents a game-specific code.

## 6. `MatchGameAdapter` surface (adapter-owned)

The adapter is **trusted server code loaded from the platform's registered package set** — clients
never upload executable game code. Its frozen surface (signatures in `match_game_adapter.gd`):

- **Identity:** `package_descriptor()` → `{game_id, adapter_version, content_versions[],
  content_hashes[], codec_ids[], slot_policy, tick_rate}`; `slot_descriptors()` → opaque
  role/slot/bot-fill policy the core reads only as counts + availability.
- **Lifecycle:** `validate_match_config(config)`; `create_match(config, seed)` (seed mandatory,
  deterministic); `recover_match(checkpoint_payload)` (in-process only in V3.0).
- **Seating & commands:** `validate_join(role, requested_slot, auth_context)` → `{ok, slot}` |
  reject; `validate_command(slot, payload)` (pure game validation — the core has already checked
  seq/expected_tick/rate/size); `apply_command(slot, payload)` (enqueues, never advances the clock).
- **Fixed simulation:** `advance(ticks)` (core owns the scheduler at `tick_rate`, adapter owns the
  tick); `terminal_result()` → opaque or `null`; `state_hash()` (deterministic — identical
  seed+commands ⇒ identical hash at identical tick); `export_replay()` (opaque).
- **Replication (opaque builders):** `build_checkpoint(codec_id)` → `{payload, state_hash, tick}`;
  `build_delta(from_ack_tick, codec_id)` → `{payload, tick, base_tick}`; `drain_events(codec_id)` →
  `[{reliability, payload}]` (adapter declares each event's delivery class).
- **Telemetry & rejection:** `metrics()` partitioned by the platform under
  game/package/version/match, so one game's payload never leaks into another's telemetry.

## 7. The binding contract (non-negotiable)

Any #73/V3 issue that touches the platform boundary **must** obey these, and only these:

1. **Core opacity.** Platform-core code must not branch on team names, entity kinds, command names,
   winner semantics, map fields, or balance data. It schedules opaque payloads and asks the adapter
   to validate/build them. It bounds `payload` by bytes and adapter/codec selection — nothing more.
2. **Mandatory identity.** `game_id + game_version + content_hash + codec_id` are match identity.
   Unknown/incompatible identity is rejected **before seating**; auth identity, package identity, and
   match identity are three distinct things (the reconnect token is not product auth).
3. **Delivery ownership split** exactly as §4/§6: platform owns ordering/limits/baselines/classes;
   adapter owns payload semantics, hash, replay, and each event's declared class.
4. **Compatibility.** Hersir v1/v2 stay green; V3 never silently reinterprets their bytes.
   `HersirWireV2` is the first registered codec, not a generic serializer.
5. **Determinism unchanged.** The adapter's `advance()`/`state_hash()`/replay keep the #36
   server-authoritative deterministic contract; the core adds no wall-clock or RNG to the sim path.

## 8. Reference fixtures & contract test

`tests/fixtures/v3_envelope_fixtures.json` gives one valid example of every message type for the
**fictional `gridwars` game** (generic `north`/`player` slots, opaque payload) plus the invalid
cases and negotiation vectors. Its absence of any Hersir field IS part of the contract.

`tests/v3_contract_test.gd` (80 checks) asserts: every valid envelope validates for its direction;
all application and transport-control types are covered; each invalid case yields exactly its expected reject code; a
non-dictionary is `malformed_envelope`; protocol/codec negotiation matches §5; delivery classes
match §4 (including an `event` honouring its declared class); `reject()` builds a valid envelope;
the base `MatchGameAdapter` refuses every call until overridden; and **no Hersir game token**
(`blue`,`red`,`hero`,`unit`,`stronghold`,`camp`,`outpost`,`recruit`,`cast_skill`,`hire_merc`,
`warcry`,`militia`,`economy`) appears — as a whole word — in the envelope corpus, the contract
module, or the adapter interface. This is the mechanical seed of the #73 P3 forbidden-reference
test.

```sh
godot --headless --path . --script res://tests/v3_contract_test.gd   # 80 checks
```

## 9. Consequences

- **#75 (extract core)** — **done.** The contract modules moved to `platform/`, joined by the
  package registry, session store, room registry, tick scheduler, match queue, slot book,
  delivery queue and replication ring. `tests/platform_core_test.gd` enforces the boundary as a
  directory walk and runs on the merge gate. See [match-platform-core.md](../match-platform-core.md)
  for the module map and the list of what is still Hersir-specific — notably that no
  `MatchGameAdapter` implementation exists yet, so the registry is not on the live serving path
  and the legacy v1/v2 route is byte-unchanged. Putting Hersir rules behind an adapter, and
  replacing its seat policy with adapter `slot_descriptors`, is **#76**.
- **V3.1** adds a second, non-Hersir adapter and the forbidden-reference architecture test; the
  `gridwars` fixtures already prove the envelope can describe a game with none of Hersir's fields.
- **Deferred follow-up:** auth provider and admin/health/metrics were delivered by #78. Durable
  match recovery and process-isolated/RPC adapters remain outside V3 and are now planned under
  [Epic #271](https://github.com/chimerakang/hersir/issues/271); see the
  [external-adapter and extraction roadmap](../match-platform-extraction-roadmap.md). None may
  weaken §7.

## 10. Reproducing

```sh
godot --headless --path . --script res://tests/v3_contract_test.gd        # 80 V3 contract checks
godot --headless --path . --script res://tests/wire_v2_test.gd            # v1/v2 unchanged
godot --headless --path . --script res://tests/network_architecture_test.gd
godot --headless --path . --script res://tests/reliability_matrix_test.gd
```
