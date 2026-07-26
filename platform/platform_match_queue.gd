class_name PlatformMatchQueue
extends RefCounted

## Waiting queue for Match Platform Core (issue #75, Epic #73).
##
## Holds peers that asked to play while the server had no room for them, in arrival
## order, and retries them as capacity frees up. The queue owns *ordering and
## fairness*; it does not own *placement policy* — which room a waiting peer belongs
## in is a game decision, so `drain` delegates that to a caller-supplied resolver.
##
## Two properties matter and are easy to get wrong:
##
##   - **Arrival order is preserved.** `drain` keeps unseated entries in their original
##     relative order, so a peer cannot be overtaken by a later arrival just because
##     the earlier one's preferred room was momentarily full.
##   - **One entry per peer.** A client that re-sends its join must not accumulate
##     queue slots; a second enqueue for a peer already waiting is refused rather than
##     appended, which also keeps reported positions honest.
##
## `options` is an opaque bag the caller round-trips through the queue untouched — the
## queue never reads inside it.

## peer_id-keyed entries in arrival order: `[{peer_id, options}]`.
var entries: Array[Dictionary] = []

func size() -> int:
	return entries.size()

func is_empty() -> bool:
	return entries.is_empty()

func has(peer_id: int) -> bool:
	return entries.any(func(entry: Dictionary) -> bool: return int(entry.peer_id) == peer_id)

## Append a waiting peer. Returns false when that peer is already queued, so the
## caller can tell a genuine enqueue from a duplicate request.
func enqueue(peer_id: int, options: Dictionary = {}) -> bool:
	if has(peer_id):
		return false
	entries.append({"peer_id": peer_id, "options": options})
	return true

## Remove a peer, returning whether it was queued. Called on leave and on disconnect —
## a queued peer that vanishes must not hold a position.
func remove(peer_id: int) -> bool:
	var before := entries.size()
	entries = entries.filter(func(entry: Dictionary) -> bool: return int(entry.peer_id) != peer_id)
	return entries.size() != before

## 1-based queue position, or 0 when not queued.
func position(peer_id: int) -> int:
	for index in entries.size():
		if int(entries[index].peer_id) == peer_id:
			return index + 1
	return 0

## Retry every waiting peer in arrival order. `resolver` is called as
## `resolver(peer_id, options) -> bool` and returns true when the entry should leave
## the queue — either because it was seated or because the peer is gone. Entries it
## refuses stay queued in place.
##
## The resolver returning "remove" for both outcomes is deliberate: the queue must not
## have to distinguish "seated" from "disappeared", because only the caller knows how
## to tell, and conflating them here would strand dead entries at the front forever.
func drain(resolver: Callable) -> int:
	if entries.is_empty():
		return 0
	var remaining: Array[Dictionary] = []
	var removed := 0
	for entry: Dictionary in entries:
		if bool(resolver.call(int(entry.peer_id), entry.options as Dictionary)):
			removed += 1
		else:
			remaining.append(entry)
	entries = remaining
	return removed

## Visit every waiting peer with its current position and the queue total, as
## `notifier(peer_id, position, total)`. Used to push queue-position updates after any
## mutation; the queue does not know how a caller delivers them.
func each_position(notifier: Callable) -> void:
	var total := entries.size()
	for index in total:
		notifier.call(int(entries[index].peer_id), index + 1, total)
