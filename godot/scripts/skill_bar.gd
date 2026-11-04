class_name SkillBar
extends Control

## One skill on the 0-100 scale: filled to where it stands now, a faint tick
## where this class started, a bright line at the most coaching can reach (the
## stretch beyond is shaded out), and the numbers written on it. When a skill
## goes up, the fill grows to the new value and glows for a moment.

var value := 0.0
var cap := 100.0
var start := 0.0
var _shown := -1.0
var _glow := 0.0

func _init() -> void:
	custom_minimum_size = Vector2(96, 17)

## `snap`: show the new numbers at once, without the grow-and-glow (a
## different person's skill, not this one improving).
func set_values(v: float, limit: float, began: float, snap := false) -> void:
	if snap:
		_shown = v
		_glow = 0.0
	elif _shown >= 0.0 and v > value:
		_glow = 1.0
	value = v
	cap = limit
	start = began
	if _shown < 0.0:
		_shown = v
	queue_redraw()

func _process(delta: float) -> void:
	if absf(_shown - value) > 0.01 or _glow > 0.0:
		_shown = move_toward(_shown, value, delta * 25.0)
		_glow = maxf(0.0, _glow - delta * 1.2)
		queue_redraw()

func _draw() -> void:
	var w := size.x
	var h := size.y
	var scale_x := w / CharacterStats.MAX_SKILL
	draw_rect(Rect2(0, 0, w, h), Color(0.07, 0.08, 0.10))
	draw_rect(Rect2(cap * scale_x, 0, w - cap * scale_x, h), Color(0.25, 0.25, 0.28, 0.5))
	var full := value >= cap
	var fill := Color(0.45, 0.82, 0.45) if full else Color(0.86, 0.68, 0.28)
	draw_rect(Rect2(0, 1, _shown * scale_x, h - 2), fill.lerp(Color.WHITE, _glow * 0.7))
	draw_line(Vector2(start * scale_x, 0), Vector2(start * scale_x, h), Color(0, 0, 0, 0.45), 1.0)
	draw_line(Vector2(cap * scale_x, -1), Vector2(cap * scale_x, h + 1), Color(1, 1, 1, 0.85), 1.5)
	var font := ThemeDB.fallback_font
	var text := "%d / %d" % [roundi(value), roundi(cap)]
	draw_string_outline(font, Vector2(4, h - 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color(0, 0, 0, 0.8))
	draw_string(font, Vector2(4, h - 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)
