class_name PlatformTickScheduler
extends RefCounted

## Fixed-step scheduler for Match Platform Core (issue #75, Epic #73).
##
## Converts irregular real-time frame deltas into a whole number of fixed simulation
## ticks. The platform owns *when* to advance; an adapter owns what a tick does. This
## separation is what keeps determinism intact across single-player, dedicated server
## and replay: the tick count is a pure function of accumulated time and the
## configured rate, never of frame timing.
##
## Two policies live here because both are transport/deployment concerns rather than
## game rules:
##
##   - **Frame clamp.** A single delta contributes at most `MAX_FRAME_SECONDS`. Without
##     it, one long stall (GC pause, host suspend, debugger break) would release a
##     burst of hundreds of ticks in one frame, spiking the step budget and stalling
##     every connected peer at once. Clamping trades a small amount of catch-up for a
##     bounded worst-case frame.
##   - **Multiplier / deferred acceleration.** A harness can run a match faster than
##     real time, optionally only *after* an initial real-time window. That window
##     exists so latency and render behaviour can be asserted at true speed before the
##     remainder of a long match is fast-forwarded to its terminal state. Because
##     acceleration only changes how many ticks are released per frame — never what a
##     tick computes — an accelerated run reaches the same authoritative state.

## Longest real-time span a single frame may contribute.
const MAX_FRAME_SECONDS := 0.25

## Disabled sentinel for the deferred-acceleration threshold.
const NO_ACCELERATION := -1

var tick_seconds: float
var multiplier: float
var accelerate_after_ticks: int

## Ticks released since construction (or the last `reset()`), across all rooms. This
## is the counter the deferred-acceleration threshold is measured against.
var processed_ticks := 0

var _accumulator := 0.0

func _init(seconds_per_tick: float, tick_multiplier := 1.0, accelerate_after := NO_ACCELERATION) -> void:
	tick_seconds = maxf(0.000001, seconds_per_tick)
	multiplier = maxf(1.0, tick_multiplier)
	accelerate_after_ticks = accelerate_after

## Accumulate a frame delta and return how many fixed ticks are now due. The caller
## steps its rooms exactly that many times; the leftover fraction stays banked so no
## time is lost or double-counted across frames.
func advance(delta: float) -> int:
	_accumulator += minf(delta, MAX_FRAME_SECONDS) * effective_multiplier()
	var due := 0
	while _accumulator >= tick_seconds:
		_accumulator -= tick_seconds
		processed_ticks += 1
		due += 1
	return due

## Real-time (1.0) while inside the deferred-acceleration window, the configured
## multiplier afterwards. With no threshold set the multiplier always applies, which
## is the normal server case.
func effective_multiplier() -> float:
	if accelerate_after_ticks >= 0 and processed_ticks < accelerate_after_ticks:
		return 1.0
	return multiplier

## Banked time not yet released as a tick. Diagnostics only — never load-bearing, so
## that reading it cannot perturb the schedule.
func pending_seconds() -> float:
	return _accumulator

func reset() -> void:
	_accumulator = 0.0
	processed_ticks = 0
