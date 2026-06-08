extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var master_api: MultiplayerAPI
var chat_api: MultiplayerAPI


func _ready() -> void:
	_start_master_server()
	_start_chat_server()


func _start_master_server() -> void:
	master_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(master_api, get_node("MasterNet").get_path())
	master_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[MASTER] peer connected: %s" % peer_id)
	)
	master_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[MASTER] peer disconnected: %s" % peer_id)
		$MasterNet/MasterEndpoint.unregister_peer(peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var bind_host := NET_CONFIG.master_bind_host()
	var err := peer.create_server(NET_CONFIG.MASTER_PORT, bind_host)
	if err != OK:
		push_error("[MASTER] failed to listen on %s:%d err=%s" % [bind_host, NET_CONFIG.MASTER_PORT, err])
		get_tree().quit(10)
		return

	master_api.multiplayer_peer = peer
	print("MASTER_READY bind=%s port=%d" % [bind_host, NET_CONFIG.MASTER_PORT])


func _start_chat_server() -> void:
	chat_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(chat_api, get_node("ChatNet").get_path())
	chat_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[CHAT] peer connected: %s" % peer_id)
	)
	chat_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[CHAT] peer disconnected: %s" % peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var bind_host := NET_CONFIG.chat_bind_host()
	var err := peer.create_server(NET_CONFIG.CHAT_PORT, bind_host)
	if err != OK:
		push_error("[CHAT] failed to listen on %s:%d err=%s" % [bind_host, NET_CONFIG.CHAT_PORT, err])
		get_tree().quit(11)
		return

	chat_api.multiplayer_peer = peer
	print("CHAT_READY bind=%s port=%d" % [bind_host, NET_CONFIG.CHAT_PORT])
