class_name MatchGameAdapter
extends RefCounted

## Trusted, server-side game adapter surface for Match Platform V3 (issue #74).
##
## An adapter is server code loaded from the platform's registered package set —
## NEVER uploaded by a client. It owns every game-specific decision the platform
## core must stay ignorant of: slot policy, command validation, simulation
## advance, checkpoint/delta/event construction, deterministic hash, replay, and
## terminal result. The core hands it opaque `payload` blobs and asks it to
## validate/build them; it never branches on game concepts itself (#73 boundary).
##
## This is an abstract base: every method returns a not-implemented rejection so a
## concrete adapter (the Hersir adapter is #75) must override the full surface.
## The signatures ARE the frozen contract; ADR 0003 is their prose. Payloads and
## returned game data are opaque to the platform — typed here as `Variant`/
## `Dictionary` deliberately, so no Hersir field name leaks into the interface.

const V3 = preload("res://platform/match_platform_v3.gd")

# --- Package identity -------------------------------------------------------

## Static descriptor the platform registry keys on. Shape:
## `{game_id, adapter_version, content_versions: [], content_hashes: [],
##   codec_ids: [], slot_policy: {...}, tick_rate: int}`.
## The registry rejects a `hello` whose identity is absent from this descriptor
## before any match seating (`unknown_game`/`unsupported_game_version`/
## `content_hash_mismatch`/`unsupported_codec`).
func package_descriptor() -> Dictionary:
	return {}

## Slot/role policy as opaque descriptors: which roles exist, how many slots,
## which are player vs spectator vs bot-fillable. The core reads only counts and
## availability from this — never a game-specific seat name.
func slot_descriptors() -> Array:
	return []

# --- Match lifecycle --------------------------------------------------------

## Validate a canonical match configuration (mode/content selection etc., all
## opaque to the core). Returns `{ok: true}` or a `V3.reject(...)` dict.
func validate_match_config(_config: Dictionary) -> Dictionary:
	return V3.reject(V3.REJECT_ADAPTER_REJECTED, "validate_match_config not implemented")

## Create a fresh authoritative match from a validated config and a required
## deterministic `seed`. Returns `{ok: true, match_id}` or a reject.
func create_match(_config: Dictionary, _seed: int) -> Dictionary:
	return V3.reject(V3.REJECT_ADAPTER_REJECTED, "create_match not implemented")

## Recover a match from an acknowledged checkpoint payload. V3.0 does not promise
## cross-process restore (see ADR 0003 §Scope); in-process recovery only.
func recover_match(_checkpoint_payload: Variant) -> Dictionary:
	return V3.reject(V3.REJECT_ADAPTER_REJECTED, "recover_match not implemented")

# --- Seating & commands -----------------------------------------------------

## Validate a join and assign a slot per the adapter's slot policy. `role` and
## `requested_slot` are opaque; `auth_context` is verified identity from the
## platform, never a game concept. Returns `{ok: true, slot}` or a reject
## (`slot_unavailable`/`unauthorized`).
func validate_join(_role: String, _requested_slot: Variant, _auth_context: Dictionary) -> Dictionary:
	return V3.reject(V3.REJECT_ADAPTER_REJECTED, "validate_join not implemented")

## Validate an opaque command payload for an assigned slot WITHOUT applying it.
## The core has already checked seq/expected_tick/rate/size; this is pure game
## validation. Returns `{ok: true}` or a reject (`adapter_rejected`).
func validate_command(_slot: Variant, _payload: Variant) -> Dictionary:
	return V3.reject(V3.REJECT_ADAPTER_REJECTED, "validate_command not implemented")

## Apply a previously-validated command to pending match state. Never advances
## the clock — mutation is enqueued for the next `advance()`.
func apply_command(_slot: Variant, _payload: Variant) -> void:
	pass

# --- Fixed simulation -------------------------------------------------------

## Advance the simulation by exactly `ticks` fixed steps. The core owns the
## scheduler and calls this at the descriptor's `tick_rate`; the adapter owns
## what a tick does. Determinism is the adapter's responsibility.
func advance(_ticks: int) -> void:
	pass

## Terminal result once the match has ended, else `null`. Shape is opaque
## (`{winner?, ...}` in the adapter's own vocabulary); the core only checks null
## vs non-null to end the match.
func terminal_result() -> Variant:
	return null

## Deterministic hash of full authoritative state at the current tick. Two
## adapters fed identical seed+commands MUST return identical hashes at identical
## ticks — the core carries it as a short checksum but never computes it.
func state_hash() -> String:
	return ""

## Export the complete replay (opaque). The core stores/streams the bytes; it
## does not interpret them.
func export_replay() -> Variant:
	return null

# --- Replication (opaque payload builders) ----------------------------------

## Full checkpoint payload for a codec, plus its state hash:
## `{payload, state_hash, tick}`. Used for join/reconnect/resync anchors. The
## core routes it as a RELIABLE recovery frame; it never reads inside `payload`.
func build_checkpoint(_codec_id: String) -> Dictionary:
	return {}

## Incremental state payload diffed from an acknowledged baseline tick, for a
## codec: `{payload, tick, base_tick}`. The core carries it REPLACEABLE and
## supersedes older copies by tick without inspecting the diff.
func build_delta(_from_ack_tick: int, _codec_id: String) -> Dictionary:
	return {}

## Drain pending events since the last drain, each as
## `{reliability: <V3 class>, payload}`. The adapter DECLARES each event's
## delivery class; the core enforces it. Control events are reliable, pure FX
## droppable — the core learns which from the field, not from the payload.
func drain_events(_codec_id: String) -> Array:
	return []

# --- Telemetry & rejection --------------------------------------------------

## Adapter-defined metrics for this match, partitioned by the platform under
## game/package/version/match so one game's payload never leaks into another's
## telemetry (#73 acceptance).
func metrics() -> Dictionary:
	return {}
