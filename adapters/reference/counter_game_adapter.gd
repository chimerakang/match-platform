class_name CounterGameAdapter
extends "../../platform/match_game_adapter.gd"

## Minimal deterministic package used to prove that Match Platform Core can run a
## second ruleset while treating every payload as opaque.

const GAME_ID := "counter-reference"
const ADAPTER_VERSION := "1.0.0"
const CONTENT_VERSION := "counter-rules.1"
const CODEC_ID := "counter.json.v1"
const TICK_RATE := 20
const PARTICIPANT_SLOTS: Array[String] = ["slot_1", "slot_2", "slot_3"]
const OBSERVER_SLOT := "observer"

var match_id := ""
var seed := 0
var tick := 0
var limit := 8
var finished := false
var completion: Variant = null
var values: Dictionary = {}
var prepared: Dictionary = {}

var _pending: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _event_cursor := 0
var _history: Dictionary = {}
var _log: Array[Dictionary] = []
var _accepted := 0
var _refused := 0
var _checkpoints := 0
var _increments := 0


func package_descriptor() -> Dictionary:
	return {
		"game_id": GAME_ID,
		"adapter_version": ADAPTER_VERSION,
		"content_versions": [CONTENT_VERSION],
		"content_hashes": [content_hash()],
		"codec_ids": [CODEC_ID],
		"tick_rate": TICK_RATE,
		"slot_policy": {"participants": PARTICIPANT_SLOTS.size(), "observers": true},
	}


func slot_descriptors() -> Array:
	var result: Array = []
	for slot: String in PARTICIPANT_SLOTS:
		result.append({"slot_id": slot, "kind": "participant", "fillable": true})
	result.append({"slot_id": OBSERVER_SLOT, "kind": "observer", "fillable": false})
	return result


func validate_match_config(candidate: Dictionary) -> Dictionary:
	var requested_limit := int(candidate.get("limit", 8))
	if requested_limit < 2 or requested_limit > 100:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "limit must be between 2 and 100")
	return {"ok": true}


func create_match(candidate: Dictionary, match_seed: int) -> Dictionary:
	var checked := validate_match_config(candidate)
	if not bool(checked.get("ok", false)):
		return checked
	match_id = String(candidate.get("match_id", "counter:%d" % match_seed))
	seed = match_seed
	tick = 0
	limit = int(candidate.get("limit", 8))
	finished = false
	completion = null
	values = {}
	prepared = {}
	for slot: String in PARTICIPANT_SLOTS:
		values[slot] = 0
		prepared[slot] = false
	_pending.clear()
	_events.clear()
	_event_cursor = 0
	_history.clear()
	_log.clear()
	_store_checkpoint()
	return {"ok": true, "match_id": match_id, "match": self}


func recover_match(checkpoint_payload: Variant) -> Dictionary:
	if not checkpoint_payload is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint must be a Dictionary")
	var payload: Dictionary = checkpoint_payload
	if String(payload.get("game_id", "")) != GAME_ID:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint belongs to another package")
	var restored: Variant = payload.get("state", payload)
	if not restored is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint state must be a Dictionary")
	var state: Dictionary = restored
	if not state.get("values") is Dictionary or not state.get("prepared") is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint state shape is invalid")
	match_id = String(payload.get("match_id", "counter:recovered"))
	seed = int(state.get("seed", 0))
	tick = int(state.get("step", 0))
	limit = int(state.get("limit", 8))
	finished = bool(state.get("closed", false))
	completion = state.get("completion")
	values = (state.get("values", {}) as Dictionary).duplicate(true)
	prepared = (state.get("prepared", {}) as Dictionary).duplicate(true)
	_pending.clear()
	_events.clear()
	_event_cursor = 0
	_history.clear()
	_log = (payload.get("log", []) as Array).duplicate(true)
	_store_checkpoint()
	return {"ok": true, "match_id": match_id, "match": self}


func validate_join(role: String, requested_slot: Variant, _auth_context: Dictionary) -> Dictionary:
	if role == "observer":
		return {"ok": true, "slot": OBSERVER_SLOT}
	if role != "participant":
		return V3.reject(V3.REJECT_UNAUTHORIZED, "role is not supported")
	var requested := String(requested_slot) if requested_slot != null else ""
	if requested.is_empty():
		return {"ok": true, "slot": PARTICIPANT_SLOTS[0]}
	if requested in PARTICIPANT_SLOTS:
		return {"ok": true, "slot": requested}
	return V3.reject(V3.REJECT_SLOT_UNAVAILABLE, "slot is not part of this package")


func validate_command(slot: Variant, payload: Variant) -> Dictionary:
	if String(slot) not in PARTICIPANT_SLOTS:
		_refused += 1
		return V3.reject(V3.REJECT_UNAUTHORIZED, "source has no participant slot")
	if finished:
		_refused += 1
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "match is already complete")
	if not payload is Dictionary:
		_refused += 1
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "payload must be a Dictionary")
	var action := String((payload as Dictionary).get("action", ""))
	if action not in ["ready", "increment", "finish"]:
		_refused += 1
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "unknown action")
	if action == "increment":
		var amount := int((payload as Dictionary).get("amount", 1))
		if amount < 1 or amount > 3:
			_refused += 1
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "amount is outside 1..3")
	return {
		"ok": true,
		"command": {
			"action": action,
			"amount": int((payload as Dictionary).get("amount", 1)),
		},
	}


func apply_command(slot: Variant, payload: Variant) -> void:
	var checked := validate_command(slot, payload)
	if not bool(checked.get("ok", false)):
		return
	var entry := {
		"slot": String(slot),
		"payload": (checked.get("command", {}) as Dictionary).duplicate(true),
		"at": tick,
	}
	_pending.append(entry)
	_log.append(entry.duplicate(true))
	_accepted += 1


func advance(ticks: int) -> void:
	for _index in maxi(0, ticks):
		if finished:
			break
		_apply_pending()
		tick += 1
		if tick >= limit and not finished:
			_close("clock")
		_store_checkpoint()


func terminal_result() -> Variant:
	return completion.duplicate(true) if completion is Dictionary else null


func state_hash() -> String:
	return JSON.stringify(_state()).sha256_text()


func export_replay() -> Variant:
	return {
		"schema": 1,
		"game_id": GAME_ID,
		"match_id": match_id,
		"seed": seed,
		"limit": limit,
		"log": _log.duplicate(true),
		"steps": tick,
		"state_hash": state_hash(),
		"completion": terminal_result(),
	}


func build_checkpoint(_codec_id: String) -> Dictionary:
	_checkpoints += 1
	return {
		"payload": {
			"game_id": GAME_ID,
			"match_id": match_id,
			"state": _state(),
			"log": _log.duplicate(true),
		},
		"state_hash": state_hash(),
		"tick": tick,
	}


func build_delta(from_ack_tick: int, _codec_id: String) -> Dictionary:
	if not _history.has(from_ack_tick) or from_ack_tick >= tick:
		return {}
	_increments += 1
	return {
		"payload": {"replace": _state()},
		"tick": tick,
		"base_tick": from_ack_tick,
	}


func drain_events(_codec_id: String) -> Array:
	var result: Array = []
	while _event_cursor < _events.size():
		result.append({
			"reliability": String(V3.RELIABLE),
			"payload": (_events[_event_cursor] as Dictionary).duplicate(true),
		})
		_event_cursor += 1
	return result


func metrics() -> Dictionary:
	return {
		"accepted": _accepted,
		"refused": _refused,
		"checkpoints": _checkpoints,
		"increments": _increments,
		"step": tick,
	}


func replay_into(replay: Dictionary) -> Dictionary:
	if String(replay.get("game_id", "")) != GAME_ID:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "replay belongs to another package")
	var created := create_match({
		"match_id": String(replay.get("match_id", "")),
		"limit": int(replay.get("limit", 8)),
	}, int(replay.get("seed", 0)))
	if not bool(created.get("ok", false)):
		return created
	var entries: Array = replay.get("log", [])
	var cursor := 0
	var target_steps := int(replay.get("steps", 0))
	while tick < target_steps:
		while cursor < entries.size() and int(entries[cursor].get("at", -1)) == tick:
			apply_command(entries[cursor].get("slot"), entries[cursor].get("payload"))
			cursor += 1
		advance(1)
	return {"ok": state_hash() == String(replay.get("state_hash", ""))}


static func content_hash() -> String:
	return "counter-reference|rules=1|slots=3|actions=ready,increment,finish".sha256_text()


func _apply_pending() -> void:
	var batch := _pending
	_pending = []
	for entry: Dictionary in batch:
		var slot := String(entry.slot)
		var payload: Dictionary = entry.payload
		match String(payload.action):
			"ready":
				prepared[slot] = true
				_emit("prepared", slot)
			"increment":
				values[slot] = int(values.get(slot, 0)) + int(payload.amount)
				_emit("changed", slot)
			"finish":
				_close(slot)


func _close(source: String) -> void:
	finished = true
	completion = {
		"completed_by": source,
		"totals": values.duplicate(true),
		"step": tick,
	}
	_emit("completed", source)


func _emit(kind: String, source: String) -> void:
	_events.append({
		"index": _events.size() + 1,
		"kind": kind,
		"source": source,
		"step": tick,
	})


func _state() -> Dictionary:
	return {
		"seed": seed,
		"step": tick,
		"limit": limit,
		"closed": finished,
		"values": values.duplicate(true),
		"prepared": prepared.duplicate(true),
		"completion": completion.duplicate(true) if completion is Dictionary else null,
	}


func _store_checkpoint() -> void:
	_history[tick] = _state()
	var cutoff := tick - 64
	for stored_tick: Variant in _history.keys():
		if int(stored_tick) < cutoff:
			_history.erase(stored_tick)
