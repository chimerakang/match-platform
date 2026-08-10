class_name ShooterLobby
extends RefCounted

## Transport-agnostic lobby for neon-platform-shooter on Match Platform V3.
##
## Owns N arenas (each: an independent NeonShooterAdapter + platform slot book +
## replication ring) plus a global spectator queue, and speaks the frozen V3
## envelope. This is the match-platform equivalent of netgame's lobby: seat into
## the first arena with a free slot, queue when every arena is full, and run the
## "野球賽" rotation at each round boundary — lowest-scoring human rotates to the
## back of the queue, the next waiter takes the seat. Bot backfill is internal to
## each adapter (idle slots), so the lobby only manages human seats.
##
## Pure logic: outbound bytes go through an injected `send_cb(peer_id, bytes)`, so
## the WebSocket host and unit tests drive the same code.

const V3 = preload("res://platform/match_platform_v3.gd")
const Registry = preload("res://platform/platform_adapter_registry.gd")
const Sessions = preload("res://platform/platform_session_registry.gd")
const Slots = preload("res://platform/platform_slot_book.gd")
const Ring = preload("res://platform/platform_replication_ring.gd")
const Delivery = preload("res://platform/platform_delivery_queue.gd")
const Scheduler = preload("res://platform/platform_tick_scheduler.gd")
const Adapter = preload("res://games/neon-shooter/adapters/neon_shooter_adapter.gd")
const Codec = preload("res://games/neon-shooter/adapters/neon_shooter_codec.gd")

const STATE_INTERVAL := 2   # broadcast state at 15 Hz (sim runs at 30 Hz)

var registry: Registry
var sessions: Sessions
var delivery: Delivery
var codec: Codec
var scheduler: Scheduler
var arenas: Array = []              # each: {id, match_id, adapter, slots, ring, last_round}
var queue: Array[int] = []          # peer ids waiting (spectate arena 0)
var loc: Dictionary = {}            # peer_id -> {arena: int, role: "player"|"queue"}
var _welcomed: Dictionary = {}      # peer_id -> bool
var _send: Callable


func _init(num_arenas: int, seed_base: int, send_cb: Callable) -> void:
	_send = send_cb
	registry = Registry.new()
	registry.register(Adapter.new())   # identity/codec gate only (descriptor)
	sessions = Sessions.new(30.0, 60.0, V3.ENVELOPE_VERSION)
	codec = Codec.new()
	delivery = Delivery.new(codec, V3.MAX_ENVELOPE_BYTES, func(_peer_id: int) -> int: return V3.ENVELOPE_VERSION)
	delivery.target_frame.connect(func(peer_id: int, bytes: PackedByteArray, _reliability: StringName) -> void:
		_send.call(peer_id, bytes))
	scheduler = Scheduler.new(1.0 / float(Adapter.TICK_RATE))
	for i in maxi(1, num_arenas):
		var adapter := Adapter.new()
		adapter.create_match({"match_id": "neon:%d" % (i + 1)}, seed_base + i)
		arenas.append({
			"id": i, "match_id": "neon:%d" % (i + 1), "adapter": adapter,
			"slots": Slots.new(Adapter.PARTICIPANT_SLOTS), "ring": Ring.new(120, 30),
			"last_round": 0,
		})


# --- Peer lifecycle ---------------------------------------------------------
func open_peer(peer_id: int) -> void:
	sessions.open(peer_id)


func close_peer(peer_id: int) -> void:
	var where: Dictionary = loc.get(peer_id, {})
	if not where.is_empty():
		if String(where.get("role", "")) == "player":
			var arena: Dictionary = arenas[int(where.arena)]
			var slot: String = arena.slots.slot_for_peer(peer_id)
			if not slot.is_empty():
				arena.slots.vacate(slot)
			arena.ring.forget_peer(peer_id)
		else:
			queue.erase(peer_id)
	sessions.close(peer_id)
	_welcomed.erase(peer_id)
	loc.erase(peer_id)
	_seat_waiters()
	_broadcast_queue()


func handle_bytes(peer_id: int, bytes: PackedByteArray) -> void:
	if bytes.size() > V3.MAX_ENVELOPE_BYTES:
		_send_direct(peer_id, V3.reject(V3.REJECT_PAYLOAD_TOO_LARGE))
		return
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary:
		_send_direct(peer_id, V3.reject(V3.REJECT_MALFORMED_ENVELOPE))
		return
	handle(peer_id, parsed)


func handle(peer_id: int, env: Dictionary) -> void:
	var valid := V3.validate_envelope(env, V3.CLIENT_MESSAGES)
	if not bool(valid.get("ok", false)):
		_send_direct(peer_id, V3.reject(StringName(valid.get("code", V3.REJECT_MALFORMED_ENVELOPE))))
		return
	match StringName(env.get("t", "")):
		V3.HELLO:
			var welcome := registry.welcome_for(env)
			_send_direct(peer_id, welcome)
			if StringName(welcome.get("t", "")) == V3.WELCOME:
				_welcomed[peer_id] = true
		V3.JOIN:
			if not bool(_welcomed.get(peer_id, false)):
				_send_direct(peer_id, V3.reject(V3.REJECT_UNAUTHORIZED, "join before welcome"))
				return
			seat(peer_id)
		V3.COMMAND:
			_handle_command(peer_id, env)


func _handle_command(peer_id: int, env: Dictionary) -> void:
	var where: Dictionary = loc.get(peer_id, {})
	if where.is_empty() or String(where.get("role", "")) != "player":
		_send_direct(peer_id, V3.reject(V3.REJECT_UNAUTHORIZED, "command before seat"))
		return
	if not sessions.consume_rate_token(peer_id):
		_send_direct(peer_id, V3.reject(V3.REJECT_RATE_LIMITED))
		return
	if not sessions.accept_sequence(peer_id, int(env.get("seq", 0))):
		_send_direct(peer_id, V3.reject(V3.REJECT_SEQUENCE_VIOLATION))
		return
	var arena: Dictionary = arenas[int(where.arena)]
	var slot: String = arena.slots.slot_for_peer(peer_id)
	if slot.is_empty():
		return
	var payload: Variant = env.get("payload")
	var validated: Dictionary = arena.adapter.validate_command(slot, payload)
	if not bool(validated.get("ok", false)):
		_send_direct(peer_id, V3.reject(StringName(validated.get("code", V3.REJECT_ADAPTER_REJECTED))))
		return
	arena.adapter.apply_command(slot, payload)


# --- Seating & rotation -----------------------------------------------------
func seat(peer_id: int) -> void:
	for i in arenas.size():
		if arenas[i].slots.has_free_slot():
			_seat_in(peer_id, i)
			return
	# Every arena is full → wait, spectating arena 0.
	queue.append(peer_id)
	arenas[0].slots.add_spectator(peer_id)
	loc[peer_id] = {"arena": 0, "role": "queue"}
	_send_seat_hint(peer_id, "", "queue", 0)
	_enqueue_checkpoint(peer_id, 0)
	delivery.flush_target(peer_id)
	_broadcast_queue()


func _seat_in(peer_id: int, arena_index: int) -> void:
	var arena: Dictionary = arenas[arena_index]
	var claim: Dictionary = arena.slots.claim(peer_id, sessions.token(peer_id))
	if not bool(claim.get("ok", false)):
		queue.append(peer_id)
		loc[peer_id] = {"arena": 0, "role": "queue"}
		return
	var slot := String(claim.slot)
	sessions.assign_seat(peer_id, arena_index + 1, "participant", slot)
	arena.ring.adopt_full(peer_id, arena.adapter.tick, arena.adapter.tick)
	loc[peer_id] = {"arena": arena_index, "role": "player"}
	_send_seat_hint(peer_id, slot, "player", arena_index)
	_enqueue_checkpoint(peer_id, arena_index)
	delivery.flush_target(peer_id)


## Baseball rotation for one arena at a round boundary: if anyone is waiting and no
## seat is free, the lowest-scoring seated human rotates to the back of the queue
## and the next waiter takes the seat.
func rotate_arena(arena_index: int) -> void:
	if queue.is_empty():
		return
	var arena: Dictionary = arenas[arena_index]
	if arena.slots.has_free_slot():
		_seat_waiters()
		return
	var humans: Array = arena.slots.connected_peer_ids()
	if humans.is_empty():
		return
	var loser := -1
	var low := 1 << 30
	for p: Variant in humans:
		var slot: String = arena.slots.slot_for_peer(int(p))
		if slot.is_empty():
			continue
		var kills := int(arena.adapter.players[slot].kills)
		if kills < low:
			low = kills
			loser = int(p)
	if loser < 0:
		return
	var loser_slot: String = arena.slots.slot_for_peer(loser)
	arena.slots.vacate(loser_slot)
	arena.ring.forget_peer(loser)
	sessions.clear_seat(loser)
	queue.append(loser)
	arenas[0].slots.add_spectator(loser)
	loc[loser] = {"arena": 0, "role": "queue"}
	_send_seat_hint(loser, "", "queue", 0)
	_seat_waiters()
	_broadcast_queue()


## Seat as many waiters as there are free slots (called after a disconnect or a
## rotation frees seats).
func _seat_waiters() -> void:
	var progressed := true
	while progressed and not queue.is_empty():
		progressed = false
		for i in arenas.size():
			if queue.is_empty():
				break
			if arenas[i].slots.has_free_slot():
				var peer_id: int = queue.pop_front()
				arenas[0].slots.spectators.erase(peer_id)
				_seat_in(peer_id, i)
				progressed = true


# --- Simulation + replication ----------------------------------------------
func tick(delta: float) -> void:
	for _t in scheduler.advance(delta):
		for i in arenas.size():
			var arena: Dictionary = arenas[i]
			arena.adapter.advance(1)
			var checkpoint: Dictionary = arena.adapter.build_checkpoint(Adapter.CODEC_ID)
			arena.ring.record(int(checkpoint.tick), checkpoint.payload)
			_replicate(i)
			if int(arena.adapter.round_index) > int(arena.last_round):
				arena.last_round = int(arena.adapter.round_index)
				rotate_arena(i)


func _replicate(arena_index: int) -> void:
	var arena: Dictionary = arenas[arena_index]
	var adapter: Adapter = arena.adapter
	# connected_peer_ids() already includes arena-0 spectators (the waiting queue).
	var audience: Array = arena.slots.connected_peer_ids()
	if audience.is_empty():
		return
	var events := adapter.drain_events(Adapter.CODEC_ID)
	for peer_id: Variant in audience:
		for event: Dictionary in events:
			delivery.enqueue_target(int(peer_id), V3.envelope(V3.EVENT, {
				"match_id": arena.match_id, "tick": adapter.tick,
				"reliability": String(event.reliability), "codec_id": Adapter.CODEC_ID,
				"payload": event.payload,
			}))
		if adapter.tick % STATE_INTERVAL == 0:
			var base_tick: int = arena.ring.resolve_baseline(int(peer_id), adapter.tick)
			var delta := adapter.build_delta(base_tick, Adapter.CODEC_ID)
			var state_env := V3.envelope(V3.STATE, {
				"match_id": arena.match_id, "tick": adapter.tick, "base_tick": base_tick,
				"seq": arena.ring.next_sequence(), "codec_id": Adapter.CODEC_ID,
				"payload": delta.get("payload", {}),
			})
			state_env["reliability"] = String(V3.REPLACEABLE)
			delivery.enqueue_target(int(peer_id), state_env)
	delivery.flush_targets()


# --- Outbound helpers -------------------------------------------------------
func _send_direct(peer_id: int, envelope: Dictionary) -> void:
	_send.call(peer_id, JSON.stringify(envelope).to_utf8_buffer())


func _enqueue_checkpoint(peer_id: int, arena_index: int) -> void:
	var arena: Dictionary = arenas[arena_index]
	var checkpoint: Dictionary = arena.adapter.build_checkpoint(Adapter.CODEC_ID)
	delivery.enqueue_target(peer_id, V3.envelope(V3.CHECKPOINT, {
		"match_id": arena.match_id, "tick": int(checkpoint.tick),
		"codec_id": Adapter.CODEC_ID, "payload": checkpoint.payload,
		"state_hash": String(checkpoint.state_hash),
	}))


func _send_seat_hint(peer_id: int, slot: String, role: String, arena_index: int) -> void:
	var arena: Dictionary = arenas[arena_index]
	var color := ""
	if slot in arena.adapter.players:
		color = String(arena.adapter.players[slot].get("color", ""))
	delivery.enqueue_target(peer_id, V3.envelope(V3.EVENT, {
		"match_id": arena.match_id, "tick": arena.adapter.tick, "reliability": String(V3.RELIABLE),
		"codec_id": Adapter.CODEC_ID,
		"payload": {"kind": "seat", "slot": slot, "role": role, "color": color, "arena": arena.id},
	}))
	delivery.flush_target(peer_id)


func _broadcast_queue() -> void:
	for i in queue.size():
		var peer_id: int = queue[i]
		delivery.enqueue_target(peer_id, V3.envelope(V3.EVENT, {
			"match_id": arenas[0].match_id, "tick": arenas[0].adapter.tick,
			"reliability": String(V3.RELIABLE), "codec_id": Adapter.CODEC_ID,
			"payload": {"kind": "queue", "pos": i + 1, "total": queue.size()},
		}))
		delivery.flush_target(peer_id)


# --- Introspection (for host/tests) -----------------------------------------
func seated_count() -> int:
	var n := 0
	for peer_id: Variant in loc:
		if String(loc[peer_id].get("role", "")) == "player":
			n += 1
	return n


func arena_of(peer_id: int) -> int:
	return int(loc.get(peer_id, {}).get("arena", -1)) if loc.has(peer_id) else -1


func role_of(peer_id: int) -> String:
	return String(loc.get(peer_id, {}).get("role", "")) if loc.has(peer_id) else ""
