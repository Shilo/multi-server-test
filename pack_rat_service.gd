class_name PackRatService
extends Node

var default_source_resolver: PackRatSourceResolver = PackRatHttpSourceResolver.new()
var default_freshness_checker: PackRatFreshnessChecker = PackRatHttpFreshnessChecker.new()
var default_cache_store: PackRatCacheStore = PackRatJsonCacheStore.new()
var default_http_client: PackRatHttpClient = PackRatHttpClient.new()
var _in_flight: Dictionary = {}


func prepare(source: Variant, options: PackRatOptions = null) -> PackRatResult:
	var resolved_options := options.copy() if options != null else PackRatOptions.new()
	var resolver := resolved_options.source_resolver if resolved_options.source_resolver != null else default_source_resolver
	var descriptor := resolver.resolve(source, resolved_options)
	if not descriptor.ok:
		return PackRatResult.failed(descriptor.error)

	if _in_flight.has(descriptor.cache_key):
		var existing: PackRatOperation = _in_flight[descriptor.cache_key]
		await existing.completed
		return existing.result

	var operation := PackRatOperation.new()
	_in_flight[descriptor.cache_key] = operation
	var result := await _prepare_resolved(descriptor, resolved_options)
	_in_flight.erase(descriptor.cache_key)
	operation.finish(result)
	return result


func _prepare_resolved(descriptor: PackRatDescriptor, options: PackRatOptions) -> PackRatResult:
	var cache_store := options.cache_store if options.cache_store != null else default_cache_store
	cache_store.configure(descriptor.cache_dir)

	var freshness_checker := options.freshness_checker if options.freshness_checker != null else default_freshness_checker
	var freshness := await freshness_checker.check(self, descriptor, cache_store)

	for warning in freshness.warnings:
		push_warning(warning)

	if freshness.use_cache:
		return _install_cached(descriptor, options, freshness)

	var download_result := await _download_and_commit(descriptor, options, cache_store, freshness)
	if not download_result.ok:
		return download_result

	return _install_result(descriptor, options, download_result)


func _install_cached(
	descriptor: PackRatDescriptor,
	options: PackRatOptions,
	freshness: PackRatFreshnessDecision
) -> PackRatResult:
	var record := freshness.record
	var result := descriptor.to_result()
	result.ok = true
	result.status = PackRatResult.STATUS_CACHE_HIT
	result.from_cache = true
	result.local_path = str(record.get("local_path", ""))
	result.final_url = str(record.get("final_url", descriptor.final_url))
	result.version_token = str(record.get("version_token", ""))
	result.etag = str(record.get("etag", ""))
	result.last_modified = str(record.get("last_modified", ""))
	result.content_length = int(record.get("content_length", 0))
	result.sha256 = str(record.get("sha256", ""))

	for warning in freshness.warnings:
		result.add_warning(warning)

	return _install_result(descriptor, options, result)


func _download_and_commit(
	descriptor: PackRatDescriptor,
	options: PackRatOptions,
	cache_store: PackRatCacheStore,
	freshness: PackRatFreshnessDecision
) -> PackRatResult:
	_ensure_directory(descriptor.cache_dir)
	_ensure_directory(descriptor.stable_dir())
	_ensure_directory(descriptor.cache_dir.path_join("tmp"))

	var part_path := descriptor.temp_path()
	if FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(part_path)

	var response := await default_http_client.download(
		self,
		descriptor.source_url,
		descriptor.request_headers,
		part_path,
		descriptor.timeout_seconds,
		descriptor.max_redirects
	)

	var metadata := freshness.metadata.duplicate()
	if response.is_success():
		metadata.merge(response.to_metadata(), true)

	if not response.is_success():
		DirAccess.remove_absolute(part_path)
		return _failed_or_stale_cache(
			descriptor,
			options,
			cache_store,
			freshness,
			"Download failed for %s (HTTP result %d, response %d)." %
			[descriptor.source_url, response.result, response.response_code]
		)

	var validation := _validate(part_path, descriptor, options, metadata)
	if not validation.ok:
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed(validation.error, descriptor.source_url)

	var version_token := validation.sha256 if not validation.sha256.is_empty() else _version_token(descriptor, metadata)
	var stable_path := descriptor.stable_path(version_token)
	var move_error := DirAccess.rename_absolute(part_path, stable_path)
	if move_error != OK:
		DirAccess.remove_absolute(part_path)
		return PackRatResult.failed("Could not move PackRat download into cache (error %d)." % move_error, descriptor.source_url)

	var result := descriptor.to_result()
	result.ok = true
	result.status = PackRatResult.STATUS_DOWNLOADED
	result.from_cache = false
	result.local_path = stable_path
	result.sha256 = validation.sha256
	result.version_token = version_token
	result.apply_http_metadata(metadata)
	result.content_length = FileAccess.get_size(stable_path)

	if freshness.status == PackRatResult.STATUS_STALE and descriptor.install_mode == PackRatOptions.InstallMode.RESOURCE_PACK and not descriptor.replace_files:
		result.add_warning(
			"PackRat downloaded a newer pack. Godot mounts are process-lifetime; replace_files=false will not override resources that were already mounted at the same res:// paths."
		)

	for warning in validation.warnings:
		result.add_warning(warning)
		push_warning(warning)

	cache_store.set_record(descriptor.cache_key, _record_from_result(descriptor, result))
	var save_error := cache_store.save()
	if save_error != OK:
		result.add_warning("PackRat prepared content, but could not save cache metadata (error %d)." % save_error)

	return result


func _failed_or_stale_cache(
	descriptor: PackRatDescriptor,
	options: PackRatOptions,
	cache_store: PackRatCacheStore,
	freshness: PackRatFreshnessDecision,
	message: String
) -> PackRatResult:
	var record := cache_store.get_record(descriptor.cache_key)
	var local_path := str(record.get("local_path", ""))
	if not local_path.is_empty() and FileAccess.file_exists(local_path):
		freshness.record = record
		freshness.warnings.append("%s PackRat kept the existing cached file." % message)
		return _install_cached(descriptor, options, freshness)

	return PackRatResult.failed(message, descriptor.source_url)


func _validate(
	local_path: String,
	descriptor: PackRatDescriptor,
	options: PackRatOptions,
	metadata: Dictionary
) -> PackRatValidationResult:
	var validators := options.validators
	if validators.is_empty():
		validators = [
			PackRatBasicValidator.new(),
			PackRatSha256Validator.new(),
		]

	var combined := PackRatValidationResult.new()
	for validator in validators:
		var validation := validator.validate(local_path, descriptor, metadata)
		if not validation.ok:
			return validation

		if not validation.sha256.is_empty():
			combined.sha256 = validation.sha256

		for warning in validation.warnings:
			combined.add_warning(warning)

	return combined


func _install_result(
	descriptor: PackRatDescriptor,
	options: PackRatOptions,
	result: PackRatResult
) -> PackRatResult:
	var installer := options.installer
	if installer == null:
		if descriptor.install_mode == PackRatOptions.InstallMode.RESOURCE_PACK:
			installer = PackRatResourcePackInstaller.new()
		else:
			installer = PackRatFileInstaller.new()

	return installer.install(descriptor, result)


func _record_from_result(descriptor: PackRatDescriptor, result: PackRatResult) -> Dictionary:
	return {
		"id": descriptor.id,
		"source_url": descriptor.source_url,
		"final_url": result.final_url,
		"etag": result.etag,
		"last_modified": result.last_modified,
		"content_length": result.content_length,
		"local_path": result.local_path,
		"version_token": result.version_token,
		"sha256": result.sha256,
		"mounted": result.mounted,
		"updated_at_unix": int(Time.get_unix_time_from_system()),
	}


func _ensure_directory(path: String) -> void:
	var error := DirAccess.make_dir_recursive_absolute(path)
	if error != OK and error != ERR_ALREADY_EXISTS:
		push_warning("PackRat could not create directory %s (error %d)." % [path, error])


func _version_token(descriptor: PackRatDescriptor, metadata: Dictionary) -> String:
	var etag := str(metadata.get("etag", ""))
	if not etag.is_empty():
		return etag.sha256_text().substr(0, 16)

	var last_modified := str(metadata.get("last_modified", ""))
	var content_length := int(metadata.get("content_length", 0))
	if not last_modified.is_empty() or content_length > 0:
		return ("%s:%d" % [last_modified, content_length]).sha256_text().substr(0, 16)

	return descriptor.source_url.sha256_text().substr(0, 16)
