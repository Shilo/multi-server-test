extends Node

const CLI_ARGS := preload("res://shared/cli_args.gd")

const ROLE_SCENES := {
	"client": "res://client/ClientRoot.tscn",
	"master": "res://server/master/MasterServer.tscn",
	"chat": "res://server/chat/ChatServer.tscn",
	"world": "res://server/world/WorldServer.tscn",
	"orchestrator": "res://server/orchestrator/Orchestrator.tscn",
}

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var role: String = CLI_ARGS.get_value(args, "role", "client")

	if not ROLE_SCENES.has(role):
		push_error("Unknown --role '%s'. Expected one of: %s" % [role, str(ROLE_SCENES.keys())])
		get_tree().quit(2)
		return

	var scene := load(ROLE_SCENES[role]) as PackedScene
	var root := scene.instantiate()
	add_child(root)
	print("[LAUNCHER] role=%s scene=%s args=%s" % [role, ROLE_SCENES[role], str(args)])
