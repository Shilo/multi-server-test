class_name PackRatResult extends RefCounted
## Result returned by [method PackRat.load_resource_pack].

## The cached file was reused.
const STATUS_CACHE_HIT: String = "cache_hit"

## A new file was downloaded and cached.
const STATUS_DOWNLOADED: String = "downloaded"

## The resource pack load failed.
const STATUS_FAILED: String = "failed"

## Failure message used when [method PackRatRequest.cancel] stops a request.
const ERROR_CANCELED: String = "PackRat request was canceled."

## [code]true[/code] when the requested content is ready.
var ok: bool = false

## Cache ID used for this pack.
var id: String = ""

## One of the [constant STATUS_CACHE_HIT], [constant STATUS_DOWNLOADED], or
## [constant STATUS_FAILED] values.
var status: String = ""

## [code]true[/code] when PackRat reused a local cache file.
var from_cache: bool = false

## [code]true[/code] when the local file was mounted as a PCK/ZIP resource pack.
var mounted: bool = false

## Original remote URL passed to [method PackRat.load_resource_pack].
var source_url: String = ""

## Local cached file path.
var local_path: String = ""

## Optional resource path copied from [member PackRatOptions.entry_path].
var entry_path: String = ""

## Remote ETag header used for freshness when available.
var etag: String = ""

## Remote Last-Modified header used for freshness when available.
var last_modified: String = ""

## Remote or downloaded byte size used for freshness when available.
var content_length: int = 0

## Last HTTP response code observed during download.
var response_code: int = 0

## Failure message when [member ok] is [code]false[/code].
var error: String = ""

## Non-fatal notes, such as missing comparable freshness headers.
var warnings: PackedStringArray = []


## Creates a failed result for [param url] with [param message].
static func failed(url: String, message: String) -> PackRatResult:
	var result: PackRatResult = PackRatResult.new()
	result.source_url = url
	result.status = STATUS_FAILED
	result.error = message
	return result


## Adds [param message] to [member warnings] when it is not empty.
func add_warning(message: String) -> void:
	if not message.is_empty():
		warnings.append(message)


## Returns [code]true[/code] when this result came from a canceled request.
func was_canceled() -> bool:
	return error == ERROR_CANCELED


## Returns [code]true[/code] when [member entry_path] points to a loadable
## [PackedScene] and this result completed successfully.
func entry_scene_exists() -> bool:
	return ok and not entry_path.is_empty() and ResourceLoader.exists(entry_path, "PackedScene")


## Loads [member entry_path] as a [PackedScene], or returns [code]null[/code]
## when this result failed, no entry path was provided, or the resource is not a scene.
func load_entry_scene() -> PackedScene:
	if not entry_scene_exists():
		return null

	var scene: PackedScene = ResourceLoader.load(entry_path, "PackedScene")
	return scene


## Changes the active scene to [member entry_path].
## [br][br]
## When [param tree] is [code]null[/code], the current [SceneTree] is read from
## [method Engine.get_main_loop].
func change_scene_to_entry(tree: SceneTree = null) -> Error:
	if not entry_scene_exists():
		return ERR_FILE_NOT_FOUND

	var target_tree: SceneTree = tree
	if target_tree == null:
		var main_loop: MainLoop = Engine.get_main_loop()
		if main_loop is not SceneTree:
			return ERR_UNCONFIGURED
		target_tree = main_loop

	return target_tree.change_scene_to_file(entry_path)


## Returns this result as a plain dictionary for logging and tests.
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
