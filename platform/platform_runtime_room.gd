class_name PlatformRuntimeRoom
extends RefCounted

const AdapterRuntime = preload("./adapter_runtime.gd")
const AdapterRuntimeCall = preload("./adapter_runtime_call.gd")

## Minimal execution owner shared by local and future process runtimes. It assigns
## monotonic request ids and never branches on the concrete runtime or opaque values.

var runtime: AdapterRuntime
var _next_request_id := 1
var _match_id := ""
var _deadline_msec := 5000


func _init(
		candidate_runtime: AdapterRuntime, candidate_match_id := "",
		candidate_deadline_msec := 5000) -> void:
	runtime = candidate_runtime
	_match_id = candidate_match_id
	_deadline_msec = maxi(1, candidate_deadline_msec)


func validate_join(
		role: String, requested_slot: Variant, auth_context: Dictionary,
		expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.validate_join(
		role, requested_slot, auth_context, _take_context(expected_tick))


func validate_command(
		slot: Variant, payload: Variant, expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.validate_command(slot, payload, _take_context(expected_tick))


func apply_command(
		slot: Variant, payload: Variant, expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.apply_command(slot, payload, _take_context(expected_tick))


func advance(ticks: int, expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.advance(ticks, _take_context(expected_tick))


func build_checkpoint(codec_id: String, expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.build_checkpoint(codec_id, _take_context(expected_tick))


func build_delta(
		from_ack_tick: int, codec_id: String, expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.build_delta(
		from_ack_tick, codec_id, _take_context(expected_tick))


func drain_events(codec_id: String, expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.drain_events(codec_id, _take_context(expected_tick))


func terminal_result(expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.terminal_result(_take_context(expected_tick))


func state_hash(expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.state_hash(_take_context(expected_tick))


func export_replay(expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.export_replay(_take_context(expected_tick))


func metrics(expected_tick := 0) -> AdapterRuntimeCall:
	return runtime.metrics(_take_context(expected_tick))


func _take_context(expected_tick: int) -> Dictionary:
	var request_id := _next_request_id
	_next_request_id += 1
	var identity := runtime.runtime_identity()
	return {
		"protocol": {"major": 1, "minor": 0},
		"match_id": _match_id,
		"adapter_instance_id": String(identity.get("adapter_instance_id", "")),
		"adapter_epoch": int(identity.get("adapter_epoch", 0)),
		"request_id": request_id,
		"expected_tick": expected_tick,
		"deadline_unix_ms": int(Time.get_unix_time_from_system() * 1000.0) + _deadline_msec,
	}
