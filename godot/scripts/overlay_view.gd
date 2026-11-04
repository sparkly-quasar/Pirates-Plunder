class_name OverlayView
extends Node2D

## Draws on the ground (z between terrain and characters): dug holes, the
## sword-and-hat markers where people were captured, dropped chests, the clash of a sword fight,
## and the selected person's box and marching orders. Persistent holes stay
## where you opened them; the one you're actively digging grows with progress.

const TILE := 32

var server: GameServer
## Where the viewing crew last saw opponents now out of sight: [cell, team, turn].
var ghosts: Array = []

func _process(_delta: float) -> void:
	# Animate the active hole as it opens, and keep order paths in step with
	# the characters as they march.
	if not server.duel.is_empty():
		queue_redraw() # the clash sparkles
		return
	for c in server.characters:
		if c.digging or not c.path.is_empty():
			queue_redraw()
			return

func _draw() -> void:
	for c in server.dug_cells:
		_draw_hole(c, 9.0, 6.0)
	for mark in server.captures:
		_draw_capture(mark[0], int(mark[1]))
	for cell in server.dropped:
		_draw_dropped_chest(cell)
	for g in ghosts:
		_draw_last_seen(g[0], int(g[1]))
	var v := server.viewer_team()
	for c in server.characters:
		# Only holes being dug where this side can see them.
		if c.digging and (c.team == v or server.seen[v].has(c.id)):
			_draw_hole(c.dig_cell, 3.0 + 7.0 * c.dig_progress, 2.0 + 4.0 * c.dig_progress)
	if not server.duel.is_empty():
		_draw_clash()
	if server.active:
		_draw_order_path(server.active)
		_draw_selection_box(server.active.cell)

## Breadcrumbs showing where the selected character has been ordered.
func _draw_order_path(c: Character) -> void:
	if c.path.is_empty():
		return
	var col := Color(0.98, 0.90, 0.45, 0.75)
	for i in c.path.size():
		var cell: Vector2i = c.path[i]
		var center := Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0)
		if i == c.path.size() - 1:
			# Destination flag.
			draw_line(center + Vector2(0, 8), center + Vector2(0, -10), Color(0.2, 0.15, 0.1), 2.0)
			draw_rect(Rect2(center.x, center.y - 10, 8, 6), col)
		else:
			draw_circle(center, 2.5, col)

## A white box around the selected player — the original's selection marker.
func _draw_selection_box(cell: Vector2i) -> void:
	var o := Vector2(cell.x * TILE, cell.y * TILE)
	draw_rect(Rect2(o.x + 1, o.y + 1, TILE - 2, TILE - 2), Color(0, 0, 0, 0.55), false, 3.0)
	draw_rect(Rect2(o.x + 1, o.y + 1, TILE - 2, TILE - 2), Color(1, 1, 1, 0.95), false, 1.5)

## The original's capture marker: a sword stuck in the ground wearing the
## captured person's hat — red-banded for a pirate, blue for a nav, and in their
## own crew's colours for the corsairs and buccaneers.
func _draw_capture(cell: Vector2i, team: int) -> void:
	var base := Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE - 6.0)
	draw_line(base, base + Vector2(0, -16), Color(0.85, 0.87, 0.92), 2.0)       # blade
	draw_line(base + Vector2(-4, -16), base + Vector2(4, -16), Color(0.72, 0.60, 0.28), 2.5) # guard
	draw_line(base + Vector2(0, -16), base + Vector2(0, -20), Color(0.40, 0.25, 0.12), 2.0)  # grip
	var hat := Character.hat_colour(team)
	var band := Character.flag_colour(team)
	draw_rect(Rect2(base.x - 3.0, base.y - 26.0, 6.0, 3.6), hat)
	draw_rect(Rect2(base.x - 6.0, base.y - 23.0, 12.0, 2.4), hat)
	draw_rect(Rect2(base.x - 3.0, base.y - 23.2, 6.0, 1.3), band)
	draw_line(base + Vector2(-5, 1), base + Vector2(5, 1), Color(0.30, 0.20, 0.10, 0.7), 2.0)

## Where an opponent was last seen: a faded hat in their colours inside a
## dotted ring.
func _draw_last_seen(cell: Vector2i, team: int) -> void:
	var mid := Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0)
	var ring := Character.ui_colour(team)
	ring.a = 0.55
	for i in 10:
		var a := TAU * i / 10.0
		draw_arc(mid, 11.0, a, a + TAU / 20.0, 3, ring, 1.6)
	var hat := Character.hat_colour(team)
	hat.a = 0.5
	draw_rect(Rect2(mid.x - 3.2, mid.y - 5.0, 6.4, 3.6), hat)
	draw_rect(Rect2(mid.x - 6.0, mid.y - 1.8, 12.0, 2.4), hat)

## A chest dropped by a captured carrier, lying on the ground for anyone with
## empty hands to pick up. Drawn under the fog, so it shows once your crew has
## uncovered that square.
func _draw_dropped_chest(cell: Vector2i) -> void:
	var r := Rect2(cell.x * TILE + 7.0, cell.y * TILE + 14.0, 18.0, 11.0)
	_ellipse(r.get_center() + Vector2(0, 6), 11.0, 3.0, Color(0, 0, 0, 0.3))      # shadow
	draw_rect(r, Color(0.55, 0.35, 0.12))
	draw_rect(Rect2(r.position, Vector2(r.size.x, 3.5)), Color(0.88, 0.70, 0.26))  # lid
	draw_rect(Rect2(r.get_center() - Vector2(1.5, 0), Vector2(3, 4)), Color(0.95, 0.82, 0.35)) # lock
	draw_rect(r, Color(0.12, 0.08, 0.05), false, 1.2)

## A flash where the blades meet, between the two fighters.
func _draw_clash() -> void:
	var a: Character = server.characters[int(server.duel.a)]
	var d: Character = server.characters[int(server.duel.d)]
	var mid := (Character.cell_to_pos(a.cell) + Character.cell_to_pos(d.cell)) / 2.0 + Vector2(0, -10)
	var t := Time.get_ticks_msec() / 1000.0
	var r := 4.0 + absf(sin(t * 8.0)) * 3.0
	for i in 6:
		var ang := TAU * i / 6.0 + t * 2.0
		draw_line(mid, mid + Vector2(cos(ang), sin(ang)) * r, Color(1.0, 0.92, 0.55, 0.9), 1.5)
	draw_circle(mid, 1.8, Color(1, 1, 1))

func _draw_hole(cell: Vector2i, rx: float, ry: float) -> void:
	var center := Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0 + 2.0)
	# Dirt pile behind the hole.
	draw_rect(Rect2(center.x - (TILE / 2.0 - 6), center.y + ry - 1, TILE - 12, 4), Color(0.34, 0.23, 0.13))
	_ellipse(center, rx, ry, Color(0.14, 0.09, 0.05))
	_ellipse(center - Vector2(0, 1), rx * 0.7, ry * 0.6, Color(0.22, 0.15, 0.09))

func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var a := TAU * i / 24.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)
