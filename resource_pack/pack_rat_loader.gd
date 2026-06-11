class_name PackRatLoader extends RefCounted
## Internal loader that coordinates PackRat cache, HTTP, and mount behavior.

static var _fast_cache_records: Dictionary = {}
static var _fast_cache_signatures: Dictionary = {}


## Loads, caches, and mounts the resource pack described by [param request].
static func load(request: PackRatRequest) -> PackRatResult:
	var url: String = request.url
	var options: PackRatOptions = request.options
	var id: String = request.id
	var key: String = request.cache_key
	var result: PackRatResult = PackRatResult.new()
	result.source_url = url
	result.id = id
	if request.is_canceled():
		return PackRatResult.failed(url, PackRatResult.ERROR_CANCELED)
	if not PackRatCachePaths.is_safe_cache_dir(options.cache_dir):
		return PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments.")

	PackRatCacheFiles.ensure_dir(options.cache_dir)

	var cache: PackRatCache = PackRatCache.load(options.cache_dir)
	var record: PackRatCacheRecord = cache.record(key)
	var metadata: PackRatHttpResponse = PackRatHttpResponse.new()
	var cached_file_exists: bool = record.file_exists()
	if not record.local_path.is_empty() and not cached_file_exists:
		cache.erase_record(key)
		forget_fast_cache(key, options)
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
		metadata = await PackRatHttpClient.freshness_metadata(url, options, request)
		if request.is_canceled():
			return PackRatResult.failed(url, PackRatResult.ERROR_CANCELED)

		var freshness: String = record.freshness_against(metadata)
		should_download = freshness == "stale"
		if freshness == "unknown":
			result.add_warning("PackRat could not compare remote freshness metadata; using the cached pack.")

	if not should_download:
		result.status = PackRatResult.STATUS_CACHE_HIT
		result.from_cache = true
		result.local_path = record.local_path
		record.apply_to_result(result)
		var cached_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
		if not cached_result.ok:
			_evict_cache_record(cache, key, record.local_path, options)
		else:
			remember_fast_cache(key, url, cached_result, options)
		return cached_result

	PackRatCacheFiles.ensure_dir(options.cache_dir.path_join("tmp"))
	var part_path: String = options.cache_dir.path_join("tmp").path_join("%s-%d.part" % [key, request.get_instance_id()])
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(part_path)

	var download: PackRatHttpResponse = await PackRatHttpClient.request(url, part_path, options, request)
	if request.is_canceled():
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(url, PackRatResult.ERROR_CANCELED)

	if not download.ok:
		DirAccess.remove_absolute(part_path)
		if cached_file_exists and not options.always_download and not cached_expected_size_mismatch:
			result.status = PackRatResult.STATUS_CACHE_HIT
			result.from_cache = true
			result.local_path = record.local_path
			result.add_warning("%s Using the previous cached pack." % download.error)
			record.apply_to_result(result)
			var fallback_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
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
	var local_path: String = PackRatCachePaths.local_path(url, options.cache_dir, result.id, metadata, options)
	if (
		FileAccess.file_exists(local_path)
		and not PackRatMountRegistry.is_mounted_path(local_path)
		and not options.always_download
		and not cached_expected_size_mismatch
	):
		result.status = PackRatResult.STATUS_DOWNLOADED
		result.from_cache = false
		result.local_path = local_path
		result.content_length = FileAccess.get_size(local_path)
		metadata.apply_to_result(result)
		var existing_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
		if existing_result.ok:
			DirAccess.remove_absolute(part_path)
			cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result, options))
			cache.save()
			remember_fast_cache(key, url, existing_result, options)
			return existing_result

		_evict_cache_record(cache, key, local_path, options, false)

	if FileAccess.file_exists(local_path):
		if PackRatMountRegistry.is_mounted_path(local_path):
			local_path = PackRatCachePaths.unused_cache_path(local_path, request.get_instance_id())
		else:
			var remove_error: Error = PackRatCacheFiles.remove_cache_file(local_path, options.cache_dir)
			if PackRatCacheFiles.is_real_remove_error(remove_error):
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
		and PackRatHttpResponse.parse_http_date_unix(metadata.last_modified) <= 0
	):
		result.add_warning("PackRat could not compare expected modified time because Last-Modified was missing or invalid.")

	var mounted_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
	if not mounted_result.ok:
		PackRatCacheFiles.remove_cache_file(local_path, options.cache_dir)
		return mounted_result

	var previous_local_path: String = record.local_path
	var previous_mounted_path: String = PackRatMountRegistry.mounted_path_for_id(result.id)
	if (
		not previous_local_path.is_empty()
		and previous_local_path != local_path
		and previous_local_path != previous_mounted_path
	):
		PackRatCacheFiles.remove_cache_file(previous_local_path, options.cache_dir)

	_cleanup_old_versions(cache, key, result.id, local_path, options, result)
	cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result, options))
	var save_error: Error = cache.save()
	if save_error != OK:
		result.add_warning("PackRat loaded the resource pack but could not save cache metadata (error %d)." % save_error)

	remember_fast_cache(key, url, mounted_result, options)
	return mounted_result


## Returns a mounted in-process cache hit, or [code]null[/code] when disk/HTTP work is needed.
static func fast_cache_result(url: String, id: String, key: String, options: PackRatOptions) -> PackRatResult:
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

	var signature: String = PackRatMountRegistry.mount_signature(record.local_path, options)
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
	return PackRatMountRegistry.mount_if_pack(result, options)


## Stores a successful result in the in-process cache-hit map.
static func remember_fast_cache(key: String, url: String, result: PackRatResult, options: PackRatOptions) -> void:
	if not result.ok:
		return

	var fast_key: String = _fast_cache_key(key, options)
	var record: PackRatCacheRecord = PackRatCacheRecord.from_result(url, result.local_path, result, options)
	_fast_cache_records[fast_key] = record.to_dictionary()
	_fast_cache_signatures[fast_key] = PackRatMountRegistry.mount_signature(result.local_path, options)


## Removes one in-process cache-hit entry.
static func forget_fast_cache(key: String, options: PackRatOptions) -> void:
	var fast_key: String = _fast_cache_key(key, options)
	_fast_cache_records.erase(fast_key)
	_fast_cache_signatures.erase(fast_key)


## Clears every in-process cache-hit entry.
static func clear_fast_cache() -> void:
	_fast_cache_records.clear()
	_fast_cache_signatures.clear()


static func _validate_expected_metadata(
	options: PackRatOptions,
	metadata: PackRatHttpResponse,
	file_size: int
) -> String:
	if options.has_expected_size() and file_size != options.expected_size:
		return "Downloaded pack size mismatch: expected %d bytes, got %d." % [options.expected_size, file_size]

	if options.has_expected_modified_time():
		var remote_modified_time: int = PackRatHttpResponse.parse_http_date_unix(metadata.last_modified)
		if remote_modified_time <= 0 and not options.has_expected_size():
			return "Downloaded pack could not validate expected modified time because Last-Modified was missing or invalid."

		if remote_modified_time > 0 and remote_modified_time != options.expected_modified_time:
			return "Downloaded pack modified time mismatch: expected %d, got %d." % [
				options.expected_modified_time,
				remote_modified_time,
			]

	return ""


static func _evict_cache_record(
	cache: PackRatCache,
	key: String,
	path: String,
	options: PackRatOptions,
	save: bool = true
) -> void:
	PackRatCacheFiles.remove_cache_file(path, options.cache_dir)
	cache.erase_record(key)
	forget_fast_cache(key, options)
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
		if PackRatCachePaths.record_id(key, record) != id:
			continue

		var remove_error: Error = PackRatCacheFiles.remove_cache_file(record.local_path, options.cache_dir)
		if remove_error == ERR_BUSY:
			result.add_warning(
				"PackRat kept old mounted cache file %s because Godot resource packs stay mounted for the life of the process." % record.local_path
			)
		cache.erase_record(key)
		forget_fast_cache(key, options)

	var scan_error: Error = PackRatCacheFiles.clear_unmounted_cache_files(options.cache_dir, id, current_path)
	if scan_error != OK:
		result.add_warning("PackRat could not fully clean old cache files for id '%s' (error %d)." % [id, scan_error])


static func _fast_cache_key(key: String, options: PackRatOptions) -> String:
	return "%s:%s:%s:%d" % [options.cache_dir, key, str(options.replace_files), options.offset]
