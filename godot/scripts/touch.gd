extends Node

## Autoload. Playing on a phone or tablet: a touch screen with no mouse.
##
## In a web browser on such a device (a "coarse" pointer, in the browser's
## words), or with --touch (or ?touch=1 on the page) to try it elsewhere:
##  - The screen is laid out for a phone held sideways: a shorter design
##    height (BASE), so text and buttons come out big enough to read and tap,
##    and the width stretches to fill the phone instead of leaving black bars.
##  - Any screen taller than that scrolls (drag it with a finger).
##  - Held upright, a notice asks you to turn the phone sideways.
##  - On the island, the map is tapped, dragged and pinched, and a bar of
##    buttons stands in for the keys (Main and PlayerController ask
##    `enabled`).
##  - Typing (a name, a chat line, a server address): the text cursor is
##    thick, bright and doesn't blink, and a strip across the top of the
##    screen shows what you're typing with the cursor in it, above the
##    phone's keyboard, which tends to cover the box itself.

## The design size on a phone: the height everything is laid out in. The
## width grows with the screen (a phone held sideways is about twice as wide).
const BASE := Vector2i(880, 560)

var enabled := false

var _turn_notice: CanvasLayer = null
var _scene_id := 0
var _check_left := 0.0

func _ready() -> void:
	enabled = _wanted()
	if not enabled:
		return
	var root := get_tree().root
	root.content_scale_size = BASE
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	_build_turn_notice()
	_build_typing_strip()
	get_tree().node_added.connect(_on_node_added)
	root.size_changed.connect(_on_resized)
	_on_resized()

## The layout chosen in Settings: "auto", "phone" or "computer". Kept in
## the same settings file as the volume. --touch and ?touch= win over it.
const SETTINGS_PATH := "user://settings.cfg"

static func layout_setting() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return "auto"
	var v := str(cfg.get_value("display", "layout", "auto"))
	return v if v in ["auto", "phone", "computer"] else "auto"

## Takes effect the next time the game starts (a page reload in a browser).
static func set_layout_setting(value: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("display", "layout", value)
	cfg.save(SETTINGS_PATH)

func _wanted() -> bool:
	var args := OS.get_cmdline_user_args()
	if args.has("--touch"):
		return true
	var href := ""
	if OS.has_feature("web"):
		href = str(JavaScriptBridge.eval("window.location.href", true))
		if href.contains("touch=1"):
			return true
		if href.contains("touch=0"):
			return false
	match layout_setting():
		"phone": return true
		"computer": return false
	if not OS.has_feature("web"):
		return false
	return bool(JavaScriptBridge.eval("window.matchMedia('(pointer: coarse)').matches", true))

## The screen's size in its own pixels (not the design's).
func _screen() -> Vector2:
	return Vector2(get_tree().root.size)

func upright() -> bool:
	var s := _screen()
	return s.y > s.x * 1.05

func _on_resized() -> void:
	if _turn_notice != null:
		_turn_notice.visible = upright()

func _build_turn_notice() -> void:
	_turn_notice = CanvasLayer.new()
	_turn_notice.layer = 110
	var dim := ColorRect.new()
	dim.color = Color(0.07, 0.10, 0.14)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_turn_notice.add_child(dim)
	var label := Label.new()
	label.text = "Turn your phone sideways to play."
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 64)
	label.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	dim.add_child(label)
	_turn_notice.visible = false
	add_child(_turn_notice)

# --- words ---------------------------------------------------------------------

## The game's words for a mouse and keyboard, said for a touch screen. The
## game's messages are written once (a server writes them for everyone), and
## each screen says them its own way.
const WORDS := [
	["Click a destination, SPACE to dig, ENTER to end the turn.", "Tap where to go. Dig to dig, End Turn when you're done."],
	["Click Continue (or press ENTER) for the results.", "Tap Continue for the results."],
	["Open the menu (Esc) to resume.", "Open the Menu to resume."],
	[" Press M for the menu.", " Open the Menu to leave."],
	["click a team-mate beside them", "tap a team-mate beside them"],
	["then click where to go", "then tap where to go"],
	["Click one of your", "Tap one of your"],
	["Click when you're ready.", "Tap when you're ready."],
]

func words(text: String) -> String:
	if not enabled:
		return text
	for pair in WORDS:
		text = text.replace(pair[0], pair[1])
	return text

# --- screens taller than a phone: they scroll ----------------------------------

## Every so often (and soon after a new screen opens), any part of the screen
## that runs off the top or bottom is put in a scrolling box. Screens add to
## themselves as you use them (the server list's start panel), so it looks again.
func _process(delta: float) -> void:
	if not enabled:
		return
	_update_typing_strip()
	var scene := get_tree().current_scene
	if scene == null:
		return
	if scene.get_instance_id() != _scene_id:
		_scene_id = scene.get_instance_id()
		_check_left = 0.1 # once it has laid itself out
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = 0.5
	if scene is Control:
		fit(scene as Control)

## Puts whatever runs off `screen` in a box that scrolls.
func fit(screen: Control) -> void:
	var view := screen.get_viewport_rect().size
	for child in screen.get_children():
		if not child is Container or child is ScrollContainer or not (child as Control).visible:
			continue
		var c := child as Container
		var r := c.get_global_rect()
		if r.position.y >= -1.0 and r.end.y <= view.y + 1.0:
			continue
		var scroll := ScrollContainer.new()
		scroll.name = "TouchScroll"
		scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var pad := MarginContainer.new()
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for side in ["top", "bottom"]:
			pad.add_theme_constant_override("margin_" + side, 16)
		var at := c.get_index()
		screen.remove_child(c)
		c.set_anchors_preset(Control.PRESET_TOP_LEFT)
		c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		pad.add_child(c)
		scroll.add_child(pad)
		screen.add_child(scroll)
		screen.move_child(scroll, at)

# --- typing ---------------------------------------------------------------------

## The text cursor a phone can see: thick, gold, steady.
const CARET_COLOR := Color(1.0, 0.82, 0.3)
const CARET_WIDTH := 3

var _typing: CanvasLayer = null
var _typing_label: Label = null
var _typing_field: LineEdit = null

## Every text box, as it's made, gets the cursor a phone can see.
func _on_node_added(n: Node) -> void:
	if n is LineEdit or n is TextEdit:
		show_caret(n as Control)

static func show_caret(box: Control) -> void:
	box.set("caret_blink", false)
	box.add_theme_constant_override("caret_width", CARET_WIDTH)
	box.add_theme_color_override("caret_color", CARET_COLOR)
	box.add_theme_color_override("selection_color", Color(1.0, 0.82, 0.3, 0.35))

func _build_typing_strip() -> void:
	_typing = CanvasLayer.new()
	_typing.name = "TypingStrip"
	_typing.layer = 105
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.12, 0.96)
	style.border_color = CARET_COLOR
	style.border_width_bottom = 2
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	_typing_label = Label.new()
	_typing_label.name = "Text"
	_typing_label.add_theme_font_size_override("font_size", 26)
	_typing_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_typing_label.clip_text = true
	panel.add_child(_typing_label)
	_typing.add_child(panel)
	_typing.visible = false
	add_child(_typing)

## Shows the strip while a one-line text box has the focus, with what's in it
## and a bar where the cursor is (dots for a hidden word).
func _update_typing_strip() -> void:
	if _typing == null:
		return
	var focus := get_viewport().gui_get_focus_owner()
	var field: LineEdit = null
	if focus is LineEdit and (focus as LineEdit).editable and focus.is_visible_in_tree():
		field = focus as LineEdit
	_typing_field = field
	_typing.visible = field != null
	if field == null:
		return
	_typing_label.text = typing_text(field)
	_typing_label.modulate = Color(1, 1, 1, 1.0 if field.text != "" else 0.6)

## What the strip says for `field`: its text with "|" at the cursor, or its
## placeholder while it's empty.
static func typing_text(field: LineEdit) -> String:
	var words := field.text
	if field.secret:
		words = field.secret_character.repeat(words.length())
	if words == "":
		return "|  " + field.placeholder_text
	var at := clampi(field.caret_column, 0, words.length())
	return words.left(at) + "|" + words.substr(at)
