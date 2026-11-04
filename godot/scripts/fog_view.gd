class_name FogView
extends Node2D

## Two jobs, drawn in one pass so layering is automatic:
##   1. Black out every tile the viewing team hasn't seen yet (fog of war —
##      each side has its own).
##   2. Draw the always-visible markers ON TOP of the fog — the red "X" hints
##      and every crew's ship — as the original game shows them from the start.
## Sits above the characters (z=20) so unexplored areas hide them; the player's
## own tile is always revealed, so the character shows through.

const TILE := 32

var grid: TerrainGrid
var server: GameServer

func _draw() -> void:
	# 1. Fog.
	var revealed: Dictionary = server.revealed[server.viewer_team()]
	for y in grid.height:
		for x in grid.width:
			if not revealed.has(Vector2i(x, y)):
				draw_rect(Rect2(x * TILE, y * TILE, TILE, TILE), Color(0.03, 0.03, 0.06))
	# 2. Markers on top.
	for m in server.x_markers:
		_draw_x(m, m == server.chart_marker)
	for t in server.ships.size():
		_draw_ship(server.ships[t], t)
	if server.outpost.x >= 0:
		_draw_outpost(server.outpost)
	# Where she's held is only marked once your crew has seen the spot.
	if server.goal == "rescue" and server._held_captive() != null and server.revealed[server.viewer_team()].has(server._held_captive().cell):
		_draw_captive_marker(server._held_captive().cell)

## The NAVS' outpost, shown from the start (it's theirs): a tent with a blue
## pennant, on a faint ring marking the squares where resting counts double.
func _draw_outpost(cell: Vector2i) -> void:
	var o := Vector2(cell.x * TILE, cell.y * TILE)
	draw_rect(Rect2(o - Vector2(TILE, TILE), Vector2(TILE * 3, TILE * 3)), Color(0.55, 0.75, 1.0, 0.85), false, 2.0)
	var tent := PackedVector2Array([o + Vector2(4, TILE - 5), o + Vector2(TILE / 2.0, 7), o + Vector2(TILE - 4, TILE - 5)])
	draw_colored_polygon(tent, Color(0.90, 0.86, 0.72))
	draw_polyline(tent + PackedVector2Array([tent[0]]), Color(0.30, 0.22, 0.12), 1.5)
	draw_line(o + Vector2(TILE / 2.0, 7), o + Vector2(TILE / 2.0, 0), Color(0.25, 0.18, 0.10), 1.5)
	draw_rect(Rect2(o.x + TILE / 2.0, o.y, 8, 5), Character.flag_colour(Character.Team.NAVS))

## Where the campaign's captive is held, shown over the fog so you know
## where to go: a blue hat in a ring of rope.
func _draw_captive_marker(cell: Vector2i) -> void:
	var mid := Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0)
	draw_arc(mid, 13.0, 0.0, TAU, 24, Color(0.95, 0.82, 0.50), 2.5)
	var hat := Character.hat_colour(Character.Team.NAVS)
	draw_rect(Rect2(mid.x - 4, mid.y - 6, 8, 5), hat)
	draw_rect(Rect2(mid.x - 8, mid.y - 2, 16, 3), hat)
	draw_rect(Rect2(mid.x - 4, mid.y - 2.2, 8, 1.5), Character.flag_colour(Character.Team.NAVS))

## The X's are red; the one the Star Chart is buried by (campaign) is gold.
func _draw_x(cell: Vector2i, gold := false) -> void:
	var o := Vector2(cell.x * TILE, cell.y * TILE)
	var col := Color(1.0, 0.80, 0.20) if gold else Color(0.9, 0.15, 0.15)
	if gold:
		draw_line(o + Vector2(6, 6), o + Vector2(TILE - 6, TILE - 6), Color(0, 0, 0, 0.6), 5.0)
		draw_line(o + Vector2(TILE - 6, 6), o + Vector2(6, TILE - 6), Color(0, 0, 0, 0.6), 5.0)
	draw_line(o + Vector2(6, 6), o + Vector2(TILE - 6, TILE - 6), col, 3.0)
	draw_line(o + Vector2(TILE - 6, 6), o + Vector2(6, TILE - 6), col, 3.0)

## The nav ship flies blue; the pirate ship a red pennant and a black flag;
## the corsairs gold and the buccaneers green, each over a pennant of their hat.
## A Captain's ship (they finished the campaign) flies the Golden Rooster
## instead: a gold rooster on wine red.
func _draw_ship(cell: Vector2i, team: int) -> void:
	if server.captains.has(team):
		_draw_captain_ship(cell)
		return
	var o := Vector2(cell.x * TILE, cell.y * TILE)
	# Hull.
	draw_rect(Rect2(o.x + 4, o.y + 12, TILE - 8, TILE - 18), Color(0.45, 0.29, 0.14))
	draw_rect(Rect2(o.x + 4, o.y + 12, TILE - 8, 3), Color(0.6, 0.4, 0.2))
	# Mast + flag.
	draw_line(o + Vector2(TILE / 2.0, 2), o + Vector2(TILE / 2.0, 14), Color(0.15, 0.12, 0.1), 2.0)
	match team:
		Character.Team.NAVS:
			draw_rect(Rect2(o.x + TILE / 2.0, o.y + 2, 9, 7), Character.flag_colour(team))
		Character.Team.PIRATES:
			draw_rect(Rect2(o.x + TILE / 2.0, o.y + 2, 9, 7), Color(0.08, 0.06, 0.06))
			draw_circle(Vector2(o.x + TILE / 2.0 + 4.5, o.y + 5.0), 1.6, Color(0.95, 0.92, 0.85))
			draw_rect(Rect2(o.x + TILE / 2.0 - 8, o.y + 4, 7, 5), Color(0.85, 0.15, 0.12))
		_:
			draw_rect(Rect2(o.x + TILE / 2.0, o.y + 2, 9, 7), Character.flag_colour(team))
			draw_rect(Rect2(o.x + TILE / 2.0, o.y + 2, 9, 7), Color(0, 0, 0, 0.6), false, 1.0)
			draw_rect(Rect2(o.x + TILE / 2.0 - 8, o.y + 4, 7, 5), Character.hat_colour(team))

func _draw_captain_ship(cell: Vector2i) -> void:
	var o := Vector2(cell.x * TILE, cell.y * TILE)
	draw_rect(Rect2(o.x + 4, o.y + 12, TILE - 8, TILE - 18), Color(0.45, 0.29, 0.14))
	draw_rect(Rect2(o.x + 4, o.y + 12, TILE - 8, 3), Color(0.85, 0.66, 0.25))
	draw_line(o + Vector2(TILE / 2.0, -2), o + Vector2(TILE / 2.0, 14), Color(0.15, 0.12, 0.1), 2.0)
	CaptainFlag.draw(self, Rect2(o.x + TILE / 2.0, o.y - 3, 15, 11))
