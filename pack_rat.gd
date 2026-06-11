class_name PackRat extends RefCounted
## Static facade for preparing downloadable Godot PCK/ZIP content at runtime.
## [br][br]
## The main API is [method prepare]. It lazily creates [member service] under the
## scene tree root so callers do not need an autoload or editor plugin.

static var _service: PackRatService = null

## Runtime worker node used by [method prepare].
## [br][br]
## PackRat creates this node automatically on first use because Godot's
## [HTTPRequest] requires a node in the scene tree.
static var service: PackRatService:
	get:
		var _service_node_name: String = "PackRatService"

		if is_instance_valid(_service):
			return _service

		var tree: SceneTree = Engine.get_main_loop()
		if tree == null or tree.root == null:
			return null

		var existing: Node = tree.root.get_node_or_null(_service_node_name)
		if existing is PackRatService:
			_service = existing
			return _service

		_service = PackRatService.new()
		_service.name = _service_node_name
		tree.root.add_child.call_deferred(_service)
		return _service


## Downloads, freshness-checks, caches, and mounts the pack at [param url].
## [br][br]
## Returns a [PackRatResult] with [member PackRatResult.ok] set to [code]true[/code]
## when the file is ready. [param options] can override cache location,
## replacement behavior, request headers, timeout, and entry path.
static func prepare(url: String, options: PackRatOptions = PackRatOptions.new()) -> PackRatResult:
	var runtime_service: PackRatService = service
	if runtime_service == null:
		return PackRatResult.failed(url, "PackRat.prepare() needs a running SceneTree.")

	if not runtime_service.is_inside_tree():
		var tree: SceneTree = Engine.get_main_loop()
		if tree != null:
			await tree.process_frame

	return await runtime_service.prepare(url, options)
