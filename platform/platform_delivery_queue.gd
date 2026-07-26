class_name PlatformDeliveryQueue
extends RefCounted

## Outbound path for one room, in Match Platform Core (issue #75, Epic #73).
##
## Everything a room wants to send is queued here first and leaves in batches at
## flush time. The queue owns four transport concerns and no game concerns:
##
##   1. **Batching.** A tick can produce many small messages (acks, events, a state
##      payload). Sending each as its own frame multiplies per-frame overhead — header,
##      compression, syscall — by the message count. Queueing and flushing lets one
##      frame carry the whole tick's traffic.
##   2. **Delivery classes.** Messages are grouped by their reliability class before
##      encoding, so a droppable visual-effects batch is never welded into the same
##      frame as a reliable control batch and forced to inherit its guarantees.
##   3. **The size ceiling.** An encoded frame larger than the transport's limit would
##      be discarded *whole* at the far end, silently losing every message inside it.
##      The queue drops it here instead and counts it, so an oversized frame is a
##      visible metric rather than a mystery gap in the stream.
##   4. **Encode-once.** Peers sharing a payload and a wire version are encoded
##      together, so N peers watching the same match cost one encode, not N.
##
## The queue never reads a message. Serialization and delivery-class assignment come
## from an injected **codec** — the game's own, since only a game knows how its
## messages compress — and delivery is emitted as signals so the transport stays above
## this layer. That injection is what keeps the queue free of any protocol module
## reference while still producing the exact bytes a game's clients expect.
##
## The codec must expose:
##   - `delivery_groups(messages: Array) -> Array` of `{reliability, messages}`
##   - `encode_batches_for(messages: Array, protocol: int) -> Array[PackedByteArray]`

## One encoded frame destined for a single peer.
signal target_frame(peer_id: int, bytes: PackedByteArray, reliability: StringName)

## One encoded frame destined for several peers at once. Kept distinct from
## `target_frame` so a transport can use a real multicast path where it has one.
signal broadcast_frame(peer_ids: Array, bytes: PackedByteArray, reliability: StringName)

## Largest encoded frame the transport will carry. Frames above it are dropped and
## counted rather than sent to be discarded remotely.
var max_frame_bytes: int

## Monotonic counters for the room's lifetime. Deliberately plain integers updated in
## place: the outbound path runs every flush, so it must not allocate to measure
## itself. Percentiles belong in a benchmark harness, not here.
var frame_bytes_peak := 0
var rejected_frames := 0
var encode_usec := 0
var encode_frames := 0
var send_usec := 0

var _codec: Object
var _protocol_of: Callable
var _broadcast_outbox: Array[Dictionary] = []
var _target_outboxes: Dictionary = {}

## `protocol_of` maps a peer id to its negotiated wire version, so the queue can group
## peers by version without holding session state of its own.
func _init(codec: Object, max_bytes: int, protocol_of: Callable) -> void:
	_codec = codec
	max_frame_bytes = max_bytes
	_protocol_of = protocol_of

# --- Queueing ---------------------------------------------------------------

## Queue a message for one peer. Delivered at the next `flush_target`/`flush_targets`.
func enqueue_target(peer_id: int, message: Dictionary) -> void:
	var pending: Array = _target_outboxes.get(peer_id, [])
	pending.append(message)
	_target_outboxes[peer_id] = pending

## Queue a message every connected peer should receive this flush.
func enqueue_broadcast(message: Dictionary) -> void:
	_broadcast_outbox.append(message)

## Take and clear the shared broadcast messages. The caller combines them with the
## per-peer state payload each group can apply, which is why this is a *take* rather
## than a flush: only the caller knows how peers are grouped.
func take_broadcast() -> Array[Dictionary]:
	var shared := _broadcast_outbox
	_broadcast_outbox = []
	return shared

func pending_broadcast_count() -> int:
	return _broadcast_outbox.size()

func pending_target_count(peer_id: int) -> int:
	return (_target_outboxes.get(peer_id, []) as Array).size()

## Forget a peer's queued messages entirely — used when the peer leaves, so a
## departed peer's outbox cannot accumulate for the room's lifetime.
func drop_target(peer_id: int) -> void:
	_target_outboxes.erase(peer_id)

# --- Flushing ---------------------------------------------------------------

## Encode and emit everything queued for one peer, grouped by delivery class.
func flush_target(peer_id: int) -> void:
	var messages: Array = _target_outboxes.get(peer_id, [])
	_target_outboxes.erase(peer_id)
	if messages.is_empty():
		return
	for delivery: Dictionary in _codec.delivery_groups(messages):
		emit_frames([peer_id], delivery.messages, false, _protocol_for(peer_id), delivery.reliability)

## Flush every peer with queued messages. Iterating a key snapshot keeps this safe
## against a flush that queues further messages.
func flush_targets() -> void:
	for peer_id: Variant in _target_outboxes.keys():
		flush_target(int(peer_id))

## Encode `messages` once per wire version present in `peer_ids` and emit the frames.
## This is the encode-once path: peers that share a payload and a version share the
## encode, so a room with many observers pays for one.
func emit_grouped(peer_ids: Array, messages: Array, reliability: StringName) -> void:
	if peer_ids.is_empty() or messages.is_empty():
		return
	var by_protocol: Dictionary = {}
	for peer_id: Variant in peer_ids:
		(by_protocol.get_or_add(_protocol_for(int(peer_id)), []) as Array).append(int(peer_id))
	for protocol: Variant in by_protocol.keys():
		emit_frames(by_protocol[protocol], messages, true, int(protocol), reliability)

## Encode and emit one (peers × wire version × delivery class) frame set. Frames over
## the ceiling are dropped and counted; the rest update the peak and are emitted.
func emit_frames(peer_ids: Array, messages: Array, is_broadcast: bool, protocol: int, reliability: StringName) -> void:
	var encode_started := Time.get_ticks_usec()
	var encoded: Array = _codec.encode_batches_for(messages, protocol)
	encode_usec += Time.get_ticks_usec() - encode_started
	encode_frames += encoded.size()
	for bytes: PackedByteArray in encoded:
		if bytes.size() > max_frame_bytes:
			# Dropped here on purpose: an oversized frame would be discarded whole at
			# the far end, losing every message in it without a trace.
			rejected_frames += 1
			continue
		frame_bytes_peak = maxi(frame_bytes_peak, bytes.size())
		var send_started := Time.get_ticks_usec()
		if is_broadcast:
			broadcast_frame.emit(peer_ids, bytes, reliability)
		else:
			target_frame.emit(int(peer_ids[0]), bytes, reliability)
		send_usec += Time.get_ticks_usec() - send_started

func _protocol_for(peer_id: int) -> int:
	if not _protocol_of.is_valid():
		return 1
	return int(_protocol_of.call(peer_id))

# --- Telemetry --------------------------------------------------------------

func telemetry() -> Dictionary:
	return {
		"encode_usec": encode_usec, "encode_frames": encode_frames,
		"send_usec": send_usec, "frame_bytes_peak": frame_bytes_peak,
		"rejected_frames": rejected_frames,
	}
