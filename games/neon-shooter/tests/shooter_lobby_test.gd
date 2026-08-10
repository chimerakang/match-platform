extends SceneTree

## Multi-arena lobby + baseball rotation, driven with a fake transport (no
## sockets) so the seating/queue/rotation logic is verified deterministically.

const ShooterLobby = preload("res://games/neon-shooter/server/shooter_lobby.gd")
const Adapter = preload("res://games/neon-shooter/adapters/neon_shooter_adapter.gd")
const V3 = preload("res://platform/match_platform_v3.gd")

var checks := 0
var failures: Array[String] = []
var _sent: Dictionary = {}   # peer_id -> Array of decoded envelopes


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String, evidence: Variant = null) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: %s evidence=%s" % [message, JSON.stringify(evidence)])


func _run() -> void:
	_test_seating_queue_and_rotation()
	_test_disconnect_reseats_queue()
	if failures.is_empty():
		print("PASS: %d neon-shooter lobby checks" % checks)
		quit(0)
	else:
		print("FAIL: %d/%d neon-shooter lobby checks failed" % [failures.size(), checks])
		for failure: String in failures:
			print(" - %s" % failure)
		quit(1)


func _send(peer_id: int, bytes: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	var box: Array = _sent.get_or_add(peer_id, [])
	if parsed is Array:
		for env: Variant in parsed:
			if env is Dictionary:
				box.append(env)
	elif parsed is Dictionary:
		box.append(parsed)


func _join(lobby: ShooterLobby, peer_id: int) -> void:
	lobby.open_peer(peer_id)
	lobby.handle(peer_id, V3.envelope(V3.HELLO, {
		"protocol_versions": [V3.ENVELOPE_VERSION], "game_id": Adapter.GAME_ID,
		"game_version": Adapter.CONTENT_VERSION, "content_hash": Adapter.content_hash(),
		"codecs": [Adapter.CODEC_ID],
	}))
	lobby.handle(peer_id, V3.envelope(V3.JOIN, {
		"match_selector": {"mode": "quick"}, "role": "participant", "auth_context": {},
	}))


func _welcomed(peer_id: int) -> bool:
	for env: Dictionary in _sent.get(peer_id, []):
		if StringName(env.get("t", "")) == V3.WELCOME:
			return true
	return false


func _test_seating_queue_and_rotation() -> void:
	# 2 arenas × 8 slots = 16 seats.
	var lobby := ShooterLobby.new(2, 1000, _send)
	for peer_id in range(1, 17):
		_join(lobby, peer_id)
	_check(_welcomed(1), "hello passes the identity gate with a welcome")
	_check(lobby.seated_count() == 16, "16 humans fill both arenas", lobby.seated_count())
	var players := 0
	for peer_id in range(1, 17):
		if lobby.role_of(peer_id) == "player":
			players += 1
	_check(players == 16, "every seated peer holds a participant slot", players)

	# 17th connection has nowhere to sit → queued.
	_join(lobby, 17)
	_check(lobby.role_of(17) == "queue" and lobby.queue.size() == 1, "a full lobby queues the next arrival", lobby.role_of(17))

	# Round boundary on arena 0 → lowest-scoring human rotates out, waiter seated.
	var seated_before: Array = lobby.arenas[0].slots.connected_peer_ids().duplicate()
	lobby.rotate_arena(0)
	_check(lobby.role_of(17) == "player", "the waiter is seated by rotation", lobby.role_of(17))
	_check(lobby.queue.size() == 1, "exactly one peer is now waiting after rotation", lobby.queue.size())
	_check(lobby.seated_count() == 16, "rotation preserves the seat count", lobby.seated_count())
	var rotated_out: int = lobby.queue[0]
	_check(rotated_out in seated_before and lobby.role_of(rotated_out) == "queue",
		"a previously-seated human rotated to the queue", rotated_out)


func _test_disconnect_reseats_queue() -> void:
	var lobby := ShooterLobby.new(1, 2000, _send)   # single arena, 8 seats
	for peer_id in range(1, 10):                     # 9 join → 8 seated, 1 queued
		_join(lobby, peer_id)
	_check(lobby.seated_count() == 8 and lobby.queue.size() == 1, "one arena seats 8 and queues the 9th", [lobby.seated_count(), lobby.queue.size()])
	var waiter: int = lobby.queue[0]
	# A seated peer drops → its slot frees → the waiter is seated immediately.
	var victim := -1
	for peer_id in range(1, 10):
		if lobby.role_of(peer_id) == "player":
			victim = peer_id
			break
	lobby.close_peer(victim)
	_check(lobby.role_of(waiter) == "player", "a disconnect frees a slot and the waiter takes it", lobby.role_of(waiter))
	_check(lobby.seated_count() == 8 and lobby.queue.is_empty(), "lobby stays full with an empty queue", [lobby.seated_count(), lobby.queue.size()])
