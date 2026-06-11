class_name PackRatResult
extends RefCounted

const STATUS_CACHE_HIT := "cache_hit"
const STATUS_DOWNLOADED := "downloaded"
const STATUS_FAILED := "failed"

var ok: bool = false
var id: String = ""
var status: String = ""
var from_cache: bool = false
var mounted: bool = false
var source_url: String = ""
var local_path: String = ""
var entry_path: String = ""
var etag: String = ""
var last_modified: String = ""
var content_length: int = 0
var response_code: int = 0
var error: String = ""
var warnings: PackedStringArray = []


static func failed(url: String, message: String) -> PackRatResult:
	var result := PackRatResult.new()
	result.source_url = url
	result.status = STATUS_FAILED
	result.error = message
	return result


func add_warning(message: String) -> void:
	if not message.is_empty():
		warnings.append(message)


func to_dictionary() -> Dictionary:
	return {
		"ok": ok,
		"id": id,
		"status": status,
		"from_cache": from_cache,
		"mounted": mounted,
		"source_url": source_url,
		"local_path": local_path,
		"entry_path": entry_path,
		"etag": etag,
		"last_modified": last_modified,
		"content_length": content_length,
		"response_code": response_code,
		"error": error,
		"warnings": warnings,
	}
