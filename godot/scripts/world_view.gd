class_name WorldView
extends Node2D

## Draws the island. Static — the terrain doesn't change, so this paints once.
##
## Shown on screen, the island is a TileMapLayer built from a small sheet of
## squares this draws once when the island loads (a few of each kind, at twice
## the size so they stay sharp zoomed in): Godot then draws a whole patch of
## the island at a time. Drawn square by square, a big island took thousands
## of draw calls every frame, which made phones crawl. With nothing on screen
## (a server, the tests) it's drawn the old way.
##
## Every tile gets a base colour plus hand-placed detail (grass tufts, tree
## canopies, bush clumps, wave lines, rock facets), because in the original you
## can read the terrain at a glance from its shapes, not just its colour.
## Detail is placed from a hash of the cell coordinates, so it's varied but
## stable — it never shimmers between redraws.

const TILE := 32

## Painted tiles for woods, thickets, hills and swamp (assets/terrain/, drawn
## for the game with Google Gemini from a screenshot of it), a few of each so
## the map doesn't repeat. Each square picks one from its position, so it's
## always the same one. Anything without a painting is drawn by hand below.
const PAINTED := {
	TerrainGrid.TREES: ["woods_1", "woods_2", "woods_3"],
	TerrainGrid.BUSH: ["thicket_1", "thicket_2", "thicket_3", "thicket_4"],
	TerrainGrid.HILL: ["hill_1", "hill_2", "hill_3", "hill_4"],
	TerrainGrid.SWAMP: ["swamp_1", "swamp_2", "swamp_3", "swamp_4"],
}
var _paintings := {} # kind -> [Texture2D]

var grid: TerrainGrid

## How many versions of each hand-drawn kind of square go on the sheet.
const DRAWN_VARIANTS := 6
const SHEET_SCALE := 2 # the sheet's squares are drawn this many times bigger
const KINDS := [TerrainGrid.WATER, TerrainGrid.MEADOW, TerrainGrid.SAND, TerrainGrid.BUSH,
	TerrainGrid.TREES, TerrainGrid.SWAMP, TerrainGrid.HILL, TerrainGrid.FENCE]
var tiles: TileMapLayer = null ## the island on screen, once the sheet is made
var _sheet_slots: Array = [] ## a sheet painter: [kind, variant] for each square
var _sheet_painter := false

func _ready() -> void:
	# The paintings are bigger than a square, so shrink them smoothly.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for kind in PAINTED:
		var list: Array[Texture2D] = []
		for n in PAINTED[kind]:
			var path := "res://assets/terrain/%s.png" % n
			if ResourceLoader.exists(path):
				list.append(load(path))
		_paintings[kind] = list
	if not _sheet_painter and grid != null and DisplayServer.get_name() != "headless":
		_make_tiles.call_deferred()

func _draw() -> void:
	if _sheet_painter:
		_draw_sheet()
		return
	if tiles != null:
		return # the TileMapLayer shows the island
	for y in grid.height:
		for x in grid.width:
			_draw_tile(Vector2i(x, y))

	# A faint grid, as the original has.
	var line := Color(0, 0, 0, 0.07)
	for x in grid.width + 1:
		draw_line(Vector2(x * TILE, 0), Vector2(x * TILE, grid.height * TILE), line, 1.0)
	for y in grid.height + 1:
		draw_line(Vector2(0, y * TILE), Vector2(grid.width * TILE, y * TILE), line, 1.0)

# --- the sheet of squares, and the island laid out from it --------------------

## How many versions of `kind` there are on the sheet.
func _variants(kind: int) -> int:
	var paintings: Array = _paintings.get(kind, [])
	return paintings.size() if not paintings.is_empty() else (1 if kind == TerrainGrid.FENCE else DRAWN_VARIANTS)

## Which version a square of the island uses: the same pick as when it was
## drawn square by square, so the island looks the same either way.
func _variant_at(c: Vector2i, kind: int) -> int:
	var n := _variants(kind)
	if not (_paintings.get(kind, []) as Array).is_empty():
		return int(_r(c, 7) * n) % n
	return int(_r(c, 3) * n) % n

## The pretend square a sheet version is drawn as (its detail comes from it).
static func _sample_cell(kind: int, variant: int) -> Vector2i:
	return Vector2i(1000 + variant * 7, 2000 + kind * 13)

## Draws the sheet, once: a few versions of every kind of square, side by
## side, at SHEET_SCALE, into a picture; then lays the island out from it.
func _make_tiles() -> void:
	var slots: Array = []
	for kind in KINDS:
		for v in _variants(kind):
			slots.append([kind, v])
	var cols := 8
	var rows := ceili(slots.size() / float(cols))
	var side := TILE * SHEET_SCALE
	var vp := SubViewport.new()
	vp.size = Vector2i(cols * side, rows * side)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var painter := WorldView.new()
	painter._sheet_painter = true
	painter._sheet_slots = slots
	painter.grid = grid
	painter.scale = Vector2(SHEET_SCALE, SHEET_SCALE)
	vp.add_child(painter)
	add_child(vp)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image() if is_instance_valid(vp) else null
	vp.queue_free()
	if img == null or img.is_empty():
		return # couldn't draw it: carry on drawing square by square
	img.generate_mipmaps()
	var source := TileSetAtlasSource.new()
	source.texture = ImageTexture.create_from_image(img)
	source.texture_region_size = Vector2i(side, side)
	source.use_texture_padding = true # no seams when zoomed out
	var at := {}
	for i in slots.size():
		var coords := Vector2i(i % cols, int(i / cols))
		source.create_tile(coords)
		at[Vector2i(slots[i][0], slots[i][1])] = coords
	var tset := TileSet.new()
	tset.tile_size = Vector2i(side, side)
	var id := tset.add_source(source)
	var layer := TileMapLayer.new()
	layer.name = "Tiles"
	layer.tile_set = tset
	layer.scale = Vector2(1.0 / SHEET_SCALE, 1.0 / SHEET_SCALE)
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for y in grid.height:
		for x in grid.width:
			var c := Vector2i(x, y)
			var kind := grid.tile_type(c)
			layer.set_cell(c, id, at.get(Vector2i(kind, _variant_at(c, kind)), Vector2i.ZERO))
	add_child(layer)
	tiles = layer
	queue_redraw() # stop drawing square by square

## The sheet painter: each version in its slot, with the faint grid line along
## its top and left edges (as the island had).
func _draw_sheet() -> void:
	for i in _sheet_slots.size():
		var kind: int = _sheet_slots[i][0]
		var v: int = _sheet_slots[i][1]
		var o := Vector2((i % 8) * TILE, int(i / 8) * TILE)
		_paint(kind, _sample_cell(kind, v), o, v)
		var line := Color(0, 0, 0, 0.07)
		draw_line(o, o + Vector2(TILE, 0), line, 1.0)
		draw_line(o, o + Vector2(0, TILE), line, 1.0)

func _draw_tile(c: Vector2i) -> void:
	_paint(grid.tile_type(c), c, Vector2(c.x * TILE, c.y * TILE), -1)

## One square of `t` at `o`, its detail placed from `c`; `pick` chooses the
## painting (-1: from `c`, as on the island).
func _paint(t: int, c: Vector2i, o: Vector2, pick_: int) -> void:
	var paintings: Array = _paintings.get(t, [])
	if not paintings.is_empty():
		# The ground under the painting: meadow round a hill, deep shade under
		# woods and thickets (so the gaps between the trees read as shade).
		match t:
			TerrainGrid.TREES: _fill(o, Color(0.06, 0.12, 0.06))
			TerrainGrid.BUSH: _fill(o, Color(0.12, 0.22, 0.09))
			TerrainGrid.HILL:
				_fill(o, Color(0.55, 0.66, 0.24))
				_grass(c, o)
		var pick := pick_ if pick_ >= 0 else int(_r(c, 7) * paintings.size()) % paintings.size()
		draw_texture_rect(paintings[pick % paintings.size()], Rect2(o, Vector2(TILE, TILE)), false)
		return
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
			# A thicket is as solid as woodland: a tangle of bushes filling the
			# square, not a couple of clumps on open grass.
			_fill(o, Color(0.20, 0.33, 0.13))
			_bushes(c, o)
		TerrainGrid.TREES:
			# Solid woodland — you go around it, so it's drawn as a dense,
			# closed canopy rather than a couple of trees on open grass.
			_fill(o, Color(0.14, 0.27, 0.13))
			_trees(c, o)
		TerrainGrid.SWAMP:
			# Wet ground you can wade through: olive mud with pools of water.
			_fill(o, Color(0.42, 0.44, 0.27))
			_swamp(c, o)
		TerrainGrid.HILL:
			# High ground, in earth colours so it stands out from the meadow.
			_fill(o, Color(0.63, 0.58, 0.36))
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

## A thicket: low bushes packed edge to edge across the square, with a few
## thorny twigs, lighter and lower than the woods' tall canopies.
func _bushes(c: Vector2i, o: Vector2) -> void:
	for i in 6:
		var p := o + Vector2(6.0 + (i % 3) * 10.0 + _r(c, i + 80) * 3.0, 9.0 + int(i / 3) * 13.0 + _r(c, i + 90) * 3.0)
		var r: float = 5.5 + _r(c, i + 100) * 1.5
		draw_circle(p + Vector2(0.5, 1.5), r, Color(0.10, 0.19, 0.07))      # shade
		draw_circle(p, r, Color(0.28, 0.45, 0.17))
		draw_circle(p + Vector2(-1.2, -1.6), r * 0.55, Color(0.40, 0.58, 0.24)) # lit top
	for i in 4:
		var p := o + Vector2(4.0 + _r(c, i + 105) * 24.0, 5.0 + _r(c, i + 106) * 22.0)
		draw_line(p, p + Vector2(2.5, -2.0), Color(0.42, 0.30, 0.16), 1.0)  # twigs

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

## Swamp: pools of murky water in the mud, with reeds standing out of them.
## Open, but slow: it's ground, not a wall.
func _swamp(c: Vector2i, o: Vector2) -> void:
	for i in 3:
		var p := o + Vector2(6.0 + _r(c, i + 130) * 20.0, 6.0 + _r(c, i + 140) * 20.0)
		var rx: float = 4.5 + _r(c, i + 150) * 3.0
		_ellipse(p, rx, rx * 0.6, Color(0.27, 0.40, 0.38))
		_ellipse(p + Vector2(-1.0, -0.8), rx * 0.55, rx * 0.25, Color(0.45, 0.58, 0.55)) # glint
	for i in 6:
		var p := o + Vector2(3.0 + _r(c, i + 160) * 26.0, 9.0 + _r(c, i + 170) * 20.0)
		var h: float = 4.0 + _r(c, i + 175) * 3.0
		draw_line(p, p + Vector2(0.8, -h), Color(0.30, 0.34, 0.16), 1.2)
		draw_line(p + Vector2(0.8, -h), p + Vector2(0.9, -h - 1.5), Color(0.45, 0.32, 0.18), 2.0) # bulrush

## High ground: a grassy mound with a lit crest, a shadowed base and a couple of
## outcrops, so it reads as a HILL you can climb (and see further from) rather
## than an unexplained grey block.
func _hill(c: Vector2i, o: Vector2) -> void:
	var mid := o + Vector2(TILE * 0.5, TILE * 0.5)
	# Shadowed skirt, then the mound, then the sunlit crest, in earth tones,
	# with contour lines like a chart's so it reads as a rise.
	_ellipse(mid + Vector2(0, 5.0), 15.5, 9.5, Color(0.46, 0.41, 0.24))
	_ellipse(mid + Vector2(0, 2.0), 13.0, 8.0, Color(0.66, 0.60, 0.37))
	_ring(mid + Vector2(0, 2.0), 13.0, 8.0, Color(0.42, 0.36, 0.20, 0.8))
	_ellipse(mid + Vector2(-1.5, -1.5), 8.5, 5.0, Color(0.76, 0.70, 0.46))
	_ring(mid + Vector2(-1.5, -1.5), 8.5, 5.0, Color(0.48, 0.42, 0.24, 0.7))
	_ellipse(mid + Vector2(-2.5, -3.5), 4.2, 2.4, Color(0.86, 0.81, 0.58))
	# A rock or two breaking the surface marks it as a ridge.
	for i in 2:
		var p := o + Vector2(7.0 + _r(c, i + 180) * 17.0, 9.0 + _r(c, i + 190) * 13.0)
		var w: float = 4.0 + _r(c, i + 200) * 3.0
		_ellipse(p, w, w * 0.55, Color(0.52, 0.50, 0.46))
		_ellipse(p - Vector2(0, 1.0), w * 0.6, w * 0.3, Color(0.68, 0.66, 0.62))

func _ring(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 21:
		var a := TAU * i / 20.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_polyline(pts, col, 1.0)

## Woods, thickets and stockades: you can't walk through them.
func _solid(c: Vector2i) -> bool:
	if not grid.in_bounds(c):
		return false
	var t := grid.tile_type(c)
	return t == TerrainGrid.TREES or t == TerrainGrid.BUSH or t == TerrainGrid.FENCE

## A solid square stands up: its shadow falls on open ground below and to the
## right, and a dark rim runs along every side that meets open ground.
func _raise(c: Vector2i) -> void:
	var o := Vector2(c.x * TILE, c.y * TILE)
	var shade := Color(0.0, 0.0, 0.0, 0.28)
	var down := c + Vector2i(0, 1)
	if grid.in_bounds(down) and grid.is_walkable(down):
		draw_rect(Rect2(o.x + 2, o.y + TILE, TILE - 2, 5), shade)
	var right := c + Vector2i(1, 0)
	if grid.in_bounds(right) and grid.is_walkable(right):
		draw_rect(Rect2(o.x + TILE, o.y + 3, 4, TILE - 3), shade)
	var rim := Color(0.05, 0.09, 0.04, 0.9)
	for side in [[Vector2i(0, -1), Vector2(0, 0), Vector2(TILE, 0)], [Vector2i(0, 1), Vector2(0, TILE), Vector2(TILE, TILE)],
			[Vector2i(-1, 0), Vector2(0, 0), Vector2(0, TILE)], [Vector2i(1, 0), Vector2(TILE, 0), Vector2(TILE, TILE)]]:
		var n: Vector2i = c + side[0]
		if grid.in_bounds(n) and grid.is_walkable(n):
			draw_line(o + side[1], o + side[2], rim, 2.0)

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
