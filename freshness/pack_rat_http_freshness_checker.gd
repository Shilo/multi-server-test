class_name PackRatHttpFreshnessChecker
extends PackRatFreshnessChecker

var http_client: PackRatHttpClient = PackRatHttpClient.new()


func check(
	owner: Node,
	descriptor: PackRatDescriptor,
	cache_store: PackRatCacheStore
) -> PackRatFreshnessDecision:
	var decision := PackRatFreshnessDecision.new()
	var record := cache_store.get_record(descriptor.cache_key)
	var local_path := str(record.get("local_path", ""))
	var has_cached_file := not local_path.is_empty() and FileAccess.file_exists(local_path)
	decision.record = record

	if descriptor.freshness_mode == PackRatOptions.FreshnessMode.ALWAYS_DOWNLOAD:
		decision.reason = "freshness mode is always_download"
		decision.status = PackRatResult.STATUS_STALE if has_cached_file else PackRatResult.STATUS_DOWNLOADED
		return await _attach_head_metadata(owner, descriptor, decision)

	if not has_cached_file:
		decision.reason = "cache record or cached file is missing"
		decision.status = PackRatResult.STATUS_DOWNLOADED
		return await _attach_head_metadata(owner, descriptor, decision)

	if descriptor.freshness_mode == PackRatOptions.FreshnessMode.CACHE_FIRST:
		decision.should_download = false
		decision.use_cache = true
		decision.status = PackRatResult.STATUS_CACHE_HIT
		decision.reason = "freshness mode is cache_first"
		return decision

	var response := await http_client.request_metadata(
		owner,
		descriptor.source_url,
		descriptor.request_headers,
		descriptor.head_timeout_seconds,
		descriptor.max_redirects
	)
	decision.metadata = response.to_metadata()

	if not response.is_success():
		decision.should_download = descriptor.download_when_freshness_unknown
		decision.use_cache = not decision.should_download
		decision.status = PackRatResult.STATUS_STALE if decision.should_download else PackRatResult.STATUS_CACHE_HIT
		decision.reason = "HEAD freshness check failed"
		decision.add_warning(
			"PackRat could not check freshness for %s (HTTP result %d, response %d); using cached content." %
			[descriptor.source_url, response.result, response.response_code]
		)
		return decision

	var comparison := _compare_metadata(record, decision.metadata)
	if bool(comparison["changed"]):
		decision.should_download = true
		decision.use_cache = false
		decision.status = PackRatResult.STATUS_STALE
		decision.reason = str(comparison["reason"])
		return decision

	if bool(comparison["comparable"]):
		decision.should_download = false
		decision.use_cache = true
		decision.status = PackRatResult.STATUS_CACHE_HIT
		decision.reason = str(comparison["reason"])
		return decision

	decision.should_download = descriptor.download_when_freshness_unknown
	decision.use_cache = not decision.should_download
	decision.status = PackRatResult.STATUS_STALE if decision.should_download else PackRatResult.STATUS_CACHE_HIT
	decision.reason = "remote server did not expose comparable freshness headers"
	decision.add_warning(
		"PackRat cache freshness for %s is unknown because ETag, Last-Modified, and Content-Length were unavailable or not recorded." %
		descriptor.source_url
	)
	return decision


func _attach_head_metadata(
	owner: Node,
	descriptor: PackRatDescriptor,
	decision: PackRatFreshnessDecision
) -> PackRatFreshnessDecision:
	var response := await http_client.request_metadata(
		owner,
		descriptor.source_url,
		descriptor.request_headers,
		descriptor.head_timeout_seconds,
		descriptor.max_redirects
	)

	if response.is_success():
		decision.metadata = response.to_metadata()

	return decision


func _compare_metadata(record: Dictionary, metadata: Dictionary) -> Dictionary:
	var comparable := false

	for key in ["etag", "last_modified"]:
		var remote_text := str(metadata.get(key, ""))
		var cached_text := str(record.get(key, ""))
		if remote_text.is_empty() or cached_text.is_empty():
			continue

		comparable = true
		if remote_text != cached_text:
			return {
				"comparable": true,
				"changed": true,
				"reason": "%s changed" % key,
			}

	var remote_length := int(metadata.get("content_length", 0))
	var cached_length := int(record.get("content_length", 0))
	if remote_length > 0 and cached_length > 0:
		comparable = true
		if remote_length != cached_length:
			return {
				"comparable": true,
				"changed": true,
				"reason": "content_length changed",
			}

	return {
		"comparable": comparable,
		"changed": false,
		"reason": "HTTP freshness metadata matched" if comparable else "no comparable metadata",
	}
