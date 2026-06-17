class_name RuntimeLoopConfig
extends RefCounted

const MASTER_PHYSICS_TICKS_PER_SECOND := 1
const MASTER_MAX_FPS := 20
const WORLD_PHYSICS_TICKS_PER_SECOND := 20
const WORLD_MAX_FPS := 20


static func apply_master() -> void:
	_apply("master", MASTER_PHYSICS_TICKS_PER_SECOND, MASTER_MAX_FPS)


static func apply_world() -> void:
	_apply("world", WORLD_PHYSICS_TICKS_PER_SECOND, WORLD_MAX_FPS)


static func _apply(role: String, physics_ticks_per_second: int, max_fps: int) -> void:
	Engine.physics_ticks_per_second = max(1, physics_ticks_per_second)
	Engine.max_fps = max(0, max_fps)
	NetLog.print_line(
		"RUNTIME_LOOP_CONFIG role=%s physics_ticks_per_second=%d max_fps=%d"
		% [role, Engine.physics_ticks_per_second, Engine.max_fps]
	)
