class_name PackRat extends RefCounted
## Static facade for loading remote Godot PCK/ZIP resource packs at runtime.
## [br][br]
## The main API is [method load_resource_pack]. It creates temporary
## [HTTPRequest] nodes under the scene tree root as needed, then frees them
## when each request completes or fails to start. No autoload, editor plugin,
## or persistent helper node is required.


## Downloads, freshness-checks, caches, and mounts the resource pack at [param url].
## [br][br]
## Returns a [PackRatResult] with [member PackRatResult.ok] set to [code]true[/code]
## when the file is ready. [param options] can override cache location,
## replacement behavior, request headers, timeout, and entry path.
static func load_resource_pack(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatResult:
	if not PackRatCachePaths.is_http_url(url):
		return PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs.")

	var request_options: PackRatOptions = options.copy()
	if not PackRatCachePaths.is_safe_cache_dir(request_options.cache_dir):
		return PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments.")
	request_options.cache_dir = PackRatCachePaths.normalized_cache_dir(request_options.cache_dir)
	var id: String = PackRatCachePaths.id_for_url(url, request_options)
	var key: String = PackRatCachePaths.cache_key(url, id, request_options)
	var fast_result: PackRatResult = PackRatLoader.fast_cache_result(url, id, key, request_options)
	if fast_result != null:
		return fast_result

	var request: PackRatRequest = load_resource_pack_async(url, request_options)
	if request.is_completed():
		return request.result

	await request.completed
	return request.result


## Starts loading the resource pack at [param url] and returns a cancelable request.
static func load_resource_pack_async(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatRequest:
	if not PackRatCachePaths.is_http_url(url):
		var invalid_request: PackRatRequest = PackRatRequest.new()
		_finish_request_next_frame(invalid_request, PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs."))
		return invalid_request

	var request_options: PackRatOptions = options.copy()
	if not PackRatCachePaths.is_safe_cache_dir(request_options.cache_dir):
		var invalid_cache_request: PackRatRequest = PackRatRequest.new()
		_finish_request_next_frame(invalid_cache_request, PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments."))
		return invalid_cache_request
	request_options.cache_dir = PackRatCachePaths.normalized_cache_dir(request_options.cache_dir)

	var id: String = PackRatCachePaths.id_for_url(url, request_options)
	var key: String = PackRatCachePaths.cache_key(url, id, request_options)
	var request: PackRatRequest = PackRatRequest.new()
	request._setup(url, request_options, id, key)
	var fast_result: PackRatResult = PackRatLoader.fast_cache_result(url, id, key, request_options)
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
	if not PackRatCachePaths.is_safe_cache_dir(options.cache_dir):
		return ERR_INVALID_PARAMETER

	var cache_dir: String = PackRatCachePaths.normalized_cache_dir(options.cache_dir)
	PackRatCacheFiles.ensure_dir(cache_dir)
	var first_error: Error = PackRatCacheFiles.clear_part_files(cache_dir)
	var clear_error: Error = PackRatCacheFiles.clear_unmounted_cache_files(cache_dir)
	if first_error == OK:
		first_error = clear_error

	var cache: PackRatCache = PackRatCache.load(cache_dir)
	for key in cache.keys():
		cache.erase_record(key)

	var save_error: Error = cache.save()
	if first_error == OK:
		first_error = save_error

	PackRatLoader.clear_fast_cache()
	return first_error


## Deletes cached entries matching [param value] as a URL, ID, cached filename, or path.
## [br][br]
## This only removes disk cache entries. Already mounted resource packs remain
## mounted until the process exits because Godot does not expose per-pack unload.
static func clear_cached_resource_pack(value: String, options: PackRatOptions = PackRatOptions.new()) -> Error:
	if not PackRatCachePaths.is_safe_cache_dir(options.cache_dir):
		return ERR_INVALID_PARAMETER

	var cache_dir: String = PackRatCachePaths.normalized_cache_dir(options.cache_dir)
	var clear_options: PackRatOptions = options.copy()
	clear_options.cache_dir = cache_dir
	var cache: PackRatCache = PackRatCache.load(cache_dir)
	var keys: PackedStringArray = cache.keys()
	var matched: bool = false
	var first_error: Error = OK
	var matched_ids: PackedStringArray = []

	for key in keys:
		var record: PackRatCacheRecord = cache.record(key)
		if not PackRatCachePaths.record_matches(value, key, record):
			continue

		matched = true
		var record_id: String = PackRatCachePaths.record_id(key, record)
		if not matched_ids.has(record_id):
			matched_ids.append(record_id)
		cache.erase_record(key)
		PackRatLoader.forget_fast_cache(key, clear_options)
		var remove_error: Error = PackRatCacheFiles.remove_cache_file(record.local_path, cache_dir)
		if PackRatCacheFiles.is_real_remove_error(remove_error) and first_error == OK:
			first_error = remove_error

	if not matched:
		var direct_id: String = PackRatCachePaths.id_from_cached_filename(value)
		var direct_path: String = value if value.begins_with("user://") else cache_dir.path_join(value)
		if not direct_id.is_empty() and PackRatCachePaths.is_cache_child_path(direct_path, cache_dir) and FileAccess.file_exists(direct_path):
			matched = true
			matched_ids.append(direct_id)
		elif not PackRatCachePaths.is_http_url(value) and PackRatCacheFiles.has_matching_cache_file(cache_dir, PackRatCachePaths.safe_name(value)):
			matched = true
			matched_ids.append(PackRatCachePaths.safe_name(value))

	if not matched:
		return ERR_DOES_NOT_EXIST

	for key in cache.keys():
		var record: PackRatCacheRecord = cache.record(key)
		if not matched_ids.has(PackRatCachePaths.record_id(key, record)):
			continue

		cache.erase_record(key)
		PackRatLoader.forget_fast_cache(key, clear_options)
		var remove_error: Error = PackRatCacheFiles.remove_cache_file(record.local_path, cache_dir)
		if PackRatCacheFiles.is_real_remove_error(remove_error) and first_error == OK:
			first_error = remove_error

	for id in matched_ids:
		var cleanup_error: Error = PackRatCacheFiles.clear_unmounted_cache_files(cache_dir, id)
		if PackRatCacheFiles.is_real_remove_error(cleanup_error) and first_error == OK:
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


static func _url_segment(value: String) -> String:
	return value.strip_edges().trim_prefix("/").trim_suffix("/").uri_encode()
