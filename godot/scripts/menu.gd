extends Control

## The first screen, in pages. The first asks only how you want to play:
## Single Player, Multiplayer or Settings (and Continue and Saved Games, when
## there's a saved game). Each leads to a second page with its choices and a
## Back button (Esc goes back too):
##  - Single Player: the campaign (scripts/campaign.gd), against one to three
##    computer crews, the tutorial (scripts/tutorial.gd, which replaced
##    Practice Alone); and Your Crew, the NAVS you've been training.
##  - Saved Games: the three save slots, to continue or delete.
##  - Multiplayer: Play on a Server (servers on your Tailscale network: start
##    a game on one, or join one), Play Direct, players sharing one computer,
##    and continuing an online match.
##  - Play Direct (from Multiplayer; Back returns there): Host a Game (on
##    this computer, for up to three friends) or Join a Game (by address).
##  - Settings: your name, the volume, and the phone layout.
## In a web browser the page came from a server, so Play on This Server is on
## the first page too. Over the internet players use Tailscale; on the same
## Wi-Fi nothing extra is needed.

enum Page { HOME, SINGLE, MULTI, SETTINGS, DIRECT, SAVES, ROYALE }

## The page to show when the menu opens: the one you left it from, so Back
## on the server list or Setup lands where you were.
static var last_page := Page.HOME

var page := Page.HOME
var _pages: VBoxContainer
var _name_edit: LineEdit = null
var _delete_armed := -1
var _update_box: VBoxContainer = null
var _finder: ServerFinder = null
var _tailscale_note := "" # what the finder's last look at Tailscale said ("" if it's running)
var _release: ReleaseUpdate = null
const CHECK_WAIT := 2.5

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if _server_wanted():
		_launch_server()
		return
	_build()

## Started with --server (or exported as a dedicated server): no menu, just the
## server (scripts/dedicated_server.gd), which takes over from here.
func _server_wanted() -> bool:
	return OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server") \
		or OS.get_cmdline_args().has("--server")

func _launch_server() -> void:
	if get_tree().root.has_node("DedicatedServer"):
		return
	var server: Node = load("res://scripts/dedicated_server.gd").new()
	server.name = "DedicatedServer"
	get_tree().root.add_child.call_deferred(server)

func _build() -> void:
	UiTheme.dress(self)

	var middle := CenterContainer.new()
	middle.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(middle)
	var centre := VBoxContainer.new()
	centre.custom_minimum_size = Vector2(520, 0)
	centre.add_theme_constant_override("separation", 12)
	middle.add_child(centre)

	var title := _label("Pirates Plunder", 84)
	title.theme_type_variation = UiTheme.TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	centre.add_child(title)

	var sub := _label("Race the pirates for the island's treasure.", 16)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(1, 1, 1, 0.7)
	centre.add_child(sub)

	centre.add_child(_gap(16))
	_pages = VBoxContainer.new()
	_pages.add_theme_constant_override("separation", 12)
	centre.add_child(_pages)

	_after_build(centre)
	show_page(last_page)

## Shows one page of the menu in place of the one before.
func show_page(which: Page) -> void:
	_update_box = null # freed with the page below
	if _name_edit != null:
		GameConfig.set_player_name(_name_edit.text) # leaving Settings keeps what was typed
		_name_edit = null
	for c in _pages.get_children():
		_pages.remove_child(c)
		c.queue_free()
	if which != Page.SAVES:
		_delete_armed = -1
	page = which
	last_page = which
	match which:
		Page.SINGLE: _single_page()
		Page.MULTI: _multi_page()
		Page.SETTINGS: _settings_page()
		Page.DIRECT: _direct_page()
		Page.SAVES: _saves_page()
		Page.ROYALE: _royale_page()
		_: _home_page()
	# Keyboards and controllers start on the first button.
	var first := _first_button(_pages)
	if first != null and not Touch.enabled:
		# Later, so the page is laid out; by then it may have been replaced
		# (two pages in one frame) or the menu left, so check it's still here.
		(func() -> void:
			if is_instance_valid(first) and first.is_inside_tree():
				first.grab_focus()).call_deferred()

func _unhandled_input(event: InputEvent) -> void:
	if _pages != null and page != Page.HOME and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		show_page(back_from(page))

## Where Back (or Esc) goes from a page.
static func back_from(which: Page) -> Page:
	return Page.MULTI if which == Page.DIRECT or which == Page.ROYALE else Page.HOME

func _web() -> bool:
	return OS.has_feature("web")

# --- the pages ------------------------------------------------------------------

func _home_page() -> void:
	var newest := GameConfig.newest_save()
	if newest != "":
		_pages.add_child(_menu_button("Continue",
			GameConfig.save_summary(newest), true,
			func() -> void: _continue(newest)))
	if _web():
		# The page came from a server, so playing there is one tap away.
		_pages.add_child(_menu_button("Play on This Server",
			"Start a game on the server this page came from, or join the one your friends have started.", true,
			_browse))
	_pages.add_child(_menu_button("Single Player",
		"Race computer crews for the treasure, or practise alone.", true,
		func() -> void: show_page(Page.SINGLE)))
	_pages.add_child(_menu_button("Multiplayer",
		"With friends: sharing this %s, or online." % ("phone" if Touch.enabled else "computer") if _web()
			else "With friends: on a server, friend to friend, or sharing this computer.", true,
		func() -> void: show_page(Page.MULTI)))
	if newest != "":
		var n := 0
		for path in GameConfig.slot_paths():
			if not GameConfig.save_info(path).is_empty():
				n += 1
		_pages.add_child(_menu_button("Saved Games",
			"%d saved game%s: pick one to continue, or clear a slot." % [n, "" if n == 1 else "s"], true,
			func() -> void: show_page(Page.SAVES)))
	_pages.add_child(_menu_button("Settings",
		"Your name, the volume, and the layout.", true,
		func() -> void: show_page(Page.SETTINGS)))
	if not _web(): # a web page always loads the server's version
		_pages.add_child(_menu_button("Check for Updates",
			"See whether there's a newer version of the game, and update to it.", true,
			_check_for_updates))
		_update_box = VBoxContainer.new()
		_update_box.name = "UpdateCheck"
		_update_box.add_theme_constant_override("separation", 6)
		_pages.add_child(_update_box)
	if not _web(): # a web page has nothing to quit to
		_pages.add_child(_gap(4))
		var quit := Button.new()
		quit.text = "Quit"
		quit.custom_minimum_size = Vector2(0, 34)
		quit.pressed.connect(func() -> void: get_tree().quit())
		_pages.add_child(quit)

func _single_page() -> void:
	_pages.add_child(_heading("Single Player"))
	var done := Campaign.won_count()
	_pages.add_child(_menu_button("Campaign: The Star Chart",
		("Captain! All %d islands won. Sail them again, or watch the ending." % Campaign.count()) if Campaign.is_captain() and done == Campaign.count()
			else ("Pirates stole the Star Chart and took Vega, your best navigator. Fifteen islands to get them back." if done == 0
			else "Island %d of %d: %s." % [Campaign.next_open() + 1, Campaign.count(), Campaign.chapter(Campaign.next_open()).title]), true,
		func() -> void:
			Net.leave()
			get_tree().change_scene_to_file("res://scenes/Campaign.tscn")))
	_pages.add_child(_menu_button("Against the Computer",
		"Race one to three computer crews for the treasure.", true,
		func() -> void: _start(GameConfig.Mode.COMPUTER)))
	_pages.add_child(_menu_button("Tutorial",
		"New here? A guided island: the controls, digging, carrying, a sword fight. About ten minutes.", true,
		func() -> void:
			Net.leave()
			GameConfig.start_tutorial()
			get_tree().change_scene_to_file("res://scenes/Main.tscn")))
	var crew := GameConfig.crew.size()
	_pages.add_child(_menu_button("Your Crew",
		("%d sailor%s you've been training: their skills, coaching and confidence. Rename them here." % [crew, "" if crew == 1 else "s"])
			if crew > 0 else "Your NAVS join the crew the first time they land. Nobody yet.", true,
		_open_crew))
	_add_back()

## The saved games, one row per slot: Continue it, or Delete it (twice).
func _saves_page() -> void:
	_pages.add_child(_heading("Saved Games"))
	for i in GameConfig.SLOTS:
		var path := GameConfig.slot_path(i)
		var info := GameConfig.save_info(path)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var open_b := Button.new()
		open_b.name = "Load%d" % (i + 1)
		open_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		open_b.custom_minimum_size = Vector2(0, 58)
		open_b.add_theme_font_size_override("font_size", 15)
		open_b.clip_text = true
		if info.is_empty():
			open_b.text = "Slot %d:  empty" % (i + 1)
			open_b.disabled = true
		else:
			var when := GameConfig.saved_when(int(info.saved_at))
			open_b.text = "Slot %d:  %s%s" % [i + 1, info.summary, ("\n" + when) if when != "" else ""]
			open_b.pressed.connect(func() -> void: _continue(path))
		row.add_child(open_b)
		var del := Button.new()
		del.name = "Delete%d" % (i + 1)
		del.text = "Sure?" if _delete_armed == i else "Delete"
		del.custom_minimum_size = Vector2(92, 58)
		del.disabled = info.is_empty()
		del.pressed.connect(func() -> void:
			if _delete_armed != i:
				_delete_armed = i
			else:
				_delete_armed = -1
				GameConfig.delete_save(path)
			show_page(Page.SAVES if GameConfig.has_any_save() else Page.HOME))
		row.add_child(del)
		_pages.add_child(row)
	var note := _label("Save from the game's menu (Esc, or Menu): Save Game. Your crew's training is kept by itself; you don't need a slot for it.", 12)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate = Color(1, 1, 1, 0.55)
	_pages.add_child(note)
	_add_back()

func _multi_page() -> void:
	_pages.add_child(_heading("Multiplayer"))
	if _web():
		_pages.add_child(_menu_button("Play on This Server",
			"Start a game on the server this page came from, or join the one your friends have started.", true,
			_browse))
	else:
		if GameConfig.has_save(GameConfig.online_save_path):
			_pages.add_child(_menu_button("Continue Online Match",
				GameConfig.save_summary(GameConfig.online_save_path) + ". Host it again; your friends rejoin into their own crews.", true,
				_continue_online))
		_pages.add_child(_menu_button("Play on a Server",
			"Find servers on your Tailscale network: start a game on one, or join the game someone has started.", true,
			_browse))
		_pages.add_child(_menu_button("Play Direct",
			"Friend to friend, no server: host a game on your computer, or join a friend's. Same Wi-Fi, or online through Tailscale.", true,
			func() -> void: show_page(Page.DIRECT)))
	_pages.add_child(_menu_button("Battle Royale",
		"Every crew for itself on a big island, each player bringing the crew they've trained in single player.", true,
		func() -> void: show_page(Page.ROYALE)))
	_pages.add_child(_menu_button("Players Sharing One %s" % ("Phone" if Touch.enabled else "Computer"),
		"Two to four crews, passing the %s between turns." % ("phone" if Touch.enabled else "mouse"), true,
		func() -> void: _start(GameConfig.Mode.HOTSEAT)))
	_add_back()

func _direct_page() -> void:
	_pages.add_child(_heading("Play Direct"))
	_pages.add_child(_menu_button("Host a Game",
		"Your computer holds the game, for up to three friends. You'll see the address they type in.", true,
		func() -> void: _start(GameConfig.Mode.HOST)))
	_pages.add_child(_menu_button("Join a Game",
		"Join a friend's game: type the address their screen shows.", true,
		func() -> void:
			Net.leave()
			GameConfig.reset()
			GameConfig.mode = GameConfig.Mode.GUEST
			get_tree().change_scene_to_file("res://scenes/Lobby.tscn")))
	_add_back()

## Battle Royale: on a server (start one from the server list, or join one
## there) or hosted on this computer for friends to join.
func _royale_page() -> void:
	_pages.add_child(_heading("Battle Royale"))
	var n := GameConfig.crew.size()
	var note := _label(("You'll bring your crew of %d, as you've trained them." % n) if n > 0
		else "You have no trained crew yet: you'd bring ten fresh recruits. Train a crew in single player first to bring them here.", 14)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate = Color(0.75, 0.95, 0.75)
	_pages.add_child(note)
	_pages.add_child(_menu_button("Play on This Server" if _web() else "On a Server",
		"Start a Battle Royale on a server (choose Battle Royale in its new-game settings), or join one already there.", true,
		func() -> void: _browse(true)))
	if not _web():
		_pages.add_child(_menu_button("Host a Battle Royale",
			"Your computer holds it, for up to three friends. Choose the rounds and whether Vega may sail every round.", true,
			_host_royale))
		_pages.add_child(_menu_button("Join a Friend's",
			"Type the address their screen shows. Their game says it's a Battle Royale.", true,
			func() -> void:
				Net.leave()
				GameConfig.reset()
				GameConfig.mode = GameConfig.Mode.GUEST
				get_tree().change_scene_to_file("res://scenes/Lobby.tscn")))
	_add_back()

## Check for Updates: ask the game's public releases on GitHub for the
## latest version (ReleaseUpdate). Newer: offer it, and download, check and
## install it if the player says so. If GitHub can't be reached, ask the
## servers on the tailnet instead (_check_servers).
func _check_for_updates() -> void:
	if _update_box == null:
		return
	if _release == null:
		_release = ReleaseUpdate.new()
		_release.name = "ReleaseUpdate"
		add_child(_release)
		_release.checked.connect(_on_release_checked)
		_release.progress.connect(_on_release_progress)
		_release.failed.connect(func(reason: String) -> void:
			_on_release_failed(reason)
			if _update_box != null and is_instance_valid(_update_box):
				_offer_update("Open the Releases Page", func() -> void: OS.shell_open(ReleaseUpdate.PAGE)))
		_release.installing.connect(_show_update_note)
		Net.updater.download_failed.connect(_on_release_failed)
		Net.updater.installing.connect(_show_update_note)
	if _release.busy():
		return
	_show_update_note("Checking for a newer version...")
	_release.check()

func _on_release_checked(result: Dictionary) -> void:
	if not is_inside_tree() or _update_box == null or not is_instance_valid(_update_box):
		return
	match str(result.kind):
		"newer":
			if _release.can_install(result):
				_show_update_note("%s Update now? The game downloads it, checks it, and restarts." % result.text)
				_offer_update("Update Now", func() -> void:
					_show_update_note("Downloading version %s..." % result.version)
					_release.download(result))
			else:
				_show_update_note("%s Download it from the releases page." % result.text)
				_offer_update("Open the Releases Page", func() -> void: OS.shell_open(str(result.page)))
		"current":
			_show_update_note(str(result.text))
		_:
			_check_servers("%s Asking the servers on your tailnet instead..." % result.text)

## Update Now (or another way to get it) and Not Now, under the note.
func _offer_update(label: String, act: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var go := Button.new()
	go.name = "UpdateNow"
	go.text = label
	go.custom_minimum_size = Vector2(0, 40)
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go.pressed.connect(act)
	row.add_child(go)
	var later := Button.new()
	later.text = "Not Now"
	later.custom_minimum_size = Vector2(120, 40)
	later.pressed.connect(func() -> void: _show_update_note(""))
	row.add_child(later)
	_update_box.add_child(row)

func _on_release_progress(done: int, total: int) -> void:
	if _update_box == null or not is_instance_valid(_update_box) or _update_box.get_child_count() == 0:
		return
	var l := _update_box.get_child(0) as Label
	if l != null:
		l.text = "Downloading... %d MB%s" % [done >> 20, (" of %d MB" % (total >> 20)) if total > 0 else ""]

func _on_release_failed(reason: String) -> void:
	if _update_box != null and is_instance_valid(_update_box):
		_show_update_note(reason)

## The servers on the tailnet (as the server list finds them): wait a moment
## for their answers, then say what was found. A newer version is offered,
## not fetched until the player says so.
func _check_servers(note: String) -> void:
	_show_update_note(note)
	if _finder == null:
		_finder = ServerFinder.new()
		add_child(_finder)
		_finder.scanned.connect(func(n: String) -> void: _tailscale_note = n)
	_finder.scan()
	get_tree().create_timer(CHECK_WAIT).timeout.connect(func() -> void:
		if not is_inside_tree() or _update_box == null or not is_instance_valid(_update_box):
			return
		var found := check_result(_finder.servers(), GameConfig.version(), _tailscale_note)
		_show_update_note(str(found.text))
		if found.kind == "newer":
			var s: Dictionary = found.server
			_offer_update("Update Now", func() -> void: _update_now(s)))

## What the check found: {kind: "none" (no server answered), "current" or
## "newer", text, server (the one with the newest version, for "newer")}.
## `note` is what the look at Tailscale said (as ServerFinder's scanned).
static func check_result(servers: Array, mine: String, note := "") -> Dictionary:
	var browser: Script = load("res://scripts/server_browser.gd")
	if servers.is_empty():
		if note != "" and note != "notfound":
			return {"kind": "none", "text": "No servers answered. " + note}
		return {"kind": "none", "text": "No servers answered. Is Tailscale on, and is the server running? (Play on a Server can also look one up by its address.)"}
	var newest: Dictionary = browser.call("update_source", servers, mine)
	if newest.is_empty():
		return {"kind": "current", "text": browser.call("up_to_date_text", servers, mine)}
	return {"kind": "newer", "server": newest,
		"text": "Version %s is on %s (you have %s). Update now? The game downloads it, restarts and comes back here." % [newest.v, browser.call("server_name", newest), mine]}

func _show_update_note(text: String) -> void:
	for c in _update_box.get_children():
		_update_box.remove_child(c)
		c.queue_free()
	if text == "":
		return
	var l := _label(text, 14)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	_update_box.add_child(l)

## Yes: the server list fetches it (the same as its own Check for Updates)
## and the game restarts into this menu, saying it's updated.
func _update_now(s: Dictionary) -> void:
	GameConfig.update_from = s
	get_tree().change_scene_to_file("res://scenes/ServerBrowser.tscn")

func _host_royale() -> void:
	Net.leave()
	GameConfig.host_royale()
	get_tree().change_scene_to_file("res://scenes/Setup.tscn")

func _settings_page() -> void:
	_pages.add_child(_heading("Settings"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	_pages.add_child(grid)

	# Your name: what other players see in a server's lobby and their lists.
	grid.add_child(_setting_label("Your name"))
	_name_edit = LineEdit.new()
	_name_edit.name = "NameEdit"
	_name_edit.text = GameConfig.player_name()
	_name_edit.max_length = 20
	_name_edit.custom_minimum_size = Vector2(300, 40)
	_name_edit.add_theme_font_size_override("font_size", 18)
	_name_edit.tooltip_text = "What other players see in a server's lobby and in their server lists."
	_name_edit.text_submitted.connect(func(t: String) -> void:
		GameConfig.set_player_name(t)
		_name_edit.text = GameConfig.player_name()
		_name_edit.release_focus())
	_name_edit.focus_exited.connect(func() -> void:
		if _name_edit != null:
			GameConfig.set_player_name(_name_edit.text))
	grid.add_child(_name_edit)

	grid.add_child(_setting_label("Volume"))
	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 10)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 5
	slider.value = roundf(AudioManager.volume * 100.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0, 32)
	var vol_label := _label("%d%%" % roundi(slider.value), 18)
	vol_label.custom_minimum_size = Vector2(56, 0)
	slider.value_changed.connect(func(v: float) -> void:
		AudioManager.set_volume(v / 100.0)
		vol_label.text = "%d%%" % roundi(v))
	slider.drag_ended.connect(func(_changed: bool) -> void: AudioManager.play(AudioManifest.DIG)) # a sample at the new level
	vol_row.add_child(slider)
	vol_row.add_child(vol_label)
	grid.add_child(vol_row)

	grid.add_child(_setting_label("Layout"))
	var layout := OptionButton.new()
	layout.custom_minimum_size = Vector2(0, 40)
	layout.add_theme_font_size_override("font_size", 18)
	var choices := [["auto", "Automatic"], ["phone", "Phone: big buttons, touch"], ["computer", "Computer: mouse and keys"]]
	for i in choices.size():
		layout.add_item(choices[i][1], i)
		if choices[i][0] == Touch.layout_setting():
			layout.select(i)
	grid.add_child(layout)

	var note := _label(_layout_note(), 12)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate = Color(1, 1, 1, 0.55)
	_pages.add_child(note)
	layout.item_selected.connect(func(i: int) -> void:
		Touch.set_layout_setting(choices[i][0])
		if _web():
			note.text = "Reloading the page with the new layout..."
			# The layout is chosen as the game starts; a page reload is quick
			# now that the browser has the game.
			JavaScriptBridge.eval("window.location.reload()", true)
		else:
			note.text = _layout_note() + " Takes effect the next time the game starts.")
	_add_back()

func _layout_note() -> String:
	var now := "phone" if Touch.enabled else "computer"
	return "Automatic uses the phone layout on a phone or tablet, and the computer layout everywhere else. Now: the %s layout." % now

# --- what the buttons do ----------------------------------------------------------

func _after_build(centre: Control) -> void:
	if GameConfig.auto_join != "":
		# Restarted after an update: straight back to the friend's game.
		GameConfig.reset()
		GameConfig.mode = GameConfig.Mode.GUEST
		get_tree().change_scene_to_file.call_deferred("res://scenes/Lobby.tscn")
	elif GameConfig.auto_browse != "":
		# Restarted after updating from a server: back to the server list.
		_browse.call_deferred()

	if GameConfig.menu_notice != "":
		var note := _label(GameConfig.menu_notice, 14)
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_color_override("font_color", Color(1.0, 0.75, 0.45))
		centre.add_child(note)
		centre.move_child(note, 2) # under the title, above the pages
		GameConfig.menu_notice = ""

	var ver := _label("Version " + GameConfig.version(), 13)
	ver.modulate = Color(1, 1, 1, 0.45)
	ver.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ver.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ver.offset_right = -14
	ver.offset_bottom = -10
	add_child(ver)

func _continue(path: String) -> void:
	Net.leave()
	if GameConfig.load_game(path):
		get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _open_crew() -> void:
	GameConfig.crew_view = true
	get_tree().change_scene_to_file("res://scenes/Coaching.tscn")

func _browse(royale := false) -> void:
	GameConfig.browse_royale = royale
	Net.leave()
	GameConfig.reset()
	GameConfig.mode = GameConfig.Mode.GUEST
	get_tree().change_scene_to_file("res://scenes/ServerBrowser.tscn")

## Host the saved online match again. Friends join as usual, and each is put
## back in the crew they sailed.
func _continue_online() -> void:
	Net.leave()
	if not GameConfig.load_game(GameConfig.online_save_path):
		return
	if Net.host_game() != OK:
		GameConfig.menu_notice = "Couldn't host (is port %d busy?)." % Net.PORT
		get_tree().reload_current_scene()
		return
	Net.resuming = true
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")

func _start(mode: GameConfig.Mode) -> void:
	Net.leave()
	GameConfig.reset()
	GameConfig.mode = mode
	get_tree().change_scene_to_file("res://scenes/Setup.tscn")

# --- building blocks ----------------------------------------------------------------

func _add_back() -> void:
	_pages.add_child(_gap(4))
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(0, 40)
	back.add_theme_font_size_override("font_size", 18)
	back.pressed.connect(func() -> void: show_page(back_from(page)))
	_pages.add_child(back)

func _heading(text: String) -> Label:
	var h := UiTheme.heading(_label(text, 30))
	h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return h

func _setting_label(text: String) -> Label:
	var l := _label(text, 18)
	l.modulate = Color(1, 1, 1, 0.8)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l

func _first_button(node: Node) -> Button:
	for c in node.get_children():
		if c is Button and not (c as Button).disabled:
			return c
		var inner := _first_button(c)
		if inner != null:
			return inner
	return null

func _menu_button(title: String, blurb: String, enabled: bool, action: Callable) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var b := Button.new()
	b.text = title
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_size_override("font_size", 21)
	b.disabled = not enabled
	b.pressed.connect(action)
	box.add_child(b)
	var l := _label(blurb if enabled else blurb + "   (coming next)", 13)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = Color(1, 1, 1, 0.55 if enabled else 0.35)
	box.add_child(l)
	return box

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l

func _gap(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c
