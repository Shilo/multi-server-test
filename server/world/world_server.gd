extends Node

const CLI_ARGS := preload("res://shared/cli_args.gd")
const NET_CONFIG := preload("res://shared/net_config.gd")

var world_api: MultiplayerAPI
var world_id := 1

func _ready() -> void:
	world_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	var args := OS.get_cmdline_user_args()
	world_id = int(CLI_ARGS.get_value(args, "world", "1"))
	if not NET_CONFIG.WORLD_PORTS.has(world_id):
		push_error("[WORLD] invalid --world %d" % world_id)
		get_tree().quit(12)
		return

	$WorldNet/WorldEndpoint.configure_server(world_id)
	world_api.peer_connected.connect(func(peer_id: int) -> void:
		print("[WORLD %d] peer connected: %s" % [world_id, peer_id])
	)
	world_api.peer_disconnected.connect(func(peer_id: int) -> void:
		print("[WORLD %d] peer disconnected: %s" % [world_id, peer_id])
	)

	var peer := WebSocketMultiplayerPeer.new()
	var port: int = NET_CONFIG.WORLD_PORTS[world_id]
	var err := peer.create_server(port, NET_CONFIG.HOST)
	if err != OK:
		push_error("[WORLD %d] failed to listen on %s:%d err=%s" % [world_id, NET_CONFIG.HOST, port, err])
		get_tree().quit(13)
		return

	world_api.multiplayer_peer = peer
	print("WORLD_READY id=%d port=%d scene=%s" % [world_id, port, NET_CONFIG.world_scene_path(world_id)])
