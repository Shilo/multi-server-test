extends Node

signal routes_received(routes: Dictionary)
signal transfer_approved(target_world: String, endpoint: Dictionary)
signal transfer_denied(target_world: String)
signal world_registered(world_key: String)
signal world_shutdown_requested(reason: String)
signal world_join_expected(world_key: String, join_ticket: String, expires_at: float)

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const HEARTBEAT_TIMEOUT_SECONDS := 5.0

var registered_worlds := {}
var peer_worlds := {}
var world_last_seen := {}
var world_process_manager: Node


func _ready() -> void:
	var timer := Timer.new()
	timer.name = "WorldHeartbeatExpiryTimer"
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_expire_stale_worlds)
	add_child(timer)


func configure_world_process_manager(manager: Node) -> void:
	world_process_manager = manager


func unregister_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if world_process_manager and world_process_manager.has_method("release_join_reservations_for_peer"):
		world_process_manager.release_join_reservations_for_peer(peer_id)
	if not peer_worlds.has(peer_id):
		return

	var world_key := str(peer_worlds[peer_id])
	unregister_world_by_key(world_key, "peer_disconnected")
	if world_process_manager and not world_process_manager.is_world_stopping(world_key):
		world_process_manager.request_world_stop(world_key, "master_peer_disconnected")


func unregister_world_by_key(world_key: String, reason: String) -> void:
	if not multiplayer.is_server():
		return

	var peer_to_remove := 0
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == world_key:
			peer_to_remove = int(peer_id)
			break

	if peer_to_remove != 0:
		peer_worlds.erase(peer_to_remove)

	registered_worlds.erase(world_key)
	world_last_seen.erase(world_key)
	print("MASTER_WORLD_DEREGISTERED key=%s reason=%s" % [world_key, reason])


func live_routes() -> Dictionary:
	var routes := NET_CONFIG.routes()
	routes["worlds"] = registered_worlds.duplicate(true)
	return routes


func registered_world_count() -> int:
	return registered_worlds.size()


func is_registered_world_peer(peer_id: int) -> bool:
	return peer_worlds.has(peer_id)


@rpc("any_peer", "call_remote", "reliable")
func request_routes() -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	print("[MASTER] route request from peer %s; registered_worlds=%d" % [sender_id, registered_world_count()])
	call_deferred("_send_routes_when_available", sender_id, NET_CONFIG.initial_world())


@rpc("any_peer", "call_remote", "reliable")
func register_world(world_key: String, launch_token: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not NET_CONFIG.is_valid_world_key(world_key):
		push_error("[MASTER] rejected invalid world registration: %s" % world_key)
		return
	if not world_process_manager or not world_process_manager.expects_registration(world_key, launch_token):
		push_error("[MASTER] rejected unexpected world registration: %s" % world_key)
		return

	var normalized_endpoint := NET_CONFIG.world_endpoint(world_key)
	registered_worlds[world_key] = normalized_endpoint
	peer_worlds[sender_id] = world_key
	world_last_seen[world_key] = Time.get_unix_time_from_system()
	print("MASTER_WORLD_REGISTERED key=%s peer=%s url=%s" % [world_key, sender_id, normalized_endpoint["url"]])
	world_process_manager.mark_world_registered(world_key)
	world_registered_ack.rpc_id(sender_id, world_key)


@rpc("any_peer", "call_remote", "reliable")
func request_transfer(target_world: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	print("[MASTER] transfer request from peer %s to %s" % [sender_id, target_world])
	if not NET_CONFIG.is_valid_world_key(target_world):
		deny_transfer.rpc_id(sender_id, target_world)
		return

	call_deferred("_approve_transfer_when_available", sender_id, target_world)


@rpc("any_peer", "call_remote", "reliable")
func refresh_world_join(world_key: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not NET_CONFIG.is_valid_world_key(world_key):
		return
	if world_process_manager and world_process_manager.has_method("refresh_world_join"):
		world_process_manager.refresh_world_join(world_key, sender_id)


@rpc("any_peer", "call_remote", "reliable")
func release_world_join(world_key: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not NET_CONFIG.is_valid_world_key(world_key):
		return
	if world_process_manager and world_process_manager.has_method("release_world_join"):
		world_process_manager.release_world_join(world_key, sender_id)


func shutdown_registered_world(world_key: String, reason: String) -> void:
	if not multiplayer.is_server():
		return

	var found_peer := false
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == world_key:
			if _is_peer_open(int(peer_id)):
				shutdown_world.rpc_id(int(peer_id), reason)
			found_peer = true
			break

	if found_peer or registered_worlds.has(world_key):
		unregister_world_by_key(world_key, reason)


@rpc("any_peer", "call_remote", "unreliable")
func world_heartbeat(world_key: String, player_count: int) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if peer_worlds.get(sender_id, "") != world_key:
		return
	world_last_seen[world_key] = Time.get_unix_time_from_system()
	if world_process_manager:
		world_process_manager.update_world_player_count(world_key, player_count)


@rpc("authority", "call_remote", "reliable")
func world_registered_ack(world_key: String) -> void:
	if multiplayer.is_server():
		return

	print("[WORLD %s] master registration acknowledged" % world_key)
	world_registered.emit(world_key)


@rpc("authority", "call_remote", "reliable")
func receive_routes(routes: Dictionary) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] received master routes")
	routes_received.emit(routes)


@rpc("authority", "call_remote", "reliable")
func approve_transfer(target_world: String, endpoint: Dictionary) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] transfer approved to %s" % target_world)
	transfer_approved.emit(target_world, endpoint)


@rpc("authority", "call_remote", "reliable")
func deny_transfer(target_world: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] transfer denied to %s" % target_world)
	transfer_denied.emit(target_world)


@rpc("authority", "call_remote", "reliable")
func shutdown_world(reason: String) -> void:
	if multiplayer.is_server():
		return

	print("[WORLD] shutdown requested by master: %s" % reason)
	world_shutdown_requested.emit(reason)


@rpc("authority", "call_remote", "reliable")
func expect_world_join(world_key: String, join_ticket: String, expires_at: float) -> void:
	if multiplayer.is_server():
		return

	world_join_expected.emit(world_key, join_ticket, expires_at)


func _send_routes_when_available(sender_id: int, world_key: String) -> void:
	var ok := await _ensure_world_available(world_key)
	if not ok:
		push_error("[MASTER] failed to make initial world available: %s" % world_key)
		receive_routes.rpc_id(sender_id, live_routes())
		return

	var routes := live_routes()
	var worlds: Dictionary = routes["worlds"]
	worlds[world_key] = _endpoint_with_join_ticket(sender_id, world_key)
	routes["worlds"] = worlds
	receive_routes.rpc_id(sender_id, routes)


func _approve_transfer_when_available(sender_id: int, target_world: String) -> void:
	var ok := await _ensure_world_available(target_world)
	if ok and registered_worlds.has(target_world):
		approve_transfer.rpc_id(sender_id, target_world, _endpoint_with_join_ticket(sender_id, target_world))
	else:
		deny_transfer.rpc_id(sender_id, target_world)


func _ensure_world_available(world_key: String) -> bool:
	if world_process_manager and world_process_manager.is_world_stopping(world_key):
		var stopped := await _wait_for_world_stop(world_key)
		if not stopped:
			return false

	if registered_worlds.has(world_key):
		if world_process_manager and not world_process_manager.is_world_available(world_key):
			unregister_world_by_key(world_key, "route_unavailable")
		else:
			if world_process_manager:
				world_process_manager.ensure_world_started(world_key)
			return true

	if not world_process_manager or not world_process_manager.ensure_world_started(world_key):
		return false

	var elapsed := 0.0
	var timeout_seconds := float(world_process_manager.world_start_timeout_seconds())
	while elapsed < timeout_seconds:
		if registered_worlds.has(world_key) and world_process_manager.is_world_available(world_key):
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05

	return false


func _wait_for_world_stop(world_key: String) -> bool:
	if not world_process_manager:
		return true

	var elapsed := 0.0
	var timeout_seconds := 3.0
	if world_process_manager.has_method("world_stop_kill_seconds"):
		timeout_seconds = float(world_process_manager.world_stop_kill_seconds()) + 1.0

	while elapsed < timeout_seconds:
		if not world_process_manager.is_world_stopping(world_key):
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05

	return not world_process_manager.is_world_stopping(world_key)


func _endpoint_with_join_ticket(sender_id: int, world_key: String) -> Dictionary:
	var endpoint: Dictionary = registered_worlds[world_key].duplicate(true)
	if not world_process_manager or not world_process_manager.has_method("reserve_world_join"):
		return endpoint

	var reservation: Dictionary = world_process_manager.reserve_world_join(world_key, sender_id)
	var join_ticket := str(reservation.get("ticket", ""))
	if join_ticket.is_empty():
		return endpoint

	var expires_at := float(reservation.get("expires_at", 0.0))
	endpoint["join_ticket"] = join_ticket
	endpoint["join_ticket_expires_at"] = expires_at
	_send_join_ticket_to_world(world_key, join_ticket, expires_at)
	return endpoint


func _send_join_ticket_to_world(world_key: String, join_ticket: String, expires_at: float) -> void:
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == world_key:
			expect_world_join.rpc_id(int(peer_id), world_key, join_ticket, expires_at)
			return


func _is_peer_open(peer_id: int) -> bool:
	var peer := multiplayer.multiplayer_peer
	if not peer or not peer.has_method("get_peer"):
		return peer_id in multiplayer.get_peers()

	var socket = peer.get_peer(peer_id)
	if not socket or not socket.has_method("get_ready_state"):
		return peer_id in multiplayer.get_peers()

	return socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func _expire_stale_worlds() -> void:
	if not multiplayer.is_server():
		return

	var now := Time.get_unix_time_from_system()
	for world_key in world_last_seen.keys():
		if now - float(world_last_seen[world_key]) <= HEARTBEAT_TIMEOUT_SECONDS:
			continue
		if world_process_manager:
			world_process_manager.request_world_stop(str(world_key), "heartbeat_timeout")
		else:
			unregister_world_by_key(str(world_key), "heartbeat_timeout")
		print("MASTER_WORLD_EXPIRED key=%s" % world_key)
