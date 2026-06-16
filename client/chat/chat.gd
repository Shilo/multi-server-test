extends PanelContainer

signal message_submitted(message: String)

@onready var output: RichTextLabel = $VBox/Output
@onready var input: LineEdit = $VBox/Input

func _ready() -> void:
	input.text_submitted.connect(_on_text_submitted)
	set_connected(false)


func set_connected(connected: bool) -> void:
	input.editable = connected
	input.placeholder_text = "chat" if connected else "chat unavailable"


func add_system_line(message: String) -> void:
	_append_line("[color=gray]%s[/color]" % _escape_bbcode(message))


func add_chat_line(sender_name: String, message: String) -> void:
	_append_line("[b]%s:[/b] %s" % [_escape_bbcode(sender_name), _escape_bbcode(message)])


func _append_line(message: String) -> void:
	output.append_text("%s\n" % message)
	output.scroll_to_line(output.get_line_count())


func _escape_bbcode(message: String) -> String:
	return message.replace("[", "[lb]")


func _on_text_submitted(message: String) -> void:
	var trimmed := message.strip_edges()
	if trimmed.is_empty():
		return

	input.clear()
	message_submitted.emit(trimmed)
