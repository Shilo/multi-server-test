class_name PackRatDemoPack extends RefCounted
## One downloadable PackRat Portal showcase pack.

## Stable cache ID used for this pack.
var id: String = ""

## User-facing pack title.
var title: String = ""

## Short 2-4 word user-facing description of the pack's content.
var summary: String = ""

## Pack format label, usually PCK or ZIP.
var format: String = ""

## Release asset and mirrored static-host filename.
var file_name: String = ""

## Scene path exposed after the pack is mounted.
var entry_path: String = ""

## Exported remote file size shown by the demo UI.
var file_size: int = 0

## Exported content token used to avoid stale HTTP and PackRat cache hits.
var version_token: String = ""

## Editor export preset that builds this pack for local testing.
var editor_export_preset: String = ""

## Card accent color.
var accent_color: Color = Color.WHITE


## Creates a complete immutable pack descriptor for the demo catalog.
static func create(
	pack_id: String,
	pack_title: String,
	pack_summary: String,
	pack_format: String,
	pack_file_name: String,
	pack_entry_path: String,
	pack_file_size: int,
	pack_version_token: String,
	pack_editor_export_preset: String,
	pack_accent_color: Color
) -> PackRatDemoPack:
	var pack: PackRatDemoPack = PackRatDemoPack.new()
	pack.id = pack_id
	pack.title = pack_title
	pack.summary = pack_summary
	pack.format = pack_format
	pack.file_name = pack_file_name
	pack.entry_path = pack_entry_path
	pack.file_size = pack_file_size
	pack.version_token = pack_version_token
	pack.editor_export_preset = pack_editor_export_preset
	pack.accent_color = pack_accent_color
	return pack


## Returns this pack's static-host URL.
func pages_url() -> String:
	return PackRat.versioned_url(PackRat.join_url(PackRatDemoCatalog.pages_pack_base_url, file_name), version_token)


## Returns this pack's GitHub Release URL.
func github_release_url() -> String:
	return PackRat.versioned_url(PackRat.github_release_url(
		PackRatDemoCatalog.RELEASE_OWNER,
		PackRatDemoCatalog.RELEASE_REPO,
		file_name,
		PackRatDemoCatalog.release_tag
	), version_token)


## Returns this pack's URL for [param source].
func url_for_source(source: String) -> String:
	if source == PackRatDemoCatalog.SOURCE_GITHUB_RELEASE:
		return github_release_url()

	return pages_url()


## Builds PackRat options for this pack.
func options() -> PackRatOptions:
	var pack_options: PackRatOptions = PackRatOptions.new()
	pack_options.id = id
	pack_options.entry_path = entry_path
	pack_options.progress_total_size = file_size
	pack_options.offline_first = true
	pack_options.use_threads = PackRatDemoCatalog.use_threads
	pack_options.capture_timings = true
	return pack_options


## Builds PackRat options for this pack and source mode.
func options_for_source(source: String) -> PackRatOptions:
	var pack_options: PackRatOptions = options()
	if source == PackRatDemoCatalog.SOURCE_EDITOR_EXPORT:
		pack_options.editor_pack_export_preset = editor_export_preset
		pack_options.editor_simulated_local_load_seconds = PackRatDemoCatalog.editor_simulated_local_load_seconds

	return pack_options
