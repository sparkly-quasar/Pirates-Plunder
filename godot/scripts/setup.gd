extends Control

## Pre-expedition setup: pick the island you'll play, and choose what your team
## is made of. Mirrors the original's Select Team Makeup dialog — you add and
## subtract across the five types, with a running "chosen X of Y" as you go.
##
## Every way of playing comes through here. The host picks the island, how
## many crews land (two to four), who sails each, and the team size; each guest
## sees the host's island and picks a crew of the same size. On a shared
## computer, and for computer crews, everyone gets the makeup chosen here.

const CLASS_ORDER := [
	CharacterStats.Kind.SCOUT,
	CharacterStats.Kind.DIGGER,
	CharacterStats.Kind.RUNNER,
	CharacterStats.Kind.FIGHTER,
	CharacterStats.Kind.SWORDSMAN,
]
const BLURBS := {
	CharacterStats.Kind.SCOUT: "Sees furthest and moves unseen. Your eyes.",
	CharacterStats.Kind.DIGGER: "Digs for 12 energy, not 35. Slow on his feet.",
	CharacterStats.Kind.RUNNER: "Fastest across the island, and recovers quickest.",
	CharacterStats.Kind.FIGHTER: "Solid at everything. No weaknesses.",
	CharacterStats.Kind.SWORDSMAN: "Wins swordfights. Tires quickly.",
}

const DIFFICULTY_BLURBS := {
	GameConfig.Difficulty.EASY: "Easy: computer crews tire sooner, rarely pick fights, and post no look-out.",
	GameConfig.Difficulty.NORMAL: "Normal: computer crews fight when the odds favour them and watch the leader's ship.",
	GameConfig.Difficulty.HARD: "Hard: computer crews take risks, hunt chest-carriers, and are hard to read.",
}

var grid: TerrainGrid
var preview: IslandPreview
var island_label: Label
var seed_edit: LineEdit
var count_labels := {}
var name_labels := {}          # class -> who would land as it
var total_label: Label
var target := GameConfig.DEFAULT_TEAM_SIZE
var target_label: Label
var start_button: Button
var reroll_row: Control
var target_controls: Array[Control] = []
var length_buttons := {}       # TerrainGrid.Length -> its button, relabelled as crews change
var seat_rows := {}            # team -> the row choosing who sails it
var difficulty_box: Control
var lobby_box: ServerLobbyBox  # on a server: who's in which seat, and the leader's Set Sail
var sides_box: Control         # four crews: free-for-all or 2v2, and the NAVS' partner
var partner_row: Control
var chat_box: ChatBox          # online guests: chat while everyone chooses
var royale_box: Control        # Battle Royale: the rounds, Vega, and the crew you bring

func _guest() -> bool:
	return GameConfig.mode == GameConfig.Mode.GUEST

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if _guest():
		target = GameConfig.team_target
	elif GameConfig.uses_crew():
		# Your saved crew lands as it is (topped up to ten while it's smaller).
		GameConfig.fit_counts_to_crew()
		target = GameConfig.team_size(GameConfig.nav_counts)
	_build()
	_roll_island(GameConfig.island_seed)
	for t in seat_rows:
		seat_rows[t].visible = t < GameConfig.team_count
	_refresh_sides()
	if _guest():
		reroll_row.visible = false
		for c in target_controls:
			c.visible = false
		Net.opponent_left.connect(_on_host_lost)
	_refresh()

func _on_host_lost() -> void:
	GameConfig.menu_notice = Net.farewell("The server closed the game." if Net.dedicated else "The host closed the game.")
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _build() -> void:
	UiTheme.dress(self)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	root.offset_left = 26
	root.offset_top = 18
	root.offset_right = -26
	root.offset_bottom = -18
	add_child(root)

	var name_l := _label("Pirates Plunder", 50)
	name_l.theme_type_variation = UiTheme.TITLE
	root.add_child(name_l)
	var sub := _label({
		GameConfig.Mode.SOLO: "Choose your island and your landing party.",
		GameConfig.Mode.COMPUTER: "Choose the island, how many rival crews, and your NAVS. The computer's crews land with the same makeup.",
		GameConfig.Mode.HOTSEAT: "Choose the island and how many crews. Every crew lands with the makeup you pick.",
		GameConfig.Mode.HOST: "Choose the island, the crews, and your NAVS. Friends pick their own crews when they join.",
		GameConfig.Mode.GUEST: _guest_intro(),
	}[GameConfig.mode], 15)
	if GameConfig.battle_royale and not _guest():
		sub.text = "Choose the island and the crews. In a Battle Royale every player brings their own trained crew."
	sub.modulate = Color(1, 1, 1, 0.7)
	root.add_child(sub)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 26)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(columns)

	columns.add_child(_island_panel())
	columns.add_child(_team_panel())

	if _guest() and Net.dedicated:
		lobby_box = ServerLobbyBox.new()
		root.add_child(lobby_box)
	if _guest():
		chat_box = ChatBox.new()
		chat_box.lines = 3
		root.add_child(chat_box)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(120, 46)
	back.pressed.connect(func() -> void:
		var to_list := _guest() and Net.dedicated
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/ServerBrowser.tscn" if to_list else "res://scenes/Menu.tscn"))
	bottom.add_child(back)
	start_button = UiTheme.primary(Button.new())
	start_button.text = "Start Expedition"
	start_button.custom_minimum_size = Vector2(0, 46)
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.add_theme_font_size_override("font_size", 20)
	start_button.pressed.connect(_on_start)
	bottom.add_child(start_button)
	root.add_child(bottom)

## A guest's line at the top: whose island, which crew is theirs, and in 2v2
## who's on which side.
func _guest_intro() -> String:
	var line := _guest_who()
	if GameConfig.two_v_two():
		line += "  2 v 2: %s." % GameConfig.sides_text()
	if GameConfig.turn_seconds > 0:
		line += "  %s." % GameConfig.turn_limit_text(GameConfig.turn_seconds).capitalize()
	return line

func _guest_who() -> String:
	var crew := GameConfig.team_name(GameConfig.my_team).to_upper()
	if not Net.dedicated:
		return "Your friend chose this island. Pick your crew: the %s." % crew
	if Net.i_lead():
		return "You started this game on the server. Pick your crew: the %s. Once everyone here has chosen, you can set sail." % crew
	var leader := int(Net.lobby.get("leader", -1))
	for seat in Net.lobby.get("seats", []):
		if seat is Dictionary and int(seat.get("team", -1)) == leader and str(seat.get("name", "")) != "":
			return "%s started this game. Pick your crew: the %s." % [GameConfig.clean_name(str(seat.name)), crew]
	return "The server chose this island. Pick your crew: the %s." % crew

func _island_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.add_child(_title("THE ISLAND", 19))

	preview = IslandPreview.new()
	box.add_child(preview)

	island_label = _label("", 14)
	island_label.modulate = Color(1, 1, 1, 0.8)
	box.add_child(island_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	reroll_row = row
	var reroll := Button.new()
	reroll.text = "New Island"
	reroll.pressed.connect(func() -> void: _roll_island(randi()))
	row.add_child(reroll)

	row.add_child(_label("Seed:", 14))
	seed_edit = LineEdit.new()
	seed_edit.custom_minimum_size = Vector2(130, 0)
	seed_edit.tooltip_text = "Same seed builds the same island: share it to play the same map."
	seed_edit.text_submitted.connect(func(t: String) -> void: _roll_island(int(t)))
	row.add_child(seed_edit)
	box.add_child(row)

	box.add_child(_length_row())
	if GameConfig.mode == GameConfig.Mode.HOST or GameConfig.mode == GameConfig.Mode.HOTSEAT:
		box.add_child(_turn_row())
	if GameConfig.mode != GameConfig.Mode.SOLO and not _guest():
		box.add_child(_crews_box())

	return box

## How many crews land, and (sharing a computer, or hosting) whether each one
## past the NAVS is sailed by a person or by the computer. More crews means a
## bigger island with more chests.
func _crews_box() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label("Crews:", 14))
	var group := ButtonGroup.new()
	for n in range(GameConfig.MIN_TEAMS, GameConfig.MAX_TEAMS + 1):
		var b := Button.new()
		if GameConfig.mode == GameConfig.Mode.COMPUTER:
			b.text = "%d rival%s" % [n - 1, "" if n == 2 else "s"]
		else:
			b.text = "%d crews" % n
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = n == GameConfig.team_count
		b.pressed.connect(func() -> void:
			GameConfig.team_count = n
			_on_crews_changed())
		row.add_child(b)
	col.add_child(row)
	sides_box = _sides_box()
	col.add_child(sides_box)
	if GameConfig.mode != GameConfig.Mode.COMPUTER:
		for t in range(1, GameConfig.MAX_TEAMS):
			var seat := HBoxContainer.new()
			seat.add_theme_constant_override("separation", 8)
			var who := _label("    " + GameConfig.team_name(t), 14)
			who.custom_minimum_size = Vector2(120, 0)
			who.add_theme_color_override("font_color", Character.ui_colour(t))
			seat.add_child(who)
			var seat_group := ButtonGroup.new()
			for cpu in [false, true]:
				var b := Button.new()
				if cpu:
					b.text = "Computer"
				else:
					b.text = "A friend online" if GameConfig.mode == GameConfig.Mode.HOST else "A player here"
				b.toggle_mode = true
				b.button_group = seat_group
				b.button_pressed = GameConfig.is_computer(t) == cpu
				b.pressed.connect(func() -> void:
					GameConfig.controllers[t] = GameConfig.Ctrl.COMPUTER if cpu else GameConfig.Ctrl.HUMAN
					_on_crews_changed())
				seat.add_child(b)
			seat_rows[t] = seat
			col.add_child(seat)
	var rule := _label("Three or four crews: you win once nobody can catch you, when no rival\ncould pass your chests even with every one still on the island.", 12)
	rule.name = "FreeForAllRule"
	rule.modulate = Color(1, 1, 1, 0.55)
	col.add_child(rule)
	return col

## Four crews: every crew for itself, or two sides of two (2v2). In 2v2 the
## chooser picks which crew teams up with the NAVS; the other two are a side.
func _sides_box() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label("Sides:", 14))
	var group := ButtonGroup.new()
	for paired in [false, true]:
		var b := Button.new()
		b.text = "2 v 2" if paired else "Free-for-all"
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = (GameConfig.partner != GameConfig.FREE_FOR_ALL) == paired
		b.pressed.connect(func() -> void:
			GameConfig.partner = Character.Team.CORSAIRS if paired else GameConfig.FREE_FOR_ALL
			_on_crews_changed())
		row.add_child(b)
	col.add_child(row)
	partner_row = HBoxContainer.new()
	partner_row.add_theme_constant_override("separation", 8)
	partner_row.add_child(_label("    NAVS with:", 14))
	var pgroup := ButtonGroup.new()
	for t in range(1, GameConfig.MAX_TEAMS):
		var b := Button.new()
		b.text = "the " + GameConfig.team_name(t)
		b.toggle_mode = true
		b.button_group = pgroup
		b.add_theme_color_override("font_color", Character.ui_colour(t))
		b.pressed.connect(func() -> void:
			GameConfig.partner = t
			_on_crews_changed())
		partner_row.add_child(b)
	col.add_child(partner_row)
	var rule := _label("", 12)
	rule.name = "SidesRule"
	rule.modulate = Color(1, 1, 1, 0.55)
	col.add_child(rule)
	return col

func _refresh_sides() -> void:
	if sides_box == null:
		return
	if GameConfig.battle_royale:
		GameConfig.partner = GameConfig.FREE_FOR_ALL
		sides_box.visible = false
		partner_row.visible = false
		return
	sides_box.visible = GameConfig.team_count == GameConfig.MAX_TEAMS
	if GameConfig.team_count != GameConfig.MAX_TEAMS:
		GameConfig.partner = GameConfig.FREE_FOR_ALL
	partner_row.visible = GameConfig.partner != GameConfig.FREE_FOR_ALL
	for i in range(1, partner_row.get_child_count()):
		(partner_row.get_child(i) as Button).set_pressed_no_signal(GameConfig.partner == i)
	var ffa_rule := sides_box.get_parent().get_node_or_null("FreeForAllRule")
	if ffa_rule:
		ffa_rule.visible = not GameConfig.two_v_two() # the 2v2 text says how a side wins
	var rule: Label = sides_box.get_node("SidesRule")
	rule.text = ("2 v 2: %s.\nPartners share what they see and can't fight each other. They can\nhand each other chests and load them on either ship; their chests add up." % GameConfig.sides_text()) \
		if GameConfig.two_v_two() else ""

func _on_crews_changed() -> void:
	_refresh_sides()
	for t in seat_rows:
		seat_rows[t].visible = t < GameConfig.team_count
	if difficulty_box:
		difficulty_box.visible = GameConfig.mode == GameConfig.Mode.COMPUTER or GameConfig.has_computer_crews()
	for level in length_buttons:
		length_buttons[level].text = _length_text(level)
	_roll_island(GameConfig.island_seed)
	_refresh()

func _length_text(level: int) -> String:
	return "%s (%d chests)" % [TerrainGrid.LENGTH_NAMES[level], TerrainGrid.chest_count(level, GameConfig.island_teams())]

func _team_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var heading := {
		GameConfig.Mode.HOTSEAT: "EVERY CREW",
		GameConfig.Mode.GUEST: "YOUR TEAM — THE %s" % GameConfig.team_name(GameConfig.my_team).to_upper(),
	}
	box.add_child(_title(heading.get(GameConfig.mode, "YOUR TEAM — THE NAVS"), 19))

	for kind in CLASS_ORDER:
		box.add_child(_class_row(kind))

	box.add_child(_spacer(8))
	var totals := HBoxContainer.new()
	totals.add_theme_constant_override("separation", 10)
	total_label = _label("", 17)
	totals.add_child(total_label)
	totals.add_child(_spacer(0, true))
	var size_label := _label("Team size:", 14)
	totals.add_child(size_label)
	var minus := _step_button("-", func() -> void: _set_target(target - 1))
	totals.add_child(minus)
	target_label = _label("", 16)
	target_label.custom_minimum_size = Vector2(26, 0)
	target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	totals.add_child(target_label)
	var plus := _step_button("+", func() -> void: _set_target(target + 1))
	totals.add_child(plus)
	target_controls = [size_label, minus, target_label, plus]
	box.add_child(totals)
	if GameConfig.mode != GameConfig.Mode.SOLO and not _guest():
		box.add_child(_spacer(6))
		difficulty_box = _difficulty_row()
		difficulty_box.visible = GameConfig.mode == GameConfig.Mode.COMPUTER or GameConfig.has_computer_crews()
		box.add_child(difficulty_box)
	if GameConfig.uses_crew():
		box.add_child(_spacer(6))
		box.add_child(_crew_row())
	if GameConfig.battle_royale:
		# No makeup to choose: everyone brings the crew they've trained.
		for c in box.get_children():
			if c != difficulty_box and box.get_child(0) != c:
				c.visible = false
		(box.get_child(0) as Label).text = "BATTLE ROYALE"
		royale_box = _royale_box()
		box.add_child(royale_box)
		box.move_child(royale_box, 1)
	return box

## Battle Royale: how many rounds and whether Vega may sail every round (the
## one setting it up chooses; a guest just sees them), and the crew this
## player brings.
func _royale_box() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	var what := _label("Every crew for itself. Each player brings the crew they've trained in single player, whole: no limits. The most rounds won takes it.", 14)
	what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	what.custom_minimum_size = Vector2(360, 0)
	col.add_child(what)
	if _guest():
		var rules := _label("%d round%s. Vega %s." % [GameConfig.br_rounds, "" if GameConfig.br_rounds == 1 else "s",
			"may sail every round" if GameConfig.br_vega else "only sails in the final round"], 15)
		rules.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
		col.add_child(rules)
	else:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(_label("Rounds:", 15))
		var group := ButtonGroup.new()
		for n in GameConfig.BR_ROUNDS:
			var b := Button.new()
			b.name = "Rounds%d" % n
			b.text = str(n)
			b.toggle_mode = true
			b.button_group = group
			b.custom_minimum_size = Vector2(48, 32)
			b.button_pressed = n == GameConfig.br_rounds
			b.pressed.connect(func() -> void: GameConfig.br_rounds = n)
			row.add_child(b)
		col.add_child(row)
		var vega := CheckBox.new()
		vega.name = "VegaEveryRound"
		vega.text = "Vega may sail every round (otherwise only in the final round)"
		vega.button_pressed = GameConfig.br_vega
		vega.toggled.connect(func(on: bool) -> void: GameConfig.br_vega = on)
		col.add_child(vega)
	var mine := GameConfig.my_br_crew()
	var regular := mine.filter(func(d: Dictionary) -> bool: return str(d.get("special", "")) == "")
	var has_vega := regular.size() < mine.size()
	var parts: Array[String] = []
	var counts := GameConfig.counts_of(mine)
	for kind in CLASS_ORDER:
		var n := int(counts.get(kind, 0))
		if n > 0:
			parts.append("%d %s%s" % [n, CharacterStats.make(kind).class_name_, "" if n == 1 else "s"])
	var bring := _label("", 14)
	bring.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bring.custom_minimum_size = Vector2(360, 0)
	if GameConfig.crew.is_empty():
		bring.text = "You have no trained crew yet, so you'll bring ten fresh recruits. Train one in single player (the campaign, or against the computer) to bring them here."
	else:
		bring.text = "You bring your crew: %d sailors (%s)%s." % [regular.size(), ", ".join(parts),
			", and Vega" if has_vega else ""]
	bring.modulate = Color(0.75, 0.95, 0.75)
	col.add_child(bring)
	return col

## Single player: who's coming back from last time, and a way to start over.
func _crew_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var note := _label("", 13)
	note.modulate = Color(1, 1, 1, 0.7)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(note)
	var fresh := Button.new()
	fresh.text = "Start a Fresh Crew"
	row.add_child(fresh)
	var show := func() -> void:
		var n := GameConfig.crew.size()
		note.text = ("Veterans keep their coaching: %d in your crew. They land first for their class." % n) if n > 0 \
			else "A fresh crew. Win against the computer to coach them."
		fresh.disabled = n == 0
	fresh.pressed.connect(func() -> void:
		GameConfig.clear_crew()
		show.call())
	show.call()
	return row

## Short, medium or long: a bigger island with more chests the longer the game.
## The host decides for both players.
func _length_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label("Game length:", 14))
	var group := ButtonGroup.new()
	for level in TerrainGrid.Length.values():
		var b := Button.new()
		b.text = _length_text(level)
		length_buttons[level] = b
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = level == GameConfig.length
		b.disabled = _guest()
		b.pressed.connect(func() -> void:
			GameConfig.length = level
			_roll_island(GameConfig.island_seed))
		row.add_child(b)
	return row

## Multiplayer: the longest a player's turn may last before it passes on.
## Games here start with no limit; a server's start with three minutes.
func _turn_row() -> Control:
	var row := HBoxContainer.new()
	row.name = "TurnLimit"
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label("Turn limit:", 14))
	var group := ButtonGroup.new()
	for secs in GameConfig.TURN_CHOICES:
		var b := Button.new()
		b.text = "None" if secs == 0 else "%d min" % (secs / 60)
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = secs == GameConfig.turn_seconds
		b.tooltip_text = "Each player's turn passes on after this long; a clock shows the time left."
		b.pressed.connect(func() -> void: GameConfig.turn_seconds = secs)
		row.add_child(b)
	return row

## Single player: how hard the computer's pirates play.
func _difficulty_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_label("Computer crews:", 15))
	var hint := _label(DIFFICULTY_BLURBS[GameConfig.difficulty], 12)
	hint.modulate = Color(1, 1, 1, 0.55)
	var group := ButtonGroup.new()
	for level in GameConfig.Difficulty.values():
		var b := Button.new()
		b.text = GameConfig.DIFFICULTY_NAMES[level]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(84, 32)
		b.button_pressed = level == GameConfig.difficulty
		b.pressed.connect(func() -> void:
			GameConfig.difficulty = level
			hint.text = DIFFICULTY_BLURBS[level])
		row.add_child(b)
	var col := VBoxContainer.new()
	col.add_child(row)
	col.add_child(hint)
	return col

## A class: its picture, name and what it's good at, the count with - and +,
## and underneath the names of who would land as that class.
func _class_row(kind: int) -> Control:
	var stats := CharacterStats.make(kind)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(ClassPicture.new(kind, GameConfig.my_team if _guest() else Character.Team.NAVS))

	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_theme_constant_override("separation", 0)
	var n := _label(stats.class_name_, 16)
	names.add_child(n)
	var blurb := _label(BLURBS[kind], 12)
	blurb.modulate = Color(1, 1, 1, 0.6)
	names.add_child(blurb)
	var who := _label("", 12)
	who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	who.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	name_labels[kind] = who
	names.add_child(who)
	row.add_child(names)

	row.add_child(_step_button("-", func() -> void: _adjust(kind, -1)))
	var count := _label("", 18)
	count.custom_minimum_size = Vector2(26, 0)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_labels[kind] = count
	row.add_child(count)
	row.add_child(_step_button("+", func() -> void: _adjust(kind, 1)))
	return row

# --- actions ---------------------------------------------------------------

func _roll_island(seed_value: int) -> void:
	GameConfig.island_seed = seed_value
	grid = TerrainGrid.new(seed_value, GameConfig.length, GameConfig.island_teams())
	preview.show_island(grid, GameConfig.my_team if _guest() else (-1 if GameConfig.mode == GameConfig.Mode.HOTSEAT else 0))
	island_label.text = IslandPreview.describe(grid)
	seed_edit.text = str(seed_value)

func _adjust(kind: int, delta: int) -> void:
	var counts := GameConfig.editing_counts()
	counts[kind] = maxi(0, int(counts.get(kind, 0)) + delta)
	_refresh()

func _set_target(value: int) -> void:
	target = clampi(value, 1, GameConfig.MAX_TEAM_SIZE)
	_refresh()

func _refresh() -> void:
	var side := GameConfig.my_team if _guest() else 0
	var roster := GameConfig.preview_roster(GameConfig.editing_counts(), side)
	for kind in CLASS_ORDER:
		count_labels[kind].text = str(int(GameConfig.editing_counts().get(kind, 0)))
		name_labels[kind].text = GameConfig.names_of(roster, kind)
		name_labels[kind].visible = name_labels[kind].text != ""
	var total := GameConfig.team_size()
	target_label.text = str(target)
	total_label.text = "Chosen %d of %d" % [total, target]
	if GameConfig.battle_royale:
		start_button.disabled = false
		start_button.text = "Bring My Crew" if _guest() else "Host This Battle Royale"
		return
	var ok := total == target
	total_label.modulate = Color(0.55, 0.95, 0.55) if ok else Color(1.0, 0.75, 0.35)
	start_button.disabled = not ok
	var go: String = {
		GameConfig.Mode.HOST: "Host This Island",
		GameConfig.Mode.GUEST: "Ready",
	}.get(GameConfig.mode, "Start Expedition")
	start_button.text = go if ok else (
		"Choose %d more" % (target - total) if total < target else "Remove %d" % (total - target))

func _on_start() -> void:
	GameConfig.team_target = target
	match GameConfig.mode:
		GameConfig.Mode.HOST:
			var err := Net.host_game()
			if err != OK:
				start_button.text = "Couldn't host (port %d busy?)" % Net.PORT
				return
			get_tree().change_scene_to_file("res://scenes/Lobby.tscn")
		GameConfig.Mode.GUEST:
			if GameConfig.battle_royale:
				Net.send_crew(GameConfig.my_br_crew())
			else:
				Net.send_ready(GameConfig.editing_counts())
			start_button.disabled = true
			start_button.text = "Waiting for the other players..." if Net.dedicated else "Waiting for the host..."
			for b in find_children("*", "Button", true, false):
				if b != start_button and b.text != "Back" and not chat_box.is_ancestor_of(b):
					b.disabled = true
			if lobby_box:
				lobby_box.chosen = true # after the loop above: this re-offers the leader's Set Sail
		_:
			if GameConfig.mode == GameConfig.Mode.HOTSEAT or GameConfig.mode == GameConfig.Mode.COMPUTER:
				for t in range(1, GameConfig.MAX_TEAMS):
					GameConfig.team_counts[t] = GameConfig.nav_counts.duplicate()
			GameConfig.configured = true
			get_tree().change_scene_to_file("res://scenes/Main.tscn")

# --- small ui helpers ------------------------------------------------------

func _title(text: String, size: int) -> Label:
	var l := UiTheme.heading(_label(text, size + 3))
	return l

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l

func _step_button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(34, 30)
	b.pressed.connect(action)
	return b

func _spacer(height: int, expand := false) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c
