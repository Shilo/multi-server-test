extends Node

const CACHE_DIR: String = "user://pack_rat_native_thread_benchmark_cache"
const DOWNLOAD_CHUNK_SIZE: int = PackRatOptions.DEFAULT_DOWNLOAD_CHUNK_SIZE
const DEFAULT_SAMPLE_COUNT: int = 8
const UNCHANGED_MAX_FPS: int = -1
const UNCHANGED_VSYNC_MODE: int = -1
const TIMEOUT_SECONDS: float = 180.0
const WAREHOUSE_PACK: Dictionary = {
	"id": "warehouse",
	"url": "https://shilo.github.io/pack-rat/packs/packrat-demo-warehouse.pck",
	"version": PackRatDemoCatalog.WAREHOUSE_VERSION_TOKEN,
	"size": PackRatDemoCatalog.WAREHOUSE_FILE_SIZE,
}
const GALLERY_PACK: Dictionary = {
	"id": "gallery",
	"url": "https://shilo.github.io/pack-rat/packs/packrat-demo-gallery.zip",
	"version": PackRatDemoCatalog.GALLERY_VERSION_TOKEN,
	"size": PackRatDemoCatalog.GALLERY_FILE_SIZE,
}

var _sample_count: int = DEFAULT_SAMPLE_COUNT
var _summaries: Dictionary = {}
var _previous_max_fps: int = 0
var _previous_vsync_mode: DisplayServer.VSyncMode = DisplayServer.VSYNC_ENABLED
var _configured_max_fps: int = UNCHANGED_MAX_FPS
var _configured_vsync_mode: int = UNCHANGED_VSYNC_MODE


func _ready() -> void:
	_sample_count = _argument_int("samples", DEFAULT_SAMPLE_COUNT)
	_sample_count = maxi(1, _sample_count)
	_previous_max_fps = Engine.max_fps
	_previous_vsync_mode = DisplayServer.window_get_vsync_mode()
	_configured_max_fps = _argument_int("max-fps", UNCHANGED_MAX_FPS)
	if _configured_max_fps >= 0:
		Engine.max_fps = _configured_max_fps
	_configured_vsync_mode = _argument_int("vsync-mode", UNCHANGED_VSYNC_MODE)
	if _configured_vsync_mode >= 0:
		DisplayServer.window_set_vsync_mode(_configured_vsync_mode)

	_clear_directory(CACHE_DIR)
	_make_directory(CACHE_DIR)

	print("NATIVE_THREAD_BENCH start samples=%d chunk_size=%d platform=%s previous_max_fps=%d active_max_fps=%d previous_vsync=%d active_vsync=%d" % [
		_sample_count,
		DOWNLOAD_CHUNK_SIZE,
		OS.get_name(),
		_previous_max_fps,
		Engine.max_fps,
		_previous_vsync_mode,
		DisplayServer.window_get_vsync_mode(),
	])

	for pack in [WAREHOUSE_PACK, GALLERY_PACK]:
		for sample_index in range(_sample_count):
			var modes: Array = [false, true] if sample_index % 2 == 0 else [true, false]
			for use_threads in modes:
				var raw_metrics: Dictionary = await _raw_case(pack, sample_index, use_threads)
				if raw_metrics.is_empty():
					return
				_remember(raw_metrics)

				var packrat_metrics: Dictionary = await _packrat_case(pack, sample_index, use_threads)
				if packrat_metrics.is_empty():
					return
				_remember(packrat_metrics)

	_print_summaries()
	_clear_directory(CACHE_DIR)
	_restore_engine_timing()
	print("NATIVE_THREAD_BENCH passed.")
	get_tree().quit(0)


func _raw_case(pack: Dictionary, sample_index: int, use_threads: bool) -> Dictionary:
	var pack_id: String = String(pack["id"])
	var expected_size: int = int(pack["size"])
	var url: String = PackRat.versioned_url(String(pack["url"]), String(pack["version"]))
	var case_id: String = "raw_%s_%s_%02d" % [_thread_label(use_threads), pack_id, sample_index]
	var download_path: String = CACHE_DIR.path_join("%s.%s" % [case_id, _extension_from_url(url)])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(download_path))

	var request: HTTPRequest = HTTPRequest.new()
	request.accept_gzip = true
	request.use_threads = use_threads
	request.download_file = download_path
	request.download_chunk_size = DOWNLOAD_CHUNK_SIZE
	request.timeout = TIMEOUT_SECONDS
	add_child(request)
	var actual_use_threads: bool = request.is_using_threads()

	var completed: Array = []
	request.request_completed.connect(func(result_code: HTTPRequest.Result, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
		completed.append(result_code)
		completed.append(response_code)
	, CONNECT_ONE_SHOT)

	var start_msec: int = Time.get_ticks_msec()
	var start_error: Error = request.request(url)
	if start_error != OK:
		request.queue_free()
		_fail("Raw %s failed to start request: %d." % [case_id, start_error])
		return {}

	var frames: int = 0
	while completed.is_empty():
		frames += 1
		await get_tree().process_frame

	var elapsed_msec: int = Time.get_ticks_msec() - start_msec
	request.queue_free()

	var result_code: HTTPRequest.Result = completed[0]
	var response_code: int = completed[1]
	var downloaded_size: int = FileAccess.get_size(download_path)
	if result_code != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_fail("Raw %s failed: result=%d response=%d elapsed=%d." % [case_id, result_code, response_code, elapsed_msec])
		return {}
	var metrics: Dictionary = {
		"kind": "raw",
		"pack": pack_id,
		"sample": sample_index,
		"requested_threads": use_threads,
		"actual_threads": actual_use_threads,
		"elapsed_msec": elapsed_msec,
		"frames": frames,
		"catalog_size": expected_size,
		"downloaded_size": downloaded_size,
	}
	_print_sample(metrics)
	return metrics


func _packrat_case(pack: Dictionary, sample_index: int, use_threads: bool) -> Dictionary:
	var pack_id: String = String(pack["id"])
	var expected_size: int = int(pack["size"])
	var url: String = PackRat.versioned_url(String(pack["url"]), String(pack["version"]))
	var case_id: String = "packrat_%s_%s_%02d" % [_thread_label(use_threads), pack_id, sample_index]

	var options: PackRatOptions = PackRatOptions.new()
	options.id = case_id
	options.cache_dir = CACHE_DIR
	options.progress_total_size = expected_size
	options.always_download = true
	options.use_threads = use_threads
	options.use_web_fetch = false
	options.download_chunk_size = DOWNLOAD_CHUNK_SIZE
	options.timeout_seconds = TIMEOUT_SECONDS
	options.capture_timings = true

	var start_msec: int = Time.get_ticks_msec()
	var result: PackRatResult = await PackRat.load_resource_pack(url, options)
	var elapsed_msec: int = Time.get_ticks_msec() - start_msec
	if not result.ok:
		_fail("PackRat %s failed: %s timings=%s." % [case_id, result.error, JSON.stringify(result.timings_msec)])
		return {}
	var downloaded_size: int = FileAccess.get_size(result.local_path)
	var metrics: Dictionary = {
		"kind": "packrat",
		"pack": pack_id,
		"sample": sample_index,
		"requested_threads": use_threads,
		"actual_threads": use_threads,
		"elapsed_msec": elapsed_msec,
		"download_msec": int(result.timings_msec.get("download_http_transfer_msec", result.timings_msec.get("download_msec", elapsed_msec))),
		"frames": int(result.timings_msec.get("download_http_progress_frames", 0)),
		"catalog_size": expected_size,
		"downloaded_size": downloaded_size,
	}
	_print_sample(metrics)
	return metrics


func _remember(metrics: Dictionary) -> void:
	var key: String = "%s|%s|%s" % [
		String(metrics["kind"]),
		String(metrics["pack"]),
		_thread_label(bool(metrics["requested_threads"])),
	]
	if not _summaries.has(key):
		_summaries[key] = []
	var samples: Array = _summaries[key]
	samples.append(metrics)
	_summaries[key] = samples


func _print_sample(metrics: Dictionary) -> void:
	print("NATIVE_THREAD_BENCH_SAMPLE kind=%s pack=%s threads=%s actual_threads=%s sample=%d elapsed=%d transfer=%d frames=%d size=%d" % [
		String(metrics["kind"]),
		String(metrics["pack"]),
		_thread_label(bool(metrics["requested_threads"])),
		_thread_label(bool(metrics["actual_threads"])),
		int(metrics["sample"]),
		int(metrics["elapsed_msec"]),
		int(metrics.get("download_msec", metrics["elapsed_msec"])),
		int(metrics["frames"]),
		int(metrics["downloaded_size"]),
	])


func _print_summaries() -> void:
	for key in _summaries.keys():
		var samples: Array = _summaries[key]
		var elapsed_values: Array[int] = []
		var transfer_values: Array[int] = []
		var frame_values: Array[int] = []
		var actual_threads_count: int = 0
		for sample in samples:
			var metrics: Dictionary = sample
			elapsed_values.append(int(metrics["elapsed_msec"]))
			transfer_values.append(int(metrics.get("download_msec", metrics["elapsed_msec"])))
			frame_values.append(int(metrics["frames"]))
			if bool(metrics["actual_threads"]):
				actual_threads_count += 1

		var parts: PackedStringArray = key.split("|")
		print("NATIVE_THREAD_BENCH_SUMMARY kind=%s pack=%s threads=%s samples=%d actual_thread_samples=%d elapsed_avg=%d elapsed_median=%d elapsed_min=%d elapsed_max=%d transfer_avg=%d transfer_median=%d frames_avg=%d" % [
			parts[0],
			parts[1],
			parts[2],
			samples.size(),
			actual_threads_count,
			_average(elapsed_values),
			_median(elapsed_values),
			_minimum(elapsed_values),
			_maximum(elapsed_values),
			_average(transfer_values),
			_median(transfer_values),
			_average(frame_values),
		])


func _argument_int(name: String, fallback: int) -> int:
	var prefix: String = "--%s=" % name
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return int(argument.trim_prefix(prefix))
	return fallback


func _restore_engine_timing() -> void:
	Engine.max_fps = _previous_max_fps
	DisplayServer.window_set_vsync_mode(_previous_vsync_mode)


func _thread_label(value: bool) -> String:
	return "on" if value else "off"


func _extension_from_url(url: String) -> String:
	var path: String = url.get_slice("?", 0)
	if path.get_extension().is_empty():
		return "pack"
	return path.get_extension()


func _average(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var total: int = 0
	for value in values:
		total += value
	return int(round(float(total) / float(values.size())))


func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted_values: Array[int] = values.duplicate()
	sorted_values.sort()
	return sorted_values[sorted_values.size() / 2]


func _minimum(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var result: int = values[0]
	for value in values:
		result = mini(result, value)
	return result


func _maximum(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var result: int = values[0]
	for value in values:
		result = maxi(result, value)
	return result


func _make_directory(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


func _clear_directory(path: String) -> void:
	var absolute_path: String = ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute_path):
		_remove_directory_recursive(absolute_path)


func _remove_directory_recursive(path: String) -> void:
	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		return

	directory.list_dir_begin()
	var file_name: String = directory.get_next()
	while not file_name.is_empty():
		var child_path: String = path.path_join(file_name)
		if directory.current_is_dir():
			_remove_directory_recursive(child_path)
			DirAccess.remove_absolute(child_path)
		else:
			DirAccess.remove_absolute(child_path)
		file_name = directory.get_next()
	directory.list_dir_end()


func _fail(message: String) -> void:
	_restore_engine_timing()
	push_error(message)
	get_tree().quit(1)
