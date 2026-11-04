extends Node
# Drives one side of tools/NetTest.tscn. See net_test.gd. Not shipped.

const PORT := 24697
const N := Character.Team.NAVS
const P := Character.Team.PIRATES

var role := "host"
var failures := 0

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	if role == "host":
		await _host()
	else:
		await _guest()

func _host() -> void:
	GameConfig.reset()
	GameConfig.team_target = 5 # these tests count on crews of five
	for t in GameConfig.MAX_TEAMS:
		GameConfig.team_counts[t] = GameConfig.balanced_counts(5)
	GameConfig.mode = GameConfig.Mode.HOST
	GameConfig.island_seed = 777
	_check(Net.host_game(PORT) == OK, "host: listening on %d" % PORT)
	Net.guest_ready.connect(func(_c: Dictionary) -> void: Net.start_match())
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started)
	var s: GameServer = Net.game_server
	_check(s.is_authority and s.characters.size() == 10, "host: both crews landed, host runs the rules")
	Net.say("Fair winds")
	await _until(func() -> bool: return Net.chat_log.any(func(m: Dictionary) -> bool: return m.text == "Aye" and int(m.team) == P))
	_check(Net.chat_log.any(func(m: Dictionary) -> bool: return m.text == "Fair winds" and int(m.team) == N),
		"host: chat goes both ways (our line shows here too, and the guest's answer arrived)")
	var sword: Character = s.characters[4]
	var digger: Character = s.characters[6]
	var pair := _open_pair(s)
	_place(sword, pair[0])
	_place(digger, pair[1])
	sword.energy = 100.0
	digger.energy = 100.0
	s._refresh_vision()
	s.intent(N, "select", [sword.cell])
	s.intent(N, "move", [digger.cell])
	await _until(func() -> bool: return not s.duel.is_empty())
	_check(true, "host: walking into the pirate started a fight")
	s.intent(N, "duel", [Combat.Choice.CAUTIOUS])
	await _until(func() -> bool: return s.duel.is_empty())
	_check(s.duel_text != "", "host: the guest's defence arrived and it resolved: %s" % s.duel_text)
	_check(sword.energy < 100.0 and digger.energy < 100.0, "host: both fighters paid energy")
	var runner: Character = s.characters[7]
	var runner_cell := runner.cell
	s.intent(N, "end_turn")
	_check(s.current_team == P, "host: handed the turn to the pirates")
	await _until(func() -> bool: return runner.cell != runner_cell)
	_check(true, "host: the guest's move order walked the pirate Runner")
	var nav_cell := s.characters[0].cell
	await get_tree().create_timer(1.0).timeout
	_check(s.characters[0].cell == nav_cell, "host: the guest couldn't move a nav")
	# --- end of the game: coaching for both, then the next game of the match ---
	s._win(N, "a test win")
	_check(GameConfig.match_score[N] == 1 and not bool(GameConfig.match_coached[N]),
		"host: the winner has a round of coaching to do")
	await _until(func() -> bool: return bool(GameConfig.match_ready[P]))
	_check(str(GameConfig.match_crews[P][0].name) == "Testy", "host: the guest renamed a pirate through us")
	_check(bool(GameConfig.match_coached[P]) and GameConfig.match_note[P].size() == 1,
		"host: we rolled the guest's coaching, one try for the one person they picked for")
	Net.ready_for_next()
	var first := s.get_instance_id() # not `s` itself: it's freed when game two loads
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.get_instance_id() != first and Net.game_server.started)
	var s2: GameServer = Net.game_server
	_check(s2.characters[5].stats.person_name == "Testy", "host: the next game lands the coached crew")
	await _until(func() -> bool: return not Net.is_online() or Net.guest_id == 0)
	_finish(failures == 0)

func _guest() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	await get_tree().create_timer(0.5).timeout # let the host open its port
	_check(Net.join_game("127.0.0.1:%d" % PORT) == OK, "guest: connecting")
	await Net.joined
	_check(GameConfig.island_seed == 777, "guest: got the host's island")
	Net.send_ready(GameConfig.pirate_counts)
	await _until(func() -> bool: return Net.game_server != null)
	var s: GameServer = Net.game_server
	_check(not s.is_authority and s.mode == GameConfig.Mode.GUEST, "guest: playing a mirror of the host's game")
	await _until(func() -> bool: return Net.chat_log.any(func(m: Dictionary) -> bool: return m.text == "Fair winds"))
	_check(int(Net.chat_log[0].team) == N and str(Net.chat_log[0].name) == GameConfig.player_name(),
		"guest: the host's chat line arrived, from the NAVS, by name")
	Net.say("Aye")
	await _until(func() -> bool: return not s.duel.is_empty())
	var att: Character = s.characters[int(s.duel.a)]
	var dfn: Character = s.characters[int(s.duel.d)]
	_check(att.team == N and dfn.team == P, "guest: our pirate is under attack")
	_check(att.fighting and dfn.fighting, "guest: both fighters shown in fight mode")
	_check(s.seen[P].has(att.id), "guest: the attacker is in sight")
	await _until(func() -> bool: return int(s.duel.ac) >= 0)
	_check(int(s.duel.ac) == 0, "guest: told the navs chose, never told what")
	s.intent(P, "duel", [Combat.Choice.AGGRESSIVE])
	await _until(func() -> bool: return s.duel.is_empty())
	_check(s.duel_text != "", "guest: saw the result: %s" % s.duel_text)
	await _until(func() -> bool: return s.current_team == P)
	_check(s.status[P].begins_with("Your turn"), "guest: told it's our turn")
	# Try to steer a nav: the host must ignore it.
	s.intent(P, "select", [s.characters[0].cell])
	s.intent(P, "move", [s.characters[0].cell + Vector2i(0, -1)])
	var runner: Character = s.characters[7]
	s.intent(P, "select", [runner.cell])
	await _until(func() -> bool: return s.active == runner)
	var start := runner.cell
	var dest := _reachable(s, runner.cell, 3)
	s.intent(P, "move", [dest])
	await _until(func() -> bool: return runner.cell != start)
	_check(true, "guest: our Runner moved on the host's say-so")
	_check(s.revealed[P].size() > 0, "guest: has the pirates' own fog")
	# --- the host wins; we coach, rename and get ready ---
	await _until(func() -> bool: return GameConfig.match_crews[P].size() == GameConfig.team_target)
	_check(not bool(GameConfig.match_coached[P]) and GameConfig.match_score[N] == 1,
		"guest: the loser gets a round of coaching too, and the score is kept")
	var vision_before := float(GameConfig.match_crews[P][0].vision)
	Net.send_coaching_plan({0: "nonsense", 99: "vision"})
	Net.send_coaching_plan({0: "vision"})
	await _until(func() -> bool: return bool(GameConfig.match_coached[P]))
	_check(GameConfig.match_note[P].size() == 1, "guest: the host rolled our plan, and only the real pick: %s" % str(GameConfig.match_note[P]))
	Net.send_coaching_plan({1: "vision"})
	Net.send_rename(0, "Testy")
	await _until(func() -> bool: return str(GameConfig.match_crews[P][0].name) == "Testy")
	_check(GameConfig.match_note[P].size() == 1, "guest: a second round in the same break is ignored")
	var vision_after := float(GameConfig.match_crews[P][0].vision)
	Net.ready_for_next()
	var first := s.get_instance_id() # not `s` itself: it's freed when game two loads
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.get_instance_id() != first)
	var s2: GameServer = Net.game_server
	_check(s2.characters[5].stats.person_name == "Testy" and is_equal_approx(s2.characters[5].stats.vision, vision_after),
		"guest: the next game has our coached, renamed pirate (vision %d -> %d)" % [vision_before, vision_after])
	_check(s2.characters.size() == 10 and s2.turn == 1, "guest: a fresh island for game two")
	await get_tree().create_timer(0.5).timeout
	_finish(failures == 0)

func _until(cond: Callable, limit := 20.0) -> void:
	var waited := 0.0
	while not cond.call():
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > limit:
			print("  [FAIL] %s waited too long" % role)
			_finish(false)
			return

func _place(c: Character, cell: Vector2i) -> void:
	c.cell = cell
	c.position = Character.cell_to_pos(cell)

func _open_pair(s: GameServer) -> Array:
	for y in range(2, s.grid.height - 2):
		for x in range(2, s.grid.width - 3):
			var a := Vector2i(x, y)
			var b := Vector2i(x + 1, y)
			if s.grid.is_meadow(a) and s.grid.is_meadow(b) and s._occupant(a) == null and s._occupant(b) == null:
				return [a, b]
	return []

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
