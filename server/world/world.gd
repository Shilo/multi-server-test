extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const MASTER_LOSS_SHUTDOWN_SECONDS := 3.0
const MASTER_REGISTRATION_TIMEOUT_SECONDS := 3.0
const JOIN_TICKET_WAIT_SECONDS := 1.0
## Fallback only. Normal portal transfers clear when the master reports the
## TravelLease was redeemed or failed; this just prevents permanent local locks.
const TRANSFER_REQUEST_TIMEOUT_SECONDS := 30.0
## How often the world reports live player positions to the master for durable
## saving. The master discards saves for guests and stale worlds.
const POSITION_SAVE_INTERVAL_SECONDS := 3.0

var world_api: MultiplayerAPI
var master_api: MultiplayerAPI
var heartbeat_timer: Timer
var position_save_timer: Timer
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
var authorized_join_metadata := {}
var peer_master_ids := {}
var pending_transfers := {}


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
	$MasterNet/MasterEndpoint.world_transfer_result_received.connect(_on_world_transfer_result_received)
	$WorldNet/WorldEndpoint.world_join_authorized.connect(_on_world_join_authorized)
	$WorldNet/WorldEndpoint.portal_use_requested.connect(_on_portal_use_requested)

	$WorldNet/WorldEndpoint.configure_server(world_key, _authorize_join)
	_load_world_scene()
	world_api.peer_connected.connect(func(peer_id: int) -> void:
		pending_players[peer_id] = true
		NetLog.print_line("[WORLD %s] peer connected: %s" % [world_key, peer_id])
	)
	world_api.peer_disconnected.connect(func(peer_id: int) -> void:
		var was_connected := connected_players.has(peer_id)
		if was_connected:
			_save_player_state(peer_id)
		pending_players.erase(peer_id)
		connected_players.erase(peer_id)
		authorized_join_metadata.erase(peer_id)
		peer_master_ids.erase(peer_id)
		pending_transfers.erase(peer_id)
		NetLog.print_line("[WORLD %s] peer disconnected: %s" % [world_key, peer_id])
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
	NetLog.print_line("WORLD_READY key=%s port=%d scene=%s" % [world_key, port, NET_CONFIG.world_scene_path(world_key)])
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


func _spawn_player(peer_id: int, spawn_position: Vector2, display_name := "", is_guest := true) -> void:
	if world_scene and world_scene.has_method("spawn_player"):
		world_scene.spawn_player(peer_id, spawn_position, display_name, is_guest)
		NetLog.print_line("[WORLD %s] spawned player for peer %s (%s%s)" % [world_key, peer_id, display_name, " guest" if is_guest else ""])


func _remove_player(peer_id: int) -> void:
	if world_scene and world_scene.has_method("remove_player"):
		world_scene.remove_player(peer_id)


func _connect_to_master() -> void:
	if master_connection_started:
		return
	if launch_token.is_empty():
		NetLog.print_line("[WORLD %s] no master launch token; running without master registration" % world_key)
		return

	master_api.connected_to_server.connect(func() -> void:
		NetLog.print_line("[WORLD %s] connected to master registry" % world_key)
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
		NetLog.print_line("[WORLD %s] master registry disconnected" % world_key)
		if _has_no_player_activity():
			NetLog.print_line("WORLD_STOPPING key=%s reason=idle" % world_key)
			get_tree().quit(0)
			return

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
	NetLog.print_line("[WORLD %s] registering with master at %s" % [world_key, NET_CONFIG.master_url()])
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

	position_save_timer = Timer.new()
	position_save_timer.name = "PositionSaveTimer"
	position_save_timer.wait_time = POSITION_SAVE_INTERVAL_SECONDS
	position_save_timer.autostart = true
	position_save_timer.timeout.connect(_save_all_player_states)
	add_child(position_save_timer)


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
	NetLog.print_line("WORLD_REGISTERED key=%s" % world_key)


func _on_world_join_expected(expected_world_key: String, join_ticket: String, expires_at: float, master_peer_id: int, source_world: String, target_portal: String, identity: Dictionary) -> void:
	if expected_world_key != world_key or join_ticket.is_empty():
		return

	expected_join_tickets[join_ticket] = {
		"expires_at": expires_at,
		"master_peer_id": master_peer_id,
		"source_world": source_world,
		"target_portal": target_portal,
		"identity": identity,
	}
	_expire_join_tickets()


func _authorize_join(peer_id: int, join_ticket: String) -> bool:
	if launch_token.is_empty():
		authorized_join_metadata[peer_id] = {
			"master_peer_id": peer_id,
			"source_world": "",
			"target_portal": "",
		}
		return true

	var elapsed := 0.0
	while elapsed < JOIN_TICKET_WAIT_SECONDS:
		var metadata := _consume_join_ticket(join_ticket)
		if not metadata.is_empty():
			authorized_join_metadata[peer_id] = metadata
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05

	NetLog.print_line("[WORLD %s] rejected peer %s without valid join ticket" % [world_key, peer_id])
	return false


func _consume_join_ticket(join_ticket: String) -> Dictionary:
	_expire_join_tickets()
	if join_ticket.is_empty() or not expected_join_tickets.has(join_ticket):
		return {}

	var metadata: Dictionary = expected_join_tickets[join_ticket]
	expected_join_tickets.erase(join_ticket)
	return metadata


func _expire_join_tickets() -> void:
	var now := Time.get_unix_time_from_system()
	for join_ticket in expected_join_tickets.keys():
		var metadata: Dictionary = expected_join_tickets[join_ticket]
		if float(metadata.get("expires_at", 0.0)) <= now:
			expected_join_tickets.erase(join_ticket)


func _on_world_join_authorized(peer_id: int) -> void:
	if connected_players.has(peer_id):
		return

	var metadata: Dictionary = authorized_join_metadata.get(peer_id, {})
	var identity: Dictionary = metadata.get("identity", {})
	var spawn_position := _resolve_spawn_position(metadata, identity)
	if not spawn_position.is_finite():
		NetLog.print_line("[WORLD %s] rejected peer %s due invalid spawn entry" % [world_key, peer_id])
		$WorldNet/WorldEndpoint.reject_world_join.rpc_id(peer_id, world_key, "invalid_spawn_entry")
		_disconnect_world_peer(peer_id)
		return

	pending_players.erase(peer_id)
	connected_players[peer_id] = true
	peer_master_ids[peer_id] = int(metadata.get("master_peer_id", peer_id))
	var display_name := str(identity.get("display_name", "Player_%d" % peer_id))
	var is_guest := bool(identity.get("is_guest", true))
	_spawn_player(peer_id, spawn_position, display_name, is_guest)
	_send_heartbeat()


## Honor a server-known saved spawn (login resume) when present, otherwise fall
## back to the portal/entry-derived spawn for this world.
func _resolve_spawn_position(metadata: Dictionary, identity: Dictionary) -> Vector2:
	if bool(identity.get("has_spawn", false)):
		return Vector2(float(identity.get("spawn_x", 0.0)), float(identity.get("spawn_y", 0.0)))
	if world_scene and world_scene.has_method("spawn_position_from_entry"):
		return world_scene.spawn_position_from_entry(
			str(metadata.get("source_world", "")),
			str(metadata.get("target_portal", ""))
		)
	return Vector2.ZERO


func _on_portal_use_requested(peer_id: int, portal_name: String) -> void:
	_expire_pending_transfers()
	if pending_transfers.has(peer_id):
		NetLog.print_line("[WORLD %s] ignoring duplicate portal request peer=%s portal=%s" % [world_key, peer_id, portal_name])
		return

	if not connected_players.has(peer_id):
		$WorldNet/WorldEndpoint.deny_portal_use.rpc_id(peer_id, portal_name, "not_joined")
		return
	if not world_scene or not world_scene.has_method("player_can_use_portal"):
		$WorldNet/WorldEndpoint.deny_portal_use.rpc_id(peer_id, portal_name, "world_has_no_portals")
		return
	if not world_scene.player_can_use_portal(peer_id, portal_name):
		$WorldNet/WorldEndpoint.deny_portal_use.rpc_id(peer_id, portal_name, "not_at_portal")
		return

	var target_world := ""
	var target_portal := ""
	if world_scene.has_method("portal_target_world"):
		target_world = world_scene.portal_target_world(portal_name)
	if world_scene.has_method("portal_target_portal"):
		target_portal = world_scene.portal_target_portal(portal_name)

	if not NET_CONFIG.is_valid_world_key(target_world):
		$WorldNet/WorldEndpoint.deny_portal_use.rpc_id(peer_id, portal_name, "invalid_target")
		return

	var master_peer_id := int(peer_master_ids.get(peer_id, 0))
	if master_peer_id <= 0:
		$WorldNet/WorldEndpoint.deny_portal_use.rpc_id(peer_id, portal_name, "missing_master_peer")
		return

	pending_transfers[peer_id] = Time.get_unix_time_from_system() + TRANSFER_REQUEST_TIMEOUT_SECONDS
	NetLog.print_line("[WORLD %s] server-approved portal peer=%s master_peer=%s portal=%s target=%s target_portal=%s" % [world_key, peer_id, master_peer_id, portal_name, target_world, target_portal])
	$MasterNet/MasterEndpoint.request_world_transfer.rpc_id(1, world_key, master_peer_id, target_world, target_portal)


func _on_world_transfer_result_received(master_peer_id: int, _target_world: String, _approved: bool) -> void:
	for peer_id in peer_master_ids.keys():
		if int(peer_master_ids[peer_id]) == master_peer_id:
			pending_transfers.erase(peer_id)
			return


func _expire_pending_transfers() -> void:
	var now := Time.get_unix_time_from_system()
	for peer_id in pending_transfers.keys():
		if float(pending_transfers[peer_id]) <= now:
			pending_transfers.erase(peer_id)


func _send_heartbeat() -> void:
	if not registered_with_master:
		return

	$MasterNet/MasterEndpoint.world_heartbeat.rpc_id(1, world_key, connected_players.size())


func _save_all_player_states() -> void:
	for peer_id in connected_players.keys():
		_save_player_state(int(peer_id))


## Report one player's live position to the master so it can be persisted. The
## world is the position authority; the master decides whether the account is
## durable (guests are skipped) and whether the world matches the player's
## current session.
func _save_player_state(peer_id: int) -> void:
	if not registered_with_master:
		return
	var master_peer_id := int(peer_master_ids.get(peer_id, 0))
	if master_peer_id <= 0:
		return
	if not world_scene or not world_scene.has_method("player_position"):
		return
	var position: Vector2 = world_scene.player_position(peer_id)
	if not position.is_finite():
		return
	$MasterNet/MasterEndpoint.save_player_state.rpc_id(1, master_peer_id, world_key, position.x, position.y)


func _has_no_player_activity() -> bool:
	_expire_join_tickets()
	_expire_pending_transfers()
	return (
		connected_players.is_empty()
		and pending_players.is_empty()
		and expected_join_tickets.is_empty()
		and pending_transfers.is_empty()
	)


func _disconnect_world_peer(peer_id: int) -> void:
	pending_players.erase(peer_id)
	authorized_join_metadata.erase(peer_id)
	peer_master_ids.erase(peer_id)
	var peer := world_api.multiplayer_peer
	if peer and peer.has_method("disconnect_peer"):
		peer.disconnect_peer(peer_id)


func _start_master_loss_timer() -> void:
	if launch_token.is_empty() or master_loss_timer:
		return

	master_loss_timer = Timer.new()
	master_loss_timer.name = "MasterLossShutdownTimer"
	master_loss_timer.one_shot = true
	master_loss_timer.wait_time = MASTER_LOSS_SHUTDOWN_SECONDS
	master_loss_timer.timeout.connect(func() -> void:
		NetLog.print_line("WORLD_STOPPING key=%s reason=master_lost" % world_key)
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
		NetLog.print_line("WORLD_STOPPING key=%s reason=registration_timeout" % world_key)
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
	NetLog.print_line("WORLD_STOPPING key=%s reason=%s" % [world_key, reason])
	get_tree().quit(0)
