class_name PackRatDemoCatalog extends RefCounted
## Static catalog for the PackRat Portal demo.

## Same-origin static-host source used by the WebGL demo.
const SOURCE_PAGES: String = "pages"

## GitHub Release source, mainly for native/editor testing.
const SOURCE_GITHUB_RELEASE: String = "github_release"

## Editor-only local source backed by Godot export presets.
const SOURCE_EDITOR_EXPORT: String = "editor_export"

## Repository owner for canonical GitHub Release assets.
const RELEASE_OWNER: String = "Shilo"

## Repository name for canonical GitHub Release assets.
const RELEASE_REPO: String = "pack-rat"

## Warehouse PCK release asset filename.
const WAREHOUSE_FILE_NAME: String = "packrat-demo-warehouse.pck"

## Gallery ZIP release asset filename.
const GALLERY_FILE_NAME: String = "packrat-demo-gallery.zip"

## Warehouse editor export preset.
const WAREHOUSE_EXPORT_PRESET: String = "Warehouse DLC"

## Gallery editor export preset.
const GALLERY_EXPORT_PRESET: String = "Gallery DLC"

## Warehouse PCK entry scene.
const WAREHOUSE_ENTRY_PATH: String = "res://demo/packs/warehouse/main.tscn"

## Gallery ZIP entry scene.
const GALLERY_ENTRY_PATH: String = "res://demo/packs/gallery/main.tscn"

## Exported byte size for the warehouse PCK.
const WAREHOUSE_FILE_SIZE: int = 10522132

## Exported byte size for the gallery ZIP.
const GALLERY_FILE_SIZE: int = 16795589

## Exported content version for the warehouse PCK.
const WAREHOUSE_VERSION_TOKEN: String = "10522132-a21e767bd032"

## Exported content version for the gallery ZIP.
const GALLERY_VERSION_TOKEN: String = "16795589-aa9c3fa746d7"

## Canonical Pages pack mirror used outside Web exports.
static var pages_pack_base_url: String = PackRat.github_pages_url(RELEASE_OWNER, RELEASE_REPO, "packs")

## Release tag used by [method PackRat.github_release_url].
static var release_tag: String = "latest"

## Cache directory used by the demo cards.
static var cache_dir: String = "user://pack_rat_demo"

## Whether demo cards use native HTTPRequest worker threads.
static var use_threads: bool = true

## Editor-only duration used to make local export-preset loads visibly test progress.
static var editor_simulated_local_load_seconds: float = 1.25


## Uses the current browser page as the static pack host when running on Web.
static func use_web_same_origin_pack_base() -> void:
	if not Engine.has_singleton("JavaScriptBridge"):
		return

	var javascript: Object = Engine.get_singleton("JavaScriptBridge")
	if javascript == null:
		return

	var value: Variant = javascript.call("eval", "new URL('packs', window.location.href).href", true)
	if typeof(value) == TYPE_STRING and not String(value).is_empty():
		pages_pack_base_url = String(value).trim_suffix("/")


## Returns the hardcoded showcase packs.
static func packs() -> Array[PackRatDemoPack]:
	var result: Array[PackRatDemoPack] = []
	result.append(PackRatDemoPack.create(
		"warehouse",
		"Warehouse PCK",
		"Box room",
		"PCK",
		WAREHOUSE_FILE_NAME,
		WAREHOUSE_ENTRY_PATH,
		WAREHOUSE_FILE_SIZE,
		WAREHOUSE_VERSION_TOKEN,
		WAREHOUSE_EXPORT_PRESET,
		Color.html("#8A5729")
	))
	result.append(PackRatDemoPack.create(
		"gallery",
		"Gallery ZIP",
		"Content gallery",
		"ZIP",
		GALLERY_FILE_NAME,
		GALLERY_ENTRY_PATH,
		GALLERY_FILE_SIZE,
		GALLERY_VERSION_TOKEN,
		GALLERY_EXPORT_PRESET,
		Color.html("#27806C")
	))
	return result


## Returns the pack with [param id], or [code]null[/code] when it is unknown.
static func pack_by_id(id: String) -> PackRatDemoPack:
	for pack in packs():
		if pack.id == id:
			return pack

	return null


## Returns a compact label for [param source].
static func source_label(source: String) -> String:
	if source == SOURCE_GITHUB_RELEASE:
		return "GitHub Release"
	if source == SOURCE_EDITOR_EXPORT:
		return "Editor export preset"

	return "GitHub Pages"
