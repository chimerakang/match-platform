class_name MatchOperationsService
extends RefCounted

## JSON-ready health/metrics/admin contract. It receives already-partitioned match
## telemetry and never accepts checkpoints, state, events, commands, or replay.

const PLATFORM_METRIC_FIELDS: Array[String] = [
	"encode_usec", "encode_frames", "state_build_usec", "snapshot_usec",
	"send_usec", "state_messages", "snapshot_messages", "packet_bytes_peak",
	"snapshot_ring_entries", "snapshot_ring_bytes", "resync_requests",
	"full_snapshots_sent", "rejected_state_acks",
]

var package_registry: Object
var metadata_store: Object


func _init(packages: Object, matches: Object) -> void:
	package_registry = packages
	metadata_store = matches


func health() -> Dictionary:
	var inventory: Array = package_registry.inventory()
	return {
		"status": "ok" if not inventory.is_empty() else "degraded",
		"active_packages": inventory.filter(
			func(entry: Dictionary) -> bool: return bool(entry.get("active", false))).size(),
		"known_matches": metadata_store.list_matches().size(),
	}


func metrics(arena_telemetry: Array) -> Dictionary:
	var matches: Array[Dictionary] = []
	for value: Variant in arena_telemetry:
		if not value is Dictionary:
			continue
		var source: Dictionary = value
		var platform: Dictionary = {}
		for field: String in PLATFORM_METRIC_FIELDS:
			if source.has(field):
				platform[field] = source[field]
		matches.append({
			"match_id": String(source.get("match_id",
				"hersir:%d" % int(source.get("arena_id", 0)))),
			"game_id": String(source.get("game_id", "")),
			"adapter_version": String(source.get("adapter_version", "")),
			"platform": platform,
			"adapter": (source.get("game_metrics", {}) as Dictionary).duplicate(true),
		})
	return {"matches": matches}


func admin_inventory() -> Dictionary:
	return {
		"packages": package_registry.inventory(),
		"matches": metadata_store.list_matches(),
	}


func activate_package(game_id: String, adapter_version: String) -> Dictionary:
	return package_registry.activate(game_id, adapter_version)


func rollback_package(game_id: String) -> Dictionary:
	return package_registry.rollback(game_id)
