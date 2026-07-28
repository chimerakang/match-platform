class_name AdapterRuntimeCall
extends RefCounted

## One result-oriented runtime invocation. A local runtime completes it before
## returning; a process runtime may complete it later without changing callers.

signal finished(result: Dictionary)

var operation: StringName
var request_id := 0
var context: Dictionary = {}
var _completed := false
var _result: Dictionary = {}


func _init(candidate_operation: StringName = &"", candidate_context: Variant = {}) -> void:
	operation = candidate_operation
	if candidate_context is Dictionary:
		context = (candidate_context as Dictionary).duplicate(true)
		request_id = int(context.get("request_id", 0))
	else:
		request_id = int(candidate_context)
		context = {"request_id": request_id}


func is_completed() -> bool:
	return _completed


func complete(result: Dictionary) -> void:
	if _completed:
		return
	_completed = true
	_result = result.duplicate(true)
	finished.emit(_result.duplicate(true))


func result_now() -> Dictionary:
	if not _completed:
		return {
			"ok": false,
			"error": {
				"code": "runtime_pending",
				"detail": "runtime call has not completed",
				"retryable": false,
			},
			"meta": {"operation": String(operation), "request_id": request_id},
		}
	return _result.duplicate(true)


func wait() -> Dictionary:
	if not _completed:
		await finished
	return _result.duplicate(true)
