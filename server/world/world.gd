extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const MASTER_LOSS_SHUTDOWN_SECONDS := 3.0
const MASTER_REGISTRATION_TIMEOUT_SECONDS := 3.0
const JOIN_TICKET_WAIT_SECONDS := 1.0

var world_api: MultiplayerAPI
var master_api: MultiplayerAPI
var heartbeat_timer: Timer
var reconnect_timer: Timer
var master_loss_timer: Timer
var registration_timer: Timer
var world_key := NET_CONFIG.initial_world()
var launch_token := ""
var registered_with_master := false
var registration_pending := false
var master_connection_started := false
var world_scene: Node
var connected_players := {}
var pending_players := {}
var expected_join_tickets := {}


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
	$MasterNet/MasterEndpoint.world_shutdown_requested.connect(_on_world_shutdown_requested)
	$MasterNet/MasterEndpoint.world_join_expected.connect(_on_world_join_expected)
	$WorldNet/WorldEndpoint.world_join_authorized.connect(_on_world_join_authorized)

	$WorldNet/WorldEndpoint.configure_server(world_key, _authorize_join)
	_load_world_scene()
	world_api.peer_connected.connect(func(peer_id: int) -> void:
		pending_players[peer_id] = true
		print("[WORLD %s] peer connected: %s" % [world_key, peer_id])
	)
	world_api.peer_disconnected.connect(func(peer_id: int) -> void:
		var was_connected := connected_players.has(peer_id)
		pending_players.erase(peer_id)
		connected_players.erase(peer_id)
		print("[WORLD %s] peer disconnected: %s" % [world_key, peer_id])
		_remove_player(peer_id)
		if was_connected:
			_send_heartbeat()
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
		push_error("[WORLD] expected explicit world key, got no user args")
		get_tree().quit(14)
		return ""
	if args.size() > 2:
		push_error("[WORLD] expected world key plus optional master launch token, got: %s" % str(args))
		get_tree().quit(14)
		return ""
	if args.size() == 2:
		launch_token = str(args[1])
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
	if launch_token.is_empty():
		print("[WORLD %s] no master launch token; running without master registration" % world_key)
		return

	master_connection_started = true
	master_api.connected_to_server.connect(func() -> void:
		print("[WORLD %s] connected to master registry" % world_key)
		_register_with_master()
	)
	master_api.connection_failed.connect(func() -> void:
		push_error("[WORLD %s] failed to connect to master registry" % world_key)
		master_connection_started = false
		registration_pending = false
		_stop_registration_timer()
		_schedule_master_reconnect()
		_start_master_loss_timer()
	)
	master_api.server_disconnected.connect(func() -> void:
		print("[WORLD %s] master registry disconnected" % world_key)
		registered_with_master = false
		registration_pending = false
		master_connection_started = false
		_stop_registration_timer()
		_schedule_master_reconnect()
		_start_master_loss_timer()
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
		_start_master_loss_timer()
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

	master_connection_started = false
	registration_pending = false
	_stop_registration_timer()
	_schedule_master_reconnect()
	_start_master_loss_timer()


func _register_with_master() -> void:
	if registered_with_master or registration_pending:
		return

	registration_pending = true
	$MasterNet/MasterEndpoint.register_world.rpc_id(
		1,
		world_key,
		launch_token
	)
	_start_registration_timer()


func _start_heartbeat() -> void:
	if heartbeat_timer:
		return

	heartbeat_timer = Timer.new()
	heartbeat_timer.name = "MasterHeartbeatTimer"
	heartbeat_timer.wait_time = 1.0
	heartbeat_timer.autostart = true
	heartbeat_timer.timeout.connect(_send_heartbeat)
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
	registration_pending = false
	registered_with_master = true
	_stop_registration_timer()
	_stop_master_loss_timer()
	_start_heartbeat()
	_send_heartbeat()
	print("WORLD_REGISTERED key=%s" % world_key)


func _on_world_join_expected(expected_world_key: String, join_ticket: String, expires_at: float) -> void:
	if expected_world_key != world_key or join_ticket.is_empty():
		return

	expected_join_tickets[join_ticket] = expires_at
	_expire_join_tickets()


func _authorize_join(peer_id: int, join_ticket: String) -> bool:
	if launch_token.is_empty():
		return true

	var elapsed := 0.0
	while elapsed < JOIN_TICKET_WAIT_SECONDS:
		if _consume_join_ticket(join_ticket):
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05

	print("[WORLD %s] rejected peer %s without valid join ticket" % [world_key, peer_id])
	return false


func _consume_join_ticket(join_ticket: String) -> bool:
	_expire_join_tickets()
	if join_ticket.is_empty() or not expected_join_tickets.has(join_ticket):
		return false

	expected_join_tickets.erase(join_ticket)
	return true


func _expire_join_tickets() -> void:
	var now := Time.get_unix_time_from_system()
	for join_ticket in expected_join_tickets.keys():
		if float(expected_join_tickets[join_ticket]) <= now:
			expected_join_tickets.erase(join_ticket)


func _on_world_join_authorized(peer_id: int) -> void:
	if connected_players.has(peer_id):
		return

	pending_players.erase(peer_id)
	connected_players[peer_id] = true
	_spawn_player(peer_id)
	_send_heartbeat()


func _send_heartbeat() -> void:
	if not registered_with_master:
		return

	$MasterNet/MasterEndpoint.world_heartbeat.rpc_id(1, world_key, connected_players.size())


func _start_master_loss_timer() -> void:
	if launch_token.is_empty() or master_loss_timer:
		return

	master_loss_timer = Timer.new()
	master_loss_timer.name = "MasterLossShutdownTimer"
	master_loss_timer.one_shot = true
	master_loss_timer.wait_time = MASTER_LOSS_SHUTDOWN_SECONDS
	master_loss_timer.timeout.connect(func() -> void:
		print("WORLD_STOPPING key=%s reason=master_lost" % world_key)
		get_tree().quit(20)
	)
	add_child(master_loss_timer)
	master_loss_timer.start()


func _stop_master_loss_timer() -> void:
	if not master_loss_timer:
		return

	master_loss_timer.stop()
	master_loss_timer.queue_free()
	master_loss_timer = null


func _start_registration_timer() -> void:
	if registration_timer:
		return

	registration_timer = Timer.new()
	registration_timer.name = "MasterRegistrationTimeoutTimer"
	registration_timer.one_shot = true
	registration_timer.wait_time = MASTER_REGISTRATION_TIMEOUT_SECONDS
	registration_timer.timeout.connect(func() -> void:
		print("WORLD_STOPPING key=%s reason=registration_timeout" % world_key)
		get_tree().quit(21)
	)
	add_child(registration_timer)
	registration_timer.start()


func _stop_registration_timer() -> void:
	if not registration_timer:
		return

	registration_timer.stop()
	registration_timer.queue_free()
	registration_timer = null


func _on_world_shutdown_requested(reason: String) -> void:
	print("WORLD_STOPPING key=%s reason=%s" % [world_key, reason])
	get_tree().quit(0)
