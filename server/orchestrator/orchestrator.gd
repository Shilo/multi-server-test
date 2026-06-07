extends Node

const CLI_ARGS := preload("res://shared/cli_args.gd")
const NET_CONFIG := preload("res://shared/net_config.gd")

const DEFAULT_IDLE_SHUTDOWN_SECONDS := 10.0
const BUFFER_LIMIT := 65536

var server := TCPServer.new()
var clients: Array[Dictionary] = []
var worlds := {}
var listen_host := "127.0.0.1"
var listen_port := 19100
var shared_key := "localdev-secret"
var godot_exe := ""
var project_root := ""
var use_exported := false

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	listen_host = CLI_ARGS.get_value(args, "orchestrator-host", listen_host)
	listen_port = int(CLI_ARGS.get_value(args, "orchestrator-port", str(listen_port)))
	shared_key = CLI_ARGS.get_value(args, "orchestrator-key", shared_key)
	godot_exe = CLI_ARGS.get_value(args, "spawn-godot", OS.get_executable_path())
	project_root = CLI_ARGS.get_value(args, "project-root", ProjectSettings.globalize_path("res://"))
	use_exported = CLI_ARGS.has_flag(args, "spawn-exported")

	var err := server.listen(listen_port, listen_host)
	if err != OK:
		push_error("[ORCH] failed to listen on %s:%d err=%s" % [listen_host, listen_port, err])
		get_tree().quit(20)
		return

	print("ORCHESTRATOR_READY url=http://%s:%d" % [listen_host, listen_port])


func _process(_delta: float) -> void:
	while server.is_connection_available():
		clients.append({
			"peer": server.take_connection(),
			"buffer": PackedByteArray(),
		})

	for i in range(clients.size() - 1, -1, -1):
		if _poll_client(clients[i]):
			clients.remove_at(i)

	_stop_idle_worlds()


func _poll_client(client: Dictionary) -> bool:
	var peer := client["peer"] as StreamPeerTCP
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return true

	var available := peer.get_available_bytes()
	if available > 0:
		var chunk := peer.get_data(available)
		if chunk[0] != OK:
			return true
		var buffer := client["buffer"] as PackedByteArray
		buffer.append_array(chunk[1])
		client["buffer"] = buffer
		if buffer.size() > BUFFER_LIMIT:
			_send_json(peer, 413, {"error": "request too large"})
			return true

	var request := _try_parse_http_request(client["buffer"])
	if request.is_empty():
		return false

	var response := _handle_request(request)
	_send_json(peer, int(response.get("status", 200)), response.get("body", {}))
	return true


func _try_parse_http_request(buffer: PackedByteArray) -> Dictionary:
	var text := buffer.get_string_from_utf8()
	var header_end := text.find("\r\n\r\n")
	if header_end == -1:
		return {}

	var header_text := text.substr(0, header_end)
	var lines := header_text.split("\r\n")
	if lines.is_empty():
		return {}

	var request_parts := lines[0].split(" ")
	if request_parts.size() < 2:
		return {}

	var content_length := 0
	var headers := {}
	for i in range(1, lines.size()):
		var line := String(lines[i])
		var colon := line.find(":")
		if colon == -1:
			continue
		var key := line.substr(0, colon).strip_edges().to_lower()
		var value := line.substr(colon + 1).strip_edges()
		headers[key] = value
		if key == "content-length":
			content_length = int(value)

	var body_start := header_end + 4
	var body_bytes := buffer.size() - body_start
	if body_bytes < content_length:
		return {}

	var body := text.substr(body_start, content_length)
	var json_body := {}
	if not body.is_empty():
		var json := JSON.new()
		if json.parse(body) != OK:
			return {
				"method": request_parts[0],
				"path": request_parts[1],
				"headers": headers,
				"body": {"_parse_error": true},
			}
		json_body = json.get_data()

	return {
		"method": request_parts[0],
		"path": request_parts[1],
		"headers": headers,
		"body": json_body,
	}


func _handle_request(request: Dictionary) -> Dictionary:
	if not _authorized(request):
		return {"status": 401, "body": {"error": "unauthorized"}}

	var method := String(request["method"])
	var path := String(request["path"])
	var body: Dictionary = request.get("body", {})
	if body is Dictionary and body.get("_parse_error", false):
		return {"status": 400, "body": {"error": "invalid json"}}

	if method == "POST" and path == "/worlds/ensure":
		return {"body": _ensure_world(body)}
	if method == "POST" and path == "/worlds/heartbeat":
		return {"body": _heartbeat_world(body)}
	if method == "GET" and path == "/worlds":
		return {"body": {"worlds": _world_list()}}
	if method == "POST" and path.ends_with("/stop"):
		var id := int(path.trim_prefix("/worlds/").trim_suffix("/stop"))
		return {"body": _stop_world(id, "api")}

	return {"status": 404, "body": {"error": "not found"}}


func _authorized(request: Dictionary) -> bool:
	var headers: Dictionary = request.get("headers", {})
	if not headers.has("x-orchestrator-key"):
		return false
	return String(headers["x-orchestrator-key"]) == shared_key


func _ensure_world(body: Dictionary) -> Dictionary:
	var world_id := int(body.get("world_id", 1))
	if not NET_CONFIG.WORLD_PORTS.has(world_id):
		return {"ok": false, "error": "unknown world_id"}

	if not worlds.has(world_id) or not _is_process_alive(worlds[world_id]):
		_start_world(world_id, float(body.get("idle_shutdown_seconds", DEFAULT_IDLE_SHUTDOWN_SECONDS)))

	var world: Dictionary = worlds[world_id]
	return {
		"ok": true,
		"world": _public_world(world),
	}


func _start_world(world_id: int, idle_shutdown_seconds: float) -> void:
	var port: int = NET_CONFIG.WORLD_PORTS[world_id]
	var args := _world_process_args(world_id, port)
	var pid := OS.create_process(godot_exe, args)
	worlds[world_id] = {
		"world_id": world_id,
		"pid": pid,
		"port": port,
		"url": NET_CONFIG.world_url(world_id),
		"state": "starting",
		"player_count": 0,
		"started_at": Time.get_ticks_msec(),
		"last_heartbeat_at": 0,
		"last_empty_at": Time.get_ticks_msec(),
		"idle_shutdown_seconds": idle_shutdown_seconds,
	}
	print("ORCHESTRATOR_WORLD_STARTED id=%d pid=%d port=%d" % [world_id, pid, port])


func _world_process_args(world_id: int, port: int) -> PackedStringArray:
	var args := PackedStringArray()
	args.append("--headless")
	if not use_exported:
		args.append("--path")
		args.append(project_root)
	args.append("--")
	args.append("--role")
	args.append("world")
	args.append("--world")
	args.append(str(world_id))
	args.append("--port")
	args.append(str(port))
	args.append("--nakama-host")
	args.append("127.0.0.1")
	args.append("--nakama-port")
	args.append("7350")
	args.append("--nakama-server-key")
	args.append("defaultkey")
	args.append("--nakama-http-key")
	args.append("defaulthttpkey")
	args.append("--orchestrator-url")
	args.append("http://%s:%d" % [listen_host, listen_port])
	args.append("--orchestrator-key")
	args.append(shared_key)
	return args


func _heartbeat_world(body: Dictionary) -> Dictionary:
	var world_id := int(body.get("world_id", 0))
	if not worlds.has(world_id):
		return {"ok": false, "error": "unknown world"}

	var world: Dictionary = worlds[world_id]
	var player_count := int(body.get("player_count", 0))
	world["state"] = "ready"
	world["player_count"] = player_count
	world["last_heartbeat_at"] = Time.get_ticks_msec()
	if player_count > 0:
		world["last_empty_at"] = 0
	elif int(world.get("last_empty_at", 0)) == 0:
		world["last_empty_at"] = Time.get_ticks_msec()
	worlds[world_id] = world
	return {"ok": true}


func _stop_idle_worlds() -> void:
	var now := Time.get_ticks_msec()
	for world_id in worlds.keys():
		var world: Dictionary = worlds[world_id]
		if int(world.get("player_count", 0)) > 0:
			continue
		var last_empty_at := int(world.get("last_empty_at", 0))
		if last_empty_at == 0:
			continue
		var idle_ms := int(float(world.get("idle_shutdown_seconds", DEFAULT_IDLE_SHUTDOWN_SECONDS)) * 1000.0)
		if now - last_empty_at >= idle_ms:
			_stop_world(int(world_id), "idle")


func _stop_world(world_id: int, reason: String) -> Dictionary:
	if not worlds.has(world_id):
		return {"ok": true, "already_stopped": true}

	var world: Dictionary = worlds[world_id]
	var pid := int(world.get("pid", -1))
	if pid > 0:
		OS.kill(pid)
	worlds.erase(world_id)
	print("ORCHESTRATOR_WORLD_STOPPED id=%d pid=%d reason=%s" % [world_id, pid, reason])
	return {"ok": true}


func _is_process_alive(world: Dictionary) -> bool:
	var pid := int(world.get("pid", -1))
	return pid > 0 and OS.is_process_running(pid)


func _world_list() -> Array:
	var list := []
	for world_id in worlds.keys():
		list.append(_public_world(worlds[world_id]))
	return list


func _public_world(world: Dictionary) -> Dictionary:
	return {
		"world_id": int(world.get("world_id", 0)),
		"state": world.get("state", "unknown"),
		"port": int(world.get("port", 0)),
		"url": world.get("url", ""),
		"player_count": int(world.get("player_count", 0)),
	}


func _send_json(peer: StreamPeerTCP, status: int, body: Dictionary) -> void:
	var payload := JSON.stringify(body)
	var status_text := "OK" if status < 400 else "Error"
	var headers := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, status_text, payload.to_utf8_buffer().size()]
	peer.put_data(headers.to_utf8_buffer())
	peer.put_data(payload.to_utf8_buffer())
	peer.disconnect_from_host()
