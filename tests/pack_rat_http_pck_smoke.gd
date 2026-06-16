extends Node

const CACHE_DIR: String = "user://pack_rat_http_pck_smoke_cache"
const SERVER_DIR: String = "user://pack_rat_http_pck_smoke_server"
const PACK_PATH: String = "user://pack_rat_http_pck_smoke_server/hub.pck"
const SOURCE_PATH: String = "user://pack_rat_http_pck_smoke_server/marker.txt"
const SCENE_SOURCE_PATH: String = "user://pack_rat_http_pck_smoke_server/mmo_world.tscn"
const RANDOM_SOURCE_PATH: String = "user://pack_rat_http_pck_smoke_server/random.bin"
const MOUNTED_MARKER: String = "res://pack_rat_http_pck_smoke/marker.txt"
const MMO_SCENE_PATH: String = "res://server/worlds/mmo_world/mmo_world.tscn"
const RANDOM_PACK_PATH: String = "res://pack_rat_http_pck_smoke/random.bin"
const MODIFIED_V2_UNIX: int = 1781122560
const MODIFIED_V3_UNIX: int = 1781122620
const SLOW_RESPONSE_CHUNK_SIZE: int = 4096

var _server: TCPServer = TCPServer.new()
var _pack_bytes: PackedByteArray = []
var _gzip_pack_bytes: PackedByteArray = []
var _url: String = ""
var _gzip_url: String = ""
var _head_count: int = 0
var _get_count: int = 0
var _etag: String = "\"packrat-smoke-v1\""
var _last_modified: String = "Wed, 10 Jun 2026 20:15:00 GMT"
var _fail_get: bool = false
var _omit_last_modified: bool = false
var _require_header: bool = false
var _active_peers: int = 0
var _last_head_path: String = ""
var _last_get_path: String = ""


func _new_options() -> PackRatOptions:
	var options: PackRatOptions = PackRatOptions.new()
	options.use_threads = false
	return options


func _ready() -> void:
	set_process(false)
	_clear_directory(CACHE_DIR)
	_clear_directory(SERVER_DIR)
	_make_directory(SERVER_DIR)
	_build_pack("mounted-from-packrat")

	var listen_error: Error = _server.listen(0, "127.0.0.1")
	if listen_error != OK:
		_fail("Could not start local HTTP server (error %d)." % listen_error)
		return

	_url = "http://127.0.0.1:%d/hub.pck" % _server.get_local_port()
	_gzip_url = "http://127.0.0.1:%d/hub-gzip.pck" % _server.get_local_port()
	set_process(true)
	await get_tree().process_frame

	var options: PackRatOptions = _new_options()
	options.id = "http_pck_smoke"
	options.cache_dir = CACHE_DIR
	options.entry_path = MOUNTED_MARKER
	options.timeout_seconds = 10.0
	options.capture_timings = true

	var first: PackRatResult = await PackRat.load_resource_pack(_url, options)
	if not first.ok or not first.mounted or first.from_cache:
		_fail("Expected first load to download and mount. Result: %s" % JSON.stringify(first.to_dictionary()))
		return
	if not _assert_download_timings(first):
		return

	if first.local_path.get_base_dir() != CACHE_DIR:
		_fail("Expected flat cache path under %s, got %s." % [CACHE_DIR, first.local_path])
		return

	if DirAccess.dir_exists_absolute(CACHE_DIR.path_join(options.id)):
		_fail("Expected flat cache to avoid per-id directory %s." % CACHE_DIR.path_join(options.id))
		return

	if FileAccess.get_file_as_string(MOUNTED_MARKER).strip_edges() != "mounted-from-packrat":
		_fail("Mounted PCK marker was not readable from res://.")
		return

	var gzip_options: PackRatOptions = options.copy()
	gzip_options.id = "http_pck_gzip_smoke"
	gzip_options.expected_size = _pack_bytes.size()
	var gzip_result: PackRatResult = await PackRat.load_resource_pack(_gzip_url, gzip_options)
	if not gzip_result.ok or gzip_result.from_cache:
		_fail("Expected gzip transfer PCK to download and mount. Result: %s" % JSON.stringify(gzip_result.to_dictionary()))
		return

	if FileAccess.get_size(gzip_result.local_path) != _pack_bytes.size():
		_fail("Expected gzip transfer to cache decoded raw PCK bytes.")
		return

	if gzip_result.content_length != _pack_bytes.size():
		_fail("Expected gzip transfer result to report decoded pack size.")
		return

	var bad_gzip_size_options: PackRatOptions = gzip_options.copy()
	bad_gzip_size_options.id = "http_pck_gzip_bad_size_smoke"
	bad_gzip_size_options.expected_size = _pack_bytes.size() + 1
	var bad_gzip_size_result: PackRatResult = await PackRat.load_resource_pack(_gzip_url, bad_gzip_size_options)
	if bad_gzip_size_result.ok:
		_fail("Expected gzip transfer with wrong expected_size to fail.")
		return

	if bad_gzip_size_result.content_length != _pack_bytes.size():
		_fail("Expected gzip expected_size failure to report decoded pack size.")
		return

	var second: PackRatResult = await PackRat.load_resource_pack(_url, options)
	if not second.ok or not second.from_cache or not second.mounted:
		_fail("Expected second load to mount from cache. Result: %s" % JSON.stringify(second.to_dictionary()))
		return
	if not _assert_mount_timings(second):
		return

	if _get_count != 3:
		_fail("Expected three GET downloads after gzip smokes, got %d." % _get_count)
		return

	if _head_count != 1:
		_fail("Expected one freshness HEAD request for cache hit, got %d." % _head_count)
		return

	var cached_cancel_request: PackRatRequest = PackRat.load_resource_pack_async(_url, options)
	cached_cancel_request.cancel()
	await cached_cancel_request.completed
	if cached_cancel_request.result == null or cached_cancel_request.result.ok:
		_fail("Expected cancel before cached load to fail without mounting.")
		return

	var corrupt_cache_file: FileAccess = FileAccess.open(second.local_path, FileAccess.WRITE)
	if corrupt_cache_file == null:
		_fail("Could not corrupt cached pack for mount recovery test.")
		return
	corrupt_cache_file.store_string("not a pack")
	corrupt_cache_file = null

	var corrupt_rejected: PackRatResult = await PackRat.load_resource_pack(_url, options)
	if corrupt_rejected.ok:
		_fail("Expected corrupted cache mount to fail before recovery.")
		return

	var recovered: PackRatResult = await PackRat.load_resource_pack(_url, options)
	if not recovered.ok or recovered.from_cache:
		_fail("Expected corrupted cache to recover with a fresh download. Result: %s" % JSON.stringify(recovered.to_dictionary()))
		return

	var stale_get_count: int = _get_count

	var first_cache_path: String = first.local_path
	_etag = "\"packrat-smoke-v2\""
	_last_modified = "Wed, 10 Jun 2026 20:16:00 GMT"
	_build_pack("mounted-from-packrat-version-two")

	var third: PackRatResult = await PackRat.load_resource_pack(_url, options)
	if not third.ok or third.from_cache:
		_fail("Expected changed ETag to redownload. Result: %s" % JSON.stringify(third.to_dictionary()))
		return

	if third.local_path.get_base_dir() != CACHE_DIR:
		_fail("Expected stale redownload to keep flat cache path, got %s." % third.local_path)
		return

	if third.local_path == first_cache_path:
		_fail("Expected stale redownload to use a new cache path, got %s." % third.local_path)
		return

	if _get_count != stale_get_count + 1:
		_fail("Expected stale redownload to perform a second GET, got %d." % _get_count)
		return

	var metadata_head_count: int = _head_count
	var metadata_get_count: int = _get_count
	var size_options: PackRatOptions = _new_options()
	size_options.id = "size_metadata_smoke"
	size_options.cache_dir = CACHE_DIR
	size_options.entry_path = MOUNTED_MARKER
	size_options.timeout_seconds = 10.0
	size_options.expected_size = _pack_bytes.size()

	var size_first: PackRatResult = await PackRat.load_resource_pack(_url, size_options)
	if not size_first.ok or size_first.from_cache:
		_fail("Expected size-only metadata load to download. Result: %s" % JSON.stringify(size_first.to_dictionary()))
		return

	if _head_count != metadata_head_count:
		_fail("Expected size-only metadata load to skip HEAD, got %d new HEAD requests." % (_head_count - metadata_head_count))
		return

	if _get_count != metadata_get_count + 1:
		_fail("Expected size-only metadata load to download once, got %d new GET requests." % (_get_count - metadata_get_count))
		return

	var size_second: PackRatResult = await PackRat.load_resource_pack(_url, size_options)
	if not size_second.ok or not size_second.from_cache:
		_fail("Expected size-only metadata load to reuse cache. Result: %s" % JSON.stringify(size_second.to_dictionary()))
		return

	if _head_count != metadata_head_count or _get_count != metadata_get_count + 1:
		_fail("Expected size-only metadata cache hit to skip HEAD and GET.")
		return

	var normalized_clear_options: PackRatOptions = size_options.copy()
	normalized_clear_options.cache_dir = "%s/" % CACHE_DIR
	var normalized_clear_error: Error = PackRat.clear_cached_resource_pack(size_options.id, normalized_clear_options)
	if normalized_clear_error != OK:
		_fail("Expected normalized clear_cached_resource_pack to succeed, got error %d." % normalized_clear_error)
		return

	var size_after_clear: PackRatResult = await PackRat.load_resource_pack(_url, size_options)
	if not size_after_clear.ok or size_after_clear.from_cache:
		_fail("Expected normalized clear to invalidate fast cache and force redownload. Result: %s" % JSON.stringify(size_after_clear.to_dictionary()))
		return

	if _get_count != metadata_get_count + 2:
		_fail("Expected normalized clear to add one GET request.")
		return

	var fast_cancel_request: PackRatRequest = PackRat.load_resource_pack_async(_url, size_options)
	fast_cancel_request.cancel()
	await fast_cancel_request.completed
	if fast_cancel_request.result == null or fast_cancel_request.result.ok:
		_fail("Expected fast cache async cancel to fail before completion.")
		return

	if _head_count != metadata_head_count or _get_count != metadata_get_count + 2:
		_fail("Expected fast cache async cancel to avoid HEAD and GET.")
		return

	var repeated_cache_start_usec: int = Time.get_ticks_usec()
	for index in range(50):
		var repeated_cache: PackRatResult = await PackRat.load_resource_pack(_url, size_options)
		if not repeated_cache.ok or not repeated_cache.from_cache:
			_fail("Expected repeated expected_size cache hit %d to reuse cache." % index)
			return

	var repeated_cache_elapsed_usec: int = Time.get_ticks_usec() - repeated_cache_start_usec
	if _head_count != metadata_head_count or _get_count != metadata_get_count + 2:
		_fail("Expected repeated expected_size cache hits to avoid HEAD and GET.")
		return

	var corrupt_file: FileAccess = FileAccess.open(size_after_clear.local_path, FileAccess.WRITE)
	if corrupt_file == null:
		_fail("Could not corrupt cached pack for expected_size validation test.")
		return
	corrupt_file.store_string("bad-cache")
	corrupt_file = null

	var size_third: PackRatResult = await PackRat.load_resource_pack(_url, size_options)
	if not size_third.ok or size_third.from_cache:
		_fail("Expected corrupted expected_size cache hit to redownload. Result: %s" % JSON.stringify(size_third.to_dictionary()))
		return

	if _get_count != metadata_get_count + 3:
		_fail("Expected corrupted expected_size cache hit to add one GET request.")
		return

	var modified_options: PackRatOptions = _new_options()
	modified_options.id = "modified_metadata_smoke"
	modified_options.cache_dir = CACHE_DIR
	modified_options.entry_path = MOUNTED_MARKER
	modified_options.timeout_seconds = 10.0
	modified_options.expected_modified_time = MODIFIED_V2_UNIX

	var modified_first: PackRatResult = await PackRat.load_resource_pack(_url, modified_options)
	if not modified_first.ok or modified_first.from_cache:
		_fail("Expected modified-time-only metadata load to download. Result: %s" % JSON.stringify(modified_first.to_dictionary()))
		return

	var both_options: PackRatOptions = _new_options()
	both_options.id = "both_metadata_smoke"
	both_options.cache_dir = CACHE_DIR
	both_options.entry_path = MOUNTED_MARKER
	both_options.timeout_seconds = 10.0
	both_options.expected_size = _pack_bytes.size()
	both_options.expected_modified_time = MODIFIED_V2_UNIX

	var both_first: PackRatResult = await PackRat.load_resource_pack(_url, both_options)
	if not both_first.ok or both_first.from_cache:
		_fail("Expected both metadata fields to validate together. Result: %s" % JSON.stringify(both_first.to_dictionary()))
		return

	var metadata_cache_path: String = both_first.local_path
	_last_modified = "Wed, 10 Jun 2026 20:17:00 GMT"
	_build_pack("metadata-version-two")
	both_options.expected_size = _pack_bytes.size()
	both_options.expected_modified_time = MODIFIED_V3_UNIX
	var metadata_third: PackRatResult = await PackRat.load_resource_pack(_url, both_options)
	if not metadata_third.ok or metadata_third.from_cache:
		_fail("Expected changed expected metadata to download. Result: %s" % JSON.stringify(metadata_third.to_dictionary()))
		return

	if metadata_third.local_path == metadata_cache_path:
		_fail("Expected changed expected metadata to use a new cache path.")
		return

	var bad_size_options: PackRatOptions = _new_options()
	bad_size_options.id = "bad_size_metadata_smoke"
	bad_size_options.cache_dir = CACHE_DIR
	bad_size_options.timeout_seconds = 10.0
	bad_size_options.expected_size = _pack_bytes.size() + 1
	var bad_size: PackRatResult = await PackRat.load_resource_pack(_url, bad_size_options)
	if bad_size.ok:
		_fail("Expected expected_size mismatch to fail.")
		return
	if bad_size.content_length != _pack_bytes.size():
		_fail("Expected expected_size mismatch result to preserve downloaded size.")
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected expected_size validation failure to remove .part files.")
		return

	var too_small_size_options: PackRatOptions = _new_options()
	too_small_size_options.id = "too_small_size_metadata_smoke"
	too_small_size_options.cache_dir = CACHE_DIR
	too_small_size_options.timeout_seconds = 10.0
	too_small_size_options.expected_size = 1
	var too_small_size: PackRatResult = await PackRat.load_resource_pack(_url, too_small_size_options)
	if too_small_size.ok:
		_fail("Expected too-small expected_size to fail during download.")
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected too-small expected_size failure to remove .part files.")
		return

	var bad_modified_options: PackRatOptions = _new_options()
	bad_modified_options.id = "bad_modified_metadata_smoke"
	bad_modified_options.cache_dir = CACHE_DIR
	bad_modified_options.timeout_seconds = 10.0
	bad_modified_options.expected_modified_time = MODIFIED_V2_UNIX
	var bad_modified: PackRatResult = await PackRat.load_resource_pack(_url, bad_modified_options)
	if bad_modified.ok:
		_fail("Expected expected_modified_time mismatch to fail.")
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected expected_modified_time validation failure to remove .part files.")
		return

	_omit_last_modified = true
	var stat_metadata: PackRatFileMetadata = PackRat.file_metadata(PACK_PATH)
	if not stat_metadata.ok:
		_fail("Expected file_metadata for local PCK to succeed: %s" % stat_metadata.error)
		return

	var stat_head_count: int = _head_count
	var stat_get_count: int = _get_count
	var stat_options: PackRatOptions = _new_options()
	stat_options.id = "stat_metadata_smoke"
	stat_options.cache_dir = CACHE_DIR
	stat_options.entry_path = MOUNTED_MARKER
	stat_options.timeout_seconds = 10.0
	stat_metadata.apply_to_options(stat_options)

	var stat_first: PackRatResult = await PackRat.load_resource_pack(_url, stat_options)
	if not stat_first.ok or stat_first.from_cache:
		_fail("Expected local stat metadata load to download. Result: %s" % JSON.stringify(stat_first.to_dictionary()))
		return

	if not _has_warning(stat_first, "Last-Modified"):
		_fail("Expected local stat metadata load without Last-Modified to warn. Result: %s" % JSON.stringify(stat_first.to_dictionary()))
		return

	var stat_second: PackRatResult = await PackRat.load_resource_pack(_url, stat_options)
	if not stat_second.ok or not stat_second.from_cache:
		_fail("Expected local stat metadata load to reuse cache. Result: %s" % JSON.stringify(stat_second.to_dictionary()))
		return

	if _head_count != stat_head_count or _get_count != stat_get_count + 1:
		_fail("Expected local stat metadata cache hit to skip HEAD and GET.")
		return

	_omit_last_modified = false

	var offline_head_count: int = _head_count
	var offline_get_count: int = _get_count
	var offline_options: PackRatOptions = _new_options()
	offline_options.id = "offline_smoke"
	offline_options.cache_dir = CACHE_DIR
	offline_options.entry_path = MOUNTED_MARKER
	offline_options.timeout_seconds = 10.0
	offline_options.offline_first = true

	var offline_first: PackRatResult = await PackRat.load_resource_pack(_url, offline_options)
	if not offline_first.ok or offline_first.from_cache:
		_fail("Expected offline-first cache miss to download. Result: %s" % JSON.stringify(offline_first.to_dictionary()))
		return

	var offline_second: PackRatResult = await PackRat.load_resource_pack(_url, offline_options)
	if not offline_second.ok or not offline_second.from_cache:
		_fail("Expected offline-first cache hit to reuse cache. Result: %s" % JSON.stringify(offline_second.to_dictionary()))
		return

	if _head_count != offline_head_count or _get_count != offline_get_count + 1:
		_fail("Expected offline-first to skip HEAD and only download on miss.")
		return

	var mutation_options: PackRatOptions = _new_options()
	mutation_options.id = "mutation_smoke"
	mutation_options.cache_dir = CACHE_DIR
	mutation_options.entry_path = MOUNTED_MARKER
	mutation_options.timeout_seconds = 10.0
	var mutation_request: PackRatRequest = PackRat.load_resource_pack_async(_url, mutation_options)
	mutation_options.id = "mutated_after_start"
	mutation_options.cache_dir = "user://pack_rat_mutated_after_start"
	await mutation_request.completed
	if not mutation_request.result.ok or mutation_request.result.id != "mutation_smoke":
		_fail("Expected async request to snapshot options before caller mutation. Result: %s" % JSON.stringify(mutation_request.result.to_dictionary()))
		return

	var version_setting_key: String = "application/config/version"
	var original_project_version: Variant = ProjectSettings.get_setting(version_setting_key)
	ProjectSettings.set_setting(version_setting_key, "0.7 smoke")

	var auto_version_options: PackRatOptions = _new_options()
	auto_version_options.id = "auto_project_version_smoke"
	auto_version_options.cache_dir = CACHE_DIR
	auto_version_options.timeout_seconds = 10.0
	auto_version_options.expected_size = _pack_bytes.size()
	_reset_request_paths()
	var auto_version_first: PackRatResult = await PackRat.load_resource_pack(_url, auto_version_options)
	if not auto_version_first.ok or auto_version_first.from_cache:
		_fail("Expected auto project version URL load to download. Result: %s" % JSON.stringify(auto_version_first.to_dictionary()))
		return

	if _last_get_path != "/hub.pck?v=0.7%20smoke":
		_fail("Expected auto project version query on GET, got %s." % _last_get_path)
		return

	var auto_version_key: String = PackRatCachePaths.cache_key(_url, auto_version_options.id, auto_version_options)
	var auto_version_record: PackRatCacheRecord = PackRatCache.load(CACHE_DIR).record(auto_version_key)
	if auto_version_record.source_url != _url:
		_fail("Expected auto project version query to leave cache record source_url unchanged, got %s." % auto_version_record.source_url)
		return

	ProjectSettings.set_setting(version_setting_key, "0.8")
	var auto_version_second_options: PackRatOptions = _new_options()
	auto_version_second_options.id = "auto_project_version_smoke"
	auto_version_second_options.cache_dir = CACHE_DIR
	auto_version_second_options.timeout_seconds = 10.0
	auto_version_second_options.expected_size = _pack_bytes.size()
	var auto_version_head_count: int = _head_count
	var auto_version_get_count: int = _get_count
	_reset_request_paths()
	var auto_version_second: PackRatResult = await PackRat.load_resource_pack(_url, auto_version_second_options)
	if not auto_version_second.ok or not auto_version_second.from_cache:
		_fail("Expected changed project version query to keep the same cache identity. Result: %s" % JSON.stringify(auto_version_second.to_dictionary()))
		return

	if _head_count != auto_version_head_count or _get_count != auto_version_get_count:
		_fail("Expected changed project version query to avoid extra HEAD and GET requests.")
		return

	if not _last_head_path.is_empty() or not _last_get_path.is_empty():
		_fail("Expected fast cache hit to avoid recording request paths after project version changed.")
		return

	var custom_query_options: PackRatOptions = _new_options()
	custom_query_options.id = "auto_project_version_custom_query_smoke"
	custom_query_options.cache_dir = CACHE_DIR
	custom_query_options.timeout_seconds = 10.0
	custom_query_options.expected_size = _pack_bytes.size()
	var custom_query_url: String = "%s?x=1&v=custom#scene" % _url
	_reset_request_paths()
	var custom_query_result: PackRatResult = await PackRat.load_resource_pack(custom_query_url, custom_query_options)
	if not custom_query_result.ok:
		_fail("Expected existing project version query to stay valid. Result: %s" % JSON.stringify(custom_query_result.to_dictionary()))
		return

	if _last_get_path != "/hub.pck?x=1&v=custom":
		_fail("Expected existing project version query to stay unchanged, got %s." % _last_get_path)
		return

	var manual_version_options: PackRatOptions = _new_options()
	manual_version_options.id = "manual_version_smoke"
	manual_version_options.cache_dir = CACHE_DIR
	manual_version_options.timeout_seconds = 10.0
	manual_version_options.expected_size = _pack_bytes.size()
	manual_version_options.query_version = "manual smoke"
	manual_version_options.query_version_key = "build"
	var manual_version_url: String = "%s?x=1#scene" % _url
	_reset_request_paths()
	var manual_version_result: PackRatResult = await PackRat.load_resource_pack(manual_version_url, manual_version_options)
	if not manual_version_result.ok:
		_fail("Expected manual request version to load. Result: %s" % JSON.stringify(manual_version_result.to_dictionary()))
		return

	if _last_get_path != "/hub.pck?x=1&build=manual%20smoke":
		_fail("Expected manual request version query, got %s." % _last_get_path)
		return

	ProjectSettings.set_setting(version_setting_key, "0.9")
	var auto_version_head_options: PackRatOptions = _new_options()
	auto_version_head_options.id = "auto_project_version_head_smoke"
	auto_version_head_options.cache_dir = CACHE_DIR
	auto_version_head_options.timeout_seconds = 10.0
	var auto_version_head_first: PackRatResult = await PackRat.load_resource_pack(_url, auto_version_head_options)
	if not auto_version_head_first.ok or auto_version_head_first.from_cache:
		_fail("Expected HEAD auto project version setup load to download. Result: %s" % JSON.stringify(auto_version_head_first.to_dictionary()))
		return

	_reset_request_paths()
	var auto_version_head_second: PackRatResult = await PackRat.load_resource_pack(_url, auto_version_head_options)
	if not auto_version_head_second.ok or not auto_version_head_second.from_cache:
		_fail("Expected HEAD auto project version second load to reuse cache. Result: %s" % JSON.stringify(auto_version_head_second.to_dictionary()))
		return

	if _last_head_path != "/hub.pck?v=0.9":
		_fail("Expected auto project version query on HEAD, got %s." % _last_head_path)
		return

	ProjectSettings.set_setting(version_setting_key, "")
	var empty_version_options: PackRatOptions = _new_options()
	empty_version_options.id = "auto_project_version_empty_smoke"
	empty_version_options.cache_dir = CACHE_DIR
	empty_version_options.timeout_seconds = 10.0
	empty_version_options.expected_size = _pack_bytes.size()
	var empty_version_url: String = "%s?x=1" % _url
	_reset_request_paths()
	var empty_version_result: PackRatResult = await PackRat.load_resource_pack(empty_version_url, empty_version_options)
	if not empty_version_result.ok:
		_fail("Expected empty project version to skip query injection. Result: %s" % JSON.stringify(empty_version_result.to_dictionary()))
		return

	if _last_get_path != "/hub.pck?x=1":
		_fail("Expected empty project version to leave URL unchanged, got %s." % _last_get_path)
		return

	ProjectSettings.set_setting(version_setting_key, original_project_version)

	var concurrent_head_count: int = _head_count
	var concurrent_get_count: int = _get_count
	var concurrent_options: PackRatOptions = _new_options()
	concurrent_options.id = "concurrent_smoke"
	concurrent_options.cache_dir = CACHE_DIR
	concurrent_options.entry_path = MOUNTED_MARKER
	concurrent_options.timeout_seconds = 10.0
	concurrent_options.expected_size = _pack_bytes.size()
	concurrent_options.expected_modified_time = MODIFIED_V3_UNIX
	var concurrent_results: Array[PackRatResult] = []
	_collect_load(concurrent_options, concurrent_results)
	_collect_load(concurrent_options, concurrent_results)

	var wait_until: int = Time.get_ticks_msec() + 3000
	while concurrent_results.size() < 2 and Time.get_ticks_msec() < wait_until:
		await get_tree().process_frame

	if concurrent_results.size() != 2:
		_fail("Timed out waiting for concurrent load results.")
		return

	for index in range(concurrent_results.size()):
		var concurrent_result: PackRatResult = concurrent_results[index]
		if not concurrent_result.ok:
			_fail("Expected concurrent load to succeed. Result: %s" % JSON.stringify(concurrent_result.to_dictionary()))
			return

	if _head_count != concurrent_head_count or _get_count != concurrent_get_count + 2:
		_fail("Expected concurrent loads to use independent downloads without HEAD requests.")
		return

	var progress_options: PackRatOptions = _new_options()
	progress_options.id = "progress_smoke"
	progress_options.cache_dir = CACHE_DIR
	progress_options.entry_path = MOUNTED_MARKER
	progress_options.timeout_seconds = 10.0
	var slow_url: String = "http://127.0.0.1:%d/slow.pck" % _server.get_local_port()
	var progress_events: Array[int] = [0]
	var progress_downloaded: Array[int] = []
	var progress_totals: Array[int] = []
	var progress_request: PackRatRequest = PackRat.load_resource_pack_async(slow_url, progress_options)
	progress_request.progress_changed.connect(func(downloaded_bytes: int, total_bytes: int) -> void:
		progress_events[0] += 1
		progress_downloaded.append(downloaded_bytes)
		progress_totals.append(total_bytes)
	)
	await progress_request.completed
	if progress_request.result == null:
		_fail("Expected async load to produce a result.")
		return

	if not progress_request.result.ok:
		_fail("Expected async load to succeed. Result: %s" % JSON.stringify(progress_request.result.to_dictionary()))
		return

	if progress_events[0] <= 0:
		_fail("Expected async load to emit progress_changed at least once.")
		return

	if (
		progress_downloaded[progress_downloaded.size() - 1] != _pack_bytes.size()
		or progress_totals[progress_totals.size() - 1] != _pack_bytes.size()
	):
		_fail("Expected async load to emit final complete progress, got %d/%d." % [
			progress_downloaded[progress_downloaded.size() - 1],
			progress_totals[progress_totals.size() - 1],
		])
		return

	var expected_progress_options: PackRatOptions = _new_options()
	expected_progress_options.id = "expected_progress_smoke"
	expected_progress_options.cache_dir = CACHE_DIR
	expected_progress_options.entry_path = MOUNTED_MARKER
	expected_progress_options.timeout_seconds = 10.0
	expected_progress_options.expected_size = _pack_bytes.size()
	var expected_progress_url: String = "http://127.0.0.1:%d/slow-no-length.pck" % _server.get_local_port()
	var expected_progress_downloaded: Array[int] = []
	var expected_progress_totals: Array[int] = []
	var expected_progress_request: PackRatRequest = PackRat.load_resource_pack_async(expected_progress_url, expected_progress_options)
	expected_progress_request.progress_changed.connect(func(downloaded_bytes: int, total_bytes: int) -> void:
		expected_progress_downloaded.append(downloaded_bytes)
		expected_progress_totals.append(total_bytes)
	)
	await expected_progress_request.completed
	if expected_progress_request.result == null:
		_fail("Expected expected-size progress load to produce a result.")
		return

	if not expected_progress_request.result.ok:
		_fail("Expected expected-size progress load to succeed. Result: %s" % JSON.stringify(expected_progress_request.result.to_dictionary()))
		return

	if expected_progress_totals.is_empty() or expected_progress_totals[0] != _pack_bytes.size():
		_fail("Expected progress to use expected_size when Content-Length is unavailable.")
		return

	if (
		expected_progress_downloaded[expected_progress_downloaded.size() - 1] != _pack_bytes.size()
		or expected_progress_totals[expected_progress_totals.size() - 1] != _pack_bytes.size()
	):
		_fail("Expected expected-size progress to finish complete, got %d/%d." % [
			expected_progress_downloaded[expected_progress_downloaded.size() - 1],
			expected_progress_totals[expected_progress_totals.size() - 1],
		])
		return

	var hinted_progress_options: PackRatOptions = _new_options()
	hinted_progress_options.id = "hinted_progress_smoke"
	hinted_progress_options.cache_dir = CACHE_DIR
	hinted_progress_options.entry_path = MOUNTED_MARKER
	hinted_progress_options.timeout_seconds = 10.0
	hinted_progress_options.progress_total_size = _pack_bytes.size()
	var hinted_progress_downloaded: Array[int] = []
	var hinted_progress_totals: Array[int] = []
	var hinted_progress_request: PackRatRequest = PackRat.load_resource_pack_async(expected_progress_url, hinted_progress_options)
	hinted_progress_request.progress_changed.connect(func(downloaded_bytes: int, total_bytes: int) -> void:
		hinted_progress_downloaded.append(downloaded_bytes)
		hinted_progress_totals.append(total_bytes)
	)
	await hinted_progress_request.completed
	if hinted_progress_request.result == null:
		_fail("Expected progress-size hint load to produce a result.")
		return

	if not hinted_progress_request.result.ok:
		_fail("Expected progress-size hint load to succeed. Result: %s" % JSON.stringify(hinted_progress_request.result.to_dictionary()))
		return

	if hinted_progress_totals.is_empty() or hinted_progress_totals[0] != _pack_bytes.size():
		_fail("Expected progress to use progress_total_size when Content-Length is unavailable.")
		return

	if (
		hinted_progress_downloaded[hinted_progress_downloaded.size() - 1] != _pack_bytes.size()
		or hinted_progress_totals[hinted_progress_totals.size() - 1] != _pack_bytes.size()
	):
		_fail("Expected hinted progress to finish complete, got %d/%d." % [
			hinted_progress_downloaded[hinted_progress_downloaded.size() - 1],
			hinted_progress_totals[hinted_progress_totals.size() - 1],
		])
		return

	await get_tree().process_frame
	if _packrat_request_runner_count() != 0:
		_fail("Expected PackRatRequestRunner to free itself after async completion.")
		return

	var cancel_options: PackRatOptions = _new_options()
	cancel_options.id = "cancel_smoke"
	cancel_options.cache_dir = CACHE_DIR
	cancel_options.timeout_seconds = 10.0
	var cancel_seen: Array[bool] = [false]
	var cancel_request: PackRatRequest = PackRat.load_resource_pack_async(slow_url, cancel_options)
	cancel_request.canceled.connect(func() -> void:
		cancel_seen[0] = true
	)
	await get_tree().process_frame
	cancel_request.cancel()
	await cancel_request.completed
	if cancel_request.result == null:
		_fail("Expected canceled async load to produce a result.")
		return

	if cancel_request.result.ok:
		_fail("Expected canceled async load to fail.")
		return

	if not cancel_seen[0]:
		_fail("Expected canceled async load to emit canceled.")
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected canceled async load to remove .part files.")
		return

	await get_tree().process_frame
	if _packrat_request_runner_count() != 0:
		_fail("Expected PackRatRequestRunner to free itself after async cancellation.")
		return

	var extensionless_options: PackRatOptions = _new_options()
	extensionless_options.id = "extensionless_smoke"
	extensionless_options.cache_dir = CACHE_DIR
	extensionless_options.entry_path = MOUNTED_MARKER
	extensionless_options.timeout_seconds = 10.0
	var extensionless_url: String = "http://127.0.0.1:%d/download?id=hub" % _server.get_local_port()
	var extensionless: PackRatResult = await PackRat.load_resource_pack(extensionless_url, extensionless_options)
	if not extensionless.ok or not extensionless.mounted:
		_fail("Expected extensionless PCK URL to download and mount. Result: %s" % JSON.stringify(extensionless.to_dictionary()))
		return

	if extensionless.local_path.get_extension().to_lower() != "pck":
		_fail("Expected extensionless PCK URL to receive a .pck cache path, got %s." % extensionless.local_path)
		return

	if extensionless.local_path.get_base_dir() != CACHE_DIR:
		_fail("Expected extensionless PCK URL to use flat cache path, got %s." % extensionless.local_path)
		return

	var clear_item_error: Error = PackRat.clear_cached_resource_pack(extensionless_options.id, extensionless_options)
	if clear_item_error != OK:
		_fail("Expected clear_cached_resource_pack by ID to succeed, got error %d." % clear_item_error)
		return

	if _cache_json_contains(extensionless.local_path):
		_fail("Expected clear_cached_resource_pack to remove cache record for %s." % extensionless.local_path)
		return

	var missing_clear_error: Error = PackRat.clear_cached_resource_pack("missing-pack", extensionless_options)
	if missing_clear_error != ERR_DOES_NOT_EXIST:
		_fail("Expected missing clear_cached_resource_pack to return ERR_DOES_NOT_EXIST, got %d." % missing_clear_error)
		return

	var github_latest_url: String = PackRat.github_release_url("owner", "repo", "hub.pck")
	if github_latest_url != "https://github.com/owner/repo/releases/latest/download/hub.pck":
		_fail("Unexpected latest GitHub release URL: %s" % github_latest_url)
		return

	var github_tag_url: String = PackRat.github_release_url("owner", "repo", "hub.pck", "v1.2.3")
	if github_tag_url != "https://github.com/owner/repo/releases/download/v1.2.3/hub.pck":
		_fail("Unexpected tagged GitHub release URL: %s" % github_tag_url)
		return

	var github_pages_url: String = PackRat.github_pages_url("owner", "repo", "packs/hub.pck")
	if github_pages_url != "https://owner.github.io/repo/packs/hub.pck":
		_fail("Unexpected GitHub Pages URL: %s" % github_pages_url)
		return

	var forced_options: PackRatOptions = _new_options()
	forced_options.id = "forced_download_smoke"
	forced_options.cache_dir = CACHE_DIR
	forced_options.entry_path = MOUNTED_MARKER
	forced_options.timeout_seconds = 10.0
	var forced_first: PackRatResult = await PackRat.load_resource_pack(_url, forced_options)
	if not forced_first.ok:
		_fail("Expected forced-download setup load to succeed. Result: %s" % JSON.stringify(forced_first.to_dictionary()))
		return

	forced_options.always_download = true
	var forced_rewrite: PackRatResult = await PackRat.load_resource_pack(_url, forced_options)
	if not forced_rewrite.ok or not _has_warning(forced_rewrite, "different pack"):
		_fail("Expected forced redownload of a mounted path to use a new cache path and warn. Result: %s" % JSON.stringify(forced_rewrite.to_dictionary()))
		return

	_fail_get = true
	var forced_second: PackRatResult = await PackRat.load_resource_pack(_url, forced_options)
	_fail_get = false
	if forced_second.ok:
		_fail("Expected always_download to fail when the fresh download fails.")
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected failed download to remove .part files.")
		return

	var invalid_url: String = "http://127.0.0.1:%d/invalid.pck" % _server.get_local_port()
	var invalid_options: PackRatOptions = _new_options()
	invalid_options.id = "invalid_mount_smoke"
	invalid_options.cache_dir = CACHE_DIR
	invalid_options.timeout_seconds = 10.0
	var invalid_get_count: int = _get_count
	var invalid_first: PackRatResult = await PackRat.load_resource_pack(invalid_url, invalid_options)
	var invalid_second: PackRatResult = await PackRat.load_resource_pack(invalid_url, invalid_options)
	if invalid_first.ok or invalid_second.ok:
		_fail("Expected invalid PCK downloads to fail mounting.")
		return

	if _get_count != invalid_get_count + 2:
		_fail("Expected failed mounts to avoid cache reuse and download twice.")
		return

	_require_header = true
	var header_options: PackRatOptions = _new_options()
	header_options.id = "header_smoke"
	header_options.cache_dir = CACHE_DIR
	header_options.timeout_seconds = 10.0
	header_options.request_headers.append("X-PackRat-Smoke: yes")
	var header_result: PackRatResult = await PackRat.load_resource_pack(_url, header_options)
	_require_header = false
	if not header_result.ok:
		_fail("Expected request_headers to be sent to HTTPRequest. Result: %s" % JSON.stringify(header_result.to_dictionary()))
		return

	var redirect_url: String = "http://127.0.0.1:%d/redirect.pck" % _server.get_local_port()
	var redirect_options: PackRatOptions = _new_options()
	redirect_options.id = "redirect_smoke"
	redirect_options.cache_dir = CACHE_DIR
	redirect_options.timeout_seconds = 10.0
	redirect_options.max_redirects = 0
	var redirect_rejected: PackRatResult = await PackRat.load_resource_pack(redirect_url, redirect_options)
	if redirect_rejected.ok:
		_fail("Expected max_redirects=0 to reject redirected URL.")
		return

	redirect_options.max_redirects = 2
	var redirect_followed: PackRatResult = await PackRat.load_resource_pack(redirect_url, redirect_options)
	if not redirect_followed.ok:
		_fail("Expected max_redirects=2 to follow redirected URL. Result: %s" % JSON.stringify(redirect_followed.to_dictionary()))
		return

	var timeout_options: PackRatOptions = _new_options()
	timeout_options.id = "timeout_smoke"
	timeout_options.cache_dir = CACHE_DIR
	timeout_options.timeout_seconds = 0.05
	var timeout_url: String = "http://127.0.0.1:%d/timeout.pck" % _server.get_local_port()
	var timeout_result: PackRatResult = await PackRat.load_resource_pack(timeout_url, timeout_options)
	if timeout_result.ok:
		_fail("Expected timeout_seconds to fail a delayed response.")
		return

	var marker_before_replace_false: String = FileAccess.get_file_as_string(MOUNTED_MARKER)
	_build_pack("replace-files-false-marker")
	var replace_false_options: PackRatOptions = _new_options()
	replace_false_options.id = "replace_false_smoke"
	replace_false_options.cache_dir = CACHE_DIR
	replace_false_options.timeout_seconds = 10.0
	replace_false_options.replace_files = false
	var replace_false_result: PackRatResult = await PackRat.load_resource_pack(_url, replace_false_options)
	if not replace_false_result.ok:
		_fail("Expected replace_files=false load to mount. Result: %s" % JSON.stringify(replace_false_result.to_dictionary()))
		return

	if FileAccess.get_file_as_string(MOUNTED_MARKER) != marker_before_replace_false:
		_fail("Expected replace_files=false to avoid overriding existing mounted resource path.")
		return

	_last_modified = "Wed, 10 Jun 2026 20:18:00 GMT"
	_build_pack("mmo-world-marker")
	var world_id: String = "mmo_world"
	var mmo_url: String = "http://127.0.0.1:%d/%s.pck" % [_server.get_local_port(), world_id]
	var mmo_options: PackRatOptions = PackRatOptions.from_expected_metadata(MODIFIED_V3_UNIX + 60, _pack_bytes.size())
	mmo_options.use_threads = false
	mmo_options.entry_path = MMO_SCENE_PATH
	var mmo_result: PackRatResult = await PackRat.load_resource_pack(mmo_url, mmo_options)
	if not mmo_result.ok:
		_fail("Expected MMO-style metadata flow to load. Result: %s" % JSON.stringify(mmo_result.to_dictionary()))
		return

	if mmo_result.id != world_id:
		_fail("Expected canonical MMO URL to derive id '%s', got '%s'." % [world_id, mmo_result.id])
		return

	if not mmo_result.entry_scene_exists():
		_fail("Expected MMO-style loaded pack to expose scene %s." % MMO_SCENE_PATH)
		return

	var stale_record_options: PackRatOptions = _new_options()
	stale_record_options.id = "stale_record_smoke"
	stale_record_options.cache_dir = CACHE_DIR
	stale_record_options.timeout_seconds = 10.0
	stale_record_options.expected_size = _pack_bytes.size()
	var stale_record_first: PackRatResult = await PackRat.load_resource_pack(_url, stale_record_options)
	if not stale_record_first.ok:
		_fail("Expected stale record setup load to succeed. Result: %s" % JSON.stringify(stale_record_first.to_dictionary()))
		return

	var stale_record_path: String = stale_record_first.local_path
	DirAccess.remove_absolute(stale_record_path)
	var stale_record_second: PackRatResult = await PackRat.load_resource_pack(_url, stale_record_options)
	if not stale_record_second.ok or stale_record_second.from_cache:
		_fail("Expected missing cache file record to repair with download. Result: %s" % JSON.stringify(stale_record_second.to_dictionary()))
		return

	_make_directory(CACHE_DIR.path_join("tmp"))
	var temp_part_path: String = CACHE_DIR.path_join("tmp").path_join("stale.part")
	var temp_part_file: FileAccess = FileAccess.open(temp_part_path, FileAccess.WRITE)
	if temp_part_file == null:
		_fail("Could not write stale .part file for clear_cache test.")
		return

	temp_part_file.store_string("stale")
	temp_part_file = null
	var clear_cache_error: Error = PackRat.clear_cache(options)
	if clear_cache_error != OK:
		_fail("Expected clear_cache to succeed, got error %d." % clear_cache_error)
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected clear_cache to remove stale .part files.")
		return

	if not _cache_json_is_empty():
		_fail("Expected clear_cache to leave cache.json empty.")
		return

	var post_clear: PackRatResult = await PackRat.load_resource_pack(_url, stale_record_options)
	if not post_clear.ok or post_clear.from_cache:
		_fail("Expected post-clear load to redownload. Result: %s" % JSON.stringify(post_clear.to_dictionary()))
		return

	if post_clear.local_path == stale_record_second.local_path:
		_fail("Expected post-clear load to avoid reusing retained mounted path %s." % post_clear.local_path)
		return

	await _finish_success("PackRat HTTP PCK smoke passed. HEAD=%d GET=%d cache=%s repeated_cache_ms=%d" % [
		_head_count,
		_get_count,
		third.local_path,
		repeated_cache_elapsed_usec / 1000,
	])


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		_serve_peer(peer)


func _serve_peer(peer: StreamPeerTCP) -> void:
	_active_peers += 1
	var request: String = ""
	var wait_until: int = Time.get_ticks_msec() + 1000

	while Time.get_ticks_msec() < wait_until and request.find("\r\n\r\n") < 0:
		if peer.get_available_bytes() > 0:
			request += peer.get_utf8_string(peer.get_available_bytes())
		else:
			await get_tree().process_frame

	var method: String = request.get_slice(" ", 0)
	var path: String = request.get_slice(" ", 1)
	var route_path: String = path.get_slice("?", 0)
	if method == "HEAD":
		_last_head_path = path
	elif method == "GET":
		_last_get_path = path
	if route_path == "/invalid.pck":
		if method == "HEAD":
			_head_count += 1
			_write_invalid_response(peer, false)
		elif method == "GET":
			_get_count += 1
			_write_invalid_response(peer, true)
		else:
			_write_not_found(peer)
	elif route_path == "/redirect.pck":
		_write_redirect(peer, "/hub.pck")
	elif route_path == "/timeout.pck":
		await _write_delayed_response(peer)
	elif route_path == "/slow.pck" and method == "GET":
		_get_count += 1
		await _write_slow_response(peer)
	elif route_path == "/slow-no-length.pck" and method == "GET":
		_get_count += 1
		await _write_slow_chunked_response(peer)
	elif route_path == "/hub-gzip.pck" and method == "GET":
		_get_count += 1
		_write_gzip_response(peer)
	elif route_path == "/hub-gzip.pck" and method == "HEAD":
		_head_count += 1
		_write_gzip_head(peer)
	elif _fail_get and method == "GET":
		_get_count += 1
		_write_not_found(peer)
	elif _require_header and not request.contains("\r\nX-PackRat-Smoke: yes\r\n"):
		if method == "HEAD":
			_head_count += 1
		elif method == "GET":
			_get_count += 1
		_write_forbidden(peer)
	elif method == "HEAD":
		_head_count += 1
		_write_response(peer, false)
	elif method == "GET":
		_get_count += 1
		_write_response(peer, true)
	else:
		_write_not_found(peer)

	peer.disconnect_from_host()
	peer = null
	_active_peers -= 1


func _collect_load(options: PackRatOptions, output: Array[PackRatResult]) -> void:
	var result: PackRatResult = await PackRat.load_resource_pack(_url, options)
	output.append(result)


func _reset_request_paths() -> void:
	_last_head_path = ""
	_last_get_path = ""


func _assert_download_timings(result: PackRatResult) -> bool:
	for key in [
		"download_msec",
		"download_http_transfer_msec",
		"download_http_total_msec",
		"download_http_progress_frames",
		"cache_finalize_msec",
		"mount_msec",
		"total_msec",
	]:
		if not result.timings_msec.has(key):
			_fail("Expected downloaded result timings to include %s. Result: %s" % [key, JSON.stringify(result.to_dictionary())])
			return false

	return true


func _assert_mount_timings(result: PackRatResult) -> bool:
	for key in ["mount_msec", "total_msec"]:
		if not result.timings_msec.has(key):
			_fail("Expected mounted cache-hit timings to include %s. Result: %s" % [key, JSON.stringify(result.to_dictionary())])
			return false

	if result.timings_msec.has("download_msec"):
		_fail("Expected cache-hit timings to skip download_msec. Result: %s" % JSON.stringify(result.to_dictionary()))
		return false

	return true


func _packrat_request_runner_count() -> int:
	var count: int = 0
	for child in get_tree().root.get_children():
		if child is PackRatRequestRunner:
			count += 1

	return count


func _write_response(peer: StreamPeerTCP, include_body: bool) -> void:
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: application/octet-stream\r\n"
		+ "Content-Length: %d\r\n" % _pack_bytes.size()
		+ "ETag: %s\r\n" % _etag
		+ "Access-Control-Allow-Origin: *\r\n"
		+ "Access-Control-Expose-Headers: ETag, Content-Length, Last-Modified\r\n"
	)
	if not _omit_last_modified:
		headers += "Last-Modified: %s\r\n" % _last_modified
	headers += "Connection: close\r\n\r\n"
	peer.put_data(headers.to_utf8_buffer())

	if include_body:
		peer.put_data(_pack_bytes)


func _write_gzip_head(peer: StreamPeerTCP) -> void:
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: application/octet-stream\r\n"
		+ "Content-Encoding: gzip\r\n"
		+ "Content-Length: %d\r\n" % _gzip_pack_bytes.size()
		+ "ETag: \"packrat-gzip-smoke\"\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())


func _write_gzip_response(peer: StreamPeerTCP) -> void:
	_write_gzip_head(peer)
	peer.put_data(_gzip_pack_bytes)


func _write_slow_response(peer: StreamPeerTCP) -> void:
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: application/octet-stream\r\n"
		+ "ETag: \"packrat-slow-smoke\"\r\n"
		+ "Connection: close\r\n"
	)
	headers += "Content-Length: %d\r\n" % _pack_bytes.size()
	headers += "\r\n"
	peer.put_data(headers.to_utf8_buffer())

	var offset: int = 0
	while offset < _pack_bytes.size():
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return

		var next_offset: int = mini(offset + SLOW_RESPONSE_CHUNK_SIZE, _pack_bytes.size())
		peer.put_data(_pack_bytes.slice(offset, next_offset))
		offset = next_offset
		await get_tree().process_frame


func _write_slow_chunked_response(peer: StreamPeerTCP) -> void:
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: application/octet-stream\r\n"
		+ "Transfer-Encoding: chunked\r\n"
		+ "ETag: \"packrat-slow-chunked-smoke\"\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())

	var offset: int = 0
	while offset < _pack_bytes.size():
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return

		var next_offset: int = mini(offset + SLOW_RESPONSE_CHUNK_SIZE, _pack_bytes.size())
		var chunk: PackedByteArray = _pack_bytes.slice(offset, next_offset)
		peer.put_data(("%s\r\n" % String.num_int64(chunk.size(), 16)).to_utf8_buffer())
		peer.put_data(chunk)
		peer.put_data("\r\n".to_utf8_buffer())
		offset = next_offset
		await get_tree().process_frame

	peer.put_data("0\r\n\r\n".to_utf8_buffer())


func _write_delayed_response(peer: StreamPeerTCP) -> void:
	await get_tree().create_timer(0.5).timeout
	_write_response(peer, true)


func _write_redirect(peer: StreamPeerTCP, location: String) -> void:
	var headers: String = (
		"HTTP/1.1 302 Found\r\n"
		+ "Location: %s\r\n" % location
		+ "Content-Length: 0\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())


func _write_not_found(peer: StreamPeerTCP) -> void:
	var body: PackedByteArray = "not found".to_utf8_buffer()
	var headers: String = (
		"HTTP/1.1 404 Not Found\r\n"
		+ "Content-Length: %d\r\n" % body.size()
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())
	peer.put_data(body)


func _write_forbidden(peer: StreamPeerTCP) -> void:
	var body: PackedByteArray = "forbidden".to_utf8_buffer()
	var headers: String = (
		"HTTP/1.1 403 Forbidden\r\n"
		+ "Content-Length: %d\r\n" % body.size()
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())
	peer.put_data(body)


func _write_invalid_response(peer: StreamPeerTCP, include_body: bool) -> void:
	var body: PackedByteArray = "not a valid pack".to_utf8_buffer()
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: application/octet-stream\r\n"
		+ "Content-Length: %d\r\n" % body.size()
		+ "ETag: \"invalid-pack\"\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())

	if include_body:
		peer.put_data(body)


func _build_pack(marker: String) -> void:
	var source: FileAccess = FileAccess.open(SOURCE_PATH, FileAccess.WRITE)
	if source == null:
		_fail("Could not write smoke source file (error %d)." % FileAccess.get_open_error())
		return

	source.store_string(marker)
	source = null

	var scene_source: FileAccess = FileAccess.open(SCENE_SOURCE_PATH, FileAccess.WRITE)
	if scene_source == null:
		_fail("Could not write smoke scene source file (error %d)." % FileAccess.get_open_error())
		return

	scene_source.store_string("[gd_scene format=3]\n\n[node name=\"MmoWorld\" type=\"Node\"]\n")
	scene_source = null

	var random_source: FileAccess = FileAccess.open(RANDOM_SOURCE_PATH, FileAccess.WRITE)
	if random_source == null:
		_fail("Could not write smoke random source file (error %d)." % FileAccess.get_open_error())
		return

	var random_bytes: PackedByteArray = PackedByteArray()
	random_bytes.resize(512 * 1024)
	var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()
	random_generator.seed = 123456789
	for index in range(random_bytes.size()):
		random_bytes[index] = random_generator.randi_range(0, 255)
	random_source.store_buffer(random_bytes)
	random_source = null

	var packer: PCKPacker = PCKPacker.new()
	var start_error: Error = packer.pck_start(PACK_PATH)
	if start_error != OK:
		_fail("Could not start PCK packer (error %d)." % start_error)
		return

	var add_error: Error = packer.add_file(MOUNTED_MARKER, SOURCE_PATH)
	if add_error != OK:
		_fail("Could not add smoke marker to PCK (error %d)." % add_error)
		return

	add_error = packer.add_file(MMO_SCENE_PATH, SCENE_SOURCE_PATH)
	if add_error != OK:
		_fail("Could not add smoke scene to PCK (error %d)." % add_error)
		return

	add_error = packer.add_file(RANDOM_PACK_PATH, RANDOM_SOURCE_PATH)
	if add_error != OK:
		_fail("Could not add smoke random payload to PCK (error %d)." % add_error)
		return

	var flush_error: Error = packer.flush()
	if flush_error != OK:
		_fail("Could not flush smoke PCK (error %d)." % flush_error)
		return

	_pack_bytes = FileAccess.get_file_as_bytes(PACK_PATH)
	if _pack_bytes.is_empty():
		_fail("Smoke PCK was empty.")
		return

	_gzip_pack_bytes = _pack_bytes.compress(FileAccess.COMPRESSION_GZIP)
	if _gzip_pack_bytes.is_empty():
		_fail("Smoke gzip PCK bytes were empty.")
		return

	if _gzip_pack_bytes.size() <= _pack_bytes.size():
		_fail("Expected smoke gzip transfer to be larger than decoded PCK for body_size_limit regression coverage.")


func _make_directory(path: String) -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		_fail("Could not create directory %s (error %d)." % [path, error])


func _clear_directory(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = path.path_join(child)
		if dir.current_is_dir():
			_clear_directory(child_path)
			DirAccess.remove_absolute(child_path)
		else:
			DirAccess.remove_absolute(child_path)
		child = dir.get_next()

	dir.list_dir_end()


func _has_warning(result: PackRatResult, text: String) -> bool:
	for warning in result.warnings:
		if warning.contains(text):
			return true

	return false


func _has_part_files(cache_dir: String) -> bool:
	var tmp_dir: String = cache_dir.path_join("tmp")
	var dir: DirAccess = DirAccess.open(tmp_dir)
	if dir == null:
		return false

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		if not dir.current_is_dir() and child.ends_with(".part"):
			dir.list_dir_end()
			return true

		child = dir.get_next()

	dir.list_dir_end()
	return false


func _cache_json_contains(text: String) -> bool:
	var cache_path: String = CACHE_DIR.path_join("cache.json")
	if not FileAccess.file_exists(cache_path):
		return false

	return FileAccess.get_file_as_string(cache_path).contains(text)


func _cache_json_is_empty() -> bool:
	var cache_path: String = CACHE_DIR.path_join("cache.json")
	if not FileAccess.file_exists(cache_path):
		return true

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(cache_path))
	if not parsed is Dictionary:
		return false

	var data: Dictionary = parsed
	return data.get("items", {}).is_empty()


func _fail(message: String) -> void:
	_server.stop()
	push_error(message)
	get_tree().quit(1)


func _finish_success(message: String) -> void:
	set_process(false)
	var wait_until: int = Time.get_ticks_msec() + 3000
	while _active_peers > 0 and Time.get_ticks_msec() < wait_until:
		await get_tree().process_frame

	print(message)
	_server.stop()
	get_tree().quit()
