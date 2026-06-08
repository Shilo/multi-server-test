extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const LOCAL_WORLD_SERVER_SCENE := "res://world_server/world_server.tscn"
const WORLD_START_TIMEOUT_SECONDS := 5.0
const WORLD_IDLE_SHUTDOWN_SECONDS := 5.0
const WORLD_STOP_KILL_SECONDS := 2.0

var master_endpoint: Node
var worlds := {}


func _ready() -> void:
	var timer := Timer.new()
	timer.name = "WorldProcessPollTimer"
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(_poll_world_processes)
	add_child(timer)


func configure_master_endpoint(endpoint: Node) -> void:
	master_endpoint = endpoint


func ensure_world_started(world_key: String) -> bool:
	if not NET_CONFIG.is_valid_world_key(world_key):
		push_error("[MASTER] cannot start invalid world key: %s" % world_key)
		return false

	if worlds.has(world_key):
		var state: Dictionary = worlds[world_key]
		var pid := int(state.get("pid", -1))
		if pid > 0 and OS.is_process_running(pid) and str(state.get("state", "")) != "stopping":
			state["last_interest"] = Time.get_unix_time_from_system()
			worlds[world_key] = state
			return true

	return _launch_world(world_key)


func expects_registration(world_key: String, launch_token: String) -> bool:
	if launch_token.is_empty() or not worlds.has(world_key):
		return false

	var state: Dictionary = worlds[world_key]
	return str(state.get("launch_token", "")) == launch_token and str(state.get("state", "")) != "stopping"


func mark_world_registered(world_key: String) -> void:
	if not worlds.has(world_key):
		return

	var state: Dictionary = worlds[world_key]
	state["registered"] = true
	state["state"] = "running"
	state["idle_since"] = Time.get_unix_time_from_system()
	state["last_interest"] = Time.get_unix_time_from_system()
	worlds[world_key] = state
	print("MASTER_WORLD_RUNNING key=%s pid=%d" % [world_key, int(state.get("pid", -1))])


func update_world_player_count(world_key: String, player_count: int) -> void:
	if not worlds.has(world_key):
		return

	var state: Dictionary = worlds[world_key]
	var clamped_count = max(player_count, 0)
	var previous_count := int(state.get("player_count", -1))
	state["player_count"] = clamped_count
	if clamped_count == 0:
		if float(state.get("idle_since", -1.0)) < 0.0:
			state["idle_since"] = Time.get_unix_time_from_system()
			print("MASTER_WORLD_IDLE key=%s players=0" % world_key)
	else:
		state["idle_since"] = -1.0
	worlds[world_key] = state
	if previous_count != clamped_count:
		print("MASTER_WORLD_PLAYERS key=%s count=%d" % [world_key, clamped_count])


func request_world_stop(world_key: String, reason: String) -> void:
	if not worlds.has(world_key):
		return

	var state: Dictionary = worlds[world_key]
	if str(state.get("state", "")) == "stopping":
		return

	state["state"] = "stopping"
	state["stop_reason"] = reason
	state["stop_requested_at"] = Time.get_unix_time_from_system()
	worlds[world_key] = state
	print("MASTER_WORLD_STOP_REQUESTED key=%s reason=%s" % [world_key, reason])

	if master_endpoint and master_endpoint.has_method("shutdown_registered_world"):
		master_endpoint.shutdown_registered_world(world_key, reason)


func stop_all_worlds(reason: String) -> void:
	for world_key in worlds.keys():
		var state: Dictionary = worlds[world_key]
		state["stop_reason"] = reason
		state["state"] = "stopping"
		worlds[world_key] = state

		var pid := int(state.get("pid", -1))
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			print("MASTER_WORLD_KILLED key=%s pid=%d reason=%s" % [world_key, pid, reason])


func world_start_timeout_seconds() -> float:
	return WORLD_START_TIMEOUT_SECONDS


func _launch_world(world_key: String) -> bool:
	var executable_path := _world_server_executable_path()
	if executable_path.is_empty() or not FileAccess.file_exists(executable_path):
		push_error("[MASTER] world server executable not found: %s" % executable_path)
		return false

	var launch_token := _new_launch_token()
	var arguments := _world_server_arguments(world_key, launch_token)
	var pid := OS.create_process(executable_path, arguments)
	if pid == -1:
		push_error("[MASTER] failed to launch world %s with executable %s" % [world_key, executable_path])
		return false

	worlds[world_key] = {
		"pid": pid,
		"launch_token": launch_token,
		"state": "starting",
		"registered": false,
		"player_count": 0,
		"idle_since": -1.0,
		"stop_requested_at": -1.0,
		"stop_reason": "",
	}
	print("MASTER_WORLD_STARTED key=%s pid=%d" % [world_key, pid])
	return true


func _world_server_executable_path() -> String:
	if not OS.has_feature("template"):
		return OS.get_executable_path()

	var master_dir := OS.get_executable_path().get_base_dir()
	for executable_name in _world_server_executable_names():
		var sibling_path := master_dir.get_base_dir().path_join("world_server").path_join(executable_name)
		if FileAccess.file_exists(sibling_path):
			return sibling_path

		var same_dir_path := master_dir.path_join(executable_name)
		if FileAccess.file_exists(same_dir_path):
			return same_dir_path

	return master_dir.get_base_dir().path_join("world_server").path_join(_world_server_executable_names()[0])


func _world_server_executable_names() -> Array[String]:
	if OS.has_feature("windows"):
		return ["world_server.exe", "world_server.console.exe"]

	return ["world_server.x86_64", "world_server"]


func _world_server_arguments(world_key: String, launch_token: String) -> PackedStringArray:
	var arguments := PackedStringArray(["--headless"])
	if not OS.has_feature("template"):
		arguments.append_array(PackedStringArray([
			"--path",
			ProjectSettings.globalize_path("res://"),
			"--scene",
			LOCAL_WORLD_SERVER_SCENE,
		]))
	arguments.append_array(PackedStringArray(["--", world_key, launch_token]))
	return arguments


func _new_launch_token() -> String:
	var token := ""
	for byte in OS.get_entropy(16):
		token += str(int(byte)).pad_zeros(3)
	return token


func _poll_world_processes() -> void:
	var now := Time.get_unix_time_from_system()
	for world_key in worlds.keys():
		var state: Dictionary = worlds[world_key]
		var pid := int(state.get("pid", -1))
		if pid > 0 and not OS.is_process_running(pid):
			_on_world_process_exited(world_key, state)
			continue

		var is_registered := bool(state.get("registered", false))
		var player_count := int(state.get("player_count", 0))
		var idle_since := float(state.get("idle_since", -1.0))
		var last_interest := float(state.get("last_interest", -1.0))
		if is_registered and player_count == 0 and idle_since >= 0.0:
			var idle_reference = max(idle_since, last_interest)
			if now - idle_reference >= WORLD_IDLE_SHUTDOWN_SECONDS:
				request_world_stop(world_key, "idle")
				continue

		if str(state.get("state", "")) != "stopping":
			continue

		var stop_requested_at := float(state.get("stop_requested_at", -1.0))
		if stop_requested_at >= 0.0 and now - stop_requested_at >= WORLD_STOP_KILL_SECONDS:
			var err := OS.kill(pid)
			print("MASTER_WORLD_KILLED key=%s pid=%d err=%s" % [world_key, pid, err])


func _on_world_process_exited(world_key: String, state: Dictionary) -> void:
	var pid := int(state.get("pid", -1))
	var reason := str(state.get("stop_reason", "process_exited"))
	print("MASTER_WORLD_STOPPED key=%s pid=%d reason=%s" % [world_key, pid, reason])
	worlds.erase(world_key)
	if master_endpoint and master_endpoint.has_method("unregister_world_by_key"):
		master_endpoint.unregister_world_by_key(world_key, "process_exited")
