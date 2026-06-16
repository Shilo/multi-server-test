extends Node

const LOCAL_FILE_CLIENT_SCRIPT: GDScript = preload("res://addons/pack_rat/filesystem/pack_rat_local_file_client.gd")

const PACKRAT_SCRIPTS: Array[Script] = [
	preload("res://addons/pack_rat/pack_rat.gd"),
	preload("res://addons/pack_rat/cache/pack_rat_cache.gd"),
	preload("res://addons/pack_rat/cache/pack_rat_cache_files.gd"),
	preload("res://addons/pack_rat/cache/pack_rat_cache_paths.gd"),
	preload("res://addons/pack_rat/cache/pack_rat_cache_record.gd"),
	preload("res://addons/pack_rat/core/pack_rat_options.gd"),
	preload("res://addons/pack_rat/core/pack_rat_request.gd"),
	preload("res://addons/pack_rat/core/pack_rat_result.gd"),
	preload("res://addons/pack_rat/filesystem/pack_rat_file_metadata.gd"),
	preload("res://addons/pack_rat/filesystem/pack_rat_local_file_client.gd"),
	preload("res://addons/pack_rat/request/pack_rat_web_fetch.gd"),
	preload("res://addons/pack_rat/request/pack_rat_web_fetch_bridge.gd"),
	preload("res://addons/pack_rat/request/pack_rat_web_fetch_result.gd"),
	preload("res://addons/pack_rat/request/pack_rat_http_client.gd"),
	preload("res://addons/pack_rat/request/pack_rat_http_response.gd"),
	preload("res://addons/pack_rat/request/pack_rat_request_runner.gd"),
	preload("res://addons/pack_rat/resource_pack/pack_rat_editor_pack_export.gd"),
	preload("res://addons/pack_rat/resource_pack/pack_rat_loader.gd"),
	preload("res://addons/pack_rat/resource_pack/pack_rat_mount_registry.gd"),
]


func _ready() -> void:
	if PACKRAT_SCRIPTS.is_empty():
		_fail("PackRat scripts were not preloaded.")
		return

	var version_setting_key: String = "application/config/version"
	var original_project_version: Variant = ProjectSettings.get_setting(version_setting_key)
	ProjectSettings.set_setting(version_setting_key, "component-version")
	var version_options: PackRatOptions = PackRatOptions.new()
	if version_options.query_version != "component-version":
		_fail("Expected PackRatOptions.query_version to default to the project version.")
		return

	ProjectSettings.set_setting(version_setting_key, "")
	var empty_version_options: PackRatOptions = PackRatOptions.new()
	if not empty_version_options.query_version.is_empty():
		_fail("Expected PackRatOptions.query_version to stay empty when the project version is empty.")
		return

	ProjectSettings.set_setting(version_setting_key, original_project_version)

	var options: PackRatOptions = PackRatOptions.new()
	options.id = "Hub Pack"
	options.entry_path = "res://dlc/hub/main.tscn"
	if options.download_chunk_size != PackRatOptions.DEFAULT_DOWNLOAD_CHUNK_SIZE:
		_fail("Expected PackRatOptions to default to the balanced resource-pack download chunk.")
		return

	if PackRatOptions.DEFAULT_DOWNLOAD_CHUNK_SIZE != PackRatWebFetch.DEFAULT_CHUNK_SIZE:
		_fail("Expected PackRatOptions to share the PackRatWebFetch default chunk size.")
		return

	if not OS.has_feature("web") and PackRatWebFetch.is_available():
		_fail("Expected PackRatWebFetch to be unavailable outside Web exports.")
		return

	if options.capture_timings:
		_fail("Expected PackRatOptions to disable capture_timings by default.")
		return

	if not options.use_web_fetch:
		_fail("Expected PackRatOptions to enable browser fetch by default when available.")
		return

	if not options.accept_gzip:
		_fail("Expected PackRatOptions to accept gzip transfer compression by default.")
		return

	if options.use_threads:
		_fail("Expected PackRatOptions to leave native HTTPRequest threads opt-in.")
		return

	var invalid: PackRatResult = await PackRat.load_resource_pack("not-a-url", options)
	if invalid.ok or invalid.status != PackRatResult.STATUS_FAILED:
		_fail("Expected invalid URL to return a failed result.")
		return

	var metadata_path: String = "user://pack_rat_metadata_component_smoke.bin"
	var file: FileAccess = FileAccess.open(metadata_path, FileAccess.WRITE)
	if file == null:
		_fail("Could not create metadata smoke file.")
		return

	file.store_buffer("packrat".to_utf8_buffer())
	file = null

	var metadata: PackRatFileMetadata = PackRat.file_metadata(metadata_path)
	if not metadata.ok:
		_fail("Expected file_metadata to succeed: %s" % metadata.error)
		return

	if metadata.size != 7:
		_fail("Expected file_metadata size 7, got %d." % metadata.size)
		return

	if metadata.modified_time <= 0:
		_fail("Expected file_metadata modified_time to be positive.")
		return

	var metadata_options: PackRatOptions = PackRatOptions.new()
	metadata.apply_to_options(metadata_options)
	if metadata_options.expected_size != metadata.size:
		_fail("Expected metadata.apply_to_options to copy size.")
		return

	if metadata_options.expected_modified_time != metadata.modified_time:
		_fail("Expected metadata.apply_to_options to copy modified time.")
		return

	var expected_options: PackRatOptions = PackRatOptions.from_expected_metadata(metadata.modified_time, metadata.size)
	if expected_options.expected_modified_time != metadata.modified_time:
		_fail("Expected from_expected_metadata to copy modified time.")
		return

	if expected_options.expected_size != metadata.size:
		_fail("Expected from_expected_metadata to copy size.")
		return

	metadata_options.request_headers.append("X-PackRat-Test: one")
	metadata_options.editor_pack_export_preset = "Warehouse DLC"
	metadata_options.editor_simulated_local_load_seconds = 0.25
	metadata_options.download_chunk_size = 2 * 1024 * 1024
	metadata_options.capture_timings = true
	metadata_options.use_web_fetch = false
	metadata_options.accept_gzip = false
	metadata_options.progress_total_size = 2048
	metadata_options.use_threads = false
	metadata_options.query_version = "build-42"
	metadata_options.query_version_key = "build"
	var copied_options: PackRatOptions = metadata_options.copy()
	metadata_options.cache_dir = "user://changed_after_copy"
	metadata_options.request_headers.append("X-PackRat-Test: two")
	metadata_options.editor_pack_export_preset = "Changed DLC"
	metadata_options.editor_simulated_local_load_seconds = 0.0
	metadata_options.download_chunk_size = 1024
	metadata_options.capture_timings = false
	metadata_options.use_web_fetch = true
	metadata_options.accept_gzip = true
	metadata_options.progress_total_size = 4096
	metadata_options.use_threads = true
	metadata_options.query_version = ""
	metadata_options.query_version_key = "v"
	if copied_options.cache_dir == metadata_options.cache_dir:
		_fail("Expected PackRatOptions.copy to snapshot cache_dir.")
		return

	if copied_options.request_headers.size() != 1:
		_fail("Expected PackRatOptions.copy to duplicate request headers.")
		return

	if copied_options.editor_pack_export_preset != "Warehouse DLC":
		_fail("Expected PackRatOptions.copy to snapshot editor_pack_export_preset.")
		return

	if not is_equal_approx(copied_options.editor_simulated_local_load_seconds, 0.25):
		_fail("Expected PackRatOptions.copy to snapshot editor_simulated_local_load_seconds.")
		return

	if copied_options.download_chunk_size != 2 * 1024 * 1024:
		_fail("Expected PackRatOptions.copy to snapshot download_chunk_size.")
		return

	if not copied_options.capture_timings:
		_fail("Expected PackRatOptions.copy to snapshot capture_timings.")
		return

	if copied_options.use_web_fetch:
		_fail("Expected PackRatOptions.copy to snapshot use_web_fetch.")
		return

	if copied_options.accept_gzip:
		_fail("Expected PackRatOptions.copy to snapshot accept_gzip.")
		return

	if copied_options.progress_total_size != 2048:
		_fail("Expected PackRatOptions.copy to snapshot progress_total_size.")
		return

	if copied_options.use_threads:
		_fail("Expected PackRatOptions.copy to snapshot use_threads.")
		return

	if copied_options.query_version != "build-42":
		_fail("Expected PackRatOptions.copy to snapshot query_version.")
		return

	if copied_options.query_version_key != "build":
		_fail("Expected PackRatOptions.copy to snapshot query_version_key.")
		return

	var gzip_response: PackRatHttpResponse = PackRatHttpResponse.from_completed(
		HTTPRequest.RESULT_SUCCESS,
		200,
		PackedStringArray([
			"Content-Encoding: gzip",
			"Content-Length: 123",
			"Content-Type: application/octet-stream",
		])
	)
	if gzip_response.content_length != 0:
		_fail("Expected gzip Content-Length to be transfer-only metadata.")
		return

	if gzip_response.transfer_content_length != 123:
		_fail("Expected gzip response to preserve transfer Content-Length.")
		return

	var fetch_failure: PackRatWebFetchResult = PackRatWebFetchResult.failed("fetch failed")
	if fetch_failure.ok or fetch_failure.error != "fetch failed":
		_fail("Expected PackRatWebFetchResult.failed to keep a clear error.")
		return

	if PackRatWebFetchResult.ERROR_CANCELED.is_empty():
		_fail("Expected PackRatWebFetchResult to expose a generic cancellation error.")
		return

	var stale_fetch_dir: String = "user://pack_rat_web_fetch_stale_smoke"
	PackRatCacheFiles.ensure_dir(stale_fetch_dir)
	var stale_target_path: String = stale_fetch_dir.path_join("sample.bin")
	var stale_download_path: String = "%s.download-1-2.part" % stale_target_path
	var stale_backup_path: String = "%s.backup-1-2.part" % stale_target_path
	_write_smoke_file(stale_target_path, "current")
	_write_smoke_file(stale_download_path, "stale-download")
	_write_smoke_file(stale_backup_path, "stale-backup")
	PackRatWebFetch._remove_stale_temporary_files(stale_target_path)
	if FileAccess.file_exists(stale_download_path):
		_fail("Expected stale Web fetch download temp file to be removed.")
		return

	if FileAccess.file_exists(stale_backup_path):
		_fail("Expected stale Web fetch backup temp file to be removed when target exists.")
		return

	if _read_smoke_file(stale_target_path) != "current":
		_fail("Expected Web fetch stale cleanup to preserve the target file.")
		return

	DirAccess.remove_absolute(stale_target_path)
	_write_smoke_file(stale_backup_path, "restored-backup")
	PackRatWebFetch._remove_stale_temporary_files(stale_target_path)
	if FileAccess.file_exists(stale_backup_path):
		_fail("Expected orphaned Web fetch backup temp file to be restored into target path.")
		return

	if _read_smoke_file(stale_target_path) != "restored-backup":
		_fail("Expected Web fetch stale cleanup to restore backup file content.")
		return

	var active_download_paths_before: Dictionary = PackRatWebFetch._active_download_paths.duplicate()
	PackRatWebFetch._active_download_paths[stale_target_path] = 2
	PackRatWebFetch._release_active_download_path(stale_target_path)
	if int(PackRatWebFetch._active_download_paths.get(stale_target_path, 0)) != 1:
		_restore_web_fetch_active_paths(active_download_paths_before)
		_fail("Expected active Web fetch download path reference count to decrement.")
		return

	PackRatWebFetch._release_active_download_path(stale_target_path)
	if PackRatWebFetch._active_download_paths.has(stale_target_path):
		_restore_web_fetch_active_paths(active_download_paths_before)
		_fail("Expected active Web fetch download path to be released.")
		return

	_restore_web_fetch_active_paths(active_download_paths_before)
	DirAccess.remove_absolute(stale_target_path)
	DirAccess.remove_absolute(stale_fetch_dir)

	var joined_url: String = PackRat.join_url("https://cdn.example.com/worlds/", "/hub.pck")
	if joined_url != "https://cdn.example.com/worlds/hub.pck":
		_fail("Expected join_url to build a clean URL.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck", "one two") != "https://cdn.example.com/hub.pck?v=one%20two":
		_fail("Expected versioned_url to append the default version query.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck?source=cdn", "42", "pack version") != "https://cdn.example.com/hub.pck?source=cdn&pack%20version=42":
		_fail("Expected versioned_url to append a custom version query.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck?v=old&source=cdn", 42) != "https://cdn.example.com/hub.pck?v=42&source=cdn":
		_fail("Expected versioned_url to replace an existing version query.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck?v=old&source=cdn", 42, "v", false) != "https://cdn.example.com/hub.pck?v=old&source=cdn":
		_fail("Expected versioned_url to preserve an existing version query when replacement is disabled.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck?v=old&v=older", "new") != "https://cdn.example.com/hub.pck?v=new":
		_fail("Expected versioned_url to collapse duplicate version queries.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck#scene", "42") != "https://cdn.example.com/hub.pck?v=42#scene":
		_fail("Expected versioned_url to preserve URL fragments.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck", "") != "https://cdn.example.com/hub.pck":
		_fail("Expected versioned_url to ignore an empty version.")
		return

	if PackRat.versioned_url("https://cdn.example.com/hub.pck", "42", "") != "https://cdn.example.com/hub.pck":
		_fail("Expected versioned_url to ignore an empty version key.")
		return

	var pages_url: String = PackRat.github_pages_url("owner", "repo", "packs/hub world.pck")
	if pages_url != "https://owner.github.io/repo/packs/hub%20world.pck":
		_fail("Expected github_pages_url to build a clean URL, got %s." % pages_url)
		return

	if PackRat.can_download_github_releases() == OS.has_feature("web"):
		_fail("Expected GitHub Release downloads to be unavailable on Web only.")
		return

	var metadata_dict: Dictionary = metadata.to_dictionary()
	if int(metadata_dict.get("size", 0)) != metadata.size:
		_fail("Expected file_metadata dictionary to include size.")
		return

	var missing_metadata: PackRatFileMetadata = PackRat.file_metadata("user://pack_rat_missing_metadata_smoke.bin")
	if missing_metadata.ok or missing_metadata.error.is_empty():
		_fail("Expected missing file_metadata to fail with an error.")
		return

	var scene_result: PackRatResult = PackRatResult.new()
	scene_result.ok = true
	scene_result.entry_path = "res://tests/pack_rat_component_smoke.tscn"
	if not scene_result.entry_scene_exists():
		_fail("Expected entry_scene_exists to find the component smoke scene.")
		return

	if scene_result.load_entry_scene() == null:
		_fail("Expected load_entry_scene to load the component smoke scene.")
		return

	scene_result.entry_path = "res://tests/missing_pack_rat_scene.tscn"
	if scene_result.entry_scene_exists():
		_fail("Expected entry_scene_exists to reject a missing scene.")
		return

	if scene_result.change_scene_to_entry() != ERR_FILE_NOT_FOUND:
		_fail("Expected change_scene_to_entry to reject a missing scene.")
		return

	var unsafe_clear_options: PackRatOptions = PackRatOptions.new()
	unsafe_clear_options.cache_dir = "user://"
	if PackRat.clear_cache(unsafe_clear_options) != ERR_INVALID_PARAMETER:
		_fail("Expected clear_cache to reject root user:// cache dir.")
		return

	unsafe_clear_options.cache_dir = "user://pack_rat/../outside"
	if PackRat.clear_cache(unsafe_clear_options) != ERR_INVALID_PARAMETER:
		_fail("Expected clear_cache to reject parent directory segments.")
		return

	var unsafe_load_options: PackRatOptions = PackRatOptions.new()
	unsafe_load_options.cache_dir = "user://pack_rat/../outside"
	var unsafe_load: PackRatResult = await PackRat.load_resource_pack("https://example.com/hub.pck", unsafe_load_options)
	if unsafe_load.ok or not unsafe_load.error.contains("cache_dir"):
		_fail("Expected load_resource_pack to reject unsafe cache_dir.")
		return

	if not LOCAL_FILE_CLIENT_SCRIPT.is_local_pack_source("file:///C:/packs/hub.pck"):
		_fail("Expected PackRatLocalFileClient to accept file:// PCK sources.")
		return

	if LOCAL_FILE_CLIENT_SCRIPT.is_local_pack_source("file:///C:/packs/hub.txt"):
		_fail("Expected PackRatLocalFileClient to reject non-pack local sources.")
		return

	print("PackRat component smoke passed.")
	get_tree().quit()


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)


func _write_smoke_file(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("Could not write smoke file: %s." % path)
		return

	file.store_buffer(text.to_utf8_buffer())
	file = null


func _read_smoke_file(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("Could not read smoke file: %s." % path)
		return ""

	var text: String = file.get_as_text()
	file = null
	return text


func _restore_web_fetch_active_paths(snapshot: Dictionary) -> void:
	PackRatWebFetch._active_download_paths.clear()
	for path in snapshot.keys():
		PackRatWebFetch._active_download_paths[path] = snapshot[path]
