class_name MatchPlatformV3
extends RefCounted

## Match Platform V3 — frozen contract (issue #74, Epic #73).
##
## This module is the executable form of ADR 0003. It defines the generic,
## game-agnostic envelope that the platform core speaks and a pure validator for
## it. The platform NEVER inspects `payload`: it is an opaque, adapter-owned blob
## that the core only bounds by size and routes by envelope class. No game
## vocabulary — seat names, entity kinds, command names, terrain fields, mode
## selectors — may appear in this file or in any message the core validates; that is
## the non-negotiable boundary from #73, enforced by `tests/platform_core_test.gd`.
##
## What lives here (platform-owned): envelope shape, mandatory match identity,
## version/codec negotiation inputs, structured rejection codes, delivery-class
## ownership. What does NOT (adapter-owned): payload semantics, slot policy,
## command validation, state/checkpoint/delta/event construction, deterministic
## hash, replay, terminal result. See `MatchGameAdapter` below for that surface.

## Platform envelope version. Distinct from `game_version`, `adapter_version`,
## `content_hash`, and `codec_id` — those describe the game, this describes the
## transport contract. Bumping this is a platform-wide breaking change; adding a
## game or codec is not.
const ENVELOPE_VERSION := 3

## Repository release version. Its SemVer major is deliberately identical to
## ENVELOPE_VERSION: a Client Protocol V3 frontend consumes Match Platform 3.x.
## Minor and patch releases must remain compatible with the same V3 envelope.
const PLATFORM_VERSION := "3.0.0"
const PLATFORM_VERSION_MAJOR := 3
const WEBSOCKET_SUBPROTOCOL := "match-platform.v%d" % PLATFORM_VERSION_MAJOR

## True when a Match Platform SemVer belongs to this protocol generation.
## This intentionally checks the major only; compatible fixes and capabilities
## may ship as 3.x without forcing coordinated client/server deployment.
static func supports_platform_version(version: String) -> bool:
	var parts := version.trim_prefix("v").split(".")
	return parts.size() == 3 and parts[0].is_valid_int() \
		and parts[1].is_valid_int() and parts[2].is_valid_int() \
		and int(parts[0]) == PLATFORM_VERSION_MAJOR

## Maximum decoded envelope size the core will accept, payload included. The core
## bounds the payload by bytes only; it never parses inside it. Mirrors the legacy
## v1/v2 wire ceiling so a V3 frame rides the same transport limits during
## migration — the legacy constant is not referenced here, because a platform
## module may not name a game's protocol module (see `tests/platform_core_test.gd`).
const MAX_ENVELOPE_BYTES := 64 * 1024

# --- Message types ----------------------------------------------------------
# The game envelopes from #73 plus the generic #79 transport-control extension.
# RTC signaling is platform-owned and carries no game payload fields.

const HELLO := &"hello"
const WELCOME := &"welcome"
const JOIN := &"join"
const COMMAND := &"command"
const STATE := &"state"
const CHECKPOINT := &"checkpoint"
const EVENT := &"event"
const REJECT := &"reject"
const TRANSPORT_SELECT := &"transport_select"
const RTC_OFFER := &"rtc_offer"
const RTC_ANSWER := &"rtc_answer"
const RTC_ICE := &"rtc_ice"
const TRANSPORT_STATUS := &"transport_status"

const CLIENT_MESSAGES: Array[StringName] = [
	HELLO, JOIN, COMMAND, TRANSPORT_SELECT, RTC_ANSWER, RTC_ICE,
]
const SERVER_MESSAGES: Array[StringName] = [
	WELCOME, STATE, CHECKPOINT, EVENT, REJECT, RTC_OFFER, RTC_ICE, TRANSPORT_STATUS,
]

## Required fields per message type. Every value is a platform field; none names a
## game concept. `payload` is required where present but treated as opaque.
const REQUIRED_FIELDS := {
	HELLO: ["pv", "t", "protocol_versions", "game_id", "game_version", "content_hash", "codecs"],
	WELCOME: ["pv", "t", "selected_protocol", "game_id", "adapter_version", "selected_codec", "tick_rate", "capabilities"],
	JOIN: ["pv", "t", "match_selector", "role", "auth_context"],
	COMMAND: ["pv", "t", "match_id", "seq", "expected_tick", "codec_id", "payload"],
	STATE: ["pv", "t", "match_id", "tick", "base_tick", "seq", "codec_id", "payload"],
	CHECKPOINT: ["pv", "t", "match_id", "tick", "codec_id", "payload", "state_hash"],
	EVENT: ["pv", "t", "match_id", "tick", "reliability", "codec_id", "payload"],
	REJECT: ["pv", "t", "code"],
	TRANSPORT_SELECT: ["pv", "t", "match_id", "attempt_id", "transport"],
	RTC_OFFER: ["pv", "t", "match_id", "attempt_id", "sdp"],
	RTC_ANSWER: ["pv", "t", "match_id", "attempt_id", "sdp"],
	RTC_ICE: ["pv", "t", "match_id", "attempt_id", "media", "index", "candidate"],
	TRANSPORT_STATUS: ["pv", "t", "match_id", "attempt_id", "transport", "status"],
}

## Mandatory match-identity fields carried by the client's opening `hello`. The
## core rejects a mismatch on any of these BEFORE a player is seated (#73
## acceptance: "rejects unknown game/content/codec/version before match seating").
const IDENTITY_FIELDS: Array[StringName] = [&"game_id", &"game_version", &"content_hash"]

# --- Delivery classes (platform-owned) --------------------------------------
# Identical semantics to the #49 reliability matrix, restated as a generic
# contract. The platform decides delivery from the envelope class; the adapter
# only *declares* an event's class in the `reliability` field.
const RELIABLE := &"reliable"
const REPLACEABLE := &"replaceable"
const DROPPABLE := &"droppable"
const RELIABILITY_CLASSES: Array[StringName] = [RELIABLE, REPLACEABLE, DROPPABLE]

## Delivery class per generic message type. `command`/`checkpoint` are reliable
## control; `state` is replaceable (newest supersedes); `event` declares its own
## class in-band (an adapter marks pure-FX events droppable, control events
## reliable) so the core never inspects the payload to decide delivery.
const MESSAGE_RELIABILITY := {
	HELLO: RELIABLE, WELCOME: RELIABLE, JOIN: RELIABLE, REJECT: RELIABLE,
	COMMAND: RELIABLE, CHECKPOINT: RELIABLE, STATE: REPLACEABLE,
	TRANSPORT_SELECT: RELIABLE, RTC_OFFER: RELIABLE, RTC_ANSWER: RELIABLE,
	RTC_ICE: RELIABLE, TRANSPORT_STATUS: RELIABLE,
}

# --- Structured rejection codes ---------------------------------------------
# Every refusal carries exactly one stable code. Codes are the platform's, not a
# game's; an adapter maps its own validation failures onto these plus a free-form
# `detail`. Negotiation/identity failures precede seating; the rest are per-frame.
const REJECT_MALFORMED_ENVELOPE := &"malformed_envelope"
const REJECT_UNSUPPORTED_PROTOCOL := &"unsupported_protocol"
const REJECT_UNKNOWN_GAME := &"unknown_game"
const REJECT_UNSUPPORTED_GAME_VERSION := &"unsupported_game_version"
const REJECT_CONTENT_MISMATCH := &"content_hash_mismatch"
const REJECT_UNSUPPORTED_CODEC := &"unsupported_codec"
const REJECT_UNKNOWN_MATCH := &"unknown_match"
const REJECT_SLOT_UNAVAILABLE := &"slot_unavailable"
const REJECT_UNAUTHORIZED := &"unauthorized"
const REJECT_PAYLOAD_TOO_LARGE := &"payload_too_large"
const REJECT_SEQUENCE_VIOLATION := &"sequence_violation"
const REJECT_RATE_LIMITED := &"rate_limited"
const REJECT_ADAPTER_REJECTED := &"adapter_rejected"
const REJECT_UNSUPPORTED_TRANSPORT := &"unsupported_transport"

const REJECT_CODES: Array[StringName] = [
	REJECT_MALFORMED_ENVELOPE, REJECT_UNSUPPORTED_PROTOCOL, REJECT_UNKNOWN_GAME,
	REJECT_UNSUPPORTED_GAME_VERSION, REJECT_CONTENT_MISMATCH, REJECT_UNSUPPORTED_CODEC,
	REJECT_UNKNOWN_MATCH, REJECT_SLOT_UNAVAILABLE, REJECT_UNAUTHORIZED,
	REJECT_PAYLOAD_TOO_LARGE, REJECT_SEQUENCE_VIOLATION, REJECT_RATE_LIMITED,
	REJECT_ADAPTER_REJECTED,
	REJECT_UNSUPPORTED_TRANSPORT,
]

# --- Pure envelope validation -----------------------------------------------

## Structurally validate a decoded envelope against the frozen contract WITHOUT
## inspecting `payload`. Returns `{ok: true}` or `{ok: false, code: <reject>}`.
## This is the only structural gate the core applies before handing `payload` to
## the adapter; it proves the core stays opaque to game state.
static func validate_envelope(env: Variant, allowed: Array[StringName]) -> Dictionary:
	if not env is Dictionary:
		return _fail(REJECT_MALFORMED_ENVELOPE)
	var packet: Dictionary = env
	if int(packet.get("pv", 0)) != ENVELOPE_VERSION:
		return _fail(REJECT_UNSUPPORTED_PROTOCOL)
	var type := StringName(packet.get("t", ""))
	if not type in allowed or not REQUIRED_FIELDS.has(type):
		return _fail(REJECT_MALFORMED_ENVELOPE)
	for field: String in REQUIRED_FIELDS[type]:
		if not packet.has(field):
			return _fail(REJECT_MALFORMED_ENVELOPE)
	if type == REJECT and not StringName(packet.get("code", "")) in REJECT_CODES:
		return _fail(REJECT_MALFORMED_ENVELOPE)
	if type == EVENT and not StringName(packet.get("reliability", "")) in RELIABILITY_CLASSES:
		return _fail(REJECT_MALFORMED_ENVELOPE)
	return {"ok": true}

## Delivery class for a generic message. `event` declares its own class in-band;
## every other type is fixed by the contract. RELIABLE > REPLACEABLE > DROPPABLE.
static func reliability_of(packet: Dictionary) -> StringName:
	var type := StringName(packet.get("t", ""))
	if type == EVENT:
		var declared := StringName(packet.get("reliability", RELIABLE))
		return declared if declared in RELIABILITY_CLASSES else RELIABLE
	return MESSAGE_RELIABILITY.get(type, RELIABLE)

## Negotiate the shared platform protocol version. Returns the highest common
## version, or 0 when there is none (→ `unsupported_protocol`, refused pre-seat).
static func negotiate_protocol(client_versions: Array, server_versions: Array) -> int:
	var server_set := {}
	for version: Variant in server_versions:
		server_set[int(version)] = true
	var best := 0
	for candidate: Variant in client_versions:
		var value := int(candidate)
		if server_set.has(value) and value > best:
			best = value
	return best

## Negotiate a codec: first client-preferred id also offered by the adapter, in
## client order (client states preference; adapter states capability). Empty
## string when disjoint (→ `unsupported_codec`).
static func negotiate_codec(client_codecs: Array, adapter_codecs: Array) -> String:
	for candidate: Variant in client_codecs:
		if String(candidate) in adapter_codecs:
			return String(candidate)
	return ""

## Build a `reject` envelope with a stable code and optional free-form detail.
## `detail` is adapter/diagnostic text; it is never load-bearing for the client.
static func reject(code: StringName, detail: String = "") -> Dictionary:
	var packet := {"pv": ENVELOPE_VERSION, "t": String(REJECT), "code": String(code)}
	if not detail.is_empty():
		packet["detail"] = detail
	return packet

## Stamp a generic envelope with the platform version and message type. Callers
## pass only platform fields plus an opaque `payload`; the core adds `pv`/`t`.
static func envelope(type: StringName, fields: Dictionary = {}) -> Dictionary:
	var packet := fields.duplicate(true)
	packet["pv"] = ENVELOPE_VERSION
	packet["t"] = String(type)
	return packet

static func _fail(code: StringName) -> Dictionary:
	return {"ok": false, "code": String(code)}
