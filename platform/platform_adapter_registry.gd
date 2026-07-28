class_name PlatformAdapterRegistry
extends RefCounted

## Trusted game-package registry for Match Platform Core (issue #75, Epic #73).
##
## The registry is the platform's *only* way to reach a game. It holds the server's
## registered package set — adapters are trusted server-side code, NEVER uploaded by
## a client (#73 boundary) — and it answers exactly two questions for the core:
##
##   1. "May this `hello` proceed?" (`resolve_hello`) — the pre-seat identity gate.
##      Unknown game, unsupported game version, mismatched content hash and disjoint
##      codec sets are all refused *before* a player is seated, each with the stable
##      reject code from the frozen contract.
##   2. "Give me a match" (`create_match` / `recover_match`) — the match factory. The
##      registry validates the canonical config through the adapter and hands back an
##      opaque match handle. It never inspects the config or the resulting state.
##
## Nothing here branches on a game concept: no slot name, no command name, no entity
## kind, no map field. `game_id`/`codec_id`/`content_hash` are opaque identifiers the
## registry compares for equality and nothing more. See ADR 0003 §5 for negotiation
## and `docs/match-platform-core.md` for how the core consumes this.

const V3 = preload("res://platform/match_platform_v3.gd")
const LocalRuntime = preload("res://platform/in_process_runtime.gd")

## Platform envelope versions this build speaks, newest first. Negotiation picks the
## highest value shared with the client (`unsupported_protocol` when disjoint). This
## is the *platform* contract version, independent of any game or codec version.
const SUPPORTED_PROTOCOLS: Array[int] = [V3.ENVELOPE_VERSION]

## Descriptor fields every registered package must declare. A package that cannot
## state its identity cannot be registered — there is no permissive default, because
## these fields *are* the pre-seat gate.
const REQUIRED_DESCRIPTOR_FIELDS: Array[String] = [
	"game_id", "adapter_version", "content_versions", "content_hashes",
	"codec_ids", "tick_rate",
]

## game_id -> {runtime: AdapterRuntime, descriptor: Dictionary}. Registration order is kept
## separately so listings are deterministic (the core must never depend on Dictionary
## iteration order for anything observable).
var _packages: Dictionary = {}
var _order: Array[String] = []

# --- Registration -----------------------------------------------------------

## Register a trusted adapter under the `game_id` from its own descriptor. Returns
## `{ok: true, game_id}`, or a reject envelope when the descriptor is unusable or the
## id is already taken. Registration is a server-startup action, not a client path.
func register(adapter: Object) -> Dictionary:
	if adapter == null:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "adapter is null")
	return register_runtime(LocalRuntime.new(adapter))

## Register any runtime that implements the common call/result contract. Descriptor
## discovery is itself a runtime call; registration refuses a pending or failed call
## rather than branching on the concrete runtime implementation.
func register_runtime(runtime: AdapterRuntime) -> Dictionary:
	if runtime == null:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "runtime is null")
	var descriptor: Variant = _runtime_value(runtime.package_descriptor(), null)
	if not descriptor is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "runtime package descriptor unavailable")
	var check := validate_descriptor(descriptor)
	if not bool(check.get("ok", false)):
		return check
	var game_id := String((descriptor as Dictionary)["game_id"])
	if _packages.has(game_id):
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "game_id already registered: %s" % game_id)
	_packages[game_id] = {
		"runtime": runtime,
		"descriptor": (descriptor as Dictionary).duplicate(true),
	}
	_order.append(game_id)
	return {"ok": true, "game_id": game_id}

## Structural descriptor validation, pure and reusable by an adapter's own tests. A
## package must name itself, list at least one content version, content hash and
## codec, and declare a positive tick rate — the core schedules at that rate.
static func validate_descriptor(descriptor: Dictionary) -> Dictionary:
	for field: String in REQUIRED_DESCRIPTOR_FIELDS:
		if not descriptor.has(field):
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "descriptor missing field: %s" % field)
	if String(descriptor["game_id"]).strip_edges().is_empty():
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "descriptor game_id must be non-empty")
	if String(descriptor["adapter_version"]).strip_edges().is_empty():
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "descriptor adapter_version must be non-empty")
	for list_field: String in ["content_versions", "content_hashes", "codec_ids"]:
		var value: Variant = descriptor[list_field]
		if not value is Array or (value as Array).is_empty():
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "descriptor %s must be a non-empty Array" % list_field)
	if int(descriptor["tick_rate"]) <= 0:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "descriptor tick_rate must be positive")
	return {"ok": true}

func registered_game_ids() -> Array[String]:
	return _order.duplicate()

func has_game(game_id: String) -> bool:
	return _packages.has(game_id)

## Registered descriptor copy, or `{}`. A copy so no caller can mutate the trusted
## package set after startup.
func descriptor(game_id: String) -> Dictionary:
	if not _packages.has(game_id):
		return {}
	return (_packages[game_id].descriptor as Dictionary).duplicate(true)

## The execution boundary for a package, or `null`.
func runtime_for(game_id: String) -> AdapterRuntime:
	if not _packages.has(game_id):
		return null
	return _packages[game_id].runtime

## Slot/role descriptors as the adapter declares them — opaque to the core, which
## reads only counts and availability from them (never a seat name).
func slot_descriptors(game_id: String) -> Array:
	var runtime := runtime_for(game_id)
	if runtime == null:
		return []
	var value: Variant = _runtime_value(runtime.slot_descriptors(), [])
	return value if value is Array else []

# --- Pre-seat identity gate -------------------------------------------------

## Resolve a client `hello` against the registered package set. This is the gate that
## must run BEFORE any seating: every failure mode returns the contract's stable code
## so a mismatched client learns *why* it cannot play rather than being seated into a
## match it would immediately desync from.
##
## Order is deliberate — protocol, then game, then game version, then content, then
## codec — so the most fundamental incompatibility is always the reported one.
## Returns `{ok: true, game_id, adapter_version, selected_protocol, selected_codec,
## tick_rate}` or `{ok: false, code, detail}`.
func resolve_hello(hello: Dictionary) -> Dictionary:
	var structural := V3.validate_envelope(hello, [V3.HELLO])
	if not bool(structural.get("ok", false)):
		return {"ok": false, "code": String(structural.get("code", V3.REJECT_MALFORMED_ENVELOPE)), "detail": "hello envelope invalid"}
	var client_protocols: Variant = hello.get("protocol_versions", [])
	if not client_protocols is Array:
		return _refuse(V3.REJECT_MALFORMED_ENVELOPE, "protocol_versions must be an Array")
	var selected_protocol := V3.negotiate_protocol(client_protocols, SUPPORTED_PROTOCOLS)
	if selected_protocol == 0:
		return _refuse(V3.REJECT_UNSUPPORTED_PROTOCOL, "no shared platform protocol version")

	var game_id := String(hello.get("game_id", ""))
	if not _packages.has(game_id):
		return _refuse(V3.REJECT_UNKNOWN_GAME, "no registered package for game_id")
	var package: Dictionary = _packages[game_id].descriptor

	# Version and content are compared as opaque strings against the package's own
	# declared sets. There is no wildcard: a package that wants to accept a build
	# must list it, which is what makes this gate meaningful.
	var game_version := String(hello.get("game_version", ""))
	if not _lists_value(package.get("content_versions", []), game_version):
		return _refuse(V3.REJECT_UNSUPPORTED_GAME_VERSION, "package does not support game_version")
	var content_hash := String(hello.get("content_hash", ""))
	if not _lists_value(package.get("content_hashes", []), content_hash):
		return _refuse(V3.REJECT_CONTENT_MISMATCH, "package does not recognize content_hash")

	var client_codecs: Variant = hello.get("codecs", [])
	if not client_codecs is Array:
		return _refuse(V3.REJECT_MALFORMED_ENVELOPE, "codecs must be an Array")
	var selected_codec := V3.negotiate_codec(client_codecs, _string_list(package.get("codec_ids", [])))
	if selected_codec.is_empty():
		return _refuse(V3.REJECT_UNSUPPORTED_CODEC, "no shared codec between client and package")

	return {
		"ok": true, "game_id": game_id,
		"adapter_version": String(package.get("adapter_version", "")),
		"selected_protocol": selected_protocol, "selected_codec": selected_codec,
		"tick_rate": int(package.get("tick_rate", 0)),
	}

## `resolve_hello` rendered as the envelope the core actually sends: a `welcome` on
## success, or the matching `reject`. `capabilities` is platform-declared (never
## game-declared) so a client can learn what the *core* supports independently of the
## game it is about to play.
func welcome_for(hello: Dictionary, capabilities: Dictionary = {}) -> Dictionary:
	var resolved := resolve_hello(hello)
	if not bool(resolved.get("ok", false)):
		return V3.reject(StringName(resolved.get("code", V3.REJECT_MALFORMED_ENVELOPE)), String(resolved.get("detail", "")))
	return V3.envelope(V3.WELCOME, {
		"selected_protocol": int(resolved.selected_protocol),
		"game_id": String(resolved.game_id),
		"adapter_version": String(resolved.adapter_version),
		"selected_codec": String(resolved.selected_codec),
		"tick_rate": int(resolved.tick_rate),
		"capabilities": capabilities.duplicate(true),
	})

# --- Match factory ----------------------------------------------------------

## Validate a canonical match configuration through the adapter, then create the
## match. `config` and the returned handle are opaque; the registry only sequences
## the two adapter calls and normalizes their refusals into contract codes.
## A deterministic `seed` is mandatory — the #36 determinism contract has no
## seedless match, and the core must not invent one from wall-clock.
func create_match(game_id: String, config: Dictionary, match_seed: int) -> Dictionary:
	var runtime := runtime_for(game_id)
	if runtime == null:
		return V3.reject(V3.REJECT_UNKNOWN_GAME, "no registered package for game_id")
	var validated: Variant = _runtime_value(runtime.validate_match_config(config), null)
	if not (validated is Dictionary and bool((validated as Dictionary).get("ok", false))):
		return _as_reject(validated, "validate_match_config refused the configuration")
	var created: Variant = _runtime_value(runtime.create_match(config, match_seed), null)
	if not (created is Dictionary and bool((created as Dictionary).get("ok", false))):
		return _as_reject(created, "create_match refused the configuration")
	return created

## Recover a match from an acknowledged checkpoint payload. V3.0 promises in-process
## recovery only (ADR 0003 §Scope); the durable match store is #78.
func recover_match(game_id: String, checkpoint_payload: Variant) -> Dictionary:
	var runtime := runtime_for(game_id)
	if runtime == null:
		return V3.reject(V3.REJECT_UNKNOWN_GAME, "no registered package for game_id")
	var recovered: Variant = _runtime_value(runtime.recover_match(checkpoint_payload), null)
	if not (recovered is Dictionary and bool((recovered as Dictionary).get("ok", false))):
		return _as_reject(recovered, "recover_match refused the checkpoint")
	return recovered

# --- Internals --------------------------------------------------------------

## Normalize an adapter's refusal: keep its own contract code when it returned one,
## otherwise attribute the failure to the adapter. This is why the core never has to
## interpret adapter-specific error text.
static func _as_reject(value: Variant, fallback_detail: String) -> Dictionary:
	if value is Dictionary and (value as Dictionary).has("code"):
		return value
	return V3.reject(V3.REJECT_ADAPTER_REJECTED, fallback_detail)

## Extract an adapter-owned value from a completed runtime call. Existing synchronous
## registry APIs remain compatible for the local runtime; execution owners use the
## AdapterRuntimeCall directly when a future runtime completes asynchronously.
static func _runtime_value(runtime_call: AdapterRuntimeCall, fallback: Variant) -> Variant:
	if runtime_call == null:
		return fallback
	var result := runtime_call.result_now()
	if not bool(result.get("ok", false)):
		return fallback
	return result.get("value", fallback)

static func _refuse(code: StringName, detail: String) -> Dictionary:
	return {"ok": false, "code": String(code), "detail": detail}

## Membership by string equality. Descriptor entries may be StringName or String
## (GDScript literals differ across call sites); identity comparison must not depend
## on which the adapter author happened to write.
static func _lists_value(list: Variant, value: String) -> bool:
	if not list is Array:
		return false
	for entry: Variant in list:
		if String(entry) == value:
			return true
	return false

static func _string_list(list: Variant) -> Array:
	var result: Array = []
	if not list is Array:
		return result
	for entry: Variant in list:
		result.append(String(entry))
	return result
