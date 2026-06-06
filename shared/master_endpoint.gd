extends Node

signal routes_received(routes: Dictionary)

const NET_CONFIG := preload("res://shared/net_config.gd")

var registered_worlds := {}
var peer_worlds := {}

func unregister_peer(peer_id: int) -> void:
	if not multiplayer.is_server() or not peer_worlds.has(peer_id):
		return

	var world_id: int = peer_worlds[peer_id]
	peer_worlds.erase(peer_id)
	registered_worlds.erase(world_id)
	print("MASTER_WORLD_DEREGISTERED id=%d peer=%s" % [world_id, peer_id])


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
func register_world(world_id: int, endpoint: Dictionary, allowed_targets: Array) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var normalized_endpoint := endpoint.duplicate(true)
	normalized_endpoint["allowed_targets"] = allowed_targets
	registered_worlds[world_id] = normalized_endpoint
	peer_worlds[sender_id] = world_id
	print("MASTER_WORLD_REGISTERED id=%d peer=%s url=%s allowed=%s" % [world_id, sender_id, normalized_endpoint["url"], str(allowed_targets)])
	world_registered_ack.rpc_id(sender_id, world_id)


@rpc("any_peer", "call_remote", "unreliable")
func world_heartbeat(world_id: int) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	#if peer_worlds.get(sender_id, 0) == world_id:
		#print("MASTER_WORLD_HEARTBEAT id=%d peer=%s" % [world_id, sender_id])


@rpc("authority", "call_remote", "reliable")
func world_registered_ack(world_id: int) -> void:
	if multiplayer.is_server():
		return

	print("[WORLD %d] master registration acknowledged" % world_id)


@rpc("authority", "call_remote", "reliable")
func receive_routes(routes: Dictionary) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] received master routes")
	routes_received.emit(routes)
