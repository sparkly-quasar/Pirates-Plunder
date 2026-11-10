class_name UiTheme
extends RefCounted

## The look of every screen off the island (the menu, setting up, coaching,
## Your Crew, the results, the campaign, the server list and the lobby): a
## captain's chart room. Deep-sea panels edged in brass, parchment-coloured
## words, gold for what matters, and a sea chart behind it all.
##
## Each of those screens calls UiTheme.dress(self) where it used to lay a flat
## colour behind itself: that sets the theme on the screen (so every button,
## box and list inside takes it) and lays the chart behind. The island keeps
## its own look.
##
## Fonts (SIL Open Font License, see assets/fonts/OFL-*.txt): Fira Sans
## for reading, IM Fell English SC for headings, Pirata One for the title.

const INK := Color(0.93, 0.87, 0.74)          ## words: parchment
const INK_DIM := Color(0.93, 0.87, 0.74, 0.55)
const GOLD := Color(1.0, 0.85, 0.52)          ## headings, hover, what matters
const BRASS := Color(0.72, 0.56, 0.31)        ## edges
const BRASS_DIM := Color(0.47, 0.38, 0.24)
const SEA_DEEP := Color(0.035, 0.07, 0.10)    ## the backdrop
const SEA := Color(0.06, 0.11, 0.15)
const PANEL := Color(0.09, 0.13, 0.17, 0.94)  ## cards and boxes
const BUTTON := Color(0.15, 0.20, 0.25)
const BUTTON_HOVER := Color(0.20, 0.26, 0.31)
const BUTTON_DOWN := Color(0.10, 0.14, 0.18)
const WELL := Color(0.04, 0.07, 0.09)         ## text boxes, bar troughs
const DARK_INK := Color(0.13, 0.08, 0.03)     ## words on gold

## Theme type variations a screen can ask for (Control.theme_type_variation):
const PRIMARY := "PrimaryButton"  ## the screen's main action, in gold
const TITLE := "TitleLabel"       ## the game's name
const HEADING := "HeadingLabel"   ## a screen's or a section's heading

static var _theme: Theme = null

## The theme, made once.
static func get_theme() -> Theme:
	if _theme == null:
		_theme = _make()
	return _theme

## Dresses a screen: the theme, and the sea chart laid behind everything.
static func dress(screen: Control) -> void:
	screen.theme = get_theme()
	var chart := ChartBackdrop.new()
	chart.name = "Backdrop"
	chart.set_anchors_preset(Control.PRESET_FULL_RECT)
	chart.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(chart)
	screen.move_child(chart, 0)

## A heading in the heading face, in gold.
static func heading(l: Label) -> Label:
	l.theme_type_variation = HEADING
	return l

## Makes `b` the screen's main action: gold, dark words.
static func primary(b: Button) -> Button:
	b.theme_type_variation = PRIMARY
	return b

# --- making it -------------------------------------------------------------

static func _make() -> Theme:
	var t := Theme.new()
	var body: Font = load("res://assets/fonts/FiraSans-Regular.ttf")
	var bold: Font = load("res://assets/fonts/FiraSans-Medium.ttf")
	var head: Font = load("res://assets/fonts/IMFellEnglishSC-Regular.ttf")
	var title: Font = load("res://assets/fonts/PirataOne-Regular.ttf")
	t.default_font = body
	t.default_font_size = 16

	# Words.
	t.set_color("font_color", "Label", INK)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.0))
	t.set_type_variation(HEADING, "Label")
	t.set_font("font", HEADING, head)
	t.set_color("font_color", HEADING, GOLD)
	t.set_color("font_shadow_color", HEADING, Color(0, 0, 0, 0.55))
	t.set_constant("shadow_offset_x", HEADING, 0)
	t.set_constant("shadow_offset_y", HEADING, 2)
	t.set_type_variation(TITLE, "Label")
	t.set_font("font", TITLE, title)
	t.set_font_size("font_size", TITLE, 76)
	t.set_color("font_color", TITLE, GOLD)
	t.set_color("font_outline_color", TITLE, Color(0.16, 0.09, 0.02))
	t.set_constant("outline_size", TITLE, 10)
	t.set_color("font_shadow_color", TITLE, Color(0, 0, 0, 0.6))
	t.set_constant("shadow_offset_x", TITLE, 0)
	t.set_constant("shadow_offset_y", TITLE, 5)

	# Buttons: a plank with a brass edge that lights up under the mouse.
	for type in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", type, _box(BUTTON, BRASS_DIM, 1, 5, 2))
		t.set_stylebox("hover", type, _box(BUTTON_HOVER, BRASS, 1, 5, 2))
		t.set_stylebox("pressed", type, _box(BUTTON_DOWN, GOLD, 1, 5, 0, 2))
		t.set_stylebox("hover_pressed", type, _box(BUTTON_DOWN, GOLD, 1, 5, 0, 2))
		t.set_stylebox("disabled", type, _box(Color(BUTTON, 0.45), Color(BRASS_DIM, 0.35), 1, 5, 0))
		t.set_stylebox("focus", type, _ring())
		t.set_color("font_color", type, INK)
		t.set_color("font_hover_color", type, GOLD)
		t.set_color("font_pressed_color", type, GOLD)
		t.set_color("font_hover_pressed_color", type, GOLD)
		t.set_color("font_focus_color", type, INK)
		t.set_color("font_disabled_color", type, Color(INK, 0.35))
		t.set_font("font", type, bold)
	# A flat button (a crew list, a small link) shows no plank until hovered.
	# Buttons set flat draw no box at all, so their colours are what's left.

	# The main action: gold.
	t.set_type_variation(PRIMARY, "Button")
	t.set_stylebox("normal", PRIMARY, _box(Color(0.80, 0.60, 0.26), Color(1.0, 0.86, 0.52), 1, 5, 3, 0, Color(0.42, 0.28, 0.08)))
	t.set_stylebox("hover", PRIMARY, _box(Color(0.90, 0.69, 0.32), Color(1.0, 0.92, 0.66), 1, 5, 3, 0, Color(0.42, 0.28, 0.08)))
	t.set_stylebox("pressed", PRIMARY, _box(Color(0.70, 0.51, 0.20), Color(1.0, 0.86, 0.52), 1, 5, 0, 3))
	t.set_stylebox("hover_pressed", PRIMARY, _box(Color(0.70, 0.51, 0.20), Color(1.0, 0.86, 0.52), 1, 5, 0, 3))
	t.set_stylebox("disabled", PRIMARY, _box(Color(0.80, 0.60, 0.26, 0.25), Color(1.0, 0.86, 0.52, 0.25), 1, 5, 0))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, PRIMARY, DARK_INK)
	t.set_color("font_disabled_color", PRIMARY, Color(INK, 0.4))

	# Toggles (the difficulty, the game length...): the chosen one in gold.
	t.set_color("font_pressed_color", "Button", GOLD)

	# Panels and cards.
	t.set_stylebox("panel", "PanelContainer", _box(PANEL, BRASS_DIM, 1, 6, 0, 0, Color(0, 0, 0, 0), 12))
	t.set_stylebox("panel", "Panel", _box(PANEL, BRASS_DIM, 1, 6, 0, 0, Color(0, 0, 0, 0), 12))
	t.set_stylebox("panel", "TooltipPanel", _box(Color(0.10, 0.08, 0.05, 0.97), BRASS, 1, 4, 0, 0, Color(0, 0, 0, 0), 8))
	t.set_color("font_color", "TooltipLabel", INK)
	t.set_font_size("font_size", "TooltipLabel", 15)

	# Text boxes: a well, edged in gold when you're typing in it.
	t.set_stylebox("normal", "LineEdit", _box(WELL, Color(BRASS_DIM, 0.8), 1, 4, 0, 0, Color(0, 0, 0, 0), 8))
	t.set_stylebox("focus", "LineEdit", _box(Color(0, 0, 0, 0), GOLD, 2, 4, 0, 0, Color(0, 0, 0, 0), 8))
	t.set_stylebox("read_only", "LineEdit", _box(Color(WELL, 0.6), Color(BRASS_DIM, 0.4), 1, 4, 0, 0, Color(0, 0, 0, 0), 8))
	t.set_color("font_color", "LineEdit", INK)
	t.set_color("font_placeholder_color", "LineEdit", Color(INK, 0.4))
	t.set_color("caret_color", "LineEdit", GOLD)
	t.set_color("selection_color", "LineEdit", Color(GOLD, 0.3))

	# Lists that scroll: a slim brass grip.
	for bar in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", bar, _box(Color(WELL, 0.6), Color(0, 0, 0, 0), 0, 4))
		t.set_stylebox("grabber", bar, _box(BRASS_DIM, Color(0, 0, 0, 0), 0, 4))
		t.set_stylebox("grabber_highlight", bar, _box(BRASS, Color(0, 0, 0, 0), 0, 4))
		t.set_stylebox("grabber_pressed", bar, _box(GOLD, Color(0, 0, 0, 0), 0, 4))

	# The volume slider.
	t.set_stylebox("slider", "HSlider", _box(WELL, BRASS_DIM, 1, 3, 0, 0, Color(0, 0, 0, 0), 3))
	t.set_stylebox("grabber_area", "HSlider", _box(BRASS, Color(0, 0, 0, 0), 0, 3, 0, 0, Color(0, 0, 0, 0), 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", _box(GOLD, Color(0, 0, 0, 0), 0, 3, 0, 0, Color(0, 0, 0, 0), 3))

	# Tabs (every crew sharing a computer gets one when coaching).
	t.set_stylebox("panel", "TabContainer", _box(PANEL, BRASS_DIM, 1, 6, 0, 0, Color(0, 0, 0, 0), 12))
	t.set_stylebox("tab_selected", "TabContainer", _box(BUTTON_HOVER, BRASS, 1, 5, 0, 0, Color(0, 0, 0, 0), 10))
	t.set_stylebox("tab_unselected", "TabContainer", _box(BUTTON_DOWN, BRASS_DIM, 1, 5, 0, 0, Color(0, 0, 0, 0), 10))
	t.set_stylebox("tab_hovered", "TabContainer", _box(BUTTON, BRASS, 1, 5, 0, 0, Color(0, 0, 0, 0), 10))
	t.set_color("font_selected_color", "TabContainer", GOLD)
	t.set_color("font_unselected_color", "TabContainer", Color(INK, 0.7))
	t.set_color("font_hovered_color", "TabContainer", INK)
	t.set_font("font", "TabContainer", bold)

	# The drop-down list (the layout setting).
	t.set_stylebox("panel", "PopupMenu", _box(Color(0.07, 0.10, 0.13, 0.98), BRASS, 1, 4, 0, 0, Color(0, 0, 0, 0), 6))
	t.set_stylebox("hover", "PopupMenu", _box(BUTTON_HOVER, Color(0, 0, 0, 0), 0, 3))
	t.set_color("font_color", "PopupMenu", INK)
	t.set_color("font_hover_color", "PopupMenu", GOLD)
	return t

## A rounded box: `fill`, a `border` of `width`, `radius` corners, a deeper
## bottom edge of `lip` (a plank's thickness; 0 for none) in `lip_colour`, and
## `sink` pushing the words down (pressed). `pad` is the room inside.
static func _box(fill: Color, border: Color, width: int, radius: int, lip := 0, sink := 0,
		lip_colour := Color(0, 0, 0, 0.45), pad := -1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.set_border_width_all(width)
	if lip > 0:
		s.border_width_bottom = width + lip
		# The lip is drawn in the border's colour: blend toward the lip shade.
		s.border_color = border
		s.shadow_color = lip_colour
		s.shadow_size = 0
		s.shadow_offset = Vector2(0, lip)
	s.set_corner_radius_all(radius)
	s.anti_aliasing = true
	if pad >= 0:
		s.set_content_margin_all(pad)
	else:
		s.content_margin_left = 12
		s.content_margin_right = 12
		s.content_margin_top = 4 + sink
		s.content_margin_bottom = 4 - mini(sink, 4)
	return s

## The keyboard's place: a gold ring round the button it's on.
static func _ring() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.draw_center = false
	s.border_color = Color(GOLD, 0.85)
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.expand_margin_left = 2
	s.expand_margin_right = 2
	s.expand_margin_top = 2
	s.expand_margin_bottom = 2
	return s
