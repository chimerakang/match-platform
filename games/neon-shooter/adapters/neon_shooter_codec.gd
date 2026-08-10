class_name NeonShooterCodec
extends RefCounted

## JSON codec for neon-platform-shooter (codec id "neon.json.v1"). Groups outgoing
## messages by the adapter-declared reliability class and frames each group; the
## platform core routes by class and never inspects the payload. Mirrors the
## reference counter codec so the same delivery queue drives both packages.

const V3 = preload("res://platform/match_platform_v3.gd")

const CODEC_ID := "neon.json.v1"


func delivery_groups(messages: Array) -> Array[Dictionary]:
	var grouped: Dictionary = {}
	for message: Dictionary in messages:
		var delivery := StringName(message.get("reliability", V3.RELIABLE))
		(grouped.get_or_add(delivery, []) as Array).append(message)
	var result: Array[Dictionary] = []
	for delivery: Variant in [V3.RELIABLE, V3.REPLACEABLE, V3.DROPPABLE]:
		if grouped.has(delivery):
			result.append({"reliability": StringName(delivery), "messages": grouped[delivery]})
	return result


func encode_batches_for(messages: Array, _protocol: int) -> Array[PackedByteArray]:
	return [JSON.stringify(messages).to_utf8_buffer()]


static func decode(bytes: PackedByteArray) -> Array:
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	return parsed if parsed is Array else []
