extends Node

signal routes_received(routes: Dictionary)
signal transfer_approved(target_world: String, endpoint: Dictionary)
signal transfer_denied(target_world: String)
signal world_registered(world_key: String)
signal world_shutdown_requested(reason: String)

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


func shutdown_registered_world(world_key: String, reason: String) -> void:
	if not multiplayer.is_server():
		return

	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == world_key:
			shutdown_world.rpc_id(int(peer_id), reason)
			break

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


func _send_routes_when_available(sender_id: int, world_key: String) -> void:
	var ok := await _ensure_world_available(world_key)
	if not ok:
		push_error("[MASTER] failed to make initial world available: %s" % world_key)
	receive_routes.rpc_id(sender_id, live_routes())


func _approve_transfer_when_available(sender_id: int, target_world: String) -> void:
	var ok := await _ensure_world_available(target_world)
	if ok and registered_worlds.has(target_world):
		approve_transfer.rpc_id(sender_id, target_world, registered_worlds[target_world])
	else:
		deny_transfer.rpc_id(sender_id, target_world)


func _ensure_world_available(world_key: String) -> bool:
	if world_process_manager and world_process_manager.is_world_stopping(world_key):
		return false

	if registered_worlds.has(world_key):
		if world_process_manager and not world_process_manager.is_world_available(world_key):
			unregister_world_by_key(world_key, "route_unavailable")
			return false
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
