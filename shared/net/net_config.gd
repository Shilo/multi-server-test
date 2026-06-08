const DEFAULT_BIND_HOST := "127.0.0.1"
const DEFAULT_PUBLIC_HOST := "127.0.0.1"
const MASTER_PORT := 19080
const DEFAULT_WORLD_KEY := "hub"
const DEFAULT_WORLD_REGISTRATION_SECRET := "local_dev_world_secret"
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


static func bind_host() -> String:
	return _env("VIRTUCADE_BIND_HOST", DEFAULT_BIND_HOST)


static func public_host() -> String:
	return _env("VIRTUCADE_PUBLIC_HOST", DEFAULT_PUBLIC_HOST)


static func world_registration_secret() -> String:
	return _env("VIRTUCADE_WORLD_REGISTRATION_SECRET", DEFAULT_WORLD_REGISTRATION_SECRET)


static func master_url() -> String:
	return "ws://%s:%d" % [_env("VIRTUCADE_MASTER_PUBLIC_HOST", public_host()), MASTER_PORT]


static func master_bind_host() -> String:
	return _env("VIRTUCADE_MASTER_BIND_HOST", bind_host())


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
	var key := world_key.to_upper()
	var explicit_url := _env("VIRTUCADE_%s_PUBLIC_URL" % key, "")
	if not explicit_url.is_empty():
		return explicit_url
	return "ws://%s:%d" % [_env("VIRTUCADE_WORLD_PUBLIC_HOST", public_host()), world_port(world_key)]


static func world_bind_host(world_key: String) -> String:
	var key := world_key.to_upper()
	return _env("VIRTUCADE_%s_BIND_HOST" % key, _env("VIRTUCADE_WORLD_BIND_HOST", bind_host()))


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


static func _env(name: String, fallback: String) -> String:
	if OS.has_environment(name):
		var value := OS.get_environment(name)
		if not value.is_empty():
			return value
	return fallback
