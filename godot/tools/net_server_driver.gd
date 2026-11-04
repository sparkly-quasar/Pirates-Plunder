extends Node
# Drives a player in the dedicated-server network test (see net_test.gd and
# tools/server_test.sh, which starts the real server and these players). Not
# shipped.
#
#   server-navs     joins first, so sails the NAVS; plays turn 1, sits out
#                   turn 2 until the server's turn clock passes it on, and
#                   after the Pirates' player quits, watches the computer
#                   take over their crew and finish a turn. Then leaves.
#   server-pirates  joins second (the Pirates), plays turn 1, quits on turn 2.
#   server-old      poses as an older version: told why and sent away.
#   server-late     joins once the game is under way: told why and sent away.
#
# The server runs with --once --turn-seconds=10, so it stops after the match.

const PORT := 24697
const N := Character.Team.NAVS
const P := Character.Team.PIRATES

var role := "server-navs"
var failures := 0

func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	match role:
		"server-navs":
			await _navs()
		"server-pirates":
			await _pirates()
		"server-old":
			await _turned_away(0.0, "This server runs version")
		_:
			await _turned_away(8.0, "A game is already under way")

func _join(delay: float) -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	await get_tree().create_timer(delay).timeout
	_check(Net.join_game("127.0.0.1:%d" % PORT) == OK, "%s: connecting" % role)

## Joins, picks a crew, and waits for the game to begin. Returns the game.
func _land(team: int, delay: float) -> GameServer:
	await _join(delay)
	await Net.joined
	_check(Net.dedicated, "%s: the welcome says it's a dedicated server" % role)
	_check(GameConfig.my_team == team, "%s: given the %s" % [role, GameServer.TEAM_NAMES[team]])
	_check(GameConfig.team_size(GameConfig.editing_counts()) == GameConfig.team_target,
		"%s: offered a crew of the server's size" % role)
	Net.send_ready(GameConfig.editing_counts())
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 30.0)
	var s: GameServer = Net.game_server
	_check(not s.is_authority and s.guest_team == team, "%s: a mirror of the server's game, as the %s" % [role, GameServer.TEAM_NAMES[team]])
	_check(s.ctrl == [GameConfig.Ctrl.FRIEND, GameConfig.Ctrl.FRIEND], "%s: both crews sailed by players online" % role)
	return s

func _navs() -> void:
	var s: GameServer = await _land(N, 0.5)
	_check(s.current_team == N and s.status[N].begins_with("Click"), "navs: our move first, with nobody on the server's own crew")
	var mover: Character = s.characters[0]
	s.intent(N, "select", [mover.cell])
	await _until(func() -> bool: return s.active == mover)
	var start := mover.cell
	s.intent(N, "move", [_reachable(s, mover.cell, 2)])
	await _until(func() -> bool: return mover.cell != start)
	_check(true, "navs: our person moved on the server's say-so")
	s.intent(N, "end_turn")
	await _until(func() -> bool: return s.current_team == P)
	_check(true, "navs: handed the turn to the Pirates")
	await _until(func() -> bool: return s.current_team == N and s.turn == 2, 30.0)
	_check(true, "navs: the Pirates' player ended theirs")
	# Turn 2: do nothing; the turn clock passes it on. We see it count down.
	var waited := Time.get_ticks_msec()
	var first := s.clock_left()
	await get_tree().create_timer(2.5).timeout
	var later := s.clock_left()
	_check(first > 6.0 and first <= 10.0 and later < first - 1.5 and later > 0.0 and main_clock_shows(),
		"navs: our screen shows the turn clock counting down (%.1fs, then %.1fs): %s" % [first, later, _clock_text()])
	await _until(func() -> bool: return s.current_team == P, 30.0)
	var took := (Time.get_ticks_msec() - waited) / 1000.0
	_check(took > 7.0 and s.status[N].contains("Out of time"),
		"navs: sitting still, the server passed our turn on when time ran out (%.1fs): %s" % [took, s.status[N]])
	# The Pirates' player quits on their turn 2: the computer takes over.
	await _until(func() -> bool: return s.is_computer(P), 30.0)
	_check(not s.won, "navs: the Pirates' player left, the computer took their crew, and the game goes on")
	await _until(func() -> bool: return s.current_team == N and s.turn == 3, 120.0)
	_check(true, "navs: the computer finished the Pirates' turn; round 3 is ours")
	_finish(failures == 0)

## The game's HUD shows the clock (Main's TurnClock label, visible).
func main_clock_shows() -> bool:
	var l := get_tree().root.find_child("TurnClock", true, false) as Label
	return l != null and l.is_visible_in_tree() and l.text.begins_with("Your turn  0:")

func _clock_text() -> String:
	var l := get_tree().root.find_child("TurnClock", true, false) as Label
	return l.text if l != null else "(no clock on screen)"

func _pirates() -> void:
	var s: GameServer = await _land(P, 2.0)
	await _until(func() -> bool: return s.current_team == P, 30.0)
	_check(s.status[P].begins_with("Your turn"), "pirates: told it's our turn")
	s.intent(P, "end_turn")
	await _until(func() -> bool: return s.current_team == N)
	await get_tree().create_timer(1.0).timeout
	var l := get_tree().root.find_child("TurnClock", true, false) as Label
	_check(l != null and l.is_visible_in_tree() and l.text.begins_with("NAVS' turn  0:"),
		"pirates: we see the NAVS' clock too: %s" % (l.text if l != null else "none"))
	await _until(func() -> bool: return s.current_team == P and s.turn == 2, 40.0)
	_check(true, "pirates: our second turn came round after the NAVS ran out of time")
	_finish(failures == 0) # leaving: the computer takes our crew

func _turned_away(delay: float, expect: String) -> void:
	await _join(delay)
	var reason: String = await Net.join_failed
	_check(reason.begins_with(expect), "%s: told why we can't play: %s" % [role, reason])
	_check(not Net.is_online(), "%s: and disconnected" % role)
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
			if not seen.has(n) and s.grid.is_walkable(n) and s._occupant(n) == null:
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
