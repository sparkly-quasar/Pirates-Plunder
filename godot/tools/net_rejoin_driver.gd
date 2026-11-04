extends Node
# Drives a player in the rejoin test (see net_test.gd and tools/rejoin_test.sh,
# which starts the real server with --rejoin-seconds=6 and these two). What
# happens when a connection drops. Not shipped.
#
#   rejoin-ann  Ann, over WebSockets (as a browser), starts a game; Ben joins.
#     A. Her connection drops: the game waits; her copy gets back in by
#        itself, onto the island as it stands.
#     C1. It drops again and she stays away: Ben gives her crew to the
#        computer. She comes back later and takes it back.
#     C2. It drops again: Ben keeps waiting, then saves the game for later.
#        Her server list offers the saved game; she continues it, Ben joins,
#        and both are back mid-game.
#     E. She leaves on purpose: the computer takes her crew at once.
#   rejoin-ben  Ben, over ENet:
#     A. Sees the game wait for Ann, and carry on when she's back.
#     B. His connection hangs; a new one takes his crew over from it.
#     C1-C2. Answers the server's question (replace; wait, then save), and is
#        sent away when the game is saved; joins Ann's continued game.
#     F. Alone (Ann has left), his connection drops: the server saves the
#        game and frees itself, and when his copy reconnects it reopens the
#        game for him at once. He leaves, and the game is in his list.

const PORT := 24685
const ADDRESS := "127.0.0.1:24685"
const C := GameConfig.Ctrl.COMPUTER
const F := GameConfig.Ctrl.FRIEND

var role := "rejoin-ann"
var failures := 0
var finder: ServerFinder
var _hung: MultiplayerPeer = null # Ben's old connection, left hanging
var _asked := 0                    # questions the server has asked us
var _decided := ""

func _ready() -> void:
	finder = ServerFinder.new()
	add_child(finder)
	Net.decision_asked.connect(func(_n: String, _s: bool) -> void: _asked += 1)
	Net.decision_made.connect(func(t: String) -> void: _decided = t)
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	if role == "rejoin-ann":
		await _ann()
	else:
		await _ben()

func _ann() -> void:
	finder.watch_web({"game": "ws://" + ADDRESS, "status": "ws://127.0.0.1:%d" % (PORT + 1), "machine": "here"})
	await _status_until(func(x: Dictionary) -> bool: return x.state == "free")
	_join("ws://" + ADDRESS, {"crews": 2, "seats": 2, "length": 0, "size": 3})
	await Net.joined
	Net.send_ready(GameConfig.editing_counts())
	var g := await _game()
	await _until(func() -> bool: return g.current_team == 0)
	g.intent(0, "end_turn")
	await _until(func() -> bool: return g.current_team == 0 and g.turn >= 2, 30.0)
	var people := g.characters.size()
	# A. A blip: her copy gets straight back in.
	Net.multiplayer.multiplayer_peer.close()
	Net.multiplayer.server_disconnected.emit()
	_check(Net.reconnecting, "ann: A. her connection dropped; her copy is getting back in")
	g = await _game(g)
	_check(not Net.reconnecting and GameConfig.my_team == 0 and g.characters.size() == people and g.turn >= 2,
		"ann: A. back in, sailing the NAVS, on the same island (turn %d)" % g.turn)
	await _until(func() -> bool: return not g.paused, 20.0)
	await _until(func() -> bool: return _heard("Ben", "back again"), 60.0) # B happens on Ben's side
	# C1. She drops and stays away; Ben gives her crew to the computer.
	_drop()
	await get_tree().create_timer(14.0).timeout
	_join("ws://" + ADDRESS, null)
	g = await _game(g)
	await _until(func() -> bool: return g.ctrl[0] == F, 20.0)
	_check(GameConfig.my_team == 0 and g.ctrl[0] == F, "ann: C1. later, she takes her crew back from the computer")
	Net.say("ann is back")
	await _until(func() -> bool: return _heard("Ben", "welcome back"), 30.0)
	var turn := g.turn
	# C2. She drops again; Ben keeps waiting, then saves the game for later.
	_drop()
	var s := await _status_until(func(x: Dictionary) -> bool: return x.state == "free" and not x.mine.is_empty(), 60.0)
	_check(s.mine.size() == 1, "ann: C2. the game was saved, and her server list offers it: %s" % (s.mine[0].s if not s.mine.is_empty() else "nothing"))
	_join("ws://" + ADDRESS, {"continue": str(s.mine[0].id)})
	await Net.joined
	_check(Net.resuming and GameConfig.my_team == 0, "ann: C2. continuing it: back in her own crew")
	g = await _game(g)
	await _until(func() -> bool: return g.started and g.ctrl[1] == F, 30.0)
	_check(g.characters.size() == people and g.turn >= turn, "ann: C2. Ben is back too, and everyone is where they were (turn %d)" % g.turn)
	Net.say("continued")
	await _until(func() -> bool: return _heard("Ben", "aye"), 30.0)
	# E. She leaves for good.
	_finish(failures == 0)

func _ben() -> void:
	await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and x.leader == "Ann", 60.0)
	_join(ADDRESS, null)
	await Net.joined
	Net.send_ready(GameConfig.editing_counts())
	var g := await _game()
	var ender := Timer.new() # he ends his turns as they come
	ender.wait_time = 0.5
	ender.autostart = true
	ender.timeout.connect(func() -> void:
		var now: GameServer = Net.game_server
		if now != null and is_instance_valid(now) and now.current_team == 1 and now.started and not now.paused:
			now.intent(1, "end_turn"))
	add_child(ender)
	# A. Ann blips: the game waits for her, then carries on.
	await _until(func() -> bool: return g.paused, 60.0)
	_check(g.paused and g.status[1].contains("Waiting for them"), "ben: A. Ann lost her connection; the game waits for her: %s" % g.status[1])
	await _until(func() -> bool: return not g.paused, 20.0)
	_check(g.ctrl[0] == F, "ben: A. she's back and the game carries on, her crew still hers")
	# B. His connection hangs; a new one takes over.
	ender.paused = true
	_hung = Net.multiplayer.multiplayer_peer
	var keep := Net.match_address
	_check(Net._connect_to(ADDRESS) == OK, "ben: B. a new connection, the old one still hanging")
	Net.match_address = keep
	g = await _game(g)
	_check(GameConfig.my_team == 1 and g.ctrl[1] == F, "ben: B. the new connection takes his crew over from the old one")
	ender.paused = false
	Net.say("back again")
	# C1. Ann drops and stays away: he's asked, and gives her crew to the computer.
	await _until(func() -> bool: return _asked >= 1, 40.0)
	_check(g.paused, "ben: C1. after the wait, he's asked what to do (the game still paused)")
	Net.choose("replace")
	await _until(func() -> bool: return g.ctrl[0] == C and not g.paused, 20.0)
	_check(g.ctrl[0] == C and _decided.contains("gave Ann's crew to the computer"), "ben: C1. the computer sails Ann's crew: %s" % _decided)
	await _until(func() -> bool: return g.ctrl[0] == F and _heard("Ann", "ann is back"), 40.0)
	_check(true, "ben: C1. Ann came back and took her crew back")
	Net.say("welcome back")
	# C2. She drops again: he waits once more, then saves the game for later.
	await _until(func() -> bool: return _asked >= 2, 40.0)
	Net.choose("wait")
	await _until(func() -> bool: return _decided.contains("keep waiting"), 10.0)
	_check(g.paused, "ben: C2. he chose to keep waiting: %s" % _decided)
	await _until(func() -> bool: return _asked >= 3, 40.0)
	Net.choose("save")
	await _until(func() -> bool: return Net.refusal != "", 20.0)
	_check(Net.refusal.contains("saved the game for later"), "ben: C2. he saved it for later, and was sent away: %s" % Net.refusal)
	ender.paused = true
	await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and x.leader == "Ann", 60.0)
	_join(ADDRESS, null)
	await Net.joined
	_check(Net.resuming and GameConfig.my_team == 1, "ben: C2. Ann continued it; he joins, back in his own crew")
	g = await _game(g)
	ender.paused = false
	await _until(func() -> bool: return _heard("Ann", "continued"), 30.0)
	Net.say("aye")
	# E. Ann leaves on purpose: the computer takes her crew straight away.
	await _until(func() -> bool: return g.ctrl[0] == C, 40.0)
	_check(not g.paused, "ben: E. Ann left; the computer sails her crew, no waiting")
	# F. Alone, he loses his connection; his copy gets him back in.
	await get_tree().create_timer(1.0).timeout
	Net.multiplayer.multiplayer_peer.close()
	Net.multiplayer.server_disconnected.emit()
	g = await _game(g, 40.0)
	_check(not Net.reconnecting and GameConfig.my_team == 1 and g.ctrl[1] == F and g.ctrl[0] == C,
		"ben: F. the server saved his game when he dropped, and reopened it when his copy came back")
	await get_tree().create_timer(1.0).timeout
	Net.leave()
	var s := await _status_until(func(x: Dictionary) -> bool: return x.state == "free" and not x.mine.is_empty(), 20.0)
	_check(not s.mine.is_empty(), "ben: F. he left; the game is in his list for another day: %s" % (s.mine[0].s if not s.mine.is_empty() else "nothing"))
	_finish(failures == 0)

# --- helpers -----------------------------------------------------------------

func _join(address: String, request: Variant) -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	_check(Net.join_game(address) == OK, "%s: connecting to %s" % [role, address])
	Net.server_request = request

## The game on our screen, once it's going (a new one if `old` is given).
func _game(old: GameServer = null, limit := 60.0) -> GameServer:
	var old_id := old.get_instance_id() if is_instance_valid(old) else 0
	await _until(func() -> bool:
		var g: GameServer = Net.game_server
		return g != null and is_instance_valid(g) and g.get_instance_id() != old_id and g.started, limit)
	return Net.game_server

## The connection just goes, without a word, and we don't try to get back in.
func _drop() -> void:
	Net.match_address = ""
	if Net.multiplayer.multiplayer_peer != null:
		Net.multiplayer.multiplayer_peer.close()
	Net.multiplayer.multiplayer_peer = null
	Net._reset()

func _status_until(cond: Callable, limit := 20.0) -> Dictionary:
	var waited := 0.0
	while true:
		if role == "rejoin-ben":
			finder.look_up(ADDRESS)
		var t := Time.get_ticks_msec()
		var s: Dictionary = await finder.found
		if cond.call(s):
			return s
		await get_tree().create_timer(0.3).timeout
		waited += (Time.get_ticks_msec() - t) / 1000.0 + 0.3
		if waited > limit:
			print("  [FAIL] %s: the server list never showed what we waited for (last: %s)" % [role, s.state])
			_finish(false)
			return s
	return {}

func _heard(who: String, text: String) -> bool:
	return Net.chat_log.any(func(m: Dictionary) -> bool: return m.name == who and m.text == text)

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
