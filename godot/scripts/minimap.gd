class_name MiniMap
extends Control

## The whole island in the corner of the screen: the ground this side has
## uncovered, the X's and every crew's ship, your people, any opponents in sight right
## now, and a box for what the main view is showing. Click or drag on it to
## move the view there.

const MAP_WIDTH := 208.0 # pixels; each island's squares are scaled to fit

var server: GameServer
var PX := 4.0
var main: Node2D
var _terrain: ImageTexture
var _fog: ImageTexture
var _fog_image: Image
var _dragging := false

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func setup(_server: GameServer, _main: Node2D) -> void:
	server = _server
	main = _main
	var g := server.grid
	PX = MAP_WIDTH / g.width
	custom_minimum_size = Vector2(MAP_WIDTH, g.height * PX)
	size = custom_minimum_size
	var img := Image.create(g.width, g.height, false, Image.FORMAT_RGBA8)
	for y in g.height:
		for x in g.width:
			img.set_pixel(x, y, IslandPreview.colour(server.grid.tile_type(Vector2i(x, y))))
	_terrain = ImageTexture.create_from_image(img)
	_fog_image = Image.create(g.width, g.height, false, Image.FORMAT_RGBA8)
	_fog = ImageTexture.create_from_image(_fog_image)
	refresh_fog()

## Rebuilds the fog layer; called when the viewing side's fog changes.
func refresh_fog() -> void:
	if server == null:
		return
	var revealed: Dictionary = server.revealed[server.viewer_team()]
	for y in server.grid.height:
		for x in server.grid.width:
			var hidden := not revealed.has(Vector2i(x, y))
			_fog_image.set_pixel(x, y, Color(0.03, 0.03, 0.06, 1.0) if hidden else Color(0, 0, 0, 0))
	_fog.update(_fog_image)

func _process(_delta: float) -> void:
	queue_redraw() # people and the view box move every frame

func _draw() -> void:
	if server == null:
		return
	var area := Rect2(Vector2.ZERO, custom_minimum_size)
	draw_rect(area.grow(2), Color(0, 0, 0, 0.75))
	draw_texture_rect(_terrain, area, false)
	draw_texture_rect(_fog, area, false)
	for m in server.x_markers:
		var mid := _dot(m)
		var xc := Color(1.0, 0.80, 0.20) if m == server.chart_marker else Color(0.98, 0.2, 0.18)
		draw_line(mid + Vector2(-2.5, -2.5), mid + Vector2(2.5, 2.5), xc, 1.6)
		draw_line(mid + Vector2(2.5, -2.5), mid + Vector2(-2.5, 2.5), xc, 1.6)
	for t in server.ships.size():
		_ship(server.ships[t], Color(1.0, 0.80, 0.20) if server.captains.has(t) else Character.flag_colour(t))
	if server.outpost.x >= 0:
		draw_rect(Rect2(_dot(server.outpost) - Vector2(2.5, 2.5), Vector2(5, 5)), Color(0.55, 0.75, 1.0))
	if server.goal == "rescue" and server._held_captive() != null and server.revealed[server.viewer_team()].has(server._held_captive().cell):
		draw_arc(_dot(server._held_captive().cell), 3.5, 0.0, TAU, 12, Color(0.95, 0.85, 0.55), 1.5)
	var v := server.viewer_team()
	for cell in server.dropped:
		if server.revealed[v].has(cell):
			var mid := _dot(cell)
			draw_rect(Rect2(mid - Vector2(3, 2.5), Vector2(6, 5)), Color(0, 0, 0, 0.8))
			draw_rect(Rect2(mid - Vector2(2, 1.5), Vector2(4, 3)), Color(0.98, 0.80, 0.25))
	for c in server.characters:
		if c.captured or not (c.team == v or server.seen[v].has(c.id)):
			continue
		var mid := _dot(c.cell)
		draw_circle(mid, 2.8, Color(0, 0, 0, 0.8))
		draw_circle(mid, 2.0, c.team_color.lightened(0.25))
		if c.carrying:
			draw_arc(mid, 3.6, 0.0, TAU, 12, Color(1.0, 0.82, 0.25), 1.4) # a gold ring: carrying a chest
		if c == server.active:
			draw_arc(mid, 4.2, 0.0, TAU, 12, Color.WHITE, 1.2)
	_draw_view_box(area)

func _ship(cell: Vector2i, col: Color) -> void:
	var mid := _dot(cell)
	draw_rect(Rect2(mid - Vector2(3.5, 2.5), Vector2(7, 5)), Color(0, 0, 0, 0.8))
	draw_rect(Rect2(mid - Vector2(2.5, 1.5), Vector2(5, 3)), col)

## The part of the island the main view is showing.
func _draw_view_box(area: Rect2) -> void:
	var cam: Camera2D = main.camera
	var half := get_viewport_rect().size / cam.zoom / 2.0
	var centre := cam.get_screen_center_position()
	var scale := float(PX) / float(Character.TILE)
	var box := Rect2((centre - half) * scale, half * 2.0 * scale).intersection(area)
	draw_rect(box, Color(1, 1, 1, 0.85), false, 1.0)

func _dot(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * PX + PX * 0.5, cell.y * PX + PX * 0.5)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			_look(event.position)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_look(event.position)
		accept_event()

func _look(at: Vector2) -> void:
	main.look_at_world(at / float(PX) * float(Character.TILE))
