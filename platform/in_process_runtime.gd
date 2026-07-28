class_name InProcessRuntime
extends AdapterRuntime

## Trusted compatibility runtime around the existing adapter object. It uses the same
## result/call boundary as a future process runtime but completes synchronously.

var _adapter: Object
var _calls := 0
var _failures := 0
var _adapter_rejections := 0
var _latency_usec := 0
var _latency_usec_max := 0


func _init(adapter: Object, candidate_runtime_id := "", candidate_epoch := 1) -> void:
	_adapter = adapter
	runtime_id = (
		candidate_runtime_id if not candidate_runtime_id.is_empty()
		else "in-process:%d" % get_instance_id())
	runtime_epoch = maxi(1, candidate_epoch)


func package_descriptor(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"package_descriptor", [], context)


func slot_descriptors(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"slot_descriptors", [], context)


func validate_match_config(
		config: Dictionary, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"validate_match_config", [config], context)


func create_match(
		config: Dictionary, seed: int, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"create_match", [config, seed], context)


func recover_match(
		checkpoint_payload: Variant, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"recover_match", [checkpoint_payload], context)


func validate_join(
		role: String, requested_slot: Variant, auth_context: Dictionary,
		context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"validate_join", [role, requested_slot, auth_context], context)


func validate_command(
		slot: Variant, payload: Variant, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"validate_command", [slot, payload], context)


func apply_command(
		slot: Variant, payload: Variant, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"apply_command", [slot, payload], context)


func advance(ticks: int, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"advance", [ticks], context)


func terminal_result(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"terminal_result", [], context)


func state_hash(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"state_hash", [], context)


func export_replay(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"export_replay", [], context)


func build_checkpoint(
		codec_id: String, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"build_checkpoint", [codec_id], context)


func build_delta(
		from_ack_tick: int, codec_id: String,
		context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"build_delta", [from_ack_tick, codec_id], context)


func drain_events(codec_id: String, context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"drain_events", [codec_id], context)


func metrics(context: Dictionary = {}) -> AdapterRuntimeCall:
	return _invoke(&"metrics", [], context)


func telemetry() -> Dictionary:
	return {
		"runtime_id": runtime_id,
		"runtime_epoch": runtime_epoch,
		"calls": _calls,
		"failures": _failures,
		"adapter_rejections": _adapter_rejections,
		"latency_usec": _latency_usec,
		"latency_usec_max": _latency_usec_max,
	}


func _invoke(
		operation: StringName, arguments: Array, context: Dictionary) -> AdapterRuntimeCall:
	var started := Time.get_ticks_usec()
	var runtime_call := AdapterRuntimeCall.new(operation, context)
	var result: Dictionary
	var adapter_rejected := false
	if _adapter == null or not _adapter.has_method(operation):
		_failures += 1
		result = {
			"ok": false,
			"error": {
				"code": "runtime_method_unavailable",
				"detail": "adapter does not implement %s" % operation,
				"retryable": false,
			},
		}
	else:
		var value: Variant = _adapter.callv(operation, arguments)
		if value is Dictionary:
			var adapter_value: Dictionary = value
			if not bool(adapter_value.get("ok", not adapter_value.has("code"))):
				_adapter_rejections += 1
				adapter_rejected = true
		result = {"ok": true, "value": value}
	var latency := Time.get_ticks_usec() - started
	_calls += 1
	_latency_usec += latency
	_latency_usec_max = maxi(_latency_usec_max, latency)
	result["meta"] = _meta(operation, context, latency)
	runtime_call.complete(result)
	var report: Dictionary = result.meta.duplicate(true)
	report["ok"] = bool(result.get("ok", false))
	report["adapter_rejected"] = adapter_rejected
	report["error_code"] = String(result.get("error", {}).get("code", ""))
	call_observed.emit(report)
	return runtime_call
