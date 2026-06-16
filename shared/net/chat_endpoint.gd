extends Node

signal chat_received(sender_id: int, sender_name: String, message: String)

const MAX_MESSAGE_LENGTH := 200
const RATE_WINDOW_SECONDS := 3.0
const MAX_MESSAGES_PER_WINDOW := 10
const NET_UTIL := preload("res://shared/net/net_util.gd")

var peer_message_times := {}
var master_endpoint: Node
var account_endpoint: Node


func configure_master_endpoint(endpoint: Node) -> void:
	master_endpoint = endpoint


func configure_account_endpoint(endpoint: Node) -> void:
	account_endpoint = endpoint


func unregister_peer(peer_id: int) -> void:
	peer_message_times.erase(peer_id)


@rpc("any_peer", "call_remote", "reliable")
func send_chat(message: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not _is_validated_client_peer(sender_id):
		NetLog.print_line("[CHAT] rejected unvalidated peer %s" % sender_id)
		_reject_unvalidated_client_peer(sender_id, "send_chat")
		return
	if not _allow_message(sender_id):
		NetLog.print_line("[CHAT] rate limited peer %s" % sender_id)
		return

	var sanitized_message := message.strip_edges().left(MAX_MESSAGE_LENGTH)
	if sanitized_message.is_empty():
		return

	var sender_name := _display_name_for(sender_id)
	NetLog.print_line("[CHAT] received from peer %s (%s): %s" % [sender_id, sender_name, sanitized_message])
	_broadcast_chat(sender_id, sender_name, sanitized_message)


@rpc("authority", "call_remote", "reliable")
func receive_chat(sender_id: int, sender_name: String, message: String) -> void:
	if multiplayer.is_server():
		return

	NetLog.print_line("[CLIENT] chat from %s: %s" % [sender_name, message])
	chat_received.emit(sender_id, sender_name, message)


func _broadcast_chat(sender_id: int, sender_name: String, message: String) -> void:
	for peer_id in multiplayer.get_peers():
		if _is_world_peer(peer_id):
			continue
		if not _is_peer_open(peer_id):
			continue
		receive_chat.rpc_id(peer_id, sender_id, sender_name, message)


func _display_name_for(sender_id: int) -> String:
	if account_endpoint and account_endpoint.has_method("session_display_name"):
		return account_endpoint.session_display_name(sender_id)
	return "Peer-%d" % sender_id


func _is_world_peer(peer_id: int) -> bool:
	if not master_endpoint or not master_endpoint.has_method("is_registered_world_peer"):
		return false
	return master_endpoint.is_registered_world_peer(peer_id)


func _is_validated_client_peer(peer_id: int) -> bool:
	if not master_endpoint or not master_endpoint.has_method("is_validated_client_peer"):
		return false
	return master_endpoint.is_validated_client_peer(peer_id)


func _reject_unvalidated_client_peer(peer_id: int, rpc_name: String) -> void:
	if master_endpoint and master_endpoint.has_method("reject_unvalidated_client_peer"):
		master_endpoint.reject_unvalidated_client_peer(peer_id, rpc_name)


func _is_peer_open(peer_id: int) -> bool:
	return NET_UTIL.is_peer_open(multiplayer, peer_id)


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
