extends Node

const NET_CONFIG := preload("res://shared/net_config.gd")

var master_api: MultiplayerAPI

func _ready() -> void:
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
	var err := peer.create_server(NET_CONFIG.MASTER_PORT, NET_CONFIG.HOST)
	if err != OK:
		push_error("[MASTER] failed to listen on %s:%d err=%s" % [NET_CONFIG.HOST, NET_CONFIG.MASTER_PORT, err])
		get_tree().quit(10)
		return

	master_api.multiplayer_peer = peer
	print("MASTER_READY port=%d" % NET_CONFIG.MASTER_PORT)
