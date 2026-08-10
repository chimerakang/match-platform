## Screen-space HUD, hosted on a CanvasLayer so the world Camera2D (#14) never
## moves it. Split out of arena.gd when the world grew to 1920×1200 while the
## window stayed 960×600 — HUD positions use the *viewport* size, not Core.W/H
## (which is now world size, not screen size).
extends Node2D

var net: NetClientV3
var _font: Font


func setup(n: NetClientV3) -> void:
	net = n
	_font = ThemeDB.fallback_font


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	if net == null:
		return
	var vp := get_viewport().get_visible_rect().size   # window (960×600), not world
	var w := vp.x
	var h := vp.y

	# phase + timer
	var timer_txt := "%ds" % ceili(net.time_left)
	draw_string(_font, Vector2(22, 40), timer_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color("#d8ffe4"))

	if net.phase == "draw":
		draw_string(_font, Vector2(24, 66), "PAINT TERRAIN", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("#8fe8ff"))
		var bx := 22.0
		var by := 80.0
		var bw := 200.0
		draw_rect(Rect2(bx, by, bw, 10), Color("#22ff66"), false, 1.0)
		var frac: float = maxf(0.0, net.my_ink / float(Core.INK_MAX))
		draw_rect(Rect2(bx + 1, by + 1, (bw - 2) * frac, 8), Color("#7dffb0"))
	elif net.phase == "battle":
		# weapon row
		var order: Array = Core.WEAPON_ORDER
		var gap := 90.0
		var x0 := w / 2.0 - (order.size() - 1) * gap / 2.0
		for idx in order.size():
			var key: String = order[idx]
			var wd: Dictionary = Core.WEAPONS[key]
			var sel := key == net.current_weapon
			var c := Color(wd["color"]) if sel else Color(0.47, 0.78, 0.63, 0.5)
			draw_string(_font, Vector2(x0 + idx * gap - 24, 26), "%d %s" % [idx + 1, wd["name"]],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, c)
		# hp / respawn
		if net.have_self:
			if net.self_stats["a"]:
				var bw := 170.0
				var bx := w / 2.0 - bw / 2.0
				var by := h - 40.0
				draw_rect(Rect2(bx, by, bw, 9), Color("#22ff66"), false, 1.0)
				var hpf: float = maxf(0.0, float(net.self_stats["hp"]) / float(Core.HP_MAX))
				var hc := Color("#7dffb0") if net.self_stats["hp"] > 35 else Color("#ff6b6b")
				draw_rect(Rect2(bx + 1, by + 1, (bw - 2) * hpf, 7), hc)
			else:
				draw_string(_font, Vector2(w / 2.0, h / 2.0),
					"DOWN · respawn %d" % net.self_stats["rs"],
					HORIZONTAL_ALIGNMENT_CENTER, -1, 28, Color("#ff8f8f"))

	# scoreboard (self + remotes)
	var board: Array = []
	if net.have_self:
		board.append({"me": true, "color": net.my_color, "k": net.self_stats["k"]})
	for pid in net.interp:
		var buf: Array = net.interp[pid]
		if not buf.is_empty():
			var l: Dictionary = buf[buf.size() - 1]
			board.append({"me": false, "color": l["color"], "k": l["k"]})
	board.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["k"] > b["k"])
	var sy := 30.0
	for r: Dictionary in board:
		var prefix := "> " if r["me"] else ""
		draw_string(_font, Vector2(w - 90, sy), "%s%d" % [prefix, r["k"]],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(r["color"]))
		sy += 20.0

	# queue banner
	if net.my_role == "queue":
		draw_string(_font, Vector2(w / 2.0, 128), "IN QUEUE · #%d" % net.queue_pos,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 24, Color("#ffe08f"))

	# connection status
	var status := "connecting…"
	if net.is_open():
		var phase_en: String = {"draw": "Draw", "battle": "Battle", "results": "Results"}.get(net.phase, "")
		status = "Arena %d · %s" % [net.my_arena, phase_en]
	draw_string(_font, Vector2(22, h - 12), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#88aacc"))
