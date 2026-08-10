## Headless end-to-end smoke test for Phase A: connect the Godot client to the
## running Node server, wait for welcome + snapshot + state, print result, quit.
## Run: godot --headless --path godot --script res://tools/smoke_test.gd -- --server=ws://127.0.0.1:2567
extends SceneTree

var core: Core
var net: NetClient
var frames := 0
var url := "ws://127.0.0.1:2567"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server="):
			url = arg.substr("--server=".length())
	core = Core.new()
	core.build_base()
	net = NetClient.new()
	net.setup(core, url)
	root.add_child(net)
	net.connect_to_server()
	print("[smoke] connecting to ", url)


func _process(_delta: float) -> bool:
	frames += 1
	# success: connected, got an id, and at least one state frame settled
	if net.is_open() and net.my_id != 0 and frames > 40:
		var players := net.interp.size() + (1 if net.have_self else 0)
		print("[smoke] OK id=%d arena=%d role=%s phase=%s players=%d ink=%d field0=%.3f mesh=%d" % [
			net.my_id, net.my_arena, net.my_role, net.phase, players,
			int(net.my_ink), core.field[0], core.remesh_all().size()])
		return true
	if frames > 300:  # ~5s safety net
		print("[smoke] TIMEOUT open=%s id=%d" % [net.is_open(), net.my_id])
		return true
	return false
