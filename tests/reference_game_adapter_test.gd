extends SceneTree

## Complete second-package lifecycle proof for issue #77.

const V3 = preload("res://platform/match_platform_v3.gd")
const Registry = preload("res://platform/platform_adapter_registry.gd")
const Sessions = preload("res://platform/platform_session_registry.gd")
const Slots = preload("res://platform/platform_slot_book.gd")
const Ring = preload("res://platform/platform_replication_ring.gd")
const Delivery = preload("res://platform/platform_delivery_queue.gd")
const Adapter = preload("res://adapters/reference/counter_game_adapter.gd")
const Codec = preload("res://adapters/reference/counter_json_codec.gd")

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
	_test_package_boundary()
	_test_identity_gate()
	_test_complete_lifecycle()
	if failures.is_empty():
		print("PASS: %d reference-game platform checks" % checks)
		quit(0)
	else:
		print("FAIL: %d/%d reference-game platform checks failed" % [
			failures.size(), checks])
		for failure: String in failures:
			print(" - %s" % failure)
		quit(1)


func _test_package_boundary() -> void:
	var source := ""
	for path: String in [
		"res://adapters/reference/counter_game_adapter.gd",
		"res://adapters/reference/counter_json_codec.gd",
	]:
		source += FileAccess.get_file_as_string(path).to_lower()
	for forbidden: String in [
		"blue", "red", "hero", "unit", "stronghold", "recruit", "cast_skill", "hersir",
	]:
		var pattern := RegEx.new()
		pattern.compile("\\b%s\\b" % forbidden)
		_check(pattern.search(source) == null,
			"reference package excludes domain token '%s'" % forbidden)
	_check(not source.contains("res://scripts/"), "reference package has no product-script dependency")
	_check(not source.contains("res://server/"), "reference package has no product-server dependency")
	_check(not source.contains("res://network/"), "reference package has no product-network dependency")


func _test_identity_gate() -> void:
	var registry := Registry.new()
	var adapter := Adapter.new()
	_check(bool(registry.register(adapter).get("ok", false)),
		"trusted reference package registers without core changes")
	var hello := V3.envelope(V3.HELLO, {
		"protocol_versions": [V3.ENVELOPE_VERSION],
		"game_id": Adapter.GAME_ID,
		"game_version": Adapter.CONTENT_VERSION,
		"content_hash": Adapter.content_hash(),
		"codecs": [Adapter.CODEC_ID],
	})
	var welcome := registry.welcome_for(hello)
	_check(StringName(welcome.get("t", "")) == V3.WELCOME,
		"matching reference identity receives welcome", welcome)
	_check(String(welcome.get("selected_codec", "")) == Adapter.CODEC_ID,
		"reference codec is negotiated")
	for mismatch: Dictionary in [
		{"game_id": "missing-package", "code": V3.REJECT_UNKNOWN_GAME},
		{"game_version": "counter-rules.0", "code": V3.REJECT_UNSUPPORTED_GAME_VERSION},
		{"content_hash": "different", "code": V3.REJECT_CONTENT_MISMATCH},
		{"codecs": ["counter.other"], "code": V3.REJECT_UNSUPPORTED_CODEC},
	]:
		var candidate := hello.duplicate(true)
		for key: String in mismatch:
			if key != "code":
				candidate[key] = mismatch[key]
		var refusal := registry.resolve_hello(candidate)
		_check(String(refusal.get("code", "")) == String(mismatch.code),
			"identity mismatch is rejected pre-seat with %s" % mismatch.code, refusal)
	_check(not bool(registry.recover_match(
		Adapter.GAME_ID, {"game_id": "another-package", "state": {}}).get("ok", false)),
		"checkpoint from another package is rejected")


func _test_complete_lifecycle() -> void:
	var registry := Registry.new()
	var adapter := Adapter.new()
	registry.register(adapter)
	var created := registry.create_match(Adapter.GAME_ID, {
		"match_id": "counter:77",
		"limit": 20,
	}, 770077)
	_check(bool(created.get("ok", false)), "registry creates reference match", created)
	_check(String(created.get("match_id", "")) == "counter:77",
		"reference match identity is preserved")

	var participant_slots: Array[String] = []
	for descriptor: Dictionary in adapter.slot_descriptors():
		if String(descriptor.get("kind", "")) == "participant":
			participant_slots.append(String(descriptor.get("slot_id", "")))
	var slots := Slots.new(participant_slots)
	var sessions := Sessions.new(10.0, 20.0, 1)
	var ring := Ring.new(2, 2)

	var first := sessions.open(101)
	var first_join := adapter.validate_join("participant", "slot_2", {"subject": "account-a"})
	_check(bool(first_join.get("ok", false)), "adapter accepts participant join")
	var first_claim := slots.claim(101, String(first.token), String(first_join.slot))
	_check(String(first_claim.get("slot", "")) == "slot_2",
		"opaque requested slot is assigned", first_claim)
	sessions.assign_seat(101, 77, "participant", String(first_claim.slot))

	var second := sessions.open(102)
	var second_claim := slots.claim(102, String(second.token))
	sessions.assign_seat(102, 77, "participant", String(second_claim.slot))
	_check(String(second_claim.get("slot", "")) == "slot_1",
		"declaration order assigns the next participant")

	sessions.open(103)
	var observer_join := adapter.validate_join("observer", null, {"subject": "account-c"})
	slots.add_spectator(103)
	sessions.assign_seat(103, 77, "observer", String(observer_join.slot))
	_check(slots.is_spectator(103) and sessions.slot(103) == Adapter.OBSERVER_SLOT,
		"observer joins without consuming a participant slot")

	var opening := adapter.build_checkpoint(Adapter.CODEC_ID)
	ring.record(int(opening.tick), opening.payload)
	ring.adopt_full(101, int(opening.tick), int(opening.tick))
	ring.adopt_full(102, int(opening.tick), int(opening.tick))

	_check(sessions.consume_rate_token(101), "command pays the platform admission budget")
	_check(sessions.accept_sequence(101, 1), "first command sequence is accepted")
	_check(not sessions.accept_sequence(101, 1), "duplicate command sequence is rejected")
	for fixture: Dictionary in [
		{"slot": "slot_2", "payload": {"action": "ready"}},
		{"slot": "slot_2", "payload": {"action": "increment", "amount": 3}},
		{"slot": "slot_1", "payload": {"action": "increment", "amount": 2}},
	]:
		var validation := adapter.validate_command(fixture.slot, fixture.payload)
		_check(bool(validation.get("ok", false)),
			"opaque reference command validates", fixture)
		adapter.apply_command(fixture.slot, fixture.payload)
	adapter.advance(1)
	_check(int(adapter.build_checkpoint(Adapter.CODEC_ID).payload.state.values.slot_2) == 3,
		"fixed tick applies the reference rules")
	_check(adapter.drain_events(Adapter.CODEC_ID).size() == 3,
		"adapter drains its own reliable events")

	var current := adapter.build_checkpoint(Adapter.CODEC_ID)
	ring.record(int(current.tick), current.payload)
	var increment := adapter.build_delta(int(opening.tick), Adapter.CODEC_ID)
	_check(int(increment.get("base_tick", -1)) == int(opening.tick),
		"increment is built from acknowledged checkpoint")
	_check(
		(increment.get("payload", {}) as Dictionary).get("replace", {})
			== (current.payload as Dictionary).get("state", {}),
		"opaque increment reconstructs the current reference state")

	var emitted: Array[PackedByteArray] = []
	var delivery := Delivery.new(Codec.new(), V3.MAX_ENVELOPE_BYTES, func(_peer_id: int) -> int: return 1)
	delivery.target_frame.connect(
		func(_peer_id: int, bytes: PackedByteArray, _reliability: StringName) -> void:
			emitted.append(bytes))
	var state_envelope := V3.envelope(V3.STATE, {
		"match_id": "counter:77",
		"tick": int(current.tick),
		"base_tick": int(opening.tick),
		"seq": ring.next_sequence(),
		"codec_id": Adapter.CODEC_ID,
		"payload": increment.payload,
	})
	state_envelope["reliability"] = String(V3.REPLACEABLE)
	delivery.enqueue_target(101, state_envelope)
	delivery.flush_target(101)
	_check(emitted.size() == 1, "generic delivery queue emits the reference codec frame")
	var decoded := Codec.decode(emitted[0])
	var decoded_payload: Variant = decoded[0].get("payload") if decoded.size() == 1 else null
	var normalized_payload: Variant = JSON.parse_string(JSON.stringify(increment.payload))
	_check(
		decoded.size() == 1
			and decoded_payload == normalized_payload,
		"delivery preserves the opaque payload exactly",
		[decoded_payload, increment.payload])

	var reconnect_token := sessions.token(101)
	var released := slots.release(101, int(current.tick))
	sessions.close(101)
	_check(String(released.get("slot", "")) == "slot_2",
		"disconnect reserves the opaque slot")
	sessions.open(201)
	var resumed := slots.resume(reconnect_token, 201)
	sessions.adopt_token(201, reconnect_token)
	sessions.assign_seat(201, 77, "participant", String(resumed.get("slot", "")))
	_check(bool(resumed.get("ok", false)) and sessions.slot(201) == "slot_2",
		"resume token restores the same reference slot", resumed)

	for _index in 4:
		adapter.advance(1)
		var checkpoint := adapter.build_checkpoint(Adapter.CODEC_ID)
		ring.record(int(checkpoint.tick), checkpoint.payload)
	var latest := adapter.build_checkpoint(Adapter.CODEC_ID)
	var repair_group: Variant = ring.resolve_group(
		201, int(latest.tick), int(latest.tick), false)
	_check(repair_group == Ring.GROUP_FULL_REPAIR,
		"expired baseline requests a full reference checkpoint", repair_group)
	_check(ring.request_repair(201, int(latest.tick)),
		"resync is admitted after the platform cooldown")
	ring.advance_group(repair_group, [201], int(latest.tick), int(latest.tick))
	_check(ring.resolve_baseline(201, int(latest.tick) + 1) == int(latest.tick),
		"resync checkpoint becomes the resumed peer baseline")

	adapter.apply_command("slot_2", {"action": "finish"})
	adapter.advance(1)
	var result: Variant = adapter.terminal_result()
	_check(result is Dictionary and String(result.get("completed_by", "")) == "slot_2",
		"reference terminal result uses its own schema", result)
	var replay: Dictionary = adapter.export_replay()
	var replayed := Adapter.new()
	var replay_result := replayed.replay_into(replay)
	_check(bool(replay_result.get("ok", false))
		and replayed.state_hash() == adapter.state_hash(),
		"reference replay reproduces the deterministic final hash")
	var final_checkpoint := adapter.build_checkpoint(Adapter.CODEC_ID)
	var recovered := Adapter.new()
	_check(bool(recovered.recover_match(final_checkpoint.payload).get("ok", false))
		and recovered.state_hash() == adapter.state_hash(),
		"reference checkpoint recovery reproduces the deterministic hash")

	var telemetry := {
		"game_id": Adapter.GAME_ID,
		"adapter_version": Adapter.ADAPTER_VERSION,
		"match_id": adapter.match_id,
		"metrics": adapter.metrics(),
	}
	var telemetry_text := JSON.stringify(telemetry)
	_check(String(telemetry.game_id) == Adapter.GAME_ID,
		"telemetry is partitioned by game package")
	for private_field: String in ["values", "prepared", "completion"]:
		_check(not telemetry_text.contains(private_field),
			"telemetry does not leak payload field '%s'" % private_field)
	_check(delivery.telemetry().get("rejected_frames", -1) == 0,
		"reference codec stays within the platform frame budget")
