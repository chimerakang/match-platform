class_name PlatformRoomRegistry
extends RefCounted

## Room lifecycle and code namespaces for Match Platform Core (issue #75, Epic #73).
##
## A *room* is one running authoritative match. The registry owns everything about a
## room that is not the match itself: its id, its join code, the server's capacity
## limit, the deterministic seed it was allocated, and its removal when empty. The
## match object attached to a room is opaque — the registry never calls into it, so
## it cannot come to depend on any game's lifecycle.
##
## ## Two code namespaces, and why they cannot be one
##
## Join codes serve two different purposes and must not be forgeable into each other:
##
##   - **Public codes** are what a player types to join a friend. They live in a short
##     alphanumeric space precisely so they are typeable.
##   - **Reserved codes** identify rooms the server allocated on a player's behalf.
##     They must be unguessable — a player who could type one could walk into an
##     arbitrary in-progress match — so they carry a prefix that public-code
##     validation *rejects*, and enough random bytes that enumeration is hopeless.
##
## `normalize_public_code` therefore refuses anything containing the reserved prefix's
## separator, while `normalize_lookup_code` accepts both (a spectator legitimately
## looks up a server-allocated room). That asymmetry is the security property; the
## tests assert it directly.

## Separator that marks the reserved namespace. Public codes are alphanumeric only, so
## its presence alone makes a code unenterable by hand.
const RESERVED_PREFIX := "Q-"

## Random bytes behind a reserved code (hex-encoded, so twice this many characters).
const RESERVED_CODE_BYTES := 4

## Random bytes behind a public code. Short enough to read aloud; collisions are
## resolved by regeneration, not by accepting a duplicate.
const PUBLIC_CODE_BYTES := 3

const MIN_PUBLIC_CODE_LENGTH := 3
const MAX_PUBLIC_CODE_LENGTH := 12

signal room_closed(room_id: int)

## room_id -> opaque match/room object.
var rooms: Dictionary = {}

## Maximum concurrent rooms this server will host. A hard cap rather than a soft
## target: refusing to open room N+1 keeps every existing match at full tick budget,
## which is strictly better than degrading all of them.
var max_rooms := 4

var _next_room_id := 1
var _next_seed: int
var _codes: Dictionary = {}

func _init(room_capacity := 4, first_seed := 1) -> void:
	max_rooms = maxi(1, room_capacity)
	_next_seed = first_seed

# --- Capacity & allocation --------------------------------------------------

func has_capacity() -> bool:
	return rooms.size() < max_rooms

func size() -> int:
	return rooms.size()

## Reserve an id, a join code and a deterministic seed for a new room, or return `{}`
## when the server is at capacity. Nothing is attached yet: the caller builds its
## match with the returned seed and then calls `attach`, so a match that fails to
## construct never leaves a half-registered room behind.
##
## Seeds are allocated monotonically. Every room therefore gets a distinct seed
## without the platform ever consulting wall-clock or a global RNG — the #36
## determinism contract forbids both on the authoritative path.
func allocate(preferred_code := "") -> Dictionary:
	if not has_capacity():
		return {}
	var code := preferred_code if not preferred_code.is_empty() else mint_reserved_code()
	if _codes.has(code):
		return {}
	var room_id := _next_room_id
	_next_room_id += 1
	_next_seed += 1
	return {"room_id": room_id, "code": code, "seed": _next_seed}

## Bind a constructed match object to a previously allocated id/code.
func attach(room_id: int, code: String, room: Object) -> void:
	rooms[room_id] = room
	_codes[code] = room_id

func has_room(room_id: int) -> bool:
	return rooms.has(room_id)

func room(room_id: int) -> Object:
	return rooms.get(room_id, null)

## Room ids in allocation order, so any iteration the server exposes is deterministic.
func room_ids() -> Array:
	var ids: Array = rooms.keys()
	ids.sort()
	return ids

func room_list() -> Array:
	var result: Array = []
	for room_id: Variant in room_ids():
		result.append(rooms[room_id])
	return result

## Drop a room and free its code for reuse. Emits `room_closed` so bookkeeping outside
## the registry (telemetry, logs) can react without the registry knowing about it.
func close(room_id: int) -> bool:
	if not rooms.has(room_id):
		return false
	rooms.erase(room_id)
	for code: Variant in _codes.keys():
		if int(_codes[code]) == room_id:
			_codes.erase(code)
	room_closed.emit(room_id)
	return true

# --- Code namespaces --------------------------------------------------------

func code_taken(code: String) -> bool:
	return _codes.has(code)

## Room id for a join code, or 0. Codes are canonicalized by the `normalize_*`
## functions before they reach here.
func room_id_for_code(code: String) -> int:
	return int(_codes.get(code, 0))

func room_for_code(code: String) -> Object:
	return rooms.get(room_id_for_code(code), null)

func code_for_room(room_id: int) -> String:
	for code: Variant in _codes.keys():
		if int(_codes[code]) == room_id:
			return String(code)
	return ""

## Canonicalize player-typed input, or `""` when it is not a legal public code.
## Uppercase alphanumeric only and length-bounded — which also means it can never
## match a reserved code, because the reserved prefix contains a separator character
## this function rejects.
static func normalize_public_code(code: String) -> String:
	var normalized := code.strip_edges().to_upper()
	if normalized.length() < MIN_PUBLIC_CODE_LENGTH or normalized.length() > MAX_PUBLIC_CODE_LENGTH:
		return ""
	for character in normalized:
		if not (character >= "A" and character <= "Z") and not (character >= "0" and character <= "9"):
			return ""
	return normalized

## Canonicalize a code for *lookup*, accepting both namespaces. A reserved code must
## match its exact shape (prefix plus the full hex body) so a partially guessed code
## is not silently widened into a public-code match.
static func normalize_lookup_code(code: String) -> String:
	var normalized := code.strip_edges().to_upper()
	var reserved_length := RESERVED_PREFIX.length() + RESERVED_CODE_BYTES * 2
	if normalized.begins_with(RESERVED_PREFIX) and normalized.length() == reserved_length:
		for character in normalized.substr(RESERVED_PREFIX.length()):
			if not (character >= "A" and character <= "F") and not (character >= "0" and character <= "9"):
				return ""
		return normalized
	return normalize_public_code(normalized)

## A code in the unguessable reserved namespace. Randomness comes from `Crypto`, not
## from any simulation RNG — this is a transport-layer identifier and must never draw
## from the deterministic stream a match replays from.
static func mint_reserved_code() -> String:
	return "%s%s" % [RESERVED_PREFIX, Crypto.new().generate_random_bytes(RESERVED_CODE_BYTES).hex_encode().to_upper()]

## A fresh player-enterable code that no live room already holds. Generated on the
## server so clients can neither collide nor infer allocation policy.
func mint_public_code() -> String:
	var code := ""
	while code.is_empty() or code_taken(code):
		code = Crypto.new().generate_random_bytes(PUBLIC_CODE_BYTES).hex_encode().to_upper()
	return code
