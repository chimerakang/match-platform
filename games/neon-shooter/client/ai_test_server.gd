## AI Test Server (Phase B). TCP server for local automated verification of the
## Godot port. AI sends line-delimited JSON commands, receives JSON game state.
## Only active in debug builds (or when PS_AI_TEST_SERVER=1). Does nothing in
## release. Protocol & busy-lock design mirror gameA's src/autoload/ai_test_server.gd.
##
## Architecture note — why we do NOT inject InputEventAction like gameA:
## platform-shooter is server-authoritative. The real convergence point for all
## input (keyboard, gamepad, AI) is the net client's OUTGOING layer:
## `net.input` / `net.aim` / `net.send_*()`. Humans reach it via arena translating
## Input Actions; the AI reaches it directly. Same funnel, one hop before the wire —
## more faithful to where authority flows, and deterministic for tests.
extends Node

const DEFAULT_PORT := 7070

var _server: TCPServer
var _client: StreamPeerTCP
var _buffer := ""
var _busy := false
var _queue: Array[String] = []
var _port := DEFAULT_PORT

var ai_mode := false            # arena skips human input while true
var _net: NetClientV3 = null      # outgoing/synced network state
var _arena: Node = null


func _ready() -> void:
	if not _should_start():
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	_port = _resolve_port()
	_server = TCPServer.new()
	var err := _server.listen(_port)
	if err == OK:
		print("[ai_test] listening on port %d" % _port)
	else:
		push_warning("[ai_test] failed to listen on port %d (err %d)" % [_port, err])


## Called by arena._ready() so the server can drive the live client.
func attach(arena: Node, net: NetClientV3) -> void:
	_arena = arena
	_net = net


func _should_start() -> bool:
	var env := OS.get_environment("PS_AI_TEST_SERVER").strip_edges().to_lower()
	if env in ["1", "true", "yes", "on"]:
		return true
	if env in ["0", "false", "no", "off"]:
		return false
	return false


func _resolve_port() -> int:
	var env_port := OS.get_environment("PS_AI_TEST_PORT").strip_edges()
	if env_port.is_valid_int():
		var p := int(env_port)
		if p > 0 and p <= 65535:
			return p
	return DEFAULT_PORT


func _process(_delta: float) -> void:
	if _server == null:
		return
	if _server.is_connection_available():
		if _client != null:
			_client.disconnect_from_host()
		_client = _server.take_connection()
		_buffer = ""
		_busy = false
		_queue.clear()
		print("[ai_test] client connected")

	if _client == null:
		return
	_client.poll()
	if _client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return

	var available := _client.get_available_bytes()
	if available > 0:
		var raw := _client.get_data(available)
		var data: String = raw[1].get_string_from_utf8()
		_buffer += data
		while _buffer.find("\n") >= 0:
			var nl := _buffer.find("\n")
			var line := _buffer.substr(0, nl).strip_edges()
			_buffer = _buffer.substr(nl + 1)
			if line != "":
				_queue.append(line)

	if not _busy and _queue.size() > 0:
		var line: String = _queue.pop_front()
		_busy = true
		await _process_command(line)
		_busy = false


func _process_command(json_str: String) -> void:
	var parsed: Variant = JSON.parse_string(json_str)
	if not parsed is Dictionary:
		_send({"error": "Invalid JSON"})
		return
	if _net == null:
		_send({"error": "not attached (no arena/net yet)"})
		return

	var cmd: String = parsed.get("command", "")
	var result: Dictionary
	match cmd:
		# ─── meta / control ─────────────────────────────
		"take_control":
			ai_mode = true
			result = _get_state()
		"release_control":
			ai_mode = false
			_net.input = {"left": false, "right": false, "jump": false}
			result = _get_state()
		# ─── read-only ──────────────────────────────────
		"get_state":
			result = _get_state()
		"solid_at":
			result = {"solid": _net.core.solid_at(parsed.get("x", 0.0), parsed.get("y", 0.0)),
				"density": _net.core.density_at(parsed.get("x", 0.0), parsed.get("y", 0.0))}
		# ─── actions (converge on net outgoing layer) ───
		"set_input":
			_net.input = {
				"left": bool(parsed.get("left", false)),
				"right": bool(parsed.get("right", false)),
				"jump": bool(parsed.get("jump", false)),
			}
			result = _get_state()
		"set_aim":
			_net.aim = Vector2(parsed.get("x", _net.aim.x), parsed.get("y", _net.aim.y))
			result = _get_state()
		"shoot":
			if parsed.has("aimX") and parsed.has("aimY"):
				_net.aim = Vector2(parsed["aimX"], parsed["aimY"])
			_net.send_shoot()
			result = _get_state()
		"set_weapon":
			_net.send_weapon(parsed.get("w", "pistol"))
			result = _get_state()
		"draw_stroke":
			_net.send_draw(parsed.get("x0", 0.0), parsed.get("y0", 0.0),
				parsed.get("x1", 0.0), parsed.get("y1", 0.0))
			result = await _wait_frames(2)
		"redraw":
			_net.send_redraw()
			result = _get_state()
		"wait_frames":
			result = await _wait_frames(int(parsed.get("frames", parsed.get("n", 10))))
		_:
			result = {"error": "Unknown command: %s" % cmd}

	_send(result)


func _wait_frames(n: int) -> Dictionary:
	for _i in maxi(1, n):
		await get_tree().process_frame
	return _get_state()


func _send(data: Dictionary) -> void:
	if _client == null:
		return
	_client.put_data((JSON.stringify(data) + "\n").to_utf8_buffer())


func _get_state() -> Dictionary:
	var n := _net
	var state := {
		"open": n.is_open(),
		"ai_mode": ai_mode,
		"id": n.my_id,
		"arena": n.my_arena,
		"role": n.my_role,
		"queue_pos": n.queue_pos,
		"phase": n.phase,
		"timeLeft": n.time_left,
		"weapon": n.current_weapon,
		"ink": int(n.my_ink),
		"have_self": n.have_self,
		"player": {
			"x": n.self_p["x"], "y": n.self_p["y"],
			"vx": n.self_p["vx"], "vy": n.self_p["vy"],
			"face": n.self_p["face"], "onGround": n.self_p["onGround"],
			"hp": n.self_stats["hp"], "alive": bool(n.self_stats["a"]),
			"kills": n.self_stats["k"], "respawn": n.self_stats["rs"],
			"guarded": bool(n.self_stats.get("gd", 0)),
		},
	}
	# remote players (latest interpolation sample) — "enemies" for AI targeting
	var enemies: Array = []
	for pid in n.interp:
		var buf: Array = n.interp[pid]
		if buf.is_empty():
			continue
		var l: Dictionary = buf[buf.size() - 1]
		enemies.append({"id": pid, "x": l["x"], "y": l["y"], "hp": l["hp"],
			"kills": l["k"], "alive": bool(l["a"])})
	state["enemies"] = enemies
	# bullets in flight
	var bl: Array = []
	for b: Dictionary in n.bullets:
		bl.append({"x": b.get("x", 0), "y": b.get("y", 0)})
	state["bullets"] = bl
	return state
