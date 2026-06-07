extends Node

const CLI_ARGS := preload("res://shared/cli_args.gd")
const NET_CONFIG := preload("res://shared/net_config.gd")
const CHAT_PANEL_SCENE := preload("res://client/chat/ChatPanel.tscn")

var world_api: MultiplayerAPI
var nakama_client
var nakama_session
var nakama_socket
var chat_channel

var chat_echoes: Array[String] = []
var active_world_id := 0
var current_world_scene: Node
var current_ticket := ""
var pending_transfer := {}
var denied_transfer := -1
var smoke_test := false
var chat_connected := false
var chat_panel: Node

@onready var world_endpoint: Node = $WorldNet/WorldEndpoint
@onready var world_view: Node2D = $WorldNet/WorldSceneRoot
@onready var canvas_layer: CanvasLayer = $CanvasLayer
@onready var status_label: Label = $CanvasLayer/StatusLabel

func _ready() -> void:
	_setup_chat_panel()
	_setup_multiplayer_branch()
	smoke_test = CLI_ARGS.has_flag(OS.get_cmdline_user_args(), "smoke-test")
	world_endpoint.world_state_received.connect(func(world_id: int, _allowed_targets: Array) -> void:
		active_world_id = world_id
		_set_status("In World %d; Nakama chat echoes=%d" % [active_world_id, chat_echoes.size()])
	)
	world_endpoint.transfer_approved.connect(_on_transfer_approved)
	world_endpoint.transfer_denied.connect(_on_transfer_denied)

	if smoke_test:
		run_smoke_test()
	else:
		run_manual_client()


func _setup_multiplayer_branch() -> void:
	world_api = MultiplayerAPI.create_default_interface()
	get_tree().set_multiplayer(world_api, get_node("WorldNet").get_path())
	world_api.server_disconnected.connect(func() -> void:
		print("[CLIENT] world server disconnected")
	)


func _setup_chat_panel() -> void:
	chat_panel = CHAT_PANEL_SCENE.instantiate()
	chat_panel.message_submitted.connect(_on_chat_message_submitted)
	canvas_layer.add_child(chat_panel)
	_add_chat_system_line("Nakama starting")


func run_manual_client() -> void:
	if await _bootstrap_nakama_client():
		print("[CLIENT] Nakama MVP client ready")
		if CLI_ARGS.has_flag(OS.get_cmdline_user_args(), "manual-portal-test"):
			await _run_manual_portal_test()


func run_smoke_test() -> void:
	print("SMOKE_STEP client starts")
	var ok := await _bootstrap_nakama_client()
	if not ok:
		_smoke_fail("bootstrap failed")
		return

	ok = await _send_chat_ping("initial")
	if not ok:
		_smoke_fail("initial Nakama chat ping failed")
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
		print("SMOKE_STEP confirmed world %d with Nakama chat alive" % active_world_id)

	print("SMOKE_PASS")
	get_tree().quit(0)


func _bootstrap_nakama_client() -> bool:
	var args := OS.get_cmdline_user_args()
	var host := CLI_ARGS.get_value(args, "nakama-host", "127.0.0.1")
	var port := int(CLI_ARGS.get_value(args, "nakama-port", "7350"))
	var server_key := CLI_ARGS.get_value(args, "nakama-server-key", "defaultkey")
	var device_id := CLI_ARGS.get_value(args, "device-id", _default_device_id())

	nakama_client = Nakama.create_client(server_key, host, port, "http")
	_set_status("Authenticating guest with Nakama")
	nakama_session = await nakama_client.authenticate_device_async(device_id, "guest", true, {"guest": "true"})
	if nakama_session.is_exception():
		push_error("[CLIENT] Nakama auth failed: %s" % nakama_session.get_exception()._to_string())
		return false
	print("[CLIENT] Nakama guest auth user_id=%s" % nakama_session.user_id)

	nakama_socket = Nakama.create_socket_from(nakama_client)
	nakama_socket.received_channel_message.connect(_on_nakama_channel_message)
	var connected = await nakama_socket.connect_async(nakama_session, true)
	if connected.is_exception():
		push_error("[CLIENT] Nakama socket failed: %s" % connected.get_exception()._to_string())
		return false

	chat_channel = await nakama_socket.join_chat_async("global", NakamaSocket.ChannelType.Room, false, false)
	if chat_channel.is_exception():
		push_error("[CLIENT] Nakama chat join failed: %s" % chat_channel.get_exception()._to_string())
		return false
	chat_connected = true
	_set_chat_connected(true)
	_add_chat_system_line("Nakama chat connected")
	print("NAKAMA_CHAT_READY channel=%s" % chat_channel.id)

	var entry := await _request_world_entry(1)
	if entry.is_empty():
		return false
	return await _connect_world(entry)


func _request_world_entry(world_id: int) -> Dictionary:
	var rpc = await nakama_client.rpc_async(
		nakama_session,
		"join_world",
		JSON.stringify({"world_id": world_id})
	)
	return _parse_rpc_payload(rpc, "join_world")


func _request_world_transfer(target_world: int) -> Dictionary:
	var rpc = await nakama_client.rpc_async(
		nakama_session,
		"transfer_world",
		JSON.stringify({
			"from_world": active_world_id,
			"target_world": target_world,
		})
	)
	return _parse_rpc_payload(rpc, "transfer_world")


func _parse_rpc_payload(rpc, label: String) -> Dictionary:
	if rpc.is_exception():
		push_error("[CLIENT] Nakama RPC %s failed: %s" % [label, rpc.get_exception()._to_string()])
		return {}

	var json := JSON.new()
	if json.parse(rpc.payload) != OK:
		push_error("[CLIENT] Nakama RPC %s returned invalid JSON: %s" % [label, rpc.payload])
		return {}
	return json.get_data()


func _connect_world(entry: Dictionary) -> bool:
	var world_id := int(entry.get("world_id", 1))
	var endpoint: Dictionary = entry.get("endpoint", {})
	var url := String(endpoint.get("url", ""))
	current_ticket = String(entry.get("ticket", ""))
	if url.is_empty() or current_ticket.is_empty():
		push_error("[CLIENT] world entry missing url or ticket: %s" % str(entry))
		return false

	world_api.multiplayer_peer = OfflineMultiplayerPeer.new()
	active_world_id = 0
	_load_world_scene(world_id)
	var ok := await _connect_api_with_retries(world_api, url, "world-%d" % world_id, 10.0)
	if not ok:
		return false
	world_endpoint.request_world_state.rpc_id(1, current_ticket)
	return await _wait_until(func() -> bool: return active_world_id == world_id, 8.0, "world %d state" % world_id)


func _available_world_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in NET_CONFIG.WORLD_PORTS.keys():
		ids.append(int(id))
	ids.sort()
	return ids


func _transfer_via_portal(target_world: int) -> bool:
	pending_transfer = {}
	denied_transfer = -1
	if current_world_scene and current_world_scene.has_method("activate_portal_to"):
		current_world_scene.activate_portal_to(target_world)
	else:
		return false

	var ok := await _wait_until(
		func() -> bool: return not pending_transfer.is_empty() or denied_transfer == target_world,
		8.0,
		"transfer approval to world %d" % target_world
	)
	if not ok or denied_transfer == target_world:
		return false

	return await _connect_world(pending_transfer)


func _run_manual_portal_test() -> void:
	print("MANUAL_PORTAL_TEST start")
	if not current_world_scene or not current_world_scene.has_method("activate_portal_to"):
		print("MANUAL_PORTAL_TEST_FAIL no active portal scene")
		get_tree().quit(1)
		return

	current_world_scene.activate_portal_to(2)
	var ok := await _wait_until(func() -> bool: return active_world_id == 2, 8.0, "manual portal transfer to world 2")
	if ok:
		print("MANUAL_PORTAL_TEST_PASS")
		get_tree().quit(0)
	else:
		print("MANUAL_PORTAL_TEST_FAIL did not reach world 2")
		get_tree().quit(1)


func _send_chat_ping(label: String) -> bool:
	if not chat_connected:
		print("[CLIENT] Nakama chat ping skipped; chat is not connected")
		return false

	var message := "chat-ping-%s-world-%d" % [label, active_world_id]
	var ack = await nakama_socket.write_chat_message_async(chat_channel.id, {"text": message})
	if ack.is_exception():
		push_error("[CLIENT] Nakama chat write failed: %s" % ack.get_exception()._to_string())
		return false
	return await _wait_until(func() -> bool: return message in chat_echoes, 5.0, "chat echo %s" % message)


func _on_chat_message_submitted(message: String) -> void:
	if not chat_connected:
		_add_chat_system_line("Nakama chat unavailable")
		return

	var ack = await nakama_socket.write_chat_message_async(chat_channel.id, {"text": message})
	if ack.is_exception():
		_add_chat_system_line("chat send failed")
		push_error("[CLIENT] Nakama chat write failed: %s" % ack.get_exception()._to_string())


func _on_nakama_channel_message(message) -> void:
	var parsed: Variant = JSON.parse_string(message.content)
	var content: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	var text := String(content.get("text", message.content))
	chat_echoes.append(text)
	if chat_panel and chat_panel.has_method("add_chat_line"):
		var name: String = message.username if not String(message.username).is_empty() else message.sender_id
		chat_panel.add_chat_line(name, text)
	print("[CLIENT] Nakama chat from %s: %s" % [message.sender_id, text])


func _set_chat_connected(is_connected: bool) -> void:
	if chat_panel and chat_panel.has_method("set_connected"):
		chat_panel.set_connected(is_connected)


func _add_chat_system_line(message: String) -> void:
	if chat_panel and chat_panel.has_method("add_system_line"):
		chat_panel.add_system_line(message)


func _connect_api_with_retries(api: MultiplayerAPI, url: String, label: String, timeout_seconds: float) -> bool:
	var elapsed := 0.0
	while elapsed < timeout_seconds:
		if await _connect_api(api, url, label, 1.0, false):
			return true
		await get_tree().create_timer(0.25).timeout
		elapsed += 1.25

	push_error("[CLIENT] connection failed for %s at %s" % [label, url])
	return false


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
		api.multiplayer_peer = OfflineMultiplayerPeer.new()
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
	print("[CLIENT] requesting Nakama transfer from world %d to world %d" % [active_world_id, target_world])
	var entry := await _request_world_transfer(target_world)
	if entry.is_empty():
		denied_transfer = target_world
		return

	_on_transfer_approved(target_world, entry)


func _on_transfer_approved(target_world: int, entry: Dictionary) -> void:
	pending_transfer = entry
	pending_transfer["target_world"] = target_world
	if not smoke_test:
		call_deferred("_complete_manual_transfer", target_world)


func _on_transfer_denied(target_world: int) -> void:
	denied_transfer = target_world


func _complete_manual_transfer(target_world: int) -> void:
	if pending_transfer.is_empty() or int(pending_transfer.get("target_world", -1)) != target_world:
		return

	_set_status("Transferring to World %d" % target_world)
	var ok := await _connect_world(pending_transfer)
	if ok:
		print("[CLIENT] manual transfer complete: world %d" % active_world_id)
	else:
		push_error("[CLIENT] manual transfer failed to world %d" % target_world)


func _default_device_id() -> String:
	var unique := OS.get_unique_id()
	if unique.is_empty():
		unique = "local"
	return "virtucade-%s-%d" % [unique, Time.get_ticks_usec()]


func _set_status(text: String) -> void:
	status_label.text = text
	print("[CLIENT] status: %s" % text)


func _smoke_fail(reason: String) -> void:
	print("SMOKE_FAIL %s" % reason)
	get_tree().quit(1)
