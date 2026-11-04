extends Control

## Play on a Server: the servers this computer can reach, found through
## Tailscale (ServerFinder), plus any typed by hand. On a free server you can
## start a game, choosing its crews, how many are for players, the island and
## the crew size; you lead it, and others pick that server here and join. On a
## server with a saved match you can continue it instead. Check for Updates
## asks the servers found for a newer version and, if one has it, updates
## from it, before you start or join anything.

const DOWNLOAD_URL := "https://tailscale.com/download"
const SHARING_URL := "https://tailscale.com/kb/1084/sharing"

var finder: ServerFinder
var list_box: VBoxContainer
var scan_label: Label
var tailscale_row: Control
var address_edit: LineEdit
var status_label: Label
var start_panel: VBoxContainer
var board_panel: VBoxContainer   # a server's Hall of Fame, when asked for
var _board_for := {}             # the server it's for
var wait_box: ServerLobbyBox
var update_label: Label
var update_bar: ProgressBar
var _shown := ""          # what the list shows, so it's only rebuilt when that changes
var _note := ""           # what Tailscale said
var _scanned := false
var _busy := false        # connecting, or connected and waiting
var _picked := {}         # the server a new game is being set up for
var _ask := {}            # that game's settings
var _update_peer := 0
var _update_only := false  # connected only to fetch an update, not to play
## Look through Tailscale (and on this computer) for servers. The tests turn
## it off, and ask only the address they type.
var scan_tailnet := true
## Running in a web browser: only the page's own server, nothing to type in,
## and no updating (reloading the page does that).
var web := OS.has_feature("web")
var _waited := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.10, 0.14)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var centre := VBoxContainer.new()
	centre.set_anchors_preset(Control.PRESET_CENTER)
	centre.grow_horizontal = Control.GROW_DIRECTION_BOTH
	centre.grow_vertical = Control.GROW_DIRECTION_BOTH
	centre.custom_minimum_size = Vector2(720, 0)
	centre.add_theme_constant_override("separation", 10)
	add_child(centre)

	centre.add_child(_title("PLAY ON A SERVER", 30))
	if web:
		centre.add_child(_small("This is the server this page came from. Start a game on it if it's free, and your friends join it from here (on their computers or phones), or join the game someone has already started."))
	else:
		centre.add_child(_small("Servers on your Tailscale network show up here, along with any a friend has shared with you in Tailscale. Start a game on a free one and your friends join it from here, or join the game someone has already started."))

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_row.add_child(_label("Your name:", 16))
	var name_edit := LineEdit.new()
	name_edit.text = GameConfig.player_name()
	name_edit.max_length = 20
	name_edit.custom_minimum_size = Vector2(220, 34)
	name_edit.tooltip_text = "What other players see in the lobby and in their server lists."
	name_edit.text_changed.connect(func(t: String) -> void: GameConfig.set_player_name(t))
	name_row.add_child(name_edit)
	centre.add_child(name_row)

	centre.add_child(_gap(4))
	list_box = VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 8)
	centre.add_child(list_box)
	scan_label = _label(_looking(), 15)
	scan_label.modulate = Color(1, 1, 1, 0.75)
	scan_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scan_label.custom_minimum_size = Vector2(700, 0)
	centre.add_child(scan_label)
	tailscale_row = _link_row([["Download Tailscale", DOWNLOAD_URL], ["How Tailscale Sharing Works", SHARING_URL]])
	tailscale_row.visible = false
	centre.add_child(tailscale_row)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label("Or a server's address:", 15))
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "e.g. 100.101.102.103  or  play.example.com"
	address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address_edit.custom_minimum_size = Vector2(0, 34)
	address_edit.text_submitted.connect(func(_t: String) -> void: _look_up())
	row.add_child(address_edit)
	var look := Button.new()
	look.text = "Look Up"
	look.custom_minimum_size = Vector2(100, 34)
	look.pressed.connect(_look_up)
	row.add_child(look)
	row.visible = not web # a browser can only reach the server it came from
	centre.add_child(row)

	start_panel = VBoxContainer.new()
	start_panel.add_theme_constant_override("separation", 8)
	start_panel.visible = false
	centre.add_child(start_panel)

	board_panel = VBoxContainer.new()
	board_panel.name = "HallOfFame"
	board_panel.add_theme_constant_override("separation", 6)
	board_panel.visible = false
	centre.add_child(board_panel)

	status_label = _label("", 16)
	status_label.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(700, 0)
	centre.add_child(status_label)
	wait_box = ServerLobbyBox.new()
	wait_box.chosen = true # rejoining a saved match: our crew is already chosen
	centre.add_child(wait_box)
	update_label = _label("", 15)
	update_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	update_label.custom_minimum_size = Vector2(700, 0)
	update_label.visible = false
	centre.add_child(update_label)
	update_bar = ProgressBar.new()
	update_bar.custom_minimum_size = Vector2(0, 22)
	update_bar.visible = false
	centre.add_child(update_bar)

	centre.add_child(_gap(6))
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	var back := Button.new()
	back.text = "Back to Menu"
	back.custom_minimum_size = Vector2(160, 36)
	back.pressed.connect(func() -> void:
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/Menu.tscn"))
	bottom.add_child(back)
	var again := Button.new()
	again.text = "Look Again"
	again.custom_minimum_size = Vector2(140, 36)
	again.pressed.connect(func() -> void:
		scan_label.text = _looking()
		if scan_tailnet:
			finder.scan())
	bottom.add_child(again)
	if not web: # a browser always gets the server's version when the page loads
		var check := Button.new()
		check.name = "CheckForUpdates"
		check.text = "Check for Updates"
		check.tooltip_text = "Ask the servers whether there's a newer version of the game, and update to it before you play."
		check.custom_minimum_size = Vector2(180, 36)
		check.pressed.connect(_check_for_updates)
		bottom.add_child(check)
	centre.add_child(bottom)

	finder = ServerFinder.new()
	add_child(finder)
	finder.found.connect(_on_found)
	finder.board_found.connect(_on_board_found)
	finder.scanned.connect(_on_scanned)
	Net.joined.connect(_on_joined)
	Net.join_failed.connect(_on_join_failed)
	Net.opponent_left.connect(_on_server_left)
	Net.updater.versions_differ.connect(_on_versions_differ)
	Net.updater.download_progress.connect(_on_download_progress)
	Net.updater.download_failed.connect(_on_download_failed)
	Net.updater.installing.connect(_on_installing)
	Net.leave()
	if scan_tailnet:
		finder.scan()
	if not GameConfig.update_from.is_empty():
		# The main menu's Check for Updates: fetch it now, then back to the menu.
		var s: Dictionary = GameConfig.update_from
		GameConfig.update_from = {}
		_update_from.call_deferred(s, true)
	if GameConfig.auto_browse != "":
		# Back from updating from a server: look it up again.
		address_edit.text = GameConfig.auto_browse
		GameConfig.auto_browse = ""
		_look_up()
		if OS.get_cmdline_user_args().has("--updated"):
			update_label.visible = true
			update_label.text = "Updated: you now have version %s." % GameConfig.version()
	get_tree().create_timer(1.0).timeout.connect(_redraw)

# --- the list --------------------------------------------------------------

func _looking() -> String:
	return "Asking the server what it's doing..." if web else "Looking for servers on your Tailscale network..."

func _process(delta: float) -> void:
	var before := floori(_waited)
	_waited += delta
	if web and floori(_waited) != before:
		_redraw() # so a server that stops answering is noticed

func _on_scanned(note: String) -> void:
	_scanned = true
	_note = note
	_redraw()

func _on_found(_server: Dictionary) -> void:
	if status_label.text.begins_with("Asking"):
		status_label.text = "" # it answered (it may already be in the list under another address)
	_redraw()

func _look_up() -> void:
	var why := finder.look_up(address_edit.text)
	status_label.text = why if why != "" else "Asking %s..." % address_edit.text.strip_edges()
	if why == "":
		get_tree().create_timer(3.0).timeout.connect(func() -> void:
			if is_instance_valid(status_label) and status_label.text.begins_with("Asking"):
				status_label.text = "No answer from %s: no Pirates Plunder server there, or it's out of reach (or older than 0.8.0, which doesn't answer: join it by its address under Join a Game)." % address_edit.text.strip_edges())

## Rebuilds the list when what it would show has changed (not on every
## answer, so a button isn't swapped out from under the mouse).
func _redraw() -> void:
	var servers := finder.servers()
	var key := JSON.stringify(servers.map(func(s: Dictionary) -> Array:
		return [s.address, s.v, s.state, s.leader, s.taken, s.open, s.crews, s.people, s.mine, s.players, s.back]))
	key += str(_busy) + str(start_panel.visible)
	if key != _shown:
		_shown = key
		for c in list_box.get_children():
			c.queue_free()
		for s in servers:
			list_box.add_child(_server_row(s))
	if servers.is_empty():
		if web:
			scan_label.text = "Asking the server what it's doing..." if not _scanned or finder.servers().is_empty() and _waited < 6.0 \
				else "The server isn't answering. Is it still running? This page will keep trying."
		elif not _scanned:
			scan_label.text = _looking()
		elif _note == "notfound":
			scan_label.text = "Tailscale isn't installed here, so only a server on this computer, or one you type in below, can be found. With Tailscale, servers on your tailnet (and ones friends share with you) show up by themselves."
		elif _note != "":
			scan_label.text = _note
		else:
			scan_label.text = "No servers found on your Tailscale network. Is the server running, and has its owner shared that machine with you in Tailscale?"
	elif web:
		scan_label.text = "The list keeps itself up to date."
	else:
		scan_label.text = "Found %d server%s. The list keeps itself up to date." % [servers.size(), "" if servers.size() == 1 else "s"]
	tailscale_row.visible = _scanned and _note != "" and not web

func _server_row(s: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.16, 0.21)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	panel.add_child(stack)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	stack.add_child(row)
	var words := VBoxContainer.new()
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var head := _label("%s   " % _server_name(s), 19)
	head.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	words.add_child(head)
	var addr := _label(("version %s" % s.v) if web else "%s  ·  version %s" % [s.address, s.v], 12)
	addr.modulate = Color(1, 1, 1, 0.55)
	words.add_child(addr)
	var line := _label(_describe(s), 14)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.custom_minimum_size = Vector2(440, 0)
	words.add_child(line)
	row.add_child(words)
	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 4)
	row.add_child(buttons)
	if _too_old(s):
		return panel
	if not web and Updater.compare(str(s.v), GameConfig.version()) > 0:
		buttons.add_child(_button("Update to %s" % s.v, func() -> void: _update_from(s)))
	match str(s.state):
		"free":
			buttons.add_child(_button("Start a Game", func() -> void: _open_start(s)))
		"setup":
			var b := _button("Join", func() -> void: _go(s, null))
			b.disabled = int(s.open) == 0
			if b.disabled:
				b.text = "Full"
			buttons.add_child(b)
		_:
			if ServerFinder.can_rejoin(s):
				# We lost our connection to this game: our crew is waiting for us.
				buttons.add_child(_button("Rejoin Your Crew", func() -> void: _go(s, null)))
			else:
				var b := _button("In Progress", func() -> void: pass)
				b.disabled = true
				buttons.add_child(b)
	buttons.add_child(_button("Hall of Fame", func() -> void: _open_board(s)))
	# This player's saved games there: continue one while the server is free.
	var saved: Array = s.get("mine", [])
	if not saved.is_empty():
		var saved_head := _label("Your saved games here:" if str(s.state) == "free" else "Your saved games here (continue one once the server is free):", 14)
		saved_head.modulate = Color(1, 1, 1, 0.75)
		stack.add_child(saved_head)
		for g in saved:
			var game_row := HBoxContainer.new()
			game_row.add_theme_constant_override("separation", 10)
			var what := _label(str(g.s), 14)
			what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			game_row.add_child(what)
			var id := str(g.id)
			var b := _button("Continue", func() -> void: _go(s, {"continue": id}))
			b.disabled = str(s.state) != "free"
			game_row.add_child(b)
			stack.add_child(game_row)
			b.disabled = b.disabled or _busy or start_panel.visible
	for b in buttons.get_children():
		if b is BaseButton:
			b.disabled = b.disabled or _busy or start_panel.visible
	return panel

func _server_name(s: Dictionary) -> String:
	return server_name(s)

static func server_name(s: Dictionary) -> String:
	return str(s.get("name", "")) if str(s.get("name", "")) != "" else str(s.get("machine", "?"))

func _too_old(s: Dictionary) -> bool:
	return Updater.compare(str(s.v), GameConfig.version()) < 0

## What the server is doing, in a sentence.
func _describe(s: Dictionary) -> String:
	var mine := GameConfig.version()
	if _too_old(s):
		return "It runs version %s, older than yours (%s). Whoever runs it needs to update it before you can play there." % [s.v, mine]
	var note := ""
	if Updater.compare(str(s.v), mine) > 0:
		note = "  It has version %s (you have %s): going there updates your game first, then brings you back here." % [s.v, mine]
	var size: String = TerrainGrid.LENGTH_NAMES[int(s.length)].to_lower()
	var who := ", ".join(s.players) if not s.players.is_empty() else ""
	match str(s.state):
		"free":
			return "Free. Start a game here and your friends can join it." + note
		"setup":
			var lead := ("%s's game" % s.leader) if str(s.leader) != "" else "A game"
			if str(s.lobby) == "always":
				lead = "Lobby open"
			var royale: Dictionary = s.get("royale", {}) if s.get("royale") is Dictionary else {}
			if bool(royale.get("on", false)):
				lead += ", a Battle Royale (%d rounds)" % int(royale.get("rounds", 3))
			return "%s: %d crews%s, a %s island, %s. %d of %d player seat%s free%s.%s" % [lead, int(s.crews),
				", 2 v 2" if int(s.partner) > 0 else "", size, GameConfig.turn_limit_text(int(s.get("turn", 0))),
				int(s.open), int(s.people), "" if int(s.people) == 1 else "s",
				(" (%s here)" % who) if who != "" else "", note]
	return "A game is under way%s. You can join once it's over." % ((" (%s)" % who) if who != "" else "")

# --- the Hall of Fame ------------------------------------------------------------

## Asks a server for its Hall of Fame and shows it here: the best players
## there by wins, then Battle Royale titles, chests aboard and captures,
## with your own row marked.
func _open_board(s: Dictionary) -> void:
	_board_for = s
	start_panel.visible = false
	board_panel.visible = true
	_fill_board({}, "Asking %s..." % _server_name(s))
	finder.ask_board(s)
	var asked := s
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		if board_panel.visible and _board_for == asked and board_panel.get_node_or_null("Waiting") != null:
			_fill_board({}, "No answer. It may be running an older version, without a Hall of Fame."))

func _on_board_found(server: Dictionary, board: Dictionary) -> void:
	if board_panel.visible and str(server.get("id", "")) == str(_board_for.get("id", "")):
		_fill_board(board)

func _fill_board(board: Dictionary, note := "") -> void:
	for c in board_panel.get_children():
		board_panel.remove_child(c)
		c.queue_free()
	board_panel.add_child(_title("HALL OF FAME: %s" % _server_name(_board_for).to_upper(), 22))
	if note != "":
		var wait := _small(note)
		wait.name = "Waiting"
		board_panel.add_child(wait)
	else:
		var rows: Array = board.get("rows", [])
		if rows.is_empty():
			board_panel.add_child(_small("Nobody has finished a game here yet. Be the first."))
		else:
			var me := ServerFinder.back_key(GameConfig.player_id())
			var grid := GridContainer.new()
			grid.columns = 7
			grid.add_theme_constant_override("h_separation", 18)
			grid.add_theme_constant_override("v_separation", 4)
			for h in ["", "Player", "Wins", "Titles", "Chests aboard", "Captures", "Games"]:
				var l := _label(h, 13)
				l.modulate = Color(1, 1, 1, 0.6)
				grid.add_child(l)
			var shown := rows.duplicate()
			var mine: Array = board.get("me", [])
			if not mine.is_empty():
				shown.append(mine)
			for r in shown:
				var you := str(r[2]) == me
				var cells := ["%d." % int(r[0]), str(r[1]) + ("  (you)" if you else ""), r[4], r[5], r[6], r[7], r[3]]
				for v in cells:
					var l := _label(str(v), 15)
					if you:
						l.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
					grid.add_child(l)
			board_panel.add_child(grid)
			var n := int(board.get("players", rows.size()))
			board_panel.add_child(_small("%d player%s ha%s finished a game here. Titles are Battle Royales won." % [n, "" if n == 1 else "s", "s" if n == 1 else "ve"]))
	board_panel.add_child(_button("Close", func() -> void:
		board_panel.visible = false
		_board_for = {}))

# --- a new game --------------------------------------------------------------

func _open_start(s: Dictionary) -> void:
	_picked = s
	var d: Dictionary = s.defaults
	_ask = {"crews": int(d.crews), "seats": int(d.crews), "length": int(d.length),
		"difficulty": int(d.difficulty), "size": int(d.size), "partner": int(d.partner),
		"royale": false, "rounds": 3, "vega": false,
		"turn": int(d.get("turn", GameConfig.SERVER_TURN_SECONDS)) if GameConfig.TURN_CHOICES.has(int(d.get("turn", -1))) else GameConfig.SERVER_TURN_SECONDS}
	if GameConfig.browse_royale:
		_set_royale(true)
	start_panel.visible = true
	status_label.text = ""
	_build_start()
	_redraw()

func _build_start() -> void:
	for c in start_panel.get_children():
		c.queue_free()
	var s := _picked
	start_panel.add_child(_title("A NEW GAME ON %s" % _server_name(s).to_upper(), 22))
	var most := int(s.most)
	start_panel.add_child(_choice_row("Game:", ["Ordinary", "Battle Royale"], 1 if _ask.royale else 0, func(i: int) -> void:
		_set_royale(i == 1)
		_build_start()))
	if _ask.royale:
		start_panel.add_child(_small("Every crew for itself; each player brings the crew they've trained in single player, whole. The most rounds won takes it."))
		start_panel.add_child(_choice_row("Rounds:", GameConfig.BR_ROUNDS.map(func(n: int) -> String: return str(n)),
			GameConfig.BR_ROUNDS.find(int(_ask.rounds)), func(i: int) -> void: _ask.rounds = GameConfig.BR_ROUNDS[i]))
		start_panel.add_child(_choice_row("Vega:", ["Final round only", "Every round"], 1 if _ask.vega else 0,
			func(i: int) -> void: _ask.vega = i == 1))
	start_panel.add_child(_choice_row("Crews:", range(GameConfig.MIN_TEAMS, most + 1).map(func(n: int) -> String: return "%d crews" % n),
		int(_ask.crews) - GameConfig.MIN_TEAMS, func(i: int) -> void:
			var all_players := int(_ask.seats) >= int(_ask.crews) # keep "every crew a player" as crews change
			_ask.crews = GameConfig.MIN_TEAMS + i
			_ask.seats = int(_ask.crews) if all_players else mini(int(_ask.seats), int(_ask.crews))
			_build_start()))
	if int(_ask.crews) == GameConfig.MAX_TEAMS and not _ask.royale:
		var with_navs := int(_ask.partner)
		start_panel.add_child(_choice_row("Sides:", ["Free-for-all", "2 v 2: NAVS + Pirates", "2 v 2: NAVS + Corsairs", "2 v 2: NAVS + Buccaneers"],
			maxi(with_navs, 0), func(i: int) -> void:
				_ask.partner = i if i > 0 else GameConfig.FREE_FOR_ALL
				_build_start()))
	start_panel.add_child(_choice_row("Players:", range(1, int(_ask.crews) + 1).map(func(n: int) -> String:
			return "1 (just you)" if n == 1 else str(n)),
		int(_ask.seats) - 1, func(i: int) -> void:
			_ask.seats = i + 1
			_build_start()))
	var who := []
	for t in int(_ask.crews):
		who.append("%s: %s" % [GameConfig.team_name(t), ("you" if t == 0 else "a player") if t < int(_ask.seats) else "the computer"])
	var sides_note := ""
	var sides := GameConfig.sides_for(int(_ask.partner), int(_ask.crews))
	if not sides.is_empty():
		var pair := []
		for t in GameConfig.MAX_TEAMS:
			if t != 0 and int(sides[t]) == 0:
				pair.append(GameConfig.team_name(t))
		sides_note = " You and the %s are one side, the other two crews the other." % pair[0]
	start_panel.add_child(_small("You sail the NAVS and lead the game. " + ", ".join(who) + "." + sides_note))
	start_panel.add_child(_choice_row("Turn limit:", GameConfig.TURN_CHOICES.map(func(t: int) -> String: return "None" if t == 0 else "%d min" % (t / 60)),
		GameConfig.TURN_CHOICES.find(int(_ask.turn)), func(i: int) -> void: _ask.turn = GameConfig.TURN_CHOICES[i]))
	start_panel.add_child(_choice_row("Island:", TerrainGrid.LENGTH_NAMES.map(func(n: String) -> String: return n),
		int(_ask.length), func(i: int) -> void: _ask.length = i))
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	size_row.add_child(_label("Crew size:", 15))
	var size_label := _label(str(_ask.size), 17)
	size_label.custom_minimum_size = Vector2(26, 0)
	size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	size_row.add_child(_button("-", func() -> void:
		_ask.size = maxi(int(_ask.size) - 1, 1)
		size_label.text = str(_ask.size)))
	size_row.add_child(size_label)
	size_row.add_child(_button("+", func() -> void:
		_ask.size = mini(int(_ask.size) + 1, GameConfig.MAX_TEAM_SIZE)
		size_label.text = str(_ask.size)))
	start_panel.add_child(size_row)
	size_row.visible = not _ask.royale or int(_ask.seats) < int(_ask.crews) # the computer's crews' size
	if int(_ask.seats) < int(_ask.crews):
		start_panel.add_child(_choice_row("Computer crews:", GameConfig.DIFFICULTY_NAMES.map(func(n: String) -> String: return n),
			int(_ask.difficulty), func(i: int) -> void: _ask.difficulty = i))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var go := _button("Start This Game", func() -> void: _go(_picked, _ask.duplicate()))
	go.custom_minimum_size = Vector2(0, 40)
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(go)
	row.add_child(_button("Cancel", func() -> void:
		start_panel.visible = false
		_redraw()))
	start_panel.add_child(row)

## Battle Royale or not. A Battle Royale is free-for-all, and starts on a
## long island with every crew a player.
func _set_royale(on: bool) -> void:
	_ask.royale = on
	if on:
		_ask.partner = GameConfig.FREE_FOR_ALL
		_ask.length = TerrainGrid.Length.LONG
		_ask.crews = int(_picked.get("most", GameConfig.MAX_TEAMS))
		_ask.seats = int(_ask.crews)

## A label and a row of toggle buttons; `pick` gets the index chosen.
func _choice_row(text: String, names: Array, current: int, pick: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var l := _label(text, 15)
	l.custom_minimum_size = Vector2(130, 0)
	row.add_child(l)
	var group := ButtonGroup.new()
	for i in names.size():
		var b := Button.new()
		b.text = str(names[i])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == current
		b.pressed.connect(pick.bind(i))
		row.add_child(b)
	return row

# --- going there ---------------------------------------------------------------

## Connect to `s`, asking to start a game (a Dictionary of settings), to
## continue one of our saved games there ({"continue": id}), or to join the game there (null).
func _go(s: Dictionary, request: Variant) -> void:
	if Net.join_game(str(s.address)) != OK:
		status_label.text = "That doesn't look like an address."
		return
	Net.server_request = request
	# After updating from this server, come back to this screen, not a game.
	Net.updater.rejoin_address = ""
	Net.updater.relaunch_extra = PackedStringArray(["--browse=" + str(s.address)])
	_busy = true
	start_panel.visible = false
	status_label.text = "Connecting to %s..." % _server_name(s)
	_redraw()

func _on_joined() -> void:
	if _update_only:
		# Only after an update, but the server has our version after all
		# (it was updated a moment ago): nothing to fetch, so don't stay.
		_update_only = false
		_busy = false
		Net.leave()
		status_label.text = "You're up to date: you have version %s." % GameConfig.version()
		_redraw()
		return
	if Net.resuming:
		# A saved match: our crew is already chosen. Wait here to set sail.
		status_label.text = "Rejoined the saved match as the %s. Waiting for the others..." % GameConfig.team_name(GameConfig.my_team).to_upper()
		return
	get_tree().change_scene_to_file("res://scenes/Setup.tscn")

func _on_join_failed(reason: String) -> void:
	_busy = false
	if _update_only and reason.begins_with("Nobody has started"):
		# Same version after all, so the server looked at us as a player.
		_update_only = false
		status_label.text = "You're up to date: you have version %s." % GameConfig.version()
		_redraw()
		return
	_update_only = false
	status_label.text = reason
	if reason.begins_with("Couldn't reach"):
		status_label.text += " Is the server still running, and can this computer reach it?"
	_redraw()

func _on_server_left() -> void:
	if _busy and Net.refusal == "":
		_busy = false
		_update_only = false
		status_label.text = "The server closed the connection."
		_redraw()

# --- a server with a newer version -----------------------------------------------

## How long Check for Updates waits for servers to answer.
const CHECK_WAIT := 2.5

## Check for Updates: look for servers again, then go by their answers.
func _check_for_updates() -> void:
	if _busy:
		return
	update_label.visible = false
	status_label.text = "Checking the servers for a newer version..."
	if scan_tailnet:
		finder.scan()
	get_tree().create_timer(CHECK_WAIT).timeout.connect(_finish_check)

func _finish_check() -> void:
	if not is_inside_tree() or _busy:
		return
	var servers := finder.servers()
	if servers.is_empty():
		status_label.text = "No servers answered, so there's nothing to check against. Is the server running, and can this computer reach it (is Tailscale on)? Or type its address above and try again."
		return
	var newest := update_source(servers, GameConfig.version())
	if newest.is_empty():
		status_label.text = up_to_date_text(servers, GameConfig.version())
		return
	_update_from(newest)

## The server to update from: the one with the newest version newer than
## `mine`, or {} if none has a newer one.
static func update_source(servers: Array, mine: String) -> Dictionary:
	var best := {}
	for s in servers:
		var v := str(s.get("v", ""))
		if Updater.compare(v, mine) > 0 and (best.is_empty() or Updater.compare(v, str(best.v)) > 0):
			best = s
	return best

## What Check for Updates says when no server has a newer version.
static func up_to_date_text(servers: Array, mine: String) -> String:
	var same := []
	var older := []
	for s in servers:
		if Updater.compare(str(s.get("v", "")), mine) == 0:
			same.append(server_name(s))
		else:
			older.append("%s (%s)" % [server_name(s), s.get("v", "?")])
	var text := "You're up to date: you have version %s" % mine
	text += (", the same as %s." % ", ".join(same)) if not same.is_empty() else "."
	if not older.is_empty():
		text += " Older: %s. %s needs updating before you can play there." % [", ".join(older),
			"It" if older.size() == 1 else "Each"]
	return text

## Connect to `s` only to fetch its newer version. The server offers it as
## soon as we say hello (the versions differ), and never seats us. After the
## restart the game comes back here, or to the main menu if that's where
## the check started (`to_menu`).
func _update_from(s: Dictionary, to_menu := false) -> void:
	if _busy:
		return
	if Net.join_game(str(s.address)) != OK:
		status_label.text = "That doesn't look like an address."
		return
	Net.server_request = null
	Net.updater.rejoin_address = ""
	Net.updater.relaunch_extra = PackedStringArray() if to_menu else PackedStringArray(["--browse=" + str(s.address)])
	_busy = true
	_update_only = true
	start_panel.visible = false
	status_label.text = "%s has version %s (you have %s). Asking it for the update..." % [server_name(s), s.v, GameConfig.version()]
	_redraw()

func _on_versions_differ(peer: int, version: String, newer: bool, can_get: bool) -> void:
	if not newer:
		return # the server sends us away and says why
	update_label.visible = true
	if web:
		update_label.text = "The server has version %s and this page has %s. Reload the page to get version %s." % [version, GameConfig.version(), version]
		return
	if not can_get:
		update_label.text = "The server has version %s and you have %s, but it can't send one for this computer. Download %s from the release page." % [version, GameConfig.version(), version]
		return
	_update_peer = peer
	update_label.text = "The server has version %s and you have %s. Updating: the game will restart and come back to this screen." % [version, GameConfig.version()]
	update_bar.visible = true
	update_bar.value = 0
	Net.updater.download_from(peer)

func _on_download_progress(done: int, total: int) -> void:
	update_bar.value = 100.0 * done / maxf(total, 1.0)
	update_label.text = "Downloading version %s from the server: %d of %d MB" % [Net.updater.incoming_version, int(done / 1e6), int(total / 1e6)]

func _on_download_failed(reason: String) -> void:
	update_label.text = reason
	update_bar.visible = false
	_busy = false
	_update_only = false
	Net.leave()
	_redraw()

func _on_installing(message: String) -> void:
	update_label.text = message
	update_bar.visible = false

# --- small ui helpers -----------------------------------------------------------

func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(36, 34)
	b.pressed.connect(action)
	return b

func _link_row(links: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for link in links:
		row.add_child(_button(link[0], func() -> void: OS.shell_open(link[1])))
	return row

func _title(text: String, size: int) -> Label:
	var l := _label(text, size)
	l.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	return l

func _small(text: String) -> Label:
	var l := _label(text, 13)
	l.modulate = Color(1, 1, 1, 0.72)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(700, 0)
	return l

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l

func _gap(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c
