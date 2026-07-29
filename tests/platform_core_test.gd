extends SceneTree

## Match Platform Core architecture + behaviour test (issue #75, Epic #73).
##
## Two jobs, both load-bearing for the epic's "judgement standard":
##
##   1. **Forbidden-reference guard.** Every file under `platform/` is scanned for
##      Hersir game vocabulary and for Hersir class/command identifiers, and for any
##      dependency pointing back at Hersir code. This is the mechanical form of the
##      #73 non-negotiable boundary: the core stays opaque to game state, and the
##      only thing keeping it that way over time is a test that fails when it slips.
##      It is deliberately a *directory* scan, not a per-file allow-list, so a new
##      platform module is covered the moment it is added.
##
##   2. **Core mechanics.** The registry, session store, room registry, tick
##      scheduler, slot book, delivery queue and replication ring are exercised
##      through a fictional `gridwars` game whose slots (`north`/`south`), commands
##      and state fields share nothing with Hersir. If these checks pass while the
##      guard above also passes, the mechanics really are game-agnostic.
##
## Run: godot --headless --path . --script res://tests/platform_core_test.gd

const V3 = preload("res://platform/match_platform_v3.gd")
const Adapter = preload("res://platform/match_game_adapter.gd")
const Registry = preload("res://platform/platform_adapter_registry.gd")

const PLATFORM_DIR := "res://platform"

## Hersir game vocabulary. Matched as WHOLE WORDS, case-insensitive, so ordinary
## English that merely contains the letters ("required", "example") is fine while the
## seat name `red` or the entity kind `unit` is not.
const FORBIDDEN_GAME_NAMES: Array[String] = [
	"blue", "red", "hero", "unit", "stronghold", "camp", "outpost",
	"recruit", "cast_skill", "hire_merc", "warcry", "militia", "economy",
	"team", "arena", "difficulty", "commander", "warlord", "merc", "gold",
]

## Hersir class names and lifecycle commands the core must never reach for. These are
## the concrete prohibitions from #75: the core does not instantiate the simulation,
## does not drive match lifecycle commands, and does not know the game's protocol
## module or its gameplay-command allow-list.
const FORBIDDEN_IDENTIFIERS: Array[String] = [
	"GameSimulation", "NativeGameSimulation", "GameData",
	"HeroTeamsNetworkArena", "HeroTeamsLobbyServer", "HeroTeamsNetworkProtocol",
	"HeroTeamsWireV2", "HeroTeamsAiTestServer", "ReleaseBattlefield",
	"start_match", "set_controller", "GAMEPLAY_COMMANDS",
]

## Resource roots a platform module may not depend on. `scripts/` is the Hersir rules
## core and view, `server/` is the Hersir-specific server, `network/` is the legacy
## Hersir protocol/codec. The core may only depend on `platform/` (and engine types).
const FORBIDDEN_RESOURCE_ROOTS: Array[String] = [
	"res://scripts/", "res://server/", "res://network/", "res://config/", "res://scenes/",
]

# --- A fictional non-Hersir game -------------------------------------------------
# `gridwars` is the same fictional game the #74 envelope fixtures use. Its slots are
# `north`/`south`, its commands are `place`/`pass`, and its state is a cell array.
# Nothing about it resembles Hersir, which is exactly why it is the test vehicle: if
# the core can run it, the core is not secretly Hersir-shaped.

class GridWarsAdapter:
	extends MatchGameAdapter

	const GAME_ID := "gridwars"
	const CONTENT_HASH := "gw-content-1"

	var created_seed := -1
	var applied: Array = []
	var advanced_ticks := 0
	var cells: Array = []
	var ended := false
	var recover_payload: Variant = null

	func package_descriptor() -> Dictionary:
		return {
			"game_id": GAME_ID, "adapter_version": "0.1.0",
			"content_versions": ["1.0.0"], "content_hashes": [CONTENT_HASH],
			"codec_ids": ["gw-json", "gw-binary"], "tick_rate": 30,
			"slot_policy": {"players": 2},
		}

	func slot_descriptors() -> Array:
		return [
			{"slot_id": "north", "kind": "player", "fillable": true},
			{"slot_id": "south", "kind": "player", "fillable": true},
			{"slot_id": "observer", "kind": "spectator", "fillable": false},
		]

	func validate_match_config(config: Dictionary) -> Dictionary:
		if int(config.get("size", 0)) <= 0:
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "size must be positive")
		return {"ok": true}

	func create_match(config: Dictionary, match_seed: int) -> Dictionary:
		created_seed = match_seed
		cells = []
		for _index in int(config.get("size", 0)):
			cells.append(0)
		return {"ok": true, "match_id": "gw-%d" % match_seed}

	func recover_match(checkpoint_payload: Variant) -> Dictionary:
		if not checkpoint_payload is Dictionary:
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint must be a Dictionary")
		recover_payload = checkpoint_payload
		cells = (checkpoint_payload as Dictionary).get("cells", []).duplicate()
		return {"ok": true, "match_id": "gw-recovered"}

	func validate_join(role: String, requested_slot: Variant, _auth_context: Dictionary) -> Dictionary:
		if role != "player":
			return {"ok": true, "slot": "observer"}
		var wanted := String(requested_slot) if requested_slot != null else ""
		if wanted in ["north", "south"]:
			return {"ok": true, "slot": wanted}
		return V3.reject(V3.REJECT_SLOT_UNAVAILABLE, "no free player slot requested")

	func validate_command(_slot: Variant, payload: Variant) -> Dictionary:
		if not payload is Dictionary:
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "payload must be a Dictionary")
		if String((payload as Dictionary).get("op", "")) not in ["place", "pass"]:
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "unknown op")
		return {"ok": true}

	func apply_command(slot: Variant, payload: Variant) -> void:
		applied.append({"slot": slot, "payload": payload})

	func advance(ticks: int) -> void:
		advanced_ticks += ticks

	func terminal_result() -> Variant:
		return {"victor": "north"} if ended else null

	func state_hash() -> String:
		return "gw:%d:%d" % [advanced_ticks, applied.size()]

	func build_checkpoint(_codec_id: String) -> Dictionary:
		return {"payload": {"cells": cells.duplicate()}, "state_hash": state_hash(), "tick": advanced_ticks}

	func build_delta(from_ack_tick: int, _codec_id: String) -> Dictionary:
		return {"payload": {"changed": applied.size()}, "tick": advanced_ticks, "base_tick": from_ack_tick}

	func drain_events(_codec_id: String) -> Array:
		return [{"reliability": String(V3.DROPPABLE), "payload": {"fx": "spark"}}]

	func metrics() -> Dictionary:
		return {"applied": applied.size()}

## An adapter that cannot state its own identity — used to prove registration is a
## gate rather than a formality.
class NamelessAdapter:
	extends MatchGameAdapter
	func package_descriptor() -> Dictionary:
		return {"adapter_version": "0.1.0"}

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: %s" % message)

func _run() -> void:
	_test_platform_directory_is_game_agnostic()
	_test_registration_gate()
	_test_pre_seat_identity_gate()
	_test_welcome_negotiation()
	_test_match_factory()
	_test_session_store()
	_test_tick_scheduler()
	_test_room_registry()
	_test_code_namespaces()
	_test_match_queue()
	_test_slot_book()
	_test_slot_reservations()
	_test_delivery_queue()
	_test_replication_history()
	_test_replication_baselines()
	_test_replication_grouping()
	if failures.is_empty():
		print("PASS: %d Match Platform Core checks" % checks)
		quit(0)
	else:
		print("FAIL: %d/%d Match Platform Core checks failed" % [failures.size(), checks])
		for failure in failures:
			print(" - %s" % failure)
		quit(1)

# --- 1. Forbidden-reference guard ----------------------------------------------

func _test_platform_directory_is_game_agnostic() -> void:
	var sources := _platform_sources()
	_check(sources.size() >= 3, "platform directory holds the core modules (found %d)" % sources.size())
	for path: String in sources:
		var source := FileAccess.get_file_as_string(path)
		_check(not source.is_empty(), "%s is readable" % path)
		for name: String in FORBIDDEN_GAME_NAMES:
			_check(not _mentions_token(source, name),
				"%s must not mention game name '%s'" % [path, name])
		for identifier: String in FORBIDDEN_IDENTIFIERS:
			_check(not source.contains(identifier),
				"%s must not reference Hersir identifier '%s'" % [path, identifier])
		for root: String in FORBIDDEN_RESOURCE_ROOTS:
			_check(not source.contains(root),
				"%s must not depend on '%s'" % [path, root])

## Every `.gd` under `platform/`, recursively. A directory walk (not a hardcoded
## list) is the point: adding a module to the core cannot silently escape the guard.
func _platform_sources() -> Array[String]:
	var result: Array[String] = []
	var pending: Array[String] = [PLATFORM_DIR]
	while not pending.is_empty():
		var dir_path: String = pending.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if entry.begins_with("."):
				entry = dir.get_next()
				continue
			var full := "%s/%s" % [dir_path, entry]
			if dir.current_is_dir():
				pending.append(full)
			elif entry.ends_with(".gd"):
				result.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	result.sort()
	return result

## True when `name` appears as a whole word (letters/digits/underscore boundaries),
## case-insensitive.
func _mentions_token(text: String, name: String) -> bool:
	var regex := RegEx.new()
	regex.compile("(?i)(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % name)
	return regex.search(text) != null

# --- 2. Registry ----------------------------------------------------------------

func _test_registration_gate() -> void:
	var registry := Registry.new()
	var adapter := GridWarsAdapter.new()
	var registered := registry.register(adapter)
	_check(bool(registered.get("ok", false)) and String(registered.get("game_id", "")) == "gridwars",
		"a descriptor-complete adapter registers under its own game_id")
	_check(registry.registered_game_ids() == ["gridwars"], "registration order is deterministic")
	var runtime := registry.runtime_for("gridwars")
	_check(runtime is InProcessRuntime, "registry wraps a trusted package in the local runtime")
	_check(
		(runtime.package_descriptor().result_now().get("value", {}) as Dictionary).get(
			"game_id", "") == "gridwars",
		"registry runtime reaches the registered package")
	_check(registry.runtime_for("nosuchgame") == null, "unknown game resolves to no runtime")

	var duplicate := registry.register(GridWarsAdapter.new())
	_check(String(duplicate.get("code", "")) == String(V3.REJECT_ADAPTER_REJECTED),
		"a second package cannot claim a registered game_id")

	var nameless := registry.register(NamelessAdapter.new())
	_check(String(nameless.get("code", "")) == String(V3.REJECT_ADAPTER_REJECTED),
		"an adapter without a game_id cannot register")
	_check(String(registry.register(Adapter.new()).get("code", "")) == String(V3.REJECT_ADAPTER_REJECTED),
		"the abstract adapter base cannot register")
	_check(registry.registered_game_ids().size() == 1, "refused registrations leave the package set untouched")

	# The descriptor the registry hands out is a copy: a caller cannot widen the
	# trusted package set after startup by mutating what it was given.
	var descriptor := registry.descriptor("gridwars")
	descriptor["codec_ids"] = ["smuggled"]
	_check(registry.descriptor("gridwars").codec_ids == ["gw-json", "gw-binary"],
		"descriptor copies cannot mutate the registered package")

	_check(registry.slot_descriptors("gridwars").size() == 3, "slot descriptors come from the adapter")
	_check(registry.slot_descriptors("nosuchgame").is_empty(), "unknown game exposes no slots")

func _hello(overrides: Dictionary = {}) -> Dictionary:
	var packet := {
		"pv": V3.ENVELOPE_VERSION, "t": String(V3.HELLO),
		"protocol_versions": [V3.ENVELOPE_VERSION], "game_id": "gridwars",
		"game_version": "1.0.0", "content_hash": GridWarsAdapter.CONTENT_HASH,
		"codecs": ["gw-binary", "gw-json"],
	}
	for key: Variant in overrides.keys():
		packet[key] = overrides[key]
	return packet

func _test_pre_seat_identity_gate() -> void:
	var registry := Registry.new()
	registry.register(GridWarsAdapter.new())

	var resolved := registry.resolve_hello(_hello())
	_check(bool(resolved.get("ok", false)), "a matching hello resolves")
	_check(int(resolved.get("selected_protocol", 0)) == V3.ENVELOPE_VERSION, "protocol negotiates to the platform version")
	_check(String(resolved.get("selected_codec", "")) == "gw-binary",
		"codec negotiation honours client preference order")
	_check(int(resolved.get("tick_rate", 0)) == 30, "tick rate comes from the package descriptor")

	# Each identity failure has exactly one stable code, and each is refused BEFORE
	# any seating happens — that is the whole point of the gate.
	var cases := {
		V3.REJECT_UNKNOWN_GAME: _hello({"game_id": "nosuchgame"}),
		V3.REJECT_UNSUPPORTED_GAME_VERSION: _hello({"game_version": "9.9.9"}),
		V3.REJECT_CONTENT_MISMATCH: _hello({"content_hash": "tampered"}),
		V3.REJECT_UNSUPPORTED_CODEC: _hello({"codecs": ["someone-elses-codec"]}),
		V3.REJECT_UNSUPPORTED_PROTOCOL: _hello({"protocol_versions": [1, 2]}),
	}
	for expected: StringName in cases.keys():
		var outcome := registry.resolve_hello(cases[expected])
		_check(not bool(outcome.get("ok", false)) and String(outcome.get("code", "")) == String(expected),
			"hello is refused with '%s'" % expected)

	# Structural failures are still structural: a hello missing a mandatory identity
	# field never reaches negotiation.
	var stripped := _hello()
	stripped.erase("content_hash")
	_check(String(registry.resolve_hello(stripped).get("code", "")) == String(V3.REJECT_MALFORMED_ENVELOPE),
		"a hello missing mandatory identity is malformed, not merely mismatched")
	_check(String(registry.resolve_hello(_hello({"codecs": "gw-json"})).get("code", "")) == String(V3.REJECT_MALFORMED_ENVELOPE),
		"a non-Array codec list is malformed")
	_check(String(registry.resolve_hello({"pv": V3.ENVELOPE_VERSION, "t": "join"}).get("code", "")) == String(V3.REJECT_MALFORMED_ENVELOPE),
		"a non-hello envelope cannot open a session")

func _test_welcome_negotiation() -> void:
	var registry := Registry.new()
	registry.register(GridWarsAdapter.new())
	var welcome := registry.welcome_for(_hello(), {"resync": true})
	_check(bool(V3.validate_envelope(welcome, V3.SERVER_MESSAGES).get("ok", false)),
		"welcome_for builds a contract-valid welcome envelope")
	_check(String(welcome.get("adapter_version", "")) == "0.1.0", "welcome carries the adapter version")
	_check(bool(welcome.get("capabilities", {}).get("resync", false)),
		"capabilities are platform-declared, not game-declared")
	var refusal := registry.welcome_for(_hello({"game_id": "nosuchgame"}))
	_check(String(refusal.get("t", "")) == String(V3.REJECT) and String(refusal.get("code", "")) == String(V3.REJECT_UNKNOWN_GAME),
		"a refused hello yields a reject envelope in place of a welcome")
	_check(bool(V3.validate_envelope(refusal, V3.SERVER_MESSAGES).get("ok", false)),
		"the reject envelope is itself contract-valid")

func _test_match_factory() -> void:
	var registry := Registry.new()
	var adapter := GridWarsAdapter.new()
	registry.register(adapter)

	var created := registry.create_match("gridwars", {"size": 9}, 4242)
	_check(bool(created.get("ok", false)) and String(created.get("match_id", "")) == "gw-4242",
		"the factory creates a match through the adapter")
	_check(adapter.created_seed == 4242, "the deterministic seed reaches the adapter unchanged")

	var refused := registry.create_match("gridwars", {"size": 0}, 1)
	_check(String(refused.get("code", "")) == String(V3.REJECT_ADAPTER_REJECTED),
		"an adapter-refused config never becomes a match")
	_check(String(registry.create_match("nosuchgame", {"size": 9}, 1).get("code", "")) == String(V3.REJECT_UNKNOWN_GAME),
		"an unregistered game cannot create a match")

	var recovered := registry.recover_match("gridwars", {"cells": [1, 0, 1]})
	_check(bool(recovered.get("ok", false)) and adapter.cells == [1, 0, 1],
		"recovery hands the opaque checkpoint payload to the adapter")
	_check(String(registry.recover_match("gridwars", "not-a-checkpoint").get("code", "")) == String(V3.REJECT_ADAPTER_REJECTED),
		"an unusable checkpoint is refused by the adapter, not interpreted by the core")

# --- 3. Session store -----------------------------------------------------------

func _test_session_store() -> void:
	# A tight budget (2 commands/sec, burst 2) makes the limiter's behaviour observable
	# without sleeping: the third frame in a burst must be refused.
	var store := PlatformSessionRegistry.new(2.0, 2.0, 2)
	var session := store.open(11)
	_check(store.has(11) and not String(session.token).is_empty(), "opening a session mints a resume token")
	_check(store.open(12).token != session.token, "resume tokens are distinct per session")
	_check(not store.is_seated(11) and store.room_id(11) == 0 and store.slot(11) == "",
		"a fresh session is connected but unseated")

	_check(store.consume_rate_token(11) and store.consume_rate_token(11),
		"the admission bucket starts full so a legitimate opening burst is not throttled")
	_check(not store.consume_rate_token(11), "a session over budget is refused")
	_check(store.consume_rate_token(12), "one peer's spending never touches another's budget")
	_check(not store.consume_rate_token(999), "an unknown peer has no budget to spend")

	_check(store.accept_sequence(11, 1) and store.accept_sequence(11, 2), "sequences advance")
	_check(not store.accept_sequence(11, 2), "a duplicate sequence is refused")
	_check(not store.accept_sequence(11, 1), "a replayed older sequence is refused")
	_check(store.accept_sequence(11, 9) and store.last_sequence(11) == 9, "a forward jump is accepted and recorded")

	_check(store.negotiate_protocol(11, 7) == 2, "a requested wire version is clamped to the ceiling")
	_check(store.negotiate_protocol(11, 0) == 1, "a below-floor request clamps up")
	_check(store.protocol(11) == 1, "the negotiated version is remembered")

	# Placement records an opaque slot the core never interprets — here a slot name from
	# a game that has no notion of the two seats Hersir uses.
	store.assign_seat(11, 4, "player", "north")
	_check(store.room_id(11) == 4 and store.slot(11) == "north" and store.is_seated(11),
		"placement records room, role and opaque slot")
	store.clear_seat(11)
	_check(store.room_id(11) == 0 and not store.is_seated(11) and store.role(11) == PlatformSessionRegistry.ROLE_UNSEATED,
		"clearing a seat returns the session to unseated")

	store.adopt_token(11, "seat-token")
	_check(store.token(11) == "seat-token", "a resuming peer adopts the seat's token, not its own")
	var closed := store.close(11)
	_check(not store.has(11) and String(closed.token) == "seat-token",
		"closing returns the last session so the room can find the seat it held")
	_check(store.close(11).is_empty(), "closing an unknown peer is harmless")

# --- 4. Tick scheduler ----------------------------------------------------------

func _test_tick_scheduler() -> void:
	var tick := 1.0 / 60.0
	var scheduler := PlatformTickScheduler.new(tick)
	_check(scheduler.advance(tick * 3.0) == 3, "whole ticks are released for accumulated time")
	_check(scheduler.advance(tick * 0.5) == 0, "a partial tick releases nothing")
	_check(scheduler.advance(tick * 0.6) == 1, "banked fractions combine into the next tick")
	_check(scheduler.processed_ticks == 4, "released ticks are counted")

	# The frame clamp is the reason one stall cannot stall every peer: a 10-second
	# delta must not release 600 ticks in a single frame.
	var stalled := PlatformTickScheduler.new(tick)
	var burst := stalled.advance(10.0)
	_check(burst == int(PlatformTickScheduler.MAX_FRAME_SECONDS / tick),
		"a long stall is clamped to one frame's worth of catch-up (got %d)" % burst)

	var fast := PlatformTickScheduler.new(tick, 4.0)
	_check(fast.advance(tick) == 4, "the multiplier scales how many ticks a frame releases")

	# Deferred acceleration: real time until the threshold, multiplied afterwards.
	var deferred := PlatformTickScheduler.new(tick, 10.0, 2)
	_check(deferred.effective_multiplier() == 1.0, "the deferred window runs at real time")
	deferred.advance(tick * 2.0)
	_check(deferred.processed_ticks == 2 and deferred.effective_multiplier() == 10.0,
		"acceleration engages once the real-time window has elapsed")
	deferred.reset()
	_check(deferred.processed_ticks == 0 and deferred.pending_seconds() == 0.0, "reset clears the clock")

# --- 5. Room registry -----------------------------------------------------------

func _test_room_registry() -> void:
	var registry := PlatformRoomRegistry.new(2, 5000)
	var first := registry.allocate()
	_check(int(first.room_id) == 1 and int(first.seed) == 5001, "allocation hands out an id and a seed")
	_check(registry.size() == 0, "allocation alone does not register a room")
	registry.attach(int(first.room_id), String(first.code), RefCounted.new())
	_check(registry.size() == 1 and registry.has_room(1), "attach registers the constructed room")

	var second := registry.allocate("PUBLIC1")
	registry.attach(int(second.room_id), "PUBLIC1", RefCounted.new())
	_check(int(second.seed) == 5002, "seeds advance monotonically so every match is distinct")
	_check(not registry.has_capacity() and registry.allocate().is_empty(),
		"a server at capacity refuses to open another room rather than degrading all of them")

	_check(registry.room_id_for_code("PUBLIC1") == 2, "a room is reachable by its code")
	_check(registry.room_for_code(String(first.code)) != null, "a reserved code resolves to its room")
	_check(registry.room_for_code("NOSUCH") == null, "an unknown code resolves to nothing")
	_check(registry.code_for_room(2) == "PUBLIC1", "a room reports its own code")
	_check(registry.allocate("PUBLIC1").is_empty(), "a live code cannot be allocated twice")
	_check(registry.room_ids() == [1, 2], "room ids are exposed in allocation order")
	_check(registry.room_list().size() == 2, "room objects are exposed in the same order")

	var closed: Array[int] = []
	registry.room_closed.connect(func(room_id: int) -> void: closed.append(room_id))
	_check(registry.close(2) and closed == [2], "closing a room announces it")
	_check(registry.size() == 1 and not registry.code_taken("PUBLIC1"), "closing frees both the room and its code")
	_check(registry.has_capacity(), "closing a room restores capacity")
	_check(not registry.close(2), "closing an already-closed room is a no-op")

func _test_code_namespaces() -> void:
	var registry := PlatformRoomRegistry.new(4, 1)
	_check(PlatformRoomRegistry.normalize_public_code("  abc123 ") == "ABC123",
		"player-typed codes are trimmed and upper-cased")
	_check(PlatformRoomRegistry.normalize_public_code("ab") == "", "a too-short code is refused")
	_check(PlatformRoomRegistry.normalize_public_code("A".repeat(13)) == "", "a too-long code is refused")
	_check(PlatformRoomRegistry.normalize_public_code("AB!123") == "", "a non-alphanumeric code is refused")

	# The security property: a server-allocated code must not be reachable through
	# player-code validation, or a player could type their way into any live match.
	var reserved := PlatformRoomRegistry.mint_reserved_code()
	_check(reserved.begins_with(PlatformRoomRegistry.RESERVED_PREFIX),
		"server-allocated codes live in the reserved namespace")
	_check(PlatformRoomRegistry.normalize_public_code(reserved) == "",
		"a reserved code can never be produced by player-code validation")
	_check(PlatformRoomRegistry.normalize_lookup_code(reserved) == reserved,
		"lookup accepts a reserved code so an observer can find a server-allocated room")
	_check(PlatformRoomRegistry.normalize_lookup_code(reserved.substr(0, reserved.length() - 1)) == "",
		"a partially guessed reserved code is refused, not widened into a public match")
	_check(PlatformRoomRegistry.normalize_lookup_code("%sZZZZZZZZ" % PlatformRoomRegistry.RESERVED_PREFIX) == "",
		"a reserved code outside the hex alphabet is refused")
	_check(PlatformRoomRegistry.mint_reserved_code() != reserved, "reserved codes are random, not sequential")

	var public_code := registry.mint_public_code()
	_check(PlatformRoomRegistry.normalize_public_code(public_code) == public_code,
		"a server-generated public code is itself player-enterable")
	registry.attach(1, public_code, RefCounted.new())
	_check(registry.mint_public_code() != public_code, "a live code is never minted again")

# --- 6. Match queue -------------------------------------------------------------

func _test_match_queue() -> void:
	var queue := PlatformMatchQueue.new()
	_check(queue.is_empty() and queue.size() == 0, "a new queue is empty")
	_check(queue.enqueue(21, {"want": "north"}), "a waiting peer is queued")
	_check(queue.enqueue(22) and queue.enqueue(23), "further peers append in arrival order")
	_check(not queue.enqueue(21), "a peer already waiting cannot take a second slot")
	_check(queue.size() == 3 and queue.position(21) == 1 and queue.position(23) == 3,
		"positions reflect arrival order")
	_check(queue.position(999) == 0, "an unqueued peer has no position")

	var notified: Array = []
	queue.each_position(func(peer_id: int, position: int, total: int) -> void:
		notified.append([peer_id, position, total]))
	_check(notified == [[21, 1, 3], [22, 2, 3], [23, 3, 3]], "every waiting peer is told its position and the total")

	_check(queue.remove(22) and not queue.has(22), "a leaving peer releases its slot")
	_check(not queue.remove(22), "removing an absent peer reports no change")
	_check(queue.position(23) == 2, "removal closes the gap without reordering")

	# Only peer 23 can be placed; 21 must keep its place at the front rather than
	# being overtaken by the peer behind it.
	queue.enqueue(24)
	var seen: Array = []
	var removed := queue.drain(func(peer_id: int, options: Dictionary) -> bool:
		seen.append(peer_id)
		return peer_id == 23 and options.is_empty())
	_check(removed == 1 and not queue.has(23), "drain removes exactly the resolved entries")
	_check(seen == [21, 23, 24], "drain visits waiting peers in arrival order")
	_check(queue.position(21) == 1 and queue.position(24) == 2,
		"refused entries keep their relative order after a drain")
	_check(PlatformMatchQueue.new().drain(func(_p: int, _o: Dictionary) -> bool: return true) == 0,
		"draining an empty queue is a no-op")

# --- 7. Slot book ---------------------------------------------------------------

## Slot ids from the fictional game, so nothing here depends on Hersir's two seats.
const GW_SLOTS: Array[String] = ["north", "south"]

func _test_slot_book() -> void:
	var book := PlatformSlotBook.new(GW_SLOTS)
	_check(book.slot_ids() == GW_SLOTS, "the book seats exactly the declared slots, in order")
	_check(book.has_slot("north") and not book.has_slot("east"), "only declared slots exist")
	_check(book.has_free_slot() and book.first_free_slot() == "north",
		"an unpreferenced joiner takes the first slot in declaration order")
	_check(PlatformSlotBook.new(["north", "north"]).slot_ids() == ["north"],
		"a duplicate slot id is declared once")

	var claimed := book.claim(31, "tok-31", "south")
	_check(bool(claimed.ok) and String(claimed.slot) == "south", "a preferred free slot is honoured")
	_check(book.first_free_slot() == "north", "the remaining slot stays free")
	var second := book.claim(32, "tok-32", "south")
	_check(bool(second.ok) and String(second.slot) == "north",
		"a taken preference falls back to the first free slot")
	var stray := PlatformSlotBook.new(GW_SLOTS).claim(33, "tok-33", "east")
	_check(bool(stray.ok) and String(stray.slot) == "north",
		"a preference naming no declared slot falls back rather than failing")

	var full := book.claim(34, "tok-34")
	_check(not bool(full.get("ok", false)) and String(full.reason) == "room_full",
		"a full room refuses another occupant")
	_check(not book.has_free_slot() and book.occupied_count() == 2 and book.connected_count() == 2,
		"a full room reports both slots occupied and connected")

	_check(book.slot_for_peer(31) == "south" and book.slot_for_peer(999) == "",
		"a connected peer resolves to its slot")
	_check(book.has_peer(31) and not book.has_peer(999), "membership follows occupancy")
	# Spectators hold no slot, so they never consume capacity.
	book.add_spectator(41)
	_check(book.is_spectator(41) and book.has_peer(41) and book.occupied_count() == 2,
		"a spectator joins without taking a slot")
	_check(book.connected_peer_ids().size() == 3, "traffic reaches occupants and spectators alike")
	_check(not book.is_abandoned(), "an occupied room is not abandoned")

	_check(String(book.release(41, 10).role) == PlatformSlotBook.ROLE_SPECTATOR,
		"releasing a spectator reports the spectator role")
	_check(not book.is_spectator(41), "a released spectator is forgotten")
	_check(book.release(999, 10).is_empty(), "releasing an unknown peer reports nothing")

	_check(book.vacate("south") and not bool(book.seats.south.occupied),
		"vacating frees a slot outright")
	_check(not book.vacate("east"), "vacating an unknown slot is a no-op")

func _test_slot_reservations() -> void:
	var book := PlatformSlotBook.new(GW_SLOTS)
	book.claim(51, "tok-51", "north")

	# A dropped socket must not read as a departure: the slot stays occupied and
	# reserved, so a two-second outage cannot hand the seat to someone else.
	var released := book.release(51, 100)
	_check(String(released.role) == PlatformSlotBook.ROLE_PLAYER and String(released.slot) == "north"
			and String(released.token) == "tok-51",
		"releasing an occupant reports the slot and its resume token")
	_check(bool(book.seats.north.occupied) and not bool(book.seats.north.connected),
		"a dropped occupant keeps its slot reserved")
	_check(book.occupied_count() == 1 and book.connected_count() == 0,
		"a reservation counts as occupied but not connected")
	_check(book.slot_for_peer(51) == "", "a disconnected occupant cannot act")
	_check(not book.is_abandoned(), "a reserved slot keeps the room alive through the outage")
	_check(book.first_free_slot() == "south", "the reserved slot is not offered to a new joiner")

	# Only the token holder may reclaim it.
	_check(not bool(book.resume("wrong-token", 52).get("ok", false)), "a wrong token reclaims nothing")
	_check(not bool(book.resume("", 52).get("ok", false)), "an empty token reclaims nothing")
	var resumed := book.resume("tok-51", 52)
	_check(bool(resumed.ok) and String(resumed.slot) == "north" and int(resumed.evicted) == PlatformSlotBook.NO_PEER,
		"the token holder reclaims its slot on a new connection")
	_check(book.slot_for_peer(52) == "north" and book.connected_count() == 1,
		"the reclaimed slot is bound to the new peer")

	# Half-open: the server still believes 52's socket is live when the same client
	# reconnects. The token proves ownership, so 53 takes the seat and 52 is evicted.
	var half_open := book.resume("tok-51", 53)
	_check(bool(half_open.ok) and int(half_open.evicted) == 52,
		"a valid token evicts a half-open predecessor rather than being refused")
	_check(book.slot_for_peer(53) == "north" and book.slot_for_peer(52) == "",
		"the seat follows the token, not the older socket")

	# Grace expiry is measured from the disconnect tick.
	book.release(53, 200)
	_check(book.expire_reservations(200 + 59, 60).is_empty(),
		"a reservation inside the grace period survives")
	_check(bool(book.seats.north.occupied), "the slot is still held while the grace period runs")
	_check(book.expire_reservations(200 + 60, 60) == ["north"],
		"a reservation past the grace period is reported as expired")
	_check(not bool(book.seats.north.occupied) and book.is_abandoned(),
		"an expired reservation frees the slot and leaves the room abandoned")
	_check(not bool(book.resume("tok-51", 54).get("ok", false)),
		"a token cannot reclaim a slot after its reservation expired")
	_check(book.expire_reservations(9999, 60).is_empty(), "expiry over a vacant book reports nothing")

# --- 8. Delivery queue ----------------------------------------------------------

## A minimal stand-in for a game's codec. It splits by declared delivery class and
## encodes each message to a byte length it is told to use, so the queue's batching,
## grouping and ceiling behaviour can be asserted without any real wire format.
class StubCodec:
	extends RefCounted

	## Bytes each encoded frame should claim to be. Set above the queue's ceiling to
	## exercise the drop path.
	var frame_size := 8
	var encode_calls: Array = []

	func delivery_groups(messages: Array) -> Array:
		var by_class: Dictionary = {}
		var order: Array = []
		for message: Dictionary in messages:
			var reliability := StringName(message.get("reliability", "reliable"))
			if not by_class.has(reliability):
				by_class[reliability] = []
				order.append(reliability)
			(by_class[reliability] as Array).append(message)
		var result: Array = []
		for reliability: Variant in order:
			result.append({"reliability": reliability, "messages": by_class[reliability]})
		return result

	## One frame per call, sized as configured, with the protocol stamped in byte 0 so
	## a test can tell the per-version encodes apart.
	func encode_batches_for(messages: Array, protocol: int) -> Array:
		encode_calls.append({"count": messages.size(), "protocol": protocol})
		var bytes := PackedByteArray()
		bytes.resize(frame_size)
		bytes[0] = protocol
		return [bytes]

func _test_delivery_queue() -> void:
	var codec := StubCodec.new()
	# Peer 61 speaks version 2, everyone else version 1.
	var queue := PlatformDeliveryQueue.new(codec, 64, func(peer_id: int) -> int: return 2 if peer_id == 61 else 1)
	var targeted: Array = []
	var broadcast: Array = []
	queue.target_frame.connect(func(peer_id: int, bytes: PackedByteArray, reliability: StringName) -> void:
		targeted.append({"peer_id": peer_id, "size": bytes.size(), "reliability": String(reliability)}))
	queue.broadcast_frame.connect(func(peer_ids: Array, bytes: PackedByteArray, reliability: StringName) -> void:
		broadcast.append({"peers": peer_ids.duplicate(), "protocol": bytes[0], "reliability": String(reliability)}))

	# Batching: a tick's worth of messages for one peer leaves as one frame per class.
	queue.enqueue_target(60, {"n": 1, "reliability": "reliable"})
	queue.enqueue_target(60, {"n": 2, "reliability": "reliable"})
	queue.enqueue_target(60, {"n": 3, "reliability": "droppable"})
	_check(queue.pending_target_count(60) == 3, "queued messages wait for a flush")
	queue.flush_target(60)
	_check(targeted.size() == 2, "one frame per delivery class, not one per message")
	_check(codec.encode_calls[0].count == 2 and codec.encode_calls[1].count == 1,
		"messages are grouped by delivery class before encoding")
	_check(String(targeted[0].reliability) == "reliable" and String(targeted[1].reliability) == "droppable",
		"each frame carries the class of the messages inside it")
	_check(queue.pending_target_count(60) == 0, "flushing clears the outbox")
	queue.flush_target(60)
	_check(targeted.size() == 2, "flushing an empty outbox emits nothing")

	# A departed peer's queued traffic is discarded rather than held forever.
	queue.enqueue_target(62, {"n": 9})
	queue.drop_target(62)
	queue.flush_targets()
	_check(not targeted.any(func(frame: Dictionary) -> bool: return int(frame.peer_id) == 62),
		"a dropped peer's queued messages are never sent")

	# Encode-once: peers sharing a payload and a version share the encode; a peer on a
	# different version gets its own frame.
	codec.encode_calls.clear()
	queue.emit_grouped([60, 61, 63], [{"n": 1}], &"replaceable")
	_check(broadcast.size() == 2, "peers are grouped by negotiated wire version")
	_check(codec.encode_calls.size() == 2, "one encode per version, not one per peer")
	var v1_frame: Dictionary = broadcast[0] if int(broadcast[0].protocol) == 1 else broadcast[1]
	var v2_frame: Dictionary = broadcast[1] if int(broadcast[0].protocol) == 1 else broadcast[0]
	_check((v1_frame.peers as Array).size() == 2 and (v2_frame.peers as Array) == [61],
		"each frame goes to exactly the peers that can decode it")
	_check(String(v1_frame.reliability) == "replaceable", "the declared class rides with the frame")

	# Shared broadcast messages are *taken*, because only the caller knows how peers
	# group for their state payload.
	queue.enqueue_broadcast({"n": 1})
	queue.enqueue_broadcast({"n": 2})
	_check(queue.pending_broadcast_count() == 2, "broadcast messages accumulate until taken")
	_check(queue.take_broadcast().size() == 2 and queue.pending_broadcast_count() == 0,
		"taking the broadcast queue drains it")

	# The ceiling: an oversized frame is dropped and counted here, not sent to be
	# discarded whole at the far end.
	var before_peak := queue.frame_bytes_peak
	var before_rejected := queue.rejected_frames
	codec.frame_size = 65
	queue.enqueue_target(60, {"n": 1})
	queue.flush_target(60)
	_check(queue.rejected_frames == before_rejected + 1, "an oversized frame is counted as rejected")
	_check(queue.frame_bytes_peak == before_peak, "a rejected frame never enters the size peak")
	_check(not targeted.any(func(frame: Dictionary) -> bool: return int(frame.size) > 64),
		"no frame above the ceiling is ever emitted")

	var telemetry := queue.telemetry()
	_check(int(telemetry.rejected_frames) == queue.rejected_frames
			and int(telemetry.frame_bytes_peak) == queue.frame_bytes_peak
			and telemetry.has("encode_usec") and telemetry.has("send_usec"),
		"telemetry reports the outbound-path counters")

	# With no protocol resolver the queue still works, at the default version.
	var bare := PlatformDeliveryQueue.new(StubCodec.new(), 64, Callable())
	var bare_frames: Array = []
	bare.target_frame.connect(func(_p: int, bytes: PackedByteArray, _r: StringName) -> void:
		bare_frames.append(bytes[0]))
	bare.enqueue_target(70, {"n": 1})
	bare.flush_target(70)
	_check(bare_frames == [1], "a queue without a version resolver falls back to the default")

# --- 9. Replication ring --------------------------------------------------------

func _test_replication_history() -> void:
	# 10 ticks of history, 5-tick repair cooldown.
	var ring := PlatformReplicationRing.new(10, 5)
	ring.record(0, {"cells": [0]})
	ring.record(4, {"cells": [1]})
	_check(ring.size() == 2 and ring.has_baseline(4), "baselines are retained by tick")
	_check(ring.baseline(4).cells == [1], "a retained baseline hands back its opaque payload")
	_check(ring.baseline(99).is_empty(), "an unknown tick has no baseline")

	# Re-recording a tick must replace it, not create a second disagreeing entry: the
	# same tick can legitimately be recorded twice (a join snapshot on a broadcast tick).
	ring.record(4, {"cells": [2]})
	_check(ring.size() == 2 and ring.baseline(4).cells == [2],
		"re-recording a tick replaces it rather than appending a duplicate")

	# The window is bounded, or history would grow for the room's lifetime.
	ring.record(13)
	_check(not ring.has_baseline(0) and ring.has_baseline(4),
		"a baseline older than the window is evicted, one inside it is kept")
	ring.record(100)
	_check(ring.size() == 1 and ring.has_baseline(100),
		"the newest baseline is always retained even when everything else ages out")

	_check(ring.next_sequence() == 1 and ring.next_sequence() == 2, "the broadcast sequence advances")
	ring.record(101, {"cells": [3]})
	_check(ring.estimate_bytes() > 0, "retained payload size can be estimated on request")
	ring.reset()
	_check(ring.size() == 0 and ring.sequence == 0,
		"a restart drops every baseline, since they all describe a world that no longer exists")

	# Externally-owned mode mirrors tick keys only, with the identical eviction rule.
	var mirrored := PlatformReplicationRing.new(10, 5, true)
	mirrored.record(0, {"ignored": true})
	mirrored.record(4)
	_check(mirrored.has_baseline(4) and mirrored.baseline(4).is_empty(),
		"externally-owned mode tracks the tick without storing a payload")
	mirrored.record(13)
	_check(not mirrored.has_baseline(0) and mirrored.has_baseline(4),
		"the mirror evicts exactly as the payload history does")
	_check(mirrored.baseline_ticks() == [4, 13] and mirrored.estimate_bytes() == 0,
		"the mirror reports its tick keys and no retained bytes")

func _test_replication_baselines() -> void:
	var ring := PlatformReplicationRing.new(10, 5)
	for tick in 11:
		ring.record(tick, {"t": tick})

	# A joining peer adopts the full payload it was just sent.
	ring.adopt_full(81, 6, 100)
	_check(int(ring.peer_baseline[81]) == 6 and not bool(ring.peer_acked[81]),
		"a full payload becomes the peer's baseline and clears its ack state")
	_check(ring.full_payloads_sent == 1, "full payloads are counted")
	_check(ring.resolve_baseline(81, 8) == 6, "a live baseline older than the current tick is usable")
	_check(ring.resolve_baseline(81, 6) == PlatformReplicationRing.NO_BASELINE,
		"a baseline equal to the current tick is not usable — an increment to itself carries nothing")
	_check(ring.resolve_baseline(999, 8) == PlatformReplicationRing.NO_BASELINE,
		"an unknown peer has no baseline")

	# An acknowledgement beyond what was sent describes state the peer cannot hold.
	_check(not ring.apply_ack(81, 7) and ring.rejected_acks == 1,
		"an ack beyond the last tick sent to the peer is refused")
	_check(not ring.apply_ack(81, -1) and ring.rejected_acks == 2, "a negative ack is refused")
	_check(int(ring.peer_baseline[81]) == 6, "a refused ack never moves the baseline")

	# The first ack is ground truth even when older than the optimistic guess.
	ring.peer_last_sent_tick[81] = 10
	_check(ring.apply_ack(81, 3) and int(ring.peer_baseline[81]) == 3,
		"the first ack is believed even when it is older than the current baseline")
	_check(bool(ring.peer_acked[81]), "the peer is now known to acknowledge")
	_check(ring.apply_ack(81, 8) and int(ring.peer_baseline[81]) == 8, "later acks move the baseline forward")
	_check(ring.apply_ack(81, 5) and int(ring.peer_baseline[81]) == 8,
		"an older ack after the first never rewinds the confirmed baseline")

	# An ack whose baseline has already aged out counts as an ack but moves nothing.
	ring.record(40)
	ring.peer_last_sent_tick[81] = 40
	_check(ring.apply_ack(81, 8) and int(ring.peer_baseline[81]) == 8,
		"an ack for an aged-out baseline is accepted without pinning an unusable baseline")

	ring.forget_peer(81)
	_check(not ring.peer_baseline.has(81) and not ring.peer_acked.has(81)
			and not ring.peer_last_full_tick.has(81) and not ring.peer_last_sent_tick.has(81),
		"a departed peer's bookkeeping is dropped entirely")

func _test_replication_grouping() -> void:
	var ring := PlatformReplicationRing.new(10, 5)
	for tick in 11:
		ring.record(tick, {"t": tick})

	# A scheduled full payload overrides everything, including a throttled peer.
	_check(ring.resolve_group(91, 10, 100, true) == PlatformReplicationRing.GROUP_FULL_SCHEDULED,
		"a scheduled full payload wins over every other consideration")
	_check(ring.resolve_group(91, 10, 100, true, true) == PlatformReplicationRing.GROUP_FULL_SCHEDULED,
		"a throttled peer still receives the scheduled full payload")
	_check(ring.resolve_group(91, 10, 100, false, true) == PlatformReplicationRing.GROUP_SKIP,
		"an intentionally throttled peer is skipped")

	# No baseline and no cooldown yet → repair.
	_check(ring.resolve_group(91, 10, 100, false) == PlatformReplicationRing.GROUP_FULL_REPAIR,
		"a peer with no usable baseline is repaired with full state")
	ring.adopt_full(91, 6, 100)
	_check(ring.resolve_group(91, 10, 100, false) == 6,
		"a peer with a live baseline gets an increment from it")

	# The cooldown is what stops one bad network moment becoming a full-state storm.
	ring.peer_baseline[91] = PlatformReplicationRing.NO_BASELINE
	_check(ring.resolve_group(91, 10, 104, false) == PlatformReplicationRing.GROUP_SKIP,
		"a peer inside its repair cooldown is skipped rather than repaired again")
	_check(ring.resolve_group(91, 10, 105, false) == PlatformReplicationRing.GROUP_FULL_REPAIR,
		"once the cooldown elapses the repair is served")
	_check(not ring.request_repair(91, 104) and ring.repair_requests == 1,
		"a repair request inside the cooldown is counted as load but refused")
	_check(ring.request_repair(91, 105) and ring.repair_requests == 2,
		"a repair request past the cooldown is served")

	_check(PlatformReplicationRing.groups_need_full([6, 7], false) == false,
		"a round of pure increments needs no full payload built")
	_check(PlatformReplicationRing.groups_need_full([6], true),
		"a scheduled round always needs the full payload")
	_check(PlatformReplicationRing.groups_need_full([6, PlatformReplicationRing.GROUP_FULL_REPAIR], false),
		"one peer needing repair is enough to require the full payload")
	_check(not PlatformReplicationRing.groups_need_full([PlatformReplicationRing.GROUP_SKIP], false),
		"a skipped group needs nothing built")

	# Advancing: acknowledging peers move only on their own reports; silent peers are
	# advanced optimistically, which is all that can be assumed about them.
	var advancing := PlatformReplicationRing.new(10, 5)
	for tick in 11:
		advancing.record(tick, {"t": tick})
	advancing.adopt_full(92, 2, 100)
	advancing.adopt_full(93, 2, 100)
	advancing.peer_last_sent_tick[93] = 2
	advancing.apply_ack(93, 2)
	advancing.advance_group(2, [92, 93], 8, 110)
	_check(int(advancing.peer_baseline[92]) == 8, "a silent peer advances optimistically to the tick just sent")
	_check(int(advancing.peer_baseline[93]) == 2, "an acknowledging peer's baseline moves only on its own acks")
	_check(int(advancing.peer_last_sent_tick[92]) == 8 and int(advancing.peer_last_sent_tick[93]) == 8,
		"both peers record the tick placed on their outbound path")

	advancing.advance_group(PlatformReplicationRing.GROUP_FULL_SCHEDULED, [93], 9, 120)
	_check(int(advancing.peer_baseline[93]) == 9 and int(advancing.peer_last_full_tick[93]) == 120,
		"full state becomes the baseline for everyone that received it, and restarts their cooldown")

	var before := int(advancing.peer_baseline[92])
	advancing.advance_group(PlatformReplicationRing.GROUP_SKIP, [92], 12, 130)
	_check(int(advancing.peer_baseline[92]) == before and int(advancing.peer_last_sent_tick[92]) == 8,
		"a skipped group advances nothing — the peer was sent nothing")

	var telemetry := advancing.telemetry()
	_check(int(telemetry.full_payloads_sent) == 2 and telemetry.has("repair_requests")
			and telemetry.has("rejected_acks") and int(telemetry.baseline_bytes) == 0,
		"telemetry reports the replication counters without serializing history by default")
