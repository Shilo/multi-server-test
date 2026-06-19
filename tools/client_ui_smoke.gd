extends SceneTree


func _init() -> void:
	var packed_scene: PackedScene = load("res://client/client.tscn")
	if packed_scene == null:
		push_error("CLIENT_UI_SMOKE_FAIL missing client scene")
		quit(1)
		return

	var scene := packed_scene.instantiate()
	var stats_label := scene.get_node_or_null("CanvasLayer/NetworkStatsLabel")
	var status_label := scene.get_node_or_null("CanvasLayer/StatusLabel")
	var pack_progress := scene.get_node_or_null("CanvasLayer/WorldPackProgress")
	if not stats_label is Label:
		push_error("CLIENT_UI_SMOKE_FAIL missing NetworkStatsLabel Label")
		quit(1)
		return
	if not status_label is Label or not pack_progress is ProgressBar:
		push_error("CLIENT_UI_SMOKE_FAIL missing baseline client HUD nodes")
		quit(1)
		return
	if stats_label.text != "net: connecting":
		push_error("CLIENT_UI_SMOKE_FAIL empty NetworkStatsLabel text")
		quit(1)
		return
	if stats_label.size.y < 100.0:
		push_error("CLIENT_UI_SMOKE_FAIL NetworkStatsLabel is too short")
		quit(1)
		return

	scene.free()
	print("CLIENT_UI_SMOKE_PASS")
	quit(0)
