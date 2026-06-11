class_name PackRat
extends RefCounted

const SERVICE_NODE_NAME := "PackRatService"

static var _service: Node


static func prepare(url: String, options: PackRatOptions = null) -> PackRatResult:
	if options == null:
		options = PackRatOptions.new()

	var service := _get_or_create_service()
	if service == null:
		return PackRatResult.failed(url, "PackRat.prepare() needs a running SceneTree.")

	if not service.is_inside_tree():
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			await tree.process_frame

	return await service.prepare(url, options)


static func _get_or_create_service() -> Node:
	if is_instance_valid(_service):
		return _service

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null

	var existing := tree.root.get_node_or_null(SERVICE_NODE_NAME)
	if existing != null:
		_service = existing
		return _service

	_service = _Service.new()
	_service.name = SERVICE_NODE_NAME
	tree.root.add_child.call_deferred(_service)
	return _service
