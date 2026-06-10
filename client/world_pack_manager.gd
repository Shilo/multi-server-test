extends Node

const NET_CONFIG := preload("res://shared/net/net_config.gd")
const PACK_CACHE_DIR := "user://world_packs"


func ensure_world_installed(world_key: String, endpoint: Dictionary) -> bool:
	var scene_path := str(endpoint.get("scene", NET_CONFIG.world_scene_path(world_key)))
	if ResourceLoader.exists(scene_path, "PackedScene"):
		return true

	var pack = endpoint.get("pack", {})
	if typeof(pack) != TYPE_DICTIONARY or pack.is_empty():
		push_error("[WORLD_PACK] missing pack metadata for %s scene=%s" % [world_key, scene_path])
		return false

	var pack_metadata: Dictionary = pack
	var url := str(pack_metadata.get("url", ""))
	if url.is_empty():
		push_error("[WORLD_PACK] missing pack URL for %s" % world_key)
		return false

	var cache_path := _cache_path(world_key, pack_metadata)
	if not FileAccess.file_exists(cache_path) or not _verify_pack_file(cache_path, pack_metadata):
		var downloaded := await _download_pack(url, cache_path)
		if not downloaded:
			return false
		if not _verify_pack_file(cache_path, pack_metadata):
			return false

	if not ProjectSettings.load_resource_pack(cache_path, true):
		push_error("[WORLD_PACK] failed to mount pack for %s: %s" % [world_key, cache_path])
		return false

	if not ResourceLoader.exists(scene_path, "PackedScene"):
		push_error("[WORLD_PACK] mounted pack did not provide %s" % scene_path)
		return false

	return true


func _download_pack(url: String, cache_path: String) -> bool:
	var cache_dir_absolute := ProjectSettings.globalize_path(PACK_CACHE_DIR)
	var dir_err := DirAccess.make_dir_recursive_absolute(cache_dir_absolute)
	if dir_err != OK:
		push_error("[WORLD_PACK] failed to create cache directory %s err=%s" % [PACK_CACHE_DIR, dir_err])
		return false

	var request := HTTPRequest.new()
	request.timeout = 0.0
	request.download_file = cache_path
	add_child(request)

	print("[WORLD_PACK] downloading %s -> %s" % [url, cache_path])
	var request_err := request.request(url)
	if request_err != OK:
		request.queue_free()
		push_error("[WORLD_PACK] failed to request %s err=%s" % [url, request_err])
		return false

	var result = await request.request_completed
	request.queue_free()

	var request_result := int(result[0])
	var response_code := int(result[1])
	if request_result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		push_error("[WORLD_PACK] download failed url=%s result=%s response=%s" % [url, request_result, response_code])
		return false

	return true


func _verify_pack_file(cache_path: String, pack_metadata: Dictionary) -> bool:
	var file := FileAccess.open(cache_path, FileAccess.READ)
	if file == null:
		return false

	var expected_size := int(pack_metadata.get("size", 0))
	if expected_size > 0 and file.get_length() != expected_size:
		file.close()
		push_error("[WORLD_PACK] size mismatch for %s" % cache_path)
		return false
	file.close()

	var expected_sha256 := str(pack_metadata.get("sha256", "")).to_lower()
	if not expected_sha256.is_empty():
		var actual_sha256 := FileAccess.get_sha256(cache_path).to_lower()
		if actual_sha256 != expected_sha256:
			push_error("[WORLD_PACK] sha256 mismatch for %s" % cache_path)
			return false

	return true


func _cache_path(world_key: String, pack_metadata: Dictionary) -> String:
	var version := str(pack_metadata.get("version", "dev"))
	var sha256 := str(pack_metadata.get("sha256", ""))
	var suffix := version
	if not sha256.is_empty():
		suffix = sha256.substr(0, 12)
	return "%s/%s-%s.pck" % [PACK_CACHE_DIR, _safe_path_component(world_key), _safe_path_component(suffix)]


func _safe_path_component(value: String) -> String:
	var safe := value
	for character in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", " "]:
		safe = safe.replace(character, "_")
	return safe
