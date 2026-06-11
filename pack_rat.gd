class_name PackRat extends RefCounted
## Static facade for loading remote Godot PCK/ZIP resource packs at runtime.
## [br][br]
## The main API is [method load_resource_pack]. It creates temporary
## [HTTPRequest] nodes under the scene tree root as needed, then frees them
## when each request completes or fails to start. No autoload, editor plugin,
## or persistent helper node is required.

const _HASH_TOKEN_LENGTH: int = 12
const _MONTHS: Dictionary = {
	"jan": 1,
	"feb": 2,
	"mar": 3,
	"apr": 4,
	"may": 5,
	"jun": 6,
	"jul": 7,
	"aug": 8,
	"sep": 9,
	"oct": 10,
	"nov": 11,
	"dec": 12,
}

static var _mounted_paths_by_id: Dictionary = {}
static var _mounted_signatures_by_id: Dictionary = {}
static var _mounted_paths: Dictionary = {}
static var _fast_cache_records: Dictionary = {}
static var _fast_cache_signatures: Dictionary = {}


## Downloads, freshness-checks, caches, and mounts the resource pack at [param url].
## [br][br]
## Returns a [PackRatResult] with [member PackRatResult.ok] set to [code]true[/code]
## when the file is ready. [param options] can override cache location,
## replacement behavior, request headers, timeout, and entry path.
static func load_resource_pack(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatResult:
	if not _is_http_url(url):
		return PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs.")

	var request_options: PackRatOptions = options.copy()
	if not _is_safe_cache_dir(request_options.cache_dir):
		return PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments.")
	request_options.cache_dir = _normalized_cache_dir(request_options.cache_dir)
	var id: String = _id_for_url(url, request_options)
	var key: String = _cache_key(url, id, request_options)
	var fast_result: PackRatResult = _fast_cache_result(url, id, key, request_options)
	if fast_result != null:
		return fast_result

	var request: PackRatRequest = load_resource_pack_async(url, request_options)
	if request.is_completed():
		return request.result

	await request.completed
	return request.result


## Starts loading the resource pack at [param url] and returns a cancelable request.
static func load_resource_pack_async(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatRequest:
	if not _is_http_url(url):
		var invalid_request: PackRatRequest = PackRatRequest.new()
		_finish_request_next_frame(invalid_request, PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs."))
		return invalid_request

	var request_options: PackRatOptions = options.copy()
	if not _is_safe_cache_dir(request_options.cache_dir):
		var invalid_cache_request: PackRatRequest = PackRatRequest.new()
		_finish_request_next_frame(invalid_cache_request, PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments."))
		return invalid_cache_request
	request_options.cache_dir = _normalized_cache_dir(request_options.cache_dir)

	var id: String = _id_for_url(url, request_options)
	var key: String = _cache_key(url, id, request_options)
	var request: PackRatRequest = PackRatRequest.new()
	request._setup(url, request_options, id, key)
	var fast_result: PackRatResult = _fast_cache_result(url, id, key, request_options)
	if fast_result != null:
		_finish_request_next_frame(request, fast_result)
		return request

	var tree: SceneTree = Engine.get_main_loop()
	if tree == null or tree.root == null:
		request._finish(PackRatResult.failed(url, "PackRat needs a running SceneTree."))
		return request

	var runner: PackRatRequestRunner = PackRatRequestRunner.new()
	tree.root.add_child(runner)
	runner.start(request)
	return request


## Deletes every cached resource pack and cache metadata entry.
static func clear_cache(options: PackRatOptions = PackRatOptions.new()) -> Error:
	if not _is_safe_cache_dir(options.cache_dir):
		return ERR_INVALID_PARAMETER

	var cache_dir: String = _normalized_cache_dir(options.cache_dir)
	_ensure_dir(cache_dir)
	var first_error: Error = _clear_part_files(cache_dir)
	var clear_error: Error = _clear_unmounted_cache_files(cache_dir)
	if first_error == OK:
		first_error = clear_error

	var cache: PackRatCache = PackRatCache.load(cache_dir)
	for key in cache.keys():
		cache.erase_record(key)

	var save_error: Error = cache.save()
	if first_error == OK:
		first_error = save_error

	_clear_fast_cache()
	return first_error


## Deletes cached entries matching [param value] as a URL, ID, cached filename, or path.
## [br][br]
## This only removes disk cache entries. Already mounted resource packs remain
## mounted until the process exits because Godot does not expose per-pack unload.
static func clear_cached_resource_pack(value: String, options: PackRatOptions = PackRatOptions.new()) -> Error:
	if not _is_safe_cache_dir(options.cache_dir):
		return ERR_INVALID_PARAMETER

	var cache_dir: String = _normalized_cache_dir(options.cache_dir)
	var cache: PackRatCache = PackRatCache.load(cache_dir)
	var keys: PackedStringArray = cache.keys()
	var matched: bool = false
	var first_error: Error = OK
	var matched_ids: PackedStringArray = []

	for key in keys:
		var record: PackRatCacheRecord = cache.record(key)
		if not _cache_record_matches(value, key, record):
			continue

		matched = true
		var record_id: String = _record_id(key, record)
		if not matched_ids.has(record_id):
			matched_ids.append(record_id)
		cache.erase_record(key)
		_forget_fast_cache(key, options)
		var remove_error: Error = _remove_cache_file(record.local_path, cache_dir)
		if _is_real_remove_error(remove_error) and first_error == OK:
			first_error = remove_error

	if not matched:
		var direct_id: String = _id_from_cached_filename(value)
		var direct_path: String = value if value.begins_with("user://") else cache_dir.path_join(value)
		if not direct_id.is_empty() and _is_cache_child_path(direct_path, cache_dir) and FileAccess.file_exists(direct_path):
			matched = true
			matched_ids.append(direct_id)
		elif not _is_http_url(value) and _has_matching_cache_file(cache_dir, _safe(value)):
			matched = true
			matched_ids.append(_safe(value))

	if not matched:
		return ERR_DOES_NOT_EXIST

	for key in cache.keys():
		var record: PackRatCacheRecord = cache.record(key)
		if not matched_ids.has(_record_id(key, record)):
			continue

		cache.erase_record(key)
		_forget_fast_cache(key, options)
		var remove_error: Error = _remove_cache_file(record.local_path, cache_dir)
		if _is_real_remove_error(remove_error) and first_error == OK:
			first_error = remove_error

	for id in matched_ids:
		var cleanup_error: Error = _clear_unmounted_cache_files(cache_dir, id)
		if _is_real_remove_error(cleanup_error) and first_error == OK:
			first_error = cleanup_error

	var save_error: Error = cache.save()
	if save_error != OK:
		return save_error

	return first_error


## Builds a direct GitHub Releases asset URL without using the GitHub API.
static func github_release_url(owner: String, repo: String, filename: String, tag: String = "latest") -> String:
	var clean_filename: String = filename.trim_prefix("/")
	if tag.is_empty() or tag == "latest":
		return "https://github.com/%s/%s/releases/latest/download/%s" % [
			_url_segment(owner),
			_url_segment(repo),
			clean_filename.uri_encode(),
		]

	return "https://github.com/%s/%s/releases/download/%s/%s" % [
		_url_segment(owner),
		_url_segment(repo),
		_url_segment(tag),
		clean_filename.uri_encode(),
	]


## Joins a static host base URL and path with slash cleanup only.
static func join_url(base_url: String, path: String) -> String:
	var clean_base: String = base_url.strip_edges().trim_suffix("/")
	var clean_path: String = path.strip_edges().trim_prefix("/")
	if clean_base.is_empty():
		return clean_path
	if clean_path.is_empty():
		return clean_base

	return "%s/%s" % [clean_base, clean_path]


## Reads size and modified-time metadata for [param path] without opening the file.
static func file_metadata(path: String) -> PackRatFileMetadata:
	var metadata: PackRatFileMetadata = PackRatFileMetadata.new()
	metadata.path = path
	if path.is_empty():
		metadata.error = "PackRat could not read file metadata because the path is empty."
		return metadata

	if not FileAccess.file_exists(path):
		metadata.error = "PackRat could not read file metadata because %s does not exist." % path
		return metadata

	metadata.size = FileAccess.get_size(path)
	metadata.modified_time = FileAccess.get_modified_time(path)
	if metadata.size < 0:
		metadata.error = "PackRat could not read file size for %s." % path
		return metadata

	if metadata.modified_time <= 0:
		metadata.error = "PackRat could not read modified time for %s." % path
		return metadata

	metadata.ok = true
	return metadata


static func _finish_resource_pack_request(request: PackRatRequest, result: PackRatResult) -> void:
	request._finish(result)


static func _finish_request_next_frame(request: PackRatRequest, result: PackRatResult) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	if tree == null:
		request._finish(result)
		return

	tree.process_frame.connect(func() -> void:
		if request.is_canceled():
			request._finish(PackRatResult.failed(request.url, "PackRat request was canceled."))
			return

		request._finish(result)
	, CONNECT_ONE_SHOT)


static func _load_resource_pack(request: PackRatRequest) -> PackRatResult:
	var url: String = request.url
	var options: PackRatOptions = request.options
	var id: String = request.id
	var key: String = request.cache_key
	var result: PackRatResult = PackRatResult.new()
	result.source_url = url
	result.id = id
	if request.is_canceled():
		return PackRatResult.failed(url, "PackRat request was canceled.")
	if not _is_safe_cache_dir(options.cache_dir):
		return PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments.")

	_ensure_dir(options.cache_dir)

	var cache: PackRatCache = PackRatCache.load(options.cache_dir)
	var record: PackRatCacheRecord = cache.record(key)
	var metadata: PackRatHttpResponse = PackRatHttpResponse.new()
	var cached_file_exists: bool = record.file_exists()
	if not record.local_path.is_empty() and not cached_file_exists:
		cache.erase_record(key)
		_forget_fast_cache(key, options)
		cache.save()

	var should_download: bool = options.always_download or not cached_file_exists
	var cached_expected_size_mismatch: bool = false

	if cached_file_exists and options.has_expected_size():
		var cached_size: int = FileAccess.get_size(record.local_path)
		if cached_size != options.expected_size:
			cached_expected_size_mismatch = true
			should_download = true
			_evict_cache_record(cache, key, record.local_path, options)

	if cached_file_exists and not should_download and (options.offline_first or options.has_expected_metadata()):
		should_download = false
	elif cached_file_exists and not should_download:
		metadata = await _freshness_metadata(url, options, request)
		if request.is_canceled():
			return PackRatResult.failed(url, "PackRat request was canceled.")

		var freshness: String = record.freshness_against(metadata)
		should_download = freshness == "stale"
		if freshness == "unknown":
			result.add_warning("PackRat could not compare remote freshness metadata; using the cached pack.")

	if not should_download:
		result.status = PackRatResult.STATUS_CACHE_HIT
		result.from_cache = true
		result.local_path = record.local_path
		record.apply_to_result(result)
		var cached_result: PackRatResult = _mount_if_pack(result, options)
		if not cached_result.ok:
			_evict_cache_record(cache, key, record.local_path, options)
		else:
			_remember_fast_cache(key, url, cached_result, options)
		return cached_result

	_ensure_dir(options.cache_dir.path_join("tmp"))
	var part_path: String = options.cache_dir.path_join("tmp").path_join("%s-%d.part" % [key, request.get_instance_id()])
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(part_path)

	var download: PackRatHttpResponse = await _request(url, part_path, options, request)
	if request.is_canceled():
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, "PackRat request was canceled.")

	if not download.ok:
		DirAccess.remove_absolute(part_path)
		if cached_file_exists and not options.always_download and not cached_expected_size_mismatch:
			result.status = PackRatResult.STATUS_CACHE_HIT
			result.from_cache = true
			result.local_path = record.local_path
			result.add_warning("%s Using the previous cached pack." % download.error)
			record.apply_to_result(result)
			var fallback_result: PackRatResult = _mount_if_pack(result, options)
			if not fallback_result.ok:
				_evict_cache_record(cache, key, record.local_path, options)
			return fallback_result

		return PackRatResult.failed(url, download.error)

	var file_size: int = FileAccess.get_size(part_path)
	if file_size <= 0:
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, "Downloaded pack was empty.")

	metadata.merge_from(download)
	var validation_error: String = _validate_expected_metadata(options, metadata, file_size)
	if not validation_error.is_empty():
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, validation_error)

	var has_comparable_freshness: bool = options.has_expected_metadata() or metadata.has_freshness()
	var local_path: String = _local_path(url, options.cache_dir, result.id, metadata, options)
	if (
		FileAccess.file_exists(local_path)
		and not _is_mounted_path(local_path)
		and not options.always_download
		and not cached_expected_size_mismatch
	):
		result.status = PackRatResult.STATUS_DOWNLOADED
		result.from_cache = false
		result.local_path = local_path
		result.content_length = FileAccess.get_size(local_path)
		metadata.apply_to_result(result)
		var existing_result: PackRatResult = _mount_if_pack(result, options)
		if existing_result.ok:
			DirAccess.remove_absolute(part_path)
			cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result, options))
			cache.save()
			_remember_fast_cache(key, url, existing_result, options)
			return existing_result

		_evict_cache_record(cache, key, local_path, options, false)

	if FileAccess.file_exists(local_path):
		if _is_mounted_path(local_path):
			local_path = _unused_cache_path(local_path, request.get_instance_id())
		else:
			var remove_error: Error = _remove_cache_file(local_path, options.cache_dir)
			if _is_real_remove_error(remove_error):
				DirAccess.remove_absolute(part_path)
				return PackRatResult.failed(url, "Could not replace cached pack %s (error %d)." % [local_path, remove_error])

	var move_error: Error = DirAccess.rename_absolute(part_path, local_path)
	if move_error != OK:
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, "Could not move downloaded pack into cache (error %d)." % move_error)

	result.status = PackRatResult.STATUS_DOWNLOADED
	result.local_path = local_path
	result.content_length = file_size
	metadata.apply_to_result(result)

	if not has_comparable_freshness:
		result.add_warning("PackRat cached this URL without comparable freshness headers.")
	if (
		options.has_expected_modified_time()
		and options.has_expected_size()
		and _http_date_unix(metadata.last_modified) <= 0
	):
		result.add_warning("PackRat could not compare expected modified time because Last-Modified was missing or invalid.")

	var mounted_result: PackRatResult = _mount_if_pack(result, options)
	if not mounted_result.ok:
		_remove_cache_file(local_path, options.cache_dir)
		return mounted_result

	var previous_local_path: String = record.local_path
	var previous_mounted_path: String = str(_mounted_paths_by_id.get(result.id, ""))
	if (
		not previous_local_path.is_empty()
		and previous_local_path != local_path
		and previous_local_path != previous_mounted_path
	):
		_remove_cache_file(previous_local_path, options.cache_dir)

	_cleanup_old_versions(cache, key, result.id, local_path, options, result)
	cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result, options))
	var save_error: Error = cache.save()
	if save_error != OK:
		result.add_warning("PackRat loaded the resource pack but could not save cache metadata (error %d)." % save_error)

	_remember_fast_cache(key, url, mounted_result, options)
	return mounted_result


static func _mount_if_pack(result: PackRatResult, options: PackRatOptions) -> PackRatResult:
	var extension: String = result.local_path.get_extension().to_lower()
	if extension != "pck" and extension != "zip":
		return PackRatResult.failed(result.source_url, "PackRat only mounts .pck and .zip files.")

	if extension == "zip" and options.offset != 0:
		return PackRatResult.failed(result.source_url, "Godot only supports nonzero resource pack offsets for .pck files.")

	var signature: String = _mount_signature(result.local_path, options)
	var previous_signature: String = str(_mounted_signatures_by_id.get(result.id, ""))
	if result.status == PackRatResult.STATUS_CACHE_HIT and previous_signature == signature:
		result.ok = true
		result.mounted = true
		result.entry_path = options.entry_path
		return result

	var previous_path: String = str(_mounted_paths_by_id.get(result.id, ""))
	if result.status == PackRatResult.STATUS_DOWNLOADED and previous_path == result.local_path:
		result.add_warning(
			"PackRat replaced a pack at an already-mounted path for id '%s'. Godot resource packs stay mounted for the life of the process." % result.id
		)

	result.mounted = ProjectSettings.load_resource_pack(result.local_path, options.replace_files, options.offset)
	if not result.mounted:
		return PackRatResult.failed(result.source_url, "Godot could not mount %s." % result.local_path)

	if not previous_path.is_empty() and previous_path != result.local_path:
		result.add_warning(
			"PackRat mounted a different pack for id '%s'. Godot resource packs stay mounted for the life of the process." % result.id
		)
	_mounted_paths_by_id[result.id] = result.local_path
	_mounted_signatures_by_id[result.id] = signature
	_mounted_paths[result.local_path] = true

	result.ok = true
	result.entry_path = options.entry_path
	return result


static func _freshness_metadata(url: String, options: PackRatOptions, owner: PackRatRequest) -> PackRatHttpResponse:
	var response: PackRatHttpResponse = await _request(url, "", options, owner, HTTPClient.METHOD_HEAD)
	if not response.ok:
		return PackRatHttpResponse.new()

	return response


static func _request(
	url: String,
	download_path: String,
	options: PackRatOptions,
	owner: PackRatRequest,
	method: HTTPClient.Method = HTTPClient.METHOD_GET
) -> PackRatHttpResponse:
	var tree: SceneTree = Engine.get_main_loop()
	if tree == null or tree.root == null:
		return PackRatHttpResponse.failed("HTTPRequest needs a running SceneTree.")

	var request: HTTPRequest = HTTPRequest.new()
	request.accept_gzip = false
	request.download_file = download_path
	request.max_redirects = options.max_redirects
	request.timeout = options.timeout_seconds
	if tree.root.is_node_ready():
		tree.root.add_child(request)
	else:
		tree.root.add_child.call_deferred(request)
		await tree.process_frame

	if not request.is_inside_tree():
		request.queue_free()
		return PackRatHttpResponse.failed("HTTPRequest could not enter the scene tree.")

	owner._set_http_request(request)
	var start_error: Error = request.request(url, options.request_headers, method)
	if start_error != OK:
		owner._set_http_request(null)
		request.queue_free()
		return PackRatHttpResponse.failed("HTTPRequest failed to start (error %d)." % start_error)

	var completed: Array = []
	request.request_completed.connect(func(result_code: HTTPRequest.Result, response_code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
		completed.append(result_code)
		completed.append(response_code)
		completed.append(headers)
	, CONNECT_ONE_SHOT)

	while completed.is_empty():
		if owner.is_canceled():
			request.cancel_request()
			owner._set_http_request(null)
			request.queue_free()
			return PackRatHttpResponse.failed("PackRat request was canceled.")

		if not download_path.is_empty():
			owner._set_progress(request.get_downloaded_bytes(), request.get_body_size())
		await tree.process_frame

	owner._set_http_request(null)
	request.queue_free()

	var result_code: HTTPRequest.Result = completed[0]
	var response_code: int = completed[1]
	var headers: PackedStringArray = completed[2]

	return PackRatHttpResponse.from_completed(result_code, response_code, headers)


static func _local_path(
	url: String,
	cache_dir: String,
	id: String,
	metadata: PackRatHttpResponse,
	options: PackRatOptions
) -> String:
	var filename: String = _filename(url)
	var extension: String = filename.get_extension()
	var token: String = _version_token(url, metadata, options)
	if extension.is_empty():
		extension = _extension_for_response(metadata)

	return cache_dir.path_join("%s-%s.%s" % [id, token, extension])


static func _version_token(url: String, metadata: PackRatHttpResponse, options: PackRatOptions) -> String:
	if options.has_expected_metadata():
		return _expected_metadata_token(options)

	if not metadata.etag.is_empty():
		return metadata.etag.sha256_text().substr(0, _HASH_TOKEN_LENGTH)

	if not metadata.last_modified.is_empty() or metadata.content_length > 0:
		return ("%s:%d" % [metadata.last_modified, metadata.content_length]).sha256_text().substr(0, _HASH_TOKEN_LENGTH)

	return url.sha256_text().substr(0, _HASH_TOKEN_LENGTH)


static func _id_for_url(url: String, options: PackRatOptions) -> String:
	if not options.id.is_empty():
		return _safe(options.id)

	return _safe(_filename(url).get_basename())


static func _cache_key(url: String, id: String, options: PackRatOptions) -> String:
	if options.has_expected_metadata():
		return "%s-%s" % [id, _expected_metadata_token(options)]

	return "%s-%s" % [id, url.sha256_text().substr(0, _HASH_TOKEN_LENGTH)]


static func _expected_metadata_token(options: PackRatOptions) -> String:
	return ("expected:%d:%d" % [options.expected_size, options.expected_modified_time]).sha256_text().substr(0, _HASH_TOKEN_LENGTH)


static func _extension_for_response(metadata: PackRatHttpResponse) -> String:
	if metadata.content_type.to_lower().contains("zip"):
		return "zip"

	return "pck"


static func _validate_expected_metadata(
	options: PackRatOptions,
	metadata: PackRatHttpResponse,
	file_size: int
) -> String:
	if options.has_expected_size() and file_size != options.expected_size:
		return "Downloaded pack size mismatch: expected %d bytes, got %d." % [options.expected_size, file_size]

	if options.has_expected_modified_time():
		var remote_modified_time: int = _http_date_unix(metadata.last_modified)
		if remote_modified_time <= 0 and not options.has_expected_size():
			return "Downloaded pack could not validate expected modified time because Last-Modified was missing or invalid."

		if remote_modified_time > 0 and remote_modified_time != options.expected_modified_time:
			return "Downloaded pack modified time mismatch: expected %d, got %d." % [
				options.expected_modified_time,
				remote_modified_time,
			]

	return ""


static func _http_date_unix(value: String) -> int:
	var parts: PackedStringArray = value.strip_edges().split(" ", false)
	if parts.size() < 5:
		return 0

	var month: int = _month_number(parts[2])
	var time_parts: PackedStringArray = parts[4].split(":")
	if month <= 0 or time_parts.size() != 3:
		return 0

	return int(Time.get_unix_time_from_datetime_dict({
		"year": int(parts[3]),
		"month": month,
		"day": int(parts[1]),
		"hour": int(time_parts[0]),
		"minute": int(time_parts[1]),
		"second": int(time_parts[2]),
	}))


static func _month_number(value: String) -> int:
	return int(_MONTHS.get(value.to_lower(), 0))


static func _cache_record_matches(value: String, key: String, record: PackRatCacheRecord) -> bool:
	if _is_http_url(value):
		return record.source_url == value

	if key == value:
		return true

	if record.local_path == value:
		return true

	var safe_value: String = _safe(value)
	if _record_id(key, record) == safe_value:
		return true

	return record.local_path.get_file() == value or _filename(record.source_url) == value


static func _filename(url: String) -> String:
	var clean_url: String = url
	var query_index: int = clean_url.find("?")
	if query_index >= 0:
		clean_url = clean_url.substr(0, query_index)

	var hash_index: int = clean_url.find("#")
	if hash_index >= 0:
		clean_url = clean_url.substr(0, hash_index)

	var filename: String = clean_url.get_file()
	return filename if not filename.is_empty() else "pack.pck"


static func _is_http_url(value: String) -> bool:
	return value.begins_with("http://") or value.begins_with("https://")


static func _safe(value: String) -> String:
	var output: PackedStringArray = []
	for index in range(value.length()):
		var character: String = value.substr(index, 1).to_lower()
		if character in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			output.append(character)
		else:
			output.append("_")

	return "".join(output) if not output.is_empty() else "pack"


static func _url_segment(value: String) -> String:
	return value.strip_edges().trim_prefix("/").trim_suffix("/").uri_encode()


static func _mount_signature(path: String, options: PackRatOptions) -> String:
	return "%s:%s:%d:%d:%d" % [
		path,
		str(options.replace_files),
		options.offset,
		FileAccess.get_size(path),
		FileAccess.get_modified_time(path),
	]


static func _record_id(key: String, record: PackRatCacheRecord) -> String:
	if not record.id.is_empty():
		return record.id

	var filename_id: String = _id_from_cached_filename(record.local_path.get_file())
	if not filename_id.is_empty():
		return filename_id

	var separator: int = key.rfind("-")
	return key.substr(0, separator) if separator > 0 else key


static func _ensure_dir(path: String) -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("PackRat could not create %s (error %d)." % [path, error])


static func _evict_cache_record(
	cache: PackRatCache,
	key: String,
	path: String,
	options: PackRatOptions,
	save: bool = true
) -> void:
	_remove_cache_file(path, options.cache_dir)
	cache.erase_record(key)
	_forget_fast_cache(key, options)
	if save:
		cache.save()


static func _cleanup_old_versions(
	cache: PackRatCache,
	current_key: String,
	id: String,
	current_path: String,
	options: PackRatOptions,
	result: PackRatResult
) -> void:
	for key in cache.keys():
		if key == current_key:
			continue

		var record: PackRatCacheRecord = cache.record(key)
		if _record_id(key, record) != id:
			continue

		var remove_error: Error = _remove_cache_file(record.local_path, options.cache_dir)
		if remove_error == ERR_BUSY:
			result.add_warning(
				"PackRat kept old mounted cache file %s because Godot resource packs stay mounted for the life of the process." % record.local_path
			)
		cache.erase_record(key)
		_forget_fast_cache(key, options)

	var scan_error: Error = _clear_unmounted_cache_files(options.cache_dir, id, current_path)
	if scan_error != OK:
		result.add_warning("PackRat could not fully clean old cache files for id '%s' (error %d)." % [id, scan_error])


static func _id_from_cached_filename(filename: String) -> String:
	var basename: String = filename.get_basename()
	var separator: int = basename.rfind("-")
	if separator <= 0:
		return ""

	return basename.substr(0, separator)


static func _unused_cache_path(path: String, salt: int) -> String:
	var directory: String = path.get_base_dir()
	var basename: String = path.get_file().get_basename()
	var extension: String = path.get_extension()
	for index in range(100):
		var suffix: String = "%d-%d" % [salt, index]
		var candidate: String = "%s-%s" % [basename, suffix]
		if not extension.is_empty():
			candidate = "%s.%s" % [candidate, extension]
		var candidate_path: String = directory.path_join(candidate)
		if not FileAccess.file_exists(candidate_path):
			return candidate_path

	var fallback: String = "%s-%d" % [basename, Time.get_ticks_usec()]
	var fallback_filename: String = "%s.%s" % [fallback, extension] if not extension.is_empty() else fallback
	return directory.path_join(fallback_filename)


static func _has_matching_cache_file(cache_dir: String, id: String) -> bool:
	var dir: DirAccess = DirAccess.open(cache_dir)
	if dir == null:
		return false

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		if not dir.current_is_dir() and _cached_filename_matches_id(child, id):
			dir.list_dir_end()
			return true

		child = dir.get_next()

	dir.list_dir_end()
	return false


static func _clear_unmounted_cache_files(cache_dir: String, id: String = "", keep_path: String = "") -> Error:
	var dir: DirAccess = DirAccess.open(cache_dir)
	if dir == null:
		return OK

	var first_error: Error = OK
	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = cache_dir.path_join(child)
		if dir.current_is_dir():
			var nested_error: Error = _clear_unmounted_cache_files(child_path, id, keep_path)
			if _is_real_remove_error(nested_error) and first_error == OK:
				first_error = nested_error
			_remove_empty_directory(child_path)
		elif _is_cache_pack_file(child):
			if keep_path.is_empty() or _normalized_cache_dir(child_path) != _normalized_cache_dir(keep_path):
				if id.is_empty() or _cached_filename_matches_id(child, id):
					var remove_error: Error = _remove_cache_file(child_path, cache_dir)
					if _is_real_remove_error(remove_error) and first_error == OK:
						first_error = remove_error

		child = dir.get_next()

	dir.list_dir_end()
	return first_error


static func _clear_part_files(cache_dir: String) -> Error:
	var tmp_dir: String = cache_dir.path_join("tmp")
	var dir: DirAccess = DirAccess.open(tmp_dir)
	if dir == null:
		return OK

	var first_error: Error = OK
	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = tmp_dir.path_join(child)
		var remove_error: Error = OK
		if dir.current_is_dir():
			remove_error = _clear_directory(child_path)
			if remove_error == OK:
				remove_error = DirAccess.remove_absolute(child_path)
		elif child.ends_with(".part"):
			remove_error = DirAccess.remove_absolute(child_path)

		if _is_real_remove_error(remove_error) and first_error == OK:
			first_error = remove_error

		child = dir.get_next()

	dir.list_dir_end()
	return first_error


static func _is_cache_pack_file(filename: String) -> bool:
	var extension: String = filename.get_extension().to_lower()
	return extension == "pck" or extension == "zip"


static func _cached_filename_matches_id(filename: String, id: String) -> bool:
	return _is_cache_pack_file(filename) and _id_from_cached_filename(filename) == id


static func _is_mounted_path(path: String) -> bool:
	return _mounted_paths.has(path) or _mounted_paths.has(_normalized_cache_dir(path))


static func _is_real_remove_error(error: Error) -> bool:
	return error != OK and error != ERR_DOES_NOT_EXIST and error != ERR_BUSY


static func _fast_cache_result(url: String, id: String, key: String, options: PackRatOptions) -> PackRatResult:
	if options.always_download or (not options.offline_first and not options.has_expected_metadata()):
		return null

	var fast_key: String = _fast_cache_key(key, options)
	if not _fast_cache_records.has(fast_key):
		return null

	var record: PackRatCacheRecord = PackRatCacheRecord.from_dictionary(_fast_cache_records[fast_key])
	if not record.file_exists():
		_fast_cache_records.erase(fast_key)
		_fast_cache_signatures.erase(fast_key)
		return null

	var signature: String = _mount_signature(record.local_path, options)
	if str(_fast_cache_signatures.get(fast_key, "")) != signature:
		_fast_cache_records.erase(fast_key)
		_fast_cache_signatures.erase(fast_key)
		return null

	var result: PackRatResult = PackRatResult.new()
	result.source_url = url
	result.id = id
	result.status = PackRatResult.STATUS_CACHE_HIT
	result.from_cache = true
	result.local_path = record.local_path
	record.apply_to_result(result)
	return _mount_if_pack(result, options)


static func _remember_fast_cache(key: String, url: String, result: PackRatResult, options: PackRatOptions) -> void:
	if not result.ok:
		return

	var fast_key: String = _fast_cache_key(key, options)
	var record: PackRatCacheRecord = PackRatCacheRecord.from_result(url, result.local_path, result, options)
	_fast_cache_records[fast_key] = record.to_dictionary()
	_fast_cache_signatures[fast_key] = _mount_signature(result.local_path, options)


static func _forget_fast_cache(key: String, options: PackRatOptions) -> void:
	var fast_key: String = _fast_cache_key(key, options)
	_fast_cache_records.erase(fast_key)
	_fast_cache_signatures.erase(fast_key)


static func _clear_fast_cache() -> void:
	_fast_cache_records.clear()
	_fast_cache_signatures.clear()


static func _fast_cache_key(key: String, options: PackRatOptions) -> String:
	return "%s:%s:%s:%d" % [options.cache_dir, key, str(options.replace_files), options.offset]


static func _is_safe_cache_dir(path: String) -> bool:
	var normalized: String = _normalized_cache_dir(path)
	return (
		normalized.begins_with("user://")
		and normalized != "user://"
		and not _has_parent_directory_segment(path)
		and not _has_parent_directory_segment(normalized)
	)


static func _is_cache_child_path(path: String, cache_dir: String) -> bool:
	var normalized_cache_dir: String = _normalized_cache_dir(cache_dir)
	var normalized_path: String = _normalized_cache_dir(path)
	if (
		normalized_cache_dir.is_empty()
		or _has_parent_directory_segment(path)
		or _has_parent_directory_segment(cache_dir)
		or _has_parent_directory_segment(normalized_path)
		or _has_parent_directory_segment(normalized_cache_dir)
	):
		return false

	return normalized_path.begins_with("%s/" % normalized_cache_dir)


static func _remove_cache_file(path: String, cache_dir: String) -> Error:
	if path.is_empty():
		return ERR_DOES_NOT_EXIST

	if not _is_cache_child_path(path, cache_dir):
		return ERR_INVALID_DATA

	if not FileAccess.file_exists(path):
		return ERR_DOES_NOT_EXIST

	if _is_mounted_path(path):
		return ERR_BUSY

	return DirAccess.remove_absolute(path)


static func _normalized_cache_dir(path: String) -> String:
	var normalized: String = path.strip_edges().replace("\\", "/").simplify_path()
	while normalized.ends_with("/") and normalized != "user://" and normalized != "res://":
		normalized = normalized.trim_suffix("/")

	return normalized


static func _has_parent_directory_segment(path: String) -> bool:
	for segment in path.replace("\\", "/").split("/", false):
		if segment == "..":
			return true

	return false


static func _clear_directory(path: String) -> Error:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return OK

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = path.path_join(child)
		var error: Error = OK
		if dir.current_is_dir():
			error = _clear_directory(child_path)
			if error == OK:
				error = DirAccess.remove_absolute(child_path)
		else:
			error = DirAccess.remove_absolute(child_path)

		if error != OK:
			dir.list_dir_end()
			dir = null
			return error

		child = dir.get_next()

	dir.list_dir_end()
	dir = null
	return OK


static func _remove_empty_directory(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var first_child: String = dir.get_next()
	dir.list_dir_end()
	dir = null
	if first_child.is_empty():
		DirAccess.remove_absolute(path)
