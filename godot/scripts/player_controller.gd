class_name PlayerController
extends Node

## Turns mouse, keyboard and touch input into intents for the authority. It never
## touches game state directly — it only asks. On the guest those intents go
## over the network to the host; everywhere else they're handled in-process.
## It always acts for the team this screen is playing (on a shared computer,
## whoever's turn it is).

const TILE := 32

var server: GameServer
var main: Node2D

const PAN_SPEED := 620.0

var _dragging := false

## Arrow keys pan continuously; right-drag scrolls, as the original does.
func _process(delta: float) -> void:
	if main == null or main.typing():
		return # arrow keys move the chat's cursor, not the camera
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT):
		dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_UP):
		dir.y += 1.0
	if Input.is_physical_key_pressed(KEY_DOWN):
		dir.y -= 1.0
	if dir != Vector2.ZERO:
		main.pan(-dir * PAN_SPEED * delta)

func _team() -> int:
	return server.viewer_team()

func _unhandled_input(event: InputEvent) -> void:
	if main.curtain_up or main.menu_open():
		return # the hand-over screen or the menu is showing
	if Touch.enabled and _touch(event):
		return
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_dragging = false
	if event is InputEventMouseMotion and _dragging:
		main.pan(-event.relative)
		return
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.double_click:
					_on_double_click(_cell_at(event.position))
				else:
					_on_click(_cell_at(event.position))
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(1.15)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(1.0 / 1.15)
			MOUSE_BUTTON_RIGHT:
				_dragging = true
	elif event is InputEventKey and event.pressed and not event.echo:
		var key: String = KEYS.get(event.keycode, "")
		if key != "":
			action(key)

## The keys, and the actions they do (the touch bar's buttons do the same).
const KEYS := {
	KEY_SPACE: "dig", KEY_ENTER: "end", KEY_KP_ENTER: "end",
	KEY_1: "stand", KEY_2: "run", KEY_3: "crawl",
	KEY_R: "reroll", KEY_M: "leave", KEY_C: "centre", KEY_ESCAPE: "menu",
	KEY_TAB: "next", KEY_T: "chat", KEY_Y: "yes", KEY_N: "no",
}

## Does one of the game's actions for this screen's crew: by key, or by a
## button on the touch bar.
func action(what: String) -> void:
	match what:
		"dig":
			server.intent(_team(), "dig")
		"end":
			if server.won:
				main.continue_after_game() # game over: on to the results
			else:
				server.intent(_team(), "end_turn")
		"stand":
			server.intent(_team(), "stance", [Character.Stance.STANDING])
		"run":
			server.intent(_team(), "stance", [Character.Stance.RUNNING])
		"crawl":
			server.intent(_team(), "stance", [Character.Stance.CRAWLING])
		"reroll":
			# A fresh island, same teams. Not in a networked game: the island
			# belongs to everyone.
			if not Net.is_online() and not GameConfig.in_campaign(): # a campaign island is fixed
				GameConfig.island_seed = randi()
				get_tree().reload_current_scene()
		"leave":
			Net.leave()
			get_tree().change_scene_to_file("res://scenes/Menu.tscn")
		"centre":
			main.recentre()
		"menu":
			main.open_menu()
		"next":
			_cycle_selection()
		"chat":
			main.open_chat()
		"yes":
			server.intent(_team(), "handoff", [true])
		"no":
			server.intent(_team(), "handoff", [false])
		"zoom_in":
			_zoom(1.25)
		"zoom_out":
			_zoom(1.0 / 1.25)

# --- touch --------------------------------------------------------------------

## A finger that lifts without having moved is a tap: select, or send the
## selected person there (a quick second tap on one of your people digs).
## One finger dragging looks around the island; two pinch to zoom.
const TAP_SLOP := 14.0      # how far a tap may wander, in design pixels
const DOUBLE_TAP := 0.35    # seconds between the taps of a double tap

var _fingers := {}          # touch index -> where it is
var _tap_from := Vector2.ZERO
var _tap_index := -1
var _slid := false
var _pinch := 0.0
var _last_tap_at := -10.0
var _last_tap_cell := Vector2i(-99, -99)
var _last_tap_pos := Vector2(-999, -999)

## Handles a touch event (true), or says it isn't one (false). The browser's
## pretend mouse clicks that follow each touch are dropped, so a tap counts once.
func _touch(event: InputEvent) -> bool:
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		return true
	if event is InputEventScreenTouch:
		if event.pressed:
			_fingers[event.index] = event.position
			if _fingers.size() == 1:
				_tap_from = event.position
				_tap_index = event.index
				_slid = false
			else:
				_slid = true # two fingers: a pinch, not a tap
				_pinch = _spread()
		else:
			if event.index == _tap_index and not _slid and _fingers.size() == 1 and not main.over_hud(event.position):
				_tap(event.position)
			_fingers.erase(event.index)
			if _fingers.size() < 2:
				_pinch = 0.0
		return true
	if event is InputEventScreenDrag:
		_fingers[event.index] = event.position
		if _fingers.size() >= 2:
			var spread := _spread()
			if _pinch > 0.0 and spread > 0.0:
				_zoom(spread / _pinch)
			_pinch = spread
		elif event.index == _tap_index:
			if _slid or event.position.distance_to(_tap_from) > TAP_SLOP:
				if not _slid:
					main.pan(-(event.position - _tap_from)) # catch up the slop
				_slid = true
				main.pan(-event.relative)
		return true
	return false

func _spread() -> float:
	var at: Array = _fingers.values()
	return (at[0] as Vector2).distance_to(at[1]) if at.size() >= 2 else 0.0

func _tap(pos: Vector2) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# The second tap of a double tap counts for the first one's square: the
	# first may have started the view gliding towards whoever it selected.
	if now - _last_tap_at <= DOUBLE_TAP and pos.distance_to(_last_tap_pos) <= TAP_SLOP * 2.0:
		_last_tap_at = -10.0
		_on_double_click(_last_tap_cell)
		return
	var cell := _cell_at(pos)
	_last_tap_at = now
	_last_tap_cell = cell
	_last_tap_pos = pos
	_on_click(cell)

## Wheel zooms between "whole island" and "close enough to read a face".
func _zoom(factor: float) -> void:
	if main == null or main.camera == null:
		return
	# Out far enough that the whole island fits (further for the big three- and
	# four-crew islands), in to 4 to read a face.
	var z: float = clampf(main.camera.zoom.x * factor, main.min_zoom(), 4.0)
	main.camera.zoom = Vector2(z, z)

## Click one of your people to select them; click anywhere else to send the
## selected one there — the original's two-click control scheme. Clicking an
## opponent is just another destination: you march until you run into them.
## A single click on one of yours only ever selects them, carrying or not;
## handing a chest over takes a double-click (see _on_double_click).
func _on_click(cell: Vector2i) -> void:
	var t := _team()
	var c := server._occupant(cell)
	if c != null and c.team != t and server.allies(c.team, t):
		return # a partner's sailor: theirs to move
	if c != null and c.team == t:
		_picked_before = server.active
		server.intent(t, "select", [cell]) # the view stays put
		return
	server.intent(t, "move", [cell])

## Who was selected before the last click on one of yours: the first click of
## a double-click has already selected whoever was clicked.
var _picked_before: Character

## Double-click one of your people to have them dig where they stand — the
## same as selecting them and pressing SPACE. Double-click a chest-carrier
## to hand the chest over: to whoever you had selected (they walk over and
## ask for it), or, with the carrier already selected, to an empty-handed
## team-mate (or 2v2 partner's sailor) beside them. With your carrier
## selected, double-clicking a partner's sailor beside them offers it too.
func _on_double_click(cell: Vector2i) -> void:
	var t := _team()
	var c := server._occupant(cell)
	if c != null and c.team != t and server.allies(c.team, t):
		var holder: Character = server.active
		if holder != null and holder.carrying and not c.carrying and _beside(holder, c):
			server.intent(t, "offer", [cell])
		return
	if c == null or c.team != t:
		_on_click(cell)
		return
	if c.carrying:
		_hand_over(c)
		return
	server.intent(t, "select", [cell])
	server.intent(t, "dig")

## Starts handing `holder`'s chest to someone: see _on_double_click.
func _hand_over(holder: Character) -> void:
	var t := _team()
	var taker := _picked_before
	if taker != null and taker != holder and taker.team == t and not taker.carrying and not taker.captured:
		server.intent(t, "select", [taker.cell])
		server.intent(t, "fetch", [holder.cell]) # beside them: asks now; else walks over first
		return
	server.intent(t, "select", [holder.cell])
	for c in server.characters:
		if c != holder and not c.captured and not c.carrying and server.allies(c.team, t) and _beside(holder, c):
			server.intent(t, "offer", [c.cell])
			return
	server.announce(t, "Pick who should take %s's chest, then double-click %s." % [holder.stats.person_name, holder.stats.person_name])

func _beside(a: Character, b: Character) -> bool:
	return maxi(absi(a.cell.x - b.cell.x), absi(a.cell.y - b.cell.y)) <= 1

func _cycle_selection() -> void:
	var mine: Array[Character] = server._members(_team())
	if mine.is_empty():
		return
	var i := mine.find(server.active)
	server.intent(_team(), "select", [mine[(i + 1) % mine.size()].cell]) # C centres on them

## Screen position -> grid cell, through the camera.
func _cell_at(screen_pos: Vector2) -> Vector2i:
	var world := screen_pos
	if main and main.camera:
		world = main.camera.get_canvas_transform().affine_inverse() * screen_pos
	return Vector2i(floori(world.x / TILE), floori(world.y / TILE))
