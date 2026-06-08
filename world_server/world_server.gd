extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var world_api: MultiplayerAPI
var master_api: MultiplayerAPI
var heartbeat_timer: Timer
var reconnect_timer: Timer
var world_key := NET_CONFIG.initial_world()
var registered_with_master := false
var master_connection_started := false
var world_scene: Node


func _ready() -> void:
	world_key = _parse_world_key()
	if world_key.is_empty():
		return
	if not NET_CONFIG.is_valid_world_key(world_key):
		push_error("[WORLD] invalid world key '%s'. Expected one of: %s" % [world_key, str(NET_CONFIG.world_keys())])
		get_tree().quit(12)
		return

	world_api = MultiplayerAPI.create_default_interface()
	master_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	get_tree().set_multiplayer(master_api, get_node("MasterNet").get_path())
	$MasterNet/MasterEndpoint.world_registered.connect(_on_world_registered)

	$WorldNet/WorldEndpoint.configure_server(world_key)
	_load_world_scene()
	world_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[WORLD %s] peer connected: %s" % [world_key, peer_id])
		_spawn_player(peer_id)
	)
	world_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[WORLD %s] peer disconnected: %s" % [world_key, peer_id])
		_remove_player(peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var port := NET_CONFIG.world_port(world_key)
	var err := peer.create_server(port)
	if err != OK:
		push_error("[WORLD %s] failed to listen on port %d err=%s" % [world_key, port, err])
		get_tree().quit(13)
		return

	world_api.multiplayer_peer = peer
	print("WORLD_READY key=%s port=%d scene=%s" % [world_key, port, NET_CONFIG.world_scene_path(world_key)])
	_connect_to_master()


func _parse_world_key() -> String:
	var args := OS.get_cmdline_user_args()
	if args.size() == 0:
		return NET_CONFIG.initial_world()
	if args.size() > 1:
		push_error("[WORLD] expected zero or one bare world key argument, got: %s" % str(args))
		get_tree().quit(14)
		return ""
	return str(args[0])


func _load_world_scene() -> void:
	var scene := load(NET_CONFIG.world_scene_path(world_key)) as PackedScene
	world_scene = scene.instantiate()
	$WorldNet/WorldSceneRoot.add_child(world_scene)


func _spawn_player(peer_id: int) -> void:
	if world_scene and world_scene.has_method("spawn_player"):
		world_scene.spawn_player(peer_id)
		print("[WORLD %s] spawned player for peer %s" % [world_key, peer_id])


func _remove_player(peer_id: int) -> void:
	if world_scene and world_scene.has_method("remove_player"):
		world_scene.remove_player(peer_id)


func _connect_to_master() -> void:
	if master_connection_started:
		return
	master_connection_started = true
	master_api.connected_to_server.connect(func() -> void:
		print("[WORLD %s] connected to master registry" % world_key)
		_register_with_master()
	)
	master_api.connection_failed.connect(func() -> void:
		push_error("[WORLD %s] failed to connect to master registry" % world_key)
		master_connection_started = false
		_schedule_master_reconnect()
	)
	master_api.server_disconnected.connect(func() -> void:
		print("[WORLD %s] master registry disconnected" % world_key)
		registered_with_master = false
		master_connection_started = false
		_schedule_master_reconnect()
	)

	_try_connect_to_master()


func _try_connect_to_master() -> void:
	master_connection_started = true

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(NET_CONFIG.master_url())
	if err != OK:
		push_error("[WORLD %s] create_client failed for master registry err=%s" % [world_key, err])
		master_connection_started = false
		_schedule_master_reconnect()
		return

	master_api.multiplayer_peer = peer
	print("[WORLD %s] registering with master at %s" % [world_key, NET_CONFIG.master_url()])
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
		world_key,
		NET_CONFIG.world_registration_secret()
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
		$MasterNet/MasterEndpoint.world_heartbeat.rpc_id(1, world_key)
	)
	add_child(heartbeat_timer)


func _schedule_master_reconnect() -> void:
	if registered_with_master:
		return
	if reconnect_timer:
		return

	reconnect_timer = Timer.new()
	reconnect_timer.name = "MasterReconnectTimer"
	reconnect_timer.one_shot = true
	reconnect_timer.wait_time = 1.0
	reconnect_timer.timeout.connect(func() -> void:
		reconnect_timer.queue_free()
		reconnect_timer = null
		_try_connect_to_master()
	)
	add_child(reconnect_timer)
	reconnect_timer.start()


func _on_world_registered(registered_world_key: String) -> void:
	if registered_world_key != world_key:
		return
	print("WORLD_REGISTERED key=%s" % world_key)
