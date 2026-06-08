extends Node

signal chat_received(sender_id: int, message: String)

const MAX_MESSAGE_LENGTH := 200
const RATE_WINDOW_SECONDS := 3.0
const MAX_MESSAGES_PER_WINDOW := 5

var peer_message_times := {}


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
	receive_chat.rpc(sender_id, sanitized_message)


@rpc("authority", "call_remote", "reliable")
func receive_chat(sender_id: int, message: String) -> void:
	if multiplayer.is_server():
		return

	print("[CLIENT] chat from %d: %s" % [sender_id, message])
	chat_received.emit(sender_id, message)


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
