class_name ChartBackdrop
extends Control

## Behind every screen off the island (see UiTheme): a sea chart by
## lamplight. Deep water, faint lines of latitude and longitude, a compass
## rose in the corner, rhumb lines running out from it, and the edges in
## shadow. All drawn here, so it's sharp at any size and costs no pictures.

const GRID := 72.0   ## design pixels between chart lines

static var _glow_tex: GradientTexture2D = null
static var _shade_tex: GradientTexture2D = null

func _ready() -> void:
	resized.connect(queue_redraw)

## The lamplight: a soft radial gradient, made once and shared.
static func _glow() -> GradientTexture2D:
	if _glow_tex == null:
		_glow_tex = _radial(Vector2(0.42, 0.36), 0.95,
			[0.0, 0.5, 1.0], [Color(0.09, 0.16, 0.21, 0.95), Color(0.06, 0.11, 0.15, 0.6), Color(0.06, 0.11, 0.15, 0.0)])
	return _glow_tex

## The shadow at the edges.
static func _shade() -> GradientTexture2D:
	if _shade_tex == null:
		_shade_tex = _radial(Vector2(0.5, 0.5), 0.78,
			[0.0, 0.62, 1.0], [Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.12), Color(0, 0, 0, 0.6)])
	return _shade_tex

static func _radial(centre: Vector2, reach: float, offsets: Array, colours: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colours)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = centre
	t.fill_to = centre + Vector2(reach, 0)
	t.width = 256
	t.height = 256
	return t

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	# The water: lighter where the lamp is (up and to the left of the middle),
	# falling away to shadow at the edges. One smooth gradient, no banding.
	draw_rect(Rect2(Vector2.ZERO, size), UiTheme.SEA_DEEP)
	draw_texture_rect(_glow(), Rect2(Vector2.ZERO, size), false)

	# Chart lines, faint, and a slightly stronger one every fourth.
	var line := Color(UiTheme.BRASS, 0.05)
	var strong := Color(UiTheme.BRASS, 0.09)
	var n := 0
	var x := fmod(w * 0.5, GRID)
	while x < w:
		draw_line(Vector2(x, 0), Vector2(x, h), strong if n % 4 == 0 else line, 1.0)
		x += GRID
		n += 1
	n = 0
	var y := fmod(h * 0.5, GRID)
	while y < h:
		draw_line(Vector2(0, y), Vector2(w, y), strong if n % 4 == 0 else line, 1.0)
		y += GRID
		n += 1

	# A compass rose low on the right, with rhumb lines running out from it.
	var rose_at := Vector2(w * 0.86, h * 0.80)
	var r := minf(w, h) * 0.17
	for i in 16:
		var a := TAU * float(i) / 16.0
		draw_line(rose_at, rose_at + Vector2.from_angle(a) * maxf(w, h) * 1.3, Color(UiTheme.BRASS, 0.035), 1.0)
	_rose(rose_at, r)

	# The edges in shadow.
	draw_texture_rect(_shade(), Rect2(Vector2.ZERO, size), false)

## A compass rose: rings, eight long points and eight short, N in gold.
func _rose(c: Vector2, r: float) -> void:
	var ink := Color(UiTheme.BRASS, 0.12)
	var faint := Color(UiTheme.BRASS, 0.08)
	draw_arc(c, r * 1.02, 0, TAU, 96, ink, 1.5, true)
	draw_arc(c, r * 0.94, 0, TAU, 96, faint, 1.0, true)
	draw_arc(c, r * 0.30, 0, TAU, 64, faint, 1.0, true)
	# Ticks round the ring.
	for i in 64:
		var a := TAU * float(i) / 64.0
		var long := 0.08 if i % 4 == 0 else 0.04
		draw_line(c + Vector2.from_angle(a) * r * 0.94, c + Vector2.from_angle(a) * r * (0.94 - long), faint, 1.0)
	# The points: a light half and a dark half each, so they read as raised.
	for i in 16:
		var a := TAU * float(i) / 16.0 - PI / 2.0
		var long := i % 2 == 0
		var reach := r * (0.92 if i % 4 == 0 else (0.66 if long else 0.42))
		var half := r * (0.10 if long else 0.06)
		var tip := c + Vector2.from_angle(a) * reach
		var side := Vector2.from_angle(a + PI / 2.0) * half
		var light := Color(UiTheme.BRASS, 0.14 if i % 4 == 0 else 0.08)
		var dark := Color(UiTheme.BRASS, 0.06 if i % 4 == 0 else 0.035)
		if i == 0:
			light = Color(UiTheme.GOLD, 0.22) # north
			dark = Color(UiTheme.GOLD, 0.10)
		draw_colored_polygon(PackedVector2Array([c, tip, c + side]), light)
		draw_colored_polygon(PackedVector2Array([c, tip, c - side]), dark)
	draw_circle(c, r * 0.04, Color(UiTheme.GOLD, 0.18))
