class_name AdapterRuntime
extends RefCounted

## Game-agnostic execution boundary for local and process adapters (#273).
## Runtime success and adapter-owned values are separate: `{ok: true, value}` means
## the invocation completed, while `value` may itself be an adapter rejection.

signal call_observed(report: Dictionary)

var runtime_id := "unbound"
var runtime_epoch := 0


func runtime_identity() -> Dictionary:
	return {
		"runtime_id": runtime_id,
		"runtime_epoch": runtime_epoch,
		"adapter_instance_id": runtime_id,
		"adapter_epoch": runtime_epoch,
	}


func package_descriptor(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"package_descriptor", context)


func slot_descriptors(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"slot_descriptors", context)


func validate_match_config(_config: Dictionary, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"validate_match_config", context)


func create_match(_config: Dictionary, _seed: int, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"create_match", context)


func recover_match(_checkpoint_payload: Variant, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"recover_match", context)


func validate_join(
		_role: String, _requested_slot: Variant, _auth_context: Dictionary,
		context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"validate_join", context)


func validate_command(
		_slot: Variant, _payload: Variant, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"validate_command", context)


func apply_command(
		_slot: Variant, _payload: Variant, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"apply_command", context)


func advance(_ticks: int, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"advance", context)


func terminal_result(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"terminal_result", context)


func state_hash(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"state_hash", context)


func export_replay(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"export_replay", context)


func build_checkpoint(_codec_id: String, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"build_checkpoint", context)


func build_delta(
		_from_ack_tick: int, _codec_id: String,
		context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"build_delta", context)


func drain_events(_codec_id: String, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"drain_events", context)


func metrics(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _unsupported(&"metrics", context)


func telemetry() -> Dictionary:
	return {
		"runtime_id": runtime_id,
		"runtime_epoch": runtime_epoch,
		"calls": 0,
		"failures": 0,
		"adapter_rejections": 0,
		"latency_usec": 0,
		"latency_usec_max": 0,
	}


func _unsupported(operation: StringName, context: Dictionary) -> AdapterRuntimeCall:
	var runtime_call := AdapterRuntimeCall.new(operation, context)
	var result := {
		"ok": false,
		"error": {
			"code": "runtime_not_implemented",
			"detail": "%s is not implemented" % operation,
			"retryable": false,
		},
		"meta": _meta(operation, context, 0),
	}
	runtime_call.complete(result)
	var report: Dictionary = result.meta.duplicate(true)
	report["ok"] = false
	report["adapter_rejected"] = false
	report["error_code"] = "runtime_not_implemented"
	call_observed.emit(report)
	return runtime_call


func _meta(operation: StringName, context: Dictionary, latency_usec: int) -> Dictionary:
	return {
		"operation": String(operation),
		"request_id": int(context.get("request_id", 0)),
		"match_id": String(context.get("match_id", "")),
		"expected_tick": int(context.get("expected_tick", 0)),
		"deadline_unix_ms": int(context.get("deadline_unix_ms", 0)),
		"runtime_id": runtime_id,
		"runtime_epoch": runtime_epoch,
		"adapter_instance_id": runtime_id,
		"adapter_epoch": runtime_epoch,
		"latency_usec": latency_usec,
	}
