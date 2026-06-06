extends Node

const CLI_ARGS := preload("res://shared/cli_args.gd")
const NET_CONFIG := preload("res://shared/net_config.gd")

var world_api: MultiplayerAPI
var master_api: MultiplayerAPI
var heartbeat_timer: Timer
var world_id := 1
var registered_with_master := false
var world_scene: Node

func _ready() -> void:
	world_api = MultiplayerAPI.create_default_interface()
	master_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	get_tree().set_multiplayer(master_api, get_node("MasterNet").get_path())
	var args := OS.get_cmdline_user_args()
	world_id = int(CLI_ARGS.get_value(args, "world", "1"))
	if not NET_CONFIG.WORLD_PORTS.has(world_id):
		push_error("[WORLD] invalid --world %d" % world_id)
		get_tree().quit(12)
		return

	$WorldNet/WorldEndpoint.configure_server(world_id)
	_load_world_scene()
	world_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[WORLD %d] peer connected: %s" % [world_id, peer_id])
		_spawn_player(peer_id)
	)
	world_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[WORLD %d] peer disconnected: %s" % [world_id, peer_id])
		_remove_player(peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var port: int = NET_CONFIG.WORLD_PORTS[world_id]
	var err := peer.create_server(port, NET_CONFIG.HOST)
	if err != OK:
		push_error("[WORLD %d] failed to listen on %s:%d err=%s" % [world_id, NET_CONFIG.HOST, port, err])
		get_tree().quit(13)
		return

	world_api.multiplayer_peer = peer
	print("WORLD_READY id=%d port=%d scene=%s" % [world_id, port, NET_CONFIG.world_scene_path(world_id)])
	_connect_to_master()


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


func _connect_to_master() -> void:
	master_api.connected_to_server.connect(func() -> void:
		print("[WORLD %d] connected to master registry" % world_id)
		_register_with_master()
	, CONNECT_ONE_SHOT)
	master_api.connection_failed.connect(func() -> void:
		push_error("[WORLD %d] failed to connect to master registry" % world_id)
	, CONNECT_ONE_SHOT)
	master_api.server_disconnected.connect(func() -> void:
		print("[WORLD %d] master registry disconnected" % world_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(NET_CONFIG.master_url())
	if err != OK:
		push_error("[WORLD %d] create_client failed for master registry err=%s" % [world_id, err])
		return

	master_api.multiplayer_peer = peer
	print("[WORLD %d] registering with master at %s" % [world_id, NET_CONFIG.master_url()])
	_wait_for_master_connection(peer)


func _wait_for_master_connection(peer: WebSocketMultiplayerPeer) -> void:
	var elapsed := 0.0
	while elapsed < 5.0:
		if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_register_with_master()
			return
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05


func _register_with_master() -> void:
	if registered_with_master:
		return

	registered_with_master = true
	$MasterNet/MasterEndpoint.register_world.rpc_id(
		1,
		world_id,
		NET_CONFIG.world_endpoint(world_id),
		NET_CONFIG.allowed_targets(world_id)
	)
	_start_heartbeat()


func _start_heartbeat() -> void:
	if heartbeat_timer:
		return

	heartbeat_timer = Timer.new()
	heartbeat_timer.name = "MasterHeartbeatTimer"
	heartbeat_timer.wait_time = 1.0
	heartbeat_timer.autostart = true
	heartbeat_timer.timeout.connect(func() -> void:
		$MasterNet/MasterEndpoint.world_heartbeat.rpc_id(1, world_id)
	)
	add_child(heartbeat_timer)
