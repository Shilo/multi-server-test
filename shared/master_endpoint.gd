extends Node

signal routes_received(routes: Dictionary)

const NET_CONFIG := preload("res://shared/net_config.gd")

@rpc("any_peer", "call_remote", "reliable")
func request_routes() -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	print("[MASTER] route request from peer %s" % sender_id)
	receive_routes.rpc_id(sender_id, NET_CONFIG.routes())


@rpc("authority", "call_remote", "reliable")
func receive_routes(routes: Dictionary) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] received master routes")
	routes_received.emit(routes)
