extends Control

## Coaching between games, as between expeditions in the original: the crew
## is coached one person at a time, each getting ONE try at a skill or an
## attitude (see CoachPanel and CharacterStats.coach). The tries are rolled
## together when you're done, and the results listed.
##
## Single player: after a win against the computer, first a new recruit (you
## pick the class), then everyone who was on the island and the recruit. The
## saved crew keeps it for every later game. A match: after every game, each
## crew for the rest of that match only (see GameConfig), win or lose; every
## person's crew on a shared computer, your own online, where the host rolls
## the dice. Computer crews coach themselves.
##
## Your Crew (from the menu's Single Player page): a card for every sailor in
## your saved crew, to look over and rename, with nothing to coach; Back
## returns to the menu, and Start a New Crew lets them all go.

const COLUMNS := ["speed", "stamina", "stealth", "swordfighting", "vision", "digging", "team_spirit"]
const NAVS := Character.Team.NAVS
const PIRATES := Character.Team.PIRATES
const SetupScreen := preload("res://scripts/setup.gd")

var solo := false
var viewing := false            # Your Crew: look, rename, nothing to spend
var _clear_armed := false
var _dismiss_armed := -1
var teams: Array = []           # the crews this screen coaches
var solo_people: Array[CharacterStats] = []
var rng := RandomNumberGenerator.new()

var score_label: Label
var status_label: Label
var next_button: Button
var sections := {}              # Your Crew: team -> {rows: Array}
var panels := {}                # coaching: team -> CoachPanel
var _coach_holder: VBoxContainer
var _recruit_box: Control

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	rng.randomize()
	viewing = GameConfig.crew_view
	GameConfig.crew_view = false
	solo = viewing or not GameConfig.in_match()
	if viewing:
		teams = [NAVS]
		for d in GameConfig.crew:
			solo_people.append(_from_saved(d))
	elif solo:
		teams = [NAVS]
		GameConfig.coaching_sessions = 0 # this round is now, or not at all
		for d in GameConfig.crew:
			if GameConfig.last_party.has(str(d.name)):
				solo_people.append(_from_saved(d))
	else:
		match GameConfig.mode:
			GameConfig.Mode.HOTSEAT: teams = GameConfig.human_teams()
			GameConfig.Mode.GUEST: teams = [GameConfig.my_team]
			_: teams = [NAVS]
		Net.match_changed.connect(_refresh)
		Net.opponent_left.connect(_on_opponent_left)
	_build()
	_refresh()

# --- the crews, wherever they live -----------------------------------------

func _from_saved(d: Dictionary) -> CharacterStats:
	var st := CharacterStats.make(int(d.kind), str(d.name))
	st.apply_saved(d)
	return st

func _people(team: int) -> Array[CharacterStats]:
	if solo:
		return solo_people
	var out: Array[CharacterStats] = []
	for d in GameConfig.match_crews[team]:
		out.append(_from_saved(d))
	return out

## A crew's plan is in: roll it here (single player), on this computer's copy
## of the match (shared computer, host), or send it to the host (guest).
func _coach_plan(team: int, plan: Dictionary) -> void:
	var panel: CoachPanel = panels[team]
	if solo:
		var results := GameConfig.coach_crew(solo_people, plan, rng)
		GameConfig.remember(solo_people)
		_play_for(results)
		panel.show_results(results)
	elif GameConfig.mode == GameConfig.Mode.GUEST:
		Net.send_coaching_plan(plan) # the host rolls, and tells us how it went
		panel.wait_for_results()
		return
	else:
		if GameConfig.coach_plan_in_match(team, plan):
			_play_for(GameConfig.match_note[team])
			Net.send_match()
	_refresh()

func _play_for(results: Array) -> void:
	var took := results.any(func(r: Variant) -> bool: return r is Dictionary and bool(r.get("ok", false)))
	AudioManager.play(AudioManifest.COACH_SUCCESS if took else AudioManifest.COACH_FAIL)

func _rename(team: int, index: int, wanted: String) -> void:
	var why := ""
	if solo:
		var st := solo_people[index]
		why = GameConfig.rename_refusal(st.person_name, wanted)
		st.person_name = GameConfig.rename(st.person_name, wanted)
	elif GameConfig.mode == GameConfig.Mode.GUEST:
		Net.send_rename(index, wanted)
		return
	else:
		var d: Dictionary = GameConfig.match_crews[team][index]
		why = GameConfig.rename_refusal(str(d.name), wanted, GameConfig.match_crews[team])
		GameConfig.rename_in_match(team, index, wanted)
		Net.send_match()
	_refresh()
	if why != "":
		# Said after the refresh, which writes its own line.
		status_label.text = why

## Your Crew: the first press arms this card's Dismiss, the second lets the
## sailor go and draws the page again without them.
func _dismiss(index: int, button: Button) -> void:
	var who := solo_people[index].person_name
	if _dismiss_armed != index:
		_dismiss_armed = index
		for team in sections:
			for row in sections[team].rows:
				var other: Button = row.panel.find_child("Dismiss", true, false)
				if other != null:
					other.text = "Dismiss"
		button.text = "Click again: let %s go" % who
		status_label.text = "%s's training would be lost for good. Saved games keep the crew they had." % who
		return
	GameConfig.dismiss(who)
	GameConfig.crew_view = true # this page again, not the coaching screen
	get_tree().reload_current_scene()

# --- layout ----------------------------------------------------------------

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.12, 0.16)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	root.offset_left = 30
	root.offset_top = 20
	root.offset_right = -30
	root.offset_bottom = -20
	add_child(root)

	var title := _label("YOUR CREW" if viewing else "COACHING", 32)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	root.add_child(title)
	var lead := "Your crew won! Coach them before the next expedition." if solo \
		else "Coach your crew for the next game. Coaching lasts for the rest of this match."
	var how := " Everyone gets one try: a skill to work on, or an attitude to develop. A try takes 25% of the time, 50% for someone Coachable or Self-Motivated, 75% for someone both.\nThe white line on a bar is as far as coaching can take that skill. Spirit keeps a tired fighter dangerous."
	if viewing:
		lead = ("Everyone who has sailed with you in single player, as they stand now. Winning against the computer earns a round of coaching and a new recruit; confidence grows with every chest dug and fight won." if not solo_people.is_empty()
			else "Nobody yet. Your NAVS join the crew the first time they land in a single-player game, and keep their training from then on.")
		how = "\nThe tick on a bar is where that class started; the white line is as far as coaching can take it. Click a name to rename; Dismiss lets one sailor go." if not solo_people.is_empty() else ""
	var intro := _label(lead + how, 13)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.modulate = Color(1, 1, 1, 0.75)
	root.add_child(intro)
	score_label = _label("", 17)
	score_label.visible = not solo
	root.add_child(score_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	if viewing:
		for team in teams:
			body.add_child(_section(team))
	else:
		if solo and GameConfig.recruit_due:
			_recruit_box = _recruit_panel()
			body.add_child(_recruit_box)
		_coach_holder = VBoxContainer.new()
		_coach_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(_coach_holder)
		_build_panels()
		_coach_holder.visible = _recruit_box == null

	status_label = _label("", 15)
	status_label.modulate = Color(1, 1, 1, 0.8)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(status_label)
	if Net.is_online() and not Net.is_dedicated_host():
		var chat := ChatBox.new()
		chat.lines = 4
		root.add_child(chat)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	var leave := Button.new()
	leave.text = "Back" if viewing else "Main Menu" if solo or GameConfig.mode == GameConfig.Mode.HOTSEAT else "Leave Match"
	leave.custom_minimum_size = Vector2(150, 46)
	leave.pressed.connect(func() -> void:
		Net.leave()
		get_tree().change_scene_to_file("res://scenes/Menu.tscn"))
	bottom.add_child(leave)
	if viewing:
		bottom.add_child(_spacer())
		var fresh := Button.new()
		fresh.name = "NewCrew"
		fresh.text = "Start a New Crew"
		fresh.custom_minimum_size = Vector2(200, 46)
		fresh.disabled = solo_people.is_empty()
		fresh.tooltip_text = "Let everyone go: the next game starts with fresh recruits."
		fresh.pressed.connect(func() -> void:
			if not _clear_armed:
				_clear_armed = true
				fresh.text = "Click again: let them all go"
				status_label.text = "Everyone's training would be lost. Saved games keep the crew they had."
				return
			GameConfig.clear_crew()
			GameConfig.crew_view = true # this page again, not the coaching screen
			get_tree().reload_current_scene())
		bottom.add_child(fresh)
		root.add_child(bottom)
		return
	next_button = Button.new()
	next_button.text = "Next Expedition" if solo else "Next Game"
	if GameConfig.in_campaign():
		next_button.text = "On to the Ending" if GameConfig.ending_due else "Back to the Campaign"
	next_button.custom_minimum_size = Vector2(0, 46)
	next_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next_button.add_theme_font_size_override("font_size", 20)
	next_button.pressed.connect(_on_next)
	bottom.add_child(next_button)
	root.add_child(bottom)

## A CoachPanel per crew this screen coaches; several crews (two or more
## people sharing a computer) get a tab each.
func _build_panels() -> void:
	for c in _coach_holder.get_children():
		_coach_holder.remove_child(c)
		c.queue_free()
	panels = {}
	var holder: Container = _coach_holder
	if teams.size() > 1:
		var tabs := TabContainer.new()
		tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_coach_holder.add_child(tabs)
		holder = tabs
	for team in teams:
		var panel := CoachPanel.new()
		panel.name = "The " + GameServer.TEAM_NAMES[team]
		holder.add_child(panel)
		panel.setup(team, _people(team))
		panel.plan_done.connect(func(plan: Dictionary) -> void: _coach_plan(team, plan))
		panel.person_renamed.connect(func(index: int, wanted: String) -> void: _rename(team, index, wanted))
		panels[team] = panel

## Single player, after a win: one new sailor joins, of the class you choose,
## as before each expedition in the original. They're coached with the rest.
func _recruit_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var campaign := GameConfig.in_campaign()
	var head := _label("A PLACE ON THE NEXT ISLAND" if campaign else "A NEW RECRUIT", 22)
	head.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	box.add_child(head)
	var have := {}
	for st in solo_people:
		have[st.kind] = int(have.get(st.kind, 0)) + 1
	if campaign:
		var next := GameConfig.campaign_chapter + 1
		var ashore := Campaign.ashore()
		var intro := _label("The next island lands %d, so there's room for one more. Take on a new recruit%s." % [
			Campaign.party_size(next), ", or bring back someone from your crew" if not ashore.is_empty() else ""], 15)
		intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(intro)
		if not ashore.is_empty():
			box.add_child(_label("From your crew:", 14))
			var crew_row := HFlowContainer.new()
			crew_row.add_theme_constant_override("h_separation", 8)
			crew_row.add_theme_constant_override("v_separation", 8)
			box.add_child(crew_row)
			for d in ashore:
				var st := CharacterStats.make(int(d.kind), str(d.name))
				var b := Button.new()
				b.name = "Bring" + str(d.name)
				b.custom_minimum_size = Vector2(170, 52)
				b.text = "%s\nthe %s" % [st.person_name, st.class_name_]
				b.pressed.connect(func() -> void: _bring_back(st.person_name, st.class_name_))
				crew_row.add_child(b)
		box.add_child(_label("Or someone new: pick what they'll be.", 14))
	else:
		box.add_child(_label("Someone new wants to sail with you: pick what they'll be. You had %d on the island." % solo_people.size(), 15))
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_row.add_child(_label("Their name:", 14))
	var name_edit := LineEdit.new()
	name_edit.max_length = GameConfig.MAX_NAME_LENGTH
	name_edit.placeholder_text = "leave blank for one of ours"
	name_edit.custom_minimum_size = Vector2(240, 0)
	name_row.add_child(name_edit)
	box.add_child(name_row)
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	for kind in SetupScreen.CLASS_ORDER:
		var st := CharacterStats.make(kind)
		var b := Button.new()
		b.name = "Recruit" + st.class_name_
		b.custom_minimum_size = Vector2(250, 64)
		b.text = "%s  (you have %d)\n%s" % [st.class_name_, int(have.get(kind, 0)), SetupScreen.BLURBS[kind]]
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func() -> void: _take_recruit(kind, name_edit.text))
		grid.add_child(b)
	var skip := Button.new()
	skip.text = "Nobody new this time" if campaign else "No recruit this time"
	skip.custom_minimum_size = Vector2(0, 36)
	skip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	skip.pressed.connect(func() -> void:
		GameConfig.recruit_due = false
		_show_coaching())
	box.add_child(skip)
	return box

## The campaign: someone from your crew who hasn't sailed it yet takes the
## next island's new place.
func _bring_back(person: String, class_title: String) -> void:
	Campaign.add_to_party(person)
	GameConfig.recruit_due = false
	_show_coaching()
	status_label.text = "%s the %s joins the crew sailing for the Star Chart." % [person, class_title]

func _take_recruit(kind: int, wanted: String) -> void:
	var asked := wanted.strip_edges().left(GameConfig.MAX_NAME_LENGTH)
	var st := GameConfig.recruit(kind, wanted)
	if GameConfig.in_campaign():
		Campaign.add_to_party(st.person_name)
	solo_people.append(st)
	GameConfig.last_party.append(st.person_name)
	_build_panels()
	_show_coaching()
	status_label.text = "%s the %s joins the crew." % [st.person_name, st.class_name_]
	if asked != "" and asked != st.person_name:
		status_label.text += " (There's already a %s in your crew, so the new one is %s. You can rename them below.)" % [asked, st.person_name]

func _show_coaching() -> void:
	if _recruit_box:
		_recruit_box.queue_free()
		_recruit_box = null
	_coach_holder.visible = true
	_refresh()

## Your Crew: a card per sailor.
func _section(team: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var cards := HFlowContainer.new()
	cards.add_theme_constant_override("h_separation", 8)
	cards.add_theme_constant_override("v_separation", 8)
	box.add_child(cards)
	var rows: Array = []
	var people := _people(team)
	for i in people.size():
		var row := _card(team, i, people[i])
		cards.add_child(row.panel)
		rows.append(row)
	sections[team] = {"rows": rows}
	return box

## A sailor's card: their picture, an editable name, a bar per skill and their
## attitudes. _refresh fills in the numbers.
func _card(team: int, index: int, st: CharacterStats) -> Dictionary:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.15, 0.20)
	style.border_color = _team_colour(team).darkened(0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(206, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	panel.add_child(col)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var picture := Control.new()
	picture.custom_minimum_size = Vector2(56, 62)
	picture.clip_contents = true
	var figure := Character.new()
	figure.setup(Vector2i.ZERO, st, team)
	figure.position = Vector2(34, 34)
	figure.scale = Vector2(1.9, 1.9)
	picture.add_child(figure)
	top.add_child(picture)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var edit := LineEdit.new()
	edit.max_length = GameConfig.MAX_NAME_LENGTH
	edit.tooltip_text = "Click to rename"
	edit.add_theme_font_size_override("font_size", 15)
	var commit := func(_t: String = "") -> void: _rename(team, index, edit.text)
	edit.text_submitted.connect(commit)
	edit.focus_exited.connect(commit)
	names.add_child(edit)
	var cls := _label("", 13)
	cls.modulate = Color(1, 1, 1, 0.6)
	names.add_child(cls)
	top.add_child(names)
	col.add_child(top)
	var career := _label("", 12)
	career.name = "Career"
	career.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	career.custom_minimum_size = Vector2(190, 0)
	career.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55, 0.85))
	career.visible = viewing # Your Crew only
	col.add_child(career)

	var bars := {}
	for skill in COLUMNS:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 4)
		var name_label := _label(CharacterStats.SKILL_NAMES[skill], 12)
		name_label.custom_minimum_size = Vector2(50, 0)
		name_label.modulate = Color(1, 1, 1, 0.75)
		line.add_child(name_label)
		var bar := SkillBar.new()
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(bar)
		col.add_child(line)
		bars[skill] = bar
	var attitudes := _label("", 12)
	attitudes.modulate = Color(1, 1, 1, 0.6)
	col.add_child(attitudes)
	if viewing and st.special == "":
		# Your Crew: let this one sailor go (it asks twice).
		var go := Button.new()
		go.name = "Dismiss"
		go.text = "Dismiss"
		go.flat = true
		go.add_theme_font_size_override("font_size", 12)
		go.size_flags_horizontal = Control.SIZE_SHRINK_END
		go.modulate = Color(1, 1, 1, 0.7)
		go.tooltip_text = "Let this sailor go for good. Their training goes with them."
		go.pressed.connect(func() -> void: _dismiss(index, go))
		col.add_child(go)
	return {"panel": panel, "edit": edit, "class": cls, "figure": figure, "bars": bars, "attitudes": attitudes, "career": career}

func _team_colour(team: int) -> Color:
	return Character.ui_colour(team)

## Fills in what changed without rebuilding, so a name being typed isn't lost
## when another player coaches or renames someone.
func _refresh() -> void:
	if viewing:
		_refresh_cards()
		return
	for team in teams:
		var panel: CoachPanel = panels.get(team)
		if panel == null or panel.finished:
			continue
		if not solo and bool(GameConfig.match_coached[team]):
			panel.show_results(GameConfig.match_note[team])
		else:
			panel.set_people(_people(team))
	if solo:
		var done: bool = _recruit_box == null and panels.has(NAVS) and panels[NAVS].finished
		next_button.disabled = not done
		if _recruit_box != null:
			status_label.text = ("Choose who takes the new place first, then coach the crew." if GameConfig.in_campaign() else "Pick a recruit first, then coach the crew.")
		elif not done:
			status_label.text = "Give everyone something to work on, then press Done."
		return
	var s: Array = GameConfig.match_score
	var parts: Array[String] = []
	for t in s.size():
		parts.append("%s %d" % [GameServer.TEAM_NAMES[t], int(s[t])])
	score_label.text = "Match score:  " + "  –  ".join(parts)
	if GameConfig.battle_royale:
		score_label.text = "Battle Royale, rounds won:  " + "  –  ".join(parts)
		if GameConfig.br_over():
			next_button.disabled = true
			next_button.text = "The Battle Royale is over"
			status_label.text = GameConfig.br_result()
			return
		score_label.text += "     (next: %s)" % GameConfig.br_round_text().to_lower()
	if GameConfig.mode == GameConfig.Mode.HOTSEAT:
		var left: Array[String] = []
		for team in teams:
			if not panels[team].finished:
				left.append("the " + GameServer.TEAM_NAMES[team])
		next_button.disabled = not left.is_empty()
		status_label.text = ("Still to coach: %s. Each crew has its own tab." % ", ".join(left)) if not left.is_empty() \
			else "Every crew is coached."
		return
	var me: int = teams[0]
	var waiting: Array[String] = []
	for t in GameConfig.match_ready.size():
		if t != me and not bool(GameConfig.match_ready[t]) and not GameConfig.is_computer(t):
			waiting.append("the " + GameServer.TEAM_NAMES[t])
	var others := ", ".join(waiting)
	var coached: bool = panels[me].finished
	if bool(GameConfig.match_ready[me]):
		next_button.disabled = true
		next_button.text = "Waiting for the others..." if waiting.size() > 0 else "Setting sail..."
		status_label.text = "You're ready. The next island starts when %s %s too." % [others, "is" if waiting.size() == 1 else "are"]
	else:
		next_button.disabled = not coached
		next_button.text = "Ready for the Next Game"
		if not coached:
			status_label.text = "Give everyone something to work on, then press Done."
		else:
			status_label.text = ("Still coaching: %s." % others) if waiting.size() > 0 else "Everyone else is ready and waiting."

func _refresh_cards() -> void:
	for team in teams:
		var sec: Dictionary = sections[team]
		var people := _people(team)
		for i in mini(people.size(), sec.rows.size()):
			var st := people[i]
			var row: Dictionary = sec.rows[i]
			if not row.edit.has_focus():
				row.edit.text = st.person_name
			row["class"].text = "%s  ·  confidence %d" % [st.class_name_, roundi(st.confidence)]
			row.career.text = ("Career: " + st.career_text()) if st.career_text() != "" else "No games yet"
			row.figure.stats.person_name = st.person_name
			for skill in COLUMNS:
				row.bars[skill].set_values(float(st.get(skill)), st.coach_cap(skill), st.start_value(skill))
			var has: Array[String] = []
			for a in CharacterStats.ATTITUDES:
				if bool(st.get(a)):
					has.append(CharacterStats.ATTITUDE_NAMES[a])
			row.attitudes.text = ", ".join(has) if not has.is_empty() else "Not yet Coachable or Self-Motivated"

func _on_next() -> void:
	if GameConfig.in_campaign():
		if GameConfig.ending_due:
			get_tree().change_scene_to_file("res://scenes/Ending.tscn")
			return
		CampaignScreen.show_chapter = Campaign.next_open()
		get_tree().change_scene_to_file("res://scenes/Campaign.tscn")
		return
	if solo:
		GameConfig.island_seed = randi()
		get_tree().change_scene_to_file("res://scenes/Setup.tscn")
	elif GameConfig.mode == GameConfig.Mode.HOTSEAT:
		GameConfig.island_seed = randi()
		GameConfig.configured = true
		get_tree().change_scene_to_file("res://scenes/Main.tscn")
	else:
		Net.ready_for_next()
		if GameConfig.mode == GameConfig.Mode.GUEST:
			GameConfig.match_ready[GameConfig.my_team] = true # shown at once; the host confirms
		_refresh()

func _on_opponent_left() -> void:
	GameConfig.menu_notice = Net.farewell("The server closed, so the match is over." if Net.dedicated
		else "The host left, so the match is over.")
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l

func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c
