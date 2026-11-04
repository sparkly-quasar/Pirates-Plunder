extends Control

## The campaign's ending, drawn in the game's own style. Night turns to dawn
## over the sea while your ship sails home with the Star Chart, flying the
## Golden Rooster flag, your crew on deck. Then the credits: every sailor who
## sailed in the campaign, with what they did over it, Vega first. Last, the
## reward: you're a Captain, and your ship flies the Golden Rooster from now on, in
## single player and in every online game. Click, tap, Enter or Esc skips
## ahead; at the end the button goes back to the campaign.

const SAIL_IN := 7.0      # seconds for the ship to reach the middle
const CREDITS_AT := 8.0   # when the credits start to roll
const ROLL_SPEED := 46.0  # pixels a second

var t := 0.0
var ship_x := -260.0
var crew_figures: Array[Character] = []
var caption: Label
var credits: VBoxContainer
var finale: VBoxContainer
var credits_panel: PanelContainer
var finale_panel: PanelContainer
var _done := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	GameConfig.ending_due = false
	_build()
	AudioManager.play(AudioManifest.WIN)

func _build() -> void:
	# Sailors on deck: the crew as it stands, Vega at the bow.
	var people := _crew()
	for i in mini(people.size(), 7):
		var c := Character.new()
		c.setup(Vector2i.ZERO, people[i], Character.Team.NAVS)
		c.energy = 100.0
		c.bare = true
		c.scale = Vector2(1.6, 1.6)
		add_child(c)
		crew_figures.append(c)

	caption = Label.new()
	caption.add_theme_font_size_override("font_size", 28)
	caption.add_theme_color_override("font_color", Color(1.0, 0.92, 0.70))
	caption.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	caption.add_theme_constant_override("outline_size", 6)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.set_anchors_preset(Control.PRESET_TOP_WIDE)
	caption.offset_top = 70
	caption.modulate.a = 0.0
	add_child(caption)

	credits_panel = _panel(0.55)
	credits_panel.visible = false
	add_child(credits_panel)
	credits = VBoxContainer.new()
	credits.add_theme_constant_override("separation", 10)
	credits.custom_minimum_size = Vector2(660, 0)
	credits_panel.add_child(credits)
	_line(credits, "THE STAR CHART", 34, Color(1.0, 0.87, 0.55))
	_line(credits, "Fifteen islands. Treasure Island is yours.", 18, Color(1, 1, 1, 0.85))
	_line(credits, " ", 10, Color.WHITE)
	_line(credits, "YOUR CREW", 22, Color(1.0, 0.87, 0.55))
	for st in people:
		var who := "%s, the %s" % [st.person_name, st.class_name_]
		var r := Campaign.record(st.person_name)
		var did := "freed on Gallows Rock" if st.special == Campaign.SPECIAL_VEGA else ""
		if not r.is_empty():
			var parts: Array[String] = []
			parts.append("%d island%s" % [int(r.get("islands", 0)), "" if int(r.get("islands", 0)) == 1 else "s"])
			parts.append("%d chest%s aboard" % [int(r.get("aboard", 0)), "" if int(r.get("aboard", 0)) == 1 else "s"])
			if int(r.get("captures", 0)) > 0:
				parts.append("%d capture%s" % [int(r.get("captures", 0)), "" if int(r.get("captures", 0)) == 1 else "s"])
			did = (did + ";  " if did != "" else "") + ",  ".join(parts)
		_line(credits, who, 20, Color.WHITE)
		if did != "":
			_line(credits, did, 14, Color(1, 1, 1, 0.6))
	_line(credits, " ", 10, Color.WHITE)
	_line(credits, "Captain BlackPatch, the Corsairs and the Buccaneers", 16, Color(1, 1, 1, 0.7))
	_line(credits, "will be back. They always are.", 16, Color(1, 1, 1, 0.7))

	finale_panel = _panel(0.78)
	finale_panel.set_anchors_preset(Control.PRESET_CENTER)
	finale_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	finale_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	finale_panel.visible = false
	add_child(finale_panel)
	finale = VBoxContainer.new()
	finale.add_theme_constant_override("separation", 14)
	finale.custom_minimum_size = Vector2(620, 0)
	finale_panel.add_child(finale)
	var flag_row := CenterContainer.new()
	flag_row.add_child(CaptainFlag.new(Vector2(90, 60)))
	finale.add_child(flag_row)
	_line(finale, "CAPTAIN %s" % GameConfig.player_name().to_upper(), 40, Color(1.0, 0.85, 0.35))
	_line(finale, "Your ship flies the Golden Rooster from now on: on every island, and in every online game, for everyone to see.", 17, Color(1, 1, 1, 0.9))
	_line(finale, "Your crew keeps everything it learned. Vega sails with you.", 15, Color(1, 1, 1, 0.7))
	var back := Button.new()
	back.name = "Done"
	back.text = "Back to the Campaign"
	back.custom_minimum_size = Vector2(0, 48)
	back.add_theme_font_size_override("font_size", 20)
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/Campaign.tscn"))
	finale.add_child(back)

## Everyone in the saved crew, Vega first, then whoever did most.
func _crew() -> Array[CharacterStats]:
	var out: Array[CharacterStats] = []
	for d in GameConfig.crew:
		var st := CharacterStats.make(int(d.kind), str(d.name))
		st.apply_saved(d)
		out.append(st)
	out.sort_custom(func(a: CharacterStats, b: CharacterStats) -> bool:
		if (a.special != "") != (b.special != ""):
			return a.special != ""
		return int(Campaign.record(a.person_name).get("aboard", 0)) > int(Campaign.record(b.person_name).get("aboard", 0)))
	if out.is_empty() or out[0].special == "":
		out.push_front(Campaign.make_vega()) # started a new crew since: she's still aboard
	return out

func _process(delta: float) -> void:
	t += delta
	var view := get_viewport_rect().size
	ship_x = minf(-260.0 + (view.x * 0.5 + 260.0) * clampf(t / SAIL_IN, 0.0, 1.0), view.x * 0.5) + sin(t * 0.6) * 6.0
	var deck := _deck_y(view)
	for i in crew_figures.size():
		crew_figures[i].position = Vector2(ship_x - 70.0 + i * 24.0, deck - 8.0 + sin(t * 1.7) * 2.0)
	if not _done:
		caption.text = "The Star Chart is home." if t < 4.5 else "Vega is home."
		caption.modulate.a = clampf(minf(t - 1.0, 7.5 - t), 0.0, 1.0)
		if t >= CREDITS_AT:
			credits_panel.visible = true
			credits_panel.position = Vector2((view.x - credits_panel.size.x) / 2.0, view.y - (t - CREDITS_AT) * ROLL_SPEED)
			if credits_panel.position.y + credits_panel.size.y < view.y * 0.25:
				_finish()
	queue_redraw()

func _finish() -> void:
	_done = true
	caption.modulate.a = 0.0
	credits_panel.visible = false
	finale_panel.visible = true
	t = maxf(t, SAIL_IN)
	if not Touch.enabled:
		(finale.find_child("Done", false, false) as Button).grab_focus.call_deferred()

func _input(event: InputEvent) -> void:
	if _done:
		return
	var skip: bool = (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed) \
		or (event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE, KEY_SPACE])
	if skip:
		get_viewport().set_input_as_handled()
		_finish()

func _deck_y(view: Vector2) -> float:
	return view.y * 0.62

# --- the picture ------------------------------------------------------------

func _draw() -> void:
	var view := get_viewport_rect().size
	var dawn := clampf(t / 14.0, 0.0, 1.0)
	var horizon := view.y * 0.58
	# Sky: night blue lifting to a gold dawn at the horizon.
	var bands := 24
	for i in bands:
		var f := float(i) / bands
		var night := Color(0.04, 0.06, 0.14).lerp(Color(0.10, 0.14, 0.30), f)
		var day := Color(0.30, 0.45, 0.70).lerp(Color(1.0, 0.72, 0.42), f * f)
		draw_rect(Rect2(0, horizon * f, view.x, horizon / bands + 1.0), night.lerp(day, dawn))
	# Stars fading out.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 70:
		var p := Vector2(rng.randf() * view.x, rng.randf() * horizon * 0.8)
		draw_circle(p, rng.randf_range(0.6, 1.6), Color(1, 1, 1, (1.0 - dawn) * rng.randf_range(0.4, 0.9)))
	# The sun coming up.
	var sun := Vector2(view.x * 0.72, horizon + 40.0 - dawn * 90.0)
	draw_circle(sun, 46.0, Color(1.0, 0.85, 0.45, 0.25 * dawn))
	draw_circle(sun, 30.0, Color(1.0, 0.88, 0.55, dawn))
	# Sea.
	draw_rect(Rect2(0, horizon, view.x, view.y - horizon), Color(0.05, 0.12, 0.22).lerp(Color(0.10, 0.30, 0.45), dawn))
	for row in 9:
		var y := horizon + 12.0 + row * row * 5.0
		var col := Color(1, 1, 1, 0.05 + 0.04 * dawn)
		for k in 14:
			var x := fmod(k * 110.0 + t * (12.0 + row * 4.0) + row * 37.0, view.x + 120.0) - 60.0
			draw_line(Vector2(x, y), Vector2(x + 26.0 + row * 3.0, y), col, 1.5 + row * 0.2)
	draw_line(Vector2(0, horizon), Vector2(view.x, horizon), Color(1.0, 0.85, 0.55, 0.35 * dawn), 1.5)
	# The sun's road on the water.
	for i in 12:
		var y := horizon + 6.0 + i * 14.0
		var w := 10.0 + i * 9.0 + sin(t * 2.0 + i) * 6.0
		draw_line(Vector2(sun.x - w / 2.0, y), Vector2(sun.x + w / 2.0, y), Color(1.0, 0.85, 0.5, 0.35 * dawn), 2.0)
	_draw_ship(Vector2(ship_x, _deck_y(view)))

func _draw_ship(at: Vector2) -> void:
	var bob := sin(t * 1.7) * 2.0
	var o := at + Vector2(0, bob)
	# Sails behind the crew.
	var mast := o + Vector2(-10, 0)
	draw_line(mast, mast + Vector2(0, -190), Color(0.30, 0.20, 0.10), 6.0)
	draw_line(mast + Vector2(80, 0), mast + Vector2(80, -140), Color(0.30, 0.20, 0.10), 5.0)
	var billow := sin(t * 1.3) * 4.0
	for s in [[mast + Vector2(-60, -175), 120.0, 70.0], [mast + Vector2(-50, -95), 100.0, 80.0], [mast + Vector2(42, -128), 76.0, 90.0]]:
		var p: Vector2 = s[0]
		var w: float = s[1]
		var h: float = s[2]
		var sail := PackedVector2Array([p, p + Vector2(w, 0), p + Vector2(w + billow, h), p + Vector2(billow, h)])
		draw_colored_polygon(sail, Color(0.95, 0.92, 0.84))
		draw_polyline(sail + PackedVector2Array([p]), Color(0.35, 0.30, 0.25), 1.5)
	# The Captain's flag at the masthead.
	var flag := Rect2(mast + Vector2(3, -192), Vector2(60, 40))
	var lift := sin(t * 4.0) * 3.0
	CaptainFlag.draw_quad(self, PackedVector2Array([flag.position, flag.position + Vector2(flag.size.x, lift),
		flag.position + Vector2(flag.size.x, flag.size.y + lift), flag.position + Vector2(0, flag.size.y)]))
	# Hull, in front of the crew's feet.
	var hull := PackedVector2Array([o + Vector2(-150, 0), o + Vector2(160, 0), o + Vector2(125, 52), o + Vector2(-120, 52)])
	draw_colored_polygon(hull, Color(0.42, 0.26, 0.12))
	draw_line(o + Vector2(-150, 0), o + Vector2(160, 0), Color(0.85, 0.66, 0.25), 4.0)
	draw_line(o + Vector2(-138, 22), o + Vector2(146, 22), Color(0.30, 0.18, 0.08), 2.0)
	for i in 6:
		draw_circle(o + Vector2(-90 + i * 40, 34), 4.0, Color(0.15, 0.10, 0.06))

func _panel(alpha: float) -> PanelContainer:
	var p := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.08, alpha)
	style.border_color = Color(0.85, 0.70, 0.35, alpha)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(22)
	p.add_theme_stylebox_override("panel", style)
	return p

func _line(box: VBoxContainer, text: String, size: int, col: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("outline_size", 4)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(l)
