class_name GamePackageRegistry
extends RefCounted

## Operator-controlled trusted package set with explicit activation and rollback.
## The active set is projected through PlatformAdapterRegistry for every negotiation,
## preserving the frozen pre-seat contract without teaching the core rollout policy.

const V3 = preload("res://platform/match_platform_v3.gd")
const RuntimeRegistry = preload("res://platform/platform_adapter_registry.gd")
const LocalRuntime = preload("res://platform/in_process_runtime.gd")

var _packages: Dictionary = {}
var _active: Dictionary = {}
var _history: Dictionary = {}
var _order: Array[String] = []


func register(adapter: Object, activate_now := true) -> Dictionary:
	if adapter == null or not adapter.has_method("package_descriptor"):
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "package has no descriptor")
	var descriptor: Variant = adapter.package_descriptor()
	if not descriptor is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "package descriptor must be a Dictionary")
	var checked := RuntimeRegistry.validate_descriptor(descriptor)
	if not bool(checked.get("ok", false)):
		return checked
	var game_id := String(descriptor.get("game_id", ""))
	var version := String(descriptor.get("adapter_version", ""))
	var versions: Dictionary = _packages.get(game_id, {})
	if versions.has(version):
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "package version already registered")
	versions[version] = {
		"adapter": adapter,
		"runtime": LocalRuntime.new(adapter, "%s:%s" % [game_id, version]),
		"descriptor": (descriptor as Dictionary).duplicate(true),
	}
	_packages[game_id] = versions
	if game_id not in _order:
		_order.append(game_id)
	if activate_now or not _active.has(game_id):
		var activated := activate(game_id, version)
		if not bool(activated.get("ok", false)):
			return activated
	return {"ok": true, "game_id": game_id, "adapter_version": version}


func load_file(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "package config must be a JSON object")
	return load_configuration(parsed)


func load_configuration(config: Dictionary) -> Dictionary:
	var entries: Variant = config.get("packages", [])
	if not entries is Array:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "packages must be an Array")
	var loaded: Array[Dictionary] = []
	for value: Variant in entries:
		if not value is Dictionary:
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "package entry must be an object")
		var entry: Dictionary = value
		if not bool(entry.get("enabled", true)):
			continue
		var path := String(entry.get("script_path", ""))
		if not path.begins_with("res://"):
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "trusted script_path must use res://")
		var script: Variant = load(path)
		if script == null or not script.has_method("new"):
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "cannot load trusted package script")
		var result := register(script.new(), bool(entry.get("active", true)))
		if not bool(result.get("ok", false)):
			return result
		loaded.append(result)
	return {"ok": true, "loaded": loaded}


func activate(game_id: String, adapter_version: String) -> Dictionary:
	var versions: Dictionary = _packages.get(game_id, {})
	if not versions.has(adapter_version):
		return V3.reject(V3.REJECT_UNKNOWN_GAME, "package version is not registered")
	var previous := String(_active.get(game_id, ""))
	if not previous.is_empty() and previous != adapter_version:
		var history: Array = _history.get(game_id, [])
		history.append(previous)
		_history[game_id] = history
	_active[game_id] = adapter_version
	return {"ok": true, "game_id": game_id, "adapter_version": adapter_version}


func rollback(game_id: String) -> Dictionary:
	var history: Array = _history.get(game_id, [])
	if history.is_empty():
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "no previous package version")
	var target := String(history.pop_back())
	_history[game_id] = history
	_active[game_id] = target
	return {"ok": true, "game_id": game_id, "adapter_version": target}


func has_game(game_id: String) -> bool:
	return _active.has(game_id) and _packages.get(game_id, {}).has(_active[game_id])


func adapter_for(game_id: String) -> Object:
	if not has_game(game_id):
		return null
	return _packages[game_id][_active[game_id]].adapter


func runtime_for(game_id: String) -> AdapterRuntime:
	if not has_game(game_id):
		return null
	return _packages[game_id][_active[game_id]].runtime


func descriptor(game_id: String) -> Dictionary:
	if not has_game(game_id):
		return {}
	return (_packages[game_id][_active[game_id]].descriptor as Dictionary).duplicate(true)


func slot_descriptors(game_id: String) -> Array:
	var runtime := runtime_for(game_id)
	if runtime == null:
		return []
	var result := runtime.slot_descriptors().result_now()
	var value: Variant = result.get("value", [])
	return value if bool(result.get("ok", false)) and value is Array else []


func registered_game_ids() -> Array[String]:
	return _order.duplicate()


func welcome_for(hello: Dictionary, capabilities: Dictionary = {}) -> Dictionary:
	var runtime := _runtime_registry()
	return runtime.welcome_for(hello, capabilities)


func resolve_hello(hello: Dictionary) -> Dictionary:
	return _runtime_registry().resolve_hello(hello)


func create_match(game_id: String, config: Dictionary, match_seed: int) -> Dictionary:
	return _runtime_registry().create_match(game_id, config, match_seed)


func recover_match(game_id: String, checkpoint_payload: Variant) -> Dictionary:
	return _runtime_registry().recover_match(game_id, checkpoint_payload)


func inventory() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for game_id: String in _order:
		var versions: Dictionary = _packages[game_id]
		var ordered_versions: Array[String] = []
		for value: Variant in versions.keys():
			ordered_versions.append(String(value))
		ordered_versions.sort()
		for version: String in ordered_versions:
			var descriptor_value: Dictionary = versions[version].descriptor
			result.append({
				"game_id": game_id,
				"adapter_version": version,
				"active": String(_active.get(game_id, "")) == version,
				"content_versions": (descriptor_value.get("content_versions", []) as Array).duplicate(),
				"content_hashes": (descriptor_value.get("content_hashes", []) as Array).duplicate(),
				"codec_ids": (descriptor_value.get("codec_ids", []) as Array).duplicate(),
			})
	return result


func _runtime_registry() -> PlatformAdapterRegistry:
	var runtime := RuntimeRegistry.new()
	for game_id: String in _order:
		var package_runtime := runtime_for(game_id)
		if package_runtime != null:
			runtime.register_runtime(package_runtime)
	return runtime
