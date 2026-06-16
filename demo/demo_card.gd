class_name PackRatDemoCard extends PanelContainer
## Interactive baked scene card that loads one PackRat Portal demo pack.

const _TIMING_DOWNLOAD_HTTP_TRANSFER: String = "download_http_transfer_msec"
const _TIMING_DOWNLOAD: String = "download_msec"
const _TIMING_TOTAL: String = "total_msec"

## Emitted when the pack is ready to show in the preview stage.
signal preview_requested(pack: PackRatDemoPack, result: PackRatResult)

## Emitted when a pack load finishes.
signal load_finished(pack: PackRatDemoPack, result: PackRatResult)

## Emitted when the card has a status message for the demo output log.
signal message_requested(message: String, is_error: bool)

## Catalog pack ID this card displays.
@export var pack_id: String = ""

var _pack: PackRatDemoPack
var _source: String = PackRatDemoCatalog.SOURCE_PAGES
var _use_web_fetch: bool = true
var _request: PackRatRequest
var _last_result: PackRatResult
var _last_download_msec: int = -1

@onready var _accent_bar: ColorRect = %AccentBar
@onready var _title_label: Label = %TitleLabel
@onready var _summary_label: Label = %SummaryLabel
@onready var _status_label: Label = %StatusLabel
@onready var _detail_label: Label = %DetailLabel
@onready var _progress_bar: ProgressBar = %ProgressBar
@onready var _bytes_label: Label = %BytesLabel
@onready var _timing_label: Label = %TimingLabel
@onready var _load_button: Button = %LoadButton
@onready var _cancel_button: Button = %CancelButton
@onready var _preview_button: Button = %PreviewButton
@onready var _clear_button: Button = %ClearButton


func _ready() -> void:
	_pack = PackRatDemoCatalog.pack_by_id(pack_id)
	if _pack == null:
		_status_label.text = "Missing catalog pack"
		_detail_label.text = pack_id
		_load_button.disabled = true
		_cancel_button.disabled = true
		_preview_button.disabled = true
		_clear_button.disabled = true
		return

	_bind_pack()
	_load_button.pressed.connect(load_pack)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_preview_button.pressed.connect(_on_preview_pressed)
	_clear_button.pressed.connect(_on_clear_pressed)
	_set_idle_state()


## Updates which catalog URL source this card uses.
func set_source(source: String) -> void:
	_source = source
	if _request == null or _request.is_completed():
		if _last_result != null and _last_result.ok:
			_update_loaded_detail()
			return

		_set_idle_state()


## Updates whether this card prefers browser [code]fetch()[/code] on Web exports.
func set_use_web_fetch(use_web_fetch: bool) -> void:
	_use_web_fetch = use_web_fetch
	if _request == null or _request.is_completed():
		if _last_result != null and _last_result.ok:
			_update_loaded_detail()
			return

		_set_idle_state()


## Starts this card's download and mount request.
func load_pack() -> void:
	if _pack == null:
		return
	if _request != null and not _request.is_completed():
		return

	var options: PackRatOptions = _pack.options_for_source(_source)
	options.cache_dir = PackRatDemoCatalog.cache_dir
	options.use_web_fetch = _use_web_fetch
	_request = PackRat.load_resource_pack_async(_pack.url_for_source(_source), options)
	_request.progress_changed.connect(_on_progress_changed)
	_request.completed.connect(_on_completed, CONNECT_ONE_SHOT)
	message_requested.emit("Loading %s..." % _pack.title, false)

	_status_label.text = "Loading"
	_detail_label.text = "%s in progress." % _load_source_label().capitalize()
	_detail_label.visible = true
	_bytes_label.text = _download_text(0, _pack.file_size)
	_update_timing_label()
	_progress_bar.value = 0.0
	_load_button.disabled = true
	_cancel_button.disabled = false
	_preview_button.disabled = true


## Returns this card's catalog pack.
func pack() -> PackRatDemoPack:
	return _pack


func _bind_pack() -> void:
	_accent_bar.color = _pack.accent_color
	_title_label.text = _pack.title
	_summary_label.text = _pack.summary
	_summary_label.visible = true


func _set_idle_state() -> void:
	_status_label.text = "Ready"
	_detail_label.text = ""
	_detail_label.visible = false
	if _pack.file_size > 0:
		_bytes_label.text = _download_text(0, _pack.file_size)
	else:
		_bytes_label.text = _download_text(0, 0)
	_update_timing_label()
	_progress_bar.value = 0.0
	_load_button.disabled = false
	_cancel_button.disabled = true
	_preview_button.disabled = _last_result == null or not _last_result.entry_scene_exists()


func _on_progress_changed(downloaded_bytes: int, total_bytes: int) -> void:
	var display_total_bytes: int = total_bytes
	if display_total_bytes <= 0:
		display_total_bytes = _pack.file_size

	if display_total_bytes > 0:
		_progress_bar.value = clampf(float(downloaded_bytes) / float(display_total_bytes) * 100.0, 0.0, 100.0)
		_bytes_label.text = _download_text(downloaded_bytes, display_total_bytes)
	else:
		_progress_bar.value = 8.0
		_bytes_label.text = _download_text(downloaded_bytes, 0)


func _on_completed(result: PackRatResult) -> void:
	_last_result = result
	_request = null
	_log_result_timings(result)
	_cancel_button.disabled = true
	_load_button.disabled = false
	_preview_button.disabled = not result.entry_scene_exists()

	if result.ok:
		_progress_bar.value = 100.0
		_status_label.text = "Mounted: %s" % result.status
		_update_loaded_detail()
		if not result.from_cache:
			_last_download_msec = _download_duration_msec(result)
		_bytes_label.text = _download_text(result.content_length, _expected_display_size(result))
		_update_timing_label()
		message_requested.emit(
			"Mounted %s from %s." % [_pack.title, "cache" if result.from_cache else _load_source_label()],
			false
		)
		preview_requested.emit(_pack, result)
	elif result.was_canceled():
		_status_label.text = "Canceled"
		_detail_label.text = "The download was canceled before mounting."
		_detail_label.visible = true
		_bytes_label.text = _download_text(0, _pack.file_size)
		_update_timing_label()
		message_requested.emit("Canceled %s." % _pack.title, false)
	else:
		_status_label.text = "Failed"
		_detail_label.text = result.error
		_detail_label.visible = true
		if result.content_length > 0:
			_progress_bar.value = 100.0
			_last_download_msec = _download_duration_msec(result)
			_bytes_label.text = _download_text(result.content_length, _expected_display_size(result))
		else:
			_progress_bar.value = 0.0
			_bytes_label.text = _download_text(0, _pack.file_size)
		_update_timing_label()
		message_requested.emit("%s failed: %s" % [_pack.title, result.error], true)

	load_finished.emit(_pack, result)


func _log_result_timings(result: PackRatResult) -> void:
	if result.timings_msec.is_empty():
		return

	print("PackRat demo: %s timings %s" % [_pack.title, JSON.stringify(result.timings_msec)])


func _update_loaded_detail() -> void:
	_detail_label.text = "Mounted from %s." % ("cache" if _last_result.from_cache else _load_source_label())
	_detail_label.visible = true


func _download_text(downloaded_bytes: int, total_bytes: int) -> String:
	if total_bytes > 0:
		return "Download: %s / %s" % [_format_bytes(downloaded_bytes), _format_bytes(total_bytes)]

	return "Download: %s / unknown" % _format_bytes(downloaded_bytes)


func _expected_display_size(result: PackRatResult) -> int:
	if _pack.file_size > 0:
		return _pack.file_size
	if result.content_length > 0:
		return result.content_length
	return 0


func _download_duration_msec(result: PackRatResult) -> int:
	if result.timings_msec.has(_TIMING_DOWNLOAD_HTTP_TRANSFER):
		return int(result.timings_msec[_TIMING_DOWNLOAD_HTTP_TRANSFER])
	if result.timings_msec.has(_TIMING_DOWNLOAD):
		return int(result.timings_msec[_TIMING_DOWNLOAD])
	if result.timings_msec.has(_TIMING_TOTAL):
		return int(result.timings_msec[_TIMING_TOTAL])
	return -1


func _update_timing_label() -> void:
	if _last_download_msec < 0:
		_timing_label.text = "Last: none"
		return

	_timing_label.text = "Last: %s" % _format_duration(_last_download_msec)


func _on_cancel_pressed() -> void:
	if _request != null:
		_request.cancel()
		_status_label.text = "Canceling"
		message_requested.emit("Canceling %s..." % _pack.title, false)


func _on_preview_pressed() -> void:
	if _last_result != null and _last_result.entry_scene_exists():
		preview_requested.emit(_pack, _last_result)


func _on_clear_pressed() -> void:
	if _pack == null:
		return

	var options: PackRatOptions = _pack.options_for_source(_source)
	options.cache_dir = PackRatDemoCatalog.cache_dir
	var error: Error = PackRat.clear_cached_resource_pack(options.id, options)
	if error == OK:
		_status_label.text = "Disk cache cleared"
		_detail_label.text = "Mounted until reload."
		message_requested.emit("Cleared %s disk cache." % _pack.title, false)
	elif error == ERR_DOES_NOT_EXIST:
		_status_label.text = "No disk cache"
		_detail_label.text = "This pack has no removable cached file right now."
		message_requested.emit("%s has no removable disk cache." % _pack.title, false)
	else:
		_status_label.text = "Clear failed"
		_detail_label.text = "Error %d" % error
		message_requested.emit("Could not clear %s disk cache (error %d)." % [_pack.title, error], true)


func _format_bytes(value: int) -> String:
	if value < 1024:
		return "%d B" % value
	if value < 1024 * 1024:
		return "%.1f KiB" % (float(value) / 1024.0)

	return "%.1f MiB" % (float(value) / 1024.0 / 1024.0)


func _format_duration(msec: int) -> String:
	if msec < 1000:
		return "%d ms" % msec

	return "%.2f s" % (float(msec) / 1000.0)


func _load_source_label() -> String:
	if _source == PackRatDemoCatalog.SOURCE_EDITOR_EXPORT:
		return "editor export"

	return "remote"
