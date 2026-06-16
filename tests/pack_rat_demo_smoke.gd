extends Node

const PORT: int = 18924
const DEFAULT_BUILD_DIR: String = "res://build/packs"
const CACHE_DIR: String = "user://pack_rat_demo_smoke/cache"
const EXPECTED_SPACE: int = 10
const _PACK_DIR_ARG: String = "--pack-dir="

var _server: TCPServer
var _pack_bytes: Dictionary[String, PackedByteArray] = {}
var _head_count: int = 0
var _get_count: int = 0
var _active_peer_count: int = 0


func _ready() -> void:
	get_tree().create_timer(45.0).timeout.connect(_on_timeout, CONNECT_ONE_SHOT)
	_clear_demo_cache()
	var build_dir: String = _pack_dir_from_args()
	var load_error: Error = _load_exported_demo_packs(build_dir)
	if load_error != OK:
		_fail("Could not load exported demo packs from %s (error %d)." % [build_dir, load_error])
		return

	for pack in PackRatDemoCatalog.packs():
		var path: String = build_dir.path_join(pack.file_name)
		var bytes: PackedByteArray = _pack_bytes.get("/packs/%s" % pack.file_name, PackedByteArray())
		if bytes.is_empty():
			_fail("Exported demo pack was empty: %s" % path)
			return
		if bytes.size() < 1024 * 1024:
			_fail("Demo smoke pack fixture for %s was too small: %d bytes." % [pack.id, bytes.size()])
			return

	if not await _assert_public_api_helpers(build_dir):
		return

	_server = TCPServer.new()
	var listen_error: Error = _server.listen(PORT, "127.0.0.1")
	if listen_error != OK:
		_fail("Could not start demo smoke HTTP server (error %d)." % listen_error)
		return

	PackRatDemoCatalog.pages_pack_base_url = "http://127.0.0.1:%d/packs" % PORT
	PackRatDemoCatalog.cache_dir = CACHE_DIR
	PackRatDemoCatalog.use_threads = false
	await get_tree().process_frame

	var demo_scene: PackedScene = load("res://demo/demo.tscn")
	if demo_scene == null:
		_fail("Could not load demo scene.")
		return

	var demo: Node = demo_scene.instantiate()
	add_child(demo)
	await get_tree().process_frame

	var placeholder: Node = demo.find_child("PreviewPlaceholder", true, false)
	if placeholder == null or placeholder.is_queued_for_deletion():
		_fail("Expected baked preview placeholder to remain alive.")
		return
	if not _assert_demo_spacing(demo):
		return

	var warehouse_card: PackRatDemoCard = _card(demo, "WarehouseCard")
	var gallery_card: PackRatDemoCard = _card(demo, "GalleryCard")
	if warehouse_card == null or gallery_card == null:
		return
	if not _assert_demo_type_scale(demo, [warehouse_card, gallery_card]):
		return
	if not _assert_unknown_total_progress_uses_catalog_size(warehouse_card):
		return

	var downloader_row: Control = _control(demo, "DownloaderRow")
	if downloader_row == null:
		return
	if downloader_row.visible != OS.has_feature("web"):
		_fail("Expected demo downloader selector row to show only in Web builds.")
		return

	var downloader_selector: OptionButton = _option_button(demo, "DownloadClientSelector")
	if downloader_selector == null:
		return
	if downloader_selector.item_count != 2:
		_fail("Expected demo downloader selector to compare fetch and HTTPRequest.")
		return

	var source_selector: OptionButton = _option_button(demo, "SourceSelector")
	if source_selector == null:
		return
	if source_selector.item_count != 3:
		_fail("Expected demo source selector to include Pages, Release, and editor export preset modes.")
		return
	var expected_editor_source_disabled: bool = not OS.has_feature("editor")
	if source_selector.is_item_disabled(2) != expected_editor_source_disabled:
		_fail("Expected demo editor export source to be enabled only in editor runs.")
		return
	if OS.has_feature("web"):
		downloader_selector.select(1)
		downloader_selector.item_selected.emit(1)
		await get_tree().process_frame

	var warehouse_first: PackRatResult = await _press_load(warehouse_card)
	if warehouse_first == null:
		return
	if not _assert_loaded(warehouse_card, warehouse_first):
		return
	if not _assert_progress_complete(warehouse_card):
		return
	if not _assert_card_text_fits(demo, warehouse_card):
		return
	if not _assert_preview_contains_icon(demo, "Box00"):
		return
	if not _assert_preview_contains_icon(demo, "MascotWatermark"):
		return
	if not _assert_preview_scene_shell(demo, "Warehouse"):
		return
	if not _assert_warehouse_physics(demo):
		return

	var valid_pack_base_url: String = PackRatDemoCatalog.pages_pack_base_url
	PackRatDemoCatalog.pages_pack_base_url = "ftp://invalid"
	var gallery_invalid: PackRatResult = await _press_load(gallery_card)
	PackRatDemoCatalog.pages_pack_base_url = valid_pack_base_url
	if gallery_invalid == null:
		return
	if gallery_invalid.ok:
		_fail("Expected invalid demo URL to fail.")
		return
	var output_text: TextEdit = _text_edit(demo, "OutputText")
	if output_text == null:
		return
	if not output_text.text.contains("Gallery ZIP failed"):
		_fail("Expected invalid demo URL to be added to the output log.")
		return

	var gallery_canceled: PackRatResult = await _press_cancel(gallery_card)
	if gallery_canceled == null:
		return

	var gallery_first: PackRatResult = await _press_load(gallery_card)
	if gallery_first == null:
		return
	if not _assert_loaded(gallery_card, gallery_first):
		return
	if not _assert_progress_complete(gallery_card):
		return
	if not _assert_card_text_fits(demo, gallery_card):
		return
	if not _assert_preview_contains_icon(demo, "Icon"):
		return
	if not _assert_preview_scene_shell(demo, "Gallery"):
		return
	if not await _assert_gallery_responsive(gallery_first):
		return

	var mounted_host: Control = _control(demo, "MountedSceneHost")
	if mounted_host == null:
		return
	if mounted_host.get_child_count() == 0:
		_fail("Expected the demo scene to preview a mounted entry scene.")
		return

	var get_count_after_downloads: int = _get_count
	var head_count_before_cache: int = _head_count
	var warehouse_cached: PackRatResult = await _press_load(warehouse_card)
	if warehouse_cached == null:
		return
	if not warehouse_cached.from_cache:
		_fail("Expected repeated warehouse button load to use cache.")
		return
	if _get_count != get_count_after_downloads:
		_fail("Expected repeated warehouse button load to avoid an extra GET.")
		return
	if _head_count != head_count_before_cache:
		_fail("Expected offline-first repeated warehouse load to avoid an extra HEAD.")
		return

	var clear_button: Button = _button(warehouse_card, "ClearButton")
	if clear_button == null:
		return
	warehouse_card.set_source(PackRatDemoCatalog.SOURCE_GITHUB_RELEASE)
	clear_button.pressed.emit()
	await get_tree().process_frame
	warehouse_card.set_source(PackRatDemoCatalog.SOURCE_PAGES)
	var warehouse_after_clear: PackRatResult = await _press_load(warehouse_card)
	if warehouse_after_clear == null:
		return
	if not warehouse_after_clear.ok:
		_fail("Expected warehouse to load after clearing disk cache.")
		return
	if _get_count <= get_count_after_downloads:
		_fail("Expected clear-disk-cache button to force a later redownload.")
		return
	var clear_all_button: Button = _button(demo, "ClearAllButton")
	if clear_all_button == null:
		return
	clear_all_button.pressed.emit()
	await get_tree().process_frame
	var clear_output_text: TextEdit = _text_edit(demo, "OutputText")
	if clear_output_text == null:
		return
	if not clear_output_text.text.contains("Disk cache cleared."):
		_fail("Expected clear-all button to append to the output log.")
		return
	if not clear_output_text.text.contains("Gallery ZIP failed"):
		_fail("Expected output log to keep earlier actions after new actions.")
		return

	if OS.has_feature("editor"):
		source_selector.select(2)
		source_selector.item_selected.emit(2)
		await get_tree().process_frame
		var editor_source_options: PackRatOptions = warehouse_card.pack().options_for_source(PackRatDemoCatalog.SOURCE_EDITOR_EXPORT)
		if editor_source_options.editor_pack_export_preset != PackRatDemoCatalog.WAREHOUSE_EXPORT_PRESET:
			_fail("Expected demo editor source to configure the warehouse export preset.")
			return
		if editor_source_options.editor_simulated_local_load_seconds <= 0.0:
			_fail("Expected demo editor source to configure simulated local load progress.")
			return

		var editor_warehouse: PackRatResult = await _press_load(warehouse_card)
		if editor_warehouse == null:
			return
		if not editor_warehouse.ok or editor_warehouse.from_cache:
			_fail("Expected editor export source to build/load a fresh local warehouse pack. Result: %s" % JSON.stringify(editor_warehouse.to_dictionary()))
			return
		if not editor_warehouse.local_path.get_file().contains("warehouse"):
			_fail("Expected editor export source to cache a warehouse pack, got %s." % editor_warehouse.local_path)
			return

	await _finish_success("PackRat demo smoke passed. GET=%d HEAD=%d" % [_get_count, _head_count])


func _assert_public_api_helpers(build_dir: String) -> bool:
	var joined_url: String = PackRat.join_url("https://example.com/packs/", "/hub.pck")
	if joined_url != "https://example.com/packs/hub.pck":
		_fail("PackRat.join_url returned %s." % joined_url)
		return false

	var release_url: String = PackRat.github_release_url("owner", "repo", "hub.pck")
	if release_url != "https://github.com/owner/repo/releases/latest/download/hub.pck":
		_fail("PackRat.github_release_url returned %s." % release_url)
		return false

	var pages_url: String = PackRat.github_pages_url("owner", "repo", "packs/hub.pck")
	if pages_url != "https://owner.github.io/repo/packs/hub.pck":
		_fail("PackRat.github_pages_url returned %s." % pages_url)
		return false

	var demo_pack: PackRatDemoPack = PackRatDemoCatalog.packs()[0]
	if not demo_pack.pages_url().ends_with("?v=%s" % demo_pack.version_token.uri_encode()):
		_fail("Expected demo pack URLs to include a version query.")
		return false
	if demo_pack.options().id != demo_pack.id:
		_fail("Expected demo pack cache ID to stay stable.")
		return false

	var metadata: PackRatFileMetadata = PackRat.file_metadata(build_dir.path_join(PackRatDemoCatalog.WAREHOUSE_FILE_NAME))
	if not metadata.ok:
		_fail("PackRat.file_metadata failed: %s" % metadata.error)
		return false
	if metadata.size < 1024 * 1024:
		_fail("PackRat.file_metadata returned unexpectedly small size %d." % metadata.size)
		return false

	var metadata_dictionary: Dictionary = metadata.to_dictionary()
	if int(metadata_dictionary.get("size", 0)) != metadata.size:
		_fail("PackRatFileMetadata.to_dictionary did not preserve size.")
		return false

	var expected_options: PackRatOptions = PackRatOptions.from_expected_metadata(metadata.modified_time, metadata.size)
	if not expected_options.has_expected_metadata() or not expected_options.has_expected_size():
		_fail("PackRatOptions.from_expected_metadata did not enable expected metadata.")
		return false

	var applied_options: PackRatOptions = PackRatOptions.new()
	metadata.apply_to_options(applied_options)
	if applied_options.expected_size != metadata.size or applied_options.expected_modified_time != metadata.modified_time:
		_fail("PackRatFileMetadata.apply_to_options did not copy metadata.")
		return false

	applied_options.request_headers = PackedStringArray(["X-PackRat-Smoke: yes"])
	var copied_options: PackRatOptions = applied_options.copy()
	applied_options.request_headers.append("X-PackRat-Smoke: mutated")
	if copied_options.request_headers.size() != 1:
		_fail("PackRatOptions.copy did not snapshot request headers.")
		return false

	var invalid_result: PackRatResult = await PackRat.load_resource_pack("res://not_remote.pck")
	if invalid_result.ok or invalid_result.status != PackRatResult.STATUS_FAILED:
		_fail("PackRat.load_resource_pack accepted an invalid URL.")
		return false
	if invalid_result.entry_scene_exists() or invalid_result.load_entry_scene() != null:
		_fail("Failed PackRatResult reported an entry scene.")
		return false
	if invalid_result.change_scene_to_entry(get_tree()) != ERR_FILE_NOT_FOUND:
		_fail("Failed PackRatResult changed scenes unexpectedly.")
		return false
	if not bool(invalid_result.to_dictionary().has("error")):
		_fail("PackRatResult.to_dictionary did not include error.")
		return false

	var invalid_request: PackRatRequest = PackRat.load_resource_pack_async("not-a-url")
	var canceled_events: Array[bool] = []
	invalid_request.canceled.connect(func() -> void:
		canceled_events.append(true)
	)
	invalid_request.cancel()
	await invalid_request.completed
	var invalid_async_result: PackRatResult = invalid_request.result
	if canceled_events.is_empty() or not invalid_request.is_canceled():
		_fail("PackRatRequest.cancel did not emit canceled.")
		return false
	if invalid_async_result.ok or not invalid_request.is_completed():
		_fail("PackRat.load_resource_pack_async invalid request did not complete as failed.")
		return false

	var clear_options: PackRatOptions = PackRatOptions.new()
	clear_options.cache_dir = CACHE_DIR.path_join("missing")
	PackRat.clear_cache(clear_options)
	if PackRat.clear_cached_resource_pack("missing", clear_options) != ERR_DOES_NOT_EXIST:
		_fail("PackRat.clear_cached_resource_pack did not report a missing cache item.")
		return false

	return true


func _pack_dir_from_args() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(_PACK_DIR_ARG):
			return argument.substr(_PACK_DIR_ARG.length())

	return DEFAULT_BUILD_DIR


func _load_exported_demo_packs(build_dir: String) -> Error:
	_pack_bytes.clear()
	for pack in PackRatDemoCatalog.packs():
		var path: String = build_dir.path_join(pack.file_name)
		if not FileAccess.file_exists(path):
			return ERR_FILE_NOT_FOUND

		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
		if bytes.is_empty() and FileAccess.get_open_error() != OK:
			return FileAccess.get_open_error()

		_pack_bytes["/packs/%s" % pack.file_name] = bytes

	return OK


func _assert_demo_spacing(demo: Node) -> bool:
	if not _assert_margin_container(demo, "Page"):
		return false
	if not _assert_margin_container(demo, "CardsMargin"):
		return false

	for container_name in [
		"Root",
		"Header",
		"Copy",
		"HeaderControls",
		"SourceRow",
		"DownloaderRow",
		"Body",
		"CardsStack",
		"CardStack",
		"PlaceholderStack",
	]:
		if not _assert_separation(demo, container_name):
			return false

	for card_name in ["WarehouseCard", "GalleryCard"]:
		var card: PackRatDemoCard = _card(demo, card_name)
		if card == null:
			return false
		if not _assert_margin_container(card, "Margin"):
			return false
		for container_name in ["Stack", "Header", "TitleStack", "StatusRow", "MetricRow"]:
			if not _assert_separation(card, container_name):
				return false
		if not _assert_flow_separation(card, "Buttons"):
			return false

	return true


func _assert_demo_type_scale(demo: Node, cards: Array[PackRatDemoCard]) -> bool:
	if not _assert_font_size(demo, "Title", PackRatDemoTypeScale.APP_TITLE):
		return false
	if not _assert_font_size(demo, "Subtitle", PackRatDemoTypeScale.BODY):
		return false
	if not _assert_font_size(demo, "SourceLabel", PackRatDemoTypeScale.BODY):
		return false
	if not _assert_font_size(demo, "DownloaderLabel", PackRatDemoTypeScale.BODY):
		return false
	if not _assert_font_size(demo, "SourceSelector", PackRatDemoTypeScale.BODY):
		return false
	if not _assert_font_size(demo, "DownloadClientSelector", PackRatDemoTypeScale.BODY):
		return false
	if not _assert_font_size(demo, "ClearAllButton", PackRatDemoTypeScale.BODY):
		return false
	if not _assert_font_size(demo, "OutputText", PackRatDemoTypeScale.META):
		return false
	if not _assert_font_size(demo, "PlaceholderTitle", PackRatDemoTypeScale.SECTION_TITLE):
		return false
	if not _assert_font_size(demo, "PlaceholderCopy", PackRatDemoTypeScale.BODY):
		return false

	for card in cards:
		if not _assert_font_size(card, "TitleLabel", PackRatDemoTypeScale.CONTENT_TITLE):
			return false
		if not _assert_font_size(card, "SummaryLabel", PackRatDemoTypeScale.BODY):
			return false
		if not _assert_font_size(card, "StatusLabel", PackRatDemoTypeScale.STATUS):
			return false
		if not _assert_font_size(card, "DetailLabel", PackRatDemoTypeScale.META):
			return false
		if not _assert_detail_label_caps(card):
			return false
		if not _assert_font_size(card, "BytesLabel", PackRatDemoTypeScale.META):
			return false
		if not _assert_font_size(card, "TimingLabel", PackRatDemoTypeScale.META):
			return false
		for button_name in ["LoadButton", "CancelButton", "PreviewButton", "ClearButton"]:
			if not _assert_font_size(card, button_name, PackRatDemoTypeScale.BODY):
				return false

	return true


func _assert_detail_label_caps(card: PackRatDemoCard) -> bool:
	var detail_label: Label = _label(card, "DetailLabel")
	if detail_label == null:
		return false
	if not detail_label.clip_text:
		_fail("Expected DetailLabel to clip long text.")
		return false
	if detail_label.max_lines_visible != 2:
		_fail("Expected DetailLabel to show no more than two lines.")
		return false
	if detail_label.text_overrun_behavior != TextServer.OVERRUN_TRIM_WORD_ELLIPSIS:
		_fail("Expected DetailLabel to ellipsize long text.")
		return false

	return true


func _process(_delta: float) -> void:
	while _server != null and _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		_serve_peer(peer)


func _serve_peer(peer: StreamPeerTCP) -> void:
	_active_peer_count += 1
	var request: String = ""
	var wait_until: int = Time.get_ticks_msec() + 1000

	while Time.get_ticks_msec() < wait_until and request.find("\r\n\r\n") < 0:
		if peer.get_available_bytes() > 0:
			request += peer.get_utf8_string(peer.get_available_bytes())
		else:
			await get_tree().process_frame

	var method: String = request.get_slice(" ", 0)
	var path: String = request.get_slice(" ", 1).get_slice("?", 0)
	if not _pack_bytes.has(path):
		_write_not_found(peer)
	elif method == "HEAD":
		_head_count += 1
		await _write_response(peer, path, false)
	elif method == "GET":
		_get_count += 1
		await _write_response(peer, path, true)
	else:
		_write_not_found(peer)

	peer.disconnect_from_host()
	_active_peer_count -= 1


func _write_response(peer: StreamPeerTCP, path: String, include_body: bool) -> void:
	var body: PackedByteArray = _pack_bytes[path]
	var content_type: String = "application/zip" if path.ends_with(".zip") else "application/octet-stream"
	var headers: String = (
		"HTTP/1.1 200 OK\r\n"
		+ "Content-Type: %s\r\n" % content_type
		+ "Content-Length: %d\r\n" % body.size()
		+ "Access-Control-Allow-Origin: *\r\n"
		+ "Access-Control-Expose-Headers: Content-Length\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())

	if include_body:
		await _write_body(peer, body)


func _write_body(peer: StreamPeerTCP, body: PackedByteArray) -> void:
	var offset: int = 0
	var chunk_size: int = 4 * 1024 * 1024
	while offset < body.size():
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return

		var end: int = mini(offset + chunk_size, body.size())
		var sent: Array = peer.put_partial_data(body.slice(offset, end))
		var error: Error = sent[0]
		var sent_bytes: int = sent[1]
		if error != OK:
			return
		if sent_bytes <= 0:
			await get_tree().process_frame
			continue

		offset += sent_bytes
		await get_tree().process_frame


func _write_not_found(peer: StreamPeerTCP) -> void:
	var body: PackedByteArray = "not found".to_utf8_buffer()
	var headers: String = (
		"HTTP/1.1 404 Not Found\r\n"
		+ "Content-Length: %d\r\n" % body.size()
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	peer.put_data(headers.to_utf8_buffer())
	peer.put_data(body)


func _clear_demo_cache() -> void:
	var options: PackRatOptions = PackRatOptions.new()
	options.cache_dir = CACHE_DIR
	PackRat.clear_cache(options)
	_clear_directory(CACHE_DIR)


func _clear_directory(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var child: String = dir.get_next()
	while not child.is_empty():
		var child_path: String = path.path_join(child)
		if dir.current_is_dir():
			_clear_directory(child_path)
			DirAccess.remove_absolute(child_path)
		else:
			DirAccess.remove_absolute(child_path)
		child = dir.get_next()
	dir.list_dir_end()


func _press_load(card: PackRatDemoCard) -> PackRatResult:
	var load_button: Button = _button(card, "LoadButton")
	if load_button == null:
		return null

	var results: Array[PackRatResult] = []
	card.load_finished.connect(func(_pack: PackRatDemoPack, result: PackRatResult) -> void:
		results.append(result)
	, CONNECT_ONE_SHOT)
	load_button.pressed.emit()

	var wait_until: int = Time.get_ticks_msec() + 30000
	while results.is_empty() and Time.get_ticks_msec() < wait_until:
		await get_tree().process_frame

	if results.is_empty():
		_fail("Timed out waiting for card load button.")
		return null

	return results[0]


func _press_cancel(card: PackRatDemoCard) -> PackRatResult:
	var load_button: Button = _button(card, "LoadButton")
	var cancel_button: Button = _button(card, "CancelButton")
	if load_button == null or cancel_button == null:
		return null

	var results: Array[PackRatResult] = []
	card.load_finished.connect(func(_pack: PackRatDemoPack, result: PackRatResult) -> void:
		results.append(result)
	, CONNECT_ONE_SHOT)

	var progress_bar: ProgressBar = _progress_bar(card, "ProgressBar")
	var get_count_before_cancel: int = _get_count
	load_button.pressed.emit()

	var wait_until: int = Time.get_ticks_msec() + 5000
	while results.is_empty() and Time.get_ticks_msec() < wait_until:
		if progress_bar != null and progress_bar.value > 0.0:
			cancel_button.pressed.emit()
			break
		if _get_count > get_count_before_cancel:
			await get_tree().process_frame
			cancel_button.pressed.emit()
			break

		await get_tree().process_frame

	wait_until = Time.get_ticks_msec() + 10000
	while results.is_empty() and Time.get_ticks_msec() < wait_until:
		await get_tree().process_frame

	if results.is_empty():
		_fail("Timed out waiting for card cancel.")
		return null

	var result: PackRatResult = results[0]
	if result.ok:
		_fail("Expected canceled card load to fail before mounting.")
		return null
	if not result.was_canceled():
		_fail("Expected canceled card load to return the PackRat cancel error, got: %s" % result.error)
		return null

	var status_label: Label = _label(card, "StatusLabel")
	if status_label == null:
		return null
	if status_label.text != "Canceled":
		_fail("Expected canceled card to show a Canceled state.")
		return null

	return result


func _assert_loaded(card: PackRatDemoCard, result: PackRatResult) -> bool:
	var pack: PackRatDemoPack = card.pack()
	if pack == null:
		_fail("Card did not expose a catalog pack.")
		return false
	if not result.ok:
		_fail("Demo pack %s failed to load: %s" % [pack.id, result.error])
		return false
	if not result.entry_scene_exists():
		_fail("Demo pack %s did not expose entry scene %s." % [pack.id, pack.entry_path])
		return false
	if result.load_entry_scene() == null:
		_fail("Demo pack %s entry scene could not be instantiated." % pack.id)
		return false

	print("PackRat demo smoke loaded %s as %s." % [pack.id, result.status])
	return true


func _assert_progress_complete(card: PackRatDemoCard) -> bool:
	var progress_bar: ProgressBar = _progress_bar(card, "ProgressBar")
	if progress_bar == null:
		return false
	if progress_bar.value != 100.0:
		_fail("Expected loaded card progress to finish at 100.")
		return false

	return true


func _assert_unknown_total_progress_uses_catalog_size(card: PackRatDemoCard) -> bool:
	var pack: PackRatDemoPack = card.pack()
	if pack == null:
		_fail("Card did not expose a catalog pack.")
		return false

	var progress_bar: ProgressBar = _progress_bar(card, "ProgressBar")
	var bytes_label: Label = _label(card, "BytesLabel")
	if progress_bar == null or bytes_label == null:
		return false

	card._on_progress_changed(pack.file_size / 2, 0)
	if progress_bar.value < 49.0 or progress_bar.value > 51.0:
		_fail("Expected unknown-total progress to use the demo catalog size, got %.2f." % progress_bar.value)
		return false
	if bytes_label.text.contains("unknown"):
		_fail("Expected unknown-total progress label to use the demo catalog size.")
		return false

	return true


func _assert_card_text_fits(demo: Node, card: PackRatDemoCard) -> bool:
	var card_scroll_node: Node = demo.find_child("CardScroll", true, false)
	if card_scroll_node is ScrollContainer:
		var card_scroll: ScrollContainer = card_scroll_node
		if card_scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
			_fail("Expected card list horizontal scrolling to be disabled.")
			return false

	var bytes_label: Label = _label(card, "BytesLabel")
	if bytes_label == null:
		return false
	if bytes_label.text.contains("user://"):
		_fail("Expected card cache label to hide internal user:// path.")
		return false
	if not bytes_label.text.begins_with("Download: ") or not bytes_label.text.contains(" / "):
		_fail("Expected card byte label to show current and max download size.")
		return false

	var timing_label: Label = _label(card, "TimingLabel")
	if timing_label == null:
		return false
	if not timing_label.text.begins_with("Last: "):
		_fail("Expected card timing label to show the last download duration.")
		return false

	return true


func _assert_preview_contains_icon(demo: Node, icon_name: String) -> bool:
	var mounted_host: Control = _control(demo, "MountedSceneHost")
	if mounted_host == null:
		return false

	var node: Node = mounted_host.find_child(icon_name, true, false)
	if node is TextureRect:
		var icon: TextureRect = node
		if icon.texture != null:
			return true
	if node is Sprite2D:
		var sprite: Sprite2D = node
		if sprite.texture != null:
			return true
	if node is RigidBody2D:
		var icon_child: Node = node.find_child("Icon", true, false)
		if icon_child is Sprite2D:
			var icon_sprite: Sprite2D = icon_child
			if icon_sprite.texture != null:
				return true

	_fail("Expected mounted demo scene icon %s to have a texture." % icon_name)
	return false


func _assert_preview_scene_shell(demo: Node, scene_name: String) -> bool:
	var mounted_host: Control = _control(demo, "MountedSceneHost")
	if mounted_host == null:
		return false

	var scene_root: Node = mounted_host.find_child(scene_name, true, false)
	if scene_root == null:
		_fail("Expected mounted demo scene %s." % scene_name)
		return false

	if scene_root.find_child("Background", true, false) != null:
		_fail("Expected mounted demo scene %s to leave the preview background visible." % scene_name)
		return false

	var header_node: Node = scene_root.find_child("Header", true, false)
	if header_node is not HBoxContainer:
		_fail("Expected mounted demo scene %s to use an HBoxContainer header." % scene_name)
		return false

	var title: Label = _label(scene_root, "Title")
	var subtitle: Label = _label(scene_root, "Subtitle")
	if title == null or subtitle == null:
		return false
	if title.get_theme_font_size("font_size") != PackRatDemoTypeScale.CONTENT_TITLE:
		_fail("Expected mounted demo scene %s title to match card title size." % scene_name)
		return false
	if subtitle.get_theme_font_size("font_size") != PackRatDemoTypeScale.BODY:
		_fail("Expected mounted demo scene %s subtitle to match card description size." % scene_name)
		return false
	if subtitle.text.split(" ", false).size() > 6:
		_fail("Expected mounted demo scene %s subtitle to stay compact." % scene_name)
		return false

	return true


func _assert_gallery_responsive(result: PackRatResult) -> bool:
	var scene: PackedScene = result.load_entry_scene()
	if scene == null:
		_fail("Could not load gallery entry scene for responsive smoke.")
		return false

	var host: Control = Control.new()
	host.size = Vector2(240.0, 260.0)
	add_child(host)

	var instance: Node = scene.instantiate()
	host.add_child(instance)
	if instance is Control:
		var control: Control = instance
		control.set_anchors_preset(Control.PRESET_FULL_RECT)

	await get_tree().process_frame
	await get_tree().process_frame
	if not _assert_gallery_width_fits(host, instance, "narrow"):
		host.queue_free()
		return false

	host.size = Vector2(720.0, 360.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var fits: bool = _assert_gallery_width_fits(host, instance, "wide")
	host.queue_free()
	return fits


func _assert_warehouse_physics(demo: Node) -> bool:
	var mounted_host: Control = _control(demo, "MountedSceneHost")
	if mounted_host == null:
		return false
	var scene_root: Node = mounted_host.find_child("Warehouse", true, false)
	if scene_root is not Control:
		_fail("Expected mounted warehouse scene root.")
		return false

	var warehouse: Control = scene_root
	var expected_width: float = maxf(warehouse.size.x, 1.0)
	var expected_floor_y: float = maxf(warehouse.size.y - 34.0, 1.0)

	var box_node: Node = mounted_host.find_child("Box00", true, false)
	if box_node is not RigidBody2D:
		_fail("Expected warehouse Box00 to be a RigidBody2D.")
		return false

	var box_collision_node: Node = box_node.find_child("CollisionShape2D", true, false)
	if box_collision_node is not CollisionShape2D:
		_fail("Expected warehouse Box00 to have a CollisionShape2D.")
		return false

	var box_collision: CollisionShape2D = box_collision_node
	if box_collision.shape is not RectangleShape2D:
		_fail("Expected warehouse Box00 collision to use a RectangleShape2D.")
		return false

	for edge_name in ["FloorCollision", "LeftWallCollision", "RightWallCollision", "CeilingCollision"]:
		var edge_node: Node = mounted_host.find_child(edge_name, true, false)
		if edge_node is not CollisionShape2D:
			_fail("Expected warehouse edge collider %s." % edge_name)
			return false

		var edge_collision: CollisionShape2D = edge_node
		if edge_collision.shape is not SegmentShape2D:
			_fail("Expected warehouse edge collider %s to use SegmentShape2D." % edge_name)
			return false

		var edge: SegmentShape2D = edge_collision.shape
		if edge_name == "FloorCollision" and absf(edge.b.x - expected_width) > 1.0:
			_fail("Expected warehouse floor edge to match scene width.")
			return false
		if edge_name == "RightWallCollision" and absf(edge.a.x - expected_width) > 1.0:
			_fail("Expected warehouse right wall edge to match scene width.")
			return false
		if edge_name == "LeftWallCollision" and absf(edge.b.y - expected_floor_y) > 1.0:
			_fail("Expected warehouse left wall edge to match scene height.")
			return false

	return true


func _assert_gallery_width_fits(host: Control, gallery: Node, label: String) -> bool:
	var scroll_node: Node = gallery.find_child("CardScroll", true, false)
	if scroll_node is not ScrollContainer:
		_fail("Expected gallery scene to use a ScrollContainer.")
		return false

	var scroll: ScrollContainer = scroll_node
	if scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
		_fail("Expected gallery %s layout to disable horizontal scrolling." % label)
		return false

	var flow_node: Node = gallery.find_child("TileFlow", true, false)
	if flow_node is not HFlowContainer:
		_fail("Expected gallery scene to use an HFlowContainer.")
		return false

	var flow: HFlowContainer = flow_node
	var host_right: float = host.get_global_rect().end.x + 1.0
	for child in flow.get_children():
		if child is Control:
			var tile: Control = child
			if tile.get_global_rect().end.x > host_right:
				_fail("Gallery %s layout overflowed horizontally." % label)
				return false

	return true


func _card(root: Node, name: String) -> PackRatDemoCard:
	var node: Node = root.find_child(name, true, false)
	if node is PackRatDemoCard:
		var card: PackRatDemoCard = node
		return card

	_fail("Could not find demo card %s." % name)
	return null


func _button(root: Node, name: String) -> Button:
	var node: Node = root.find_child(name, true, false)
	if node is Button:
		var button: Button = node
		return button

	_fail("Could not find button %s." % name)
	return null


func _option_button(root: Node, name: String) -> OptionButton:
	var node: Node = root.find_child(name, true, false)
	if node is OptionButton:
		var option_button: OptionButton = node
		return option_button

	_fail("Could not find option button %s." % name)
	return null


func _progress_bar(root: Node, name: String) -> ProgressBar:
	var node: Node = root.find_child(name, true, false)
	if node is ProgressBar:
		var progress_bar: ProgressBar = node
		return progress_bar

	_fail("Could not find progress bar %s." % name)
	return null


func _label(root: Node, name: String) -> Label:
	var node: Node = root.find_child(name, true, false)
	if node is Label:
		var label: Label = node
		return label

	_fail("Could not find label %s." % name)
	return null


func _text_edit(root: Node, name: String) -> TextEdit:
	var node: Node = root.find_child(name, true, false)
	if node is TextEdit:
		var text_edit: TextEdit = node
		return text_edit

	_fail("Could not find text edit %s." % name)
	return null


func _assert_font_size(root: Node, name: String, expected: int) -> bool:
	var node: Node = root.find_child(name, true, false)
	if node is not Control:
		_fail("Could not find font control %s." % name)
		return false

	var control: Control = node
	var actual: int = control.get_theme_font_size("font_size")
	if actual != expected:
		_fail("Expected %s font size %d, got %d." % [name, expected, actual])
		return false

	return true


func _assert_margin_container(root: Node, name: String) -> bool:
	var node: Node = root.find_child(name, true, false)
	if node is not MarginContainer:
		_fail("Could not find margin container %s." % name)
		return false

	var margin: MarginContainer = node
	for constant in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		var actual: int = margin.get_theme_constant(constant)
		if actual != EXPECTED_SPACE:
			_fail("Expected %s %s to be %d, got %d." % [name, constant, EXPECTED_SPACE, actual])
			return false

	return true


func _assert_separation(root: Node, name: String) -> bool:
	var node: Node = root.find_child(name, true, false)
	if node is not BoxContainer:
		_fail("Could not find box container %s." % name)
		return false

	var container: BoxContainer = node
	var actual: int = container.get_theme_constant("separation")
	if actual != EXPECTED_SPACE:
		_fail("Expected %s separation to be %d, got %d." % [name, EXPECTED_SPACE, actual])
		return false

	return true


func _assert_flow_separation(root: Node, name: String) -> bool:
	var node: Node = root.find_child(name, true, false)
	if node is not HFlowContainer:
		_fail("Could not find flow container %s." % name)
		return false

	var container: HFlowContainer = node
	for constant in ["h_separation", "v_separation"]:
		var actual: int = container.get_theme_constant(constant)
		if actual != EXPECTED_SPACE:
			_fail("Expected %s %s to be %d, got %d." % [name, constant, EXPECTED_SPACE, actual])
			return false

	return true


func _control(root: Node, name: String) -> Control:
	var node: Node = root.find_child(name, true, false)
	if node is Control:
		var control: Control = node
		return control

	_fail("Could not find control %s." % name)
	return null


func _fail(message: String) -> void:
	_stop_server()
	push_error(message)
	get_tree().quit(1)


func _on_timeout() -> void:
	_fail("PackRat demo smoke timed out. GET=%d HEAD=%d" % [_get_count, _head_count])


func _finish_success(message: String) -> void:
	var wait_until: int = Time.get_ticks_msec() + 1000
	while _active_peer_count > 0 and Time.get_ticks_msec() < wait_until:
		await get_tree().process_frame

	_stop_server()
	print(message)
	get_tree().quit()


func _stop_server() -> void:
	if _server != null:
		_server.stop()
		_server = null
