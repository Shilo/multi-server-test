extends Node

signal routes_received(routes: Dictionary)
signal transfer_approved(target_world: String, endpoint: Dictionary)
signal transfer_denied(target_world: String)

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var registered_worlds := {}
var peer_worlds := {}


func unregister_peer(peer_id: int) -> void:
	if not multiplayer.is_server() or not peer_worlds.has(peer_id):
		return

	var world_key := str(peer_worlds[peer_id])
	peer_worlds.erase(peer_id)
	registered_worlds.erase(world_key)
	print("MASTER_WORLD_DEREGISTERED key=%s peer=%s" % [world_key, peer_id])


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
	receive_routes.rpc_id(sender_id, live_routes())


@rpc("any_peer", "call_remote", "reliable")
func register_world(world_key: String, endpoint: Dictionary, allowed_targets: Array) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not NET_CONFIG.is_valid_world_key(world_key):
		push_error("[MASTER] rejected invalid world registration: %s" % world_key)
		return

	var normalized_endpoint := endpoint.duplicate(true)
	normalized_endpoint["allowed_targets"] = allowed_targets
	registered_worlds[world_key] = normalized_endpoint
	peer_worlds[sender_id] = world_key
	print("MASTER_WORLD_REGISTERED key=%s peer=%s url=%s allowed=%s" % [world_key, sender_id, normalized_endpoint["url"], str(allowed_targets)])
	world_registered_ack.rpc_id(sender_id, world_key)


@rpc("any_peer", "call_remote", "reliable")
func request_transfer(current_world: String, target_world: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var allowed_targets := NET_CONFIG.allowed_targets(current_world) if NET_CONFIG.is_valid_world_key(current_world) else []
	print("[MASTER] transfer request from peer %s: %s -> %s" % [sender_id, current_world, target_world])
	if target_world in allowed_targets and registered_worlds.has(target_world):
		approve_transfer.rpc_id(sender_id, target_world, registered_worlds[target_world])
	else:
		deny_transfer.rpc_id(sender_id, target_world)


@rpc("any_peer", "call_remote", "unreliable")
func world_heartbeat(_world_key: String) -> void:
	if not multiplayer.is_server():
		return


@rpc("authority", "call_remote", "reliable")
func world_registered_ack(world_key: String) -> void:
	if multiplayer.is_server():
		return

	print("[WORLD %s] master registration acknowledged" % world_key)


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
