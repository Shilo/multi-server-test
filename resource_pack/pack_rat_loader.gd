class_name PackRatLoader extends RefCounted
## Internal loader that coordinates PackRat cache, HTTP, and mount behavior.

static var _fast_cache_records: Dictionary = {}
static var _fast_cache_signatures: Dictionary = {}


## Loads, caches, and mounts the resource pack described by [param request].
static func load(request: PackRatRequest) -> PackRatResult:
	var url: String = request.url
	var options: PackRatOptions = request.options
	var capture_timings: bool = options.capture_timings
	var total_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	var id: String = request.id
	var key: String = request.cache_key
	var result: PackRatResult = PackRatResult.new()
	result.source_url = url
	result.id = id
	if request.is_canceled():
		return _finish_timing(PackRatResult.failed(url, PackRatResult.ERROR_CANCELED), total_start_msec, capture_timings)
	if not PackRatCachePaths.is_safe_cache_dir(options.cache_dir):
		return _finish_timing(PackRatResult.failed(url, "PackRat cache_dir must be a non-root user:// path without '..' segments."), total_start_msec, capture_timings)

	var ensure_cache_dir_start_msec: int = _timing_start(capture_timings)
	PackRatCacheFiles.ensure_dir(options.cache_dir)
	_record_timing(result, capture_timings, "ensure_cache_dir_msec", ensure_cache_dir_start_msec)

	var load_cache_start_msec: int = _timing_start(capture_timings)
	var cache: PackRatCache = PackRatCache.load(options.cache_dir)
	_record_timing(result, capture_timings, "load_cache_metadata_msec", load_cache_start_msec)
	var record: PackRatCacheRecord = cache.record(key)
	var metadata: PackRatHttpResponse = PackRatHttpResponse.new()
	var cached_exists_start_msec: int = _timing_start(capture_timings)
	var cached_file_exists: bool = record.file_exists()
	_record_timing(result, capture_timings, "cached_file_check_msec", cached_exists_start_msec)
	if not record.local_path.is_empty() and not cached_file_exists:
		var missing_record_start_msec: int = _timing_start(capture_timings)
		cache.erase_record(key)
		forget_fast_cache(key, options)
		cache.save()
		_record_timing(result, capture_timings, "missing_cache_record_repair_msec", missing_record_start_msec)

	var should_download: bool = options.always_download or not cached_file_exists
	var cached_expected_size_mismatch: bool = false

	if cached_file_exists and options.has_expected_size():
		var cached_size_start_msec: int = _timing_start(capture_timings)
		var cached_size: int = FileAccess.get_size(record.local_path)
		_record_timing(result, capture_timings, "cached_size_check_msec", cached_size_start_msec)
		if cached_size != options.expected_size:
			cached_expected_size_mismatch = true
			should_download = true
			var evict_mismatch_start_msec: int = _timing_start(capture_timings)
			_evict_cache_record(cache, key, record.local_path, options)
			_record_timing(result, capture_timings, "cached_size_evict_msec", evict_mismatch_start_msec)

	if cached_file_exists and not should_download and (options.offline_first or options.has_expected_metadata()):
		should_download = false
	elif cached_file_exists and not should_download:
		var freshness_start_msec: int = _timing_start(capture_timings)
		metadata = await PackRatHttpClient.freshness_metadata(url, options, request)
		if capture_timings:
			_merge_timings(result.timings_msec, metadata.timings_msec, "freshness_")
		_record_timing(result, capture_timings, "freshness_request_msec", freshness_start_msec)
		if request.is_canceled():
			return _finish_timing(PackRatResult.failed(url, PackRatResult.ERROR_CANCELED), total_start_msec, capture_timings)

		var freshness: String = record.freshness_against(metadata)
		should_download = freshness == "stale"
		if freshness == "unknown":
			result.add_warning("PackRat could not compare remote freshness metadata; using the cached pack.")

	if not should_download:
		result.status = PackRatResult.STATUS_CACHE_HIT
		result.from_cache = true
		result.local_path = record.local_path
		record.apply_to_result(result)
		var cache_mount_start_msec: int = _timing_start(capture_timings)
		var cached_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
		_copy_result_timings(cached_result, result, capture_timings)
		_record_timing(cached_result, capture_timings, "mount_msec", cache_mount_start_msec)
		if not cached_result.ok:
			_evict_cache_record(cache, key, record.local_path, options)
		else:
			remember_fast_cache(key, url, cached_result, options)
		return _finish_timing(cached_result, total_start_msec, capture_timings)

	var ensure_tmp_start_msec: int = _timing_start(capture_timings)
	PackRatCacheFiles.ensure_dir(options.cache_dir.path_join("tmp"))
	_record_timing(result, capture_timings, "ensure_tmp_dir_msec", ensure_tmp_start_msec)
	var part_path: String = options.cache_dir.path_join("tmp").path_join("%s-%d.part" % [key, request.get_instance_id()])
	var part_cleanup_start_msec: int = _timing_start(capture_timings)
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(part_path)
	_record_timing(result, capture_timings, "part_cleanup_msec", part_cleanup_start_msec)

	var download_start_msec: int = _timing_start(capture_timings)
	var download: PackRatHttpResponse = await PackRatHttpClient.request(url, part_path, options, request)
	if capture_timings:
		_merge_timings(result.timings_msec, download.timings_msec, "download_")
	_record_timing(result, capture_timings, "download_msec", download_start_msec)
	if request.is_canceled():
		DirAccess.remove_absolute(part_path)
		return _failed_with_timings(url, PackRatResult.ERROR_CANCELED, result, total_start_msec, capture_timings)

	if not download.ok:
		DirAccess.remove_absolute(part_path)
		if cached_file_exists and not options.always_download and not cached_expected_size_mismatch:
			result.status = PackRatResult.STATUS_CACHE_HIT
			result.from_cache = true
			result.local_path = record.local_path
			result.add_warning("%s Using the previous cached pack." % download.error)
			record.apply_to_result(result)
			var fallback_mount_start_msec: int = _timing_start(capture_timings)
			var fallback_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
			_copy_result_timings(fallback_result, result, capture_timings)
			_record_timing(fallback_result, capture_timings, "mount_msec", fallback_mount_start_msec)
			if not fallback_result.ok:
				_evict_cache_record(cache, key, record.local_path, options)
			return _finish_timing(fallback_result, total_start_msec, capture_timings)

		return _failed_with_timings(url, download.error, result, total_start_msec, capture_timings)

	var cache_finalize_start_msec: int = _timing_start(capture_timings)
	var file_size_start_msec: int = _timing_start(capture_timings)
	var file_size: int = FileAccess.get_size(part_path)
	_record_timing(result, capture_timings, "file_size_msec", file_size_start_msec)
	if file_size <= 0:
		DirAccess.remove_absolute(part_path)
		return _failed_with_timings(url, "Downloaded pack was empty.", result, total_start_msec, capture_timings)

	var metadata_merge_start_msec: int = _timing_start(capture_timings)
	metadata.merge_from(download)
	var has_comparable_freshness: bool = options.has_expected_metadata() or metadata.has_freshness()
	metadata.content_length = file_size
	metadata.apply_to_result(result)
	result.content_length = file_size
	_record_timing(result, capture_timings, "metadata_merge_msec", metadata_merge_start_msec)
	var validation_start_msec: int = _timing_start(capture_timings)
	var validation_error: String = _validate_expected_metadata(options, metadata, file_size)
	_record_timing(result, capture_timings, "validate_metadata_msec", validation_start_msec)
	if not validation_error.is_empty():
		DirAccess.remove_absolute(part_path)
		return _failed_with_timings(url, validation_error, result, total_start_msec, capture_timings)

	var local_path_start_msec: int = _timing_start(capture_timings)
	var local_path: String = PackRatCachePaths.local_path(url, options.cache_dir, result.id, metadata, options)
	_record_timing(result, capture_timings, "local_path_msec", local_path_start_msec)
	if (
		# This branch can happen after a parallel download produced the same cache path.
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
		_record_timing(result, capture_timings, "cache_finalize_msec", cache_finalize_start_msec)
		var existing_mount_start_msec: int = _timing_start(capture_timings)
		var existing_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
		_copy_result_timings(existing_result, result, capture_timings)
		_record_timing(existing_result, capture_timings, "mount_msec", existing_mount_start_msec)
		if existing_result.ok:
			var existing_save_start_msec: int = _timing_start(capture_timings)
			DirAccess.remove_absolute(part_path)
			cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result, options))
			cache.save()
			_record_timing(existing_result, capture_timings, "existing_cache_record_save_msec", existing_save_start_msec)
			var existing_fast_cache_start_msec: int = _timing_start(capture_timings)
			remember_fast_cache(key, url, existing_result, options)
			_record_timing(existing_result, capture_timings, "remember_fast_cache_msec", existing_fast_cache_start_msec)
			return _finish_timing(existing_result, total_start_msec, capture_timings)

		_evict_cache_record(cache, key, local_path, options, false)

	if FileAccess.file_exists(local_path):
		if PackRatMountRegistry.is_mounted_path(local_path):
			local_path = PackRatCachePaths.unused_cache_path(local_path, request.get_instance_id())
		else:
			var replace_cache_start_msec: int = _timing_start(capture_timings)
			var remove_error: Error = PackRatCacheFiles.remove_cache_file(local_path, options.cache_dir)
			_record_timing(result, capture_timings, "replace_cache_file_msec", replace_cache_start_msec)
			if PackRatCacheFiles.is_real_remove_error(remove_error):
				DirAccess.remove_absolute(part_path)
				return _failed_with_timings(url, "Could not replace cached pack %s (error %d)." % [local_path, remove_error], result, total_start_msec, capture_timings)

	var move_start_msec: int = _timing_start(capture_timings)
	var move_error: Error = DirAccess.rename_absolute(part_path, local_path)
	_record_timing(result, capture_timings, "move_into_cache_msec", move_start_msec)
	if move_error != OK:
		DirAccess.remove_absolute(part_path)
		return _failed_with_timings(url, "Could not move downloaded pack into cache (error %d)." % move_error, result, total_start_msec, capture_timings)

	result.status = PackRatResult.STATUS_DOWNLOADED
	result.local_path = local_path
	result.content_length = file_size
	metadata.content_length = file_size
	metadata.apply_to_result(result)
	_record_timing(result, capture_timings, "cache_finalize_msec", cache_finalize_start_msec)

	if not has_comparable_freshness:
		result.add_warning("PackRat cached this URL without comparable freshness headers.")
	if (
		options.has_expected_modified_time()
		and options.has_expected_size()
		and PackRatHttpResponse.parse_http_date_unix(metadata.last_modified) <= 0
	):
		result.add_warning("PackRat could not compare expected modified time because Last-Modified was missing or invalid.")

	var mount_start_msec: int = _timing_start(capture_timings)
	var mounted_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
	_copy_result_timings(mounted_result, result, capture_timings)
	_record_timing(mounted_result, capture_timings, "mount_msec", mount_start_msec)
	if not mounted_result.ok:
		PackRatCacheFiles.remove_cache_file(local_path, options.cache_dir)
		return _finish_timing(mounted_result, total_start_msec, capture_timings)

	var previous_local_path: String = record.local_path
	var previous_mounted_path: String = PackRatMountRegistry.mounted_path_for_id(result.id)
	if (
		not previous_local_path.is_empty()
		and previous_local_path != local_path
		and previous_local_path != previous_mounted_path
	):
		var previous_cleanup_start_msec: int = _timing_start(capture_timings)
		PackRatCacheFiles.remove_cache_file(previous_local_path, options.cache_dir)
		_record_timing(mounted_result, capture_timings, "previous_cache_cleanup_msec", previous_cleanup_start_msec)

	var old_versions_start_msec: int = _timing_start(capture_timings)
	_cleanup_old_versions(cache, key, result.id, local_path, options, result)
	_record_timing(mounted_result, capture_timings, "old_versions_cleanup_msec", old_versions_start_msec)
	var set_record_start_msec: int = _timing_start(capture_timings)
	cache.set_record(key, PackRatCacheRecord.from_result(url, local_path, result, options))
	_record_timing(result, capture_timings, "cache_record_msec", set_record_start_msec)
	var save_cache_start_msec: int = _timing_start(capture_timings)
	var save_error: Error = cache.save()
	_record_timing(result, capture_timings, "save_cache_metadata_msec", save_cache_start_msec)
	if save_error != OK:
		result.add_warning("PackRat loaded the resource pack but could not save cache metadata (error %d)." % save_error)

	var remember_start_msec: int = _timing_start(capture_timings)
	remember_fast_cache(key, url, mounted_result, options)
	_record_timing(mounted_result, capture_timings, "remember_fast_cache_msec", remember_start_msec)
	return _finish_timing(mounted_result, total_start_msec, capture_timings)


## Returns a mounted in-process cache hit, or [code]null[/code] when disk/HTTP work is needed.
static func fast_cache_result(url: String, id: String, key: String, options: PackRatOptions) -> PackRatResult:
	var capture_timings: bool = options.capture_timings
	var total_start_msec: int = Time.get_ticks_msec() if capture_timings else 0
	if options.always_download or (not options.offline_first and not options.has_expected_metadata()):
		return null

	var lookup_start_msec: int = _timing_start(capture_timings)
	var fast_key: String = _fast_cache_key(key, options)
	if not _fast_cache_records.has(fast_key):
		return null

	var record: PackRatCacheRecord = PackRatCacheRecord.from_dictionary(_fast_cache_records[fast_key])
	if not record.file_exists():
		_fast_cache_records.erase(fast_key)
		_fast_cache_signatures.erase(fast_key)
		return null

	var signature_start_msec: int = _timing_start(capture_timings)
	var signature: String = PackRatMountRegistry.mount_signature(record.local_path, options)
	if str(_fast_cache_signatures.get(fast_key, "")) != signature:
		_fast_cache_records.erase(fast_key)
		_fast_cache_signatures.erase(fast_key)
		return null

	var result: PackRatResult = PackRatResult.new()
	_record_timing(result, capture_timings, "fast_cache_lookup_msec", lookup_start_msec)
	_record_timing(result, capture_timings, "fast_cache_signature_msec", signature_start_msec)
	result.source_url = url
	result.id = id
	result.status = PackRatResult.STATUS_CACHE_HIT
	result.from_cache = true
	result.local_path = record.local_path
	record.apply_to_result(result)
	var mount_start_msec: int = _timing_start(capture_timings)
	var mounted_result: PackRatResult = PackRatMountRegistry.mount_if_pack(result, options)
	_copy_result_timings(mounted_result, result, capture_timings)
	_record_timing(mounted_result, capture_timings, "mount_msec", mount_start_msec)
	return _finish_timing(mounted_result, total_start_msec, capture_timings)


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


static func _merge_timings(target: Dictionary, source: Dictionary, prefix: String = "") -> void:
	for key in source.keys():
		target["%s%s" % [prefix, str(key)]] = source[key]


static func _timing_start(capture_timings: bool) -> int:
	return Time.get_ticks_msec() if capture_timings else 0


static func _record_timing(result: PackRatResult, capture_timings: bool, key: String, start_msec: int) -> void:
	if capture_timings:
		result.timings_msec[key] = Time.get_ticks_msec() - start_msec


static func _copy_result_timings(target: PackRatResult, source: PackRatResult, capture_timings: bool) -> void:
	if capture_timings:
		target.timings_msec = source.timings_msec


static func _finish_timing(result: PackRatResult, total_start_msec: int, capture_timings: bool) -> PackRatResult:
	if capture_timings:
		result.timings_msec["total_msec"] = Time.get_ticks_msec() - total_start_msec
	return result


static func _failed_with_timings(
	url: String,
	message: String,
	source_result: PackRatResult,
	total_start_msec: int,
	capture_timings: bool
) -> PackRatResult:
	var failed_result: PackRatResult = PackRatResult.failed(url, message)
	failed_result.id = source_result.id
	failed_result.content_length = source_result.content_length
	failed_result.response_code = source_result.response_code
	failed_result.etag = source_result.etag
	failed_result.last_modified = source_result.last_modified
	failed_result.warnings = source_result.warnings
	if capture_timings:
		failed_result.timings_msec = source_result.timings_msec.duplicate()
	return _finish_timing(failed_result, total_start_msec, capture_timings)


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
