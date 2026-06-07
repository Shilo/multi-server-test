extends Node

const CLI_ARGS := preload("res://shared/cli_args.gd")
const NET_CONFIG := preload("res://shared/net_config.gd")

var world_api: MultiplayerAPI
var heartbeat_timer: Timer
var world_id := 1
var port := 0
var world_scene: Node
var nakama_client
var nakama_http_key := "defaulthttpkey"
var orchestrator_url := "http://127.0.0.1:19100"
var orchestrator_key := "localdev-secret"
var valid_peers := {}

func _ready() -> void:
	world_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	var args := OS.get_cmdline_user_args()
	world_id = int(CLI_ARGS.get_value(args, "world", "1"))
	if not NET_CONFIG.WORLD_PORTS.has(world_id):
		push_error("[WORLD] invalid --world %d" % world_id)
		get_tree().quit(12)
		return
	port = int(CLI_ARGS.get_value(args, "port", str(NET_CONFIG.WORLD_PORTS[world_id])))
	orchestrator_url = CLI_ARGS.get_value(args, "orchestrator-url", orchestrator_url)
	orchestrator_key = CLI_ARGS.get_value(args, "orchestrator-key", orchestrator_key)
	var nakama_host := CLI_ARGS.get_value(args, "nakama-host", "127.0.0.1")
	var nakama_port := int(CLI_ARGS.get_value(args, "nakama-port", "7350"))
	var nakama_server_key := CLI_ARGS.get_value(args, "nakama-server-key", "defaultkey")
	nakama_http_key = CLI_ARGS.get_value(args, "nakama-http-key", nakama_http_key)
	nakama_client = Nakama.create_client(nakama_server_key, nakama_host, nakama_port, "http")

	$WorldNet/WorldEndpoint.configure_server(world_id)
	$WorldNet/WorldEndpoint.world_state_requested.connect(_on_world_state_requested)
	_load_world_scene()
	world_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[WORLD %d] peer connected: %s" % [world_id, peer_id])
	)
	world_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[WORLD %d] peer disconnected: %s" % [world_id, peer_id])
		valid_peers.erase(peer_id)
		_remove_player(peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port, NET_CONFIG.HOST)
	if err != OK:
		push_error("[WORLD %d] failed to listen on %s:%d err=%s" % [world_id, NET_CONFIG.HOST, port, err])
		get_tree().quit(13)
		return

	world_api.multiplayer_peer = peer
	print("WORLD_READY id=%d port=%d scene=%s" % [world_id, port, NET_CONFIG.world_scene_path(world_id)])
	_start_heartbeat()


func _load_world_scene() -> void:
	var scene := load(NET_CONFIG.world_scene_path(world_id)) as PackedScene
	world_scene = scene.instantiate()
	$WorldNet/WorldSceneRoot.add_child(world_scene)


func _spawn_player(peer_id: int) -> void:
	if world_scene and world_scene.has_method("spawn_player"):
		world_scene.spawn_player(peer_id)
		print("[WORLD %d] spawned player for peer %s" % [world_id, peer_id])


func _remove_player(peer_id: int) -> void:
	if world_scene and world_scene.has_method("remove_player"):
		world_scene.remove_player(peer_id)


func _on_world_state_requested(peer_id: int, ticket: String) -> void:
	if valid_peers.has(peer_id):
		$WorldNet/WorldEndpoint.send_world_state(peer_id, NET_CONFIG.allowed_targets(world_id))
		return

	var validation := await _validate_ticket(ticket)
	if not bool(validation.get("ok", false)):
		push_error("[WORLD %d] rejected peer %s ticket: %s" % [world_id, peer_id, validation.get("error", "unknown")])
		if world_api.multiplayer_peer:
			world_api.multiplayer_peer.disconnect_peer(peer_id)
		return

	valid_peers[peer_id] = validation.get("user_id", "")
	_spawn_player(peer_id)
	$WorldNet/WorldEndpoint.send_world_state(peer_id, validation.get("allowed_targets", NET_CONFIG.allowed_targets(world_id)))


func _validate_ticket(ticket: String) -> Dictionary:
	var payload := JSON.stringify({
		"ticket": ticket,
		"world_id": world_id,
	})
	var rpc = await nakama_client.rpc_async_with_key(nakama_http_key, "validate_ticket", payload)
	if rpc.is_exception():
		return {"ok": false, "error": rpc.get_exception()._to_string()}

	var json := JSON.new()
	if json.parse(rpc.payload) != OK:
		return {"ok": false, "error": "invalid validate_ticket payload"}
	return json.get_data()


func _start_heartbeat() -> void:
	if heartbeat_timer:
		return

	heartbeat_timer = Timer.new()
	heartbeat_timer.name = "OrchestratorHeartbeatTimer"
	heartbeat_timer.wait_time = 1.0
	heartbeat_timer.autostart = true
	heartbeat_timer.timeout.connect(_send_orchestrator_heartbeat)
	add_child(heartbeat_timer)
	_send_orchestrator_heartbeat()


func _send_orchestrator_heartbeat() -> void:
	var request := HTTPRequest.new()
	add_child(request)
	request.request_completed.connect(func(_result: int, _code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		request.queue_free()
	)

	var body := JSON.stringify({
		"world_id": world_id,
		"player_count": valid_peers.size(),
	})
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"X-Orchestrator-Key: %s" % orchestrator_key,
	])
	request.request("%s/worlds/heartbeat" % orchestrator_url, headers, HTTPClient.METHOD_POST, body)
