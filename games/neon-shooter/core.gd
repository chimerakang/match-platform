## Shared game core — pure logic, no rendering. Direct port of
## netgame/public/core.js so terrain physics/collision stay identical to the
## Node authoritative server. One Core instance owns one density field
## (client: one; server later: one per Arena). Keeping the field as a member
## avoids PackedFloat32Array copy-on-write surprises.
class_name Core
extends RefCounted

# ─── Arena geometry ───────────────────────────────────────────
# 場景 2×（#14）：世界 1920×1200，視窗仍 960×600（arena.gd 用 Camera2D 卷軸）。
# 玩家物理不變、靠畫地形跨越更大的空間。core.js 必須同步同值。
const W: int = 1920
const H: int = 1200
const CELL: int = 10
const ISO: float = 0.5
const COLS: int = 192         # W / CELL
const ROWS: int = 120         # H / CELL
const NX: int = 193           # COLS + 1
const NY: int = 121           # ROWS + 1
const CH: int = 8             # chunk size (cells)
const CH_COLS: int = 24       # ceil(COLS / CH)
const CH_ROWS: int = 15       # ceil(ROWS / CH)

# ─── Rules / tuning ───────────────────────────────────────────
const DRAW_TIME: int = 30
const INK_MAX: int = 1400
const BRUSH: float = 9.0
const PHYS_SPEED: float = 220.0
const PHYS_JUMP: float = 470.0
const PHYS_GRAV: float = 1400.0
const PHYS_HW: float = 6.0
const PHYS_HH: float = 14.0
const HP_MAX: int = 100
const RESPAWN_MS: int = 2200
const BATTLE_TIME: int = 90
const RESULT_TIME: int = 6
const FRAG_LIMIT: int = 15
const SPAWN_GUARD_MS: int = 1500   # 出生無敵窗（與 core.js 同步）
const BEDROCK_Y: int = H - 24      # 底部基岩帶：打不穿，防止穿地板無限下墜

# 武器表（與 server / JS 前端共用）。cd=冷卻ms, carve=挖洞半徑, splash=火箭範圍
const WEAPONS := {
	"pistol":  {"name": "Pistol",  "pellets": 1, "spread": 0.0,  "speed": 900.0,  "cd": 220, "carve": 22.0, "dmg": 34, "life": 1.2,  "color": "#ffffff"},
	"shotgun": {"name": "Shotgun", "pellets": 6, "spread": 0.42, "speed": 780.0,  "cd": 640, "carve": 15.0, "dmg": 11, "life": 0.42, "color": "#ffd27f"},
	"rocket":  {"name": "Rocket",  "pellets": 1, "spread": 0.0,  "speed": 520.0,  "cd": 950, "carve": 46.0, "dmg": 58, "life": 2.4,  "color": "#ff9f6b", "splash": 64.0, "splashDmg": 38},
	"laser":   {"name": "Laser",   "pellets": 1, "spread": 0.0,  "speed": 1700.0, "cd": 130, "carve": 11.0, "dmg": 15, "life": 0.85, "color": "#9fdfff", "thin": true},
}
const WEAPON_ORDER := ["pistol", "shotgun", "rocket", "laser"]
const PLAYER_COLORS := ["#8fe8ff", "#ff8f8f", "#b6ffcf", "#ffe08f", "#c9a0ff", "#ff9fe0", "#9fffe8", "#ffd0a0"]

# 12 個出生點/平台，3 排散佈於 1920×1200（上 y=300 / 中 y=600 / 下 y=904），
# 填滿放大後的上半空曠區。平台/禁畫框尺寸維持玩家相對大小不變。
const SPAWNS := [
	Vector2(360, 300), Vector2(840, 300), Vector2(1320, 300), Vector2(1800, 300),
	Vector2(480, 600), Vector2(960, 600), Vector2(1440, 600), Vector2(1800, 600),
	Vector2(240, 904), Vector2(720, 904), Vector2(1200, 904), Vector2(1680, 904),
]
# padRects: [x-58, y-4, 116, 20] per spawn
const PAD_RECTS := [
	Rect2(302, 296, 116, 20), Rect2(782, 296, 116, 20), Rect2(1262, 296, 116, 20), Rect2(1742, 296, 116, 20),
	Rect2(422, 596, 116, 20), Rect2(902, 596, 116, 20), Rect2(1382, 596, 116, 20), Rect2(1742, 596, 116, 20),
	Rect2(182, 900, 116, 20), Rect2(662, 900, 116, 20), Rect2(1142, 900, 116, 20), Rect2(1622, 900, 116, 20),
]
# noDraw: [x-80, y-70, 160, 110] per spawn + 4 border strips（邊框用新 W/H）
const NO_DRAW := [
	Rect2(280, 230, 160, 110), Rect2(760, 230, 160, 110), Rect2(1240, 230, 160, 110), Rect2(1720, 230, 160, 110),
	Rect2(400, 530, 160, 110), Rect2(880, 530, 160, 110), Rect2(1360, 530, 160, 110), Rect2(1720, 530, 160, 110),
	Rect2(160, 834, 160, 110), Rect2(640, 834, 160, 110), Rect2(1120, 834, 160, 110), Rect2(1600, 834, 160, 110),
	Rect2(0, 0, 1920, 26), Rect2(0, 1174, 1920, 26), Rect2(0, 0, 26, 1200), Rect2(1894, 0, 26, 1200),
]

var field: PackedFloat32Array


func _init() -> void:
	field = PackedFloat32Array()
	field.resize(NX * NY)


# ─── Wrapping / rects ─────────────────────────────────────────
static func wrap_x(x: float) -> float:
	return x + W if x < 0 else (x - W if x >= W else x)

static func wrap_y(y: float) -> float:
	return y + H if y < 0 else (y - H if y >= H else y)

static func in_rect(x: float, y: float, r: Rect2) -> bool:
	return x >= r.position.x and x <= r.position.x + r.size.x \
		and y >= r.position.y and y <= r.position.y + r.size.y

static func in_no_draw(x: float, y: float) -> bool:
	for r in NO_DRAW:
		if in_rect(x, y, r):
			return true
	return false

# 週期 = 畫面寬 → 左右接縫地形高度一致（環繞無縫）。基準/振幅 ×2 隨世界放大。
static func ground_top(x: float) -> float:
	var k := TAU / W
	return 1096.0 + 28.0 * sin(k * 2.0 * x) + 12.0 * sin(k * 5.0 * x)

static func weapon(name: String) -> Dictionary:
	return WEAPONS.get(name, WEAPONS["pistol"])


# ─── Field build / sampling ───────────────────────────────────
func _v(nx: int, ny: int) -> float:
	return field[ny * NX + nx]

func build_base() -> void:
	for ny in NY:
		var wy := float(ny * CELL)
		for nx in NX:
			var wx := float(nx * CELL)
			var v := 0.5 + (wy - ground_top(wx)) / (2.0 * CELL)
			for r: Rect2 in PAD_RECTS:
				if wx >= r.position.x and wx <= r.position.x + r.size.x \
						and wy >= r.position.y and wy <= r.position.y + r.size.y:
					v = 1.0
			field[ny * NX + nx] = clampf(v, 0.0, 1.0)

# stamp：delta>0 加地形（畫），delta<0 挖洞（破壞）。dirty 為選用髒 chunk 集合
# (Dictionary used as a set); pass null to skip chunk tracking, matching JS `if(dirty)`.
func stamp_field(wx: float, wy: float, radius: float, delta: float, dirty: Variant = null) -> void:
	var r2 := radius * radius
	var a := maxi(0, int(floor((wx - radius) / CELL)))
	var b := mini(NX - 1, int(ceil((wx + radius) / CELL)))
	var c := maxi(0, int(floor((wy - radius) / CELL)))
	var d := mini(NY - 1, int(ceil((wy + radius) / CELL)))
	for ny in range(c, d + 1):
		for nx in range(a, b + 1):
			if delta < 0 and ny * CELL >= BEDROCK_Y:   # 基岩不可挖穿
				continue
			var dx := nx * CELL - wx
			var dy := ny * CELL - wy
			var dd := dx * dx + dy * dy
			if dd > r2:
				continue
			var fall := 1.0 - sqrt(dd) / radius
			var i := ny * NX + nx
			field[i] = clampf(field[i] + delta * fall, 0.0, 1.0)
	if dirty != null:
		var c0x := maxi(0, a - 1)
		var c1x := mini(COLS - 1, b)
		var c0y := maxi(0, c - 1)
		var c1y := mini(ROWS - 1, d)
		var chy := c0y / CH
		while chy <= c1y / CH:
			var chx := c0x / CH
			while chx <= c1x / CH:
				dirty[chy * CH_COLS + chx] = true
				chx += 1
			chy += 1

# 沿筆觸路徑 stamp 一串圓（畫地形）。回傳實際消耗的 ink 長度
func paint_stroke(x0: float, y0: float, x1: float, y1: float, delta: float, dirty: Variant = null) -> float:
	var dist := sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
	var steps := maxi(1, int(ceil(dist / (BRUSH * 0.4))))
	var used := 0.0
	for i in range(1, steps + 1):
		var px := x0 + (x1 - x0) * i / float(steps)
		var py := y0 + (y1 - y0) * i / float(steps)
		if in_no_draw(px, py):
			continue
		stamp_field(px, py, BRUSH, delta, dirty)
		used += BRUSH * 0.4
	return used

func density_at(wx: float, wy: float) -> float:
	wx = fposmod(wx, float(W))      # 環繞取樣 → 碰撞無縫
	wy = fposmod(wy, float(H))
	var gx := wx / CELL
	var gy := wy / CELL
	var cx := int(floor(gx))
	var cy := int(floor(gy))
	var fxr := gx - cx
	var fyr := gy - cy
	var a := _v(cx, cy)
	var b := _v(cx + 1, cy)
	var c := _v(cx, cy + 1)
	var d := _v(cx + 1, cy + 1)
	return (a * (1 - fxr) + b * fxr) * (1 - fyr) + (c * (1 - fxr) + d * fxr) * fyr

func solid_at(x: float, y: float) -> bool:
	return density_at(x, y) >= ISO


# ─── Player physics (server-authoritative sim; client predicts) ──
func _side_hit(p: Dictionary, dir: int) -> bool:
	var x: float = p["x"] + dir * PHYS_HW
	var h := PHYS_HH
	return solid_at(x, p["y"] - h + 4) or solid_at(x, p["y"]) or solid_at(x, p["y"] + h - 5)

func _foot_hit(p: Dictionary) -> bool:
	var y: float = p["y"] + PHYS_HH
	var w := PHYS_HW
	return solid_at(p["x"] - w + 2, y) or solid_at(p["x"], y) or solid_at(p["x"] + w - 2, y)

func _head_hit(p: Dictionary) -> bool:
	var y: float = p["y"] - PHYS_HH
	var w := PHYS_HW
	return solid_at(p["x"] - w + 2, y) or solid_at(p["x"], y) or solid_at(p["x"] + w - 2, y)

func step_player(p: Dictionary, input: Dictionary, dt: float) -> void:
	var mx := 0
	if input.get("left", false):
		mx -= 1
	if input.get("right", false):
		mx += 1
	if mx != 0:
		p["face"] = mx
	p["vx"] = mx * PHYS_SPEED
	if input.get("jump", false) and p.get("onGround", false):
		p["vy"] = -PHYS_JUMP
		p["onGround"] = false

	p["x"] = wrap_x(p["x"] + p["vx"] * dt)
	if mx != 0 and _side_hit(p, mx):
		var climbed := false
		for s in range(1, 9):
			p["y"] -= 1
			if not _side_hit(p, mx):
				climbed = true
				break
		if not climbed:
			p["y"] += 8
			var n := 0
			while _side_hit(p, mx) and n < 40:
				p["x"] = wrap_x(p["x"] - mx)
				n += 1
	p["vy"] += PHYS_GRAV * dt
	p["y"] = wrap_y(p["y"] + p["vy"] * dt)
	if p["vy"] >= 0 and _foot_hit(p):
		var n := 0
		while _foot_hit(p) and n < 52:
			p["y"] -= 1
			n += 1
		p["vy"] = 0
		p["onGround"] = true
	else:
		p["onGround"] = false
		if p["vy"] < 0 and _head_hit(p):
			var n := 0
			while _head_hit(p) and n < 52:
				p["y"] += 1
				n += 1
			p["vy"] = 0
	p["x"] = wrap_x(p["x"])
	p["y"] = wrap_y(p["y"])


# ─── Marching Squares (client render only; server never calls) ──
func _lerp_t(a: float, b: float) -> float:
	var d := b - a
	return 0.5 if absf(d) < 1e-6 else (ISO - a) / d

func _cell_segs(cx: int, cy: int, out: PackedVector2Array) -> void:
	var x0 := float(cx * CELL)
	var y0 := float(cy * CELL)
	var x1 := x0 + CELL
	var y1 := y0 + CELL
	var tl := _v(cx, cy)
	var tr := _v(cx + 1, cy)
	var br := _v(cx + 1, cy + 1)
	var bl := _v(cx, cy + 1)
	var k := 0
	if tl >= ISO: k |= 1
	if tr >= ISO: k |= 2
	if br >= ISO: k |= 4
	if bl >= ISO: k |= 8
	if k == 0 or k == 15:
		return
	var pt := Vector2(x0 + _lerp_t(tl, tr) * CELL, y0)   # Top
	var pr := Vector2(x1, y0 + _lerp_t(tr, br) * CELL)   # Right
	var pb := Vector2(x0 + _lerp_t(bl, br) * CELL, y1)   # Bottom
	var pl := Vector2(x0, y0 + _lerp_t(tl, bl) * CELL)   # Left
	match k:
		1: out.append_array([pl, pt])
		2: out.append_array([pt, pr])
		3: out.append_array([pl, pr])
		4: out.append_array([pr, pb])
		5: out.append_array([pl, pt, pr, pb])
		6: out.append_array([pt, pb])
		7: out.append_array([pl, pb])
		8: out.append_array([pb, pl])
		9: out.append_array([pt, pb])
		10: out.append_array([pt, pr, pb, pl])
		11: out.append_array([pr, pb])
		12: out.append_array([pl, pr])
		13: out.append_array([pt, pr])
		14: out.append_array([pt, pl])

func remesh_chunk(ci: int) -> PackedVector2Array:
	var chx := ci % CH_COLS
	var chy := ci / CH_COLS
	var cx0 := chx * CH
	var cy0 := chy * CH
	var cx1 := mini(COLS, cx0 + CH)
	var cy1 := mini(ROWS, cy0 + CH)
	var out := PackedVector2Array()
	for cy in range(cy0, cy1):
		for cx in range(cx0, cx1):
			_cell_segs(cx, cy, out)
	return out

## Full-arena mesh: all segments for draw_multiline (client convenience).
func remesh_all() -> PackedVector2Array:
	var out := PackedVector2Array()
	for cy in ROWS:
		for cx in COLS:
			_cell_segs(cx, cy, out)
	return out


# ─── Density-field snapshot (mid-join) ────────────────────────
func encode_field() -> PackedByteArray:
	var u := PackedByteArray()
	u.resize(field.size())
	for i in field.size():
		u[i] = int(round(field[i] * 255.0))
	return u

func decode_field(u: PackedByteArray) -> void:
	var n := mini(u.size(), field.size())
	for i in n:
		field[i] = u[i] / 255.0
