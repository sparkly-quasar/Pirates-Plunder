extends Node
# Drives a player in the player-started-games test (see net_test.gd and
# tools/lobby_test.sh, which starts the real server, with lobby=players, and
# these three). Each asks the server's status port the way the Play on a
# Server screen does (ServerFinder). Not shipped.
#
#   lobby-a  Alice: finds the server free; asking only to join, is told nobody
#            has started a game; starts one and leaves at once, and the server
#            is free again; then starts a 2v2 game for 4 players (NAVS and
#            Corsairs against Pirates and Buccaneers, a short island, crews of
#            3), sails the NAVS and leads it; chooses her crew, waits for Bob,
#            chats (to everyone, and to her side only), and leaves before
#            setting sail.
#   lobby-b  Bob: joins Alice's game as the Pirates; hears what Alice says to
#            everyone but not what she says to her side, and answers; asking
#            to set sail while Alice leads does nothing; once she leaves he
#            leads, sets sail, and the computer takes the three empty crews.
#            Sees his computer partner's crew, plays a turn and leaves (the
#            server stops: --once).
#   lobby-c  Cara: asks to start a game while Alice's is open, and is told
#            someone just did; once Bob's game is under way the server list
#            says so, and joining is refused.
#   lobby-scan  Not part of the test: lists what ServerFinder finds through
#            Tailscale on this computer, for checking by hand.

const PORT := 24693
const ADDRESS := "127.0.0.1:24693"

var role := "lobby-a"
var failures := 0
var finder: ServerFinder

func _ready() -> void:
	finder = ServerFinder.new()
	add_child(finder)
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	match role:
		"lobby-a":
			await _alice()
		"lobby-b":
			await _bob()
		"lobby-c":
			await _cara()
		_:
			await _scan()

func _alice() -> void:
	var s := await _status_until(func(x: Dictionary) -> bool: return true)
	_check(s.state == "free" and s.lobby == "players" and s.v == GameConfig.version() and int(s.p) == Net.PROTOCOL,
		"alice: the server list finds the server, free, on our version")
	_check(int(s.most) == 4 and int(s.defaults.crews) == 2, "alice: it allows up to 4 crews and suggests 2")
	_check(s.address == ADDRESS, "alice: and gives the address to join")
	# Asking only to join a free server: nothing to join.
	var why := await _refused(null)
	_check(why.begins_with("Nobody has started a game"), "alice: joining a free server is refused: %s" % why)
	# Start a game, and leave before anyone else comes: the server is free again.
	_connect({"crews": 2, "seats": 2})
	await Net.joined
	Net.leave()
	s = await _status_until(func(x: Dictionary) -> bool: return x.state == "free", 10.0)
	_check(s.state == "free", "alice: leaving her empty game frees the server again")
	# The real game.
	_connect({"crews": 4, "seats": 4, "length": 0, "size": 3, "difficulty": 2, "partner": Character.Team.CORSAIRS})
	await Net.joined
	_check(Net.dedicated and GameConfig.my_team == 0, "alice: starting the game seats her as the NAVS")
	_check(GameConfig.team_count == 4 and GameConfig.length == TerrainGrid.Length.SHORT and GameConfig.team_target == 3,
		"alice: with her settings: 4 crews, a short island, crews of 3")
	_check(GameConfig.two_v_two() and GameConfig.sides() == [0, 1, 0, 1], "alice: 2 v 2, the NAVS with the Corsairs")
	await _until(func() -> bool: return Net.i_lead())
	_check(Net.i_lead(), "alice: the lobby says she leads the game")
	Net.send_ready(GameConfig.editing_counts())
	await _until(func() -> bool: return _seat(1).get("who", "") == "player" and bool(_seat(0).get("ready", false)), 40.0)
	_check(str(_seat(1).name) == "Bob", "alice: Bob shows up in the Pirates' seat, by name")
	await get_tree().create_timer(1.0).timeout
	Net.say("Ahoy, Bob!")
	Net.say("Psst, Corsairs only", true)
	await _until(func() -> bool: return _heard("Bob", "Aye, Alice"), 20.0)
	_check(_heard("Bob", "Aye, Alice") and _heard("Alice", "Psst, Corsairs only"),
		"alice: she hears Bob's answer, and her own line to her side")
	s = await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and int(x.taken) == 2)
	_check(s.leader == "Alice" and int(s.people) == 4 and int(s.open) == 2 and s.players.has("Bob") and int(s.partner) == 2,
		"alice: the server list shows her game: led by Alice, 2 v 2, 2 of 4 player seats free, Bob there")
	await get_tree().create_timer(4.0).timeout # Cara's try at starting a game of her own
	_finish(failures == 0) # leaving before setting sail: Bob takes over

func _bob() -> void:
	await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and x.leader == "Alice" and int(x.crews) == 4, 60.0)
	_connect(null)
	await Net.joined
	_check(GameConfig.my_team == 1 and GameConfig.team_count == 4 and GameConfig.team_target == 3 and GameConfig.sides() == [0, 1, 0, 1],
		"bob: joins Alice's game as the Pirates, on her settings (2 v 2)")
	await _until(func() -> bool: return not Net.lobby.is_empty())
	_check(not Net.i_lead() and int(Net.lobby.leader) == 0, "bob: Alice leads, not him")
	Net.send_ready(GameConfig.editing_counts())
	await _until(func() -> bool: return _heard("Alice", "Ahoy, Bob!"), 30.0)
	await get_tree().create_timer(1.5).timeout
	_check(_heard("Alice", "Ahoy, Bob!") and not _heard("Alice", "Psst, Corsairs only"),
		"bob: hears what Alice says to everyone, not what she says to her side")
	Net.say("Aye, Alice")
	Net.request_sail()
	await get_tree().create_timer(2.0).timeout
	_check(Net.game_server == null and not Net.lobby.is_empty(), "bob: asking to set sail while Alice leads does nothing")
	await _until(func() -> bool: return Net.i_lead(), 40.0)
	_check(_seat(0).get("who", "") == "open", "bob: Alice left, so he leads now, and her seat is open")
	Net.request_sail()
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 30.0)
	var g: GameServer = Net.game_server
	var C := GameConfig.Ctrl.COMPUTER
	var F := GameConfig.Ctrl.FRIEND
	_check(g.team_count == 4 and g.ctrl == [C, F, C, C],
		"bob: he set sail, and the computer sails the other three crews: %s" % str(g.ctrl))
	await _until(func() -> bool: return not g.seen[1].is_empty(), 20.0)
	var partner_ids := g._members(Character.Team.BUCCANEERS).map(func(c: Character) -> int: return c.id)
	_check(g.sides == [0, 1, 0, 1] and partner_ids.all(func(id: int) -> bool: return g.seen[1].has(id)),
		"bob: his partner's crew (the computer's Buccaneers) is always in sight")
	await _until(func() -> bool: return g.current_team == 1, 90.0)
	_check(true, "bob: the computer's NAVS moved, and it's his turn")
	g.intent(1, "end_turn")
	await _until(func() -> bool: return g.current_team != 1, 20.0)
	_check(true, "bob: he ended his turn")
	await get_tree().create_timer(2.0).timeout # for Cara to see the game under way
	_finish(failures == 0)

func _cara() -> void:
	var s := await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and int(x.crews) == 4, 60.0)
	_check(s.leader == "Alice", "cara: the server list shows Alice's game being set up")
	var why := await _refused({"crews": 2})
	_check(why.begins_with("Someone else has just started a game"), "cara: starting a second game is refused: %s" % why)
	s = await _status_until(func(x: Dictionary) -> bool: return x.state == "playing", 90.0)
	_check(s.state == "playing" and s.players.has("Bob"), "cara: the server list says a game is under way, with Bob")
	why = await _refused(null)
	_check(why.begins_with("A game is already under way"), "cara: joining it is refused: %s" % why)
	_finish(failures == 0)

## Not part of the test: what Tailscale and the servers on it say, from here.
func _scan() -> void:
	finder.scan()
	var note: String = await finder.scanned
	print("Tailscale: %s" % ("read its list of machines" if note == "" else note))
	await get_tree().create_timer(4.0).timeout
	for s in finder.servers():
		print("  %s at %s: version %s, %s%s" % [s.machine, s.address, s.v, s.state,
			(", %s's game" % s.leader) if str(s.leader) != "" else ""])
	print("NET_RESULT lobby-scan: %d server(s) found" % finder.servers().size())
	Net.leave_and_quit(0)

# --- helpers -----------------------------------------------------------------

func _connect(request: Variant) -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	_check(Net.join_game(ADDRESS) == OK, "%s: connecting" % role)
	Net.server_request = request

## Connects asking for `request`, and returns why the server sent us away.
func _refused(request: Variant) -> String:
	_connect(request)
	var why: String = await Net.join_failed
	_check(not Net.is_online(), "%s: and is disconnected" % role)
	return why

## The server's status, asked again until `cond` holds.
func _status_until(cond: Callable, limit := 20.0) -> Dictionary:
	var waited := 0.0
	while true:
		finder.look_up(ADDRESS)
		var t := Time.get_ticks_msec()
		var s: Dictionary = await finder.found
		if cond.call(s):
			return s
		await get_tree().create_timer(0.3).timeout
		waited += (Time.get_ticks_msec() - t) / 1000.0 + 0.3
		if waited > limit:
			print("  [FAIL] %s: the server list never showed what we waited for (last: %s %s)" % [role, s.state, s.leader])
			_finish(false)
			return s
	return {}

## Whether a chat line from `who` saying `text` has arrived.
func _heard(who: String, text: String) -> bool:
	return Net.chat_log.any(func(m: Dictionary) -> bool: return m.name == who and m.text == text)

func _seat(team: int) -> Dictionary:
	for seat in Net.lobby.get("seats", []):
		if int(seat.team) == team:
			return seat
	return {}

func _until(cond: Callable, limit := 20.0) -> void:
	var waited := 0.0
	while not cond.call():
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > limit:
			print("  [FAIL] %s waited too long" % role)
			_finish(false)
			return

func _check(cond: bool, label: String) -> void:
	if not cond:
		failures += 1
	print(("  [PASS] " if cond else "  [FAIL] "), label)

func _finish(ok: bool) -> void:
	print("NET_RESULT %s: %s" % [role, "ALL PASS" if ok else "FAIL"])
	Net.leave_and_quit(0 if ok else 1)
