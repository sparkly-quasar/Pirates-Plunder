extends Node
# Drives a player in the Battle Royale network test (see net_test.gd and
# tools/royale_test.sh, which starts the real server and these two). Not shipped.
#
#   royale-ann  Ann: starts a Battle Royale on the free server (3 crews, 2 of
#               them players, 3 rounds, Vega only in the final round) and
#               brings her trained crew: six sailors and Vega, plus a few
#               entries a tampered copy might send (a skill past its cap, a
#               name used twice, a class that doesn't exist, a second special).
#               Once Bo has brought his crew she sets sail. On the island her
#               crew is exactly her six, as trained but within the coaching
#               limits, with Vega ashore for round 1.
#   royale-bo   Bo: sees the Battle Royale in the server list, joins it, and,
#               with no trained crew, brings ten fresh recruits. On the island
#               he sees Ann's crew as she trained it, and the computer's crew.
#   royale-host Hal hosts a one-round Battle Royale himself (Play Direct): his
#               crew of three and Vega; one round is the final, so she sails.
#   royale-guest Gus joins Hal's with his crew of two.

const ADDRESS := "127.0.0.1:24697"

var role := "royale-ann"
var failures := 0
var finder: ServerFinder

func _ready() -> void:
	finder = ServerFinder.new()
	add_child(finder)
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("  [FAIL] %s timed out" % role)
		_finish(false))
	match role:
		"royale-ann": await _ann()
		"royale-bo": await _bo()
		"royale-host": await _hal()
		_: await _gus()

## Ann's crew as saved by single player: a Runner coached to 100 speed, a
## Swordsman, four more, and Vega; then the junk.
func _ann_crew() -> Array:
	var out: Array = []
	var runner := CharacterStats.make(CharacterStats.Kind.RUNNER, "Annie Runner")
	runner.speed = 100.0
	runner.stamina = 90.0
	out.append(runner.to_dict())
	var sword := CharacterStats.make(CharacterStats.Kind.SWORDSMAN, "Annie Blade")
	sword.swordfighting = 999.0 # past the cap (100): the host brings it down
	out.append(sword.to_dict())
	for i in 4:
		out.append(CharacterStats.make(CharacterStats.Kind.FIGHTER, "Annie %d" % i).to_dict())
	out.append(Campaign.make_vega().to_dict())
	out.append(CharacterStats.make(CharacterStats.Kind.SCOUT, "Annie 0").to_dict()) # a name used twice
	out.append({"kind": 42, "name": "Nobody"}) # no such class
	var fake := Campaign.make_vega().to_dict()
	fake.name = "Vega Two" # a second special
	out.append(fake)
	return out

func _ann() -> void:
	await _status_until(func(x: Dictionary) -> bool: return x.state == "free")
	_connect({"crews": 3, "seats": 2, "length": 0, "royale": true, "rounds": 3, "vega": false})
	GameConfig.crew = _ann_crew() # in memory only: never saved over a real crew
	await Net.joined
	_check(GameConfig.battle_royale and GameConfig.br_rounds == 3 and not GameConfig.br_vega and GameConfig.partner == GameConfig.FREE_FOR_ALL,
		"ann: the server seats her in a Battle Royale: 3 rounds, Vega in the final only, every crew for itself")
	Net.send_crew(GameConfig.my_br_crew())
	await _until(func() -> bool: return Net.i_lead() and bool(_seat(1).get("ready", false)) and bool(_seat(0).get("ready", false)), 60.0)
	_check(true, "ann: she leads, and both crews are in")
	Net.request_sail()
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 40.0)
	var g: GameServer = Net.game_server
	var mine := g.characters.filter(func(c: Character) -> bool: return c.team == 0)
	var names: Array = mine.map(func(c: Character) -> String: return c.stats.person_name)
	names.sort()
	_check(names == ["Annie 0", "Annie 1", "Annie 2", "Annie 3", "Annie Blade", "Annie Runner"],
		"ann: her own six land, the junk dropped and Vega ashore for round 1: %s" % str(names))
	var runner: Character = mine.filter(func(c: Character) -> bool: return c.stats.person_name == "Annie Runner")[0]
	var blade: Character = mine.filter(func(c: Character) -> bool: return c.stats.person_name == "Annie Blade")[0]
	_check(runner.stats.speed == 100.0 and runner.stats.stamina == 90.0, "ann: her Runner lands as she trained him")
	_check(blade.stats.swordfighting == blade.stats.coach_cap("swordfighting"), "ann: a skill past its limit is brought down to it")
	_check(g.team_count == 3 and GameConfig.br_round_text() == "Round 1 of 3" and not GameConfig.br_vega_allowed(),
		"ann: round 1 of 3, three crews")
	await _until(func() -> bool: return _heard("Bo", "Seen it"), 30.0)
	_finish(failures == 0)

func _bo() -> void:
	var s := await _status_until(func(x: Dictionary) -> bool: return x.state == "setup" and x.leader == "Ann", 60.0)
	var royale: Dictionary = s.get("royale", {})
	_check(bool(royale.get("on", false)) and int(royale.get("rounds", 0)) == 3, "bo: the server list shows Ann's Battle Royale")
	# The server's Hall of Fame (royale_test.sh fills it in before starting the server).
	finder.ask_board(s)
	var got: Array = await finder.board_found
	var board: Dictionary = got[1]
	var rows: Array = board.get("rows", [])
	var mine := rows.filter(func(r: Array) -> bool: return str(r[2]) == ServerFinder.back_key("royale-bo"))
	_check(rows.size() == 2 and str(rows[0][1]) == "Champ" and int(rows[0][4]) == 5 and int(rows[0][5]) == 2,
		"bo: the Hall of Fame comes back, best first: %s" % str(rows))
	_check(mine.size() == 1 and str(mine[0][1]) == "Bo" and int(mine[0][0]) == 2, "bo: his own row is there, marked as his, second")
	_connect(null)
	GameConfig.crew = [] # never played single player
	await Net.joined
	_check(GameConfig.battle_royale and GameConfig.my_team == 1, "bo: he joins it as the Pirates, and knows it's a Battle Royale")
	var bring := GameConfig.my_br_crew()
	_check(bring.size() == 10, "bo: with no trained crew he brings ten fresh recruits")
	Net.send_crew(bring)
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 60.0)
	var g: GameServer = Net.game_server
	var ann := g.characters.filter(func(c: Character) -> bool: return c.team == 0)
	var his := g.characters.filter(func(c: Character) -> bool: return c.team == 1)
	var cpu := g.characters.filter(func(c: Character) -> bool: return c.team == 2)
	_check(ann.size() == 6 and ann.any(func(c: Character) -> bool: return c.stats.person_name == "Annie Runner" and c.stats.speed == 100.0),
		"bo: he sees Ann's crew as she trained it")
	_check(his.size() == 10 and cpu.size() == GameConfig.DEFAULT_TEAM_SIZE and not g.characters.any(func(c: Character) -> bool: return c.stats.special != ""),
		"bo: his ten, the computer's fresh crew, and no Vega anywhere in round 1")
	Net.say("Seen it")
	await get_tree().create_timer(2.0).timeout
	_finish(failures == 0)

const DIRECT_PORT := 24699

func _hal() -> void:
	GameConfig.host_royale()
	GameConfig.team_count = 2
	GameConfig.set_battle_royale(true, 1, false)
	GameConfig.turn_seconds = 120 # chosen on the setup screen
	GameConfig.crew = [CharacterStats.make(CharacterStats.Kind.SCOUT, "Hal Scout").to_dict(),
		CharacterStats.make(CharacterStats.Kind.DIGGER, "Hal Digger").to_dict(),
		CharacterStats.make(CharacterStats.Kind.SWORDSMAN, "Hal Blade").to_dict(), Campaign.make_vega().to_dict()]
	_check(Net.host_game(DIRECT_PORT) == OK, "hal: hosting a Battle Royale")
	Net.guest_ready.connect(func(_c: Dictionary) -> void: Net.start_match())
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 60.0)
	var g: GameServer = Net.game_server
	var mine: Array = g.characters.filter(func(c: Character) -> bool: return c.team == 0).map(func(c: Character) -> String: return c.stats.person_name)
	var his: Array = g.characters.filter(func(c: Character) -> bool: return c.team == 1).map(func(c: Character) -> String: return c.stats.person_name)
	mine.sort()
	his.sort()
	_check(mine == ["Hal Blade", "Hal Digger", "Hal Scout", "Vega"], "hal: his crew lands, Vega too (one round is the final): %s" % str(mine))
	_check(his == ["Gus A", "Gus B"], "hal: Gus's crew lands as he brought it: %s" % str(his))
	await _until(func() -> bool: return _heard("Gus", "Aye"), 30.0)
	_finish(failures == 0)

func _gus() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	GameConfig.crew = [CharacterStats.make(CharacterStats.Kind.RUNNER, "Gus A").to_dict(),
		CharacterStats.make(CharacterStats.Kind.FIGHTER, "Gus B").to_dict()]
	var tries := 0
	while Net.join_game("127.0.0.1:%d" % DIRECT_PORT) != OK and tries < 5:
		tries += 1
		await get_tree().create_timer(1.0).timeout
	await Net.joined
	_check(GameConfig.battle_royale and GameConfig.br_rounds == 1 and GameConfig.br_vega_allowed() and GameConfig.turn_seconds == 120,
		"gus: Hal's game says it's a one-round Battle Royale, with 2-minute turns")
	Net.send_crew(GameConfig.my_br_crew())
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started, 60.0)
	var g: GameServer = Net.game_server
	_check(g.characters.any(func(c: Character) -> bool: return c.team == 0 and c.stats.special == Campaign.SPECIAL_VEGA),
		"gus: he sees Hal's Vega on the island")
	await _until(func() -> bool: return g.clock_left() > 0.0, 20.0)
	_check(g.clock_left() > 100.0 and g.clock_left() <= 120.0, "gus: and Hal's turn clock, counting down from 2 minutes (%.0fs)" % g.clock_left())
	Net.say("Aye")
	await get_tree().create_timer(2.0).timeout
	_finish(failures == 0)

# --- helpers (as in net_lobby_driver.gd) ---------------------------------------

func _connect(request: Variant) -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	_check(Net.join_game(ADDRESS) == OK, "%s: connecting" % role)
	Net.server_request = request

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
