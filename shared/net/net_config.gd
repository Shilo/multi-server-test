const HOST := "127.0.0.1"
const MASTER_PORT := 19080
const DEFAULT_WORLD_KEY := "hub"
const WORLD_REGISTRATION_SECRET := "local_dev_world_secret"
const WORLD_CONFIGS := {
	"hub": {
		"name": "Hub",
		"port": 19081,
		"scene": "res://shared/world/hub.tscn",
		"allowed_targets": ["left_world", "right_world"],
	},
	"left_world": {
		"name": "Left World",
		"port": 19082,
		"scene": "res://shared/world/left_world.tscn",
		"allowed_targets": ["hub"],
	},
	"right_world": {
		"name": "Right World",
		"port": 19083,
		"scene": "res://shared/world/right_world.tscn",
		"allowed_targets": ["hub"],
	},
}


static func master_url() -> String:
	return "ws://%s:%d" % [HOST, MASTER_PORT]


static func world_registration_secret() -> String:
	return WORLD_REGISTRATION_SECRET


static func world_keys() -> Array[String]:
	var keys: Array[String] = []
	for key in WORLD_CONFIGS.keys():
		keys.append(str(key))
	keys.sort()
	return keys


static func initial_world() -> String:
	return DEFAULT_WORLD_KEY


static func is_valid_world_key(world_key: String) -> bool:
	return WORLD_CONFIGS.has(world_key)


static func world_url(world_key: String) -> String:
	return "ws://%s:%d" % [HOST, world_port(world_key)]


static func world_port(world_key: String) -> int:
	return int(WORLD_CONFIGS[world_key]["port"])


static func world_scene_path(world_key: String) -> String:
	return str(WORLD_CONFIGS[world_key]["scene"])


static func allowed_targets(world_key: String) -> Array[String]:
	var targets: Array[String] = []
	for target in WORLD_CONFIGS[world_key]["allowed_targets"]:
		targets.append(str(target))
	return targets


static func world_endpoint(world_key: String) -> Dictionary:
	return {
		"key": world_key,
		"name": str(WORLD_CONFIGS[world_key]["name"]),
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
