const SERVER_HOST := "127.0.0.1"
const DEFAULT_CLIENT_HOST := "127.0.0.1"
const DEFAULT_CLIENT_SCHEME := "ws"
const MASTER_PORT := 19080
const GITHUB_PAGES_WORLD_PACK_BASE_URL := "https://shilo.github.io/multi-server-test/world_packs"
const CLIENT_HOST_ENV := "MULTI_SERVER_CLIENT_HOST"
const CLIENT_SCHEME_ENV := "MULTI_SERVER_CLIENT_SCHEME"
const TLS_CERT_PATH_ENV := "MULTI_SERVER_TLS_CERT"
const TLS_KEY_PATH_ENV := "MULTI_SERVER_TLS_KEY"
const WORLD_PACK_BASE_URL_ENV := "MULTI_SERVER_WORLD_PACK_BASE_URL"
const WORLD_PACK_DIR_ENV := "MULTI_SERVER_WORLD_PACK_DIR"
const DEFAULT_WORLD_KEY := "hub"
const WORLD_SCENE_DIR := "res://server/worlds"

static var _cached_world_keys: Array[String] = []
static var _world_keys_loaded := false


static func master_url() -> String:
	return "%s://%s:%d" % [client_scheme(), client_host(), MASTER_PORT]


static func local_master_url() -> String:
	return "ws://%s:%d" % [SERVER_HOST, MASTER_PORT]


static func client_host() -> String:
	var value := OS.get_environment(CLIENT_HOST_ENV).strip_edges()
	if value.is_empty():
		value = _web_query_value("server_host")
	if value.is_empty():
		return DEFAULT_CLIENT_HOST
	return value


static func client_scheme() -> String:
	var value := OS.get_environment(CLIENT_SCHEME_ENV).strip_edges().to_lower()
	if value.is_empty():
		value = _web_query_value("server_scheme").to_lower()
	if value.is_empty() and OS.has_feature("web"):
		value = _web_same_origin_socket_scheme()
	if value.is_empty():
		return DEFAULT_CLIENT_SCHEME
	return value


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
	return "%s://%s:%d" % [client_scheme(), client_host(), world_port(world_key)]


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
	return OS.get_executable_path().get_base_dir().get_base_dir().path_join("world_packs")


static func world_pack_url(world_key: String) -> String:
	return "%s/%s.pck" % [world_pack_base_url(), world_key.uri_encode()]


static func tls_enabled() -> bool:
	return not tls_cert_path().is_empty() and not tls_key_path().is_empty()


static func tls_cert_path() -> String:
	return OS.get_environment(TLS_CERT_PATH_ENV).strip_edges()


static func tls_key_path() -> String:
	return OS.get_environment(TLS_KEY_PATH_ENV).strip_edges()


static func tls_server_options() -> TLSOptions:
	var cert_path := tls_cert_path()
	var key_path := tls_key_path()
	if cert_path.is_empty() or key_path.is_empty():
		return null

	var certificate := X509Certificate.new()
	var cert_err := certificate.load(cert_path)
	if cert_err != OK:
		push_error("[NET_CONFIG] failed to load TLS certificate %s err=%s" % [cert_path, cert_err])
		return null

	var key := CryptoKey.new()
	var key_err := key.load(key_path)
	if key_err != OK:
		push_error("[NET_CONFIG] failed to load TLS key %s err=%s" % [key_path, key_err])
		return null

	return TLSOptions.server(key, certificate)


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


static func _web_same_origin_socket_scheme() -> String:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return ""

	var javascript: Object = Engine.get_singleton("JavaScriptBridge")
	if javascript == null:
		return ""

	var value: Variant = javascript.call("eval", "window.location.protocol === 'https:' ? 'wss' : 'ws'", true)
	if typeof(value) != TYPE_STRING:
		return ""
	return String(value).strip_edges().to_lower()


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
