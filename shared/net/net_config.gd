const HOST := "127.0.0.1"
const MASTER_PORT := 19080
const DEFAULT_WORLD_KEY := "hub"
const WORLD_SCENE_DIR := "res://shared/worlds"


static func master_url() -> String:
	return "ws://%s:%d" % [HOST, MASTER_PORT]


static func world_keys() -> Array[String]:
	var keys: Array[String] = []
	for entry in ResourceLoader.list_directory(WORLD_SCENE_DIR):
		if not entry.ends_with("/"):
			continue
		var key := entry.trim_suffix("/")
		if ResourceLoader.exists(world_scene_path(key), "PackedScene"):
			keys.append(key)
		else:
			push_error("[NET_CONFIG] world folder '%s' must contain %s.tscn" % [key, key])
	keys.sort()
	return keys


static func initial_world() -> String:
	return DEFAULT_WORLD_KEY


static func is_valid_world_key(world_key: String) -> bool:
	return world_keys().has(world_key)


static func world_url(world_key: String) -> String:
	return "ws://%s:%d" % [HOST, world_port(world_key)]


static func world_port(world_key: String) -> int:
	var world_index := world_keys().find(world_key)
	if world_index == -1:
		return -1
	return MASTER_PORT + 1 + world_index


static func world_scene_path(world_key: String) -> String:
	return "%s/%s/%s.tscn" % [WORLD_SCENE_DIR, world_key, world_key]


static func world_endpoint(world_key: String) -> Dictionary:
	return {
		"key": world_key,
		"name": world_key.capitalize(),
		"url": world_url(world_key),
		"port": world_port(world_key),
		"scene": world_scene_path(world_key),
	}


static func routes() -> Dictionary:
	return {
		"worlds": {},
		"initial_world": initial_world(),
	}
