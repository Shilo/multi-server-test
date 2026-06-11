class_name PackRat extends RefCounted
## Static facade for loading remote Godot PCK/ZIP resource packs at runtime.
## [br][br]
## The main API is [method load_resource_pack]. It creates temporary
## [HTTPRequest] nodes under the scene tree root as needed, then frees them
## when each request completes or fails to start. No autoload, editor plugin,
## or persistent helper node is required.

const _REQUEST_RUNNER_SCRIPT: GDScript = preload("res://addons/pack_rat/internal/pack_rat_request_runner.gd")

static var _in_flight: Dictionary = {}
static var _mounted_paths_by_id: Dictionary = {}


## Downloads, freshness-checks, caches, and mounts the resource pack at [param url].
## [br][br]
## Returns a [PackRatResult] with [member PackRatResult.ok] set to [code]true[/code]
## when the file is ready. [param options] can override cache location,
## replacement behavior, request headers, timeout, and entry path.
static func load_resource_pack(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatResult:
	if not _is_http_url(url):
		return PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs.")

	var request: PackRatRequest = load_resource_pack_async(url, options)
	await request.completed
	return request.result


## Starts loading the resource pack at [param url] and returns a cancelable request.
static func load_resource_pack_async(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatRequest:
	if not _is_http_url(url):
		var invalid_request: PackRatRequest = PackRatRequest.new()
		_finish_request_next_frame(invalid_request, PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs."))
		return invalid_request

	var id: String = _id_for_url(url, options)
	var key: String = _cache_key(url, id, options)
	var flight_key: String = "%s:%s" % [options.cache_dir, key]
	if _in_flight.has(flight_key):
		return _in_flight[flight_key]

	var request: PackRatRequest = PackRatRequest.new()
	request._setup(url, options, id, key)
	_in_flight[flight_key] = request
	var tree: SceneTree = Engine.get_main_loop()
	if tree == null or tree.root == null:
		_in_flight.erase(flight_key)
		request._finish(PackRatResult.failed(url, "PackRat needs a running SceneTree."))
		return request

	var runner: Node = _REQUEST_RUNNER_SCRIPT.new()
	tree.root.add_child(runner)
	runner.start(request, flight_key)
	return request


## Deletes every cached resource pack and cache metadata entry.
static func clear_cache(options: PackRatOptions = PackRatOptions.new()) -> Error:
	var error: Error = _clear_directory(options.cache_dir)
	if error != OK:
		return error

	_ensure_dir(options.cache_dir)
	return OK


## Deletes cached entries matching [param value] as a URL, ID, cached filename, or path.
## [br][br]
## This only removes disk cache entries. Already mounted resource packs remain
## mounted until the process exits because Godot does not expose per-pack unload.
static func clear_cached_resource_pack(value: String, options: PackRatOptions = PackRatOptions.new()) -> Error:
	var cache: PackRatCache = PackRatCache.load(options.cache_dir)
	var keys: PackedStringArray = cache.keys()
	var matched: bool = false
	var first_error: Error = OK

	for key in keys:
		var record: PackRatCacheRecord = cache.record(key)
		if not _cache_record_matches(value, record):
			continue

		matched = true
		if FileAccess.file_exists(record.local_path):
			var remove_error: Error = DirAccess.remove_absolute(record.local_path)
			if remove_error != OK and first_error == OK:
				first_error = remove_error
		cache.erase_record(key)
		_remove_empty_directory(record.local_path.get_base_dir())

	if not matched:
		return ERR_DOES_NOT_EXIST

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


static func _finish_resource_pack_request(request: PackRatRequest, flight_key: String, result: PackRatResult) -> void:
	_in_flight.erase(flight_key)
	request._finish(result)


static func _finish_request_next_frame(request: PackRatRequest, result: PackRatResult) -> void:
	var tree: SceneTree = Engine.get_main_loop()
	if tree == null:
		request._finish(result)
		return

	tree.process_frame.connect(func() -> void:
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

	_ensure_dir(options.cache_dir)
	_ensure_dir(options.cache_dir.path_join(result.id))
	_ensure_dir(options.cache_dir.path_join("tmp"))

	var cache: PackRatCache = PackRatCache.load(options.cache_dir)
	var record: PackRatCacheRecord = cache.record(key)
	var metadata: PackRatHttpResponse = PackRatHttpResponse.new()
	var cached_file_exists: bool = record.file_exists()
	var should_download: bool = options.always_download or not cached_file_exists

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
			cache.erase_record(key)
			cache.save()
		return cached_result

	var part_path: String = options.cache_dir.path_join("tmp").path_join("%s.part" % key)
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(part_path)

	var download: PackRatHttpResponse = await _request(url, part_path, options, request)
	if request.is_canceled():
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, "PackRat request was canceled.")

	if not download.ok:
		DirAccess.remove_absolute(part_path)
		if cached_file_exists and not options.always_download:
			result.status = PackRatResult.STATUS_CACHE_HIT
			result.from_cache = true
			result.local_path = record.local_path
			result.add_warning("%s Using the previous cached pack." % download.error)
			record.apply_to_result(result)
			var fallback_result: PackRatResult = _mount_if_pack(result, options)
			if not fallback_result.ok:
				cache.erase_record(key)
				cache.save()
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
	if FileAccess.file_exists(local_path):
		DirAccess.remove_absolute(local_path)

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

	var mounted_result: PackRatResult = _mount_if_pack(result, options)
	if not mounted_result.ok:
		DirAccess.remove_absolute(local_path)
		return mounted_result

	cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result, options))
	var save_error: Error = cache.save()
	if save_error != OK:
		result.add_warning("PackRat loaded the resource pack but could not save cache metadata (error %d)." % save_error)

	return mounted_result


static func _mount_if_pack(result: PackRatResult, options: PackRatOptions) -> PackRatResult:
	var extension: String = result.local_path.get_extension().to_lower()
	if extension != "pck" and extension != "zip":
		return PackRatResult.failed(result.source_url, "PackRat only mounts .pck and .zip files.")

	if extension == "zip" and options.offset != 0:
		return PackRatResult.failed(result.source_url, "Godot only supports nonzero resource pack offsets for .pck files.")

	result.mounted = ProjectSettings.load_resource_pack(result.local_path, options.replace_files, options.offset)
	if not result.mounted:
		return PackRatResult.failed(result.source_url, "Godot could not mount %s." % result.local_path)

	var previous_path: String = str(_mounted_paths_by_id.get(result.id, ""))
	if not previous_path.is_empty() and previous_path != result.local_path:
		result.add_warning(
			"PackRat mounted a different pack for id '%s'. Godot resource packs stay mounted for the life of the process." % result.id
		)
	_mounted_paths_by_id[result.id] = result.local_path

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
	var basename: String = filename.get_basename()
	var token: String = _version_token(url, metadata, options)
	if extension.is_empty():
		extension = _extension_for_response(metadata)

	return cache_dir.path_join(id).path_join("%s-%s.%s" % [basename, token, extension])


static func _version_token(url: String, metadata: PackRatHttpResponse, options: PackRatOptions) -> String:
	if options.has_expected_metadata():
		return _expected_metadata_token(options)

	if not metadata.etag.is_empty():
		return metadata.etag.sha256_text().substr(0, 12)

	if not metadata.last_modified.is_empty() or metadata.content_length > 0:
		return ("%s:%d" % [metadata.last_modified, metadata.content_length]).sha256_text().substr(0, 12)

	return url.sha256_text().substr(0, 12)


static func _id_for_url(url: String, options: PackRatOptions) -> String:
	if not options.id.is_empty():
		return _safe(options.id)

	return _safe(_filename(url).get_basename())


static func _cache_key(url: String, id: String, options: PackRatOptions) -> String:
	if options.has_expected_metadata():
		return "%s-%s" % [id, _expected_metadata_token(options)]

	return "%s-%s" % [id, url.sha256_text().substr(0, 12)]


static func _expected_metadata_token(options: PackRatOptions) -> String:
	return ("expected:%d:%d" % [options.expected_size, options.expected_modified_time]).sha256_text().substr(0, 12)


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
		if remote_modified_time <= 0:
			return "Downloaded pack could not validate expected modified time because Last-Modified was missing or invalid."

		if remote_modified_time != options.expected_modified_time:
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
	var months: PackedStringArray = [
		"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
	]
	for index in range(months.size()):
		if months[index].to_lower() == value.to_lower():
			return index + 1

	return 0


static func _cache_record_matches(value: String, record: PackRatCacheRecord) -> bool:
	if _is_http_url(value):
		return record.source_url == value

	if record.local_path == value:
		return true

	var id: String = record.local_path.get_base_dir().get_file()
	if id == _safe(value):
		return true

	return record.local_path.get_file() == value


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
	var output: String = ""
	for index in range(value.length()):
		var character: String = value.substr(index, 1).to_lower()
		if character in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			output += character
		else:
			output += "_"

	return output if not output.is_empty() else "pack"


static func _url_segment(value: String) -> String:
	return value.strip_edges().trim_prefix("/").trim_suffix("/").uri_encode()


static func _ensure_dir(path: String) -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("PackRat could not create %s (error %d)." % [path, error])


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
			return error

		child = dir.get_next()

	dir.list_dir_end()
	return OK


static func _remove_empty_directory(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var first_child: String = dir.get_next()
	dir.list_dir_end()
	if first_child.is_empty():
		DirAccess.remove_absolute(path)
