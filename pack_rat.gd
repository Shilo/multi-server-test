class_name PackRat extends RefCounted
## Loads remote Godot PCK/ZIP resource packs at runtime.
## [br][br]
## PackRat is a static facade around runtime HTTP downloads, local pack sources,
## [code]user://[/code] cache files, and [method ProjectSettings.load_resource_pack].
## It does not require an autoload, editor plugin, manifest, provider system, or
## persistent helper node.


## Loads the resource pack at [param url].
## [br][br]
## Parameters:
## - [param url]: HTTP(S) URL or local path for a Godot [code].pck[/code] or [code].zip[/code].
## - [param options]: Optional cache, validation, HTTP, and mount settings.
## [br][br]
## Returns:
## - A [PackRatResult] with [member PackRatResult.ok] set to [code]true[/code] when
## the pack is cached, mounted, and ready to use.
static func load_resource_pack(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatResult:
	var request_options: PackRatOptions = options.copy()
	var local_pack_path: String = _local_pack_path_for_url(url, request_options)
	if not _can_load_source(url, request_options, local_pack_path):
		return PackRatResult.failed(url, "PackRat only accepts HTTP(S) URLs, local .pck/.zip files, or editor export presets.")

	if not PackRatCachePaths.is_safe_cache_dir(request_options.cache_dir):
		return PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments.")
	request_options.cache_dir = PackRatCachePaths.normalized_cache_dir(request_options.cache_dir)
	var id: String = PackRatCachePaths.id_for_url(url, request_options)
	var key: String = _cache_key_for_source(url, id, request_options)
	if local_pack_path.is_empty() and not _uses_editor_pack_export(request_options):
		var fast_result: PackRatResult = PackRatLoader.fast_cache_result(url, id, key, request_options)
		if fast_result != null:
			return fast_result

	var request: PackRatRequest = load_resource_pack_async(url, request_options)
	if request.is_completed():
		return request.result

	await request.completed
	return request.result


## Starts loading the resource pack at [param url] without waiting for completion.
## [br][br]
## Parameters:
## - [param url]: HTTP(S) URL or local path for a Godot [code].pck[/code] or [code].zip[/code].
## - [param options]: Optional cache, validation, HTTP, and mount settings.
## [br][br]
## Returns:
## - A cancelable [PackRatRequest] that emits progress and completion signals.
static func load_resource_pack_async(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatRequest:
	var request_options: PackRatOptions = options.copy()
	var local_pack_path: String = _local_pack_path_for_url(url, request_options)
	if not _can_load_source(url, request_options, local_pack_path):
		var invalid_request: PackRatRequest = PackRatRequest.new()
		_finish_request_next_frame(invalid_request, PackRatResult.failed(url, "PackRat only accepts HTTP(S) URLs, local .pck/.zip files, or editor export presets."))
		return invalid_request

	if not PackRatCachePaths.is_safe_cache_dir(request_options.cache_dir):
		var invalid_cache_request: PackRatRequest = PackRatRequest.new()
		_finish_request_next_frame(invalid_cache_request, PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments."))
		return invalid_cache_request
	request_options.cache_dir = PackRatCachePaths.normalized_cache_dir(request_options.cache_dir)

	var id: String = PackRatCachePaths.id_for_url(url, request_options)
	var key: String = _cache_key_for_source(url, id, request_options)
	var request_url: String = _request_url_for_source(url, request_options)
	var request: PackRatRequest = PackRatRequest.new()
	request._setup(url, request_url, request_options, id, key, local_pack_path)
	if local_pack_path.is_empty() and not _uses_editor_pack_export(request_options):
		var fast_result: PackRatResult = PackRatLoader.fast_cache_result(url, id, key, request_options)
		if fast_result != null:
			_finish_request_next_frame(request, fast_result)
			return request

	var tree: SceneTree = Engine.get_main_loop()
	if tree == null or tree.root == null:
		request._finish(PackRatResult.failed(url, "PackRat needs a running SceneTree."))
		return request

	var runner: PackRatRequestRunner = PackRatRequestRunner.new()
	if tree.root.is_node_ready():
		tree.root.add_child(runner)
	else:
		tree.root.add_child.call_deferred(runner)
	runner.start.call_deferred(request)
	return request


static func _can_load_source(url: String, options: PackRatOptions, local_pack_path: String) -> bool:
	return (
		PackRatCachePaths.is_http_url(url)
		or _uses_editor_pack_export(options)
		or not local_pack_path.is_empty()
	)


static func _local_pack_path_for_url(url: String, options: PackRatOptions) -> String:
	if _uses_editor_pack_export(options):
		return ""

	if PackRatLocalFileClient.is_local_pack_source(url):
		return PackRatLocalFileClient.path_from_source(url)

	return ""


static func _uses_editor_pack_export(options: PackRatOptions) -> bool:
	return PackRatEditorPackExport.is_available() and not options.editor_pack_export_preset.strip_edges().is_empty()


static func _request_url_for_source(url: String, options: PackRatOptions) -> String:
	if not PackRatCachePaths.is_http_url(url):
		return url

	if not options.auto_project_version_query:
		return url

	var query_key: String = options.project_version_query_key.strip_edges()
	if query_key.is_empty():
		return url

	var project_version: Variant = ProjectSettings.get_setting("application/config/version")
	if typeof(project_version) == TYPE_NIL:
		return url

	var clean_version: String = str(project_version).strip_edges()
	if clean_version.is_empty():
		return url

	return versioned_url_if_missing(url, clean_version, query_key)


static func _cache_key_for_source(url: String, id: String, options: PackRatOptions) -> String:
	if not _uses_editor_pack_export(options):
		return PackRatCachePaths.cache_key(url, id, options)

	var preset_name: String = options.editor_pack_export_preset.strip_edges()
	var editor_url: String = "%s#pack_rat_editor_export_preset=%s" % [url, preset_name]
	var editor_id: String = "%s-editor-%s" % [id, PackRatCachePaths.safe_name(preset_name)]
	return PackRatCachePaths.cache_key(editor_url, editor_id, options)


## Deletes every removable PackRat cache file and cache metadata entry.
## [br][br]
## Parameters:
## - [param options]: Selects the cache directory to clear.
## [br][br]
## Returns:
## - [constant OK] on success, or an [enum Error] value when cleanup fails.
static func clear_cache(options: PackRatOptions = PackRatOptions.new()) -> Error:
	if not PackRatCachePaths.is_safe_cache_dir(options.cache_dir):
		return ERR_INVALID_PARAMETER

	var cache_dir: String = PackRatCachePaths.normalized_cache_dir(options.cache_dir)
	PackRatCacheFiles.ensure_dir(cache_dir)
	var first_error: Error = PackRatCacheFiles.clear_part_files(cache_dir)
	var clear_error: Error = PackRatCacheFiles.clear_unmounted_cache_files(cache_dir)
	if first_error == OK:
		first_error = clear_error
	var editor_metadata_error: Error = PackRatCacheFiles.clear_editor_export_metadata(cache_dir)
	if first_error == OK:
		first_error = editor_metadata_error

	var cache: PackRatCache = PackRatCache.load(cache_dir)
	for key in cache.keys():
		cache.erase_record(key)

	var save_error: Error = cache.save()
	if first_error == OK:
		first_error = save_error

	PackRatLoader.clear_fast_cache()
	return first_error


## Deletes cached entries matching [param value].
## [br][br]
## Parameters:
## - [param value]: A pack URL, stable pack ID, cached filename, or cached path.
## - [param options]: Selects the cache directory to search.
## [br][br]
## Returns:
## - [constant OK] when a matching cache entry was removed. Already mounted packs
## remain mounted until process exit because Godot does not expose per-pack unload.
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


## Builds a direct GitHub Release asset URL.
## [br][br]
## Parameters:
## - [param owner]: GitHub user or organization name.
## - [param repo]: GitHub repository name.
## - [param filename]: Release asset filename.
## - [param tag]: Release tag, or [code]"latest"[/code] for the latest release.
## [br][br]
## Returns:
## - A GitHub Release download URL. This helper does not call the GitHub API.
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


## Builds a GitHub Pages project URL.
## [br][br]
## Parameters:
## - [param owner]: GitHub user or organization name.
## - [param repo]: GitHub repository name.
## - [param path]: Optional path inside the Pages site.
## [br][br]
## Returns:
## - A [code]https://owner.github.io/repo[/code] URL. This helper does not call the
## GitHub API.
static func github_pages_url(owner: String, repo: String, path: String = "") -> String:
	var clean_path: String = path.strip_edges().trim_prefix("/")
	var url: String = "https://%s.github.io/%s" % [
		_url_segment(owner),
		_url_segment(repo),
	]
	if clean_path.is_empty():
		return url

	return "%s/%s" % [url, _url_path(clean_path)]


## Checks whether direct GitHub Release asset downloads are suitable here.
## [br][br]
## Returns:
## - [code]true[/code] for native/editor clients, and [code]false[/code] for Web
## exports where browser CORS blocks GitHub's release asset redirect chain.
static func can_download_github_releases() -> bool:
	return not OS.has_feature("web")


## Sets a stable content-version query value on [param url].
## [br][br]
## Parameters:
## - [param url]: Base URL for a remote pack or static file.
## - [param version]: Content version such as a build number, tag, or file token.
## - [param version_key]: Query key to set. Defaults to [code]"v"[/code].
## [br][br]
## Returns:
## - [param url] with [param version_key] set to [param version]. Existing matching
## query keys are replaced, URL fragments are preserved, and empty key/version
## values return [param url] unchanged.
static func versioned_url(url: String, version: Variant, version_key: String = "v") -> String:
	return _versioned_url_internal(url, version, version_key, true)


## Sets a stable content-version query value on [param url] only when missing.
## [br][br]
## Parameters:
## - [param url]: Base URL for a remote pack or static file.
## - [param version]: Content version such as a build number, tag, or file token.
## - [param version_key]: Query key to append. Defaults to [code]"v"[/code].
## [br][br]
## Returns:
## - [param url] with [param version_key] appended only when that key does not
## already exist. Existing matching query keys are preserved unchanged, URL
## fragments are preserved, and empty key/version values return [param url]
## unchanged.
static func versioned_url_if_missing(url: String, version: Variant, version_key: String = "v") -> String:
	return _versioned_url_internal(url, version, version_key, false)


static func _versioned_url_internal(
	url: String,
	version: Variant,
	version_key: String,
	replace_existing: bool
) -> String:
	var clean_key: String = version_key.strip_edges()
	var clean_version: String = str(version).strip_edges()
	if clean_key.is_empty() or clean_version.is_empty():
		return url
	var encoded_key: String = clean_key.uri_encode()
	var encoded_version: String = clean_version.uri_encode()

	var fragment: String = ""
	var base_url: String = url
	var fragment_index: int = url.find("#")
	if fragment_index >= 0:
		base_url = url.substr(0, fragment_index)
		fragment = url.substr(fragment_index)

	var path_url: String = base_url
	var query: String = ""
	var query_index: int = base_url.find("?")
	if query_index >= 0:
		path_url = base_url.substr(0, query_index)
		query = base_url.substr(query_index + 1)

	var replaced: bool = false
	var output_parts: PackedStringArray = []
	for part in query.split("&", false):
		var key: String = part.get_slice("=", 0)
		if key == clean_key or key == encoded_key:
			if not replace_existing:
				return url
			if not replaced:
				output_parts.append("%s=%s" % [encoded_key, encoded_version])
				replaced = true
			continue

		output_parts.append(part)

	if not replaced:
		output_parts.append("%s=%s" % [encoded_key, encoded_version])

	return "%s?%s%s" % [path_url, "&".join(output_parts), fragment]


## Joins a static host base URL and path.
## [br][br]
## Parameters:
## - [param base_url]: Static host or directory URL.
## - [param path]: Relative path to append.
## [br][br]
## Returns:
## - A URL with exactly one slash between [param base_url] and [param path].
static func join_url(base_url: String, path: String) -> String:
	var clean_base: String = base_url.strip_edges().trim_suffix("/")
	var clean_path: String = path.strip_edges().trim_prefix("/")
	if clean_base.is_empty():
		return clean_path
	if clean_path.is_empty():
		return clean_base

	return "%s/%s" % [clean_base, clean_path]


## Reads local file metadata for [param path].
## [br][br]
## Parameters:
## - [param path]: Local path to inspect.
## [br][br]
## Returns:
## - A [PackRatFileMetadata] containing file size and modified time, or an error
## message when the file cannot be read.
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
			request._finish(PackRatResult.failed(request.url, PackRatResult.ERROR_CANCELED))
			return

		request._finish(result)
	, CONNECT_ONE_SHOT)


static func _url_segment(value: String) -> String:
	return value.strip_edges().trim_prefix("/").trim_suffix("/").uri_encode()


static func _url_path(path: String) -> String:
	var segments: PackedStringArray = path.split("/", false)
	for index in range(segments.size()):
		segments[index] = segments[index].uri_encode()
	return "/".join(segments)
