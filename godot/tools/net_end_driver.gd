extends Node
# Drives a player in the end test (see net_test.gd and tools/end_test.sh,
# which starts the real server). Not shipped.
#
#   end-ann  Ann starts a game; once it's going, her connection just goes.
#            Afterwards her server list offers no saved game.
#   end-ben  Ben joins. When Ann goes he's asked at once what to do, and
#            chooses End the Game: he's sent away, told he ended it, and the
#            server keeps nothing (his list offers no saved game either).

const PORT := 24663
const ADDRESS := "127.0.0.1:24663"

var role := "end-ann"
var failures := 0
var finder: ServerFinder
var _asked := 0

func _ready() -> void:
	finder = ServerFinder.new()
	add_child(finder)
	Net.decision_asked.connect(func(_n: String, _s: bool) -> void: _asked += 1)
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	if role == "end-ann":
		await _ann()
	else:
		await _ben()

func _ann() -> void:
	await _status_until(func(x: Dictionary) -> bool: return x.state == "free")
	_join(ADDRESS, {"crews": 2, "seats": 2, "length": 0, "size": 3})
	await Net.joined
	Net.send_ready(GameConfig.editing_counts())
	var g := await _game()
	await _until(func() -> bool: return g.current_team == 0)
	g.intent(0, "end_turn")
	await get_tree().create_timer(2.0).timeout
	# Her connection just goes.
	Net.match_address = ""
	Net.multiplayer.multiplayer_peer.close()
	Net.multiplayer.multiplayer_peer = null
	Net._reset()
	var s := await _status_until(func(x: Dictionary) -> bool: return x.state == "free", 40.0)
	await get_tree().create_timer(1.0).timeout
	s = await _status_until(func(x: Dictionary) -> bool: return x.state == "free", 10.0)
	_check(s.mine.is_empty(), "ann: the game was ended, and her list offers nothing to continue (%d)" % s.mine.size())
	_finish(failures == 0)

func _ben() -> void:
	await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and x.leader == "Ann", 60.0)
	_join(ADDRESS, null)
	await Net.joined
	Net.send_ready(GameConfig.editing_counts())
	var g := await _game()
	await _until(func() -> bool: return _asked >= 1, 60.0)
	_check(bool(Net.decision_info.get("first", false)) and g.paused, "ben: Ann went, and he's asked at once, with the game paused")
	Net.choose("end")
	await _until(func() -> bool: return Net.refusal != "", 20.0)
	_check(Net.refusal.contains("Ben ended the game"), "ben: he ended the game and was sent away: %s" % Net.refusal)
	var s := await _status_until(func(x: Dictionary) -> bool: return x.state == "free", 30.0)
	_check(s.mine.is_empty(), "ben: nothing saved: his list offers nothing to continue (%d)" % s.mine.size())
	_finish(failures == 0)

# --- helpers -----------------------------------------------------------------

func _join(address: String, request: Variant) -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	_check(Net.join_game(address) == OK, "%s: connecting to %s" % [role, address])
	Net.server_request = request

func _game() -> GameServer:
	await _until(func() -> bool:
		var g: GameServer = Net.game_server
		return g != null and is_instance_valid(g) and g.started, 60.0)
	return Net.game_server

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
			print("  [FAIL] %s: the server list never showed what we waited for (last: %s)" % [role, s.state])
			_finish(false)
			return s
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
