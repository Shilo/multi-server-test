class_name PackRatRequest extends RefCounted
## Active remote resource pack load returned by [method PackRat.load_resource_pack_async].

## Emitted when downloaded byte counts change during the GET request.
signal progress_changed(downloaded_bytes: int, total_bytes: int)

## Emitted once when the request finishes, fails, or is canceled.
signal completed(result: PackRatResult)

## Emitted once when [method cancel] requests cancellation.
signal canceled()

## Original URL or local source path passed to [method PackRat.load_resource_pack_async].
var url: String = ""

## Options used by this request.
var options: PackRatOptions

## Cache ID used by this request.
var id: String = ""

## Cache key used by this request.
var cache_key: String = ""

## Final result. Set before [signal completed] is emitted.
var result: PackRatResult

var _local_pack_path: String = ""
var _http_request: HTTPRequest
var _is_canceled: bool = false
var _is_completed: bool = false
var _has_progress: bool = false
var _last_downloaded_bytes: int = 0
var _last_total_bytes: int = 0


## Returns [code]true[/code] after [method cancel] has been called.
func is_canceled() -> bool:
	return _is_canceled


## Returns [code]true[/code] after [signal completed] has been emitted.
func is_completed() -> bool:
	return _is_completed


## Cancels the active download when one is running.
func cancel() -> void:
	if _is_completed or _is_canceled:
		return

	_is_canceled = true
	if _http_request != null:
		_http_request.cancel_request()
	canceled.emit()


func _setup(
	source_url: String,
	request_options: PackRatOptions,
	request_id: String,
	key: String,
	local_pack_path: String = ""
) -> void:
	url = source_url
	options = request_options
	id = request_id
	cache_key = key
	_local_pack_path = local_pack_path


func _set_http_request(request: HTTPRequest) -> void:
	_http_request = request
	if _is_canceled and _http_request != null:
		_http_request.cancel_request()


func _set_progress(downloaded_bytes: int, total_bytes: int) -> void:
	if _has_progress and downloaded_bytes == _last_downloaded_bytes and total_bytes == _last_total_bytes:
		return

	_has_progress = true
	_last_downloaded_bytes = downloaded_bytes
	_last_total_bytes = total_bytes
	progress_changed.emit(downloaded_bytes, total_bytes)


func _finish(value: PackRatResult) -> void:
	if _is_completed:
		return

	result = value
	_is_completed = true
	_http_request = null
	completed.emit(result)
