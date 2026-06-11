class_name PackRat extends RefCounted
## Static facade for preparing downloadable Godot PCK/ZIP content at runtime.
## [br][br]
## The main API is [method prepare]. It creates temporary [HTTPRequest] nodes
## under the scene tree root as needed, then frees them when each request
## completes or fails to start. No autoload, editor plugin, or persistent helper
## node is required.


## Downloads, freshness-checks, caches, and mounts the pack at [param url].
## [br][br]
## Returns a [PackRatResult] with [member PackRatResult.ok] set to [code]true[/code]
## when the file is ready. [param options] can override cache location,
## replacement behavior, request headers, timeout, and entry path.
static func prepare(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatResult:
	var result: PackRatResult = PackRatResult.new()
	result.source_url = url
	result.id = _id_for_url(url, options)

	if not (url.begins_with("http://") or url.begins_with("https://")):
		return PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs.")

	_ensure_dir(options.cache_dir)
	_ensure_dir(options.cache_dir.path_join(result.id))
	_ensure_dir(options.cache_dir.path_join("tmp"))

	var cache: PackRatCache = PackRatCache.load(options.cache_dir)
	var key: String = _cache_key(url, result.id)
	var record: PackRatCacheRecord = cache.record(key)
	var metadata: PackRatHttpResponse = await _freshness_metadata(url, options)
	var cached_file_exists: bool = record.file_exists()
	var should_download: bool = options.always_download or not cached_file_exists

	if cached_file_exists and not should_download:
		var freshness: String = record.freshness_against(metadata)
		should_download = freshness == "stale"
		if freshness == "unknown":
			result.add_warning("PackRat could not compare remote freshness metadata; using the cached pack.")

	if not should_download:
		result.status = PackRatResult.STATUS_CACHE_HIT
		result.from_cache = true
		result.local_path = record.local_path
		record.apply_to_result(result)
		return _mount_if_pack(result, options)

	var part_path: String = options.cache_dir.path_join("tmp").path_join("%s.part" % key)
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(part_path)

	var download: PackRatHttpResponse = await _request(url, part_path, options)
	if not download.ok:
		if cached_file_exists:
			result.status = PackRatResult.STATUS_CACHE_HIT
			result.from_cache = true
			result.local_path = record.local_path
			result.add_warning("%s Using the previous cached pack." % download.error)
			record.apply_to_result(result)
			return _mount_if_pack(result, options)

		return PackRatResult.failed(url, download.error)

	var file_size: int = FileAccess.get_size(part_path)
	if file_size <= 0:
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, "Downloaded pack was empty.")

	var has_remote_freshness: bool = metadata.has_freshness()
	metadata.merge_from(download)
	var local_path: String = _local_path(url, options.cache_dir, result.id, metadata)
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

	cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result))
	var save_error: Error = cache.save()
	if save_error != OK:
		result.add_warning("PackRat prepared the pack but could not save cache metadata (error %d)." % save_error)

	if not has_remote_freshness:
		result.add_warning("PackRat cached this URL without comparable freshness headers.")

	return _mount_if_pack(result, options)


static func _mount_if_pack(result: PackRatResult, options: PackRatOptions) -> PackRatResult:
	var extension: String = result.local_path.get_extension().to_lower()
	if extension == "pck" or extension == "zip":
		result.mounted = ProjectSettings.load_resource_pack(result.local_path, options.replace_files)
		if not result.mounted:
			return PackRatResult.failed(result.source_url, "Godot could not mount %s." % result.local_path)

	result.ok = true
	result.entry_path = options.entry_path
	return result


static func _freshness_metadata(url: String, options: PackRatOptions) -> PackRatHttpResponse:
	var response: PackRatHttpResponse = await _request(url, "", options, HTTPClient.METHOD_HEAD)
	if not response.ok:
		return PackRatHttpResponse.new()

	return response


static func _request(
	url: String,
	download_path: String,
	options: PackRatOptions,
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

	var start_error: Error = request.request(url, options.request_headers, method)
	if start_error != OK:
		request.queue_free()
		return PackRatHttpResponse.failed("HTTPRequest failed to start (error %d)." % start_error)

	var completed: Array = await request.request_completed
	request.queue_free()

	var result_code: HTTPRequest.Result = completed[0]
	var response_code: int = completed[1]
	var headers: PackedStringArray = completed[2]

	return PackRatHttpResponse.from_completed(result_code, response_code, headers)


static func _local_path(url: String, cache_dir: String, id: String, metadata: PackRatHttpResponse) -> String:
	var filename: String = _filename(url)
	var extension: String = filename.get_extension()
	var basename: String = filename.get_basename()
	var token: String = _version_token(url, metadata)
	if extension.is_empty():
		return cache_dir.path_join(id).path_join("%s-%s" % [basename, token])

	return cache_dir.path_join(id).path_join("%s-%s.%s" % [basename, token, extension])


static func _version_token(url: String, metadata: PackRatHttpResponse) -> String:
	if not metadata.etag.is_empty():
		return metadata.etag.sha256_text().substr(0, 12)

	if not metadata.last_modified.is_empty() or metadata.content_length > 0:
		return ("%s:%d" % [metadata.last_modified, metadata.content_length]).sha256_text().substr(0, 12)

	return url.sha256_text().substr(0, 12)


static func _id_for_url(url: String, options: PackRatOptions) -> String:
	if not options.id.is_empty():
		return _safe(options.id)

	return _safe(_filename(url).get_basename())


static func _cache_key(url: String, id: String) -> String:
	return "%s-%s" % [id, url.sha256_text().substr(0, 12)]


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


static func _safe(value: String) -> String:
	var output: String = ""
	for index in range(value.length()):
		var character: String = value.substr(index, 1).to_lower()
		if character in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			output += character
		else:
			output += "_"

	return output if not output.is_empty() else "pack"


static func _ensure_dir(path: String) -> void:
	var error: Error = DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("PackRat could not create %s (error %d)." % [path, error])
