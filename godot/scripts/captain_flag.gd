class_name CaptainFlag
extends Control

## The reward for finishing the campaign: the Golden Rooster, a gold rooster
## on a wine-red flag with a gold border. Flown by a Captain's ship in the
## game (FogView), drawn big in the ending, and as a badge on the menus.

const FIELD := Color(0.46, 0.08, 0.14)
const GOLD := Color(1.0, 0.80, 0.20)
const GOLD_DARK := Color(0.62, 0.42, 0.08)

var flag_size := Vector2(30, 20)

func _init(sz := Vector2(30, 20)) -> void:
	flag_size = sz
	custom_minimum_size = Vector2(sz.x + 6, sz.y + 10)

func _draw() -> void:
	var pole := Vector2(2, 0)
	draw_line(pole, pole + Vector2(0, flag_size.y + 10), Color(0.35, 0.25, 0.15), 2.0)
	draw(self, Rect2(pole + Vector2(1, 1), flag_size))

## The whole flag in `r`: field, gold border, rooster.
static func draw(on: CanvasItem, r: Rect2) -> void:
	on.draw_colored_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]), FIELD)
	var edge := maxf(1.0, r.size.y * 0.07)
	on.draw_rect(r.grow(-edge / 2.0), GOLD, false, edge)
	rooster(on, r.grow(-r.size.y * 0.16), GOLD)

## The flag on a waving cloth: `quad` is its four corners.
static func draw_quad(on: CanvasItem, quad: PackedVector2Array) -> void:
	on.draw_colored_polygon(quad, FIELD)
	on.draw_polyline(quad + PackedVector2Array([quad[0]]), GOLD, 2.0)
	var box := Rect2(quad[0], quad[2] - quad[0]).abs()
	rooster(on, box.grow(-box.size.y * 0.16), GOLD)

## A rooster facing right, filling `box` (kept in proportion, centred).
const BODY := [
	Vector2(0.02, 0.30), Vector2(0.05, 0.12), Vector2(0.18, 0.04), Vector2(0.30, 0.28),
	Vector2(0.45, 0.40), Vector2(0.60, 0.32), Vector2(0.64, 0.14), Vector2(0.72, 0.08),
	Vector2(0.80, 0.12), Vector2(0.90, 0.17), Vector2(0.78, 0.21), Vector2(0.74, 0.30),
	Vector2(0.84, 0.48), Vector2(0.74, 0.70), Vector2(0.48, 0.76), Vector2(0.28, 0.64),
	Vector2(0.14, 0.48),
]
const COMB := [Vector2(0.63, 0.13), Vector2(0.65, 0.0), Vector2(0.69, 0.07), Vector2(0.72, -0.01),
	Vector2(0.75, 0.07), Vector2(0.78, 0.02), Vector2(0.79, 0.12)]

static func rooster(on: CanvasItem, box: Rect2, col: Color) -> void:
	var side := minf(box.size.x, box.size.y * 1.15)
	var size := Vector2(side, side / 1.15)
	var o := box.position + (box.size - size) / 2.0
	var at := func(p: Vector2) -> Vector2: return o + Vector2(p.x * size.x, p.y * size.y)
	on.draw_colored_polygon(PackedVector2Array(COMB.map(at)), Color(0.90, 0.25, 0.20) if size.x > 14.0 else col)
	on.draw_colored_polygon(PackedVector2Array(BODY.map(at)), col)
	var w := maxf(1.0, size.x * 0.05)
	for leg in [[Vector2(0.54, 0.74), Vector2(0.51, 0.97)], [Vector2(0.63, 0.72), Vector2(0.65, 0.97)]]:
		on.draw_line(at.call(leg[0]), at.call(leg[1]), col, w)
		on.draw_line(at.call(leg[1]), at.call(leg[1] + Vector2(0.07, 0.0)), col, w)
	if size.x > 14.0:
		on.draw_circle(at.call(Vector2(0.73, 0.15)), maxf(0.8, size.x * 0.025), FIELD) # the eye
		on.draw_line(at.call(Vector2(0.20, 0.12)), at.call(Vector2(0.36, 0.44)), GOLD_DARK, w * 0.7) # tail feathers
		on.draw_line(at.call(Vector2(0.10, 0.22)), at.call(Vector2(0.30, 0.52)), GOLD_DARK, w * 0.7)
