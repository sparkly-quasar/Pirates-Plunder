class_name GameServer
extends Node

## The authority. Every rule lives here: legal moves, the energy economy,
## digging, sword fights, and the win check. Players send *intents*; nothing
## else mutates state.
##
## TURN-BASED, as in Pirate Battles (DESIGN_REFERENCE.md §2). Within your turn
## you move whoever you like, spending energy per square. Energy does NOT trickle
## back — when your turn comes round, each of your people regains energy equal
## to their STAMINA, capped at 100. Managing that budget is the game.
##
## Two to four crews take turns: the NAVS, then the PIRATES, then the CORSAIRS
## and BUCCANEERS when they're playing. Walk into an opponent and a sword fight
## starts (see Combat). In a networked game only the host's copy runs these
## rules; each guest's copy is a mirror fed by apply_state().
##
## Winning: with two crews, more than half the chests aboard, as in the
## original. With more crews that would almost never happen, so the same idea
## is put the way it actually works: you win once nobody can catch you — when
## you have more chests aboard than any rival could reach even if every chest
## still on the island went their way. (With two crews that is exactly "more
## than half".) Capture every rival and the island is yours; a crew that is
## wiped out drops out of the turn order. If every chest is aboard and the
## leaders are level, it's a draw.
##
## 2v2 (four crews, GameConfig.partner): two SIDES of two partners. Partners
## don't fight (they walk round each other), each sees what the other's crew
## sees, a carrier can hand a chest to a partner's sailor and load it aboard
## either partner's ship, and the win rule above is counted per side: the
## partners' chests add up. In a free-for-all every crew is its own side.

signal fog_changed
signal holes_changed
signal status_changed(text: String) ## the local viewer's status line changed
signal selection_changed
signal path_changed
signal turn_changed
signal game_won
signal duel_changed
signal duel_resolved(text: String)
signal offer_changed

const NAVS := Character.Team.NAVS
const PIRATES := Character.Team.PIRATES
const TEAM_NAMES := ["NAVS", "Pirates", "Corsairs", "Buccaneers"]
## `winner` when nobody won: the game stopped (the host left), or a draw.
const NOBODY := -1
const DRAW := -2

var grid: TerrainGrid
var mode: GameConfig.Mode = GameConfig.Mode.SOLO
## False on the guest: its copy only mirrors what the host sends.
var is_authority := true
## More than one crew on the island (the name is from when there were two).
var two_teams := false
## How many crews are playing (1 when practising alone), and who sails each:
## GameConfig.Ctrl per team. Left empty, setup() fills it in from the mode.
var team_count := 1
var ctrl: Array = []
## On a guest: the crew this machine plays.
var guest_team: int = PIRATES
## The crew that moves first (it changes from game to game in a match).
var first_team := 0
## 2v2: the side each crew is on (GameConfig.sides()). Empty: free-for-all,
## every crew its own side.
var sides: Array = []
## Sharing a computer: whose view is on the screen. It follows the turn, but
## stays with the last person to play while the computer takes its turn.
var _hotseat_view := 0
## A hosted game holds still until the guest has landed.
var started := true

## Everyone on the island, both teams. A person's index here is their id, and
## is the same on both machines because both build the rosters identically.
var characters: Array[Character] = []
var active_by_team: Array = [null, null, null, null]
var current_team: int = NAVS

var x_markers: Array[Vector2i] = [] # Treasure Chest Markers (the red X's)
var buried: Dictionary = {}         # dig cell -> marker it belongs to (unfound only)
var dropped: Dictionary = {}        # cell -> chests lying there, dropped by a captured carrier
var ships: Array[Vector2i] = []

var turn := 1
var chests_total := 0
var delivered := [0, 0]
var won := false
var winner := -1
var revealed: Array = [{}, {}]      # per team: Set of Vector2i ever seen
var seen: Array = [{}, {}]          # per team: Set of rival ids in sight right now
var dug_cells: Array[Vector2i] = [] # holes opened so far
var captures: Array = []            # [cell, team of the captured] — sword-and-hat markers

## The fight in progress, or empty. a/d = attacker/defender ids, ac/dc = their
## choices (-1 until made), t = seconds the defender has been deciding.
var duel := {}
var duel_seq := 0
var duel_text := ""
var duel_teams := []                # the two crews in the last fight that ended

## A chest hand-off waiting for its team's answer, or empty: from/to = the
## carrier and the team-mate next to them who offered to take it.
var offer := {}
## A campaign island's goal (see Campaign): "" for the usual race, "rescue"
## (free the captive and walk them onto the NAVS' ship) or "chart" (get the
## Star Chart aboard). With a goal, chests can't win it for the NAVS, though
## a rival can still win on chests.
var goal := ""
## The turn clock: the game's limit on each player's turn
## (GameConfig.turn_seconds, chosen when the game is set up; 0 = none), and
## the seconds left in this turn, or -1 when no clock runs (no limit, or the
## computer's turn). Whoever runs the game counts it down here (_tick_clock);
## guests get it in every snapshot and count down between them (clock_left).
## When it runs out the turn passes on.
var turn_limit := 0.0
var turn_clock := -1.0
var _clock_at := 0
var clock_hold := false ## players sharing a computer: held while the hand-over screen is up
var _warned := {}
signal time_ran_out(team: int)
## The tutorial: the first dig beside an X that still has its chest finds it.
var kind_digs := false
## Crews whose player has finished the campaign: their ships fly the gold
## flag. Worked out by whoever runs the game, sent to everyone in snapshots.
var captains: Array = []
var captive_id := -1                # rescue: the NAVS sailor held captive
## Rescue: the rival sailors standing guard over the captive (ids). Nobody
## can cut her free while one of them, or any rival, stands beside her.
var guards := {}
var _guard_warned := -1
## Rival sailors with a post to keep (the captive's guards, ambushers):
## id -> [the cell, how far from it they'll go after someone, whether they
## stand beside it (guards) rather than on it (ambushers)]. ComputerPlayer
## keeps them there.
var posts := {}
## Rescue: the NAVS' outpost, where a sailor ending a turn within a square
## of it gets double their usual rest; and the stockade round the captive.
var outpost := Vector2i(-1, -1)
var pen := Vector2i(-1, -1)
var pen_gate := Vector2i(-1, -1)
## A stronghold (Campaign "fort"): a big stockade by the rivals' ship with one
## gate, the hoard from the raid lying inside it as chests on the ground, and
## guards posted at the gate. The computer crews leave the hoard where it is
## (ComputerPlayer), so it's there for the NAVS to take. fort_chests: how many
## chests the hoard started with, counted in chests_total.
var fort := Vector2i(-1, -1)
var fort_gate := Vector2i(-1, -1)
var fort_chests := 0
var _base_chests := 0
var chart_spot := Vector2i(-1, -1)  # chart: where it's buried, while it is
var chart_marker := Vector2i(-1, -1) # chart: its X, drawn gold
var chart_carrier := -1             # chart: who has it in their arms
var chart_dropped := Vector2i(-1, -1) # chart: lying where a captured carrier dropped it
signal goal_changed
## People walking over to a carrying team-mate to take their chest: the
## walker's id -> the carrier's id. When they arrive they ask for it.
var meeting := {}

## Online, either player can pause the game for both; nothing moves and no
## clock runs until someone resumes. (On one computer the menu freezes the
## whole scene instead.) paused_by = the team that paused.
var paused := false
var paused_by := -1
## paused_by while the game waits for a player who lost their connection.
const HELD := -2

## Each person's record for the results page, by id: squares walked, holes
## dug, chests found and got aboard, captures, and fights won / tied / lost.
var tally: Array = []
var win_reason := ""

var status: Array = ["", ""]
## Walking and digging speed on the moving crew's turn, for its people that a
## person on another crew can and can't see. The computer player turns both up
## on its turn — a little in sight, a lot out of it — so you aren't left
## waiting on an empty map. Ending a turn puts them back to 1.
var seen_pace := 1.0
var unseen_pace := 1.0
## Share of stamina each team recovers at the start of its turn. Easy computer
## pirates get two-thirds, as the original's easier pirates had less energy.
var rest_scale := [1.0, 1.0, 1.0, 1.0]
var rng := RandomNumberGenerator.new()
var _dirty := false
## Host: the fog last sent to each guest's crew, so it only goes again when it
## has changed (a four-crew island's fog is several kilobytes).
var _sent_fog := {}
## Crews already announced as wiped out.
var _out := {}

## The selected person of whoever is looking at this screen.
var active: Character:
	get:
		return active_by_team[viewer_team()]

func setup(_grid: TerrainGrid, people: Array[Character]) -> void:
	grid = _grid
	characters = people
	team_count = 1
	for i in characters.size():
		characters[i].id = i
		tally.append({"steps": 0, "holes": 0, "found": 0, "aboard": 0, "captures": 0, "tied": 0, "lost": 0})
		team_count = maxi(team_count, int(characters[i].team) + 1)
	if mode != GameConfig.Mode.SOLO:
		team_count = maxi(team_count, 2)
	team_count = mini(team_count, Character.MAX_TEAMS)
	two_teams = team_count > 1
	if ctrl.size() < team_count:
		ctrl = _default_ctrl()
	delivered = []
	revealed = []
	seen = []
	status = []
	for t in team_count:
		delivered.append(0)
		revealed.append({})
		seen.append({})
		status.append("")
	# A hosted game waits for every guest; a guest waits for the host to say so.
	started = not _hosting() and mode != GameConfig.Mode.GUEST
	rng.randomize()
	# The island decides where its own landmarks go — it's generated, so nothing
	# can be hard-coded to fixed coordinates any more.
	x_markers = grid.markers.duplicate()
	ships.clear()
	for t in team_count:
		ships.append(grid.ships[t] if t < grid.ships.size() else grid.ships[0])
	# One chest per X, buried in one of the 8 surrounding squares, always in
	# clear meadow as in the original. Which neighbour is decided by the island
	# seed, so both players in a networked game dig the same island.
	var chest_rng := RandomNumberGenerator.new()
	chest_rng.seed = grid.island_seed
	for m in x_markers:
		buried[_buried_spot(m, chest_rng)] = m
	chests_total = buried.size()
	_base_chests = chests_total
	for t in _teams():
		active_by_team[t] = _members(t)[0] if not _members(t).is_empty() else null
	first_team = clampi(first_team, 0, team_count - 1)
	current_team = first_team if not _members(first_team).is_empty() else NAVS
	_hotseat_view = current_team if is_person(current_team) else _first_person()
	reset_turn_clock()
	refresh_captains()
	_refresh_vision()

## Who sails each crew when nobody said: from the way we're playing.
func _default_ctrl() -> Array:
	var out := []
	for t in team_count:
		var c := GameConfig.Ctrl.HUMAN
		match mode:
			GameConfig.Mode.COMPUTER:
				c = GameConfig.Ctrl.HUMAN if t == NAVS else GameConfig.Ctrl.COMPUTER
			GameConfig.Mode.HOST, GameConfig.Mode.GUEST:
				c = GameConfig.Ctrl.HUMAN if t == NAVS else GameConfig.Ctrl.FRIEND
			GameConfig.Mode.SERVER:
				c = GameConfig.Ctrl.FRIEND
		out.append(c)
	return out

func _buried_spot(marker: Vector2i, chest_rng: RandomNumberGenerator) -> Vector2i:
	var options: Array[Vector2i] = []
	for n in grid.neighbours(marker):
		if grid.is_meadow(n) and not buried.has(n):
			options.append(n)
	if options.is_empty():
		return marker
	return options[chest_rng.randi() % options.size()]

# --- who is who ------------------------------------------------------------

## Which team this screen shows: the host and a single player see the NAVS,
## a guest their own crew, and a shared computer whoever's turn it is (or, on
## the computer's turn, whoever played last).
func viewer_team() -> int:
	match mode:
		GameConfig.Mode.GUEST:
			return guest_team
		GameConfig.Mode.HOTSEAT:
			return _hotseat_view
	return NAVS

func is_local_team(team: int) -> bool:
	match mode:
		GameConfig.Mode.HOTSEAT:
			return is_person(team)
		GameConfig.Mode.GUEST:
			return team == guest_team
		GameConfig.Mode.SERVER:
			return false # a dedicated server sails no crew of its own
	return team == NAVS

## This copy runs the game for players over the network: hosting, or a
## dedicated server.
func _hosting() -> bool:
	return mode == GameConfig.Mode.HOST or mode == GameConfig.Mode.SERVER

## Sailed by a person (here or over the network) rather than the computer.
func is_person(team: int) -> bool:
	return team >= 0 and team < ctrl.size() and int(ctrl[team]) != GameConfig.Ctrl.COMPUTER

func is_computer(team: int) -> bool:
	return team >= 0 and team < ctrl.size() and int(ctrl[team]) == GameConfig.Ctrl.COMPUTER

## Crews sailed by friends over the network (the host sends each its own view).
func remote_teams() -> Array:
	var out := []
	for t in team_count:
		if t < ctrl.size() and int(ctrl[t]) == GameConfig.Ctrl.FRIEND:
			out.append(t)
	return out

## How many crews people sail (at this computer or over the network).
func human_count() -> int:
	var n := 0
	for t in team_count:
		if is_person(t):
			n += 1
	return n

func _first_person() -> int:
	for t in team_count:
		if is_person(t):
			return t
	return NAVS

func _teams() -> Array:
	return range(team_count)

## Crews with anyone left on the island.
func alive_teams() -> Array:
	return _teams().filter(func(t: int) -> bool: return not _members(t).is_empty())

## The crews `team` plays against, in turn order after it (not its partner).
func rivals(team: int) -> Array:
	var out := []
	for i in range(1, team_count):
		var t := (team + i) % team_count
		if not allies(team, t):
			out.append(t)
	return out

func side_of(team: int) -> int:
	return int(sides[team]) if team >= 0 and team < sides.size() else team

## The same crew, or partners in 2v2.
func allies(a: int, b: int) -> bool:
	return a == b or (a >= 0 and b >= 0 and side_of(a) == side_of(b))

## The other crew on `team`'s side in 2v2 (none in a free-for-all).
func partners(team: int) -> Array:
	return _teams().filter(func(t: int) -> bool: return t != team and allies(t, team))

## "the NAVS", or in 2v2 "the NAVS and the Corsairs".
func side_name(team: int) -> String:
	var names := [TEAM_NAMES[team]]
	for t in partners(team):
		names.append(TEAM_NAMES[t])
	return " and the ".join(names)

## Chests aboard for `team`'s side: in 2v2 the partners' add up.
func side_delivered(team: int) -> int:
	var n := 0
	for t in _teams():
		if allies(t, team):
			n += int(delivered[t])
	return n

## Anyone on `team`'s side still on the island.
func side_alive(team: int) -> bool:
	for t in _teams():
		if allies(t, team) and not _members(t).is_empty():
			return true
	return false

func _members(team: int) -> Array[Character]:
	var out: Array[Character] = []
	for c in characters:
		if c.team == team and not c.captured:
			out.append(c)
	return out

## The next crew in turn order — with two crews, simply the opponent.
func other(team: int) -> int:
	return (team + 1) % maxi(team_count, 2)

## Whether anyone sailed by a person, on a crew other than c's, can see c.
## (A partner always can.)
func _watched(c: Character) -> bool:
	for t in team_count:
		if t != c.team and is_person(t) and seen[t].has(c.id):
			return true
	return false

# --- the clock -------------------------------------------------------------

func _process(delta: float) -> void:
	if not is_authority:
		return
	_tick_clock(delta)
	if not won and started and not paused:
		if not duel.is_empty():
			_tick_duel(delta)
		else:
			for c in characters:
				if c.captured or c.stats == null:
					continue
				var d := delta
				if c.team == current_team:
					d *= seen_pace if _watched(c) else unseen_pace
				if c.digging:
					_update_dig(c, d)
				elif c.team == current_team:
					_follow_path(c, d)
	_flush()

func _update_dig(c: Character, delta: float) -> void:
	c.dig_elapsed += delta
	c.dig_progress = clampf(c.dig_elapsed / 1.0, 0.0, 1.0)
	_mark()
	if c.dig_elapsed >= 1.0:
		_end_dig(c)

## Walks a character along its orders, one square at a time, paced by their
## speed. Each square costs energy by terrain and stance; when they can't afford
## the next one they simply stop — there is no waiting for regen inside a turn.
func _follow_path(c: Character, delta: float) -> void:
	if c.path.is_empty():
		c.moving = false
		return
	c.step_timer -= delta
	if c.step_timer > 0.0:
		return
	var next: Vector2i = c.path[0]
	var occupant := _occupant(next)
	var dest: Vector2i = c.path[c.path.size() - 1]
	if occupant != null and not allies(occupant.team, c.team):
		# Ran into an opponent: both stop, and it's a sword fight — unless
		# it's one we can see and aren't heading for, who we walk round.
		var avoid: bool = seen[c.team].has(occupant.id) and next != dest
		var around: Array[Vector2i] = []
		if avoid:
			around = _route(c, dest)
		if around.is_empty() or around[0] == next:
			_bump(c, occupant)
			return
		c.path = around
		next = c.path[0]
		occupant = _occupant(next)
	if not grid.is_walkable(next) or occupant != null or (_held_captive() != null and next == _held_captive().cell):
		# A team-mate (or a partner) stepped into our lane — walk around them
		# rather than give up.
		var rerouted := _route(c, dest)
		if rerouted.is_empty():
			_clear_path(c)
			if c == active_by_team[c.team]:
				announce(c.team, "Path blocked.")
			return
		c.path = rerouted
		next = c.path[0]
		occupant = _occupant(next)
		if occupant != null and not allies(occupant.team, c.team):
			_bump(c, occupant)
			return
	var cost := _step_cost(c, next)
	if c.energy < cost:
		_clear_path(c)
		if c == active_by_team[c.team]:
			announce(c.team, "%s is out of energy. End the turn to rest." % c.stats.person_name)
		return
	c.energy -= cost
	c.path.remove_at(0)
	c.move_to(next)
	tally[c.id].steps += 1
	c.step_timer = c.stats.step_time()
	_refresh_vision()
	fog_changed.emit()
	path_changed.emit()
	_mark()
	_check_pickup(c, next)
	_check_deliver(c, next)
	_check_rescue(c)
	_try_free()
	if won:
		return
	if c.path.is_empty():
		c.moving = false
		_arrive_at_meeting(c)
		# Arriving means you stop and stand up. Without this the character
		# stayed in RUNNING stance for ever, pinning vision at 25% — which is
		# why the fog stopped clearing once anyone had moved.
		c.stance = Character.Stance.STANDING
		_refresh_vision()
		fog_changed.emit()
		if c == active_by_team[c.team]:
			announce(c.team)

## Energy for one square. Carrying a chest doubles it (DESIGN_REFERENCE.md §6).
func _step_cost(c: Character, cell: Vector2i) -> float:
	var cost := grid.move_cost(cell, c.stance == Character.Stance.CRAWLING)
	if c.carrying:
		cost *= 2.0
	return cost

## The way for `c` to `dest`: round team-mates, and round any opponent their
## crew can see right now unless that's who they're heading for (clicking an
## opponent still attacks). Opponents nobody can see aren't dodged: you walk
## into them. If the only way passes a visible opponent, that's the way.
func _route(c: Character, dest: Vector2i) -> Array[Vector2i]:
	var blocked := _blocked_for(c)
	var with_rivals := blocked.duplicate()
	for id in seen[c.team]:
		var o := characters[int(id)]
		if not o.captured and o.cell != dest and not allies(o.team, c.team):
			with_rivals[o.cell] = true
	var way := grid.find_path(c.cell, dest, with_rivals)
	return way if not way.is_empty() else grid.find_path(c.cell, dest, blocked)

## Routes go around your own team-mates (and a partner's); _route() also goes
## round opponents in sight.
func _blocked_for(c: Character) -> Dictionary:
	var out := {}
	for o in characters:
		if o != c and not o.captured and allies(o.team, c.team):
			out[o.cell] = true
	if _held_captive() != null:
		out[_held_captive().cell] = true
	return out

func _occupant(cell: Vector2i) -> Character:
	for c in characters:
		if c.cell == cell and not c.captured:
			return c
	return null

# --- intents ---------------------------------------------------------------

## Every player action arrives here: from this machine's mouse and keyboard, or
## (on the host) from the guest over the network. On the guest it is simply
## forwarded to the host, which decides.
func intent(team: int, kind: String, args: Array = []) -> void:
	if not is_authority:
		Net.send_intent(kind, args)
		return
	if team < 0 or team >= team_count:
		return
	var cell_arg: Variant = args[0] if args.size() == 1 and args[0] is Vector2i else null
	var int_arg: int = int(args[0]) if args.size() == 1 and args[0] is int else -1
	match kind:
		"select":
			if cell_arg != null:
				request_select(team, cell_arg)
		"deselect":
			request_deselect(team)
		"move":
			if cell_arg != null:
				request_move_order(team, cell_arg)
		"stance":
			if int_arg >= 0 and int_arg <= Character.Stance.CRAWLING:
				request_stance(team, int_arg)
		"dig":
			request_dig(team)
		"end_turn":
			request_end_turn(team)
		"duel":
			if int_arg >= 0:
				duel_choose(team, int_arg)
		"offer":
			if cell_arg != null:
				request_offer(team, cell_arg)
		"fetch":
			if cell_arg != null:
				request_fetch(team, cell_arg)
		"handoff":
			if args.size() == 1 and args[0] is bool:
				request_handoff(team, args[0])
		"pause":
			if args.size() == 1 and args[0] is bool:
				request_pause(team, args[0])

## Whether `team` may give orders right now; explains why not if it can't.
func _can_act(team: int) -> bool:
	if won:
		return false
	if not started:
		announce(team, "Waiting for everyone to come ashore...")
		return false
	if paused:
		announce(team, "The game is paused.")
		return false
	if not duel.is_empty():
		announce(team, "Finish the sword fight first.")
		return false
	if not offer.is_empty() and characters[int(offer.from)].team == team:
		announce(team, "Hand over the chest, or keep it, first.")
		return false
	if two_teams and team != current_team:
		announce(team, "The %s are moving. Wait for your turn." % TEAM_NAMES[current_team])
		return false
	return true

## Selecting is allowed any time — on the other side's turn too — so you can
## look over your people while you wait.
func request_select(team: int, cell: Vector2i) -> bool:
	if won:
		return false
	var c := _occupant(cell)
	if c == null or c.team != team:
		return false
	active_by_team[team] = c
	selection_changed.emit()
	announce(team)
	return true

func request_deselect(team: int) -> void:
	active_by_team[team] = null
	selection_changed.emit()
	_mark()

## Click the map to send the selected person there. Standing people break into
## a run automatically — you only ever move by running or crawling. Clicking an
## opponent sends them to attack: they march until they run into them.
func request_move_order(team: int, target: Vector2i) -> void:
	if not _can_act(team):
		return
	var a: Character = active_by_team[team]
	if a == null or a.digging:
		return
	if not grid.is_walkable(target):
		announce(team, "They can't walk there.")
		return
	var occupant := _occupant(target)
	if (occupant != null and allies(occupant.team, team)) or (_held_captive() != null and target == _held_captive().cell):
		announce(team, "Someone's already there.")
		return
	var new_path := _route(a, target)
	if new_path.is_empty():
		announce(team, "No route to that spot.")
		return
	_start_walk(a, new_path)
	meeting.erase(a.id)
	announce(team, "On their way...")

func _start_walk(a: Character, new_path: Array[Vector2i]) -> void:
	if a.stance == Character.Stance.STANDING:
		a.stance = Character.Stance.RUNNING
	a.path = new_path
	a.step_timer = 0.0
	a.moving = true
	path_changed.emit()

func _clear_path(c: Character) -> void:
	meeting.erase(c.id)
	c.path.clear()
	c.moving = false
	path_changed.emit()
	_mark()

## Stance is free to change and governs vision, stealth, and move cost.
func request_stance(team: int, stance: Character.Stance) -> void:
	if not _can_act(team):
		return
	var a: Character = active_by_team[team]
	if a == null or a.digging:
		return
	a.stance = stance
	if stance == Character.Stance.STANDING:
		_clear_path(a)
	_refresh_vision()
	fog_changed.emit()
	var names := {
		Character.Stance.STANDING: "standing — best view",
		Character.Stance.RUNNING: "running — fast, but blind and easily seen",
		Character.Stance.CRAWLING: "crawling — slow and costly, but unseen",
	}
	announce(team, "%s is %s." % [a.stats.person_name, names[stance]])

func request_dig(team: int) -> void:
	if not _can_act(team):
		return
	var a: Character = active_by_team[team]
	if a == null or a.digging or a.carrying:
		return
	_clear_path(a)
	var cost := a.stats.dig_cost()
	if a.energy < cost:
		announce(team, "Not enough energy to dig (needs %d)." % int(cost))
		return
	a.energy -= cost
	a.begin_dig(a.cell)
	_sfx(AudioManifest.DIG, team)
	announce(team, "Digging...")

## End of turn. Alone, everyone rests and goes again. With rivals the next
## crew still on the island takes its turn, and THEY rest: energy equal to
## stamina, capped at 100. The turn number goes up once every crew has moved.
func request_end_turn(team: int) -> void:
	if not _can_act(team):
		return
	_pass_turn(team)

func _pass_turn(team: int) -> void:
	for c in characters:
		if c.team == team:
			_clear_path(c)
	seen_pace = 1.0
	unseen_pace = 1.0
	if two_teams:
		var next := _next_team(team)
		if _round_pos(next) <= _round_pos(team):
			turn += 1
		current_team = next
		if mode == GameConfig.Mode.HOTSEAT and is_person(current_team):
			_hotseat_view = current_team
	else:
		turn += 1
	for c in _members(current_team):
		c.energy = minf(c.energy + c.stats.stamina * float(rest_scale[current_team]) * rest_bonus(c), CharacterStats.MAX_ENERGY)
	reset_turn_clock()
	turn_changed.emit()
	_refresh_vision()
	fog_changed.emit()
	if two_teams:
		_sfx(AudioManifest.YOUR_TURN, current_team, active_by_team[current_team])
		for t in _teams():
			if t == current_team:
				announce(t, "Your turn — everyone rested.")
			else:
				announce(t, "The %s are moving. Wait for your turn." % TEAM_NAMES[current_team])
	else:
		announce(team, "Turn %d — everyone rested." % turn)

## The next crew after `team` that still has anyone on the island.
func _next_team(team: int) -> int:
	for i in range(1, team_count + 1):
		var t := (team + i) % team_count
		if not _members(t).is_empty():
			return t
	return team

## Where a crew comes in the round, counting from whoever moved first.
func _round_pos(team: int) -> int:
	return (team - first_team + team_count) % team_count

# --- pausing and saving ------------------------------------------------------

## Online pause: either side may pause, either may resume.
func request_pause(team: int, on: bool) -> void:
	if won or paused == on or paused_by == HELD:
		return
	paused = on
	paused_by = team if on else -1
	for t in _teams():
		status[t] = ("Paused by the %s. Open the menu (Esc) to resume." % TEAM_NAMES[team]) if on else _default_status(t)
	status_changed.emit(status[viewer_team()])
	_mark()

## A game can be saved once everyone is standing still — no one walking or
## digging, no sword fight or hand-off waiting. Returns why not, or "".
func save_blocker() -> String:
	if won:
		return "The game is over."
	if not duel.is_empty():
		return "Finish the sword fight first."
	if not offer.is_empty():
		return "Answer the hand-off first."
	for c in characters:
		if not c.captured and (c.digging or not c.path.is_empty()):
			return "Wait until everyone has stopped moving."
	return ""

## Everything needed to pick this game up again later (the island itself comes
## back from its seed).
func save_state() -> Dictionary:
	var people := []
	for c in characters:
		people.append({"stats": c.stats.to_dict(), "team": c.team, "cell": c.cell, "energy": c.energy,
			"stance": c.stance, "carrying": c.carrying, "captured": c.captured, "facing": c.facing,
			"turncoat": c.turncoat})
	var hidden := []
	for spot in buried:
		hidden.append([spot, buried[spot]])
	var act := []
	var fog := []
	for t in team_count:
		act.append(active_by_team[t].id if active_by_team[t] != null else -1)
		fog.append(_pack(revealed[t]))
	return {"people": people, "buried": hidden, "dropped": _drops(), "dug": dug_cells, "captures": captures, "tally": tally,
		"delivered": delivered, "turn": turn, "cur": current_team, "act": act, "first": first_team,
		"view": _hotseat_view, "revealed": fog, "goal": {"goal": goal, "captive": captive_id, "guards": guards.keys(), "posts": _posts_list(),
			"outpost": outpost, "pen": pen, "gate": pen_gate, "spot": chart_spot,
			"marker": chart_marker, "carrier": chart_carrier, "dropped": chart_dropped,
			"fort": fort, "fort_gate": fort_gate, "fort_chests": fort_chests}}

## Puts a saved game back. The characters must already have been built from
## the saved people, in the same order.
func load_state(d: Dictionary) -> void:
	var people: Array = d.get("people", [])
	for i in mini(people.size(), characters.size()):
		var p: Dictionary = people[i]
		var c := characters[i]
		c.cell = p.cell
		c.position = Character.cell_to_pos(p.cell)
		c.energy = float(p.energy)
		c.stance = int(p.stance)
		c.set_carrying(bool(p.carrying))
		c.captured = bool(p.captured)
		c.facing = float(p.get("facing", 1.0))
	buried.clear()
	for pair in d.get("buried", []):
		buried[pair[0]] = pair[1]
	_set_drops(d.get("dropped", []))
	dug_cells.assign(d.get("dug", []))
	captures = d.get("captures", [])
	var saved_tally: Array = d.get("tally", [])
	if saved_tally.size() == characters.size():
		tally = saved_tally
	var saved_delivered: Array = d.get("delivered", [])
	for t in mini(saved_delivered.size(), team_count):
		delivered[t] = int(saved_delivered[t])
	turn = int(d.get("turn", 1))
	current_team = clampi(int(d.get("cur", NAVS)), 0, team_count - 1)
	first_team = clampi(int(d.get("first", 0)), 0, team_count - 1)
	var act: Array = d.get("act", [])
	for t in mini(act.size(), team_count):
		var id := int(act[t])
		active_by_team[t] = characters[id] if id >= 0 and id < characters.size() and not characters[id].captured else null
	var rev: Array = d.get("revealed", [])
	for t in mini(rev.size(), team_count):
		revealed[t] = _unpack(rev[t])
	for t in _teams():
		if _members(t).is_empty():
			_out[t] = true
	var g: Variant = d.get("goal", {})
	if g is Dictionary and not g.is_empty():
		goal = _goal_named(str(g.get("goal", "")))
		captive_id = int(g.get("captive", -1)) if int(g.get("captive", -1)) < characters.size() else -1
		outpost = g.get("outpost") if g.get("outpost") is Vector2i else Vector2i(-1, -1)
		pen = g.get("pen") if g.get("pen") is Vector2i else Vector2i(-1, -1)
		pen_gate = g.get("gate") if g.get("gate") is Vector2i else Vector2i(-1, -1)
		posts = {}
		var ps: Variant = g.get("posts", [])
		if ps is Array:
			for p in ps:
				if p is Array and p.size() == 4 and p[1] is Vector2i and int(p[0]) >= 0 and int(p[0]) < characters.size():
					posts[int(p[0])] = [p[1], int(p[2]), bool(p[3])]
		guards = {}
		var gs: Variant = g.get("guards", [])
		if gs is Array:
			for id in gs:
				if (id is int or id is float) and int(id) >= 0 and int(id) < characters.size():
					guards[int(id)] = true
		chart_spot = g.get("spot", Vector2i(-1, -1)) if g.get("spot") is Vector2i else Vector2i(-1, -1)
		chart_marker = g.get("marker", Vector2i(-1, -1)) if g.get("marker") is Vector2i else Vector2i(-1, -1)
		chart_dropped = g.get("dropped", Vector2i(-1, -1)) if g.get("dropped") is Vector2i else Vector2i(-1, -1)
		var carrier := int(g.get("carrier", -1))
		_set_chart_carrier(carrier if carrier < characters.size() else -1)
		fort = g.get("fort") if g.get("fort") is Vector2i else Vector2i(-1, -1)
		fort_gate = g.get("fort_gate") if g.get("fort_gate") is Vector2i else Vector2i(-1, -1)
		fort_chests = clampi(int(g.get("fort_chests", 0)), 0, 20) if fort.x >= 0 else 0
		chests_total = _base_chests + fort_chests
	_hotseat_view = clampi(int(d.get("view", current_team)), 0, team_count - 1)
	if is_person(current_team):
		_hotseat_view = current_team
	_refresh_vision()
	fog_changed.emit()
	holes_changed.emit()
	selection_changed.emit()
	reset_turn_clock() # a resumed game: this turn starts afresh
	turn_changed.emit()
	announce()

## Which crews fly the Captain's Golden Rooster flag: this computer's own crew if its
## player has finished the campaign (not when people share the computer:
## whose would it be?), and each online friend's who said so in their hello.
func refresh_captains() -> Array:
	if not is_authority:
		return captains
	var out := []
	for t in team_count:
		if is_computer(t):
			continue
		if mode == GameConfig.Mode.HOST or mode == GameConfig.Mode.SERVER:
			var peer := Net.peer_for(t)
			if peer != 0:
				if Net.updater != null and Net.updater.is_captain(peer):
					out.append(t)
				continue
		if mode != GameConfig.Mode.HOTSEAT and mode != GameConfig.Mode.SERVER and is_local_team(t) and GameConfig.is_captain():
			out.append(t)
	captains = out
	return out

# --- the turn clock ---------------------------------------------------------

## A new turn: the full limit for a player's turn, no clock for the computer's.
func reset_turn_clock() -> void:
	turn_clock = turn_limit if turn_limit > 0.0 and is_person(current_team) else -1.0
	_clock_at = Time.get_ticks_msec()
	_warned = {}
	_mark()

## Counts the player's turn down (only where the game runs), with warnings
## at 30 and 10 seconds. It waits while the crews come ashore, while paused,
## and behind a shared computer's hand-over screen.
func _tick_clock(delta: float) -> void:
	if not is_authority or turn_clock < 0.0 or won or not started or paused or clock_hold:
		return
	if not is_person(current_team):
		turn_clock = -1.0
		return
	var before := turn_clock
	turn_clock = maxf(turn_clock - delta, 0.0)
	for mark in [30, 10]:
		if turn_clock <= mark and before > mark and turn_limit > mark + 5:
			announce(current_team, "%d seconds left in this turn." % mark)
	if int(before) != int(turn_clock) and int(turn_clock) % 15 == 0:
		_mark() # a fresh snapshot now and then keeps everyone's countdown in step
	if turn_clock <= 0.0:
		_time_up()

## Out of time: an unanswered hand-off is a no, an unchosen sword-fight move
## is a retreat (attacking) or caution (defending), and once the fight is
## settled the turn passes on.
func _time_up() -> void:
	var team := current_team
	if not offer.is_empty():
		request_handoff(characters[int(offer.from)].team, false)
	if not duel.is_empty():
		var a: Character = characters[int(duel.a)]
		var d: Character = characters[int(duel.d)]
		if int(duel.ac) < 0 and a.team == team:
			duel_choose(a.team, Combat.Choice.RETREAT)
		if int(duel.dc) < 0 and d.team == team:
			duel_choose(d.team, Combat.Choice.CAUTIOUS)
		return # the fight plays out; the turn passes once it's over
	if won or current_team != team:
		return
	time_ran_out.emit(team)
	_pass_turn(team)
	announce(team, "Out of time: the turn has passed on.")

## Seconds left in this turn as this screen should show them, or -1 for no
## clock. A guest counts down from the last snapshot, except while paused or
## before everyone is ashore (the server's clock waits then too).
func clock_left() -> float:
	if turn_clock < 0.0:
		return -1.0
	if is_authority or paused or not started or won:
		return maxf(turn_clock, 0.0)
	return maxf(turn_clock - (Time.get_ticks_msec() - _clock_at) / 1000.0, 0.0)

## "2:41".
static func clock_text(seconds: float) -> String:
	var s := ceili(maxf(seconds, 0.0))
	return "%d:%02d" % [s / 60, s % 60]

# --- campaign goals ---------------------------------------------------------

## Sets up a campaign island's goal after setup(): "rescue" holds `captive`
## (a NAVS character, already captured) where they stand; "chart" picks the
## X nearest the pirates' ship and buries the Star Chart by it.
func setup_goal(kind: String, captive: int = -1) -> void:
	goal = _goal_named(kind)
	if kind == "rescue" and captive >= 0 and captive < characters.size():
		captive_id = captive
		characters[captive].captured = true
	if kind == "chart" and not buried.is_empty():
		var best := Vector2i(-1, -1)
		var best_d := INF
		for spot in buried:
			var d := Vector2(buried[spot] - ships[PIRATES]).length()
			if d < best_d or (d == best_d and (spot.x < best.x or (spot.x == best.x and spot.y < best.y))):
				best_d = d
				best = spot
		chart_spot = best
		chart_marker = buried[best]
	goal_changed.emit()
	announce()

## A campaign island's goal by its name in Campaign: "chests" is the usual
## race, so it's "" here. (Up to 0.13.0 it was kept as "chests", which no
## chest could win: the NAVS could never win those islands on chests.)
static func _goal_named(kind: String) -> String:
	return "" if kind == "chests" else kind

## A resumed game that should already be over (saved by 0.13.0 with every
## chest aboard, say) ends now. True if it did.
func settle_resumed() -> bool:
	return is_authority and not won and started and _check_victory()

## A stronghold goes up: its hoard lies on the ground at `hoard` (one chest a
## square), and counts towards the island's chests.
func setup_fort(center: Vector2i, gate: Vector2i, hoard: Array) -> void:
	fort = center
	fort_gate = gate
	for cell in hoard:
		dropped[cell] = int(dropped.get(cell, 0)) + 1
	fort_chests = hoard.size()
	chests_total = _base_chests + fort_chests
	holes_changed.emit() # the overlay draws chests on the ground
	goal_changed.emit()

## Inside the stronghold's fence.
func in_fort(cell: Vector2i) -> bool:
	if fort.x < 0:
		return false
	var gap: Vector2i = (cell - fort).abs()
	return maxi(gap.x, gap.y) < Campaign.FORT_RADIUS

## Double rest for a NAVS sailor at the outpost (within a square of it).
func rest_bonus(c: Character) -> float:
	if outpost.x < 0 or not allies(c.team, NAVS):
		return 1.0
	var gap: Vector2i = (c.cell - outpost).abs()
	return 2.0 if maxi(gap.x, gap.y) <= 1 else 1.0

## The rescue's captive while they're still held, or null.
func _held_captive() -> Character:
	if captive_id < 0 or captive_id >= characters.size():
		return null
	var c := characters[captive_id]
	return c if c.captured else null

## A NAVS sailor beside the held captive cuts them free, unless a guard (any
## rival) stands beside her too: they have to be dealt with first. Freed,
## she joins the crew where she stands, rested enough to move. The captive
## stepping onto the NAVS' ship wins the island.
func _check_rescue(c: Character) -> void:
	if goal != "rescue" or captive_id < 0:
		return
	var held := _held_captive()
	if held != null and allies(c.team, NAVS):
		var gap: Vector2i = (held.cell - c.cell).abs()
		if maxi(gap.x, gap.y) <= 1:
			var guard := guard_beside_captive()
			if guard != null:
				if _guard_warned != turn:
					_guard_warned = turn
					announce(NAVS, "%s stands guard over %s: capture the guards beside her, or draw them off, before you can cut her free." % [
						guard.stats.person_name, held.stats.person_name])
				return
			_free_captive(c)
		return
	if c.id == captive_id and not c.captured and c.cell == ships[NAVS]:
		_win(NAVS, "%s is safe aboard" % c.stats.person_name)

## Smugglers' Cove ("sweep"): won once every chest is aboard the NAVS' ship
## and every rival is captured. True if that just won it.
func _check_sweep() -> bool:
	if goal != "sweep" or won or int(delivered[NAVS]) < chests_total:
		return false
	for t in rivals(NAVS):
		if not _members(t).is_empty():
			return false
	_win(NAVS, "every chest aboard and every pirate captured: now they'll talk")
	return true

## A rival standing beside the held captive, or null.
func guard_beside_captive() -> Character:
	var held := _held_captive()
	if held == null:
		return null
	for o in characters:
		if not o.captured and not allies(o.team, NAVS):
			var gap: Vector2i = (o.cell - held.cell).abs()
			if maxi(gap.x, gap.y) <= 1:
				return o
	return null

## The guards beside her are gone (captured, or drawn off): a NAVS sailor
## already standing beside her cuts her free.
func _try_free() -> void:
	if goal != "rescue" or _held_captive() == null or guard_beside_captive() != null or won:
		return
	var held := _held_captive()
	for c in characters:
		if not c.captured and c.id != captive_id and allies(c.team, NAVS):
			var gap: Vector2i = (c.cell - held.cell).abs()
			if maxi(gap.x, gap.y) <= 1:
				_free_captive(c)
				return

func _free_captive(c: Character) -> void:
	var held := _held_captive()
	if held == null:
		return
	held.captured = false
	held.energy = maxf(held.energy, 60.0)
	held.stance = Character.Stance.STANDING
	held.position = Character.cell_to_pos(held.cell)
	_clear_path(c)
	_sfx(AudioManifest.TAKE_CARRY, NAVS, held)
	announce(NAVS, "%s cut %s free! Now get her aboard your ship." % [c.stats.person_name, held.stats.person_name])
	goal_changed.emit()
	_refresh_vision()
	fog_changed.emit()
	selection_changed.emit()

func _posts_list() -> Array:
	var out := []
	for id in posts:
		out.append([id, posts[id][0], posts[id][1], posts[id][2]])
	return out

func _set_chart_carrier(id: int) -> void:
	if chart_carrier >= 0 and chart_carrier < characters.size():
		characters[chart_carrier].chart = false
		characters[chart_carrier].queue_redraw()
	chart_carrier = id
	if id >= 0:
		characters[id].chart = true
		characters[id].queue_redraw()
	goal_changed.emit()

## The whole island is mapped for `team` (a charted campaign island).
func reveal_all(team: int) -> void:
	for y in grid.height:
		for x in grid.width:
			revealed[team][Vector2i(x, y)] = true
	fog_changed.emit()

# --- handing over a chest ---------------------------------------------------

## The selected person is carrying and `cell` holds a team-mate beside them with
## empty hands: the team-mate offers to take the chest (DESIGN_REFERENCE.md §6 —
## a chest can't be put down, only handed over or loaded aboard). In 2v2 a
## partner's sailor can take it too; the carrier's player still says yes.
func request_offer(team: int, cell: Vector2i) -> void:
	if not _can_act(team):
		return
	var from: Character = active_by_team[team]
	var to := _occupant(cell)
	if from == null or to == null or to == from or not allies(to.team, team) or not from.carrying or from.digging:
		return
	_offer_chest(team, from, to)

## `to` offers to take `from`'s chest, if they're beside each other with hands
## free. `team` (the carrier's player) answers. True if the offer is made.
func _offer_chest(team: int, from: Character, to: Character) -> bool:
	var gap: Vector2i = (to.cell - from.cell).abs()
	if maxi(gap.x, gap.y) > 1:
		announce(team, "%s has to be right next to %s." % [to.stats.person_name, from.stats.person_name])
		return false
	if to.carrying:
		announce(team, "%s's hands are already full." % to.stats.person_name)
		return false
	if to.digging or from.digging or not from.carrying:
		return false
	_clear_path(from)
	_clear_path(to)
	offer = {"from": from.id, "to": to.id}
	offer_changed.emit()
	_sfx(AudioManifest.OFFER_CARRY, team, to)
	announce(team, "%s: \"You want me to carry the treasure?\"" % to.stats.person_name)
	_mark()
	return true

## With empty hands selected, clicking a team-mate who carries a chest sends
## the selected person over to them; once beside the carrier they offer to
## take it, and you answer as for any hand-off. Already beside them, they ask
## straight away.
func request_fetch(team: int, cell: Vector2i) -> void:
	if not _can_act(team):
		return
	var a: Character = active_by_team[team]
	var holder := _occupant(cell)
	if a == null or holder == null or holder == a or holder.team != team or not holder.carrying \
			or a.carrying or a.digging or a.captured:
		return
	var gap: Vector2i = (holder.cell - a.cell).abs()
	if maxi(gap.x, gap.y) <= 1:
		_offer_chest(team, holder, a)
		return
	var route := route_beside(a, holder)
	if route.is_empty():
		announce(team, "%s can't find a way to %s." % [a.stats.person_name, holder.stats.person_name])
		return
	_start_walk(a, route)
	meeting[a.id] = holder.id
	announce(team, "%s is going over to take %s's chest." % [a.stats.person_name, holder.stats.person_name])

## The cheapest way for `walker` to reach a free square right beside `holder`
## (fewest steps; ties to the first found), or empty if there's none.
func route_beside(walker: Character, holder: Character) -> Array[Vector2i]:
	var blocked := _blocked_for(walker)
	var best: Array[Vector2i] = []
	var best_cost := INF
	for n in grid.neighbours(holder.cell):
		if blocked.has(n) or not grid.is_walkable(n):
			continue
		var route := grid.find_path(walker.cell, n, blocked)
		if route.is_empty():
			continue
		var cost := 0.0
		for cell in route:
			cost += grid.move_cost(cell, walker.stance == Character.Stance.CRAWLING)
		if cost < best_cost:
			best_cost = cost
			best = route
	return best

## Someone sent to take a team-mate's chest has stopped walking: beside the
## carrier, they ask for it. If the carrier moved off or handed it on, say so.
func _arrive_at_meeting(c: Character) -> void:
	if not meeting.has(c.id):
		return
	var holder := characters[int(meeting[c.id])]
	meeting.erase(c.id)
	if holder.captured or not holder.carrying:
		announce(c.team, "%s isn't carrying the chest any more." % holder.stats.person_name)
		return
	var gap: Vector2i = (holder.cell - c.cell).abs()
	if maxi(gap.x, gap.y) > 1:
		announce(c.team, "%s moved on. Click them again to catch up." % holder.stats.person_name)
		return
	if not offer.is_empty() or not duel.is_empty():
		return
	_offer_chest(c.team, holder, c)

## The answer to a hand-off: yes passes the chest across, no keeps it where it is.
func request_handoff(team: int, accept: bool) -> void:
	if offer.is_empty() or won:
		return
	var from := characters[int(offer.from)]
	var to := characters[int(offer.to)]
	if from.team != team:
		return
	offer = {}
	offer_changed.emit()
	if accept and from.carrying and not to.carrying and not from.captured and not to.captured:
		from.set_carrying(false)
		to.set_carrying(true)
		if from.id == chart_carrier:
			_set_chart_carrier(to.id)
		if to.team == team:
			active_by_team[team] = to
		selection_changed.emit()
		_sfx(AudioManifest.TAKE_CARRY, team, to)
		announce(team, "%s: \"I'll carry it now.\"" % to.stats.person_name)
		if to.team != team:
			_sfx(AudioManifest.TAKE_CARRY, to.team, to)
			announce(to.team, "The %s handed %s a chest. Take it to your ship, or theirs." % [TEAM_NAMES[team], to.stats.person_name])
	else:
		announce(team, "%s keeps the chest." % from.stats.person_name)
	_mark()

# --- sword fights ----------------------------------------------------------

## Someone walked into an opponent. Both stop where they are and it's a fight —
## unless the walker can't fight: carriers can't attack, and attacking takes at
## least 25 energy (DESIGN_REFERENCE.md §2, §6).
func _bump(c: Character, enemy: Character) -> void:
	_clear_path(c)
	c.stance = Character.Stance.STANDING
	_refresh_vision()
	fog_changed.emit()
	if c.carrying:
		announce(c.team, "%s ran into %s — can't fight while carrying treasure." % [
			c.stats.person_name, enemy.stats.person_name])
		return
	if c.energy < CharacterStats.ATTACK_MIN_ENERGY:
		announce(c.team, "%s ran into %s — too tired to fight (needs %d energy)." % [
			c.stats.person_name, enemy.stats.person_name, int(CharacterStats.ATTACK_MIN_ENERGY)])
		return
	enemy.path.clear()
	enemy.stance = Character.Stance.STANDING
	duel = {"a": c.id, "d": enemy.id, "ac": -1, "dc": -1, "t": 0.0}
	c.fighting = true
	enemy.fighting = true
	if enemy.cell.x != c.cell.x:
		c.facing = signf(enemy.cell.x - c.cell.x)
	enemy.facing = -c.facing
	_sfx(AudioManifest.SWORD)
	duel_changed.emit()
	announce(c.team, "En garde! %s has run into %s." % [c.stats.person_name, enemy.stats.person_name])
	announce(enemy.team, "%s is attacked by %s!" % [enemy.stats.person_name, c.stats.person_name])

## Each side picks secretly; when both have, the clash resolves. The attacker
## may back off instead, at no cost, before choosing.
func duel_choose(team: int, choice: int) -> void:
	if duel.is_empty() or won or paused:
		return
	var a := characters[int(duel.a)]
	var d := characters[int(duel.d)]
	var fighting_choice := choice == Combat.Choice.CAUTIOUS or choice == Combat.Choice.AGGRESSIVE
	if team == a.team and int(duel.ac) < 0:
		if choice == Combat.Choice.RETREAT:
			_end_duel()
			announce(a.team, "%s backs away from %s." % [a.stats.person_name, d.stats.person_name])
			announce(d.team, "%s backed away." % a.stats.person_name)
			return
		if not fighting_choice:
			return
		duel.ac = choice
	elif team == d.team and int(duel.dc) < 0 and fighting_choice:
		duel.dc = choice
	else:
		return
	duel_changed.emit()
	if int(duel.ac) >= 0 and int(duel.dc) >= 0:
		_resolve_duel()
	else:
		announce(a.team)
		announce(d.team)

## A defender who doesn't answer in time defends cautiously.
func _tick_duel(delta: float) -> void:
	if int(duel.dc) >= 0:
		return
	duel.t = float(duel.t) + delta
	if int(duel.t * 4.0) != int((float(duel.t) - delta) * 4.0):
		_mark() # keep the guest's countdown moving
	if float(duel.t) >= Combat.DEFEND_TIMEOUT:
		duel_choose(characters[int(duel.d)].team, Combat.Choice.CAUTIOUS)

## The clash itself (DESIGN_REFERENCE.md §4). Strength is measured on the energy
## each fighter came in with; then both pay for their choice. A tie leaves both
## standing and weaker; otherwise the stronger is likelier to capture the other.
func _resolve_duel() -> void:
	var a := characters[int(duel.a)]
	var d := characters[int(duel.d)]
	var ta := int(a.team) # before anyone comes over to the other side
	var td := int(d.team)
	var ac := int(duel.ac)
	var dc := int(duel.dc)
	var ea := a.energy
	var ed := d.energy
	var cs_a := a.stats.combat_strength(ea)
	var cs_d := d.stats.combat_strength(ed) * (0.5 if d.carrying else 1.0) # carriers defend at half
	a.energy = maxf(0.0, ea - Combat.cost(ac))
	d.energy = maxf(0.0, ed - Combat.cost(dc))
	var styles := ["cautiously", "aggressively"]
	var text := "%s attacked %s, %s defended %s. " % [
		a.stats.person_name, styles[ac], d.stats.person_name, styles[dc]]
	var tie := Combat.tie_chance(ac, dc, ea, ed, Combat.terrain_bonus(grid, [a.cell, d.cell]))
	if rng.randf() < tie:
		tally[a.id].tied += 1
		tally[d.id].tied += 1
		text += "A tie — both come away weaker."
		_sfx(AudioManifest.TIE)
	else:
		var attacker_wins := rng.randf() < Combat.win_chance(cs_a, cs_d)
		var w := a if attacker_wins else d
		var l := d if attacker_wins else a
		tally[w.id].captures += 1
		tally[l.id].lost += 1
		if rng.randf() < _defect_chance(l, w):
			text += "%s beat %s, who threw down their sword and came over to the %s%s!" % [
				w.stats.person_name, l.stats.person_name, TEAM_NAMES[w.team], _defect(l, w)]
		else:
			text += "%s captured %s%s!" % [w.stats.person_name, l.stats.person_name, _capture(l, w)]
	_end_duel()
	duel_seq += 1
	duel_text = text
	duel_teams = [ta, td]
	announce(ta, text)
	announce(td, text)
	duel_resolved.emit(text)
	_check_wipeout()

## Vega sailing with you (campaign islands after Gallows Rock): a rival the
## NAVS beat in a fight may come over to them instead of being captured.
## The odds are best when Vega wins the fight herself, good when she's close
## by, and a long shot otherwise; posted guards are half as easy to turn.
const DEFECT_BY_VEGA := 0.40
const DEFECT_NEAR_VEGA := 0.25
const DEFECT_NEAR := 4 ## squares from the fight that count as close by
const DEFECT_ANYWHERE := 0.10
var defections := false

func _defect_chance(loser: Character, winner: Character) -> float:
	if not defections or winner.team != NAVS or allies(loser.team, NAVS) or loser.captive:
		return 0.0
	var chance := 0.0
	for c in _members(NAVS):
		if not c.stats.charismatic():
			continue
		var gap: Vector2i = (c.cell - loser.cell).abs()
		if c == winner:
			chance = maxf(chance, DEFECT_BY_VEGA)
		elif maxi(gap.x, gap.y) <= DEFECT_NEAR:
			chance = maxf(chance, DEFECT_NEAR_VEGA)
		else:
			chance = maxf(chance, DEFECT_ANYWHERE)
	if posts.has(loser.id):
		chance *= 0.5
	return chance

## `loser` comes over to `winner`'s crew where they stand, keeping any chest
## they hold (it's the NAVS' to take aboard now). Returns a phrase to finish
## the result line.
func _defect(loser: Character, winner: Character) -> String:
	var old := loser.team
	loser.fighting = false
	loser.digging = false
	_clear_path(loser)
	posts.erase(loser.id)
	guards.erase(loser.id)
	if active_by_team[old] == loser:
		active_by_team[old] = null
	loser.join_team(winner.team)
	loser.turncoat = true
	loser.stance = Character.Stance.STANDING
	winner.stats.confidence = minf(winner.stats.confidence + Combat.CONFIDENCE_FOR_WIN, 100.0)
	_sfx(AudioManifest.YOUR_TURN, winner.team, loser) # "Aye, captain!"
	selection_changed.emit()
	_refresh_vision()
	fog_changed.emit()
	var vega_won := winner.stats.charismatic()
	return (", won round by %s" % winner.stats.person_name) if vega_won else (" with a chest" if loser.carrying else "")

## Takes `loser` off the island, leaving a sword-and-hat marker. Any chest they
## carried goes to the winner — or, if the winner's hands are full, drops where
## they stood, for the next person with empty hands to walk over and pick up.
## Returns a phrase to finish the result line.
func _capture(loser: Character, winner_c: Character) -> String:
	loser.captured = true
	loser.fighting = false
	loser.digging = false
	loser.path.clear()
	captures.append([loser.cell, loser.team])
	if active_by_team[loser.team] == loser:
		active_by_team[loser.team] = null
		selection_changed.emit()
	winner_c.stats.confidence = minf(winner_c.stats.confidence + Combat.CONFIDENCE_FOR_WIN, 100.0)
	_sfx(AudioManifest.CAPTURED, loser.team)
	_refresh_vision()
	fog_changed.emit()
	if loser.id == captive_id:
		goal_changed.emit()
	if guards.has(loser.id):
		_try_free.call_deferred() # a guard down: someone beside her may cut her free now
	if not loser.carrying:
		return ""
	loser.set_carrying(false)
	var had_chart := loser.id == chart_carrier
	if not winner_c.carrying:
		winner_c.set_carrying(true)
		_sfx(AudioManifest.TREASURE, winner_c.team, winner_c)
		if had_chart:
			_set_chart_carrier(winner_c.id)
			return " and took the Star Chart"
		return " and took the treasure"
	dropped[loser.cell] = int(dropped.get(loser.cell, 0)) + 1
	if had_chart:
		_set_chart_carrier(-1)
		chart_dropped = loser.cell
		goal_changed.emit()
		holes_changed.emit()
		return " — the Star Chart fell to the ground for anyone to pick up"
	holes_changed.emit() # the overlay draws it on the ground
	return " — the chest fell to the ground for anyone to pick up"

func _end_duel() -> void:
	for key in ["a", "d"]:
		var c := characters[int(duel[key])]
		c.fighting = false
	duel = {}
	duel_changed.emit()
	_refresh_vision()
	fog_changed.emit()
	_mark()

## After a capture: a crew with nobody left is out of the game. Capture every
## rival and the island is yours, chests or not. A crew wiped out on its own
## turn (an attacker who lost) hands the turn on.
func _check_wipeout() -> void:
	if won or not two_teams:
		return
	var alive := alive_teams()
	if goal == "sweep" and not alive.is_empty() and alive.all(func(t: int) -> bool: return allies(t, NAVS)):
		# Smugglers' Cove: capturing every pirate isn't the whole job; the
		# chests must all be aboard too. Carry on alone until they are.
		if _check_sweep():
			return
		if rivals(NAVS).any(func(t: int) -> bool: return not _out.has(t)):
			announce(NAVS, "Every pirate is captured. Now get every last chest aboard, and they'll talk.")
	elif not alive.is_empty() and alive.all(func(t: int) -> bool: return allies(t, alive[0])):
		var gone: Array = rivals(alive[0])
		var reason := ("every one of the %s was captured" % TEAM_NAMES[gone[0]]) if gone.size() == 1 \
			else "every rival crew was captured"
		_win(alive[0], reason)
		return
	for t in _teams():
		if _members(t).is_empty() and not _out.has(t):
			_out[t] = true
			for o in _teams():
				if o == t:
					announce(o, "Every one of your crew has been captured. You're out of this game.")
				else:
					announce(o, "The %s have all been captured — they're out of the game." % TEAM_NAMES[t])
	if _check_victory():
		return
	if _members(current_team).is_empty():
		_pass_turn(current_team)

# --- rules -----------------------------------------------------------------

func _end_dig(c: Character) -> void:
	var cell := c.dig_cell
	c.digging = false
	c.dig_progress = 0.0
	tally[c.id].holes += 1
	if not dug_cells.has(cell):
		dug_cells.append(cell)
	holes_changed.emit()
	_mark()
	if kind_digs and not buried.has(cell):
		for spot in buried.keys():
			var gap: Vector2i = (buried[spot] - cell).abs()
			if maxi(gap.x, gap.y) <= 1 and grid.is_meadow(cell):
				buried[cell] = buried[spot]
				buried.erase(spot)
				break
	if buried.has(cell):
		buried.erase(cell)
		c.set_carrying(true)
		tally[c.id].found += 1
		c.stats.confidence = minf(c.stats.confidence + 10.0, 100.0) # digging builds confidence
		_sfx(AudioManifest.TREASURE, c.team, c)
		if cell == chart_spot:
			chart_spot = Vector2i(-1, -1)
			_set_chart_carrier(c.id)
			for t in _teams():
				if t == c.team:
					announce(t, "The Star Chart! Get it aboard your ship.")
				elif t == NAVS:
					announce(t, "The %s have dug up the Star Chart! Capture the carrier to take it back." % TEAM_NAMES[c.team])
			return
		announce(c.team, "Treasure!")
		return
	announce(c.team, "Nothing here!")

func _marker_has_chest(marker: Vector2i) -> bool:
	for spot in buried:
		if buried[spot] == marker:
			return true
	return false

## Walking onto a dropped chest with empty hands picks it up; no digging.
func _check_pickup(c: Character, cell: Vector2i) -> void:
	if c.carrying or not dropped.has(cell):
		return
	dropped[cell] = int(dropped[cell]) - 1
	if int(dropped[cell]) <= 0:
		dropped.erase(cell)
	c.set_carrying(true)
	tally[c.id].found += 1
	holes_changed.emit()
	_sfx(AudioManifest.TREASURE, c.team, c)
	if cell == chart_dropped:
		chart_dropped = Vector2i(-1, -1)
		_set_chart_carrier(c.id)
		announce(c.team, "%s picked up the Star Chart!" % c.stats.person_name)
		return
	announce(c.team, "%s picked up the dropped chest!" % c.stats.person_name)

## Dropped chests as [cell, count] pairs, for snapshots and saves.
func _drops() -> Array:
	var out := []
	for cell in dropped:
		out.append([cell, dropped[cell]])
	return out

func _set_drops(pairs: Array) -> bool:
	var before := dropped.duplicate()
	dropped.clear()
	for pair in pairs:
		dropped[pair[0]] = int(pair[1])
	return dropped != before

## A carrier reaching their ship (in 2v2, or their partner's) loads the chest.
## It counts for the carrier's crew, and so for their side.
func _check_deliver(c: Character, cell: Vector2i) -> void:
	if not c.carrying:
		return
	var aboard := false
	for t in _teams():
		if allies(t, c.team) and cell == ships[t]:
			aboard = true
	if not aboard:
		return
	c.set_carrying(false)
	delivered[c.team] += 1
	tally[c.id].aboard += 1
	if goal == "sweep":
		if not allies(c.team, NAVS):
			_win(c.team, "the %s got a chest away, so the cove's treasure can't all be yours" % TEAM_NAMES[c.team])
			return
		if _check_sweep():
			return
		var still := chests_total - int(delivered[NAVS])
		announce(c.team, "Chest aboard! %d to go%s." % [still, "" if alive_teams().all(func(t: int) -> bool: return allies(t, NAVS)) else ", and every pirate to capture"])
		return
	if c.id == chart_carrier:
		_set_chart_carrier(-1)
		if allies(c.team, NAVS):
			_win(c.team, "the Star Chart is back aboard")
		else:
			_win(c.team, "the %s sailed off with the Star Chart" % TEAM_NAMES[c.team])
		return
	if _check_victory():
		return
	if goal != "" and allies(c.team, NAVS):
		announce(c.team, "Chest aboard! It won't win this island, but it keeps it from your rivals.")
		return
	var ours := side_delivered(c.team)
	var need: int = ours + chests_to_win(c.team)
	var pair := not partners(c.team).is_empty()
	announce(c.team, "Chest aboard! %s%d of %d — need %d to win." % ["Your side has " if pair else "", ours, chests_total, need])
	for t in partners(c.team):
		announce(t, "The %s got a chest aboard: your side has %d of %d — need %d to win." % [TEAM_NAMES[c.team], ours, chests_total, need])
	for t in rivals(c.team):
		announce(t, "The %s got a chest aboard (%s%d of %d)." % [
			TEAM_NAMES[c.team], "their side has " if pair else "", ours, chests_total])

## Chests not yet aboard any ship: still buried, being carried, or dropped.
func chests_left() -> int:
	var aboard := 0
	for n in delivered:
		aboard += int(n)
	return chests_total - aboard

## The most chests any rival side of `team` could still end up with: what it
## has, plus every chest left if it still has anyone on the island.
func _best_rival(team: int) -> int:
	var best := 0
	var left := chests_left()
	for t in rivals(team):
		best = maxi(best, side_delivered(t) + (left if side_alive(t) else 0))
	return best

## How many more chests `team` needs aboard to be sure of winning. It never
## goes up: a rival's chest raises their total but empties the island by the
## same amount. With two crews it's the original's "more than half".
func chests_to_win(team: int) -> int:
	if not two_teams:
		return maxi(0, chests_total / 2 + 1 - int(delivered[team]))
	# Each chest we load adds one to us and takes one from what a rival could
	# still reach (if they're still on the island and so in the race for it).
	var need := 1
	var left := chests_left()
	for t in rivals(team):
		var racing := side_alive(t)
		var gap := side_delivered(t) + (left if racing else 0) - side_delivered(team)
		var k := (floori(gap / 2.0) + 1) if racing else (gap + 1)
		need = maxi(need, k)
	return clampi(need, 0, left)

## Has anyone won on chests? Then it's over. Also calls a draw when every
## chest is aboard and the leaders are level. True if the game ended.
func _check_victory() -> bool:
	if won:
		return true
	if not two_teams:
		if int(delivered[NAVS]) * 2 > chests_total:
			_win(NAVS, "%d of %d chests aboard" % [delivered[NAVS], chests_total])
			return true
		return false
	for t in _teams():
		if goal != "" and allies(t, NAVS):
			continue # the island's goal wins it for the NAVS, not chests
		var ours := side_delivered(t)
		if ours > 0 and ours > _best_rival(t):
			var reason := "%d of %d chests aboard" % [ours, chests_total]
			if ours * 2 <= chests_total:
				reason += ", and nobody can catch them now"
			_win(t, reason)
			return true
	if chests_left() <= 0 and goal == "":
		_draw("every chest is aboard and the leaders are level")
		return true
	return false

## `team` won (in 2v2, with its partner: winner is the one that did it).
func _win(team: int, reason: String) -> void:
	won = true
	winner = team
	win_reason = reason
	for t in _teams():
		if allies(t, team):
			_sfx(AudioManifest.WIN, t)
	if two_teams:
		_sfx_others(AudioManifest.LOSE, team)
	for t in _teams():
		announce(t, ("You Won! " if allies(t, team) else "The %s won. " % side_name(team))
			+ reason[0].to_upper() + reason.substr(1) + "." + _replay_hint())
	game_won.emit()

## Did `team` win (alone, or as the winner's partner in 2v2)?
func is_winner(team: int) -> bool:
	return winner >= 0 and allies(team, winner)

## Nobody wins: the leaders finished level with nothing left to play for.
func _draw(reason: String) -> void:
	won = true
	winner = DRAW
	win_reason = reason
	_sfx(AudioManifest.TIE)
	for t in _teams():
		announce(t, "A draw! " + reason[0].to_upper() + reason.substr(1) + "." + _replay_hint())
	game_won.emit()

func _replay_hint() -> String:
	return " Click Continue (or press ENTER) for the results."

## The host disconnected (seen from a guest): the game stops where it stands.
func opponent_left() -> void:
	won = true
	winner = NOBODY
	var who := "The server has closed" if Net.dedicated else "The host has left"
	for t in _teams():
		status[t] = Net.farewell("%s the game." % who) + " Press M for the menu."
	status_changed.emit(status[viewer_team()])
	game_won.emit()

## Host: a friend left mid-game, so the computer takes over their crew. The
## caller (Main) starts the ComputerPlayer that sails it from now on.
func hand_to_computer(team: int) -> void:
	if team < 0 or team >= team_count or (team == NAVS and mode != GameConfig.Mode.SERVER):
		return
	ctrl[team] = GameConfig.Ctrl.COMPUTER
	if not offer.is_empty() and characters[int(offer.from)].team == team:
		request_handoff(team, false)
	for t in _teams():
		if t != team:
			announce(t, "The %s' player left, and the computer has taken over their crew." % TEAM_NAMES[team])
	_mark()

## Host: a player who'd left is back and has loaded the island, so they sail
## their crew again. The caller (Main) stops the ComputerPlayer that sailed it.
func take_back(team: int) -> void:
	if team < 0 or team >= team_count:
		return
	ctrl[team] = GameConfig.Ctrl.FRIEND
	for t in _teams():
		if t != team:
			announce(t, "The %s' player is back and sails their crew again." % TEAM_NAMES[team])
	announce(team, "Welcome back! You sail the %s again." % TEAM_NAMES[team])
	_mark()

## Host: a player lost their connection, so the game waits for them (or
## stops waiting), saying `text` to everyone. Nothing moves while it waits,
## the computer's crews included, and nobody can unpause it.
func hold(on: bool, text := "") -> void:
	if won:
		return
	paused = on
	paused_by = HELD if on else -1
	for t in _teams():
		status[t] = (text if text != "" else "Waiting for a player to come back...") if on else _default_status(t)
	status_changed.emit(status[viewer_team()])
	_mark()

## Vision is recomputed from scratch each time anyone moves or changes stance,
## because standing still lets you see four times as far as running. With two
## teams it also decides which opponents each side can see right now.
func _refresh_vision() -> void:
	if not is_authority:
		return # a guest's fog and sightings come only from the host, for its own crew
	# In 2v2 what a crew sees, its partner sees too.
	for t in _teams():
		for c in _members(t):
			for cell in grid.visible_from(c.cell, c.vision_points()):
				for o in _teams():
					if allies(o, t):
						revealed[o][cell] = true
	if not two_teams:
		return
	var sight := {} # viewer id -> sight costs, computed once per refresh
	for t in _teams():
		var spotted := {}
		for e in characters:
			if e.team == t or e.captured:
				continue
			if allies(e.team, t) or _spotted(t, e, sight):
				spotted[e.id] = true # a partner's people are always in sight
		seen[t] = spotted
	_mark()

## Can anyone on `team`'s side see `target`? Opponents next to you are always
## seen, and so is anyone running two squares away (DESIGN_REFERENCE.md §5).
## Beyond that it's vision against stealth: a crawling Scout is only spotted
## up close.
func _spotted(team: int, target: Character, sight: Dictionary) -> bool:
	var factor := Combat.spot_factor(target)
	var watchers: Array[Character] = []
	for t in _teams():
		if allies(t, team):
			watchers.append_array(_members(t))
	for m in watchers:
		var gap: Vector2i = (m.cell - target.cell).abs()
		var d := maxi(gap.x, gap.y)
		if d <= 1:
			return true
		if d <= 2 and (target.stance == Character.Stance.RUNNING or target.moving):
			return true
		if not sight.has(m.id):
			sight[m.id] = grid.sight_costs(m.cell, m.vision_points() * Combat.MAX_SPOT_FACTOR)
		var costs: Dictionary = sight[m.id]
		if costs.has(target.cell) and float(costs[target.cell]) <= m.vision_points() * factor:
			return true
	return false

## Sets a team's status line. With no text, says what they can do next.
## team -1 means everyone.
func announce(team := -1, text := "") -> void:
	var teams: Array = _teams() if team < 0 else [team]
	for t in teams:
		status[t] = text if text != "" else _default_status(t)
	status_changed.emit(status[viewer_team()])
	_mark()

func _default_status(t: int) -> String:
	if won:
		if winner == DRAW:
			return "A draw!" + _replay_hint()
		return "You Won!" + _replay_hint() if is_winner(t) else "The %s won.%s" % [side_name(maxi(winner, 0)), _replay_hint()]
	if not started:
		return "Waiting for everyone to come ashore..."
	if two_teams and _members(t).is_empty():
		return "Your crew has all been captured. The %s are moving." % TEAM_NAMES[current_team]
	if not duel.is_empty():
		var a := characters[int(duel.a)]
		var d := characters[int(duel.d)]
		if a.team != t and d.team != t:
			if seen[t].has(a.id) or seen[t].has(d.id):
				return "The %s and the %s are crossing swords..." % [TEAM_NAMES[a.team], TEAM_NAMES[d.team]]
			return "Steel rings out somewhere on the island..."
		var attacking := a.team == t
		var mine := int(duel.ac if attacking else duel.dc)
		if mine >= 0:
			return "Waiting for the %s to choose..." % TEAM_NAMES[d.team if attacking else a.team]
		return "Sword fight! Choose your attack." if attacking else "Sword fight! Choose your defence."
	if two_teams and t != current_team:
		return "The %s are moving. Wait for your turn." % TEAM_NAMES[current_team]
	var a: Character = active_by_team[t]
	if a == null:
		return "Click one of your %s, then click where to go." % TEAM_NAMES[t]
	if a.id == chart_carrier:
		return "Carrying the Star Chart: get it aboard your ship!"
	if a.carrying:
		return "Carrying treasure — take it to your ship, or click a team-mate beside them to hand it over."
	if t == NAVS and _held_captive() != null:
		if pen.x >= 0 and not revealed[NAVS].has(_held_captive().cell):
			return "%s is held somewhere near the pirates' ship. Scout ahead to find her; rest at the outpost (double energy)." % _held_captive().stats.person_name
		if guard_beside_captive() != null:
			return "%s is in the stockade, guarded. Its one gate is the way in: deal with the guards beside her first." % _held_captive().stats.person_name
		return "%s is held near the pirates' ship: walk someone up beside her to free her." % _held_captive().stats.person_name
	return "Click a destination, SPACE to dig, ENTER to end the turn."

## Plays a sound for one team (or everyone with -1) on whichever machine that
## team is being played. A line a sailor speaks is said in their own voice
## (`speaker`'s CharacterStats.voice).
func _sfx(path: String, team := -1, speaker: Character = null) -> void:
	if speaker != null and speaker.stats != null:
		path = AudioManifest.voiced(path, speaker.stats.voice)
	if team < 0 or is_local_team(team):
		AudioManager.play(path)
	if _hosting():
		for t in remote_teams():
			if team < 0 or team == t:
				Net.send_sfx(path, t)

## Plays a sound once for every team but `except` (and, in 2v2, its partner),
## wherever they're played.
func _sfx_others(path: String, except: int) -> void:
	var here := false
	for t in _teams():
		if not allies(t, except) and is_local_team(t):
			here = true
	if here:
		AudioManager.play(path)
	if _hosting():
		for t in remote_teams():
			if not allies(t, except):
				Net.send_sfx(path, t)

# --- networking (host side) ------------------------------------------------

## Host: a guest has loaded the island. Play starts once every guest has.
func on_guest_in_game() -> void:
	_sent_fog.clear()
	started = Net.all_in_game()
	announce()
	_mark()
	_flush()

func _mark() -> void:
	_dirty = true

## At most once a frame, the host sends each guest a fresh picture of the
## game, as their own crew sees it.
func _flush() -> void:
	if not _dirty:
		return
	_dirty = false
	if _hosting() and is_authority:
		for t in remote_teams():
			if not Net.team_in_game(t):
				continue
			var snap := snapshot(t)
			if _sent_fog.has(t) and _sent_fog[t] == snap.revealed:
				snap.erase("revealed") # unchanged since last time
			else:
				_sent_fog[t] = snap.revealed
			Net.send_state(t, snap)

## Everything crew `team`'s screen needs. The fight choices are masked — a
## guest learns THAT the other side has chosen, never what.
func snapshot(team: int = PIRATES) -> Dictionary:
	var people := []
	for c in characters:
		people.append([c.cell, c.energy, c.stance, c.carrying, c.captured, c.digging,
			c.dig_progress, c.path, c.stats.confidence, c.facing, c.fighting, c.moving])
	var act := []
	for t in team_count:
		act.append(active_by_team[t].id if active_by_team[t] != null else -1)
	var public_duel := {}
	if not duel.is_empty():
		public_duel = duel.duplicate()
		for key in ["ac", "dc"]:
			var owner := characters[int(duel.a if key == "ac" else duel.d)].team
			if owner != team and int(duel[key]) >= 0:
				public_duel[key] = 0 # chosen, but not saying which
	return {
		"people": people, "act": act, "cur": current_team, "turn": turn, "first": first_team,
		"delivered": delivered, "total": chests_total, "won": won, "winner": winner,
		"started": started, "dug": dug_cells, "dropped": _drops(), "captures": captures, "duel": public_duel,
		"status": status[team], "revealed": _pack(revealed[team]),
		"seen": seen[team].keys(), "duel_seq": duel_seq, "duel_text": duel_text, "duel_teams": duel_teams,
		"offer": offer, "paused": paused, "ctrl": ctrl, "sides": sides, "clock": turn_clock, "captains": refresh_captains(),
		"tally": tally if won else [], "reason": win_reason,
	}

# --- networking (guest side) -----------------------------------------------

## The guest's copy takes the host's word for everything.
func apply_state(s: Dictionary) -> void:
	var me := guest_team
	var clock: Variant = s.get("clock", -1.0)
	turn_clock = float(clock) if (clock is float or clock is int) else -1.0
	_clock_at = Time.get_ticks_msec()
	var caps: Variant = s.get("captains", [])
	if caps is Array:
		captains = caps.filter(func(v: Variant) -> bool: return v is int and v >= 0 and v < Character.MAX_TEAMS)
	var people: Array = s.get("people", [])
	for i in mini(people.size(), characters.size()):
		var c := characters[i]
		var r: Array = people[i]
		c.path.assign(r[7])
		if r[0] != c.cell:
			c.move_to(r[0])
		else:
			c.moving = r[11]
		c.energy = r[1]
		c.stance = r[2]
		if c.carrying != r[3]:
			c.set_carrying(r[3])
		c.captured = r[4]
		c.digging = r[5]
		c.dig_progress = r[6]
		c.stats.confidence = r[8]
		c.facing = r[9]
		c.fighting = r[10]
	var act: Array = s.get("act", [])
	for t in mini(act.size(), team_count):
		var id := int(act[t])
		active_by_team[t] = characters[id] if id >= 0 and id < characters.size() else null
	var old_turn := [current_team, turn]
	current_team = clampi(int(s.get("cur", NAVS)), 0, team_count - 1)
	turn = int(s.get("turn", 1))
	first_team = clampi(int(s.get("first", first_team)), 0, team_count - 1)
	var got: Array = s.get("delivered", [])
	for t in mini(got.size(), team_count):
		delivered[t] = int(got[t])
	var who: Variant = s.get("ctrl")
	if who is Array and who.size() == team_count:
		ctrl = who
	var sided: Variant = s.get("sides")
	if sided is Array and (sided.is_empty() or sided.size() == team_count):
		sides = sided.map(func(v: Variant) -> int: return clampi(int(v), 0, team_count - 1))
	chests_total = int(s.get("total", chests_total))
	var was_won := won
	won = bool(s.get("won", false))
	winner = int(s.get("winner", -1))
	started = bool(s.get("started", true))
	var old_holes := dug_cells.size()
	var drops_moved := _set_drops(s.get("dropped", []))
	dug_cells.assign(s.get("dug", []))
	captures = s.get("captures", [])
	var old_duel := duel
	duel = s.get("duel", {})
	var old_offer := offer
	offer = s.get("offer", {})
	paused = bool(s.get("paused", false))
	var t: Array = s.get("tally", [])
	if t.size() == characters.size():
		tally = t
	win_reason = str(s.get("reason", ""))
	status[me] = str(s.get("status", ""))
	if s.has("revealed"):
		revealed[me] = _unpack(s.revealed)
	var spotted := {}
	for id in s.get("seen", []):
		spotted[int(id)] = true
	seen[me] = spotted
	var seq := int(s.get("duel_seq", 0))
	duel_teams = s.get("duel_teams", [])

	fog_changed.emit()
	path_changed.emit()
	selection_changed.emit()
	status_changed.emit(status[me])
	if dug_cells.size() != old_holes or drops_moved:
		holes_changed.emit()
	if old_turn != [current_team, turn]:
		turn_changed.emit()
	if old_duel != duel:
		duel_changed.emit()
	if old_offer != offer:
		offer_changed.emit()
	if seq != duel_seq:
		duel_seq = seq
		duel_text = str(s.get("duel_text", ""))
		duel_resolved.emit(duel_text)
	if won and not was_won:
		game_won.emit()

func _pack(cells: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(grid.width * grid.height)
	for c in cells:
		bytes[c.y * grid.width + c.x] = 1
	return bytes

func _unpack(bytes: PackedByteArray) -> Dictionary:
	var out := {}
	for i in bytes.size():
		if bytes[i]:
			out[Vector2i(i % grid.width, i / grid.width)] = true
	return out
