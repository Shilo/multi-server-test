class_name NetConfig

const HOST := "127.0.0.1"
const MASTER_PORT := 19080
const CHAT_PORT := 19081
const WORLD_PORTS := {
	1: 19082,
	2: 19083,
	3: 19084,
}

static func master_url() -> String:
	return "ws://%s:%d" % [HOST, MASTER_PORT]


static func chat_url() -> String:
	return "ws://%s:%d" % [HOST, CHAT_PORT]


static func world_url(world_id: int) -> String:
	return "ws://%s:%d" % [HOST, WORLD_PORTS[world_id]]


static func world_scene_path(world_id: int) -> String:
	return "res://client/world/world_%d.tscn" % world_id


static func allowed_targets(world_id: int) -> Array:
	match world_id:
		1:
			return [2, 3]
		2:
			return [1]
		3:
			return [1]
	return []


static func world_endpoint(world_id: int) -> Dictionary:
	return {
		"id": world_id,
		"name": "World %d" % world_id,
		"url": world_url(world_id),
		"port": WORLD_PORTS[world_id],
		"scene": world_scene_path(world_id),
	}


static func routes() -> Dictionary:
	return {
		"chat": {
			"url": chat_url(),
			"port": CHAT_PORT,
		},
		"worlds": {
			1: world_endpoint(1),
			2: world_endpoint(2),
			3: world_endpoint(3),
		},
		"initial_world": 1,
	}
