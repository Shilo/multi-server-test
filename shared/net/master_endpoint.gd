extends Node

signal routes_received(routes: Dictionary)
signal transfer_approved(target_world: String, endpoint: Dictionary)
signal transfer_denied(target_world: String)
signal world_join_approved(world_key: String, endpoint: Dictionary)
signal world_join_denied(world_key: String, reason: String)
signal world_registered(world_key: String)
signal world_shutdown_requested(reason: String)
signal world_join_expected(world_key: String, join_ticket: String, expires_at: float, master_peer_id: int, source_world: String, target_portal: String, identity: Dictionary)
signal world_transfer_result_received(master_peer_id: int, target_world: String, approved: bool)

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const NET_UTIL := preload("res://shared/net/net_util.gd")
const HEARTBEAT_TIMEOUT_SECONDS := 5.0
const WORLD_JOIN_INTENT_SECONDS := 120.0

var registered_worlds := {}
var peer_worlds := {}
var world_last_seen := {}
var pending_world_join_intents := {}
var world_process_manager: Node
var account_endpoint: Node


func _ready() -> void:
	var timer := Timer.new()
	timer.name = "WorldHeartbeatExpiryTimer"
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_expire_stale_worlds)
	add_child(timer)


func configure_world_process_manager(manager: Node) -> void:
	world_process_manager = manager


func configure_account_endpoint(endpoint: Node) -> void:
	account_endpoint = endpoint


## Called by AccountEndpoint after a login/logout so the next world join for this
## peer targets the resumed world, optionally at a server-known saved position.
func set_login_resume_intent(peer_id: int, world_key: String, has_spawn: bool, spawn_x: float, spawn_y: float) -> void:
	_set_pending_world_join_intent(peer_id, world_key, "", "", has_spawn, spawn_x, spawn_y)


func unregister_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if world_process_manager and world_process_manager.has_method("release_join_reservations_for_peer"):
		world_process_manager.release_join_reservations_for_peer(peer_id)
	pending_world_join_intents.erase(str(peer_id))
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

	var was_registered := registered_worlds.has(world_key) or world_last_seen.has(world_key) or peer_to_remove != 0
	if not was_registered:
		return

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
func request_world_transfer(source_world: String, master_peer_id: int, target_world: String, target_portal := "") -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if peer_worlds.get(sender_id, "") != source_world:
		push_error("[MASTER] rejected transfer from untrusted world peer=%s source=%s target=%s" % [sender_id, source_world, target_world])
		return
	if not NET_CONFIG.is_valid_world_key(source_world) or not NET_CONFIG.is_valid_world_key(target_world):
		deny_transfer.rpc_id(master_peer_id, target_world)
		return
	if not _is_peer_open(master_peer_id):
		return

	print("[MASTER] world-approved transfer peer=%s from=%s to=%s" % [master_peer_id, source_world, target_world])
	call_deferred("_approve_transfer_when_available", master_peer_id, target_world, source_world, target_portal)


@rpc("any_peer", "call_remote", "reliable")
func request_world_join(world_key: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not NET_CONFIG.is_valid_world_key(world_key):
		deny_world_join.rpc_id(sender_id, world_key, "invalid_world")
		return

	call_deferred("_approve_world_join_when_available", sender_id, world_key)


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
			if reason == "idle":
				_disconnect_peer(int(peer_id))
			elif _is_peer_open(int(peer_id)):
				shutdown_world.rpc_id(int(peer_id), reason)
			found_peer = true
			break

	if reason != "idle" and (found_peer or registered_worlds.has(world_key)):
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


@rpc("any_peer", "call_remote", "reliable")
func save_player_state(master_peer_id: int, world_key: String, pos_x: float, pos_y: float) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	# Only the registered world server for this key may report saves for it.
	if peer_worlds.get(sender_id, "") != world_key:
		return
	if account_endpoint and account_endpoint.has_method("save_position"):
		account_endpoint.save_position(master_peer_id, world_key, pos_x, pos_y)


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
func approve_world_join(world_key: String, endpoint: Dictionary) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] join approved for %s" % world_key)
	world_join_approved.emit(world_key, endpoint)


@rpc("authority", "call_remote", "reliable")
func deny_transfer(target_world: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] transfer denied to %s" % target_world)
	transfer_denied.emit(target_world)


@rpc("authority", "call_remote", "reliable")
func deny_world_join(world_key: String, reason: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] join denied for %s: %s" % [world_key, reason])
	world_join_denied.emit(world_key, reason)


@rpc("authority", "call_remote", "reliable")
func shutdown_world(reason: String) -> void:
	if multiplayer.is_server():
		return

	print("[WORLD] shutdown requested by master: %s" % reason)
	world_shutdown_requested.emit(reason)


@rpc("authority", "call_remote", "reliable")
func expect_world_join(world_key: String, join_ticket: String, expires_at: float, master_peer_id: int, source_world: String, target_portal: String, identity: Dictionary) -> void:
	if multiplayer.is_server():
		return

	world_join_expected.emit(world_key, join_ticket, expires_at, master_peer_id, source_world, target_portal, identity)


func _send_routes_when_available(sender_id: int, world_key: String) -> void:
	var ok := await _ensure_world_available(world_key)
	if not ok:
		push_error("[MASTER] failed to make initial world available: %s" % world_key)
		receive_routes.rpc_id(sender_id, live_routes())
		return

	var routes := live_routes()
	var worlds: Dictionary = routes["worlds"]
	worlds[world_key] = _endpoint_without_join_ticket(world_key)
	routes["worlds"] = worlds
	_set_pending_world_join_intent(sender_id, world_key, "", "")
	receive_routes.rpc_id(sender_id, routes)


func _approve_transfer_when_available(sender_id: int, target_world: String, source_world: String, target_portal: String) -> void:
	var ok := await _ensure_world_available(target_world)
	if ok and registered_worlds.has(target_world):
		_set_pending_world_join_intent(sender_id, target_world, source_world, target_portal)
		approve_transfer.rpc_id(sender_id, target_world, _endpoint_without_join_ticket(target_world))
		_notify_source_world_transfer_completed(source_world, sender_id, target_world, true)
	else:
		deny_transfer.rpc_id(sender_id, target_world)
		_notify_source_world_transfer_completed(source_world, sender_id, target_world, false)


func _approve_world_join_when_available(sender_id: int, world_key: String) -> void:
	var intent := _consume_world_join_intent(sender_id, world_key)
	if intent.is_empty():
		deny_world_join.rpc_id(sender_id, world_key, "missing_join_intent")
		return

	var ok := await _ensure_world_available(world_key)
	if not ok or not registered_worlds.has(world_key):
		deny_world_join.rpc_id(sender_id, world_key, "world_unavailable")
		return

	var endpoint := _endpoint_with_join_ticket(
		sender_id,
		world_key,
		str(intent.get("source_world", "")),
		str(intent.get("target_portal", "")),
		intent
	)
	if str(endpoint.get("join_ticket", "")).is_empty():
		deny_world_join.rpc_id(sender_id, world_key, "ticket_unavailable")
		return

	approve_world_join.rpc_id(sender_id, world_key, endpoint)


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


func _endpoint_without_join_ticket(world_key: String) -> Dictionary:
	if not registered_worlds.has(world_key):
		return NET_CONFIG.world_endpoint(world_key)
	return registered_worlds[world_key].duplicate(true)


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


func _endpoint_with_join_ticket(sender_id: int, world_key: String, source_world: String, target_portal: String, intent: Dictionary) -> Dictionary:
	var endpoint: Dictionary = registered_worlds[world_key].duplicate(true)
	if not world_process_manager or not world_process_manager.has_method("reserve_world_join"):
		return endpoint

	var reservation: Dictionary = world_process_manager.reserve_world_join(world_key, sender_id, source_world, target_portal)
	var join_ticket := str(reservation.get("ticket", ""))
	if join_ticket.is_empty():
		return endpoint

	var expires_at := float(reservation.get("expires_at", 0.0))
	endpoint["join_ticket"] = join_ticket
	endpoint["join_ticket_expires_at"] = expires_at
	endpoint["source_world"] = source_world
	endpoint["target_portal"] = target_portal
	_send_join_ticket_to_world(world_key, join_ticket, expires_at, sender_id, source_world, target_portal, _join_identity(sender_id, world_key, intent))
	return endpoint


## Identity payload baked into the player's spawn data by the world. Combines the
## master-owned session identity (name/guest) with any server-known saved spawn
## position carried by a login resume intent.
func _join_identity(sender_id: int, world_key: String, intent: Dictionary) -> Dictionary:
	var identity := {"display_name": "Player_%d" % sender_id, "is_guest": true}
	if account_endpoint and account_endpoint.has_method("get_join_identity"):
		identity = account_endpoint.get_join_identity(sender_id, world_key)
	identity["has_spawn"] = bool(intent.get("has_spawn", false))
	identity["spawn_x"] = float(intent.get("spawn_x", 0.0))
	identity["spawn_y"] = float(intent.get("spawn_y", 0.0))
	return identity


func _send_join_ticket_to_world(world_key: String, join_ticket: String, expires_at: float, master_peer_id: int, source_world: String, target_portal: String, identity: Dictionary) -> void:
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == world_key:
			expect_world_join.rpc_id(int(peer_id), world_key, join_ticket, expires_at, master_peer_id, source_world, target_portal, identity)
			return


func _set_pending_world_join_intent(sender_id: int, target_world: String, source_world: String, target_portal: String, has_spawn := false, spawn_x := 0.0, spawn_y := 0.0) -> void:
	pending_world_join_intents[str(sender_id)] = {
		"target_world": target_world,
		"source_world": source_world,
		"target_portal": target_portal,
		"has_spawn": has_spawn,
		"spawn_x": spawn_x,
		"spawn_y": spawn_y,
		"expires_at": Time.get_unix_time_from_system() + WORLD_JOIN_INTENT_SECONDS,
	}


func _consume_world_join_intent(sender_id: int, world_key: String) -> Dictionary:
	_expire_pending_world_join_intents()
	var intent_key := str(sender_id)
	if pending_world_join_intents.has(intent_key):
		var intent: Dictionary = pending_world_join_intents[intent_key]
		if str(intent.get("target_world", "")) == world_key:
			pending_world_join_intents.erase(intent_key)
			return intent

	if world_key == NET_CONFIG.initial_world():
		return {
			"target_world": world_key,
			"source_world": "",
			"target_portal": "",
		}

	return {}


func _expire_pending_world_join_intents() -> void:
	var now := Time.get_unix_time_from_system()
	for intent_key in pending_world_join_intents.keys():
		var intent: Dictionary = pending_world_join_intents[intent_key]
		if float(intent.get("expires_at", 0.0)) <= now:
			pending_world_join_intents.erase(intent_key)


func _notify_source_world_transfer_completed(source_world: String, master_peer_id: int, target_world: String, approved: bool) -> void:
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == source_world and _is_peer_open(int(peer_id)):
			world_transfer_completed.rpc_id(int(peer_id), master_peer_id, target_world, approved)
			return


@rpc("authority", "call_remote", "reliable")
func world_transfer_completed(master_peer_id: int, target_world: String, approved: bool) -> void:
	if multiplayer.is_server():
		return

	world_transfer_result_received.emit(master_peer_id, target_world, approved)


func _is_peer_open(peer_id: int) -> bool:
	return NET_UTIL.is_peer_open(multiplayer, peer_id)


func _disconnect_peer(peer_id: int) -> void:
	NET_UTIL.disconnect_peer(multiplayer, peer_id)


func _expire_stale_worlds() -> void:
	if not multiplayer.is_server():
		return

	_expire_pending_world_join_intents()
	var now := Time.get_unix_time_from_system()
	for world_key in world_last_seen.keys():
		if now - float(world_last_seen[world_key]) <= HEARTBEAT_TIMEOUT_SECONDS:
			continue
		if world_process_manager:
			world_process_manager.request_world_stop(str(world_key), "heartbeat_timeout")
		else:
			unregister_world_by_key(str(world_key), "heartbeat_timeout")
		print("MASTER_WORLD_EXPIRED key=%s" % world_key)
