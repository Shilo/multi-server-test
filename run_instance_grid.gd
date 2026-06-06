extends Node
## MimicRunInstanceGrid optional editor-only AutoLoad.
## [br][br]
## Not registered automatically by the plugin; add this script as an AutoLoad
## to enable window tiling.
## Automatically tiles multiple Godot run-instance windows into a shared grid.
## [br][br]
## This utility is intended for local multiplayer testing from the editor. Make
## sure "Game > Embedding Options > Embed Game on Next Play" is disabled so run
## instances open as separate windows. Each run instance writes a short-lived
## marker file, discovers sibling instances from the same launch burst, then
## moves and resizes itself into a screen tile.
## [br][br]
## Window titles show launch order. When a window has an active multiplayer
## connection, the title also shows its local peer ID so each session is easier
## to match with debugger tabs and peer-tagged logs.
## [br][br]
## "Fill" uses the whole grid cell as the window frame. "Fit" shrinks and
## centers the window inside that cell so Godot's aspect-preserving stretch modes
## do not create black bars inside the game viewport.

const _DIR := "user://mimic/run_grid"
const _GROUP_MS := 3000
const _STALE_MS := 15_000
const _SETTLE_TIMEOUT := 2.0
const _SETTLE_STEP := 0.15
const _STABLE_SCANS := 3
const _MIN_SIZE := Vector2i(96, 96)
const _MIN_CLIENT_SIZE := Vector2i(1, 1)
const _APPEND_WINDOW_INDEX := true
const _STRETCH_MODE_SETTING := "display/window/stretch/mode"
const _STRETCH_ASPECT_SETTING := "display/window/stretch/aspect"
const _STRETCH_MODE_CANVAS_ITEMS := "canvas_items"
const _STRETCH_MODE_VIEWPORT := "viewport"
const _STRETCH_ASPECT_KEEP := "keep"
const _STRETCH_ASPECT_KEEP_WIDTH := "keep_width"
const _STRETCH_ASPECT_KEEP_HEIGHT := "keep_height"

var _base_title := ""
var _grid_title := ""


func _ready() -> void:
	if not OS.has_feature("editor"):
		return
	if DisplayServer.get_name() == "headless":
		return

	_base_title = get_window().title

	DirAccess.make_dir_recursive_absolute(_DIR)

	var started_at := _now_ms()
	var marker := "%d_%d" % [started_at, OS.get_process_id()]
	FileAccess.open("%s/%s" % [_DIR, marker], FileAccess.WRITE)

	var markers := await _wait_for_markers(started_at)
	var index := markers.find(marker)

	if index < 0 or markers.size() < 2:
		_remove_marker(marker)
		return

	if _APPEND_WINDOW_INDEX:
		_set_grid_title(index, markers.size())
		_connect_multiplayer_title_signals()
		_refresh_connection_title()

	_tile(index, markers.size())


func _wait_for_markers(started_at: int) -> Array[String]:
	var markers: Array[String] = []

	return await _wait_for_markers_scan(started_at, markers, -1, 0, 0.0)


func _wait_for_markers_scan(
	started_at: int,
	markers: Array[String],
	previous_count: int,
	stable_scans: int,
	elapsed: float
) -> Array[String]:
	if elapsed >= _SETTLE_TIMEOUT:
		return markers

	markers = _get_markers(started_at)
	if markers.size() == previous_count:
		stable_scans += 1
	else:
		stable_scans = 0
		previous_count = markers.size()

	if stable_scans >= _STABLE_SCANS:
		return markers

	await get_tree().create_timer(_SETTLE_STEP).timeout
	return await _wait_for_markers_scan(
		started_at,
		markers,
		previous_count,
		stable_scans,
		elapsed + _SETTLE_STEP
	)


func _get_markers(started_at: int) -> Array[String]:
	var markers: Array[String] = []
	var now := _now_ms()

	for file_name in DirAccess.get_files_at(_DIR):
		var time := file_name.get_slice("_", 0).to_int()

		if now - time > _STALE_MS:
			DirAccess.remove_absolute("%s/%s" % [_DIR, file_name])
		elif abs(time - started_at) <= _GROUP_MS:
			markers.append(file_name)

	markers.sort()
	return markers


func _tile(index: int, count: int) -> void:
	var area := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var reference_client_size := _get_reference_client_size()
	var cell_rect := _get_cell_rect(index, count, area, reference_client_size)
	var frame_margins := _get_frame_decoration_margins()

	# Fill uses the whole cell. Fit shrinks and centers the frame only when
	# Godot would otherwise letterbox or pillarbox the game content.
	var should_fit_to_cell := _should_fit_to_cell(
		cell_rect,
		reference_client_size,
		frame_margins
	)
	var frame_rect := cell_rect
	if should_fit_to_cell:
		frame_rect = _fit_frame_rect_to_cell(
			cell_rect,
			reference_client_size,
			frame_margins
		)

	_set_frame_rect(frame_rect, frame_margins)


func _get_cell_rect(
	index: int,
	count: int,
	area: Rect2i,
	reference_client_size: Vector2i
) -> Rect2i:
	var grid := _get_grid(count, area.size, _get_aspect(reference_client_size))
	var cell := Vector2i(area.size.x / grid.x, area.size.y / grid.y)
	var slot := Vector2i(index % grid.x, index / grid.x)

	return Rect2i(area.position + slot * cell, cell)


func _get_reference_client_size() -> Vector2i:
	var reference_size := get_window().content_scale_size
	if reference_size.x <= 0 or reference_size.y <= 0:
		reference_size = DisplayServer.window_get_size()

	return reference_size.max(_MIN_SIZE)


func _get_grid(count: int, screen_size: Vector2i, target_aspect := 16.0 / 9.0) -> Vector2i:
	var best := Vector2i(count, 1)
	var best_score: float = INF

	for rows in range(1, count + 1):
		var columns := ceili(float(count) / rows)
		var cell := Vector2(float(screen_size.x) / columns, float(screen_size.y) / rows)
		var score: float = absf(cell.aspect() - target_aspect)

		if score < best_score:
			best_score = score
			best = Vector2i(columns, rows)

	return best


func _get_frame_decoration_margins() -> Vector4i:
	# Only the titlebar height (top) is measured from the OS frame. The
	# left/right/bottom borders are deliberately hardcoded — see
	# _get_frame_border_size for the recurring regression this avoids.
	var client_top := DisplayServer.window_get_position().y
	var frame_top := DisplayServer.window_get_position_with_decorations().y
	var titlebar_height := maxi(0, client_top - frame_top)
	var border := _get_frame_border_size()

	return Vector4i(border.x, titlebar_height, border.x, border.y)


func _get_frame_border_size() -> Vector2i:
	# RECURRING REGRESSION — READ BEFORE CHANGING. Returns the VISIBLE window
	# border thickness (x = left and right, y = bottom).
	#
	# Do NOT replace this with a value measured from
	# DisplayServer.window_get_*_with_decorations(). On Windows those return
	# GetWindowRect (Godot platform/windows/display_server_windows.cpp ->
	# window_get_position_with_decorations / window_get_size_with_decorations),
	# which INCLUDES the invisible DWM resize border (~7 px per side on Windows
	# 10/11). That phantom border is not part of the visible window, so
	# subtracting it from each grid cell insets every window and leaves a visible
	# gap between tiled windows. The visible border is ~1 px; only the titlebar
	# (top) is safe to measure. This gap has been reintroduced several times by
	# "just measure the real decorations" refactors — keep it hardcoded.
	if OS.has_feature("windows"):
		return Vector2i(1, 1)

	return Vector2i.ZERO


func _should_fit_to_cell(
	cell_rect: Rect2i,
	reference_client_size: Vector2i,
	frame_margins := Vector4i(0, 0, 0, 0)
) -> bool:
	var stretch_mode := String(ProjectSettings.get_setting(_STRETCH_MODE_SETTING, "disabled"))
	var stretch_aspect := String(
		ProjectSettings.get_setting(_STRETCH_ASPECT_SETTING, _STRETCH_ASPECT_KEEP)
	)
	return _should_fit_to_cell_for_stretch(
		cell_rect,
		reference_client_size,
		frame_margins,
		stretch_mode,
		stretch_aspect
	)


func _should_fit_to_cell_for_stretch(
	cell_rect: Rect2i,
	reference_client_size: Vector2i,
	frame_margins: Vector4i,
	stretch_mode: String,
	stretch_aspect: String
) -> bool:
	if stretch_mode != _STRETCH_MODE_CANVAS_ITEMS and stretch_mode != _STRETCH_MODE_VIEWPORT:
		return false

	var target_client_size := _get_unclamped_frame_client_size(
		cell_rect.size,
		frame_margins
	).max(Vector2i(1, 1))
	var reference_aspect := _get_aspect(reference_client_size)
	var target_aspect := _get_aspect(target_client_size)
	if is_equal_approx(reference_aspect, target_aspect):
		return false

	# Keep width/height modes only add bars in one direction; mirror Godot's
	# Window content-scale aspect branches instead of fitting every keep variant.
	if stretch_aspect == _STRETCH_ASPECT_KEEP:
		return true
	if stretch_aspect == _STRETCH_ASPECT_KEEP_WIDTH:
		return target_aspect > reference_aspect
	if stretch_aspect == _STRETCH_ASPECT_KEEP_HEIGHT:
		return target_aspect < reference_aspect

	return false


func _fit_frame_rect_to_cell(
	cell_rect: Rect2i,
	reference_client_size: Vector2i,
	frame_margins := Vector4i(0, 0, 0, 0)
) -> Rect2i:
	var frame_chrome_size := _get_frame_chrome_size(frame_margins)
	var available_client_size := _get_frame_client_size(
		cell_rect.size,
		frame_margins
	)
	var fitted_client_size := _fit_size_to_aspect(available_client_size, reference_client_size)
	# A cell smaller than the window chrome cannot preserve aspect; clamp so the
	# fitted frame never spills out of its cell and overlaps a neighbor.
	var fitted_frame_size := (fitted_client_size + frame_chrome_size).min(cell_rect.size)
	var fitted_frame_position := cell_rect.position + (cell_rect.size - fitted_frame_size) / 2

	return Rect2i(fitted_frame_position, fitted_frame_size)


func _get_frame_chrome_size(frame_margins := Vector4i(0, 0, 0, 0)) -> Vector2i:
	return Vector2i(frame_margins.x + frame_margins.z, frame_margins.y + frame_margins.w)


func _get_frame_client_size(
	frame_size: Vector2i,
	frame_margins := Vector4i(0, 0, 0, 0)
) -> Vector2i:
	return _get_unclamped_frame_client_size(frame_size, frame_margins).max(_MIN_CLIENT_SIZE)


func _get_unclamped_frame_client_size(
	frame_size: Vector2i,
	frame_margins := Vector4i(0, 0, 0, 0)
) -> Vector2i:
	return frame_size - _get_frame_chrome_size(frame_margins)


func _fit_size_to_aspect(available_size: Vector2i, reference_size: Vector2i) -> Vector2i:
	if reference_size.x <= 0 or reference_size.y <= 0:
		return available_size

	var aspect := _get_aspect(reference_size)
	var height_from_width := maxi(1, floori(float(available_size.x) / aspect))
	if height_from_width <= available_size.y:
		return Vector2i(available_size.x, height_from_width)

	var width_from_height := maxi(1, floori(float(available_size.y) * aspect))
	return Vector2i(width_from_height, available_size.y)


func _get_aspect(size: Vector2i) -> float:
	if size.y <= 0:
		return 16.0 / 9.0

	return float(size.x) / float(size.y)


func _set_frame_rect(rect: Rect2i, frame_margins := Vector4i(0, 0, 0, 0)) -> Vector2i:
	var frame_chrome_size := _get_frame_chrome_size(frame_margins)
	var client_size := _get_frame_client_size(rect.size, frame_margins)
	var frame_size := client_size + frame_chrome_size
	var frame_position := rect.position + (rect.size - frame_size) / 2

	get_window().size = client_size
	get_window().position = frame_position + Vector2i(frame_margins.x, frame_margins.y)

	return client_size


func _connect_multiplayer_title_signals() -> void:
	# Title updates are purely event-driven off MultiplayerAPI; no polling. There
	# is no signal for assigning or clearing the local peer, so a lone server
	# with no remote peers keeps its launch-order title until a peer connects.
	# That edge case is accepted on purpose to avoid a refresh timer.
	var multiplayer_api := multiplayer
	if multiplayer_api == null:
		return

	if not multiplayer_api.connected_to_server.is_connected(_on_multiplayer_state_changed):
		multiplayer_api.connected_to_server.connect(_on_multiplayer_state_changed)
	if not multiplayer_api.connection_failed.is_connected(_on_multiplayer_state_changed):
		multiplayer_api.connection_failed.connect(_on_multiplayer_state_changed)
	if not multiplayer_api.server_disconnected.is_connected(_on_multiplayer_state_changed):
		multiplayer_api.server_disconnected.connect(_on_multiplayer_state_changed)
	if not multiplayer_api.peer_connected.is_connected(_on_multiplayer_peer_connection_changed):
		multiplayer_api.peer_connected.connect(_on_multiplayer_peer_connection_changed)
	if not multiplayer_api.peer_disconnected.is_connected(_on_multiplayer_peer_connection_changed):
		multiplayer_api.peer_disconnected.connect(_on_multiplayer_peer_connection_changed)


func _set_grid_title(index: int, count: int) -> void:
	_grid_title = _format_window_index_title(_base_title, index, count)
	get_window().title = _grid_title


func _refresh_connection_title() -> void:
	var peer_id := _get_multiplayer_peer_id()
	var target_title := _grid_title
	if peer_id > 0 and not _grid_title.is_empty():
		target_title = _format_peer_title(_grid_title, peer_id)

	var window := get_window()
	if not target_title.is_empty() and window.title != target_title:
		window.title = target_title


func _get_multiplayer_peer_id() -> int:
	var multiplayer_api := multiplayer
	if multiplayer_api == null or not multiplayer_api.has_multiplayer_peer():
		return 0

	var current_peer := multiplayer_api.multiplayer_peer
	if current_peer == null or current_peer is OfflineMultiplayerPeer:
		return 0
	if current_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return 0

	return multiplayer_api.get_unique_id()


func _format_window_index_title(base_title: String, index: int, count: int) -> String:
	return "%s [Session %d/%d]" % [base_title, index + 1, count]


func _format_peer_title(grid_title: String, peer_id: int) -> String:
	return "%s [Peer %d]" % [grid_title, peer_id]


func _on_multiplayer_state_changed() -> void:
	_refresh_connection_title()


func _on_multiplayer_peer_connection_changed(_peer_id: int) -> void:
	_refresh_connection_title()


func _remove_marker(marker: String) -> void:
	var path := "%s/%s" % [_DIR, marker]
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)
