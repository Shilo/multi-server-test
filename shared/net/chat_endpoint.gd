extends Node

signal chat_received(sender_id: int, message: String)

const MAX_MESSAGE_LENGTH := 200
const RATE_WINDOW_SECONDS := 3.0
const MAX_MESSAGES_PER_WINDOW := 10

var peer_message_times := {}
var master_endpoint: Node


func configure_master_endpoint(endpoint: Node) -> void:
	master_endpoint = endpoint


func unregister_peer(peer_id: int) -> void:
	peer_message_times.erase(peer_id)


@rpc("any_peer", "call_remote", "reliable")
func send_chat(message: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _allow_message(sender_id):
		print("[CHAT] rate limited peer %s" % sender_id)
		return

	var sanitized_message := message.strip_edges().left(MAX_MESSAGE_LENGTH)
	if sanitized_message.is_empty():
		return

	print("[CHAT] received from peer %s: %s" % [sender_id, sanitized_message])
	_broadcast_chat(sender_id, sanitized_message)


@rpc("authority", "call_remote", "reliable")
func receive_chat(sender_id: int, message: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] chat from %d: %s" % [sender_id, message])
	chat_received.emit(sender_id, message)


func _broadcast_chat(sender_id: int, message: String) -> void:
	for peer_id in multiplayer.get_peers():
		if _is_world_peer(peer_id):
			continue
		if not _is_peer_open(peer_id):
			continue
		receive_chat.rpc_id(peer_id, sender_id, message)


func _is_world_peer(peer_id: int) -> bool:
	if not master_endpoint or not master_endpoint.has_method("is_registered_world_peer"):
		return false
	return master_endpoint.is_registered_world_peer(peer_id)


func _is_peer_open(peer_id: int) -> bool:
	var peer := multiplayer.multiplayer_peer
	if not peer or not peer.has_method("get_peer"):
		return peer_id in multiplayer.get_peers()

	var socket = peer.get_peer(peer_id)
	if not socket or not socket.has_method("get_ready_state"):
		return peer_id in multiplayer.get_peers()

	return socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func _allow_message(sender_id: int) -> bool:
	var now := Time.get_unix_time_from_system()
	var times: Array = peer_message_times.get(sender_id, [])
	var kept_times: Array = []
	for time in times:
		if now - float(time) <= RATE_WINDOW_SECONDS:
			kept_times.append(time)

	if kept_times.size() >= MAX_MESSAGES_PER_WINDOW:
		peer_message_times[sender_id] = kept_times
		return false

	kept_times.append(now)
	peer_message_times[sender_id] = kept_times
	return true
