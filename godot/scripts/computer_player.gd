class_name ComputerPlayer
extends Node

## Plays one computer crew — the PIRATES in a classic single-player game, or any
## crew the setup screen gives to the computer. It sees only what that crew
## sees: its own fog, the rivals in sight right now, and what's on everyone's
## map (the red X's, every ship, open holes). It acts only through
## GameServer.intent(), exactly as a person at the mouse does, so it can't do
## anything a human player couldn't.
##
## Whenever one of its people is standing idle it gives them their next order,
## and when nobody has anything useful left to do it ends the turn. Each
## person's order, most urgent first:
##   1. carrying a chest -> take it to the ship;
##   1b. a dropped chest on uncovered ground that no team-mate is after -> go
##      and pick it up (it's free treasure, no digging);
##   2. an opponent in sight worth fighting -> attack (a chest-carrier is worth
##      worse odds, because winning takes the chest);
##   3. standing on a likely spot -> dig;
##   4. otherwise -> walk to the nearest likely spot nobody else has taken.
## A likely spot is a meadow square next to a red X that hasn't been dug, at an
## X whose chest we haven't found ourselves. The best swordfighter (in a crew of
## four or more) instead keeps watch near the leading rival's ship, where their
## chests have to come — and everyone joins the watch once there's nothing left
## to dig. With several rivals it picks fights with the leader more readily: in
## a free-for-all, letting one crew run away with it is how you lose.
## Nobody walks themselves into the ground: travellers keep some energy back,
## and the look-out only moves up while fresh enough to fight on arrival.

const THINK_TIME := 0.35      ## pause between orders, so the turn reads as deliberate
const DUEL_THINK_TIME := 0.9  ## pause before answering a sword fight
const MAX_ORDERS := 10        ## per person per turn; a safety net against dithering
const SEEN_PACE := 1.5        ## our turn's walking speed-up for those of us in sight...
const UNSEEN_PACE := 3.0      ## ...and for those out of it
const TRAVEL_RESERVE := 20.0  ## energy a traveller keeps back, so they aren't easy prey
const WATCH_RESERVE := 60.0   ## the look-out arrives ready for a fight
## What changes with difficulty: the odds it needs to start a fight (and to go
## after a chest-carrier), the odds below which an attacker backs off, the
## energy it keeps above the minimum to attack,
## whether it posts a look-out, how often it flips its fight choice to stay
## unpredictable, and what share of stamina its people recover each turn.
const LEVELS := {
	GameConfig.Difficulty.EASY: {
		"fight_odds": 0.7, "carrier_odds": 0.55, "retreat_odds": 0.45, "fight_reserve": 30.0,
		"watch": false, "flip": 0.35, "rest": 0.66,
	},
	GameConfig.Difficulty.NORMAL: {
		"fight_odds": 0.55, "carrier_odds": 0.4, "retreat_odds": 0.4, "fight_reserve": 20.0,
		"watch": true, "flip": 0.2, "rest": 1.0,
	},
	GameConfig.Difficulty.HARD: {
		"fight_odds": 0.45, "carrier_odds": 0.3, "retreat_odds": 0.33, "fight_reserve": 10.0,
		"watch": true, "flip": 0.1, "rest": 1.0,
	},
}
const GUESSED_ENERGY := 70.0  ## an opponent's energy isn't shown, so assume this
const WATCH_DISTANCE := 5     ## squares from the rival ship to keep watch
const LEADER_BONUS := 0.35    ## how much more a fight with the leading rival is worth
const NOWHERE := Vector2i(-1, -1)

var server: GameServer
var team: int = Character.Team.PIRATES
var difficulty: GameConfig.Difficulty = GameConfig.Difficulty.NORMAL
## The tutorial's pirate: answers sword fights, otherwise just ends its turns.
var passive := false

var _turn_key := []
var _wait := 0.0
var _duel_wait := -1.0
var _rng := RandomNumberGenerator.new()
var _orders: Dictionary = {}   # person id -> orders given this turn
var _done: Dictionary = {}     # person ids with nothing left to do this turn
var _goal: Dictionary = {}     # person id -> [square, its X or NOWHERE] they're bound for
var _dug_by: Dictionary = {}   # person id -> square they last dug
var _found: Dictionary = {}    # X squares whose chest we've dug up ourselves
var _shunned: Dictionary = {}  # opponent ids we backed away from this turn
var _seen_energy: Dictionary = {} # opponent id -> energy the fight panel last showed: better than a guess next time

func _ready() -> void:
	_rng.randomize()
	if server:
		server.rest_scale[team] = _level().rest

func _level() -> Dictionary:
	return LEVELS[difficulty]

func _process(delta: float) -> void:
	if server == null or server.won or not server.started:
		return
	var ours := server.current_team == team
	if ours:
		# Only on our own turn: with several computer crews, each speeds up its own.
		server.seen_pace = SEEN_PACE
		server.unseen_pace = UNSEEN_PACE
	if not server.duel.is_empty():
		_answer_duel(delta)
		return
	_duel_wait = -1.0
	if server.current_team != team:
		return
	if passive:
		server.intent(team, "end_turn")
		return
	var key := [server.turn, server.current_team]
	if key != _turn_key:
		_turn_key = key
		_orders.clear()
		_done.clear()
		_goal.clear()
		_shunned.clear()
		_wait = THINK_TIME
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = THINK_TIME
	_note_finds()
	var people := server._members(team)
	# Carriers first: they have the most to lose and the clearest job.
	people.sort_custom(func(a: Character, b: Character) -> bool: return a.carrying and not b.carrying)
	if _clear_ships(people):
		return # give them a moment to step off before anyone else plans a route
	var watcher := _watcher(people)
	var busy := false
	for c in people:
		if c.digging or not c.path.is_empty():
			busy = true
		elif not _done.has(c.id):
			if int(_orders.get(c.id, 0)) < MAX_ORDERS and _act(c, watcher):
				_orders[c.id] = int(_orders.get(c.id, 0)) + 1
				busy = true
			else:
				_done[c.id] = true
	if not busy:
		server.intent(team, "end_turn")

## Someone standing on our ship (who has just loaded a chest, say) blocks the
## way for the next carrier, since routes go round team-mates: they step off
## onto the cheapest free square beside it. True if anyone was sent.
func _clear_ships(people: Array[Character]) -> bool:
	var homes: Array[Vector2i] = [server.ships[team]]
	for t in server.partners(team):
		homes.append(server.ships[t])
	var sent := false
	for c in people:
		if c.carrying or c.digging or not c.path.is_empty() or not homes.has(c.cell):
			continue
		var costs := server.grid.move_costs(c.cell, server._blocked_for(c), 1.0)
		var best := NOWHERE
		var best_cost := INF
		for n in server.grid.neighbours(c.cell):
			if costs.has(n) and not homes.has(n) and server._occupant(n) == null and float(costs[n]) < best_cost:
				best = n
				best_cost = float(costs[n])
		if best != NOWHERE and _go(c, best, costs):
			sent = true
	return sent

## Someone who dug and came up carrying found that X's chest: stop digging there.
func _note_finds() -> void:
	for c in server._members(team):
		if not _dug_by.has(c.id) or c.digging:
			continue
		if c.carrying:
			for m in server.x_markers:
				if _dug_by[c.id] == m or server.grid.neighbours(m).has(_dug_by[c.id]):
					_found[m] = true
		_dug_by.erase(c.id)

# --- orders ----------------------------------------------------------------

## Gives `c` their next order. False when there's nothing useful for them to do.
func _act(c: Character, watcher: Character) -> bool:
	_goal.erase(c.id)
	var costs := server.grid.move_costs(c.cell, server._blocked_for(c), 2.0 if c.carrying else 1.0)
	if server.posts.has(c.id) and not c.carrying and (not bool(server.posts[c.id][2]) or server._held_captive() != null):
		return _keep_post(c, costs)
	if c.carrying:
		var home := _home_ship(costs)
		return _go(c, home, costs) or _make_way(c, home)
	var drop := _dropped_chest(c, costs)
	if drop != NOWHERE and _go(c, drop, costs):
		_goal[c.id] = [drop, NOWHERE]
		return true
	var target := _fight_target(c, costs)
	if target != null and _go(c, target.cell, costs, CharacterStats.ATTACK_MIN_ENERGY + float(_level().fight_reserve), true):
		return true
	var spots := _likely_spots(c)
	if c != watcher and spots.has(c.cell):
		_goal[c.id] = [c.cell, spots[c.cell]]
		if c.energy < c.stats.dig_cost():
			return false # wait here for the next turn
		_select(c)
		server.intent(team, "dig")
		_dug_by[c.id] = c.cell
		return c.digging
	var taken := {}
	var at_x := {}
	for id in _goal:
		taken[_goal[id][0]] = true
		at_x[_goal[id][1]] = true
	var goal := NOWHERE
	if c != watcher:
		goal = _pick_spot(spots, costs, taken, at_x)
	if goal == NOWHERE:
		goal = _watch_post(c, costs, taken)
	if goal == NOWHERE or goal == c.cell:
		return false
	_goal[c.id] = [goal, spots.get(goal, NOWHERE)]
	return _go(c, goal, costs, WATCH_RESERVE if c == watcher else TRAVEL_RESERVE)

## The nearest dropped chest this crew has uncovered that `c` can walk to and no
## team-mate is already heading for, or NOWHERE.
func _dropped_chest(c: Character, costs: Dictionary) -> Vector2i:
	var best := NOWHERE
	for cell in server.dropped:
		if not server.revealed[team].has(cell) or not costs.has(cell):
			continue
		var claimed := false
		for id in _goal:
			if id != c.id and _goal[id][0] == cell:
				claimed = true
		if not claimed and (best == NOWHERE or float(costs[cell]) < float(costs[best])):
			best = cell
	return best

## The crew's best swordfighter keeps watch, if there are enough of us to spare one.
func _watcher(people: Array[Character]) -> Character:
	if not _level().watch or server._members(team).size() < 4:
		return null
	var best: Character = null
	for c in people:
		if not c.carrying and (best == null or c.stats.swordfighting > best.stats.swordfighting):
			best = c
	return best

## Sends `c` towards `cell`, as far as they can go keeping `reserve` energy in
## hand — or, with `whole`, only if they can get all the way. Walking into an
## opponent at the end costs nothing: that's the fight starting. False if they
## don't set off.
func _go(c: Character, cell: Vector2i, costs: Dictionary, reserve := 0.0, whole := false) -> bool:
	if cell == c.cell or not costs.has(cell):
		return false
	var path := server.grid.find_path(c.cell, cell, server._blocked_for(c))
	var stop := c.cell
	var left := c.energy
	for step in path:
		if step == cell and server._occupant(step) != null:
			stop = step
			break
		left -= server._step_cost(c, step)
		if left < reserve:
			break
		stop = step
	if stop == c.cell or (whole and stop != cell):
		return false
	_select(c)
	server.intent(team, "move", [stop])
	return not c.path.is_empty()

## `c` can't get to `target` because team-mates are in the way (an idle one
## standing in a narrow pass, say: routes go round team-mates, never through).
## The first idle one on the way there steps aside, to the nearest free square
## off that way. True if someone was sent.
func _make_way(c: Character, target: Vector2i) -> bool:
	var way := server.grid.find_path(c.cell, target, {})
	var on_way := {}
	for step in way:
		on_way[step] = true
	for step in way:
		var o := server._occupant(step)
		if o == null or o == c or o.team != team:
			continue
		if o.carrying or o.digging or not o.path.is_empty():
			return false # they're on their way already, or busy: wait for them
		var costs := server.grid.move_costs(o.cell, server._blocked_for(o), 1.0)
		var best := NOWHERE
		var best_cost := INF
		for cell in costs:
			var cost := float(costs[cell])
			if cost < best_cost and cost <= o.energy and not on_way.has(cell) and server._occupant(cell) == null:
				best = cell
				best_cost = cost
		return best != NOWHERE and _go(o, best, costs)
	return false

## Where to take a chest: our ship, or in 2v2 our partner's if it's cheaper to reach.
func _home_ship(costs: Dictionary) -> Vector2i:
	var best: Vector2i = server.ships[team]
	for t in server.partners(team):
		var s: Vector2i = server.ships[t]
		if costs.has(s) and (not costs.has(best) or float(costs[s]) < float(costs[best])):
			best = s
	return best

func _select(c: Character) -> void:
	if server.active_by_team[team] != c:
		server.intent(team, "select", [c.cell])

## A sailor with a post to keep (GameServer.posts): a guard beside the
## campaign's captive, or an ambusher lying low by the way. They go for anyone
## who comes within reach of the post, whatever the odds (that's the job),
## and otherwise go back: a guard to a square beside the post, an ambusher
## onto it, crawling so they're hard to spot.
func _keep_post(c: Character, costs: Dictionary) -> bool:
	var info: Array = server.posts[c.id]
	var post: Vector2i = info[0]
	var reach := int(info[1])
	var beside := bool(info[2])
	var best: Character = null
	for id in server.seen[team]:
		var e: Character = server.characters[int(id)]
		if e.captured or server.allies(e.team, team) or not costs.has(e.cell):
			continue
		var near: Vector2i = (e.cell - post).abs()
		if maxi(near.x, near.y) <= reach and c.energy - float(costs[e.cell]) >= CharacterStats.ATTACK_MIN_ENERGY:
			if best == null or float(costs[e.cell]) < float(costs[best.cell]):
				best = e
	if best != null and _go(c, best.cell, costs, CharacterStats.ATTACK_MIN_ENERGY, true):
		return true
	var gap: Vector2i = (c.cell - post).abs()
	var home := maxi(gap.x, gap.y) <= 1 if beside else c.cell == post
	if home:
		if not beside and c.stance != Character.Stance.CRAWLING:
			_select(c)
			server.intent(team, "stance", [Character.Stance.CRAWLING])
		return false # on post
	var back := NOWHERE if beside else (post if server._occupant(post) == null else NOWHERE)
	if beside:
		for n in server.grid.neighbours(post):
			if costs.has(n) and server._occupant(n) == null and (back == NOWHERE or float(costs[n]) < float(costs[back])):
				back = n
	return back != NOWHERE and _go(c, back, costs)

## An opponent in sight that `c` can reach with energy to spare and is likely to
## beat — the best such, preferring chest-carriers.
func _fight_target(c: Character, costs: Dictionary) -> Character:
	var best: Character = null
	var best_score := -INF
	var leader := _leading_rival()
	for id in server.seen[team]:
		var e: Character = server.characters[int(id)]
		if e.captured or server.allies(e.team, team) or _shunned.has(e.id) or not costs.has(e.cell):
			continue
		var left := c.energy - float(costs[e.cell])
		if left < CharacterStats.ATTACK_MIN_ENERGY + float(_level().fight_reserve):
			continue
		# Their energy isn't shown, so guess; but once a fight has shown it,
		# don't guess lower than that (no attacking someone just to back off).
		var guess := maxf(GUESSED_ENERGY, float(_seen_energy.get(e.id, 0.0)))
		var theirs := e.stats.combat_strength(guess) * (0.5 if e.carrying else 1.0)
		var odds := Combat.win_chance(c.stats.combat_strength(left), theirs)
		var chasing_leader := server.team_count > 2 and e.team == leader
		var needed := float(_level().carrier_odds if e.carrying else _level().fight_odds)
		if chasing_leader:
			needed -= 0.1 # worth a riskier fight to slow the leader down
		if odds < needed:
			continue
		var score := odds + (1.0 if e.carrying else 0.0) - float(costs[e.cell]) / 100.0 \
			+ (LEADER_BONUS if chasing_leader else 0.0)
		if score > best_score:
			best_score = score
			best = e
	return best

## Undug meadow squares next to an X whose chest might still be there, each
## mapped to its X. Squares with someone standing on them (other than `c`) are
## left out.
func _likely_spots(c: Character) -> Dictionary:
	var dug := {}
	for h in server.dug_cells:
		dug[h] = true
	var out := {}
	for m in server.x_markers:
		if _found.has(m):
			continue
		for n in server.grid.neighbours(m):
			if server.grid.is_meadow(n) and not dug.has(n):
				var who := server._occupant(n)
				if who == null or who == c:
					out[n] = m
	return out

## The cheapest likely spot nobody has taken, steering away from X's someone
## else is already working.
func _pick_spot(spots: Dictionary, costs: Dictionary, taken: Dictionary, at_x: Dictionary) -> Vector2i:
	var best := NOWHERE
	var best_cost := INF
	for s in spots:
		if taken.has(s) or not costs.has(s):
			continue
		var cost := float(costs[s]) + (12.0 if at_x.has(spots[s]) else 0.0)
		if cost < best_cost:
			best_cost = cost
			best = s
	return best

## The rival crew most likely to win: most chests aboard, then nearest our
## ship's side of the island. -1 if every rival is out.
func _leading_rival() -> int:
	var best := -1
	var best_score := -INF
	for t in server.rivals(team):
		if server._members(t).is_empty():
			continue
		var gap: Vector2i = (server.ships[t] - server.ships[team]).abs()
		var score := float(server.side_delivered(t)) * 1000.0 - float(gap.x + gap.y)
		if score > best_score:
			best_score = score
			best = t
	return best

## A square a few steps from the leading rival's ship to keep watch from.
func _watch_post(c: Character, costs: Dictionary, taken: Dictionary) -> Vector2i:
	var rival := _leading_rival()
	if rival < 0:
		return NOWHERE
	var ship: Vector2i = server.ships[rival]
	var gap: Vector2i = (c.cell - ship).abs()
	if maxi(gap.x, gap.y) <= WATCH_DISTANCE:
		return c.cell # already on watch
	var best := NOWHERE
	var best_cost := INF
	for dy in range(-WATCH_DISTANCE, WATCH_DISTANCE + 1):
		for dx in range(-WATCH_DISTANCE, WATCH_DISTANCE + 1):
			var s := ship + Vector2i(dx, dy)
			if s == ship or taken.has(s) or not costs.has(s):
				continue
			if float(costs[s]) < best_cost:
				best_cost = float(costs[s])
				best = s
	return best

# --- sword fights ----------------------------------------------------------

## Answers our half of a sword fight after a moment's thought.
func _answer_duel(delta: float) -> void:
	var a: Character = server.characters[int(server.duel.a)]
	var d: Character = server.characters[int(server.duel.d)]
	var me: Character = null
	if a.team == team and int(server.duel.ac) < 0:
		me = a
	elif d.team == team and int(server.duel.dc) < 0:
		me = d
	if me == null:
		return
	if _duel_wait < 0.0:
		_duel_wait = DUEL_THINK_TIME
	_duel_wait -= delta
	if _duel_wait > 0.0:
		return
	_duel_wait = -1.0
	var them := d if me == a else a
	_seen_energy[them.id] = them.energy
	var choice := choose(me, them, me == a)
	if choice == Combat.Choice.RETREAT:
		# Up close they looked stronger than we guessed: leave them be for now.
		_shunned[them.id] = true
	server.intent(team, "duel", [choice])

## The fight panel shows both fighters' strength and energy, so the computer
## may use them too. Strong: settle it aggressively. Weak: be cautious, which
## usually ends in a tie, or — as the attacker — back off for free. A carrier
## defends cautiously to keep the chest. A little randomness keeps it from
## being read like a book.
func choose(me: Character, them: Character, attacking: bool) -> int:
	var mine := me.combat_strength() * (0.5 if me.carrying and not attacking else 1.0)
	var theirs := them.combat_strength() * (0.5 if them.carrying and attacking else 1.0)
	var odds := Combat.win_chance(mine, theirs)
	if attacking and odds < float(_level().carrier_odds if them.carrying else _level().retreat_odds):
		return Combat.Choice.RETREAT
	if not attacking and me.carrying:
		return Combat.Choice.CAUTIOUS
	var bold := odds >= 0.6 or (attacking and them.carrying)
	if _rng.randf() < float(_level().flip):
		bold = not bold
	return Combat.Choice.AGGRESSIVE if bold else Combat.Choice.CAUTIOUS
