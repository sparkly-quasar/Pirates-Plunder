extends Node
# Drives a player in the browser test (see net_test.gd and tools/web_test.sh,
# which starts the real server and these two). One player connects the way a
# copy in a web browser does, over WebSockets, and the other the way the
# desktop game does, over ENet; both are on the same server at once. Not
# shipped.
#
#   web-wendy  Wendy, as a browser: works out the server's addresses from a
#              page's address; asks the server's status over a WebSocket and
#              finds it free; starts a game over a WebSocket (2 crews, a long
#              island) and leads it; waits for Dan, swaps chat lines with him,
#              sets sail, ends her turn, waits for her next one, and leaves.
#   web-dan    Dan, as the desktop game: finds Wendy's game through the UDP
#              status port, joins it as the Pirates over ENet, chats, plays
#              his turn when it comes, and leaves.

const PORT := 24689
const ADDRESS := "127.0.0.1:24689"

var role := "web-wendy"
var failures := 0
var finder: ServerFinder

func _ready() -> void:
	finder = ServerFinder.new()
	add_child(finder)
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	match role:
		"web-wendy":
			await _wendy()
		_:
			await _dan()

func _wendy() -> void:
	var u := ServerFinder.urls_for_page("https://pirates.example.ts.net/index.html#x")
	_check(u.game == "wss://pirates.example.ts.net/ws" and u.status == "wss://pirates.example.ts.net/status" and u.machine == "pirates.example.ts.net",
		"wendy: a page on https talks to its own host's /ws and /status, over wss: %s" % str(u))
	u = ServerFinder.urls_for_page("https://pirates.example.ts.net:10000/index.html?server=pirates.example.ts.net%3A24680")
	_check(u.game == "wss://pirates.example.ts.net:10000/ws" and u.status == "wss://pirates.example.ts.net:10000/status" and u.machine == "pirates.example.ts.net",
		"wendy: on https, ?server= (from the server's own / redirect) is ignored for /ws and /status: %s" % str(u))
	u =ServerFinder.urls_for_page("http://localhost:8060/index.html?server=127.0.0.1%3A" + str(PORT))
	_check(u.game == "ws://" + ADDRESS and u.status == "ws://127.0.0.1:%d" % (PORT + 1),
		"wendy: ?server= points it at a server's own ports: %s" % str(u))
	finder.watch_web(u)
	var s := await _status_until(func(x: Dictionary) -> bool: return true)
	_check(s.state == "free" and s.v == GameConfig.version() and s.address == u.game,
		"wendy: asked over a WebSocket, the server says it's free, on our version")
	finder.ask_board(s)
	var got: Array = await finder.board_found
	_check(got[1].get("rows", []).is_empty() and int(got[1].get("players", -1)) == 0,
		"wendy: the Hall of Fame answers over the WebSocket too (nobody in it yet)")
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	_check(Net.join_game(str(u.game)) == OK, "wendy: connecting over a WebSocket")
	_check(Net.multiplayer.multiplayer_peer is WebSocketMultiplayerPeer, "wendy: and it is a WebSocket")
	Net.server_request = {"crews": 2, "seats": 2, "length": 2, "size": 5}
	await Net.joined
	_check(Net.dedicated and GameConfig.my_team == 0 and GameConfig.length == TerrainGrid.Length.LONG,
		"wendy: she starts the game and sails the NAVS, on a long island")
	await _until(func() -> bool: return Net.i_lead())
	Net.send_ready(GameConfig.editing_counts())
	await _until(func() -> bool: return _seat(1).get("who", "") == "player" and bool(_seat(1).get("ready", false)), 60.0)
	_check(str(_seat(1).name) == "Dan", "wendy: Dan, on the desktop game, takes the Pirates and chooses his crew")
	Net.say("Ahoy from a browser")
	await _until(func() -> bool: return _heard("Dan", "Ahoy from a desktop"), 20.0)
	_check(_heard("Dan", "Ahoy from a desktop"), "wendy: she hears Dan")
	Net.request_sail()
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 60.0)
	var g: GameServer = Net.game_server
	_check(g.ctrl == [GameConfig.Ctrl.FRIEND, GameConfig.Ctrl.FRIEND], "wendy: she set sail, both crews played by people")
	await _until(func() -> bool: return g.current_team == 0 and g.grid != null, 30.0)
	_check(g.grid != null and g.grid.width * g.grid.height > 2000,
		"wendy: the whole long island arrived over the WebSocket (%dx%d)" % [g.grid.width, g.grid.height])
	s = await _status_until(func(x: Dictionary) -> bool: return x.state == "playing", 15.0)
	_check(s.players.has("Wendy") and s.players.has("Dan"), "wendy: the status says a game is under way, with both of us")
	g.intent(0, "end_turn")
	await _until(func() -> bool: return g.current_team == 1, 20.0)
	_check(true, "wendy: she ended her turn and it's Dan's")
	await _until(func() -> bool: return g.current_team == 0, 60.0)
	_check(g.turn >= 2, "wendy: Dan played his turn, and it's hers again")
	_finish(failures == 0)

func _dan() -> void:
	var s := await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and x.leader == "Wendy", 60.0)
	_check(int(s.crews) == 2 and int(s.open) == 1, "dan: over UDP, the server list shows Wendy's game with a seat free")
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	_check(Net.join_game(ADDRESS) == OK, "dan: connecting over ENet")
	_check(Net.multiplayer.multiplayer_peer is ENetMultiplayerPeer, "dan: and it is ENet")
	Net.server_request = null
	await Net.joined
	_check(GameConfig.my_team == 1 and GameConfig.length == TerrainGrid.Length.LONG, "dan: he joins as the Pirates on Wendy's island")
	await _until(func() -> bool: return not Net.lobby.is_empty())
	Net.send_ready(GameConfig.editing_counts())
	await _until(func() -> bool: return _heard("Wendy", "Ahoy from a browser"), 30.0)
	_check(_heard("Wendy", "Ahoy from a browser"), "dan: he hears Wendy")
	Net.say("Ahoy from a desktop")
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 60.0)
	var g: GameServer = Net.game_server
	await _until(func() -> bool: return g.current_team == 1, 60.0)
	_check(true, "dan: Wendy ended her turn; it's his")
	g.intent(1, "end_turn")
	await _until(func() -> bool: return g.current_team != 1, 20.0)
	_check(true, "dan: he ended his turn")
	await get_tree().create_timer(2.0).timeout
	_finish(failures == 0)

# --- helpers -----------------------------------------------------------------

## The server's status (through whichever way `finder` asks), until `cond` holds.
func _status_until(cond: Callable, limit := 20.0) -> Dictionary:
	var waited := 0.0
	while true:
		if role == "web-dan":
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
