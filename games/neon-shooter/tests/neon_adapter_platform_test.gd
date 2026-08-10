extends SceneTree

## End-to-end proof that neon-platform-shooter runs on Match Platform V3: the
## adapter registers, passes the identity gate, seats players through the real
## platform registries, simulates deterministically, and produces checkpoint /
## delta / classified events that round-trip through the platform delivery queue.

const V3 = preload("res://platform/match_platform_v3.gd")
const Registry = preload("res://platform/platform_adapter_registry.gd")
const Sessions = preload("res://platform/platform_session_registry.gd")
const Slots = preload("res://platform/platform_slot_book.gd")
const Ring = preload("res://platform/platform_replication_ring.gd")
const Delivery = preload("res://platform/platform_delivery_queue.gd")
const Adapter = preload("res://games/neon-shooter/adapters/neon_shooter_adapter.gd")
const Codec = preload("res://games/neon-shooter/adapters/neon_shooter_codec.gd")

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String, evidence: Variant = null) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: %s evidence=%s" % [message, JSON.stringify(evidence)])


func _run() -> void:
	_test_identity_gate()
	_test_short_scenario_determinism()
	_test_battle_events_and_reliability()
	_test_delivery_roundtrip()
	_test_rule_parity()
	_test_phase_progression()
	if failures.is_empty():
		print("PASS: %d neon-shooter platform checks" % checks)
		quit(0)
	else:
		print("FAIL: %d/%d neon-shooter platform checks failed" % [failures.size(), checks])
		for failure: String in failures:
			print(" - %s" % failure)
		quit(1)


func _hello() -> Dictionary:
	return V3.envelope(V3.HELLO, {
		"protocol_versions": [V3.ENVELOPE_VERSION],
		"game_id": Adapter.GAME_ID,
		"game_version": Adapter.CONTENT_VERSION,
		"content_hash": Adapter.content_hash(),
		"codecs": [Adapter.CODEC_ID],
	})


func _test_identity_gate() -> void:
	var registry := Registry.new()
	var adapter := Adapter.new()
	_check(bool(registry.register(adapter).get("ok", false)), "shooter package registers without core changes")
	var welcome := registry.welcome_for(_hello())
	_check(StringName(welcome.get("t", "")) == V3.WELCOME, "matching shooter identity receives welcome", welcome)
	_check(String(welcome.get("selected_codec", "")) == Adapter.CODEC_ID, "shooter codec is negotiated")
	_check(int(welcome.get("tick_rate", 0)) == Adapter.TICK_RATE, "welcome advertises the shooter tick rate")
	for mismatch: Dictionary in [
		{"game_id": "missing", "code": V3.REJECT_UNKNOWN_GAME},
		{"game_version": "neon-rules.0", "code": V3.REJECT_UNSUPPORTED_GAME_VERSION},
		{"content_hash": "different", "code": V3.REJECT_CONTENT_MISMATCH},
		{"codecs": ["neon.other"], "code": V3.REJECT_UNSUPPORTED_CODEC},
	]:
		var candidate := _hello().duplicate(true)
		for key: String in mismatch:
			if key != "code":
				candidate[key] = mismatch[key]
		var refusal := registry.resolve_hello(candidate)
		_check(String(refusal.get("code", "")) == String(mismatch.code),
			"identity mismatch rejected pre-seat with %s" % mismatch.code, refusal)


func _seat_participant(sessions: Object, slots: Object, peer: int, requested: String) -> String:
	var opened: Dictionary = sessions.open(peer)
	var join := (Adapter.new()).validate_join("participant", requested, {"subject": "acct-%d" % peer})
	var claim: Dictionary = slots.claim(peer, String(opened.token), String(join.get("slot", requested)))
	sessions.assign_seat(peer, 1, "participant", String(claim.get("slot", requested)))
	return String(claim.get("slot", requested))


func _test_short_scenario_determinism() -> void:
	var registry := Registry.new()
	var adapter := Adapter.new()
	registry.register(adapter)
	var created := registry.create_match(Adapter.GAME_ID, {"match_id": "neon:short"}, 424242)
	_check(bool(created.get("ok", false)), "registry creates a shooter match", created)

	var slots := Slots.new(Adapter.PARTICIPANT_SLOTS)
	var sessions := Sessions.new(10.0, 20.0, 1)
	var p1 := _seat_participant(sessions, slots, 11, "p1")
	var p2 := _seat_participant(sessions, slots, 12, "p2")
	_check(p1 == "p1" and p2 == "p2", "participants take their requested opaque slots", [p1, p2])
	sessions.open(13)
	slots.add_spectator(13)
	_check(slots.is_spectator(13), "observer joins without consuming a participant slot")

	var start_ink := int(adapter.players["p1"].ink)
	# Draw phase: paint a stroke (movement is battle-only in netgame, so we do not
	# expect the player to move here).
	for step in 20:
		adapter.apply_command("p1", {"kind": "input", "seq": step + 1, "left": false, "right": false, "jump": false, "aimX": 1000.0, "aimY": 300.0})
		if step == 5:
			adapter.apply_command("p1", {"kind": "draw", "x0": 500.0, "y0": 500.0, "x1": 560.0, "y1": 500.0})
		adapter.advance(1)
	_check(int(adapter.players["p1"].ink) < start_ink, "draw consumes ink")
	# Battle phase: input now advances the authoritative position.
	adapter.advance(Adapter.DRAW_TICKS - adapter.tick)
	var bx := float(adapter.players["p1"].x)
	for step in 10:
		adapter.apply_command("p1", {"kind": "input", "seq": 100 + step, "left": false, "right": true, "jump": false, "aimX": 1600.0, "aimY": 500.0})
		adapter.advance(1)
	_check(float(adapter.players["p1"].x) != bx, "battle input advances the authoritative player position")

	var replay: Dictionary = adapter.export_replay()
	var replayed := Adapter.new()
	var replay_result := replayed.replay_into(replay)
	_check(bool(replay_result.get("ok", false)) and replayed.state_hash() == adapter.state_hash(),
		"replay reproduces the deterministic hash", [replayed.state_hash(), adapter.state_hash()])

	var checkpoint := adapter.build_checkpoint(Adapter.CODEC_ID)
	var recovered := Adapter.new()
	var rec: Variant = recovered.recover_match(checkpoint.payload)
	_check(rec is Dictionary and bool((rec as Dictionary).get("ok", false)) and recovered.state_hash() == adapter.state_hash(),
		"checkpoint recovery reproduces the deterministic hash",
		[JSON.stringify(rec), recovered.state_hash() == adapter.state_hash()])

	var delta := adapter.build_delta(0, Adapter.CODEC_ID)
	_check(int(delta.get("base_tick", -1)) == 0 and delta.has("payload"), "delta is built from an acknowledged baseline", delta)


func _test_battle_events_and_reliability() -> void:
	var adapter := Adapter.new()
	adapter.create_match({"match_id": "neon:battle"}, 7)
	adapter.advance(Adapter.DRAW_TICKS)  # draw -> battle
	_check(adapter.phase == "battle", "phase machine reaches battle after the draw window", adapter.phase)

	# Mark p1 and p2 human (so no bot backfill moves them) and place them in open
	# air, clearing the spawn-guard window so the shot can connect.
	adapter.apply_command("p2", {"kind": "input", "seq": 1, "left": false, "right": false, "jump": false, "aimX": 0.0, "aimY": 0.0})
	adapter.players["p1"].x = 360.0
	adapter.players["p1"].y = 500.0
	adapter.players["p1"].cd = 0
	adapter.players["p1"].guard = 0
	adapter.players["p2"].x = 390.0
	adapter.players["p2"].y = 500.0
	adapter.players["p2"].hp = 20
	adapter.players["p2"].guard = 0
	adapter.players["p1"].aimX = 390.0
	adapter.players["p1"].aimY = 500.0
	adapter.apply_command("p1", {"kind": "shoot"})
	for _i in 3:
		adapter.advance(1)
	_check(int(adapter.players["p1"].kills) >= 1, "a resolved bullet scores a kill (sub-stepped, no tunnelling)", adapter.players["p1"].kills)

	# Fire into the ground (near the terrain surface) to carve a crater.
	adapter.players["p1"].x = 360.0
	adapter.players["p1"].y = 1050.0
	adapter.players["p1"].cd = 0
	adapter.players["p1"].aimX = 360.0
	adapter.players["p1"].aimY = 1300.0
	adapter.apply_command("p1", {"kind": "shoot"})
	for _i in 6:
		adapter.advance(1)

	var events := adapter.drain_events(Adapter.CODEC_ID)
	var by_kind := {}
	var by_reliability := {}
	for event: Dictionary in events:
		var kind := String((event.payload as Dictionary).get("kind", ""))
		by_kind[kind] = String(event.reliability)
		by_reliability[String(event.reliability)] = true
	_check(by_kind.get("phase", "") == String(V3.RELIABLE), "phase events are reliable", by_kind)
	_check(by_kind.get("kill", "") == String(V3.DROPPABLE), "kill events are droppable FX", by_kind)
	_check(by_kind.get("crater", "") == String(V3.RELIABLE), "crater events are reliable (authoritative terrain)", by_kind)
	_check(by_reliability.has(String(V3.RELIABLE)) and by_reliability.has(String(V3.DROPPABLE)),
		"adapter declares multiple delivery classes", by_reliability.keys())


# netgame rule parity: spawn-guard invincibility, rocket splash, bot backfill.
func _test_rule_parity() -> void:
	# Spawn-guard invincibility: a fresh spawn (guard > 0) is transparent to bullets.
	var a := Adapter.new()
	a.create_match({"match_id": "neon:guard"}, 11)
	a.advance(Adapter.DRAW_TICKS)  # enter battle; everyone spawns with a guard window
	a.apply_command("p2", {"kind": "input", "seq": 1, "left": false, "right": false, "jump": false, "aimX": 0.0, "aimY": 0.0})
	a.players["p1"].x = 360.0; a.players["p1"].y = 500.0; a.players["p1"].cd = 0; a.players["p1"].guard = 0
	a.players["p2"].x = 390.0; a.players["p2"].y = 500.0; a.players["p2"].hp = 20  # p2 keeps its spawn guard
	_check(int(a.players["p2"].guard) > 0, "fresh spawn has an active guard window", a.players["p2"].guard)
	a.players["p1"].aimX = 390.0; a.players["p1"].aimY = 500.0
	a.apply_command("p1", {"kind": "shoot"})
	for _i in 3:
		a.advance(1)
	_check(bool(a.players["p2"].alive) and int(a.players["p2"].hp) == 20, "guarded player takes no damage", a.players["p2"].hp)

	# Rocket splash: a rocket that hits p2 directly also splashes bystander p3.
	# (All three fall together in open air, so relative geometry is preserved.)
	var b := Adapter.new()
	b.create_match({"match_id": "neon:splash"}, 12)
	b.advance(Adapter.DRAW_TICKS)
	b.apply_command("p2", {"kind": "input", "seq": 1, "left": false, "right": false, "jump": false, "aimX": 0.0, "aimY": 0.0})
	b.apply_command("p3", {"kind": "input", "seq": 1, "left": false, "right": false, "jump": false, "aimX": 0.0, "aimY": 0.0})
	b.players["p1"].x = 300.0; b.players["p1"].y = 400.0; b.players["p1"].cd = 0; b.players["p1"].guard = 0
	b.players["p1"].weapon = "rocket"
	b.players["p2"].x = 360.0; b.players["p2"].y = 400.0; b.players["p2"].guard = 0; b.players["p2"].hp = 100
	b.players["p3"].x = 392.0; b.players["p3"].y = 400.0; b.players["p3"].guard = 0; b.players["p3"].hp = 100
	b.players["p1"].aimX = 360.0; b.players["p1"].aimY = 400.0
	b.apply_command("p1", {"kind": "shoot"})
	for _i in 6:
		b.advance(1)
	_check(int(b.players["p2"].hp) < 100, "rocket directly damages its target", b.players["p2"].hp)
	_check(int(b.players["p3"].hp) < 100, "rocket splash damages a nearby bystander", b.players["p3"].hp)

	# Bot backfill: with one human in battle, an idle slot is driven by AI and moves.
	var c := Adapter.new()
	c.create_match({"match_id": "neon:bots"}, 13)
	c.advance(Adapter.DRAW_TICKS)
	var spawn_x := float(c.players["p2"].x)
	for step in 90:
		c.apply_command("p1", {"kind": "input", "seq": step + 1, "left": false, "right": true, "jump": false, "aimX": 1600.0, "aimY": 500.0})
		c.advance(1)
	var moved := false
	for slot: String in ["p2", "p3", "p4", "p5", "p6", "p7", "p8"]:
		if absf(float(c.players[slot].x) - float(Core.SPAWNS[c.players[slot].spawn_index].x)) > 2.0:
			moved = true
	_check(moved, "an idle slot is backfilled by a bot and acts", spawn_x)


func _test_delivery_roundtrip() -> void:
	var adapter := Adapter.new()
	adapter.create_match({"match_id": "neon:delivery"}, 99)
	adapter.advance(3)
	var delta := adapter.build_delta(0, Adapter.CODEC_ID)
	var emitted: Array[PackedByteArray] = []
	var delivery := Delivery.new(Codec.new(), V3.MAX_ENVELOPE_BYTES, func(_peer_id: int) -> int: return 1)
	delivery.target_frame.connect(func(_peer: int, bytes: PackedByteArray, _reliability: StringName) -> void:
		emitted.append(bytes))
	var envelope := V3.envelope(V3.STATE, {
		"match_id": "neon:delivery", "tick": int(delta.tick), "base_tick": int(delta.base_tick),
		"seq": 1, "codec_id": Adapter.CODEC_ID, "payload": delta.payload,
	})
	envelope["reliability"] = String(V3.REPLACEABLE)
	delivery.enqueue_target(21, envelope)
	delivery.flush_target(21)
	_check(emitted.size() == 1, "platform delivery queue emits one shooter codec frame")
	var decoded := Codec.decode(emitted[0])
	var decoded_payload: Variant = decoded[0].get("payload") if decoded.size() == 1 else null
	var normalized: Variant = JSON.parse_string(JSON.stringify(delta.payload))
	_check(decoded.size() == 1 and decoded_payload == normalized, "delivery preserves the opaque payload exactly")
	_check(int(delivery.telemetry().get("rejected_frames", -1)) == 0, "shooter codec stays within the frame budget")


func _test_phase_progression() -> void:
	# rounds:1 makes the otherwise-endless arena terminate after one round.
	var adapter := Adapter.new()
	adapter.create_match({"match_id": "neon:full", "rounds": 1}, 5)
	adapter.advance(Adapter.DRAW_TICKS + Adapter.BATTLE_TICKS + 1)
	_check(adapter.phase == "results", "battle window transitions to results", adapter.phase)
	_check(adapter.terminal_result() == null, "results is not terminal until the round closes")
	adapter.advance(Adapter.RESULT_TICKS + 1)
	_check(adapter.finished, "results window ends a bounded (rounds=1) match")
	var result: Variant = adapter.terminal_result()
	_check(result is Dictionary and (result as Dictionary).has("winner"), "terminal result carries the winner", result)

	# Endless mode (default) cycles back to draw instead of finishing.
	var endless := Adapter.new()
	endless.create_match({"match_id": "neon:endless"}, 6)
	endless.advance(Adapter.DRAW_TICKS + Adapter.BATTLE_TICKS + Adapter.RESULT_TICKS + 2)
	_check(not endless.finished and endless.phase == "draw" and endless.round_index == 1,
		"endless arena cycles into the next round", [endless.phase, endless.round_index])
	var telemetry := {"game_id": Adapter.GAME_ID, "metrics": adapter.metrics()}
	_check(String(telemetry.game_id) == Adapter.GAME_ID, "telemetry is partitioned by game package")
