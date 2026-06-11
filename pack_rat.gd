class_name PackRat
extends RefCounted

const SERVICE_NODE_NAME := "PackRatService"

static var _service: PackRatService


static func prepare(source: Variant, options: PackRatOptions = null) -> PackRatResult:
	var service := _get_or_create_service()
	if service == null:
		return PackRatResult.failed("PackRat.prepare() needs a running SceneTree.")

	return await service.prepare(source, options)


static func prepare_descriptor(descriptor: PackRatDescriptor, options: PackRatOptions = null) -> PackRatResult:
	return await prepare(descriptor, options)


static func use_service(service: PackRatService) -> void:
	_service = service


static func clear_service() -> void:
	_service = null


static func _get_or_create_service() -> PackRatService:
	if is_instance_valid(_service):
		return _service

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null

	var existing := tree.root.get_node_or_null(SERVICE_NODE_NAME) as PackRatService
	if existing != null:
		_service = existing
		return _service

	_service = PackRatService.new()
	_service.name = SERVICE_NODE_NAME
	tree.root.add_child(_service)
	return _service
