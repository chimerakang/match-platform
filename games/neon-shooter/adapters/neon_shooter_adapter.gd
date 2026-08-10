class_name NeonShooterAdapter
extends "res://platform/match_game_adapter.gd"

## Downstream game adapter: neon-platform-shooter on Match Platform V3.
##
## The platform core stays ignorant of every shooter concept; this adapter owns
## slot policy, command validation, the fixed-tick simulation, deterministic hash,
## checkpoint/delta/event construction, replay and terminal result. It reuses
## `Core` (res://games/neon-shooter/core.gd) for terrain + player physics so the authoritative sim
## stays value-identical to the client's prediction core.
##
## This is the full-rule port of netgame/server.js: bullet sub-stepping (no
## tunnelling), spawn offset + 9×16 hitbox, rocket splash, spawn-guard
## invincibility, continuous draw→battle→results round cycling, and bot AI —
## all made deterministic (tick counters + a seeded RNG carried in state) instead
## of the original wall-clock + Math.random, as the platform determinism contract
## requires.

const Core = preload("res://games/neon-shooter/core.gd")

const GAME_ID := "neon-platform-shooter"
const ADAPTER_VERSION := "0.2.0"
const CONTENT_VERSION := "neon-rules.1"
const CODEC_ID := "neon.json.v1"
const TICK_RATE := 30
const DT := 1.0 / float(TICK_RATE)

const PARTICIPANT_SLOTS: Array[String] = ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"]
const OBSERVER_SLOT := "observer"

const DRAW_TICKS := Core.DRAW_TIME * TICK_RATE
const BATTLE_TICKS := Core.BATTLE_TIME * TICK_RATE
const RESULT_TICKS := Core.RESULT_TIME * TICK_RATE
const GUARD_TICKS := int(round(float(Core.SPAWN_GUARD_MS) / 1000.0 * TICK_RATE))
const RESPAWN_TICKS := int(round(float(Core.RESPAWN_MS) / 1000.0 * TICK_RATE))
const SPAWN_Y_OFFSET := 30.0
const BULLET_MUZZLE := 16.0
const BULLET_MUZZLE_UP := 6.0
const HIT_HALF_W := 9.0
const HIT_HALF_H := 16.0

# A slot with no human command for this many ticks is eligible for bot backfill.
const BOT_IDLE_TICKS := 60
# Fill (humans + bots) up to this many active participants, netgame BOT_MIN_PLAYERS.
const BOT_MIN_PLAYERS := 2
const BOT_JITTER_TICKS := int(round(0.18 * TICK_RATE))
const BOT_LEVELS := {
	"easy": {"aim_err": 72.0, "react": 640, "fire_gap": 1.15, "miss": 0.35},
	"normal": {"aim_err": 40.0, "react": 400, "fire_gap": 0.90, "miss": 0.15},
	"hard": {"aim_err": 18.0, "react": 240, "fire_gap": 0.65, "miss": 0.03},
}
const BOT_MIX := [["easy", 0.5], ["normal", 0.35], ["hard", 0.15]]

var match_id := ""
var seed := 0
var tick := 0
var phase := "draw"
var phase_end_tick := DRAW_TICKS
var round_index := 0
var rounds_limit := 0        # 0 = endless (netgame parity); >0 ends the match
var finished := false
var completion: Variant = null

var core: Core = null
var players: Dictionary = {}
var bullets: Array[Dictionary] = []
var _next_bullet := 1
var _rng := RandomNumberGenerator.new()

var _pending: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _event_cursor := 0
var _log: Array[Dictionary] = []

var _accepted := 0
var _refused := 0
var _checkpoints := 0
var _shots := 0


# --- Package identity -------------------------------------------------------
func package_descriptor() -> Dictionary:
	return {
		"game_id": GAME_ID, "adapter_version": ADAPTER_VERSION,
		"content_versions": [CONTENT_VERSION], "content_hashes": [content_hash()],
		"codec_ids": [CODEC_ID], "tick_rate": TICK_RATE,
		"slot_policy": {"participants": PARTICIPANT_SLOTS.size(), "observers": true},
	}


func slot_descriptors() -> Array:
	var result: Array = []
	for slot: String in PARTICIPANT_SLOTS:
		result.append({"slot_id": slot, "kind": "participant", "fillable": true})
	result.append({"slot_id": OBSERVER_SLOT, "kind": "observer", "fillable": false})
	return result


static func content_hash() -> String:
	return ("%s|rules=%s|slots=%d|weapons=%s|W=%d|H=%d" % [
		GAME_ID, CONTENT_VERSION, PARTICIPANT_SLOTS.size(),
		",".join(Core.WEAPON_ORDER), Core.W, Core.H,
	]).sha256_text()


# --- Match lifecycle --------------------------------------------------------
func validate_match_config(candidate: Dictionary) -> Dictionary:
	var frag := int(candidate.get("frag_limit", Core.FRAG_LIMIT))
	if frag < 1 or frag > 100:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "frag_limit must be between 1 and 100")
	var rounds := int(candidate.get("rounds", 0))
	if rounds < 0:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "rounds must be >= 0")
	return {"ok": true}


func create_match(candidate: Dictionary, match_seed: int) -> Dictionary:
	var checked := validate_match_config(candidate)
	if not bool(checked.get("ok", false)):
		return checked
	match_id = String(candidate.get("match_id", "neon:%d" % match_seed))
	seed = match_seed
	rounds_limit = int(candidate.get("rounds", 0))
	tick = 0
	phase = "draw"
	phase_end_tick = DRAW_TICKS
	round_index = 0
	finished = false
	completion = null
	_rng = RandomNumberGenerator.new()
	_rng.seed = match_seed
	core = Core.new()
	core.build_base()
	players = {}
	bullets = []
	_next_bullet = 1
	_pending = []
	_events = []
	_event_cursor = 0
	_log = []
	for index in PARTICIPANT_SLOTS.size():
		players[PARTICIPANT_SLOTS[index]] = _new_player(PARTICIPANT_SLOTS[index], index)
	return {"ok": true, "match_id": match_id, "match": self}


func recover_match(checkpoint_payload: Variant) -> Dictionary:
	if not checkpoint_payload is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint must be a Dictionary")
	var payload: Dictionary = checkpoint_payload
	if String(payload.get("game_id", "")) != GAME_ID:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint belongs to another package")
	var state: Variant = payload.get("state")
	if not state is Dictionary:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "checkpoint state must be a Dictionary")
	var s: Dictionary = state
	match_id = String(payload.get("match_id", "neon:recovered"))
	seed = int(s.get("seed", 0))
	rounds_limit = int(s.get("rounds_limit", 0))
	tick = int(s.get("tick", 0))
	phase = String(s.get("phase", "draw"))
	phase_end_tick = int(s.get("phase_end_tick", DRAW_TICKS))
	round_index = int(s.get("round_index", 0))
	finished = bool(s.get("finished", false))
	completion = s.get("completion")
	_rng = RandomNumberGenerator.new()
	_rng.seed = int(s.get("rng_seed", seed))
	_rng.state = int(s.get("rng_state", _rng.state))
	core = Core.new()
	core.build_base()
	var field_b64 := String(s.get("field", ""))
	if not field_b64.is_empty():
		core.decode_field(Marshalls.base64_to_raw(field_b64))
	players = {}
	for slot: Variant in (s.get("players", {}) as Dictionary):
		players[String(slot)] = (s.players[slot] as Dictionary).duplicate(true)
	bullets = []
	for b: Variant in (s.get("bullets", []) as Array):
		if b is Dictionary:
			bullets.append((b as Dictionary).duplicate(true))
	_next_bullet = int(s.get("next_bullet", 1))
	_pending = []
	_events = []
	_event_cursor = 0
	_log = []
	for entry: Variant in (payload.get("log", []) as Array):
		if entry is Dictionary:
			_log.append((entry as Dictionary).duplicate(true))
	return {"ok": true, "match_id": match_id, "match": self}


# --- Seating & commands -----------------------------------------------------
func validate_join(role: String, requested_slot: Variant, _auth_context: Dictionary) -> Dictionary:
	if role == "observer":
		return {"ok": true, "slot": OBSERVER_SLOT}
	if role != "participant":
		return V3.reject(V3.REJECT_UNAUTHORIZED, "role is not supported")
	var requested := String(requested_slot) if requested_slot != null else ""
	if requested.is_empty():
		return {"ok": true, "slot": PARTICIPANT_SLOTS[0]}
	if requested in PARTICIPANT_SLOTS:
		return {"ok": true, "slot": requested}
	return V3.reject(V3.REJECT_SLOT_UNAVAILABLE, "slot is not part of this package")


func validate_command(slot: Variant, payload: Variant) -> Dictionary:
	var slot_id := String(slot)
	if slot_id not in PARTICIPANT_SLOTS:
		_refused += 1
		return V3.reject(V3.REJECT_UNAUTHORIZED, "source has no participant slot")
	if finished:
		_refused += 1
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "match is already complete")
	if not payload is Dictionary:
		_refused += 1
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "payload must be a Dictionary")
	var body: Dictionary = payload
	var kind := String(body.get("kind", ""))
	match kind:
		"input":
			return {"ok": true, "command": {
				"kind": "input", "seq": int(body.get("seq", 0)),
				"left": bool(body.get("left", false)), "right": bool(body.get("right", false)),
				"jump": bool(body.get("jump", false)),
				"aimX": float(body.get("aimX", 0.0)), "aimY": float(body.get("aimY", 0.0)),
			}}
		"draw":
			if phase != "draw":
				_refused += 1
				return V3.reject(V3.REJECT_ADAPTER_REJECTED, "draw is only allowed in the draw phase")
			return {"ok": true, "command": {
				"kind": "draw",
				"x0": clampf(float(body.get("x0", 0.0)), 0.0, Core.W), "y0": clampf(float(body.get("y0", 0.0)), 0.0, Core.H),
				"x1": clampf(float(body.get("x1", 0.0)), 0.0, Core.W), "y1": clampf(float(body.get("y1", 0.0)), 0.0, Core.H),
			}}
		"shoot":
			if phase != "battle":
				_refused += 1
				return V3.reject(V3.REJECT_ADAPTER_REJECTED, "shoot is only allowed in the battle phase")
			return {"ok": true, "command": {"kind": "shoot"}}
		"weapon":
			var w := String(body.get("w", ""))
			if w not in Core.WEAPON_ORDER:
				_refused += 1
				return V3.reject(V3.REJECT_ADAPTER_REJECTED, "unknown weapon")
			return {"ok": true, "command": {"kind": "weapon", "w": w}}
		"redraw":
			if phase != "draw":
				_refused += 1
				return V3.reject(V3.REJECT_ADAPTER_REJECTED, "redraw is only allowed in the draw phase")
			return {"ok": true, "command": {"kind": "redraw"}}
		_:
			_refused += 1
			return V3.reject(V3.REJECT_ADAPTER_REJECTED, "unknown command kind")


func apply_command(slot: Variant, payload: Variant) -> void:
	var checked := validate_command(slot, payload)
	if not bool(checked.get("ok", false)):
		return
	var command: Dictionary = checked.command
	var slot_id := String(slot)
	var player: Dictionary = players.get(slot_id, {})
	if player.is_empty():
		return
	_accepted += 1
	_log.append({"slot": slot_id, "payload": command.duplicate(true), "at": tick})
	# Any command marks the slot human-controlled, so bot AI yields it.
	player["last_input_tick"] = tick
	if String(command.kind) == "input":
		player["input"] = {"left": bool(command.left), "right": bool(command.right), "jump": bool(command.jump)}
		player["aimX"] = float(command.aimX)
		player["aimY"] = float(command.aimY)
		player["seq"] = int(command.seq)
	else:
		_pending.append({"slot": slot_id, "command": command})


# --- Fixed simulation -------------------------------------------------------
func advance(ticks: int) -> void:
	for _index in maxi(0, ticks):
		if finished:
			break
		_apply_pending()
		if phase == "battle":
			_step_bots()
			_step_players()
			_update_bullets()
			_update_respawns()
		_decrement_timers()
		tick += 1
		_advance_phase()


func _apply_pending() -> void:
	var batch := _pending
	_pending = []
	for entry: Dictionary in batch:
		var slot: String = entry.slot
		var command: Dictionary = entry.command
		var player: Dictionary = players.get(slot, {})
		if player.is_empty():
			continue
		match String(command.kind):
			"draw":
				if int(player.get("ink", 0)) <= 0:
					continue
				var used := core.paint_stroke(command.x0, command.y0, command.x1, command.y1, Core.ISO)
				if used > 0.0:
					player["ink"] = maxi(0, int(player.ink) - int(ceil(used)))
					_emit("stroke", V3.RELIABLE, {"x0": command.x0, "y0": command.y0, "x1": command.x1, "y1": command.y1})
			"weapon":
				player["weapon"] = command.w
			"redraw":
				_start_draw()
			"shoot":
				if phase == "battle" and bool(player.get("alive", true)) and not bool(player.get("waiting", false)):
					_fire(slot, player)


func _step_players() -> void:
	for slot: String in PARTICIPANT_SLOTS:
		var player: Dictionary = players[slot]
		if not bool(player.get("alive", true)) or bool(player.get("waiting", false)):
			continue
		if _is_bot(player):
			continue  # bot movement is driven in _step_bots
		core.step_player(player, player.get("input", {}), DT)


func _is_bot(player: Dictionary) -> bool:
	return tick - int(player.get("last_input_tick", -100000)) > BOT_IDLE_TICKS


# Bot backfill + AI, ported from netgame stepBots. Fills idle slots up to
# BOT_MIN_PLAYERS only while at least one human is present (netgame parity), and
# drives each bot deterministically from the seeded RNG.
func _step_bots() -> void:
	var humans: Array[String] = []
	var idle: Array[String] = []
	for slot: String in PARTICIPANT_SLOTS:
		if _is_bot(players[slot]):
			idle.append(slot)
		else:
			humans.append(slot)
	if humans.is_empty():
		return
	var want_bots := clampi(BOT_MIN_PLAYERS - humans.size(), 0, idle.size())
	var active: Array[String] = idle.slice(0, want_bots)
	for slot: String in active:
		var bot: Dictionary = players[slot]
		if not bool(bot.get("alive", true)):
			continue
		_run_bot(slot, bot)


func _run_bot(slot: String, bot: Dictionary) -> void:
	var brain: Dictionary = bot.brain
	var cfg: Dictionary = BOT_LEVELS.get(String(brain.get("lvl", "normal")), BOT_LEVELS.normal)
	var input := {"left": false, "right": false, "jump": false}
	var best := {}
	var best_d := INF
	var best_dx := 0.0
	for other: String in PARTICIPANT_SLOTS:
		if other == slot:
			continue
		var q: Dictionary = players[other]
		if not bool(q.get("alive", true)) or bool(q.get("waiting", false)) or int(q.get("guard", 0)) > 0:
			continue
		var dx := float(q.x) - float(bot.x)
		if dx > Core.W / 2.0: dx -= Core.W
		elif dx < -Core.W / 2.0: dx += Core.W
		var d := sqrt(dx * dx + (float(q.y) - float(bot.y)) * (float(q.y) - float(bot.y)))
		if d < best_d:
			best_d = d
			best = q
			best_dx = dx
	if not best.is_empty():
		if tick >= int(brain.get("jitter_at", 0)):
			brain["jx"] = (_rng.randf() * 2.0 - 1.0) * float(cfg.aim_err)
			brain["jy"] = (_rng.randf() * 2.0 - 1.0) * float(cfg.aim_err)
			brain["jitter_at"] = tick + BOT_JITTER_TICKS
		bot["aimX"] = float(bot.x) + best_dx + float(brain.jx)
		bot["aimY"] = float(best.y) + float(brain.jy)
		var range_x := absf(best_dx)
		var want := 200.0
		if range_x > want + 40.0:
			if best_dx > 0.0: input.right = true
			else: input.left = true
		elif range_x < want - 60.0:
			if best_dx > 0.0: input.left = true
			else: input.right = true
		else:
			if tick >= int(brain.get("wander_at", 0)):
				brain["dir"] = -1 if _rng.randf() < 0.5 else 1
				brain["wander_at"] = tick + int(round(0.7 * TICK_RATE))
			if int(brain.dir) > 0: input.right = true
			else: input.left = true
		if bool(bot.get("onGround", false)) and ((float(best.y) < float(bot.y) - 24.0 and _rng.randf() < 0.04) or _rng.randf() < 0.006):
			input.jump = true
		if tick >= int(brain.get("next_shot", 0)):
			var react_ticks := int(round(float(cfg.react) / 1000.0 * TICK_RATE))
			if _rng.randf() < float(cfg.miss):
				brain["next_shot"] = tick + maxi(1, react_ticks / 2)
			elif _fire(slot, bot):
				brain["next_shot"] = tick + maxi(1, int(round(react_ticks * float(cfg.fire_gap) * (0.6 + _rng.randf() * 0.8))))
	elif tick >= int(brain.get("wander_at", 0)):
		brain["dir"] = -1 if _rng.randf() < 0.5 else 1
		brain["wander_at"] = tick + int(round(0.9 * TICK_RATE))
		if int(brain.dir) > 0: input.right = true
		else: input.left = true
	core.step_player(bot, input, DT)


func _fire(slot: String, player: Dictionary) -> bool:
	if not bool(player.get("alive", true)) or int(player.get("cd", 0)) > 0:
		return false
	var weapon_id := String(player.get("weapon", "pistol"))
	var weapon: Dictionary = Core.weapon(weapon_id)
	player["cd"] = int(round(float(weapon.cd) / 1000.0 * TICK_RATE))
	_shots += 1
	var bx := float(player.x)
	var by := float(player.y) - BULLET_MUZZLE_UP
	var base_angle := atan2(float(player.aimY) - by, float(player.aimX) - bx)
	var pellets := int(weapon.get("pellets", 1))
	var spread := float(weapon.get("spread", 0.0))
	for _pellet in pellets:
		var angle := base_angle
		if pellets > 1:
			angle += (_rng.randf() - 0.5) * spread
		bullets.append({
			"id": _next_bullet, "owner": slot,
			"x": bx + cos(angle) * BULLET_MUZZLE, "y": by + sin(angle) * BULLET_MUZZLE,
			"dx": cos(angle), "dy": sin(angle), "spd": float(weapon.speed),
			"life": float(weapon.life), "dmg": int(weapon.dmg), "carve": float(weapon.carve),
			"splash": float(weapon.get("splash", 0.0)), "splash_dmg": int(weapon.get("splashDmg", 0)),
			"color": String(weapon.color),
		})
		_next_bullet += 1
	return true


func _update_bullets() -> void:
	var survivors: Array[Dictionary] = []
	for bullet: Dictionary in bullets:
		bullet["life"] = float(bullet.life) - DT
		var step := float(bullet.spd) * DT
		var sub := maxi(1, int(ceil(step / 4.0)))
		var dead := false
		for _s in sub:
			bullet["x"] = Core.wrap_x(float(bullet.x) + float(bullet.dx) * step / sub)
			bullet["y"] = Core.wrap_y(float(bullet.y) + float(bullet.dy) * step / sub)
			var victim := _bullet_hit(bullet)
			if victim != "" or core.solid_at(float(bullet.x), float(bullet.y)):
				core.stamp_field(float(bullet.x), float(bullet.y), float(bullet.carve), -1.0)
				_emit("crater", V3.RELIABLE, {"x": bullet.x, "y": bullet.y, "r": bullet.carve})
				if victim != "":
					_damage(victim, int(bullet.dmg), String(bullet.owner), float(bullet.x), float(bullet.y))
				if float(bullet.splash) > 0.0:
					_splash(bullet, victim)
				dead = true
				break
		if not dead and float(bullet.life) > 0.0:
			survivors.append(bullet)
	bullets = survivors


func _bullet_hit(bullet: Dictionary) -> String:
	for slot: String in PARTICIPANT_SLOTS:
		if slot == String(bullet.owner):
			continue
		var player: Dictionary = players[slot]
		if not bool(player.get("alive", true)) or bool(player.get("waiting", false)) or int(player.get("guard", 0)) > 0:
			continue  # invincible / waiting players are transparent to bullets
		if absf(float(bullet.x) - float(player.x)) < HIT_HALF_W and absf(float(bullet.y) - float(player.y)) < HIT_HALF_H:
			return slot
	return ""


func _splash(bullet: Dictionary, direct_victim: String) -> void:
	var radius := float(bullet.splash)
	for slot: String in PARTICIPANT_SLOTS:
		if slot == String(bullet.owner) or slot == direct_victim:
			continue
		var player: Dictionary = players[slot]
		if not bool(player.get("alive", true)) or bool(player.get("waiting", false)) or int(player.get("guard", 0)) > 0:
			continue
		var dx := float(player.x) - float(bullet.x)
		var dy := float(player.y) - float(bullet.y)
		if sqrt(dx * dx + dy * dy) < radius:
			_damage(slot, int(bullet.splash_dmg), String(bullet.owner), float(player.x), float(player.y))


func _damage(slot: String, amount: int, by: String, x: float, y: float) -> void:
	var player: Dictionary = players[slot]
	if not bool(player.get("alive", true)) or int(player.get("guard", 0)) > 0:
		return
	player["hp"] = int(player.hp) - amount
	if int(player.hp) > 0:
		return
	player["hp"] = 0
	player["alive"] = false
	player["respawn"] = RESPAWN_TICKS
	player["deaths"] = int(player.deaths) + 1
	if by in players and by != slot:
		players[by]["kills"] = int(players[by].kills) + 1
	_emit("kill", V3.DROPPABLE, {"x": x, "y": y, "by": by, "victim": slot})


func _update_respawns() -> void:
	for slot: String in PARTICIPANT_SLOTS:
		var player: Dictionary = players[slot]
		if bool(player.get("alive", true)):
			continue
		player["respawn"] = int(player.respawn) - 1
		if int(player.respawn) <= 0:
			player["hp"] = Core.HP_MAX
			player["alive"] = true
			_assign_spawn(player)


func _decrement_timers() -> void:
	for slot: String in PARTICIPANT_SLOTS:
		var player: Dictionary = players[slot]
		if int(player.get("cd", 0)) > 0:
			player["cd"] = int(player.cd) - 1
		if int(player.get("guard", 0)) > 0:
			player["guard"] = int(player.guard) - 1


func _advance_phase() -> void:
	if finished:
		return
	if phase == "battle":
		var top := 0
		for slot: String in PARTICIPANT_SLOTS:
			top = maxi(top, int(players[slot].kills))
		if top >= Core.FRAG_LIMIT:
			_start_results()
			return
	if tick < phase_end_tick:
		return
	match phase:
		"draw":
			_start_battle()
		"battle":
			_start_results()
		"results":
			round_index += 1
			if rounds_limit > 0 and round_index >= rounds_limit:
				finished = true
				completion = {"winner": _leader(), "scores": _scoreboard(), "rounds": round_index, "tick": tick}
				_emit("phase", V3.RELIABLE, {"phase": "ended", "tick": tick})
			else:
				_start_draw()


func _start_battle() -> void:
	phase = "battle"
	phase_end_tick = tick + BATTLE_TICKS
	for slot: String in PARTICIPANT_SLOTS:
		var player: Dictionary = players[slot]
		player["hp"] = Core.HP_MAX
		player["alive"] = true
		player["respawn"] = 0
		player["waiting"] = false
		_assign_spawn(player)
	_emit("phase", V3.RELIABLE, {"phase": "battle", "tick": tick})


func _start_results() -> void:
	if phase == "results":
		return
	phase = "results"
	phase_end_tick = tick + RESULT_TICKS
	bullets = []
	completion = {"winner": _leader(), "scores": _scoreboard(), "round": round_index, "tick": tick}
	_emit("phase", V3.RELIABLE, {"phase": "results", "tick": tick})


func _start_draw() -> void:
	phase = "draw"
	phase_end_tick = tick + DRAW_TICKS
	core.build_base()
	bullets = []
	for slot: String in PARTICIPANT_SLOTS:
		var player: Dictionary = players[slot]
		player["ink"] = Core.INK_MAX
		player["kills"] = 0
		player["deaths"] = 0
		player["hp"] = Core.HP_MAX
		player["alive"] = true
		player["waiting"] = false
		_assign_spawn(player)
	_emit("phase", V3.RELIABLE, {"phase": "draw", "tick": tick})


func terminal_result() -> Variant:
	return completion.duplicate(true) if (finished and completion is Dictionary) else null


# --- Deterministic hash / replay --------------------------------------------
func state_hash() -> String:
	var ordered: Array = [tick, phase, phase_end_tick, round_index, int(finished), int(_rng.state)]
	for slot: String in PARTICIPANT_SLOTS:
		var p: Dictionary = players[slot]
		ordered.append([
			slot, _q(p.x), _q(p.y), _q(p.vx), _q(p.vy),
			int(p.hp), int(p.kills), int(p.deaths), int(p.alive),
			String(p.weapon), int(p.ink), int(p.cd), int(p.respawn), int(p.guard),
		])
	var bullet_view: Array = []
	for b: Dictionary in bullets:
		bullet_view.append([int(b.id), _q(b.x), _q(b.y), _q(b.dx), _q(b.dy), _q(b.life)])
	bullet_view.sort_custom(func(a: Array, c: Array) -> bool: return int(a[0]) < int(c[0]))
	ordered.append(bullet_view)
	ordered.append(Marshalls.raw_to_base64(core.encode_field()).sha256_text())
	return JSON.stringify(ordered).sha256_text()


func export_replay() -> Variant:
	return {
		"schema": 1, "game_id": GAME_ID, "match_id": match_id, "seed": seed,
		"rounds": rounds_limit, "log": _log.duplicate(true), "steps": tick,
		"state_hash": state_hash(), "completion": terminal_result(),
	}


func replay_into(replay: Dictionary) -> Dictionary:
	if String(replay.get("game_id", "")) != GAME_ID:
		return V3.reject(V3.REJECT_ADAPTER_REJECTED, "replay belongs to another package")
	var created := create_match({"match_id": String(replay.get("match_id", "")), "rounds": int(replay.get("rounds", 0))}, int(replay.get("seed", 0)))
	if not bool(created.get("ok", false)):
		return created
	var entries: Array = replay.get("log", [])
	var cursor := 0
	var target := int(replay.get("steps", 0))
	while tick < target and not finished:
		while cursor < entries.size() and int(entries[cursor].get("at", -1)) == tick:
			apply_command(entries[cursor].get("slot"), entries[cursor].get("payload"))
			cursor += 1
		advance(1)
	return {"ok": state_hash() == String(replay.get("state_hash", ""))}


# --- Replication ------------------------------------------------------------
func build_checkpoint(_codec_id: String) -> Dictionary:
	_checkpoints += 1
	return {
		"payload": {"game_id": GAME_ID, "match_id": match_id, "state": _full_state()},
		"state_hash": state_hash(), "tick": tick,
	}


func build_delta(from_ack_tick: int, _codec_id: String) -> Dictionary:
	return {"payload": {"replace": _dynamic_state()}, "tick": tick, "base_tick": from_ack_tick}


func drain_events(_codec_id: String) -> Array:
	var result: Array = []
	while _event_cursor < _events.size():
		var event: Dictionary = _events[_event_cursor]
		result.append({"reliability": String(event.reliability), "payload": (event.payload as Dictionary).duplicate(true)})
		_event_cursor += 1
	return result


func metrics() -> Dictionary:
	return {
		"accepted": _accepted, "refused": _refused, "checkpoints": _checkpoints,
		"shots": _shots, "tick": tick, "phase": phase, "round": round_index,
		"bullets": bullets.size(),
	}


# --- Internal helpers -------------------------------------------------------
func _new_player(slot: String, index: int) -> Dictionary:
	var player := {
		"id": slot, "color": Core.PLAYER_COLORS[index % Core.PLAYER_COLORS.size()],
		"spawn_index": index % Core.SPAWNS.size(),
		"x": 0.0, "y": 0.0, "vx": 0.0, "vy": 0.0, "face": 1, "onGround": false,
		"hp": Core.HP_MAX, "alive": true, "kills": 0, "deaths": 0,
		"weapon": "pistol", "ink": Core.INK_MAX, "cd": 0, "respawn": 0, "guard": 0,
		"waiting": false, "aimX": 0.0, "aimY": 0.0, "seq": 0,
		"last_input_tick": -100000,   # unoccupied slots start bot-eligible
		"input": {"left": false, "right": false, "jump": false},
		"brain": _new_brain(),
	}
	_assign_spawn(player)
	return player


func _new_brain() -> Dictionary:
	return {
		"lvl": _pick_bot_level(), "jitter_at": 0, "jx": 0.0, "jy": 0.0,
		"wander_at": 0, "dir": 1, "next_shot": 0,
	}


func _pick_bot_level() -> String:
	var roll := _rng.randf()
	var acc := 0.0
	for entry: Array in BOT_MIX:
		acc += float(entry[1])
		if roll < acc:
			return String(entry[0])
	return "normal"


func _assign_spawn(player: Dictionary) -> void:
	var spawn: Vector2 = Core.SPAWNS[int(player.spawn_index)]
	player["x"] = spawn.x
	player["y"] = spawn.y - SPAWN_Y_OFFSET
	player["vx"] = 0.0
	player["vy"] = 0.0
	player["onGround"] = false
	player["guard"] = GUARD_TICKS
	player["aimX"] = spawn.x + 10.0
	player["aimY"] = spawn.y - SPAWN_Y_OFFSET


func _emit(kind: String, reliability: StringName, data: Dictionary) -> void:
	var payload := data.duplicate(true)
	payload["kind"] = kind
	payload["tick"] = tick
	payload["index"] = _events.size() + 1
	_events.append({"reliability": String(reliability), "payload": payload})


func _full_state() -> Dictionary:
	return {
		"seed": seed, "rng_seed": seed, "rng_state": int(_rng.state),
		"tick": tick, "phase": phase, "phase_end_tick": phase_end_tick,
		"round_index": round_index, "rounds_limit": rounds_limit,
		"finished": finished, "completion": completion,
		"players": _players_copy(), "bullets": _bullets_copy(),
		"next_bullet": _next_bullet, "field": Marshalls.raw_to_base64(core.encode_field()),
	}


func _dynamic_state() -> Dictionary:
	return {
		"tick": tick, "phase": phase, "phase_end_tick": phase_end_tick,
		"round": round_index, "finished": finished,
		"players": _players_copy(), "bullets": _bullets_copy(),
	}


func _players_copy() -> Dictionary:
	var out: Dictionary = {}
	for slot: String in PARTICIPANT_SLOTS:
		out[slot] = (players[slot] as Dictionary).duplicate(true)
	return out


func _bullets_copy() -> Array:
	var out: Array = []
	for b: Dictionary in bullets:
		out.append(b.duplicate(true))
	return out


func _scoreboard() -> Dictionary:
	var out: Dictionary = {}
	for slot: String in PARTICIPANT_SLOTS:
		out[slot] = {"kills": int(players[slot].kills), "deaths": int(players[slot].deaths)}
	return out


func _leader() -> String:
	var best := ""
	var best_kills := -1
	for slot: String in PARTICIPANT_SLOTS:
		if int(players[slot].kills) > best_kills:
			best_kills = int(players[slot].kills)
			best = slot
	return best


static func _q(value: float) -> int:
	return int(round(value * 8.0))
