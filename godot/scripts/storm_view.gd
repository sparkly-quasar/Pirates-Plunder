class_name StormView
extends Control

## Rain over a storm island (a campaign island with "storm"): streaks falling
## slantwise across the screen and the light a little dimmer, so it's plain
## from the first look that this island is different. Drawn in screen space
## under the HUD; it never catches a click.

const DROPS := 140
var _drops: Array = []   # [x, y, length, speed] in 0..1 screen units
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rng.seed = 11
	for i in DROPS:
		_drops.append([_rng.randf(), _rng.randf(), _rng.randf_range(0.02, 0.05), _rng.randf_range(0.8, 1.4)])

func _process(delta: float) -> void:
	for d in _drops:
		d[1] += delta * 0.9 * float(d[3])
		d[0] += delta * 0.25 * float(d[3])
		if float(d[1]) > 1.05:
			d[1] = -0.05
			d[0] = _rng.randf() - 0.2
		if float(d[0]) > 1.05:
			d[0] -= 1.1
	queue_redraw()

func _draw() -> void:
	var view := size
	draw_rect(Rect2(Vector2.ZERO, view), Color(0.05, 0.08, 0.16, 0.22)) # the light under storm clouds
	var col := Color(0.78, 0.86, 1.0, 0.35)
	for d in _drops:
		var a := Vector2(float(d[0]) * view.x, float(d[1]) * view.y)
		var l := float(d[2]) * view.y
		draw_line(a, a + Vector2(l * 0.28, l), col, 1.2)
