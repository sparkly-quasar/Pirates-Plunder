class_name ChatBox
extends VBoxContainer

## Chat in an online game, in the lobby and between games: a line to
## everyone, or in 2v2 to your side only. Lines travel through Net (the host
## or server passes them on, only to your side when you ask), and the last
## few stay on screen. In a game, T starts typing; ENTER sends, ESC stops.

## How many recent lines to show.
var lines := 7

var _log: RichTextLabel
var _edit: LineEdit
var _to_side: Button

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 4)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.fit_content = true
	_log.scroll_active = false
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.custom_minimum_size = Vector2(440, 0)
	_log.add_theme_font_size_override("normal_font_size", 14)
	_log.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_log.add_theme_constant_override("outline_size", 4)
	add_child(_log)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_to_side = Button.new()
	_to_side.toggle_mode = true
	_to_side.focus_mode = Control.FOCUS_NONE
	_to_side.custom_minimum_size = Vector2(130, 30)
	_to_side.toggled.connect(func(on: bool) -> void: _to_side.text = "To: your side" if on else "To: everyone")
	_to_side.text = "To: everyone"
	_to_side.tooltip_text = "2 v 2: send to everyone, or only to your side."
	_to_side.visible = GameConfig.two_v_two()
	row.add_child(_to_side)
	_edit = LineEdit.new()
	_edit.placeholder_text = "Say something..."
	_edit.max_length = Net.CHAT_MAX
	_edit.custom_minimum_size = Vector2(300, 30)
	_edit.text_submitted.connect(_send)
	_edit.gui_input.connect(_on_edit_input)
	row.add_child(_edit)
	add_child(row)
	Net.chat_received.connect(_on_chat)
	_refresh()

## Start typing (T in the game).
func open() -> void:
	_edit.grab_focus()

func is_typing() -> bool:
	return _edit != null and _edit.has_focus()

func _send(text: String) -> void:
	if text.strip_edges() != "":
		Net.say(text, _to_side.visible and _to_side.button_pressed)
	_edit.clear()
	_edit.release_focus() # so ENTER ends the turn again

func _on_edit_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_edit.release_focus()
		_edit.accept_event()

## A method, not a lambda, so Godot disconnects it from the autoload when this
## box goes.
func _on_chat(_msg: Dictionary) -> void:
	_refresh()

func _refresh() -> void:
	var out: Array[String] = []
	for msg in Net.chat_log.slice(-lines):
		var team := int(msg.team)
		out.append("[color=#%s]%s[/color]%s: %s" % [Character.ui_colour(team).to_html(false), msg.name,
			" [color=#c8c8c8](to your side)[/color]" if bool(msg.side) else "", msg.text])
	_log.text = "\n".join(out)
