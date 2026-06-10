const HOST := "127.0.0.1"
const MASTER_PORT := 19080
const DEFAULT_WORLD_KEY := "hub"
const WORLD_SCENE_DIR := "res://server/worlds"
const WORLD_MANIFEST_PATH := "res://server/worlds/world_manifest.json"

static var _cached_world_keys: Array[String] = []
static var _cached_world_manifest := {}
static var _world_manifest_loaded := false


static func master_url() -> String:
	return "ws://%s:%d" % [HOST, MASTER_PORT]


static func world_keys() -> Array[String]:
	if not _cached_world_keys.is_empty():
		return _cached_world_keys.duplicate()

	var keys: Array[String] = []
	var manifest_worlds: Dictionary = world_manifest().get("worlds", {})
	for key in manifest_worlds.keys():
		var world_key := str(key)
		if not keys.has(world_key):
			keys.append(world_key)

	for entry in ResourceLoader.list_directory(WORLD_SCENE_DIR):
		if not entry.ends_with("/"):
			continue
		var key := entry.trim_suffix("/")
		if ResourceLoader.exists(default_world_scene_path(key), "PackedScene"):
			if not keys.has(key):
				keys.append(key)
		else:
			push_error("[NET_CONFIG] world folder '%s' must contain %s.tscn" % [key, key])

	var valid_keys: Array[String] = []
	for key in keys:
		if ResourceLoader.exists(world_scene_path(key), "PackedScene"):
			valid_keys.append(key)
			continue
		var world_entry: Dictionary = manifest_worlds.get(key, {})
		if bool(world_entry.get("allow_missing_scene", false)):
			valid_keys.append(key)
		else:
			push_error("[NET_CONFIG] world folder '%s' must contain %s.tscn" % [key, key])

	valid_keys.sort()
	_cached_world_keys = valid_keys
	return _cached_world_keys.duplicate()


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
	var world_entry := world_manifest_entry(world_key)
	var scene := str(world_entry.get("scene", ""))
	if not scene.is_empty():
		return scene
	return default_world_scene_path(world_key)


static func default_world_scene_path(world_key: String) -> String:
	return "%s/%s/%s.tscn" % [WORLD_SCENE_DIR, world_key, world_key]


static func world_endpoint(world_key: String) -> Dictionary:
	var world_entry := world_manifest_entry(world_key)
	var endpoint := {
		"key": world_key,
		"name": str(world_entry.get("display_name", world_key.capitalize())),
		"url": world_url(world_key),
		"port": world_port(world_key),
		"scene": world_scene_path(world_key),
	}
	var pack := world_pack_metadata(world_key)
	if not pack.is_empty():
		endpoint["pack"] = pack
	return endpoint


static func world_catalog() -> Dictionary:
	var catalog := {}
	for world_key in world_keys():
		var endpoint := world_endpoint(world_key)
		endpoint.erase("url")
		endpoint.erase("port")
		catalog[world_key] = endpoint
	return catalog


static func world_manifest() -> Dictionary:
	if _world_manifest_loaded:
		return _cached_world_manifest.duplicate(true)

	_world_manifest_loaded = true
	if not FileAccess.file_exists(WORLD_MANIFEST_PATH):
		_cached_world_manifest = {}
		return {}

	var file := FileAccess.open(WORLD_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_error("[NET_CONFIG] failed to open world manifest: %s" % WORLD_MANIFEST_PATH)
		_cached_world_manifest = {}
		return {}

	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[NET_CONFIG] invalid world manifest JSON: %s" % WORLD_MANIFEST_PATH)
		_cached_world_manifest = {}
		return {}

	_cached_world_manifest = parsed
	return _cached_world_manifest.duplicate(true)


static func world_manifest_entry(world_key: String) -> Dictionary:
	var worlds: Dictionary = world_manifest().get("worlds", {})
	return worlds.get(world_key, {})


static func world_pack_metadata(world_key: String) -> Dictionary:
	var world_entry := world_manifest_entry(world_key)
	var pack: Dictionary = world_entry.get("pack", {})
	if pack.is_empty() or not bool(pack.get("enabled", false)):
		return {}

	var metadata := pack.duplicate(true)
	metadata.erase("enabled")
	if not metadata.has("version") or str(metadata["version"]).is_empty():
		metadata["version"] = "dev"
	if not metadata.has("scene") or str(metadata["scene"]).is_empty():
		metadata["scene"] = world_scene_path(world_key)

	var url := str(metadata.get("url", ""))
	var file_name := str(metadata.get("file", ""))
	if url.is_empty() and not file_name.is_empty():
		var base_url := str(world_manifest().get("asset_base_url", ""))
		if not base_url.is_empty():
			url = "%s/%s" % [base_url.trim_suffix("/"), file_name]
			metadata["url"] = url
	return metadata


static func routes() -> Dictionary:
	return {
		"worlds": {},
		"initial_world": initial_world(),
		"world_catalog": world_catalog(),
	}
