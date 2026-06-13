extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var master_api: MultiplayerAPI

@onready var master_endpoint: Node = $MasterNet/MasterEndpoint
@onready var chat_endpoint: Node = $MasterNet/ChatEndpoint
@onready var account_endpoint: Node = $MasterNet/AccountEndpoint
@onready var database_service: Node = $DatabaseService
@onready var world_process_manager: Node = $WorldProcessManager


func _ready() -> void:
	world_process_manager.configure_master_endpoint(master_endpoint)
	master_endpoint.configure_world_process_manager(world_process_manager)
	master_endpoint.configure_account_endpoint(account_endpoint)
	chat_endpoint.configure_master_endpoint(master_endpoint)
	chat_endpoint.configure_account_endpoint(account_endpoint)
	account_endpoint.configure(database_service, master_endpoint)
	_start_master_server()


func _exit_tree() -> void:
	if world_process_manager:
		world_process_manager.stop_all_worlds("master_exit")


func _start_master_server() -> void:
	master_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(master_api, get_node("MasterNet").get_path())
	master_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[MASTER] peer connected: %s" % peer_id)
		# World server peers also connect to MasterNet; only client peers get a
		# guest session. World registration arrives separately and is filtered
		# downstream by is_registered_world_peer.
		account_endpoint.create_guest_session(peer_id)
	)
	master_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[MASTER] peer disconnected: %s" % peer_id)
		master_endpoint.unregister_peer(peer_id)
		chat_endpoint.unregister_peer(peer_id)
		account_endpoint.drop_session(peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(NET_CONFIG.MASTER_PORT)
	if err != OK:
		push_error("[MASTER] failed to listen on port %d err=%s" % [NET_CONFIG.MASTER_PORT, err])
		get_tree().quit(10)
		return

	master_api.multiplayer_peer = peer
	print("MASTER_READY port=%d" % NET_CONFIG.MASTER_PORT)
