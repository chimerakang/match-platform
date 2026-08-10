## Main scene: renders the shared density field (Marching Squares), players,
## bullets and a minimal HUD, and feeds Input-Action input to the net client.
## Phase A goal: connect to the existing Node server and behave like client.js.
## ALL gameplay input goes through Godot Input Actions (keyboard + gamepad share
## the same actions) — analog aim reads the right stick directly.
extends Node2D

# Fallback production server for web builds when CI didn't inject window.PS_SERVER.
const DEFAULT_WEB_SERVER := "wss://hatice.me:9445"

var core: Core
var net: NetClientV3
var _mesh := PackedVector2Array()
var _mesh_dirty := true
var _font: Font
# #14 卷軸相機：世界 1920×1200 > 視窗 960×600。battle 跟隨本機玩家(zoom 1)，
# draw/結算/排隊則 zoom out 看整個戰場。HUD 放獨立 CanvasLayer 不受相機影響。
var _cam: Camera2D
var _hud: Node

# draw-phase brushing
var _drawing := false
var _last_draw := Vector2.ZERO
# transient fx: particles + floating pops (crater/kill feedback)
var _parts: Array = []
var _pops: Array = []


func _ready() -> void:
	_font = ThemeDB.fallback_font
	core = Core.new()
	core.build_base()

	net = NetClientV3.new()
	add_child(net)
	net.setup(core, _server_url())
	net.terrain_dirty.connect(func() -> void: _mesh_dirty = true)
	net.snapshot_applied.connect(func() -> void: _mesh_dirty = true)
	net.crater_fx.connect(_on_crater)
	net.kill_fx.connect(_on_kill)
	net.connect_to_server()

	# #14 相機：跟隨本機玩家、torus 接縫由 _draw 的位移迴圈處理
	_cam = Camera2D.new()
	_cam.position_smoothing_enabled = true
	_cam.position_smoothing_speed = 10.0
	_cam.zoom = _fit_zoom()
	_cam.position = Vector2(Core.W / 2.0, Core.H / 2.0)
	add_child(_cam)
	_cam.make_current()

	# HUD 移到 CanvasLayer → 固定螢幕、不隨相機捲動 / 縮放
	var hud_layer := CanvasLayer.new()
	add_child(hud_layer)
	_hud = preload("res://games/neon-shooter/client/hud.gd").new()
	hud_layer.add_child(_hud)
	_hud.setup(net)

	# Phase B: let the AI test server drive this live client.
	AiTestServer.attach(self, net)


# 讓整個世界塞進視窗的縮放（draw/結算/排隊用）；960/1920 = 0.5
func _fit_zoom() -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(vp.x / float(Core.W), vp.y / float(Core.H))


func _server_url() -> String:
	# override with: godot ... -- --server=ws://host:port
	# native/editor: --server=... user arg, else PS_SERVER env
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server="):
			return arg.substr("--server=".length())
	var env := OS.get_environment("PS_SERVER")
	if env != "":
		return env
	# web build (itch.io): CI injects `window.PS_SERVER` into index.html (see
	# deploy workflow), pointing at the production server. Fallback default if unset.
	if OS.has_feature("web"):
		var injected: Variant = JavaScriptBridge.eval("window.PS_SERVER || ''", true)
		if injected is String and injected != "":
			return injected
		return DEFAULT_WEB_SERVER
	return "ws://127.0.0.1:2567"


func _process(delta: float) -> void:
	_update_input()
	_update_fx(delta)
	_update_camera(delta)
	if _mesh_dirty:
		_mesh = core.remesh_all()
		_mesh_dirty = false
		net.dirty.clear()
	queue_redraw()


# battle → 跟隨本機玩家(含前瞻)、zoom 1；其餘 → 置中看全場、zoom fit。
# torus：目標位置解到離現在相機最近的環繞副本，避免玩家跨接縫時相機橫掃整張圖。
func _update_camera(delta: float) -> void:
	var target_pos: Vector2
	var target_zoom: Vector2
	if net.phase == "battle" and net.have_self and net.my_role == "player":
		var p := Vector2(net.self_p["x"], net.self_p["y"])
		var look := Vector2(float(net.self_p["face"]) * 90.0 + clampf(net.self_p["vx"], -160.0, 160.0) * 0.35, 0.0)
		target_pos = p + look
		target_zoom = Vector2.ONE
	else:
		target_pos = Vector2(Core.W / 2.0, Core.H / 2.0)
		target_zoom = _fit_zoom()
	target_pos.x = _nearest_wrap(_cam.position.x, target_pos.x, float(Core.W))
	target_pos.y = _nearest_wrap(_cam.position.y, target_pos.y, float(Core.H))
	_cam.position = target_pos
	_cam.zoom = _cam.zoom.lerp(target_zoom, clampf(delta * 6.0, 0.0, 1.0))


# 回傳 val 加減整數個 period 後，離 ref 最近的值（torus 展開）
func _nearest_wrap(ref: float, val: float, period: float) -> float:
	while val - ref > period / 2.0:
		val -= period
	while val - ref < -period / 2.0:
		val += period
	return val


# ─── Input (all through Input Actions; aim via right stick or mouse) ──
func _update_input() -> void:
	# AI test server owns input while in control — skip human input entirely.
	if AiTestServer.ai_mode:
		return

	net.input = {
		"left": Input.is_action_pressed("ps_left"),
		"right": Input.is_action_pressed("ps_right"),
		"jump": Input.is_action_pressed("ps_jump"),
	}

	# Aim: right stick if deflected, else mouse position (world == screen here).
	var rstick := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if rstick.length() > 0.3 and net.have_self:
		var origin := Vector2(net.self_p["x"], net.self_p["y"] - 6)
		net.aim = origin + rstick.normalized() * 120.0
	else:
		# 相機下滑鼠螢幕座標 → 世界座標（含 zoom / 卷軸位移）
		net.aim = get_global_mouse_position()

	if net.my_role != "player":
		return

	if net.phase == "draw":
		# hold ps_shoot (mouse-left / gamepad) to paint terrain
		if Input.is_action_pressed("ps_shoot"):
			var w := net.aim
			if not _drawing:
				_drawing = true
				_last_draw = w
				net.send_draw(w.x, w.y, w.x, w.y)
			else:
				net.send_draw(_last_draw.x, _last_draw.y, w.x, w.y)
				_last_draw = w
		else:
			_drawing = false
	else:
		_drawing = false
		if Input.is_action_just_pressed("ps_shoot") and net.self_stats["a"]:
			net.send_shoot()

	# Q / 搖桿 button 9：循環切換
	if Input.is_action_just_pressed("ps_weapon_next"):
		var order: Array = Core.WEAPON_ORDER
		var idx := order.find(net.current_weapon)
		net.send_weapon(order[(idx + 1) % order.size()])
	# 數字鍵 1-4：直選（對齊 HUD 的「1 Pistol 2 Shotgun…」與 JS 版）
	for i in Core.WEAPON_ORDER.size():
		if Input.is_action_just_pressed("ps_weapon_%d" % (i + 1)):
			net.send_weapon(Core.WEAPON_ORDER[i])


# ─── FX (crater/kill feedback, cosmetic only) ──
func _on_crater(pos: Vector2, _r: float) -> void:
	_pops.append({"pos": pos, "vy": -40.0, "life": 0.9, "txt": "+"})
	for i in 18:
		var a := randf() * TAU
		var s := 40.0 + randf() * 240.0
		_parts.append({"pos": pos, "vel": Vector2(cos(a) * s, sin(a) * s - 60.0), "life": 0.4 + randf() * 0.5})

func _on_kill(pos: Vector2) -> void:
	_pops.append({"pos": pos, "vy": -30.0, "life": 1.0, "txt": "x"})
	for i in 26:
		var a := randf() * TAU
		var s := 60.0 + randf() * 300.0
		_parts.append({"pos": pos, "vel": Vector2(cos(a) * s, sin(a) * s - 40.0), "life": 0.5 + randf() * 0.5})

func _update_fx(dt: float) -> void:
	for i in range(_parts.size() - 1, -1, -1):
		var p: Dictionary = _parts[i]
		p["life"] -= dt
		p["vel"].y += 800.0 * dt
		p["pos"] += p["vel"] * dt
		if p["life"] <= 0.0:
			_parts.remove_at(i)
	for i in range(_pops.size() - 1, -1, -1):
		var p: Dictionary = _pops[i]
		p["life"] -= dt
		p["pos"].y += p["vy"] * dt
		if p["life"] <= 0.0:
			_pops.remove_at(i)


# ─── Rendering ──
func _draw() -> void:
	# torus 接縫：依相機視野決定要畫世界的哪些 ±W/±H 環繞副本，每個副本用
	# draw_set_transform 位移後畫整個世界（相機自身處理 zoom / 卷軸）。
	var view := _camera_view_rect()
	for off: Vector2 in _wrap_offsets(view):
		draw_set_transform(off, 0.0, Vector2.ONE)
		_draw_world()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# HUD 已移到 CanvasLayer（hud.gd），不在世界層畫


func _draw_world() -> void:
	# terrain
	if _mesh.size() >= 2:
		draw_multiline(_mesh, Color("#b6ffcf"), 2.0)

	# no-draw zones during draw phase（前 12 個是 per-spawn，其後 4 個是邊框不畫）
	if net.phase == "draw":
		for r: Rect2 in Core.NO_DRAW.slice(0, 12):
			draw_rect(r, Color(1, 0.27, 0.27, 0.45), false, 1.0)

	# remote players（環繞由外層位移迴圈處理，這裡直接畫世界座標）
	var rt := Time.get_ticks_msec() - net.INTERP_MS
	for pid in net.interp:
		var s: Dictionary = net.sample_interp(net.interp[pid], rt)
		if s.is_empty():
			continue
		var alpha := 1.0 if s["a"] else 0.22
		var pt := Vector2(s["x"], s["y"])
		_draw_stick(pt, s["face"], Color(s["color"]), alpha)
		if s.get("gd", 0) != 0:
			_draw_guard_ring(pt, Color(s["color"]))

	# local player (predicted, zero-latency)
	if net.have_self:
		var alpha := 1.0 if net.self_stats["a"] else 0.22
		var sp := Vector2(net.self_p["x"], net.self_p["y"])
		_draw_stick(sp, net.self_p["face"], Color(net.my_color), alpha)
		if net.self_stats.get("gd", 0) != 0:
			_draw_guard_ring(sp, Color(net.my_color))
		# aim line
		if net.phase == "battle" and net.self_stats["a"]:
			var origin := Vector2(sp.x, sp.y - 6)
			var dir := (net.aim - origin)
			if dir.length() > 0.001:
				dir = dir.normalized()
			draw_line(origin, origin + dir * 60.0, Color(1, 1, 1, 0.35), 1.0)

	# bullets
	for b: Dictionary in net.bullets:
		var bp := Vector2(b.get("x", 0), b.get("y", 0))
		var bd := Vector2(b.get("dx", 0), b.get("dy", 0))
		draw_line(bp, bp - bd * 10.0, Color(b.get("c", "#ffffff")), 2.0)

	# particles + pops
	for p: Dictionary in _parts:
		draw_rect(Rect2(p["pos"] - Vector2.ONE, Vector2(2, 2)), Color(0.92, 1, 0.94, maxf(0, p["life"])))
	for p: Dictionary in _pops:
		draw_string(_font, p["pos"], p["txt"], HORIZONTAL_ALIGNMENT_CENTER, -1, 16,
			Color(0.87, 1, 0.91, maxf(0, p["life"])))


# 相機目前看到的世界矩形（含 zoom 與卷軸；供接縫副本判斷）
func _camera_view_rect() -> Rect2:
	var world_size: Vector2 = get_viewport_rect().size / _cam.zoom
	var center: Vector2 = _cam.get_screen_center_position()
	return Rect2(center - world_size / 2.0, world_size)


# 涵蓋相機視野的所有「整數週期」位移（torus 接縫）。相機跟隨會累積漂移到
# 世界外好幾個週期，所以不能只查 ±1 週期，要依實際視野算出需要的 k*W / k*H。
func _wrap_offsets(view: Rect2) -> Array:
	var offs: Array = []
	var kx0 := int(floor(view.position.x / Core.W))
	var kx1 := int(floor(view.end.x / Core.W))
	var ky0 := int(floor(view.position.y / Core.H))
	var ky1 := int(floor(view.end.y / Core.H))
	for kx in range(kx0, kx1 + 1):
		for ky in range(ky0, ky1 + 1):
			offs.append(Vector2(kx * Core.W, ky * Core.H))
	if offs.is_empty():
		offs.append(Vector2.ZERO)
	return offs


func _draw_stick(pos: Vector2, face: int, col: Color, alpha: float) -> void:
	col.a = alpha
	var f := float(face)
	var lp := func(ax: float, ay: float, bx: float, by: float) -> void:
		draw_line(pos + Vector2(ax * f, ay), pos + Vector2(bx * f, by), col, 2.0)
	draw_arc(pos + Vector2(0, -11), 4.0, 0, TAU, 12, col, 2.0)
	lp.call(0, -7, 0, 4)
	lp.call(0, -3, 7, -1)
	lp.call(0, -3, -5, 2)
	lp.call(0, 4, -5, 14)
	lp.call(0, 4, 5, 14)


## Spawn-invulnerability shield: a pulsing ring around a guarded player.
func _draw_guard_ring(pos: Vector2, col: Color) -> void:
	var pulse := 0.55 + 0.35 * sin(Time.get_ticks_msec() / 90.0)
	var ring := Color(col.r, col.g, col.b, pulse)
	draw_arc(pos + Vector2(0, -2), 16.0, 0, TAU, 24, ring, 2.0)


