class_name InMemoryMatchMetadataStore
extends MatchMetadataStore

var _records: Dictionary = {}
var _order: Array[String] = []


func upsert(record: Dictionary) -> Dictionary:
	var checked := validate_record(record)
	if not bool(checked.get("ok", false)):
		return checked
	var match_id := String(record.match_id)
	var merged: Dictionary = _records.get(match_id, {}).duplicate(true)
	for key: Variant in record:
		merged[key] = record[key]
	var now := int(Time.get_unix_time_from_system())
	if not merged.has("created_at_unix"):
		merged["created_at_unix"] = now
	merged["updated_at_unix"] = now
	if not _records.has(match_id):
		_order.append(match_id)
	_records[match_id] = merged
	return {"ok": true, "match_id": match_id}


func get_match(match_id: String) -> Dictionary:
	return (_records.get(match_id, {}) as Dictionary).duplicate(true)


func list_matches(filters: Dictionary = {}) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for match_id: String in _order:
		var record: Dictionary = _records[match_id]
		var include := true
		for key: Variant in filters:
			if record.get(key) != filters[key]:
				include = false
				break
		if include:
			result.append(record.duplicate(true))
	return result
