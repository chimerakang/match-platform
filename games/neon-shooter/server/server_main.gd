extends SceneTree

## Neon-platform-shooter authoritative server host: a thin WebSocket transport
## shell around ShooterLobby (multi-arena + rotation lobby on Match Platform V3).
## The lobby owns all game/platform logic; this file only terminates WebSocket and
## pumps bytes both ways, so the same lobby code is exercised by the unit tests.

const ShooterLobby = preload("res://games/neon-shooter/server/shooter_lobby.gd")

var lobby: ShooterLobby
var _server := TCPServer.new()
var _peers: Dictionary = {}   # peer_id -> WebSocketPeer
var _next_peer := 1
var _running := true


func _initialize() -> void:
	var port := int(_env("PS_PORT", "2567"))
	var bind := _env("PS_BIND", "127.0.0.1")
	var seed := int(_env("PS_SEED", "1337"))
	var arenas := int(_env("PS_ARENAS", "3"))
	lobby = ShooterLobby.new(arenas, seed, _send_to_peer)
	var err := _server.listen(port, bind)
	if err != OK:
		push_error("[neon-server] listen(%s:%d) failed: %d" % [bind, port, err])
		_running = false
		quit(1)
		return
	print("[neon-server] listening on %s:%d (arenas=%d tick=30)" % [bind, port, arenas])


func _process(delta: float) -> bool:
	if not _running:
		return true
	_accept_connections()
	_poll_peers()
	lobby.tick(delta)
	return false


func _finalize() -> void:
	_server.stop()


func _accept_connections() -> void:
	while _server.is_connection_available():
		var conn := _server.take_connection()
		var ws := WebSocketPeer.new()
		if ws.accept_stream(conn) != OK:
			continue
		_peers[_next_peer] = ws
		_next_peer += 1


func _poll_peers() -> void:
	for peer_id: int in _peers.keys():
		var ws: WebSocketPeer = _peers[peer_id]
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			if not lobby.sessions.has(peer_id):
				lobby.open_peer(peer_id)
			while ws.get_available_packet_count() > 0:
				lobby.handle_bytes(peer_id, ws.get_packet())
		elif state == WebSocketPeer.STATE_CLOSED:
			if lobby.sessions.has(peer_id):
				lobby.close_peer(peer_id)
			_peers.erase(peer_id)


func _send_to_peer(peer_id: int, bytes: PackedByteArray) -> void:
	var ws: WebSocketPeer = _peers.get(peer_id, null)
	if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send(bytes)


static func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name).strip_edges()
	return value if not value.is_empty() else fallback
