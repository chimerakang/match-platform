## WebSocket client for the Match Platform V3 authoritative server
## (shooter/server/server_main.gd). Drop-in replacement for NetClient: it exposes
## the same public surface (self_p / self_stats / interp / bullets / phase /
## signals / send_* / input / aim / sample_interp) so arena.gd is unchanged, but
## speaks V3 envelopes (hello→welcome→join→checkpoint/state/event) instead of the
## old `t`-tagged netgame protocol. Prediction/reconciliation still runs core.gd.
class_name NetClientV3
extends Node

const V3 = preload("res://platform/match_platform_v3.gd")

signal connected
signal disconnected
signal terrain_dirty
signal snapshot_applied
signal crater_fx(pos: Vector2, r: float)
signal kill_fx(pos: Vector2)
signal phase_changed(phase: String, time_left: float)

const DT: float = 1.0 / 30.0
const INTERP_MS: int = 100
const GAME_ID := "neon-platform-shooter"
const GAME_VERSION := "neon-rules.1"
const CODEC_ID := "neon.json.v1"

var _ws := WebSocketPeer.new()
var _url: String = "ws://127.0.0.1:2567"
var _open := false
var _welcomed := false
var _joined := false
var core: Core
var dirty: Dictionary = {}

# network-visible state (arena reads these)
var my_id: String = ""           # our opaque slot ("p1".."p8")
var my_color: String = "#8fe8ff"
var my_arena: int = 0
var my_role: String = "player"
var queue_pos: int = 0
var queue_total: int = 0
var phase: String = "draw"
var time_left: float = Core.DRAW_TIME
var my_ink: float = Core.INK_MAX
var current_weapon: String = "pistol"

var self_p := {"x": 0.0, "y": 0.0, "vx": 0.0, "vy": 0.0, "face": 1, "onGround": false}
var self_stats := {"hp": Core.HP_MAX, "k": 0, "a": 1, "rs": 0, "gd": 0}
var have_self := false
var bullets: Array = []
var interp: Dictionary = {}

var input := {"left": false, "right": false, "jump": false}
var aim := Vector2(Core.W / 2.0, Core.H / 2.0)

var _match_id := ""
var _codec := CODEC_ID
var _server_tick := 0
var _pending: Array = []          # unacked local inputs for reconcile
var _input_seq: int = 0
var _send_accum: float = 0.0


func setup(shared_core: Core, url: String = "") -> void:
	core = shared_core
	if url != "":
		_url = url


func connect_to_server() -> void:
	var err := _ws.connect_to_url(_url)
	if err != OK:
		push_warning("net_client_v3: connect_to_url(%s) failed: %d" % [_url, err])


func is_open() -> bool:
	return _open


func _process(delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _open:
			_open = true
			connected.emit()
			_send_hello()
		while _ws.get_available_packet_count() > 0:
			_on_bytes(_ws.get_packet())
		_tick_input(delta)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _open:
			_open = false
			disconnected.emit()


# --- outgoing ---------------------------------------------------------------
func _send(envelope: Dictionary) -> void:
	if _open:
		_ws.send_text(JSON.stringify(envelope))


func _send_hello() -> void:
	_send(V3.envelope(V3.HELLO, {
		"protocol_versions": [V3.ENVELOPE_VERSION],
		"game_id": GAME_ID, "game_version": GAME_VERSION,
		"content_hash": _content_hash(), "codecs": [CODEC_ID],
	}))


func _send_join() -> void:
	if _joined:
		return
	_joined = true
	_send(V3.envelope(V3.JOIN, {
		"match_selector": {"mode": "quick"}, "role": "participant", "auth_context": {},
	}))


func _send_command(payload: Dictionary) -> void:
	if not _joined or _match_id.is_empty():
		return
	_input_seq += 1
	_send(V3.envelope(V3.COMMAND, {
		"match_id": _match_id, "seq": _input_seq, "expected_tick": _server_tick + 1,
		"codec_id": _codec, "payload": payload,
	}))


func send_draw(x0: float, y0: float, x1: float, y1: float) -> void:
	_send_command({"kind": "draw", "x0": x0, "y0": y0, "x1": x1, "y1": y1})

func send_shoot() -> void:
	_send_command({"kind": "shoot"})

func send_weapon(w: String) -> void:
	if Core.WEAPONS.has(w):
		current_weapon = w
		_send_command({"kind": "weapon", "w": w})

func send_redraw() -> void:
	_send_command({"kind": "redraw"})


func _tick_input(delta: float) -> void:
	if not _joined or my_role != "player":
		return
	_send_accum += delta
	while _send_accum >= DT:
		_send_accum -= DT
		_input_seq += 1
		if phase == "battle" and int(self_stats.get("a", 0)) == 1:
			core.step_player(self_p, input, DT)
			_pending.append({"seq": _input_seq, "input": input.duplicate()})
		_send(V3.envelope(V3.COMMAND, {
			"match_id": _match_id, "seq": _input_seq, "expected_tick": _server_tick + 1,
			"codec_id": _codec,
			"payload": {
				"kind": "input", "seq": _input_seq,
				"left": input["left"], "right": input["right"], "jump": input["jump"],
				"aimX": aim.x, "aimY": aim.y,
			},
		}))


# --- incoming ---------------------------------------------------------------
func _on_bytes(bytes: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if parsed is Array:
		for env: Variant in parsed:
			if env is Dictionary:
				_on_env(env)
	elif parsed is Dictionary:
		_on_env(parsed)


func _on_env(env: Dictionary) -> void:
	match StringName(env.get("t", "")):
		V3.WELCOME:
			_welcomed = true
			_codec = String(env.get("selected_codec", CODEC_ID))
			_send_join()
		V3.REJECT:
			push_warning("net_client_v3: reject %s" % String(env.get("code", "")))
		V3.CHECKPOINT:
			_match_id = String(env.get("match_id", _match_id))
			_apply_checkpoint(env.get("payload", {}))
		V3.STATE:
			_match_id = String(env.get("match_id", _match_id))
			_server_tick = int(env.get("tick", _server_tick))
			_apply_state(env.get("payload", {}))
		V3.EVENT:
			_match_id = String(env.get("match_id", _match_id))
			_apply_event(env.get("payload", {}))


func _apply_checkpoint(payload: Dictionary) -> void:
	var state: Dictionary = payload.get("state", {})
	var field_b64 := String(state.get("field", ""))
	if not field_b64.is_empty():
		core.decode_field(Marshalls.base64_to_raw(field_b64))
		snapshot_applied.emit()
	_server_tick = int(state.get("tick", _server_tick))
	_apply_dynamic(state)


func _apply_state(payload: Dictionary) -> void:
	var dynamic: Dictionary = payload.get("replace", payload)
	_apply_dynamic(dynamic)


func _apply_dynamic(state: Dictionary) -> void:
	var new_phase := String(state.get("phase", phase))
	if new_phase != phase:
		phase = new_phase
		phase_changed.emit(phase, time_left)
	if state.has("phase_end_tick"):
		time_left = maxf(0.0, float(int(state.phase_end_tick) - _server_tick) * DT)
	var players: Dictionary = state.get("players", {})
	var now := Time.get_ticks_msec()
	var seen := {}
	for slot: Variant in players.keys():
		var slot_id := String(slot)
		var p: Dictionary = players[slot]
		seen[slot_id] = true
		if slot_id == my_id:
			_apply_self(p)
		else:
			var buf: Array = interp.get(slot_id, [])
			buf.append({
				"t": now, "x": float(p.get("x", 0.0)), "y": float(p.get("y", 0.0)),
				"face": int(p.get("face", 1)), "a": 1 if bool(p.get("alive", true)) else 0,
				"hp": int(p.get("hp", 0)), "k": int(p.get("kills", 0)),
				"rs": int(p.get("respawn", 0)), "color": String(p.get("color", "#fff")), "gd": 0,
			})
			if buf.size() > 50:
				buf.pop_front()
			interp[slot_id] = buf
	for slot_id: Variant in interp.keys():
		if not seen.has(slot_id):
			interp.erase(slot_id)
	bullets = _remap_bullets(state.get("bullets", []))


func _apply_self(p: Dictionary) -> void:
	self_stats = {
		"hp": int(p.get("hp", 0)), "k": int(p.get("kills", 0)),
		"a": 1 if bool(p.get("alive", true)) else 0, "rs": int(p.get("respawn", 0)), "gd": 0,
	}
	my_ink = float(p.get("ink", my_ink))
	current_weapon = String(p.get("weapon", current_weapon))
	self_p["face"] = int(p.get("face", 1))
	if phase == "battle" and bool(p.get("alive", true)):
		self_p["x"] = float(p.get("x", 0.0))
		self_p["y"] = float(p.get("y", 0.0))
		self_p["vx"] = float(p.get("vx", 0.0))
		self_p["vy"] = float(p.get("vy", 0.0))
		self_p["onGround"] = bool(p.get("onGround", false))
		var ack := int(p.get("seq", 0))
		while _pending.size() > 0 and int(_pending[0]["seq"]) <= ack:
			_pending.pop_front()
		for q: Dictionary in _pending:
			core.step_player(self_p, q["input"], DT)
	else:
		self_p["x"] = float(p.get("x", 0.0))
		self_p["y"] = float(p.get("y", 0.0))
		self_p["vx"] = 0.0
		self_p["vy"] = 0.0
		_pending.clear()
	have_self = true


func _apply_event(payload: Dictionary) -> void:
	match String(payload.get("kind", "")):
		"seat":
			my_id = String(payload.get("slot", my_id))
			my_role = "player" if String(payload.get("role", "participant")) == "participant" else "spectator"
			my_color = String(payload.get("color", my_color))
		"phase":
			var new_phase := String(payload.get("phase", phase))
			if new_phase != phase and new_phase != "ended":
				phase = new_phase
				phase_changed.emit(phase, time_left)
		"stroke":
			core.paint_stroke(payload.x0, payload.y0, payload.x1, payload.y1, Core.ISO, dirty)
			terrain_dirty.emit()
		"crater":
			var r := float(payload.get("r", 24.0))
			core.stamp_field(payload.x, payload.y, r, -1.0, dirty)
			terrain_dirty.emit()
			crater_fx.emit(Vector2(payload.x, payload.y), r)
		"kill":
			kill_fx.emit(Vector2(float(payload.get("x", 0.0)), float(payload.get("y", 0.0))))
		"redraw":
			pass  # full field arrives with the next checkpoint


func _remap_bullets(raw: Array) -> Array:
	var out: Array = []
	for b: Variant in raw:
		if b is Dictionary:
			out.append({
				"x": float(b.get("x", 0.0)), "y": float(b.get("y", 0.0)),
				"dx": float(b.get("dx", 0.0)), "dy": float(b.get("dy", 0.0)),
				"c": String(b.get("color", "#fff")),
			})
	return out


## Wrap-aware interpolation sample (identical semantics to NetClient.sample_interp).
func sample_interp(buf: Array, rt: int) -> Dictionary:
	if buf.is_empty():
		return {}
	if rt <= buf[0]["t"]:
		return buf[0]
	var last: Dictionary = buf[buf.size() - 1]
	if rt >= last["t"]:
		return last
	for i in range(buf.size() - 1, 0, -1):
		var a: Dictionary = buf[i - 1]
		var b: Dictionary = buf[i]
		if a["t"] <= rt and rt <= b["t"]:
			var span: float = float(b["t"] - a["t"])
			var u: float = (rt - a["t"]) / (span if span != 0.0 else 1.0)
			return {
				"x": b["x"] if absf(b["x"] - a["x"]) > Core.W / 2.0 else a["x"] + (b["x"] - a["x"]) * u,
				"y": b["y"] if absf(b["y"] - a["y"]) > Core.H / 2.0 else a["y"] + (b["y"] - a["y"]) * u,
				"face": b["face"], "a": b["a"], "hp": b["hp"], "k": b["k"], "rs": b["rs"],
				"color": b["color"], "gd": b.get("gd", 0),
			}
	return last


static func _content_hash() -> String:
	return ("%s|rules=%s|slots=%d|weapons=%s|W=%d|H=%d" % [
		GAME_ID, GAME_VERSION, 8, ",".join(Core.WEAPON_ORDER), Core.W, Core.H,
	]).sha256_text()
