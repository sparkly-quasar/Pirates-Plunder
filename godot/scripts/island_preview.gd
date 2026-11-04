class_name IslandPreview
extends Control

## A small map of the island for the setup screen, so you can look at what
## you're about to play and roll for another one if you don't like it.

## The preview's box; each island's squares are scaled to fit it, so a long
## game's big island shows smaller squares than a short game's. Drawn as a
## little chart rather than squares of colour: rounded coasts with shallows,
## trees, hills and swamp as symbols on the meadow, bold X's, each crew's
## ship as a boat (yours marked), and a key underneath saying what each kind
## of ground does in play.
const BOX := Vector2(430, 300)
const KEY_HEIGHT := 62.0

var grid: TerrainGrid
var PX := 7.0
## Whose ship to mark "you" (-1: nobody's, as for someone watching).
var home_team := 0
var box := BOX

func _init(size := BOX) -> void:
	box = size
	custom_minimum_size = Vector2(box.x, box.y + KEY_HEIGHT)

func show_island(g: TerrainGrid, home := 0) -> void:
	grid = g
	home_team = home
	PX = minf(box.x / g.width, box.y / g.height)
	queue_redraw()

func _land(c: Vector2i) -> bool:
	return grid.in_bounds(c) and grid.tile_type(c) != TerrainGrid.WATER

func _mid(c: Vector2i) -> Vector2:
	return Vector2(c.x * PX + PX * 0.5, c.y * PX + PX * 0.5)

func _draw() -> void:
	if grid == null:
		return
	var w := grid.width * PX
	var h := grid.height * PX
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), colour(TerrainGrid.WATER))
	# Shallows, then a sandy coast drawn round, so the outline isn't steps.
	for y in grid.height:
		for x in grid.width:
			if _land(Vector2i(x, y)):
				draw_circle(_mid(Vector2i(x, y)), PX * 1.15, Color(0.22, 0.47, 0.66), true, -1.0, true)
	for y in grid.height:
		for x in grid.width:
			if _land(Vector2i(x, y)):
				draw_circle(_mid(Vector2i(x, y)), PX * 0.76, colour(TerrainGrid.SAND), true, -1.0, true)
	# The ground: whole squares inside, round ones at the edges.
	for y in grid.height:
		for x in grid.width:
			var c := Vector2i(x, y)
			var t := grid.tile_type(c)
			if t == TerrainGrid.WATER or t == TerrainGrid.SAND:
				continue
			var ground := colour(TerrainGrid.MEADOW) if t != TerrainGrid.SWAMP else colour(TerrainGrid.SWAMP)
			var inside := true
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + d
				if not _land(n) or grid.tile_type(n) == TerrainGrid.SAND:
					inside = false
			if inside:
				draw_rect(Rect2(x * PX - 0.5, y * PX - 0.5, PX + 1.0, PX + 1.0), ground)
			else:
				draw_circle(_mid(c), PX * 0.66, ground, true, -1.0, true)
	# What's on the ground.
	for y in grid.height:
		for x in grid.width:
			var c := Vector2i(x, y)
			var m := _mid(c)
			match grid.tile_type(c):
				TerrainGrid.TREES:
					draw_circle(m + Vector2(-PX * 0.18, PX * 0.1), PX * 0.42, Color(0.10, 0.25, 0.11), true, -1.0, true)
					draw_circle(m + Vector2(PX * 0.2, -PX * 0.12), PX * 0.38, Color(0.13, 0.31, 0.14), true, -1.0, true)
				TerrainGrid.BUSH:
					draw_circle(m, PX * 0.32, Color(0.25, 0.42, 0.17), true, -1.0, true)
				TerrainGrid.HILL:
					var hump := PackedVector2Array([m + Vector2(-PX * 0.45, PX * 0.3), m + Vector2(0, -PX * 0.35), m + Vector2(PX * 0.45, PX * 0.3)])
					draw_colored_polygon(hump, Color(0.66, 0.60, 0.36))
					draw_polyline(hump, Color(0.40, 0.33, 0.18), maxf(1.0, PX * 0.12), true)
				TerrainGrid.SWAMP:
					if PX >= 5.0:
						draw_line(m + Vector2(-PX * 0.3, 0), m + Vector2(PX * 0.3, 0), Color(0.55, 0.62, 0.55, 0.8), 1.0, true)
	# Markers need a dark halo to stay legible against the greens.
	for mk in grid.markers:
		var mid := _mid(mk)
		var r := maxf(PX * 0.9, 4.0)
		for pass_ in [[Color(1, 1, 1, 0.85), 5.5], [Color(0.85, 0.10, 0.10), 3.0]]:
			draw_line(mid + Vector2(-r, -r), mid + Vector2(r, r), pass_[0], pass_[1], true)
			draw_line(mid + Vector2(r, -r), mid + Vector2(-r, r), pass_[0], pass_[1], true)
	for t in grid.ships.size():
		_ship(grid.ships[t], t)
	draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.45), false, 2.0)
	_draw_key(h + 8.0)

## A little boat in the crew's colour; yours gets "You" beside it.
func _ship(cell: Vector2i, team: int) -> void:
	var mid := _mid(cell)
	var s := maxf(PX, 6.0)
	var hull := PackedVector2Array([mid + Vector2(-s, 0), mid + Vector2(s, 0), mid + Vector2(s * 0.65, s * 0.55), mid + Vector2(-s * 0.65, s * 0.55)])
	draw_colored_polygon(hull, Color(0.35, 0.22, 0.10))
	draw_line(mid, mid + Vector2(0, -s * 1.3), Color(0.15, 0.10, 0.05), 1.5, true)
	draw_colored_polygon(PackedVector2Array([mid + Vector2(0, -s * 1.3), mid + Vector2(s * 0.9, -s * 0.95), mid + Vector2(0, -s * 0.55)]),
		Character.flag_colour(team) if team != Character.Team.PIRATES else Color(0.12, 0.10, 0.10))
	if team == home_team:
		var font := ThemeDB.fallback_font
		var at := mid + Vector2(s * 1.2, -s * 0.4)
		at.x = minf(at.x, box.x - 30.0)
		draw_string_outline(font, at, "You", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0, 0, 0, 0.85))
		draw_string(font, at, "You", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.9, 0.55))

## What each kind of ground means in play.
func _draw_key(y: float) -> void:
	var font := ThemeDB.fallback_font
	var items := [
		[colour(TerrainGrid.MEADOW), "Meadow: quick; chests are buried here"],
		[Color(0.12, 0.28, 0.12), "Woods: no way through, blocks sight"],
		[Color(0.66, 0.60, 0.36), "Hills: slow; see further from them"],
		[colour(TerrainGrid.SWAMP), "Swamp: slowest, blocks sight"],
		[colour(TerrainGrid.SAND), "Sand: slow"],
	]
	var x := 0.0
	var row := 0
	for it in items:
		var text: String = it[1]
		var wide := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 22.0
		if x + wide > box.x and x > 0.0:
			x = 0.0
			row += 1
		var top := y + row * 16.0
		draw_rect(Rect2(x, top, 10, 10), it[0])
		draw_rect(Rect2(x, top, 10, 10), Color(0, 0, 0, 0.5), false, 1.0)
		draw_string(font, Vector2(x + 14, top + 9), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.75))
		x += wide

func _colour_water() -> Color:
	return colour(TerrainGrid.WATER)

static func colour(t: int) -> Color:
	match t:
		TerrainGrid.WATER: return Color(0.13, 0.34, 0.55)
		TerrainGrid.SAND: return Color(0.85, 0.79, 0.56)
		TerrainGrid.MEADOW: return Color(0.55, 0.66, 0.24)
		TerrainGrid.BUSH: return Color(0.42, 0.56, 0.22)
		TerrainGrid.TREES: return Color(0.13, 0.26, 0.13) # solid woodland
		TerrainGrid.SWAMP: return Color(0.35, 0.37, 0.23)
		TerrainGrid.HILL: return Color(0.62, 0.69, 0.33) # high ground
		TerrainGrid.FENCE: return Color(0.45, 0.30, 0.15) # a stockade
	return Color.MAGENTA

## A short human description, so the numbers mean something at a glance.
static func describe(g: TerrainGrid) -> String:
	var land := 0
	var wood := 0
	var open := 0
	var rough := 0
	for y in g.height:
		for x in g.width:
			var t: int = g.cells[y][x]
			if t == TerrainGrid.WATER:
				continue
			land += 1
			if t == TerrainGrid.TREES or t == TerrainGrid.BUSH:
				wood += 1
			elif t == TerrainGrid.MEADOW or t == TerrainGrid.SAND:
				open += 1
			elif t == TerrainGrid.SWAMP or t == TerrainGrid.HILL:
				rough += 1
	# The size word follows the game length, which is what sets the island's size.
	var size: String = ["Small", "Medium", "Large"][g.length]
	if g.teams > 2:
		size = ["Wide", "Broad", "Vast"][g.length]
	var character := "open ground"
	if wood > land * 0.42:
		character = "heavily wooded"
	elif rough > land * 0.25:
		character = "rough going"
	elif wood > land * 0.25:
		character = "patchy woods"
	return "%s island · %s · %d squares of land · %d chests · %d ships" % [size, character, land, g.markers.size(), g.ships.size()]
