class_name PackRatFileMetadata extends RefCounted
## Lightweight filesystem metadata returned by [method PackRat.file_metadata].

## [code]true[/code] when metadata was read successfully.
var ok: bool = false

## Path that was checked.
var path: String = ""

## File size in bytes.
var size: int = 0

## File modified time as a Unix timestamp.
var modified_time: int = 0

## Failure message when [member ok] is [code]false[/code].
var error: String = ""


## Copies [member size] and [member modified_time] into [param options].
func apply_to_options(options: PackRatOptions) -> void:
	options.expected_size = size
	options.expected_modified_time = modified_time


## Returns a generic client payload containing [param url] and file metadata.
func to_pack_info(url: String, id: String = "", entry_path: String = "") -> Dictionary:
	if not ok:
		return {
			"ok": false,
			"error": error,
		}

	var info: Dictionary = {
		"url": url,
		"size": size,
		"modified_time": modified_time,
	}
	if not id.is_empty():
		info["id"] = id
	if not entry_path.is_empty():
		info["entry_path"] = entry_path

	return info


## Returns this metadata as a plain dictionary for server payloads or logging.
func to_dictionary() -> Dictionary:
	return {
		"ok": ok,
		"path": path,
		"size": size,
		"modified_time": modified_time,
		"error": error,
	}
