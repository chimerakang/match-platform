class_name MatchMetadataStore
extends RefCounted

const V3 = preload("res://platform/match_platform_v3.gd")

## Gameplay payloads are forbidden here. Durable provider implementations may store
## only the operator identity/lifecycle fields defined by this contract.
const ALLOWED_FIELDS: Array[String] = [
	"match_id", "game_id", "adapter_version", "content_version", "content_hash",
	"codec_ids", "status", "created_at_unix", "updated_at_unix", "ended_at_unix",
]
const REQUIRED_FIELDS: Array[String] = [
	"match_id", "game_id", "adapter_version", "content_version", "content_hash", "status",
]


func validate_record(record: Dictionary) -> Dictionary:
	for key: Variant in record.keys():
		if String(key) not in ALLOWED_FIELDS:
			return V3.reject(V3.REJECT_ADAPTER_REJECTED,
				"metadata field is not allowed: %s" % String(key))
	for field: String in REQUIRED_FIELDS:
		if String(record.get(field, "")).strip_edges().is_empty():
			return V3.reject(V3.REJECT_ADAPTER_REJECTED,
				"metadata field is required: %s" % field)
	return {"ok": true}


func upsert(_record: Dictionary) -> Dictionary:
	return V3.reject(V3.REJECT_ADAPTER_REJECTED, "metadata store is not configured")


func get_match(_match_id: String) -> Dictionary:
	return {}


func list_matches(_filters: Dictionary = {}) -> Array[Dictionary]:
	return []
