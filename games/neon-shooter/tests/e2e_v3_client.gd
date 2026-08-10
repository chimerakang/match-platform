extends SceneTree

## Live end-to-end client for the V3 gateway: connects a real NetClientV3 to a
## running server_main over WebSocket and verifies the full handshake and one
## command round-trip — hello→welcome→join→seat→checkpoint→state, then a draw
## command that comes back as an authoritative terrain (stroke) event.

const NetClientV3 = preload("res://games/neon-shooter/client/net_client_v3.gd")

var core: Core
var net: NetClientV3
var checks := 0
var failures: Array[String] = []

var _elapsed := 0.0
var _timeout := 12.0
var _got_state := false
var _got_stroke := false
var _draw_sent := false
var _done := false


func _initialize() -> void:
	var url := _env("PS_URL", "ws://127.0.0.1:2567")
	core = Core.new()
	core.build_base()
	net = NetClientV3.new()
	net.setup(core, url)
	net.terrain_dirty.connect(func() -> void: _got_stroke = true)
	root.add_child(net)
	net.connect_to_server()


func _process(delta: float) -> bool:
	if _done:
		return true
	_elapsed += delta

	if net.have_self and int(net.time_left) >= 0 and net._server_tick > 0:
		_got_state = true
	# Once seated, paint a stroke; the server must echo an authoritative terrain
	# event back to us (command → adapter → event → client).
	if net.have_self and not _draw_sent and net.phase == "draw":
		net.send_draw(500.0, 500.0, 560.0, 500.0)
		net.send_draw(560.0, 500.0, 620.0, 500.0)
		_draw_sent = true

	if (net.have_self and _got_state and _got_stroke) or _elapsed >= _timeout:
		_finish()
		return true
	return false


func _finish() -> void:
	_done = true
	_check(net.is_open(), "client established a WebSocket connection")
	_check(net.have_self, "client seated and received its slot + checkpoint", net.my_id)
	_check(net.my_id in ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"], "assigned a participant slot", net.my_id)
	_check(net._server_tick > 0, "received authoritative state ticks", net._server_tick)
	_check(_got_stroke, "draw command round-tripped as an authoritative terrain event")
	if failures.is_empty():
		print("PASS: %d neon-shooter V3 e2e checks" % checks)
		quit(0)
	else:
		print("FAIL: %d/%d neon-shooter V3 e2e checks failed" % [failures.size(), checks])
		for failure: String in failures:
			print(" - %s" % failure)
		quit(1)


func _check(condition: bool, message: String, evidence: Variant = null) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: %s evidence=%s" % [message, JSON.stringify(evidence)])


static func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name).strip_edges()
	return value if not value.is_empty() else fallback
