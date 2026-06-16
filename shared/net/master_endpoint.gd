extends Node

signal routes_received(routes: Dictionary)
signal routes_rejected(reason: String, server_version: String, client_version: String)
signal travel_lease_granted(target_world: String, endpoint: Dictionary)
signal transfer_denied(target_world: String)
signal world_join_approved(world_key: String, endpoint: Dictionary)
signal world_join_denied(world_key: String, reason: String)
signal world_registered(world_key: String)
signal world_shutdown_requested(reason: String)
signal world_join_expected(world_key: String, join_ticket: String, expires_at: float, master_peer_id: int, source_world: String, target_portal: String, identity: Dictionary, transfer_request_id: String, travel_lease_id: String)
signal world_transfer_lease_created_received(master_peer_id: int, target_world: String, transfer_request_id: String, travel_lease_id: String, hard_expires_at: float)
signal world_transfer_result_received(master_peer_id: int, target_world: String, approved: bool, transfer_request_id: String, travel_lease_id: String)

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const NET_UTIL := preload("res://shared/net/net_util.gd")
const HEARTBEAT_TIMEOUT_SECONDS := 5.0
const TRAVEL_LEASE_REFRESH_SECONDS := 120.0
const TRAVEL_LEASE_MAX_SECONDS := 3600.0
const MAX_TRAVEL_LEASES_PER_PEER := 8
const MAX_TRAVEL_LEASES_TOTAL := 2048
const MAX_PENDING_WORLD_ADMISSIONS_TOTAL := 2048

var registered_worlds := {}
var validated_client_peers := {}
var peer_worlds := {}
var world_last_seen := {}
var travel_leases := {}
var active_world_join_requests := {}
var pending_world_admissions := {}
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
func create_login_resume_lease(peer_id: int, world_key: String, has_spawn: bool, spawn_x: float, spawn_y: float) -> Dictionary:
	if not NET_CONFIG.is_valid_world_key(world_key):
		return {}
	var lease := _create_travel_lease(peer_id, world_key, "", "", has_spawn, spawn_x, spawn_y)
	return _endpoint_for_travel_lease(lease)


func unregister_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	validated_client_peers.erase(peer_id)
	if world_process_manager and world_process_manager.has_method("release_join_reservations_for_peer"):
		world_process_manager.release_join_reservations_for_peer(peer_id)
	_release_peer_travel_leases(peer_id)
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
	NetLog.print_line("MASTER_WORLD_DEREGISTERED key=%s reason=%s" % [world_key, reason])


func live_routes() -> Dictionary:
	var routes := NET_CONFIG.routes()
	var worlds := {}
	for world_key in registered_worlds.keys():
		worlds[world_key] = _endpoint_without_join_ticket(str(world_key))
	routes["worlds"] = worlds
	if routes.has("world_catalog"):
		var catalog: Dictionary = routes["world_catalog"]
		for world_key in catalog.keys():
			catalog[world_key] = _endpoint_with_world_pack_metadata(str(world_key), catalog[world_key])
		routes["world_catalog"] = catalog
	return routes


func registered_world_count() -> int:
	return registered_worlds.size()


func is_registered_world_peer(peer_id: int) -> bool:
	return peer_worlds.has(peer_id)


func is_validated_client_peer(peer_id: int) -> bool:
	return validated_client_peers.has(peer_id) and not is_registered_world_peer(peer_id)


func reject_unvalidated_client_peer(peer_id: int, rpc_name: String) -> void:
	_require_validated_client_peer(peer_id, rpc_name)


@rpc("any_peer", "call_remote", "reliable")
func request_routes(client_build_version := "") -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var server_build_version := _project_version()
	var requested_build_version := str(client_build_version)
	if requested_build_version != server_build_version:
		NetLog.print_line("[MASTER] route rejected for peer %s reason=version_mismatch client=%s server=%s" % [
			sender_id,
			requested_build_version,
			server_build_version,
		])
		reject_routes.rpc_id(sender_id, "version_mismatch", server_build_version, requested_build_version)
		call_deferred("_disconnect_peer_after_rejection", sender_id)
		return

	_mark_client_peer_validated(sender_id)
	NetLog.print_line("[MASTER] route request from peer %s; registered_worlds=%d" % [sender_id, registered_world_count()])
	call_deferred("_send_routes_when_available", sender_id, NET_CONFIG.initial_world())


@rpc("any_peer", "call_remote", "reliable")
func register_world(world_key: String, launch_token: String, world_build_version := "") -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var server_build_version := _project_version()
	if str(world_build_version) != server_build_version:
		push_error("[MASTER] rejected world registration for %s due build version mismatch: world=%s server=%s" % [
			world_key,
			str(world_build_version),
			server_build_version,
		])
		shutdown_world.rpc_id(sender_id, "version_mismatch")
		call_deferred("_disconnect_peer_after_rejection", sender_id)
		return
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
	NetLog.print_line("MASTER_WORLD_REGISTERED key=%s peer=%s url=%s" % [world_key, sender_id, normalized_endpoint["url"]])
	world_process_manager.mark_world_registered(world_key)
	world_registered_ack.rpc_id(sender_id, world_key)


func _project_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.1"))


@rpc("any_peer", "call_remote", "reliable")
func request_world_transfer(source_world: String, master_peer_id: int, target_world: String, target_portal := "", transfer_request_id := "") -> void:
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

	NetLog.print_line("[MASTER] world-approved transfer peer=%s from=%s to=%s" % [master_peer_id, source_world, target_world])
	call_deferred("_approve_transfer_when_available", master_peer_id, target_world, source_world, target_portal, transfer_request_id)


@rpc("any_peer", "call_remote", "reliable")
func request_world_join(world_key: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _require_validated_client_peer(sender_id, "request_world_join"):
		return
	NetLog.print_line("[MASTER] WORLD_JOIN_REQUEST_RECEIVED key=%s peer=%s" % [world_key, sender_id])
	if not NET_CONFIG.is_valid_world_key(world_key):
		deny_world_join.rpc_id(sender_id, world_key, "invalid_world")
		return

	if world_key == NET_CONFIG.initial_world():
		var lease := _create_travel_lease(sender_id, world_key, "", "")
		travel_leases.erase(str(lease.get("id", "")))
		call_deferred("_approve_world_join_when_available", sender_id, lease)
	else:
		deny_world_join.rpc_id(sender_id, world_key, "missing_travel_lease")


@rpc("any_peer", "call_remote", "reliable")
func refresh_travel_lease(travel_lease_id: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _require_validated_client_peer(sender_id, "refresh_travel_lease"):
		return
	var lease := _travel_lease_for_peer(sender_id, travel_lease_id)
	if lease.is_empty():
		return

	var now := Time.get_unix_time_from_system()
	var hard_expires_at := float(lease.get("hard_expires_at", 0.0))
	if hard_expires_at <= now:
		_expire_travel_lease(travel_lease_id, lease)
		return

	lease["expires_at"] = min(now + TRAVEL_LEASE_REFRESH_SECONDS, hard_expires_at)
	travel_leases[travel_lease_id] = lease


@rpc("any_peer", "call_remote", "reliable")
func redeem_travel_lease(travel_lease_id: String, expected_world_key := "") -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _require_validated_client_peer(sender_id, "redeem_travel_lease"):
		return
	var lease := _consume_travel_lease(sender_id, travel_lease_id)
	if lease.is_empty():
		deny_world_join.rpc_id(sender_id, expected_world_key, "invalid_travel_lease")
		return
	if not expected_world_key.is_empty() and str(lease.get("target_world", "")) != expected_world_key:
		_notify_source_world_transfer_completed(str(lease.get("source_world", "")), sender_id, str(lease.get("target_world", "")), false, str(lease.get("transfer_request_id", "")), travel_lease_id)
		deny_world_join.rpc_id(sender_id, expected_world_key, "travel_lease_target_mismatch")
		return

	active_world_join_requests[travel_lease_id] = {
		"peer_id": sender_id,
		"world_key": str(lease.get("target_world", "")),
		"source_world": str(lease.get("source_world", "")),
		"transfer_request_id": str(lease.get("transfer_request_id", "")),
	}
	NetLog.print_line("[MASTER] WORLD_JOIN_REQUEST_RECEIVED key=%s peer=%s lease=%s" % [
		str(lease.get("target_world", "")),
		sender_id,
		travel_lease_id,
	])
	call_deferred("_approve_world_join_when_available", sender_id, lease)


@rpc("any_peer", "call_remote", "reliable")
func release_travel_lease(travel_lease_id: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _require_validated_client_peer(sender_id, "release_travel_lease"):
		return
	var lease := _travel_lease_for_peer(sender_id, travel_lease_id)
	if lease.is_empty():
		return
	travel_leases.erase(travel_lease_id)
	_notify_source_world_transfer_completed(
		str(lease.get("source_world", "")),
		sender_id,
		str(lease.get("target_world", "")),
		false,
		str(lease.get("transfer_request_id", "")),
		travel_lease_id
	)


@rpc("any_peer", "call_remote", "reliable")
func confirm_world_join(master_peer_id: int, world_key: String, join_ticket: String, source_world := "", transfer_request_id := "", travel_lease_id := "") -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if peer_worlds.get(sender_id, "") != world_key:
		return
	if join_ticket.is_empty() or master_peer_id <= 0:
		return

	var admission := {
		"peer_id": master_peer_id,
		"world_key": world_key,
		"source_world": source_world,
		"transfer_request_id": transfer_request_id,
		"travel_lease_id": travel_lease_id,
	}
	if pending_world_admissions.has(join_ticket):
		admission = pending_world_admissions[join_ticket]
		if int(admission.get("peer_id", 0)) != master_peer_id or str(admission.get("world_key", "")) != world_key:
			return
		pending_world_admissions.erase(join_ticket)

	if account_endpoint and account_endpoint.has_method("commit_active_world"):
		account_endpoint.commit_active_world(master_peer_id, world_key)
	if world_process_manager and world_process_manager.has_method("release_world_join"):
		world_process_manager.release_world_join(world_key, master_peer_id)
	_notify_source_world_transfer_completed(
		str(admission.get("source_world", "")),
		master_peer_id,
		world_key,
		true,
		str(admission.get("transfer_request_id", "")),
		str(admission.get("travel_lease_id", ""))
	)


@rpc("any_peer", "call_remote", "reliable")
func refresh_world_join(world_key: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _require_validated_client_peer(sender_id, "refresh_world_join"):
		return
	if not NET_CONFIG.is_valid_world_key(world_key):
		return
	if world_process_manager and world_process_manager.has_method("refresh_world_join"):
		world_process_manager.refresh_world_join(world_key, sender_id)


@rpc("any_peer", "call_remote", "reliable")
func release_world_join(world_key: String, travel_lease_id := "") -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _require_validated_client_peer(sender_id, "release_world_join"):
		return
	if not NET_CONFIG.is_valid_world_key(world_key):
		return
	_cancel_active_world_join_request(sender_id, world_key, travel_lease_id)
	_cancel_pending_world_admission(sender_id, world_key, travel_lease_id)
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

	NetLog.print_line("[WORLD %s] master registration acknowledged" % world_key)
	world_registered.emit(world_key)


@rpc("authority", "call_remote", "reliable")
func receive_routes(routes: Dictionary) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[CLIENT] received master routes")
	routes_received.emit(routes)


@rpc("authority", "call_remote", "reliable")
func reject_routes(reason: String, server_version: String, client_version: String) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[CLIENT] route request rejected: %s client=%s server=%s" % [reason, client_version, server_version])
	routes_rejected.emit(reason, server_version, client_version)


@rpc("authority", "call_remote", "reliable")
func grant_travel_lease(target_world: String, endpoint: Dictionary) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[CLIENT] travel lease granted to %s" % target_world)
	travel_lease_granted.emit(target_world, endpoint)


@rpc("authority", "call_remote", "reliable")
func approve_world_join(world_key: String, endpoint: Dictionary) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[CLIENT] join approved for %s" % world_key)
	world_join_approved.emit(world_key, endpoint)


@rpc("authority", "call_remote", "reliable")
func deny_transfer(target_world: String) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[CLIENT] transfer denied to %s" % target_world)
	transfer_denied.emit(target_world)


@rpc("authority", "call_remote", "reliable")
func deny_world_join(world_key: String, reason: String) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[CLIENT] join denied for %s: %s" % [world_key, reason])
	world_join_denied.emit(world_key, reason)


@rpc("authority", "call_remote", "reliable")
func shutdown_world(reason: String) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[WORLD] shutdown requested by master: %s" % reason)
	world_shutdown_requested.emit(reason)


@rpc("authority", "call_remote", "reliable")
func expect_world_join(world_key: String, join_ticket: String, expires_at: float, master_peer_id: int, source_world: String, target_portal: String, identity: Dictionary, transfer_request_id := "", travel_lease_id := "") -> void:
	if multiplayer.is_server():
		return

	world_join_expected.emit(world_key, join_ticket, expires_at, master_peer_id, source_world, target_portal, identity, transfer_request_id, travel_lease_id)


@rpc("authority", "call_remote", "reliable")
func world_transfer_lease_created(master_peer_id: int, target_world: String, transfer_request_id: String, travel_lease_id: String, hard_expires_at: float) -> void:
	if multiplayer.is_server():
		return

	world_transfer_lease_created_received.emit(master_peer_id, target_world, transfer_request_id, travel_lease_id, hard_expires_at)


func _send_routes_when_available(sender_id: int, world_key: String) -> void:
	if not _is_peer_open(sender_id):
		return
	var routes := live_routes()
	var worlds: Dictionary = routes["worlds"]
	var lease := _create_travel_lease(sender_id, world_key, "", "")
	worlds[world_key] = _endpoint_for_travel_lease(lease)
	routes["worlds"] = worlds
	receive_routes.rpc_id(sender_id, routes)


func _approve_transfer_when_available(sender_id: int, target_world: String, source_world: String, target_portal: String, transfer_request_id: String) -> void:
	if not _is_peer_open(sender_id):
		_notify_source_world_transfer_completed(source_world, sender_id, target_world, false, transfer_request_id, "")
		return
	if world_process_manager and world_process_manager.is_world_stopping(target_world):
		var stopped := await _wait_for_world_stop(target_world)
		if not _is_peer_open(sender_id):
			_notify_source_world_transfer_completed(source_world, sender_id, target_world, false, transfer_request_id, "")
			return
		if not stopped:
			deny_transfer.rpc_id(sender_id, target_world)
			_notify_source_world_transfer_completed(source_world, sender_id, target_world, false, transfer_request_id, "")
			return

	if not NET_CONFIG.is_valid_world_key(target_world):
		deny_transfer.rpc_id(sender_id, target_world)
		_notify_source_world_transfer_completed(source_world, sender_id, target_world, false, transfer_request_id, "")
		return

	var lease := _create_travel_lease(sender_id, target_world, source_world, target_portal, false, 0.0, 0.0, transfer_request_id)
	_notify_source_world_transfer_lease_created(source_world, sender_id, target_world, transfer_request_id, str(lease.get("id", "")), float(lease.get("hard_expires_at", 0.0)))
	grant_travel_lease.rpc_id(sender_id, target_world, _endpoint_for_travel_lease(lease))


func _approve_world_join_when_available(sender_id: int, lease: Dictionary) -> void:
	var world_key := str(lease.get("target_world", ""))
	var travel_lease_id := str(lease.get("id", ""))
	var transfer_request_id := str(lease.get("transfer_request_id", ""))
	if not NET_CONFIG.is_valid_world_key(world_key):
		deny_world_join.rpc_id(sender_id, world_key, "invalid_world")
		active_world_join_requests.erase(travel_lease_id)
		return
	if not _is_peer_open(sender_id):
		active_world_join_requests.erase(travel_lease_id)
		_notify_source_world_transfer_completed(str(lease.get("source_world", "")), sender_id, world_key, false, transfer_request_id, travel_lease_id)
		return

	var ok := await _ensure_world_available(world_key)
	if not _is_active_world_join_request(sender_id, world_key, travel_lease_id):
		return
	if not _is_peer_open(sender_id):
		active_world_join_requests.erase(travel_lease_id)
		_notify_source_world_transfer_completed(str(lease.get("source_world", "")), sender_id, world_key, false, transfer_request_id, travel_lease_id)
		return
	if not ok or not registered_worlds.has(world_key):
		active_world_join_requests.erase(travel_lease_id)
		_notify_source_world_transfer_completed(str(lease.get("source_world", "")), sender_id, world_key, false, transfer_request_id, travel_lease_id)
		deny_world_join.rpc_id(sender_id, world_key, "world_unavailable")
		return

	var endpoint := _endpoint_with_join_ticket(
		sender_id,
		world_key,
		str(lease.get("source_world", "")),
		str(lease.get("target_portal", "")),
		lease
	)
	if str(endpoint.get("join_ticket", "")).is_empty():
		active_world_join_requests.erase(travel_lease_id)
		_notify_source_world_transfer_completed(str(lease.get("source_world", "")), sender_id, world_key, false, transfer_request_id, travel_lease_id)
		deny_world_join.rpc_id(sender_id, world_key, "ticket_unavailable")
		return

	active_world_join_requests.erase(travel_lease_id)
	NetLog.print_line("[MASTER] WORLD_JOIN_APPROVED key=%s peer=%s" % [world_key, sender_id])
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
	var endpoint: Dictionary = NET_CONFIG.world_endpoint(world_key)
	if registered_worlds.has(world_key):
		endpoint = registered_worlds[world_key].duplicate(true)
	return _endpoint_with_world_pack_metadata(world_key, endpoint)


func _endpoint_with_world_pack_metadata(world_key: String, endpoint: Dictionary) -> Dictionary:
	var enriched := endpoint.duplicate(true)
	var pack_path := NET_CONFIG.world_pack_file_path(world_key)
	if not FileAccess.file_exists(pack_path):
		return enriched

	var pack_size := FileAccess.get_size(pack_path)
	var pack_modified_time := FileAccess.get_modified_time(pack_path)
	if pack_size <= 0 or pack_modified_time <= 0:
		return enriched

	enriched["pack_url"] = NET_CONFIG.world_pack_url(world_key)
	enriched["pack_modified_time"] = pack_modified_time
	enriched["pack_size"] = pack_size
	return enriched


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
	pending_world_admissions[join_ticket] = {
		"peer_id": sender_id,
		"world_key": world_key,
		"source_world": source_world,
		"target_portal": target_portal,
		"transfer_request_id": str(intent.get("transfer_request_id", "")),
		"travel_lease_id": str(intent.get("id", "")),
		"expires_at": expires_at,
	}
	_trim_pending_world_admissions()
	_send_join_ticket_to_world(
		world_key,
		join_ticket,
		expires_at,
		sender_id,
		source_world,
		target_portal,
		_join_identity(sender_id, world_key, intent),
		str(intent.get("transfer_request_id", "")),
		str(intent.get("id", ""))
	)
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


func _send_join_ticket_to_world(world_key: String, join_ticket: String, expires_at: float, master_peer_id: int, source_world: String, target_portal: String, identity: Dictionary, transfer_request_id: String, travel_lease_id: String) -> void:
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == world_key:
			expect_world_join.rpc_id(int(peer_id), world_key, join_ticket, expires_at, master_peer_id, source_world, target_portal, identity, transfer_request_id, travel_lease_id)
			return


func _create_travel_lease(sender_id: int, target_world: String, source_world: String, target_portal: String, has_spawn := false, spawn_x := 0.0, spawn_y := 0.0, transfer_request_id := "") -> Dictionary:
	_remove_matching_travel_leases(sender_id, target_world, source_world, target_portal)
	_trim_peer_travel_leases(sender_id)
	_trim_global_travel_leases()
	var now := Time.get_unix_time_from_system()
	var lease_id := _new_travel_lease_id()
	var lease := {
		"id": lease_id,
		"peer_id": sender_id,
		"target_world": target_world,
		"source_world": source_world,
		"target_portal": target_portal,
		"transfer_request_id": transfer_request_id,
		"has_spawn": has_spawn,
		"spawn_x": spawn_x,
		"spawn_y": spawn_y,
		"expires_at": now + TRAVEL_LEASE_REFRESH_SECONDS,
		"hard_expires_at": now + TRAVEL_LEASE_MAX_SECONDS,
	}
	travel_leases[lease_id] = lease
	NetLog.print_line("[MASTER] TRAVEL_LEASE_CREATED id=%s peer=%s target=%s source=%s" % [
		lease_id,
		sender_id,
		target_world,
		source_world,
	])
	return lease


func _remove_matching_travel_leases(sender_id: int, target_world: String, source_world: String, target_portal: String) -> void:
	for travel_lease_id in travel_leases.keys():
		var lease: Dictionary = travel_leases[travel_lease_id]
		if (
			int(lease.get("peer_id", 0)) == sender_id
			and str(lease.get("target_world", "")) == target_world
			and str(lease.get("source_world", "")) == source_world
			and str(lease.get("target_portal", "")) == target_portal
		):
			travel_leases.erase(str(travel_lease_id))


func _trim_peer_travel_leases(sender_id: int) -> void:
	var peer_lease_ids: Array[String] = []
	for travel_lease_id in travel_leases.keys():
		var lease: Dictionary = travel_leases[travel_lease_id]
		if int(lease.get("peer_id", 0)) == sender_id:
			peer_lease_ids.append(str(travel_lease_id))
	if peer_lease_ids.size() < MAX_TRAVEL_LEASES_PER_PEER:
		return

	peer_lease_ids.sort_custom(func(a: String, b: String) -> bool:
		var a_lease: Dictionary = travel_leases.get(a, {})
		var b_lease: Dictionary = travel_leases.get(b, {})
		return float(a_lease.get("expires_at", 0.0)) < float(b_lease.get("expires_at", 0.0))
	)
	while peer_lease_ids.size() >= MAX_TRAVEL_LEASES_PER_PEER:
		var oldest_id: String = peer_lease_ids.pop_front()
		if travel_leases.has(oldest_id):
			_expire_travel_lease(oldest_id, travel_leases[oldest_id])


func _trim_global_travel_leases() -> void:
	if travel_leases.size() < MAX_TRAVEL_LEASES_TOTAL:
		return

	var lease_ids: Array[String] = []
	for travel_lease_id in travel_leases.keys():
		lease_ids.append(str(travel_lease_id))
	lease_ids.sort_custom(func(a: String, b: String) -> bool:
		var a_lease: Dictionary = travel_leases.get(a, {})
		var b_lease: Dictionary = travel_leases.get(b, {})
		return float(a_lease.get("expires_at", 0.0)) < float(b_lease.get("expires_at", 0.0))
	)
	while lease_ids.size() >= MAX_TRAVEL_LEASES_TOTAL:
		var oldest_id: String = lease_ids.pop_front()
		if travel_leases.has(oldest_id):
			_expire_travel_lease(oldest_id, travel_leases[oldest_id])


func _new_travel_lease_id() -> String:
	var token := ""
	for byte in OS.get_entropy(16):
		token += str(int(byte)).pad_zeros(3)
	return token


func _endpoint_for_travel_lease(lease: Dictionary) -> Dictionary:
	if lease.is_empty():
		return {}
	var endpoint := _endpoint_without_join_ticket(str(lease.get("target_world", "")))
	endpoint["travel_lease_id"] = str(lease.get("id", ""))
	endpoint["travel_lease_expires_at"] = float(lease.get("expires_at", 0.0))
	endpoint["travel_lease_hard_expires_at"] = float(lease.get("hard_expires_at", 0.0))
	return endpoint


func _travel_lease_for_peer(sender_id: int, travel_lease_id: String) -> Dictionary:
	_expire_travel_leases()
	if travel_lease_id.is_empty() or not travel_leases.has(travel_lease_id):
		return {}
	var lease: Dictionary = travel_leases[travel_lease_id]
	if int(lease.get("peer_id", 0)) != sender_id:
		return {}
	return lease


func _consume_travel_lease(sender_id: int, travel_lease_id: String) -> Dictionary:
	var lease := _travel_lease_for_peer(sender_id, travel_lease_id)
	if lease.is_empty():
		return {}
	travel_leases.erase(travel_lease_id)
	return lease


func _release_peer_travel_leases(peer_id: int) -> void:
	for travel_lease_id in travel_leases.keys():
		var lease: Dictionary = travel_leases[travel_lease_id]
		if int(lease.get("peer_id", 0)) == peer_id:
			_expire_travel_lease(str(travel_lease_id), lease)
	_cancel_all_pending_world_admissions_for_peer(peer_id)


func _is_active_world_join_request(peer_id: int, world_key: String, travel_lease_id: String) -> bool:
	if travel_lease_id.is_empty() or not active_world_join_requests.has(travel_lease_id):
		return false
	var request: Dictionary = active_world_join_requests[travel_lease_id]
	return int(request.get("peer_id", 0)) == peer_id and str(request.get("world_key", "")) == world_key


func _cancel_active_world_join_request(peer_id: int, world_key: String, travel_lease_id: String) -> void:
	for active_id in active_world_join_requests.keys():
		if not travel_lease_id.is_empty() and str(active_id) != travel_lease_id:
			continue
		var request: Dictionary = active_world_join_requests[active_id]
		if int(request.get("peer_id", 0)) == peer_id and str(request.get("world_key", "")) == world_key:
			active_world_join_requests.erase(active_id)
			_notify_source_world_transfer_completed(
				str(request.get("source_world", "")),
				peer_id,
				world_key,
				false,
				str(request.get("transfer_request_id", "")),
				str(active_id)
			)
			return


func _cancel_pending_world_admission(peer_id: int, world_key: String, travel_lease_id: String) -> void:
	for join_ticket in pending_world_admissions.keys():
		var admission: Dictionary = pending_world_admissions[join_ticket]
		if (
			int(admission.get("peer_id", 0)) == peer_id
			and str(admission.get("world_key", "")) == world_key
			and (travel_lease_id.is_empty() or str(admission.get("travel_lease_id", "")) == travel_lease_id)
		):
			pending_world_admissions.erase(join_ticket)
			_notify_source_world_transfer_completed(
				str(admission.get("source_world", "")),
				peer_id,
				world_key,
				false,
				str(admission.get("transfer_request_id", "")),
				str(admission.get("travel_lease_id", ""))
			)
			return


func _cancel_all_pending_world_admissions_for_peer(peer_id: int) -> void:
	for join_ticket in pending_world_admissions.keys():
		var admission: Dictionary = pending_world_admissions[join_ticket]
		if int(admission.get("peer_id", 0)) == peer_id:
			pending_world_admissions.erase(join_ticket)
			_notify_source_world_transfer_completed(
				str(admission.get("source_world", "")),
				peer_id,
				str(admission.get("world_key", "")),
				false,
				str(admission.get("transfer_request_id", "")),
				str(admission.get("travel_lease_id", ""))
			)


func _expire_pending_world_admissions() -> void:
	var now := Time.get_unix_time_from_system()
	for join_ticket in pending_world_admissions.keys():
		var admission: Dictionary = pending_world_admissions[join_ticket]
		if float(admission.get("expires_at", 0.0)) > now:
			continue
		pending_world_admissions.erase(join_ticket)
		var world_key := str(admission.get("world_key", ""))
		var peer_id := int(admission.get("peer_id", 0))
		if world_process_manager and world_process_manager.has_method("release_world_join") and NET_CONFIG.is_valid_world_key(world_key):
			world_process_manager.release_world_join(world_key, peer_id)
		_notify_source_world_transfer_completed(
			str(admission.get("source_world", "")),
			peer_id,
			world_key,
			false,
			str(admission.get("transfer_request_id", "")),
			str(admission.get("travel_lease_id", ""))
		)


func _trim_pending_world_admissions() -> void:
	if pending_world_admissions.size() < MAX_PENDING_WORLD_ADMISSIONS_TOTAL:
		return
	var join_tickets: Array[String] = []
	for join_ticket in pending_world_admissions.keys():
		join_tickets.append(str(join_ticket))
	join_tickets.sort_custom(func(a: String, b: String) -> bool:
		var a_admission: Dictionary = pending_world_admissions.get(a, {})
		var b_admission: Dictionary = pending_world_admissions.get(b, {})
		return float(a_admission.get("expires_at", 0.0)) < float(b_admission.get("expires_at", 0.0))
	)
	while join_tickets.size() >= MAX_PENDING_WORLD_ADMISSIONS_TOTAL:
		var oldest_ticket: String = join_tickets.pop_front()
		if not pending_world_admissions.has(oldest_ticket):
			continue
		var admission: Dictionary = pending_world_admissions[oldest_ticket]
		pending_world_admissions.erase(oldest_ticket)
		var world_key := str(admission.get("world_key", ""))
		var peer_id := int(admission.get("peer_id", 0))
		if world_process_manager and world_process_manager.has_method("release_world_join") and NET_CONFIG.is_valid_world_key(world_key):
			world_process_manager.release_world_join(world_key, peer_id)
		_notify_source_world_transfer_completed(
			str(admission.get("source_world", "")),
			peer_id,
			world_key,
			false,
			str(admission.get("transfer_request_id", "")),
			str(admission.get("travel_lease_id", ""))
		)


func _expire_travel_leases() -> void:
	var now := Time.get_unix_time_from_system()
	for travel_lease_id in travel_leases.keys():
		var lease: Dictionary = travel_leases[travel_lease_id]
		if float(lease.get("expires_at", 0.0)) <= now or float(lease.get("hard_expires_at", 0.0)) <= now:
			_expire_travel_lease(str(travel_lease_id), lease)


func _expire_travel_lease(travel_lease_id: String, lease: Dictionary) -> void:
	travel_leases.erase(travel_lease_id)
	_notify_source_world_transfer_completed(
		str(lease.get("source_world", "")),
		int(lease.get("peer_id", 0)),
		str(lease.get("target_world", "")),
		false,
		str(lease.get("transfer_request_id", "")),
		travel_lease_id
	)


func _notify_source_world_transfer_lease_created(source_world: String, master_peer_id: int, target_world: String, transfer_request_id: String, travel_lease_id: String, hard_expires_at: float) -> void:
	if source_world.is_empty():
		return
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == source_world and _is_peer_open(int(peer_id)):
			world_transfer_lease_created.rpc_id(int(peer_id), master_peer_id, target_world, transfer_request_id, travel_lease_id, hard_expires_at)
			return


func _notify_source_world_transfer_completed(source_world: String, master_peer_id: int, target_world: String, approved: bool, transfer_request_id: String, travel_lease_id: String) -> void:
	if source_world.is_empty():
		return
	for peer_id in peer_worlds.keys():
		if str(peer_worlds[peer_id]) == source_world and _is_peer_open(int(peer_id)):
			world_transfer_completed.rpc_id(int(peer_id), master_peer_id, target_world, approved, transfer_request_id, travel_lease_id)
			return


@rpc("authority", "call_remote", "reliable")
func world_transfer_completed(master_peer_id: int, target_world: String, approved: bool, transfer_request_id := "", travel_lease_id := "") -> void:
	if multiplayer.is_server():
		return

	world_transfer_result_received.emit(master_peer_id, target_world, approved, transfer_request_id, travel_lease_id)


func _is_peer_open(peer_id: int) -> bool:
	return NET_UTIL.is_peer_open(multiplayer, peer_id)


func _disconnect_peer(peer_id: int) -> void:
	NET_UTIL.disconnect_peer(multiplayer, peer_id)


func _disconnect_peer_after_rejection(peer_id: int) -> void:
	await get_tree().create_timer(0.2).timeout
	if not is_inside_tree():
		return
	if _is_peer_open(peer_id):
		_disconnect_peer(peer_id)


func _mark_client_peer_validated(peer_id: int) -> void:
	validated_client_peers[peer_id] = true
	if account_endpoint and account_endpoint.has_method("create_guest_session"):
		account_endpoint.create_guest_session(peer_id)


func _require_validated_client_peer(peer_id: int, rpc_name: String) -> bool:
	if is_validated_client_peer(peer_id):
		return true
	NetLog.print_line("[MASTER] rejected unvalidated client RPC peer=%s rpc=%s" % [peer_id, rpc_name])
	call_deferred("_disconnect_peer_after_rejection", peer_id)
	return false


func _expire_stale_worlds() -> void:
	if not multiplayer.is_server():
		return

	_expire_travel_leases()
	_expire_pending_world_admissions()
	var now := Time.get_unix_time_from_system()
	for world_key in world_last_seen.keys():
		if now - float(world_last_seen[world_key]) <= HEARTBEAT_TIMEOUT_SECONDS:
			continue
		if world_process_manager:
			world_process_manager.request_world_stop(str(world_key), "heartbeat_timeout")
		else:
			unregister_world_by_key(str(world_key), "heartbeat_timeout")
		NetLog.print_line("MASTER_WORLD_EXPIRED key=%s" % world_key)
