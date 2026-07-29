extends SceneTree

const Packages = preload("res://operations/game_package_registry.gd")
const Auth = preload("res://operations/in_memory_auth_identity_verifier.gd")
const Metadata = preload("res://operations/in_memory_match_metadata_store.gd")
const Operations = preload("res://operations/match_operations_service.gd")
const Reference = preload("res://adapters/reference/counter_game_adapter.gd")

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: %s" % message)


func _run() -> void:
	var packages := Packages.new()
	var adapter := Reference.new()
	_check(bool(packages.register(adapter).get("ok", false)),
		"reference package registers and activates")
	_check(packages.has_game(Reference.GAME_ID),
		"active reference package resolves without a core change")

	var auth := Auth.new(false, {"valid": {"subject": "operator"}})
	_check(bool(auth.verify({"bearer_token": "valid"}).get("ok", false)),
		"configured identity is accepted")
	_check(not bool(auth.verify({"bearer_token": "invalid"}).get("ok", false)),
		"unknown credential is rejected")

	var metadata := Metadata.new()
	_check(bool(metadata.upsert({
		"match_id": "counter:1", "game_id": Reference.GAME_ID,
		"adapter_version": Reference.ADAPTER_VERSION,
		"content_version": Reference.CONTENT_VERSION,
		"content_hash": adapter.content_hash(),
		"status": "running",
	}).get("ok", false)), "match metadata is stored")
	var service := Operations.new(packages, metadata)
	_check(String(service.health().get("status", "")) == "ok",
		"operations health reports an active package")
	_check(service.admin_inventory().get("matches", []).size() == 1,
		"operations inventory includes the reference match")

	if failures.is_empty():
		print("PASS: %d standalone operations SDK checks" % checks)
		quit(0)
	else:
		print("FAIL: %d/%d operations SDK checks failed" % [failures.size(), checks])
		quit(1)
