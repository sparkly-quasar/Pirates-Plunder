extends Control

## What a dedicated server shows in its lobby when it has a window (run without
## --headless): its log as it goes. Headless, nothing is drawn.

var log_label: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.10, 0.14)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var title := Label.new()
	title.text = "PIRATES PLUNDER SERVER  (version %s)" % GameConfig.version()
	title.position = Vector2(20, 14)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	add_child(title)
	log_label = Label.new()
	log_label.position = Vector2(20, 52)
	log_label.add_theme_font_size_override("font_size", 13)
	add_child(log_label)
	var server := get_tree().root.get_node_or_null("DedicatedServer")
	if server:
		log_label.text = "\n".join(server.recent)
		server.logged.connect(_on_logged)

func _on_logged(_line: String) -> void:
	if not is_inside_tree():
		return # on its way out: a new lobby replaces this screen as the line is logged
	var server := get_tree().root.get_node_or_null("DedicatedServer")
	if server:
		log_label.text = "\n".join(server.recent)
