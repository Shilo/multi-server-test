extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")

var master_api: MultiplayerAPI
var perf_monitor: PerfMonitor

@onready var master_endpoint: Node = $MasterNet/MasterEndpoint
@onready var chat_endpoint: Node = $MasterNet/ChatEndpoint
@onready var account_endpoint: Node = $MasterNet/AccountEndpoint
@onready var database_service: Node = $DatabaseService
@onready var world_process_manager: Node = $WorldProcessManager


func _ready() -> void:
	RuntimeLoopConfig.apply_master()
	_setup_perf_monitor()
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
	if perf_monitor:
		perf_monitor.register_multiplayer_api("master", master_api)
	master_api.peer_connected.connect(func(peer_id: int) -> void:
		if perf_monitor:
			perf_monitor.increment("master_peer_connected")
			perf_monitor.set_gauge("master_peers", _master_peer_count())
		NetLog.print_line("[MASTER] peer connected: %s" % peer_id)
	)
	master_api.peer_disconnected.connect(func(peer_id: int) -> void:
		if perf_monitor:
			perf_monitor.increment("master_peer_disconnected")
			perf_monitor.set_gauge("master_peers", _master_peer_count())
		NetLog.print_line("[MASTER] peer disconnected: %s" % peer_id)
		master_endpoint.unregister_peer(peer_id)
		chat_endpoint.unregister_peer(peer_id)
		account_endpoint.drop_session(peer_id)
	)

	var peer := WebSocketMultiplayerPeer.new()
	var bind_host := NET_CONFIG.bind_host()
	var err := peer.create_server(NET_CONFIG.MASTER_PORT, bind_host, NET_CONFIG.tls_server_options())
	if err != OK:
		push_error("[MASTER] failed to listen on %s:%d err=%s" % [bind_host, NET_CONFIG.MASTER_PORT, err])
		get_tree().quit(10)
		return

	master_api.multiplayer_peer = peer
	NetLog.print_line(
		"MASTER_READY bind=%s port=%d build=%s public_master_url=%s world_pack_base_url=%s world_pack_dir=%s"
		% [
			bind_host,
			NET_CONFIG.MASTER_PORT,
			_project_version(),
			NET_CONFIG.master_url(),
			NET_CONFIG.world_pack_base_url(),
			NET_CONFIG.world_pack_dir(),
		]
	)


func _setup_perf_monitor() -> void:
	perf_monitor = PerfMonitor.new()
	perf_monitor.name = "PerfMonitor"
	perf_monitor.configure("master", "master", _master_perf_stats)
	add_child(perf_monitor)


func _master_perf_stats() -> Dictionary:
	var stats := {
		"master_peers": _master_peer_count(),
		"registered_worlds": master_endpoint.registered_world_count() if master_endpoint else 0,
		"validated_clients": master_endpoint.validated_client_peers.size() if master_endpoint else 0,
		"travel_leases": master_endpoint.travel_leases.size() if master_endpoint else 0,
		"pending_world_admissions": master_endpoint.pending_world_admissions.size() if master_endpoint else 0,
		"active_world_join_requests": master_endpoint.active_world_join_requests.size() if master_endpoint else 0,
		"join_ticket_ack_success_total": master_endpoint.join_ticket_ack_success_count if master_endpoint else 0,
		"join_ticket_ack_timeout_total": master_endpoint.join_ticket_ack_timeout_count if master_endpoint else 0,
		"join_ticket_ack_last_msec": master_endpoint.join_ticket_ack_last_msec if master_endpoint else -1,
		"join_ticket_ack_timeout_last_msec": master_endpoint.join_ticket_ack_timeout_last_msec if master_endpoint else -1,
	}
	if world_process_manager and world_process_manager.has_method("perf_stats"):
		stats.merge(world_process_manager.perf_stats(), true)
	return stats


func _master_peer_count() -> int:
	if not master_api or not master_api.multiplayer_peer:
		return 0
	return master_api.get_peers().size()


func _project_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.1"))
