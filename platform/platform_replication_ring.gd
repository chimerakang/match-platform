class_name PlatformReplicationRing
extends RefCounted

## Acked-baseline state replication for one room, in Match Platform Core (issue #75,
## Epic #73).
##
## A room broadcasts incremental state far more often than full state. An increment is
## only applicable if the receiver holds the exact baseline it was diffed against, so
## the authoritative side must remember, per peer, *which baseline that peer actually
## has* — and must keep enough recent baselines around to build a diff from any of
## them. That bookkeeping is this class. The baseline payloads themselves are opaque:
## the ring stores and hands them back, and never looks inside.
##
## ## Why a ring, and why it is bounded
##
## Baselines are kept for a bounded window of recent ticks. Unbounded history would
## grow without limit for the room's lifetime; too short a window and any peer whose
## acknowledgement is delayed by ordinary latency falls out of it and needs full state.
## The window is the tolerance for round-trip delay, expressed in ticks.
##
## ## Acknowledged vs optimistic baselines
##
## A peer that reports what it has applied gets diffs from its *confirmed* baseline, so
## a coalesced or lost increment never forces a repair while the confirmed baseline is
## still in the window. A peer that never reports is advanced optimistically to the
## last tick sent to it — correct over an ordered, reliable transport, and the only
## thing that can be assumed about a client that says nothing.
##
## The first acknowledgement is treated as ground truth even when it is *older* than
## the optimistic guess, because it is the first real evidence of what the peer holds.
## Afterwards the confirmed baseline only moves forward.
##
## ## Repair, and why it has a cooldown
##
## When a peer's baseline is gone, the only fix is full state. Full state is by far the
## most expensive frame a room emits, and the events that cause a lost baseline —
## latency spikes, packet loss — arrive in bursts and affect many peers at once.
## Without a per-peer cooldown, one bad network moment turns into a full-state storm
## that makes the congestion worse. A peer inside its cooldown is skipped instead;
## it stays behind for a few more ticks and recovers on the next attempt.
##
## ## Externally-owned baselines
##
## When the authoritative core keeps its own columnar baseline history (and can diff
## against it directly), storing a second copy here would double the cost of every
## broadcast for no benefit. In that mode the ring mirrors only the tick keys, using
## the identical eviction rule, so baseline resolution still works while the payloads
## live exactly once.

## Group keys returned by `resolve_group`. An integer key is a shared baseline tick —
## every peer under it receives the same increment.
##
## `FULL_SCHEDULED` is the periodic full-state broadcast; `FULL_REPAIR` is a peer that
## lost its baseline; `SKIP` sends nothing this round. The two full-state keys are
## distinguished because only the repair path is worth counting as a repair.
const GROUP_FULL_SCHEDULED := "snap"
const GROUP_FULL_REPAIR := "full"
const GROUP_SKIP := "skip"

## Sentinel for "this peer has no usable baseline".
const NO_BASELINE := -1

## Ticks of baseline history to retain. Sized from tolerable round-trip delay.
var history_ticks: int

## Minimum ticks between full-state repairs for the same peer.
var resync_cooldown_ticks: int

## True when the authoritative core owns the baseline payloads and this ring mirrors
## only their tick keys.
var external_baselines: bool

## Monotonically increasing broadcast sequence, stamped on outgoing state so a
## receiver can detect a gap it never saw.
var sequence := 0

## Lifetime counters. Full payloads and repairs are the expensive events, so they are
## counted separately from ordinary increments.
var full_payloads_sent := 0
var repair_requests := 0
var rejected_acks := 0

## peer_id -> the baseline tick increments are currently diffed from.
var peer_baseline: Dictionary = {}

## peer_id -> whether this peer has ever acknowledged. Decides confirmed vs optimistic.
var peer_acked: Dictionary = {}

## peer_id -> tick of the last full payload sent, for the repair cooldown.
var peer_last_full_tick: Dictionary = {}

## peer_id -> newest tick placed on this peer's outbound path. An acknowledgement
## beyond it describes state the peer was never sent, so it is refused: accepting it
## would pin the baseline to a tick the peer cannot possibly hold, and every later
## increment would be undecodable.
var peer_last_sent_tick: Dictionary = {}

var _entries: Array[Dictionary] = []
var _ticks: Array[int] = []

func _init(retained_ticks: int, cooldown_ticks: int, externally_owned := false) -> void:
	history_ticks = maxi(1, retained_ticks)
	resync_cooldown_ticks = maxi(0, cooldown_ticks)
	external_baselines = externally_owned

# --- Baseline history -------------------------------------------------------

## Drop all history and reset the broadcast sequence. Called when the match restarts:
## every previously-recorded baseline describes a world that no longer exists, so
## keeping any of it could only produce an increment against the wrong state.
func reset() -> void:
	_entries = []
	_ticks = []
	sequence = 0

## Record a baseline at `tick`. `payload` is stored only when this ring owns the
## payloads; in externally-owned mode just the tick key is mirrored.
##
## Re-recording the same tick replaces it rather than appending, so a tick recorded
## twice (a join snapshot on a tick that is also a broadcast tick) cannot leave two
## disagreeing entries under one key.
func record(tick: int, payload: Dictionary = {}) -> void:
	if external_baselines:
		if _ticks.is_empty() or _ticks[-1] != tick:
			_ticks.append(tick)
		_evict_ticks(tick)
		return
	if not _entries.is_empty() and int(_entries[-1].tick) == tick:
		_entries[-1] = {"tick": tick, "payload": payload}
	else:
		_entries.append({"tick": tick, "payload": payload})
	var cutoff := tick - history_ticks
	while _entries.size() > 1 and int(_entries[0].tick) < cutoff:
		_entries.pop_front()

## Eviction for the mirrored tick keys. Identical rule to the payload path so the
## mirror and the external history can never disagree about which baselines exist.
func _evict_ticks(tick: int) -> void:
	var cutoff := tick - history_ticks
	while _ticks.size() > 1 and _ticks[0] < cutoff:
		_ticks.pop_front()

func has_baseline(tick: int) -> bool:
	if external_baselines:
		return _ticks.has(tick)
	for entry: Dictionary in _entries:
		if int(entry.tick) == tick:
			return true
	return false

## The stored payload for a tick, or `{}`. Always `{}` in externally-owned mode — the
## caller asks the authoritative core there.
func baseline(tick: int) -> Dictionary:
	for entry: Dictionary in _entries:
		if int(entry.tick) == tick:
			return entry.payload
	return {}

func baseline_ticks() -> Array[int]:
	if external_baselines:
		return _ticks.duplicate()
	var result: Array[int] = []
	for entry: Dictionary in _entries:
		result.append(int(entry.tick))
	return result

func size() -> int:
	return _ticks.size() if external_baselines else _entries.size()

## Advance and return the broadcast sequence for a new round.
func next_sequence() -> int:
	sequence += 1
	return sequence

# --- Per-peer state ---------------------------------------------------------

## Adopt a full payload at `tick` as this peer's baseline, resetting its acknowledgement
## state. Used for join, resume and repair: the peer now demonstrably holds exactly
## this state, so it is the one baseline that needs no confirmation.
func adopt_full(peer_id: int, tick: int, now_tick: int) -> void:
	peer_baseline[peer_id] = tick
	peer_acked[peer_id] = false
	peer_last_full_tick[peer_id] = now_tick
	peer_last_sent_tick[peer_id] = tick
	full_payloads_sent += 1

## Forget a departed peer, so its bookkeeping cannot accumulate for the room's life.
func forget_peer(peer_id: int) -> void:
	peer_baseline.erase(peer_id)
	peer_acked.erase(peer_id)
	peer_last_full_tick.erase(peer_id)
	peer_last_sent_tick.erase(peer_id)

## Record a peer's report of the newest tick it has fully applied. Returns false when
## the report is refused (and counts it): a negative tick, or one beyond what was
## actually sent to that peer.
##
## An acknowledgement whose baseline has already aged out is *accepted* as evidence
## that the peer acknowledges at all, but does not move the baseline — the next
## broadcast falls through to a cooldown-gated repair instead.
func apply_ack(peer_id: int, ack_tick: int) -> bool:
	if ack_tick < 0 or ack_tick > int(peer_last_sent_tick.get(peer_id, NO_BASELINE)):
		rejected_acks += 1
		return false
	var first := not bool(peer_acked.get(peer_id, false))
	peer_acked[peer_id] = true
	if not has_baseline(ack_tick):
		return true
	if first or ack_tick > int(peer_baseline.get(peer_id, NO_BASELINE)):
		peer_baseline[peer_id] = ack_tick
	return true

## Count a peer's repair request and report whether it may be served now. A request
## inside the cooldown is counted (it is real load) but refused, which is what stops a
## burst of requests from amplifying into a full-state storm.
func request_repair(peer_id: int, now_tick: int) -> bool:
	repair_requests += 1
	return not _in_cooldown(peer_id, now_tick)

func _in_cooldown(peer_id: int, now_tick: int) -> bool:
	if not peer_last_full_tick.has(peer_id):
		return false
	return now_tick - int(peer_last_full_tick[peer_id]) < resync_cooldown_ticks

# --- Grouping ---------------------------------------------------------------

## Decide what a peer receives this round.
##
## Order matters: a scheduled full payload overrides everything (it is the periodic
## resynchronization point); an intentionally throttled peer is skipped before any
## work is done for it; a peer with a live baseline gets an increment; otherwise a
## repair, unless its cooldown says wait.
func resolve_group(peer_id: int, current_tick: int, now_tick: int, force_full: bool, throttled := false) -> Variant:
	if force_full:
		return GROUP_FULL_SCHEDULED
	if throttled:
		return GROUP_SKIP
	var base := resolve_baseline(peer_id, current_tick)
	if base >= 0:
		return base
	if _in_cooldown(peer_id, now_tick):
		return GROUP_SKIP
	return GROUP_FULL_REPAIR

## This peer's usable baseline tick, or `NO_BASELINE`. A baseline equal to the current
## tick is not usable: an increment from a tick to itself carries nothing.
func resolve_baseline(peer_id: int, current_tick: int) -> int:
	var candidate := int(peer_baseline.get(peer_id, NO_BASELINE))
	if candidate >= 0 and candidate < current_tick and has_baseline(candidate):
		return candidate
	return NO_BASELINE

static func is_full_group(key: Variant) -> bool:
	return key is String and (key == GROUP_FULL_SCHEDULED or key == GROUP_FULL_REPAIR)

## True when any group this round needs the full payload built. Lets a caller whose
## full payload is expensive to materialize decide *once* whether to pay for it.
static func groups_need_full(keys: Array, force_full: bool) -> bool:
	if force_full:
		return true
	for key: Variant in keys:
		if is_full_group(key):
			return true
	return false

## Move a group's peers forward after their payload was emitted.
##
## Peers that received full state adopt it as their baseline and restart their repair
## cooldown. Peers on an increment advance optimistically *only* if they have never
## acknowledged; an acknowledging peer's baseline moves solely on its own reports,
## which is the entire point of tracking acknowledgement.
func advance_group(key: Variant, peer_ids: Array, current_tick: int, now_tick: int) -> void:
	if key is String and key == GROUP_SKIP:
		return
	var full := is_full_group(key)
	for peer_id: Variant in peer_ids:
		var id := int(peer_id)
		peer_last_sent_tick[id] = current_tick
		if full:
			peer_baseline[id] = current_tick
			peer_last_full_tick[id] = now_tick
		elif not bool(peer_acked.get(id, false)):
			peer_baseline[id] = current_tick

# --- Telemetry --------------------------------------------------------------

## Approximate retained-payload size. Serializing the history is expensive, so it is
## computed only when explicitly requested and never on a broadcast path.
func estimate_bytes() -> int:
	var total := 0
	for entry: Dictionary in _entries:
		total += var_to_bytes(entry.payload).size()
	return total

func telemetry(include_bytes := false) -> Dictionary:
	return {
		"baseline_entries": size(),
		"baseline_bytes": estimate_bytes() if include_bytes else 0,
		"full_payloads_sent": full_payloads_sent,
		"repair_requests": repair_requests,
		"rejected_acks": rejected_acks,
	}
