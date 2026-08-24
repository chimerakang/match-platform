extends SceneTree

## Contract test for Match Platform V3 (issue #74, ADR 0003).
##
## Proves the frozen envelope contract against the reference JSON fixtures:
##   - every `valid` envelope passes structural validation for its direction;
##   - every `invalid` envelope is refused with EXACTLY its expected reject code;
##   - protocol/codec negotiation matches the documented rules;
##   - the platform stays opaque: no game payload is inspected, and no Hersir
##     name appears in the contract module, adapter interface, or fixtures;
##   - the abstract MatchGameAdapter refuses every call until overridden.
##
## Run: godot --headless --path . --script res://tests/v3_contract_test.gd

const V3 = preload("res://platform/match_platform_v3.gd")
const Adapter = preload("res://platform/match_game_adapter.gd")
const FIXTURES_PATH := "res://tests/fixtures/v3_envelope_fixtures.json"

# Names that must NEVER appear in a platform envelope, the contract module, the
# adapter interface, or the fixtures. This is the #73 non-negotiable boundary,
# enforced mechanically.
const FORBIDDEN_GAME_NAMES: Array[String] = [
	"blue", "red", "hero", "unit", "stronghold", "camp", "outpost",
	"recruit", "cast_skill", "hire_merc", "warcry", "militia", "economy",
]

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: %s" % message)

func _run() -> void:
	var fixtures := _load_fixtures()
	if fixtures.is_empty():
		print("FAIL: could not load %s" % FIXTURES_PATH)
		quit(1)
		return
	_test_valid_envelopes(fixtures)
	_test_release_version()
	_test_invalid_envelopes(fixtures)
	_test_negotiation(fixtures)
	_test_delivery_classes(fixtures)
	_test_reject_builder()
	_test_adapter_is_abstract()
	_test_no_game_names_leak(fixtures)
	if failures.is_empty():
		print("PASS: %d Match Platform V3 contract checks" % checks)
		quit(0)
	else:
		print("FAIL: %d/%d V3 contract checks failed" % [failures.size(), checks])
		for failure in failures:
			print(" - %s" % failure)
		quit(1)

func _test_release_version() -> void:
	var release_version := FileAccess.get_file_as_string("res://VERSION").strip_edges()
	_check(release_version == V3.PLATFORM_VERSION,
		"VERSION matches the executable platform version")
	_check(V3.PLATFORM_VERSION_MAJOR == V3.ENVELOPE_VERSION,
		"Match Platform major matches the Client Protocol major")
	_check(V3.supports_platform_version("3.0.0"), "same-major platform release is compatible")
	_check(V3.supports_platform_version("v3.9.7"), "v-prefixed same-major release is compatible")
	_check(not V3.supports_platform_version("4.0.0"), "next-major platform release is incompatible")
	_check(not V3.supports_platform_version("3.0"), "non-SemVer platform release is invalid")

func _load_fixtures() -> Dictionary:
	var text := FileAccess.get_file_as_string(FIXTURES_PATH)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

func _allowed_for(direction: String) -> Array[StringName]:
	return V3.CLIENT_MESSAGES if direction == "client" else V3.SERVER_MESSAGES

func _test_valid_envelopes(fixtures: Dictionary) -> void:
	_check(int(fixtures.get("envelope_version", 0)) == V3.ENVELOPE_VERSION,
		"fixtures declare the module's envelope version")
	var valid: Dictionary = fixtures.get("valid", {})
	# Each fixture must validate for whichever direction its type belongs to, and
	# the two directions together must cover all seven message types exactly once.
	var seen: Dictionary = {}
	for name: String in valid.keys():
		var env: Dictionary = valid[name]
		var type := StringName(env.get("t", ""))
		seen[type] = true
		var direction := "client" if type in V3.CLIENT_MESSAGES else "server"
		var result := V3.validate_envelope(env, _allowed_for(direction))
		_check(bool(result.get("ok", false)),
			"valid '%s' envelope passes %s validation (got %s)" % [name, direction, result.get("code", "")])
	for type: StringName in V3.CLIENT_MESSAGES + V3.SERVER_MESSAGES:
		_check(seen.has(type), "fixtures include a valid example for '%s'" % type)

func _test_invalid_envelopes(fixtures: Dictionary) -> void:
	var invalid: Array = fixtures.get("invalid", [])
	_check(invalid.size() >= 6, "fixtures cover the core rejection cases")
	for entry: Dictionary in invalid:
		var expect := String(entry.get("expect_code", ""))
		var allowed := _allowed_for(String(entry.get("allowed", "server")))
		var result := V3.validate_envelope(entry.get("envelope"), allowed)
		_check(not bool(result.get("ok", true)) and String(result.get("code", "")) == expect,
			"invalid case (%s) → %s (got %s)" % [entry.get("why", ""), expect, result.get("code", "ok")])
	# A non-dictionary envelope is malformed, never a crash.
	var not_a_dict := V3.validate_envelope("not-an-envelope", V3.CLIENT_MESSAGES)
	_check(String(not_a_dict.get("code", "")) == String(V3.REJECT_MALFORMED_ENVELOPE),
		"non-dictionary envelope is malformed")

func _test_negotiation(fixtures: Dictionary) -> void:
	var negotiation: Dictionary = fixtures.get("negotiation", {})
	for case: Dictionary in negotiation.get("protocol", []):
		var got := V3.negotiate_protocol(case.get("client", []), case.get("server", []))
		_check(got == int(case.get("expect", -1)),
			"protocol negotiation (%s) → %d" % [case.get("why", ""), got])
	for case: Dictionary in negotiation.get("codec", []):
		var got := V3.negotiate_codec(case.get("client", []), case.get("adapter", []))
		_check(got == String(case.get("expect", "?")),
			"codec negotiation (%s) → '%s'" % [case.get("why", ""), got])

func _test_delivery_classes(fixtures: Dictionary) -> void:
	var valid: Dictionary = fixtures.get("valid", {})
	# state is replaceable, command/checkpoint reliable, and an event carries the
	# class it declares — the core never reads the payload to decide delivery.
	_check(V3.reliability_of(valid["state"]) == V3.REPLACEABLE, "state is replaceable")
	_check(V3.reliability_of(valid["command"]) == V3.RELIABLE, "command is reliable")
	_check(V3.reliability_of(valid["checkpoint"]) == V3.RELIABLE, "checkpoint is reliable")
	_check(V3.reliability_of(valid["event"]) == V3.DROPPABLE, "event honours its declared droppable class")
	var reliable_event: Dictionary = valid["event"].duplicate()
	reliable_event["reliability"] = String(V3.RELIABLE)
	_check(V3.reliability_of(reliable_event) == V3.RELIABLE, "same event type can declare reliable")

func _test_reject_builder() -> void:
	var packet := V3.reject(V3.REJECT_UNKNOWN_GAME, "no such game")
	var result := V3.validate_envelope(packet, V3.SERVER_MESSAGES)
	_check(bool(result.get("ok", false)), "reject() builds a valid reject envelope")
	_check(String(packet.get("code", "")) == String(V3.REJECT_UNKNOWN_GAME), "reject() carries the code")

func _test_adapter_is_abstract() -> void:
	var adapter := Adapter.new()
	_check(adapter.package_descriptor().is_empty(), "base adapter has no package identity")
	var join := adapter.validate_join("player", "north", {})
	_check(String(join.get("code", "")) == String(V3.REJECT_ADAPTER_REJECTED),
		"base adapter refuses join until overridden")
	var command := adapter.validate_command("north", {})
	_check(String(command.get("code", "")) == String(V3.REJECT_ADAPTER_REJECTED),
		"base adapter refuses commands until overridden")
	_check(adapter.terminal_result() == null, "base adapter has no terminal result")
	_check(adapter.state_hash() == "", "base adapter has no state hash")

func _test_no_game_names_leak(fixtures: Dictionary) -> void:
	# The whole envelope corpus (valid + negotiation) must be free of any Hersir
	# game vocabulary as a WHOLE TOKEN — 'red' inside "required" is fine, the seat
	# name 'red' is not. Payload blobs use only the fictional 'gridwars' game. The
	# `_comment` block is documentation, not an envelope, so it is excluded.
	var corpus := JSON.stringify(fixtures.get("valid", {})) + JSON.stringify(fixtures.get("negotiation", {}))
	for name: String in FORBIDDEN_GAME_NAMES:
		_check(not _mentions_token(corpus, name), "no game name '%s' leaks into platform envelopes" % name)
	# And the contract module + adapter interface themselves stay game-agnostic.
	for path: String in ["res://platform/match_platform_v3.gd", "res://platform/match_game_adapter.gd"]:
		var src := FileAccess.get_file_as_string(path)
		for name: String in FORBIDDEN_GAME_NAMES:
			_check(not _mentions_token(src, name), "%s does not mention '%s'" % [path, name])

## True when `name` appears in `text` as a whole word (letters/digits/underscore
## boundaries), case-insensitive — so English prose that merely contains the
## letters ("required", "example") does not trip the game-name guard.
func _mentions_token(text: String, name: String) -> bool:
	var regex := RegEx.new()
	regex.compile("(?i)(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % name)
	return regex.search(text) != null
