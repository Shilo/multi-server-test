class_name PackRatDemo extends Control
## PackRat Portal: a polished WebGL-friendly runtime DLC showcase.

const _SOURCE_ARG: String = "--source="
const _PACK_BASE_ARG: String = "--pack-base-url="
const _RELEASE_TAG_ARG: String = "--release-tag="
const _AUTO_LOAD_ARG: String = "--auto-load="
const _DOWNLOADER_ARG: String = "--downloader="
const _DOWNLOADER_FETCH: String = "fetch"
const _DOWNLOADER_HTTP_REQUEST: String = "httprequest"
const _NARROW_WIDTH: float = 900.0
const _SPACE: int = 10
const _SOURCE_INDEX_PAGES: int = 0
const _SOURCE_INDEX_GITHUB_RELEASE: int = 1
const _SOURCE_INDEX_EDITOR_EXPORT: int = 2

var _source: String = PackRatDemoCatalog.SOURCE_PAGES
var _use_web_fetch: bool = true
var _pack_base_arg_applied: bool = false
var _cards: Array[PackRatDemoCard] = []
var _quit_when_done: bool = false
var _auto_load_ids: PackedStringArray = []
var _pending_auto_loads: int = 0
var _auto_load_failed: bool = false

@onready var _page: MarginContainer = %Page
@onready var _body: BoxContainer = %Body
@onready var _cards_panel: PanelContainer = %CardsPanel
@onready var _source_selector: OptionButton = %SourceSelector
@onready var _download_client_row: HBoxContainer = %DownloaderRow
@onready var _download_client_selector: OptionButton = %DownloadClientSelector
@onready var _mounted_scene_host: Control = %MountedSceneHost
@onready var _preview_placeholder: Control = %PreviewPlaceholder
@onready var _preview_host: Control = %PreviewHost
@onready var _clear_all_button: Button = %ClearAllButton
@onready var _output_text: TextEdit = %OutputText
@onready var _warehouse_card: PackRatDemoCard = %WarehouseCard
@onready var _gallery_card: PackRatDemoCard = %GalleryCard


func _ready() -> void:
	_apply_user_args()
	_apply_source_limits()
	get_viewport().size_changed.connect(_apply_responsive_layout)
	_cards = [_warehouse_card, _gallery_card]
	_source_selector.select(_source_index(_source))
	_download_client_row.visible = OS.has_feature("web")
	_download_client_selector.select(0 if _use_web_fetch else 1)
	_source_selector.item_selected.connect(_on_source_selected)
	_download_client_selector.item_selected.connect(_on_downloader_selected)
	_clear_all_button.pressed.connect(_on_clear_all_pressed)

	for card in _cards:
		card.set_source(_source)
		card.set_use_web_fetch(_use_web_fetch)
		card.preview_requested.connect(_on_preview_requested)
		card.load_finished.connect(_on_load_finished)
		card.message_requested.connect(_append_output)

	_apply_responsive_layout()
	_show_placeholder()
	_append_output("Ready. Offline-first cache hits enabled.")
	_start_auto_loads()


func _show_placeholder() -> void:
	_clear_preview()
	_preview_placeholder.visible = true


func _apply_responsive_layout() -> void:
	var viewport_size: Vector2 = get_viewport_rect().size
	var narrow: bool = viewport_size.x < _NARROW_WIDTH or viewport_size.x < viewport_size.y
	_body.vertical = narrow

	_page.add_theme_constant_override("margin_left", _SPACE)
	_page.add_theme_constant_override("margin_top", _SPACE)
	_page.add_theme_constant_override("margin_right", _SPACE)
	_page.add_theme_constant_override("margin_bottom", _SPACE)

	var cards_minimum_size: Vector2 = _cards_panel.custom_minimum_size
	cards_minimum_size.x = 0.0 if narrow else 360.0
	_cards_panel.custom_minimum_size = cards_minimum_size
	_preview_host.custom_minimum_size = Vector2(0.0 if narrow else 420.0, 260.0 if narrow else 320.0)


func _append_output(message: String, is_error: bool = false) -> void:
	if message.is_empty():
		return

	var line: String = "- %s" % message
	if is_error:
		line = "- ERROR: %s" % message
		printerr("PackRat demo error: %s" % message)
	else:
		print("PackRat demo: %s" % message)

	if _output_text.text.is_empty():
		_output_text.text = line
	else:
		_output_text.text = "%s\n%s" % [_output_text.text, line]
	_scroll_output_to_bottom.call_deferred()


func _scroll_output_to_bottom() -> void:
	_output_text.scroll_vertical = float(_output_text.get_line_count())


func _on_source_selected(index: int) -> void:
	if index == _SOURCE_INDEX_GITHUB_RELEASE and not PackRat.can_download_github_releases():
		_source_selector.select(_SOURCE_INDEX_PAGES)
		_source = PackRatDemoCatalog.SOURCE_PAGES
		_append_output("GitHub Release assets are blocked by browser CORS; using GitHub Pages.", true)
		return

	if index == _SOURCE_INDEX_EDITOR_EXPORT and not OS.has_feature("editor"):
		_source_selector.select(_SOURCE_INDEX_PAGES)
		_source = PackRatDemoCatalog.SOURCE_PAGES
		_append_output("Editor export preset source is only available in editor runs; using GitHub Pages.", true)
		return

	_source = _source_from_index(index)
	for card in _cards:
		card.set_source(_source)
	_append_output("Source set to %s." % PackRatDemoCatalog.source_label(_source))


func _on_downloader_selected(index: int) -> void:
	_use_web_fetch = index == 0
	for card in _cards:
		card.set_use_web_fetch(_use_web_fetch)
	_append_output("Downloader set to %s." % _downloader_label())


func _on_preview_requested(pack: PackRatDemoPack, result: PackRatResult) -> void:
	var scene: PackedScene = result.load_entry_scene()
	if scene == null:
		_append_output("Entry scene was not found after mount.", true)
		return

	_clear_preview()
	_preview_placeholder.visible = false
	var instance: Node = scene.instantiate()
	_mounted_scene_host.add_child(instance)
	if instance is Control:
		var control: Control = instance
		control.set_anchors_preset(Control.PRESET_FULL_RECT)

	_append_output("Previewing %s." % pack.title)


func _on_clear_all_pressed() -> void:
	var options: PackRatOptions = PackRatOptions.new()
	options.cache_dir = PackRatDemoCatalog.cache_dir
	var error: Error = PackRat.clear_cache(options)
	if error == OK:
		_append_output("Disk cache cleared.")
	else:
		_append_output("Could not clear disk cache (error %d)." % error, true)


func _on_load_finished(_pack: PackRatDemoPack, result: PackRatResult) -> void:
	if _pending_auto_loads <= 0:
		return

	_pending_auto_loads -= 1
	if not result.ok:
		_auto_load_failed = true

	if _pending_auto_loads == 0 and _quit_when_done:
		if _auto_load_failed:
			_append_output("Auto-load finished with errors.", true)
		else:
			_append_output("Auto-load finished.")
		get_tree().quit(1 if _auto_load_failed else 0)


func _clear_preview() -> void:
	for child in _mounted_scene_host.get_children():
		child.queue_free()


func _start_auto_loads() -> void:
	if _auto_load_ids.is_empty():
		if _quit_when_done:
			_append_output("No auto-load packs requested.")
			get_tree().quit()
		return

	for card in _cards:
		var pack: PackRatDemoPack = card.pack()
		if pack != null and _auto_load_ids.has(pack.id):
			_pending_auto_loads += 1
			card.load_pack()

	if _pending_auto_loads == 0 and _quit_when_done:
		_append_output("No matching auto-load packs were found.", true)
		get_tree().quit(1)


func _apply_user_args() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(_SOURCE_ARG):
			var source: String = argument.substr(_SOURCE_ARG.length())
			if (
				source == PackRatDemoCatalog.SOURCE_GITHUB_RELEASE
				or source == PackRatDemoCatalog.SOURCE_PAGES
				or source == PackRatDemoCatalog.SOURCE_EDITOR_EXPORT
			):
				_source = source
		elif argument.begins_with(_PACK_BASE_ARG):
			_pack_base_arg_applied = true
			PackRatDemoCatalog.pages_pack_base_url = argument.substr(_PACK_BASE_ARG.length())
		elif argument.begins_with(_RELEASE_TAG_ARG):
			PackRatDemoCatalog.release_tag = argument.substr(_RELEASE_TAG_ARG.length())
		elif argument.begins_with(_AUTO_LOAD_ARG):
			_auto_load_ids = argument.substr(_AUTO_LOAD_ARG.length()).split(",", false)
		elif argument.begins_with(_DOWNLOADER_ARG):
			var downloader: String = argument.substr(_DOWNLOADER_ARG.length()).to_lower()
			if downloader == _DOWNLOADER_FETCH:
				_use_web_fetch = true
			elif downloader == _DOWNLOADER_HTTP_REQUEST or downloader == "http_request":
				_use_web_fetch = false
		elif argument == "--quit-when-done":
			_quit_when_done = true

	if not _pack_base_arg_applied:
		PackRatDemoCatalog.use_web_same_origin_pack_base()


func _apply_source_limits() -> void:
	if not PackRat.can_download_github_releases():
		if _source == PackRatDemoCatalog.SOURCE_GITHUB_RELEASE:
			_source = PackRatDemoCatalog.SOURCE_PAGES

		_source_selector.set_item_disabled(_SOURCE_INDEX_GITHUB_RELEASE, true)
		_source_selector.set_item_text(_SOURCE_INDEX_GITHUB_RELEASE, "GitHub Release asset (native only)")

	if not OS.has_feature("editor"):
		if _source == PackRatDemoCatalog.SOURCE_EDITOR_EXPORT:
			_source = PackRatDemoCatalog.SOURCE_PAGES

		_source_selector.set_item_disabled(_SOURCE_INDEX_EDITOR_EXPORT, true)
		_source_selector.set_item_text(_SOURCE_INDEX_EDITOR_EXPORT, "Editor export preset (editor only)")


func _source_from_index(index: int) -> String:
	if index == _SOURCE_INDEX_GITHUB_RELEASE:
		return PackRatDemoCatalog.SOURCE_GITHUB_RELEASE
	if index == _SOURCE_INDEX_EDITOR_EXPORT:
		return PackRatDemoCatalog.SOURCE_EDITOR_EXPORT

	return PackRatDemoCatalog.SOURCE_PAGES


func _source_index(source: String) -> int:
	if source == PackRatDemoCatalog.SOURCE_GITHUB_RELEASE:
		return _SOURCE_INDEX_GITHUB_RELEASE
	if source == PackRatDemoCatalog.SOURCE_EDITOR_EXPORT:
		return _SOURCE_INDEX_EDITOR_EXPORT

	return _SOURCE_INDEX_PAGES


func _downloader_label() -> String:
	if not OS.has_feature("web"):
		return "Godot HTTPRequest"
	if _use_web_fetch:
		return "browser fetch"
	return "Godot HTTPRequest"
