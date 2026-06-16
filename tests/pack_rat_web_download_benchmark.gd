extends Control

const CACHE_DIR: String = "user://pack_rat_web_download_benchmark_cache"
const PACK_URL: String = "packs/packrat-demo-gallery.zip"
const SAMPLE_COUNT: int = 5
const CHUNK_SIZES: Array[int] = [
	4 * 1024 * 1024,
	8 * 1024 * 1024,
	PackRatOptions.MAX_DOWNLOAD_CHUNK_SIZE,
]


func _ready() -> void:
	if not OS.has_feature("web"):
		print("WEB_BENCH skipped: Web export only.")
		get_tree().quit()
		return

	await get_tree().process_frame
	var url: String = _benchmark_pack_url()
	var sample_count: int = _benchmark_sample_count()
	print("WEB_BENCH start url=%s samples=%d" % [url, sample_count])
	var clear_options: PackRatOptions = PackRatOptions.new()
	clear_options.cache_dir = CACHE_DIR
	PackRat.clear_cache(clear_options)
	_clear_directory(CACHE_DIR)
	await _assert_fetch_non_success_fails_without_body(url)
	await _assert_fetch_expected_size_cap(url)
	await _assert_fetch_invalid_header_fails_without_body(url)

	var summaries: Dictionary = {}
	for use_web_fetch in [true, false]:
		for chunk_size in CHUNK_SIZES:
			for sample_index in range(sample_count):
				var metrics: Dictionary = await _run_case(url, use_web_fetch, chunk_size, sample_index + 1)
				var summary_key: String = "%s_%d" % [str(metrics.get("case", "")), chunk_size]
				if not summaries.has(summary_key):
					summaries[summary_key] = []
				var samples: Array = summaries[summary_key]
				samples.append(metrics)
				summaries[summary_key] = samples
				await get_tree().process_frame

	_print_summaries(summaries)

	print("WEB_BENCH_DONE")


func _run_case(url: String, use_web_fetch: bool, chunk_size: int, sample_index: int) -> Dictionary:
	var options: PackRatOptions = PackRatOptions.new()
	options.id = "web_bench_%s_%d" % ["fetch" if use_web_fetch else "httprequest", chunk_size]
	options.cache_dir = CACHE_DIR
	options.use_web_fetch = use_web_fetch
	options.download_chunk_size = chunk_size
	options.capture_timings = true
	options.always_download = true

	var started_msec: int = Time.get_ticks_msec()
	var label: String = "fetch" if use_web_fetch else "httprequest"
	var case_url: String = _cache_busted_url(url, "case=%s_%d_%d_%d" % [label, chunk_size, sample_index, Time.get_ticks_usec()])
	var result: PackRatResult = await PackRat.load_resource_pack(case_url, options)
	var elapsed_msec: int = Time.get_ticks_msec() - started_msec
	var transfer_msec: int = int(result.timings_msec.get("download_http_transfer_msec", -1))
	var write_chunks: int = int(result.timings_msec.get("download_http_write_chunks", 0))
	var write_max_chunk_size: int = int(result.timings_msec.get("download_http_write_max_chunk_size", 0))
	if not result.ok:
		_fail("Expected Web benchmark %s chunk=%d sample=%d to load: %s" % [label, chunk_size, sample_index, result.error])
		return {}

	if result.local_path.ends_with(".part") or result.local_path.contains("/tmp/"):
		_fail("Expected Web benchmark %s chunk=%d sample=%d to finalize out of tmp: %s" % [label, chunk_size, sample_index, result.local_path])
		return {}

	if _has_part_files(CACHE_DIR):
		_fail("Expected Web benchmark %s chunk=%d sample=%d to clean .part files." % [label, chunk_size, sample_index])
		return {}

	if use_web_fetch:
		if write_chunks <= 0:
			_fail("Expected Web fetch benchmark chunk=%d sample=%d to write at least one chunk." % [chunk_size, sample_index])
			return {}

		if write_max_chunk_size <= 0 or write_max_chunk_size > chunk_size:
			_fail("Expected Web fetch benchmark chunk=%d sample=%d max chunk to stay in range, got %d." % [
				chunk_size,
				sample_index,
				write_max_chunk_size,
			])
			return {}

	print("WEB_BENCH sample=%d case=%s chunk=%d ok=%s elapsed=%d transfer=%d write_chunks=%d write_max_chunk=%d timings=%s" % [
		sample_index,
		label,
		chunk_size,
		str(result.ok),
		elapsed_msec,
		transfer_msec,
		write_chunks,
		write_max_chunk_size,
		JSON.stringify(result.timings_msec),
	])
	return {
		"case": label,
		"chunk": chunk_size,
		"ok": result.ok,
		"elapsed": elapsed_msec,
		"transfer": transfer_msec,
		"write_chunks": write_chunks,
		"write_max_chunk": write_max_chunk_size,
	}


func _assert_fetch_non_success_fails_without_body(url: String) -> void:
	var options: PackRatOptions = PackRatOptions.new()
	options.id = "web_bench_missing_fetch"
	options.cache_dir = CACHE_DIR
	options.use_web_fetch = true
	options.download_chunk_size = 4 * 1024 * 1024
	options.capture_timings = true
	options.always_download = true

	var result: PackRatResult = await PackRat.load_resource_pack(_cache_busted_url(_missing_pack_url(url), "case=missing_%d" % Time.get_ticks_usec()), options)
	if result.ok:
		_fail("Expected Web fetch benchmark missing pack to fail.")
		return

	if int(result.timings_msec.get("download_http_write_chunks", 0)) != 0:
		_fail("Expected Web fetch missing pack to fail before writing body chunks. Result: %s" % JSON.stringify(result.to_dictionary()))
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected Web fetch missing pack failure to clean .part files.")
		return


func _assert_fetch_expected_size_cap(url: String) -> void:
	var options: PackRatOptions = PackRatOptions.new()
	options.id = "web_bench_fetch_size_cap"
	options.cache_dir = CACHE_DIR
	options.use_web_fetch = true
	options.download_chunk_size = 4 * 1024 * 1024
	options.expected_size = 1
	options.capture_timings = true
	options.always_download = true

	var result: PackRatResult = await PackRat.load_resource_pack(_cache_busted_url(url, "case=size_cap_%d" % Time.get_ticks_usec()), options)
	if result.ok:
		_fail("Expected Web fetch benchmark size cap to fail.")
		return

	if int(result.timings_msec.get("download_http_write_chunks", 0)) != 0:
		_fail("Expected Web fetch size cap to fail before writing body chunks. Result: %s" % JSON.stringify(result.to_dictionary()))
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected Web fetch size cap failure to clean .part files.")
		return


func _assert_fetch_invalid_header_fails_without_body(url: String) -> void:
	var options: PackRatOptions = PackRatOptions.new()
	options.id = "web_bench_fetch_invalid_header"
	options.cache_dir = CACHE_DIR
	options.use_web_fetch = true
	options.download_chunk_size = 4 * 1024 * 1024
	options.request_headers = PackedStringArray(["InvalidHeader"])
	options.capture_timings = true
	options.always_download = true

	var result: PackRatResult = await PackRat.load_resource_pack(_cache_busted_url(url, "case=invalid_header_%d" % Time.get_ticks_usec()), options)
	if result.ok:
		_fail("Expected Web fetch benchmark invalid header to fail.")
		return

	if not result.error.contains("Invalid HTTP header"):
		_fail("Expected Web fetch invalid header to report a stable error. Result: %s" % JSON.stringify(result.to_dictionary()))
		return

	if int(result.timings_msec.get("download_http_write_chunks", 0)) != 0:
		_fail("Expected Web fetch invalid header to fail before writing body chunks. Result: %s" % JSON.stringify(result.to_dictionary()))
		return

	if _has_part_files(CACHE_DIR):
		_fail("Expected Web fetch invalid header failure to clean .part files.")
		return


func _print_summaries(summaries: Dictionary) -> void:
	for key in summaries.keys():
		var samples: Array = summaries[key]
		var ok_count: int = 0
		var elapsed_sum: int = 0
		var transfer_sum: int = 0
		var max_write_chunk: int = 0
		for sample in samples:
			if bool(sample.get("ok", false)):
				ok_count += 1
			elapsed_sum += int(sample.get("elapsed", 0))
			transfer_sum += maxi(0, int(sample.get("transfer", 0)))
			max_write_chunk = maxi(max_write_chunk, int(sample.get("write_max_chunk", 0)))

		var count: int = maxi(1, samples.size())
		print("WEB_BENCH_SUMMARY key=%s samples=%d ok=%d avg_elapsed=%d avg_transfer=%d max_write_chunk=%d" % [
			key,
			samples.size(),
			ok_count,
			roundi(float(elapsed_sum) / float(count)),
			roundi(float(transfer_sum) / float(count)),
			max_write_chunk,
		])


func _absolute_pack_url() -> String:
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return PACK_URL

	var origin: String = String(bridge.eval("window.location.origin + window.location.pathname.replace(/[^/]*$/, '')", true))
	if not origin.ends_with("/"):
		origin += "/"
	return origin + PACK_URL


func _benchmark_pack_url() -> String:
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return PACK_URL

	var configured_url: String = String(bridge.eval("new URLSearchParams(window.location.search).get('pack_url') || ''", true))
	if configured_url.is_empty():
		return _absolute_pack_url()

	return configured_url


func _benchmark_sample_count() -> int:
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return SAMPLE_COUNT

	var configured_count: int = int(bridge.eval("Number(new URLSearchParams(window.location.search).get('samples') || 0)", true))
	if configured_count <= 0:
		return SAMPLE_COUNT

	return configured_count


func _cache_busted_url(url: String, query: String) -> String:
	var separator: String = "&" if url.contains("?") else "?"
	return "%s%s%s" % [url, separator, query]


func _missing_pack_url(url: String) -> String:
	var clean_url: String = url.get_slice("?", 0)
	var base_url: String = clean_url.get_base_dir()
	if base_url.is_empty():
		return "__packrat_missing__.pck"

	return "%s/__packrat_missing__.pck" % base_url


func _clear_directory(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return

	for file_name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file_name))

	for directory_name in DirAccess.get_directories_at(path):
		_clear_directory(path.path_join(directory_name))
		DirAccess.remove_absolute(path.path_join(directory_name))


func _has_part_files(path: String) -> bool:
	if not DirAccess.dir_exists_absolute(path):
		return false

	for file_name in DirAccess.get_files_at(path):
		if file_name.ends_with(".part"):
			return true

	for directory_name in DirAccess.get_directories_at(path):
		if _has_part_files(path.path_join(directory_name)):
			return true

	return false


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
