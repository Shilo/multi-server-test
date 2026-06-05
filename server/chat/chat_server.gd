extends Node

const NET_CONFIG := preload("res://shared/net_config.gd")

var chat_api: MultiplayerAPI

func _ready() -> void:
	chat_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(chat_api, get_node("ChatNet").get_path())
	chat_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[CHAT] peer connected: %s" % peer_id)
	)
	chat_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[CHAT] peer disconnected: %s" % peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(NET_CONFIG.CHAT_PORT, NET_CONFIG.HOST)
	if err != OK:
		push_error("[CHAT] failed to listen on %s:%d err=%s" % [NET_CONFIG.HOST, NET_CONFIG.CHAT_PORT, err])
		get_tree().quit(11)
		return

	chat_api.multiplayer_peer = peer
	print("CHAT_READY port=%d" % NET_CONFIG.CHAT_PORT)
