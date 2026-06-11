class_name PackRatCacheRecord extends RefCounted
## Internal cache entry for one prepared URL.

## Original remote URL used to create this cache entry.
var source_url: String = ""

## Local cached file path.
var local_path: String = ""

## Cached ETag header.
var etag: String = ""

## Cached Last-Modified header.
var last_modified: String = ""

## Cached file size or remote Content-Length.
var content_length: int = 0

## Unix timestamp for when this record was written.
var updated_at_unix: int = 0


## Creates a cache record from JSON-compatible [param data].
static func from_dictionary(data: Variant) -> PackRatCacheRecord:
	var record: PackRatCacheRecord = PackRatCacheRecord.new()
	if not data is Dictionary:
		return record

	record.source_url = str(data.get("source_url", ""))
	record.local_path = str(data.get("local_path", ""))
	record.etag = str(data.get("etag", ""))
	record.last_modified = str(data.get("last_modified", ""))
	record.content_length = int(data.get("content_length", 0))
	record.updated_at_unix = int(data.get("updated_at_unix", 0))
	return record


## Creates a cache record from a successful [PackRatResult].
static func from_result(url: String, path: String, result: PackRatResult) -> PackRatCacheRecord:
	var record: PackRatCacheRecord = PackRatCacheRecord.new()
	record.source_url = url
	record.local_path = path
	record.etag = result.etag
	record.last_modified = result.last_modified
	record.content_length = result.content_length
	record.updated_at_unix = int(Time.get_unix_time_from_system())
	return record


## Returns [code]true[/code] when [member local_path] points to an existing file.
func file_exists() -> bool:
	return not local_path.is_empty() and FileAccess.file_exists(local_path)


## Compares this record against remote [param response] metadata.
func freshness_against(response: PackRatHttpResponse) -> String:
	if not response.has_freshness():
		return "unknown"

	if not response.etag.is_empty() and not etag.is_empty():
		return "fresh" if response.etag == etag else "stale"

	if not response.last_modified.is_empty() and not last_modified.is_empty():
		return "fresh" if response.last_modified == last_modified else "stale"

	if response.content_length > 0 and content_length > 0:
		return "fresh" if response.content_length == content_length else "stale"

	return "unknown"


## Copies this record into [param result].
func apply_to_result(result: PackRatResult) -> void:
	result.etag = etag
	result.last_modified = last_modified
	result.content_length = content_length


## Returns a JSON-compatible dictionary for [code]cache.json[/code].
func to_dictionary() -> Dictionary:
	return {
		"source_url": source_url,
		"local_path": local_path,
		"etag": etag,
		"last_modified": last_modified,
		"content_length": content_length,
		"updated_at_unix": updated_at_unix,
	}
