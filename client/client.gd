extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const CHAT_SCENE := preload("res://client/chat/chat.tscn")
const LOGIN_PANEL_SCENE := preload("res://client/login/login_panel.tscn")
const SMOKE_TEST_ARG := "smoke_test"
const MANUAL_PORTAL_TEST_ARG := "manual_portal_test"

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

@onready var master_endpoint: Node = $MasterNet/MasterEndpoint
@onready var chat_endpoint: Node = $MasterNet/ChatEndpoint
@onready var account_endpoint: Node = $MasterNet/AccountEndpoint
@onready var world_endpoint: Node = $WorldNet/WorldEndpoint
@onready var world_view: Node2D = $WorldNet/WorldSceneRoot
@onready var canvas_layer: CanvasLayer = $CanvasLayer
@onready var status_label: Label = $CanvasLayer/StatusLabel


func _ready() -> void:
	_setup_chat()
	_setup_login_panel()
	_setup_multiplayer_branches()
	smoke_test = SMOKE_TEST_ARG in OS.get_cmdline_user_args()
	master_endpoint.routes_received.connect(func(new_routes: Dictionary) -> void:
		routes = new_routes
	)
	master_endpoint.transfer_approved.connect(_on_transfer_approved)
	master_endpoint.transfer_denied.connect(_on_transfer_denied)
	master_endpoint.world_join_approved.connect(_on_world_join_approved)
	master_endpoint.world_join_denied.connect(_on_world_join_denied)
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
			print("[CLIENT] ignoring unexpected world state %s while connecting to %s" % [world_key, connecting_world_key])
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

	if smoke_test:
		run_smoke_test()
	else:
		run_manual_client()


func _setup_multiplayer_branches() -> void:
	master_api = MultiplayerAPI.create_default_interface()
	world_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(master_api, get_node("MasterNet").get_path())
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	master_api.server_disconnected.connect(func() -> void:
		print("[CLIENT] master server disconnected")
		chat_connected = false
		join_keepalive_active = false
		join_keepalive_world = ""
		_set_chat_connected(false)
		_add_chat_system_line("master disconnected")
	)
	world_api.server_disconnected.connect(func() -> void:
		print("[CLIENT] world server disconnected")
	)


func _setup_chat() -> void:
	chat = CHAT_SCENE.instantiate()
	chat.message_submitted.connect(_on_chat_message_submitted)
	canvas_layer.add_child(chat)
	_add_chat_system_line("chat starting")


func _setup_login_panel() -> void:
	# The smoke client runs headless and never logs in; skip the widget there.
	if SMOKE_TEST_ARG in OS.get_cmdline_user_args():
		return
	login_panel = LOGIN_PANEL_SCENE.instantiate()
	login_panel.login_submitted.connect(_on_login_submitted)
	login_panel.logout_requested.connect(_on_logout_requested)
	canvas_layer.add_child(login_panel)


func _on_login_submitted(username: String) -> void:
	if _is_master_connected():
		account_endpoint.login.rpc_id(1, username)


func _on_logout_requested() -> void:
	if _is_master_connected():
		account_endpoint.logout.rpc_id(1)


func _on_session_updated(display_name: String, is_guest: bool, _account_id: int) -> void:
	if login_panel and login_panel.has_method("set_identity"):
		login_panel.set_identity(display_name, is_guest)


func _on_login_failed(reason: String) -> void:
	if login_panel and login_panel.has_method("show_error"):
		login_panel.show_error(reason)


func _on_resume_world_requested(world_key: String) -> void:
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
		print("[CLIENT] resumed into world %s" % active_world_key)
	else:
		push_error("[CLIENT] failed to resume into world %s" % world_key)


func run_manual_client() -> void:
	if await _bootstrap_connections(false):
		print("[CLIENT] manual client ready")
		if MANUAL_PORTAL_TEST_ARG in OS.get_cmdline_user_args():
			await _run_manual_portal_test()


func run_smoke_test() -> void:
	print("SMOKE_STEP client starts")
	var ok := await _bootstrap_connections(true)
	if not ok:
		_smoke_fail("bootstrap failed")
		return

	var sequence := _smoke_transfer_sequence()
	for i in range(sequence.size()):
		var target_world := str(sequence[i])
		print("SMOKE_STEP transfer %s_to_%s" % [active_world_key, target_world])
		ok = await _transfer_via_portal(target_world)
		if not ok:
			_smoke_fail("transfer to %s failed" % target_world)
			return
		ok = await _send_chat_ping("after-transfer-%d-world-%s" % [i + 1, active_world_key])
		if not ok:
			_smoke_fail("chat ping failed after %s" % active_world_key)
			return
		print("SMOKE_STEP confirmed world %s with chat alive" % active_world_key)

	await get_tree().create_timer(1.0).timeout
	print("SMOKE_PASS")
	get_tree().quit(0)


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
	var ok := await _connect_api(master_api, NET_CONFIG.master_url(), "master")
	if not ok:
		return false
	master_endpoint.request_routes.rpc_id(1)
	var route_predicate := func() -> bool:
		return _has_initial_world_route()
	ok = await _wait_until(route_predicate, 5.0, "master routes")
	if not ok:
		return false
	print("SMOKE_STEP client connected to master" if require_all_worlds else "[CLIENT] connected to master")

	chat_connected = true
	_set_chat_connected(true)
	_add_chat_system_line("chat connected")
	if require_all_worlds:
		print("SMOKE_STEP client chat ready")
		ok = await _send_chat_ping("initial")
		if not ok:
			return false

	var initial_world := str(routes["initial_world"])
	ok = await _connect_world(initial_world)
	if not ok:
		return false
	print("SMOKE_STEP client confirmed initial world %s" % active_world_key if require_all_worlds else "[CLIENT] manual initial world ready: %s" % active_world_key)
	return true


func _has_initial_world_route() -> bool:
	if routes.is_empty() or not routes.has("worlds") or not routes.has("initial_world"):
		return false

	var worlds: Dictionary = routes["worlds"]
	return worlds.has(routes["initial_world"])


func _connect_world(world_key: String) -> bool:
	var route_endpoint: Dictionary = _world_route_or_catalog(world_key)
	if route_endpoint.is_empty():
		push_error("[CLIENT] no registered route for world %s" % world_key)
		return false

	var assets_ready: bool = await _prepare_world_assets(world_key, route_endpoint)
	if not assets_ready:
		push_error("[CLIENT] assets unavailable for world %s" % world_key)
		return false

	world_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	active_world_key = ""
	connecting_world_key = world_key
	rejected_world_join = ""
	if not _load_world_scene(world_key, route_endpoint):
		connecting_world_key = ""
		return false

	var endpoint := await _request_world_join(world_key)
	if endpoint.is_empty():
		connecting_world_key = ""
		return false

	_start_join_keepalive(world_key)
	var ok := await _connect_api(world_api, endpoint["url"], "world-%s" % world_key)
	if not ok:
		connecting_world_key = ""
		_stop_join_keepalive(world_key, false)
		return false
	world_endpoint.request_world_state.rpc_id(1, str(endpoint.get("join_ticket", "")))
	ok = await _wait_until(
		func() -> bool:
			return active_world_key == world_key or rejected_world_join == world_key,
		5.0,
		"world %s state" % world_key
	)
	connecting_world_key = ""
	_stop_join_keepalive(world_key, ok)
	return ok and rejected_world_join != world_key


func _prepare_world_assets(world_key: String, endpoint: Dictionary) -> bool:
	var scene_path := str(endpoint.get("scene", NET_CONFIG.world_scene_path(world_key)))
	if ResourceLoader.exists(scene_path, "PackedScene"):
		return true

	push_error("[CLIENT] world scene is not available yet: %s" % scene_path)
	return false


func _request_world_join(world_key: String) -> Dictionary:
	pending_join_endpoint = {}
	pending_join_world = world_key
	denied_join_world = ""
	denied_join_reason = ""
	master_endpoint.request_world_join.rpc_id(1, world_key)

	var ok := await _wait_until(
		func() -> bool:
			return (
				str(pending_join_endpoint.get("key", "")) == world_key
				or denied_join_world == world_key
			),
		5.0,
		"join ticket for %s" % world_key
	)
	pending_join_world = ""
	if not ok or denied_join_world == world_key:
		if not denied_join_reason.is_empty():
			push_error("[CLIENT] join denied for %s: %s" % [world_key, denied_join_reason])
		return {}

	var endpoint: Dictionary = pending_join_endpoint.duplicate(true)
	if not routes.has("worlds"):
		routes["worlds"] = {}
	var worlds: Dictionary = routes["worlds"]
	worlds[world_key] = endpoint
	routes["worlds"] = worlds
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
	pending_transfer = {}
	denied_transfer = ""
	requested_transfer_target = ""
	requested_transfer_portal = ""
	if current_world_scene and current_world_scene.has_method("activate_portal_to"):
		if current_world_scene.has_method("move_local_player_to_portal"):
			current_world_scene.move_local_player_to_portal(target_world)
			await get_tree().create_timer(0.5).timeout
		current_world_scene.activate_portal_to(target_world)
	else:
		return false
	if requested_transfer_target != target_world:
		requested_transfer_target = ""
		requested_transfer_portal = ""
		return false

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
		return false

	var approved_world := str(pending_transfer["target_world"])
	var connected := await _connect_transfer_world(approved_world)
	requested_transfer_target = ""
	requested_transfer_portal = ""
	return connected


func _run_manual_portal_test() -> void:
	print("MANUAL_PORTAL_TEST start")
	if not current_world_scene or not current_world_scene.has_method("activate_portal_to"):
		print("MANUAL_PORTAL_TEST_FAIL no active portal scene")
		get_tree().quit(1)
		return

	if current_world_scene.has_method("move_local_player_to_portal"):
		current_world_scene.move_local_player_to_portal("left_world")
		await get_tree().create_timer(0.5).timeout
	current_world_scene.activate_portal_to("left_world")
	var ok := await _wait_until(func() -> bool: return active_world_key == "left_world", 5.0, "manual portal transfer to left_world")
	if ok:
		print("MANUAL_PORTAL_TEST_PASS")
		get_tree().quit(0)
	else:
		print("MANUAL_PORTAL_TEST_FAIL did not reach left_world")
		get_tree().quit(1)


func _send_chat_ping(label: String) -> bool:
	if not chat_connected or not _is_master_connected():
		print("[CLIENT] chat ping skipped; chat is not connected")
		return false

	var local_peer_id := master_api.get_unique_id()
	var message := "chat-ping-%s-client-%d-world-%s" % [label, local_peer_id, active_world_key]
	var receipt_key := "%d:%s" % [local_peer_id, message]
	chat_receipts.erase(receipt_key)
	chat_endpoint.send_chat.rpc_id(1, message)
	return await _wait_until(func() -> bool: return chat_receipts.has(receipt_key), 5.0, "chat echo %s" % message)


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
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		if report_error:
			push_error("[CLIENT] create_client failed for %s url=%s err=%s" % [label, url, err])
		return false

	api.multiplayer_peer = peer
	print("[CLIENT] connecting to %s at %s" % [label, url])
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
		return false
	print("[CLIENT] connected to %s" % label)
	return true


func _start_join_keepalive(world_key: String) -> void:
	join_keepalive_world = world_key
	if _is_master_connected():
		master_endpoint.refresh_world_join.rpc_id(1, world_key)
	if join_keepalive_active:
		return

	join_keepalive_active = true
	call_deferred("_run_join_keepalive", world_key)


func _stop_join_keepalive(world_key: String, _completed: bool) -> void:
	if join_keepalive_world != world_key:
		return

	join_keepalive_active = false
	join_keepalive_world = ""
	if _is_master_connected():
		master_endpoint.release_world_join.rpc_id(1, world_key)


func _run_join_keepalive(world_key: String) -> void:
	while join_keepalive_active and join_keepalive_world == world_key:
		if not _is_master_connected():
			join_keepalive_active = false
			join_keepalive_world = ""
			return
		master_endpoint.refresh_world_join.rpc_id(1, world_key)
		await get_tree().create_timer(2.0).timeout


func _is_master_connected() -> bool:
	var peer := master_api.multiplayer_peer
	return peer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


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
	for child in world_view.get_children():
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
		print("[CLIENT] portal target %s is invalid; ignoring" % target_world)
		return
	if not requested_transfer_target.is_empty():
		print("[CLIENT] transfer already pending to %s; ignoring %s" % [requested_transfer_target, target_world])
		return
	if transfer_in_progress:
		print("[CLIENT] transfer already in progress; ignoring %s" % target_world)
		return

	requested_transfer_target = target_world
	requested_transfer_portal = portal_name
	print("[CLIENT] requesting transfer from %s to %s via %s" % [active_world_key, target_world, portal_name])
	world_endpoint.request_portal_use.rpc_id(1, portal_name)
	call_deferred("_clear_stale_transfer_request", portal_name)


func _on_transfer_approved(target_world: String, endpoint: Dictionary) -> void:
	if requested_transfer_target != target_world:
		print("[CLIENT] ignoring stale transfer approval to %s" % target_world)
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
		print("[CLIENT] ignoring stale join approval for %s" % world_key)
		return

	pending_join_endpoint = endpoint


func _on_world_join_denied(world_key: String, reason: String) -> void:
	if pending_join_world != world_key:
		print("[CLIENT] ignoring stale join denial for %s" % world_key)
		return

	denied_join_world = world_key
	denied_join_reason = reason


func _on_transfer_denied(target_world: String) -> void:
	if requested_transfer_target != target_world:
		print("[CLIENT] ignoring stale transfer denial to %s" % target_world)
		return

	denied_transfer = target_world
	requested_transfer_target = ""
	requested_transfer_portal = ""


func _complete_manual_transfer(target_world: String) -> void:
	if pending_transfer.is_empty() or str(pending_transfer.get("target_world", "")) != target_world:
		return

	_set_status("Transferring to %s" % target_world)
	var ok := await _connect_transfer_world(target_world)
	if ok:
		print("[CLIENT] manual transfer complete: %s" % active_world_key)
	else:
		push_error("[CLIENT] manual transfer failed to %s" % target_world)
	requested_transfer_target = ""
	requested_transfer_portal = ""


func _clear_stale_transfer_request(portal_name: String) -> void:
	await get_tree().create_timer(5.0).timeout
	if requested_transfer_portal != portal_name:
		return
	if transfer_in_progress or str(pending_transfer.get("target_world", "")) == requested_transfer_target:
		return

	print("[CLIENT] transfer request timed out: %s" % portal_name)
	denied_transfer = requested_transfer_target
	requested_transfer_portal = ""
	requested_transfer_target = ""


func _connect_transfer_world(target_world: String) -> bool:
	if transfer_in_progress:
		print("[CLIENT] transfer connection already in progress; ignoring %s" % target_world)
		return false

	transfer_in_progress = true
	var ok := await _connect_world(target_world)
	transfer_in_progress = false
	return ok


func _set_status(text: String) -> void:
	status_label.text = text
	print("[CLIENT] status: %s" % text)


func _smoke_fail(reason: String) -> void:
	print("SMOKE_FAIL %s" % reason)
	get_tree().quit(1)
