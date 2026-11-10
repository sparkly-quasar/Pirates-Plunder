class_name CoachPanel
extends VBoxContainer

## One crew's coaching, a person at a time. Everyone gets ONE try: pick a skill
## for them to work on, or an attitude for them to develop, and the panel moves
## on to the next person. Picks can be changed (click a name in the roster)
## until Done; then every try is rolled at once and the results replace the
## panel. "Coach the rest for me" fills in anyone not yet picked for.
##
## The panel only collects the plan. Whoever owns it rolls the dice (the
## coaching screen, the match on the host) and hands back the results with
## show_results().

signal plan_done(plan: Dictionary)
signal person_renamed(index: int, wanted: String)

const SKILL_ROWS := ["speed", "stamina", "stealth", "swordfighting", "vision", "digging", "team_spirit"]
const PICKED := Color(1.0, 0.87, 0.55)

var team := 0
var people: Array[CharacterStats] = []
var picks := {}                 # index -> pick (CharacterStats.COACH_PICKS)
var current := 0
var finished := false
var waiting := false            # the plan went to the host; results to come

var _progress: Label
var _roster: HFlowContainer
var _roster_buttons: Array[Button] = []
var _person: Control
var _picture: Control
var _figure: Character
var _name_edit: LineEdit
var _class_label: Label
var _attitude_label: Label
var _odds_label: Label
var _skill_buttons := {}        # pick -> Button
var _skill_bars := {}           # skill -> SkillBar
var _attitude_buttons := {}     # attitude -> Button
var _prev: Button
var _next: Button
var _auto: Button
var _done: Button
var _results: VBoxContainer

func setup(team_: int, people_: Array[CharacterStats]) -> void:
	team = team_
	people = people_
	add_theme_constant_override("separation", 10)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build()
	if people.is_empty():
		show_results([{"text": "Nobody to coach this time.", "ok": false}])
		return
	if people.all(func(st: CharacterStats) -> bool: return st.auto_pick() == ""):
		show_results([{"text": "Everyone is as good as coaching can make them.", "ok": true}])
		return
	_show_person(0)

# --- what the owner calls ---------------------------------------------------

## The people changed outside (a rename came back from the host): show the new
## names and numbers, keeping the picks.
func set_people(people_: Array[CharacterStats]) -> void:
	if finished or people_.size() != people.size():
		return
	people = people_
	_show_person(current)

## The tries have been rolled: `lines` are {"text", "ok"} as
## GameConfig.coach_crew() makes them.
func show_results(lines: Variant) -> void:
	finished = true
	waiting = false
	_person.visible = false
	_roster.visible = false
	for b in [_prev, _next, _auto, _done]:
		b.visible = false
	_progress.text = "How the coaching went:"
	for c in _results.get_children():
		c.queue_free()
	var any := false
	if lines is Array:
		for line in lines:
			if not line is Dictionary:
				continue
			any = true
			var l := _label(str(line.get("text", "")), 15)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55) if bool(line.get("ok", false)) else Color(1, 1, 1, 0.55))
			_results.add_child(l)
	if not any:
		_results.add_child(_label("Nobody was coached this time.", 15))
	var good := 0
	if lines is Array:
		for line in lines:
			if line is Dictionary and bool(line.get("ok", false)):
				good += 1
	if any:
		var sum := _label("%d of %d tries worked." % [good, (lines as Array).size()], 15)
		sum.add_theme_color_override("font_color", PICKED)
		_results.add_child(sum)
	_results.visible = true

## The plan has gone to the host: hold everything until the results come.
func wait_for_results() -> void:
	waiting = true
	for b in [_prev, _next, _auto, _done]:
		b.disabled = true
	_progress.text = "Sent. Waiting for the host to roll your crew's coaching..."

# --- layout -----------------------------------------------------------------

func _build() -> void:
	_progress = _label("", 15)
	_progress.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_progress)

	_roster = HFlowContainer.new()
	_roster.add_theme_constant_override("h_separation", 6)
	_roster.add_theme_constant_override("v_separation", 6)
	add_child(_roster)
	for i in people.size():
		var b := Button.new()
		b.add_theme_font_size_override("font_size", 13)
		b.custom_minimum_size = Vector2(0, 30)
		b.pressed.connect(_show_person.bind(i))
		_roster.add_child(b)
		_roster_buttons.append(b)

	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.15, 0.20)
	style.border_color = Character.ui_colour(team).darkened(0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	card.add_theme_stylebox_override("panel", style)
	_person = card
	add_child(card)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 18)
	card.add_child(cols)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	left.custom_minimum_size = Vector2(220, 0)
	cols.add_child(left)
	_picture = Control.new()
	_picture.custom_minimum_size = Vector2(110, 110)
	_picture.clip_contents = true
	left.add_child(_picture)
	_name_edit = LineEdit.new()
	_name_edit.max_length = GameConfig.MAX_NAME_LENGTH
	_name_edit.tooltip_text = "Click to rename"
	_name_edit.add_theme_font_size_override("font_size", 20)
	var commit := func(_t: String = "") -> void:
		if not finished and _name_edit.text != people[current].person_name:
			person_renamed.emit(current, _name_edit.text)
	_name_edit.text_submitted.connect(commit)
	_name_edit.focus_exited.connect(commit)
	left.add_child(_name_edit)
	_class_label = _label("", 14)
	_class_label.modulate = Color(1, 1, 1, 0.7)
	left.add_child(_class_label)
	_attitude_label = _label("", 13)
	_attitude_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_attitude_label)
	_odds_label = _label("", 14)
	_odds_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_odds_label.add_theme_color_override("font_color", PICKED)
	left.add_child(_odds_label)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 5)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	right.add_child(_label("Work on one skill:", 14))
	for skill in SKILL_ROWS:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 8)
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(150, 28)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_pressed_color", PICKED)
		b.add_theme_color_override("font_hover_pressed_color", PICKED)
		b.pressed.connect(_choose.bind(skill))
		line.add_child(b)
		var bar := SkillBar.new()
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(bar)
		right.add_child(line)
		_skill_buttons[skill] = b
		_skill_bars[skill] = bar
	right.add_child(_label("Or develop an attitude (it makes every later try likelier):", 14))
	var atts := HBoxContainer.new()
	atts.add_theme_constant_override("separation", 8)
	for a in CharacterStats.ATTITUDES:
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 28)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_color_override("font_pressed_color", PICKED)
		b.add_theme_color_override("font_hover_pressed_color", PICKED)
		b.pressed.connect(_choose.bind(a))
		atts.add_child(b)
		_attitude_buttons[a] = b
	right.add_child(atts)

	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 8)
	_prev = _button("< Previous", func() -> void: _show_person(posmod(current - 1, people.size())))
	_next = _button("Next >", func() -> void: _show_person((current + 1) % people.size()))
	nav.add_child(_prev)
	nav.add_child(_next)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_child(gap)
	_auto = _button("Coach the rest for me", _auto_pick_rest)
	_auto.tooltip_text = "Picks for everyone you haven't: attitudes first, then each class's best skill, then spirit."
	nav.add_child(_auto)
	_done = UiTheme.primary(_button("Done: see how it goes", func() -> void:
		if not picks.is_empty():
			plan_done.emit(picks.duplicate())))
	nav.add_child(_done)
	add_child(nav)

	_results = VBoxContainer.new()
	_results.add_theme_constant_override("separation", 4)
	_results.visible = false
	add_child(_results)

func _show_person(i: int) -> void:
	if people.is_empty() or finished:
		return
	var same := current == clampi(i, 0, people.size() - 1) and _figure != null
	current = clampi(i, 0, people.size() - 1)
	var st := people[current]
	if _figure:
		_figure.queue_free()
	_figure = Character.new()
	_figure.setup(Vector2i.ZERO, st, team)
	_figure.position = Vector2(55, 62)
	_figure.scale = Vector2(3.4, 3.4)
	_picture.add_child(_figure)
	if not _name_edit.has_focus():
		_name_edit.text = st.person_name
	_class_label.text = "#%d of %d  ·  %s" % [current + 1, people.size(), st.class_name_]
	var has: Array[String] = []
	var lacks: Array[String] = []
	for a in CharacterStats.ATTITUDES:
		(has if bool(st.get(a)) else lacks).append(CharacterStats.ATTITUDE_NAMES[a])
	_attitude_label.text = ("Is " + " and ".join(has) + "." if not has.is_empty() else "Neither Coachable nor Self-Motivated yet.") \
		+ ("" if lacks.is_empty() else "  Not yet " + " or ".join(lacks) + ".")
	_odds_label.text = "Coaching takes %d%% of the time with them." % roundi(st.coach_chance() * 100.0)
	var chosen := str(picks.get(current, ""))
	for skill in SKILL_ROWS:
		var b: Button = _skill_buttons[skill]
		b.text = st.pick_text(skill) if st.can_coach(skill) else "%s (as far as it goes)" % CharacterStats.SKILL_NAMES[skill]
		b.disabled = not st.can_coach(skill) or waiting
		b.set_pressed_no_signal(chosen == skill)
		_skill_bars[skill].set_values(float(st.get(skill)), st.coach_cap(skill), st.start_value(skill), not same)
	for a in CharacterStats.ATTITUDES:
		var b: Button = _attitude_buttons[a]
		b.text = ("Become " + CharacterStats.ATTITUDE_NAMES[a]) if st.can_coach(a) else "Already " + CharacterStats.ATTITUDE_NAMES[a]
		b.disabled = not st.can_coach(a) or waiting
		b.set_pressed_no_signal(chosen == a)
	_refresh_roster()

func _refresh_roster() -> void:
	for i in _roster_buttons.size():
		var b := _roster_buttons[i]
		var st := people[i]
		var pick := str(picks.get(i, ""))
		b.text = "%s: %s" % [st.person_name, st.pick_text(pick) if pick != "" else "..."]
		b.add_theme_color_override("font_color", PICKED if pick != "" else Color(1, 1, 1, 0.7))
		b.flat = i != current
	var left := people.size() - picks.size()
	_progress.text = ("Pick one thing for each person to work on. %d of %d chosen." % [picks.size(), people.size()]) if left > 0 \
		else "Everyone has something to work on. Change any pick by clicking a name, or press Done."
	_done.disabled = picks.is_empty() or waiting
	_done.text = "Done: see how it goes" if left == 0 else "Done (%d sit this one out)" % left
	_auto.disabled = left == 0 or waiting

## A pick for whoever is showing, then on to the next person without one.
func _choose(pick: String) -> void:
	if finished or waiting:
		return
	picks[current] = pick
	for step in range(1, people.size() + 1):
		var i := (current + step) % people.size()
		if not picks.has(i):
			_show_person(i)
			return
	_show_person(current)

func _auto_pick_rest() -> void:
	for i in people.size():
		if not picks.has(i):
			var pick := people[i].auto_pick()
			if pick != "":
				picks[i] = pick
	_show_person(current)

func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.pressed.connect(on_press)
	return b

func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l
