class_name PlatformSlotBook
extends RefCounted

## Seat occupancy for one room, in Match Platform Core (issue #75, Epic #73).
##
## The book tracks who occupies which slot, who is currently connected, and which
## vacated slots are still *reserved* for a returning player. Slot identifiers are
## opaque strings the adapter declared in its `slot_descriptors()`; the book compares
## them for equality and never interprets them, which is what lets one implementation
## seat a two-seat game and a many-seat game alike.
##
## What a *vacant* slot means is likewise the adapter's business. The book only says
## "nobody occupies this"; whether that becomes an AI stand-in, an empty chair, or a
## forfeit is a game decision made above this layer.
##
## ## The three states a slot moves through, and why the middle one exists
##
##   1. **vacant** — no occupant.
##   2. **occupied, connected** — an occupant with a live transport connection.
##   3. **occupied, disconnected** — the occupant's socket dropped, but the slot is
##      held for them until the grace period expires.
##
## State 3 is the whole reason this is a book and not a dictionary of peer ids. A
## dropped connection is usually a transient network event, not a departure; releasing
## the slot immediately would make a two-second outage indistinguishable from quitting
## and would hand the seat to someone else mid-match. The reservation is keyed on the
## resume token, so only the original occupant can reclaim it.
##
## ## Half-open connections
##
## A peer can reappear with a valid token while the server still believes the old
## socket is live — the transport has not yet noticed the old connection died. A valid
## token proves seat ownership, so `resume` hands the slot to the new peer and reports
## the old one as *evicted* for the caller to disconnect. Refusing the resume instead
## would lock a player out of their own seat for the entire grace period.

## Roles the book itself distinguishes. Everything finer-grained (which slot may hold
## which kind of participant) belongs to the adapter's slot policy.
const ROLE_PLAYER := "player"
const ROLE_SPECTATOR := "spectator"

## Sentinel for "no peer" and "not disconnected". Kept explicit so an absent value is
## never confused with peer 0 or tick 0.
const NO_PEER := -1
const NEVER := -1

## slot_id -> seat Dictionary:
## `{slot, occupied, connected, peer_id, token, disconnected_tick}`.
var seats: Dictionary = {}

## peer_id -> true for non-occupying observers. Spectators hold no slot and are never
## reserved across a disconnect: there is nothing to hold.
var spectators: Dictionary = {}

## Slot ids in declaration order. Order is load-bearing: when a joiner expresses no
## preference, the first free slot in *declaration* order is assigned, so seating is
## reproducible rather than dependent on Dictionary iteration.
var _slot_order: Array[String] = []

## `slot_ids` are the opaque identifiers from the adapter's slot descriptors, in the
## order the adapter declared them.
func _init(slot_ids: Array = []) -> void:
	for slot_id: Variant in slot_ids:
		var key := String(slot_id)
		if seats.has(key):
			continue
		_slot_order.append(key)
		seats[key] = vacant_seat(key)

## A seat with no occupant. Static so a caller holding only a slot id can build the
## same shape when it needs to force a slot empty.
static func vacant_seat(slot_id: String) -> Dictionary:
	return {
		"slot": slot_id, "occupied": false, "connected": false,
		"peer_id": NO_PEER, "token": "", "disconnected_tick": NEVER,
	}

func slot_ids() -> Array[String]:
	return _slot_order.duplicate()

func has_slot(slot_id: String) -> bool:
	return seats.has(slot_id)

# --- Claiming ---------------------------------------------------------------

## True when at least one slot has no occupant. A slot held by a disconnected occupant
## counts as taken — that reservation is exactly what the grace period protects.
func has_free_slot() -> bool:
	return not first_free_slot().is_empty()

## First unoccupied slot in declaration order, or `""`.
func first_free_slot() -> String:
	for slot_id: String in _slot_order:
		if not bool(seats[slot_id].occupied):
			return slot_id
	return ""

## Seat a peer, honouring `preferred_slot` when it is a real and free slot and falling
## back to the first free one otherwise. Returns `{ok: true, slot}` or
## `{ok: false, reason: "room_full"}`.
##
## `token` is the resume token minted for this connection; storing it here is what
## makes the seat reclaimable later.
func claim(peer_id: int, token: String, preferred_slot := "") -> Dictionary:
	var slot_id := preferred_slot
	if not seats.has(slot_id) or bool(seats[slot_id].occupied):
		slot_id = first_free_slot()
	if slot_id.is_empty():
		return {"ok": false, "reason": "room_full"}
	seats[slot_id] = {
		"slot": slot_id, "occupied": true, "connected": true,
		"peer_id": peer_id, "token": token, "disconnected_tick": NEVER,
	}
	return {"ok": true, "slot": slot_id}

## Reclaim a reserved slot with its resume token. Returns
## `{ok: true, slot, evicted}` — `evicted` being the peer id of a half-open
## predecessor the caller should disconnect, or `NO_PEER`. A token that matches no
## seat returns `{ok: false, reason: "resume_not_found"}` and changes nothing.
func resume(token: String, peer_id: int) -> Dictionary:
	if token.is_empty():
		return {"ok": false, "reason": "resume_not_found"}
	for slot_id: String in _slot_order:
		var seat: Dictionary = seats[slot_id]
		if not bool(seat.occupied) or String(seat.token) != token:
			continue
		var evicted := NO_PEER
		if bool(seat.connected) and int(seat.peer_id) != peer_id and int(seat.peer_id) > 0:
			evicted = int(seat.peer_id)
		seat.connected = true
		seat.peer_id = peer_id
		seat.disconnected_tick = NEVER
		return {"ok": true, "slot": slot_id, "evicted": evicted}
	return {"ok": false, "reason": "resume_not_found"}

# --- Releasing --------------------------------------------------------------

## Mark a peer's connection as gone at `now_tick`, keeping its slot reserved, or drop
## it from the spectator set. Returns what was released:
## `{role: "player", slot, token}`, `{role: "spectator"}`, or `{}` when the peer held
## nothing. The caller needs the token to know which reservation now exists.
func release(peer_id: int, now_tick: int) -> Dictionary:
	if spectators.erase(peer_id):
		return {"role": ROLE_SPECTATOR}
	for slot_id: String in _slot_order:
		var seat: Dictionary = seats[slot_id]
		if bool(seat.occupied) and int(seat.peer_id) == peer_id:
			seat.connected = false
			seat.peer_id = NO_PEER
			seat.disconnected_tick = now_tick
			return {"role": ROLE_PLAYER, "slot": slot_id, "token": String(seat.token)}
	return {}

## Force a slot empty, discarding any reservation. This is the *deliberate departure*
## path: a player who explicitly leaves has forfeited their seat, so holding it for
## the grace period would only keep the room from filling.
func vacate(slot_id: String) -> bool:
	if not seats.has(slot_id):
		return false
	seats[slot_id] = vacant_seat(slot_id)
	return true

## Expire every reservation older than `grace_ticks`, returning the slot ids that were
## freed so the caller can react (hand the seat to a stand-in, announce it, …).
func expire_reservations(now_tick: int, grace_ticks: int) -> Array[String]:
	var expired: Array[String] = []
	for slot_id: String in _slot_order:
		var seat: Dictionary = seats[slot_id]
		if not bool(seat.occupied) or bool(seat.connected):
			continue
		if int(seat.disconnected_tick) < 0:
			continue
		if now_tick - int(seat.disconnected_tick) >= grace_ticks:
			seats[slot_id] = vacant_seat(slot_id)
			expired.append(slot_id)
	return expired

# --- Spectators -------------------------------------------------------------

func add_spectator(peer_id: int) -> void:
	spectators[peer_id] = true

func is_spectator(peer_id: int) -> bool:
	return spectators.has(peer_id)

# --- Queries ----------------------------------------------------------------

## Slot a *connected* peer occupies, or `""`. A reserved-but-disconnected seat
## deliberately reports nothing: its occupant cannot act until it returns.
func slot_for_peer(peer_id: int) -> String:
	for slot_id: String in _slot_order:
		var seat: Dictionary = seats[slot_id]
		if bool(seat.occupied) and bool(seat.connected) and int(seat.peer_id) == peer_id:
			return slot_id
	return ""

func has_peer(peer_id: int) -> bool:
	return not slot_for_peer(peer_id).is_empty() or spectators.has(peer_id)

## Every peer that can receive traffic for this room: connected occupants plus
## spectators. Slots are appended in declaration order after the spectator set so the
## list is stable across calls.
func connected_peer_ids() -> Array:
	var result: Array = spectators.keys()
	for slot_id: String in _slot_order:
		var seat: Dictionary = seats[slot_id]
		if bool(seat.occupied) and bool(seat.connected):
			result.append(int(seat.peer_id))
	return result

## Occupied slots, including those merely reserved across a disconnect.
func occupied_count() -> int:
	var count := 0
	for slot_id: String in _slot_order:
		if bool(seats[slot_id].occupied):
			count += 1
	return count

## Occupied slots whose occupant is currently connected.
func connected_count() -> int:
	var count := 0
	for slot_id: String in _slot_order:
		var seat: Dictionary = seats[slot_id]
		if bool(seat.occupied) and bool(seat.connected):
			count += 1
	return count

## True when nothing holds this room open: no occupant (reserved or otherwise) and no
## spectator. Reserved seats keep a room alive on purpose, so a player mid-reconnect
## does not return to find their match reclaimed.
func is_abandoned() -> bool:
	return occupied_count() == 0 and spectators.is_empty()
