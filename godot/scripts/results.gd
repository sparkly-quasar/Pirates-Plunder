extends Control

## The page after a game: who won and why, the score, each sailor's record,
## and a star of the game. From here it's on to coaching when there's coaching
## to do (a single-player win, or any game of a match); otherwise play again or
## go back to the menu.

const NAVS := Character.Team.NAVS
const PIRATES := Character.Team.PIRATES
const COLUMNS := [
	["found", "Chests found"], ["aboard", "Got aboard"], ["captures", "Captures"],
	["tied", "Ties"], ["lost", "Fights lost"], ["holes", "Holes dug"], ["steps", "Squares walked"],
]

var r: Dictionary

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	r = GameConfig.last_results
	if Net.is_online():
		Net.opponent_left.connect(_on_opponent_left)
	_build()

func _build() -> void:
	UiTheme.dress(self)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	root.offset_left = 30
	root.offset_top = 20
	root.offset_right = -30
	root.offset_bottom = -20
	add_child(root)

	var winner := int(r.get("winner", -1))
	var title := UiTheme.heading(_label(_headline(winner), 42))
	root.add_child(title)
	var reason := str(r.get("reason", ""))
	if reason != "":
		root.add_child(_label(reason[0].to_upper() + reason.substr(1) + ".", 18))

	var delivered: Array = r.get("delivered", [0, 0])
	var summary := "Turns played: %d    ·    Chests aboard: " % int(r.get("turn", 1))
	if bool(r.get("two_teams", false)):
		summary += "%s (of %d)" % [_per_team(delivered), int(r.get("total", 0))]
	else:
		summary += "%d of %d" % [int(delivered[0]), int(r.get("total", 0))]
	if GameConfig.battle_royale:
		summary += "    ·    Battle Royale, rounds won: " + _per_team(GameConfig.match_score, " – ")
	elif GameConfig.in_match():
		summary += "    ·    Match score: " + _per_team(GameConfig.match_score, " – ")
	var line := _label(summary, 15)
	line.modulate = Color(1, 1, 1, 0.8)
	root.add_child(line)

	if GameConfig.br_over():
		var done := _label(GameConfig.br_result(), 24)
		done.add_theme_color_override("font_color", Color(1.0, 0.80, 0.30))
		root.add_child(done)
	var star := _star()
	if not star.is_empty():
		root.add_child(_star_box(star))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	scroll.add_child(body)
	var teams: Array = range(_team_count())
	for team in teams:
		body.add_child(_team_table(team, winner))

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	var menu := Button.new()
	menu.text = "Leave the Match" if Net.is_online() else "Main Menu"
	menu.custom_minimum_size = Vector2(170, 48)
	menu.pressed.connect(func() -> void:
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/Menu.tscn"))
	bottom.add_child(menu)
	var next := UiTheme.primary(Button.new())
	next.custom_minimum_size = Vector2(0, 48)
	next.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next.add_theme_font_size_override("font_size", 21)
	if bool(r.get("coaching", false)):
		next.text = "Continue to Coaching  (Enter)"
		next.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/Coaching.tscn"))
	elif GameConfig.br_over():
		next.text = "Back to the Menu  (Enter)"
		next.pressed.connect(func() -> void:
			Net.leave()
			get_tree().change_scene_to_file("res://scenes/Menu.tscn"))
	elif GameConfig.in_campaign():
		next.text = "Try %s Again  (Enter)" % Campaign.chapter(GameConfig.campaign_chapter).title
		next.pressed.connect(func() -> void:
			CampaignScreen.show_chapter = GameConfig.campaign_chapter
			get_tree().change_scene_to_file("res://scenes/Campaign.tscn"))
	else:
		next.text = "Play Again on a New Island  (Enter)"
		next.pressed.connect(func() -> void:
			GameConfig.island_seed = randi()
			GameConfig.configured = true
			get_tree().change_scene_to_file("res://scenes/Main.tscn"))
	bottom.add_child(next)
	root.add_child(bottom)
	next.grab_focus.call_deferred()

func _headline(winner: int) -> String:
	if not bool(r.get("two_teams", false)):
		return "YOU WON!"
	if winner == GameServer.DRAW:
		return "A DRAW!"
	if winner < 0:
		return "GAME OVER"
	if GameConfig.mode == GameConfig.Mode.HOTSEAT and int(r.get("hotseat_people", 2)) > 1:
		return "THE %s WON!" % _side_name(winner).to_upper()
	return "YOU WON!" if _won(int(r.get("viewer", NAVS)), winner) else "THE %s WON" % _side_name(winner).to_upper()

## Did `team` win: it's the winner, or (2v2) the winner's partner.
func _won(team: int, winner: int) -> bool:
	var sides: Array = r.get("sides", [])
	if winner < 0:
		return false
	if team == winner:
		return true
	return sides.size() > maxi(team, winner) and int(sides[team]) == int(sides[winner])

## "NAVS", or in 2v2 "NAVS and the Corsairs".
func _side_name(team: int) -> String:
	var names := [GameServer.TEAM_NAMES[team]]
	for t in _team_count():
		if t != team and _won(t, team):
			names.append(GameServer.TEAM_NAMES[t])
	return " and the ".join(names)

func _team_count() -> int:
	if not bool(r.get("two_teams", false)):
		return 1
	return clampi(int(r.get("team_count", 2)), 2, Character.MAX_TEAMS)

## "NAVS 2, Pirates 1, Corsairs 3" — one number per crew in this game.
func _per_team(numbers: Array, sep := ", ") -> String:
	var parts: Array[String] = []
	for t in mini(numbers.size(), _team_count()):
		parts.append("%s %d" % [GameServer.TEAM_NAMES[t], int(numbers[t])])
	return sep.join(parts)

## One side: a heading, then a row per sailor with their picture and record.
func _team_table(team: int, winner: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var who := "THE %s" % GameServer.TEAM_NAMES[team].to_upper()
	var ctrl: Array = r.get("ctrl", [])
	if team < ctrl.size() and int(ctrl[team]) == GameConfig.Ctrl.COMPUTER and bool(r.get("two_teams", false)):
		who += "  (computer)"
	var head := _label("%s%s" % [who, "  —  winners" if _won(team, winner) else ""], 18)
	head.add_theme_color_override("font_color", _team_colour(team))
	box.add_child(head)
	var grid := GridContainer.new()
	grid.columns = COLUMNS.size() + 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)
	grid.add_child(_label("", 13))
	for col in COLUMNS:
		var h := _label(col[1], 13)
		h.modulate = Color(1, 1, 1, 0.65)
		grid.add_child(h)
	var status_head := _label("", 13)
	grid.add_child(status_head)
	for p in r.get("people", []):
		if int(p.team) != team:
			continue
		grid.add_child(_who(p))
		var t: Dictionary = p.tally
		for col in COLUMNS:
			var n := int(t.get(col[0], 0))
			var cell := _label(str(n), 16)
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			if n == 0:
				cell.modulate = Color(1, 1, 1, 0.35)
			grid.add_child(cell)
		var fate := "Captured" if bool(p.captured) else ("Holding a chest" if bool(p.get("carrying", false)) \
			else ("Came over" if bool(p.get("turncoat", false)) else ""))
		var f := _label(fate, 13)
		f.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45) if bool(p.captured) else Color(1.0, 0.87, 0.55))
		grid.add_child(f)
	return box

## A sailor's picture, name and class.
func _who(p: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(190, 0) # same width on both teams' tables, so the columns line up
	var picture := Control.new()
	picture.custom_minimum_size = Vector2(40, 44)
	picture.clip_contents = true
	var figure := Character.new()
	figure.setup(Vector2i.ZERO, CharacterStats.make(int(p.kind), str(p.name)), int(p.team))
	figure.position = Vector2(24, 24)
	figure.scale = Vector2(1.3, 1.3)
	if bool(p.captured):
		figure.modulate = Color(1, 1, 1, 0.35)
	picture.add_child(figure)
	row.add_child(picture)
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	names.add_child(_label(str(p.name), 16))
	var cls := _label(CharacterStats.make(int(p.kind)).class_name_, 12)
	cls.modulate = Color(1, 1, 1, 0.6)
	names.add_child(cls)
	row.add_child(names)
	return row

## Whoever did the most for their side: chests count most, then captures.
func _star() -> Dictionary:
	var best: Dictionary = {}
	var best_score := 0.0
	for p in r.get("people", []):
		var t: Dictionary = p.tally
		var score := 4.0 * int(t.get("aboard", 0)) + 3.0 * int(t.get("found", 0)) \
			+ 3.0 * int(t.get("captures", 0)) + 0.25 * int(t.get("holes", 0))
		if score > best_score:
			best_score = score
			best = p
	return best

func _star_box(p: Dictionary) -> Control:
	var t: Dictionary = p.tally
	var deeds: Array[String] = []
	if int(t.found) > 0:
		deeds.append("found %d chest%s" % [int(t.found), "" if int(t.found) == 1 else "s"])
	if int(t.aboard) > 0:
		deeds.append("got %d aboard" % int(t.aboard))
	if int(t.captures) > 0:
		deeds.append("captured %d" % int(t.captures))
	if deeds.is_empty():
		deeds.append("dug %d holes" % int(t.holes))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_who(p))
	var text := _label("★  Star of the game: %s the %s (%s) — %s." % [
		str(p.name), CharacterStats.make(int(p.kind)).class_name_, GameServer.TEAM_NAMES[int(p.team)],
		", ".join(deeds)], 16)
	text.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	row.add_child(text)
	return row

func _team_colour(team: int) -> Color:
	return Character.ui_colour(team)

func _on_opponent_left() -> void:
	GameConfig.menu_notice = Net.farewell("The server closed, so the match is over." if Net.dedicated
		else "The host left, so the match is over.")
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l
