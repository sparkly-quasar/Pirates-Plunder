extends Node2D

## Bootstraps the game: builds the world and every crew, wires the authority to
## the views, and hands input to the local player. How we're playing comes from
## GameConfig.mode — against the computer, alone, sharing one computer, hosting,
## or joining — and GameConfig says how many crews land and who sails each.

const TILE := 32

var grid: TerrainGrid
var server: GameServer
var characters: Array[Character] = []
var controller: PlayerController
var world_view: WorldView
var overlay_view: OverlayView
var fog_view: FogView
var camera: Camera2D
var hud_label: Label
var info_label: Label
var controls_label: Label
var win_label: Label
var banner_label: Label
var minimap: MiniMap
var chat: ChatBox      # online: chat with everyone, or (2v2) your side
var continue_button: Button
var game_menu: GameMenu
var tutorial: Tutorial = null

var duel_panel: PanelContainer
var duel_title: Label
var duel_body: Label
var duel_hint: Label
var duel_buttons: HBoxContainer
var _duel_side := -1 # which team the panel is currently asking

var offer_panel: PanelContainer
var offer_label: Label

## Three or four crews: who has how many chests aboard, and who's left.
var score_panel: PanelContainer
var score_label: RichTextLabel
## On a phone: the Scoreboard button beside Menu, and whether it has the
## scoreboard open (it starts folded away).
var score_button: Button
var scores_open := false

## Shared computer: a screen between turns so neither side sees the other's map.
var curtain: ColorRect
var curtain_label: Label
var curtain_up := false
var _banner_left := 0.0
## Whose view was on the screen last, so a shared computer only asks people to
## swap seats when the view actually changes hands.
var _last_view := 0

func _ready() -> void:
	# The island and the rosters come from the setup screen (or the host).
	# Running Main directly (as the tests do) falls back to a random island and
	# the default balanced five, alone.
	if not GameConfig.configured:
		GameConfig.reset()
		GameConfig.mode = GameConfig.Mode.SOLO
	var mode := GameConfig.mode
	grid = TerrainGrid.new(GameConfig.island_seed, GameConfig.length, GameConfig.island_teams(), GameConfig.island_stretch())
	if GameConfig.in_campaign() and int(Campaign.chapter(GameConfig.campaign_chapter).get("guards", 0)) > 0:
		_lay_out_rescue()
	if GameConfig.in_campaign() and int(Campaign.chapter(GameConfig.campaign_chapter).get("fort", 0)) > 0:
		_lay_out_fort()

	world_view = WorldView.new()
	world_view.grid = grid
	world_view.z_index = 0
	add_child(world_view)

	var saved := GameConfig.resume
	GameConfig.resume = {}
	GameConfig.resumed = not saved.is_empty()
	if GameConfig.resumed:
		_rebuild_people(saved.get("people", []))
	else:
		for t in GameConfig.teams_in_play():
			_build_team(t, GameConfig.build_roster(t), grid.ships[t])
		if GameConfig.in_campaign() and str(Campaign.chapter(GameConfig.campaign_chapter).goal) == "rescue":
			_build_captive()

	server = GameServer.new()
	server.name = "GameServer"
	server.mode = mode
	server.is_authority = mode != GameConfig.Mode.GUEST
	server.guest_team = GameConfig.my_team
	server.ctrl = GameConfig.resolved_controllers().slice(0, GameConfig.teams_in_play())
	server.first_team = GameConfig.first_team()
	server.sides = GameConfig.sides()
	server.turn_limit = float(GameConfig.turn_seconds) if GameConfig.mode in [GameConfig.Mode.HOST, GameConfig.Mode.SERVER, GameConfig.Mode.HOTSEAT] else 0.0
	add_child(server)
	server.setup(grid, characters)
	# A guest only rebuilds the people of a resumed game; the rest comes from
	# the host's snapshots.
	if GameConfig.in_campaign():
		_setup_campaign_island()
	if GameConfig.resumed and server.is_authority:
		server.load_state(saved)

	if server.is_authority:
		for t in server.team_count:
			if server.is_computer(t):
				_add_computer(t)

	overlay_view = OverlayView.new()
	overlay_view.server = server
	overlay_view.z_index = 5 # dug holes + order paths: above terrain, below people
	add_child(overlay_view)

	fog_view = FogView.new()
	fog_view.grid = grid
	fog_view.server = server
	fog_view.z_index = 20
	add_child(fog_view)

	_build_camera()

	controller = PlayerController.new()
	controller.server = server
	controller.main = self
	add_child(controller)

	_build_hud()

	server.fog_changed.connect(fog_view.queue_redraw)
	server.holes_changed.connect(overlay_view.queue_redraw)
	server.selection_changed.connect(overlay_view.queue_redraw)
	server.path_changed.connect(overlay_view.queue_redraw)
	server.status_changed.connect(_on_status)
	server.turn_changed.connect(_on_turn_changed)
	server.game_won.connect(_on_won)
	server.duel_changed.connect(_refresh_duel_panel)
	server.duel_changed.connect(overlay_view.queue_redraw) # clash on, clash off, capture markers
	server.duel_resolved.connect(_on_duel_resolved)
	server.offer_changed.connect(_refresh_offer_panel)
	server.fog_changed.connect(minimap.refresh_fog)
	server.turn_changed.connect(minimap.refresh_fog) # a shared computer changes whose fog it shows

	if Net.is_online():
		Net.game_server = server
		Net.opponent_left.connect(_on_opponent_left)
		Net.guest_left.connect(_on_guest_left)
		Net.guest_returned.connect(_on_guest_returned)
		Net.guest_rejoining.connect(_on_guest_rejoining)
		Net.decision_asked.connect(_on_decision_asked)
		Net.decision_made.connect(_on_decision_made)
		if mode == GameConfig.Mode.GUEST:
			Net.report_in_game()
		elif Net.guest_in_game:
			server.on_guest_in_game()

	AudioManager.play(AudioManifest.WELCOME)
	_last_view = server.viewer_team()
	_look_at_home()
	server.announce()
	_on_status("")
	_refresh_scores()
	fog_view.queue_redraw()
	if mode == GameConfig.Mode.HOTSEAT and server.human_count() > 1 and server.viewer_team() != Character.Team.NAVS:
		_raise_curtain(server.viewer_team()) # someone other than the NAVS starts this game
	if GameConfig.in_campaign():
		var start := "%s\n%s" % [Campaign.heading(GameConfig.campaign_chapter), Campaign.goal_text(GameConfig.campaign_chapter)]
		if _storm_island():
			start += "\nA storm: your crew get back a quarter less energy each turn. Fight rested."
		_banner(start, 6.0)
	server.goal_changed.connect(func() -> void:
		fog_view.queue_redraw()
		minimap.queue_redraw()
		overlay_view.queue_redraw())
	if GameConfig.resumed:
		server.settle_resumed()

## Campaign rescue island: Vega, tied to a post a few squares inland from the
## pirates' ship, somewhere the NAVS can walk to. She's a NAVS sailor, held
## captive until someone walks up beside her (GameServer._check_rescue).
func _build_captive() -> void:
	var c := Character.new()
	c.z_index = 25
	add_child(c)
	var stats := CharacterStats.new()
	stats.kind = CharacterStats.Kind.SCOUT
	stats.apply_saved(GameConfig.vega_dict())
	stats.person_name = str(GameConfig.vega_dict().name)
	c.setup(rescue.get("captive", Campaign.captive_cell(grid, characters)), stats, Character.Team.NAVS)
	c.energy = 15.0 # slumped against the post
	c.captive = true
	c.captured = true
	characters.append(c)

## Gallows Rock: the stockade goes up round Vega's post before the island is
## drawn (a resumed game puts it where it was).
var rescue := {}
func _lay_out_rescue() -> void:
	var saved_goal: Variant = GameConfig.resume.get("goal", {})
	if saved_goal is Dictionary and saved_goal.get("pen") is Vector2i and Vector2i(saved_goal.pen).x >= 0:
		rescue = {"captive": saved_goal.pen, "gate": saved_goal.gate, "outpost": saved_goal.get("outpost", Vector2i(-1, -1)), "ambush": []}
	else:
		rescue = Campaign.rescue_layout(grid)
	if not rescue.is_empty():
		grid.build_pen(rescue.captive, rescue.gate)

## A stronghold (Vega's Course): its fence goes up before the island is
## drawn (a resumed game puts it where it was; its hoard and guards come back
## with the rest of the saved game).
var fort_plan := {}
func _lay_out_fort() -> void:
	var saved_goal: Variant = GameConfig.resume.get("goal", {})
	if saved_goal is Dictionary and saved_goal.get("fort") is Vector2i and Vector2i(saved_goal.fort).x >= 0:
		fort_plan = {"center": saved_goal.fort, "gate": saved_goal.get("fort_gate", Vector2i(-1, -1))}
	elif not GameConfig.resume.is_empty():
		return # saved before this island had a stronghold: play on without one
	else:
		var c := Campaign.chapter(GameConfig.campaign_chapter)
		fort_plan = Campaign.fort_layout(grid, int(c.fort), int(c.get("fort_guards", 0)))
	if not fort_plan.is_empty():
		grid.build_pen(fort_plan.center, fort_plan.gate, Campaign.FORT_RADIUS)

## The stronghold's guards: the rivals' best swordsmen and fighters, on posts
## just inside the gate. They go for anyone within three squares and then go
## back, standing (they aren't hiding).
func _post_fort_guards(cells: Array) -> void:
	var rank := {CharacterStats.Kind.SWORDSMAN: 0, CharacterStats.Kind.FIGHTER: 1, CharacterStats.Kind.RUNNER: 2,
		CharacterStats.Kind.SCOUT: 3, CharacterStats.Kind.DIGGER: 4}
	var free: Array = characters.filter(func(p: Character) -> bool: return p.team == Character.Team.PIRATES and not server.posts.has(p.id))
	free.sort_custom(func(a: Character, b: Character) -> bool: return int(rank[a.stats.kind]) < int(rank[b.stats.kind]))
	# Keep at least a few pirates free to dig and fight.
	for i in mini(cells.size(), free.size() - 3):
		var p: Character = free[i]
		var at: Vector2i = cells[i]
		if server._occupant(at) != null:
			continue
		p.cell = at
		p.position = Character.cell_to_pos(at)
		server.posts[p.id] = [at, 3, false]

## Ambushers: pirates lying low (crawling) beside the way past the outpost,
## who go for anyone coming within three squares and then slip back.
func _post_ambush(spots: Array) -> void:
	var rank := {CharacterStats.Kind.SCOUT: 0, CharacterStats.Kind.FIGHTER: 1, CharacterStats.Kind.RUNNER: 2,
		CharacterStats.Kind.DIGGER: 3, CharacterStats.Kind.SWORDSMAN: 4}
	var free: Array = characters.filter(func(p: Character) -> bool: return p.team == Character.Team.PIRATES and not server.posts.has(p.id))
	free.sort_custom(func(a: Character, b: Character) -> bool: return int(rank[a.stats.kind]) < int(rank[b.stats.kind]))
	for i in mini(spots.size(), free.size()):
		var p: Character = free[i]
		var at: Vector2i = spots[i]
		if server._occupant(at) != null:
			continue
		p.cell = at
		p.position = Character.cell_to_pos(at)
		p.stance = Character.Stance.CRAWLING
		server.posts[p.id] = [at, 3, false]

## Rescue: BlackPatch's best stand guard on the squares beside the captive,
## swordsmen and fighters first: the four sides, then the corners.
func _post_guards(at: Vector2i, count: int) -> void:
	if count <= 0:
		return
	var pirates: Array = characters.filter(func(p: Character) -> bool: return p.team == Character.Team.PIRATES)
	var rank := {CharacterStats.Kind.SWORDSMAN: 0, CharacterStats.Kind.FIGHTER: 1, CharacterStats.Kind.RUNNER: 2,
		CharacterStats.Kind.SCOUT: 3, CharacterStats.Kind.DIGGER: 4}
	pirates.sort_custom(func(a: Character, b: Character) -> bool: return int(rank[a.stats.kind]) < int(rank[b.stats.kind]))
	var spots: Array[Vector2i] = []
	# Inside the stockade, the squares nearest the gate first.
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1)]
	if rescue.has("gate"):
		var gate: Vector2i = rescue.gate
		dirs.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return Vector2(at + a - gate).length() < Vector2(at + b - gate).length())
	for d in dirs:
		var cell: Vector2i = at + d
		if grid.is_walkable(cell) and server._occupant(cell) == null:
			spots.append(cell)
	var ids := {}
	for i in mini(count, mini(spots.size(), pirates.size())):
		var g: Character = pirates[i]
		g.cell = spots[i]
		g.position = Character.cell_to_pos(spots[i])
		ids[g.id] = true
		server.posts[g.id] = [at, 2, true]
	server.guards = ids

## A campaign island's own rules: its goal, the storm, the chart.
func _setup_campaign_island() -> void:
	var c := Campaign.chapter(GameConfig.campaign_chapter)
	var captive := -1
	for p in characters:
		if p.team == Character.Team.NAVS and p.stats.special == Campaign.SPECIAL_VEGA and str(c.goal) == "rescue":
			captive = p.id
			p.captive = true
	server.setup_goal(str(c.goal), captive)
	if not rescue.is_empty():
		server.pen = rescue.captive
		server.pen_gate = rescue.gate
		server.outpost = rescue.outpost
	if captive >= 0 and not GameConfig.resumed:
		_post_guards(characters[captive].cell, int(c.get("guards", 0)))
		_post_ambush(rescue.get("ambush", []))
	if captive >= 0 and GameConfig.resumed:
		characters[captive].captured = true # load_state puts back whether she's still held
	server.defections = Campaign.vega_sails(GameConfig.campaign_chapter)
	if fort_plan.has("hoard") and not GameConfig.resumed:
		server.setup_fort(fort_plan.center, fort_plan.gate, fort_plan.hoard)
		_post_fort_guards(fort_plan.guards)
	if c.get("storm", false):
		server.rest_scale[Character.Team.NAVS] = 0.75
	if c.get("charted", false) and not GameConfig.resumed:
		server.reveal_all(Character.Team.NAVS)

## A computer player for crew `team`.
func _add_computer(team: int) -> void:
	var cpu := ComputerPlayer.new()
	cpu.name = "ComputerPlayer%d" % team
	cpu.server = server
	cpu.team = team
	cpu.difficulty = GameConfig.difficulty
	cpu.passive = GameConfig.tutorial
	add_child(cpu)

func _exit_tree() -> void:
	if Net.game_server == server:
		Net.game_server = null

func _build_team(team: int, roster: Array, ship: Vector2i) -> void:
	# Landed on whatever beach the generated island put the ship on, in the
	# makeup chosen on the setup screen.
	var spots := grid.landing_cells(ship, roster.size())
	for i in roster.size():
		var c := Character.new()
		c.z_index = 25 # above fog so sprites and bars stay crisp
		add_child(c)
		var cell: Vector2i = spots[i] if i < spots.size() else ship
		var stats := CharacterStats.make(roster[i][0], roster[i][1])
		if roster[i].size() > 2:
			stats.apply_saved(roster[i][2])
		c.setup(cell, stats, team)
		characters.append(c)

## A saved game's people, exactly as they were (where they stand comes back in
## GameServer.load_state).
func _rebuild_people(people: Array) -> void:
	for p in people:
		var d: Dictionary = p.stats
		var stats := CharacterStats.make(int(d.kind), str(d.name))
		stats.apply_saved(d)
		var c := Character.new()
		c.z_index = 25
		add_child(c)
		c.setup(p.cell, stats, int(p.team))
		c.turncoat = bool(p.get("turncoat", false))
		characters.append(c)

func _build_camera() -> void:
	camera = Camera2D.new()
	camera.zoom = Vector2(1.2, 1.2)
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 6.0
	# Clamp to the island so following a character can never scroll the map
	# off screen — which is what hid the team on the beach before. The
	# limits reach a little past the island where the HUD covers the screen
	# (see _update_camera_limits), so its edge can be scrolled clear of it.
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = grid.width * TILE
	camera.limit_bottom = grid.height * TILE
	add_child(camera)
	camera.make_current()
	camera.position = Vector2(grid.width * TILE, grid.height * TILE) / 2.0

## Puts the camera on the viewing team's people.
func _look_at_home() -> void:
	var a: Character = server.active
	var spot := a.position if a else Character.cell_to_pos(server.ships[server.viewer_team()])
	camera.position = spot
	camera.reset_smoothing()

## How much of the screen's edges the HUD covers, in screen pixels:
## [top, right, bottom]. On a phone the bar of buttons and the line above it
## cover the bottom, and the mini-map sits in the bottom-right corner.
func hud_margins() -> Vector3:
	var top := 0.0
	for l: Label in [hud_label, info_label]:
		if l != null and l.visible and l.text != "":
			top = maxf(top, l.position.y + l.size.y)
	var bottom := 0.0
	if controls_label != null:
		bottom = get_viewport_rect().size.y - controls_label.position.y
	var right := 0.0
	if minimap != null and minimap.visible:
		right = minimap.size.x + 24.0
	return Vector3(top, right, bottom)

## Lets the camera go past the island by however much of it the HUD would
## otherwise always hide, at the current zoom: the bottom rows used to sit
## under the phone's buttons for good, with no way to scroll them into view.
func _update_camera_limits() -> void:
	if camera == null:
		return
	var m := hud_margins() / camera.zoom.x
	camera.limit_top = -ceili(m.x)
	camera.limit_right = grid.width * TILE + ceili(m.y)
	camera.limit_bottom = grid.height * TILE + ceili(m.z)

func _process(delta: float) -> void:
	_update_camera_limits()
	_update_visibility()
	_update_info()
	if duel_panel.visible:
		_refresh_duel_panel()
	if _banner_left > 0.0:
		_banner_left -= delta
		banner_label.visible = _banner_left > 0.0

## Per viewing crew: opponents who have gone out of sight, id -> [the cell
## where this crew last saw them, their crew, the turn]. A faded marker stays
## there for two rounds, so someone slipping out of view (stopping, crawling,
## or your own runner's narrowed sight) doesn't seem to vanish into thin air.
var _last_seen := {}
## Per viewing crew: id -> the cell each opponent in sight stands on. The
## marker goes where they were SEEN, never where they've just stepped to.
var _seen_at := {}
var _ghost_view := -1
const LAST_SEEN_ROUNDS := 2

## Your own people always show; opponents only while one of yours can see them.
func _update_visibility() -> void:
	var v := server.viewer_team()
	var spotted: Dictionary = server.seen[v]
	if not _last_seen.has(v):
		_last_seen[v] = {}
		_seen_at[v] = {}
	var marks: Dictionary = _last_seen[v]
	var where: Dictionary = _seen_at[v]
	var changed := false
	for c in characters:
		var shown := not c.captured and (c.team == v or spotted.has(c.id))
		c.visible = shown or (c.captive and c.captured and server.revealed[v].has(c.cell))
		if c.team == v:
			continue
		if c.captured or shown:
			if marks.erase(c.id):
				changed = true
			if shown:
				where[c.id] = c.cell
			else:
				where.erase(c.id)
		elif where.has(c.id):
			marks[c.id] = [where[c.id], c.team, server.turn]
			where.erase(c.id)
			changed = true
	for id in marks.keys():
		if server.turn - int(marks[id][2]) >= LAST_SEEN_ROUNDS:
			marks.erase(id)
			changed = true
	if changed or v != _ghost_view:
		_ghost_view = v
		overlay_view.ghosts = marks.values()
		overlay_view.queue_redraw()

## Pans the view and stops the camera chasing the selected character.
func pan(delta_px: Vector2) -> void:
	# Kept inside the limits, or dragging past an edge piles up distance
	# that has to be dragged back before the view moves again.
	look_at_world(camera.position + delta_px / camera.zoom.x)

## Centre (C, or the button on a phone): the view jumps to whoever is
## selected, once. The camera never follows anyone by itself: selecting or
## moving someone leaves the view where you put it.
func recentre() -> void:
	if server and server.active:
		look_at_world(server.active.position)

## How far the wheel zooms out: the whole island on screen, but never past 0.55
## on the smaller islands, where that already shows all of it.
func min_zoom() -> float:
	var view := get_viewport_rect().size
	var m := hud_margins()
	view -= Vector2(0.0, m.x + m.z) # the part between the HUD's top and bottom
	var fit := minf(view.x / (grid.width * TILE), view.y / (grid.height * TILE))
	return clampf(fit, 0.3, 0.55)

func open_menu() -> void:
	game_menu.open()

func menu_open() -> bool:
	return game_menu != null and game_menu.visible

## Moves the view to a point on the island (the mini-map does this), kept
## inside the island's edges so dragging off the side doesn't overshoot.
func look_at_world(pos: Vector2) -> void:
	_update_camera_limits()
	var half := get_viewport_rect().size / camera.zoom / 2.0
	var near := Vector2(camera.limit_left, camera.limit_top)
	var far := Vector2(camera.limit_right, camera.limit_bottom)
	camera.position = Vector2(
		clampf(pos.x, near.x + half.x, maxf(near.x + half.x, far.x - half.x)),
		clampf(pos.y, near.y + half.y, maxf(near.y + half.y, far.y - half.y)))

# --- HUD -------------------------------------------------------------------

func open_chat() -> void:
	if chat:
		chat.open()

func typing() -> bool:
	return chat != null and chat.is_typing()

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	if GameConfig.in_campaign() and Campaign.chapter(GameConfig.campaign_chapter).get("storm", false):
		layer.add_child(StormView.new()) # first, so the HUD sits on top of the rain

	hud_label = _make_label(Vector2(12, 8), 18)
	layer.add_child(hud_label)

	# The original's readout: who is selected, their energy and combat strength.
	info_label = _make_label(Vector2(12, 32), 15)
	layer.add_child(info_label)

	# HUD lives in screen space, so size it to the VIEWPORT, not the island.
	var view := get_viewport_rect().size
	controls_label = _make_label(Vector2(12, view.y - 30), 14)
	controls_label.modulate = Color(1, 1, 1, 0.8)
	var who: String = GameServer.TEAM_NAMES[server.viewer_team()]
	if server.two_teams:
		controls_label.text = "Click one of yours, then a destination  |  click an enemy to attack  |  1 stand  2 run  3 crawl  |  SPACE dig  |  ENTER end turn  |  TAB next  |  ESC menu"
	else:
		controls_label.text = "Click a %s then a destination  |  1 stand  2 run  3 crawl  |  SPACE dig  |  ENTER end turn  |  TAB next  |  wheel zooms" % who.trim_suffix("S")
	layer.add_child(controls_label)

	banner_label = _make_label(Vector2(0, 70), 26)
	banner_label.size = Vector2(view.x, 50)
	banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner_label.visible = false
	layer.add_child(banner_label)

	win_label = _make_label(Vector2(0, view.y * 0.4), 40)
	win_label.size = Vector2(view.x, 60)
	win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	win_label.visible = false
	win_label.text = "You Won!"
	layer.add_child(win_label)

	continue_button = Button.new()
	continue_button.custom_minimum_size = Vector2(320, 52)
	continue_button.position = Vector2((view.x - 320) / 2.0, view.y * 0.4 + 70)
	continue_button.add_theme_font_size_override("font_size", 21)
	var look := StyleBoxFlat.new()
	look.bg_color = Color(0.08, 0.06, 0.05, 0.95)
	look.border_color = Color(0.85, 0.70, 0.35)
	look.set_border_width_all(2)
	look.set_corner_radius_all(6)
	continue_button.add_theme_stylebox_override("normal", look)
	var lit := look.duplicate()
	lit.bg_color = Color(0.22, 0.17, 0.09, 0.98)
	continue_button.add_theme_stylebox_override("hover", lit)
	continue_button.add_theme_stylebox_override("focus", lit)
	continue_button.visible = false
	continue_button.pressed.connect(continue_after_game)
	layer.add_child(continue_button)

	minimap = MiniMap.new()
	layer.add_child(minimap)
	minimap.setup(server, self)
	minimap.position = view - minimap.size - Vector2(12, 40)

	if Net.is_online() and not Net.is_dedicated_host():
		chat = ChatBox.new()
		chat.lines = 6
		chat.position = Vector2(12, view.y - 220)
		layer.add_child(chat)
		controls_label.text += "  |  T chat"

	_build_duel_panel(layer, view)
	_build_decision_panel(layer, view)
	_build_offer_panel(layer, view)
	_build_scoreboard(layer, view)

	menu_button = Button.new()
	menu_button.text = "Menu"
	menu_button.tooltip_text = "Pause, volume, save, quit (Esc)"
	menu_button.custom_minimum_size = Vector2(80, 32)
	menu_button.position = Vector2(view.x - 92, 8)
	menu_button.pressed.connect(open_menu)
	layer.add_child(menu_button)
	clock_panel = PanelContainer.new()
	var clock_style := StyleBoxFlat.new()
	clock_style.bg_color = Color(0.05, 0.07, 0.10, 0.85)
	clock_style.set_corner_radius_all(4)
	clock_style.content_margin_left = 10
	clock_style.content_margin_right = 10
	clock_panel.add_theme_stylebox_override("panel", clock_style)
	clock_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock_panel.visible = false
	clock_label = Label.new()
	clock_label.name = "TurnClock"
	clock_label.add_theme_font_size_override("font_size", 16 if Touch.enabled else 18)
	clock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	clock_panel.add_child(clock_label)
	layer.add_child(clock_panel)
	_build_curtain(layer)

	if Touch.enabled:
		_build_touch_bar(layer)
		controls_label.text = "Tap one of yours, then where to go  |  tap an enemy to attack  |  double-tap to dig  |  drag to look around, pinch to zoom"
		menu_button.custom_minimum_size = Vector2(110, 52)
		menu_button.add_theme_font_size_override("font_size", 22)
		# With three or four crews: the scoreboard, folded away behind a button.
		score_button = Button.new()
		score_button.name = "ScoreboardButton"
		score_button.text = "Scoreboard"
		score_button.toggle_mode = true
		score_button.focus_mode = Control.FOCUS_NONE
		score_button.custom_minimum_size = Vector2(0, 52)
		score_button.add_theme_font_size_override("font_size", 22)
		score_button.visible = false
		score_button.pressed.connect(func() -> void:
			score_button.set_pressed_no_signal(not score_button.button_pressed) # toggle_scores sets it
			toggle_scores())
		layer.add_child(score_button)
		_refresh_scores()
	_layout_hud()
	get_viewport().size_changed.connect(_layout_hud)

	if GameConfig.tutorial:
		tutorial = Tutorial.new()
		layer.add_child(tutorial)
		tutorial.setup(self, server)
		_layout_hud()
	game_menu = GameMenu.new()
	layer.add_child(game_menu) # last, so it sits over everything
	game_menu.setup(self, server)

## Puts the HUD where it goes on this screen. Again whenever the screen
## changes size (a phone's browser shows and hides its bars).
func _layout_hud() -> void:
	var view := get_viewport_rect().size
	var bar := touch_bar.size.y if touch_bar != null else 0.0
	if touch_bar != null:
		touch_bar.position = Vector2(0, view.y - bar)
		touch_bar.size = Vector2(view.x, bar)
	controls_label.position = Vector2(12, view.y - bar - 30)
	banner_label.size = Vector2(view.x, 50)
	win_label.position = Vector2(0, view.y * 0.4)
	win_label.size = Vector2(view.x, 60)
	continue_button.position = Vector2((view.x - 320) / 2.0, view.y * 0.4 + 70)
	minimap.position = view - minimap.size - Vector2(12, 40 + bar)
	if tutorial != null:
		tutorial.position = Vector2(12, 64) # under the readout, on the left
	if chat != null:
		chat.position = Vector2(12, view.y - bar - 220)
	decision_panel.position = Vector2((view.x - 620) / 2.0, maxf(view.y * 0.3 - bar, 40.0))
	duel_panel.position = Vector2((view.x - 560) / 2.0, maxf(view.y - 330 - bar, 60.0))
	offer_panel.position = Vector2((view.x - 460) / 2.0, 120)
	score_panel.position = Vector2(view.x - 402, 48 + (menu_button.size.y - 32))
	menu_button.position = Vector2(view.x - menu_button.size.x - 12, 8)
	if clock_panel != null:
		# Level with Menu on a computer; a slim strip under it on a phone.
		var clock_h := CLOCK_TOUCH_HEIGHT if Touch.enabled else menu_button.size.y
		clock_panel.custom_minimum_size = Vector2(0, clock_h)
		clock_panel.size = Vector2(0, clock_h) # shrink to the text
	_place_right_column()

## On a phone, down the right edge, each under the last: Menu, Scoreboard
## (three or four crews), the turn clock (a turn limit), then the scoreboard
## itself when it's open. Out of the way of the readout along the top.
func _place_right_column() -> void:
	if Touch.enabled:
		var y := menu_button.position.y + menu_button.size.y + 6
		var right := menu_button.position.x + menu_button.size.x
		if score_button != null:
			var w := score_button.get_combined_minimum_size()
			score_button.position = Vector2(right - w.x, y)
			if score_button.visible:
				y += w.y + 6
		if clock_panel != null:
			clock_panel.position = Vector2(right - clock_panel.size.x, y)
			if clock_panel.visible:
				y += clock_panel.size.y + 6
		if score_panel != null:
			score_panel.position.y = y
	elif clock_panel != null:
		_place_clock()
	_place_scores()

## Whether a point on the screen is on part of the HUD (so a tap there isn't
## also a tap on the island beneath it).
func over_hud(pos: Vector2) -> bool:
	for c: Control in [touch_bar, minimap, menu_button, chat, duel_panel, offer_panel, decision_panel, continue_button, tutorial, score_panel, score_button]:
		if c != null and c.is_visible_in_tree() and c.get_global_rect().has_point(pos):
			return true
	return false

# --- the touch bar: buttons for what the keys do -------------------------------

var touch_bar: PanelContainer
var menu_button: Button
## The turn clock, beside the Menu button: whose turn and the time left, when
## the game has a turn limit (games on a server). Hidden otherwise.
var clock_panel: PanelContainer
const CLOCK_TOUCH_HEIGHT := 30.0
var clock_label: Label
var _stance_buttons: Array[Button] = []

func _build_touch_bar(layer: CanvasLayer) -> void:
	touch_bar = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.07, 0.82)
	style.set_content_margin_all(6)
	touch_bar.add_theme_stylebox_override("panel", style)
	touch_bar.custom_minimum_size = Vector2(0, 76)
	touch_bar.size = Vector2(0, 76)
	layer.add_child(touch_bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	touch_bar.add_child(row)
	var group := ButtonGroup.new()
	for pair in [["Stand", "stand"], ["Run", "run"], ["Crawl", "crawl"]]:
		var b := _touch_button(row, pair[0], pair[1], 96)
		b.toggle_mode = true
		b.button_group = group
		_stance_buttons.append(b)
	_touch_gap(row, 10)
	_touch_button(row, "Dig", "dig", 96)
	_touch_button(row, "Next", "next", 96)
	_touch_button(row, "Centre", "centre", 104)
	_touch_button(row, "+", "zoom_in", 60)
	_touch_button(row, "-", "zoom_out", 60)
	if chat != null:
		_touch_button(row, "Chat", "chat", 90)
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(fill)
	var end := _touch_button(row, "End Turn", "end", 170)
	var gold := StyleBoxFlat.new()
	gold.bg_color = Color(0.45, 0.33, 0.10)
	gold.border_color = Color(1.0, 0.85, 0.45)
	gold.set_border_width_all(2)
	gold.set_corner_radius_all(6)
	end.add_theme_stylebox_override("normal", gold)
	end.add_theme_stylebox_override("hover", gold)
	_refresh_touch_bar()

func _touch_button(row: HBoxContainer, text: String, what: String, width: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(width, 62)
	b.add_theme_font_size_override("font_size", 22)
	b.focus_mode = Control.FOCUS_NONE
	for state in ["normal", "hover", "pressed", "disabled", "hover_pressed"]:
		var look := StyleBoxFlat.new()
		look.bg_color = {"normal": Color(0.20, 0.22, 0.27), "hover": Color(0.20, 0.22, 0.27),
			"pressed": Color(0.62, 0.48, 0.18), "hover_pressed": Color(0.62, 0.48, 0.18), "disabled": Color(0.12, 0.13, 0.15)}[state]
		look.set_corner_radius_all(6)
		b.add_theme_stylebox_override(state, look)
	b.pressed.connect(func() -> void: controller.action(what))
	row.add_child(b)
	return b

func _touch_gap(row: HBoxContainer, width: float) -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(width, 0)
	row.add_child(gap)

## The stance buttons show how the selected person is moving.
func _refresh_touch_bar() -> void:
	if touch_bar == null:
		return
	var c: Character = server.active
	for i in _stance_buttons.size():
		_stance_buttons[i].disabled = c == null
		_stance_buttons[i].set_pressed_no_signal(c != null and int(c.stance) == i)

func _make_label(pos: Vector2, font_size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 5)
	return l

## Beside the Menu button on a computer; under it on a phone, where the
## bigger text would cover the end of the readout (_place_right_column).
func _place_clock() -> void:
	if Touch.enabled:
		_place_right_column()
	else:
		clock_panel.position = Vector2(menu_button.position.x - clock_panel.size.x - 8, menu_button.position.y)

## Whose turn it is and how long is left, when there's a turn limit: white,
## then gold in the last minute, red in the last 30 seconds, flashing in the
## last 10.
func _update_clock() -> void:
	if clock_panel == null:
		return
	var left := server.clock_left()
	clock_panel.visible = left >= 0.0 and not server.won
	if not clock_panel.visible:
		return
	var v := server.viewer_team()
	var whose := "Your turn" if server.current_team == v else "%s' turn" % GameServer.TEAM_NAMES[server.current_team]
	var text := "%s  %s%s" % [whose, GameServer.clock_text(left), "  (paused)" if server.paused else ""]
	if clock_label.text != text:
		clock_label.text = text
		clock_panel.size = Vector2(0, clock_panel.size.y)
		_place_clock()
	var col := Color.WHITE
	if left <= 30.0:
		col = Color(1.0, 0.42, 0.35)
		if left <= 10.0 and not server.paused:
			col.a = 0.55 + 0.45 * absf(sin(Time.get_ticks_msec() / 250.0))
	elif left <= 60.0:
		col = Color(1.0, 0.85, 0.4)
	clock_label.add_theme_color_override("font_color", col)

func _storm_island() -> bool:
	return GameConfig.in_campaign() and bool(Campaign.chapter(GameConfig.campaign_chapter).get("storm", false))

func _update_info() -> void:
	if server == null or info_label == null:
		return
	_update_clock()
	_refresh_touch_bar()
	var v := server.viewer_team()
	var turn_text := "Turn %d" % server.turn
	if server.two_teams:
		turn_text += " — %s" % ("your move" if server.current_team == v
			else "%s moving" % GameServer.TEAM_NAMES[server.current_team])
	var chests := "%d of %d chests aboard" % [server.delivered[v], server.chests_total]
	if server.goal == "sweep":
		var free := 0
		for t in server.rivals(GameServer.NAVS):
			free += server._members(t).size()
		chests = "Chests: you %d of %d, pirates free %d (need all aboard, none free)" % [server.delivered[v], server.chests_total, free]
	elif not server.partners(v).is_empty():
		var ours := server.side_delivered(v)
		chests = "Chests: your side %d, need %d to win" % [ours, ours + server.chests_to_win(v)]
	elif server.team_count > 2:
		chests = "Chests: you %d, need %d to win" % [server.delivered[v], server.delivered[v] + server.chests_to_win(v)]
	elif server.two_teams:
		chests = "Chests: you %d, %s %d (of %d)" % [server.delivered[v],
			GameServer.TEAM_NAMES[server.other(v)], server.delivered[server.other(v)], server.chests_total]
	var c: Character = server.active
	if c == null:
		info_label.text = "%s   |   %s   |   island #%d" % [turn_text, chests, grid.island_seed]
		return
	var stance_name: String = ["Standing", "Running", "Crawling"][c.stance]
	# What they get back when their crew's turn comes round: stamina.
	var rest := c.stats.stamina * float(server.rest_scale[c.team]) * server.rest_bonus(c)
	var storm := c.team == v and _storm_island()
	if server.rest_bonus(c) > 1.0:
		storm = false
	info_label.text = "%s   |   %s the %s (%s)   Energy %d (+%d a turn%s)   Combat %d   |   %s" % [
		turn_text, c.stats.person_name, c.stats.class_name_, stance_name,
		roundi(c.energy), roundi(rest), ", storm" if storm else (", outpost" if server.rest_bonus(c) > 1.0 else ""), roundi(c.combat_strength()), chests,
	]

func _on_status(_text: String) -> void:
	hud_label.text = Touch.words(server.status[server.viewer_team()])
	_refresh_scores()

## The scoreboard for three or four crews: each crew's chests aboard and how
## many of them are still on the island, whose move it is, and what it takes
## to win. Everyone sees it — in a free-for-all you need to know who to stop.
## In 2v2 it lists the two sides, partners together, with each side's total.
func _refresh_scores() -> void:
	if score_panel == null or server == null:
		return
	var shown := server.team_count > 2
	if score_button != null and score_button.visible != shown:
		score_button.visible = shown
		_place_right_column.call_deferred()
	# On a phone it stays folded away until the Scoreboard button opens it.
	score_panel.visible = shown and (scores_open or not Touch.enabled)
	if not score_panel.visible:
		return
	var v := server.viewer_team()
	var lines: Array[String] = []
	var lead := 0
	var order: Array = range(server.team_count)
	var paired := not server.sides.is_empty()
	if paired:
		order.sort_custom(func(a: int, b: int) -> bool: return [server.side_of(a), a] < [server.side_of(b), b])
	for t in server.team_count:
		lead = maxi(lead, server.side_delivered(t) if paired else int(server.delivered[t]))
	for t in order:
		if paired and (t == order[0] or server.side_of(t) != server.side_of(order[order.find(t) - 1])):
			var total := server.side_delivered(t)
			lines.append("[color=#e0d6b0]%s: %d chest%s aboard%s[/color]" % ["Your side" if server.allies(t, v) else "Their side",
				total, "" if total == 1 else "s", "  ★" if lead > 0 and total == lead else ""])
		var left := server._members(t).size()
		var col := Character.ui_colour(t).to_html(false)
		var who: String = GameServer.TEAM_NAMES[t] + (" (you)" if t == v else "")
		if server.is_computer(t):
			who += " (computer)"
		var line := "[color=#%s]%s %s[/color]   %d chest%s aboard   %s" % [col,
			"»" if t == server.current_team and not server.won else "  ", who, int(server.delivered[t]),
			"" if int(server.delivered[t]) == 1 else "s",
			"all captured" if left == 0 else "%d sailor%s free" % [left, "" if left == 1 else "s"]]
		if lead > 0 and int(server.delivered[t]) == lead and not paired:
			line += "  ★"
		lines.append(("   " if paired else "") + line)
	lines.append("[color=#c8c8c8]%d of %d chests still on the island[/color]" % [server.chests_left(), server.chests_total])
	if Touch.enabled:
		lines[lines.size() - 1] += "   [color=#c8c8c8](tap to hide)[/color]"
	score_label.text = "\n".join(lines)
	_place_scores.call_deferred()

## The scoreboard fits its text and keeps to the right edge, under Menu.
func _place_scores() -> void:
	if score_panel == null:
		return
	score_panel.reset_size()
	score_panel.position.x = get_viewport_rect().size.x - score_panel.size.x - 12

## On a phone: opens the scoreboard (the Scoreboard button beside Menu), or
## folds it away again.
func toggle_scores() -> void:
	scores_open = not scores_open
	if score_button != null:
		score_button.set_pressed_no_signal(scores_open)
	_refresh_scores()

func _banner(text: String, seconds := 2.5) -> void:
	banner_label.text = text
	banner_label.visible = true
	_banner_left = seconds

func _on_turn_changed() -> void:
	fog_view.queue_redraw()
	overlay_view.queue_redraw()
	_on_status("")
	if not server.two_teams:
		return
	var team_name: String = GameServer.TEAM_NAMES[server.current_team]
	var view := server.viewer_team()
	if server.mode == GameConfig.Mode.HOTSEAT and view != _last_view:
		# Hide the board while the mouse changes hands.
		_raise_curtain(view)
	elif server.current_team == view:
		_banner("Your turn!")
	else:
		_banner("The %s are moving..." % team_name)
	_last_view = view

## Shared computer: a screen over the board until the next player is in the seat.
func _raise_curtain(team: int) -> void:
	var others: Array[String] = []
	for t in server.team_count:
		if t != team and server.is_person(t):
			others.append(GameServer.TEAM_NAMES[t])
	var away := " and ".join(others) if others.size() <= 2 else "Everyone else"
	curtain_label.text = Touch.words("The %s' turn\n\n%s, look away!\nClick when you're ready.") % [
		GameServer.TEAM_NAMES[team].to_upper(), away]
	curtain.color = Character.SHIRTS[team].darkened(0.6)
	curtain.visible = true
	curtain_up = true
	server.clock_hold = true

func _on_won() -> void:
	var v := server.viewer_team()
	if server.winner == GameServer.NOBODY:
		win_label.text = "The server closed" if Net.dedicated else "The host left"
	elif server.winner == GameServer.DRAW:
		win_label.text = "A draw!"
	elif not server.two_teams or (server.mode == GameConfig.Mode.HOTSEAT and server.human_count() > 1):
		win_label.text = "The %s won!" % server.side_name(server.winner) if server.two_teams else "You Won!"
	else:
		win_label.text = "You Won!" if server.is_winner(v) else "The %s won." % server.side_name(server.winner)
	win_label.visible = true
	duel_panel.visible = false
	offer_panel.visible = false
	continue_button.text = "Back to the Menu" if server.winner == GameServer.NOBODY else "Continue  (Enter)"
	continue_button.visible = true
	_on_status("")
	_after_game()

## The game is over: on to the results page (and from there, coaching), or
## back to the menu if the other player left.
func continue_after_game() -> void:
	if not server.won:
		return
	if GameConfig.tutorial:
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/Menu.tscn")
		return
	if server.winner == GameServer.NOBODY:
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/Menu.tscn")
		return
	GameConfig.last_results = _results()
	get_tree().change_scene_to_file("res://scenes/Results.tscn")

## Everything the results page shows, taken from the finished game.
func _results() -> Dictionary:
	var people := []
	for c in characters:
		people.append({"name": c.stats.person_name, "kind": c.stats.kind, "team": c.team,
			"captured": c.captured, "carrying": c.carrying, "tally": server.tally[c.id]})
	return {
		"winner": server.winner, "reason": server.win_reason, "turn": server.turn,
		"delivered": server.delivered.duplicate(), "total": server.chests_total,
		"two_teams": server.two_teams, "team_count": server.team_count, "ctrl": server.ctrl.duplicate(),
		"hotseat_people": server.human_count(), "viewer": server.viewer_team(), "people": people,
		"sides": server.sides.duplicate(),
		"coaching": (GameConfig.in_match() and not GameConfig.br_over()) or GameConfig.coaching_sessions > 0,
		"sessions": GameConfig.coaching_sessions,
	}

## Single player: the crew keeps what it earned (confidence from chests and
## fights), and a win against the computer earns a round of coaching and a
## new recruit.
func _after_game() -> void:
	if GameConfig.current_slot != "" and not Net.is_online():
		GameConfig.delete_save(GameConfig.current_slot) # played to the end: nothing left to continue
	GameConfig.current_slot = ""
	GameConfig.resumed = false
	if GameConfig.in_match():
		_after_match_game()
		return
	if not GameConfig.uses_crew():
		return
	var navs_won := server.is_winner(Character.Team.NAVS)
	if GameConfig.in_campaign():
		var mine := []
		for c in characters:
			if c.team == Character.Team.NAVS and not c.turncoat and not (c.captive and not navs_won):
				mine.append({"name": c.stats.person_name, "tally": server.tally[c.id]})
		Campaign.add_records(mine)
		if navs_won and Campaign.win(GameConfig.campaign_chapter):
			GameConfig.ending_due = true
	var party: Array = []
	for c in characters:
		# A captive only joins your crew once you've won her island.
		if c.team == Character.Team.NAVS and not c.turncoat and not (c.captive and not navs_won):
			c.stats.add_career(server.tally[c.id], navs_won) # their lifetime record
			party.append(c.stats)
	GameConfig.remember(party)
	GameConfig.last_party = party.map(func(st: CharacterStats) -> String: return st.person_name)
	if server.mode != GameConfig.Mode.COMPUTER or not server.is_winner(Character.Team.NAVS):
		return
	# A win earns a round of coaching (one try for everyone) and a new recruit.
	GameConfig.coaching_sessions = 1
	GameConfig.recruit_due = party.size() < GameConfig.MAX_TEAM_SIZE

func _on_opponent_left() -> void:
	server.opponent_left()

## Host: a friend left. The computer sails their crew for the rest of the game.
func _on_guest_left(team: int) -> void:
	if server.won or team >= server.team_count or server.is_computer(team):
		return
	server.hand_to_computer(team)
	_add_computer(team)
	if not server.started:
		server.on_guest_in_game() # they left while loading: start without them
	_banner("The %s' player left. The computer sails their crew now." % GameServer.TEAM_NAMES[team], 4.0)
	_refresh_scores()

## Host: a player who'd left is coming back (loading the island now).
func _on_guest_rejoining(team: int) -> void:
	if not server.won and team < server.team_count:
		_banner("The %s' player is back, and coming ashore." % GameServer.TEAM_NAMES[team], 3.0)

## Host: they've landed. The computer hands their crew back.
func _on_guest_returned(team: int) -> void:
	if server.won or team >= server.team_count:
		return
	var cpu := get_node_or_null("ComputerPlayer%d" % team)
	if cpu != null:
		cpu.name = "ComputerPlayerLeaving%d" % team # free the name for a later hand-over
		cpu.queue_free()
	server.take_back(team)
	_banner("The %s' player is back. They sail their crew again." % GameServer.TEAM_NAMES[team], 4.0)
	_refresh_scores()

# --- the sword-fight panel -------------------------------------------------

# --- a player lost their connection: what now? -------------------------------

var decision_panel: PanelContainer
var decision_text: Label
var decision_buttons: Array[Button] = []

func _build_decision_panel(layer: CanvasLayer, view: Vector2) -> void:
	decision_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.05, 0.94)
	style.border_color = Color(0.85, 0.70, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	decision_panel.add_theme_stylebox_override("panel", style)
	decision_panel.custom_minimum_size = Vector2(620, 0)
	decision_panel.position = Vector2((view.x - 620) / 2.0, view.y * 0.3)
	decision_panel.visible = false
	layer.add_child(decision_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	decision_panel.add_child(box)
	decision_text = _make_label(Vector2.ZERO, 18)
	decision_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	decision_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	decision_text.custom_minimum_size = Vector2(580, 0)
	box.add_child(decision_text)
	for pair in [["Give Their Crew to the Computer", "replace"], ["Keep Waiting", "wait"], ["Save the Game for Later", "save"]]:
		var b := Button.new()
		b.text = pair[0]
		b.custom_minimum_size = Vector2(0, 44)
		b.add_theme_font_size_override("font_size", 18)
		for state in ["normal", "hover", "pressed", "disabled"]:
			var look := StyleBoxFlat.new()
			look.bg_color = {"normal": Color(0.25, 0.20, 0.14), "hover": Color(0.36, 0.28, 0.17),
				"pressed": Color(0.45, 0.35, 0.18), "disabled": Color(0.16, 0.14, 0.12)}[state]
			look.border_color = Color(0.85, 0.70, 0.35, 0.6)
			look.set_border_width_all(1)
			look.set_corner_radius_all(4)
			b.add_theme_stylebox_override(state, look)
		var choice: String = pair[1]
		b.pressed.connect(func() -> void:
			for other in decision_buttons:
				other.disabled = true
			Net.choose(choice))
		box.add_child(b)
		decision_buttons.append(b)

## Nobody came back in time: everyone still playing chooses (first answer counts).
func _on_decision_asked(names: String, can_save: bool) -> void:
	if Net.is_dedicated_host() or decision_panel == null:
		return # a server has nobody at the screen; its players choose
	decision_text.text = "%s lost the connection and hasn't come back.\nWhat now? (Whoever answers first decides.)\nThe computer can sail their crew, and they can still take it back if they return." % names
	for b in decision_buttons:
		b.disabled = false
	decision_buttons[2].visible = can_save
	decision_panel.visible = true

func _on_decision_made(text: String) -> void:
	if decision_panel != null:
		decision_panel.visible = false
	if text != "":
		_banner(text, 4.0)

func _build_duel_panel(layer: CanvasLayer, view: Vector2) -> void:
	duel_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.05, 0.92)
	style.border_color = Color(0.85, 0.70, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	duel_panel.add_theme_stylebox_override("panel", style)
	duel_panel.custom_minimum_size = Vector2(560, 0)
	# Low on the screen: the camera centres on the fighters, so the panel
	# mustn't cover the middle.
	duel_panel.position = Vector2((view.x - 560) / 2.0, view.y - 330)
	duel_panel.visible = false
	layer.add_child(duel_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	duel_panel.add_child(box)
	duel_title = _make_label(Vector2.ZERO, 22)
	duel_title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	duel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(duel_title)
	duel_body = _make_label(Vector2.ZERO, 15)
	duel_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(duel_body)
	duel_buttons = HBoxContainer.new()
	duel_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	duel_buttons.add_theme_constant_override("separation", 10)
	box.add_child(duel_buttons)
	duel_hint = _make_label(Vector2.ZERO, 13)
	duel_hint.modulate = Color(1, 1, 1, 0.7)
	duel_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(duel_hint)

## Shows the fight to whoever is in it: the two fighters, your odds, and your
## choice — or that you're waiting on the other side.
func _refresh_duel_panel() -> void:
	var d: Dictionary = server.duel
	if d.is_empty() or server.won:
		duel_panel.visible = false
		_duel_side = -1
		return
	var att: Character = server.characters[int(d.a)]
	var dfn: Character = server.characters[int(d.d)]
	# Whose choice is the panel asking for? On a shared computer, the attacker's
	# first and then the defender's (when a person sails them); otherwise this
	# screen's team.
	var side := server.viewer_team()
	if server.mode == GameConfig.Mode.HOTSEAT:
		if int(d.ac) < 0 and server.is_person(att.team):
			side = att.team
		elif int(d.dc) < 0 and server.is_person(dfn.team):
			side = dfn.team
		elif server.is_person(att.team):
			side = att.team
		elif server.is_person(dfn.team):
			side = dfn.team
	if side != att.team and side != dfn.team:
		duel_panel.visible = false
		return
	var me := att if side == att.team else dfn
	var them := dfn if me == att else att
	var my_choice := int(d.ac if me == att else d.dc)
	duel_panel.visible = true
	duel_title.text = "SWORD FIGHT"
	var my_cs := me.combat_strength() * (0.5 if me.carrying and me == dfn else 1.0)
	var their_cs := them.combat_strength() * (0.5 if them.carrying and them == dfn else 1.0)
	var p := Combat.win_chance(my_cs, their_cs)
	# Ties come first, then strength decides: show both, so 97% odds that
	# usually end in a tie don't look like a sure thing.
	var C := Combat.Choice
	var ground := Combat.terrain_bonus(grid, [att.cell, dfn.cell])
	var ties := []
	for pair in [[C.CAUTIOUS, C.CAUTIOUS], [C.CAUTIOUS, C.AGGRESSIVE], [C.AGGRESSIVE, C.AGGRESSIVE]]:
		ties.append(roundi(100.0 * Combat.tie_chance(pair[0], pair[1], att.energy, dfn.energy, ground)))
	duel_body.text = "%s the %s (%s)   Combat %d   Energy %d\nvs\n%s the %s (%s)   Combat %d   Energy %d\n\nChance of a tie: %d%% both cautious, %d%% mixed, %d%% both aggressive.\nIf it isn't a tie, %s's odds are %s (%d%%)." % [
		me.stats.person_name, me.stats.class_name_, GameServer.TEAM_NAMES[me.team], roundi(my_cs), roundi(me.energy),
		them.stats.person_name, them.stats.class_name_, GameServer.TEAM_NAMES[them.team], roundi(their_cs), roundi(them.energy),
		ties[0], ties[1], ties[2], me.stats.person_name, Combat.odds_word(p), roundi(p * 100.0)]
	if my_choice >= 0:
		_set_duel_buttons(-2)
		duel_hint.text = "Waiting for the %s to choose..." % GameServer.TEAM_NAMES[them.team]
		return
	_set_duel_buttons(side)
	if me == att:
		duel_hint.text = "Cautious usually ends in a tie and wears them down; aggressive usually settles it."
	else:
		var left := maxf(0.0, Combat.DEFEND_TIMEOUT - float(d.get("t", 0.0)))
		duel_hint.text = "Choose within %ds or %s defends cautiously." % [ceili(left), me.stats.person_name]

## Rebuilds the buttons only when the side being asked changes, so a click
## isn't lost to a rebuild mid-press. -2 = no buttons (waiting).
func _set_duel_buttons(side: int) -> void:
	if side == _duel_side:
		return
	_duel_side = side
	for b in duel_buttons.get_children():
		b.queue_free()
	if side < 0:
		return
	var attacking := server.characters[int(server.duel.a)].team == side
	var verb := "attack" if attacking else "defence"
	_duel_button("Cautious %s (%d)" % [verb, int(CharacterStats.COST_CAUTIOUS)], side, Combat.Choice.CAUTIOUS)
	_duel_button("Aggressive %s (%d)" % [verb, int(CharacterStats.COST_AGGRESSIVE)], side, Combat.Choice.AGGRESSIVE)
	if attacking:
		_duel_button("Back off", side, Combat.Choice.RETREAT)

func _duel_button(text: String, side: int, choice: int) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.pressed.connect(func() -> void: server.intent(side, "duel", [choice]))
	duel_buttons.add_child(b)

func _on_duel_resolved(text: String) -> void:
	_duel_side = -1
	# Crews that weren't in the fight only hear how it ended, not how it was fought.
	var v := server.viewer_team()
	var teams: Array = server.duel_teams
	if server.mode == GameConfig.Mode.HOTSEAT or teams.size() < 2 or teams.has(v):
		_banner(text, 5.0)
	else:
		_banner("The %s and the %s crossed swords." % [GameServer.TEAM_NAMES[int(teams[0])],
			GameServer.TEAM_NAMES[int(teams[1])]], 3.0)

# --- handing over a chest ---------------------------------------------------

func _build_offer_panel(layer: CanvasLayer, view: Vector2) -> void:
	offer_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.05, 0.92)
	style.border_color = Color(0.85, 0.70, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	offer_panel.add_theme_stylebox_override("panel", style)
	offer_panel.custom_minimum_size = Vector2(460, 0)
	offer_panel.position = Vector2((view.x - 460) / 2.0, 120)
	offer_panel.visible = false
	layer.add_child(offer_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	offer_panel.add_child(box)
	offer_label = _make_label(Vector2.ZERO, 17)
	offer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(offer_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	for answer in [true, false]:
		var b := Button.new()
		b.text = "Hand it over (Y)" if answer else "Keep it (N)"
		b.custom_minimum_size = Vector2(150, 36)
		b.pressed.connect(func() -> void: server.intent(server.viewer_team(), "handoff", [answer]))
		row.add_child(b)

## Asks this screen's player whether the chest should change hands.
func _refresh_offer_panel() -> void:
	var o: Dictionary = server.offer
	if o.is_empty() or server.won:
		offer_panel.visible = false
		return
	var from: Character = server.characters[int(o.from)]
	var to: Character = server.characters[int(o.to)]
	offer_panel.visible = from.team == server.viewer_team()
	offer_label.text = "%s: \"You want me to carry the treasure?\"\n(%s is carrying it now)" % [
		to.stats.person_name, from.stats.person_name]

# --- shared-computer hand-over ---------------------------------------------

func _build_curtain(layer: CanvasLayer) -> void:
	curtain = ColorRect.new()
	curtain.set_anchors_preset(Control.PRESET_FULL_RECT)
	curtain.mouse_filter = Control.MOUSE_FILTER_STOP
	curtain.visible = false
	layer.add_child(curtain)
	curtain_label = _make_label(Vector2.ZERO, 30)
	curtain_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	curtain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	curtain_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	curtain.add_child(curtain_label)
	curtain.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			curtain.visible = false
			curtain_up = false
			server.clock_hold = false
			_look_at_home())

func _build_scoreboard(layer: CanvasLayer, view: Vector2) -> void:
	score_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.07, 0.72)
	style.set_corner_radius_all(5)
	style.set_content_margin_all(8)
	score_panel.add_theme_stylebox_override("panel", style)
	score_panel.position = Vector2(view.x - 402, 48)
	score_panel.custom_minimum_size = Vector2(390, 0)
	score_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_panel.visible = false
	layer.add_child(score_panel)
	if Touch.enabled:
		# One line on a phone, so it doesn't cover the island: tap for the rest.
		score_panel.name = "Scoreboard"
		score_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		score_panel.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				toggle_scores())
	score_label = RichTextLabel.new()
	score_label.bbcode_enabled = true
	score_label.fit_content = true
	score_label.scroll_active = false
	score_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	score_label.add_theme_font_size_override("normal_font_size", 14)
	score_label.custom_minimum_size = Vector2(304, 0)
	score_panel.add_child(score_label)

## A match: the crews as they stand carry into the next game, and every crew
## gets coaching (the host works it out and tells the guests).
func _after_match_game() -> void:
	if server.winner == GameServer.NOBODY:
		return # the host left: the match is over
	if GameConfig.battle_royale and GameConfig.mode != GameConfig.Mode.SERVER:
		# Our own trained crew sailed: their careers grow (nothing else about
		# the saved crew changes in a Battle Royale).
		var me := server.viewer_team()
		var mine := []
		for c in characters:
			if c.team == me:
				mine.append({"name": c.stats.person_name, "tally": server.tally[c.id], "won": server.is_winner(me)})
		GameConfig.add_careers(mine)
	if server.mode != GameConfig.Mode.GUEST:
		var crews := []
		for t in server.team_count:
			crews.append([])
		for c in characters:
			crews[c.team].append(c.stats)
		GameConfig.end_game_in_match(crews, server.winner, server.delivered)
		Net.send_match() # a host also saves the match here (Net.send_match)
