extends Node

signal world_state_received(world_key: String)
signal world_join_authorized(peer_id: int)
signal world_join_rejected(world_key: String, reason: String)
signal portal_use_requested(peer_id: int, portal_name: String)
signal portal_use_denied(portal_name: String, reason: String)

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var server_world_key := NET_CONFIG.initial_world()
var admission_checker := Callable()


func configure_server(world_key: String, checker := Callable()) -> void:
	server_world_key = world_key
	admission_checker = checker


@rpc("any_peer", "call_remote", "reliable")
func request_world_state(join_ticket := "") -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	print("[WORLD %s] state request from peer %s" % [server_world_key, sender_id])
	var is_admitted := await _is_join_admitted(sender_id, join_ticket)
	if not is_admitted:
		reject_world_join.rpc_id(sender_id, server_world_key, "admission_denied")
		_disconnect_peer(sender_id)
		return

	world_join_authorized.emit(sender_id)
	receive_world_state.rpc_id(sender_id, server_world_key)


@rpc("authority", "call_remote", "reliable")
func receive_world_state(world_key: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] confirmed world %s" % world_key)
	world_state_received.emit(world_key)


@rpc("authority", "call_remote", "reliable")
func reject_world_join(world_key: String, reason: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] world join rejected key=%s reason=%s" % [world_key, reason])
	world_join_rejected.emit(world_key, reason)


@rpc("any_peer", "call_remote", "reliable")
func request_portal_use(portal_name: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	portal_use_requested.emit(sender_id, portal_name)


@rpc("authority", "call_remote", "reliable")
func deny_portal_use(portal_name: String, reason: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] portal use denied portal=%s reason=%s" % [portal_name, reason])
	portal_use_denied.emit(portal_name, reason)


func _is_join_admitted(sender_id: int, join_ticket: String) -> bool:
	if not admission_checker.is_valid():
		return true
	return await admission_checker.call(sender_id, join_ticket)


func _disconnect_peer(peer_id: int) -> void:
	var peer := multiplayer.multiplayer_peer
	if peer and peer.has_method("disconnect_peer"):
		peer.disconnect_peer(peer_id)
