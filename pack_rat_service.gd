class_name _Service
extends Node


func prepare(url: String, options: PackRatOptions) -> PackRatResult:
	var result := PackRatResult.new()
	result.source_url = url
	result.id = _id_for_url(url, options)

	if not (url.begins_with("http://") or url.begins_with("https://")):
		return PackRatResult.failed(url, "PackRat MVP only accepts HTTP(S) URLs.")

	_ensure_dir(options.cache_dir)
	_ensure_dir(options.cache_dir.path_join(result.id))
	_ensure_dir(options.cache_dir.path_join("tmp"))

	var cache := _load_cache(options.cache_dir)
	var items: Dictionary = cache.get("items", {})
	var key := _cache_key(url, result.id)
	var record: Dictionary = items.get(key, {})
	var metadata := await _head(url, options)
	var cached_path := str(record.get("local_path", ""))
	var cached_file_exists := not cached_path.is_empty() and FileAccess.file_exists(cached_path)
	var should_download := options.always_download or not cached_file_exists

	if cached_file_exists and not should_download:
		var freshness := _freshness(record, metadata)
		should_download = freshness == "stale"
		if freshness == "unknown":
			result.add_warning("PackRat could not compare remote freshness metadata; using the cached pack.")

	if not should_download:
		result.status = PackRatResult.STATUS_CACHE_HIT
		result.from_cache = true
		result.local_path = cached_path
		_apply_record(result, record)
		return _mount_if_pack(result, options)

	var part_path := options.cache_dir.path_join("tmp").path_join("%s.part" % key)
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(part_path)

	var download := await _download(url, part_path, options)
	if not bool(download.get("ok", false)):
		if cached_file_exists:
			result.status = PackRatResult.STATUS_CACHE_HIT
			result.from_cache = true
			result.local_path = cached_path
			result.add_warning("%s Using the previous cached pack." % str(download.get("error", "")))
			_apply_record(result, record)
			return _mount_if_pack(result, options)

		return PackRatResult.failed(url, str(download.get("error", "Download failed.")))

	var file_size := FileAccess.get_size(part_path)
	if file_size <= 0:
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, "Downloaded pack was empty.")

	var has_remote_freshness := not str(metadata.get("etag", "")).is_empty()
	has_remote_freshness = has_remote_freshness or not str(metadata.get("last_modified", "")).is_empty()
	has_remote_freshness = has_remote_freshness or int(metadata.get("content_length", 0)) > 0
	metadata.merge(download, true)
	var local_path := _local_path(url, options.cache_dir, result.id, metadata)
	if FileAccess.file_exists(local_path):
		DirAccess.remove_absolute(local_path)

	var move_error := DirAccess.rename_absolute(part_path, local_path)
	if move_error != OK:
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, "Could not move downloaded pack into cache (error %d)." % move_error)

	result.status = PackRatResult.STATUS_DOWNLOADED
	result.local_path = local_path
	result.content_length = file_size
	_apply_metadata(result, metadata)

	items[key] = _record(url, local_path, result)
	cache["items"] = items
	var save_error := _save_cache(options.cache_dir, cache)
	if save_error != OK:
		result.add_warning("PackRat prepared the pack but could not save cache metadata (error %d)." % save_error)

	if not has_remote_freshness:
		result.add_warning("PackRat cached this URL without comparable freshness headers.")

	return _mount_if_pack(result, options)


func _mount_if_pack(result: PackRatResult, options: PackRatOptions) -> PackRatResult:
	var extension := result.local_path.get_extension().to_lower()
	if extension == "pck" or extension == "zip":
		result.mounted = ProjectSettings.load_resource_pack(result.local_path, options.replace_files)
		if not result.mounted:
			return PackRatResult.failed(result.source_url, "Godot could not mount %s." % result.local_path)

	result.ok = true
	result.entry_path = options.entry_path
	return result


func _head(url: String, options: PackRatOptions) -> Dictionary:
	var response := await _request(url, "", HTTPClient.METHOD_HEAD, options)
	if not bool(response.get("ok", false)):
		return {}

	return response


func _download(url: String, path: String, options: PackRatOptions) -> Dictionary:
	return await _request(url, path, HTTPClient.METHOD_GET, options)


func _request(url: String, download_path: String, method: int, options: PackRatOptions) -> Dictionary:
	var request := HTTPRequest.new()
	request.accept_gzip = false
	request.download_file = download_path
	request.max_redirects = options.max_redirects
	request.timeout = options.timeout_seconds
	add_child(request)

	var start_error := request.request(url, options.request_headers, method)
	if start_error != OK:
		request.queue_free()
		return {"ok": false, "error": "HTTPRequest failed to start (error %d)." % start_error}

	var completed: Array = await request.request_completed
	request.queue_free()

	var result_code := int(completed[0])
	var response_code := int(completed[1])
	var headers: PackedStringArray = completed[2]
	var headers_by_name := _headers(headers)
	var ok := result_code == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300

	return {
		"ok": ok,
		"error": "HTTP request failed (result %d, response %d)." % [result_code, response_code],
		"response_code": response_code,
		"etag": str(headers_by_name.get("etag", "")),
		"last_modified": str(headers_by_name.get("last-modified", "")),
		"content_length": int(str(headers_by_name.get("content-length", "0"))),
	}


func _headers(headers: PackedStringArray) -> Dictionary:
	var output := {}
	for raw_header in headers:
		var header := str(raw_header)
		var separator := header.find(":")
		if separator <= 0:
			continue

		output[header.substr(0, separator).strip_edges().to_lower()] = header.substr(separator + 1).strip_edges()

	return output


func _freshness(record: Dictionary, metadata: Dictionary) -> String:
	if metadata.is_empty():
		return "unknown"

	for key in ["etag", "last_modified"]:
		var remote_value := str(metadata.get(key, ""))
		var cached_value := str(record.get(key, ""))
		if not remote_value.is_empty() and not cached_value.is_empty():
			return "fresh" if remote_value == cached_value else "stale"

	var remote_length := int(metadata.get("content_length", 0))
	var cached_length := int(record.get("content_length", 0))
	if remote_length > 0 and cached_length > 0:
		return "fresh" if remote_length == cached_length else "stale"

	return "unknown"


func _load_cache(cache_dir: String) -> Dictionary:
	var path := cache_dir.path_join("cache.json")
	if not FileAccess.file_exists(path):
		return {"schema": 1, "items": {}}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"schema": 1, "items": {}}

	var parsed := JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.has("items") and (parsed["items"] is Dictionary):
		return parsed

	return {"schema": 1, "items": {}}


func _save_cache(cache_dir: String, cache: Dictionary) -> Error:
	var path := cache_dir.path_join("cache.json")
	var part_path := "%s.tmp" % path
	var file := FileAccess.open(part_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_string(JSON.stringify(cache, "\t"))
	file = null

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	return DirAccess.rename_absolute(part_path, path)


func _record(url: String, local_path: String, result: PackRatResult) -> Dictionary:
	return {
		"source_url": url,
		"local_path": local_path,
		"etag": result.etag,
		"last_modified": result.last_modified,
		"content_length": result.content_length,
		"updated_at_unix": int(Time.get_unix_time_from_system()),
	}


func _apply_record(result: PackRatResult, record: Dictionary) -> void:
	result.etag = str(record.get("etag", ""))
	result.last_modified = str(record.get("last_modified", ""))
	result.content_length = int(record.get("content_length", 0))


func _apply_metadata(result: PackRatResult, metadata: Dictionary) -> void:
	result.etag = str(metadata.get("etag", ""))
	result.last_modified = str(metadata.get("last_modified", ""))
	var remote_length := int(metadata.get("content_length", 0))
	if remote_length > 0:
		result.content_length = remote_length
	result.response_code = int(metadata.get("response_code", 0))


func _local_path(url: String, cache_dir: String, id: String, metadata: Dictionary) -> String:
	var filename := _filename(url)
	var extension := filename.get_extension()
	var basename := filename.get_basename()
	var token := _version_token(url, metadata)
	if extension.is_empty():
		return cache_dir.path_join(id).path_join("%s-%s" % [basename, token])

	return cache_dir.path_join(id).path_join("%s-%s.%s" % [basename, token, extension])


func _version_token(url: String, metadata: Dictionary) -> String:
	var etag := str(metadata.get("etag", ""))
	if not etag.is_empty():
		return etag.sha256_text().substr(0, 12)

	var last_modified := str(metadata.get("last_modified", ""))
	var content_length := int(metadata.get("content_length", 0))
	if not last_modified.is_empty() or content_length > 0:
		return ("%s:%d" % [last_modified, content_length]).sha256_text().substr(0, 12)

	return url.sha256_text().substr(0, 12)


func _id_for_url(url: String, options: PackRatOptions) -> String:
	if not options.id.is_empty():
		return _safe(options.id)

	return _safe(_filename(url).get_basename())


func _cache_key(url: String, id: String) -> String:
	return "%s-%s" % [id, url.sha256_text().substr(0, 12)]


func _filename(url: String) -> String:
	var clean_url := url
	var query_index := clean_url.find("?")
	if query_index >= 0:
		clean_url = clean_url.substr(0, query_index)

	var hash_index := clean_url.find("#")
	if hash_index >= 0:
		clean_url = clean_url.substr(0, hash_index)

	var filename := clean_url.get_file()
	return filename if not filename.is_empty() else "pack.pck"


func _safe(value: String) -> String:
	var output := ""
	for index in range(value.length()):
		var character := value.substr(index, 1).to_lower()
		if character in "abcdefghijklmnopqrstuvwxyz0123456789._-":
			output += character
		else:
			output += "_"

	return output if not output.is_empty() else "pack"


func _ensure_dir(path: String) -> void:
	var error := DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("PackRat could not create %s (error %d)." % [path, error])
