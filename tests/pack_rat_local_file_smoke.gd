extends Node

const CACHE_DIR: String = "user://pack_rat_local_file_smoke_cache"
const SERVER_DIR: String = "user://pack_rat_local_file_smoke_source"
const USER_PACK_PATH: String = "user://pack_rat_local_file_smoke_source/user_pack.pck"
const USER_ZIP_PATH: String = "user://pack_rat_local_file_smoke_source/user_pack.zip"
const RES_PACK_PATH: String = "res://tests/tmp_pack_rat_local_file_smoke.pck"
const FILE_PACK_PATH: String = "user://pack_rat_local_file_smoke_source/file_pack.pck"
const CANCEL_PACK_PATH: String = "user://pack_rat_local_file_smoke_source/cancel_pack.pck"
const STALE_PACK_PATH: String = "user://pack_rat_local_file_smoke_source/stale_pack.pck"
const USER_MARKER: String = "res://pack_rat_local_file_smoke/user_marker.txt"
const ZIP_MARKER: String = "res://pack_rat_local_file_smoke/zip_marker.txt"
const FILE_MARKER: String = "res://pack_rat_local_file_smoke/file_marker.txt"
const RES_MARKER: String = "res://pack_rat_local_file_smoke/res_marker.txt"
const CANCEL_MARKER: String = "res://pack_rat_local_file_smoke/cancel_marker.txt"
const STALE_MARKER: String = "res://pack_rat_local_file_smoke/stale_marker.txt"


func _ready() -> void:
	_clear_directory(CACHE_DIR)
	_clear_directory(SERVER_DIR)
	_make_directory(SERVER_DIR)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RES_PACK_PATH))

	if not _build_pack(USER_PACK_PATH, USER_MARKER, "user-pack"):
		return
	if not _build_zip(USER_ZIP_PATH, ZIP_MARKER, "zip-pack"):
		return
	if not _build_pack(FILE_PACK_PATH, FILE_MARKER, "file-pack"):
		return
	if not _build_pack(RES_PACK_PATH, RES_MARKER, "res-pack"):
		return
	if not _build_pack(CANCEL_PACK_PATH, CANCEL_MARKER, "cancel-pack", 1024 * 1024):
		return
	if not _build_pack(STALE_PACK_PATH, STALE_MARKER, "stale-old-a"):
		return

	var user_result: PackRatResult = await PackRat.load_resource_pack(USER_PACK_PATH, _options("user-pack"))
	if not _assert_loaded(user_result, USER_MARKER, "user-pack"):
		return

	var zip_result: PackRatResult = await PackRat.load_resource_pack(USER_ZIP_PATH, _options("zip-pack"))
	if not _assert_loaded(zip_result, ZIP_MARKER, "zip-pack"):
		return

	OS.delay_msec(1100)
	if not _build_pack(USER_PACK_PATH, USER_MARKER, "user-pack-updated-with-new-size"):
		return
	var updated_user_result: PackRatResult = await PackRat.load_resource_pack(USER_PACK_PATH, _options("user-pack"))
	if not updated_user_result.ok or updated_user_result.from_cache:
		_fail("Expected changed local source pack to refresh the cache. Result: %s" % JSON.stringify(updated_user_result.to_dictionary()))
		return

	var missing_result: PackRatResult = await PackRat.load_resource_pack(SERVER_DIR.path_join("missing_pack.pck"), _options("missing-pack"))
	if missing_result.ok or not missing_result.error.contains("does not exist"):
		_fail("Expected missing local pack to fail clearly. Result: %s" % JSON.stringify(missing_result.to_dictionary()))
		return

	var file_url: String = "file:///%s" % ProjectSettings.globalize_path(FILE_PACK_PATH).replace("\\", "/")
	var file_result: PackRatResult = await PackRat.load_resource_pack(file_url, _options("file-pack"))
	if not _assert_loaded(file_result, FILE_MARKER, "file-pack"):
		return
	var localhost_file_url: String = file_url.replace("file:///", "file://localhost/")
	if not PackRatLocalFileClient.is_local_pack_source(localhost_file_url):
		_fail("Expected PackRatLocalFileClient to accept file://localhost PCK sources.")
		return

	var res_result: PackRatResult = await PackRat.load_resource_pack(RES_PACK_PATH, _options("res-pack"))
	if not _assert_loaded(res_result, RES_MARKER, "res-pack"):
		return

	if not _prime_stale_expected_metadata_cache():
		return
	if not _build_pack(STALE_PACK_PATH, STALE_MARKER, "stale-new-b"):
		return
	var stale_options: PackRatOptions = _options("stale-pack")
	stale_options.expected_size = FileAccess.get_size(STALE_PACK_PATH)
	var stale_result: PackRatResult = await PackRat.load_resource_pack(STALE_PACK_PATH, stale_options)
	if not _assert_loaded(stale_result, STALE_MARKER, "stale-new-b"):
		return
	if stale_result.from_cache:
		_fail("Expected stale same-cache-path local source to replace the old cached pack.")
		return

	var simulated_options: PackRatOptions = _options("simulated-pack")
	simulated_options.editor_simulated_local_load_seconds = 0.15
	var simulated_start_msec: int = Time.get_ticks_msec()
	var simulated_result: PackRatResult = await PackRat.load_resource_pack(FILE_PACK_PATH, simulated_options)
	var simulated_elapsed_msec: int = Time.get_ticks_msec() - simulated_start_msec
	if not _assert_loaded(simulated_result, FILE_MARKER, "file-pack"):
		return

	if OS.has_feature("editor") and simulated_elapsed_msec < 75:
		_fail("Expected editor_simulated_local_load_seconds to slow local copy progress, got %d ms." % simulated_elapsed_msec)
		return

	var simulated_cache_start_msec: int = Time.get_ticks_msec()
	var simulated_cache_result: PackRatResult = await PackRat.load_resource_pack(FILE_PACK_PATH, simulated_options)
	var simulated_cache_elapsed_msec: int = Time.get_ticks_msec() - simulated_cache_start_msec
	if not simulated_cache_result.ok or not simulated_cache_result.from_cache:
		_fail("Expected simulated local second load to use cache. Result: %s" % JSON.stringify(simulated_cache_result.to_dictionary()))
		return

	if OS.has_feature("editor") and simulated_cache_elapsed_msec > 75:
		_fail("Expected editor_simulated_local_load_seconds not to slow cache hits, got %d ms." % simulated_cache_elapsed_msec)
		return

	var bad_size_options: PackRatOptions = _options("bad-size")
	bad_size_options.expected_size = FileAccess.get_size(USER_PACK_PATH) + 1
	var bad_size_result: PackRatResult = await PackRat.load_resource_pack(USER_PACK_PATH, bad_size_options)
	if bad_size_result.ok or not bad_size_result.error.contains("size mismatch"):
		_fail("Expected local expected_size mismatch to fail. Result: %s" % JSON.stringify(bad_size_result.to_dictionary()))
		return

	var cancel_options: PackRatOptions = _options("cancel-pack")
	cancel_options.download_chunk_size = PackRatOptions.MIN_DOWNLOAD_CHUNK_SIZE
	var request: PackRatRequest = PackRat.load_resource_pack_async(CANCEL_PACK_PATH, cancel_options)
	request.progress_changed.connect(func(downloaded_bytes: int, total_bytes: int) -> void:
		if downloaded_bytes > 0 and downloaded_bytes < total_bytes:
			request.cancel()
	)
	await request.completed
	if request.result.ok or request.result.error != PackRatResult.ERROR_CANCELED:
		_fail("Expected local copy cancellation to fail as canceled. Result: %s" % JSON.stringify(request.result.to_dictionary()))
		return

	DirAccess.remove_absolute(ProjectSettings.globalize_path(RES_PACK_PATH))
	print("PackRat local file smoke passed.")
	get_tree().quit()


func _options(id: String) -> PackRatOptions:
	var options: PackRatOptions = PackRatOptions.new()
	options.id = id
	options.cache_dir = CACHE_DIR
	options.capture_timings = true
	return options


func _assert_loaded(result: PackRatResult, marker_path: String, expected_text: String) -> bool:
	if not result.ok or not result.mounted:
		_fail("Expected local pack to mount. Result: %s" % JSON.stringify(result.to_dictionary()))
		return false

	if FileAccess.get_file_as_string(marker_path).strip_edges() != expected_text:
		_fail("Expected mounted marker %s to equal %s." % [marker_path, expected_text])
		return false

	if not result.local_path.begins_with(CACHE_DIR):
		_fail("Expected local pack to copy into PackRat cache, got %s." % result.local_path)
		return false

	var slash_variant: String = result.local_path.replace("/", "\\")
	if not PackRatMountRegistry.is_mounted_path(slash_variant):
		_fail("Expected mounted path registry to normalize %s." % slash_variant)
		return false

	return true


func _prime_stale_expected_metadata_cache() -> bool:
	var stale_options: PackRatOptions = _options("stale-pack")
	stale_options.expected_size = FileAccess.get_size(STALE_PACK_PATH)
	var metadata: PackRatHttpResponse = PackRatLocalFileClient.metadata(STALE_PACK_PATH)
	if not metadata.ok:
		_fail("Could not read stale local pack metadata: %s." % metadata.error)
		return false

	var stale_key: String = PackRatCachePaths.cache_key(STALE_PACK_PATH, stale_options.id, stale_options)
	var stale_cache_path: String = PackRatCachePaths.local_path(STALE_PACK_PATH, CACHE_DIR, stale_options.id, metadata, stale_options)
	if not _copy_file(STALE_PACK_PATH, stale_cache_path):
		return false

	var stale_result: PackRatResult = PackRatResult.new()
	stale_result.id = stale_options.id
	stale_result.local_path = stale_cache_path
	stale_result.etag = metadata.etag
	stale_result.last_modified = metadata.last_modified
	stale_result.content_length = metadata.content_length
	var cache: PackRatCache = PackRatCache.load(CACHE_DIR)
	cache.set_record(stale_key, PackRatCacheRecord.from_result(STALE_PACK_PATH, stale_cache_path, stale_result, stale_options))
	var save_error: Error = cache.save()
	if save_error != OK:
		_fail("Could not save primed stale local cache (error %d)." % save_error)
		return false

	return true


func _copy_file(source_path: String, target_path: String) -> bool:
	var source_file: FileAccess = FileAccess.open(source_path, FileAccess.READ)
	if source_file == null:
		_fail("Could not open source file for copy: %s." % source_path)
		return false

	var target_file: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
	if target_file == null:
		source_file.close()
		_fail("Could not open target file for copy: %s." % target_path)
		return false

	target_file.store_buffer(source_file.get_buffer(source_file.get_length()))
	source_file.close()
	target_file.close()
	return true


func _build_pack(path: String, marker_path: String, text: String, payload_size: int = 0) -> bool:
	var source_path: String = SERVER_DIR.path_join("%s.txt" % marker_path.get_file().get_basename())
	var source_file: FileAccess = FileAccess.open(source_path, FileAccess.WRITE)
	if source_file == null:
		_fail("Could not create local pack source file: %s." % source_path)
		return false

	source_file.store_buffer(text.to_utf8_buffer())
	if payload_size > 0:
		source_file.store_buffer(PackedByteArray())
		for index in range(payload_size / 1024):
			source_file.store_buffer(("payload-%04d\n" % index).repeat(64).to_utf8_buffer())
	source_file = null

	var packer: PCKPacker = PCKPacker.new()
	var pack_output_path: String = ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	var error: Error = packer.pck_start(pack_output_path)
	if error != OK:
		_fail("Could not start local smoke PCK %s (error %d)." % [path, error])
		return false

	error = packer.add_file(marker_path, source_path)
	if error != OK:
		_fail("Could not add marker to local smoke PCK %s (error %d)." % [path, error])
		return false

	error = packer.flush()
	if error != OK:
		_fail("Could not flush local smoke PCK %s (error %d)." % [path, error])
		return false

	return true


func _build_zip(path: String, marker_path: String, text: String) -> bool:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	var writer: ZIPPacker = ZIPPacker.new()
	var open_error: Error = writer.open(path)
	if open_error != OK:
		_fail("Could not open local smoke ZIP %s (error %d)." % [path, open_error])
		return false

	var start_error: Error = writer.start_file(marker_path.trim_prefix("res://"))
	if start_error != OK:
		_fail("Could not start local smoke ZIP marker %s (error %d)." % [marker_path, start_error])
		writer.close()
		return false

	var write_error: Error = writer.write_file(text.to_utf8_buffer())
	if write_error != OK:
		_fail("Could not write local smoke ZIP marker %s (error %d)." % [marker_path, write_error])
		writer.close()
		return false

	var close_file_error: Error = writer.close_file()
	if close_file_error != OK:
		_fail("Could not close local smoke ZIP marker %s (error %d)." % [marker_path, close_file_error])
		writer.close()
		return false

	var close_error: Error = writer.close()
	if close_error != OK:
		_fail("Could not close local smoke ZIP %s (error %d)." % [path, close_error])
		return false

	return true


func _make_directory(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(path)


func _clear_directory(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return

	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return

	directory.list_dir_begin()
	var name: String = directory.get_next()
	while not name.is_empty():
		var child_path: String = path.path_join(name)
		if directory.current_is_dir():
			_clear_directory(child_path)
			DirAccess.remove_absolute(child_path)
		else:
			DirAccess.remove_absolute(child_path)
		name = directory.get_next()
	directory.list_dir_end()


func _fail(message: String) -> void:
	push_error(message)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RES_PACK_PATH))
	get_tree().quit(1)
