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
		NetLog.print_line("[MASTER] peer connected: %s" % peer_id)
	)
	master_api.peer_disconnected.connect(func(peer_id: int) -> void:
		NetLog.print_line("[MASTER] peer disconnected: %s" % peer_id)
		master_endpoint.unregister_peer(peer_id)
		chat_endpoint.unregister_peer(peer_id)
		account_endpoint.drop_session(peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(NET_CONFIG.MASTER_PORT, "*", NET_CONFIG.tls_server_options())
	if err != OK:
		push_error("[MASTER] failed to listen on port %d err=%s" % [NET_CONFIG.MASTER_PORT, err])
		get_tree().quit(10)
		return

	master_api.multiplayer_peer = peer
	NetLog.print_line(
		"MASTER_READY port=%d build=%s public_master_url=%s world_pack_base_url=%s world_pack_dir=%s"
		% [
			NET_CONFIG.MASTER_PORT,
			_project_version(),
			NET_CONFIG.master_url(),
			NET_CONFIG.world_pack_base_url(),
			NET_CONFIG.world_pack_dir(),
		]
	)


func _project_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.1"))
