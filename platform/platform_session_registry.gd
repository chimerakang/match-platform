class_name PlatformSessionRegistry
extends RefCounted

## Per-connection session store for Match Platform Core (issue #75, Epic #73).
##
## One session exists per connected peer, from the moment the transport reports a
## connection until it reports a disconnect. The session holds only platform state:
##
##   - **identity**: a server-minted resume token. The token is the *only* thing a
##     returning client presents to reclaim a seat, and it is generated here so a
##     client can never propose its own (a client-chosen token would let anyone name
##     someone else's seat).
##   - **admission**: a token-bucket rate limiter and a monotonic command sequence.
##     Both are per-session by construction, so one abusive peer cannot spend another
##     peer's budget or replay another peer's ordering.
##   - **placement**: which room this peer sits in, in what role, on which slot — all
##     opaque values assigned by an adapter's slot policy and merely *recorded* here.
##
## The store never learns what a slot means. `slot` is whatever string the adapter
## returned from `validate_join`; the core compares it for equality and hands it back.
## That is what lets the same store seat a two-player abstract-strategy game and a
## many-slot game without a line changing (#73 boundary).

## Protocol version assumed before negotiation. Version numbering belongs to the
## codec/transport layer above; the store only clamps and remembers.
const DEFAULT_PROTOCOL := 1

## Role for a peer that is connected but not yet placed in a room. Kept as an
## explicit value rather than an empty string so "never seated" and "seat cleared"
## are the same observable state.
const ROLE_UNSEATED := "unseated"

## peer_id -> session Dictionary. Exposed directly because the surrounding server
## and its tests treat it as the authoritative session table; every mutation still
## goes through the methods below so the invariants stay in one place.
var sessions: Dictionary = {}

var _rate_per_second: float
var _rate_burst: float
var _max_protocol: int

## `commands_per_second` and `burst` are the admission budget; `protocol_ceiling` is
## the highest wire version this build can speak. All three are injected because they
## are deployment/codec policy, not platform invariants.
func _init(commands_per_second: float, burst: float, protocol_ceiling: int = DEFAULT_PROTOCOL) -> void:
	_rate_per_second = maxf(0.0, commands_per_second)
	_rate_burst = maxf(0.0, burst)
	_max_protocol = maxi(DEFAULT_PROTOCOL, protocol_ceiling)

# --- Lifecycle --------------------------------------------------------------

## Open a session for a freshly connected peer and mint its resume token. The bucket
## starts full so a legitimate client's opening burst (hello + join + first commands)
## is never throttled. Re-opening an existing peer replaces the session outright,
## which is the correct reading of "the transport says this peer just connected".
func open(peer_id: int) -> Dictionary:
	var session := {
		"token": mint_token(peer_id),
		"room_id": 0, "role": ROLE_UNSEATED, "slot": "",
		"last_seq": 0, "tokens": _rate_burst, "rate_at": Time.get_ticks_msec(),
		"joined": false, "proto": DEFAULT_PROTOCOL,
	}
	sessions[peer_id] = session
	return session

## Forget a peer, returning its last session (or `{}`). The caller needs the returned
## placement to tell the room which seat just went quiet — the session is gone, but
## the seat it occupied may still be reserved for a reconnect.
func close(peer_id: int) -> Dictionary:
	var session: Dictionary = sessions.get(peer_id, {})
	sessions.erase(peer_id)
	return session

func has(peer_id: int) -> bool:
	return sessions.has(peer_id)

func session(peer_id: int) -> Dictionary:
	return sessions.get(peer_id, {})

func peer_ids() -> Array:
	return sessions.keys()

func size() -> int:
	return sessions.size()

# --- Identity ---------------------------------------------------------------

func token(peer_id: int) -> String:
	return String(sessions.get(peer_id, {}).get("token", ""))

## Bind a peer to an existing token after a successful resume. The reclaiming peer
## adopts the *seat's* token rather than keeping its own freshly minted one, so a
## further reconnect from the same client still resolves to the same seat.
func adopt_token(peer_id: int, resume_token: String) -> void:
	if sessions.has(peer_id):
		sessions[peer_id].token = resume_token

## A resume token cryptographically bound to nothing a client controls. Random bytes
## dominate; peer id and a microsecond stamp only guarantee distinctness if the RNG
## ever repeats. Never derived from a client-supplied value.
static func mint_token(peer_id: int) -> String:
	var random := Crypto.new().generate_random_bytes(24).hex_encode()
	return ("%s:%s:%s" % [random, peer_id, Time.get_ticks_usec()]).sha256_text()

# --- Negotiated wire version ------------------------------------------------

func protocol(peer_id: int) -> int:
	return int(sessions.get(peer_id, {}).get("proto", DEFAULT_PROTOCOL))

## Clamp a client's requested wire version into what this build supports and remember
## it. Clamping rather than rejecting keeps an older or newer client usable at the
## best shared version — the negotiated value is returned so the caller can echo it.
func negotiate_protocol(peer_id: int, requested: int) -> int:
	var selected := clampi(requested, DEFAULT_PROTOCOL, _max_protocol)
	if sessions.has(peer_id):
		sessions[peer_id].proto = selected
	return selected

# --- Admission --------------------------------------------------------------

## Spend one admission token, refilling by elapsed wall time first. Returns false
## when the peer is over budget.
##
## Every inbound frame must pay, including malformed ones: if only well-formed frames
## were charged, garbage traffic would bypass the limiter entirely and could spend
## unbounded CPU on validation and refusal replies.
func consume_rate_token(peer_id: int) -> bool:
	if not sessions.has(peer_id):
		return false
	var session: Dictionary = sessions[peer_id]
	var now := Time.get_ticks_msec()
	var elapsed := maxf(0.0, float(now - int(session.rate_at)) / 1000.0)
	session.rate_at = now
	session.tokens = minf(_rate_burst, float(session.tokens) + elapsed * _rate_per_second)
	if float(session.tokens) < 1.0:
		return false
	session.tokens = float(session.tokens) - 1.0
	return true

func available_rate_tokens(peer_id: int) -> float:
	return float(sessions.get(peer_id, {}).get("tokens", 0.0))

## Accept a command sequence only if it strictly advances this session's counter, and
## record it. Duplicates and reordered replays are refused, which is what makes a
## retransmitting client safe: the same sequence can never be applied twice.
func accept_sequence(peer_id: int, sequence: int) -> bool:
	if not sessions.has(peer_id):
		return false
	var session: Dictionary = sessions[peer_id]
	if sequence <= int(session.last_seq):
		return false
	session.last_seq = sequence
	return true

func last_sequence(peer_id: int) -> int:
	return int(sessions.get(peer_id, {}).get("last_seq", 0))

# --- Placement --------------------------------------------------------------

func room_id(peer_id: int) -> int:
	return int(sessions.get(peer_id, {}).get("room_id", 0))

func role(peer_id: int) -> String:
	return String(sessions.get(peer_id, {}).get("role", ROLE_UNSEATED))

## The opaque slot identifier an adapter assigned, or `""` when unseated. The store
## never interprets it.
func slot(peer_id: int) -> String:
	return String(sessions.get(peer_id, {}).get("slot", ""))

func is_seated(peer_id: int) -> bool:
	return bool(sessions.get(peer_id, {}).get("joined", false))

## Record where a peer now sits. `joined` is derived from the room id rather than
## passed in, so "has a room" and "is seated" cannot drift apart.
func assign_seat(peer_id: int, room: int, seat_role: String, seat_slot: String) -> void:
	if not sessions.has(peer_id):
		return
	var session: Dictionary = sessions[peer_id]
	session.room_id = room
	session.role = seat_role
	session.slot = seat_slot
	session.joined = room != 0

func clear_seat(peer_id: int) -> void:
	assign_seat(peer_id, 0, ROLE_UNSEATED, "")
