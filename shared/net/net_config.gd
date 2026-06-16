const SERVER_HOST := "127.0.0.1"
const CLIENT_HOST := "127.0.0.1"
const CLIENT_SCHEME := "ws"
const MASTER_PORT := 19080
const GITHUB_PAGES_WORLD_PACK_BASE_URL := "https://shilo.github.io/multi-server-test/world_packs"
const WORLD_PACK_BASE_URL_ENV := "MULTI_SERVER_WORLD_PACK_BASE_URL"
const WORLD_PACK_DIR_ENV := "MULTI_SERVER_WORLD_PACK_DIR"
const DEFAULT_WORLD_KEY := "hub"
const WORLD_SCENE_DIR := "res://server/worlds"

static var _cached_world_keys: Array[String] = []
static var _world_keys_loaded := false


static func master_url() -> String:
	return "%s://%s:%d" % [CLIENT_SCHEME, CLIENT_HOST, MASTER_PORT]


static func local_master_url() -> String:
	return "ws://%s:%d" % [SERVER_HOST, MASTER_PORT]


static func world_keys() -> Array[String]:
	if _world_keys_loaded:
		return _cached_world_keys.duplicate()

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
	_cached_world_keys = keys
	_world_keys_loaded = true
	return _cached_world_keys.duplicate()


static func initial_world() -> String:
	return DEFAULT_WORLD_KEY


static func is_valid_world_key(world_key: String) -> bool:
	return world_keys().has(world_key)


static func world_url(world_key: String) -> String:
	return "%s://%s:%d" % [CLIENT_SCHEME, CLIENT_HOST, world_port(world_key)]


static func world_port(world_key: String) -> int:
	var world_index := world_keys().find(world_key)
	if world_index == -1:
		return -1
	return MASTER_PORT + 1 + world_index


static func world_scene_path(world_key: String) -> String:
	return "%s/%s/%s.tscn" % [WORLD_SCENE_DIR, world_key, world_key]


static func world_pack_base_url() -> String:
	var value := OS.get_environment(WORLD_PACK_BASE_URL_ENV).strip_edges()
	if value.is_empty():
		value = _web_query_value("world_pack_base_url")
	if value.is_empty() and OS.has_feature("web"):
		value = _web_same_origin_world_pack_base_url()
	if value.is_empty():
		return GITHUB_PAGES_WORLD_PACK_BASE_URL
	return value.trim_suffix("/")


static func world_pack_file_path(world_key: String) -> String:
	return world_pack_dir().path_join("%s.pck" % world_key)


static func world_pack_dir() -> String:
	var value := OS.get_environment(WORLD_PACK_DIR_ENV).strip_edges()
	if not value.is_empty():
		return value
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://builds/web/world_packs")
	return OS.get_executable_path().get_base_dir().get_base_dir().path_join("web").path_join("world_packs")


static func world_pack_url(world_key: String) -> String:
	var url := "%s/%s.pck" % [world_pack_base_url(), world_key.uri_encode()]
	var version := str(ProjectSettings.get_setting("application/config/version", "0.1"))
	if version.is_empty():
		return url
	return "%s?v=%s" % [url, version.uri_encode()]


static func _web_query_value(key: String) -> String:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return ""

	var javascript: Object = Engine.get_singleton("JavaScriptBridge")
	if javascript == null:
		return ""

	var expression := "new URLSearchParams(window.location.search).get('%s') || ''" % key
	var value: Variant = javascript.call("eval", expression, true)
	return String(value).strip_edges() if typeof(value) == TYPE_STRING else ""


static func _web_same_origin_world_pack_base_url() -> String:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return ""

	var javascript: Object = Engine.get_singleton("JavaScriptBridge")
	if javascript == null:
		return ""

	var value: Variant = javascript.call("eval", "new URL('world_packs', window.location.href).href", true)
	if typeof(value) != TYPE_STRING:
		return ""
	return String(value).strip_edges().trim_suffix("/")


static func world_endpoint(world_key: String) -> Dictionary:
	return {
		"key": world_key,
		"name": world_key.capitalize(),
		"url": world_url(world_key),
		"port": world_port(world_key),
		"scene": world_scene_path(world_key),
	}


static func world_catalog() -> Dictionary:
	var catalog := {}
	for world_key in world_keys():
		var endpoint := world_endpoint(world_key)
		endpoint.erase("url")
		endpoint.erase("port")
		catalog[world_key] = endpoint
	return catalog


static func routes() -> Dictionary:
	return {
		"worlds": {},
		"initial_world": initial_world(),
		"world_catalog": world_catalog(),
	}
