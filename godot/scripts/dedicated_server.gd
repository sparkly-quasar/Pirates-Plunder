extends Node

## Runs Pirates Plunder as an always-on DEDICATED SERVER: a host with no crew
## of its own. It runs the same rules as a player's hosted game (GameServer, in
## the real Main scene, drawing nothing), and every crew, the NAVS included,
## is a player online or the computer. Anyone who can reach the address plays,
## no Tailscale needed.
##
## Start it with --server after the "--" (see SERVER.md):
##   godot --headless --path . -- --server --crews=4 --seats=4
## Every setting below can also come from an environment variable, PP_ and the
## name in capitals with underscores (PP_CREWS=4), which suits Docker.
##
## One match at a time, started one of two ways (`lobby`):
##  - players (the default): the server sits FREE until someone picks it under
##    Play on a Server and starts a game, choosing the crews (up to
##    `most-crews`), how many are for players, the island and the crew size.
##    They LEAD it: once everyone in the lobby has chosen a crew, they may set
##    sail with the computer in the seats nobody took (it also sails by itself
##    once every seat is taken). If they leave before then, the next player
##    leads; if everyone leaves, the server is free again.
##  - always: a lobby with the settings below is always open, as in 0.7.0. It
##    sets sail once every seat has a player who has chosen a crew, or
##    `start-after` seconds after `min-players` have, with the computer in the
##    empty seats.
## Either way the lobby fills seats in turn order (NAVS, Pirates, ...), and a
## match runs game after game (coaching between, as in any online match)
## until every player has left. Players can't join a match already under way.
##
## Players' server lists find it by asking on the STATUS port (the game's
## port + 1): a small UDP question, answered with what it's doing (see
## ServerFinder).
##
## Looked after here, so one stalled player can't hold everyone up: lobby,
## loading, between-games and (optionally) per-turn time limits, and a cap on
## pauses. Net rate-limits messages and checks every one.
##
## Not a class_name on purpose: a server started straight from a fresh
## checkout works before Godot has rebuilt its class cache.

signal logged(line: String)

const IDLE_SCENE := "res://scenes/ServerIdle.tscn"
const RECENT := 40

## name -> [default, what it does]. The default's type is the setting's type.
const OPTIONS := {
	"port": [24680, "UDP port to listen on."],
	"bind": ["", "Listen on this address only (an IP or a host name). Empty: every address."],
	"name": ["", "The server's name in players' server lists. Empty: they see the machine's Tailscale name, or the address they typed."],
	"web-port": [0, "TCP port where copies of the game in a web browser connect (over WebSockets). 0: the same number as port (24680). -1: no browsers."],
	"page-port": [0, "TCP port that hands out the game for web browsers (open http://<this server>:<port>/ on a phone). 0: the game's port + 2 (24682). -1: don't."],
	"web-files": ["", "Folder holding the web version of the game (index.html and the rest). Empty: the 'web' folder beside the server, which tools/package.sh fills."],
	"status-port": [0, "UDP port that answers players' server lists. 0: the game's port + 1 (24681). -1: don't answer (the server can still be joined by its address)."],
	"lobby": ["players", "players: whoever picks this server under Play on a Server starts a game and chooses its settings; the rest join it. always: a lobby with the settings below is always open (how 0.7.0 worked)."],
	"most-crews": [4, "lobby=players: the most crews a game here may have, 2 to 4."],
	"crews": [2, "Crews on the island, 2 to 4. With lobby=players, what a new game starts from."],
	"partner": [0, "With 4 crews, 2v2: the crew that teams up with the NAVS (1 Pirates, 2 Corsairs, 3 Buccaneers); the other two are the other side. 0: free-for-all. With lobby=players, what a new game starts from."],
	"seats": [0, "lobby=always: how many of those crews players can take, in turn order from the NAVS; the rest are the computer's. 0: all of them."],
	"min-players": [2, "lobby=always: players who must have chosen a crew before the start-after countdown begins."],
	"start-after": [60.0, "lobby=always: seconds after min-players are ready to wait for more, then sail with the computer in the empty seats. 0: wait for every seat."],
	"length": ["medium", "short, medium or long: the island's size and how many chests it holds. With lobby=players, what a new game starts from."],
	"crew-size": [10, "People per crew, 1 to 16. Players pick exactly this many. With lobby=players, what a new game starts from."],
	"difficulty": ["normal", "easy, normal or hard, for the computer's crews. With lobby=players, what a new game starts from."],
	"turn-seconds": [180.0, "Longest a player's turn may last before it passes on, in a new game (players starting a game choose: none, 1, 2, 3 or 5 minutes). 0: no limit."],
	"pause": [true, "Whether players may pause the game."],
	"pause-seconds": [120.0, "Longest a pause lasts before the game carries on. 0: no limit."],
	"choose-seconds": [300.0, "Time a player has to choose their crew in the lobby."],
	"join-seconds": [120.0, "Time a copy may stay connected without a seat (a different version, say) unless it's downloading an update."],
	"load-seconds": [90.0, "Time everyone has to load the island; anyone slower is replaced by the computer."],
	"rejoin-seconds": [120.0, "When a player loses their connection mid-game, how long the game waits, paused, for them to come back before asking the others whether to give their crew to the computer, keep waiting, or save the game for later. 0: the computer takes over at once."],
	"ready-seconds": [300.0, "Time between games before the next island starts without waiting for everyone to finish coaching. 0: wait for everyone."],
	"downloads": ["", "Folder of release downloads to update older copies from: <folder>/<version>/PiratesPlunder-mac.zip and PiratesPlunder-windows.exe. Empty: the 'downloads' folder beside the server, which tools/package.sh fills."],
	"saves": ["user://server-saves", "Folder for saved games. A match is saved at every turn and after every game, and when its players have all gone; each player's server list offers their own saved games to continue. -: keep none."],
	"save-days": [30.0, "Saved games older than this many days are deleted. 0: kept until each player has three newer ones."],
	"tick": [30, "Frames per second the server runs at. Turn-based, so 30 is plenty, and it spares the CPU."],
	"once": [false, "Quit after the first match ends instead of opening a new lobby (for tests)."],
}

var port := 24680
var bind := ""
var server_name := ""
var status_port := 24681
var web_port := 24680
var page_port := 24682
var web_files := ""
var lobby_mode := "players"
var most_crews := 4
var crews := 2
var partner := GameConfig.FREE_FOR_ALL
var seats := 2
var min_players := 2
var start_after := 60.0
var length := TerrainGrid.Length.MEDIUM
var crew_size := 5
var difficulty := GameConfig.Difficulty.NORMAL
var turn_seconds := 0.0
var allow_pause := true
var pause_seconds := 120.0
var choose_seconds := 300.0
var join_seconds := 120.0
var load_seconds := 90.0
var ready_seconds := 300.0
var rejoin_seconds := 120.0
var downloads := ""
var saves := ""
var save_days := 30.0
var tick := 30
var once := false

## The last few log lines, for the window when the server has one.
var recent: Array[String] = []

var _countdown := -1.0  # seconds until sailing with the computer in empty seats; < 0 when not counting
var _waiting_logged := false
var _connected_at := {} # peer -> when it connected
var _seated_at := {}    # peer -> when it got a seat
var _chose := {}        # seated peers whose choice of crew has been logged
var _downloaded := {}   # peers that finished downloading an update from us
var _active_at := {}    # peer -> when it last downloaded an update from us
var _kicked := {}       # peers already being sent away
var _game_id := 0       # the GameServer we're watching
var _game_since := 0.0
var _load_checked := false
var _over_since := -1.0
var _forced := false
var _saved_at := []     # the [turn, crew] last saved to the campaign
var _paused_for := 0.0
var _match_games := 0
var _filling := false   # the countdown ran out and the computer is taking the empty seats
var _sailing := false   # the leader set sail and the computer is taking the empty seats
var _game_open := false # a lobby or a match (lobby=players: false while free)
var _games: RefCounted = preload("res://scripts/server_saves.gd").new() # saved games (scripts/server_saves.gd)
var _board: RefCounted = preload("res://scripts/server_board.gd").new() # the Hall of Fame (scripts/server_board.gd)
var _save_id := ""      # the saved game this match is kept as
var _names := {}        # crew -> its player's name, for the saved game's line
var _saved_for_later := false # its players chose to save it and stop
var _leader := 0        # lobby=players: the peer who started the game, or took it over
var _status: PacketPeerUDP = null
var _web_status: Node = null # answers browsers' server lists (scripts/web_status.gd)
var _server_id := ""
var _asked := {}        # address -> server-list questions this second
var _asked_second := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_read_options()
	Engine.max_fps = tick
	AudioManager.enabled = false
	var address := bind
	if address != "" and not address.is_valid_ip_address():
		address = IP.resolve_hostname(bind, IP.TYPE_IPV4)
		if address == "":
			_log("Couldn't find the address '%s' to listen on." % bind)
			get_tree().quit(1)
			return
	# Room for every seat, plus copies still comparing versions or downloading.
	var err := Net.host_game(port, mini(maxi(crews, most_crews) + 12, 32), address, web_port)
	if err != OK:
		_log("Couldn't listen on UDP port %d%s (error %d). Is something else using it?" % [
			port, (" and TCP port %d" % web_port) if web_port >= 0 else "", err])
		get_tree().quit(1)
		return
	Net.dedicated = true
	Net.updater.serve_dir = downloads
	Net.gatekeeper = _gate
	Net.guest_waiting.connect(func(team: int) -> void:
		_log("The %s' player lost their connection; the game waits %ds for them to come back." % [GameConfig.team_name(team), int(rejoin_seconds)]))
	Net.decision_asked.connect(func(_names: String, _can_save: bool) -> void:
		_log("Nobody came back in time; asking the other players what to do."))
	Net.decision_made.connect(func(text: String) -> void: _log(text))
	if not allow_pause:
		Net.blocked_intents["pause"] = true
	_server_id = Crypto.new().generate_random_bytes(8).hex_encode()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Net.seats_changed.connect(_on_seats_changed)
	Net.guest_left.connect(_on_guest_left)
	Net.sail_requested.connect(_on_sail_requested)
	Net.guest_rejoining.connect(func(team: int) -> void:
		_log("%s is back, coming into the %s again." % [_who(Net.peer_for(team)), GameConfig.team_name(team)]))
	Net.guest_returned.connect(_on_guest_returned)
	Net.peer_refused.connect(func(id: int, why: String) -> void: _log("Sent player %d away: %s" % [id, why]))
	Net.updater.versions_differ.connect(_on_versions_differ)
	Net.updater.serving_progress.connect(func(id: int, done: int, total: int) -> void:
		if not _active_at.has(id):
			_log("Player %d is downloading version %s from us (%d MB)." % [id, GameConfig.version(), int(total / 1e6)])
		_active_at[id] = _now()
		if done >= total and not _downloaded.has(id):
			_downloaded[id] = true
			_log("Player %d finished downloading." % id))
	_log("Pirates Plunder %s dedicated server, listening on UDP port %d%s%s." % [
		GameConfig.version(), port, (" and for browsers on TCP port %d" % web_port) if web_port >= 0 else "",
		(" at " + address) if address != "" else ""])
	if status_port > 0:
		_status = PacketPeerUDP.new()
		var status_err := _status.bind(status_port, address if address != "" else "*")
		if status_err == OK:
			_log("Answers players' server lists on UDP port %d%s." % [status_port, (" as \"%s\"" % server_name) if server_name != "" else ""])
		else:
			_status = null
			_log("Couldn't open UDP port %d for players' server lists (error %d), so it won't show up in them. It can still be joined by its address." % [status_port, status_err])
		if web_port >= 0:
			_web_status = load("res://scripts/web_status.gd").new()
			_web_status.info = _status_info
			_web_status.board = func(key: String) -> Dictionary: return _board.board_info(key)
			if _web_status.listen(status_port, address) == OK:
				add_child(_web_status)
				_log("Answers browsers' server lists on TCP port %d." % status_port)
			else:
				_web_status.free()
				_web_status = null
				_log("Couldn't open TCP port %d for browsers' server lists, so browsers won't see what it's doing." % status_port)
	if lobby_mode == "players":
		_log("Players start games here: whoever picks this server under Play on a Server chooses the crews (up to %d), how many are for players, the island and the crew size; the rest join their game." % most_crews)
		_log("New games start from %d crews of %d on a %s island, with %s computer crews." % [
			mini(crews, most_crews), crew_size, TerrainGrid.LENGTH_NAMES[length].to_lower(), GameConfig.DIFFICULTY_NAMES[difficulty].to_lower()])
	else:
		_log("%d crews, %s; players take the first %d (%s), the computer the rest. Crews of %d, %s island." % [
			crews, "every seat open to players" if seats == crews else "%d for players" % seats, seats,
			", ".join(range(seats).map(func(t: int) -> String: return GameConfig.team_name(t))),
			crew_size, TerrainGrid.LENGTH_NAMES[length].to_lower()])
		if start_after > 0.0 and seats > 1:
			_log("Sails %ds after %d player%s %s ready, or as soon as every seat is taken." % [
				int(start_after), min_players, "" if min_players == 1 else "s", "is" if min_players == 1 else "are"])
	if downloads != "":
		var dir := downloads.path_join(GameConfig.version())
		var found := []
		for f in [Updater.MAC_ZIP, Updater.WIN_EXE]:
			if FileAccess.file_exists(dir.path_join(f)):
				found.append(f)
		_log(("Updates older copies from %s (%s)." % [dir, ", ".join(found)]) if not found.is_empty()
			else "No downloads found in %s, so older copies can't update from here." % dir)
	if web_port >= 0 and page_port > 0:
		var page: Node = load("res://scripts/web_page_server.gd").new()
		if not page.has_game(web_files):
			page.free()
			_log("No web version of the game found%s, so browsers can't load it from here (they can still join if the page comes from elsewhere)." % ((" in " + web_files) if web_files != "" else ""))
		else:
			page.folder = web_files
			page.game_port = web_port
			page.tag = GameConfig.version()
			if page.listen(page_port, address) == OK:
				add_child(page)
				_log("Hands out the game for web browsers on TCP port %d: http://localhost:%d/ on this machine. Phones and other computers need https in front of it (tailscale serve: see HTTPS with Tailscale in SERVER.md)." % [page_port, page_port])
			else:
				page.free()
				_log("Couldn't open TCP port %d to hand out the game for web browsers." % page_port)
	if saves != "":
		if _games.open(saves, save_days) == OK:
			_log("Keeps saved games in %s (%d there now)." % [ProjectSettings.globalize_path(saves), _games.count()])
		else:
			_log("Couldn't write to %s for saved games, so none are kept. Check that the server's user can write there (with Docker, see Saved games in SERVER.md)." % ProjectSettings.globalize_path(saves))
			saves = ""
	_board.open(saves)
	_log("Keeps a Hall of Fame in %s (%d player%s so far)." % [ProjectSettings.globalize_path(_board.path), _board.players.size(), "" if _board.players.size() == 1 else "s"])
	Net.wait_seconds = rejoin_seconds
	Net.save_for_later = _save_for_later if saves != "" else Callable()
	if lobby_mode == "players":
		_go_free()
	else:
		_open_lobby()

# --- settings ------------------------------------------------------------------

func _read_options() -> void:
	port = clampi(_opt("port"), 1, 65534)
	bind = _opt("bind")
	server_name = GameConfig.clean_name(_opt("name"))
	var sp: int = _opt("status-port")
	status_port = port + ServerFinder.STATUS_OFFSET if sp == 0 else (-1 if sp < 0 else clampi(sp, 1, 65535))
	var wp: int = _opt("web-port")
	web_port = port if wp == 0 else (-1 if wp < 0 else clampi(wp, 1, 65535))
	var pp: int = _opt("page-port")
	page_port = port + 2 if pp == 0 else (-1 if pp < 0 else clampi(pp, 1, 65535))
	web_files = _opt("web-files")
	if web_files == "":
		web_files = _beside("web")
	lobby_mode = "always" if str(_opt("lobby")).to_lower() == "always" else "players"
	if str(_opt("lobby")).to_lower() not in ["always", "players"]:
		_log("Ignored lobby=%s: choose players or always." % _opt("lobby"))
	most_crews = clampi(_opt("most-crews"), GameConfig.MIN_TEAMS, GameConfig.MAX_TEAMS)
	crews = clampi(_opt("crews"), GameConfig.MIN_TEAMS, GameConfig.MAX_TEAMS)
	var p: int = _opt("partner")
	partner = p if p >= 1 and p < GameConfig.MAX_TEAMS else GameConfig.FREE_FOR_ALL
	var s: int = _opt("seats")
	seats = crews if s <= 0 else clampi(s, 1, crews)
	min_players = clampi(_opt("min-players"), 1, seats)
	start_after = maxf(_opt("start-after"), 0.0)
	length = _pick("length", TerrainGrid.LENGTH_NAMES, TerrainGrid.Length.MEDIUM) as TerrainGrid.Length
	crew_size = clampi(_opt("crew-size"), 1, GameConfig.MAX_TEAM_SIZE)
	difficulty = _pick("difficulty", GameConfig.DIFFICULTY_NAMES, GameConfig.Difficulty.NORMAL) as GameConfig.Difficulty
	turn_seconds = maxf(_opt("turn-seconds"), 0.0)
	allow_pause = _opt("pause")
	pause_seconds = maxf(_opt("pause-seconds"), 0.0)
	choose_seconds = maxf(_opt("choose-seconds"), 10.0)
	join_seconds = maxf(_opt("join-seconds"), 10.0)
	load_seconds = maxf(_opt("load-seconds"), 10.0)
	ready_seconds = maxf(_opt("ready-seconds"), 0.0)
	rejoin_seconds = maxf(_opt("rejoin-seconds"), 0.0)
	downloads = _opt("downloads")
	if downloads == "":
		downloads = _bundled_downloads()
	saves = _opt("saves")
	if saves == "-":
		saves = ""
	save_days = maxf(_opt("save-days"), 0.0)
	tick = clampi(_opt("tick"), 5, 120)
	once = _opt("once")

## The downloads folder tools/package.sh puts beside the server build (or, run
## from source, in godot/build/server/), if there is one.
func _bundled_downloads() -> String:
	return _beside("downloads")

## A folder tools/package.sh puts beside the server build (run from source:
## in godot/build/server/), or "" if it isn't there.
func _beside(folder: String) -> String:
	var p := OS.get_executable_path().get_base_dir().path_join(folder) if OS.has_feature("template") \
		else ProjectSettings.globalize_path("res://build/server/" + folder)
	return p if DirAccess.dir_exists_absolute(p) else ""

## A setting from the command line (--name=value), else the environment
## (PP_NAME), else its default; read as the default's type.
func _opt(key: String) -> Variant:
	var fallback: Variant = OPTIONS[key][0]
	var raw := ""
	var found := false
	var env := "PP_" + key.to_upper().replace("-", "_")
	if OS.has_environment(env):
		raw = OS.get_environment(env)
		found = true
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for a in args:
		if a == "--" + key and typeof(fallback) == TYPE_BOOL:
			raw = "true"
			found = true
		elif a.begins_with("--%s=" % key):
			raw = a.substr(key.length() + 3)
			found = true
	if not found:
		return fallback
	raw = raw.strip_edges()
	match typeof(fallback):
		TYPE_INT:
			if raw.is_valid_int():
				return raw.to_int()
		TYPE_FLOAT:
			if raw.is_valid_float():
				return raw.to_float()
		TYPE_BOOL:
			if raw.to_lower() in ["1", "true", "yes", "on"]:
				return true
			if raw.to_lower() in ["0", "false", "no", "off"]:
				return false
		_:
			return raw
	_log("Ignored %s=%s: not a valid value. Using %s." % [key, raw, str(fallback)])
	return fallback

## A setting that names one of `names` (case doesn't matter); its index.
func _pick(key: String, names: Array, fallback: int) -> int:
	var wanted := str(_opt(key)).to_lower()
	for i in names.size():
		if str(names[i]).to_lower() == wanted:
			return i
	_log("Ignored %s=%s: choose one of %s." % [key, wanted, ", ".join(names.map(func(n: String) -> String: return n.to_lower()))])
	return fallback

# --- the lobby -------------------------------------------------------------------

## A fresh lobby on a new island, for the next match: with `game`'s settings
## (a player's, already checked by _clean_request()) or else the server's own;
## or saved game `save_id` instead. With `only`, just those players' crews
## wait for them (a game saved when its players lost their connection, opened
## again for whoever is back first); the computer sails the rest.
func _open_lobby(game := {}, save_id := "", only := []) -> void:
	var n := int(game.get("crews", crews))
	var players := int(game.get("seats", seats))
	var size := int(game.get("size", crew_size))
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.SERVER
	GameConfig.team_count = n
	GameConfig.length = int(game.get("length", length)) as TerrainGrid.Length
	GameConfig.difficulty = int(game.get("difficulty", difficulty)) as GameConfig.Difficulty
	GameConfig.team_target = size
	GameConfig.partner = int(game.get("partner", partner)) if n == GameConfig.MAX_TEAMS else GameConfig.FREE_FOR_ALL
	GameConfig.set_battle_royale(bool(game.get("royale", false)), int(game.get("rounds", 3)), bool(game.get("vega", false)))
	GameConfig.turn_seconds = int(game.get("turn", turn_seconds))
	for t in GameConfig.MAX_TEAMS:
		GameConfig.controllers[t] = GameConfig.Ctrl.HUMAN if t < players else GameConfig.Ctrl.COMPUTER
		GameConfig.team_counts[t] = GameConfig.balanced_counts(size)
	GameConfig.new_match() # sized for this many crews
	var campaign: bool = save_id != "" and _games.has(save_id) and GameConfig.load_game(_games.path_of(save_id))
	if campaign and not only.is_empty():
		for t in GameConfig.seat_owners.keys():
			if not only.has(str(GameConfig.seat_owners[t])):
				GameConfig.controllers[t] = GameConfig.Ctrl.COMPUTER
	_save_id = save_id if campaign else _games.new_id()
	_saved_for_later = false
	_names = _games.names_of(save_id) if campaign else {}
	GameConfig.mode = GameConfig.Mode.SERVER
	Net.reopen()
	Net.resuming = campaign
	Net.game_server = null # the last game's scene goes with the change below
	_reset_lobby()
	_game_open = true
	get_tree().change_scene_to_file(IDLE_SCENE)
	if campaign:
		_match_games = GameConfig.match_games
		_log("Lobby open, continuing saved game %s (%s%s). Returning players get their own crews back." % [
			_save_id, GameConfig.save_summary(_games.path_of(_save_id)), "" if GameConfig.resume.is_empty() else ", partway through a game"])
	else:
		_log("Lobby open on island #%d%s. Waiting for players." % [GameConfig.island_seed,
			(", 2 v 2: %s" % GameConfig.sides_text()) if GameConfig.two_v_two()
				else (", Battle Royale, %d rounds%s" % [GameConfig.br_rounds, ", Vega every round" if GameConfig.br_vega else ""]) if GameConfig.battle_royale else ""])

## lobby=players: no game here. The next player to pick this server starts one.
func _go_free() -> void:
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.SERVER
	Net.reopen()
	Net.game_server = null
	_reset_lobby()
	_game_open = false
	get_tree().change_scene_to_file(IDLE_SCENE)
	_save_id = ""
	_log("Free: waiting for someone to start a game here, or continue a saved one.")

func _reset_lobby() -> void:
	_countdown = -1.0
	_waiting_logged = false
	_seated_at.clear()
	_chose.clear()
	_game_id = 0
	_match_games = 0
	_leader = 0

## Net asks this before seating someone (Net.gatekeeper). With lobby=players a
## free server lets in only someone starting a game, who leads it; once a game
## is open anyone may join it, and Net seats them if there's room.
func _gate(id: int) -> String:
	if Net.match_started:
		return "" # Net seats them if their crew is waiting for them, or tells them the game is under way
	var ask: Variant = Net.updater.request_of(id)
	var me := Net.updater.player_of(id)
	# Continuing a saved game: one they chose from their list, or (a copy that
	# lost its connection and is reconnecting by itself) the one that was
	# saved when everyone had gone.
	var sid := ""
	var auto: bool = ask is String and ask == "rejoin"
	if auto:
		sid = _games.dropped_by(me, REJOIN_WINDOW) if saves != "" else ""
		if sid == "":
			if not _game_open:
				return "Your game isn't on this server any more."
			ask = null # a new lobby since: just join it
	elif ask is Dictionary and ask.has("continue"):
		sid = str(ask["continue"])
		if not _games.owns(sid, me):
			return "That saved game isn't on this server any more."
	elif ask is String and ask == "continue": # copies before 0.10
		sid = _games.newest_of(me) if saves != "" else ""
		if sid == "":
			return "There's no saved game of yours on this server."
	if sid != "":
		if _game_open and (lobby_mode == "players" or not Net.guests.is_empty()):
			return "Someone has started a game on this server meanwhile. Continue yours from the server list once it's free."
		_open_lobby({}, sid, _games.dropped_in(sid) if auto else [])
		_leader = id
		_log("%s %s saved game %s." % [_who(id), "is back, reopening" if auto else "continues", sid])
		return ""
	if lobby_mode == "always":
		return "" # Net seats them, or tells them the lobby is full
	if _game_open:
		if ask != null:
			return "Someone else has just started a game on this server. Join theirs from the server list, or start one when the server is free again."
		return ""
	if ask is Dictionary:
		var game := _clean_request(ask)
		_open_lobby(game)
		_leader = id
		_log("%s starts a game: %d crews, %s, crews of %d, a %s island%s." % [_who(id), int(game.crews),
			"all for players" if int(game.seats) == int(game.crews) else "%d for players" % int(game.seats),
			int(game.size), TerrainGrid.LENGTH_NAMES[int(game.length)].to_lower(),
			"" if int(game.seats) == int(game.crews) else ", %s computer crews" % GameConfig.DIFFICULTY_NAMES[int(game.difficulty)].to_lower()])
		return ""
	return "Nobody has started a game on this server yet. Choose it under Play on a Server to start one."

## A player's settings for a new game, kept within what this server allows.
func _clean_request(ask: Dictionary) -> Dictionary:
	var n := clampi(_int(ask.get("crews"), mini(crews, most_crews)), GameConfig.MIN_TEAMS, most_crews)
	var with_navs := _int(ask.get("partner"), GameConfig.FREE_FOR_ALL)
	return {
		"crews": n,
		"partner": with_navs if n == GameConfig.MAX_TEAMS and with_navs >= 1 and with_navs < GameConfig.MAX_TEAMS else GameConfig.FREE_FOR_ALL,
		"seats": clampi(_int(ask.get("seats"), n), 1, n),
		"length": clampi(_int(ask.get("length"), length), 0, TerrainGrid.LENGTH_NAMES.size() - 1),
		"difficulty": clampi(_int(ask.get("difficulty"), difficulty), 0, GameConfig.DIFFICULTY_NAMES.size() - 1),
		"size": clampi(_int(ask.get("size"), crew_size), 1, GameConfig.MAX_TEAM_SIZE),
		"turn": _int(ask.get("turn"), int(turn_seconds)) if GameConfig.TURN_CHOICES.has(_int(ask.get("turn"), -1)) else int(turn_seconds),
		"royale": ask.get("royale") is bool and ask.royale,
		"rounds": _int(ask.get("rounds"), 3) if GameConfig.BR_ROUNDS.has(_int(ask.get("rounds"), 3)) else 3,
		"vega": ask.get("vega") is bool and ask.vega,
	}

static func _int(v: Variant, fallback: int) -> int:
	return int(v) if v is int or v is float else fallback

## lobby=players: the leader asked to set sail now. Once everyone in the lobby
## has chosen a crew, the computer takes the seats nobody has.
func _on_sail_requested(id: int) -> void:
	if lobby_mode != "players" or id != _leader or Net.match_started or _anyone_choosing():
		return
	_sailing = true
	Net.fill_open_seats() # its seats_changed starts the match
	_sailing = false

## The player who leads after the leader left: whoever sails the earliest crew.
func _next_leader() -> int:
	var best := 0
	for id in Net.guests:
		if best == 0 or int(Net.guests[id]) < int(Net.guests[best]):
			best = int(id)
	return best

## Tells everyone in the lobby who's in which seat, and who leads.
func _send_lobby() -> void:
	if Net.match_started:
		return
	var out := []
	for t in GameConfig.team_count:
		var id := Net.peer_for(t)
		out.append({"team": t, "who": "computer" if GameConfig.is_computer(t) else ("player" if id != 0 else "open"),
			"name": Net.updater.name_of(id) if id != 0 else "", "ready": Net.has_chosen(t),
			"captain": id != 0 and Net.updater.is_captain(id)})
	Net.send_lobby({"leader": int(Net.guests.get(_leader, -1)), "seats": out, "auto": lobby_mode == "always"})

## "Ana (player 3)", or "Player 3" for a copy that didn't say its name.
func _who(id: int) -> String:
	var n := Net.updater.name_of(id)
	return ("%s (player %d)" % [n, id]) if n != "" else "Player %d" % id

func _on_peer_connected(id: int) -> void:
	_connected_at[id] = _now()
	var peer := multiplayer.multiplayer_peer
	var from := ""
	if peer is ENetMultiplayerPeer and (peer as ENetMultiplayerPeer).get_peer(id):
		from = " from %s" % (peer as ENetMultiplayerPeer).get_peer(id).get_remote_address()
	elif peer != null and peer.has_method("describe"):
		from = " from %s" % peer.describe(id)
	_log("Player %d connected%s." % [id, from])

func _on_peer_disconnected(id: int) -> void:
	_log("Player %d disconnected." % id)
	_connected_at.erase(id)
	_seated_at.erase(id)
	_chose.erase(id)
	_active_at.erase(id)
	_downloaded.erase(id)
	_kicked.erase(id)

## A copy with another version said hello. If it's older and we hold the
## download for its computer, it can update from us; otherwise there's no
## point in it waiting, so it's told why and sent away.
func _on_versions_differ(id: int, version: String, newer: bool, _can_get: bool) -> void:
	var mine := GameConfig.version()
	if not newer and Net.updater.can_serve_to(id):
		_log("Player %d has version %s; offering them %s." % [id, version, mine])
		return
	var why: String
	if newer:
		why = "This server runs version %s, older than yours (%s). It needs updating before you can play here." % [mine, version]
	else:
		why = "This server runs version %s and you have %s. Download version %s to play here." % [mine, version, mine]
	_kick(id, why)

func _on_seats_changed() -> void:
	if Net.match_started:
		_note_names()
		if Net.guests.is_empty():
			# Everyone has gone. The game is saved for them (unless they chose to
			# save it for later just now, which did), and the server is free.
			# Those who lost their connection go straight back into it if
			# their game reconnects; anyone can continue it from their list.
			var dropped: Array = Net.away.values().map(func(p: Variant) -> String: return str(p))
			if not _saved_for_later:
				_save_match(dropped)
			if _games.has(_save_id):
				_log("The game is saved as %s (%s)%s." % [_save_id, GameConfig.save_summary(_games.path_of(_save_id)),
					(", for players who lost their connection to come back to") if not dropped.is_empty() else ""])
			_end_match("every player has gone" if not dropped.is_empty() else "every player has left")
		return
	if lobby_mode == "players" and _game_open:
		if Net.guests.is_empty():
			_log("Everyone left the lobby before setting sail.")
			_go_free()
			return
		if not Net.guests.has(_leader):
			_leader = _next_leader()
			_log("%s leads the game now." % _who(_leader))
	for id in Net.guests:
		var team := int(Net.guests[id])
		if not _seated_at.has(id):
			_seated_at[id] = _now()
			_log("%s takes the %s." % [_who(id), GameConfig.team_name(team)])
		if Net.has_chosen(team) and not _chose.has(id):
			_chose[id] = true
			_log("%s has chosen the %s' crew." % [_who(id), GameConfig.team_name(team)])
	_send_lobby()
	_consider_start()

func _chosen_count() -> int:
	var n := 0
	for id in Net.guests:
		if Net.has_chosen(int(Net.guests[id])):
			n += 1
	return n

func _anyone_choosing() -> bool:
	return _chosen_count() < Net.guests.size()

func _consider_start() -> void:
	if Net.match_started:
		return
	if Net.guests.is_empty():
		_countdown = -1.0
		return
	if Net.all_seats_ready():
		var why := "every seat is taken"
		if _filling:
			why = "waited %ds for more players" % int(start_after)
		elif _sailing:
			why = "%s set sail" % _who(_leader)
		_start(why)
		return
	if lobby_mode == "always" and start_after > 0.0 and _chosen_count() >= min_players:
		if _countdown < 0.0:
			_countdown = start_after
			_waiting_logged = false
			_log("%d player%s ready: sailing in %ds unless every seat fills first." % [
				_chosen_count(), "" if _chosen_count() == 1 else "s", int(start_after)])
	elif _countdown >= 0.0:
		_countdown = -1.0
		_log("Not enough players ready any more; the countdown stops.")

func _start(why: String) -> void:
	if Net.match_started or Net.guests.is_empty():
		return
	_countdown = -1.0
	var who: Array[String] = []
	for t in GameConfig.team_count:
		var id := Net.peer_for(t)
		who.append("%s: %s" % [GameConfig.team_name(t), _who(id) if id != 0 else "the computer"])
	_log("Setting sail (%s). %s." % [why, ", ".join(who)])
	Net.start_match()

## The match is over, so a new lobby opens (or, with --once, the server stops).
func _end_match(why: String) -> void:
	_log("Match over: %s, after %d game%s." % [why, _match_games, "" if _match_games == 1 else "s"])
	if once:
		_log("Shutting down (--once).")
		Net.leave()
		get_tree().quit(0)
		return
	if lobby_mode == "players":
		_go_free()
	else:
		_open_lobby()

func _on_guest_left(team: int) -> void:
	if Net.away.has(team):
		_log("The %s' player lost their connection; the computer sails their crew until they're back." % GameConfig.team_name(team))
	else:
		_log("The %s' player left; the computer sails their crew." % GameConfig.team_name(team))

## A player who'd dropped is sailing their crew again.
func _on_guest_returned(team: int) -> void:
	_log("The %s' player is back at the helm." % GameConfig.team_name(team))

# --- the clocks ------------------------------------------------------------------

func _process(delta: float) -> void:
	var now := _now()
	_answer_lists()
	if not Net.match_started:
		_lobby_clocks(now, delta)
	_stragglers(now)
	var gs: GameServer = Net.game_server
	if gs != null and is_instance_valid(gs):
		_game_clocks(gs, now, delta)

func _lobby_clocks(now: float, delta: float) -> void:
	for id in Net.guests.keys():
		var chosen := Net.has_chosen(int(Net.guests[id]))
		if not chosen and now - float(_seated_at.get(id, now)) > choose_seconds:
			_kick(int(id), "Disconnected: you took too long to choose a crew.")
	if _countdown >= 0.0:
		_countdown -= delta
		if _countdown <= 0.0:
			_countdown = 0.0
			if _anyone_choosing():
				if not _waiting_logged:
					_waiting_logged = true
					_log("Time's up, but someone is still choosing their crew; waiting for them.")
				return
			_filling = true
			Net.fill_open_seats() # its seats_changed starts the match
			_filling = false

## Connected without a seat (a different version, or still saying hello) for
## too long, and not downloading an update from us: sent away.
func _stragglers(now: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		return # shutting down (--once): the last frame runs after Net.leave()
	for id in multiplayer.get_peers():
		if Net.guests.has(id) or _kicked.has(id):
			continue
		var since := maxf(float(_connected_at.get(id, now)), float(_active_at.get(id, 0.0)))
		if now - since > join_seconds:
			_kick(id, "Disconnected: no seat for you on this server right now.")

func _game_clocks(gs: GameServer, now: float, delta: float) -> void:
	if gs.get_instance_id() != _game_id:
		_game_id = gs.get_instance_id()
		_game_since = now
		_load_checked = false
		_over_since = -1.0
		_forced = false
		_saved_at = []
		_paused_for = 0.0
		_match_games += 1
		_log("Game %d of this match is loading (island #%d, %s)." % [_match_games, gs.grid.island_seed, GameConfig.turn_limit_text(GameConfig.turn_seconds)])
		gs.time_ran_out.connect(func(team: int) -> void:
			_log("The %s ran out of time on turn %d." % [GameServer.TEAM_NAMES[team], gs.turn]))
	# Loading: anyone who hasn't landed in time is replaced by the computer.
	if not gs.started and not gs.won and not _load_checked and now - _game_since > load_seconds:
		_load_checked = true
		for id in Net.guests.keys():
			if not Net.in_game(int(id)):
				_kick(int(id), "Disconnected: your game took too long to load the island.")
	if gs.won:
		if _over_since < 0.0:
			_over_since = now
			_save_match()
			_record_game(gs)
			var result := "nobody won"
			if gs.winner == GameServer.DRAW:
				result = "a draw"
			elif gs.winner >= 0:
				result = "the %s won" % GameServer.TEAM_NAMES[gs.winner]
			_log("Game %d over on turn %d: %s (%s). Chests aboard: %s." % [_match_games, gs.turn, result, gs.win_reason,
				", ".join(range(gs.team_count).map(func(t: int) -> String: return "%s %d" % [GameServer.TEAM_NAMES[t], int(gs.delivered[t])]))])
		elif GameConfig.br_over() and not _forced and now - _over_since > maxf(ready_seconds, 60.0):
			# Every round played: thank everyone and open up for the next game.
			_forced = true
			_log("Battle Royale over: %s (%s)." % [GameConfig.br_result(), GameConfig.br_standings()])
			for id in Net.guests.keys():
				_kick(int(id), "The Battle Royale is over. " + GameConfig.br_result())
		elif ready_seconds > 0.0 and not _forced and now - _over_since > ready_seconds and not Net.guests.is_empty():
			_forced = true
			_log("Waited %ds between games; starting the next island." % int(ready_seconds))
			Net.force_next()
		return
	if not gs.started:
		return
	# A pause doesn't last for ever.
	if gs.paused and pause_seconds > 0.0 and gs.paused_by != GameServer.HELD:
		_paused_for += delta
		if _paused_for >= pause_seconds:
			gs.request_pause(gs.paused_by, false)
			gs.announce(-1, "The pause ran out after %ds, so the game carries on." % int(pause_seconds))
	if not gs.paused:
		_paused_for = 0.0
	# A campaign is saved whenever the turn passes, so a restart loses little.
	var at := [gs.turn, gs.current_team]
	if at != _saved_at:
		_saved_at = at
		_save_match()

## Answers the questions players' server lists send to the status port (see
## ServerFinder): what's going on here. At most a few answers a second to any
## one address.
func _answer_lists() -> void:
	if _status == null:
		return
	var second := floori(_now())
	if second != _asked_second:
		_asked_second = second
		_asked.clear()
	while _status.get_available_packet_count() > 0:
		var packet := _status.get_packet()
		var ip := _status.get_packet_ip()
		var from := _status.get_packet_port()
		if not ServerFinder.is_query(packet):
			continue
		_asked[ip] = int(_asked.get(ip, 0)) + 1
		if int(_asked[ip]) > 5:
			continue
		_status.set_dest_address(ip, from)
		if ServerFinder.is_board_query(packet):
			_status.put_packet(ServerFinder.make_board_reply(_board.board_info(ServerFinder.query_key(packet))))
		else:
			_status.put_packet(ServerFinder.make_reply(_status_info(ServerFinder.query_key(packet))))

## A game's over: everyone still sailing their crew at the end gets it added
## to their Hall of Fame row, and after a Battle Royale's last round, the
## crews that took it a title. (The match has already been scored: Main does
## that as the game ends.)
func _record_game(gs: GameServer) -> void:
	var seats := {}
	for t in gs.team_count:
		var peer := Net.peer_for(t)
		if peer != 0 and Net.updater.player_of(peer) != "":
			seats[t] = [Net.updater.player_of(peer), Net.updater.name_of(peer)]
	var titles := GameConfig.br_leaders() if GameConfig.br_over() else []
	var results: Array = _board.results_of(gs, seats, titles)
	_board.record(results)
	for r in results:
		if bool(r.title):
			_log("%s takes the Battle Royale title." % str(r.name))

## What a server list is told (ServerFinder.parse_reply() lists the keys).
func _status_info(key := "") -> Dictionary:
	var state := "free"
	if Net.match_started:
		state = "playing"
	elif _game_open:
		state = "setup"
	var people := 0
	var players := []
	if _game_open:
		for t in GameConfig.team_count:
			if GameConfig.is_friend(t):
				people += 1
		for id in Net.guests:
			var n := Net.updater.name_of(int(id))
			players.append(n if n != "" else "Player %d" % int(id))
	return {
		"game": "pirates-plunder",
		"v": GameConfig.version(),
		"p": Net.PROTOCOL,
		"id": _server_id,
		"name": server_name,
		"port": port,
		"state": state,
		"lobby": lobby_mode,
		"leader": Net.updater.name_of(_leader) if _leader != 0 else "",
		"crews": GameConfig.team_count if _game_open else mini(crews, most_crews),
		"people": people,
		"taken": Net.guests.size(),
		"open": Net.open_seats().size() if state == "setup" else 0,
		"length": GameConfig.length if _game_open else length,
		"partner": GameConfig.partner if _game_open else GameConfig.FREE_FOR_ALL,
		"royale": GameConfig.royale_state() if _game_open else {},
		"turn": GameConfig.turn_seconds if _game_open else int(turn_seconds),
		"mine": _games.mine(key) if saves != "" else [],
		"players": players,
		# Who may come back into their crew (by a fingerprint of their player
		# id, so their list can offer them Rejoin without naming anyone).
		"back": Net.away.values().map(func(pid: Variant) -> String: return ServerFinder.back_key(str(pid))) if Net.match_started else [],
		"most": most_crews,
		"defaults": {"crews": mini(crews, most_crews), "size": crew_size, "length": length, "difficulty": difficulty,
			"partner": partner, "turn": int(turn_seconds)},
	}

# --- saved games ------------------------------------------------------------------

## A player who's back after losing their connection is put straight back
## into a game saved when everyone had gone, within this many seconds.
const REJOIN_WINDOW := 1800.0

## Keeps the match on disk as saved game _save_id: the game in progress if
## there is one, else the match between games. People walking or digging just
## stop where they are, and a fight not yet settled is called off, when it's
## picked up again. `dropped`: the players who lost their connection.
func _save_match(dropped: Array = []) -> void:
	if saves == "" or _save_id == "":
		return
	var gs: GameServer = Net.game_server
	var playing := gs != null and is_instance_valid(gs) and gs.started and not gs.won
	var summary: String
	if playing:
		summary = "Game %d, turn %d" % [GameConfig.match_games + 1, gs.turn]
	elif GameConfig.match_games > 0:
		summary = "After %d game%s" % [GameConfig.match_games, "" if GameConfig.match_games == 1 else "s"]
	else:
		return # nothing played yet
	_note_names()
	_games.save(_save_id, gs.save_state() if playing else {}, summary, _names, dropped)

## Players' names by crew, for the saved game's line in their lists.
func _note_names() -> void:
	for id in Net.guests:
		var n := Net.updater.name_of(int(id))
		if n != "":
			_names[int(Net.guests[id])] = n

## The players chose to save the game for later (Net asks, see Net.decide()):
## save it, and send everyone away saying how to pick it up again.
func _save_for_later(who: String) -> void:
	_save_match()
	_saved_for_later = true
	_log("%s saved the game for later, as %s." % [who, _save_id])
	for id in Net.guests.keys():
		_kick(int(id), "%s saved the game for later. Continue it from Play on a Server; everyone comes back into their own crew." % who)

# --- helpers ---------------------------------------------------------------------

func _kick(id: int, why: String) -> void:
	if _kicked.has(id):
		return
	_kicked[id] = true
	Net.kick(id, why)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _log(line: String) -> void:
	var stamped := "[%s] %s" % [Time.get_datetime_string_from_system(true, true), line]
	print(stamped)
	recent.append(stamped)
	if recent.size() > RECENT:
		recent.remove_at(0)
	logged.emit(stamped)
