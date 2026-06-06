extends Node

signal chat_received(message: String)

@rpc("any_peer", "call_remote", "reliable")
func send_chat(message: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	print("[CHAT] received from peer %s: %s" % [sender_id, message])
	receive_chat.rpc(message)


@rpc("authority", "call_remote", "reliable")
func receive_chat(message: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] chat echo: %s" % message)
	chat_received.emit(message)
