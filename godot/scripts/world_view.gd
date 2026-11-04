class_name WorldView
extends Node2D

## Draws the island. Static — the terrain doesn't change, so this paints once.
##
## Every tile gets a base colour plus hand-placed detail (grass tufts, tree
## canopies, bush clumps, wave lines, rock facets), because in the original you
## can read the terrain at a glance from its shapes, not just its colour.
## Detail is placed from a hash of the cell coordinates, so it's varied but
## stable — it never shimmers between redraws.

const TILE := 32

var grid: TerrainGrid

func _draw() -> void:
	for y in grid.height:
		for x in grid.width:
			_draw_tile(Vector2i(x, y))
	# A faint grid, as the original has.
	var line := Color(0, 0, 0, 0.07)
	for x in grid.width + 1:
		draw_line(Vector2(x * TILE, 0), Vector2(x * TILE, grid.height * TILE), line, 1.0)
	for y in grid.height + 1:
		draw_line(Vector2(0, y * TILE), Vector2(grid.width * TILE, y * TILE), line, 1.0)

func _draw_tile(c: Vector2i) -> void:
	var o := Vector2(c.x * TILE, c.y * TILE)
	var t := grid.tile_type(c)
	match t:
		TerrainGrid.WATER:
			_fill(o, Color(0.13, 0.34, 0.55))
			_waves(c, o)
		TerrainGrid.SAND:
			_fill(o, Color(0.85, 0.79, 0.56))
			_speckle(c, o, Color(0.75, 0.68, 0.46), 7, 1.2)
		TerrainGrid.MEADOW:
			_fill(o, Color(0.55, 0.66, 0.24))
			_grass(c, o)
		TerrainGrid.BUSH:
			_fill(o, Color(0.52, 0.62, 0.23))
			_grass(c, o)
			_bushes(c, o)
		TerrainGrid.TREES:
			# Solid woodland — you go around it, so it's drawn as a dense,
			# closed canopy rather than a couple of trees on open grass.
			_fill(o, Color(0.14, 0.27, 0.13))
			_trees(c, o)
		TerrainGrid.SWAMP:
			_fill(o, Color(0.35, 0.37, 0.23))
			_swamp(c, o)
		TerrainGrid.HILL:
			_fill(o, Color(0.52, 0.60, 0.26))
			_hill(c, o)
		TerrainGrid.FENCE:
			_fill(o, Color(0.55, 0.66, 0.24))
			_palisade(o)

## A stockade: sharpened stakes, side by side, lashed together.
func _palisade(o: Vector2) -> void:
	for i in 5:
		var x := o.x + 3.0 + i * 6.0
		draw_rect(Rect2(x, o.y + 6, 4.5, TILE - 8), Color(0.45, 0.30, 0.15))
		draw_colored_polygon(PackedVector2Array([Vector2(x, o.y + 6), Vector2(x + 4.5, o.y + 6), Vector2(x + 2.25, o.y + 1)]), Color(0.52, 0.36, 0.18))
		draw_rect(Rect2(x, o.y + 6, 4.5, TILE - 8), Color(0.18, 0.12, 0.06), false, 1.0)
	draw_line(Vector2(o.x + 1, o.y + 13), Vector2(o.x + TILE - 1, o.y + 13), Color(0.70, 0.60, 0.40), 1.5)
	draw_line(Vector2(o.x + 1, o.y + 22), Vector2(o.x + TILE - 1, o.y + 22), Color(0.70, 0.60, 0.40), 1.5)

func _fill(o: Vector2, col: Color) -> void:
	draw_rect(Rect2(o.x, o.y, TILE, TILE), col)

## Tufts of grass — short strokes leaning slightly, in two tones.
func _grass(c: Vector2i, o: Vector2) -> void:
	for i in 9:
		var p := o + Vector2(_r(c, i * 3) * TILE, _r(c, i * 3 + 1) * TILE)
		var h: float = 2.0 + _r(c, i * 3 + 2) * 2.5
		var col := Color(0.46, 0.58, 0.19) if i % 2 == 0 else Color(0.63, 0.72, 0.30)
		draw_line(p, p + Vector2(0.6, -h), col, 1.0)

func _speckle(c: Vector2i, o: Vector2, col: Color, n: int, r: float) -> void:
	for i in n:
		var p := o + Vector2(_r(c, i * 2 + 40) * TILE, _r(c, i * 2 + 41) * TILE)
		draw_circle(p, r, col)

func _waves(c: Vector2i, o: Vector2) -> void:
	for i in 3:
		var y: float = o.y + 6.0 + i * 9.0 + _r(c, i + 60) * 3.0
		var x: float = o.x + 3.0 + _r(c, i + 70) * 10.0
		draw_line(Vector2(x, y), Vector2(x + 9.0, y), Color(0.30, 0.52, 0.72, 0.75), 1.0)

## Bushes: a couple of low rounded clumps.
func _bushes(c: Vector2i, o: Vector2) -> void:
	for i in 2:
		var p := o + Vector2(7.0 + _r(c, i + 80) * 18.0, 9.0 + _r(c, i + 90) * 14.0)
		var r: float = 4.0 + _r(c, i + 100) * 2.0
		draw_circle(p, r, Color(0.20, 0.38, 0.16))
		draw_circle(p + Vector2(-1, -1.5), r * 0.6, Color(0.29, 0.49, 0.21))

## Dense woodland: overlapping canopies that fill the square, so it reads as a
## wall of trees you have to walk around.
func _trees(c: Vector2i, o: Vector2) -> void:
	for i in 4:
		var bx: float = o.x + 6.0 + (i % 2) * 13.0 + _r(c, i + 110) * 5.0
		var by: float = o.y + 8.0 + int(i / 2) * 13.0 + _r(c, i + 120) * 4.0
		draw_rect(Rect2(bx - 1.0, by + 3.0, 2.0, 5.0), Color(0.28, 0.18, 0.10)) # trunk
		var canopy := Vector2(bx, by)
		draw_circle(canopy, 7.0, Color(0.07, 0.19, 0.09))                 # deep shade
		draw_circle(canopy + Vector2(-1.0, -1.6), 5.4, Color(0.16, 0.38, 0.17))
		draw_circle(canopy + Vector2(-2.0, -2.8), 2.8, Color(0.26, 0.54, 0.23)) # lit top

## Swamp: murky blotches and a few reeds.
func _swamp(c: Vector2i, o: Vector2) -> void:
	for i in 3:
		var p := o + Vector2(_r(c, i + 130) * TILE, _r(c, i + 140) * TILE)
		draw_circle(p, 4.0 + _r(c, i + 150) * 3.0, Color(0.26, 0.30, 0.20))
	for i in 4:
		var p := o + Vector2(4.0 + _r(c, i + 160) * 24.0, 10.0 + _r(c, i + 170) * 18.0)
		draw_line(p, p + Vector2(0.8, -5.0), Color(0.44, 0.47, 0.26), 1.0)

## High ground: a grassy mound with a lit crest, a shadowed base and a couple of
## outcrops, so it reads as a HILL you can climb (and see further from) rather
## than an unexplained grey block.
func _hill(c: Vector2i, o: Vector2) -> void:
	var mid := o + Vector2(TILE * 0.5, TILE * 0.5)
	# Shadowed skirt, then the mound, then the sunlit crest.
	_ellipse(mid + Vector2(0, 5.0), 15.0, 9.0, Color(0.38, 0.45, 0.20))
	_ellipse(mid + Vector2(0, 2.0), 13.0, 8.0, Color(0.50, 0.58, 0.25))
	_ellipse(mid + Vector2(-1.5, -1.5), 8.5, 5.0, Color(0.62, 0.69, 0.33))
	_ellipse(mid + Vector2(-2.5, -3.5), 4.2, 2.4, Color(0.72, 0.77, 0.42))
	# A rock or two breaking the surface marks it as a ridge.
	for i in 2:
		var p := o + Vector2(7.0 + _r(c, i + 180) * 17.0, 9.0 + _r(c, i + 190) * 13.0)
		var w: float = 4.0 + _r(c, i + 200) * 3.0
		_ellipse(p, w, w * 0.55, Color(0.52, 0.50, 0.46))
		_ellipse(p - Vector2(0, 1.0), w * 0.6, w * 0.3, Color(0.68, 0.66, 0.62))

func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 20:
		var a := TAU * i / 20.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)

## Stable pseudo-random in 0..1 from a cell plus a salt, so detail is varied
## across the island but identical every redraw.
func _r(c: Vector2i, salt: int) -> float:
	var n: int = c.x * 374761393 + c.y * 668265263 + salt * 1013904223
	n = (n ^ (n >> 13)) * 1274126177
	return float(absi(n ^ (n >> 16)) % 10000) / 10000.0
