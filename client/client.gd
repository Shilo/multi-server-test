extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const CHAT_SCENE := preload("res://client/chat/chat.tscn")
const LOGIN_PANEL_SCENE := preload("res://client/login/login_panel.tscn")
const SMOKE_TEST_ARG := "smoke_test"
const WORLD_CRASH_RECOVERY_TEST_ARG := "world_crash_recovery_test"
const MANUAL_PORTAL_TEST_ARG := "manual_portal_test"
const DB_PERSIST_TEST_ARG := "db_persist_test"
const VERSION_GATE_BYPASS_TEST_ARG := "version_gate_bypass_test"
const FORCE_PACKRAT_WORLD_PACKS_ARG := "force_packrat_world_packs"
const USE_BUNDLED_WORLD_SCENES_ARG := "use_bundled_world_scenes"
const SMOKE_PACKRAT_CACHE_DIR_PREFIX := "smoke_packrat_cache_dir="
const EDITOR_PACK_EXPORT_PRESET_PREFIX := "World Pack - "
const EDITOR_SIMULATED_LOCAL_LOAD_SECONDS := 1.0
const TRAVEL_LEASE_REFRESH_INTERVAL_SECONDS := 10.0
const TRAVEL_LEASE_REDEEM_GRACE_SECONDS := 5.0
const WORLD_JOIN_TICKET_TIMEOUT_SECONDS := 12.0
const MASTER_BOOTSTRAP_ATTEMPTS := 5
const MASTER_BOOTSTRAP_RETRY_DELAY_SECONDS := 1.0
const WORLD_CONNECT_ATTEMPTS := 3
const WORLD_CONNECT_RETRY_DELAY_SECONDS := 0.35
const WORLD_STATE_TIMEOUT_SECONDS := 5.0
const PORTAL_TEST_REPLICATION_SETTLE_SECONDS := 2.5
const WEB_PORTAL_TEST_REPLICATION_SETTLE_SECONDS := 4.0
const WORLD_DISCONNECT_RECOVERY_DELAY_SECONDS := 0.75

var master_api: MultiplayerAPI
var world_api: MultiplayerAPI

var routes := {}
var chat_echoes: Array[String] = []
var chat_receipts := {}
var active_world_key := ""
var current_world_scene: Node
var pending_transfer := {}
var denied_transfer := ""
var requested_transfer_target := ""
var requested_transfer_portal := ""
var transfer_request_generation := 0
var transfer_in_progress := false
var pending_join_endpoint := {}
var pending_join_world := ""
var denied_join_world := ""
var denied_join_reason := ""
var join_keepalive_world := ""
var join_keepalive_active := false
var connecting_world_key := ""
var rejected_world_join := ""
var smoke_test := false
var chat_connected := false
var chat: Node
var login_panel: Node
var resume_in_progress := false
var resume_target := ""
var session_display_name := ""
var session_is_guest := true
var world_pack_last_logged_percent := -10
var world_pack_last_logged_msec := 0
var travel_lease_keepalive_id := ""
var travel_lease_keepalive_active := false
var travel_lease_keepalive_generation := 0
var route_rejection_reason := ""
var launch_args := PackedStringArray()
var connection_dialog: AcceptDialog
var perf_monitor: PerfMonitor
var perf_ping_timer: Timer
var network_stats_timer: Timer
var master_ping_msec := -1
var world_ping_msec := -1
var last_world_pack_status := "none"
var last_world_pack_bytes := 0
var last_world_pack_msec := -1
var last_transfer_msec := -1
var world_disconnect_recovery_in_progress := false
var world_disconnect_recovery_succeeded_count := 0
var world_rejoin_requests := {}

@onready var master_endpoint: Node = $MasterNet/MasterEndpoint
@onready var chat_endpoint: Node = $MasterNet/ChatEndpoint
@onready var account_endpoint: Node = $MasterNet/AccountEndpoint
@onready var world_endpoint: Node = $WorldNet/WorldEndpoint
@onready var world_view: Node2D = $WorldNet/WorldSceneRoot
@onready var canvas_layer: CanvasLayer = $CanvasLayer
@onready var status_label: Label = $CanvasLayer/StatusLabel
@onready var world_pack_progress: ProgressBar = $CanvasLayer/WorldPackProgress
@onready var network_stats_label: Label = $CanvasLayer/NetworkStatsLabel


func _ready() -> void:
	launch_args = _runtime_user_args()
	smoke_test = (
		SMOKE_TEST_ARG in launch_args
		or VERSION_GATE_BYPASS_TEST_ARG in launch_args
		or WORLD_CRASH_RECOVERY_TEST_ARG in launch_args
	)
	NetLog.print_line("[CLIENT] build version: %s" % _project_version())
	_setup_perf_monitor()
	_setup_chat()
	_setup_login_panel()
	_setup_multiplayer_branches()
	master_endpoint.routes_received.connect(func(new_routes: Dictionary) -> void:
		routes = new_routes
	)
	master_endpoint.routes_rejected.connect(_on_routes_rejected)
	master_endpoint.travel_lease_granted.connect(_on_travel_lease_granted)
	master_endpoint.transfer_denied.connect(_on_transfer_denied)
	master_endpoint.world_join_approved.connect(_on_world_join_approved)
	master_endpoint.world_join_denied.connect(_on_world_join_denied)
	master_endpoint.perf_pong_received.connect(_on_master_perf_pong_received)
	account_endpoint.session_updated.connect(_on_session_updated)
	account_endpoint.resume_world_requested.connect(_on_resume_world_requested)
	account_endpoint.login_failed.connect(_on_login_failed)
	chat_endpoint.chat_received.connect(func(sender_id: int, sender_name: String, message: String) -> void:
		chat_echoes.append(message)
		chat_receipts["%d:%s" % [sender_id, message]] = true
		if chat and chat.has_method("add_chat_line"):
			chat.add_chat_line(sender_name, message)
	)
	world_endpoint.world_state_received.connect(func(world_key: String) -> void:
		if not connecting_world_key.is_empty() and world_key != connecting_world_key:
			NetLog.print_line("[CLIENT] ignoring unexpected world state %s while connecting to %s" % [world_key, connecting_world_key])
			return
		active_world_key = world_key
		_set_status("In %s; chat echoes=%d" % [active_world_key, chat_echoes.size()])
	)
	world_endpoint.world_join_rejected.connect(func(world_key: String, _reason: String) -> void:
		rejected_world_join = world_key
	)
	world_endpoint.portal_use_denied.connect(func(portal_name: String, _reason: String) -> void:
		if requested_transfer_portal == portal_name:
			denied_transfer = requested_transfer_target
			requested_transfer_portal = ""
			requested_transfer_target = ""
	)
	world_endpoint.perf_pong_received.connect(_on_world_perf_pong_received)

	var user_args := launch_args
	if VERSION_GATE_BYPASS_TEST_ARG in user_args:
		run_version_gate_bypass_test()
	elif WORLD_CRASH_RECOVERY_TEST_ARG in user_args:
		run_world_crash_recovery_test()
	elif DB_PERSIST_TEST_ARG in user_args and user_args.size() >= 3:
		run_db_persist_test(str(user_args[1]), str(user_args[2]))
	elif smoke_test:
		run_smoke_test()
	else:
		run_manual_client()


func _setup_multiplayer_branches() -> void:
	master_api = MultiplayerAPI.create_default_interface()
	world_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(master_api, get_node("MasterNet").get_path())
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	if perf_monitor:
		perf_monitor.register_multiplayer_api("master", master_api)
		perf_monitor.register_multiplayer_api("world", world_api)
	master_api.server_disconnected.connect(func() -> void:
		if perf_monitor:
			perf_monitor.increment("master_disconnected")
			perf_monitor.set_gauge("master_connected", 0)
		master_ping_msec = -1
		world_ping_msec = -1
		NetLog.print_line("[CLIENT] master server disconnected")
		chat_connected = false
		join_keepalive_active = false
		join_keepalive_world = ""
		_set_chat_connected(false)
		_add_chat_system_line("master disconnected")
		if route_rejection_reason.is_empty():
			_show_server_unavailable_prompt("Connection Lost", "The game server disconnected. It may be restarting for an update.")
	)
	world_api.server_disconnected.connect(func() -> void:
		if perf_monitor:
			perf_monitor.increment("world_disconnected")
			perf_monitor.set_gauge("world_connected", 0)
		world_ping_msec = -1
		var disconnected_world := active_world_key
		if disconnected_world.is_empty():
			disconnected_world = connecting_world_key
		NetLog.print_line("[CLIENT] world server disconnected key=%s" % disconnected_world)
		active_world_key = ""
		if not disconnected_world.is_empty() and not transfer_in_progress and _is_master_connected():
			call_deferred("_recover_world_disconnect", disconnected_world)
		else:
			if transfer_in_progress:
				pending_transfer = {}
				requested_transfer_portal = ""
				requested_transfer_target = ""
			if not smoke_test:
				_show_server_unavailable_prompt("World Disconnected", "The world server disconnected. Return to the game shortly.")
	)


func _setup_perf_monitor() -> void:
	perf_monitor = PerfMonitor.new()
	perf_monitor.name = "PerfMonitor"
	perf_monitor.configure("client", "client-%d" % OS.get_process_id(), _client_perf_stats)
	add_child(perf_monitor)
	_start_perf_ping_timer()
	_start_network_stats_timer()


func _client_perf_stats() -> Dictionary:
	return {
		"active_world": active_world_key,
		"connecting_world": connecting_world_key,
		"transfer_in_progress": int(transfer_in_progress),
		"master_connected": int(_is_master_connected()),
		"world_connected": int(_is_world_connected()),
		"chat_connected": int(chat_connected),
		"routes": routes.size(),
		"chat_echoes": chat_echoes.size(),
		"pending_join": int(not pending_join_world.is_empty()),
		"pending_transfer": pending_transfer.size(),
		"join_keepalive": int(join_keepalive_active),
		"travel_lease_keepalive": int(travel_lease_keepalive_active),
		"world_pack_progress_visible": int(world_pack_progress.visible),
		"world_pack_progress_value": int(world_pack_progress.value),
		"world_pack_progress_max": int(world_pack_progress.max_value),
		"network_stats_ui_visible": int(is_instance_valid(network_stats_label) and network_stats_label.visible),
		"client_master_ping_msec": master_ping_msec,
		"client_world_ping_msec": world_ping_msec,
		"last_world_pack_bytes": last_world_pack_bytes,
		"last_world_pack_msec": last_world_pack_msec,
		"last_transfer_msec": last_transfer_msec,
	}


func _start_perf_ping_timer() -> void:
	if perf_ping_timer:
		return
	perf_ping_timer = Timer.new()
	perf_ping_timer.name = "PerfPingTimer"
	perf_ping_timer.wait_time = 2.0
	perf_ping_timer.autostart = true
	perf_ping_timer.timeout.connect(_send_perf_pings)
	add_child(perf_ping_timer)


func _stop_perf_ping_timer() -> void:
	if not perf_ping_timer:
		return
	perf_ping_timer.stop()
	perf_ping_timer.queue_free()
	perf_ping_timer = null


func _start_network_stats_timer() -> void:
	if network_stats_timer:
		return
	network_stats_timer = Timer.new()
	network_stats_timer.name = "NetworkStatsTimer"
	network_stats_timer.wait_time = 0.5
	network_stats_timer.autostart = true
	network_stats_timer.timeout.connect(_update_network_stats_label)
	add_child(network_stats_timer)
	_update_network_stats_label()


func _send_perf_pings() -> void:
	var sent_msec := Time.get_ticks_msec()
	if _is_master_connected() and master_api.get_unique_id() != MultiplayerPeer.TARGET_PEER_SERVER:
		master_endpoint.perf_ping.rpc_id(1, "client_master", sent_msec)
	if _is_world_connected() and world_api.get_unique_id() != MultiplayerPeer.TARGET_PEER_SERVER:
		world_endpoint.perf_ping.rpc_id(1, "client_world", sent_msec)


func _on_master_perf_pong_received(label: String, sent_msec: int, _server_msec: int) -> void:
	var latency_msec := Time.get_ticks_msec() - sent_msec
	master_ping_msec = latency_msec
	if perf_monitor:
		perf_monitor.observe_latency(label, latency_msec)
	_update_network_stats_label()


func _on_world_perf_pong_received(label: String, sent_msec: int, _server_msec: int) -> void:
	var latency_msec := Time.get_ticks_msec() - sent_msec
	world_ping_msec = latency_msec
	if perf_monitor:
		perf_monitor.observe_latency(label, latency_msec)
	_update_network_stats_label()


func _recover_world_disconnect(world_key: String) -> void:
	if world_disconnect_recovery_in_progress:
		return
	world_disconnect_recovery_in_progress = true
	if perf_monitor:
		perf_monitor.increment("world_disconnect_recovery_started")
	_set_status("Reconnecting to %s" % world_key)
	await get_tree().create_timer(WORLD_DISCONNECT_RECOVERY_DELAY_SECONDS).timeout
	var ok := false
	if _is_master_connected() and not transfer_in_progress:
		world_rejoin_requests[world_key] = true
		ok = await _connect_transfer_world(world_key)
		world_rejoin_requests.erase(world_key)
	world_disconnect_recovery_in_progress = false
	if ok:
		if perf_monitor:
			perf_monitor.increment("world_disconnect_recovery_succeeded")
		world_disconnect_recovery_succeeded_count += 1
		NetLog.print_line("[CLIENT] world reconnect succeeded key=%s" % world_key)
		return
	if perf_monitor:
		perf_monitor.increment("world_disconnect_recovery_failed")
	NetLog.print_line("[CLIENT] world reconnect failed key=%s" % world_key)
	if not smoke_test:
		_show_server_unavailable_prompt("World Disconnected", "The world server disconnected and reconnect failed. Try again shortly.")


func _update_network_stats_label() -> void:
	if not is_instance_valid(network_stats_label):
		return

	var lines := [
		"net master=%s world=%s" % [_format_ping(master_ping_msec), _format_ping(world_ping_msec)],
		"ws buffered master=%s world=%s" % [
			_format_bytes(_websocket_buffered_bytes(master_api)),
			_format_bytes(_websocket_buffered_bytes(world_api)),
		],
		"world %s routes=%d chat=%s" % [
			active_world_key if not active_world_key.is_empty() else "-",
			routes.size(),
			"on" if chat_connected else "off",
		],
		"pack %s %s in %s" % [
			last_world_pack_status,
			_format_bytes(last_world_pack_bytes),
			_format_duration(last_world_pack_msec),
		],
		"transfer %s fps=%d" % [
			_format_duration(last_transfer_msec),
			int(Performance.get_monitor(Performance.TIME_FPS)),
		],
	]
	network_stats_label.text = "\n".join(lines)


func _format_ping(value_msec: int) -> String:
	if value_msec < 0:
		return "--ms"
	return "%dms" % value_msec


func _format_duration(value_msec: int) -> String:
	if value_msec < 0:
		return "--ms"
	return "%dms" % value_msec


func _format_bytes(value: int) -> String:
	if value <= 0:
		return "0B"
	if value < 1024:
		return "%dB" % value
	if value < 1024 * 1024:
		return "%.1fKB" % (float(value) / 1024.0)
	return "%.1fMB" % (float(value) / (1024.0 * 1024.0))


func _websocket_buffered_bytes(api: MultiplayerAPI) -> int:
	if api == null:
		return 0
	var peer: Object = api.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return 0
	if not peer.has_method("get_peer"):
		return 0

	var total := 0
	for peer_id in _transport_peer_ids(api):
		var socket_peer: Variant = peer.get_peer(peer_id)
		if socket_peer != null and socket_peer.has_method("get_current_outbound_buffered_amount"):
			total += int(socket_peer.get_current_outbound_buffered_amount())
	return total


func _transport_peer_ids(api: MultiplayerAPI) -> Array[int]:
	if api == null:
		return []
	if api.is_server():
		var result: Array[int] = []
		for peer_id in api.get_peers():
			result.append(int(peer_id))
		return result
	return [MultiplayerPeer.TARGET_PEER_SERVER]


func _setup_chat() -> void:
	chat = CHAT_SCENE.instantiate()
	chat.message_submitted.connect(_on_chat_message_submitted)
	canvas_layer.add_child(chat)
	_add_chat_system_line("chat starting")


func _setup_login_panel() -> void:
	# The smoke client runs headless and never logs in; skip the widget there.
	if SMOKE_TEST_ARG in launch_args:
		return
	login_panel = LOGIN_PANEL_SCENE.instantiate()
	login_panel.login_submitted.connect(_on_login_submitted)
	login_panel.logout_requested.connect(_on_logout_requested)
	canvas_layer.add_child(login_panel)
	if login_panel.has_method("set_version_text"):
		login_panel.set_version_text(_display_version())


func _on_login_submitted(username: String) -> void:
	if _is_master_connected():
		account_endpoint.login.rpc_id(1, username)


func _on_logout_requested() -> void:
	if _is_master_connected():
		account_endpoint.logout.rpc_id(1)


func _on_session_updated(display_name: String, is_guest: bool, _account_id: int) -> void:
	session_display_name = display_name
	session_is_guest = is_guest
	if login_panel and login_panel.has_method("set_identity"):
		login_panel.set_identity(display_name, is_guest)


func _on_login_failed(reason: String) -> void:
	if login_panel and login_panel.has_method("show_error"):
		login_panel.show_error(reason)


func _on_resume_world_requested(world_key: String, endpoint: Dictionary) -> void:
	if not endpoint.is_empty():
		if not routes.has("worlds"):
			routes["worlds"] = {}
		var worlds: Dictionary = routes["worlds"]
		worlds[world_key] = endpoint
		routes["worlds"] = worlds
	resume_target = world_key
	call_deferred("_resume_into_world", world_key)


## Re-enter the world the master resumed us into after a login/logout. Reuses the
## normal world-join path, so it works whether the target is the current world
## (login while already in hub) or a different saved world.
func _resume_into_world(world_key: String) -> void:
	if resume_in_progress:
		return
	resume_in_progress = true
	var waited := 0.0
	while transfer_in_progress and waited < 5.0:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var ok := await _connect_transfer_world(world_key)
	resume_in_progress = false
	if ok:
		NetLog.print_line("[CLIENT] resumed into world %s" % active_world_key)
	else:
		push_error("[CLIENT] failed to resume into world %s" % world_key)


func run_manual_client() -> void:
	if await _bootstrap_connections(false):
		NetLog.print_line("[CLIENT] manual client ready")
		if MANUAL_PORTAL_TEST_ARG in launch_args:
			await _run_manual_portal_test()


func run_smoke_test() -> void:
	NetLog.print_line("SMOKE_STEP client starts")
	var ok := await _bootstrap_connections(true)
	if not ok:
		_smoke_fail("bootstrap failed")
		return

	var sequence := _smoke_transfer_sequence()
	for i in range(sequence.size()):
		var target_world := str(sequence[i])
		NetLog.print_line("SMOKE_STEP transfer %s_to_%s" % [active_world_key, target_world])
		ok = await _transfer_via_portal(target_world)
		if not ok:
			_smoke_fail("transfer to %s failed" % target_world)
			return
		ok = await _send_chat_ping("after-transfer-%d-world-%s" % [i + 1, active_world_key])
		if not ok:
			_smoke_fail("chat ping failed after %s" % active_world_key)
			return
		NetLog.print_line("SMOKE_STEP confirmed world %s with chat alive" % active_world_key)

	_stop_perf_ping_timer()
	await get_tree().create_timer(3.0).timeout
	NetLog.print_line("SMOKE_PASS")
	get_tree().quit(0)


func run_version_gate_bypass_test() -> void:
	smoke_test = true
	NetLog.print_line("VERSION_GATE_BYPASS_STEP start")
	var ok := await _connect_api(master_api, NET_CONFIG.master_url(), "master")
	if not ok:
		NetLog.print_line("VERSION_GATE_BYPASS_FAIL could not connect to master")
		get_tree().quit(1)
		return

	account_endpoint.login.rpc_id(1, "bypass")
	chat_endpoint.send_chat.rpc_id(1, "bypass")
	master_endpoint.request_world_join.rpc_id(1, NET_CONFIG.initial_world())
	ok = await _wait_until(
		func() -> bool:
			return not _is_master_connected(),
		3.0,
		"unvalidated peer disconnect",
		false
	)
	if ok:
		NetLog.print_line("VERSION_GATE_BYPASS_PASS")
		get_tree().quit(0)
	else:
		NetLog.print_line("VERSION_GATE_BYPASS_FAIL master kept unvalidated peer connected")
		get_tree().quit(1)


func run_world_crash_recovery_test() -> void:
	NetLog.print_line("WORLD_CRASH_RECOVERY_STEP start")
	var ok := await _bootstrap_connections(true)
	if not ok:
		NetLog.print_line("WORLD_CRASH_RECOVERY_FAIL bootstrap")
		get_tree().quit(1)
		return

	if active_world_key != "left_world":
		NetLog.print_line("WORLD_CRASH_RECOVERY_STEP transfer_to_left_world")
		ok = await _transfer_via_portal("left_world")
		if not ok:
			NetLog.print_line("WORLD_CRASH_RECOVERY_FAIL transfer_to_left_world active=%s" % active_world_key)
			get_tree().quit(1)
			return

	var initial_world := active_world_key
	NetLog.print_line("WORLD_CRASH_RECOVERY_READY world=%s" % initial_world)
	ok = await _wait_until(
		func() -> bool:
			return world_disconnect_recovery_succeeded_count > 0 and active_world_key == initial_world,
		20.0,
		"world crash recovery",
		true
	)
	if not ok:
		NetLog.print_line("WORLD_CRASH_RECOVERY_FAIL reconnect world=%s active=%s recoveries=%d" % [
			initial_world,
			active_world_key,
			world_disconnect_recovery_succeeded_count,
		])
		get_tree().quit(1)
		return

	ok = await _send_chat_ping("after-world-crash-recovery")
	if not ok:
		NetLog.print_line("WORLD_CRASH_RECOVERY_FAIL chat")
		get_tree().quit(1)
		return

	NetLog.print_line("WORLD_CRASH_RECOVERY_PASS world=%s" % active_world_key)
	get_tree().quit(0)


## Two-phase persistence test driven over the real network stack.
##   phase1 <name>: log in (creating the account), travel to left_world, park at
##                  a known position, and wait for it to persist.
##   phase2 <name>: log in again and assert we resumed into left_world at that
##                  same position. Run as two client processes sharing a master.
const DB_TEST_WORLD := "left_world"
const DB_TEST_POSITION := Vector2(213, 147)

func run_db_persist_test(phase: String, username: String) -> void:
	NetLog.print_line("DBTEST_STEP start phase=%s name=%s" % [phase, username])
	if not await _bootstrap_connections(false):
		_db_test_fail("bootstrap failed")
		return

	account_endpoint.login.rpc_id(1, username)
	if not await _wait_until(func() -> bool: return not session_is_guest, 5.0, "login"):
		_db_test_fail("login did not complete")
		return

	# Let the master-issued resume run and settle.
	await get_tree().create_timer(0.3).timeout
	if not await _wait_until(func() -> bool: return not resume_in_progress and not active_world_key.is_empty(), 8.0, "resume settle"):
		_db_test_fail("resume did not settle")
		return
	NetLog.print_line("DBTEST_STEP logged in as %s, resumed world=%s" % [session_display_name, active_world_key])

	if phase == "phase1":
		await _db_test_phase1()
	elif phase == "phase2":
		await _db_test_phase2()
	else:
		_db_test_fail("unknown phase %s" % phase)


func _db_test_phase1() -> void:
	if active_world_key != DB_TEST_WORLD:
		if not await _wait_until(func() -> bool: return _local_player() != null, 3.0, "local player spawn"):
			_db_test_fail("local player never spawned in %s" % active_world_key)
			return
		if not await _manual_travel(DB_TEST_WORLD):
			_db_test_fail("travel to %s failed" % DB_TEST_WORLD)
			return
	if not _set_local_player_position(DB_TEST_POSITION):
		_db_test_fail("could not place local player")
		return
	NetLog.print_line("DBTEST_STEP parked at %s pos=(%s,%s)" % [active_world_key, DB_TEST_POSITION.x, DB_TEST_POSITION.y])
	# Wait past one position-save interval (3s on the world) so it persists.
	await get_tree().create_timer(4.5).timeout
	NetLog.print_line("DBTEST_PHASE1_DONE world=%s" % active_world_key)
	get_tree().quit(0)


func _db_test_phase2() -> void:
	if active_world_key != DB_TEST_WORLD:
		_db_test_fail("expected resume into %s, got %s" % [DB_TEST_WORLD, active_world_key])
		return
	await get_tree().create_timer(0.5).timeout
	var pos := _local_player_position()
	NetLog.print_line("DBTEST_PHASE2 world=%s pos=(%s,%s)" % [active_world_key, pos.x, pos.y])
	if not pos.is_finite() or pos.distance_to(DB_TEST_POSITION) > 24.0:
		_db_test_fail("position not resumed (got %s, expected %s)" % [pos, DB_TEST_POSITION])
		return
	NetLog.print_line("DBTEST_PASS")
	get_tree().quit(0)


## Manual-mode travel: walk the local player into the portal and let the normal
## manual transfer auto-complete (client.gd's _on_travel_lease_granted) land us.
func _manual_travel(target_world: String) -> bool:
	if not current_world_scene or not current_world_scene.has_method("activate_portal_to"):
		return false
	if current_world_scene.has_method("move_local_player_to_portal"):
		current_world_scene.move_local_player_to_portal(target_world)
		await get_tree().create_timer(_portal_test_replication_settle_seconds()).timeout
	current_world_scene.activate_portal_to(target_world)
	return await _wait_until(func() -> bool: return active_world_key == target_world, 8.0, "travel to %s" % target_world)


func _db_test_fail(reason: String) -> void:
	NetLog.print_line("DBTEST_FAIL %s" % reason)
	get_tree().quit(1)


func _local_player() -> Node2D:
	if not current_world_scene:
		return null
	var spawn_root := current_world_scene.get_node_or_null("SpawnRoot")
	if not spawn_root:
		return null
	for child in spawn_root.get_children():
		if child is CharacterBody2D and child.is_multiplayer_authority():
			return child
	return null


func _set_local_player_position(pos: Vector2) -> bool:
	var player := _local_player()
	if not player:
		return false
	player.position = pos
	return true


func _local_player_position() -> Vector2:
	var player := _local_player()
	return player.position if player else Vector2.INF


func _smoke_transfer_sequence() -> Array[String]:
	var sequence: Array[String] = []
	var initial_world := NET_CONFIG.initial_world()
	var world_keys := _known_world_keys()
	if (
		initial_world == "hub"
		and "left_world" in world_keys
		and "right_world" in world_keys
		and "top_world" in world_keys
	):
		sequence = [
			"left_world",
			"top_world",
			"right_world",
			"hub",
			"top_world",
			"hub",
			"right_world",
			"left_world",
			"hub",
		]
		for world_key in world_keys:
			if world_key == initial_world or world_key in sequence:
				continue
			sequence.append(world_key)
			sequence.append(initial_world)
		return sequence

	for world_key in world_keys:
		if world_key == initial_world:
			continue
		sequence.append(world_key)
		sequence.append(initial_world)
	return sequence


func _bootstrap_connections(require_all_worlds: bool) -> bool:
	var ok := await _connect_master_and_routes()
	if not ok:
		if not route_rejection_reason.is_empty():
			return false
		_show_server_unavailable_prompt("Server Offline", "The game server is offline or restarting. Try again soon.")
		return false
	if not route_rejection_reason.is_empty():
		return false
	NetLog.print_line("SMOKE_STEP client connected to master" if require_all_worlds else "[CLIENT] connected to master")

	chat_connected = true
	_set_chat_connected(true)
	_add_chat_system_line("chat connected")
	if require_all_worlds:
		NetLog.print_line("SMOKE_STEP client chat ready")
		ok = await _send_chat_ping("initial")
		if not ok:
			return false

	var initial_world := str(routes["initial_world"])
	ok = await _connect_world(initial_world)
	if not ok:
		return false
	NetLog.print_line("SMOKE_STEP client confirmed initial world %s" % active_world_key if require_all_worlds else "[CLIENT] manual initial world ready: %s" % active_world_key)
	return true


func _connect_master_and_routes() -> bool:
	for attempt in range(MASTER_BOOTSTRAP_ATTEMPTS):
		route_rejection_reason = ""
		routes = {}
		master_api.multiplayer_peer = OfflineMultiplayerPeer.new()
		var report_error := attempt == MASTER_BOOTSTRAP_ATTEMPTS - 1
		var ok := await _connect_api(master_api, NET_CONFIG.master_url(), "master", 5.0, report_error)
		if ok:
			master_endpoint.request_routes.rpc_id(1, _project_version())
			var route_predicate := func() -> bool:
				return _has_initial_world_route() or not route_rejection_reason.is_empty()
			ok = await _wait_until(route_predicate, 5.0, "master routes", report_error)
			if not route_rejection_reason.is_empty():
				return false
			if ok and route_rejection_reason.is_empty():
				return true

		if attempt < MASTER_BOOTSTRAP_ATTEMPTS - 1:
			NetLog.print_line("[CLIENT] MASTER_BOOTSTRAP_RETRY attempt=%d" % [attempt + 2])
			await get_tree().create_timer(MASTER_BOOTSTRAP_RETRY_DELAY_SECONDS).timeout
	return false


func _has_initial_world_route() -> bool:
	if routes.is_empty() or not routes.has("worlds") or not routes.has("initial_world"):
		return false

	var worlds: Dictionary = routes["worlds"]
	return worlds.has(routes["initial_world"])


func _connect_world(world_key: String, route_override := {}) -> bool:
	var start_msec := Time.get_ticks_msec()
	var route_endpoint: Dictionary = route_override.duplicate(true) if not route_override.is_empty() else _world_route_or_catalog(world_key)
	if route_endpoint.is_empty():
		push_error("[CLIENT] no registered route for world %s" % world_key)
		if perf_monitor:
			perf_monitor.increment("world_connect_failed")
		return false

	_start_travel_lease_keepalive(route_endpoint)
	var assets_ready: bool = await _prepare_world_assets(world_key, route_endpoint)
	if not assets_ready:
		_release_travel_lease(route_endpoint)
		push_error("[CLIENT] assets unavailable for world %s" % world_key)
		if perf_monitor:
			perf_monitor.increment("world_connect_failed")
		return false

	world_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	active_world_key = ""
	connecting_world_key = world_key
	rejected_world_join = ""
	if not _load_world_scene(world_key, route_endpoint):
		_cancel_world_join(world_key, route_endpoint)
		connecting_world_key = ""
		if perf_monitor:
			perf_monitor.increment("world_connect_failed")
		return false

	_start_join_keepalive(world_key)
	var joined := await _connect_world_with_ticket_retries(world_key, route_endpoint)
	connecting_world_key = ""
	_stop_join_keepalive(world_key, joined, str(route_endpoint.get("travel_lease_id", "")))
	_stop_travel_lease_keepalive(str(route_endpoint.get("travel_lease_id", "")))
	if not joined:
		_release_travel_lease(route_endpoint)
	var elapsed_msec := Time.get_ticks_msec() - start_msec
	if perf_monitor:
		if joined:
			perf_monitor.increment("world_connect_succeeded")
			perf_monitor.observe_latency("world_ready", elapsed_msec)
		else:
			perf_monitor.increment("world_connect_failed")
	if joined:
		_remove_route_travel_lease(world_key, str(route_endpoint.get("travel_lease_id", "")))
		last_transfer_msec = elapsed_msec
		_update_network_stats_label()
	return joined


func _connect_world_with_ticket_retries(world_key: String, route_endpoint: Dictionary) -> bool:
	for attempt in range(WORLD_CONNECT_ATTEMPTS):
		var endpoint := await _request_world_join(world_key, route_endpoint)
		if endpoint.is_empty():
			if attempt < WORLD_CONNECT_ATTEMPTS - 1 and _is_transient_world_join_failure():
				NetLog.print_line("[CLIENT] WORLD_JOIN_RETRY key=%s attempt=%d reason=%s" % [world_key, attempt + 2, denied_join_reason])
				await get_tree().create_timer(WORLD_CONNECT_RETRY_DELAY_SECONDS).timeout
				continue
			return false

		rejected_world_join = ""
		world_api.multiplayer_peer = OfflineMultiplayerPeer.new()
		var ok := await _connect_api(world_api, str(endpoint["url"]), "world-%s" % world_key, 5.0, attempt == WORLD_CONNECT_ATTEMPTS - 1)
		if ok:
			world_endpoint.request_world_state.rpc_id(1, str(endpoint.get("join_ticket", "")))
			ok = await _wait_until(
				func() -> bool:
					return active_world_key == world_key or rejected_world_join == world_key or not _is_world_connected(),
				WORLD_STATE_TIMEOUT_SECONDS,
				"world %s state" % world_key
			)
			if ok and active_world_key == world_key and rejected_world_join != world_key:
				return true

		_cancel_world_join(world_key, route_endpoint)
		world_api.multiplayer_peer = OfflineMultiplayerPeer.new()
		if attempt < WORLD_CONNECT_ATTEMPTS - 1:
			NetLog.print_line("[CLIENT] WORLD_CONNECT_RETRY key=%s attempt=%d" % [world_key, attempt + 2])
			await get_tree().create_timer(WORLD_CONNECT_RETRY_DELAY_SECONDS).timeout
	return false


func _is_transient_world_join_failure() -> bool:
	return denied_join_reason.is_empty() or denied_join_reason in ["world_unavailable", "ticket_unavailable"]


func _prepare_world_assets(world_key: String, endpoint: Dictionary) -> bool:
	var scene_path := str(endpoint.get("scene", NET_CONFIG.world_scene_path(world_key)))
	var local_scene_available := ResourceLoader.exists(scene_path, "PackedScene")
	var use_editor_export := _use_editor_pack_exports()
	if local_scene_available and (_use_bundled_world_scenes() or (not _force_packrat_world_packs() and not use_editor_export)):
		NetLog.print_line("[CLIENT] WORLD_PACK_SKIPPED key=%s reason=local_scene_available arg=%s" % [world_key, FORCE_PACKRAT_WORLD_PACKS_ARG])
		last_world_pack_status = "bundled"
		last_world_pack_bytes = 0
		last_world_pack_msec = 0
		_update_network_stats_label()
		if perf_monitor:
			perf_monitor.increment("world_pack_skipped")
		return true

	var pack_url := str(endpoint.get("pack_url", ""))
	if pack_url.is_empty() and use_editor_export:
		pack_url = NET_CONFIG.world_pack_url(world_key)
	if pack_url.is_empty():
		push_error("[CLIENT] missing pack metadata for world %s; scene is not bundled: %s" % [world_key, scene_path])
		last_world_pack_status = "missing"
		last_world_pack_bytes = 0
		last_world_pack_msec = -1
		_update_network_stats_label()
		if perf_monitor:
			perf_monitor.increment("world_pack_failed")
		return false

	var expected_modified_time := int(endpoint.get("pack_modified_time", 0))
	var expected_size := int(endpoint.get("pack_size", 0))
	var options := PackRatOptions.from_expected_metadata(expected_modified_time, expected_size)
	options.id = world_key
	options.entry_path = scene_path
	options.progress_total_size = expected_size
	var smoke_cache_dir := _smoke_packrat_cache_dir()
	if not smoke_cache_dir.is_empty():
		options.cache_dir = smoke_cache_dir
	if use_editor_export:
		options.editor_pack_export_preset = _editor_pack_export_preset(world_key)
		options.editor_simulated_local_load_seconds = EDITOR_SIMULATED_LOCAL_LOAD_SECONDS
		options.expected_modified_time = 0
		options.expected_size = 0
		options.progress_total_size = 0
		expected_modified_time = 0
		expected_size = 0
		NetLog.print_line("[CLIENT] WORLD_PACK_EDITOR_EXPORT key=%s preset=%s simulated_seconds=%.1f" % [
			world_key,
			options.editor_pack_export_preset,
			options.editor_simulated_local_load_seconds,
		])

	NetLog.print_line("[CLIENT] WORLD_PACK_START key=%s url=%s size=%d modified_time=%d" % [
		world_key,
		pack_url,
		expected_size,
		expected_modified_time,
	])
	if perf_monitor:
		perf_monitor.increment("world_pack_started")
		perf_monitor.set_gauge("world_pack_expected_bytes", expected_size)
	last_world_pack_status = "loading"
	last_world_pack_bytes = 0
	last_world_pack_msec = -1
	_update_network_stats_label()
	_show_world_pack_progress(world_key, expected_size)
	var pack_start_msec := Time.get_ticks_msec()
	var request: PackRatRequest = PackRat.load_resource_pack_async(pack_url, options)
	request.progress_changed.connect(func(downloaded_bytes: int, total_bytes: int) -> void:
		_update_world_pack_progress(world_key, downloaded_bytes, total_bytes)
	)
	await _wait_for_pack_or_lease_expiry(world_key, endpoint, request)

	var result: PackRatResult = request.result
	_hide_world_pack_progress()
	for warning in result.warnings:
		NetLog.print_line("[CLIENT] PackRat warning for %s: %s" % [world_key, warning])
	var pack_elapsed_msec := Time.get_ticks_msec() - pack_start_msec
	if not result.ok:
		NetLog.print_line("[CLIENT] WORLD_PACK_FAILED key=%s url=%s error=%s" % [world_key, pack_url, result.error])
		push_error("[CLIENT] failed to load pack for %s from %s: %s" % [world_key, pack_url, result.error])
		last_world_pack_status = "failed"
		last_world_pack_bytes = result.content_length
		last_world_pack_msec = pack_elapsed_msec
		_update_network_stats_label()
		if perf_monitor:
			perf_monitor.increment("world_pack_failed")
		return false
	if not result.entry_scene_exists():
		push_error("[CLIENT] pack for %s mounted, but scene is missing: %s" % [world_key, scene_path])
		last_world_pack_status = "missing_scene"
		last_world_pack_bytes = result.content_length
		last_world_pack_msec = pack_elapsed_msec
		_update_network_stats_label()
		if perf_monitor:
			perf_monitor.increment("world_pack_failed")
		return false

	NetLog.print_line(
		"[CLIENT] WORLD_PACK_READY key=%s status=%s cache=%s bytes=%d path=%s" %
		[world_key, result.status, str(result.from_cache), result.content_length, result.local_path]
	)
	last_world_pack_status = result.status
	last_world_pack_bytes = result.content_length
	last_world_pack_msec = pack_elapsed_msec
	_update_network_stats_label()
	if perf_monitor:
		perf_monitor.increment("world_pack_ready")
		perf_monitor.observe_latency("world_pack_prepare", pack_elapsed_msec)
		if result.from_cache:
			perf_monitor.increment("world_pack_cache_hit")
		else:
			perf_monitor.increment("world_pack_downloaded")
			perf_monitor.add_bytes("world_pack_download_bytes", result.content_length)
	return true


func _wait_for_pack_or_lease_expiry(world_key: String, endpoint: Dictionary, request: PackRatRequest) -> void:
	var hard_expires_at := float(endpoint.get("travel_lease_hard_expires_at", 0.0))
	while not request.is_completed():
		if hard_expires_at > 0.0 and Time.get_unix_time_from_system() >= hard_expires_at - TRAVEL_LEASE_REDEEM_GRACE_SECONDS:
			NetLog.print_line("[CLIENT] WORLD_PACK_CANCELED key=%s reason=travel_lease_expiring" % world_key)
			request.cancel()
			break
		await get_tree().create_timer(0.25).timeout
	if not request.is_completed():
		await request.completed


func _force_packrat_world_packs() -> bool:
	return FORCE_PACKRAT_WORLD_PACKS_ARG in launch_args


func _use_bundled_world_scenes() -> bool:
	return USE_BUNDLED_WORLD_SCENES_ARG in launch_args


func _smoke_packrat_cache_dir() -> String:
	if not smoke_test:
		return ""
	for arg in launch_args:
		if arg.begins_with(SMOKE_PACKRAT_CACHE_DIR_PREFIX):
			return arg.substr(SMOKE_PACKRAT_CACHE_DIR_PREFIX.length()).strip_edges()
	return ""


func _use_editor_pack_exports() -> bool:
	return (
		OS.has_feature("editor")
		and not _force_packrat_world_packs()
	)


func _editor_pack_export_preset(world_key: String) -> String:
	return "%s%s" % [EDITOR_PACK_EXPORT_PRESET_PREFIX, world_key]


func _runtime_user_args() -> PackedStringArray:
	var args := OS.get_cmdline_user_args()
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return args

	var javascript: Object = Engine.get_singleton("JavaScriptBridge")
	if javascript == null:
		return args

	var value: Variant = javascript.call(
		"eval",
		"new URLSearchParams(window.location.search).get('args') || ''",
		true
	)
	if typeof(value) != TYPE_STRING:
		return args

	for item in String(value).split(",", false):
		var arg := item.strip_edges()
		if not arg.is_empty() and not args.has(arg):
			args.append(arg)
	return args


func _show_world_pack_progress(world_key: String, expected_size: int) -> void:
	_set_status("Downloading %s" % world_key)
	world_pack_last_logged_percent = -10
	world_pack_last_logged_msec = Time.get_ticks_msec()
	world_pack_progress.visible = true
	world_pack_progress.value = 0.0
	world_pack_progress.max_value = 100.0
	if expected_size > 0:
		world_pack_progress.max_value = expected_size


func _update_world_pack_progress(world_key: String, downloaded_bytes: int, total_bytes: int) -> void:
	if perf_monitor:
		perf_monitor.set_gauge("world_pack_downloaded_bytes", downloaded_bytes)
		perf_monitor.set_gauge("world_pack_total_bytes", total_bytes)
	last_world_pack_status = "downloading"
	last_world_pack_bytes = downloaded_bytes
	_update_network_stats_label()
	var total := total_bytes
	if total <= 0:
		total = int(world_pack_progress.max_value)
	if total > 0:
		world_pack_progress.max_value = total
		world_pack_progress.value = clamp(downloaded_bytes, 0, total)
		var percent := int(round(float(downloaded_bytes) * 100.0 / float(total)))
		status_label.text = "Downloading %s %d%%" % [world_key, percent]
		if percent >= world_pack_last_logged_percent + 10 or percent >= 100:
			world_pack_last_logged_percent = percent
			NetLog.print_line("[CLIENT] WORLD_PACK_PROGRESS key=%s percent=%d bytes=%d total=%d" % [world_key, percent, downloaded_bytes, total_bytes])
	else:
		world_pack_progress.value = 0.0
		status_label.text = "Downloading %s" % world_key
		var now := Time.get_ticks_msec()
		if now - world_pack_last_logged_msec >= 1000:
			world_pack_last_logged_msec = now
			NetLog.print_line("[CLIENT] WORLD_PACK_PROGRESS key=%s bytes=%d total=%d" % [world_key, downloaded_bytes, total_bytes])


func _hide_world_pack_progress() -> void:
	world_pack_progress.visible = false


func _request_world_join(world_key: String, route_endpoint: Dictionary) -> Dictionary:
	pending_join_endpoint = {}
	pending_join_world = world_key
	denied_join_world = ""
	denied_join_reason = ""
	var travel_lease_id := str(route_endpoint.get("travel_lease_id", ""))
	NetLog.print_line("[CLIENT] WORLD_JOIN_REQUEST key=%s lease=%s" % [world_key, travel_lease_id])
	var start_msec := Time.get_ticks_msec()
	if perf_monitor:
		perf_monitor.increment("world_join_requested")
	if travel_lease_id.is_empty():
		if bool(world_rejoin_requests.get(world_key, false)):
			master_endpoint.request_world_rejoin.rpc_id(1, world_key)
		else:
			master_endpoint.request_world_join.rpc_id(1, world_key)
	else:
		master_endpoint.redeem_travel_lease.rpc_id(1, travel_lease_id, world_key)

	var ok := await _wait_until(
		func() -> bool:
			return (
				str(pending_join_endpoint.get("key", "")) == world_key
				or denied_join_world == world_key
			),
		WORLD_JOIN_TICKET_TIMEOUT_SECONDS,
		"join ticket for %s" % world_key
	)
	pending_join_world = ""
	if not ok:
		_cancel_world_join(world_key, route_endpoint)
		if perf_monitor:
			perf_monitor.increment("world_join_failed")
		return {}
	if denied_join_world == world_key:
		if not denied_join_reason.is_empty():
			push_error("[CLIENT] join denied for %s: %s" % [world_key, denied_join_reason])
		if perf_monitor:
			perf_monitor.increment("world_join_failed")
		return {}

	var endpoint: Dictionary = pending_join_endpoint.duplicate(true)
	if not routes.has("worlds"):
		routes["worlds"] = {}
	var worlds: Dictionary = routes["worlds"]
	worlds[world_key] = endpoint
	routes["worlds"] = worlds
	if perf_monitor:
		perf_monitor.increment("world_join_approved")
		perf_monitor.observe_latency("world_join_ticket", Time.get_ticks_msec() - start_msec)
	return endpoint


func _has_world_route(world_key: String) -> bool:
	if not routes.has("worlds"):
		return false

	var worlds: Dictionary = routes["worlds"]
	return worlds.has(world_key)


## A route good enough to prepare assets and load the scene. Prefers a live route
## (carries url + join ticket), falls back to the master-provided world catalog,
## then to NetConfig. The live url + ticket are filled in later by the join RPC.
func _world_route_or_catalog(world_key: String) -> Dictionary:
	if _has_world_route(world_key):
		return routes["worlds"][world_key]
	if routes.has("world_catalog"):
		var catalog: Dictionary = routes["world_catalog"]
		if catalog.has(world_key):
			var endpoint: Dictionary = catalog[world_key].duplicate(true)
			endpoint["scene"] = NET_CONFIG.world_scene_path(world_key)
			return endpoint
	if NET_CONFIG.is_valid_world_key(world_key):
		return {"key": world_key, "scene": NET_CONFIG.world_scene_path(world_key)}
	return {}


func _remove_route_travel_lease(world_key: String, travel_lease_id: String) -> void:
	if travel_lease_id.is_empty() or not routes.has("worlds"):
		return
	var worlds: Dictionary = routes["worlds"]
	if not worlds.has(world_key):
		return
	var endpoint: Dictionary = worlds[world_key]
	if str(endpoint.get("travel_lease_id", "")) != travel_lease_id:
		return
	endpoint.erase("travel_lease_id")
	endpoint.erase("travel_lease_expires_at")
	endpoint.erase("travel_lease_hard_expires_at")
	worlds[world_key] = endpoint
	routes["worlds"] = worlds


func _known_world_keys() -> Array[String]:
	var keys: Array[String] = []
	if routes.has("world_catalog"):
		var world_catalog: Dictionary = routes["world_catalog"]
		for key in world_catalog.keys():
			keys.append(str(key))
	if keys.is_empty():
		keys = NET_CONFIG.world_keys()
	keys.sort()
	return keys


func _is_known_world_key(world_key: String) -> bool:
	if _known_world_keys().has(world_key):
		return true
	if _has_world_route(world_key):
		return true
	return NET_CONFIG.is_valid_world_key(world_key)


func _transfer_via_portal(target_world: String) -> bool:
	var start_msec := Time.get_ticks_msec()
	transfer_request_generation += 1
	pending_transfer = {}
	denied_transfer = ""
	requested_transfer_target = ""
	requested_transfer_portal = ""
	if current_world_scene and current_world_scene.has_method("activate_portal_to"):
		if current_world_scene.has_method("move_local_player_to_portal"):
			current_world_scene.move_local_player_to_portal(target_world)
			await get_tree().create_timer(_portal_test_replication_settle_seconds()).timeout
		current_world_scene.activate_portal_to(target_world)
	else:
		if perf_monitor:
			perf_monitor.increment("transfer_failed")
		return false
	if requested_transfer_target != target_world:
		requested_transfer_target = ""
		requested_transfer_portal = ""
		if perf_monitor:
			perf_monitor.increment("transfer_failed")
		return false

	if perf_monitor:
		perf_monitor.increment("transfer_requested")
	var ok := await _wait_until(
		func() -> bool:
			return (
				str(pending_transfer.get("target_world", "")) == target_world
				or denied_transfer == target_world
			),
		5.0,
		"transfer approval to %s" % target_world
	)
	if not ok or denied_transfer == target_world:
		requested_transfer_target = ""
		if perf_monitor:
			perf_monitor.increment("transfer_failed")
		return false

	var approved_world := str(pending_transfer["target_world"])
	var connected := await _connect_transfer_world(approved_world, pending_transfer.get("endpoint", {}))
	requested_transfer_target = ""
	requested_transfer_portal = ""
	if perf_monitor:
		if connected:
			perf_monitor.increment("transfer_succeeded")
			perf_monitor.observe_latency("transfer", Time.get_ticks_msec() - start_msec)
		else:
			perf_monitor.increment("transfer_failed")
	return connected


func _run_manual_portal_test() -> void:
	NetLog.print_line("MANUAL_PORTAL_TEST start")
	if not current_world_scene or not current_world_scene.has_method("activate_portal_to"):
		NetLog.print_line("MANUAL_PORTAL_TEST_FAIL no active portal scene")
		get_tree().quit(1)
		return

	if current_world_scene.has_method("move_local_player_to_portal"):
		current_world_scene.move_local_player_to_portal("left_world")
		await get_tree().create_timer(_portal_test_replication_settle_seconds()).timeout
	current_world_scene.activate_portal_to("left_world")
	var ok := await _wait_until(func() -> bool: return active_world_key == "left_world", 5.0, "manual portal transfer to left_world")
	if ok:
		NetLog.print_line("MANUAL_PORTAL_TEST_PASS")
		get_tree().quit(0)
	else:
		NetLog.print_line("MANUAL_PORTAL_TEST_FAIL did not reach left_world")
		get_tree().quit(1)


func _send_chat_ping(label: String) -> bool:
	if not chat_connected or not _is_master_connected():
		NetLog.print_line("[CLIENT] chat ping skipped; chat is not connected")
		return false

	var start_msec := Time.get_ticks_msec()
	var local_peer_id := master_api.get_unique_id()
	var message := "chat-ping-%s-client-%d-world-%s" % [label, local_peer_id, active_world_key]
	var receipt_key := "%d:%s" % [local_peer_id, message]
	chat_receipts.erase(receipt_key)
	chat_endpoint.send_chat.rpc_id(1, message)
	var ok := await _wait_until(func() -> bool: return chat_receipts.has(receipt_key), 5.0, "chat echo %s" % message)
	if perf_monitor:
		if ok:
			perf_monitor.increment("chat_echo_succeeded")
			perf_monitor.observe_latency("chat_echo", Time.get_ticks_msec() - start_msec)
		else:
			perf_monitor.increment("chat_echo_failed")
	return ok


func _on_chat_message_submitted(message: String) -> void:
	if not chat_connected or not _is_master_connected():
		_add_chat_system_line("chat unavailable")
		return

	chat_endpoint.send_chat.rpc_id(1, message)


func _set_chat_connected(connected: bool) -> void:
	if chat and chat.has_method("set_connected"):
		chat.set_connected(connected)


func _add_chat_system_line(message: String) -> void:
	if chat and chat.has_method("add_system_line"):
		chat.add_system_line(message)


func _connect_api(api: MultiplayerAPI, url: String, label: String, timeout_seconds := 5.0, report_error := true) -> bool:
	var start_msec := Time.get_ticks_msec()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		if report_error:
			push_error("[CLIENT] create_client failed for %s url=%s err=%s" % [label, url, err])
		if perf_monitor:
			perf_monitor.increment("%s_connect_failed" % _safe_metric_name(label))
		return false

	api.multiplayer_peer = peer
	NetLog.print_line("[CLIENT] connecting to %s at %s" % [label, url])
	var ok := await _wait_until(
		func() -> bool:
			return peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTING,
		timeout_seconds,
		"%s connection" % label,
		report_error
	)
	if not ok or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if report_error:
			push_error("[CLIENT] connection failed for %s" % label)
		if perf_monitor:
			perf_monitor.increment("%s_connect_failed" % _safe_metric_name(label))
		return false
	NetLog.print_line("[CLIENT] connected to %s" % label)
	if perf_monitor:
		var metric_name := _safe_metric_name(label)
		perf_monitor.increment("%s_connect_succeeded" % metric_name)
		perf_monitor.observe_latency("%s_connect" % metric_name, Time.get_ticks_msec() - start_msec)
		if label == "master":
			perf_monitor.set_gauge("master_connected", 1)
		elif label.begins_with("world-"):
			perf_monitor.set_gauge("world_connected", 1)
	return true


func _on_routes_rejected(reason: String, server_version: String, client_version: String) -> void:
	route_rejection_reason = reason
	if reason == "version_mismatch":
		_set_status("Game updated; reload required")
		_show_version_mismatch_prompt(server_version, client_version)
	else:
		_show_server_unavailable_prompt("Connection Rejected", "The game server rejected this connection: %s" % reason)


func _show_version_mismatch_prompt(server_version: String, client_version: String) -> void:
	NetLog.print_line("[CLIENT] PROJECT_VERSION_REJECTED client=%s server=%s" % [client_version, server_version])
	if smoke_test:
		return

	var show_reload := OS.has_feature("web") and _web_url_version() != server_version
	var action := ""
	if show_reload:
		action = "Reload to get the latest client before connecting."
	elif OS.has_feature("web"):
		action = "The game server and Web client are still updating. Try again shortly."
	else:
		action = "Restart the game client to get the latest version before connecting."
	var message := "This game was updated. %s\n\nClient: %s\nServer: %s" % [
		action,
		client_version,
		server_version,
	]
	_show_connection_prompt("Game Updated", message, show_reload, server_version)


func _show_server_unavailable_prompt(title: String, message: String) -> void:
	NetLog.print_line("[CLIENT] CONNECTION_PROMPT title=%s message=%s" % [title, message])
	if smoke_test:
		return
	_show_connection_prompt(title, message)


func _show_connection_prompt(title: String, message: String, show_reload := false, server_version := "") -> void:
	if connection_dialog:
		if connection_dialog.get_parent():
			connection_dialog.get_parent().remove_child(connection_dialog)
		connection_dialog.queue_free()

	connection_dialog = AcceptDialog.new()
	connection_dialog.name = "ConnectionPrompt"
	connection_dialog.title = title
	connection_dialog.dialog_text = message
	connection_dialog.exclusive = true
	canvas_layer.add_child(connection_dialog)
	if show_reload:
		connection_dialog.add_button("Reload", true, "reload")
		connection_dialog.custom_action.connect(func(action: StringName) -> void:
			if action == &"reload":
				_reload_web_client(server_version)
		)
	connection_dialog.popup_centered(Vector2i(440, 180))


func _reload_web_client(server_version: String) -> void:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return

	var javascript: Object = Engine.get_singleton("JavaScriptBridge")
	if javascript == null:
		return

	var version := server_version.uri_encode()
	# Web exports reload through the same static host with an explicit version
	# query so stale GitHub Pages/browser caches do not keep serving old files.
	var expression := "const u = new URL(window.location.href); u.searchParams.set('v', '%s'); window.location.replace(u.toString());" % version
	javascript.call("eval", expression, true)


func _web_url_version() -> String:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return ""

	var javascript: Object = Engine.get_singleton("JavaScriptBridge")
	if javascript == null:
		return ""

	var value: Variant = javascript.call("eval", "new URLSearchParams(window.location.search).get('v') || ''", true)
	return String(value) if typeof(value) == TYPE_STRING else ""


func _start_join_keepalive(world_key: String) -> void:
	join_keepalive_world = world_key
	if _is_master_connected():
		master_endpoint.refresh_world_join.rpc_id(1, world_key)
	if join_keepalive_active:
		return

	join_keepalive_active = true
	call_deferred("_run_join_keepalive", world_key)


func _stop_join_keepalive(world_key: String, completed: bool, travel_lease_id := "") -> void:
	if join_keepalive_world != world_key:
		return

	join_keepalive_active = false
	join_keepalive_world = ""
	if not completed:
		_cancel_world_join(world_key, {"travel_lease_id": travel_lease_id})


func _cancel_world_join(world_key: String, endpoint: Dictionary) -> void:
	if not _is_master_connected():
		return
	master_endpoint.release_world_join.rpc_id(1, world_key, str(endpoint.get("travel_lease_id", "")))


func _run_join_keepalive(world_key: String) -> void:
	while join_keepalive_active and join_keepalive_world == world_key:
		if not _is_master_connected():
			join_keepalive_active = false
			join_keepalive_world = ""
			return
		master_endpoint.refresh_world_join.rpc_id(1, world_key)
		await get_tree().create_timer(2.0).timeout


func _is_master_connected() -> bool:
	if not master_api:
		return false
	var peer := master_api.multiplayer_peer
	return peer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _is_world_connected() -> bool:
	if not world_api:
		return false
	var peer := world_api.multiplayer_peer
	return peer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _safe_metric_name(value: String) -> String:
	return value.replace("-", "_").replace(" ", "_").to_lower()


func _wait_until(predicate: Callable, timeout_seconds: float, label: String, report_error := true) -> bool:
	var elapsed := 0.0
	while elapsed < timeout_seconds:
		if predicate.call():
			return true
		await get_tree().create_timer(0.05).timeout
		elapsed += 0.05
	if report_error:
		push_error("[CLIENT] timeout waiting for %s" % label)
	return false


func _load_world_scene(world_key: String, endpoint: Dictionary) -> bool:
	# Detach synchronously (not just queue_free) so re-entering the SAME world
	# does not collide names with the still-pending old scene, which would make
	# Godot rename the new root and break MultiplayerSpawner path matching.
	for child in world_view.get_children():
		world_view.remove_child(child)
		child.queue_free()

	var scene_path := str(endpoint.get("scene", NET_CONFIG.world_scene_path(world_key)))
	var scene := load(scene_path) as PackedScene
	if scene == null:
		push_error("[CLIENT] failed to load world scene: %s" % scene_path)
		return false
	current_world_scene = scene.instantiate()
	current_world_scene.portal_requested.connect(_on_portal_requested)
	world_view.add_child(current_world_scene)
	_set_status("Loading %s" % world_key)
	return true


func _on_portal_requested(portal_name: String, target_world: String) -> void:
	if not _is_known_world_key(target_world):
		NetLog.print_line("[CLIENT] portal target %s is invalid; ignoring" % target_world)
		return
	if not requested_transfer_target.is_empty():
		NetLog.print_line("[CLIENT] transfer already pending to %s; ignoring %s" % [requested_transfer_target, target_world])
		return
	if transfer_in_progress:
		NetLog.print_line("[CLIENT] transfer already in progress; ignoring %s" % target_world)
		return

	requested_transfer_target = target_world
	requested_transfer_portal = portal_name
	transfer_request_generation += 1
	var request_generation := transfer_request_generation
	NetLog.print_line("[CLIENT] requesting transfer from %s to %s via %s" % [active_world_key, target_world, portal_name])
	world_endpoint.request_portal_use.rpc_id(1, portal_name)
	call_deferred("_clear_stale_transfer_request", portal_name, target_world, request_generation)


func _start_travel_lease_keepalive(endpoint: Dictionary) -> void:
	var travel_lease_id := str(endpoint.get("travel_lease_id", ""))
	if travel_lease_id.is_empty():
		return
	travel_lease_keepalive_generation += 1
	travel_lease_keepalive_id = travel_lease_id
	travel_lease_keepalive_active = true
	if _is_master_connected():
		master_endpoint.refresh_travel_lease.rpc_id(1, travel_lease_id)
	call_deferred("_run_travel_lease_keepalive", travel_lease_id, travel_lease_keepalive_generation)


func _stop_travel_lease_keepalive(travel_lease_id: String) -> void:
	if travel_lease_keepalive_id != travel_lease_id:
		return
	travel_lease_keepalive_generation += 1
	travel_lease_keepalive_active = false
	travel_lease_keepalive_id = ""


func _release_travel_lease(endpoint: Dictionary) -> void:
	var travel_lease_id := str(endpoint.get("travel_lease_id", ""))
	_stop_travel_lease_keepalive(travel_lease_id)
	if not travel_lease_id.is_empty() and _is_master_connected():
		master_endpoint.release_travel_lease.rpc_id(1, travel_lease_id)


func _run_travel_lease_keepalive(travel_lease_id: String, generation: int) -> void:
	while (
		travel_lease_keepalive_active
		and travel_lease_keepalive_id == travel_lease_id
		and travel_lease_keepalive_generation == generation
	):
		if not _is_master_connected():
			travel_lease_keepalive_active = false
			travel_lease_keepalive_id = ""
			return
		master_endpoint.refresh_travel_lease.rpc_id(1, travel_lease_id)
		await get_tree().create_timer(TRAVEL_LEASE_REFRESH_INTERVAL_SECONDS).timeout


func _on_travel_lease_granted(target_world: String, endpoint: Dictionary) -> void:
	if requested_transfer_target != target_world:
		NetLog.print_line("[CLIENT] ignoring stale travel lease to %s" % target_world)
		return

	if not routes.has("worlds"):
		routes["worlds"] = {}
	var worlds: Dictionary = routes["worlds"]
	worlds[target_world] = endpoint
	routes["worlds"] = worlds
	pending_transfer = {"target_world": target_world, "endpoint": endpoint}
	if not smoke_test:
		call_deferred("_complete_manual_transfer", target_world)


func _on_world_join_approved(world_key: String, endpoint: Dictionary) -> void:
	if pending_join_world != world_key:
		NetLog.print_line("[CLIENT] ignoring stale join approval for %s" % world_key)
		return

	pending_join_endpoint = endpoint


func _on_world_join_denied(world_key: String, reason: String) -> void:
	if pending_join_world != world_key:
		NetLog.print_line("[CLIENT] ignoring stale join denial for %s" % world_key)
		return

	denied_join_world = world_key
	denied_join_reason = reason


func _on_transfer_denied(target_world: String) -> void:
	if requested_transfer_target != target_world:
		NetLog.print_line("[CLIENT] ignoring stale transfer denial to %s" % target_world)
		return

	denied_transfer = target_world
	requested_transfer_target = ""
	requested_transfer_portal = ""


func _complete_manual_transfer(target_world: String) -> void:
	if pending_transfer.is_empty() or str(pending_transfer.get("target_world", "")) != target_world:
		return

	_set_status("Transferring to %s" % target_world)
	var ok := await _connect_transfer_world(target_world, pending_transfer.get("endpoint", {}))
	if ok:
		NetLog.print_line("[CLIENT] manual transfer complete: %s" % active_world_key)
	else:
		push_error("[CLIENT] manual transfer failed to %s" % target_world)
	requested_transfer_target = ""
	requested_transfer_portal = ""


func _clear_stale_transfer_request(portal_name: String, target_world: String, request_generation: int) -> void:
	await get_tree().create_timer(5.0).timeout
	if transfer_request_generation != request_generation:
		return
	if requested_transfer_portal != portal_name:
		return
	if requested_transfer_target != target_world:
		return
	if transfer_in_progress or str(pending_transfer.get("target_world", "")) == requested_transfer_target:
		return

	NetLog.print_line("[CLIENT] transfer request timed out: %s" % portal_name)
	denied_transfer = requested_transfer_target
	requested_transfer_portal = ""
	requested_transfer_target = ""


func _connect_transfer_world(target_world: String, endpoint := {}) -> bool:
	if transfer_in_progress:
		NetLog.print_line("[CLIENT] transfer connection already in progress; ignoring %s" % target_world)
		return false

	transfer_in_progress = true
	var ok := await _connect_world(target_world, endpoint)
	transfer_in_progress = false
	return ok


func _portal_test_replication_settle_seconds() -> float:
	return WEB_PORTAL_TEST_REPLICATION_SETTLE_SECONDS if OS.has_feature("web") else PORTAL_TEST_REPLICATION_SETTLE_SECONDS


func _set_status(text: String) -> void:
	status_label.text = text
	NetLog.print_line("[CLIENT] status: %s" % text)


func _project_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.1"))


func _display_version() -> String:
	return "v%s" % _project_version()


func _smoke_fail(reason: String) -> void:
	NetLog.print_line("SMOKE_FAIL %s" % reason)
	get_tree().quit(1)
