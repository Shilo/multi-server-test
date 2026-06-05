extends Node

signal world_state_received(world_id: int, allowed_targets: Array)
signal transfer_approved(target_world: int, endpoint: Dictionary)
signal transfer_denied(target_world: int)

const NET_CONFIG := preload("res://shared/net_config.gd")

var server_world_id := 1

func configure_server(world_id: int) -> void:
	server_world_id = world_id


@rpc("any_peer", "call_remote", "reliable")
func request_world_state() -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	print("[WORLD %d] state request from peer %s" % [server_world_id, sender_id])
	receive_world_state.rpc_id(sender_id, server_world_id, NET_CONFIG.allowed_targets(server_world_id))


@rpc("any_peer", "call_remote", "reliable")
func request_transfer(target_world: int) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var allowed := NET_CONFIG.allowed_targets(server_world_id)
	print("[WORLD %d] transfer request from peer %s to world %d" % [server_world_id, sender_id, target_world])
	if target_world in allowed:
		approve_transfer.rpc_id(sender_id, target_world, NET_CONFIG.world_endpoint(target_world))
	else:
		deny_transfer.rpc_id(sender_id, target_world)


@rpc("authority", "call_remote", "reliable")
func receive_world_state(world_id: int, allowed_targets: Array) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] confirmed world %d; allowed=%s" % [world_id, str(allowed_targets)])
	world_state_received.emit(world_id, allowed_targets)


@rpc("authority", "call_remote", "reliable")
func approve_transfer(target_world: int, endpoint: Dictionary) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] transfer approved to world %d" % target_world)
	transfer_approved.emit(target_world, endpoint)


@rpc("authority", "call_remote", "reliable")
func deny_transfer(target_world: int) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] transfer denied to world %d" % target_world)
	transfer_denied.emit(target_world)
