extends Node
# Drives one player in the saved-online-match test (see net_test.gd and
# tools/resume_test.sh, which runs the three stages in order). Three crews:
# a host (NAVS) and two friends, each process with its own --player-id=.
# Not shipped.
#
#   --stage=play     A fresh match. guest-a joins first (Pirates), guest-b
#                    second (Corsairs). The host wins game 1; each friend
#                    coaches and renames one of their crew, then leaves. The
#                    match has saved itself, coaching and all.
#   --stage=match    The host continues the match the way the menu's Continue
#                    Online Match does, through the real Lobby. guest-b joins
#                    first this time and must still get the Corsairs back.
#                    Neither chooses a crew; game 2 lands the coached crews on
#                    a new island. The host plays a turn, then Save and Quit
#                    (the in-game menu's) partway through; both friends are
#                    told why the game ended.
#   --stage=midgame  The host continues the match saved partway through
#                    game 2. Everyone is rebuilt exactly as saved, on the
#                    same island and turn; play carries on across the network.
#
# Roles: resume-host, resume-guest-a, resume-guest-b. The host's saves go to
# a test slot, not your real online save; the guests check that their own
# slots are never touched.

const PORT := 24701
const N := Character.Team.NAVS
const P := Character.Team.PIRATES
const C := Character.Team.CORSAIRS
const SAVE := "user://resume_test_online.cfg"
const EXPECT := "user://resume_test_expect.cfg" # what the host left, for the next stage
const GUEST_SAVES := {
	"resume-guest-a": ["user://resume_test_a_save.cfg", "user://resume_test_a_online.cfg"],
	"resume-guest-b": ["user://resume_test_b_save.cfg", "user://resume_test_b_online.cfg"],
}
const IDS := {"resume-host": "host-1", "resume-guest-a": "guest-a", "resume-guest-b": "guest-b"}
const NAMES := {P: "Annie", C: "Bonny"}

var role := "resume-host"
var stage := "play"
var failures := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stage="):
			stage = a.trim_prefix("--stage=")
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("  [FAIL] %s (%s) timed out" % [role, stage])
		_finish(false))
	_check(GameConfig.player_id() == IDS.get(role, ""), "%s: this copy is %s" % [_who(), GameConfig.player_id()])
	match [role, stage]:
		["resume-host", "play"]: await _host_play()
		["resume-host", "match"]: await _host_match()
		["resume-host", "midgame"]: await _host_midgame()
		["resume-guest-a", "play"]: await _guest_play(P, 0.5)
		["resume-guest-b", "play"]: await _guest_play(C, 2.0)
		["resume-guest-b", "match"]: await _guest_match(C, 0.5, "first")
		["resume-guest-a", "match"]: await _guest_match(P, 2.0, "second")
		["resume-guest-a", "midgame"]: await _guest_midgame(P, 0.5)
		["resume-guest-b", "midgame"]: await _guest_midgame(C, 2.0)
		_:
			_check(false, "%s: no such stage" % _who())
			_finish(false)

# --- the host --------------------------------------------------------------

func _host_play() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPECT))
	GameConfig.reset()
	GameConfig.team_target = 5 # these tests count on crews of five
	for t in GameConfig.MAX_TEAMS:
		GameConfig.team_counts[t] = GameConfig.balanced_counts(5)
	GameConfig.mode = GameConfig.Mode.HOST
	GameConfig.online_save_path = SAVE
	GameConfig.island_seed = 4242
	GameConfig.team_count = 3
	_check(Net.host_game(PORT) == OK, "host: listening on %d" % PORT)
	Net.guest_ready.connect(func(_c: Dictionary) -> void:
		if Net.all_seats_ready():
			Net.start_match())
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started and Net.all_in_game(), 60.0)
	var s: GameServer = Net.game_server
	_check(s.team_count == 3 and s.characters.size() == 15, "host: three crews of five landed")
	_check(GameConfig.seat_owners.get(P) == "guest-a" and GameConfig.seat_owners.get(C) == "guest-b",
		"host: knows whose crew is whose: %s" % [GameConfig.seat_owners])
	s._win(N, "a test win")
	_check(GameConfig.has_save(SAVE) and GameConfig.save_summary(SAVE).begins_with("Online match"),
		"host: the match saved itself when the game ended: %s" % GameConfig.save_summary(SAVE))
	# Each friend coaches and renames one of their crew, then leaves.
	await _until(func() -> bool: return _crew_name(P, 0) == NAMES[P] and _crew_name(C, 0) == NAMES[C], 30.0)
	await _until(func() -> bool: return Net.guests.is_empty(), 30.0)
	_check(true, "host: both friends coached, renamed and left")
	var cfg := ConfigFile.new()
	_check(cfg.load(SAVE) == OK, "host: the save is readable")
	var game: Variant = cfg.get_value("save", "game", {"missing": true})
	_check(game is Dictionary and game.is_empty(), "host: saved between games, with no island in progress")
	var saved: Dictionary = cfg.get_value("save", "match", {})
	var crews: Array = saved.get("crews", [])
	_check(crews.size() == 3 and str(crews[P][0].name) == NAMES[P] and str(crews[C][0].name) == NAMES[C],
		"host: the save keeps the coaching and names done after the game")
	_check(_same_crews(crews, GameConfig.match_crews), "host: the saved crews are the match's crews exactly")
	var expect := ConfigFile.new()
	expect.set_value("play", "seed", GameConfig.island_seed)
	expect.set_value("play", "crews", GameConfig.match_crews)
	expect.save(EXPECT)
	_finish(failures == 0)

## What the menu's Continue Online Match does, on the test port and slot.
func _continue() -> bool:
	Net.leave()
	GameConfig.online_save_path = SAVE
	if not GameConfig.load_game(GameConfig.online_save_path):
		return false
	if Net.host_game(PORT) != OK:
		return false
	Net.resuming = true
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")
	return true

func _host_match() -> void:
	var expect := ConfigFile.new()
	_check(expect.load(EXPECT) == OK, "host: found what the first stage left")
	var want: Array = expect.get_value("play", "crews", [])
	_check(_continue(), "host: Continue Online Match loaded the save and is hosting it")
	_check(GameConfig.mode == GameConfig.Mode.HOST and GameConfig.resume.is_empty() and GameConfig.match_games == 1
		and int(GameConfig.match_score[N]) == 1, "host: one game played, the NAVS 1 up, the next island not begun")
	_check(GameConfig.seat_owners == {P: "guest-a", C: "guest-b"}, "host: remembers whose crew is whose: %s" % [GameConfig.seat_owners])
	_check(GameConfig.is_friend(P) and GameConfig.is_friend(C) and Net.open_seats() == [P, C],
		"host: both crews are seats for friends again, though the computer took them when their players left")
	_check(_same_crews(GameConfig.match_crews, want), "host: the coached crews came back from the save")
	_check(GameConfig.island_seed != int(expect.get_value("play", "seed", 0)), "host: game 2 is on a new island")
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started and Net.all_in_game(), 60.0)
	var s: GameServer = Net.game_server
	_check(_scene() == "res://scenes/Main.tscn", "host: the Lobby set sail once both friends were back")
	_check(_owner_of(P) == "guest-a" and _owner_of(C) == "guest-b", "host: each friend is sailing their own crew")
	_check(s.turn == 1 and s.characters.size() == 15, "host: game 2 begins")
	_check(_landed_as(s, P, want) and _landed_as(s, C, want) and _landed_as(s, N, want),
		"host: every crew landed as coached (%s, %s)" % [NAMES[P], NAMES[C]])
	_check(s.first_team == P and s.current_team == P,
		"host: game 2 opens with the Pirates (the first move goes round the crews, and came back with the save; first %d, now %d)" % [s.first_team, s.current_team])
	await _until(func() -> bool: return s.current_team == N, 60.0)
	_check(s.turn == 1, "host: both friends took their turns; now ours")
	# Play a little, then save partway through, from the in-game menu.
	var mover: Character = _members(s, N)[0]
	s.intent(N, "select", [mover.cell])
	var start := mover.cell
	s.intent(N, "move", [_reachable(s, mover.cell, 3)])
	await _until(func() -> bool: return mover.cell != start and s.save_blocker() == "", 30.0)
	s.intent(N, "end_turn")
	await _until(func() -> bool: return s.current_team == P and s.save_blocker() == "")
	expect.set_value("mid", "seed", GameConfig.island_seed)
	expect.set_value("mid", "turn", s.turn)
	expect.set_value("mid", "cur", s.current_team)
	expect.set_value("mid", "people", _people(s))
	expect.save(EXPECT)
	var menu: GameMenu = s.get_parent().game_menu
	menu._save_and_quit()
	await _until(func() -> bool: return _scene() == "res://scenes/Menu.tscn", 10.0)
	_check(not Net.is_online(), "host: Save and Quit closed the match and went back to the menu")
	var cfg := ConfigFile.new()
	cfg.load(SAVE)
	var game: Variant = cfg.get_value("save", "game", {})
	_check(game is Dictionary and not game.is_empty() and int(game.get("turn", 0)) == int(expect.get_value("mid", "turn", -1)),
		"host: saved partway through game 2: %s" % GameConfig.save_summary(SAVE))
	_finish(failures == 0)

func _host_midgame() -> void:
	var expect := ConfigFile.new()
	_check(expect.load(EXPECT) == OK, "host: found what the second stage left")
	var people: Array = expect.get_value("mid", "people", [])
	_check(_continue(), "host: Continue Online Match loaded the save and is hosting it")
	_check(not GameConfig.resume.is_empty() and GameConfig.island_seed == int(expect.get_value("mid", "seed", -1)),
		"host: picking up game 2 partway through, on the same island")
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.started and Net.all_in_game(), 60.0)
	var s: GameServer = Net.game_server
	_check(_owner_of(P) == "guest-a" and _owner_of(C) == "guest-b", "host: each friend is sailing their own crew")
	_check(s.turn == int(expect.get_value("mid", "turn", -1)) and s.current_team == int(expect.get_value("mid", "cur", -1)),
		"host: the same turn, with the Pirates to move (turn %d)" % s.turn)
	_check(_people(s) == people, "host: all 15 people exactly where and as they were")
	_check(GameConfig.match_games == 1 and _crew_name(P, 0) == NAMES[P], "host: the match around the game came back too")
	# Play goes on: both friends take their turns over the network, then us.
	var turn := s.turn
	await _until(func() -> bool: return s.current_team == N, 60.0)
	_check(s.turn == turn, "host: both friends took their turns in the resumed game")
	s.intent(N, "end_turn")
	_check(s.current_team == P and s.turn == turn + 1, "host: and round %d begins" % s.turn)
	await _until(func() -> bool: return Net.guests.is_empty(), 30.0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPECT))
	_finish(failures == 0)

# --- the friends -----------------------------------------------------------

func _join(delay: float) -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	# Somewhere harmless: a guest must never write to either slot.
	GameConfig.save_path = GUEST_SAVES[role][0]
	GameConfig.online_save_path = GUEST_SAVES[role][1]
	if stage == "play":
		for path in GUEST_SAVES[role]:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	await get_tree().create_timer(delay).timeout
	_check(Net.join_game("127.0.0.1:%d" % PORT) == OK, "%s: connecting" % _who())
	await Net.joined

func _guest_play(team: int, delay: float) -> void:
	await _join(delay)
	_check(GameConfig.my_team == team and not Net.resuming, "%s: a new match; given the %s" % [_who(), GameServer.TEAM_NAMES[team]])
	Net.send_ready(GameConfig.editing_counts())
	await _until(func() -> bool: return Net.game_server != null, 60.0)
	# The host wins; we coach one of our crew, rename them, and leave.
	# (The match state arrives once the host has scored the game: until then
	# a guest knows of only two crews.)
	await _until(_scored.bind(team), 60.0)
	_check(int(GameConfig.match_score[N]) == 1 and GameConfig.match_games == 1, "%s: the NAVS won game 1" % _who())
	Net.send_coaching_plan({0: "vision"})
	await _until(func() -> bool: return bool(GameConfig.match_coached[team]))
	Net.send_rename(0, NAMES[team])
	await _until(func() -> bool: return _crew_name(team, 0) == NAMES[team])
	_check(true, "%s: coached and renamed %s (%s)" % [_who(), NAMES[team], GameConfig.match_note[team]])
	_check_slots_untouched()
	_finish(failures == 0) # leaving from the coaching screen

func _guest_match(team: int, delay: float, order: String) -> void:
	var expect := ConfigFile.new()
	expect.load(EXPECT)
	var want: Array = expect.get_value("play", "crews", [])
	await _join(delay)
	_check(Net.resuming, "%s: told this is a saved match, so there's no crew to choose" % _who())
	_check(GameConfig.my_team == team, "%s: joined %s, and given our own crew back, the %s" % [_who(), order, GameServer.TEAM_NAMES[team]])
	# No send_ready: the host starts once both of us are back.
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.characters.size() == 15, 60.0)
	var s: GameServer = Net.game_server
	_check(not s.is_authority and s.guest_team == team and s.turn == 1, "%s: landed in game 2 without choosing" % _who())
	_check(_landed_as(s, team, want), "%s: our coached crew, %s among them" % [_who(), NAMES[team]])
	_check(GameConfig.match_games == 1 and int(GameConfig.match_score[N]) == 1, "%s: the match score came with it" % _who())
	await _take_turn(s, team)
	await _until(func() -> bool: return not Net.is_online(), 90.0)
	_check(Net.refusal.contains("saved the game"), "%s: told why the game ended: %s" % [_who(), Net.refusal])
	_check_slots_untouched()
	_finish(failures == 0)

func _guest_midgame(team: int, delay: float) -> void:
	var expect := ConfigFile.new()
	expect.load(EXPECT)
	var people: Array = expect.get_value("mid", "people", [])
	await _join(delay)
	_check(Net.resuming and GameConfig.my_team == team, "%s: rejoined the saved game as the %s, nothing to choose" % [_who(), GameServer.TEAM_NAMES[team]])
	await _until(func() -> bool: return Net.game_server != null and Net.game_server.characters.size() == 15, 60.0)
	var s: GameServer = Net.game_server
	var rebuilt := true
	for i in people.size():
		var c: Character = s.characters[i]
		rebuilt = rebuilt and c.stats.person_name == str(people[i].name) and c.team == int(people[i].team) \
			and (c.team != team or c.cell == people[i].cell)
	_check(rebuilt, "%s: rebuilt the same 15 people, ours where we left them" % _who())
	await _until(func() -> bool: return s.turn == int(expect.get_value("mid", "turn", -1)) and s.current_team == P, 30.0)
	_check(true, "%s: the host's snapshots brought the saved turn (%d, the Pirates to move)" % [_who(), s.turn])
	var turn := s.turn
	await _take_turn(s, team)
	await _until(func() -> bool: return s.current_team == P and s.turn == turn + 1, 60.0)
	_check(true, "%s: play carried on to round %d" % [_who(), s.turn])
	_check_slots_untouched()
	_finish(failures == 0)

## Wait for our turn, then end it.
func _take_turn(s: GameServer, team: int) -> void:
	# (Ours once everyone has come ashore, which the host's snapshots tell us.)
	await _until(func() -> bool: return s.started and s.current_team == team, 60.0)
	_check(not s.status[team].contains("Wait"), "%s: our turn: %s" % [_who(), s.status[team]])
	s.intent(team, "end_turn")
	await _until(func() -> bool: return s.current_team != team, 20.0)

func _scored(team: int) -> bool:
	return GameConfig.match_crews.size() > team and GameConfig.match_crews[team].size() == GameConfig.team_target \
		and GameConfig.match_games >= 1

func _check_slots_untouched() -> void:
	_check(not FileAccess.file_exists(GUEST_SAVES[role][0]) and not FileAccess.file_exists(GUEST_SAVES[role][1]),
		"%s: neither of our own save slots was written" % _who())

# --- helpers ---------------------------------------------------------------

func _scene() -> String:
	var scene := get_tree().current_scene
	return scene.scene_file_path if scene != null else ""

func _who() -> String:
	return "%s (%s)" % [role.trim_prefix("resume-"), stage]

func _crew_name(team: int, i: int) -> String:
	if team >= GameConfig.match_crews.size() or i >= GameConfig.match_crews[team].size():
		return ""
	return str(GameConfig.match_crews[team][i].get("name", ""))

func _owner_of(team: int) -> String:
	var id := Net.peer_for(team)
	return Net.updater.player_of(id) if id != 0 else ""

func _members(s: GameServer, team: int) -> Array:
	return s.characters.filter(func(c: Character) -> bool: return c.team == team)

## The crews' names and skills match, person by person.
func _same_crews(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for t in a.size():
		if a[t].size() != b[t].size():
			return false
		for i in a[t].size():
			for k in ["name", "kind", "vision", "sword", "speed", "stamina", "stealth"]:
				if str(a[t][i].get(k, "")) != str(b[t][i].get(k, "")):
					return false
	return true

## `team` landed as the match's crew `want[team]`: the same people, coached.
func _landed_as(s: GameServer, team: int, want: Array) -> bool:
	var landed := _members(s, team)
	if team >= want.size() or landed.size() != want[team].size():
		return false
	var names := []
	for c in landed:
		names.append(c.stats.person_name)
	for d in want[team]:
		var i := names.find(str(d.name))
		if i < 0 or not is_equal_approx(landed[i].stats.vision, float(d.vision)):
			return false
	return true

func _people(s: GameServer) -> Array:
	var out := []
	for c in s.characters:
		out.append({"name": c.stats.person_name, "team": c.team, "cell": c.cell, "energy": snappedf(c.energy, 0.01),
			"carrying": c.carrying, "captured": c.captured})
	return out

func _until(cond: Callable, limit := 20.0) -> void:
	var waited := 0.0
	while not cond.call():
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > limit:
			print("  [FAIL] %s waited too long" % _who())
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

var _done := false
func _finish(ok: bool) -> void:
	if _done:
		return
	_done = true
	print("NET_RESULT %s (%s): %s" % [role, stage, "ALL PASS" if ok and failures == 0 else "FAIL"])
	Net.leave_and_quit(0 if ok and failures == 0 else 1)
