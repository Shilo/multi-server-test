class_name PackRatResult
extends RefCounted

const STATUS_CACHE_HIT := "cache_hit"
const STATUS_DOWNLOADED := "downloaded"
const STATUS_FAILED := "failed"
const STATUS_MOUNTED := "mounted"
const STATUS_STALE := "stale"

var ok: bool = false
var id: String = ""
var status: String = ""
var from_cache: bool = false
var mounted: bool = false
var source_url: String = ""
var final_url: String = ""
var local_path: String = ""
var entry_path: String = ""
var version_token: String = ""
var etag: String = ""
var last_modified: String = ""
var content_length: int = 0
var sha256: String = ""
var response_code: int = 0
var error: String = ""
var warnings: PackedStringArray = []


static func failed(message: String, source_url_value: String = "") -> PackRatResult:
	var result := PackRatResult.new()
	result.ok = false
	result.status = STATUS_FAILED
	result.source_url = source_url_value
	result.error = message
	return result


func add_warning(message: String) -> void:
	if message.is_empty():
		return

	warnings.append(message)


func apply_http_metadata(metadata: Dictionary) -> void:
	final_url = str(metadata.get("final_url", final_url))
	etag = str(metadata.get("etag", etag))
	last_modified = str(metadata.get("last_modified", last_modified))
	content_length = int(metadata.get("content_length", content_length))
	response_code = int(metadata.get("response_code", response_code))


func to_dictionary() -> Dictionary:
	return {
		"ok": ok,
		"id": id,
		"status": status,
		"from_cache": from_cache,
		"mounted": mounted,
		"source_url": source_url,
		"final_url": final_url,
		"local_path": local_path,
		"entry_path": entry_path,
		"version_token": version_token,
		"etag": etag,
		"last_modified": last_modified,
		"content_length": content_length,
		"sha256": sha256,
		"response_code": response_code,
		"error": error,
		"warnings": warnings,
	}
