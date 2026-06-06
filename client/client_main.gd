extends Node

const CLI_ARGS := preload("res://shared/cli_args.gd")
const NET_CONFIG := preload("res://shared/net_config.gd")

var master_api: MultiplayerAPI
var chat_api: MultiplayerAPI
var world_api: MultiplayerAPI

var routes := {}
var chat_echoes: Array[String] = []
var active_world_id := 0
var current_world_scene: Node
var pending_transfer := {}
var denied_transfer := -1
var smoke_test := false
var chat_connected := false

@onready var master_endpoint: Node = $MasterNet/MasterEndpoint
@onready var chat_endpoint: Node = $ChatNet/ChatEndpoint
@onready var world_endpoint: Node = $WorldNet/WorldEndpoint
@onready var world_view: Node2D = $WorldNet/WorldSceneRoot
@onready var status_label: Label = $CanvasLayer/StatusLabel

func _ready() -> void:
	_setup_multiplayer_branches()
	smoke_test = CLI_ARGS.has_flag(OS.get_cmdline_user_args(), "smoke-test")
	master_endpoint.routes_received.connect(func(new_routes: Dictionary) -> void:
		routes = new_routes
	)
	chat_endpoint.chat_received.connect(func(message: String) -> void:
		chat_echoes.append(message)
	)
	world_endpoint.world_state_received.connect(func(world_id: int, _allowed_targets: Array) -> void:
		active_world_id = world_id
		_set_status("In World %d; chat echoes=%d" % [active_world_id, chat_echoes.size()])
	)
	world_endpoint.transfer_approved.connect(_on_transfer_approved)
	world_endpoint.transfer_denied.connect(_on_transfer_denied)

	if smoke_test:
		run_smoke_test()
	else:
		run_manual_client()


func _setup_multiplayer_branches() -> void:
	master_api = MultiplayerAPI.create_default_interface()
	chat_api = MultiplayerAPI.create_default_interface()
	world_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(master_api, get_node("MasterNet").get_path())
	get_tree().set_multiplayer(chat_api, get_node("ChatNet").get_path())
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	chat_api.server_disconnected.connect(func() -> void:
		print("[CLIENT] chat server disconnected")
	)
	world_api.server_disconnected.connect(func() -> void:
		print("[CLIENT] world server disconnected")
	)


func run_manual_client() -> void:
	if await _bootstrap_manual_connections():
		print("[CLIENT] manual client ready")
		if CLI_ARGS.has_flag(OS.get_cmdline_user_args(), "manual-portal-test"):
			await _run_manual_portal_test()


func run_smoke_test() -> void:
	print("SMOKE_STEP client starts")
	var ok := await _bootstrap_smoke_connections()
	if not ok:
		_smoke_fail("bootstrap failed")
		return

	var sequence := [2, 1, 3, 1]
	for i in range(sequence.size()):
		var target_world: int = sequence[i]
		print("SMOKE_STEP transfer %d_to_%d" % [active_world_id, target_world])
		ok = await _transfer_via_portal(target_world)
		if not ok:
			_smoke_fail("transfer to world %d failed" % target_world)
			return
		ok = await _send_chat_ping("after-transfer-%d-world-%d" % [i + 1, active_world_id])
		if not ok:
			_smoke_fail("chat ping failed after world %d" % active_world_id)
			return
		print("SMOKE_STEP confirmed world %d with chat alive" % active_world_id)

	print("SMOKE_PASS")
	get_tree().quit(0)


func _bootstrap_smoke_connections() -> bool:
	var ok := await _connect_api(master_api, NET_CONFIG.master_url(), "master")
	if not ok:
		return false
	master_endpoint.request_routes.rpc_id(1)
	ok = await _wait_until(func() -> bool: return _has_all_world_routes(), 5.0, "master routes")
	if not ok:
		return false
	print("SMOKE_STEP client connected to master")
	master_api.multiplayer_peer = OfflineMultiplayerPeer.new()

	ok = await _connect_api(chat_api, routes["chat"]["url"], "chat")
	if not ok:
		return false
	chat_connected = true
	print("SMOKE_STEP client connected to chat")
	ok = await _send_chat_ping("initial")
	if not ok:
		return false

	var initial_world: int = routes["initial_world"]
	ok = await _connect_world(initial_world)
	if not ok:
		return false
	print("SMOKE_STEP client confirmed initial world %d" % active_world_id)
	return true


func _bootstrap_manual_connections() -> bool:
	var ok := await _connect_api(master_api, NET_CONFIG.master_url(), "master")
	if not ok:
		return false
	master_endpoint.request_routes.rpc_id(1)
	ok = await _wait_until(func() -> bool: return _has_initial_world_route(), 5.0, "initial world route")
	if not ok:
		return false
	print("[CLIENT] received manual routes; registered worlds=%s" % str(_available_world_ids()))
	master_api.multiplayer_peer = OfflineMultiplayerPeer.new()

	if routes.has("chat"):
		chat_connected = await _connect_api(chat_api, routes["chat"]["url"], "chat", 1.0, false)
		if chat_connected:
			print("[CLIENT] optional chat connected")
		else:
			print("[CLIENT] optional chat unavailable; continuing without chat")

	var initial_world: int = routes["initial_world"]
	ok = await _connect_world(initial_world)
	if not ok:
		return false
	print("[CLIENT] manual initial world ready: %d" % active_world_id)
	return true


func _has_initial_world_route() -> bool:
	if routes.is_empty() or not routes.has("worlds") or not routes.has("initial_world"):
		return false

	var worlds: Dictionary = routes["worlds"]
	return worlds.has(routes["initial_world"])


func _has_all_world_routes() -> bool:
	if routes.is_empty() or not routes.has("worlds"):
		return false

	var worlds: Dictionary = routes["worlds"]
	return worlds.has(1) and worlds.has(2) and worlds.has(3)


func _available_world_ids() -> Array[int]:
	var ids: Array[int] = []
	if routes.has("worlds"):
		var worlds: Dictionary = routes["worlds"]
		for id in worlds.keys():
			ids.append(int(id))
	ids.sort()
	return ids


func _connect_world(world_id: int) -> bool:
	if not _has_world_route(world_id):
		push_error("[CLIENT] no registered route for world %d" % world_id)
		return false

	world_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	active_world_id = 0
	_load_world_scene(world_id)
	var endpoint: Dictionary = routes["worlds"][world_id]
	var ok := await _connect_api(world_api, endpoint["url"], "world-%d" % world_id)
	if not ok:
		return false
	world_endpoint.request_world_state.rpc_id(1)
	return await _wait_until(func() -> bool: return active_world_id == world_id, 5.0, "world %d state" % world_id)


func _has_world_route(world_id: int) -> bool:
	if not routes.has("worlds"):
		return false

	var worlds: Dictionary = routes["worlds"]
	return worlds.has(world_id)


func _transfer_via_portal(target_world: int) -> bool:
	pending_transfer = {}
	denied_transfer = -1
	if current_world_scene and current_world_scene.has_method("activate_portal_to"):
		current_world_scene.activate_portal_to(target_world)
	else:
		return false

	var ok := await _wait_until(
		func() -> bool: return not pending_transfer.is_empty() or denied_transfer == target_world,
		5.0,
		"transfer approval to world %d" % target_world
	)
	if not ok or denied_transfer == target_world:
		return false

	var approved_world: int = pending_transfer["target_world"]
	return await _connect_world(approved_world)


func _run_manual_portal_test() -> void:
	print("MANUAL_PORTAL_TEST start")
	if not current_world_scene or not current_world_scene.has_method("activate_portal_to"):
		print("MANUAL_PORTAL_TEST_FAIL no active portal scene")
		get_tree().quit(1)
		return

	current_world_scene.activate_portal_to(2)
	var ok := await _wait_until(func() -> bool: return active_world_id == 2, 5.0, "manual portal transfer to world 2")
	if ok:
		print("MANUAL_PORTAL_TEST_PASS")
		get_tree().quit(0)
	else:
		print("MANUAL_PORTAL_TEST_FAIL did not reach world 2")
		get_tree().quit(1)


func _send_chat_ping(label: String) -> bool:
	if not chat_connected:
		print("[CLIENT] chat ping skipped; chat is not connected")
		return false

	var message := "chat-ping-%s-world-%d" % [label, active_world_id]
	chat_endpoint.send_chat.rpc_id(1, message)
	return await _wait_until(func() -> bool: return message in chat_echoes, 5.0, "chat echo %s" % message)


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


func _load_world_scene(world_id: int) -> void:
	for child in world_view.get_children():
		child.queue_free()

	var scene := load(NET_CONFIG.world_scene_path(world_id)) as PackedScene
	current_world_scene = scene.instantiate()
	if current_world_scene.has_method("set_available_world_ids"):
		current_world_scene.set_available_world_ids(_available_world_ids())
	current_world_scene.portal_requested.connect(_on_portal_requested)
	world_view.add_child(current_world_scene)
	_set_status("Loading World %d" % world_id)


func _on_portal_requested(target_world: int) -> void:
	if not _has_world_route(target_world):
		print("[CLIENT] portal target world %d is not registered; ignoring" % target_world)
		return

	print("[CLIENT] requesting transfer from world %d to world %d" % [active_world_id, target_world])
	world_endpoint.request_transfer.rpc_id(1, target_world)


func _on_transfer_approved(target_world: int, endpoint: Dictionary) -> void:
	pending_transfer = {"target_world": target_world, "endpoint": endpoint}
	if not smoke_test:
		call_deferred("_complete_manual_transfer", target_world)


func _on_transfer_denied(target_world: int) -> void:
	denied_transfer = target_world


func _complete_manual_transfer(target_world: int) -> void:
	if pending_transfer.is_empty() or int(pending_transfer.get("target_world", -1)) != target_world:
		return

	_set_status("Transferring to World %d" % target_world)
	var ok := await _connect_world(target_world)
	if ok:
		print("[CLIENT] manual transfer complete: world %d" % active_world_id)
	else:
		push_error("[CLIENT] manual transfer failed to world %d" % target_world)


func _set_status(text: String) -> void:
	status_label.text = text
	print("[CLIENT] status: %s" % text)


func _smoke_fail(reason: String) -> void:
	print("SMOKE_FAIL %s" % reason)
	get_tree().quit(1)
