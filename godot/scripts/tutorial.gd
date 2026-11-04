class_name Tutorial
extends PanelContainer

## The tutorial (Single Player -> Tutorial, in place of Practice Alone): a
## small fixed island with a fresh crew of five and one lone pirate, and this
## panel walking through the game a step at a time. Each step says what to do,
## in mouse-and-keys or touch words, and moves on by itself once you've done
## it: select, move, crawl, end the turn, dig by an X, find a chest, hand it
## over the new way, get it aboard, open the menu, and a sword fight with a
## pirate who creeps up for the purpose. Then win the island.
##
## Kept gentle (GameConfig.start_tutorial / GameServer.kind_digs): the first
## dig beside an X that still has its chest finds it, the pirate only waits
## (ComputerPlayer.passive) and is a poor swordsman, and nothing is saved:
## the crew here is not your saved crew.

const STEPS := [
	{"id": "welcome", "title": "Welcome aboard",
		"mouse": "These are your NAVS (blue), landed beside your ship. Somewhere on the island, chests are buried by the red X's. Black is fog: what your crew hasn't seen yet. The line at the top says who's selected and how much energy they have.",
		"touch": "These are your NAVS (blue), landed beside your ship. Somewhere on the island, chests are buried by the red X's. Black is fog: what your crew hasn't seen yet. Drag to look around, pinch to zoom."},
	{"id": "select", "title": "Pick a sailor",
		"mouse": "Click one of your crew to select them. The white box shows who's selected. (Tab picks the next one.)",
		"touch": "Tap one of your crew to select them. The white box shows who's selected. (Next picks the next one.)"},
	{"id": "move", "title": "Send them somewhere",
		"mouse": "Now click an open square: they walk there. Every square costs energy, more in woods and on hills, so short routes are cheap ones.",
		"touch": "Now tap an open square: they walk there. Every square costs energy, more in woods and on hills, so short routes are cheap ones."},
	{"id": "crawl", "title": "Stand, run, crawl",
		"mouse": "Press 3 to crawl. Crawling is slow and costly but hard to spot; 2 runs (fast, but you see little); 1 stands still and sees furthest.",
		"touch": "Tap Crawl on the bar below. Crawling is slow and costly but hard to spot; Run is fast but you see little; Stand sees furthest."},
	{"id": "end", "title": "End the turn",
		"mouse": "Energy doesn't come back as you go: it comes back at the start of your turn, by each sailor's stamina. Press Enter to end the turn.",
		"touch": "Energy doesn't come back as you go: it comes back at the start of your turn, by each sailor's stamina. Tap End Turn."},
	{"id": "dig", "title": "Dig by an X",
		"mouse": "Walk someone onto open grass right beside a red X, then press Space (or double-click them) to dig. Diggers dig for a third of the energy.",
		"touch": "Walk someone onto open grass right beside a red X, then double-tap them (or tap Dig) to dig. Diggers dig for a third of the energy."},
	{"id": "find", "title": "Find the chest",
		"mouse": "Each X's chest is in one of the eight squares around it. Keep digging beside the X until someone comes up holding it.",
		"touch": "Each X's chest is in one of the eight squares around it. Keep digging beside the X until someone comes up holding it."},
	{"id": "hand", "title": "Hand it over",
		"mouse": "Carrying a chest doubles the cost of every step. Select someone else with empty hands, then double-click the carrier: they walk over and ask for it. Say Yes (Y).",
		"touch": "Carrying a chest doubles the cost of every step. Select someone else with empty hands, then double-tap the carrier: they walk over and ask for it. Say Yes."},
	{"id": "aboard", "title": "Get it aboard",
		"mouse": "Walk the new carrier onto your ship (the square with the blue flag). Low on energy? End the turn, and they rest.",
		"touch": "Walk the new carrier onto your ship (the square with the blue flag). Low on energy? End the turn, and they rest."},
	{"id": "menu", "title": "The menu",
		"mouse": "Press Esc (or Menu, top right): pause, volume, saving and a list of the controls. Close it again with Esc or Resume.",
		"touch": "Tap Menu (top right): pause, volume, saving and a list of the controls. Close it again with Resume."},
	{"id": "fight", "title": "A pirate!",
		"mouse": "A pirate has crept up on you. Click him to attack. In a sword fight each side secretly picks cautious or aggressive, and rested sailors fight hardest. Lose, and you're captured.",
		"touch": "A pirate has crept up on you. Tap him to attack. In a sword fight each side secretly picks cautious or aggressive, and rested sailors fight hardest. Lose, and you're captured."},
	{"id": "win", "title": "Win the island",
		"mouse": "To win: get more than half the chests aboard, or capture every pirate. Off you go.",
		"touch": "To win: get more than half the chests aboard, or capture every pirate. Off you go."},
]

var main: Node2D
var server: GameServer
var step := 0
var title_label: Label
var body: Label
var count_label: Label
var next_button: Button
var buttons: HBoxContainer
var _start := {}
var _menu_seen := false
var _finished := false

func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # the menu step runs while the game is paused
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.12, 0.92)
	style.border_color = Color(0.85, 0.70, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	add_theme_stylebox_override("panel", style)
	custom_minimum_size = Vector2(340, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	add_child(col)
	count_label = _label("", 12)
	count_label.modulate = Color(1, 1, 1, 0.55)
	col.add_child(count_label)
	title_label = _label("", 20)
	title_label.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	col.add_child(title_label)
	body = _label("", 15)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(312, 0)
	col.add_child(body)
	buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	col.add_child(buttons)
	var skip := Button.new()
	skip.name = "Skip"
	skip.text = "Leave the Tutorial"
	skip.focus_mode = Control.FOCUS_NONE
	skip.pressed.connect(_to_menu)
	buttons.add_child(skip)
	next_button = Button.new()
	next_button.name = "Next"
	next_button.text = "Next"
	next_button.focus_mode = Control.FOCUS_NONE
	next_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next_button.pressed.connect(advance)
	buttons.add_child(next_button)

func setup(_main: Node2D, _server: GameServer) -> void:
	main = _main
	server = _server
	server.kind_digs = true
	var pirate := _pirate()
	if pirate != null:
		pirate.stats.swordfighting = 5.0
		pirate.stats.team_spirit = 20.0
	_show()

func _pirate() -> Character:
	for c in server.characters:
		if c.team == Character.Team.PIRATES:
			return c
	return null

func step_id() -> String:
	return str(STEPS[step].id) if step < STEPS.size() else "done"

## On to the next step (by itself once its check passes; the welcome has a
## Next button).
func advance() -> void:
	if step >= STEPS.size():
		return
	step += 1
	if step_id() == "fight":
		_bring_pirate()
	_show()

func _show() -> void:
	if step >= STEPS.size():
		return
	var s: Dictionary = STEPS[step]
	count_label.text = "TUTORIAL  ·  step %d of %d" % [step + 1, STEPS.size()]
	title_label.text = str(s.title)
	body.text = str(s.touch if Touch.enabled else s.mouse)
	next_button.visible = step_id() == "welcome"
	_start = {"active": server.active, "steps": _navs_steps(), "turn": server.turn, "dug": server.dug_cells.size(),
		"carrier": _carrier_id(), "duel": server.duel_seq}
	_menu_seen = false

func _process(_delta: float) -> void:
	if server == null or _finished:
		return
	if server.won:
		_finish()
		return
	if _done():
		advance()

## Whether the current step has been done since it started.
func _done() -> bool:
	match step_id():
		"select":
			return server.active != null and server.active != _start.active
		"move":
			return _navs_steps() > int(_start.steps)
		"crawl":
			return server.active != null and server.active.stance == Character.Stance.CRAWLING
		"end":
			return server.turn > int(_start.turn)
		"dig":
			return server.dug_cells.size() > int(_start.dug) or server._members(Character.Team.NAVS).any(func(c: Character) -> bool: return c.digging)
		"find":
			return _carrier_id() >= 0
		"hand":
			return _carrier_id() >= 0 and _carrier_id() != int(_start.carrier) or int(server.delivered[Character.Team.NAVS]) > 0
		"aboard":
			return int(server.delivered[Character.Team.NAVS]) > 0
		"menu":
			if main.menu_open():
				_menu_seen = true
			return _menu_seen and not main.menu_open()
		"fight":
			var p := _pirate()
			return server.duel_seq > int(_start.duel) and server.duel.is_empty() or (p != null and p.captured)
	return false

func _navs_steps() -> int:
	var n := 0
	for c in server.characters:
		if c.team == Character.Team.NAVS:
			n += int(server.tally[c.id].steps)
	return n

func _carrier_id() -> int:
	for c in server._members(Character.Team.NAVS):
		if c.carrying:
			return c.id
	return -1

## The pirate steps out of the fog a few squares from whoever is selected,
## somewhere your crew can see him.
func _bring_pirate() -> void:
	var p := _pirate()
	var near: Character = server.active if server.active != null else server._members(Character.Team.NAVS)[0]
	if p == null or p.captured or near == null:
		return
	var best := Vector2i(-1, -1)
	for r in [3, 4, 2, 5]:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var cell: Vector2i = near.cell + Vector2i(dx, dy)
				if server.grid.is_walkable(cell) and server._occupant(cell) == null and not server.ships.has(cell) \
						and not server.grid.find_path(near.cell, cell).is_empty():
					best = cell
					break
			if best.x >= 0:
				break
		if best.x >= 0:
			break
	if best.x < 0:
		return
	p.cell = best
	p.position = Character.cell_to_pos(best)
	p.path.clear()
	p.stance = Character.Stance.STANDING
	p.energy = 40.0
	server.revealed[Character.Team.NAVS][best] = true
	server._refresh_vision()
	server.fog_changed.emit()
	main.look_at_world(p.position)

func _finish() -> void:
	_finished = true
	count_label.text = "TUTORIAL  ·  done"
	title_label.text = "You've got it!"
	body.text = "That's the game. The Campaign tells a story over fifteen islands with your own crew, and Against the Computer is a quick race on any island you like."
	next_button.visible = false
	for b in buttons.get_children():
		b.queue_free()
	var menu := Button.new()
	menu.name = "Menu"
	menu.text = "Main Menu"
	menu.pressed.connect(_to_menu)
	buttons.add_child(menu)
	var camp := Button.new()
	camp.name = "Campaign"
	camp.text = "Start the Campaign"
	camp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camp.pressed.connect(func() -> void:
		Net.leave()
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scenes/Campaign.tscn"))
	buttons.add_child(camp)

func _to_menu() -> void:
	Net.leave()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l
