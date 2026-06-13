extends PanelContainer
## Bottom-right login widget. Guests can keep playing without ever opening it;
## entering a name resumes (or starts) that account. See client.gd for wiring.

signal login_submitted(username: String)
signal logout_requested()

var _is_guest := true

@onready var identity_label: Label = $VBox/IdentityLabel
@onready var login_button: Button = $VBox/LoginButton
@onready var form: VBoxContainer = $VBox/Form
@onready var name_input: LineEdit = $VBox/Form/NameInput
@onready var submit_button: Button = $VBox/Form/Buttons/SubmitButton
@onready var cancel_button: Button = $VBox/Form/Buttons/CancelButton
@onready var error_label: Label = $VBox/Form/ErrorLabel


func _ready() -> void:
	login_button.pressed.connect(_on_login_button_pressed)
	submit_button.pressed.connect(_submit)
	cancel_button.pressed.connect(_hide_form)
	name_input.text_submitted.connect(func(_text: String) -> void: _submit())
	form.visible = false


func set_identity(display_name: String, is_guest: bool) -> void:
	_is_guest = is_guest
	identity_label.text = ("Guest: %s" if is_guest else "Logged in: %s") % display_name
	login_button.text = "Log In" if is_guest else "Log Out"
	_hide_form()


func show_error(reason: String) -> void:
	error_label.text = reason


func _on_login_button_pressed() -> void:
	if _is_guest:
		form.visible = not form.visible
		if form.visible:
			name_input.grab_focus()
	else:
		logout_requested.emit()


func _submit() -> void:
	var username := name_input.text.strip_edges()
	if username.is_empty():
		return
	error_label.text = ""
	login_submitted.emit(username)


func _hide_form() -> void:
	form.visible = false
	name_input.clear()
	error_label.text = ""
