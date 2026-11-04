extends Node
# Headless regression test: drives the real GameServer through the turn-based
# loop and asserts the rules from DESIGN_REFERENCE.md. Not shipped.

var server: GameServer
var character: Character
var grid: TerrainGrid
var failures := 0

func _ready() -> void:
	# Never touch the player's real saved crew.
	GameConfig.crew_path = "user://smoke_test_crew.cfg"
	GameConfig.save_path = "user://smoke_test_save.cfg"
	GameConfig.crew = []
	_test_scripts_compile()
	_test_island_generation()
	_test_team_makeup()
	_test_combat_rules()
	grid = TerrainGrid.new(4242)
	var team: Array[Character] = []
	var roster := [CharacterStats.Kind.SCOUT, CharacterStats.Kind.DIGGER,
		CharacterStats.Kind.RUNNER, CharacterStats.Kind.FIGHTER, CharacterStats.Kind.SWORDSMAN]
	for i in roster.size():
		var c := Character.new()
		add_child(c)
		var spots := grid.landing_cells(grid.nav_ship, roster.size())
		c.setup(spots[i], CharacterStats.make(roster[i], "P%d" % i))
		team.append(c)
	server = GameServer.new()
	add_child(server)
	server.setup(grid, team)
	var scout: Character = team[0]
	var digger: Character = team[1]
	var runner: Character = team[2]
	var swordsman: Character = team[4]
	server.request_select(Character.Team.NAVS, scout.cell)
	character = server.active

	# --- the class grid (DESIGN_REFERENCE.md §1) ---
	_check(server.characters.size() == 5, "a full team of five is on the island")
	_check(runner.stats.speed > digger.stats.speed, "the Runner is faster than the Digger")
	_check(runner.stats.stamina > swordsman.stats.stamina, "the Runner recovers faster than the Swordsman")
	_check(swordsman.stats.swordfighting > runner.stats.swordfighting, "the Swordsman is the better fighter")
	_check(scout.stats.vision > runner.stats.vision, "the Scout sees furthest")
	_check(is_equal_approx(digger.stats.dig_cost(), CharacterStats.DIG_COST_DIGGER),
		"the Digger digs for 12 energy")
	_check(is_equal_approx(scout.stats.dig_cost(), CharacterStats.DIG_COST),
		"everyone else digs for 35 energy")
	# The ratings scale is multiplicative: Poor is a quarter of Excellent.
	_check(is_equal_approx(CharacterStats.POOR * 4.0, CharacterStats.EXCELLENT),
		"Poor is a quarter of Excellent")

	# --- combat strength formula (§4) ---
	var st := swordsman.stats
	st.confidence = 0.0
	st.team_spirit = 20.0
	var expect_full: float = st.swordfighting * 1.0
	_check(absf(st.combat_strength(100.0) - expect_full) < 0.01,
		"combat strength at full energy equals swordfighting (%.0f)" % expect_full)
	_check(st.combat_strength(50.0) < st.combat_strength(100.0), "combat strength falls with energy")
	# Team spirit floors the energy term, so an exhausted fighter is still dangerous.
	st.team_spirit = 100.0
	_check(st.combat_strength(1.0) > st.swordfighting * 0.15,
		"team spirit floors combat strength when exhausted")
	st.team_spirit = 20.0
	# Confidence lifts it.
	var before_conf := st.combat_strength(100.0)
	st.confidence = 50.0
	_check(st.combat_strength(100.0) > before_conf, "confidence raises combat strength")
	st.confidence = 0.0

	# --- energy & terrain (§2, §5) ---
	var meadow := _find_tile(TerrainGrid.MEADOW)
	_check(grid.tile_type(meadow) == TerrainGrid.MEADOW, "the island has meadow")
	_check(is_equal_approx(grid.move_cost(meadow, false), 2.0), "running across meadow costs 2")
	_check(is_equal_approx(grid.move_cost(meadow, true), 6.0), "crawling costs 3x running")
	var trees := _find_tile(TerrainGrid.TREES)
	_check(not grid.is_walkable(trees), "dense woodland is SOLID — you go around it")
	var swamp := _find_tile(TerrainGrid.SWAMP)
	if grid.tile_type(swamp) == TerrainGrid.SWAMP:
		_check(grid.move_cost(swamp, false) > grid.move_cost(meadow, false),
			"difficult terrain costs more to cross")
	_check(grid.sight_cost(trees) > grid.sight_cost(meadow), "woods block sight more than meadow")
	var bush := _find_tile(TerrainGrid.BUSH)
	_check(not grid.is_walkable(bush), "thickets are solid too — vegetation is a barrier")
	_check(grid.sight_cost(bush) > grid.sight_cost(meadow), "vegetation blocks sight")
	if grid.tile_type(swamp) == TerrainGrid.SWAMP:
		_check(grid.is_walkable(swamp), "swamp is walkable cover — somewhere to hide")

	# --- stance changes vision (§3) ---
	scout.stance = Character.Stance.STANDING
	scout.moving = false
	var standing_view := scout.vision_points()
	scout.stance = Character.Stance.RUNNING
	var running_view := scout.vision_points()
	_check(is_equal_approx(standing_view, running_view * 4.0), "standing sees 4x as far as running")
	scout.stance = Character.Stance.STANDING
	_check(grid.visible_from(scout.cell, standing_view).size()
		> grid.visible_from(scout.cell, running_view).size(), "standing reveals more of the island")

	# --- TURN-BASED: energy does not trickle back inside a turn ---
	scout.energy = 40.0
	await get_tree().create_timer(0.4).timeout
	_check(is_equal_approx(scout.energy, 40.0), "energy does NOT regenerate during a turn")
	var turn_before := server.turn
	server.request_end_turn(Character.Team.NAVS)
	_check(server.turn == turn_before + 1, "ending the turn advances the turn counter")
	_check(is_equal_approx(scout.energy, 40.0 + scout.stats.stamina),
		"each turn restores energy equal to stamina (+%.0f)" % scout.stats.stamina)
	scout.energy = 95.0
	server.request_end_turn(Character.Team.NAVS)
	_check(scout.energy <= CharacterStats.MAX_ENERGY, "energy is capped at 100")

	# --- movement spends energy per square ---
	server.request_select(Character.Team.NAVS, scout.cell)
	scout.energy = CharacterStats.MAX_ENERGY
	var e_before := scout.energy
	var start_cell := scout.cell
	_check(await _walk_to(_open_cell_near(scout.cell, 4)), "walked to an open square")
	_check(scout.cell != start_cell, "the scout actually moved")
	_check(scout.energy < e_before, "moving spent energy (%.0f -> %.0f)" % [e_before, scout.energy])
	# Crawling the same ground must cost more than running it.
	_check(grid.move_cost(scout.cell, true) > grid.move_cost(scout.cell, false),
		"crawling the same square costs more than running it")

	# FOG REGRESSION: a move order puts you in RUNNING stance, which is only a
	# quarter of your eyesight. Arriving must put you back on your feet, or
	# vision stays pinned at 25% and the fog never lifts again.
	_check(scout.stance == Character.Stance.STANDING,
		"arriving puts you back on your feet (stance resets to standing)")
	# Even the worst eyesight, mid-run, must reveal what's next to you.
	var blind := server.characters[2] # the Runner: vision Poor
	blind.stance = Character.Stance.RUNNING
	blind.moving = true
	var near := grid.visible_from(blind.cell, blind.vision_points())
	_check(near.size() > 1, "even a poor-sighted runner sees the squares beside them")
	blind.stance = Character.Stance.STANDING
	blind.moving = false
	# And walking somewhere new must actually uncover ground.
	var seen_before: int = server.revealed[Character.Team.NAVS].size()
	server.request_select(Character.Team.NAVS, scout.cell)
	scout.energy = CharacterStats.MAX_ENERGY
	var far := _open_cell_near(scout.cell, 6)
	if far != scout.cell:
		_check(await _walk_to(far), "walked into unexplored ground")
		_check(server.revealed[Character.Team.NAVS].size() > seen_before,
			"the fog CLEARS as you advance (%d -> %d squares seen)"
				% [seen_before, server.revealed[Character.Team.NAVS].size()])

	# --- chests (§6) ---
	_check(server.chests_total == server.x_markers.size(), "every red X has a chest buried by it")
	for m in server.x_markers:
		_check(server._marker_has_chest(m), "  X at %s has a chest" % m)
	for spot in server.buried:
		var marker: Vector2i = server.buried[spot]
		var d: Vector2i = (spot - marker).abs()
		_check(maxi(d.x, d.y) == 1, "  buried spot %s is adjacent to its X" % spot)
		_check(grid.is_meadow(spot), "  buried spot %s is clear meadow" % spot)
	# Carrying doubles the cost of every square.
	scout.set_carrying(true)
	var carry_cost := server._step_cost(scout, meadow)
	scout.set_carrying(false)
	_check(is_equal_approx(carry_cost, server._step_cost(scout, meadow) * 2.0),
		"carrying a chest doubles movement cost")

	# --- play it out across turns until we win ---
	var guard := 0
	while not server.won and guard < 40:
		guard += 1
		var target: Vector2i = server.buried.keys()[0]
		if not await _walk_to(target):
			server.request_end_turn(Character.Team.NAVS)
			continue
		while server.active.energy < server.active.stats.dig_cost():
			server.request_end_turn(Character.Team.NAVS)
			await get_tree().process_frame
		server.request_dig(Character.Team.NAVS)
		await get_tree().create_timer(1.4).timeout
		if not server.active.carrying:
			continue
		while not await _walk_to(server.ships[Character.Team.NAVS]):
			server.request_end_turn(Character.Team.NAVS)
			await get_tree().process_frame
	_check(server.dug_cells.size() >= 1, "holes were left where we dug")
	_check(server.delivered[Character.Team.NAVS] * 2 > server.chests_total,
		"won with MORE THAN HALF the chests (%d of %d)" % [server.delivered[Character.Team.NAVS], server.chests_total])
	_check(server.won, "GAME WON on turn %d" % server.turn)

	# --- fog ---
	_check(server.revealed[Character.Team.NAVS].size() > 0, "fog: some tiles revealed")
	_check(server.revealed[Character.Team.NAVS].size() < grid.width * grid.height, "fog: map not fully revealed")

	await _test_two_teams()
	_test_computer()
	_test_paths()
	_test_handoff()
	_test_fetch_chest()
	_test_campaign()
	_test_dropped_chest()
	_test_coaching()
	_test_crew()
	_test_difficulty()
	_test_match()
	_test_match_names()
	_test_save_and_pause()
	_test_many_crew_islands()
	_test_many_crew_rules()
	_test_many_crew_config()
	_test_many_crew_computer()
	_test_dedicated_server()
	_test_server_list()
	_test_two_v_two()
	_test_equal_crews()
	_test_online_save()
	await _test_menu_pages()
	await _test_save_slots_and_crew()
	await _test_tutorial()
	await _test_battle_royale()
	await _test_camera_and_clock()
	await _test_hall_of_fame_and_careers()
	await _test_menu_update_check()
	_test_no_dither()
	_test_recruits_land()
	await _test_gallows_rock()
	_test_campaign_levels()
	_test_recruits()
	await _test_coaching_screen()
	_test_window_size()
	await _test_check_for_updates()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GameConfig.crew_path))
	GameConfig.delete_save()

	var passed: bool = failures == 0 and server.won
	print("SMOKE_RESULT: ", "ALL PASS" if passed else "FAIL (%d checks failed)" % failures)
	get_tree().quit(0 if passed else 1)

## The tie odds and spotting maths from DESIGN_REFERENCE.md §3-4.
func _test_combat_rules() -> void:
	var C := Combat.Choice
	_check(is_equal_approx(Combat.tie_chance(C.CAUTIOUS, C.CAUTIOUS, 80, 80, 0), 0.9), "both cautious: 90% tie")
	_check(is_equal_approx(Combat.tie_chance(C.AGGRESSIVE, C.AGGRESSIVE, 80, 80, 0), 0.1), "both aggressive: 10% tie")
	_check(is_equal_approx(Combat.tie_chance(C.CAUTIOUS, C.AGGRESSIVE, 80, 80, 0), 0.6), "mixed: 60% tie")
	_check(is_equal_approx(Combat.tie_chance(C.CAUTIOUS, C.CAUTIOUS, 90, 50, 0), 0.8),
		"80% more energy takes 10% off the tie chance")
	_check(is_equal_approx(Combat.tie_chance(C.CAUTIOUS, C.CAUTIOUS, 90, 30, 0), 0.6),
		"200% more energy takes 30% off")
	_check(is_equal_approx(Combat.tie_chance(C.CAUTIOUS, C.CAUTIOUS, 100, 0, 0), 0.1),
		"an exhausted fighter can't hold off a fresh one with ties")
	_check(is_equal_approx(Combat.tie_chance(C.CAUTIOUS, C.AGGRESSIVE, 80, 80, 0.4), 0.9),
		"swamp adds 40%, clamped to 90%")
	_check(is_equal_approx(Combat.tie_chance(C.AGGRESSIVE, C.AGGRESSIVE, 80, 80, -1.0), 0.1),
		"never below 10%")
	_check(Combat.win_chance(60, 20) > 0.7 and Combat.win_chance(20, 60) < 0.3,
		"the stronger fighter is likelier to win")
	_check(is_equal_approx(Combat.cost(C.CAUTIOUS), 20.0) and is_equal_approx(Combat.cost(C.AGGRESSIVE), 25.0),
		"cautious costs 20 energy, aggressive 25")
	var scout := Character.new()
	scout.setup(Vector2i.ZERO, CharacterStats.make(CharacterStats.Kind.SCOUT))
	var digger := Character.new()
	digger.setup(Vector2i.ZERO, CharacterStats.make(CharacterStats.Kind.DIGGER))
	scout.stance = Character.Stance.CRAWLING
	digger.stance = Character.Stance.RUNNING
	_check(Combat.spot_factor(scout) < Combat.spot_factor(digger),
		"a crawling Scout is far harder to spot than a running Digger")
	scout.stance = Character.Stance.STANDING
	var standing := Combat.spot_factor(scout)
	scout.stance = Character.Stance.CRAWLING
	_check(Combat.spot_factor(scout) < standing, "crawling is stealthier than standing")
	scout.free()
	digger.free()

## NAVS against PIRATES on one island: turns, fog per side, and sword fights.
func _test_two_teams() -> void:
	var g := TerrainGrid.new(777)
	var people: Array[Character] = []
	var kinds := [CharacterStats.Kind.SCOUT, CharacterStats.Kind.DIGGER,
		CharacterStats.Kind.RUNNER, CharacterStats.Kind.FIGHTER, CharacterStats.Kind.SWORDSMAN]
	for team in [Character.Team.NAVS, Character.Team.PIRATES]:
		var ship: Vector2i = g.nav_ship if team == Character.Team.NAVS else g.pirate_ship
		var spots := g.landing_cells(ship, kinds.size())
		for i in kinds.size():
			var c := Character.new()
			add_child(c)
			c.setup(spots[i], CharacterStats.make(kinds[i], "T%d-%d" % [team, i]), team)
			people.append(c)
	var duo := GameServer.new()
	duo.mode = GameConfig.Mode.HOTSEAT
	add_child(duo)
	duo.setup(g, people)
	duo.rng.seed = 12345
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	var nav_sword: Character = people[4]
	var nav_scout: Character = people[0]
	var pir_digger: Character = people[6]
	var pir_scout: Character = people[5]
	var pir_runner: Character = people[7]

	_check(duo.two_teams and duo.characters.size() == 10, "two teams of five on the island")
	_check(people[9].team == P and people[9].team_color != people[0].team_color, "pirates are red, navs blue")
	_check(duo.current_team == N, "the NAVS move first")
	_check(duo.revealed[N].size() > 0 and duo.revealed[P].size() > 0, "each side has its own fog")
	_check(not duo.revealed[N].has(g.pirate_ship), "the navs haven't seen the pirates' beach")
	_check(not duo.seen[N].has(pir_digger.id), "the pirates start out of sight")

	# --- turns ---
	duo.request_select(P, pir_runner.cell)
	var before := pir_runner.cell
	duo.request_move_order(P, _free_near(duo, g, pir_runner.cell, 3))
	await _frames(40)
	_check(pir_runner.cell == before, "the pirates can't move on the navs' turn")
	nav_scout.energy = 50.0
	pir_runner.energy = 30.0
	var turn_before := duo.turn
	duo.request_end_turn(N)
	_check(duo.current_team == P, "ending the navs' turn hands it to the pirates")
	_check(duo.turn == turn_before, "the turn number only advances once both sides have moved")
	_check(is_equal_approx(pir_runner.energy, 30.0 + pir_runner.stats.stamina), "the pirates rest as their turn begins")
	_check(is_equal_approx(nav_scout.energy, 50.0), "the navs don't rest on the pirates' turn")
	duo.request_end_turn(N)
	_check(duo.current_team == P, "the navs can't end the pirates' turn")
	duo.request_end_turn(P)
	_check(duo.current_team == N and duo.turn == turn_before + 1, "back to the navs, turn %d" % duo.turn)

	# --- a fight: put a nav Swordsman beside a pirate Digger in open meadow ---
	var pair := _open_pair(g, duo)
	_check(pair.size() == 2, "found open ground for a fight")
	if pair.size() < 2:
		return
	_place(nav_sword, pair[0])
	_place(pir_digger, pair[1])
	duo._refresh_vision()
	_check(duo.seen[N].has(pir_digger.id) and duo.seen[P].has(nav_sword.id),
		"opponents next to you are always seen")
	nav_sword.energy = 100.0
	pir_digger.energy = 100.0
	duo.request_select(N, nav_sword.cell)
	duo.request_move_order(N, pir_digger.cell)
	await _frames(30)
	_check(not duo.duel.is_empty(), "walking into an opponent starts a sword fight")
	_check(nav_sword.cell == pair[0] and pir_digger.cell == pair[1], "both stop where they stand")
	_check(nav_sword.fighting and pir_digger.fighting, "both are drawn in fight mode")
	_check(nav_sword.facing == -pir_digger.facing, "the fighters face each other")
	duo.request_end_turn(N)
	_check(duo.current_team == N, "no ending the turn mid-fight")
	duo.request_move_order(N, pair[0] + Vector2i(0, 1))
	_check(nav_sword.path.is_empty(), "no new orders mid-fight")

	# Backing off is free.
	duo.duel_choose(N, Combat.Choice.RETREAT)
	_check(duo.duel.is_empty() and is_equal_approx(nav_sword.energy, 100.0), "the attacker can back off for free")
	_check(not nav_sword.fighting, "backing off ends fight mode")

	# Both sides choose; nothing resolves until the second choice is in.
	_start_fight(duo, nav_sword, pir_digger)
	duo.duel_choose(N, Combat.Choice.CAUTIOUS)
	_check(not duo.duel.is_empty(), "the fight waits for the defender's choice")
	duo.duel_choose(N, Combat.Choice.AGGRESSIVE)
	_check(int(duo.duel.ac) == Combat.Choice.CAUTIOUS, "a choice can't be changed once made")
	duo.duel_choose(P, Combat.Choice.CAUTIOUS)
	_check(duo.duel.is_empty(), "the fight resolves once both have chosen")
	var spent_ok := is_equal_approx(nav_sword.energy, 80.0) and is_equal_approx(pir_digger.energy, 80.0)
	_check(spent_ok, "a cautious exchange costs each fighter 20 energy")
	_check(duo.duel_text != "", "the result is announced: %s" % duo.duel_text)

	# A defender who never answers defends cautiously.
	if not pir_digger.captured and not nav_sword.captured:
		nav_sword.energy = 100.0
		pir_digger.energy = 100.0
		_start_fight(duo, nav_sword, pir_digger)
		duo.duel_choose(N, Combat.Choice.AGGRESSIVE)
		duo.duel["t"] = Combat.DEFEND_TIMEOUT - 0.01
		await _frames(3)
		_check(duo.duel.is_empty(), "an unanswered defence times out and resolves")
		_check(is_equal_approx(pir_digger.energy, 80.0), "a timed-out defender pays the cautious cost")

	# Keep fighting until someone is captured (the swordsman should win most).
	var bouts := 0
	while not nav_sword.captured and not pir_digger.captured and bouts < 60:
		bouts += 1
		nav_sword.energy = 100.0
		pir_digger.energy = 100.0
		_start_fight(duo, nav_sword, pir_digger)
		duo.duel_choose(N, Combat.Choice.AGGRESSIVE)
		duo.duel_choose(P, Combat.Choice.AGGRESSIVE)
	var loser: Character = pir_digger if pir_digger.captured else nav_sword
	var victor: Character = nav_sword if loser == pir_digger else pir_digger
	_check(loser.captured, "aggressive fighting ends in a capture (%d bouts)" % bouts)
	_check(duo.captures.size() == 1 and duo.captures[0][0] == loser.cell,
		"a sword-and-hat marker is left where they were taken")
	_check(victor.stats.confidence >= Combat.CONFIDENCE_FOR_WIN, "winning a fight builds confidence")
	_check(duo._occupant(loser.cell) == null, "the captured are off the island")
	duo._refresh_vision()
	_check(not duo.seen[victor.team].has(loser.id), "the captured can't be seen any more")

	# --- carriers: can't attack, defend at half, and lose the chest ---
	var carrier := nav_scout if victor.team == P else pir_scout
	var robber := victor
	carrier.set_carrying(true)
	var gain := duo._capture(carrier, robber)
	_check(robber.carrying and not carrier.carrying and gain.contains("treasure"),
		"capturing a carrier steals the chest")
	robber.set_carrying(true)
	var other_side: Array[Character] = duo._members(duo.other(robber.team))
	if not other_side.is_empty():
		var target: Character = other_side[0]
		_place(target, robber.cell + Vector2i(1, 0) if g.is_walkable(robber.cell + Vector2i(1, 0)) else robber.cell + Vector2i(0, 1))
		if duo.current_team != robber.team:
			duo.request_end_turn(duo.current_team)
		robber.energy = 100.0
		duo.request_select(robber.team, robber.cell)
		duo.request_move_order(robber.team, target.cell)
		await _frames(30)
		_check(duo.duel.is_empty(), "someone carrying a chest can't start a fight")
		robber.set_carrying(false)
		robber.energy = 10.0
		duo.request_move_order(robber.team, target.cell)
		await _frames(30)
		_check(duo.duel.is_empty(), "too tired to attack below 25 energy")

	# --- each team delivers to its own ship ---
	var p_carrier: Character = duo._members(P)[0]
	p_carrier.set_carrying(true)
	duo._check_deliver(p_carrier, g.nav_ship)
	_check(duo.delivered[P] == 0, "the pirates can't load onto the nav ship")
	duo._check_deliver(p_carrier, g.pirate_ship)
	_check(duo.delivered[P] == 1, "the pirates load onto their own ship")

	# --- capture every opponent and you win ---
	var wipe_team := duo.other(robber.team)
	for c in duo._members(wipe_team):
		duo._capture(c, robber)
	duo._check_wipeout()
	_check(duo.won and duo.winner == robber.team, "capturing every opponent wins the game")

	# --- the guest's mirror shows what the host decides ---
	var snap := duo.snapshot()
	var mirror_people: Array[Character] = []
	for c in people:
		var m := Character.new()
		add_child(m)
		m.setup(Vector2i.ZERO, CharacterStats.make(c.stats.kind), c.team)
		mirror_people.append(m)
	var mirror := GameServer.new()
	mirror.mode = GameConfig.Mode.GUEST
	mirror.is_authority = false
	add_child(mirror)
	mirror.setup(g, mirror_people)
	mirror.apply_state(snap)
	var same := true
	for i in people.size():
		if mirror_people[i].cell != people[i].cell or mirror_people[i].captured != people[i].captured:
			same = false
	_check(same, "a snapshot rebuilds every position and capture on the guest")
	_check(mirror.won and mirror.winner == duo.winner and mirror.delivered == duo.delivered,
		"the guest sees the same score and result")
	_check(mirror.revealed[P].size() == duo.revealed[P].size(), "the guest gets the pirates' fog")

func _start_fight(duo: GameServer, a: Character, d: Character) -> void:
	if duo.current_team != a.team:
		duo.request_end_turn(duo.current_team)
	duo._bump(a, d)

const NOWHERE_CELL := Vector2i(-1, -1)

func _place(c: Character, cell: Vector2i) -> void:
	c.cell = cell
	c.position = Character.cell_to_pos(cell)
	c.path.clear()
	c.moving = false

## A carrier captured by someone whose hands are already full drops the chest
## where they stood. It lies there for anyone with empty hands to walk onto and
## pick up, and the computer goes for one it can see.
func _test_dropped_chest() -> void:
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	var navs := game._members(N)
	var pirs := game._members(P)
	# Captured on top of a chest still buried there: neither may be lost.
	var spot: Vector2i = game.buried.keys()[0]
	var loser: Character = pirs[0]
	var winner: Character = navs[4]
	_place(loser, spot)
	var beside := NOWHERE_CELL
	for n in g.neighbours(spot):
		if g.is_walkable(n) and game._occupant(n) == null:
			beside = n
			break
	_place(winner, beside)
	loser.set_carrying(true)
	winner.set_carrying(true)
	var left := game.chests_left()
	var gain := game._capture(loser, winner)
	_check(winner.carrying and not loser.carrying and int(game.dropped.get(spot, 0)) == 1,
		"a full-handed winner leaves the loser's chest on the ground")
	_check(gain.contains("pick"), "the fight result says the chest is there to pick up")
	_check(game.buried.has(spot), "a chest still buried under the spot isn't lost")
	_check(game.chests_left() == left, "a dropped chest still counts as one left to win")
	game._check_pickup(winner, spot)
	_check(game.dropped.has(spot), "someone already carrying can't pick up a second chest")

	var saved := game.save_state()
	game.dropped.clear()
	game.load_state(saved)
	_check(int(game.dropped.get(spot, 0)) == 1, "a dropped chest is kept in a saved game")
	var mirror_people: Array[Character] = []
	for c in game.characters:
		var m := Character.new()
		add_child(m)
		m.setup(Vector2i.ZERO, CharacterStats.make(c.stats.kind), c.team)
		mirror_people.append(m)
	var mirror := GameServer.new()
	mirror.mode = GameConfig.Mode.GUEST
	mirror.is_authority = false
	add_child(mirror)
	mirror.setup(g, mirror_people)
	mirror.apply_state(game.snapshot(P))
	_check(mirror.dropped == game.dropped, "a friend's copy online shows the dropped chest")
	for m in mirror_people:
		m.queue_free()
	mirror.queue_free()

	# Walking onto it with empty hands picks it up; no digging.
	var picker: Character = navs[2]
	_place(winner, g.nav_ship)
	_place(picker, beside)
	picker.energy = 100.0
	var found_before := int(game.tally[picker.id].found)
	game.request_select(N, picker.cell)
	game.request_move_order(N, spot)
	var t := 0.0
	while t < 10.0 and picker.cell != spot:
		game._process(0.05)
		t += 0.05
	_check(picker.carrying and not game.dropped.has(spot) and not picker.digging,
		"walking onto a dropped chest picks it up")
	_check(int(game.tally[picker.id].found) == found_before + 1, "picking it up counts as a chest found")
	_free_game(game)

	# The computer sees one on uncovered ground and fetches it.
	game = _computer_game(g)
	pirs = game._members(P)
	var cpu: ComputerPlayer = game.get_meta("cpu")
	game.request_end_turn(N)
	var drop := NOWHERE_CELL
	var costs := g.move_costs(pirs[0].cell, game._blocked_for(pirs[0]))
	for cell in costs:
		if float(costs[cell]) >= 15.0 and float(costs[cell]) <= 30.0 and g.is_meadow(cell) \
				and not game.buried.has(cell) and game._occupant(cell) == null:
			drop = cell
			break
	game.dropped[drop] = 1
	game.revealed[P][drop] = true
	_sim(game, cpu, 20.0, func() -> bool: return game.dropped.is_empty())
	var fetched := false
	for c in game._members(P):
		fetched = fetched or c.carrying
	_check(game.dropped.is_empty() and fetched, "a computer crew picks up a dropped chest it can see")
	_free_game(game)

## Single player: the computer runs the pirates, through the same intents a
## person sends. Driven by hand at a fixed step so it runs at full speed.
func _test_computer() -> void:
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var cpu: ComputerPlayer = game.get_meta("cpu")
	var pirates := game._members(P)
	_check(game.two_teams and game.viewer_team() == N and not game.is_local_team(P),
		"single player: you are the NAVS, the computer the PIRATES")
	_sim(game, cpu, 3.0)
	_check(game.current_team == N, "the computer waits while the navs move")
	var start := pirates.map(func(c: Character) -> Vector2i: return c.cell)
	game.request_end_turn(N)
	var took := _sim(game, cpu, 240.0, func() -> bool: return game.current_team == N)
	_check(game.current_team == N, "the computer ends its own turn (%.0f s)" % took)
	_check(pirates.map(func(c: Character) -> Vector2i: return c.cell) != start, "the pirates set off")

	# Navs who do nothing but end their turns: the pirates should find the
	# chests, carry them home, and win.
	var turns := 1
	while not game.won and turns < 80:
		game.request_end_turn(N)
		_sim(game, cpu, 400.0, func() -> bool: return game.current_team == N or game.won)
		turns += 1
	_check(game.dug_cells.size() > 0, "the computer digs by the X's (%d holes)" % game.dug_cells.size())
	_check(game.won and game.winner == P and game.delivered[P] * 2 > game.chests_total,
		"left unopposed, the computer wins on chests (turn %d, %d of %d)" % [
			game.turn, game.delivered[P], game.chests_total])
	_check(not game.is_queued_for_deletion() and game.delivered[N] == 0, "and it never plays the navs' side")
	# The results page's numbers add up.
	var walked := 0
	var holes := 0
	var found := 0
	var aboard := 0
	for c in game._members(P):
		walked += int(game.tally[c.id].steps)
		holes += int(game.tally[c.id].holes)
		found += int(game.tally[c.id].found)
		aboard += int(game.tally[c.id].aboard)
	_check(walked > 0 and holes == game.dug_cells.size() and found >= aboard and aboard == game.delivered[P],
		"each person's record adds up: %d squares walked, %d holes, %d found, %d aboard" % [walked, holes, found, aboard])
	_check(game.win_reason.contains("chests aboard"), "and the reason for the win is kept: %s" % game.win_reason)
	_free_game(game)

	# It answers a sword fight in a moment, without waiting out the clock.
	game = _computer_game(g)
	cpu = game.get_meta("cpu")
	var nav_sword: Character = game.characters[4]
	var pir_digger: Character = game.characters[6]
	var pair := _open_pair(g, game)
	_place(nav_sword, pair[0])
	_place(pir_digger, pair[1])
	nav_sword.energy = 100.0
	pir_digger.energy = 100.0
	game._refresh_vision()
	game.request_select(N, nav_sword.cell)
	game.request_move_order(N, pir_digger.cell)
	_sim(game, cpu, 2.0, func() -> bool: return not game.duel.is_empty())
	_check(not game.duel.is_empty() and int(game.duel.dc) < 0, "the navs attack; the computer is thinking")
	_sim(game, cpu, 3.0, func() -> bool: return int(game.duel.get("dc", -1)) >= 0)
	_check(int(game.duel.get("dc", -1)) >= 0 and float(game.duel.t) < 3.0,
		"the computer chooses its defence within a few seconds")
	game.duel_choose(N, Combat.Choice.AGGRESSIVE)
	_check(game.duel.is_empty(), "and the fight resolves")
	var ts: Dictionary = game.tally[nav_sword.id]
	var td: Dictionary = game.tally[pir_digger.id]
	_check(int(ts.captures) + int(ts.tied) + int(ts.lost) == 1 and int(td.captures) + int(td.tied) + int(td.lost) == 1
		and int(ts.captures) == int(td.lost) and int(ts.lost) == int(td.captures),
		"the fight goes on both fighters' records")
	_free_game(game)

	# Its fight sense: back off from a bad fight, guard a chest, go after one.
	game = _computer_game(g)
	cpu = game.get_meta("cpu")
	var weak: Character = game.characters[7]   # pirate Runner, Poor sword
	var strong: Character = game.characters[4] # nav Swordsman
	weak.energy = 60.0
	strong.energy = 100.0
	_check(cpu.choose(weak, strong, true) == Combat.Choice.RETREAT,
		"a Runner who walks into a fresh Swordsman backs off")
	weak.set_carrying(true)
	_check(cpu.choose(weak, strong, false) == Combat.Choice.CAUTIOUS, "a chest-carrier defends cautiously")
	weak.set_carrying(false)
	var nav_digger: Character = game.characters[1]
	var pir_sword: Character = game.characters[9]
	pair = _open_pair(g, game)
	_place(pir_sword, pair[0])
	_place(nav_digger, Vector2i(pair[1].x, pair[1].y))
	nav_digger.set_carrying(true)
	game.request_end_turn(N)
	pir_sword.energy = 100.0
	game._refresh_vision()
	_sim(game, cpu, 10.0, func() -> bool: return not game.duel.is_empty() or game.current_team == N)
	_check(not game.duel.is_empty() and int(game.duel.a) == pir_sword.id and int(game.duel.d) == nav_digger.id,
		"the computer goes after a nav carrying a chest")
	_free_game(game)

## Routes take the cheapest way, and among equally cheap ones the straightest.
func _test_paths() -> void:
	var g := TerrainGrid.new(1)
	for y in g.height:
		for x in g.width:
			g.cells[y][x] = TerrainGrid.MEADOW
	var path := g.find_path(Vector2i(5, 5), Vector2i(15, 5))
	_check(path.size() == 10 and path.all(func(c: Vector2i) -> bool: return c.y == 5),
		"across open meadow, people walk in a straight line")
	path = g.find_path(Vector2i(5, 5), Vector2i(17, 9))
	var worst := 0.0
	for c in path:
		worst = maxf(worst, absf(12.0 * (c.y - 5) - 4.0 * (c.x - 5)) / sqrt(160.0))
	_check(path.size() == 12 and worst < 1.0,
		"a slanting route stays within a square of the straight line (%.2f)" % worst)
	for y in [4, 5, 6]:
		g.cells[y][10] = TerrainGrid.HILL
	path = g.find_path(Vector2i(5, 5), Vector2i(15, 5))
	_check(path.size() == 10 and not path.has(Vector2i(10, 5)),
		"they step round a hill when that's no longer and costs less energy")
	g.cells[3][10] = TerrainGrid.TREES
	g.cells[7][10] = TerrainGrid.TREES
	_check(not g.find_path(Vector2i(5, 5), Vector2i(15, 5)).is_empty(), "and still find a way when it isn't")

## A carrier hands the chest to a team-mate beside them, once you say yes.
func _test_handoff() -> void:
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var N := Character.Team.NAVS
	var carrier: Character = game.characters[1]
	var mate: Character = game.characters[2]
	var far: Character = game.characters[3]
	var pair := _open_pair(g, game)
	_place(carrier, pair[0])
	_place(mate, pair[1])
	_place(far, pair[0] + Vector2i(-3, 0) if g.is_walkable(pair[0] + Vector2i(-3, 0)) else pair[0] + Vector2i(0, 3))
	carrier.set_carrying(true)
	game.request_select(N, carrier.cell)
	game.request_offer(N, far.cell)
	_check(game.offer.is_empty(), "no hand-off to someone who isn't right beside the carrier")
	game.request_offer(N, mate.cell)
	_check(game.offer.get("to", -1) == mate.id, "a team-mate beside the carrier offers to take the chest")
	game.request_end_turn(N)
	_check(game.current_team == N, "the offer has to be answered before anything else")
	game.request_handoff(N, false)
	_check(carrier.carrying and not mate.carrying and game.offer.is_empty(), "say no and the carrier keeps it")
	game.request_offer(N, mate.cell)
	game.request_handoff(N, true)
	_check(mate.carrying and not carrier.carrying, "say yes and the chest changes hands")
	_check(game.active == mate, "and the new carrier is selected")
	game.request_select(N, mate.cell)
	game.request_offer(N, carrier.cell)
	game.intent(N, "handoff", [true])
	_check(carrier.carrying and not mate.carrying, "and it works the other way, through an intent")
	_free_game(game)

## Someone empty-handed, sent to a carrying team-mate, walks over and asks for
## the chest. A single click on the carrier only selects them; a double-click
## sends whoever was selected over to ask.
func _test_fetch_chest() -> void:
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var N := Character.Team.NAVS
	var carrier: Character = game.characters[1]
	var helper: Character = game.characters[2]
	var pair := _open_pair(g, game)
	_place(carrier, pair[0])
	# The helper starts a few squares off, somewhere they can walk from.
	var start := Vector2i(-1, -1)
	for d in [Vector2i(-4, 0), Vector2i(0, 4), Vector2i(0, -4), Vector2i(4, 2), Vector2i(-3, 3), Vector2i(3, -3)]:
		var cell: Vector2i = pair[0] + d
		if g.is_walkable(cell) and game._occupant(cell) == null and not g.find_path(cell, pair[1]).is_empty():
			start = cell
			break
	_check(start.x >= 0, "found a square a few steps from the carrier for the fetch test")
	_place(helper, start)
	carrier.set_carrying(true)
	carrier.energy = 100.0
	helper.energy = 100.0
	game.request_select(N, helper.cell)
	var ctrl := PlayerController.new()
	ctrl.server = game
	game.add_child(ctrl)
	ctrl._on_click(carrier.cell)
	_check(game.active == carrier and helper.path.is_empty() and game.meeting.is_empty() and game.offer.is_empty(),
		"a single click on a carrier just selects them")
	ctrl._on_click(helper.cell)
	ctrl._on_click(carrier.cell) # a double-click: its first click selects...
	ctrl._on_double_click(carrier.cell) # ...then the second hands over
	_check(game.active == helper and not helper.path.is_empty() and int(game.meeting.get(helper.id, -1)) == carrier.id,
		"double-clicking a carrier with someone else selected sends them over")
	var last: Vector2i = helper.path[helper.path.size() - 1]
	_check(maxi(absi(last.x - carrier.cell.x), absi(last.y - carrier.cell.y)) == 1,
		"their route ends right beside the carrier")
	ctrl._on_click(carrier.cell)
	_check(game.active == carrier and not helper.path.is_empty(),
		"a second click on the carrier selects them, and the helper keeps walking")
	var t := _sim(game, game.get_meta("cpu"), 15.0, func() -> bool: return not game.offer.is_empty())
	_check(int(game.offer.get("from", -1)) == carrier.id and int(game.offer.get("to", -1)) == helper.id,
		"arriving beside the carrier, the helper asks for the chest (%.1fs)" % t)
	_check(game.meeting.is_empty() and helper.path.is_empty(), "and stops there")
	game.request_handoff(N, true)
	_check(helper.carrying and not carrier.carrying and game.active == helper, "say yes and the helper has the chest")

	# Already beside the carrier: they ask straight away.
	game.request_select(N, carrier.cell)
	game.intent(N, "fetch", [helper.cell])
	_check(int(game.offer.get("to", -1)) == carrier.id and carrier.path.is_empty(),
		"someone already beside the carrier asks at once")
	game.request_handoff(N, false)
	_check(helper.carrying and not carrier.carrying, "say no and the carrier keeps it")
	ctrl._on_click(helper.cell)
	ctrl._on_click(carrier.cell)
	_check(game.active == carrier and game.offer.is_empty(),
		"with a carrier selected, a single click on a team-mate beside them selects that team-mate")
	ctrl._on_click(helper.cell)
	ctrl._on_click(helper.cell)
	ctrl._on_double_click(helper.cell)
	_check(int(game.offer.get("from", -1)) == helper.id and int(game.offer.get("to", -1)) == carrier.id,
		"double-clicking the selected carrier hands it to the team-mate beside them")
	game.request_handoff(N, false)

	# A fresh order cancels the errand; the carrier walking off is reported.
	var fresh: Character = game.characters[3]
	_place(fresh, start)
	fresh.energy = 100.0
	game.request_select(N, fresh.cell)
	game.intent(N, "fetch", [helper.cell])
	_check(game.meeting.has(fresh.id), "a third sailor sets off for the new carrier")
	game.intent(N, "move", [_free_near(game, g, start, 1)])
	_check(not game.meeting.has(fresh.id) and not fresh.path.is_empty(), "a new order on the way cancels the errand")
	_place(fresh, start)
	game.intent(N, "fetch", [helper.cell])
	_place(helper, start + (start - pair[0]))
	helper.set_carrying(true)
	_sim(game, game.get_meta("cpu"), 15.0, func() -> bool: return fresh.path.is_empty())
	_check(game.offer.is_empty() and not game.meeting.has(fresh.id) and fresh.path.is_empty(),
		"if the carrier has moved off by the time they get there, nobody is asked")

	# Nobody fetches from a rival, or while carrying themselves.
	var pirate: Character = game._members(Character.Team.PIRATES)[0]
	pirate.set_carrying(true)
	game.intent(N, "fetch", [pirate.cell])
	_check(not game.meeting.has(fresh.id) and game.offer.is_empty(), "no fetching a rival's chest")
	ctrl.queue_free()
	_free_game(game)

## Coaching rules: one try per person, odds by attitude, steps by rating.
func _test_coaching() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var runner := CharacterStats.make(CharacterStats.Kind.RUNNER)
	_check(runner.coach_step("speed") == 10.0 and runner.coach_cap("speed") == 100.0,
		"an Excellent skill coaches by 10, up to 100")
	_check(runner.coach_step("swordfighting") == 2.0 and runner.coach_cap("swordfighting") == 40.0,
		"a Poor skill coaches by 2, up to 40")
	_check(runner.coach_step("stealth") == 5.0 and runner.coach_cap("stealth") == 70.0,
		"an Average skill coaches by 5, up to 70")
	var odds := func(coachable: bool, motivated: bool) -> int:
		var worked := 0
		for i in 400:
			var st := CharacterStats.make(CharacterStats.Kind.FIGHTER)
			st.coachable = coachable
			st.self_motivated = motivated
			if st.coach("vision", rng) > 0.0:
				worked += 1
		return worked
	var both: int = odds.call(true, true)
	var one: int = odds.call(true, false)
	var other: int = odds.call(false, true)
	var neither: int = odds.call(false, false)
	_check(both > 270 and both < 330 and one > 170 and one < 230 and other > 170 and other < 230
		and neither > 70 and neither < 130,
		"coaching takes 75%% with both attitudes, 50%% with one, 25%% with neither (%d, %d, %d, %d of 400)" % [both, one, other, neither])
	var slacker := CharacterStats.make(CharacterStats.Kind.SCOUT, "Slacker")
	slacker.coachable = false
	slacker.self_motivated = false
	_check(slacker.can_coach("coachable") and slacker.auto_pick() == "coachable", "coach-for-me tries attitudes first")
	var tries := 0
	while not slacker.coachable and tries < 200:
		slacker.coach("coachable", rng)
		tries += 1
	_check(slacker.coachable and not slacker.can_coach("coachable") and is_equal_approx(slacker.coach_chance(), 0.5),
		"an attitude can be developed, once, and it raises the odds")
	slacker.self_motivated = true
	_check(slacker.auto_pick() == "stealth", "then a Scout works on an Excellent skill")
	var saved := slacker.to_dict()
	var back := CharacterStats.make(CharacterStats.Kind.SCOUT, "Someone Else")
	back.apply_saved(saved)
	_check(back.coachable and back.self_motivated, "attitudes are saved with the person")
	var a := CharacterStats.make(CharacterStats.Kind.FIGHTER, "Bering")
	var b := CharacterStats.make(CharacterStats.Kind.FIGHTER, "Bering")
	_check(a.coachable == b.coachable and a.self_motivated == b.self_motivated,
		"the same person starts with the same attitudes on every computer")
	var made := 0
	var motivated := 0
	for n in GameConfig.NAV_NAMES + GameConfig.PIRATE_NAMES:
		var st := CharacterStats.make(CharacterStats.Kind.FIGHTER, n)
		made += int(st.coachable)
		motivated += int(st.self_motivated)
	_check(made > 22 and motivated > 8 and motivated < 28, "most start Coachable, some Self-Motivated (%d, %d of 36)" % [made, motivated])
	runner.coachable = true
	runner.self_motivated = true
	for i in 60:
		runner.coach("swordfighting", rng)
		runner.coach("team_spirit", rng)
	_check(runner.swordfighting == 40.0 and not runner.can_coach("swordfighting"), "a skill stops at its limit")
	_check(runner.team_spirit == 100.0, "team spirit tops out at 100")
	_check(not runner.can_coach("luck") and runner.coach("luck", rng) == 0.0, "nonsense can't be coached")
	# One round for a crew: a line per try, nobody without a pick.
	var crew: Array = [CharacterStats.make(CharacterStats.Kind.SCOUT, "One"), CharacterStats.make(CharacterStats.Kind.DIGGER, "Two"),
		CharacterStats.make(CharacterStats.Kind.RUNNER, "Three")]
	var lines := GameConfig.coach_crew(crew, {0: "vision", 2: "luck"}, rng)
	_check(lines.size() == 1 and str(lines[0].text).begins_with("One (Scout)"), "a round coaches only who has a real pick")
	_check(GameConfig.sanitize_plan({0: "speed", 5: "speed", "x": "speed", 1: "luck", 2: 3}, 3) == {0: "speed"},
		"plans from the network are cleaned")
	var fighter := CharacterStats.make(CharacterStats.Kind.FIGHTER)
	fighter.digging = CharacterStats.EXCELLENT
	_check(is_equal_approx(fighter.dig_cost(), CharacterStats.DIG_COST_DIGGER),
		"coach a Fighter's digging to Excellent and they dig like a Digger")
	fighter.digging = 45.0
	_check(fighter.dig_cost() < CharacterStats.DIG_COST and fighter.dig_cost() > CharacterStats.DIG_COST_DIGGER,
		"partway there, digging costs partway less")

## Single player keeps your crew between games, coaching and names included.
func _test_crew() -> void:
	var saved_mode := GameConfig.mode
	var saved_counts := GameConfig.nav_counts.duplicate()
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.nav_counts = GameConfig.default_counts()
	var vet := CharacterStats.make(CharacterStats.Kind.SCOUT, "Hudson")
	vet.vision = 80.0
	GameConfig.crew = []
	GameConfig.remember([vet])
	GameConfig.load_crew()
	_check(GameConfig.crew.size() == 1 and float(GameConfig.crew[0].vision) == 80.0, "the crew is saved and loads back")
	var roster := GameConfig.build_roster()
	_check(roster[0][1] == "Hudson" and float(roster[0][2].vision) == 80.0,
		"a veteran Scout lands again, coaching intact")
	var names := roster.map(func(r: Array) -> String: return r[1])
	_check(names.count("Hudson") == 1, "recruits don't take a veteran's name")
	_check(GameConfig.build_roster(true)[0][2].is_empty(), "the pirates are always fresh")
	GameConfig.last_party = ["Hudson"]
	GameConfig.remember([CharacterStats.make(CharacterStats.Kind.FIGHTER, "Cook")])
	_check(GameConfig.rename("Hudson", "  Captain Anne  ") == "Captain Anne", "a sailor can be renamed")
	_check(str(GameConfig.crew[0].name) == "Captain Anne" and GameConfig.last_party == ["Captain Anne"],
		"the new name sticks to the same person")
	_check(GameConfig.rename("Captain Anne", "Cook") == "Captain Anne", "two sailors can't share a name")
	_check(GameConfig.rename("Captain Anne", "   ") == "Captain Anne", "a blank name is refused")
	_check(GameConfig.rename("Cook", "A very long name indeed") == "A very long name", "names are kept short")
	GameConfig.mode = GameConfig.Mode.HOTSEAT
	_check(GameConfig.build_roster()[0][2].is_empty(), "two-player games don't use the saved crew")
	GameConfig.clear_crew()
	GameConfig.mode = saved_mode
	GameConfig.nav_counts = saved_counts

## Easy pirates tire sooner and take fewer risks; hard ones take more.
func _test_difficulty() -> void:
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var cpu: ComputerPlayer = game.get_meta("cpu")
	cpu.difficulty = GameConfig.Difficulty.EASY
	cpu._ready()
	var pirate: Character = game.characters[5]
	pirate.energy = 10.0
	game.request_end_turn(Character.Team.NAVS)
	_check(is_equal_approx(pirate.energy, 10.0 + pirate.stats.stamina * 0.66), "easy pirates recover two-thirds of their stamina")
	_check(cpu._watcher(game._members(Character.Team.PIRATES)) == null, "easy pirates post no look-out")
	var easy: Dictionary = ComputerPlayer.LEVELS[GameConfig.Difficulty.EASY]
	var hard: Dictionary = ComputerPlayer.LEVELS[GameConfig.Difficulty.HARD]
	_check(easy.fight_odds > hard.fight_odds and easy.fight_reserve > hard.fight_reserve,
		"hard pirates pick fights at worse odds and with less in reserve")
	_free_game(game)

## Regular multiplayer: each crew lands with its player's Your Crew names,
## class by class, but fresh skills; names nobody sent, or that an earlier
## crew already asked for, come from the usual lists.
func _test_match_names() -> void:
	var saved_mode := GameConfig.mode
	var saved_crew: Array = GameConfig.crew.duplicate(true)
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOST
	var anne := CharacterStats.make(CharacterStats.Kind.SCOUT, "Anne")
	anne.vision = 90.0
	GameConfig.crew = [anne.to_dict(), CharacterStats.make(CharacterStats.Kind.FIGHTER, "Bo").to_dict(),
		Campaign.make_vega().to_dict()]
	var mine := GameConfig.my_crew_names()
	_check(mine.size() == 2 and mine[0] == {"kind": CharacterStats.Kind.SCOUT, "name": "Anne"},
		"names sent for a regular game: names and classes only, no Vega")
	GameConfig.team_names[0] = mine
	GameConfig.team_names[1] = GameConfig.sanitize_names([{"kind": CharacterStats.Kind.SCOUT, "name": "Anne"},
		{"kind": CharacterStats.Kind.SCOUT, "name": "Cy"}, {"kind": CharacterStats.Kind.SCOUT, "name": "Cy"},
		{"kind": 99, "name": "Junk"}, {"kind": CharacterStats.Kind.DIGGER, "name": "  [b]Dee  "}, "nonsense"])
	_check(GameConfig.team_names[1].map(func(d: Dictionary) -> String: return d.name) == ["Anne", "Cy", "bDee"],
		"names from a player are checked: no repeats, unknown classes or markup")
	var navs := GameConfig.build_roster(0)
	var by_name := {}
	for r in navs:
		by_name[r[1]] = r
	_check(by_name.has("Anne") and int(by_name.Anne[0]) == CharacterStats.Kind.SCOUT and by_name.Anne[2].is_empty(),
		"your Scout keeps her name, with fresh skills")
	_check(by_name.has("Bo") and int(by_name.Bo[0]) == CharacterStats.Kind.FIGHTER and navs.size() == 10,
		"each name goes to someone of the same class; the rest of the crew is filled as usual")
	var pirates := GameConfig.build_roster(1).map(func(r: Array) -> String: return r[1])
	_check(pirates.has("Cy") and pirates.has("bDee") and not pirates.has("Anne"),
		"another crew gets its own names, but not one the NAVS already asked for")
	var all_names := navs.map(func(r: Array) -> String: return r[1]) + pirates
	var unique := {}
	for n in all_names:
		unique[n] = true
	_check(unique.size() == all_names.size(), "no two sailors on the island share a name")
	_check(GameConfig.build_roster(2)[0][1] in GameConfig.CORSAIR_NAMES, "a crew that sent no names gets the usual ones")
	GameConfig.set_battle_royale(true)
	_check(not GameConfig.build_roster(0).any(func(r: Array) -> bool: return r[1] == "Bo"),
		"a Battle Royale doesn't use these names (it brings the whole crew instead)")
	GameConfig.reset()
	_check(GameConfig.team_names == [[], [], [], []], "a new game forgets them")
	GameConfig.crew = saved_crew
	GameConfig.mode = saved_mode

## Two players: coaching carries through a match, and a new match starts fresh.
func _test_match() -> void:
	var saved_mode := GameConfig.mode
	GameConfig.mode = GameConfig.Mode.HOTSEAT
	GameConfig.new_match()
	GameConfig.nav_counts = GameConfig.default_counts()
	GameConfig.pirate_counts = GameConfig.default_counts()
	_check(GameConfig.build_roster(true)[0][2].is_empty(), "a match's first game: both crews fresh")
	var crews := [[], []]
	for t in 2:
		for r in GameConfig.build_roster(t == 1):
			crews[t].append(CharacterStats.make(r[0], r[1]))
	GameConfig.end_game_in_match(crews, Character.Team.PIRATES, [1, 2])
	_check(GameConfig.match_coached == [false, false], "after a game, every crew has a round of coaching to do")
	_check(GameConfig.match_score == [0, 1], "the match score is kept")
	var before := float(GameConfig.match_crews[1][0].vision)
	var plan := {}
	for i in GameConfig.match_crews[1].size():
		plan[i] = "vision"
	var fresh: Array = GameConfig.match_crews[1].duplicate(true)
	var tries := 0
	var took := false
	while not took and tries < 30:
		GameConfig.match_coached[1] = false
		GameConfig.match_crews[1] = fresh.duplicate(true)
		took = GameConfig.coach_plan_in_match(1, plan) and float(GameConfig.match_crews[1][0].vision) > before
		tries += 1
	_check(took and bool(GameConfig.match_coached[1]) and GameConfig.match_note[1].size() == GameConfig.match_crews[1].size(),
		"the pirates coach everyone once, and it shows")
	_check(not GameConfig.coach_plan_in_match(1, plan), "one round of coaching per game")
	_check(not GameConfig.coach_plan_in_match(0, {0: "luck", 99: "vision"}) and not bool(GameConfig.match_coached[0]),
		"nonsense coaching requests are refused")
	GameConfig.rename_in_match(1, 0, "Salty Sue")
	GameConfig.rename_in_match(1, 1, "Salty Sue")
	var roster := GameConfig.build_roster(true)
	_check(roster[0][1] == "Salty Sue" and roster[1][1] != "Salty Sue", "renamed, and names stay unique within a crew")
	_check(float(roster[0][2].vision) > before, "the next game of the match lands the coached crew")
	GameConfig.end_game_in_match(crews, Character.Team.NAVS, [0, 0])
	_check(GameConfig.match_coached == [false, false] and GameConfig.match_note == [[], []],
		"the next game opens a fresh round for everyone")
	var mirror := GameConfig.match_state().duplicate(true)
	GameConfig.reset()
	_check(GameConfig.match_crews == [[], []] and GameConfig.match_score == [0, 0], "a new match starts everyone fresh")
	GameConfig.apply_match_state(mirror)
	_check(GameConfig.match_score == [1, 1] and GameConfig.match_crews[1].size() == crews[1].size(), "the guest's copy takes the host's word")
	GameConfig.new_match()
	GameConfig.mode = saved_mode

## Save a game mid-way, load it back into a fresh one, and find it as it was;
## and the online pause stops everything.
func _test_save_and_pause() -> void:
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var cpu: ComputerPlayer = game.get_meta("cpu")
	var N := Character.Team.NAVS
	game.request_end_turn(N)
	_sim(game, cpu, 240.0, func() -> bool: return game.current_team == N)
	var digger: Character = game.characters[1]
	digger.set_carrying(true)
	digger.energy = 42.0
	game.request_select(N, digger.cell)
	_check(game.save_blocker() == "", "a game with everyone standing still can be saved")
	game.request_move_order(N, _free_near(game, g, digger.cell, 3))
	_check(game.save_blocker() != "", "but not while someone is walking")
	game._clear_path(digger)
	var state := game.save_state()
	var mode_before := GameConfig.mode
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.island_seed = 4242
	GameConfig.save_game(state, "test save")
	_check(GameConfig.has_save() and GameConfig.save_summary() == "test save", "the save slot holds the game")
	_check(GameConfig.load_game() and GameConfig.mode == GameConfig.Mode.COMPUTER and GameConfig.island_seed == 4242,
		"loading it sets the game back up")
	var saved: Dictionary = GameConfig.resume
	GameConfig.resume = {}
	var people: Array[Character] = []
	for p in saved.people:
		var st := CharacterStats.make(int(p.stats.kind), str(p.stats.name))
		st.apply_saved(p.stats)
		var c := Character.new()
		add_child(c)
		c.setup(p.cell, st, int(p.team))
		people.append(c)
	var again := GameServer.new()
	again.mode = GameConfig.Mode.COMPUTER
	add_child(again)
	again.set_process(false)
	again.setup(TerrainGrid.new(4242), people)
	again.load_state(saved)
	var same := true
	for i in game.characters.size():
		var a: Character = game.characters[i]
		var b: Character = again.characters[i]
		same = same and a.cell == b.cell and is_equal_approx(a.energy, b.energy) and a.carrying == b.carrying \
			and a.stats.person_name == b.stats.person_name
	_check(same, "everyone is back where they were, with their energy and chests")
	_check(again.turn == game.turn and again.current_team == game.current_team
		and again.dug_cells == game.dug_cells and again.buried == game.buried
		and again.revealed[0].size() == game.revealed[0].size(), "turn, holes, chests and fog all come back")
	_check(again.active == again.characters[1], "and the same person is selected")
	GameConfig.delete_save()
	_check(not GameConfig.has_save(), "a finished game clears the save slot")
	for c in people:
		c.queue_free()
	again.queue_free()
	GameConfig.mode = mode_before

	# Online pause: either side pauses, nothing moves, either resumes.
	game.request_pause(Character.Team.PIRATES, true)
	var scout: Character = game.characters[0]
	game.request_select(N, scout.cell)
	game.request_move_order(N, _free_near(game, g, scout.cell, 3))
	_check(game.paused and scout.path.is_empty(), "paused: no orders are taken")
	game.request_end_turn(N)
	_check(game.current_team == N, "paused: the turn can't be ended")
	game.intent(N, "pause", [false])
	game.request_move_order(N, _free_near(game, g, scout.cell, 3))
	_check(not game.paused and not scout.path.is_empty(), "resumed by the other side, and play goes on")
	_free_game(game)

## The campaign: fifteen fixed islands, progress on disk, Vega held captive
## and freed, the Star Chart, rival drilling, and the Golden Rooster.
func _test_campaign() -> void:
	var path_before := Campaign.path
	Campaign.path = "user://smoke_test_campaign.cfg"
	Campaign.reset(true)
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	_check(Campaign.count() == 15 and Campaign.chapter(Campaign.RESCUE).goal == "rescue"
		and Campaign.chapter(Campaign.CHART).goal == "chart" and Campaign.FINAL == 14, "campaign: fifteen islands, the rescue and the chart among them")
	var seeds := {}
	for c in Campaign.CHAPTERS:
		seeds[int(c.seed)] = true
	_check(seeds.size() == 15, "campaign: every island is its own")
	_check(Campaign.unlocked(0) and not Campaign.unlocked(1) and Campaign.next_open() == 0, "campaign: only the first island is open to begin with")
	_check(not Campaign.win(0) and Campaign.won(0) and Campaign.unlocked(1) and not Campaign.unlocked(2) and Campaign.next_open() == 1,
		"campaign: winning an island opens the next")
	Campaign._loaded_from = "" # read it back from disk
	_check(Campaign.won(0) and Campaign.won_count() == 1, "campaign: progress is kept on disk")

	# Rosters: your party, drilled rivals, Vega once freed.
	var mode_before := GameConfig.mode
	GameConfig.start_campaign(3, GameConfig.balanced_counts(5))
	_check(GameConfig.in_campaign() and GameConfig.island_seed == int(Campaign.chapter(3).seed) and GameConfig.team_count == 2
		and GameConfig.difficulty == GameConfig.Difficulty.NORMAL, "campaign: an island sets up its own seed, crews and difficulty")
	var rivals := GameConfig.build_roster(1)
	var fresh := CharacterStats.make(int(rivals[0][0]))
	var drilled := 0.0
	for e in rivals:
		var st := CharacterStats.make(int(e[0]))
		st.apply_saved(e[2])
		for skill in CharacterStats.SKILLS:
			drilled += float(st.get(skill)) - float(CharacterStats.make(int(e[0])).get(skill))
	_check(rivals.size() == int(Campaign.chapter(3).rival_crew) and drilled > 0.0 and GameConfig.build_roster(1) == rivals, "campaign: rivals come drilled, the same every time")
	_check(GameConfig.build_roster(0).size() == 5, "campaign: before the rescue, no Vega")
	GameConfig.start_campaign(Campaign.RESCUE + 1, GameConfig.balanced_counts(4))
	_check(GameConfig.build_roster(0).size() == 4, "campaign: Vega only sails once she's been freed")
	Campaign.win(Campaign.RESCUE)
	var roster := GameConfig.build_roster(0)
	var vega_row: Array = roster[roster.size() - 1]
	_check(roster.size() == 5 and str(vega_row[1]) == Campaign.VEGA and str(vega_row[2].get("special", "")) == Campaign.SPECIAL_VEGA,
		"campaign: after the rescue, Vega sails as well as the party")
	var vega := Campaign.make_vega()
	var back := CharacterStats.make(vega.kind, vega.person_name)
	back.apply_saved(vega.to_dict())
	_check(back.special == Campaign.SPECIAL_VEGA and back.class_name_ == "Navigator" and back.vision == 100.0
		and back.coach_cap("swordfighting") == 100.0 and back.can_coach("speed"), "campaign: Vega is a Navigator with high skills, kept in saves")
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.crew = [vega.to_dict()]
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.campaign_chapter = -1
	_check(GameConfig.build_roster(0).all(func(e: Array) -> bool: return str(e[1]) != Campaign.VEGA),
		"campaign: outside the campaign she doesn't take a Scout's place")
	GameConfig.crew = crew_before

	# The rescue.
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var captive := Character.new()
	add_child(captive)
	captive.setup(Campaign.captive_cell(g, game.characters), Campaign.make_vega(), N)
	captive.captured = true
	captive.captive = true
	captive.id = game.characters.size()
	game.characters.append(captive)
	game.tally.append({"steps": 0, "holes": 0, "found": 0, "aboard": 0, "captures": 0, "tied": 0, "lost": 0})
	game.setup_goal("rescue", captive.id)
	var held := captive.cell
	var d: int = maxi(absi(held.x - g.pirate_ship.x), absi(held.y - g.pirate_ship.y))
	_check(game._held_captive() == captive and d >= 4 and d <= 7 and g.is_meadow(held), "rescue: Vega is held in open ground near the pirates' ship (%d squares)" % d)
	_check(game._occupant(held) == null and game._blocked_for(game.characters[0]).has(held), "rescue: nobody walks onto her square")
	var hero: Character = game.characters[2]
	var beside := Vector2i(-1, -1)
	var start := Vector2i(-1, -1)
	for n in g.neighbours(held):
		if not g.is_walkable(n) or game._occupant(n) != null:
			continue
		for m in g.neighbours(n):
			if g.is_walkable(m) and m != held and game._occupant(m) == null and maxi(absi(m.x - held.x), absi(m.y - held.y)) > 1:
				beside = n
				start = m
				break
		if start.x >= 0:
			break
	_place(hero, start)
	hero.energy = 100.0
	game.request_select(N, hero.cell)
	game.request_move_order(N, beside)
	_sim(game, game.get_meta("cpu"), 5.0, func() -> bool: return not captive.captured)
	_check(not captive.captured and game._members(N).has(captive), "rescue: walking up beside her cuts her free, and she joins the crew")
	game.delivered[N] = 3
	_check(not game._check_victory(), "rescue: chests don't win this island for the NAVS")
	_place(captive, g.nav_ship + Vector2i(0, -1) if g.is_walkable(g.nav_ship + Vector2i(0, -1)) else g.landing_cells(g.nav_ship, 1)[0])
	captive.path.assign([g.nav_ship])
	captive.energy = 100.0
	captive.step_timer = 0.0
	game._follow_path(captive, 0.05)
	_check(game.won and game.winner == N and game.win_reason.contains("safe aboard"), "rescue: Vega aboard the NAVS' ship wins it: %s" % game.win_reason)
	_free_game(game)
	captive.queue_free()

	# The Star Chart.
	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	game.setup_goal("chart")
	_check(game.buried.has(game.chart_spot) and game.x_markers.has(game.chart_marker), "chart: buried by one of the X's, which is drawn gold")
	var pirate: Character = game._members(P)[0]
	_place(pirate, game.chart_spot)
	pirate.begin_dig(game.chart_spot)
	game._end_dig(pirate)
	_check(game.chart_carrier == pirate.id and pirate.chart and pirate.carrying, "chart: whoever digs it up carries the Star Chart")
	var nav: Character = game._members(N)[3]
	var said := game._capture(pirate, nav)
	_check(game.chart_carrier == nav.id and nav.chart and not pirate.chart and said.contains("Star Chart"), "chart: capture the carrier and it's yours")
	var mate: Character = game._members(N)[1]
	game.offer = {"from": nav.id, "to": mate.id}
	game.request_handoff(N, true)
	_check(game.chart_carrier == mate.id and mate.chart, "chart: it can be handed over like a chest")
	game.delivered[N] = 4
	_check(not game._check_victory(), "chart: ordinary chests don't win this island for the NAVS")
	_place(mate, g.nav_ship)
	game._check_deliver(mate, g.nav_ship)
	_check(game.won and game.winner == N and game.win_reason.contains("Star Chart"), "chart: getting it aboard wins: %s" % game.win_reason)
	var saved := game.save_state()
	_check(saved.goal.goal == "chart" and saved.goal.marker == game.chart_marker, "chart: the goal is kept in a saved game")
	_free_game(game)

	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	game.setup_goal("chart")
	pirate = game._members(P)[0]
	pirate.set_carrying(true)
	game._set_chart_carrier(pirate.id)
	_place(pirate, g.pirate_ship)
	game._check_deliver(pirate, g.pirate_ship)
	_check(game.won and game.winner == P, "chart: if the pirates get it aboard their ship, they win")
	_free_game(game)

	# An ordinary campaign island ("chests") is won on chests, saved or not.
	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	game.setup_goal("chests")
	_check(game.goal == "", "chests: an ordinary campaign island has no special goal")
	game.delivered[N] = game.chests_total / 2
	var runner: Character = game._members(N)[0]
	runner.set_carrying(true)
	_place(runner, g.nav_ship)
	game._check_deliver(runner, g.nav_ship)
	_check(game.won and game.winner == N, "chests: the NAVS win a campaign chest race on chests: %s" % game.win_reason)
	_free_game(game)
	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	var old_save := game.save_state()
	old_save.goal = {"goal": "chests"} # as 0.13.0 saved it
	old_save.delivered = [game.chests_total / 2 + 1, game.chests_total / 2 - 1]
	game.load_state(old_save)
	_check(game.goal == "" and not game.won, "chests: a 0.13.0 save's \"chests\" goal loads as the usual race")
	_check(game.settle_resumed() and game.won and game.winner == N, "chests: a resumed game already won ends at once")
	_free_game(game)

	# Smugglers' Cove ("sweep"): every chest aboard and every pirate captured.
	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	game.setup_goal("sweep")
	_check(game.goal == "sweep" and Campaign.CHAPTERS[1].goal == "sweep", "sweep: Smugglers' Cove has its own goal")
	game.delivered[N] = game.chests_total - 1
	_check(not game._check_victory() and not game.won, "sweep: chests alone don't win it")
	var sweeper: Character = game._members(N)[4]
	for pir in game._members(P):
		game._capture(pir, sweeper)
	game._check_wipeout()
	_check(not game.won and game._members(P).is_empty(), "sweep: capturing every pirate doesn't end it while a chest is left")
	_check(game.current_team == N or not game._members(N).is_empty(), "sweep: the NAVS carry on alone")
	var last: Character = game._members(N)[0]
	last.set_carrying(true)
	_place(last, g.nav_ship)
	game._check_deliver(last, g.nav_ship)
	_check(game.won and game.winner == N and game.win_reason.contains("talk"), "sweep: the last chest aboard with every pirate captured wins: %s" % game.win_reason)
	_free_game(game)
	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	game.setup_goal("sweep")
	game.delivered[N] = game.chests_total - 1
	last = game._members(N)[0]
	last.set_carrying(true)
	_place(last, g.nav_ship)
	game._check_deliver(last, g.nav_ship)
	_check(not game.won and int(game.delivered[N]) == game.chests_total, "sweep: every chest aboard doesn't win it while pirates are free")
	for pir in game._members(P):
		game._capture(pir, game._members(N)[4])
	game._check_wipeout()
	_check(game.won and game.winner == N, "sweep: capturing the last pirate then wins it")
	_free_game(game)
	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	game.setup_goal("sweep")
	var thief: Character = game._members(P)[0]
	thief.set_carrying(true)
	_place(thief, g.pirate_ship)
	game._check_deliver(thief, g.pirate_ship)
	_check(game.won and game.winner == P, "sweep: one pirate chest aboard their ship loses the island")
	_check(Campaign.goal_text(1).contains("every pirate") and Campaign.rules(1).any(func(r: String) -> bool: return r.contains("All or nothing")), "sweep: the island card says what it takes")
	_free_game(game)

	# Charted islands, the Golden Rooster.
	g = TerrainGrid.new(4242)
	game = _computer_game(g)
	game.reveal_all(N)
	_check(game.revealed[N].size() == g.width * g.height and game.revealed[P].size() < g.width * g.height, "charted: the whole island is mapped for the NAVS only")
	_check(game.refresh_captains().is_empty(), "rooster: no flag before the campaign is won")
	for i in Campaign.FINAL:
		Campaign.win(i)
	_check(Campaign.win(Campaign.FINAL) and Campaign.is_captain() and not Campaign.win(Campaign.FINAL), "rooster: winning Treasure Island makes you a Captain, once")
	_check(game.refresh_captains() == [N] and game.snapshot(P).captains == [N], "rooster: your ship flies it, and everyone's told")
	Campaign.reset()
	_check(Campaign.is_captain() and Campaign.won_count() == 0, "rooster: starting the islands over keeps it")
	_free_game(game)
	Campaign.add_records([{"name": "Bering", "tally": {"found": 2, "aboard": 1, "captures": 1}}])
	Campaign.add_records([{"name": "Bering", "tally": {"found": 1, "aboard": 2, "captures": 0}}])
	var rec := Campaign.record("Bering")
	_check(int(rec.aboard) == 3 and int(rec.islands) == 2 and int(rec.captures) == 1, "campaign: each sailor's record adds up for the credits")

	GameConfig.reset()
	GameConfig.mode = mode_before
	Campaign.reset(true)
	Campaign.path = path_before

## A single-player game on `g`: five NAVS, five computer PIRATES, nobody
## running on the engine's clock (the test ticks it with _sim).
func _computer_game(g: TerrainGrid) -> GameServer:
	var people: Array[Character] = []
	var kinds := [CharacterStats.Kind.SCOUT, CharacterStats.Kind.DIGGER,
		CharacterStats.Kind.RUNNER, CharacterStats.Kind.FIGHTER, CharacterStats.Kind.SWORDSMAN]
	for team in [Character.Team.NAVS, Character.Team.PIRATES]:
		var ship: Vector2i = g.nav_ship if team == Character.Team.NAVS else g.pirate_ship
		var spots := g.landing_cells(ship, kinds.size())
		for i in kinds.size():
			var c := Character.new()
			add_child(c)
			c.setup(spots[i], CharacterStats.make(kinds[i], "C%d-%d" % [team, i]), team)
			people.append(c)
	var game := GameServer.new()
	game.mode = GameConfig.Mode.COMPUTER
	add_child(game)
	game.setup(g, people)
	game.rng.seed = 999
	game.set_process(false)
	var cpu := ComputerPlayer.new()
	cpu.server = game
	add_child(cpu)
	cpu.set_process(false)
	game.set_meta("cpu", cpu)
	return game

func _free_game(game: GameServer) -> void:
	for c in game.characters:
		c.queue_free()
	(game.get_meta("cpu") as Node).queue_free()
	game.queue_free()

## Runs the game and the computer for up to `seconds` of game time in 50 ms
## steps, stopping early once `until` is true. Returns the time taken.
func _sim(game: GameServer, cpu: ComputerPlayer, seconds: float, until := Callable()) -> float:
	var t := 0.0
	while t < seconds:
		if until.is_valid() and until.call():
			break
		cpu._process(0.05)
		game._process(0.05)
		t += 0.05
	return t

## Two neighbouring open squares away from everyone.
func _open_pair(g: TerrainGrid, duo: GameServer) -> Array:
	for y in range(2, g.height - 2):
		for x in range(2, g.width - 3):
			var a := Vector2i(x, y)
			var b := Vector2i(x + 1, y)
			if g.is_meadow(a) and g.is_meadow(b) and duo._occupant(a) == null and duo._occupant(b) == null:
				return [a, b]
	return []

func _free_near(duo: GameServer, g: TerrainGrid, from: Vector2i, dist: int) -> Vector2i:
	for n in g.neighbours(from):
		for m in g.neighbours(n):
			if duo._occupant(m) == null and m != from:
				return m
	return from

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

## Issues a move order the way a player does, then waits out the march.
func _walk_to(target: Vector2i, max_frames := 2000) -> bool:
	if server.active.cell == target:
		return true
	server.request_move_order(Character.Team.NAVS, target)
	if server.active.path.is_empty():
		return false
	var frames := 0
	while not server.active.path.is_empty() and frames < max_frames:
		frames += 1
		await get_tree().process_frame
	return server.active.cell == target

## The setup screen's choices must actually reach the expedition.
func _test_team_makeup() -> void:
	var saved := GameConfig.nav_counts.duplicate()
	GameConfig.crew = []
	GameConfig.nav_counts = {
		CharacterStats.Kind.SCOUT: 2,
		CharacterStats.Kind.DIGGER: 0,
		CharacterStats.Kind.RUNNER: 3,
		CharacterStats.Kind.FIGHTER: 1,
		CharacterStats.Kind.SWORDSMAN: 0,
	}
	_check(GameConfig.team_size() == 6, "team size counts every class chosen")
	var roster := GameConfig.build_roster()
	_check(roster.size() == 6, "roster has one entry per chosen member")
	var tally := {}
	var names := {}
	for entry in roster:
		tally[entry[0]] = int(tally.get(entry[0], 0)) + 1
		names[entry[1]] = true
	_check(int(tally.get(CharacterStats.Kind.RUNNER, 0)) == 3, "three Runners were chosen, three appear")
	_check(int(tally.get(CharacterStats.Kind.SCOUT, 0)) == 2, "two Scouts were chosen, two appear")
	_check(not tally.has(CharacterStats.Kind.DIGGER), "a class set to zero brings nobody")
	_check(names.size() == roster.size(), "every member gets their own name")
	# An empty team would leave nothing to play, so it falls back to one person.
	GameConfig.nav_counts = {}
	_check(GameConfig.build_roster().size() >= 1, "an empty roster still yields someone to play")
	GameConfig.nav_counts = saved
	# Counts arriving over the network are cleaned before use.
	var dirty := GameConfig.sanitize_counts({CharacterStats.Kind.SCOUT: 99, "junk": 3, CharacterStats.Kind.RUNNER: "x"})
	_check(int(dirty[CharacterStats.Kind.SCOUT]) == GameConfig.MAX_TEAM_SIZE and int(dirty[CharacterStats.Kind.RUNNER]) == 0
		and not dirty.has("junk"), "roster counts from the network are sanitised")

## Generated islands must always be playable, whatever seed comes up.
func _test_island_generation() -> void:
	var seeds := [1, 7, 99, 1234, 55555, 987654]
	var all_ok := true
	for job in seeds.size() * 3:
		var sv: int = seeds[job % seeds.size()]
		var length: int = job / seeds.size()
		var g := TerrainGrid.new(sv, length)
		var land := 0
		for y in g.height:
			for x in g.width:
				if g.cells[y][x] != TerrainGrid.WATER:
					land += 1
		var ok := land >= g.width * g.height * 0.13
		ok = ok and g.markers.size() == TerrainGrid.CHESTS[length]
		ok = ok and g.is_walkable(g.nav_ship) and g.is_walkable(g.pirate_ship)
		# Every marker must have somewhere to bury a chest, and be reachable
		# from the ship — otherwise the island is unwinnable.
		for m in g.markers:
			var has_spot := false
			for n in g.neighbours(m):
				if g.is_meadow(n):
					has_spot = true
					break
			ok = ok and has_spot
			ok = ok and not g.find_path(g.nav_ship, m).is_empty()
		ok = ok and not g.find_path(g.nav_ship, g.pirate_ship).is_empty()
		# With woodland solid, every walkable square must still be one region.
		var walkable := 0
		var reached := {}
		var start := g.nav_ship
		var q: Array[Vector2i] = [start]
		reached[start] = true
		var h := 0
		while h < q.size():
			var cur: Vector2i = q[h]
			h += 1
			for n in g.neighbours(cur):
				if not reached.has(n):
					reached[n] = true
					q.append(n)
		for yy in g.height:
			for xx in g.width:
				if g.is_walkable(Vector2i(xx, yy)):
					walkable += 1
		if reached.size() != walkable:
			ok = false
			print("    island #%d has walkable ground cut off (%d of %d reachable)"
				% [sv, reached.size(), walkable])
		# The landing party must not box itself in on a narrow spit: with the
		# biggest crew standing there, everyone still needs somewhere to step.
		var spots := g.landing_cells(g.nav_ship, GameConfig.MAX_TEAM_SIZE)
		ok = ok and spots.size() == GameConfig.MAX_TEAM_SIZE
		var taken := {}
		for sp in spots:
			taken[sp] = true
		for sp in spots:
			var free := false
			for n in g.neighbours(sp):
				if not taken.has(n):
					free = true
					break
			if not free:
				ok = false
				print("    island #%d boxes in a landing spot at %s" % [sv, sp])
		if not ok:
			all_ok = false
			print("    island #%d (%s) FAILED: land=%d markers=%d" % [sv, TerrainGrid.LENGTH_NAMES[length], land, g.markers.size()])
		# The same seed must rebuild the same island, or networked players desync.
		var again := TerrainGrid.new(sv, length)
		if again.cells != g.cells or again.markers != g.markers:
			all_ok = false
			print("    island #%d is NOT deterministic" % sv)
	_check(all_ok, "generated islands are playable and deterministic (%d seeds x short, medium, long)" % seeds.size())
	var short := TerrainGrid.new(5, TerrainGrid.Length.SHORT)
	var long := TerrainGrid.new(5, TerrainGrid.Length.LONG)
	_check(short.width < long.width and short.markers.size() == 3 and long.markers.size() == 7,
		"a long game's island is bigger and holds more chests (%dx%d, %d vs %dx%d, %d)" % [
			short.width, short.height, short.markers.size(), long.width, long.height, long.markers.size()])
	# Different seeds must actually give different islands.
	var a := TerrainGrid.new(1)
	var b := TerrainGrid.new(2)
	_check(a.cells != b.cells, "different seeds give different islands")

func _find_tile(tile: int) -> Vector2i:
	for y in grid.height:
		for x in grid.width:
			if grid.cells[y][x] == tile:
				return Vector2i(x, y)
	return Vector2i.ZERO

## A reachable, unoccupied square a few steps away — found by walking the map,
## since on a generated island a fixed offset may well be open sea.
func _open_cell_near(from: Vector2i, dist: int) -> Vector2i:
	var seen := {from: true}
	var queue: Array[Vector2i] = [from]
	var head := 0
	var steps := 0
	var best := from
	while head < queue.size() and steps < 60:
		var cur: Vector2i = queue[head]
		head += 1
		steps += 1
		if cur != from and server._occupant(cur) == null:
			best = cur
			if absi(cur.x - from.x) + absi(cur.y - from.y) >= dist:
				return cur
		for n in grid.neighbours(cur):
			if not seen.has(n):
				seen[n] = true
				queue.append(n)
	return best

func _check(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
	print(("  [PASS] " if cond else "  [FAIL] "), label)

# --- three and four crews --------------------------------------------------

## Bigger islands with more chests and a ship per crew, still playable and
## still the same island from the same seed.
func _test_many_crew_islands() -> void:
	var all_ok := true
	for sv in [3, 77, 4242, 31337]:
		for teams in [3, 4]:
			for length in [TerrainGrid.Length.SHORT, TerrainGrid.Length.MEDIUM]:
				var g := TerrainGrid.new(sv, length, teams)
				var ok := g.width == TerrainGrid.island_size(length, teams).x
				ok = ok and g.markers.size() == TerrainGrid.chest_count(length, teams)
				ok = ok and g.ships.size() == teams
				var spots := {}
				for ship in g.ships:
					ok = ok and g.is_walkable(ship) and not spots.has(ship)
					spots[ship] = true
					ok = ok and g.landing_cells(ship, GameConfig.MAX_TEAM_SIZE).size() == GameConfig.MAX_TEAM_SIZE
					for m in g.markers:
						ok = ok and not g.find_path(ship, m).is_empty()
				var again := TerrainGrid.new(sv, length, teams)
				ok = ok and again.cells == g.cells and again.markers == g.markers and again.ships == g.ships
				if not ok:
					all_ok = false
					print("    island #%d for %d crews (%s) FAILED" % [sv, teams, TerrainGrid.LENGTH_NAMES[length]])
	_check(all_ok, "three- and four-crew islands are playable and deterministic")
	var two := TerrainGrid.new(9, TerrainGrid.Length.MEDIUM, 2)
	var four := TerrainGrid.new(9, TerrainGrid.Length.MEDIUM, 4)
	_check(four.width * four.height > two.width * two.height * 2 and four.markers.size() > two.markers.size() * 2,
		"four crews get a much bigger island (%dx%d vs %dx%d) and more chests (%d vs %d)" % [
			four.width, four.height, two.width, two.height, four.markers.size(), two.markers.size()])
	_check(TerrainGrid.new(9).cells == two.cells and TerrainGrid.new(9).ships == two.ships,
		"two-crew islands are unchanged by the bigger ones")
	var ships := four.ships
	_check(ships[0].y > ships[1].y and ships[2].x < ships[3].x,
		"four ships take a side each: NAVS south, Pirates north, Corsairs west, Buccaneers east")

## A four-crew game on one computer, `ctrl` saying who sails each crew.
func _crews_game(teams: int, per_team: int, ctrl: Array = [], sv := 31337) -> GameServer:
	var g := TerrainGrid.new(sv, TerrainGrid.Length.SHORT, teams)
	var people: Array[Character] = []
	var kinds := [CharacterStats.Kind.SWORDSMAN, CharacterStats.Kind.DIGGER, CharacterStats.Kind.SCOUT,
		CharacterStats.Kind.RUNNER, CharacterStats.Kind.FIGHTER]
	for team in teams:
		var spots := g.landing_cells(g.ships[team], per_team)
		for i in per_team:
			var c := Character.new()
			add_child(c)
			c.setup(spots[i], CharacterStats.make(kinds[i % kinds.size()], "M%d-%d" % [team, i]), team)
			people.append(c)
	var game := GameServer.new()
	game.mode = GameConfig.Mode.HOTSEAT
	game.ctrl = ctrl
	add_child(game)
	game.setup(g, people)
	game.rng.seed = 4321
	game.set_process(false)
	return game

func _free_crews_game(game: GameServer) -> void:
	for c in game.characters:
		c.queue_free()
	for n in game.get_children():
		n.queue_free()
	game.queue_free()

## Turns, winning, draws, crews being wiped out, and each crew's own view.
func _test_many_crew_rules() -> void:
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	var C := Character.Team.CORSAIRS
	var B := Character.Team.BUCCANEERS
	var game := _crews_game(4, 3)
	_check(game.team_count == 4 and game.characters.size() == 12 and game.ships.size() == 4,
		"four crews of three on the island, a ship each")
	_check(game.characters[6].team_color != game.characters[9].team_color
		and game.characters[6].team_color != game.characters[0].team_color, "every crew has its own colours")
	_check(game.revealed.size() == 4 and game.revealed[C].size() > 0 and not game.revealed[N].has(game.ships[B]),
		"every crew has its own fog")

	# --- turn order ---
	var turn_before := game.turn
	var order := [game.current_team]
	for i in 4:
		game.request_end_turn(game.current_team)
		order.append(game.current_team)
	_check(order == [N, P, C, B, N] and game.turn == turn_before + 1,
		"turns go NAVS, Pirates, Corsairs, Buccaneers, and the round counts once all have moved")
	_check(game.viewer_team() == N, "sharing a computer: the screen follows the turn")
	var corsair: Character = game._members(C)[0]
	corsair.energy = 10.0
	game.request_end_turn(N)
	game.request_end_turn(P)
	_check(is_equal_approx(corsair.energy, 10.0 + corsair.stats.stamina), "a crew rests as its own turn begins")
	game.request_end_turn(P)
	_check(game.current_team == C, "a crew can't end someone else's turn")

	# --- winning once nobody can catch you ---
	var total := game.chests_total
	_check(total == TerrainGrid.chest_count(TerrainGrid.Length.SHORT, 4), "%d chests for four crews on a short island" % total)
	game.delivered = [3, 1, 1, 0]
	var left := game.chests_left()
	_check(left == total - 5, "chests still out are counted (%d)" % left)
	_check(not game._check_victory() and not game.won, "a lead that can still be caught doesn't win yet")
	var need := game.chests_to_win(N)
	_check(need >= 1 and need <= left, "the NAVS are told they need %d more" % need)
	game.delivered = [3 + need, 1, 1, 0]
	_check(game._check_victory() and game.won and game.winner == N,
		"once no rival can pass you, you've won (%d of %d, nobody can catch them)" % [3 + need, total])
	_free_crews_game(game)

	# A draw: every chest aboard and the leaders level.
	game = _crews_game(4, 2)
	var t := game.chests_total
	var lead := (t - 1) / 2
	game.delivered = [lead, lead, t - 2 * lead, 0]
	_check(game._check_victory() and game.won and game.winner == GameServer.DRAW,
		"all chests aboard with the leaders level is a draw (%s)" % str(game.delivered))
	_free_crews_game(game)

	# --- crews wiped out ---
	game = _crews_game(4, 2)
	for c in game._members(C):
		c.captured = true
	game._check_wipeout()
	_check(not game.won and game.alive_teams() == [N, P, B], "a crew with nobody left is out, the rest play on")
	game.request_end_turn(N)
	game.request_end_turn(P)
	_check(game.current_team == B, "the turn skips a crew that's been wiped out")
	game.delivered = [0, 0, 2, 0]
	var gone_need := game.chests_to_win(N)
	_check(gone_need >= 3, "a crew that's out can still hold the record to beat (need %d)" % gone_need)
	game.delivered = [0, 0, 0, 0]
	for c in game._members(B):
		c.captured = true
	game._check_wipeout()
	_check(not game.won and game.current_team == N, "a crew wiped out on its own turn hands the turn on")
	for c in game._members(P):
		c.captured = true
	game._check_wipeout()
	_check(game.won and game.winner == N and game.win_reason == "every rival crew was captured",
		"the last crew standing wins")
	_free_crews_game(game)

	# --- each crew sees only its own picture ---
	game = _crews_game(3, 2)
	var att: Character = game._members(N)[0]
	var dfn: Character = game._members(P)[0]
	game.duel = {"a": att.id, "d": dfn.id, "ac": Combat.Choice.AGGRESSIVE, "dc": -1, "t": 0.0}
	var for_corsairs := game.snapshot(C)
	var for_pirates := game.snapshot(P)
	_check(int(for_corsairs.duel.ac) == 0 and int(for_pirates.duel.ac) == 0,
		"nobody but the attacker learns how they chose to attack")
	_check(str(game._default_status(C)).contains("somewhere") or str(game._default_status(C)).contains("crossing"),
		"a crew outside the fight is told only that swords are out")
	game.duel = {}
	game.status[C] = "corsair news"
	_check(game.snapshot(C).status == "corsair news" and game.snapshot(C).revealed == game._pack(game.revealed[C]),
		"a guest's snapshot carries their own crew's status and fog")
	var mirror_people: Array[Character] = []
	for c in game.characters:
		var m := Character.new()
		add_child(m)
		m.setup(c.cell, CharacterStats.make(c.stats.kind, c.stats.person_name), c.team)
		mirror_people.append(m)
	var mirror := GameServer.new()
	mirror.mode = GameConfig.Mode.GUEST
	mirror.is_authority = false
	mirror.guest_team = C
	add_child(mirror)
	mirror.setup(game.grid, mirror_people)
	mirror.apply_state(game.snapshot(C))
	_check(mirror.revealed[C].size() == game.revealed[C].size() and mirror.status[C] == "corsair news",
		"the Corsairs' guest gets the Corsairs' fog and status")
	var snap := game.snapshot(C)
	snap.erase("revealed")
	mirror.apply_state(snap)
	_check(mirror.revealed[C].size() == game.revealed[C].size(), "fog left out of a snapshot (unchanged) is kept")
	for m in mirror_people:
		m.queue_free()
	mirror.queue_free()
	_free_crews_game(game)

	# --- sharing a computer with computer crews ---
	var H := GameConfig.Ctrl.HUMAN
	var X := GameConfig.Ctrl.COMPUTER
	game = _crews_game(4, 2, [H, X, H, X])
	_check(game.human_count() == 2 and game.is_local_team(C) and not game.is_local_team(P),
		"two people and two computer crews at one computer")
	game.request_end_turn(N)
	_check(game.current_team == P and game.viewer_team() == N, "on the computer's turn the screen stays with the last person")
	game.request_end_turn(P)
	_check(game.viewer_team() == C, "and moves on to the next person when it's their turn")
	game.hand_to_computer(C)
	_check(game.is_computer(C) and game.human_count() == 1, "a crew can be handed to the computer mid-game")
	_free_crews_game(game)

## GameConfig with several crews: names, who sails what, matches and coaching.
func _test_many_crew_config() -> void:
	var saved_mode := GameConfig.mode
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOTSEAT
	GameConfig.team_count = 4
	_check(GameConfig.build_roster(2)[0][1] in GameConfig.CORSAIR_NAMES
		and GameConfig.build_roster(3)[0][1] in GameConfig.BUCCANEER_NAMES,
		"the Corsairs and Buccaneers have names of their own")
	_check(GameConfig.ctrl_of(1) == GameConfig.Ctrl.HUMAN and GameConfig.human_teams() == [0, 1, 2, 3],
		"sharing a computer: every crew is a person unless you say otherwise")
	GameConfig.controllers[3] = GameConfig.Ctrl.COMPUTER
	_check(GameConfig.is_computer(3) and GameConfig.has_computer_crews(), "a crew can be given to the computer")
	GameConfig.mode = GameConfig.Mode.HOST
	_check(GameConfig.ctrl_of(1) == GameConfig.Ctrl.FRIEND and GameConfig.ctrl_of(3) == GameConfig.Ctrl.COMPUTER,
		"hosting: the other crews are friends online, or the computer")
	GameConfig.mode = GameConfig.Mode.COMPUTER
	_check(GameConfig.ctrl_of(0) == GameConfig.Ctrl.HUMAN and GameConfig.ctrl_of(1) == GameConfig.Ctrl.COMPUTER,
		"single player: the computer sails every other crew")

	GameConfig.mode = GameConfig.Mode.HOST
	GameConfig.new_match()
	_check(GameConfig.match_score == [0, 0, 0, 0] and GameConfig.first_team() == 0,
		"a four-crew match keeps four scores, and the NAVS start the first game")
	var crews := []
	for t in 4:
		crews.append([])
		for r in GameConfig.build_roster(t):
			crews[t].append(CharacterStats.make(r[0], r[1]))
	GameConfig.end_game_in_match(crews, 2, [1, 0, 3, 0])
	_check(GameConfig.match_score == [0, 0, 1, 0] and not bool(GameConfig.match_coached[0])
		and not bool(GameConfig.match_coached[2]), "four crews' coaching: every crew gets a round, winner or not")
	_check(bool(GameConfig.match_coached[3]) and not GameConfig.match_note[3].is_empty() and bool(GameConfig.match_ready[3])
		and not bool(GameConfig.match_ready[1]), "a computer crew coaches itself and is ready at once")
	_check(GameConfig.first_team() == 1, "the next game, the Pirates move first")
	_check(not GameConfig.all_ready(), "the next game waits for every person")
	for t in 4:
		GameConfig.match_ready[t] = true
	_check(GameConfig.all_ready(), "and goes once they're all ready")
	var state := GameConfig.match_state().duplicate(true)
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	GameConfig.apply_match_state(state)
	_check(GameConfig.team_count == 4 and GameConfig.match_score == [0, 0, 1, 0] and GameConfig.is_computer(3)
		and GameConfig.match_games == 1, "a guest's copy of a four-crew match takes the host's word")
	GameConfig.reset()
	GameConfig.mode = saved_mode

## Three computer crews against NAVS who only end their turns: the computer
## crews take their turns in order, fight each other, and one of them wins.
func _test_many_crew_computer() -> void:
	var N := Character.Team.NAVS
	var X := GameConfig.Ctrl.COMPUTER
	var game := _crews_game(4, 3, [GameConfig.Ctrl.HUMAN, X, X, X], 4242)
	game.mode = GameConfig.Mode.COMPUTER
	var cpus: Array[ComputerPlayer] = []
	for t in range(1, 4):
		var cpu := ComputerPlayer.new()
		cpu.server = game
		cpu.team = t
		game.add_child(cpu)
		cpu.set_process(false)
		cpus.append(cpu)
	var seen_turns := {}
	var rounds := 0
	while not game.won and rounds < 120:
		game.request_end_turn(N)
		var t := 0.0
		while t < 1200.0 and game.current_team != N and not game.won:
			seen_turns[game.current_team] = true
			for cpu in cpus:
				cpu._process(0.05)
			game._process(0.05)
			t += 0.05
		rounds += 1
	_check(seen_turns.size() == 3, "each computer crew takes its own turn")
	_check(game.won and (game.winner > 0 or game.winner == GameServer.DRAW),
		"three computer crews play a four-crew game to the end (round %d, %s, winner %d)" % [
			rounds, str(game.delivered), game.winner])
	_check(game.won and int(game.delivered[N]) == 0, "and nobody plays the NAVS' side for them")
	_free_crews_game(game)

## An online match saved between games (a campaign): it keeps its own slot,
## the score and crews, and who sailed which crew, and a crew the computer
## took over when its player left is a seat for them again.
func _test_online_save() -> void:
	var saved_mode := GameConfig.mode
	var saved_path := GameConfig.online_save_path
	GameConfig.online_save_path = "user://smoke_test_online.cfg"
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOST
	GameConfig.team_count = 3
	GameConfig.team_target = 4
	GameConfig.new_match()
	GameConfig.match_score = [1, 2, 0]
	GameConfig.match_games = 3
	GameConfig.controllers[2] = GameConfig.Ctrl.COMPUTER # their player left
	GameConfig.seat_owners = {1: "aaaa", 2: "bbbb"}
	_check(GameConfig.can_save() and GameConfig.save_slot() == GameConfig.online_save_path,
		"a host can save an online match, in a slot of its own")
	GameConfig.save_match()
	_check(GameConfig.save_summary(GameConfig.online_save_path).contains("Pirates 2"),
		"the menu can say what the saved match is: %s" % GameConfig.save_summary(GameConfig.online_save_path))
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.COMPUTER
	_check(GameConfig.load_game(GameConfig.online_save_path) and GameConfig.mode == GameConfig.Mode.HOST
		and GameConfig.team_count == 3 and GameConfig.team_target == 4 and GameConfig.match_games == 3
		and GameConfig.resume.is_empty(), "a match saved between games loads, ready for a new island")
	_check(str(GameConfig.seat_owners.get(1, "")) == "aaaa" and GameConfig.ctrl_of(2) == GameConfig.Ctrl.FRIEND,
		"each crew remembers whose it was, and a crew the computer took over is theirs again")
	var me := GameConfig.player_id()
	_check(me.length() >= 8 and GameConfig.player_id() == me, "this copy has a player id, and keeps it")
	GameConfig.delete_save(GameConfig.online_save_path)
	GameConfig.online_save_path = saved_path
	GameConfig.reset()
	GameConfig.mode = saved_mode

## Every class recovers the same energy on every crew, whether it's sailed at
## this computer or by a friend online (players asked whether the Pirates
## were weaker).
func _test_equal_crews() -> void:
	var game := _crews_game(2, 5, [GameConfig.Ctrl.HUMAN, GameConfig.Ctrl.FRIEND])
	game.mode = GameConfig.Mode.HOST
	for c in game.characters:
		c.energy = 10.0
	game.request_end_turn(Character.Team.NAVS)    # the Pirates rest
	game.request_end_turn(Character.Team.PIRATES) # then the NAVS
	var same := true
	for i in 5:
		var nav: Character = game.characters[i]
		var pirate: Character = game.characters[5 + i]
		if nav.stats.kind != pirate.stats.kind or not is_equal_approx(nav.energy, pirate.energy) \
				or not is_equal_approx(nav.stats.stamina, pirate.stats.stamina):
			same = false
	_check(same and game.characters[0].energy > 10.0 and game.turn == 2,
		"a NAVS and a Pirate of the same class recover exactly the same each turn")
	_free_crews_game(game)

## A dedicated server's rules: no crew of its own, every crew (the NAVS too) a
## player online or the computer, and computer crews of the server's size.
func _test_dedicated_server() -> void:
	var saved_mode := GameConfig.mode
	var F := GameConfig.Ctrl.FRIEND
	var X := GameConfig.Ctrl.COMPUTER
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.SERVER
	GameConfig.team_count = 4
	GameConfig.controllers[3] = X
	_check(GameConfig.ctrl_of(0) == F and GameConfig.ctrl_of(1) == F and GameConfig.ctrl_of(3) == X,
		"a dedicated server: the NAVS too are a player online, unless the computer sails them")
	_check(GameConfig.in_match() and not GameConfig.can_save() and not GameConfig.uses_crew(),
		"a dedicated server plays matches, saves nothing and keeps no crew of its own")
	var five := GameConfig.balanced_counts(5)
	_check(GameConfig.team_size(five) == 5 and five.values().all(func(n: Variant) -> bool: return int(n) == 1),
		"a balanced five is one of each class")
	GameConfig.team_target = 7
	var model := GameConfig.computer_counts()
	_check(GameConfig.team_size(model) == 7 and int(model[CharacterStats.Kind.FIGHTER]) == 2
		and int(model[CharacterStats.Kind.DIGGER]) == 1, "a server's computer crews are balanced, at the server's crew size")
	_check(Net.first_seat() == 1, "offline, the first seat for a friend is still the Pirates'")

	var g := TerrainGrid.new(2468, TerrainGrid.Length.SHORT, 2)
	var people: Array[Character] = []
	for team in 2:
		var spots := g.landing_cells(g.ships[team], 2)
		for i in 2:
			var c := Character.new()
			add_child(c)
			c.setup(spots[i], CharacterStats.make(CharacterStats.Kind.FIGHTER, "S%d-%d" % [team, i]), team)
			people.append(c)
	var game := GameServer.new()
	game.mode = GameConfig.Mode.SERVER
	game.ctrl = [F, F]
	add_child(game)
	game.set_process(false)
	game.setup(g, people)
	_check(not game.started, "a server's game waits for its players to come ashore")
	_check(not game.is_local_team(0) and not game.is_local_team(1) and game.remote_teams() == [0, 1],
		"no crew is sailed on the server itself: both are sent their own view")
	var snap := game.snapshot(0)
	_check(snap.has("revealed") and snap.status is String, "the NAVS' player gets a snapshot like anyone else")
	game.hand_to_computer(0)
	_check(game.is_computer(0), "a NAVS player who leaves a server's game is replaced by the computer")
	_free_crews_game(game)
	var hosted := _crews_game(2, 2, [GameConfig.Ctrl.HUMAN, F])
	hosted.hand_to_computer(0)
	_check(hosted.is_person(0), "elsewhere the NAVS stay with the person at this computer")
	_free_crews_game(hosted)
	GameConfig.reset()
	GameConfig.mode = saved_mode

## Play on a Server: reading Tailscale's list of machines, and the question a
## server list asks and a server's answer (ServerFinder).
func _test_server_list() -> void:
	var status := JSON.stringify({
		"BackendState": "Running",
		"Self": {"HostName": "DevMac", "DNSName": "devmac.tail.ts.net.", "TailscaleIPs": ["100.64.0.1", "fd7a::1"], "Online": true},
		"Peer": {
			"a": {"HostName": "Homeserver", "DNSName": "homeserver.tail.ts.net.", "TailscaleIPs": ["100.64.0.2", "fd7a::2"], "Online": true},
			"b": {"HostName": "asleep", "TailscaleIPs": ["100.70.0.1"], "Online": false},
			"c": {"HostName": "v6only", "TailscaleIPs": ["fd7a::3"], "Online": true},
			"d": {"HostName": "localhost", "DNSName": "phone.tail.ts.net.", "TailscaleIPs": ["100.64.0.3"], "Online": true},
			"e": {"HostName": "[b]shared[/b]", "TailscaleIPs": ["100.64.0.4"], "Online": true},
		}})
	var listed := ServerFinder.peers_from_status(status)
	var names: Array = listed.peers.map(func(p: Dictionary) -> String: return "%s@%s" % [p.name, p.ip])
	names.sort()
	_check(listed.note == "" and names == ["DevMac@100.64.0.1", "Homeserver@100.64.0.2", "bshared/b@100.64.0.4", "phone@100.64.0.3"],
		"server list: Tailscale's online machines (this one too), by name and 100.x address: %s" % str(names))
	var off := ServerFinder.peers_from_status(JSON.stringify({"BackendState": "Stopped", "Peer": {}}))
	_check(off.peers.is_empty() and off.note.contains("switched off"), "server list: Tailscale switched off is said so")
	_check(ServerFinder.peers_from_status("not json").note != "", "server list: an unreadable answer from Tailscale is said so")
	var q := ServerFinder.query_packet()
	_check(q.size() == ServerFinder.QUERY_SIZE and ServerFinder.is_query(q) and not ServerFinder.is_query(q.slice(0, 40)),
		"server list: the question is padded, and a short one isn't answered")
	var info := {"game": "pirates-plunder", "v": "0.8.0", "p": Net.PROTOCOL, "id": "abc", "name": "Homeserver", "port": 24680,
		"state": "setup", "lobby": "players", "leader": "[i]Ana[/i]", "crews": 9, "people": 3, "taken": 2, "open": 1,
		"length": 0, "mine": [{"id": "ab12cd34", "s": "Game 2, turn 5, with [b]Ana[/b]"}], "players": ["Ana", "Sam"], "most": 4,
		"defaults": {"crews": 2, "size": 5, "length": 1, "difficulty": 1}}
	var back := ServerFinder.parse_reply(ServerFinder.make_reply(info))
	_check(back.state == "setup" and back.v == "0.8.0" and back.name == "Homeserver" and int(back.open) == 1 and back.players == ["Ana", "Sam"],
		"server list: a server's answer reads back")
	_check(back.leader == "iAna/i" and int(back.crews) == 4, "server list: names lose their BBCode, and numbers are kept in range")
	_check(back.mine.size() == 1 and back.mine[0].id == "ab12cd34" and back.mine[0].s == "Game 2, turn 5, with bAna/b",
		"server list: the asker's saved games read back, without BBCode")
	_check(ServerFinder.query_key(q) == ServerFinder.back_key(GameConfig.player_id()) and ServerFinder.query_key(PackedByteArray([80, 80, 81, 49])) == "",
		"server list: the question carries the asker's fingerprint (and an old one carries none)")
	var crowd := info.duplicate(true)
	crowd.players = ["A very long name one", "A very long name two", "A very long name tri", "A very long name for"]
	crowd.mine = [{"id": "a", "s": "x".repeat(60)}, {"id": "b", "s": "y".repeat(60)}, {"id": "c", "s": "z".repeat(60)}]
	crowd.name = "n".repeat(40)
	var big := ServerFinder.make_reply(crowd)
	_check(big.size() <= ServerFinder.REPLY_LIMIT and big.size() < ServerFinder.QUERY_SIZE and not ServerFinder.parse_reply(big).is_empty(),
		"server list: an answer is never bigger than the question (%d bytes)" % big.size())
	var wrong := info.duplicate(true)
	wrong.game = "something else"
	_check(ServerFinder.parse_reply(ServerFinder.make_reply(wrong)).is_empty() and ServerFinder.parse_reply("PPQ1{}".to_utf8_buffer()).is_empty(),
		"server list: answers from anything else are ignored")
	var odd := info.duplicate(true)
	odd.state = "exploded"
	_check(ServerFinder.parse_reply(ServerFinder.make_reply(odd)).is_empty(), "server list: an answer in an unknown state is ignored")
	_check(GameConfig.clean_name("  [b]Captain[/b] of the seven seas, no less ") == "bCaptain/b of the se",
		"player names: printable, no brackets, at most 20 characters")

## 2v2: two sides of two. Partners don't fight, share sight, hand each other
## chests and load them on either ship, and their chests add up.
func _test_two_v_two() -> void:
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	var C := Character.Team.CORSAIRS
	var B := Character.Team.BUCCANEERS
	_check(GameConfig.sides_for(C, 4) == [0, 1, 0, 1] and GameConfig.sides_for(P, 4) == [0, 0, 1, 1]
		and GameConfig.sides_for(C, 3).is_empty() and GameConfig.sides_for(GameConfig.FREE_FOR_ALL, 4).is_empty(),
		"2v2: the NAVS and the crew they pick are one side, the other two the other; only with four crews")
	var game := _crews_game(4, 2)
	game.sides = [0, 1, 0, 1]
	game._refresh_vision()
	_check(game.allies(N, C) and game.allies(P, B) and not game.allies(N, P) and game.rivals(N) == [P, B]
		and game.partners(N) == [C] and game.side_name(N) == "NAVS and the Corsairs",
		"2v2: the NAVS' partner is the Corsairs; their rivals are the Pirates and Buccaneers")
	var nav: Character = game._members(N)[0]
	var cor: Character = game._members(C)[0]
	_check(game.seen[N].has(cor.id) and game.seen[C].has(nav.id), "2v2: partners' people are always in sight")
	_check(game.revealed[N].has(cor.cell) and game.revealed[C].has(nav.cell), "2v2: what one partner sees, the other sees")
	# Walking into a partner is no fight: they're stepped round.
	var pair := _open_pair(game.grid, game)
	_place(nav, pair[0])
	_place(cor, pair[1])
	nav.path.assign([cor.cell])
	nav.step_timer = 0.0
	game.current_team = N
	game._follow_path(nav, 0.1)
	_check(game.duel.is_empty() and nav.cell != cor.cell, "2v2: walking into a partner starts no sword fight")
	# Hand a chest to a partner's sailor, who loads it on the NAVS' ship.
	_place(nav, pair[0])
	_place(cor, pair[1])
	nav.set_carrying(true)
	game.active_by_team[N] = nav
	game.request_offer(N, cor.cell)
	game.request_handoff(N, true)
	_check(cor.carrying and not nav.carrying and game.active_by_team[N] == nav,
		"2v2: a carrier can hand a chest to a partner's sailor")
	var ship: Vector2i = game.ships[N]
	game._check_deliver(cor, ship)
	_check(not cor.carrying and int(game.delivered[C]) == 1 and game.side_delivered(N) == 1 and game.side_delivered(P) == 0,
		"2v2: a Corsair can load it on the NAVS' ship; it counts for their side")
	# The win counts the side's chests together.
	var total := game.chests_total
	var half := total / 2
	game.delivered = [half, 0, 1, 0]
	_check(game._check_victory() and game.won and game.is_winner(C) and game.is_winner(N) and not game.is_winner(P),
		"2v2: partners' chests add up (%d + 1 of %d), and both partners win" % [half, total])
	_free_crews_game(game)
	# Capturing both rival crews wins for the side, though one partner is out too.
	game = _crews_game(4, 2)
	game.sides = [0, 0, 1, 1]
	for c in game._members(N) + game._members(C):
		c.captured = true
	game._check_wipeout()
	_check(not game.won, "2v2: one crew from each side out, the game goes on")
	for c in game._members(B):
		c.captured = true
	game._check_wipeout()
	_check(game.won and game.is_winner(P) and game.is_winner(N), "2v2: capture both rival crews and your side wins")
	_free_crews_game(game)
	# Four computer crews play a 2v2 to the end without crossing swords with a partner.
	var X := GameConfig.Ctrl.COMPUTER
	game = _crews_game(4, 3, [X, X, X, X], 4242)
	game.sides = [0, 1, 0, 1]
	game._refresh_vision()
	var cpus: Array[ComputerPlayer] = []
	for t in 4:
		var cpu := ComputerPlayer.new()
		cpu.server = game
		cpu.team = t
		game.add_child(cpu)
		cpu.set_process(false)
		cpus.append(cpu)
	var friendly_fight := false
	var clock := 0.0
	while not game.won and clock < 20000.0 and game.turn <= 120:
		for cpu in cpus:
			cpu._process(0.05)
		game._process(0.05)
		if not game.duel.is_empty() and game.allies(game.characters[int(game.duel.a)].team, game.characters[int(game.duel.d)].team):
			friendly_fight = true
		clock += 0.05
	_check(game.won and not friendly_fight and (game.winner >= 0 or game.winner == GameServer.DRAW),
		"2v2: four computer crews play it to the end, never fighting a partner (round %d, %s, sides %d v %d)" % [
			game.turn, str(game.delivered), game.side_delivered(0), game.side_delivered(1)])
	_free_crews_game(game)
	# A match: both partners score the win.
	var saved_mode := GameConfig.mode
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOTSEAT
	GameConfig.team_count = 4
	GameConfig.partner = C
	GameConfig.new_match()
	GameConfig.end_game_in_match([[], [], [], []], N, [1, 0, 1, 0])
	_check(GameConfig.match_score == [1, 0, 1, 0], "2v2: in a match both partners score the win")
	GameConfig.reset()
	GameConfig.mode = saved_mode

## The desktop window's first size: most of the screen, in the game's shape,
## centred, never below the smallest usable size.
## Check for Updates on the server list: which server to update from, and
## what it says when there's nothing newer.
func _test_check_for_updates() -> void:
	var SB: Script = load("res://scripts/server_browser.gd")
	var a := {"name": "homeserver", "machine": "homeserver", "v": "0.12.0", "address": "100.1.1.1"}
	var b := {"name": "", "machine": "vps", "v": "0.13.0", "address": "100.1.1.2"}
	var c := {"name": "old", "machine": "old", "v": "0.10.1", "address": "100.1.1.3"}
	_check(SB.update_source([a, b, c], "0.11.1").get("machine") == "vps", "updates: from the server with the newest version")
	_check(SB.update_source([a, c], "0.12.0").is_empty(), "updates: nothing to fetch when no server is newer")
	_check(SB.update_source([], "0.12.0").is_empty(), "updates: nothing to fetch with no servers")
	var text: String = SB.up_to_date_text([a, c], "0.12.0")
	_check(text.begins_with("You're up to date: you have version 0.12.0, the same as homeserver.") and text.contains("old (0.10.1)"),
		"updates: up to date, naming the same and the older servers: %s" % text)
	var browser: Control = load("res://scenes/ServerBrowser.tscn").instantiate()
	browser.set("scan_tailnet", false)
	add_child(browser)
	await _frames(2)
	_check(_button_texts(browser).has("Check for Updates"), "updates: the server list has a Check for Updates button")
	browser.queue_free()
	Net.leave()
	await _frames(2)

func _test_window_size() -> void:
	var W: Script = load("res://scripts/window_size.gd")
	var mac: Rect2i = W.first_rect(Rect2i(0, 25, 3024, 1890)) # a 14" MacBook Pro in pixels, below the menu bar
	_check(mac.size == Vector2i(2142, 1607) and mac.position == Vector2i(441, 166),
		"window: on a Retina Mac it opens at 85%% of the screen's height, centred (%s)" % str(mac))
	var hd: Rect2i = W.first_rect(Rect2i(0, 0, 1920, 1040)) # 1080p, above a taskbar
	_check(hd.size.y == 884 and absf(float(hd.size.x) / hd.size.y - 4.0 / 3.0) < 0.01 and Rect2i(0, 0, 1920, 1040).encloses(hd),
		"window: on a 1080p screen it keeps the game's shape and fits (%s)" % str(hd))
	var small: Rect2i = W.first_rect(Rect2i(0, 0, 1024, 700))
	_check(small.size == Vector2i(800, 600), "window: never smaller than 800x600 when the screen has room (%s)" % str(small))
	var tiny: Rect2i = W.first_rect(Rect2i(0, 0, 640, 480))
	_check(Rect2i(0, 0, 640, 480).encloses(tiny), "window: never bigger than the screen (%s)" % str(tiny))

## The main menu in pages: the first asks only how you want to play, each
## choice opens its own page with a way back, and the menu reopens on the
## page it was left from.
func _test_menu_pages() -> void:
	var MenuScript: Script = load("res://scripts/menu.gd")
	MenuScript.set("last_page", 0)
	var menu: Control = load("res://scenes/Menu.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	var home := _button_texts(menu)
	_check(home.has("Single Player") and home.has("Multiplayer") and home.has("Settings") and home.has("Quit")
		and not home.has("Practice Alone") and not home.has("Host a Game") and not home.has("Play on a Server"),
		"menu: the first page asks only how you want to play: %s" % str(home))
	_press(menu, "Single Player")
	await _frames(2)
	var single := _button_texts(menu)
	_check(single.has("Against the Computer") and single.has("Tutorial") and not single.has("Practice Alone") and single.has("Back") and not single.has("Multiplayer"),
		"menu: Single Player opens its own page: %s" % str(single))
	_press(menu, "Back")
	await _frames(2)
	_check(_button_texts(menu).has("Multiplayer"), "menu: Back returns to the first page")
	_press(menu, "Multiplayer")
	await _frames(2)
	var multi := _button_texts(menu)
	_check(multi.has("Play on a Server") and multi.has("Play Direct") and not multi.has("Host a Game")
		and multi.has("Players Sharing One Computer") and multi.has("Back"),
		"menu: Multiplayer has the server, Play Direct and sharing one computer: %s" % str(multi))
	_press(menu, "Play Direct")
	await _frames(2)
	var direct := _button_texts(menu)
	_check(direct.has("Host a Game") and direct.has("Join a Game") and direct.has("Back") and not direct.has("Play on a Server"),
		"menu: Play Direct opens its own page with Host and Join: %s" % str(direct))
	_press(menu, "Back")
	await _frames(2)
	_check(_button_texts(menu).has("Play Direct"), "menu: Back from Play Direct returns to Multiplayer")
	_press(menu, "Play Direct")
	await _frames(2)
	menu.queue_free()
	await _frames(2)
	menu = load("res://scenes/Menu.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	_check(_button_texts(menu).has("Host a Game"), "menu: reopens on the page it was left from (Back from a screen lands there)")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	menu._unhandled_input(esc)
	await _frames(2)
	_check(_button_texts(menu).has("Play Direct"), "menu: Esc from Play Direct goes back to Multiplayer")
	menu._unhandled_input(esc)
	await _frames(2)
	_check(_button_texts(menu).has("Settings"), "menu: Esc goes back to the first page")
	_press(menu, "Settings")
	await _frames(2)
	var name_edit := menu.find_child("NameEdit", true, false) as LineEdit
	var options := menu.find_children("*", "OptionButton", true, false)
	var sliders := menu.find_children("*", "HSlider", true, false)
	_check(name_edit != null and name_edit.text == GameConfig.player_name() and options.size() == 1 and sliders.size() == 1,
		"menu: Settings has your name, the layout and the volume")
	menu.queue_free()
	MenuScript.set("last_page", 0)
	await _frames(2)

## Three save slots: the game's menu saves into one, the main menu's Saved
## Games continues or deletes them, Continue takes the newest. Your Crew shows
## the saved crew with nothing to spend.
func _test_save_slots_and_crew() -> void:
	var paths := GameConfig.slot_paths()
	_check(paths.size() == 3 and paths[0] == GameConfig.save_path and paths[1] != paths[2] and paths[1] != paths[0],
		"saves: three slots, the first being the old single slot: %s" % str(paths))
	for p in paths:
		GameConfig.delete_save(p)
	_check(GameConfig.newest_save() == "" and not GameConfig.has_any_save(), "saves: none to begin with")

	# Saving from the game's menu.
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var mode_before := GameConfig.mode
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.current_slot = ""
	var gm := GameMenu.new()
	add_child(gm)
	gm.setup(null, game)
	gm._show_slots()
	_check(gm.slots_box.visible and not gm.main_box.visible and gm.slot_buttons.size() == 3
		and gm.slot_buttons[1].text.contains("empty"), "saves: Save Game shows the three slots")
	gm._save_in(1)
	_check(not GameConfig.save_info(paths[1]).is_empty() and GameConfig.current_slot == paths[1] and gm.after_save.visible,
		"saves: picking an empty slot saves there, then offers Keep Playing or Quit")
	_check(gm.slot_buttons[1].text.contains("(this game)") and gm.slot_buttons[1].text.contains("Saved today at"),
		"saves: the slot says it's this game and when it was saved: %s" % gm.slot_buttons[1].text.replace("\n", " / "))
	# Another game in slot 1 (index 0): saving over it takes a second click.
	GameConfig.save_game({"people": []}, "another game", paths[0])
	var other := ConfigFile.new()
	other.load(paths[0])
	other.set_value("save", "saved_at", 1000)
	other.save(paths[0])
	gm._save_in(0)
	_check(GameConfig.save_summary(paths[0]) == "another game" and gm.slot_buttons[0].text.contains("click again"),
		"saves: a slot holding another game asks before it's saved over")
	gm._save_in(0)
	_check(GameConfig.save_summary(paths[0]) != "another game" and GameConfig.current_slot == paths[0],
		"saves: the second click saves over it")
	gm._save_in(0)
	_check(GameConfig.current_slot == paths[0], "saves: this game's own slot saves straight over")
	gm.visible = true
	gm._input(_esc_key())
	_check(gm.main_box.visible and not gm.slots_box.visible, "saves: Esc backs out of the slots to the menu")
	gm.queue_free()
	_free_game(game)

	# Newest first; the main menu lists them.
	var older := ConfigFile.new()
	older.load(paths[1])
	older.set_value("save", "saved_at", 2000)
	older.save(paths[1])
	_check(GameConfig.newest_save() == paths[0], "saves: Continue takes the newest slot")
	_check(GameConfig.saved_when(0) == "" and GameConfig.saved_when(100000, 100000).begins_with("Saved today at")
		and GameConfig.saved_when(100000, 100000 + 86400 * 40).begins_with("Saved "), "saves: when they were saved, in words")
	var MenuScript: Script = load("res://scripts/menu.gd")
	MenuScript.set("last_page", 0)
	var menu: Control = load("res://scenes/Menu.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	var home := _button_texts(menu)
	_check(home.has("Continue") and home.has("Saved Games"), "saves: the first page has Continue and Saved Games: %s" % str(home))
	_press(menu, "Saved Games")
	await _frames(2)
	var load1 := menu.find_child("Load1", true, false) as Button
	var load3 := menu.find_child("Load3", true, false) as Button
	_check(load1 != null and not load1.disabled and load3 != null and load3.disabled and load3.text.contains("empty"),
		"saves: Saved Games lists the slots, the empty one greyed out")
	var del2 := menu.find_child("Delete2", true, false) as Button
	del2.pressed.emit()
	await _frames(2)
	_check(not GameConfig.save_info(paths[1]).is_empty() and (menu.find_child("Delete2", true, false) as Button).text == "Sure?",
		"saves: Delete asks first")
	(menu.find_child("Delete2", true, false) as Button).pressed.emit()
	await _frames(2)
	_check(GameConfig.save_info(paths[1]).is_empty() and not GameConfig.save_info(paths[0]).is_empty(),
		"saves: the second press deletes that slot only")
	_check(GameConfig.load_game(paths[0]) and GameConfig.current_slot == paths[0] and GameConfig.mode == GameConfig.Mode.COMPUTER,
		"saves: loading a slot remembers it, to clear when the game is played out")
	GameConfig.resume = {}
	menu.queue_free()
	await _frames(1)
	for p in paths:
		GameConfig.delete_save(p)

	# Your Crew.
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.crew = []
	for kind in [CharacterStats.Kind.SCOUT, CharacterStats.Kind.DIGGER]:
		var st := CharacterStats.make(kind, "Crew%d" % kind)
		st.confidence = 12.0
		GameConfig.crew.append(st.to_dict())
	MenuScript.set("last_page", 1)
	menu = load("res://scenes/Menu.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	_check(_button_texts(menu).has("Your Crew"), "crew: Single Player has Your Crew")
	menu.queue_free()
	GameConfig.crew_view = true
	var view: Control = load("res://scenes/Coaching.tscn").instantiate()
	add_child(view)
	await _frames(2)
	var texts := _button_texts(view)
	var labels := view.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
	var pluses := view.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.text == "+" and b.visible)
	var edits := view.find_children("*", "LineEdit", true, false)
	_check(labels.has("YOUR CREW") and texts.has("Back") and texts.has("Start a New Crew") and not texts.has("Next Expedition")
		and pluses.is_empty() and edits.size() == 2 and not GameConfig.crew_view,
		"crew: Your Crew shows every sailor, with nothing to spend: %s" % str(texts.filter(func(t: String) -> bool: return t != "+")))
	_check(labels.any(func(t: String) -> bool: return t.contains("confidence 12")), "crew: and each one's confidence")
	view._rename(NAVS_TEAM, 0, "Ishmael")
	_check(GameConfig.crew.any(func(d: Dictionary) -> bool: return str(d.name) == "Ishmael"), "crew: renaming there renames the saved sailor")
	view.queue_free()
	GameConfig.crew = crew_before
	GameConfig.save_crew()
	GameConfig.mode = mode_before
	MenuScript.set("last_page", 0)
	await _frames(2)

## The tutorial, played through in the real game scene: each step moves on
## once it's done, the pirate shows up for the fight, and winning ends it.
func _test_tutorial() -> void:
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.start_tutorial()
	_check(GameConfig.tutorial and not GameConfig.uses_crew() and not GameConfig.can_save() and GameConfig.island_seed == GameConfig.TUTORIAL_SEED,
		"tutorial: its own island, a fresh crew, no saving")
	var main: Node2D = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	var game: GameServer = main.server
	var tut: Tutorial = main.tutorial
	var N := Character.Team.NAVS
	var navs := game._members(N)
	var pirate := tut._pirate()
	_check(tut != null and tut.step_id() == "welcome" and navs.size() == 5 and pirate != null and game.kind_digs
		and game.get_node("../ComputerPlayer1").passive, "tutorial: five NAVS, one waiting pirate, the welcome first")
	tut.advance()
	game.intent(N, "select", [navs[1].cell])
	await _frames(2)
	_check(tut.step_id() == "move", "tutorial: selecting someone moves it on")
	var digger: Character = null
	for c in navs:
		if c.stats.kind == CharacterStats.Kind.DIGGER:
			digger = c
	game.intent(N, "select", [digger.cell])
	var mark: Vector2i = game.x_markers[0]
	for m in game.x_markers:
		if Vector2(m - game.ships[N]).length() < Vector2(mark - game.ships[N]).length():
			mark = m
	var by := Vector2i(-1, -1)
	for n in game.grid.neighbours(mark):
		if game.grid.is_meadow(n) and game._occupant(n) == null:
			by = n
			break
	game.intent(N, "move", [by])
	for i in 200:
		game._process(0.05)
		if digger.cell == by:
			break
	await _frames(2)
	_check(tut.step_id() == "crawl" and digger.cell == by, "tutorial: walking moves it on")
	game.intent(N, "stance", [Character.Stance.CRAWLING])
	await _frames(2)
	_check(tut.step_id() == "end", "tutorial: crawling moves it on")
	game.intent(N, "end_turn")
	for i in 40:
		game._process(0.05)
		await _frames(1)
		if game.current_team == N:
			break
	await _frames(2)
	_check(tut.step_id() == "dig" and game.current_team == N, "tutorial: the pirate just ends his turn, and it's yours again")
	game.intent(N, "select", [digger.cell])
	game.intent(N, "dig")
	for i in 40:
		game._process(0.05)
	await _frames(3)
	_check(digger.carrying and tut.step_id() == "hand", "tutorial: the first dig beside the X finds its chest")
	var helper: Character = navs[0] if navs[0] != digger else navs[2]
	helper.energy = 100.0
	game.intent(N, "select", [helper.cell])
	game.intent(N, "fetch", [digger.cell])
	for i in 400:
		game._process(0.05)
		if not game.offer.is_empty():
			break
	game.intent(N, "handoff", [true])
	await _frames(2)
	_check(helper.carrying and tut.step_id() == "aboard", "tutorial: handing it over the new way moves it on")
	helper.energy = 100.0
	helper.path.assign(game.grid.find_path(helper.cell, game.ships[N], game._blocked_for(helper)))
	for i in 600:
		game._process(0.05)
		if game.delivered[N] > 0:
			break
	await _frames(2)
	_check(game.delivered[N] == 1 and tut.step_id() == "menu", "tutorial: a chest aboard moves it on")
	main.open_menu()
	await _frames(2)
	main.game_menu.close()
	await _frames(2)
	_check(tut.step_id() == "fight", "tutorial: opening and closing the menu moves it on")
	var near: Character = game.active
	_check(maxi(absi(pirate.cell.x - near.cell.x), absi(pirate.cell.y - near.cell.y)) <= 5 and game.revealed[N].has(pirate.cell),
		"tutorial: the pirate steps out of the fog near you")
	game.characters[pirate.id].captured = true
	game._check_wipeout()
	await _frames(3)
	_check(game.won and tut._finished and tut.find_child("Campaign", true, false) != null, "tutorial: winning finishes it, and offers the campaign")
	_check(GameConfig.crew == crew_before, "tutorial: your saved crew is untouched")
	main.queue_free()
	GameConfig.reset()
	await _frames(2)

## Battle Royale: trained crews checked, rounds counted, Vega ashore until
## the final round (or every round, if chosen), and the end of it.
func _test_battle_royale() -> void:
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOST
	GameConfig.set_battle_royale(true, 3, false)
	GameConfig.team_count = 3
	GameConfig.new_match()
	_check(GameConfig.battle_royale and GameConfig.partner == GameConfig.FREE_FOR_ALL and GameConfig.in_match(),
		"royale: a Battle Royale is a free-for-all match")
	# Checking a crew someone sends.
	var big: Array = []
	for i in 20:
		big.append(CharacterStats.make(CharacterStats.Kind.FIGHTER, "F%d" % i).to_dict())
	big.append(Campaign.make_vega().to_dict())
	var low := CharacterStats.make(CharacterStats.Kind.SCOUT, "Low").to_dict()
	low.vision = 1.0 # below where a Scout starts
	big.push_front(low)
	var clean := GameConfig.sanitize_crew(big)
	var regulars := clean.filter(func(d: Dictionary) -> bool: return not d.has("special"))
	_check(regulars.size() == GameConfig.MAX_TEAM_SIZE and clean.size() == GameConfig.MAX_TEAM_SIZE + 1
		and float(clean[0].vision) == CharacterStats.EXCELLENT, "royale: at most %d sailors and Vega; no skill below where its class starts" % GameConfig.MAX_TEAM_SIZE)
	_check(GameConfig.sanitize_crew("junk").is_empty() and GameConfig.sanitize_crew([{"kind": 1}]).is_empty(), "royale: junk is no crew at all")
	GameConfig.crew = []
	var fresh := GameConfig.my_br_crew()
	_check(fresh.size() == GameConfig.DEFAULT_TEAM_SIZE and GameConfig.counts_of(fresh) == GameConfig.default_counts(),
		"royale: no trained crew means ten fresh recruits, two of each class")
	# Rounds and Vega.
	var ann := [CharacterStats.make(CharacterStats.Kind.RUNNER, "Ann R").to_dict(), Campaign.make_vega().to_dict()]
	GameConfig.match_crews[0] = ann
	_check(GameConfig.br_round_text() == "Round 1 of 3" and not GameConfig.br_vega_allowed()
		and GameConfig.build_roster(0).size() == 1, "royale: round 1 of 3, Vega ashore")
	var landed: Array = [CharacterStats.make(CharacterStats.Kind.RUNNER, "Ann R")]
	GameConfig.end_game_in_match([landed, [], []], 0, [1, 0, 0])
	_check(GameConfig.match_crews[0].size() == 2 and GameConfig.match_crews[0].any(func(d: Dictionary) -> bool: return str(d.get("special", "")) != ""),
		"royale: she stays in the crew while she waits ashore")
	GameConfig.end_game_in_match([landed, [], []], 1, [0, 1, 0])
	_check(GameConfig.br_final_round() and GameConfig.br_round_text() == "Final round" and GameConfig.br_vega_allowed()
		and GameConfig.build_roster(0).size() == 2, "royale: in the final round Vega sails")
	var both: Array = [CharacterStats.make(CharacterStats.Kind.RUNNER, "Ann R"), Campaign.make_vega()]
	GameConfig.end_game_in_match([both, [], []], 0, [2, 0, 0])
	_check(GameConfig.br_over() and GameConfig.br_result() == "The NAVS take the Battle Royale!"
		and GameConfig.br_standings() == "NAVS 2, Pirates 1, Corsairs 0", "royale: three rounds played, the most wins takes it")
	var state := GameConfig.match_state()
	GameConfig.reset()
	GameConfig.apply_match_state(state)
	_check(GameConfig.battle_royale and GameConfig.br_rounds == 3 and GameConfig.br_over(), "royale: it travels with the match (and its saves)")
	GameConfig.set_battle_royale(true, 5, true)
	GameConfig.match_games = 0
	_check(GameConfig.br_vega_allowed() and GameConfig.br_round_text() == "Round 1 of 5", "royale: with the option, Vega may sail every round")
	GameConfig.set_battle_royale(true, 1, false)
	_check(GameConfig.br_final_round() and GameConfig.br_vega_allowed() and GameConfig.br_round_text() == "One round",
		"royale: a one-round Battle Royale is its own final")

	# The screens.
	var MenuScript: Script = load("res://scripts/menu.gd")
	MenuScript.set("last_page", 2)
	var menu: Control = load("res://scenes/Menu.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	_press(menu, "Battle Royale")
	await _frames(2)
	var texts := _button_texts(menu)
	_check(texts.has("Host a Battle Royale") and texts.has("On a Server") and texts.has("Join a Friend's"), "royale: the Multiplayer menu has a Battle Royale page: %s" % str(texts))
	menu.queue_free()
	await _frames(2)
	GameConfig.host_royale() # what Host a Battle Royale does before opening Setup
	_check(GameConfig.mode == GameConfig.Mode.HOST and GameConfig.battle_royale and GameConfig.length == TerrainGrid.Length.LONG,
		"royale: hosting one starts on a long island")
	var setup: Control = load("res://scenes/Setup.tscn").instantiate()
	add_child(setup)
	await _frames(2)
	texts = _button_texts(setup)
	_check(setup.find_child("TurnLimit", true, false) != null and texts.has("None") and texts.has("3 min"),
		"turn limit: a game you host offers one (none to 5 minutes)")
	_check(texts.has("Host This Battle Royale") and texts.has("1") and texts.has("3") and texts.has("5")
		and setup.find_child("VegaEveryRound", true, false) != null and not setup.sides_box.visible,
		"royale: setting it up: rounds, the Vega option, no sides or crew makeup")
	setup.queue_free()
	MenuScript.set("last_page", 0)
	GameConfig.reset()
	GameConfig.crew = crew_before
	await _frames(2)

## The camera stays where you put it when someone is selected or walks off;
## Centre jumps to them once. The turn clock: only with a limit, the full
## limit for a person's turn, none for the computer's, and a guest counts
## down between snapshots.
func _test_camera_and_clock() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.island_seed = 4242
	GameConfig.configured = true
	var main: Node2D = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	var game: GameServer = main.server
	var N := Character.Team.NAVS
	var navs := game._members(N)
	main.look_at_world(Vector2(game.grid.width, game.grid.height) * 16.0) # somewhere in the middle
	await _frames(2)
	var parked: Vector2 = main.camera.position
	var far: Character = navs[navs.size() - 1]
	main.controller._on_click(far.cell)
	main.controller._cycle_selection()
	game.intent(N, "move", [_free_near(game, game.grid, game.active.cell, 1)])
	for i in 30:
		game._process(0.05)
		await _frames(1)
	_check(main.camera.position.distance_to(parked) < 1.0, "camera: selecting, Tab and walking leave the view where it was")
	main.recentre()
	await _frames(2)
	var want: Vector2 = game.active.position
	_check(main.camera.position.distance_to(parked) > 1.0 and main.camera.position.distance_to(want) < main.camera.position.distance_to(parked) + 1.0,
		"camera: Centre jumps to whoever is selected")
	var after: Vector2 = main.camera.position
	game._process(0.05)
	await _frames(5)
	_check(main.camera.position.distance_to(after) < 1.0, "camera: and doesn't follow them after that")
	_check(game.clock_left() < 0.0 and not main.clock_panel.visible, "clock: no turn limit, no clock on screen")
	game.turn_limit = 90.0
	game.reset_turn_clock()
	main._update_clock()
	_check(is_equal_approx(game.clock_left(), 90.0) and main.clock_panel.visible and main.clock_label.text == "Your turn  1:30",
		"clock: with a limit, a person's turn starts with all of it, on screen: %s" % main.clock_label.text)
	game.request_end_turn(N)
	_check(game.turn_clock < 0.0, "clock: the computer's turn runs no clock")
	main.queue_free()
	await _frames(2)
	# Counted where the game runs: a hot-seat game of two people.
	var g := TerrainGrid.new(4242)
	var duo := _computer_game(g)
	duo.mode = GameConfig.Mode.HOTSEAT
	duo.ctrl = [GameConfig.Ctrl.HUMAN, GameConfig.Ctrl.HUMAN]
	duo.turn_limit = 40.0
	duo.reset_turn_clock()
	duo.clock_hold = true
	duo._process(5.0)
	_check(is_equal_approx(duo.turn_clock, 40.0), "clock: held while a shared computer's hand-over screen is up")
	duo.clock_hold = false
	duo.paused = true
	duo._process(5.0)
	_check(is_equal_approx(duo.turn_clock, 40.0), "clock: and while paused")
	duo.paused = false
	for i in 12:
		duo._process(1.0)
	_check(duo.turn_clock > 27.0 and duo.turn_clock < 29.0 and duo.status[N].contains("30 seconds left"),
		"clock: it counts down, with a warning at 30 seconds: %s" % duo.status[N])
	for i in 28:
		duo._process(1.0)
	_check(duo.current_team == Character.Team.PIRATES and duo.turn_clock > 39.0 and duo.status[N].contains("Out of time"),
		"clock: when it runs out the turn passes on, and the next player gets the full time")
	_free_game(duo)
	var mirror := GameServer.new()
	mirror.is_authority = false
	mirror.started = true
	mirror.turn_clock = -1.0
	add_child(mirror)
	mirror.set_process(false)
	mirror.turn_clock = 20.0
	mirror._clock_at = Time.get_ticks_msec() - 5000
	_check(absf(mirror.clock_left() - 15.0) < 0.2, "clock: a guest counts down from the last snapshot")
	mirror.paused = true
	_check(is_equal_approx(mirror.clock_left(), 20.0), "clock: but not while the game is paused")
	_check(GameServer.clock_text(161.2) == "2:42" and GameServer.clock_text(0.0) == "0:00", "clock: written as minutes and seconds")
	mirror.queue_free()
	GameConfig.reset()
	await _frames(2)

## A server's Hall of Fame (per player, lifetime on that server) and each
## saved sailor's career.
func _test_hall_of_fame_and_careers() -> void:
	var Board: Script = load("res://scripts/server_board.gd")
	var folder := "user://smoke_board"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	if FileAccess.file_exists(folder.path_join("hall_of_fame.cfg")):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join("hall_of_fame.cfg")))
	var board: RefCounted = Board.new()
	board.open(folder)
	_check(board.players.is_empty() and board.board_info().rows.is_empty(), "hall: a new server's Hall of Fame is empty")
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	game.delivered[N] = 2
	game.delivered[P] = 1
	game.tally[game._members(N)[0].id].captures = 2
	game.tally[game._members(P)[1].id].captures = 1
	var seats := {N: ["pid-ann", "Ann"], P: ["pid-bo", "Bo"]}
	_check(Board.results_of(game, seats).is_empty(), "hall: a game still going counts for nothing")
	game._win(N, "test")
	var res: Array = Board.results_of(game, seats, [N])
	board.record(res)
	var ann: Dictionary = board.players["pid-ann"]
	var bo: Dictionary = board.players["pid-bo"]
	_check(int(ann.games) == 1 and int(ann.wins) == 1 and int(ann.aboard) == 2 and int(ann.captures) == 2 and int(ann.titles) == 1,
		"hall: the winner gets a game, a win, her chests aboard, her captures and the title")
	_check(int(bo.games) == 1 and int(bo.wins) == 0 and int(bo.aboard) == 1 and int(bo.captures) == 1 and int(bo.titles) == 0,
		"hall: the other player gets the game and his numbers")
	board.record(Board.results_of(game, {P: ["pid-bo", "Bo the Bold"]}))
	_check(str(board.players["pid-bo"].name) == "Bo the Bold" and int(board.players["pid-bo"].games) == 2, "hall: a player shows under their latest name")
	_free_game(game)
	for i in 9:
		board.players["pid-x%d" % i] = {"name": "Crew %d" % i, "games": 10, "wins": 9 - i, "titles": 0, "aboard": 5, "captures": 0, "at": 0}
	board.save()
	var info: Dictionary = board.board_info(ServerFinder.back_key("pid-bo"))
	_check(info.rows.size() == 7 and str(info.rows[0][1]) == "Crew 0" and int(info.players) == 11, "hall: ranked by wins, the top seven shown")
	_check(info.me.size() == 8 and str(info.me[1]) == "Bo the Bold" and int(info.me[0]) > 7, "hall: and your own row, when you're further down")
	var reply := ServerFinder.make_board_reply(info)
	var back := ServerFinder.parse_board_reply(reply)
	_check(reply.size() <= ServerFinder.REPLY_LIMIT and back.rows.size() >= 5 and str(back.me[1]) == "Bo the Bold",
		"hall: the answer fits one small packet (%d bytes) and reads back" % reply.size())
	_check(ServerFinder.is_board_query(ServerFinder.board_query_packet()) and not ServerFinder.is_board_query(ServerFinder.query_packet())
		and ServerFinder.is_query(ServerFinder.board_query_packet()), "hall: its question is the status question with one byte changed")
	var again: RefCounted = Board.new()
	again.open(folder)
	_check(again.players.size() == 11 and int(again.players["pid-ann"].titles) == 1, "hall: kept on disk")
	# Careers.
	var st := CharacterStats.make(CharacterStats.Kind.SCOUT, "Careerist")
	st.add_career({"found": 2, "aboard": 1, "captures": 1}, true)
	st.add_career({"found": 0, "aboard": 2, "captures": 0}, false)
	var copy := CharacterStats.make(CharacterStats.Kind.SCOUT, "Careerist")
	copy.apply_saved(st.to_dict())
	_check(copy.career == {"games": 2, "wins": 1, "found": 2, "aboard": 3, "captures": 1}
		and copy.career_text() == "2 games · 1 won · 3 chests aboard · 1 capture", "career: a sailor's lifetime record, kept with them: %s" % copy.career_text())
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.crew = [CharacterStats.make(CharacterStats.Kind.RUNNER, "Rio").to_dict()]
	var speed_before := float(GameConfig.crew[0].speed)
	GameConfig.add_careers([{"name": "Rio", "tally": {"found": 1, "aboard": 1, "captures": 3}, "won": true}, {"name": "Nobody", "tally": {}, "won": true}])
	_check(int(GameConfig.crew[0].career.captures) == 3 and int(GameConfig.crew[0].career.wins) == 1 and float(GameConfig.crew[0].speed) == speed_before,
		"career: a Battle Royale round adds to the saved sailors' careers, and nothing else")
	GameConfig.crew_view = true
	var view: Control = load("res://scenes/Coaching.tscn").instantiate()
	add_child(view)
	await _frames(2)
	var career_label := view.find_child("Career", true, false) as Label
	_check(career_label != null and career_label.visible and career_label.text.begins_with("Career: 1 game · 1 won"),
		"career: Your Crew shows it: %s" % (career_label.text if career_label else "none"))
	view.queue_free()
	GameConfig.crew = crew_before
	GameConfig.save_crew()
	await _frames(2)

## Check for Updates on the main menu: what it says for each answer, and
## that saying yes has the server list fetch it and come back to the menu.
func _test_menu_update_check() -> void:
	var MenuScript: Script = load("res://scripts/menu.gd")
	MenuScript.set("last_page", 0)
	var menu: Control = load("res://scenes/Menu.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	_check(_button_texts(menu).has("Check for Updates") and menu.find_child("UpdateCheck", true, false) != null,
		"menu updates: the first page has Check for Updates")
	menu.queue_free()
	await _frames(2)
	var mine := GameConfig.version()
	var none: Dictionary = MenuScript.call("check_result", [], mine)
	var same: Dictionary = MenuScript.call("check_result", [{"v": mine, "name": "homeserver", "machine": "homeserver"}], mine)
	var newer: Dictionary = MenuScript.call("check_result", [{"v": mine, "name": "old", "machine": "old"},
		{"v": "99.0.0", "name": "homeserver", "machine": "homeserver", "address": "127.0.0.1:1"}], mine)
	_check(none.kind == "none" and same.kind == "current" and str(same.text).begins_with("You're up to date"),
		"menu updates: no servers, or none newer, and it says so")
	_check(newer.kind == "newer" and str(newer.server.v) == "99.0.0" and str(newer.text).begins_with("Version 99.0.0 is on homeserver"),
		"menu updates: a newer one is offered, not fetched: %s" % newer.text)
	GameConfig.update_from = newer.server
	var browser: Control = load("res://scenes/ServerBrowser.tscn").instantiate()
	browser.set("scan_tailnet", false)
	add_child(browser)
	await _frames(3)
	var said: String = browser.status_label.text
	_check(said.contains("Asking it for the update") and Net.updater.relaunch_extra.is_empty() and GameConfig.update_from.is_empty(),
		"menu updates: Update Now has the server list fetch it, and the game restarts into the menu: %s" % said)
	Net.leave()
	browser.queue_free()
	await _frames(2)

	# From the public releases on GitHub.
	var RU: Script = load("res://scripts/release_update.gd")
	var rel := {"tag_name": "v99.1.0", "html_url": "https://example.invalid/r",
		"assets": [{"name": "PiratesPlunder-mac.zip", "browser_download_url": "https://example.invalid/m"},
			{"name": "PiratesPlunder-windows.exe", "browser_download_url": "https://example.invalid/w"},
			{"name": "SHA256SUMS.txt", "browser_download_url": "https://example.invalid/s"}]}
	var got: Dictionary = RU.call("parse_release", rel, mine)
	_check(got.kind == "newer" and got.version == "99.1.0" and got.files.size() == 3, "releases: a newer release is spotted: %s" % got.get("text", ""))
	rel.tag_name = "v" + mine
	_check(RU.call("parse_release", rel, mine).kind == "current", "releases: the same version is up to date")
	_check(RU.call("parse_release", {"message": "Not Found"}, mine).kind == "error", "releases: a strange answer is an error, not an update")
	var sums := "%s  PiratesPlunder-macos.dmg\n%s  PiratesPlunder-mac.zip\n" % ["a".repeat(64), "B".repeat(64)]
	_check(RU.call("sum_for", sums, "PiratesPlunder-mac.zip") == "b".repeat(64) and RU.call("sum_for", sums, "PiratesPlunder-windows.exe") == "",
		"releases: the right fingerprint is found in SHA256SUMS.txt")
	_check(RU.call("file_for", "macOS") == "PiratesPlunder-mac.zip" and RU.call("file_for", "Windows") == "PiratesPlunder-windows.exe" and RU.call("file_for", "Linux") == "",
		"releases: each computer installs its own file")
	MenuScript.set("last_page", 0)
	menu = load("res://scenes/Menu.tscn").instantiate()
	add_child(menu)
	await _frames(2)
	menu.call("_check_for_updates")
	var ru: Node = menu.find_child("ReleaseUpdate", true, false)
	ru.set("platform_override", "Windows")
	rel.tag_name = "v99.1.0"
	menu.call("_on_release_checked", RU.call("parse_release", rel, mine))
	await _frames(1)
	var upd: Button = menu.find_child("UpdateNow", true, false)
	_check(upd != null and upd.text == "Update Now", "releases: a newer release on Windows or a Mac is offered as Update Now")
	ru.set("platform_override", "Linux")
	menu.call("_on_release_checked", RU.call("parse_release", rel, mine))
	await _frames(1)
	upd = menu.find_child("UpdateNow", true, false)
	_check(upd != null and upd.text == "Open the Releases Page", "releases: elsewhere, the releases page is offered instead")
	menu.queue_free()
	await _frames(2)

## Pirates used to attack and back away in a loop: a route went straight
## through a visible opponent they'd just retreated from, and they kept
## guessing an opponent's energy at 70 after a fight had shown 100.
func _test_no_dither() -> void:
	var g := TerrainGrid.new(4242)
	var game := _computer_game(g)
	var N := Character.Team.NAVS
	var P := Character.Team.PIRATES
	# A straight row of five open squares, nobody on them.
	var row := []
	for y in range(2, g.height - 2):
		for x in range(2, g.width - 6):
			var ok := true
			for i in 5:
				var cell := Vector2i(x + i, y)
				if not g.is_meadow(cell) or game._occupant(cell) != null:
					ok = false
			for i in 5:
				for dy in [-1, 1]:
					if not g.is_walkable(Vector2i(x + i, y + dy)):
						ok = false
			if ok and row.is_empty():
				row = [Vector2i(x, y), Vector2i(x + 2, y), Vector2i(x + 4, y)]
	_check(not row.is_empty(), "dither: found an open row for the test")
	var walker: Character = game._members(N)[2]
	var pirate: Character = game._members(P)[4]
	_place(walker, row[0])
	_place(pirate, row[1])
	game.seen[N] = {pirate.id: true}
	var way := game._route(walker, row[2])
	_check(not way.is_empty() and not way.has(row[1]), "dither: a route goes round an opponent you can see")
	var at := game._route(walker, row[1])
	_check(not at.is_empty() and at[at.size() - 1] == row[1], "dither: heading for them (an attack) still goes straight at them")
	game.seen[N] = {}
	var blind := game._route(walker, row[2])
	_check(blind.has(row[1]), "dither: one nobody can see isn't dodged")
	# The computer remembers what a fight showed.
	var cpu: ComputerPlayer = game.get_meta("cpu")
	cpu.team = P
	var nav: Character = game._members(N)[3] # a Fighter
	var sword: Character = game._members(P)[4] # a Swordsman
	_place(nav, row[0] + Vector2i(1, 0))
	_place(sword, row[0])
	_place(walker, row[2] + Vector2i(0, 1) if g.is_walkable(row[2] + Vector2i(0, 1)) else row[2])
	_place(pirate, row[2])
	nav.energy = 100.0
	sword.energy = 52.0
	game.seen[P] = {nav.id: true}
	var costs := g.move_costs(sword.cell, game._blocked_for(sword))
	_check(cpu._fight_target(sword, costs) == nav, "dither: guessing their energy at 70, the pirate would attack")
	cpu._seen_energy[nav.id] = 100.0
	_check(cpu._fight_target(sword, costs) == null, "dither: but once a fight has shown 100, it doesn't start one only to back off")
	_free_game(game)

## A crew grown past an island's number lands whole, and the briefing starts
## from who's really in it (a recruit was being left out).
func _test_recruits_land() -> void:
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.crew = []
	for k in [2, 1, 0, 3, 4, 2, 1, 0, 3]: # nine, the last a second Swordsman
		GameConfig.crew.append(CharacterStats.make(k, "R%d" % GameConfig.crew.size()).to_dict())
	GameConfig.crew.append(Campaign.make_vega().to_dict())
	var island := 5 # lands 8
	_check(Campaign.party_size(island) == 9, "recruits: a crew of nine lands nine on an island of eight (Vega not counted)")
	var last8 := GameConfig.balanced_counts(8)
	var counts := GameConfig.campaign_counts(Campaign.party_size(island), last8)
	_check(counts == GameConfig.counts_of(GameConfig.crew), "recruits: the briefing starts from the crew as it is")
	var roster := GameConfig.preview_roster(counts, 0, GameConfig.Mode.COMPUTER)
	_check(roster.size() == 9 and GameConfig.names_of(roster, CharacterStats.Kind.SWORDSMAN) == "R3, R8",
		"recruits: both Swordsmen are in the landing party: %s" % GameConfig.names_of(roster, CharacterStats.Kind.SWORDSMAN))
	GameConfig.crew = GameConfig.crew.slice(0, 3)
	var small := GameConfig.campaign_counts(Campaign.party_size(0), {})
	var n := 0
	for k in small:
		n += int(small[k])
	_check(Campaign.party_size(0) == 6 and n == 6 and int(small[CharacterStats.Kind.SCOUT]) >= 1 and int(small[CharacterStats.Kind.RUNNER]) >= 1,
		"recruits: a small crew is topped up to the island's number, everyone in it included")
	GameConfig.crew = crew_before

## Gallows Rock: Vega behind a stockade with one gate, four guards beside
## her, an ambush on the way, an outpost of your own, and her post only
## marked once seen. Built in the real game scene.
func _test_gallows_rock() -> void:
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.crew = []
	GameConfig.start_campaign(Campaign.RESCUE, GameConfig.campaign_counts(8))
	var main: Node2D = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await _frames(3)
	var game: GameServer = main.server
	var g: TerrainGrid = game.grid
	var vega := game.characters[game.captive_id]
	_check(game.pen == vega.cell and game.pen_gate.x >= 0 and g.is_walkable(game.pen_gate) and g.width == TerrainGrid.SIZES[2].x and g.height == roundi(TerrainGrid.SIZES[2].y * 1.6),
		"gallows: a long island, stretched north to south, Vega in a stockade with a gate")
	var inside: Array[Vector2i] = []
	for n in g.neighbours(vega.cell):
		inside.append(n)
	var shut := g.move_costs(g.nav_ship, {game.pen_gate: true})
	var open := g.move_costs(g.nav_ship)
	_check(not inside.is_empty() and inside.all(func(c: Vector2i) -> bool: return not shut.has(c)) and inside.any(func(c: Vector2i) -> bool: return open.has(c)),
		"gallows: the gate is the only way in")
	var guards: Array = game.guards.keys()
	var ambush := game.posts.keys().filter(func(id: int) -> bool: return not bool(game.posts[id][2]))
	_check(guards.size() == 4 and guards.all(func(id: int) -> bool: return maxi(absi(game.characters[id].cell.x - vega.cell.x), absi(game.characters[id].cell.y - vega.cell.y)) == 1),
		"gallows: four guards stand beside her")
	_check(ambush.size() == 3 and ambush.all(func(id: int) -> bool: return game.characters[id].stance == Character.Stance.CRAWLING),
		"gallows: three pirates lie in ambush, crawling")
	_check(not game.revealed[N_TEAM].has(vega.cell), "gallows: her post isn't on the map until your crew sees it")
	var nav: Character = game._members(N_TEAM)[0]
	_place(nav, game.outpost)
	_check(game.rest_bonus(nav) == 2.0, "gallows: resting at the outpost gives double energy")
	# Beside her, but a guard's there too: no rescue.
	var beside := Vector2i(-1, -1)
	for c in inside:
		if game._occupant(c) == null:
			beside = c
	_place(nav, beside)
	game._check_rescue(nav)
	_check(vega.captured and game.guard_beside_captive() != null, "gallows: with a guard beside her, she can't be cut free")
	for id in guards:
		game.characters[id].captured = true
	game._try_free()
	_check(not vega.captured, "gallows: once the guards are dealt with, the sailor beside her cuts her free")
	main.queue_free()
	GameConfig.reset()
	GameConfig.crew = crew_before
	await _frames(2)

## Normal, Hard and Extreme: tuned rivals, separate progress, old saves.
func _test_campaign_levels() -> void:
	var path_before := Campaign.path
	Campaign.path = "user://smoke_levels.cfg"
	var cfg := ConfigFile.new()
	cfg.set_value("campaign", "won", [0, 1, 2]) # a save from before the levels
	cfg.set_value("campaign", "captain", false)
	cfg.save(Campaign.path)
	Campaign._loaded_from = ""
	Campaign.level = 0
	_check(Campaign.won_count() == 3 and Campaign.won(2), "levels: an old campaign carries on as Normal")
	var normal := Campaign.chapter(3)
	Campaign.set_level(1)
	var hard := Campaign.chapter(3)
	_check(Campaign.won_count() == 0 and int(hard.difficulty) == mini(int(normal.difficulty) + 1, 2)
		and int(hard.rival_crew) == int(normal.rival_crew) + 2 and int(hard.drilled) == int(normal.drilled) + 2,
		"levels: Hard has its own progress, and harder, bigger, better-drilled rivals")
	_check(int(Campaign.chapter(Campaign.RESCUE).guards) == 5, "levels: a fifth guard at Gallows Rock on Hard")
	Campaign.set_level(2)
	var ext := Campaign.chapter(0)
	_check(int(ext.difficulty) == 2 and int(ext.rival_crew) == int(Campaign.CHAPTERS[0].rival_crew) + 4 and bool(ext.pirates_first)
		and int(Campaign.chapter(Campaign.RESCUE).guards) == 6, "levels: Extreme: hard rivals, 4 more each, always first, six guards")
	for i in Campaign.FINAL:
		Campaign.win(i)
	_check(Campaign.win(Campaign.FINAL) and Campaign.level_done(2) and not Campaign.level_done(1), "levels: finishing Extreme plays the ending, for that level")
	Campaign.set_level(0)
	_check(Campaign.won_count() == 3, "levels: and Normal's progress is untouched")
	Campaign._loaded_from = ""
	_check(Campaign.data().won[2].size() == 15 and Campaign.level == 0, "levels: kept on disk, with the level last chosen")
	Campaign.reset()
	_check(Campaign.won_count() == 0 and Campaign.data().won[2].size() == 15 and Campaign.is_captain(), "levels: Start Over clears only the level you're on")
	Campaign.reset(true)
	Campaign.path = path_before
	Campaign._loaded_from = ""

const N_TEAM := 0
const NAVS_TEAM := 0

## Single player: a win brings a recruit of the class you pick, who lands next
## time; a crew grown past ten lands whole.
func _test_recruits() -> void:
	var mode_before := GameConfig.mode
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.clear_crew()
	_check(GameConfig.team_size(GameConfig.nav_counts) == 10 and GameConfig.team_target == 10,
		"crews: ten by default, two of each class")
	for r in GameConfig.build_roster():
		GameConfig.remember([CharacterStats.make(r[0], r[1])])
	var st := GameConfig.recruit(CharacterStats.Kind.SCOUT, "")
	_check(GameConfig.crew.size() == 11 and int(GameConfig.nav_counts[CharacterStats.Kind.SCOUT]) == 3
		and GameConfig.team_target == 11 and not GameConfig.recruit_due, "recruits: a new Scout joins and gets a place")
	_check(GameConfig.build_roster().map(func(r: Array) -> String: return r[1]).has(st.person_name),
		"recruits: they land on the next island")
	var named := GameConfig.recruit(CharacterStats.Kind.DIGGER, "  Mary Read ")
	var dup := GameConfig.recruit(CharacterStats.Kind.DIGGER, "Mary Read")
	_check(named.person_name == "Mary Read" and dup.person_name != "Mary Read", "recruits: you can name them; names stay unique")
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.COMPUTER
	_check(GameConfig.fit_counts_to_crew() and GameConfig.team_size(GameConfig.nav_counts) == 13
		and int(GameConfig.nav_counts[CharacterStats.Kind.DIGGER]) == 4, "recruits: next time, the whole grown crew lands")
	while GameConfig.crew.size() < 20:
		GameConfig.recruit(CharacterStats.Kind.FIGHTER)
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.fit_counts_to_crew()
	_check(GameConfig.team_size(GameConfig.nav_counts) == GameConfig.MAX_TEAM_SIZE and GameConfig.build_roster().size() == 16,
		"crews: never more than sixteen land")
	GameConfig.crew = crew_before
	GameConfig.save_crew()
	GameConfig.reset()
	GameConfig.mode = mode_before

## The coaching screen: pick a recruit, coach one person at a time, see how it went.
func _test_coaching_screen() -> void:
	var mode_before := GameConfig.mode
	var crew_before := GameConfig.crew.duplicate(true)
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.COMPUTER
	GameConfig.clear_crew()
	var party: Array = []
	for r in GameConfig.build_roster():
		party.append(CharacterStats.make(r[0], r[1]))
	GameConfig.remember(party)
	GameConfig.last_party = party.map(func(p: CharacterStats) -> String: return p.person_name)
	GameConfig.coaching_sessions = 1
	GameConfig.recruit_due = true
	var view: Control = load("res://scenes/Coaching.tscn").instantiate()
	add_child(view)
	await _frames(2)
	_check(_button_texts(view).any(func(t: String) -> bool: return t.begins_with("Scout")) and view.next_button.disabled,
		"coaching: a win offers a recruit first, and Next waits for the coaching")
	(view.find_child("RecruitScout", true, false) as Button).pressed.emit()
	await _frames(2)
	var panel: CoachPanel = view.panels[NAVS_TEAM]
	_check(panel.people.size() == 11 and GameConfig.crew.size() == 11, "coaching: the recruit joins and is coached with the rest")
	panel._choose("swordfighting")
	_check(panel.picks == {0: "swordfighting"} and panel.current == 1, "coaching: a pick moves on to the next person")
	panel._auto_pick_rest()
	_check(panel.picks.size() == 11 and str(panel.picks[0]) == "swordfighting", "coaching: coach-the-rest fills in only the others")
	var before := GameConfig.crew.map(func(d: Dictionary) -> Dictionary: return d.duplicate())
	panel.plan_done.emit(panel.picks.duplicate())
	await _frames(1)
	_check(panel.finished and panel._results.get_child_count() >= 11 and not view.next_button.disabled,
		"coaching: Done rolls every try and lists how it went")
	var changed := 0
	for i in GameConfig.crew.size():
		if GameConfig.crew[i] != before[i]:
			changed += 1
	_check(changed > 0, "coaching: the results are saved with the crew (%d changed)" % changed)
	view.queue_free()
	await _frames(1)
	# Two people at one computer: a tab each, and Next waits for both.
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.HOTSEAT
	GameConfig.new_match()
	var crews := [[], []]
	for t in 2:
		for r in GameConfig.build_roster(t):
			crews[t].append(CharacterStats.make(r[0], r[1]))
	GameConfig.end_game_in_match(crews, 0, [0, 0])
	var hot: Control = load("res://scenes/Coaching.tscn").instantiate()
	add_child(hot)
	await _frames(2)
	_check(hot.panels.size() == 2 and hot.find_children("*", "TabContainer", true, false).size() == 1 and hot.next_button.disabled,
		"coaching: two crews at one computer get a tab each")
	for t in 2:
		hot.panels[t]._auto_pick_rest()
		hot.panels[t].plan_done.emit(hot.panels[t].picks.duplicate())
	await _frames(1)
	_check(GameConfig.match_coached == [true, true] and not hot.next_button.disabled, "coaching: once both have coached, on to the next game")
	hot.queue_free()
	await _frames(1)
	GameConfig.crew = crew_before
	GameConfig.save_crew()
	GameConfig.reset()
	GameConfig.mode = mode_before

func _esc_key() -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.pressed = true
	return k

func _button_texts(node: Node) -> Array:
	var out := []
	for b in node.find_children("*", "Button", true, false):
		if not (b as Node).is_queued_for_deletion() and not b is OptionButton:
			out.append((b as Button).text)
	return out

func _press(node: Node, text: String) -> void:
	for b in node.find_children("*", "Button", true, false):
		if (b as Button).text == text and not (b as Node).is_queued_for_deletion():
			(b as Button).pressed.emit()
			return
	_check(false, "menu: no button %s" % text)

## Every script loads and compiles, screens included that no other test opens
## (a typing slip in one only shows when that screen is opened).
func _test_scripts_compile() -> void:
	var broken: Array[String] = []
	for dir in ["res://scripts", "res://tools"]:
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".gd"):
				var script: Script = load(dir.path_join(f))
				if script == null or not script.can_instantiate():
					broken.append(f)
	_check(broken.is_empty(), "every script compiles%s" % ("" if broken.is_empty() else ": not " + ", ".join(broken)))
