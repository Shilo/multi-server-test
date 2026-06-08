const HOST := "127.0.0.1"
const MASTER_PORT := 19080
const FIRST_WORLD_PORT := MASTER_PORT + 1
const DEFAULT_WORLD_KEY := "hub"
const WORLD_REGISTRATION_SECRET := "local_dev_world_secret"
const WORLD_SCENE_DIR := "res://shared/world"
const WORLD_KEYS := ["hub", "left_world", "right_world"]


static func master_url() -> String:
	return "ws://%s:%d" % [HOST, MASTER_PORT]


static func world_registration_secret() -> String:
	return WORLD_REGISTRATION_SECRET


static func world_keys() -> Array[String]:
	var keys: Array[String] = []
	for key in WORLD_KEYS:
		keys.append(str(key))
	return keys


static func initial_world() -> String:
	return DEFAULT_WORLD_KEY


static func is_valid_world_key(world_key: String) -> bool:
	return WORLD_KEYS.has(world_key)


static func world_url(world_key: String) -> String:
	return "ws://%s:%d" % [HOST, world_port(world_key)]


static func world_port(world_key: String) -> int:
	var world_index := WORLD_KEYS.find(world_key)
	if world_index == -1:
		return -1
	return FIRST_WORLD_PORT + world_index


static func world_scene_path(world_key: String) -> String:
	return "%s/%s.tscn" % [WORLD_SCENE_DIR, world_key]


static func allowed_targets(world_key: String) -> Array[String]:
	var targets: Array[String] = []
	if world_key == DEFAULT_WORLD_KEY:
		for key in WORLD_KEYS:
			if key != DEFAULT_WORLD_KEY:
				targets.append(str(key))
	elif is_valid_world_key(world_key):
		targets.append(DEFAULT_WORLD_KEY)
	return targets


static func world_endpoint(world_key: String) -> Dictionary:
	return {
		"key": world_key,
		"name": world_key.capitalize(),
		"url": world_url(world_key),
		"port": world_port(world_key),
		"scene": world_scene_path(world_key),
		"allowed_targets": allowed_targets(world_key),
	}


static func routes() -> Dictionary:
	return {
		"worlds": {},
		"initial_world": initial_world(),
	}
