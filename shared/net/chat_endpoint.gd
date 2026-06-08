extends Node

signal chat_received(sender_id: int, message: String)

@rpc("any_peer", "call_remote", "reliable")
func send_chat(message: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	print("[CHAT] received from peer %s: %s" % [sender_id, message])
	receive_chat.rpc(sender_id, message)


@rpc("authority", "call_remote", "reliable")
func receive_chat(sender_id: int, message: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] chat from %d: %s" % [sender_id, message])
	chat_received.emit(sender_id, message)
