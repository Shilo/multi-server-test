extends Node

signal world_state_received(world_key: String, allowed_targets: Array[String])

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var server_world_key := NET_CONFIG.initial_world()


func configure_server(world_key: String) -> void:
	server_world_key = world_key


@rpc("any_peer", "call_remote", "reliable")
func request_world_state() -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var allowed_targets := NET_CONFIG.allowed_targets(server_world_key)
	print("[WORLD %s] state request from peer %s" % [server_world_key, sender_id])
	receive_world_state.rpc_id(sender_id, server_world_key, allowed_targets)


@rpc("authority", "call_remote", "reliable")
func receive_world_state(world_key: String, allowed_targets: Array[String]) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] confirmed world %s; allowed=%s" % [world_key, str(allowed_targets)])
	world_state_received.emit(world_key, allowed_targets)
