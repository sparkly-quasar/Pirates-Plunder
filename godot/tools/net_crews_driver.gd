extends Node
# Drives one side of the four-crew network test: a host (NAVS), two guests
# (Pirates and Corsairs) and a computer crew (Buccaneers) in three processes.
# See net_test.gd. Not shipped.
#
# The host waits for both friends, the crews take a full round of turns across
# the network, then the Corsairs' player quits and the computer takes over
# their crew while the game carries on. Each player's Your Crew names (not
# their skills) land with them: the host's Scout "Anne", the Pirates' trained
# Scout "Cy" (who also asks for "Anne", already the NAVS'); the Corsairs'
# player has no crew, so theirs get the usual names.

const PORT := 24698
const N := Character.Team.NAVS
const P := Character.Team.PIRATES
const C := Character.Team.CORSAIRS
const B := Character.Team.BUCCANEERS

var role := "crews-host"
var failures := 0

func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	match role:
		"crews-host":
			await _host()
		"crews-pirates":
			await _guest(P, 0.5)
		_:
			await _guest(C, 2.0)

func _host() -> void:
	GameConfig.reset()
	GameConfig.team_target = 5 # these tests count on crews of five
	for t in GameConfig.MAX_TEAMS:
		GameConfig.team_counts[t] = GameConfig.balanced_counts(5)
	GameConfig.mode = GameConfig.Mode.HOST
	GameConfig.crew = [_trained(CharacterStats.Kind.SCOUT, "Anne")] # in memory only: never saved
	GameConfig.island_seed = 888
	GameConfig.team_count = 4
	GameConfig.controllers[B] = GameConfig.Ctrl.COMPUTER
	_check(Net.host_game(PORT) == OK, "host: listening on %d" % PORT)
	_check(Net.open_seats() == [P, C], "host: two seats for friends, the Buccaneers to the computer")
	Net.guest_ready.connect(func(_c: Dictionary) -> void:
		if Net.all_seats_ready():
			Net.start_match())
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started)
	var s: GameServer = Net.game_server
	_check(s.team_count == 4 and s.characters.size() == 20, "host: four crews of five landed")
	_check(s.ctrl == [GameConfig.Ctrl.HUMAN, GameConfig.Ctrl.FRIEND, GameConfig.Ctrl.FRIEND, GameConfig.Ctrl.COMPUTER],
		"host: NAVS here, two friends, one computer crew")
	var teams := Net.guests.values()
	teams.sort()
	_check(teams == [P, C], "host: each friend was given their own crew")
	_check(s.get_parent().has_node("ComputerPlayer3"), "host: a computer player sails the Buccaneers")
	_check_names(s, "host")

	# --- one full round: us, both friends over the network, the computer ---
	s.intent(N, "end_turn")
	_check(s.current_team == P, "host: handed the turn to the Pirates")
	await _until(func() -> bool: return s.current_team == C, 90.0)
	_check(true, "host: the Pirates' player ended their turn")
	await _until(func() -> bool: return s.current_team == B, 90.0)
	_check(true, "host: the Corsairs' player ended their turn")
	await _until(func() -> bool: return s.current_team == N, 120.0)
	_check(s.turn == 2, "host: the computer's Buccaneers ended theirs, and it's round 2")

	# --- the Corsairs' player has quit: the computer takes over ---
	await _until(func() -> bool: return Net.guests.size() == 1, 60.0)
	await get_tree().process_frame
	_check(s.is_computer(C) and s.get_parent().has_node("ComputerPlayer2"),
		"host: the Corsairs' player left, and the computer took over their crew")
	_check(not s.won, "host: the game carries on without them")
	s.intent(N, "end_turn")
	await _until(func() -> bool: return s.current_team == N, 200.0)
	_check(s.turn == 3, "host: a second round with the computer sailing the Corsairs")
	_finish(failures == 0)

func _guest(team: int, delay: float) -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	GameConfig.crew = [_trained(CharacterStats.Kind.SCOUT, "Anne"), _trained(CharacterStats.Kind.SCOUT, "Cy")] \
		if team == P else []
	await get_tree().create_timer(delay).timeout # join in a known order
	var who: String = GameServer.TEAM_NAMES[team]
	_check(Net.join_game("127.0.0.1:%d" % PORT) == OK, "%s: connecting" % who)
	await Net.joined
	_check(GameConfig.my_team == team and GameConfig.team_count == 4,
		"%s: given the %s in a four-crew game" % [who, who])
	Net.send_ready(GameConfig.editing_counts())
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started)
	var s: GameServer = Net.game_server
	_check(s.guest_team == team and s.viewer_team() == team and s.characters.size() == 20,
		"%s: playing our own crew on a mirror of the host's island" % who)
	_check(s.revealed[team].size() > 0 and s.revealed[N].is_empty() and s.revealed[B].is_empty(),
		"%s: we get our own fog and nobody else's (%s)" % [who, str(s.revealed.map(func(r: Dictionary) -> int: return r.size()))])
	_check(s.is_computer(B), "%s: told the Buccaneers are the computer's" % who)
	_check_names(s, who)

	await _until(func() -> bool: return s.current_team == team, 90.0)
	_check(s.status[team].begins_with("Your turn"), "%s: told it's our turn" % who)
	var runner: Character = s.characters[team * 5 + 2]
	s.intent(team, "select", [runner.cell])
	await _until(func() -> bool: return s.active == runner)
	var start := runner.cell
	s.intent(team, "move", [_reachable(s, runner.cell, 3)])
	await _until(func() -> bool: return runner.cell != start and runner.path.is_empty())
	_check(true, "%s: our Runner moved on the host's say-so" % who)
	s.intent(team, "end_turn")
	await _until(func() -> bool: return s.current_team != team)
	_check(true, "%s: ended our turn" % who)

	if team == C:
		_finish(failures == 0) # quit mid-game; the computer should take over
		return
	await _until(func() -> bool: return s.current_team == team and s.turn == 2, 150.0)
	_check(s.is_computer(C), "%s: told the computer sails the Corsairs now" % who)
	s.intent(team, "end_turn")
	await _until(func() -> bool: return s.won, 200.0)
	_check(s.winner == GameServer.NOBODY, "%s: the host left, and the game stopped" % who)
	_finish(failures == 0)

## A Your Crew sailor with coached vision (which a regular game must leave behind).
func _trained(kind: int, name: String) -> Dictionary:
	var st := CharacterStats.make(kind, name)
	st.vision = 95.0
	return st.to_dict()

## Every copy sees the same names: the NAVS' Scout is Anne and the Pirates'
## is Cy, both with fresh skills; nobody else is Anne or Cy; the Corsairs
## have the usual corsairs' names.
func _check_names(s: GameServer, who: String) -> void:
	var by_team := [[], [], [], []]
	var fresh_vision := CharacterStats.make(CharacterStats.Kind.SCOUT, "x").vision
	var anne: Character = null
	var cy: Character = null
	for c in s.characters:
		by_team[c.team].append(c.stats.person_name)
		if c.stats.person_name == "Anne":
			anne = c if anne == null else null
		elif c.stats.person_name == "Cy":
			cy = c if cy == null else null
	_check(anne != null and anne.team == N and anne.stats.kind == CharacterStats.Kind.SCOUT
		and is_equal_approx(anne.stats.vision, fresh_vision),
		"%s: the NAVS' Scout is Anne, from the host's Your Crew, with fresh skills" % who)
	_check(cy != null and cy.team == P and cy.stats.kind == CharacterStats.Kind.SCOUT
		and is_equal_approx(cy.stats.vision, fresh_vision),
		"%s: the Pirates' Scout is Cy, from their Your Crew, fresh (Anne was taken)" % who)
	_check(by_team[C].all(func(n: String) -> bool: return n in GameConfig.CORSAIR_NAMES),
		"%s: the Corsairs, with no crew sent, have the usual names: %s" % [who, str(by_team[C])])
	print("  names (%s): %s" % [who, str(by_team)])

func _until(cond: Callable, limit := 30.0) -> void:
	var waited := 0.0
	while not cond.call():
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > limit:
			print("  [FAIL] %s waited too long" % role)
			_finish(false)
			return

func _reachable(s: GameServer, from: Vector2i, dist: int) -> Vector2i:
	var seen := {from: 0}
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if int(seen[cur]) >= dist and s._occupant(cur) == null:
			return cur
		for n in s.grid.neighbours(cur):
			if not seen.has(n) and s._occupant(n) == null:
				seen[n] = int(seen[cur]) + 1
				queue.append(n)
	return from

func _check(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
	print(("  [PASS] " if cond else "  [FAIL] "), label)

func _finish(ok: bool) -> void:
	print("NET_RESULT %s: %s" % [role, "ALL PASS" if ok else "FAIL"])
	Net.leave_and_quit(0 if ok else 1)
